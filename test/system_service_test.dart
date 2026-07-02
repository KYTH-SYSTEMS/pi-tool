import 'package:evcc_updater/src/services/system_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseOsPrettyName', () {
    test('reads PRETTY_NAME from os-release', () {
      const out = 'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n'
          'NAME="Debian GNU/Linux"\nVERSION_ID="12"\n';
      expect(parseOsPrettyName(out), 'Debian GNU/Linux 12 (bookworm)');
    });
    test('falls back to NAME when PRETTY_NAME is absent', () {
      expect(parseOsPrettyName('NAME="Raspbian"\nVERSION_ID="11"'), 'Raspbian');
    });
    test('null on empty / unrecognised', () {
      expect(parseOsPrettyName(''), isNull);
      expect(parseOsPrettyName('garbage'), isNull);
    });
  });

  group('parsePendingUpdates', () {
    test('reads the upgraded count from an apt-get -s upgrade summary', () {
      const out = 'Reading package lists...\n'
          '12 upgraded, 0 newly installed, 0 to remove and 3 not upgraded.';
      expect(parsePendingUpdates(out), 12);
    });
    test('zero when nothing is pending', () {
      expect(
        parsePendingUpdates('0 upgraded, 0 newly installed, 0 to remove.'),
        0,
      );
    });
    test('null when the summary line is missing', () {
      expect(parsePendingUpdates('Reading package lists...'), isNull);
    });
  });

  group('parseTemperatureC', () {
    test("reads vcgencmd output (temp=48.3'C)", () {
      expect(parseTemperatureC("temp=48.3'C\n"), 48.3);
    });
    test('reads sysfs millidegrees (thermal_zone0)', () {
      expect(parseTemperatureC('48312\n'), closeTo(48.3, 0.1));
    });
    test('null on empty / garbage', () {
      expect(parseTemperatureC(''), isNull);
      expect(parseTemperatureC('command not found'), isNull);
    });
  });

  group('parseDiskUsage', () {
    test('reads total/available/percent from df -P -BM /', () {
      const out = 'Filesystem     1048576-blocks  Used Available Capacity Mounted on\n'
          '/dev/root              29000M 11000M    16500M      42% /\n';
      final d = parseDiskUsage(out);
      expect(d, isNotNull);
      expect(d!.totalMb, 29000);
      expect(d.availableMb, 16500);
      expect(d.usedPercent, 42);
    });
    test('null when df failed', () {
      expect(parseDiskUsage(''), isNull);
      expect(parseDiskUsage('df: /: No such file'), isNull);
    });
  });

  group('parseMemAvailableMb', () {
    test('reads the available column from free -m', () {
      const out =
          '               total        used        free      shared  buff/cache   available\n'
          'Mem:             430         180          50           9         200         240\n'
          'Swap:             99           0          99\n';
      expect(parseMemAvailableMb(out), 240);
    });
    test('null when free failed', () {
      expect(parseMemAvailableMb(''), isNull);
    });
  });

  group('SystemHealth', () {
    test('summary joins the available readings', () {
      final h = SystemHealth(
        tempC: 48.3,
        disk: const DiskUsage(totalMb: 29000, availableMb: 16500, usedPercent: 42),
        memAvailableMb: 240,
      );
      expect(h.summary, contains('48.3°C'));
      expect(h.summary, contains('16.1 GB frei'));
      expect(h.summary, contains('RAM 240 MB'));
      expect(h.lowDisk, isFalse);
    });

    test('lowDisk warns below 1 GB free or ≥90% used', () {
      const lowAbs = SystemHealth(
          disk: DiskUsage(totalMb: 29000, availableMb: 800, usedPercent: 60));
      const lowPct = SystemHealth(
          disk: DiskUsage(totalMb: 29000, availableMb: 2000, usedPercent: 93));
      expect(lowAbs.lowDisk, isTrue);
      expect(lowPct.lowDisk, isTrue);
      expect(lowAbs.summary, contains('Speicher fast voll'));
    });

    test('missing readings are simply omitted', () {
      const h = SystemHealth();
      expect(h.summary, isEmpty);
      expect(h.lowDisk, isFalse);
    });
  });

  group('parseAptUpgrades', () {
    test('lists the packages a full-upgrade simulation would upgrade', () {
      const out = 'Reading package lists...\n'
          'Inst evcc [0.310.0] (0.311.0 evcc:armhf [armhf])\n'
          'Inst libfoo [1.0] (1.1 Debian:armhf [armhf])\n'
          'Conf evcc (0.311.0 evcc:armhf [armhf])\n'
          '2 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.';
      final pkgs = parseAptUpgrades(out);
      expect(pkgs, containsAll(['evcc', 'libfoo']));
      expect(pkgs.length, 2);
    });
    test('empty when nothing is upgraded', () {
      expect(parseAptUpgrades('0 upgraded, 0 newly installed, 0 to remove.'),
          isEmpty);
    });
  });
}
