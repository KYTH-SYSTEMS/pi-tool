import 'package:evcc_updater/src/commands.dart';
import 'package:evcc_updater/src/services/homeassistant_service.dart';
import 'package:evcc_updater/src/services/pihole_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseServiceBackupPath', () {
    test('reads the BACKUP_OK marker path', () {
      expect(
        parseServiceBackupPath('some log\nBACKUP_OK /var/backups/pi-tool/x.tar.gz\n'),
        '/var/backups/pi-tool/x.tar.gz',
      );
    });
    test('null when the marker is absent', () {
      expect(parseServiceBackupPath('BACKUP_FAIL\n'), isNull);
      expect(parseServiceBackupPath(''), isNull);
    });
  });

  group('buildPiholeBackupScript', () {
    final s = buildPiholeBackupScript();
    test('runs a teleporter export (v5 or v6) into the backup dir', () {
      expect(s, contains('/var/backups/pi-tool'));
      // v5 CLI teleporter or v6 pihole-FTL fallback.
      expect(s, contains('pihole -a -t'));
      expect(s, contains('pihole-FTL --teleporter'));
      expect(s, contains('BACKUP_OK'));
    });
  });

  group('buildHomeAssistantBackupScript', () {
    test('tars the config dir into the backup dir, shell-quoted', () {
      final s = buildHomeAssistantBackupScript('/opt/homeassistant/config');
      expect(s, contains('/var/backups/pi-tool'));
      expect(s, contains("tar -czf"));
      expect(s, contains("-C '/opt/homeassistant/config'"));
      expect(s, contains('BACKUP_OK'));
    });
    test('single-quotes the config path so it cannot break out', () {
      final s = buildHomeAssistantBackupScript("/x';reboot;'");
      expect(s, contains(r"'\''"));
      expect(s, isNot(contains("-C '/x';reboot")));
    });
  });

  group('homeAssistantConfigPath (from docker inspect)', () {
    test('reads the /config bind-mount source', () {
      const inspect = '[{"Name":"/homeassistant","Mounts":['
          '{"Type":"bind","Source":"/opt/homeassistant/config","Destination":"/config"},'
          '{"Type":"bind","Source":"/run/dbus","Destination":"/run/dbus"}]}]';
      expect(homeAssistantConfigPath(inspect), '/opt/homeassistant/config');
    });
    test('null when there is no /config mount', () {
      const inspect = '[{"Mounts":[{"Source":"/x","Destination":"/data"}]}]';
      expect(homeAssistantConfigPath(inspect), isNull);
      expect(homeAssistantConfigPath(''), isNull);
    });
  });
}
