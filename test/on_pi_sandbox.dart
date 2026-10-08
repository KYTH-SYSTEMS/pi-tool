import 'dart:convert';
import 'dart:io';

// A sandboxed "Pi" for the tests that run the on-Pi timer wrappers (health
// alerts, automatic updates, scheduled backups) in a REAL bash. Shared by
// alerts_test, auto_update_test, scheduled_backup_test and on_pi_wrapper_test;
// test/backup_scripts_test.dart carries a private sandbox of the same design.

/// The bash for the sandbox groups. On Windows `bash` may be the WSL launcher,
/// so they only run with an explicit Git Bash
/// (PITOOL_TEST_BASH=C:\Program Files\Git\bin\bash.exe).
final String? sandboxBash =
    Platform.isWindows ? Platform.environment['PITOOL_TEST_BASH'] : 'bash';

/// Skip reason for a real-bash group, or false when a bash is at hand.
final Object needsBash =
    sandboxBash == null ? 'needs bash (PITOOL_TEST_BASH on Windows)' : false;

/// An absolute `dash`, or null where there is none. dash is the `/bin/sh` of
/// a Pi; under Git Bash `/bin/sh` is a bash, which lets bashisms in a
/// `#!/bin/sh` wrapper pass unnoticed.
final String? sandboxDash = () {
  if (sandboxBash == null) return null;
  final r = Process.runSync(sandboxBash!, ['-c', 'command -v dash']);
  final path = (r.stdout as String).trim();
  return r.exitCode == 0 && path.startsWith('/') ? path : null;
}();

/// Skip reason for a test that runs a wrapper under dash, or false.
final Object needsDash = sandboxDash == null ? 'needs dash' : false;

/// `date '+%Y-%m-%d %H:%M:%S'` as written at the start of the status lines.
const String statusTime = r'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d';

/// The plain tools the wrappers may use; each gets a pass-through wrapper.
final List<String> _realTools = 'awk basename cat chmod cut date dirname grep '
        'gzip head ls md5sum mkdir mktemp mv rm sed sort stat tail tar touch '
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
    final r = Process.runSync(sandboxBash!, [
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

class SandboxRun {
  SandboxRun(this.code, this.out, this.err);
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

/// A throwaway "Pi". PATH holds ONLY `bin/`: pass-through wrappers for the
/// plain tools (tar, ls, date, …) and whatever a test stubs (systemctl,
/// apt-get, curl, …) — nothing else on the host can be reached, and a command
/// the Pi would not have is simply missing. Absolute Pi paths (/etc, /var,
/// /usr, /root, /home, /sys, /proc) are rebased into the sandbox; /dev/null
/// stays real.
class PiSandbox {
  PiSandbox() : _dir = Directory.systemTemp.createTempSync('pitool-sb') {
    final host = _Host.instance;
    root = '${host.temp}/${_dir.path.replaceAll(r'\', '/').split('/').last}';
    // The sandbox's own directories, then the ones every Pi has.
    for (final d in '/bin /state /tmp /etc/systemd/system /usr/local/lib '
            '/var/lib/apt/lists /var/lib/systemd/timers /var/backups'
        .split(' ')) {
      Directory(_host(d)).createSync(recursive: true);
    }
    host.tools.forEach((name, real) => File(_host('/bin/$name'))
        .writeAsStringSync('#!/bin/sh\nexec "$real" "\$@"\n'));
    // Waiting loops must not slow the tests down.
    stub('sleep', 'exit 0');
  }

  final Directory _dir;

  /// The sandbox as the scripts see it.
  late final String root;

  /// [abs] (a Pi path like `/etc/evcc.yaml`) as dart:io reaches it.
  String _host(String abs) => '${_dir.path}$abs';

  /// Writes the executable stub [name]; each call is logged as `name args`.
  /// `$S` is the state directory, `$R` the sandbox root and `$REAL_<TOOL>` a
  /// plain tool behind its pass-through (`$REAL_CHMOD`). [shell] is the
  /// stub's interpreter (`sh`, or `bash` where the body needs it).
  void stub(String name, String body, {bool log = true, String shell = 'sh'}) {
    final reals = _Host.instance.tools.entries
        .map((e) => "REAL_${e.key.toUpperCase()}='${e.value}'\n")
        .join();
    File(_host('/bin/$name')).writeAsStringSync('#!/bin/$shell\n'
        "S='$root/state'\n"
        "R='$root'\n"
        '$reals'
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

  void remove(String abs) {
    final f = File(_host(abs));
    if (f.existsSync()) f.deleteSync();
  }

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

  /// Every logged stub call so far, oldest first.
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
  /// The stub directory becomes PATH from INSIDE the shell: Git Bash's
  /// launcher puts its own directories in front of an inherited PATH.
  Future<SandboxRun> run(String script, {bool rebase = true}) async {
    final p = await Process.start(sandboxBash!, ['-s']);
    final out = p.stdout.transform(utf8.decoder).join();
    final err = p.stderr.transform(utf8.decoder).join();
    p.stdin.add(utf8.encode("chmod +x '$root'/bin/*\n"
        "export PATH='$root/bin' TMPDIR='$root/tmp'\n"
        '${rebase ? this.rebase(script) : script}\n'));
    await p.stdin.close();
    return SandboxRun(await p.exitCode, await out, await err);
  }

  /// Sets the mtime of [abs] to [when] in `date -d` wording ("2 days ago").
  Future<void> setAge(String abs, String when) async {
    final r = await run("touch -d '$when' '$root$abs'", rebase: false);
    if (r.code != 0) throw StateError('touch -d: ${r.err}');
  }

  /// Seconds since the mtime of [abs], measured in the sandbox's shell.
  Future<int> ageSeconds(String abs) async {
    final r = await run(
        'echo \$(( \$(date +%s) - \$(stat -c %Y \'$root$abs\') ))',
        rebase: false);
    return int.parse(r.out.trim());
  }

  /// Permission bits of [abs] as `stat -c %a` prints them ("600"). Only
  /// meaningful on a real POSIX file system — not under Git Bash on Windows.
  Future<String> mode(String abs) async =>
      (await run("stat -c %a '$root$abs'", rebase: false)).out.trim();

  void dispose() => _dir.deleteSync(recursive: true);
}

/// The body of the heredoc that [installScript] opens with `<<'[tag]'` for
/// the [n]-th time (0-based) — what lands in the file on the Pi.
String heredocBody(String installScript, String tag, [int n = 0]) {
  final open = "<<'$tag'\n";
  var start = -1;
  for (var i = 0; i <= n; i++) {
    start = installScript.indexOf(open, start + 1);
    if (start < 0) throw StateError("no heredoc <<'$tag' #$n");
  }
  start += open.length;
  return installScript.substring(start, installScript.indexOf('\n$tag\n', start));
}
