import 'dart:convert';
import 'dart:io';

import 'package:evcc_updater/src/commands.dart';
import 'package:evcc_updater/src/services/apt_services.dart';
import 'package:evcc_updater/src/services/homeassistant_service.dart';
import 'package:flutter_test/flutter_test.dart';

// Home Assistant and InfluxDB 2 exist for 64-bit systems only. Both installers
// check that before they change anything and refuse with one
// `INSTALL_REFUSED: <Grund>` line — instead of installing Docker (or writing an
// apt source and a keyring) for something that can only fail afterwards.

/// The bash for the sandbox runs — absolute, because PATH inside the sandbox
/// is the stub directory alone. On Windows `bash` may be the WSL launcher, so
/// the sandbox groups only run with an explicit Git Bash
/// (PITOOL_TEST_BASH=C:\Program Files\Git\bin\bash.exe).
final String? _bash = Platform.isWindows
    ? Platform.environment['PITOOL_TEST_BASH']
    : (Process.runSync('bash', ['-c', 'command -v bash']).stdout as String)
        .trim();

/// Skip reason for the real-bash groups, or false when a bash is at hand.
final Object _needsBash =
    _bash == null ? 'needs bash (PITOOL_TEST_BASH on Windows)' : false;

/// A path usable inside PATH (Git Bash wants /c/... there, not C:/...).
String _posix(String p) {
  final s = p.replaceAll(r'\', '/');
  final m = RegExp(r'^([A-Za-z]):/').firstMatch(s);
  return m == null ? s : '/${m.group(1)!.toLowerCase()}/${s.substring(3)}';
}

String get _influxInstall =>
    knownAptServices.firstWhere((s) => s.id == 'influxdb').installScript!;

/// A throwaway "Pi" for running a real install script in a real bash. Every
/// command the script may call is a logging stub in `bin/`, and PATH holds
/// ONLY that directory, so nothing on the host (docker, apt, curl, sh,
/// systemctl) can leak in — the Home Assistant script would otherwise fetch
/// and run the real Docker installer. /etc, /opt and /tmp are rebased into the
/// sandbox. The dpkg and apt stubs drain stdin — like under `sudo -S bash -s`,
/// a call without its own `</dev/null` then swallows the rest of the script.
class _Pi {
  _Pi() : _dir = Directory.systemTemp.createTempSync('pitool-arch') {
    root = _dir.path.replaceAll(r'\', '/');
    // `later/`: commands that are not installed yet (Docker).
    for (final d in const [
      'bin',
      'later',
      'state',
      'tmp',
      'etc/apt/sources.list.d',
    ]) {
      Directory('$root/$d').createSync(recursive: true);
    }
    for (final tool in ['cat', 'rm', 'mkdir', 'grep', 'mv']) {
      final real = (Process.runSync(_bash!, ['-c', 'command -v $tool']).stdout
              as String)
          .trim();
      stub(tool, 'exec $real "\$@"', log: false);
    }
    stub(
        'dpkg',
        'case "\$1" in\n'
            '  --print-architecture) cat "$state/arch" ;;\n'
            '  --print-foreign-architectures) [ -f "$state/foreign" ] && cat "$state/foreign"; exit 0 ;;\n'
            '  *) exit 2 ;;\n'
            'esac',
        drainStdin: true);
    stub('uname', '[ "\$1" = -m ] && cat "$state/kernel"');
  }

  final Directory _dir;
  late final String root;
  String get state => '$root/state';

  /// Writes the executable stub [name]; each call is logged as `name args`.
  void stub(String name, String body,
      {bool log = true, bool drainStdin = false, String dir = 'bin'}) {
    File('$root/$dir/$name').writeAsStringSync('#!/bin/sh\n'
        '${log ? 'echo "$name \$*" >> "$state/calls"\n' : ''}'
        '${drainStdin ? 'cat >/dev/null\n' : ''}'
        '$body\n');
  }

  void remove(String name) => File('$root/bin/$name').deleteSync();

  /// dpkg's own architecture, the foreign ones, and what `uname -m` says.
  void system(String arch,
      {List<String> foreign = const [], required String kernel}) {
    File('$state/arch').writeAsStringSync('$arch\n');
    File('$state/foreign').writeAsStringSync(foreign.map((a) => '$a\n').join());
    File('$state/kernel').writeAsStringSync('$kernel\n');
  }

  bool exists(String abs) =>
      FileSystemEntity.typeSync('$root$abs', followLinks: false) !=
      FileSystemEntityType.notFound;

  List<String> get calls {
    final f = File('$state/calls');
    return f.existsSync()
        ? f.readAsLinesSync().where((l) => l.isNotEmpty).toList()
        : const [];
  }

  /// Calls that are not one of the guard's read-only questions.
  List<String> get changes => calls
      .where((c) =>
          !c.startsWith('dpkg --print-') &&
          !c.startsWith('uname ') &&
          !c.startsWith('docker ps '))
      .toList();

  /// Feeds [script] to `bash -s` on stdin, exactly like the app's root shell.
  /// PATH is set as the script's first line, not through the process
  /// environment: Git Bash's launcher puts its own directories (with a real
  /// curl, sh, gpg, uname) in front of whatever it inherits.
  Future<({int code, String out, String err})> run(String script) async {
    Process.runSync(_bash!, ['-c', r'chmod +x "$0"/bin/* "$0"/later/*', root]);
    final rebased = script.replaceAllMapped(
        RegExp(r'(?<![\w.$:/-])/(etc|opt|tmp)/'), (m) => '$root${m[0]}');
    final p = await Process.start(_bash!, ['-s']);
    final out = p.stdout.transform(utf8.decoder).join();
    final err = p.stderr.transform(utf8.decoder).join();
    p.stdin.add(utf8.encode("export PATH='${_posix('$root/bin')}'\n$rebased"));
    await p.stdin.close();
    return (code: await p.exitCode, out: await out, err: await err);
  }

  void dispose() => _dir.deleteSync(recursive: true);
}

/// Non-empty stdout lines, trimmed.
List<String> _lines(String out) =>
    out.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

void _expectRefused(({int code, String out, String err}) r, String needle) {
  expect(r.code, 3, reason: '${r.out}\n${r.err}');
  final lines = _lines(r.out);
  expect(lines.where((l) => l.startsWith(installRefusedPrefix)), hasLength(1),
      reason: r.out);
  expect(lines.last, startsWith(installRefusedPrefix));
  final reason = parseInstallRefusal(r.out);
  expect(reason, isNotNull);
  expect(reason, contains(needle));
  expect(reason, contains('64-Bit'));
  expect(r.out, isNot(contains('INSTALL_OK')));
}

void main() {
  group('Home Assistant install: architecture guard', () {
    final s = buildHomeAssistantInstallScript();

    test('asks dpkg before Docker is installed or anything is created', () {
      final guard = s.indexOf('dpkg --print-architecture');
      expect(guard, greaterThan(0));
      for (final change in [
        'get.docker.com',
        'mkdir -p',
        'docker start',
        'docker run'
      ]) {
        expect(guard, lessThan(s.indexOf(change)), reason: change);
      }
    });

    test('a refusal is one INSTALL_REFUSED line and exit 3', () {
      expect(installRefusedPrefix.trim().allMatches(s), hasLength(1));
      expect(s, contains('exit 3'));
      // German user text with real umlauts — it becomes the error message.
      expect(s, contains('für 64-Bit-Systeme (arm64/amd64)'));
    });

    test('the dpkg question cannot eat the script from stdin', () {
      final asks = s.split('\n').where((l) => l.contains('dpkg --print-'));
      expect(asks, isNotEmpty);
      for (final line in asks) {
        expect(line, contains('</dev/null'), reason: line);
      }
    });
  });

  group('Home Assistant install in bash', () {
    late _Pi pi;
    final script = buildHomeAssistantInstallScript();

    /// A Docker that answers `ps`/`inspect` from the state dir and logs the
    /// rest. [dir] `later` = not installed yet (the `sh` stub brings it in).
    void docker({String dir = 'bin'}) => pi.stub(
        'docker',
        'case "\$1" in\n'
            '  ps) [ -f "${pi.state}/containers" ] && cat "${pi.state}/containers"; exit 0 ;;\n'
            '  inspect) cat "${pi.state}/running" 2>/dev/null; exit 0 ;;\n'
            'esac',
        dir: dir);

    setUp(() {
      pi = _Pi();
      // What the Docker convenience script would need.
      pi.stub('mktemp', 'echo "${pi.state}/setup.sh"', log: false);
      pi.stub('curl', 'for a; do last=\$a; done; : > "\$last"');
      pi.stub('sh', 'mv "${pi.root}/later/docker" "${pi.root}/bin/docker"');
    });
    tearDown(() => pi.dispose());

    for (final arch in ['armhf', 'armel', 'i386']) {
      test('$arch without Docker: refused before Docker is installed',
          () async {
        pi.system(arch, kernel: 'armv7l');
        docker(dir: 'later');
        final r = await pi.run(script);
        _expectRefused(r, 'dieses System ist $arch');
        expect(parseInstallRefusal(r.out), contains('Home Assistant'));
        expect(pi.changes, isEmpty, reason: pi.calls.join('\n'));
        expect(pi.exists('/opt/homeassistant'), isFalse);
      });
    }

    test('armhf userland on a 64-bit kernel is still refused (Docker pulls '
        'for the userland)', () async {
      pi.system('armhf', foreign: ['arm64'], kernel: 'aarch64');
      docker();
      final r = await pi.run(script);
      _expectRefused(r, 'dieses System ist armhf');
      expect(pi.changes, isEmpty, reason: pi.calls.join('\n'));
      expect(pi.exists('/opt/homeassistant'), isFalse);
    });

    test('armhf with an existing container: started as before, not refused',
        () async {
      // An image pulled while 32-bit builds still existed keeps running.
      pi.system('armhf', kernel: 'armv7l');
      docker();
      File('${pi.state}/containers')
          .writeAsStringSync('pihole\nhomeassistant\n');
      File('${pi.state}/running').writeAsStringSync('false\n');
      final r = await pi.run(script);
      expect(r.code, 0, reason: '${r.out}\n${r.err}');
      expect(r.out, isNot(contains(installRefusedPrefix.trim())));
      expect(pi.calls, contains('docker start homeassistant'));
      expect(pi.calls.where((c) => c.startsWith('docker run')), isEmpty);
    });

    for (final arch in ['arm64', 'amd64']) {
      test('$arch with Docker: the container is started', () async {
        pi.system(arch, kernel: arch == 'arm64' ? 'aarch64' : 'x86_64');
        docker();
        final r = await pi.run(script);
        expect(r.code, 0, reason: '${r.out}\n${r.err}');
        expect(r.out, isNot(contains(installRefusedPrefix.trim())));
        final run = pi.calls.singleWhere((c) => c.startsWith('docker run'));
        expect(run, contains('--name homeassistant'));
        expect(run, endsWith(homeAssistantImage));
        expect(pi.exists('/opt/homeassistant/config'), isTrue);
      });
    }

    test('arm64 without Docker: Docker is installed first, then the container',
        () async {
      pi.system('arm64', kernel: 'aarch64');
      docker(dir: 'later');
      final r = await pi.run(script);
      expect(r.code, 0, reason: '${r.out}\n${r.err}');
      final c = pi.calls;
      final get = c.indexWhere(
          (l) => l.startsWith('curl ') && l.contains('get.docker.com'));
      final install = c.indexWhere((l) => l.startsWith('sh '));
      final run = c.indexWhere((l) => l.startsWith('docker run'));
      expect(get, greaterThanOrEqualTo(0), reason: c.join('\n'));
      expect(install, greaterThan(get));
      expect(run, greaterThan(install));
    });

    test('unknown architecture (no dpkg): not refused', () async {
      pi.remove('dpkg');
      docker();
      final r = await pi.run(script);
      expect(r.code, 0, reason: '${r.out}\n${r.err}');
      expect(pi.calls.where((c) => c.startsWith('docker run')), hasLength(1));
    });
  }, skip: _needsBash);

  group('InfluxDB install: architecture guard', () {
    final s = _influxInstall;

    test('asks before the key, the source or any package', () {
      final guard = s.indexOf('dpkg --print-architecture');
      expect(guard, greaterThan(0));
      for (final change in ['apt-get', 'wget', 'keyrings', 'influxdata.list']) {
        expect(guard, lessThan(s.indexOf(change)), reason: change);
      }
      expect(s.indexOf('exit 3'), lessThan(s.indexOf('apt-get')));
    });

    test('a refusal is one INSTALL_REFUSED line and exit 3', () {
      expect(installRefusedPrefix.trim().allMatches(s), hasLength(1));
      expect(s, contains('für 64-Bit-Systeme (arm64/amd64)'));
    });

    test('the dpkg questions cannot eat the script from stdin', () {
      final asks = s.split('\n').where((l) => l.contains('dpkg --print-'));
      expect(asks, isNotEmpty);
      for (final line in asks) {
        expect(line, contains('</dev/null'), reason: line);
      }
    });

    test('the other install scripts carry no guard (they have armhf builds)',
        () {
      for (final svc
          in knownInstallableServices.where((x) => x.id != 'influxdb')) {
        expect(svc.installScript, isNot(contains('INSTALL_REFUSED')),
            reason: svc.id);
      }
    });
  });

  group('InfluxDB install in bash', () {
    late _Pi pi;
    // Like the updater: the marker only after the whole script ran.
    final script = '$_influxInstall\necho INSTALL_OK';

    setUp(() {
      pi = _Pi();
      pi.stub('apt-get', '', drainStdin: true);
      pi.stub('systemctl', '');
      // `wget -q -O <file> <url>` writes the key file.
      pi.stub('wget', ': > "\$3"');
      pi.stub(
          'gpg',
          'case "\$1" in\n'
              '  --show-keys) echo "fpr:::::::::24C975CBA61A024EE1B631787C3D57159FC2F927:" ;;\n'
              '  --dearmor) cat ;;\n'
              'esac',
          log: false);
    });
    tearDown(() => pi.dispose());

    void expectNothingWritten() {
      expect(pi.changes, isEmpty, reason: pi.calls.join('\n'));
      expect(pi.exists('/etc/apt/keyrings'), isFalse);
      expect(pi.exists('/etc/apt/sources.list.d/influxdata.list'), isFalse);
      expect(pi.exists('/tmp/influxdata-archive.key'), isFalse);
    }

    void expectInstalled(({int code, String out, String err}) r) {
      expect(r.code, 0, reason: '${r.out}\n${r.err}\n${pi.calls.join('\n')}');
      expect(_lines(r.out).last, 'INSTALL_OK');
      expect(r.out, isNot(contains(installRefusedPrefix.trim())));
      expect(pi.calls.where((c) => c.startsWith('apt-get ')).last,
          endsWith('install -y influxdb2'));
      expect(pi.calls.last, 'systemctl enable --now influxdb');
      expect(pi.exists('/etc/apt/sources.list.d/influxdata.list'), isTrue);
      expect(pi.exists('/etc/apt/keyrings/influxdata-archive.gpg'), isTrue);
    }

    test('32-bit system on a 32-bit kernel: refused, nothing written',
        () async {
      // Pi Zero/1/2, or a Pi 3 with the stock 32-bit kernel.
      pi.system('armhf', kernel: 'armv7l');
      final r = await pi.run(script);
      _expectRefused(r, 'dieses System ist armhf');
      expect(parseInstallRefusal(r.out), contains('InfluxDB 2'));
      expectNothingWritten();
    });

    test('32-bit kernel refuses even when arm64 is a foreign architecture',
        () async {
      // apt would install influxdb2:arm64 — a binary this kernel cannot run.
      pi.system('armhf', foreign: ['arm64'], kernel: 'armv7l');
      _expectRefused(await pi.run(script), 'dieses System ist armhf');
      expectNothingWritten();
    });

    test('32-bit system without a 64-bit foreign architecture: refused',
        () async {
      // E.g. Raspberry Pi OS Bullseye (32-bit) on a Pi 4: 64-bit kernel, but
      // apt knows no arm64 — "Unable to locate package influxdb2".
      pi.system('armhf', kernel: 'aarch64');
      _expectRefused(await pi.run(script), 'dieses System ist armhf');
      expectNothingWritten();
    });

    test('32-bit Raspberry Pi OS with arm64 as foreign architecture on a '
        '64-bit kernel: installs as before', () async {
      // Bookworm and later register arm64 on the 32-bit images, so apt takes
      // influxdb2:arm64 and the static binary runs on the 64-bit kernel.
      pi.system('armhf', foreign: ['arm64'], kernel: 'aarch64');
      expectInstalled(await pi.run(script));
    });

    for (final (arch, foreign, kernel) in [
      ('arm64', ['armhf'], 'aarch64'), // 64-bit Raspberry Pi OS
      ('arm64', <String>[], 'aarch64'),
      ('amd64', <String>[], 'x86_64'),
    ]) {
      test('$arch (foreign: ${foreign.join(',')}) on $kernel: installs',
          () async {
        pi.system(arch, foreign: foreign, kernel: kernel);
        expectInstalled(await pi.run(script));
      });
    }

    test('i386 with amd64 as foreign architecture on a 64-bit kernel: installs',
        () async {
      pi.system('i386', foreign: ['amd64'], kernel: 'x86_64');
      expectInstalled(await pi.run(script));
    });

    test('a system InfluxData has no build for (riscv64): refused', () async {
      pi.system('riscv64', kernel: 'riscv64');
      _expectRefused(await pi.run(script), 'dieses System ist riscv64');
      expectNothingWritten();
    });
  }, skip: _needsBash);
}
