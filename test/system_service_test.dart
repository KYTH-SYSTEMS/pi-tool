import 'dart:convert';
import 'dart:io';

import 'package:evcc_updater/src/services/system_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bash for the sandbox runs — absolute, because PATH inside the sandbox
/// is the stub directory alone. On Windows `bash` may be the WSL launcher, so
/// the group only runs with an explicit Git Bash
/// (PITOOL_TEST_BASH=C:\Program Files\Git\bin\bash.exe).
final String? _bash = Platform.isWindows
    ? Platform.environment['PITOOL_TEST_BASH']
    : (Process.runSync('bash', ['-c', 'command -v bash']).stdout as String)
        .trim();

/// A throwaway Pi for [systemAptRefreshCommand]: `sudo` and `apt-get` are
/// stubs, PATH holds only the stub directory, and /var/lib/apt/lists is a
/// directory in the sandbox whose package lists are ten days old.
class _AptBox {
  _AptBox() : _dir = Directory.systemTemp.createTempSync('pitool-apt') {
    root = _dir.path.replaceAll(r'\', '/');
    Directory('$root/bin').createSync();
    Directory(lists).createSync(recursive: true);
    for (final tool in ['sh', 'touch', 'expr', 'date', 'stat']) {
      final real = (Process.runSync(_bash!, ['-c', 'command -v $tool']).stdout
              as String)
          .trim();
      _stub(tool, 'exec $real "\$@"');
    }
    // Like `sudo -S`: the password comes as the first line on stdin.
    _stub('sudo', r'''
while [ "${1#-}" != "$1" ]; do shift; done
IFS= read -r pw
if [ "$pw" != sekret ]; then
  echo "Sorry, try again." >&2
  exit 1
fi
exec "$@"''');
    // Message texts as in apt-pkg/update.cc ("Failed to fetch %s  %s", "Some
    // index files failed to download. …"). A transient failure is a warning
    // and exits 0; with -qq a run without one prints nothing. The stub never
    // touches the lists directory — like apt when every source answers "Hit".
    _stub('apt-get', r'''
echo "apt-get $*" >> "$BOX/calls"
case "$APT_MODE" in
  clean) ;;
  notice)
    echo "W: Target Packages (main/binary-arm64/Packages) is configured multiple times in /etc/apt/sources.list:1 and /etc/apt/sources.list.d/raspi.list:1" >&2
    ;;
  transient)
    echo "W: Failed to fetch http://deb.debian.org/debian/dists/bookworm/InRelease  Temporary failure resolving 'deb.debian.org'" >&2
    echo "W: Some index files failed to download. They have been ignored, or old ones used instead." >&2
    ;;
  error)
    echo "E: The repository 'http://raspbian.raspberrypi.org/raspbian buster Release' does no longer have a Release file." >&2
    exit 100
    ;;
esac
exit 0''');
    Process.runSync(_bash!, ['-c', r'chmod +x "$0"/bin/*', root]);
    Process.runSync(_bash!, ['-c', r'touch -d "10 days ago" "$0"', lists]);
  }

  final Directory _dir;
  late final String root;
  String get lists => '$root/var/lib/apt/lists';

  void _stub(String name, String body) =>
      File('$root/bin/$name').writeAsStringSync('#!/bin/sh\n$body\n');

  String _rebased(String command) =>
      command.replaceAll('/var/lib/apt/lists', lists);

  /// Whether the apt-get stub was called at all.
  bool get aptRan => File('$root/calls').existsSync();

  /// Runs the refresh like the app does: the command line in a shell, the
  /// sudo password on stdin.
  Future<({int code, String out})> refresh(String mode,
      {String password = 'sekret'}) async {
    final p = await Process.start(
        _bash!, ['-c', _rebased(systemAptRefreshCommand)],
        environment: {'PATH': '$root/bin', 'APT_MODE': mode, 'BOX': root});
    final out = p.stdout.transform(utf8.decoder).join();
    final err = p.stderr.transform(utf8.decoder).join();
    p.stdin.write('$password\n');
    await p.stdin.close();
    return (code: await p.exitCode, out: '${await out}${await err}');
  }

  /// What detection concludes from the age its probe measures here: whether
  /// the lists are recent enough to trust "nothing pending".
  Future<bool> indexFresh() async {
    final r = await Process.run(_bash!, ['-c', _rebased(systemAptAgeCommand)],
        environment: {'PATH': '$root/bin'});
    final seconds = parseAptListsAgeSeconds(r.stdout as String);
    expect(seconds, isNotNull, reason: '${r.stdout}${r.stderr}');
    return isAptIndexFresh(seconds);
  }

  void dispose() => _dir.deleteSync(recursive: true);
}

void main() {
  // apt only changes the mtime of /var/lib/apt/lists when an index file is
  // replaced or removed. When every source answers "Hit" (frozen EOL archive,
  // a quiet week), a refresh left the measured age where it was, and the apt
  // cards kept saying "Paketlisten N Tage alt — Stand unbekannt".
  group('systemAptRefreshCommand in bash', () {
    late _AptBox box;
    setUp(() => box = _AptBox());
    tearDown(() => box.dispose());

    test('every source answers "Hit": the measured age still jumps back',
        () async {
      expect(await box.indexFresh(), isFalse);
      final r = await box.refresh('clean');
      expect(r.code, 0, reason: r.out);
      expect(box.aptRan, isTrue);
      expect(await box.indexFresh(), isTrue);
    });

    test('a warning that is not about a download does not stand in the way',
        () async {
      final r = await box.refresh('notice');
      expect(r.code, 0, reason: r.out);
      expect(r.out, contains('is configured multiple times'));
      expect(await box.indexFresh(), isTrue);
    });

    test('sources not reachable (apt exits 0 all the same): age stays', () async {
      // The old lists remain in use — claiming them fresh would bring back
      // the green "aktuell" over an index nobody refreshed.
      final r = await box.refresh('transient');
      expect(r.code, 0, reason: r.out);
      expect(r.out, contains('W: Failed to fetch'));
      expect(await box.indexFresh(), isFalse);
    });

    test('apt fails: age stays, apt\'s message and exit status are handed on',
        () async {
      final r = await box.refresh('error');
      expect(r.code, 100, reason: r.out);
      expect(r.out, contains('does no longer have a Release file'));
      expect(await box.indexFresh(), isFalse);
    });

    test('rejected sudo password: nothing runs', () async {
      final r = await box.refresh('clean', password: 'falsch');
      expect(r.code, isNot(0));
      expect(r.out, contains('Sorry, try again.'));
      expect(box.aptRan, isFalse);
      expect(await box.indexFresh(), isFalse);
    });
  }, skip: _bash == null ? 'needs bash (PITOOL_TEST_BASH on Windows)' : false);

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

  group('parseAptListsAgeSeconds', () {
    test('reads the age the Pi computed for its package lists', () {
      expect(parseAptListsAgeSeconds('864000\n'), 864000);
      expect(parseAptListsAgeSeconds('  42  '), 42);
    });
    test('zero (just refreshed) is a real answer, not "unknown"', () {
      expect(parseAptListsAgeSeconds('0'), 0);
    });
    test('null when the probe produced nothing usable', () {
      // stat/expr failed, path missing, permission denied, empty section.
      expect(parseAptListsAgeSeconds(''), isNull);
      expect(parseAptListsAgeSeconds('stat: cannot stat ...: No such file'),
          isNull);
      expect(parseAptListsAgeSeconds('expr: syntax error'), isNull);
    });
    test('null on a negative age (mtime in the future = broken clock)', () {
      expect(parseAptListsAgeSeconds('-120'), isNull);
    });
  });

  group('isAptIndexFresh', () {
    test('fresh below the 3-day threshold', () {
      expect(isAptIndexFresh(0), isTrue);
      expect(isAptIndexFresh(2 * 24 * 3600), isTrue);
    });
    test('stale at or beyond 3 days — this is the bug that shipped', () {
      // A 10-day-old index reported "0 upgraded" while 27 updates waited.
      expect(isAptIndexFresh(3 * 24 * 3600), isFalse);
      expect(isAptIndexFresh(10 * 24 * 3600), isFalse);
    });
    test('unknown age counts as NOT fresh (never claim what you cannot back)',
        () {
      expect(isAptIndexFresh(null), isFalse);
    });
  });

  group('aptIndexStaleDetail', () {
    test('names the age so the number is actionable', () {
      expect(aptIndexStaleDetail(10 * 24 * 3600), 'Paketlisten 10 Tage alt — Stand unbekannt');
    });
    test('says plainly when even the age is unknown', () {
      expect(aptIndexStaleDetail(null), 'Paketlisten-Stand unbekannt');
    });
  });

  group('parseTemperatureC', () {
    test("reads vcgencmd output (temp=48.3'C)", () {
      expect(parseTemperatureC("temp=48.3'C\n"), 48.3);
    });
    test('reads sysfs millidegrees (thermal_zone0)', () {
      expect(parseTemperatureC('48312\n'), closeTo(48.3, 0.1));
    });
    test('sysfs is ALWAYS millidegrees — small/negative values scale too', () {
      expect(parseTemperatureC('900\n'), closeTo(0.9, 0.01)); // not 900°C
      expect(parseTemperatureC('-3000\n'), closeTo(-3.0, 0.01)); // winter Pi
    });
    test('noise before the sysfs value (VCHI error on stdout) is skipped', () {
      expect(parseTemperatureC('VCHI initialization failed\n48312\n'),
          closeTo(48.3, 0.1));
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
    test('old free layout (buffers/cached, no available column) yields null', () {
      // procps < 3.3.10: last column is "cached" — returning it as available
      // would be a WRONG value; null is the contract.
      const out =
          '             total       used       free     shared    buffers     cached\n'
          'Mem:           430        180         50          9         40        200\n';
      expect(parseMemAvailableMb(out), isNull);
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

    test('lowDisk warns below 1 GB free or ≥90% used with little room left', () {
      const lowAbs = SystemHealth(
          disk: DiskUsage(totalMb: 29000, availableMb: 800, usedPercent: 60));
      const lowPct = SystemHealth(
          disk: DiskUsage(totalMb: 29000, availableMb: 2000, usedPercent: 93));
      expect(lowAbs.lowDisk, isTrue);
      expect(lowPct.lowDisk, isTrue);
      expect(lowAbs.summary, contains('Speicher fast voll'));
    });

    test('no false alarm on a big disk that is 90%+ used but has plenty free',
        () {
      // 1-TB SSD at 94% still has ~60 GB free — an apt upgrade cannot fail on
      // space, so the warning would be wrong.
      const big = SystemHealth(
          disk:
              DiskUsage(totalMb: 980000, availableMb: 60000, usedPercent: 94));
      expect(big.lowDisk, isFalse);
    });

    test('missing readings are simply omitted', () {
      const h = SystemHealth();
      expect(h.summary, isEmpty);
      expect(h.lowDisk, isFalse);
    });
  });

  group('storage health (SD-Karte)', () {
    test('probe reads mounts without sudo and counts kernel I/O errors', () {
      expect(systemStorageCommand, contains('/proc/mounts'));
      expect(systemStorageCommand, contains('journalctl -k'));
      expect(systemStorageCommand, isNot(contains('sudo')));
      expect(systemStorageCommand, contains('|| true')); // batch-safe
    });

    test('healthy rw mounts + zero errors → no warning', () {
      const out = '/dev/mmcblk0p2 / ext4 rw,noatime 0 0\n'
          '/dev/mmcblk0p1 /boot/firmware vfat rw,relatime 0 0\n'
          '0\n';
      final s = parseStorageHealth(out);
      expect(s.readOnlyMount, isNull);
      expect(s.kernelErrors, 0);
      expect(s.warning, isFalse);
    });

    test('read-only root is flagged (SD card likely failing)', () {
      const out = '/dev/mmcblk0p2 / ext4 ro,noatime 0 0\n'
          '/dev/mmcblk0p1 /boot/firmware vfat rw 0 0\n'
          '0\n';
      final s = parseStorageHealth(out);
      expect(s.readOnlyMount, '/');
      expect(s.warning, isTrue);
    });

    test('ro must match the option, not a substring (errors=remount-ro)', () {
      const out =
          '/dev/mmcblk0p2 / ext4 rw,noatime,errors=remount-ro 0 0\n0\n';
      final s = parseStorageHealth(out);
      expect(s.readOnlyMount, isNull); // "remount-ro" is not the ro option
      expect(s.warning, isFalse);
    });

    test('many kernel I/O errors warn even when mounts look fine', () {
      const out = '/dev/mmcblk0p2 / ext4 rw 0 0\n17\n';
      final s = parseStorageHealth(out);
      expect(s.kernelErrors, 17);
      expect(s.warning, isTrue);
    });

    test('a few transient errors do not warn', () {
      const out = '/dev/mmcblk0p2 / ext4 rw 0 0\n2\n';
      expect(parseStorageHealth(out).warning, isFalse);
    });

    test('missing count (no journalctl) → unknown, no warning', () {
      const out = '/dev/mmcblk0p2 / ext4 rw 0 0\n';
      final s = parseStorageHealth(out);
      expect(s.kernelErrors, isNull);
      expect(s.warning, isFalse);
    });

    test('empty/garbage output stays silent', () {
      expect(parseStorageHealth('').warning, isFalse);
      expect(parseStorageHealth('bash: no such file\n').warning, isFalse);
    });

    test('SystemHealth surfaces the SD warning in the summary', () {
      const h = SystemHealth(
        storage: (readOnlyMount: '/', kernelErrors: 0),
      );
      expect(h.summary, contains('SD-Karte prüfen'));
      expect(h.warning, isTrue);
    });

    test('SystemHealth.warning also covers lowDisk (existing behaviour)', () {
      const h = SystemHealth(
          disk: DiskUsage(totalMb: 30000, availableMb: 500, usedPercent: 98));
      expect(h.warning, isTrue);
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

  group('isDpkgInterrupted', () {
    test('recognises the apt refusal after a killed dpkg run', () {
      const out =
          "E: dpkg was interrupted, you must manually run 'sudo dpkg "
          "--configure -a' to correct the problem.";
      expect(isDpkgInterrupted(out), isTrue);
    });

    test('recognises it when only the remedy is echoed', () {
      expect(isDpkgInterrupted('run: sudo dpkg --configure -a'), isTrue);
    });

    test('an ordinary apt failure is NOT this case', () {
      expect(isDpkgInterrupted('E: Unable to locate package evcc'), isFalse);
      expect(isDpkgInterrupted(''), isFalse);
    });
  });
}
