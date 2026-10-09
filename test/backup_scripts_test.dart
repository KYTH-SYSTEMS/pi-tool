import 'dart:convert';
import 'dart:io';

import 'package:evcc_updater/src/alerts.dart';
import 'package:evcc_updater/src/auto_update.dart';
import 'package:evcc_updater/src/commands.dart';
import 'package:evcc_updater/src/scheduled_backup.dart';
import 'package:evcc_updater/src/services/homeassistant_service.dart';
import 'package:evcc_updater/src/services/pihole_service.dart';
import 'package:flutter_test/flutter_test.dart';

// The on-Pi backup / restore / alert scripts in a REAL bash against a sandboxed
// "Pi": what they leave on disk and report is checked, not which substrings the
// builders contain. Linux (CI) and Git Bash on Windows.

/// The bash for these groups. On Windows `bash` may be the WSL launcher, so
/// they only run with an explicit Git Bash
/// (PITOOL_TEST_BASH=C:\Program Files\Git\bin\bash.exe).
final String? _bash =
    Platform.isWindows ? Platform.environment['PITOOL_TEST_BASH'] : 'bash';

/// Skip reason for the real-bash groups, or false when a bash is at hand.
final Object _needsBash =
    _bash == null ? 'needs bash (PITOOL_TEST_BASH on Windows)' : false;

/// `date '+%Y-%m-%d %H:%M:%S'` as written at the start of the status lines.
const String _ts = r'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d';

/// The plain tools the scripts may use; each gets a pass-through wrapper.
final List<String> _realTools = 'awk base64 basename cat chmod chown cp cut date '
        'dirname grep gzip head ls md5sum mkdir mktemp mv rm sed sort tail tar '
        'tr xargs'
    .split(' ');

/// What the host offers, asked once per test run: the temp directory as bash
/// names it and where the real tools live.
class _Host {
  _Host._(this.temp, this.tools);

  /// `/tmp` in Git Bash — its tar would read a drive letter (`C:/…`) as a
  /// remote host, so the scripts only ever see this form.
  final String temp;
  final Map<String, String> tools;

  static final _Host instance = () {
    final r = Process.runSync(_bash!, [
      '-c',
      'cd "\$0" && pwd || exit 1\n'
          'for t in ${_realTools.join(' ')}; do\n'
          '  command -v "\$t" || { echo "missing tool: \$t" >&2; exit 1; }\n'
          'done',
      Directory.systemTemp.path,
    ]);
    if (r.exitCode != 0) throw StateError('sandbox probe: ${r.stderr}');
    final lines = (r.stdout as String).trim().split('\n');
    return _Host._(lines.first.trim(), {
      for (var i = 0; i < _realTools.length; i++)
        _realTools[i]: lines[i + 1].trim(),
    });
  }();
}

class _Run {
  _Run(this.code, this.out, this.err);
  final int code;
  final String out;
  final String err;

  /// Non-empty stdout lines, trimmed.
  List<String> get lines => out
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
}

/// A throwaway "Pi" for running a real script in a real bash. PATH holds ONLY
/// `bin/`: pass-through wrappers for the plain tools (tar, ls, date, …) and
/// whatever a test stubs (systemctl, pihole, curl, docker, …) — nothing else on
/// the host can be reached, and a command the Pi would not have is simply
/// missing. Absolute Pi paths (/etc, /var, /usr, /root, /home, /sys, /proc) are
/// rebased into the sandbox; /dev/null stays real.
class _Pi {
  _Pi() : _dir = Directory.systemTemp.createTempSync('pitool-bk') {
    final host = _Host.instance;
    root = '${host.temp}/${_dir.path.replaceAll(r'\', '/').split('/').last}';
    realTar = host.tools['tar']!;
    // The sandbox's own directories, then the ones every Pi has.
    for (final d in '/bin /state /tmp /etc/systemd/system /usr/local/lib '
            '/var/lib /var/backups /root /home'
        .split(' ')) {
      Directory(_host(d)).createSync(recursive: true);
    }
    host.tools.forEach((name, real) => File(_host('/bin/$name'))
        .writeAsStringSync('#!/bin/sh\nexec "$real" "\$@"\n'));
    File(_host('/bin/sleep')).writeAsStringSync('#!/bin/sh\nexit 0\n');
  }

  final Directory _dir;

  /// The sandbox as the scripts see it.
  late final String root;
  late final String realTar;

  /// [abs] (a Pi path like `/etc/evcc.yaml`) as dart:io reaches it.
  String _host(String abs) => '${_dir.path}$abs';

  /// Writes the executable stub [name]; each call is logged as `name args`.
  /// `$S` is the state directory, `$REAL_TAR` the real tar.
  void stub(String name, String body, {bool log = true}) {
    File(_host('/bin/$name')).writeAsStringSync('#!/bin/sh\n'
        "S='$root/state'\n"
        "REAL_TAR='$realTar'\n"
        '${log ? 'echo "$name \$*" >> "\$S/calls"\n' : ''}'
        '$body\n');
  }

  void put(String abs, [String content = 'x']) => File(_host(abs))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);

  bool exists(String abs) =>
      FileSystemEntity.typeSync(_host(abs), followLinks: false) !=
      FileSystemEntityType.notFound;

  String read(String abs) => File(_host(abs)).readAsStringSync();

  /// File names in [absDir], sorted; empty when the directory is missing.
  List<String> ls(String absDir) {
    final d = Directory(_host(absDir));
    if (!d.existsSync()) return const [];
    return d
        .listSync()
        .map((e) => e.path.replaceAll(r'\', '/').split('/').last)
        .toList()
      ..sort();
  }

  List<String> get calls {
    final f = File(_host('/state/calls'));
    return f.existsSync()
        ? f.readAsLinesSync().where((l) => l.isNotEmpty).toList()
        : const [];
  }

  void clearCalls() {
    final f = File(_host('/state/calls'));
    if (f.existsSync()) f.deleteSync();
  }

  /// [script] with its absolute Pi paths pointed into the sandbox.
  String rebase(String script) => script.replaceAllMapped(
      RegExp(r'(?<![\w.$-])/(etc|var|usr|root|home|sys|proc)/'),
      (m) => '$root${m[0]}');

  /// Feeds [script] to `bash -s` on stdin, exactly like the app's root shell.
  Future<_Run> run(String script, {bool rebase = true}) async {
    final p = await Process.start(_bash!, ['-s']);
    final out = p.stdout.transform(utf8.decoder).join();
    final err = p.stderr.transform(utf8.decoder).join();
    p.stdin.add(utf8.encode("chmod +x '$root'/bin/*\n"
        "export PATH='$root/bin' TMPDIR='$root/tmp'\n"
        '${rebase ? this.rebase(script) : script}\n'));
    await p.stdin.close();
    return _Run(await p.exitCode, await out, await err);
  }

  /// Member names of the archive [abs] (read with the real tar), without the
  /// sandbox prefix: `var/lib/evcc/evcc.db`.
  Future<List<String>> members(String abs) async {
    final r = await run("'$realTar' -tzf '$root$abs'", rebase: false);
    expect(r.code, 0, reason: r.err);
    final prefix = '${root.substring(1)}/';
    return [
      for (final l in r.lines)
        l.startsWith(prefix) ? l.substring(prefix.length) : l
    ];
  }

  /// Creates [abs] as an OLD file: its mtime is [day] January 2001, so a
  /// higher day is newer in `ls -t` and anything a script writes is newest.
  void putAged(String abs, int day) {
    put(abs);
    File(_host(abs)).setLastModifiedSync(DateTime(2001, 1, day));
  }

  void dispose() => _dir.deleteSync(recursive: true);
}

/// tar that leaves a partial file behind and fails like a full disk (exit 2).
const String _tarFails = r'''
prev=
for a in "$@"; do
  [ "$prev" = -czf ] && echo partial > "$a"
  prev=$a
done
exit 2''';

/// tar that writes the archive but reports "file changed as we read it".
const String _tarWarns = r'''
"$REAL_TAR" "$@" || exit $?
exit 1''';

/// Pi-hole v6 CLI: no `-a` any more — an unknown argument prints the help and
/// exits 0, writing nothing.
const String _piholeV6 = r'''
echo "Usage: pihole [options]"
exit 0''';

/// Pi-hole v6 FTL: the teleporter export lands as a zip in the working dir.
const String _ftlV6 = r'''
[ "$1" = --teleporter ] || exit 1
echo ZIP > "pi-hole_pi_teleporter_2026-10-08_03-00-00_UTC.zip"''';

/// Pi-hole v5 CLI: `-a -t` writes a tar.gz into the working dir.
const String _piholeV5 = r'''
[ "$1 $2" = "-a -t" ] || exit 1
echo TGZ > "pi-hole-pi-teleporter_2026-10-08_03-00-00.tar.gz"''';

void main() {
  group('scheduled backup wrapper in bash', () {
    late _Pi pi;
    const wrapper = '/usr/local/lib/$scheduledBackupUnit.sh';
    const dir = '/var/backups/pi-tool';
    const status = '/var/lib/pi-tool/backup.status';

    setUp(() async {
      pi = _Pi();
      pi.stub('systemctl', 'exit 0');
      final r = await pi.run(buildScheduledBackupInstallScript(
          onCalendar: '*-*-* 03:00:00', keep: 2));
      expect(r.code, 0, reason: r.err);
      expect(r.lines.last, 'BACKUP_TIMER_INSTALLED');
      pi.clearCalls();
    });
    tearDown(() => pi.dispose());

    /// Runs the installed wrapper (its own shebang) and returns the status.
    Future<String> runWrapper() async {
      final r = await pi.run("'${pi.root}$wrapper'", rebase: false);
      expect(r.code, 0, reason: r.err);
      return pi.read(status).trim();
    }

    List<String> archives(String service) =>
        pi.ls(dir).where((n) => n.startsWith('sched-$service-')).toList();

    test('no /etc/evcc.yaml (evcc set up in the web UI): the state is archived',
        () async {
      pi.put('/var/lib/evcc/evcc.db', 'DB');
      final st = await runWrapper();
      expect(archives('evcc'), hasLength(1));
      expect(archives('evcc').single, endsWith('.tar.gz'));
      expect(await pi.members('$dir/${archives('evcc').single}'),
          contains('var/lib/evcc/evcc.db'));
      expect(st, matches(RegExp('^$_ts ok: evcc\$')));
    });

    test('only /etc/evcc.yaml, no state dir: the config is archived', () async {
      pi.put('/etc/evcc.yaml', 'site: x');
      final st = await runWrapper();
      expect(archives('evcc'), hasLength(1));
      expect(await pi.members('$dir/${archives('evcc').single}'),
          ['etc/evcc.yaml']);
      expect(st, matches(RegExp('^$_ts ok: evcc\$')));
    });

    test('tar exit 2: no archive, no .part, the status names the failure',
        () async {
      pi.put('/etc/evcc.yaml');
      pi.put('/var/lib/evcc/evcc.db');
      pi.put('$dir/sched-evcc-20260101-030000.tar.gz', 'GOOD');
      pi.stub('tar', _tarFails);
      final st = await runWrapper();
      // The earlier good backup is all there is — nothing new, nothing rotated.
      expect(pi.ls(dir), ['sched-evcc-20260101-030000.tar.gz']);
      expect(pi.read('$dir/sched-evcc-20260101-030000.tar.gz'), 'GOOD');
      expect(st, matches(RegExp('^$_ts fehler: evcc\\(tar-rc=2\\)\$')));
      expect(st, isNot(contains('ok')));
    });

    test('tar exit 1 (file changed as we read it): the archive counts',
        () async {
      pi.put('/etc/evcc.yaml');
      pi.put('/var/lib/evcc/evcc.db');
      pi.stub('tar', _tarWarns);
      final st = await runWrapper();
      expect(archives('evcc'), hasLength(1));
      expect(archives('evcc').single, endsWith('.tar.gz'));
      expect(
          await pi.members('$dir/${archives('evcc').single}'),
          containsAll(['etc/evcc.yaml', 'var/lib/evcc/evcc.db']));
      expect(st, matches(RegExp('^$_ts ok: evcc\$')));
    });

    test('nothing installed: nothing written, the status says so', () async {
      final st = await runWrapper();
      expect(pi.ls(dir), isEmpty);
      expect(st, matches(RegExp('^$_ts ok: nichts\$')));
    });

    test('rotation keeps the newest `keep` archives', () async {
      pi.put('/etc/evcc.yaml');
      for (var d = 1; d <= 3; d++) {
        pi.putAged('$dir/sched-evcc-2026010$d-030000.tar.gz', d);
      }
      await runWrapper();
      final left = archives('evcc');
      expect(left, hasLength(2)); // keep: 2 → the new one + the newest old one
      expect(left, contains('sched-evcc-20260103-030000.tar.gz'));
    });

    test('Pi-hole v6 (`pihole -a -t` = help, exit 0): the FTL zip is kept',
        () async {
      pi.stub('pihole', _piholeV6);
      pi.stub('pihole-FTL', _ftlV6);
      final st = await runWrapper();
      expect(archives('pihole'), hasLength(1));
      expect(archives('pihole').single, endsWith('.zip'));
      expect(pi.read('$dir/${archives('pihole').single}').trim(), 'ZIP');
      expect(st, matches(RegExp('^$_ts ok: pihole\$')));
    });

    test('Pi-hole v5: the tar.gz of `pihole -a -t` is kept, FTL is not asked',
        () async {
      pi.stub('pihole', _piholeV5);
      pi.stub('pihole-FTL', 'exit 1');
      final st = await runWrapper();
      expect(archives('pihole'), hasLength(1));
      expect(archives('pihole').single, endsWith('.tar.gz'));
      expect(pi.read('$dir/${archives('pihole').single}').trim(), 'TGZ');
      expect(pi.calls, ['pihole -a -t']);
      expect(st, matches(RegExp('^$_ts ok: pihole\$')));
    });

    test('Pi-hole present but no archive: the status says so, evcc still ok',
        () async {
      pi.put('/etc/evcc.yaml');
      pi.stub('pihole', _piholeV6);
      pi.stub('pihole-FTL', 'exit 1');
      final st = await runWrapper();
      expect(archives('pihole'), isEmpty);
      expect(archives('evcc'), hasLength(1));
      expect(
          st,
          matches(
              RegExp('^$_ts fehler: pihole\\(kein-archiv\\); ok: evcc\$')));
    });
  }, skip: _needsBash);

  group('auto-update wrapper in bash (backup before the upgrade)', () {
    late _Pi pi;
    const wrapper = '/usr/local/lib/$autoUpdateUnit.sh';
    const dir = '/var/backups/pi-tool';
    const status = '/var/lib/pi-tool/autoupdate.status';

    setUp(() async {
      pi = _Pi();
      pi.stub('systemctl', r'[ "$1" = is-active ] && echo active; exit 0');
      pi.stub('dpkg-query', 'exit 0');
      pi.stub('apt-get', 'exit 0');
      final r = await pi
          .run(buildAutoUpdateInstallScript(onCalendar: '*-*-* 04:00:00'));
      expect(r.code, 0, reason: r.err);
      expect(r.lines.last, 'AUTOUPDATE_INSTALLED');
      pi.clearCalls();
    });
    tearDown(() => pi.dispose());

    Future<String> runWrapper() async {
      final r = await pi.run("'${pi.root}$wrapper'", rebase: false);
      expect(r.code, 0, reason: r.err);
      return pi.read(status).trim();
    }

    List<String> archives() =>
        pi.ls(dir).where((n) => n.startsWith('autoupdate-evcc-')).toList();

    bool upgraded() => pi.calls.any((c) => c.contains('full-upgrade'));

    test('no /etc/evcc.yaml: the state is still archived before the upgrade',
        () async {
      pi.put('/var/lib/evcc/evcc.db', 'DB');
      final st = await runWrapper();
      expect(archives(), hasLength(1));
      expect(archives().single, endsWith('.tar.gz'));
      expect(await pi.members('$dir/${archives().single}'),
          contains('var/lib/evcc/evcc.db'));
      expect(upgraded(), isTrue);
      expect(st, matches(RegExp('^$_ts ok\$')));
    });

    test('tar exit 2: no archive, no .part, the status names the lost backup',
        () async {
      pi.put('/etc/evcc.yaml');
      pi.put('/var/lib/evcc/evcc.db');
      pi.stub('tar', _tarFails);
      final st = await runWrapper();
      expect(archives(), isEmpty);
      expect(upgraded(), isTrue);
      expect(st, matches(RegExp('^$_ts ok; backup-fehler\\(rc=2\\)\$')));
    });

    test('tar exit 1 (file changed as we read it): the archive counts',
        () async {
      pi.put('/etc/evcc.yaml');
      pi.put('/var/lib/evcc/evcc.db');
      pi.stub('tar', _tarWarns);
      final st = await runWrapper();
      expect(archives(), hasLength(1));
      expect(archives().single, endsWith('.tar.gz'));
      expect(st, matches(RegExp('^$_ts ok\$')));
    });
  }, skip: _needsBash);

  group('buildPiholeBackupScript in bash', () {
    late _Pi pi;
    const dir = '/var/backups/pi-tool';

    setUp(() => pi = _Pi());
    tearDown(() => pi.dispose());

    test('Pi-hole v6 (`pihole -a -t` = help, exit 0): the FTL zip is saved',
        () async {
      pi.stub('pihole', _piholeV6);
      pi.stub('pihole-FTL', _ftlV6);
      final r = await pi.run(buildPiholeBackupScript());
      expect(r.code, 0, reason: '${r.out}${r.err}');
      final saved = pi.ls(dir).single;
      expect(saved, matches(RegExp(r'^pihole-backup-\d{8}-\d{6}\.zip$')));
      expect(r.lines.last, 'BACKUP_OK ${pi.root}$dir/$saved');
      expect(pi.read('$dir/$saved').trim(), 'ZIP');
    });

    test('Pi-hole v5: the tar.gz is saved, FTL is not asked', () async {
      pi.stub('pihole', _piholeV5);
      pi.stub('pihole-FTL', 'exit 1');
      final r = await pi.run(buildPiholeBackupScript());
      expect(r.code, 0, reason: '${r.out}${r.err}');
      final saved = pi.ls(dir).single;
      expect(saved, matches(RegExp(r'^pihole-backup-\d{8}-\d{6}\.tar\.gz$')));
      expect(r.lines.last, 'BACKUP_OK ${pi.root}$dir/$saved');
      expect(pi.calls, ['pihole -a -t']);
    });

    test('no archive from either CLI: BACKUP_FAIL, exit 1', () async {
      pi.stub('pihole', _piholeV6);
      pi.stub('pihole-FTL', 'exit 1');
      final r = await pi.run(buildPiholeBackupScript());
      expect(r.code, 1);
      expect(r.lines, ['BACKUP_FAIL']);
      expect(pi.ls(dir), isEmpty);
    });
  }, skip: _needsBash);

  group('buildBackupScript in bash', () {
    late _Pi pi;
    const dir = '/var/backups/evcc';

    setUp(() => pi = _Pi());
    tearDown(() => pi.dispose());

    /// Runs the backup; returns the archive (Pi path) from the OK marker.
    Future<String> backup() async {
      final r = await pi.run(buildBackupScript());
      expect(r.code, 0, reason: '${r.out}${r.err}');
      final ok = r.lines.last;
      expect(ok, startsWith('EVCC_BACKUP_OK ${pi.root}$dir/evcc-backup-'));
      return ok.substring('EVCC_BACKUP_OK ${pi.root}'.length);
    }

    test('legacy /root database next to the live one: the live one is '
        'archived, with its -wal and -shm', () async {
      pi.put('/root/.evcc/evcc.db', 'LEGACY');
      pi.put('/var/lib/evcc/evcc.db', 'LIVE');
      pi.put('/var/lib/evcc/evcc.db-wal', 'WAL');
      pi.put('/var/lib/evcc/evcc.db-shm', 'SHM');
      final m = await pi.members(await backup());
      expect(
          m,
          unorderedEquals([
            'var/lib/evcc/evcc.db',
            'var/lib/evcc/evcc.db-wal',
            'var/lib/evcc/evcc.db-shm',
          ]));
    });

    test('only the legacy /root database: that one is archived', () async {
      pi.put('/etc/evcc.yaml', 'site: x\n');
      pi.put('/root/.evcc/evcc.db', 'LEGACY');
      final m = await pi.members(await backup());
      expect(m, unorderedEquals(['etc/evcc.yaml', 'root/.evcc/evcc.db']));
    });

    test('without a service database, /root comes before a home directory',
        () async {
      // An old install that still runs as root keeps its data in /root; a
      // database in a home directory is then the leftover of a manual run.
      pi.put('/home/pi/.evcc/evcc.db', 'HOME');
      pi.put('/root/.evcc/evcc.db', 'ROOT');
      expect(await pi.members(await backup()), ['root/.evcc/evcc.db']);
    });

    test('only a database in a home directory: that one is archived',
        () async {
      pi.put('/home/pi/.evcc/evcc.db', 'HOME');
      expect(await pi.members(await backup()), ['home/pi/.evcc/evcc.db']);
    });

    test('a rollback journal next to the database is archived with it',
        () async {
      pi.put('/var/lib/evcc/evcc.db', 'LIVE');
      pi.put('/var/lib/evcc/evcc.db-journal', 'JOURNAL');
      final m = await pi.members(await backup());
      expect(
          m,
          unorderedEquals(
              ['var/lib/evcc/evcc.db', 'var/lib/evcc/evcc.db-journal']));
    });

    for (final (label, line) in [
      ('double-quoted with a trailing comment', 'dsn: "@DB@"  # meine DB'),
      ('single-quoted', "dsn: '@DB@'"),
      ('plain with a trailing comment', 'dsn: @DB@ # meine DB'),
      ('plain, CRLF line ends', 'dsn: @DB@\r'),
    ]) {
      test('dsn $label, path with a space: that database is archived',
          () async {
        const db = '/mnt/usb stick/evcc.db';
        pi.put(db, 'CUSTOM');
        pi.put('$db-wal', 'WAL');
        pi.put('/var/lib/evcc/evcc.db', 'DEFAULT');
        pi.put(
            '/etc/evcc.yaml',
            'database:\n  type: sqlite\n'
                '  ${line.replaceAll('@DB@', '${pi.root}$db')}\n');
        final m = await pi.members(await backup());
        expect(
            m,
            unorderedEquals([
              'etc/evcc.yaml',
              'mnt/usb stick/evcc.db',
              'mnt/usb stick/evcc.db-wal',
            ]));
      });
    }

    test('a dsn that points at no file falls back to the default location',
        () async {
      pi.put('/etc/evcc.yaml', 'database:\n  dsn: /nowhere/evcc.db\n');
      pi.put('/var/lib/evcc/evcc.db', 'LIVE');
      final m = await pi.members(await backup());
      expect(m, unorderedEquals(['etc/evcc.yaml', 'var/lib/evcc/evcc.db']));
    });

    test('a dsn that names no file is mentioned, but never printed',
        () async {
      // A MySQL/Postgres dsn carries credentials; the log is shared in bug
      // reports.
      pi.put('/etc/evcc.yaml',
          'database:\n  dsn: evcc:geheim123@tcp(db:3306)/evcc\n');
      pi.put('/var/lib/evcc/evcc.db', 'LIVE');
      final r = await pi.run(buildBackupScript());
      expect(r.code, 0, reason: '${r.out}${r.err}');
      expect(r.out, contains('Hinweis:'));
      expect('${r.out}${r.err}', isNot(contains('geheim123')));
    });

    test('tar exit 2: EVCC_BACKUP_FAIL, and no half archive is left to restore',
        () async {
      pi.put('/etc/evcc.yaml');
      pi.put('/var/lib/evcc/evcc.db');
      pi.stub('tar', _tarFails);
      final r = await pi.run(buildBackupScript());
      expect(r.code, 1);
      expect(r.lines.last, 'EVCC_BACKUP_FAIL');
      expect(r.out, isNot(contains('EVCC_BACKUP_OK')));
      expect(pi.ls(dir), isEmpty);
    });

    test('tar exit 1 (file changed as we read it): the archive counts',
        () async {
      pi.put('/var/lib/evcc/evcc.db');
      pi.stub('tar', _tarWarns);
      final archive = await backup();
      expect(pi.ls(dir), [archive.split('/').last]);
      expect(await pi.members(archive), ['var/lib/evcc/evcc.db']);
    });

    test('nothing to back up: EVCC_BACKUP_EMPTY, exit 0, no archive', () async {
      final r = await pi.run(buildBackupScript());
      expect(r.code, 0, reason: r.err);
      expect(r.lines, ['EVCC_BACKUP_EMPTY']);
      expect(pi.ls(dir), isEmpty);
    });

    test('keeps the 10 newest evcc-backup archives, whatever their names',
        () async {
      pi.put('/etc/evcc.yaml');
      // Day 1 and 2 are the oldest: a name with a space, and a foreign file.
      pi.putAged('$dir/evcc-backup-2025 kopie.tar.gz', 1);
      pi.putAged('$dir/umzug.tar.gz', 2);
      // The temp file of a run that was killed half-way goes as well.
      pi.putAged('$dir/evcc-backup-20250101-000000.tar.gz.part', 3);
      String old(int d) => 'evcc-backup-202601$d-000000.tar.gz';
      for (var d = 11; d <= 22; d++) {
        pi.putAged('$dir/${old(d)}', d);
      }
      final created = (await backup()).split('/').last;
      expect(
          pi.ls(dir),
          unorderedEquals([
            created,
            for (var d = 14; d <= 22; d++) old(d),
            'umzug.tar.gz', // not ours: never rotated
          ]));
    });
  }, skip: _needsBash);

  group('buildRestoreScript in bash', () {
    late _Pi pi;
    const archive = '/var/backups/evcc/evcc-backup-20260630-120000.tar.gz';

    setUp(() {
      pi = _Pi();
      pi.stub('systemctl', r'''
case "$1" in
  stop) echo inactive > "$S/evcc" ;;
  start) echo active > "$S/evcc" ;;
esac
exit 0''');
      pi.put('/state/evcc', 'active\n');
    });
    tearDown(() => pi.dispose());

    /// Packs [files] (member name → content) into [archive] the way the
    /// backup stores them: without the leading `/`.
    Future<void> pack(Map<String, String> files) async {
      for (final e in files.entries) {
        pi.put('/src/${e.key}', e.value);
      }
      final names = files.keys.map((k) => "'$k'").join(' ');
      final r = await pi.run(
          "mkdir -p '${pi.root}/var/backups/evcc' && cd '${pi.root}/src' && "
          "'${pi.realTar}' -czf '${pi.root}$archive' $names",
          rebase: false);
      expect(r.code, 0, reason: r.err);
    }

    /// The restore with `/` as the extraction target pointed at the sandbox —
    /// and a hard stop if that rewrite ever stops matching the script.
    Future<_Run> restore() {
      final script = pi
          .rebase(buildRestoreScript(archive))
          .replaceAll(' -C /\n', ' -C ${pi.root}/\n')
          .replaceAll(r'"/$m$s"', '"${pi.root}/\$m\$s"');
      expect(script, contains(' -C ${pi.root}/\n'));
      expect(script, contains('"${pi.root}/\$m\$s"'));
      expect(script, isNot(contains(' -C /\n')));
      return pi.run(script, rebase: false);
    }

    String evcc() => pi.read('/state/evcc').trim();

    test('truncated archive: refused before evcc is stopped, nothing changed',
        () async {
      await pack({'etc/evcc.yaml': 'ARCHIVE', 'var/lib/evcc/evcc.db': 'ADB'});
      final f = File(pi._host(archive));
      final bytes = f.readAsBytesSync();
      f.writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
      pi.put('/etc/evcc.yaml', 'LIVE');
      pi.put('/var/lib/evcc/evcc.db', 'LIVEDB');
      final r = await restore();
      expect(r.code, isNot(0));
      expect(r.out, isNot(contains('RESTORE_OK')));
      expect(pi.calls, isNot(contains('systemctl stop evcc')));
      expect(evcc(), 'active');
      expect(pi.read('/etc/evcc.yaml'), 'LIVE');
      expect(pi.read('/var/lib/evcc/evcc.db'), 'LIVEDB');
    });

    test('extraction fails after the stop: evcc is started again, no marker',
        () async {
      await pack({'etc/evcc.yaml': 'ARCHIVE'});
      // Listing works, extracting fails (full disk).
      pi.stub('tar', r'''
case " $* " in *" -xzf "*) exit 2 ;; esac
exec "$REAL_TAR" "$@"''');
      final r = await restore();
      expect(r.code, isNot(0));
      expect(r.out, isNot(contains('RESTORE_OK')));
      final svc = pi.calls.where((c) => c.startsWith('systemctl ')).toList();
      expect(svc.first, 'systemctl stop evcc');
      expect(svc.last, 'systemctl start evcc');
      expect(evcc(), 'active');
    });

    test('happy path: files restored, stale -wal/-shm of the live database '
        'removed, evcc started once, marker last', () async {
      await pack({'etc/evcc.yaml': 'ARCHIVE', 'var/lib/evcc/evcc.db': 'ADB'});
      pi.put('/etc/evcc.yaml', 'LIVE');
      pi.put('/var/lib/evcc/evcc.db', 'LIVEDB');
      pi.put('/var/lib/evcc/evcc.db-wal', 'LIVEWAL');
      pi.put('/var/lib/evcc/evcc.db-shm', 'LIVESHM');
      pi.put('/var/lib/evcc/evcc.db-journal', 'LIVEJOURNAL');
      pi.put('/var/lib/evcc/other.db-wal', 'OTHER'); // not in the archive
      final r = await restore();
      expect(r.code, 0, reason: '${r.out}${r.err}');
      expect(r.lines.last, 'RESTORE_OK');
      expect(pi.read('/etc/evcc.yaml'), 'ARCHIVE');
      expect(pi.read('/var/lib/evcc/evcc.db'), 'ADB');
      expect(pi.exists('/var/lib/evcc/evcc.db-wal'), isFalse);
      expect(pi.exists('/var/lib/evcc/evcc.db-shm'), isFalse);
      expect(pi.exists('/var/lib/evcc/evcc.db-journal'), isFalse);
      expect(pi.read('/var/lib/evcc/other.db-wal'), 'OTHER');
      expect(pi.calls.where((c) => c.startsWith('systemctl ')),
          ['systemctl stop evcc', 'systemctl start evcc']);
      expect(evcc(), 'active');
    });

    test('an archive with its own -wal: that one is restored, the live -shm '
        'it does not carry is removed', () async {
      await pack({
        'var/lib/evcc/evcc.db': 'ADB',
        'var/lib/evcc/evcc.db-wal': 'AWAL',
      });
      pi.put('/var/lib/evcc/evcc.db', 'LIVEDB');
      pi.put('/var/lib/evcc/evcc.db-wal', 'LIVEWAL');
      pi.put('/var/lib/evcc/evcc.db-shm', 'LIVESHM');
      final r = await restore();
      expect(r.code, 0, reason: '${r.out}${r.err}');
      expect(r.lines.last, 'RESTORE_OK');
      expect(pi.read('/var/lib/evcc/evcc.db'), 'ADB');
      expect(pi.read('/var/lib/evcc/evcc.db-wal'), 'AWAL');
      expect(pi.exists('/var/lib/evcc/evcc.db-shm'), isFalse);
    });

    test('missing archive: refused, evcc untouched', () async {
      final r = await restore();
      expect(r.code, 1);
      expect(r.out, isNot(contains('RESTORE_OK')));
      expect(pi.calls, isEmpty);
    });
  }, skip: _needsBash);

  group('backup list commands in bash', () {
    late _Pi pi;
    const evccDir = '/var/backups/evcc';
    const dir = '/var/backups/pi-tool';

    setUp(() {
      pi = _Pi();
      // The commands run under `sh -c`, and PATH holds only the sandbox's bin.
      pi.stub('sh', r'exec /bin/sh "$@"', log: false);
    });
    tearDown(() => pi.dispose());

    /// Runs [command] and returns the paths [parse] reads from its output, as
    /// the Pi names them.
    Future<List<String>> list(
        String command, List<String> Function(String) parse) async {
      final r = await pi.run(command);
      return [for (final p in parse(r.out)) p.replaceFirst(pi.root, '')];
    }

    /// Files in the shared directory that are no evcc archive.
    void putOthers() {
      pi.putAged('$dir/sched-evcc-20260109-030000.tar.gz.part', 9);
      pi.putAged('$dir/sched-pihole-20260109-030000.zip', 9);
      pi.putAged('$dir/pihole-backup-20260109-120000.zip', 9);
      pi.putAged('$dir/homeassistant-backup-20260109-120000.tar.gz', 9);
      pi.putAged('$dir/config-evcc.yaml-20260109-120000.bak', 9);
    }

    test('evcc: the app\'s backups and both timers\' archives, newest first',
        () async {
      pi.putAged('$evccDir/evcc-backup-20260105-120000.tar.gz', 5);
      pi.putAged('$dir/autoupdate-evcc-20260106-040000.tar.gz', 6);
      pi.putAged('$dir/sched-evcc-20260107-030000.tar.gz', 7);
      pi.putAged('$evccDir/evcc-backup-20260108-120000.tar.gz', 8);
      putOthers();
      expect(await list(listBackupsCommand, parseBackupList), [
        '$evccDir/evcc-backup-20260108-120000.tar.gz',
        '$dir/sched-evcc-20260107-030000.tar.gz',
        '$dir/autoupdate-evcc-20260106-040000.tar.gz',
        '$evccDir/evcc-backup-20260105-120000.tar.gz',
      ]);
    });

    test('evcc: no timer archives (two patterns without a match): the app\'s '
        'backups are still listed', () async {
      pi.putAged('$evccDir/evcc-backup-20260105-120000.tar.gz', 5);
      pi.putAged('$evccDir/evcc-backup-20260108-120000.tar.gz', 8);
      putOthers();
      expect(await list(listBackupsCommand, parseBackupList), [
        '$evccDir/evcc-backup-20260108-120000.tar.gz',
        '$evccDir/evcc-backup-20260105-120000.tar.gz',
      ]);
    });

    test('evcc: only an archive of the update timer: it is listed', () async {
      pi.putAged('$dir/autoupdate-evcc-20260106-040000.tar.gz', 6);
      putOthers();
      expect(await list(listBackupsCommand, parseBackupList),
          ['$dir/autoupdate-evcc-20260106-040000.tar.gz']);
    });

    test('evcc: no archive at all: an empty list', () async {
      putOthers();
      expect(await list(listBackupsCommand, parseBackupList), isEmpty);
    });

    test('Pi-hole: on-demand and timer archives, newest first, nothing of '
        'another service', () async {
      pi.putAged('$dir/pihole-backup-20260103-120000.zip', 3);
      pi.putAged('$dir/sched-pihole-20260104-030000.tar.gz', 4);
      pi.putAged('$dir/sched-pihole-20260105-030000.zip', 5);
      pi.putAged('$dir/sched-evcc-20260109-030000.tar.gz', 9);
      pi.putAged('$dir/autoupdate-evcc-20260109-040000.tar.gz', 9);
      pi.putAged('$dir/homeassistant-backup-20260109-120000.tar.gz', 9);
      expect(
          await list(serviceBackupListCommand('pihole'), parseServiceBackupList),
          [
            '$dir/sched-pihole-20260105-030000.zip',
            '$dir/sched-pihole-20260104-030000.tar.gz',
            '$dir/pihole-backup-20260103-120000.zip',
          ]);
    });

    test('Home Assistant (the timer writes none): its on-demand archives',
        () async {
      pi.putAged('$dir/homeassistant-backup-20260103-120000.tar.gz', 3);
      pi.putAged('$dir/sched-pihole-20260109-030000.zip', 9);
      pi.putAged('$dir/sched-evcc-20260109-030000.tar.gz', 9);
      expect(
          await list(serviceBackupListCommand('homeassistant'),
              parseServiceBackupList),
          ['$dir/homeassistant-backup-20260103-120000.tar.gz']);
    });

    test('a prefix with a quote stays part of one word: nothing else runs',
        () async {
      pi.putAged('$dir/pihole-backup-20260103-120000.zip', 3);
      // TMPDIR is the sandbox's /tmp in every shell of this run.
      final r = await pi.run(serviceBackupListCommand(
          "x'; echo yes > \"\$TMPDIR/injected\"; echo '"));
      expect(pi.exists('/tmp/injected'), isFalse);
      expect(r.out, isNot(contains('pihole-backup')));
    });
  }, skip: _needsBash);

  // The archives the on-Pi timers write are offered for restore next to the
  // app's own. These run the installed wrapper and then the restore on the
  // archive it wrote — the layout the restore expects is the one they produce.
  group('timer archives restore like the app\'s own, in bash', () {
    late _Pi pi;
    const dir = '/var/backups/pi-tool';
    final sched = buildScheduledBackupInstallScript(
        onCalendar: '*-*-* 03:00:00', keep: 7);

    setUp(() {
      pi = _Pi();
      pi.stub('systemctl', r'''
case "$1" in
  is-active) cat "$S/evcc" ;;
  stop) echo inactive > "$S/evcc" ;;
  start) echo active > "$S/evcc" ;;
esac
exit 0''');
      pi.put('/state/evcc', 'active\n');
      pi.stub('dpkg-query', 'exit 0');
      pi.stub('apt-get', 'exit 0');
    });
    tearDown(() => pi.dispose());

    /// Installs a timer with [install], runs the wrapper of [unit] and returns
    /// the one archive named [prefix]… it left behind (Pi path).
    Future<String> archiveOf(String install, String unit, String prefix) async {
      final i = await pi.run(install);
      expect(i.code, 0, reason: i.err);
      final w =
          await pi.run("'${pi.root}/usr/local/lib/$unit.sh'", rebase: false);
      expect(w.code, 0, reason: w.err);
      return '$dir/${pi.ls(dir).singleWhere((n) => n.startsWith(prefix))}';
    }

    for (final (timer, install, unit, prefix) in [
      ('backup timer', sched, scheduledBackupUnit, 'sched-evcc-'),
      (
        'update timer',
        buildAutoUpdateInstallScript(onCalendar: '*-*-* 04:00:00'),
        autoUpdateUnit,
        'autoupdate-evcc-',
      ),
    ]) {
      test('evcc archive of the $timer: config and database come back, a '
          'stale -wal of the live database goes', () async {
        pi.put('/etc/evcc.yaml', 'ARCHIVED');
        pi.put('/var/lib/evcc/evcc.db', 'ADB');
        final archive = await archiveOf(install, unit, prefix);
        // The name is one the app runs the evcc restore on.
        expect(isEvccRestorePath(archive), isTrue, reason: archive);
        // The sandboxed wrapper archived sandbox paths, so every member name
        // starts with the sandbox: extracting at `/` below stays inside it.
        final raw = await pi.run("'${pi.realTar}' -tzf '${pi.root}$archive'",
            rebase: false);
        expect(raw.code, 0, reason: raw.err);
        expect(raw.lines, isNotEmpty);
        expect(raw.lines, everyElement(startsWith('${pi.root.substring(1)}/')));
        expect(await pi.members(archive),
            containsAll(['etc/evcc.yaml', 'var/lib/evcc/evcc.db']));

        pi.put('/etc/evcc.yaml', 'LIVE');
        pi.put('/var/lib/evcc/evcc.db', 'LIVEDB');
        pi.put('/var/lib/evcc/evcc.db-wal', 'LIVEWAL');
        pi.clearCalls();
        final r = await pi.run(buildRestoreScript(archive));
        expect(r.code, 0, reason: '${r.out}${r.err}');
        expect(r.lines.last, 'RESTORE_OK');
        expect(pi.read('/etc/evcc.yaml'), 'ARCHIVED');
        expect(pi.read('/var/lib/evcc/evcc.db'), 'ADB');
        expect(pi.exists('/var/lib/evcc/evcc.db-wal'), isFalse);
        expect(pi.calls.where((c) => c.startsWith('systemctl ')),
            ['systemctl stop evcc', 'systemctl start evcc']);
        expect(pi.read('/state/evcc').trim(), 'active');
      });
    }

    test('Pi-hole archive of the backup timer: the Teleporter zip the restore '
        'imports', () async {
      pi.stub('pihole', _piholeV6);
      // v6 FTL: without a file an export into the working dir, with one the
      // import of that file.
      pi.stub('pihole-FTL', r'''
[ "$1" = --teleporter ] || exit 1
if [ -n "$2" ]; then cat "$2" > "$S/imported"; exit 0; fi
echo ZIP > "pi-hole_pi_teleporter_2026-10-08_03-00-00_UTC.zip"''');
      final archive =
          await archiveOf(sched, scheduledBackupUnit, 'sched-pihole-');
      expect(archive, endsWith('.zip'));
      pi.clearCalls();
      final r = await pi.run(buildPiholeRestoreScript(archive));
      expect(r.code, 0, reason: '${r.out}${r.err}');
      expect(r.lines.last, 'RESTORE_OK');
      expect(pi.read('/state/imported').trim(), 'ZIP');
      expect(pi.calls, [
        'pihole-FTL --teleporter ${pi.root}$archive',
        'pihole reloaddns',
      ]);
    });
  }, skip: _needsBash);

  group('buildHomeAssistantRestoreScript in bash', () {
    late _Pi pi;

    setUp(() => pi = _Pi());
    tearDown(() => pi.dispose());

    Future<_Run> restore() async {
      final r = await pi.run(
          "mkdir -p '${pi.root}/src' '${pi.root}/opt/config' && "
          "cd '${pi.root}/src' && echo NEW > configuration.yaml && "
          "'${pi.realTar}' -czf '${pi.root}/ha.tar.gz' configuration.yaml",
          rebase: false);
      expect(r.code, 0, reason: r.err);
      return pi.run(
          buildHomeAssistantRestoreScript(
            archivePath: '${pi.root}/ha.tar.gz',
            configPath: '${pi.root}/opt/config',
            containerName: 'homeassistant',
          ),
          rebase: false);
    }

    test('`docker stop` dies (channel closed on cancel): Home Assistant is '
        'started again', () async {
      // The container is stopped, then the CLI dies writing its name (SIGPIPE).
      pi.stub('docker', r'[ "$1" = stop ] && exit 141; exit 0');
      final r = await restore();
      expect(r.code, isNot(0));
      expect(r.out, isNot(contains('RESTORE_OK')));
      expect(pi.calls,
          ['docker stop homeassistant', 'docker start homeassistant']);
    });

    test('happy path: stop, extract, start, verify, marker last', () async {
      pi.stub('docker', r'''[ "$1" = inspect ] && echo 'running|0'; exit 0''');
      final r = await restore();
      expect(r.code, 0, reason: '${r.out}${r.err}');
      expect(r.lines.last, 'RESTORE_OK');
      expect(pi.read('/opt/config/configuration.yaml').trim(), 'NEW');
      expect(pi.calls.take(2),
          ['docker stop homeassistant', 'docker start homeassistant']);
      expect(pi.calls.where((c) => c.startsWith('docker start')),
          hasLength(1));
    });
  }, skip: _needsBash);

  group('health-alerts wrapper in bash', () {
    late _Pi pi;
    const wrapper = '/usr/local/lib/$alertsUnit.sh';
    const last = '/var/lib/pi-tool/alerts.last';

    Future<void> install() async {
      final r = await pi.run(buildAlertsInstallScript(
          ntfyServer: 'https://ntfy.example', ntfyTopic: 'pi-tool-test'));
      expect(r.code, 0, reason: r.err);
      expect(r.lines.last, 'ALERTS_INSTALLED');
      pi.clearCalls();
    }

    setUp(() async {
      pi = _Pi();
      // No service is enabled, the disk is 95 % full: exactly one problem.
      pi.stub('systemctl',
          r'case "$1" in is-enabled|is-active) exit 1 ;; esac; exit 0',
          log: false);
      pi.stub('journalctl', 'exit 0', log: false);
      pi.stub('apt-get', 'exit 0', log: false);
      pi.stub('df', r'''
echo "Filesystem 1K-blocks Used Available Use% Mounted on"
echo "/dev/root 100 95 5 95% /"''', log: false);
      pi.stub('curl', r'''
cat >/dev/null
[ -e "$S/curl-fails" ] && exit 6
if [ -e "$S/http-error" ]; then
  # Like curl: an HTTP error only fails the call with -f/--fail.
  for a in "$@"; do
    case "$a" in --fail|-f*|-[!-]*f*) exit 22 ;; esac
  done
fi
exit 0''');
      await install();
    });
    tearDown(() => pi.dispose());

    Future<void> runWrapper() async {
      final r = await pi.run("'${pi.root}$wrapper'", rebase: false);
      expect(r.code, 0, reason: r.err);
    }

    List<String> pushes() =>
        pi.calls.where((c) => c.startsWith('curl ')).toList();

    test('a failed push is not remembered: alerts.last stays, the next run '
        'tries again', () async {
      pi.put(last, 'OLD');
      pi.put('/state/curl-fails', '');
      await runWrapper();
      expect(pi.read(last), 'OLD');
      await runWrapper();
      expect(pushes(), hasLength(2));
      expect(pi.read(last), 'OLD');
    });

    test('an HTTP error from the ntfy server counts as a failed push',
        () async {
      pi.put(last, 'OLD');
      pi.put('/state/http-error', '');
      await runWrapper();
      expect(pushes(), hasLength(1));
      expect(pi.read(last), 'OLD');
    });

    test('a delivered push is remembered and not sent a second time',
        () async {
      await runWrapper();
      expect(pi.read(last), matches(RegExp(r'^[0-9a-f]{32}$')));
      await runWrapper();
      expect(pushes(), hasLength(1));
      expect(pushes().single, contains('https://ntfy.example/pi-tool-test'));
      // Bounded: the oneshot unit has no start timeout of its own.
      expect(pushes().single, contains('--max-time'));
    });

    test('installing again (new topic) forgets the last sent state', () async {
      await runWrapper();
      expect(pi.read(last), isNotEmpty);
      await install(); // also empties the call log
      expect(pi.exists(last), isFalse);
      await runWrapper();
      expect(pushes(), hasLength(1)); // the same problem goes out again
    });
  }, skip: _needsBash);

  group('timer remove scripts in bash', () {
    late _Pi pi;

    setUp(() {
      pi = _Pi();
      pi.stub('systemctl', 'exit 0');
    });
    tearDown(() => pi.dispose());

    final timers = [
      (
        unit: autoUpdateUnit,
        install: buildAutoUpdateInstallScript(onCalendar: '*-*-* 04:00:00'),
        remove: buildAutoUpdateRemoveScript(),
        marker: 'AUTOUPDATE_REMOVED',
      ),
      (
        unit: scheduledBackupUnit,
        install: buildScheduledBackupInstallScript(
            onCalendar: '*-*-* 03:00:00', keep: 7),
        remove: buildScheduledBackupRemoveScript(),
        marker: 'BACKUP_TIMER_REMOVED',
      ),
      (
        unit: alertsUnit,
        install: buildAlertsInstallScript(
            ntfyServer: 'https://ntfy.example', ntfyTopic: 'pi-tool-test'),
        remove: buildAlertsRemoveScript(),
        marker: 'ALERTS_REMOVED',
      ),
    ];

    for (final t in timers) {
      List<String> files() => [
            '/etc/systemd/system/${t.unit}.timer',
            '/etc/systemd/system/${t.unit}.service',
            '/usr/local/lib/${t.unit}.sh',
          ];

      test('${t.unit}: removes timer, service and wrapper, marker last',
          () async {
        expect((await pi.run(t.install)).code, 0);
        expect(files().every(pi.exists), isTrue);
        final r = await pi.run(t.remove);
        expect(r.code, 0, reason: r.err);
        expect(r.lines.last, t.marker);
        expect(files().any(pi.exists), isFalse);
      });

      test('${t.unit}: a failing rm (read-only root) ends without the marker',
          () async {
        expect((await pi.run(t.install)).code, 0);
        pi.stub('rm', 'exit 1');
        final r = await pi.run(t.remove);
        expect(r.code, isNot(0));
        expect(r.out, isNot(contains(t.marker)));
        expect(files().every(pi.exists), isTrue);
      });
    }
  }, skip: _needsBash);

  group('buildConfigWriteScript in bash (backup rotation)', () {
    late _Pi pi;
    const dir = '/var/backups/pi-tool';

    setUp(() => pi = _Pi());
    tearDown(() => pi.dispose());

    Future<void> write(String path, String content) async {
      final r = await pi.run(buildConfigWriteScript(
          path: path, base64Content: base64Encode(utf8.encode(content))));
      expect(r.code, 0, reason: '${r.out}${r.err}');
      expect(r.lines.last, 'CONFIG_SAVED');
      expect(pi.read(path), content);
    }

    test('a file name with a space: the 5 newest backups stay', () async {
      const path = '/etc/my notes.conf';
      pi.put(path, 'old');
      String bak(int d) => 'config-my notes.conf-202601$d-000000.bak';
      for (var d = 11; d <= 17; d++) {
        pi.putAged('$dir/${bak(d)}', d);
      }
      await write(path, 'new');
      final left = pi.ls(dir);
      expect(left, hasLength(5));
      expect(left, containsAll([for (var d = 14; d <= 17; d++) bak(d)]));
    });

    test('backups of evcc.yaml-old are not counted (or deleted) as evcc.yaml',
        () async {
      const path = '/etc/evcc.yaml';
      pi.put(path, 'old');
      String other(int d) => 'config-evcc.yaml-old-202601$d-000000.bak';
      String own(int d) => 'config-evcc.yaml-202601$d-000000.bak';
      for (var d = 11; d <= 15; d++) {
        pi.putAged('$dir/${other(d)}', d);
      }
      for (var d = 21; d <= 23; d++) {
        pi.putAged('$dir/${own(d)}', d);
      }
      await write(path, 'new');
      final left = pi.ls(dir);
      // 3 old + the new one of evcc.yaml, and all 5 of the other file.
      expect(left, hasLength(9));
      expect(left, containsAll([for (var d = 11; d <= 15; d++) other(d)]));
    });
  }, skip: _needsBash);

  // Where no bash is at hand the groups above are skipped. These pin the order
  // of the steps they prove, so a regression still shows up there.
  group('script shape (no bash needed)', () {
    final sched = buildScheduledBackupInstallScript(
        onCalendar: '*-*-* 03:00:00', keep: 7);
    final auto = buildAutoUpdateInstallScript(onCalendar: '*-*-* 04:00:00');
    final alerts = buildAlertsInstallScript(
        ntfyServer: 'https://ntfy.sh', ntfyTopic: 'pi-tool-test');

    /// Asserts that [steps] all occur in [script], in this order.
    void expectOrder(String script, List<String> steps) {
      var at = -1;
      for (final step in steps) {
        final i = script.indexOf(step, at + 1);
        expect(i, greaterThan(at), reason: 'missing or out of order: $step');
        at = i;
      }
    }

    test('timer wrappers hand tar only the evcc paths that exist', () {
      for (final s in [sched, auto]) {
        expect(s,
            contains(r'[ -f /etc/evcc.yaml ] && set -- "$@" /etc/evcc.yaml'));
        expect(
            s, contains(r'[ -d /var/lib/evcc ] && set -- "$@" /var/lib/evcc'));
        expect(s, isNot(contains('/etc/evcc.yaml /var/lib/evcc')));
      }
    });

    test('Pi-hole backups do not pick the CLI generation by exit code', () {
      for (final s in [buildPiholeBackupScript(), sched]) {
        // Both calls on one line = the old `a || b` chain.
        expect(RegExp(r'pihole -a -t[^\n]*pihole-FTL').hasMatch(s), isFalse);
        expectOrder(s, ['pihole -a -t', 'ls *.tar.gz', 'pihole-FTL --teleporter']);
      }
    });

    test('evcc backup: the service database is probed before the legacy one, '
        'the archive is written as .part first', () {
      final s = buildBackupScript();
      expectOrder(s, [
        'for c in /var/lib/evcc/evcc.db',
        '/root/.evcc/evcc.db',
        '/home/*/.evcc/evcc.db; do',
        r'tar -czf "$out.part" --warning=no-file-changed -- "$@"',
        r'mv -f "$out.part" "$out"',
        'EVCC_BACKUP_OK',
      ]);
    });

    test('evcc restore: archive check, trap, stop, extract, start, marker', () {
      final s = buildRestoreScript('/var/backups/evcc/evcc-backup-x.tar.gz');
      expectOrder(s, [
        "-tzf '/var/backups/evcc/evcc-backup-x.tar.gz'",
        "trap 'systemctl start evcc",
        'systemctl stop evcc',
        "tar -xzf '/var/backups/evcc/evcc-backup-x.tar.gz' -C /",
        'trap - EXIT',
        'systemctl start evcc\n',
        'echo RESTORE_OK',
      ]);
      expect(s.trimRight(), endsWith('echo RESTORE_OK'));
    });

    test('Home Assistant restore arms the trap before the stop', () {
      final s = buildHomeAssistantRestoreScript(
          archivePath: '/a.tar.gz', configPath: '/c', containerName: 'ha');
      expectOrder(s, [
        "trap \"docker start 'ha'",
        "docker stop 'ha'",
        'tar -xzf',
        'trap - EXIT',
        "docker start 'ha'\n",
        'echo "RESTORE_OK"',
      ]);
    });

    test('alerts: the hash is written inside the push-succeeded branch, and '
        'installing resets it', () {
      expectOrder(alerts, [
        'rm -f /var/lib/pi-tool/alerts.last',
        "<<'WRAP'",
        'if printf ',
        'curl -fsS --connect-timeout 10 --max-time 30 ',
        '; then\n',
        r'''printf '%s' "$hash" > /var/lib/pi-tool/alerts.last''',
        '  fi\n',
      ]);
    });

    test('the three remove scripts run under set -e and end with the marker',
        () {
      for (final (s, marker) in [
        (buildAutoUpdateRemoveScript(), 'AUTOUPDATE_REMOVED'),
        (buildScheduledBackupRemoveScript(), 'BACKUP_TIMER_REMOVED'),
        (buildAlertsRemoveScript(), 'ALERTS_REMOVED'),
      ]) {
        expect(s.trimLeft(), startsWith('set -e\n'));
        expect(s.trimRight(), endsWith('echo $marker'));
      }
    });

    test('the status parsers hand a failure line on unchanged', () {
      const backup = '2026-10-08 03:00:01 fehler: evcc(tar-rc=2); ok: pihole';
      expect(
          parseScheduledBackupStatus('ENABLED enabled\nNEXT \nSTATUS $backup\n')
              .lastResult,
          backup);
      const update = '2026-10-08 04:00:12 ok; backup-fehler(rc=2)';
      expect(
          parseAutoUpdateStatus('ENABLED enabled\nNEXT \nSTATUS $update\n')
              .lastResult,
          update);
    });
  });
}
