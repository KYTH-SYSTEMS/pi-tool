import 'package:evcc_updater/src/history.dart';
import 'package:evcc_updater/src/profiles.dart';
import 'package:evcc_updater/src/settings_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory [FlutterSecureStorage] for tests — intercepts every call via
/// [noSuchMethod] so we don't have to match the (option-heavy) signatures.
class FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> data;
  FakeSecureStorage([Map<String, String>? initial]) : data = {...?initial};

  /// Reads throw — what the plugin does with `resetOnError: false` when a
  /// stored value cannot be decrypted.
  bool failReads = false;

  /// How many of the next deleteAll calls throw (a storage that does not open).
  int failDeleteAlls = 0;

  /// Every call by member name, and next to it the Android options that call
  /// passed on its own (null = the instance's).
  final calls = <Symbol>[];
  final callOptions = <AndroidOptions?>[];

  static PlatformException _keystoreError() => PlatformException(
      code: 'Exception encountered', message: 'AEADBadTagException');

  @override
  dynamic noSuchMethod(Invocation i) {
    calls.add(i.memberName);
    callOptions.add(i.namedArguments[#aOptions] as AndroidOptions?);
    switch (i.memberName) {
      case #read:
        if (failReads) return Future<String?>.error(_keystoreError());
        return Future.value(data[i.namedArguments[#key]]);
      case #write:
        final k = i.namedArguments[#key] as String;
        final v = i.namedArguments[#value] as String?;
        if (v == null) {
          data.remove(k);
        } else {
          data[k] = v;
        }
        return Future.value();
      case #delete:
        data.remove(i.namedArguments[#key]);
        return Future.value();
      case #deleteAll:
        if (failDeleteAlls > 0) {
          failDeleteAlls--;
          return Future<void>.error(_keystoreError());
        }
        data.clear();
        return Future.value();
      case #readAll:
        if (failReads) {
          return Future<Map<String, String>>.error(_keystoreError());
        }
        return Future.value(Map<String, String>.from(data));
      case #containsKey:
        return Future.value(data.containsKey(i.namedArguments[#key]));
      default:
        return Future.value();
    }
  }
}

void main() {
  group('SettingsStore', () {
    test('clear() deletes exactly the keys save() wrote', () async {
      final fake = FakeSecureStorage();
      final store = SettingsStore(fake);

      await store.save(const Settings(
        host: '192.168.178.64',
        port: '22',
        username: 'pi',
        password: 'secret',
        fullUpgrade: true,
      ));
      expect(fake.data['host'], '192.168.178.64');
      expect(fake.data['password'], 'secret');
      expect(fake.data.isNotEmpty, isTrue);

      await store.clear();
      // Every flat credential key must be gone — no stale copy left behind.
      expect(fake.data, isEmpty);
    });
  });

  group('AppConfigStore.load migration', () {
    test('migrates legacy flat keys, persists app_config, purges the legacy keys',
        () async {
      final fake = FakeSecureStorage({
        'host': '192.168.178.64',
        'user': 'pi',
        'password': 'secret',
        'fullUpgrade': 'true',
        'themeMode': 'dark',
      });
      final config = await AppConfigStore(fake).load();

      // Migrated into a single "Standard" profile.
      expect(config.active.host, '192.168.178.64');
      expect(config.active.password, 'secret');
      expect(config.active.fullUpgrade, isTrue);
      expect(config.themeMode, 'dark');
      // The new config is now persisted...
      expect(fake.data['app_config_v1'], isNotNull);
      // ...and the legacy flat credential keys are purged.
      expect(fake.data['host'], isNull);
      expect(fake.data['password'], isNull);
    });

    test('with app_config_v1 present, the legacy keys are left untouched',
        () async {
      final existing = encodeAppConfig(const AppConfig(
        profiles: [Profile(name: 'Pi', host: '10.0.0.5', password: 'pw')],
        activeIndex: 0,
      ));
      final fake = FakeSecureStorage({
        'app_config_v1': existing,
        'host': 'legacy-should-stay', // a stray legacy key
      });
      final config = await AppConfigStore(fake).load();

      expect(config.active.host, '10.0.0.5');
      // No migration ran → the stray legacy key is not cleared.
      expect(fake.data['host'], 'legacy-should-stay');
    });
  });

  // The plugin's default `resetOnError: true` deletes what it cannot decrypt
  // and answers "nothing stored" — the app then took that for a first start
  // and saved an empty configuration over the profiles. What the stores send
  // is checked where the plugin receives it: on its method channel.
  group('what the stores ask of the plugin', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    Object? Function(MethodCall call)? answer;

    Map<Object?, Object?> optionsOf(MethodCall c) =>
        (c.arguments as Map)['options'] as Map<Object?, Object?>;

    // The plugin's own defaults with the one flag turned off — same storage
    // file, key and cipher as before.
    final appOptions = {
      ...AndroidOptions.defaultOptions.params,
      'resetOnError': 'false',
    };

    setUp(() {
      calls.clear();
      answer = null;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return answer?.call(call);
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('every store sends resetOnError=false and nothing else off default',
        () async {
      expect(AndroidOptions.defaultOptions.params['resetOnError'], 'true');

      await AppConfigStore().load(); // empty → runs the legacy migration too
      final history = HistoryStore();
      await history.load();
      await history.add(const HistoryEntry(when: 't', text: 'x'));
      await history.clear();
      final hostKeys = SecureHostKeyStore();
      await hostKeys.get('hostkey:192.0.2.10:22');
      await hostKeys.set('hostkey:192.0.2.10:22', 'SHA256:abc');
      await hostKeys.remove('hostkey:192.0.2.10:22');
      final legacy = SettingsStore();
      await legacy.load();
      await legacy.save(Settings.empty);
      await legacy.clear();

      expect(calls.map((c) => c.method).toSet(),
          {'read', 'readAll', 'write', 'delete'});
      for (final c in calls) {
        expect(optionsOf(c), appOptions, reason: c.method);
      }
    });

    test('loading a stored configuration is still one read and nothing else',
        () async {
      final stored = encodeAppConfig(const AppConfig(
        profiles: [Profile(name: 'Pi', host: '192.0.2.10')],
        activeIndex: 0,
      ));
      answer = (call) => call.method == 'read' ? stored : null;

      final config = await AppConfigStore().load();

      expect(config.active.host, '192.0.2.10');
      expect(calls.map((c) => c.method), ['read']);
      expect((calls.single.arguments as Map)['key'], 'app_config_v1');
    });

    test('reset deletes everything, with the options of every other call',
        () async {
      await AppConfigStore().reset();

      expect(calls.map((c) => c.method), ['deleteAll']);
      expect(optionsOf(calls.single), appOptions);
    });

    test(
        'reset: a storage that does not open is handed to the plugin once, '
        'with its own resetOnError=true', () async {
      var failures = 1;
      answer = (call) {
        if (failures-- > 0) {
          throw PlatformException(
              code: 'Exception encountered',
              message: 'Migration failed after algorithm change');
        }
        return null;
      };

      await AppConfigStore().reset();

      expect(calls.map((c) => c.method), ['deleteAll', 'deleteAll']);
      expect(optionsOf(calls[0]), appOptions);
      expect(optionsOf(calls[1]), AndroidOptions.defaultOptions.params);
    });

    test('reset: when the plugin cannot recover either, the error is passed on',
        () async {
      answer = (call) => throw PlatformException(
          code: 'Exception encountered', message: 'KeyStoreException');

      await expectLater(
          AppConfigStore().reset(), throwsA(isA<PlatformException>()));
      expect(calls.map((c) => c.method), ['deleteAll', 'deleteAll']);
    });
  });

  // With resetOnError off, a value that cannot be decrypted reaches Dart as
  // an exception. No store may answer that with "nothing stored", and none
  // may write.
  group('a read that throws', () {
    final existing = encodeAppConfig(const AppConfig(
      profiles: [Profile(name: 'Pi', host: '10.0.0.5', password: 'pw')],
      activeIndex: 0,
    ));

    test('AppConfigStore.load passes it on and writes nothing', () async {
      final fake = FakeSecureStorage({'app_config_v1': existing})
        ..failReads = true;

      await expectLater(
          AppConfigStore(fake).load(), throwsA(isA<PlatformException>()));

      expect(fake.calls, [#read]);
      expect(fake.data, {'app_config_v1': existing});
    });

    test('a first start whose legacy keys cannot be read saves nothing',
        () async {
      // No app_config_v1 yet, so load() goes on to the legacy keys (readAll).
      final fake = _LegacyUnreadable({'host': '192.168.178.64'});

      await expectLater(
          AppConfigStore(fake).load(), throwsA(isA<PlatformException>()));

      expect(fake.calls, [#read, #readAll]);
      expect(fake.data, {'host': '192.168.178.64'});
    });

    test('SecureHostKeyStore.get passes it on — an unreadable pin is not '
        '"no pin"', () async {
      final fake = FakeSecureStorage({'hostkey:192.0.2.10:22': 'SHA256:abc'})
        ..failReads = true;

      await expectLater(SecureHostKeyStore(fake).get('hostkey:192.0.2.10:22'),
          throwsA(isA<PlatformException>()));
      expect(fake.data, {'hostkey:192.0.2.10:22': 'SHA256:abc'});
    });

    test('HistoryStore.add writes nothing — and the next add is not blocked',
        () async {
      const before = '[{"when":"2026-06-29 14:00","text":"alt"}]';
      final fake = FakeSecureStorage({'history_v1': before})..failReads = true;
      final store = HistoryStore(fake);

      await expectLater(
          store.add(const HistoryEntry(when: 't1', text: 'verloren')),
          throwsA(isA<PlatformException>()));
      expect(fake.data['history_v1'], before);
      expect(fake.calls, isNot(contains(#write)));

      fake.failReads = false;
      await store.add(const HistoryEntry(when: 't2', text: 'neu'));
      expect(parseHistory(fake.data['history_v1']!).map((e) => e.text),
          ['alt', 'neu']);
    });
  });

  group('resetSecureStorage', () {
    test('one deleteAll with the storage\'s own options when it works',
        () async {
      final fake = FakeSecureStorage({'app_config_v1': 'x', 'history_v1': 'y'});

      await resetSecureStorage(fake);

      expect(fake.data, isEmpty);
      expect(fake.calls, [#deleteAll]);
      expect(fake.callOptions, [null]);
    });

    test('falls back to the plugin\'s resetOnError=true when that throws',
        () async {
      final fake = FakeSecureStorage({'app_config_v1': 'x'})
        ..failDeleteAlls = 1;

      await resetSecureStorage(fake);

      expect(fake.data, isEmpty);
      expect(fake.calls, [#deleteAll, #deleteAll]);
      expect(fake.callOptions.first, isNull);
      expect(fake.callOptions.last!.params['resetOnError'], 'true');
    });
  });

  // add() reads the list, appends and writes it back.
  group('HistoryStore writes run one after the other', () {
    test('two adds started together both end up in the list', () async {
      final fake = FakeSecureStorage();
      final store = HistoryStore(fake);

      final first = store.add(const HistoryEntry(when: 't1', text: 'eins'));
      final second = store.add(const HistoryEntry(when: 't2', text: 'zwei'));
      await Future.wait([first, second]);

      expect((await store.load()).map((e) => e.text), ['eins', 'zwei']);
    });

    test('a clear behind a pending add is not undone by it', () async {
      final fake = FakeSecureStorage(
          {'history_v1': '[{"when":"t0","text":"alt"}]'});
      final store = HistoryStore(fake);

      final add = store.add(const HistoryEntry(when: 't1', text: 'eins'));
      final clear = store.clear();
      await Future.wait([add, clear]);

      expect(fake.data.containsKey('history_v1'), isFalse);
      expect(await store.load(), isEmpty);
    });
  });
}

/// A storage whose single reads work while reading everything throws: one
/// stored value among the legacy keys cannot be decrypted.
class _LegacyUnreadable extends FakeSecureStorage {
  _LegacyUnreadable(super.initial);

  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #readAll) failReads = true;
    return super.noSuchMethod(i);
  }
}
