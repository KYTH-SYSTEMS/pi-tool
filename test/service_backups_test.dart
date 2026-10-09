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
      expect(s, contains('tar --warning=no-file-changed -czf'));
      expect(s, contains("-C '/opt/homeassistant/config'"));
      expect(s, contains('BACKUP_OK'));
    });

    test('a tar warning (exit 1) on a live HA is NOT a failure; only >1 is', () {
      final s = buildHomeAssistantBackupScript('/opt/homeassistant/config');
      expect(s, contains(r'rc=$?'));
      expect(s, contains(r'if [ "$rc" -gt 1 ]')); // exit 1 = warning, still OK
    });
    test('single-quotes the config path so it cannot break out', () {
      final s = buildHomeAssistantBackupScript("/x';reboot;'");
      expect(s, contains(r"'\''"));
      expect(s, isNot(contains("-C '/x';reboot")));
    });

    test('both backup scripts rotate: keep the newest 5, delete the rest', () {
      final p = buildPiholeBackupScript();
      expect(p, contains('tail -n +6'));
      expect(p, contains('pihole-backup-'));
      final h = buildHomeAssistantBackupScript('/opt/ha/config');
      expect(h, contains('tail -n +6'));
      expect(h, contains('homeassistant-backup-'));
    });
  });

  group('service backup management', () {
    // What the command lists is checked in a real shell, see 'backup list
    // commands in bash' in backup_scripts_test.dart.
    test('list command: one `sh -c` word, newest first, no sudo', () {
      expect(
          serviceBackupListCommand('pihole'),
          "sh -c 'ls -1t /var/backups/pi-tool/'\\''pihole'\\''-backup-* "
          "/var/backups/pi-tool/sched-'\\''pihole'\\''-* 2>/dev/null'");
    });

    test('evcc list command: the app\'s directory and both timer patterns', () {
      expect(
          listBackupsCommand,
          "sh -c 'ls -1t /var/backups/evcc/*.tar.gz "
          '/var/backups/pi-tool/sched-evcc-*.tar.gz '
          "/var/backups/pi-tool/autoupdate-evcc-*.tar.gz 2>/dev/null'");
    });

    test('parseServiceBackupList keeps .tar.gz and .zip archives only', () {
      const out = '/var/backups/pi-tool/pihole-backup-20260706-1.zip\n'
          '/var/backups/pi-tool/pihole-backup-20260705-1.tar.gz\n'
          'ls: nonsense\n';
      final list = parseServiceBackupList(out);
      expect(list, hasLength(2));
      expect(list.first, endsWith('.zip'));
    });

    test('delete command removes exactly the quoted file via sudo', () {
      final c = serviceBackupDeleteCommand("/var/backups/pi-tool/a'b.zip");
      expect(c, startsWith('LC_ALL=C sudo -S rm -f --'));
      expect(c, contains(r"'/var/backups/pi-tool/a'\''b.zip'")); // quoted
    });
  });

  group('timer archives', () {
    const dir = '/var/backups/pi-tool';

    test('backupOrigin tells them from the app\'s own by the file name', () {
      for (final (path, origin) in [
        ('/var/backups/evcc/evcc-backup-20260630-120000.tar.gz',
            BackupOrigin.app),
        ('$dir/pihole-backup-20260706-090000.zip', BackupOrigin.app),
        ('$dir/homeassistant-backup-20260706-090000.tar.gz', BackupOrigin.app),
        ('$dir/sched-evcc-20260630-030000.tar.gz', BackupOrigin.scheduled),
        ('$dir/sched-pihole-20260630-030000.zip', BackupOrigin.scheduled),
        ('$dir/autoupdate-evcc-20260630-040000.tar.gz',
            BackupOrigin.autoUpdate),
      ]) {
        expect(backupOrigin(path), origin, reason: path);
      }
    });

    test('isEvccRestorePath: the evcc directory and the two timer names', () {
      for (final path in [
        '/var/backups/evcc/evcc-backup-20260630-120000.tar.gz',
        '/var/backups/evcc/x.tar.gz', // the migration helper's upload
        '$dir/sched-evcc-20260630-030000.tar.gz',
        '$dir/autoupdate-evcc-20260630-040000.tar.gz',
      ]) {
        expect(isEvccRestorePath(path), isTrue, reason: path);
      }
    });

    test('isEvccRestorePath: nothing else from the shared backup directory',
        () {
      for (final path in [
        // Other services' archives: a different layout.
        '$dir/homeassistant-backup-20260630-120000.tar.gz',
        '$dir/pihole-backup-20260630-120000.tar.gz',
        '$dir/sched-pihole-20260630-030000.tar.gz',
        // Not the name the wrappers write.
        '$dir/sched-evcc-20260630-030000.tar.gz.part',
        '$dir/sched-evcc-latest.tar.gz',
        '$dir/sched-evcc-20260630-030000.zip',
        '$dir/sub/sched-evcc-20260630-030000.tar.gz',
        '$dir/../../tmp/sched-evcc-20260630-030000.tar.gz',
        '$dir/sched-evcc-20260630-030000.tar.gz\n',
        '/tmp/sched-evcc-20260630-030000.tar.gz',
        // Through the evcc directory into the shared one.
        '/var/backups/evcc/../pi-tool/homeassistant-backup-20260630-120000.tar.gz',
        '/var/backups/evcc/evcc-backup-20260630-120000.tar.gz.part',
        '/etc/passwd',
      ]) {
        expect(isEvccRestorePath(path), isFalse, reason: path);
      }
    });
  });

  group('buildPiholeRestoreScript', () {
    test('a v6 zip is imported via pihole-FTL --teleporter + DNS reload', () {
      final s =
          buildPiholeRestoreScript('/var/backups/pi-tool/pihole-backup-x.zip');
      expect(s, contains('pihole-FTL --teleporter'));
      expect(s, contains("'/var/backups/pi-tool/pihole-backup-x.zip'"));
      expect(s, contains('pihole reloaddns'));
      expect(s, contains('RESTORE_OK'));
    });

    // This path only ever runs on v6 (a v5 .tar.gz is refused above), and v6
    // exits 0 for the unknown `restartdns`. Using it here would silently skip
    // the reload AND void the `set -e` promise that a broken import aborts
    // before RESTORE_OK — the script would claim success with DNS untouched.
    test('does not use v6-dead restartdns, which would defeat set -e', () {
      final s =
          buildPiholeRestoreScript('/var/backups/pi-tool/pihole-backup-x.zip');
      expect(s, isNot(contains('pihole restartdns')));
    });

    test('quotes a hostile path (no injection)', () {
      final s = buildPiholeRestoreScript("/x';reboot;'.zip");
      expect(s, contains(r"'\''"));
      expect(s, isNot(contains("teleporter /x';reboot")));
    });

    test('a v5 tar.gz is refused with a clear message (web-UI only)', () {
      final s = buildPiholeRestoreScript(
          '/var/backups/pi-tool/pihole-backup-x.tar.gz');
      expect(s, contains('RESTORE_FAIL_V5'));
      expect(s, isNot(contains('--teleporter'))); // never attempt a v5 import
    });
  });

  group('buildHomeAssistantRestoreScript', () {
    test('stops the container, extracts into /config, starts it again', () {
      final s = buildHomeAssistantRestoreScript(
        archivePath: '/var/backups/pi-tool/homeassistant-backup-x.tar.gz',
        configPath: '/opt/homeassistant/config',
        containerName: 'homeassistant',
      );
      expect(s, contains("docker stop 'homeassistant'"));
      expect(s, contains("-C '/opt/homeassistant/config'"));
      expect(s, contains("docker start 'homeassistant'"));
      expect(s, contains('RESTORE_OK'));
    });

    test('quotes hostile values everywhere (no injection)', () {
      final s = buildHomeAssistantRestoreScript(
        archivePath: "/a';reboot;'.tar.gz",
        configPath: "/c';reboot;'",
        containerName: "n';reboot;'",
      );
      expect(s, isNot(contains("stop n';reboot")));
      expect(s, isNot(contains("-C /c';reboot")));
    });

    test('the container restarts even when tar fails (start is in a trap)', () {
      final s = buildHomeAssistantRestoreScript(
        archivePath: '/a.tar.gz',
        configPath: '/c',
        containerName: 'ha',
      );
      // docker start must be guaranteed via trap, not only on the happy path.
      expect(s, contains('trap'));
    });
  });

  group('buildCleanupScript / parseCleanupFreed', () {
    test('cleans apt, dangling docker images and old journal, reports space',
        () {
      final s = buildCleanupScript();
      expect(s, contains('autoremove -y'));
      expect(s, contains('apt-get clean'));
      // Only dangling images — container prune would delete our rollback
      // containers (…-evccpitool-old)!
      expect(s, contains('docker image prune -f'));
      expect(s, isNot(contains('container prune')));
      expect(s, isNot(contains('system prune')));
      expect(s, contains('journalctl --vacuum-time=7d'));
      expect(s, contains('CLEANUP_OK'));
    });

    test('parseCleanupFreed computes freed bytes from the marker', () {
      // before-avail=1 GB, after-avail=1.5 GB → 500 MB freed
      expect(parseCleanupFreed('x\nCLEANUP_OK 1000000000 1500000000\n'),
          500000000);
      // Nothing freed / negative drift clamps to 0.
      expect(parseCleanupFreed('CLEANUP_OK 1000 900'), 0);
      expect(parseCleanupFreed('no marker'), isNull);
    });
  });

  group('parseHaVersion (from /config/.HA_VERSION)', () {
    test('reads a calver version, trimmed', () {
      expect(parseHaVersion('2026.6.3\n'), '2026.6.3');
      expect(parseHaVersion('  2026.12.0 '), '2026.12.0');
    });
    test('null when no version is present (probe empty / HA not running)', () {
      expect(parseHaVersion(''), isNull);
      expect(parseHaVersion('cat: /config/.HA_VERSION: No such file'), isNull);
    });
  });

  group('haVersionProbe', () {
    test('finds the HA container and cats its version, no sudo', () {
      expect(haVersionProbe, contains('.HA_VERSION'));
      expect(haVersionProbe, contains('docker exec'));
      expect(haVersionProbe, isNot(contains('sudo')));
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
