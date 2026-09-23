import 'dart:io';

import 'package:evcc_updater/src/eol_sources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseDeadAptSource', () {
    test('reads the source from "no longer has a Release file"', () {
      // Verbatim from the Raspbian-Buster Pi that could not install Tailscale.
      const out = "Reading package lists...\n"
          "E: The repository 'http://raspbian.raspberrypi.org/raspbian buster "
          "Release' no longer has a Release file.";
      expect(parseDeadAptSource(out),
          'http://raspbian.raspberrypi.org/raspbian buster');
    });

    test('reads the older wording "does not have a Release file"', () {
      const out = "E: The repository 'http://deb.debian.org/debian "
          "buster-updates Release' does not have a Release file.";
      expect(parseDeadAptSource(out),
          'http://deb.debian.org/debian buster-updates');
    });

    test('null for a healthy run or an unrelated error', () {
      expect(parseDeadAptSource('Hit:1 http://x buster InRelease'), isNull);
      expect(parseDeadAptSource('E: Unable to locate package foo'), isNull);
    });
  });

  group('isAptLocked', () {
    test('recognises the dpkg frontend lock and the lists lock', () {
      expect(
          isAptLocked('E: Could not get lock /var/lib/dpkg/lock-frontend. It '
              'is held by process 1234 (unattended-upgr)'),
          isTrue);
      expect(
          isAptLocked('E: Unable to acquire the dpkg frontend lock '
              '(/var/lib/dpkg/lock-frontend), is another process using it?'),
          isTrue);
      expect(isAptLocked('E: Unable to lock directory /var/lib/apt/lists/'),
          isTrue);
    });
    test('false otherwise', () {
      expect(isAptLocked('0 upgraded, 0 newly installed'), isFalse);
    });
  });

  group('eolSourcesFixScript', () {
    test('targets only the official archives of the EOL releases', () {
      expect(eolSourcesFixScript, contains('http://legacy.raspbian.org/raspbian'));
      expect(eolSourcesFixScript, contains('http://archive.debian.org/debian'));
      expect(eolSourcesFixScript,
          contains('http://archive.debian.org/debian-security'));
      expect(eolSourcesFixScript, contains('jessie|stretch|buster'));
    });

    test('backs up outside sources.list.d and never fails the caller', () {
      expect(eolSourcesFixScript, contains('/var/backups/pi-tool/apt-sources'));
      expect(eolSourcesFixScript.trimRight(),
          endsWith('pitool_fix_eol_sources || true'));
    });

    test('reads the source files, never stdin (runs via bash -s)', () {
      // The script arrives on stdin; a loop reading stdin would eat its tail.
      expect(eolSourcesFixScript, contains('done <"\$f"'));
      expect(eolSourcesFixScript, isNot(contains('<<')));
    });

    test('runs as root through its own, recognisable command', () {
      expect(eolSourcesShellCommand, startsWith('LC_ALL=C sudo -S bash -s'));
      expect(eolSourcesShellCommand, isNot(equals('LC_ALL=C sudo -S bash -s')));
    });
  });

  // The real script in a real bash, against sandboxed source files. `curl` is a
  // stub that answers like the servers did on 2026-09-23 (old URLs 404, the
  // archives 200, stretch-updates gone everywhere), so this is deterministic
  // and offline. Skipped on Windows: `bash` there may be the WSL launcher.
  group('eolSourcesFixScript in bash', () {
    late Directory tmp;
    late String apt;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('eol');
      apt = '${tmp.path}/etc/apt';
      Directory('$apt/sources.list.d').createSync(recursive: true);
      final bin = Directory('${tmp.path}/bin')..createSync();
      File('${bin.path}/curl').writeAsStringSync(r'''#!/bin/sh
for a; do u=$a; done
case "$u" in
  *stretch-updates*) exit 22 ;;
  *legacy.raspbian.org*|*archive.debian.org*) exit 0 ;;
  *) exit 22 ;;
esac
''');
      Process.runSync('chmod', ['+x', '${bin.path}/curl']);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<ProcessResult> runFix() {
      final script = eolSourcesFixScript
          .replaceAll('/etc/apt', apt)
          .replaceAll('/var/backups/pi-tool', '${tmp.path}/backups');
      final f = File('${tmp.path}/fix.sh')..writeAsStringSync(script);
      return Process.run('bash', [f.path], environment: {
        'PATH': '${tmp.path}/bin:${Platform.environment['PATH']}',
      });
    }

    test('moves dead sources to the archive and keeps everything else',
        () async {
      File('$apt/sources.list').writeAsStringSync(
          'deb http://raspbian.raspberrypi.org/raspbian/ buster main contrib non-free rpi\n'
          '#deb-src http://raspbian.raspberrypi.org/raspbian/ buster main\n');
      File('$apt/sources.list.d/debian.list').writeAsStringSync(
          'deb [arch=arm64 signed-by=/k.gpg] http://security.debian.org buster/updates main\n'
          'deb http://deb.debian.org/debian stretch-updates main\n'
          'deb http://deb.debian.org/debian stretch main'); // no final newline
      const thirdParty =
          'deb https://dl.cloudsmith.io/public/evcc/stable/deb/raspbian buster main\n'
          'deb http://archive.raspberrypi.org/debian/ buster main\n';
      File('$apt/sources.list.d/other.list').writeAsStringSync(thirdParty);

      final r = await runFix();
      expect(r.exitCode, 0, reason: '${r.stderr}');

      expect(File('$apt/sources.list').readAsStringSync(),
          'deb http://legacy.raspbian.org/raspbian buster main contrib non-free rpi\n'
          '#deb-src http://raspbian.raspberrypi.org/raspbian/ buster main\n');
      expect(File('$apt/sources.list.d/debian.list').readAsStringSync(),
          'deb [arch=arm64 signed-by=/k.gpg] http://archive.debian.org/debian-security buster/updates main\n'
          '# deb http://deb.debian.org/debian stretch-updates main  # Pi-Tool: Quelle existiert nicht mehr\n'
          'deb http://archive.debian.org/debian stretch main\n');
      expect(File('$apt/sources.list.d/other.list').readAsStringSync(),
          thirdParty);
      expect(r.stdout, contains('Paketquelle umgestellt'));
      expect(r.stdout, contains('Paketquelle abgeschaltet'));

      // Originals backed up, and nothing extra left in sources.list.d.
      final backups = Directory('${tmp.path}/backups/apt-sources')
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .toList();
      expect(backups.where((b) => b.startsWith('sources.list.')), hasLength(1));
      expect(backups.where((b) => b.startsWith('debian.list.')), hasLength(1));
      expect(
          Directory('$apt/sources.list.d')
              .listSync()
              .map((e) => e.uri.pathSegments.last),
          unorderedEquals(['debian.list', 'other.list']));
    });

    test('a healthy or already repaired Pi is left alone, silently', () async {
      const healthy = 'deb http://raspbian.raspberrypi.org/raspbian/ bookworm main\n'
          'deb http://legacy.raspbian.org/raspbian buster main\n';
      File('$apt/sources.list').writeAsStringSync(healthy);

      final r = await runFix();
      expect(r.exitCode, 0);
      expect(r.stdout, isEmpty);
      expect(File('$apt/sources.list').readAsStringSync(), healthy);
      expect(Directory('${tmp.path}/backups').existsSync(), isFalse);
    });

    test('without network nothing is touched', () async {
      File('${tmp.path}/bin/curl').writeAsStringSync('#!/bin/sh\nexit 7\n');
      const dead = 'deb http://raspbian.raspberrypi.org/raspbian/ buster main\n';
      File('$apt/sources.list').writeAsStringSync(dead);

      final r = await runFix();
      expect(r.exitCode, 0);
      expect(File('$apt/sources.list').readAsStringSync(), dead);
    });
  }, skip: Platform.isWindows);
}
