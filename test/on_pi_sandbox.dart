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

  // ---- for running a builder on values it must not trust -------------------

  /// Exit status of [runGuarded] when the sandbox does not hold, and of a
  /// [confine]d tool asked to touch something outside of it.
  static const int leakExit = 113;

  /// The commands [runGuarded] looks up before the script starts: the ones
  /// that download, install or run something when they are the host's own.
  static const List<String> guarded = [
    'curl', 'wget', 'apt-get', 'apt', 'dpkg', 'docker', 'sudo', 'systemctl',
    'sh', 'bash',
  ];

  /// Absolute directories [rebase] leaves alone. A script that names one of
  /// them is not run by [runGuarded] (`#!/bin/sh` is no such name).
  static final RegExp _notRebased = RegExp(
      r'''(?<![\w.$!-])/(?:tmp|opt|run|boot|srv|mnt|media|snap|bin|sbin|lib)/[^\s"']*''');

  /// A redirection into an absolute path.
  static final RegExp _redirect = RegExp(r'''>[|&]?\s*["']?(/[^\s"';|&)]*)''');

  /// Like [run], with the sandbox checked first:
  /// - the shell looks up every command of [guarded] before the first line of
  ///   [script]; one that resolves outside `bin/` ends it with [leakExit];
  /// - a script that names a directory [rebase] does not move, or redirects
  ///   into an absolute path outside the sandbox (other than /dev/null), is
  ///   not started at all ([StateError]).
  ///
  /// [script] may name the sandbox itself ([root]): such a path is not
  /// rebased a second time. The working directory is the sandbox, so a
  /// relative path lands there too.
  Future<SandboxRun> runGuarded(String script, {bool rebase = true}) {
    const mark = '__PITOOL_SANDBOX__';
    final masked = script.replaceAll(root, mark);
    final text = rebase ? this.rebase(masked).replaceAll(root, mark) : masked;
    final outside = [
      for (final m in _notRebased.allMatches(text)) m[0]!,
      for (final m in _redirect.allMatches(text))
        if (m[1] != '/dev/null') '> ${m[1]}',
    ];
    if (outside.isNotEmpty) {
      throw StateError('the script leaves the sandbox: ${outside.join(', ')}');
    }
    return run('$guard${text.replaceAll(mark, root)}', rebase: false);
  }

  /// The lines [runGuarded] puts in front of a script: into the sandbox, then
  /// every command of [guarded] looked up with the PATH the script will run
  /// with — [leakExit] at the first one that is the host's own.
  String get guard => "cd '$root' || exit $leakExit\n"
      'for pitool_t in ${guarded.join(' ')}; do\n'
      '  pitool_p=\$(command -v "\$pitool_t") || continue\n'
      '  case "\$pitool_p" in\n'
      "    '$root/bin/'*) ;;\n"
      '    *) echo "sandbox leak: \$pitool_t is \$pitool_p" >&2; '
      'exit $leakExit ;;\n'
      '  esac\n'
      'done\n'
      'unset pitool_t pitool_p\n';

  static final Map<String, String> _resolved = {};

  /// The host's own [tool] as an absolute path in bash's spelling.
  String real(String tool) =>
      _Host.instance.tools[tool] ??
      _resolved.putIfAbsent(tool, () {
        final r =
            Process.runSync(sandboxBash!, ['-c', r'command -v "$0"', tool]);
        final path = (r.stdout as String).trim();
        if (r.exitCode != 0 || !path.startsWith('/')) {
          throw StateError('missing tool: $tool');
        }
        return path;
      });

  /// Pass-through wrappers for further plain tools of the host (base64, cp,
  /// readlink, …), next to the standard set.
  void allow(Iterable<String> tools) {
    for (final t in tools) {
      File(_host('/bin/$t'))
          .writeAsStringSync('#!/bin/sh\nexec "${real(t)}" "\$@"\n');
    }
  }

  /// Replaces the wrappers of [tools] by ones that refuse an operand outside
  /// the sandbox: exit [leakExit] and a line in [leaks]. For tools whose
  /// operands are all paths (rm, mv, cp, mkdir, touch) — against a path a
  /// script computes while it runs, which [rebase] cannot reach.
  void confine(Iterable<String> tools) {
    for (final t in tools) {
      File(_host('/bin/$t')).writeAsStringSync('#!/bin/sh\n'
          "R='$root'\n"
          'paths_only=0\n'
          'for a in "\$@"; do\n'
          '  if [ "\$paths_only" = 0 ]; then\n'
          '    case "\$a" in --) paths_only=1; continue ;; -*) continue ;; esac\n'
          '  fi\n'
          '  case "\$a" in /*) p=\$a ;; *) p=\$PWD/\$a ;; esac\n'
          '  case "\$p/" in\n'
          '    */../*) ;;\n'
          '    "\$R"/*) continue ;;\n'
          '  esac\n'
          '  echo "sandbox leak: $t \$a" >&2\n'
          '  echo "$t \$a" >> "\$R/state/leak"\n'
          '  exit $leakExit\n'
          'done\n'
          'exec "${real(t)}" "\$@"\n');
    }
  }

  /// What the [confine]d tools refused so far, one `tool operand` line each.
  List<String> get leaks {
    final f = File(_host('/state/leak'));
    return f.existsSync() ? f.readAsLinesSync() : const [];
  }

  /// A stub that notes each call for [recorded] — its arguments byte for
  /// byte, a line break or an empty one included — and then runs [then]
  /// (exit 0 without).
  void record(String name, [String then = '']) => stub(
      name,
      // The next free number is claimed by creating its file: with noclobber
      // that fails for a file another call already has. `$n` is the call's
      // number, for [then].
      'n=0\n'
          'set -C\n'
          'until { true > "\$S/call.\$n"; } 2>/dev/null; do\n'
          '  n=\$((n + 1))\n'
          '  [ "\$n" -lt 10000 ] || exit $leakExit\n'
          'done\n'
          'set +C\n'
          '{\n'
          "  printf '%s\\000' '$name'\n"
          '  for a in "\$@"; do printf \'%s\\000\' "\$a"; done\n'
          '} >> "\$S/call.\$n"\n'
          '$then',
      log: false);

  /// Every call of a [record]ed stub so far, oldest first: the stub's name,
  /// then its arguments.
  List<List<String>> get recorded {
    final calls = <List<String>>[];
    for (var n = 0;; n++) {
      final f = File(_host('/state/call.$n'));
      if (!f.existsSync()) return calls;
      calls.add(utf8.decode(f.readAsBytesSync()).split('\x00')..removeLast());
    }
  }

  /// The names of all entries anywhere in the sandbox that start with
  /// [prefix] — what a canary command left behind, wherever it ran.
  List<String> named(String prefix) => _dir
      .listSync(recursive: true, followLinks: false)
      .map((e) => e.path.replaceAll(r'\', '/').split('/').last)
      .where((n) => n.startsWith(prefix))
      .toList()
    ..sort();

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
