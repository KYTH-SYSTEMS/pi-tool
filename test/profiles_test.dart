import 'package:evcc_updater/src/profiles.dart';
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
        autoCheck: true,
        backupBeforeUpdate: false,
        notifyUpdates: true,
        disclaimerAccepted: true,
        lastSeenVersion: '0.20.0',
        consoleHistory: ['df -h', 'docker ps'],
        customCommands: ['vcgencmd measure_temp', 'ls -la /etc'],
      );

      final back = parseAppConfig(encodeAppConfig(cfg));
      expect(back.backupBeforeUpdate, isFalse);
      expect(back.notifyUpdates, isTrue);
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
      expect(back.autoCheck, isTrue);
    });

    test('parse tolerates junk and falls back to initial', () {
      expect(parseAppConfig('').profiles.single.name, 'Standard');
      expect(parseAppConfig('not json').profiles.single.name, 'Standard');
      expect(parseAppConfig('[]').profiles.single.name, 'Standard');
    });

    test('notifyUpdates defaults OFF when the key is absent', () {
      expect(parseAppConfig('{"profiles":[],"activeIndex":0}').notifyUpdates,
          isFalse);
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
      expect(cfg.autoCheck, isTrue);
    });
  });
}
