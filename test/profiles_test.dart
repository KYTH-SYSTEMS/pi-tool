import 'package:evcc_updater/src/profiles.dart';
import 'package:evcc_updater/src/review_prompt.dart';
import 'package:evcc_updater/src/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Profile.lastGoodHost', () {
    test('survives the JSON round-trip', () {
      const p = Profile(
          name: 'Pi',
          lanHost: '192.168.178.125',
          tailscaleIp: '100.64.0.5',
          lastGoodHost: '100.64.0.5');
      expect(Profile.fromJson(p.toJson()).lastGoodHost, '100.64.0.5');
    });

    test('a profile written before this field loads empty, not broken', () {
      expect(Profile.fromJson(const {'name': 'Pi'}).lastGoodHost, '');
    });
  });

  group('Profile.copyWith', () {
    // Umbenennen eines NICHT aktiven Profils lief über copyWith(name:) — und
    // verlor dabei still Auto-Verbinden und den gemerkten letzten Stand.
    test('behält Auto-Verbinden und den gemerkten Stand', () {
      const p = Profile(name: 'Pi', autoConnect: true, cachedServices: [
        {'id': 'evcc', 'name': 'evcc', 'installed': true}
      ]);
      final renamed = p.copyWith(name: 'Garage');
      expect(renamed.name, 'Garage');
      expect(renamed.autoConnect, isTrue);
      expect(renamed.cachedServices, hasLength(1));
      expect(p.copyWith(autoConnect: false).autoConnect, isFalse);
    });

    test('keeps the ntfy destination, and sets it when told to', () {
      const p = Profile(
          name: 'Pi',
          alertsNtfyServer: 'https://ntfy.example.org',
          alertsNtfyTopic: 'pi-tool-k7m2q9x4vb3dwz');
      final renamed = p.copyWith(name: 'Garage');
      expect(renamed.alertsNtfyServer, 'https://ntfy.example.org');
      expect(renamed.alertsNtfyTopic, 'pi-tool-k7m2q9x4vb3dwz');
      final moved = p.copyWith(
          alertsNtfyServer: 'https://ntfy.sh', alertsNtfyTopic: 'anderes-thema');
      expect(moved.alertsNtfyServer, 'https://ntfy.sh');
      expect(moved.alertsNtfyTopic, 'anderes-thema');
      expect(moved.name, 'Pi');
    });
  });

  group('Profile ntfy destination', () {
    test('survives the JSON round-trip', () {
      const p = Profile(
          name: 'Pi',
          alertsNtfyServer: 'https://ntfy.example.org',
          alertsNtfyTopic: 'pi-tool-k7m2q9x4vb3dwz');
      final back = Profile.fromJson(p.toJson());
      expect(back.alertsNtfyServer, 'https://ntfy.example.org');
      expect(back.alertsNtfyTopic, 'pi-tool-k7m2q9x4vb3dwz');
    });

    test('a profile written before these fields has none of its own', () {
      final p = Profile.fromJson(const {'name': 'Pi', 'host': '10.0.0.5'});
      expect(p.alertsNtfyServer, '');
      expect(p.alertsNtfyTopic, '');
    });

    test('each profile of a config keeps its own', () {
      const cfg = AppConfig(profiles: [
        Profile(name: 'A', alertsNtfyTopic: 'thema-von-a-1234567'),
        Profile(name: 'B', alertsNtfyTopic: 'thema-von-b-7654321'),
        Profile(name: 'C'),
      ], activeIndex: 0, alertsNtfyTopic: 'app-weit-9999999999');
      final back = parseAppConfig(encodeAppConfig(cfg));
      expect(back.profiles.map((p) => p.alertsNtfyTopic),
          ['thema-von-a-1234567', 'thema-von-b-7654321', '']);
      expect(back.alertsNtfyTopic, 'app-weit-9999999999');
    });
  });

  group('effectiveNtfyDestination', () {
    test('the profile\'s own destination wins over the app-wide one', () {
      final d = effectiveNtfyDestination(
          profileServer: 'https://ntfy.example.org',
          profileTopic: 'eigenes-thema-123456',
          fallbackServer: 'https://ntfy.sh',
          fallbackTopic: 'app-weit-9999999999');
      expect(d.server, 'https://ntfy.example.org');
      expect(d.topic, 'eigenes-thema-123456');
    });

    test('a profile without one falls back to the app-wide destination', () {
      final d = effectiveNtfyDestination(
          profileServer: '',
          profileTopic: '',
          fallbackServer: 'https://ntfy.example.org',
          fallbackTopic: 'app-weit-9999999999');
      expect(d.server, 'https://ntfy.example.org');
      expect(d.topic, 'app-weit-9999999999');
    });

    test('neither known: the topic is empty, not made up', () {
      final d = effectiveNtfyDestination(
          profileServer: '',
          profileTopic: ' ',
          fallbackServer: 'https://ntfy.sh',
          fallbackTopic: '');
      expect(d.server, 'https://ntfy.sh');
      expect(d.topic, '');
    });
  });

  group('profilesForImport', () {
    test(
        'a profile without a destination of its own takes the exporting '
        'app\'s app-wide one along', () {
      const exported = AppConfig(
        profiles: [
          Profile(name: 'A'),
          Profile(
              name: 'B',
              alertsNtfyServer: 'https://ntfy.example.org',
              alertsNtfyTopic: 'thema-von-b-7654321'),
        ],
        activeIndex: 0,
        alertsNtfyServer: 'https://ntfy.sh',
        alertsNtfyTopic: 'app-weit-9999999999',
      );
      final imported = profilesForImport(exported);
      expect(imported.map((p) => p.name), ['A', 'B']);
      expect(imported[0].alertsNtfyServer, 'https://ntfy.sh');
      expect(imported[0].alertsNtfyTopic, 'app-weit-9999999999');
      expect(imported[1].alertsNtfyServer, 'https://ntfy.example.org');
      expect(imported[1].alertsNtfyTopic, 'thema-von-b-7654321');
    });

    test('an export without any topic leaves the profiles as they are', () {
      const exported = AppConfig(
          profiles: [Profile(name: 'A', host: '10.0.0.5')], activeIndex: 0);
      final imported = profilesForImport(exported);
      expect(imported.single.host, '10.0.0.5');
      expect(imported.single.alertsNtfyServer, '');
      expect(imported.single.alertsNtfyTopic, '');
    });
  });

  group('AppConfig encode/parse', () {
    test('round-trips profiles + globals', () {
      const cfg = AppConfig(
        profiles: [
          Profile(
              name: 'Zuhause',
              host: '192.168.178.64',
              authMode: AuthMode.key,
              privateKey: 'KEY',
              lanHost: '192.168.178.64',
              tailscaleIp: '100.64.1.5'),
          Profile(name: 'Eltern', host: '10.0.0.5', fullUpgrade: true),
        ],
        activeIndex: 1,
        uiScheme: 'https',
        uiPort: '8080',
        lockEnabled: true,
        themeMode: 'dark',
        channel: 'unstable',
        backupBeforeUpdate: false,
        disclaimerAccepted: true,
        lastSeenVersion: '0.20.0',
        consoleHistory: ['df -h', 'docker ps'],
        customCommands: ['vcgencmd measure_temp', 'ls -la /etc'],
      );

      final back = parseAppConfig(encodeAppConfig(cfg));
      expect(back.backupBeforeUpdate, isFalse);
      expect(back.disclaimerAccepted, isTrue);
      expect(back.lastSeenVersion, '0.20.0');
      expect(back.consoleHistory, ['df -h', 'docker ps']);
      expect(back.customCommands, ['vcgencmd measure_temp', 'ls -la /etc']);
      expect(back.profiles.length, 2);
      expect(back.profiles[0].name, 'Zuhause');
      expect(back.profiles[0].authMode, AuthMode.key);
      expect(back.profiles[0].privateKey, 'KEY');
      expect(back.profiles[0].lanHost, '192.168.178.64');
      expect(back.profiles[0].tailscaleIp, '100.64.1.5');
      expect(back.profiles[1].fullUpgrade, isTrue);
      expect(back.activeIndex, 1);
      expect(back.active.name, 'Eltern');
      expect(back.uiScheme, 'https');
      expect(back.uiPort, '8080');
      expect(back.lockEnabled, isTrue);
      expect(back.themeMode, 'dark');
      expect(back.channel, 'unstable');
    });

    test('parse tolerates junk and falls back to initial', () {
      expect(parseAppConfig('').profiles.single.name, 'Standard');
      expect(parseAppConfig('not json').profiles.single.name, 'Standard');
      expect(parseAppConfig('[]').profiles.single.name, 'Standard');
    });

    // autoCheck and notifyUpdates were stored but never read or set. A config
    // written by an older release still carries the keys.
    test('a stored config with the removed keys loads, and drops them', () {
      final cfg = parseAppConfig('{"activeIndex":1,'
          '"profiles":[{"name":"A","host":"10.0.0.5"},{"name":"B"}],'
          '"autoCheck":true,"notifyUpdates":true,'
          '"uiPort":"8080","backupBeforeUpdate":false}');
      expect(cfg.profiles.map((p) => p.name), ['A', 'B']);
      expect(cfg.profiles.first.host, '10.0.0.5');
      expect(cfg.activeIndex, 1);
      expect(cfg.uiPort, '8080');
      expect(cfg.backupBeforeUpdate, isFalse);

      final keys = cfg.toJson().keys;
      expect(keys, isNot(contains('autoCheck')));
      expect(keys, isNot(contains('notifyUpdates')));
    });

    test('disclaimerAccepted defaults OFF when the key is absent', () {
      expect(
          parseAppConfig('{"profiles":[],"activeIndex":0}').disclaimerAccepted,
          isFalse);
    });

    test('backupBeforeUpdate defaults ON when the key is absent', () {
      expect(parseAppConfig('{"profiles":[],"activeIndex":0}').backupBeforeUpdate,
          isTrue);
    });

    test('safeIndex/active clamp an out-of-range index', () {
      const cfg = AppConfig(
          profiles: [Profile(name: 'A'), Profile(name: 'B')], activeIndex: 9);
      expect(cfg.safeIndex, 1);
      expect(cfg.active.name, 'B');
    });

    test('the review-prompt state survives the round-trip', () {
      final state = ReviewPromptState.initial
          .recordSuccess(DateTime(2026, 10, 1))
          .recordSuccess(DateTime(2026, 10, 2))
          .recordAsk(DateTime(2026, 10, 9));
      final back = parseAppConfig(encodeAppConfig(AppConfig(
          profiles: const [Profile(name: 'A')],
          activeIndex: 0,
          reviewPrompt: state)));
      expect(back.reviewPrompt.successes, 2);
      expect(back.reviewPrompt.firstSuccessAt, DateTime(2026, 10, 1));
      expect(back.reviewPrompt.lastAskedAt, DateTime(2026, 10, 9));
      expect(back.reviewPrompt.asks, 1);
    });

    test('a config written before the review prompt starts it from zero', () {
      final cfg = parseAppConfig('{"profiles":[],"activeIndex":0}');
      expect(cfg.reviewPrompt.successes, 0);
      expect(cfg.reviewPrompt.asks, 0);
    });

    test('copyWith keeps the review-prompt state unless told otherwise', () {
      final state = ReviewPromptState.initial.recordSuccess(DateTime(2026));
      final cfg = AppConfig(
          profiles: const [Profile(name: 'A')],
          activeIndex: 0,
          reviewPrompt: state);
      expect(cfg.copyWith(uiPort: '8080').reviewPrompt.successes, 1);
      expect(
          cfg.copyWith(reviewPrompt: ReviewPromptState.initial)
              .reviewPrompt
              .successes,
          0);
    });

    test('empty profile list still yields a usable active profile', () {
      final cfg = parseAppConfig('{"profiles":[],"activeIndex":0}');
      expect(cfg.profiles, isNotEmpty);
      expect(cfg.active.name, 'Standard');
    });
  });

  group('migrateFromSettings', () {
    test('builds one "Standard" profile from the old flat settings', () {
      const s = Settings(
        host: '192.168.178.64',
        port: '22',
        username: 'pi',
        password: 'sekret',
        fullUpgrade: true,
        authMode: AuthMode.key,
        privateKey: 'PEM',
        keyPassphrase: 'pp',
        uiScheme: 'https',
        uiPort: '7000',
        lockEnabled: true,
        themeMode: 'dark',
        channel: 'unstable',
        autoCheck: true,
      );

      final cfg = migrateFromSettings(s);
      expect(cfg.profiles.single.name, 'Standard');
      expect(cfg.profiles.single.host, '192.168.178.64');
      expect(cfg.profiles.single.authMode, AuthMode.key);
      expect(cfg.profiles.single.privateKey, 'PEM');
      expect(cfg.profiles.single.fullUpgrade, isTrue);
      expect(cfg.activeIndex, 0);
      // globals carried over
      expect(cfg.uiScheme, 'https');
      expect(cfg.lockEnabled, isTrue);
      expect(cfg.themeMode, 'dark');
      expect(cfg.channel, 'unstable');
    });
  });
}
