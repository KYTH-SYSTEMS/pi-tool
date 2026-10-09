@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';

import 'package:evcc_updater/src/alerts.dart';
import 'package:evcc_updater/src/auto_update.dart';
import 'package:evcc_updater/src/commands.dart';
import 'package:evcc_updater/src/docker_containers.dart';
import 'package:evcc_updater/src/evcc_updater.dart';
import 'package:evcc_updater/src/files.dart';
import 'package:evcc_updater/src/pi_job.dart';
import 'package:evcc_updater/src/scheduled_backup.dart';
import 'package:evcc_updater/src/services/apt_services.dart';
import 'package:evcc_updater/src/services/homeassistant_service.dart';
import 'package:evcc_updater/src/services/pi_connect.dart';
import 'package:evcc_updater/src/services/pihole_service.dart';
import 'package:evcc_updater/src/services/tailscale.dart';
import 'package:evcc_updater/src/ssh_keys.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:evcc_updater/src/storage_explorer.dart';
import 'package:evcc_updater/src/systemd_services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'on_pi_sandbox.dart';

// What a value from the user or from the Pi — a path, a container name, a
// topic, a prefix, a schedule — does to the scripts and command lines that
// carry it: run in a REAL bash on a sandboxed Pi (on_pi_sandbox.dart), with
// values that would run a command wherever quoting slips.
//
// Two things are checked for every builder. Nothing of the value runs: each
// hostile value would leave its own `pwned-…` file behind, anywhere in the
// sandbox. And the value arrives as it is: as one argument of the command it
// is meant for (stubs note their arguments byte for byte), or as the name or
// the content of the file that gets written. A builder that refuses such a
// value instead is checked for exactly that.
//
// The sandbox is checked before every run (PiSandbox.runGuarded): curl, wget,
// apt, dpkg, docker, sudo, systemctl, sh and bash resolve to a stub or not at
// all, and rm, mv, cp, mkdir and touch act inside the sandbox only.
//
// The rule that no heredoc opens with an unquoted delimiter is checked over
// every script builder in test/script_syntax_test.dart, which has the table.

/// Values that run a command wherever quoting slips; each would leave its
/// own file behind. The last one carries no command — it has to arrive as it
/// is all the same.
const _hostile = <(String, String)>[
  ('single quote', "a';touch pwned-quote;'b"),
  ('double quote', 'a";touch pwned-dquote;"b'),
  ('command substitution', r'a$(touch pwned-subst)b'),
  ('backticks', 'a`touch pwned-tick`b'),
  ('semicolon', 'a b;touch pwned-semi;#c'),
  ('line break', 'a\ntouch pwned-line\nb'),
  ('umlauts and blanks', 'Müll  Ordner ö'),
];

/// All of them in one value, for the scripts that take seconds per run:
/// whatever the kind of slip, one of its parts fires.
const _allInOne = (
  'all at once',
  "a';touch pwned-quote;'b\";touch pwned-dquote;\"c\$(touch pwned-subst)d"
      '`touch pwned-tick`e\ntouch pwned-line\nf g;touch pwned-semi;#h ö'
);

/// The same for a value a builder strips of all whitespace first (the ntfy
/// destination): `${IFS}` stands in for the blank.
const _allInOneNoBlank = (
  'all at once, no blank',
  r"a';touch${IFS}pwned-quote;'b"
      r'";touch${IFS}pwned-dquote;"c$(touch${IFS}pwned-subst)d'
      r'`touch${IFS}pwned-tick`e;touch${IFS}pwned-semi;#f'
);

/// The values the scripts with many steps are run with.
const _heavy = [_allInOne];

const _id = '0123456789abcdef';

/// `sudo` as far as these tests need it: its options go, the command runs.
const _sudo = r'''
while [ $# -gt 0 ]; do
  case "$1" in
    -p) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
PITOOL_SUDO=1
export PITOOL_SUDO
exec "$@"''';

/// What a recording `stat` does once it has noted its arguments. Asked about
/// a directory on the way to a link (`-L -c '%f %u'`), it answers like a Pi
/// where each one is root's and closed to others: Git Bash knows no owners,
/// and the directories above the sandbox are the host's. Any other question
/// goes to the real stat.
const _stat = r'''
case "$*" in
  "-L -c %f %u -- "*) echo "41ed 0" ;;
  *) exec "$REAL_STAT" "$@" ;;
esac''';

/// Nothing of a value ran, and nothing was touched outside the sandbox.
void _expectDataOnly(PiSandbox pi, String reason) {
  expect(pi.named('pwned-'), isEmpty, reason: reason);
  expect(pi.leaks, isEmpty, reason: reason);
}

/// Runs [commands] one after the other, each the way the SSH exec channel
/// hands a line to the login shell, and returns their exit statuses.
Future<List<int>> _exec(PiSandbox pi, Iterable<String> commands,
    {bool rebase = true}) async {
  final r = await pi.runGuarded(
      [for (final c in commands) '$c\necho "@@status \$?"'].join('\n'),
      rebase: rebase);
  expect(r.code, 0, reason: '${r.out}\n${r.err}');
  return [
    for (final l in r.lines)
      if (l.startsWith('@@status ')) int.parse(l.substring(9)),
  ];
}

/// Runs [doing] with `$p` holding exactly [path]. The name goes through a
/// file, not through quoting of this test's own.
Future<SandboxRun> _withPath(PiSandbox pi, String path, String doing) {
  pi.put('/state/name', path);
  return pi.runGuarded(
      "IFS= read -r -d '' p < '${pi.root}/state/name'\n$doing",
      rebase: false);
}

/// Creates the directory [path] under exactly this name — through the
/// sandbox's shell: dart:io on Windows cannot name what a Pi's file system
/// can (a line break, a double quote).
Future<void> _mkdir(PiSandbox pi, String path) async {
  final r = await _withPath(pi, path, r'mkdir -p -- "$p"');
  expect(r.code, 0, reason: r.err);
}

/// Writes [content] into the file [path], under exactly this name.
Future<void> _write(PiSandbox pi, String path, String content) async {
  pi.put('/state/content', content);
  final r = await _withPath(
      pi,
      path,
      'mkdir -p -- "\${p%/*}"\n'
      "IFS= read -r -d '' c < '${pi.root}/state/content'\n"
      'printf \'%s\' "\$c" > "\$p"');
  expect(r.code, 0, reason: r.err);
}

/// The content of the file [path], or null when there is no such file.
Future<String?> _read(PiSandbox pi, String path) async {
  final r = await _withPath(
      pi,
      path,
      '[ -f "\$p" ] || exit 44\n'
      'IFS= read -r -d \'\' c < "\$p"\n'
      'printf \'%s\' "\$c"');
  return r.code == 44 ? null : r.out;
}

/// Makes [link] a symlink to [target], both under exactly these names, and
/// says whether this host can. MSYS=…: Git Bash copies instead of linking
/// unless it is told to write a link of its own kind; anywhere else the
/// variable means nothing.
Future<bool> _symlink(PiSandbox pi, String target, String link) async {
  pi.put('/state/target', target);
  final r = await _withPath(
      pi,
      link,
      'mkdir -p -- "\${p%/*}"\n'
      "IFS= read -r -d '' t < '${pi.root}/state/target'\n"
      'MSYS=winsymlinks:sysfile ln -s -- "\$t" "\$p" && [ -L "\$p" ]');
  return r.code == 0;
}

/// One command line and the commands that have to get its value.
class _Line {
  const _Line(this.name, this.build, this.takers, {this.whole, this.arrange});

  final String name;
  final String Function(String v) build;

  /// The stubs that are called with the value, in order.
  final List<String> takers;

  /// The arguments of such a call that carry the value [v]: `{v}`, unless the
  /// builder itself adds to it. [root] is the sandbox, for a path it names.
  final Set<String> Function(String v, String root)? whole;
  final void Function(PiSandbox pi)? arrange;
}

final _lines = <_Line>[
  const _Line('dockerInspectJsonCommand', dockerInspectJsonCommand, ['docker']),
  const _Line(
      'dockerInspectJsonSudoCommand', dockerInspectJsonSudoCommand, ['docker']),
  const _Line(
      'buildDockerRestartCommand', buildDockerRestartCommand, ['docker']),
  const _Line('buildDockerLogsCommand', buildDockerLogsCommand, ['docker']),
  const _Line('buildDockerRunningProbe', buildDockerRunningProbe, ['docker']),
  _Line(
      'buildServiceLogsCommand: a container',
      (v) => buildServiceLogsCommand(id: 'evcc', detail: 'Docker · $v').command,
      const ['docker']),
  // Both tries name the container.
  _Line(
      'buildServiceLogsCommand: a container only root may read',
      (v) => buildServiceLogsCommand(id: 'evcc', detail: 'Docker · $v').command,
      const ['docker', 'docker'],
      arrange: (pi) => pi.put('/state/docker-needs-sudo')),
  _Line('buildServiceLogsCommand: a unit',
      (v) => buildServiceLogsCommand(id: v, detail: '').command,
      const ['journalctl']),
  const _Line('serviceBackupDeleteCommand', serviceBackupDeleteCommand, ['rm']),
  // The prefix is part of two patterns; nothing matches them here, so `ls`
  // gets them as they are.
  _Line('serviceBackupListCommand', serviceBackupListCommand, const ['ls'],
      whole: (v, root) => {
            '$root$serviceBackupDir/$v-backup-*',
            '$root$serviceBackupDir/sched-$v-*',
          }),
  const _Line('buildConfigReadCommand', buildConfigReadCommand, ['cat']),
  const _Line('buildListDirCommand', buildListDirCommand, ['find']),
  // The other end of the pipe is the real base64, reading what head gives it.
  _Line('buildReadFileCommand', buildReadFileCommand, const ['head'],
      arrange: (pi) => pi.allow(['base64'])),
  const _Line('buildDownloadFileCommand', buildDownloadFileCommand, ['base64']),
  _Line('buildDeleteCommand: a file',
      (v) => buildDeleteCommand(path: v, isDir: false), const ['rm']),
  _Line('buildDeleteCommand: a directory',
      (v) => buildDeleteCommand(path: v, isDir: true), const ['rm']),
  const _Line('buildStorageProbe', buildStorageProbe, ['du', 'find']),
];

/// A `docker inspect` object with [v] in every field that reaches the
/// reconstructed `docker run` …
Map<String, dynamic> _container(String v) => {
      'Id': 'f00dfeedf00dfeed',
      'Name': '/$v',
      'Config': {
        'Image': 'old $v',
        'Hostname': 'host $v',
        'User': 'user $v',
        'Env': ['A=$v', 'PATH=/usr/bin'],
        'Labels': {'my.$v': v, 'com.docker.compose.project': v},
        'Entrypoint': ['entry $v', 'arg $v'],
        'Cmd': ['cmd $v'],
      },
      'HostConfig': {
        'NetworkMode': 'net $v',
        'RestartPolicy': {'Name': 'on-failure', 'MaximumRetryCount': 3},
        'PortBindings': {
          '80$v/udp': [
            {'HostIp': 'ip$v', 'HostPort': 'p$v'}
          ],
        },
        'Devices': [
          {'PathOnHost': '/dev/$v', 'PathInContainer': '/dev/in $v'}
        ],
        'GroupAdd': ['grp $v'],
        'CapAdd': ['cap $v'],
        'CapDrop': ['drop $v'],
        'LogConfig': {
          'Type': 'log $v',
          'Config': {'max-size': v},
        },
        'Binds': ['/data/$v:/data'],
        'SecurityOpt': ['opt $v'],
        'Tmpfs': {'/cache $v': 'size=$v'},
        'Sysctls': {'net.$v': v},
        'Memory': 268435456,
        'NanoCpus': 1500000000,
        'CpusetCpus': 'cpus $v',
        'CpusetMems': 'mems $v',
        'PidMode': 'container:$v',
        'ExtraHosts': ['extra $v'],
      },
    };

/// … and the arguments of that `docker run` which carry [v], with [image] as
/// the image. Not among them: the image the container was created from, the
/// label of docker compose and PATH — the builder leaves those out.
Set<String> _runWhole(String v, String image) => {
      v, // --name
      'ip$v:p$v:80$v/udp', // -p
      '/dev/$v:/dev/in $v', // --device
      'grp $v', 'cap $v', 'drop $v', 'log $v', 'max-size=$v',
      '/data/$v:/data', // -v
      'A=$v', 'my.$v=$v', 'net $v', 'opt $v',
      '/cache $v:size=$v', // --tmpfs
      'net.$v=$v', 'cpus $v', 'mems $v', 'container:$v', 'user $v',
      'host $v', 'extra $v', 'entry $v', image, 'arg $v', 'cmd $v',
    };

/// The recorded arguments that hold a part of one of the values above (each
/// has `pwned-` or `Müll` in it). Compared with the whole values a builder
/// was given: a part on its own means the value was split or expanded, a
/// missing one that it did not arrive. That leaves the order and the options
/// of a command free to change.
Set<String> _carrying(Iterable<List<String>> calls) => {
      for (final call in calls)
        for (final arg in call.skip(1))
          if (arg.contains('pwned-') || arg.contains('Müll')) arg,
    };

/// docker for the recreate script: the container runs an older image than
/// the tag names, restarts `always`, and after the recreate reports what
/// `state/status` says. `docker run` fails while `state/run-fails` exists.
const _dockerRecreate = r'''
case "$1 $2" in
  "container inspect") echo sha256:old ;;
  "image inspect") echo sha256:new ;;
  "inspect -f")
    case "$3" in
      *RestartPolicy*) echo always:0 ;;
      *State.Status*) "$REAL_CAT" "$S/status" ;;
    esac ;;
  "run -d") [ ! -e "$S/run-fails" ] || exit 125 ;;
esac
exit 0''';

/// An [SshRunner] that notes the commands it is asked to run.
class _Recorder implements SshRunner {
  final commands = <String>[];

  @override
  Future<void> connect() async {}

  @override
  Future<CommandResult> run(String command,
      {String? stdin, void Function(String chunk)? onOutput}) async {
    commands.add(command);
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  Future<void> close() async {}
}

void main() {
  late PiSandbox pi;

  setUp(() {
    if (sandboxBash == null) return;
    pi = PiSandbox();
    pi.confine(['rm', 'rmdir', 'mv', 'cp', 'mkdir', 'touch']);
  });
  tearDown(() {
    if (sandboxBash != null) pi.dispose();
  });

  // The canaries have to be able to fire, and the sandbox has to hold — a
  // check that cannot fail is the defect these tests replace.
  group('the canaries and the sandbox', () {
    final slips = <String, String Function(String v)>{
      'single quotes without escaping': (v) => "echo '$v'",
      'double quotes': (v) => 'echo "$v"',
      'no quotes': (v) => 'echo $v',
      'a heredoc with an unquoted delimiter': (v) =>
          'cat > /dev/null <<EOF\n$v\nEOF',
    };
    const slipOf = {
      'single quote': 'single quotes without escaping',
      'double quote': 'double quotes',
      'command substitution': 'double quotes',
      'backticks': 'a heredoc with an unquoted delimiter',
      'semicolon': 'no quotes',
      'line break': 'no quotes',
    };

    for (final (tag, v) in _hostile) {
      final slip = slipOf[tag];
      if (slip == null) continue;
      test('$tag: fires in $slip', () async {
        await pi.runGuarded(slips[slip]!(v), rebase: false);
        expect(pi.named('pwned-'), hasLength(1));
      });
    }

    for (final (tag, v) in [_allInOne, _allInOneNoBlank]) {
      for (final slip in slips.entries) {
        test('$tag: fires in ${slip.key}', () async {
          await pi.runGuarded(slip.value(v), rebase: false);
          expect(pi.named('pwned-'), isNotEmpty);
        });
      }
    }

    test('shSingleQuote: every value is one word and nothing else', () async {
      final values = [
        for (final (_, v) in [..._hostile, _allInOne, _allInOneNoBlank]) v,
      ];
      pi.record('take');
      final statuses =
          await _exec(pi, [for (final v in values) 'take ${shSingleQuote(v)}']);
      expect(statuses, everyElement(0));
      expect(pi.recorded, [for (final v in values) ['take', v]]);
      _expectDataOnly(pi, 'shSingleQuote');
    });

    // What went wrong twice in this project: a PATH that also reaches the
    // host, so that its curl, sh and bash answered instead of the stubs.
    test('with the host on PATH the shell ends before the first line of the '
        'script', () async {
      final r = await pi.run(
          'PATH="\$PATH:\$(dirname "\$BASH")"\n'
          '${pi.guard}'
          'touch pwned-ran',
          rebase: false);
      expect(r.code, PiSandbox.leakExit, reason: r.err);
      expect(r.err, contains('sandbox leak: '));
      expect(pi.named('pwned-'), isEmpty);
      // With the stubs alone the same lines run through.
      final tight = await pi.run('${pi.guard}touch pwned-ran', rebase: false);
      expect(tight.code, 0, reason: tight.err);
      expect(pi.named('pwned-'), ['pwned-ran']);
    });

    test('a script that names a path outside the sandbox is not started', () {
      for (final script in [
        'rm -f /tmp/pi-tool-signin',
        'mkdir -p /opt/homeassistant/config',
        'cat /run/user/1000/bus',
        'echo x > /boot/config.txt',
        'echo x >/pitool-none',
        'echo x >> "/pitool-none/x"',
        'echo x >| /pitool-none',
        // With these the stubs would no longer be the only ones to answer.
        'PATH="\$PATH:/usr/sbin"',
        "export PATH='${pi.root}/bin:/pitool-none'",
        // A descriptor of the shell is not moved into the sandbox — so what
        // leads on from one is the host's.
        '[ -e /proc/self/fd/3/../../environ ]',
      ]) {
        expect(() => pi.runGuarded(script), throwsStateError, reason: script);
      }
      // Run as it is, a path that a rebase would have moved is the host's.
      for (final script in [
        'cat /etc/hostname',
        "ls '/var/lib/pi-tool/x'",
        // Below /proc only a descriptor of the shell itself is let through.
        '[ -e /proc/self/environ ]',
        '[ -d /proc/self/fd/ ]',
        '[ -e /proc/1/fd/3 ]',
      ]) {
        expect(() => pi.runGuarded(script, rebase: false), throwsStateError,
            reason: script);
      }
    });

    // How a root script reaches the file it just created (fd 3 of
    // rootReplaceFileLines): moved into the sandbox, the name would lead
    // nowhere.
    test('a descriptor of the shell itself stays what it is', () async {
      for (final rebase in [true, false]) {
        final r = await pi.runGuarded(
            "exec 3> '${pi.root}/etc/pitool-fd-$rebase'\n"
            'fd=/proc/self/fd/3\n'
            '[ -f "\$fd" ] && echo offen\n'
            'echo drin >&3',
            rebase: rebase);
        expect(r.code, 0, reason: r.err);
        expect(r.lines, ['offen'], reason: 'rebase: $rebase');
        expect(pi.read('/etc/pitool-fd-$rebase'), 'drin\n');
      }
    });

    test('a script that stays inside the sandbox is run', () async {
      final r = await pi.runGuarded('#!/bin/sh\n'
          "PATH='${pi.root}/bin'\n"
          'echo drin > /etc/pitool-probe 2>/dev/null\n'
          'cat /etc/pitool-probe');
      expect(r.code, 0, reason: r.err);
      expect(r.lines, ['drin']);
      expect(pi.read('/etc/pitool-probe'), 'drin\n');
    });

    // Also for a test that expects its script to fail: exit 113 is not the
    // failure it means.
    test('a run that ends on a leak is an error, not a result', () async {
      await expectLater(
          pi.runGuarded('set -e\ntouch /pitool-none/x\necho weiter',
              rebase: false),
          throwsStateError);
      expect(pi.leaks, ['touch /pitool-none/x']);
    });

    test('rm, mv, cp, mkdir and touch refuse what lies outside the sandbox',
        () async {
      pi.put('/home/keep');
      // None of these paths exists: were one of them not refused, the tool
      // itself would fail on it.
      final refused = [
        'rm -f -- /pitool-none/x',
        "rm -f '${pi.root}/../pitool-none/x'",
        'mkdir /pitool-none/x',
        "mv '${pi.root}/home/keep' /pitool-none/x",
        "cp '${pi.root}/home/keep' /pitool-none/x",
        'touch /pitool-none/x',
        'cd / && touch pitool-none/x',
      ];
      final statuses = await _exec(pi, refused, rebase: false);
      expect(statuses, everyElement(PiSandbox.leakExit));
      expect(pi.leaks, hasLength(refused.length));
      expect(pi.exists('/home/keep'), isTrue);
    });
  }, skip: needsBash);

  group('command lines', () {
    setUp(() {
      for (final tool in const [
        'journalctl', 'rm', 'ls', 'cat', 'find', 'head', 'base64', 'du',
      ]) {
        pi.record(tool);
      }
      // With `state/docker-needs-sudo` docker answers under sudo only.
      pi.record('docker', r'''
if [ -e "$S/docker-needs-sudo" ] && [ -z "${PITOOL_SUDO:-}" ]; then exit 1; fi''');
      pi.stub('sudo', _sudo, log: false);
      // `sh -c`: dash where there is one, as on a Pi.
      pi.stub('sh', 'exec ${sandboxDash ?? pi.real('sh')} "\$@"', log: false);
      pi.allow(['bash']);
    });

    for (final line in _lines) {
      test(line.name, () async {
        const values = [..._hostile, _allInOne];
        line.arrange?.call(pi);
        final statuses =
            await _exec(pi, [for (final (_, v) in values) line.build(v)]);
        expect(statuses, List.filled(values.length, 0));
        expect([
          for (final call in pi.recorded) [call.first, _carrying([call])],
        ], [
          for (final (_, v) in values)
            for (final taker in line.takers)
              [taker, line.whole?.call(v, pi.root) ?? {v}],
        ]);
        _expectDataOnly(pi, line.name);
      });
    }

    test('buildFileSizeCommand: the file of that name is the one measured',
        () async {
      pi.allow(['wc']);
      final files = [
        for (final (_, v) in [_hostile[0], _hostile[2], _hostile[5], _allInOne])
          '${pi.root}/home/pi/$v',
      ];
      for (final (i, file) in files.indexed) {
        await _write(pi, file, 'x' * (i + 1));
      }
      final r = await pi.runGuarded(
          [for (final file in files) buildFileSizeCommand(file)].join('\n'),
          rebase: false);
      expect(r.code, 0, reason: r.err);
      expect(r.lines, [for (var i = 1; i <= files.length; i++) '$i']);
      _expectDataOnly(pi, 'buildFileSizeCommand');
    });

    test('buildDockerRunCommand: every field of the container is one argument',
        () async {
      final values = [
        for (final (_, v) in [..._hostile, _allInOne])
          if (v.contains('pwned-')) v,
      ];
      final statuses = await _exec(pi, rebase: false, [
        for (final v in values)
          buildDockerRunCommand(_container(v), image: 'img $v'),
      ]);
      expect(statuses, List.filled(values.length, 0));
      final calls = pi.recorded;
      expect(calls, hasLength(values.length));
      for (final (i, v) in values.indexed) {
        expect(calls[i].take(3), ['docker', 'run', '-d'], reason: v);
        expect(_carrying([calls[i]]), _runWhole(v, 'img $v'), reason: v);
      }
      _expectDataOnly(pi, 'buildDockerRunCommand');
    });

    test('buildDockerRunCommand: a restart policy docker does not know is '
        'left out', () {
      for (final (tag, v) in _hostile) {
        final container = _container(v);
        (container['HostConfig'] as Map)['RestartPolicy'] = {'Name': v};
        expect(buildDockerRunCommand(container), isNot(contains('--restart')),
            reason: tag);
      }
    });

    test('the restart of a systemd unit, as the updater sends it', () async {
      final runner = _Recorder();
      final updater = EvccUpdater(runnerFactory: (_) => runner);
      for (final (_, v) in _hostile) {
        await updater.restartSystemdUnit(
            config: const SshConfig(
                host: 'pi.invalid', port: 22, username: 'pi', password: 'x'),
            unit: v,
            onLog: (_) {});
      }
      pi.record('systemctl');
      final statuses = await _exec(pi, runner.commands);
      expect(statuses, List.filled(_hostile.length, 0));
      expect([
        for (final call in pi.recorded) [call.first, call.last],
      ], [
        for (final (_, v) in _hostile) ['systemctl', v],
      ]);
      _expectDataOnly(pi, 'restartSystemdUnit');
    });

    test('buildInstallAuthorizedKeyScript: the line is what the file gets',
        () async {
      final lines = [_hostile[0], _hostile[2], _hostile[5], _allInOne];
      for (final (i, (tag, v)) in lines.indexed) {
        final home = '/home/user$i';
        // Twice: the second run has to find the line and leave it alone.
        for (var run = 0; run < 2; run++) {
          final r = await pi.runGuarded("export HOME='${pi.root}$home'\n"
              '${buildInstallAuthorizedKeyScript(v)}');
          expect(r.code, 0, reason: '$tag\n${r.err}');
          expect(r.lines, ['KEY_INSTALLED'], reason: tag);
        }
        expect(pi.read('$home/.ssh/authorized_keys'), '$v\n', reason: tag);
        _expectDataOnly(pi, tag);
      }
    });
  }, skip: needsBash);

  group('root scripts', () {
    test('dockerComposeUpdateScript: directory, project, files and service',
        () async {
      pi.record('docker', r'pwd > "$S/cwd.$n"');
      for (final (tag, v) in _heavy) {
        final dir = '${pi.root}/home/$v';
        await _mkdir(pi, dir);
        final before = pi.recorded.length;
        final r = await pi.runGuarded(
            dockerComposeUpdateScript(DockerComposeInfo(
                workingDir: dir,
                configFile: '$v.yml, extra $v.yml',
                service: v,
                project: v)),
            rebase: false);
        expect(r.code, 0, reason: '$tag\n${r.err}');
        final calls = pi.recorded.skip(before).toList();
        expect(_carrying(calls), {v, '$v.yml', 'extra $v.yml'}, reason: tag);
        // The pull and the recreate run in the project's directory.
        expect(calls.length, greaterThanOrEqualTo(2), reason: tag);
        final last = before + calls.length - 1;
        for (final call in [last - 1, last]) {
          expect(pi.read('/state/cwd.$call'), '$dir\n', reason: tag);
        }
        _expectDataOnly(pi, tag);
      }
    });

    group('dockerRunRecreateScript: name and image', () {
      /// Every argument that may carry [v]: the name, the name of the rollback
      /// copy, the image and what `docker run` is given.
      Set<String> whole(String v) =>
          {..._runWhole(v, 'img $v'), '$v-evccpitool-old'};

      Future<SandboxRun> recreate(String v) => pi.runGuarded(
          dockerRunRecreateScript(
              name: v,
              image: 'img $v',
              runCommand:
                  buildDockerRunCommand(_container(v), image: 'img $v')),
          rebase: false);

      setUp(() {
        pi.record('docker', _dockerRecreate);
        pi.put('/state/status', 'running|0\n');
      });

      test('the container is recreated', () async {
        for (final (tag, v) in _heavy) {
          final before = pi.recorded.length;
          final r = await recreate(v);
          expect(r.code, 0, reason: '$tag\n${r.out}${r.err}');
          final calls = pi.recorded.skip(before).toList();
          expect(_carrying(calls), whole(v), reason: tag);
          expect(calls, contains(equals(['docker', 'stop', v])), reason: tag);
          _expectDataOnly(pi, tag);
        }
      });

      // The two ways back name the container and its copy once more.
      test('docker run fails: the old container is started again', () async {
        pi.put('/state/run-fails');
        for (final (tag, v) in _heavy) {
          final before = pi.recorded.length;
          final r = await recreate(v);
          expect(r.code, 1, reason: '$tag\n${r.out}${r.err}');
          final calls = pi.recorded.skip(before).toList();
          expect(_carrying(calls), whole(v), reason: tag);
          expect(calls.last, ['docker', 'start', v], reason: tag);
          _expectDataOnly(pi, tag);
        }
      });

      test('the new container does not stay up: the old one is started again',
          () async {
        pi.put('/state/status', 'restarting|2\n');
        for (final (tag, v) in _heavy) {
          final before = pi.recorded.length;
          final r = await recreate(v);
          expect(r.code, 1, reason: '$tag\n${r.out}${r.err}');
          final calls = pi.recorded.skip(before).toList();
          expect(_carrying(calls), whole(v), reason: tag);
          expect(calls.last, ['docker', 'start', v], reason: tag);
          _expectDataOnly(pi, tag);
        }
      });
    });

    test('buildConfigWriteScript: the file of that name is written', () async {
      pi.allow(['base64', 'readlink', 'chown']);
      // The new file takes owner and mode from the one it replaces.
      pi.record('stat', _stat);
      for (final (tag, v) in _heavy) {
        final path = '${pi.root}/home/pi/$v';
        await _write(pi, path, 'alt\n');
        final before = pi.recorded.length;
        final r = await pi.runGuarded(buildConfigWriteScript(
            path: path, base64Content: base64.encode(utf8.encode('neu $v\n'))));
        expect(r.code, 0, reason: '$tag\n${r.err}');
        expect(r.lines.last, 'CONFIG_SAVED', reason: tag);
        expect(await _read(pi, path), 'neu $v\n', reason: tag);
        // The file of that name is the one that was asked about.
        expect(_carrying(pi.recorded.skip(before)), {path}, reason: tag);
        _expectDataOnly(pi, tag);
      }
      // One file and one backup per name, no temp file left.
      expect(pi.ls('/home/pi'), hasLength(_heavy.length));
      expect(pi.ls(serviceBackupDir), hasLength(_heavy.length));
    });

    // A link at the path is followed by hand, one name at a time — and where
    // it leads is a value from the Pi like the path itself.
    test('buildConfigWriteScript: a link of that name is followed to the '
        'file of that name', () async {
      pi.allow(['base64', 'readlink', 'chown']);
      pi.confine(['ln']);
      pi.record('stat', _stat);
      for (final (tag, v) in _heavy) {
        final dir = '${pi.root}/home/pi/$v';
        final file = '$dir/ziel $v';
        final link = '${pi.root}/etc/$v';
        await _write(pi, file, 'alt\n');
        if (!await _symlink(pi, file, link)) {
          markTestSkipped('this host creates no symlinks');
          return;
        }
        final before = pi.recorded.length;
        final r = await pi.runGuarded(buildConfigWriteScript(
            path: link, base64Content: base64.encode(utf8.encode('neu $v\n'))));
        expect(r.code, 0, reason: '$tag\n${r.out}${r.err}');
        expect(r.lines.last, 'CONFIG_SAVED', reason: tag);
        expect(await _read(pi, file), 'neu $v\n', reason: tag);
        final still = await _withPath(pi, link, r'[ -L "$p" ]');
        expect(still.code, 0, reason: '$tag: the link is still one');
        // Asked about under exactly their names: the directory the last name
        // was looked up in, and the file for its owner and mode.
        expect(_carrying(pi.recorded.skip(before)), {dir, file}, reason: tag);
        _expectDataOnly(pi, tag);
      }
    });

    test('buildConfigWriteScript: content that is no base64 writes nothing',
        () async {
      pi.allow(['base64', 'readlink', 'chown']);
      pi.put('/home/pi/evcc.yaml', 'alt\n');
      for (final (tag, v) in _heavy) {
        final r = await pi.runGuarded(buildConfigWriteScript(
            path: '/home/pi/evcc.yaml', base64Content: v));
        expect(r.code, isNot(0), reason: tag);
        expect(r.out, isNot(contains('CONFIG_SAVED')), reason: tag);
        expect(pi.read('/home/pi/evcc.yaml'), 'alt\n', reason: tag);
        _expectDataOnly(pi, tag);
      }
      expect(pi.ls('/home/pi'), ['evcc.yaml']);
    });

    test('buildUploadScript: the file of that name is written', () async {
      pi.allow(['base64', 'chown']);
      pi.record('stat', _stat);
      for (final (tag, v) in _heavy) {
        final path = '${pi.root}/home/pi/neu/$v';
        final before = pi.recorded.length;
        final r = await pi.runGuarded(buildUploadScript(
            path: path, base64Content: base64.encode(utf8.encode('neu $v\n'))));
        expect(r.code, 0, reason: '$tag\n${r.err}');
        expect(r.lines.last, 'UPLOAD_OK', reason: tag);
        expect(await _read(pi, path), 'neu $v\n', reason: tag);
        // Asked whether there is a file of that name to take over from.
        expect(_carrying(pi.recorded.skip(before)), {path}, reason: tag);
        _expectDataOnly(pi, tag);
      }
      expect(pi.ls('/home/pi/neu'), hasLength(_heavy.length));
    });

    test('buildUploadScript: content that is no base64 writes nothing',
        () async {
      pi.allow(['base64', 'chown']);
      for (final (tag, v) in _heavy) {
        final r = await pi.runGuarded(
            buildUploadScript(path: '/home/pi/neu/a.txt', base64Content: v));
        expect(r.code, isNot(0), reason: tag);
        expect(r.out, isNot(contains('UPLOAD_OK')), reason: tag);
        _expectDataOnly(pi, tag);
      }
      expect(pi.ls('/home/pi/neu'), isEmpty);
    });

    test('buildRestoreScript: the archive of that name is checked and '
        'unpacked', () async {
      pi.record('tar', r'case " $* " in *" -tzf "*) echo etc/evcc.yaml ;; esac');
      pi.record('systemctl');
      for (final (tag, v) in _heavy) {
        final archive = '${pi.root}$evccBackupDir/$v.tar.gz';
        await _write(pi, archive, 'x');
        final before = pi.recorded.length;
        final r = await pi.runGuarded(buildRestoreScript(archive));
        expect(r.code, 0, reason: '$tag\n${r.out}${r.err}');
        expect(r.lines.last, 'RESTORE_OK', reason: tag);
        final tars = pi.recorded.skip(before).where((c) => c.first == 'tar');
        // Once to read the archive, once to unpack it.
        expect(tars, hasLength(2), reason: tag);
        for (final tar in tars) {
          expect(_carrying([tar]), {archive}, reason: tag);
        }
        _expectDataOnly(pi, tag);
      }
    });

    test('buildPiholeRestoreScript: the archive of that name is imported',
        () async {
      pi.record('pihole-FTL');
      pi.record('pihole');
      for (final (tag, v) in _heavy) {
        final archive = '${pi.root}$serviceBackupDir/$v.zip';
        await _write(pi, archive, 'x');
        final before = pi.recorded.length;
        final r = await pi.runGuarded(buildPiholeRestoreScript(archive));
        expect(r.code, 0, reason: '$tag\n${r.out}${r.err}');
        expect(r.lines.last, 'RESTORE_OK', reason: tag);
        final calls = pi.recorded.skip(before).toList();
        expect(_carrying(calls), {archive}, reason: tag);
        expect(calls.first.first, 'pihole-FTL', reason: tag);
        _expectDataOnly(pi, tag);
      }
    });

    group('Home Assistant', () {
      test('buildHomeAssistantBackupScript: the directory of that name is '
          'archived', () async {
        pi.record('tar');
        for (final (tag, v) in _heavy) {
          final config = '${pi.root}/home/ha $v';
          await _mkdir(pi, config);
          final before = pi.recorded.length;
          final r = await pi.runGuarded(buildHomeAssistantBackupScript(config));
          expect(r.code, 0, reason: '$tag\n${r.out}${r.err}');
          final tar = pi.recorded.skip(before).single;
          expect(_carrying([tar]), {config}, reason: tag);
          // tar changes into that directory: the argument right after -C.
          expect(tar[tar.indexOf('-C') + 1], config, reason: tag);
          expect(
              r.lines.last,
              startsWith('BACKUP_OK ${pi.root}$serviceBackupDir/'
                  'homeassistant-backup-'),
              reason: tag);
          _expectDataOnly(pi, tag);
        }
      });

      /// The restore of the archive, the directory and the container [v].
      Future<(SandboxRun, String archive, String config)> restore(
          String v) async {
        final archive = '${pi.root}$serviceBackupDir/$v.tar.gz';
        final config = '${pi.root}/home/ha $v';
        await _write(pi, archive, 'x');
        await _mkdir(pi, config);
        final r = await pi.runGuarded(buildHomeAssistantRestoreScript(
            archivePath: archive, configPath: config, containerName: v));
        return (r, archive, config);
      }

      test('buildHomeAssistantRestoreScript: archive, directory and container',
          () async {
        pi.record('tar');
        pi.record('docker', r'[ "$1" != inspect ] || echo "running|0"');
        for (final (tag, v) in _heavy) {
          final before = pi.recorded.length;
          final (r, archive, config) = await restore(v);
          expect(r.code, 0, reason: '$tag\n${r.out}${r.err}');
          expect(r.lines.last, 'RESTORE_OK', reason: tag);
          final calls = pi.recorded.skip(before).toList();
          expect(_carrying(calls), {archive, config, v}, reason: tag);
          expect(calls, contains(equals(['docker', 'stop', v])), reason: tag);
          final tar = calls.singleWhere((c) => c.first == 'tar');
          expect(tar[tar.indexOf('-C') + 1], config, reason: tag);
          _expectDataOnly(pi, tag);
        }
      });

      // The trap names the container once more — when it is set, and when it
      // fires.
      test('buildHomeAssistantRestoreScript: tar fails, and the trap starts '
          'the container of that name', () async {
        pi.record('tar', 'exit 2');
        pi.record('docker');
        for (final (tag, v) in _heavy) {
          final before = pi.recorded.length;
          final (r, archive, config) = await restore(v);
          expect(r.code, isNot(0), reason: '$tag\n${r.out}${r.err}');
          expect(r.out, isNot(contains('RESTORE_OK')), reason: tag);
          final calls = pi.recorded.skip(before).toList();
          expect(_carrying(calls), {archive, config, v}, reason: tag);
          expect(calls.last, ['docker', 'start', v], reason: tag);
          _expectDataOnly(pi, tag);
        }
      });
    });

    test('buildTailscaleUpScript: every flag is one argument', () async {
      // `tailscale up` runs detached; the script's wait ends once it has run.
      pi.stub('setsid', r'exec "$@"', log: false);
      pi.record('tailscale', r'[ "$1" != up ] || true > "$S/up.done"');
      pi.stub(
          'sleep',
          'i=0\n'
              'while [ ! -e "\$S/up.done" ] && [ "\$i" -lt 200 ]; do\n'
              '  "${pi.real('sleep')}" 0.05\n'
              '  i=\$((i + 1))\n'
              'done\n'
              '"\$REAL_RM" -f "\$S/up.done"',
          log: false);
      for (final (tag, v) in _heavy) {
        final before = pi.recorded.length;
        final r = await pi.runGuarded(
            buildTailscaleUpScript(['--hostname=$v', v]),
            rebase: false);
        expect(r.code, 0, reason: '$tag\n${r.err}');
        expect(r.lines.last, 'TS_UP_OK', reason: tag);
        final up = pi.recorded.skip(before).first;
        expect(up.take(2), ['tailscale', 'up'], reason: tag);
        expect(up.skip(2), ['--hostname=$v', v], reason: tag);
        _expectDataOnly(pi, tag);
      }
    });

    // These two take checked values only (see "values a builder refuses"):
    // what passes the check has to arrive as one argument as well.
    test('buildTailscaleAdvertiseScript: the routes are one argument, the '
        'app\'s own are noted', () async {
      pi.record('sysctl', r'[ "$1" != -n ] || echo 1');
      pi.record('tailscale');
      pi.put('/etc/sysctl.d/README');
      final r = await pi.runGuarded(buildTailscaleAdvertiseScript(
          const ['192.168.178.0/24', 'fd00:1::/64'],
          mine: const ['192.168.178.0/24']));
      expect(r.code, 0, reason: r.err);
      expect(r.lines.last, tailscaleRoutesMarker);
      final set = pi.recorded.singleWhere((c) => c.first == 'tailscale');
      expect(set, contains('--advertise-routes=192.168.178.0/24,fd00:1::/64'));
      expect(pi.read(tailscaleForwardingConf).split('\n'),
          contains('# routes=192.168.178.0/24'));
    });

    test('buildPiholeSetPasswordScript: the password is one argument and is '
        'not printed', () async {
      const password = 'Abcdefgh23456789';
      // No password set so far.
      pi.record('pihole-FTL', "echo '\"\"'");
      pi.record('pihole');
      final r = await pi.runGuarded(buildPiholeSetPasswordScript(password));
      expect(r.code, 0, reason: r.err);
      expect(r.lines, contains(piholePasswordSetMarker));
      expect(r.lines.last, piholePasswordDoneMarker);
      final set = pi.recorded.singleWhere((c) => c.first == 'pihole');
      expect(set.last, password);
      expect('${r.out}${r.err}', isNot(contains(password)));
    });
  }, skip: needsBash);

  group('the ntfy destination', () {
    // Server and topic lose all whitespace before anything else is done with
    // them — a line break included.
    String stripped(String v) => v.replaceAll(RegExp(r'\s'), '');
    const values = [
      ..._hostile,
      _allInOne,
      _allInOneNoBlank,
      // A line equal to the heredoc's end, and the script going on after it.
      ('heredoc end', 'x\nWRAP\ntouch pwned-wrap\n'),
    ];

    /// What the test push needs on the Pi: the command is one `sh -c` — dash
    /// where there is one, as on a Pi — that asks for the host name and calls
    /// curl.
    void pushTools() {
      pi.stub('sh', 'exec ${sandboxDash ?? pi.real('sh')} "\$@"', log: false);
      pi.stub('hostname', 'echo zirkel', log: false);
      pi.record('curl');
    }

    /// The title of every push: one argument, blank and brackets included.
    const title = 'Title: Pi-Tool (zirkel)';

    /// What curl got: per call the header — the argument after `-H` —, the
    /// URL — its last argument — and every argument that carries a part of
    /// the value.
    List<List<Object>> pushes() => [
          for (final call in pi.recorded)
            [call[call.indexOf('-H') + 1], call.last, _carrying([call])],
        ];

    test('buildTestAlertCommand: the topic is part of one URL argument',
        () async {
      pushTools();
      final statuses = await _exec(pi, [
        for (final (_, v) in values)
          buildTestAlertCommand(ntfyServer: 'https://ntfy.example', ntfyTopic: v),
      ]);
      expect(statuses, List.filled(values.length, 0));
      final urls = [
        for (final (_, v) in values) 'https://ntfy.example/${stripped(v)}',
      ];
      expect(pushes(), [for (final url in urls) [title, url, {url}]]);
      _expectDataOnly(pi, 'topic');
    });

    test('buildTestAlertCommand: the server is part of one URL argument',
        () async {
      pushTools();
      final statuses = await _exec(pi, [
        for (final (_, v) in values)
          buildTestAlertCommand(
              ntfyServer: 'https://ntfy.example/$v', ntfyTopic: 'pi'),
      ]);
      expect(statuses, List.filled(values.length, 0));
      final urls = [
        for (final (_, v) in values) 'https://ntfy.example/${stripped(v)}/pi',
      ];
      expect(pushes(), [for (final url in urls) [title, url, {url}]]);
      _expectDataOnly(pi, 'server');
    });

    test('buildAlertsInstallScript: the wrapper reads server and topic as '
        'they were entered', () async {
      pi.record('systemctl');
      // The wrapper is a #!/bin/sh script and sources the file: dash where
      // there is one.
      pi.stub('posix-sh', 'exec ${sandboxDash ?? pi.real('sh')} "\$@"',
          log: false);
      pi.put('/state/show.sh',
          '. "\$1"\nprintf \'%s\\n%s\\n\' "\$URL" "\$TOPIC"\n');
      for (final (tag, v) in [_allInOneNoBlank, _allInOne, values.last]) {
        final server = 'https://ntfy.example/$v';
        final r = await pi.runGuarded(
            buildAlertsInstallScript(ntfyServer: server, ntfyTopic: v));
        expect(r.code, 0, reason: '$tag\n${r.err}');
        expect(r.lines.last, 'ALERTS_INSTALLED', reason: tag);
        final shown = await pi.runGuarded(
            "posix-sh '${pi.root}/state/show.sh' "
            "'${pi.root}$alertsDestinationPath'",
            rebase: false);
        expect(shown.out, '${stripped(server)}\n${stripped(v)}\n', reason: tag);
        _expectDataOnly(pi, tag);
      }
    });
  }, skip: needsBash);

  group('what sudo and the job bootstrap do with the password line', () {
    test('buildRootStdin: the password is the line sudo takes, the script '
        'runs after it', () async {
      // Like `sudo -S` when it asks: one line of stdin is the password.
      pi.stub(
          'sudo',
          'IFS= read -r line\n'
              'printf \'%s\\n\' "\$line" >> "\$S/passwords"\n'
              '$_sudo',
          log: false);
      pi.allow(['bash']);
      // One line by its nature: sudo reads up to the line break.
      final passwords = [
        for (final (_, v) in _hostile)
          if (!v.contains('\n')) v,
      ];
      for (final v in passwords) {
        final r = await pi.runGuarded(
            '$installShellCommand\n'
            '${buildRootStdin(sudoNeedsPassword: true, password: v, script: 'echo ROOT-SCRIPT')}',
            rebase: false);
        expect(r.code, 0, reason: '$v\n${r.err}');
        expect(r.lines, ['ROOT-SCRIPT'], reason: v);
        _expectDataOnly(pi, v);
      }
      expect(pi.read('/state/passwords'), passwords.map((v) => '$v\n').join());
    });

    test('buildRootStdin: a sudo that asks for nothing gets no password line',
        () {
      for (final (_, v) in _hostile) {
        expect(
            buildRootStdin(
                sudoNeedsPassword: false, password: v, script: 'echo x'),
            'echo x\n');
      }
    });

    test('the job bootstrap drops a password line sudo did not take', () async {
      // A sudo that asks for nothing: the line reaches the bootstrap.
      pi.stub('sudo', _sudo, log: false);
      pi.allow(['bash']);
      // The follower with all of its paths in the sandbox, /run included.
      final options = JobScriptOptions(root: pi.root);
      for (final (tag, v) in [_hostile[5], _allInOne]) {
        final r = await pi.runGuarded(
            '${jobFollowCommand(_id)}\n'
            '${buildJobFollowStdin(password: v, id: _id, options: options)}',
            rebase: false);
        expect(r.code, 0, reason: '$tag\n${r.err}');
        expect(r.lines, ['PITOOL_JOB_UNKNOWN $_id'], reason: tag);
        _expectDataOnly(pi, tag);
      }
    });
  }, skip: needsBash);

  // No shell is needed for these: a value that is refused reaches no script.
  group('values a builder refuses', () {
    final values = [
      for (final (_, v) in [..._hostile, _allInOne, _allInOneNoBlank]) v,
    ];

    test('a schedule that is not one of the app\'s own', () {
      const daily = '*-*-* 04:00:00';
      for (final v in values) {
        for (final schedule in [v, '$daily$v', '$daily\n$v', '$v$daily']) {
          expect(() => buildAutoUpdateInstallScript(onCalendar: schedule),
              throwsArgumentError,
              reason: schedule);
          expect(
              () => buildScheduledBackupInstallScript(
                  onCalendar: schedule, keep: 7),
              throwsArgumentError,
              reason: schedule);
        }
      }
      // What the app builds passes.
      expect(buildAutoUpdateInstallScript(onCalendar: daily),
          contains('\nOnCalendar=$daily\n'));
    });

    test('a login name, a package name, a job id, a job kind', () {
      for (final v in values) {
        for (final purge in [false, true]) {
          expect(
              () => buildPiConnectUninstallScript(user: 'pi$v', purge: purge),
              throwsArgumentError,
              reason: v);
        }
        expect(() => buildPackageUpdatePayload('evcc$v'), throwsArgumentError,
            reason: v);
        expect(() => jobStartCommand('$_id$v'), throwsArgumentError, reason: v);
        expect(() => jobFollowCommand(v), throwsArgumentError, reason: v);
        expect(() => buildJobFollowerScript(id: v), throwsArgumentError,
            reason: v);
        expect(
            () => buildJobLauncherScript(id: _id, kind: v, payload: 'true'),
            throwsArgumentError,
            reason: v);
        expect(
            () => buildJobWrapperScript(
                options: JobScriptOptions(root: '/srv/$v')),
            throwsArgumentError,
            reason: v);
      }
    });

    test('a web password — and the message does not repeat it', () {
      for (final v in values) {
        for (final build in [
          () => buildPiholeInstallScript(webPassword: 'Abcdefgh$v'),
          () => buildPiholeSetPasswordScript('Abcdefgh$v'),
        ]) {
          expect(
              build,
              throwsA(isA<ArgumentError>().having(
                  (e) => '$e', 'message', isNot(contains('Abcdefgh')))),
              reason: v);
        }
      }
    });

    test('a channel that is not one of the two is the stable one', () {
      for (final v in values) {
        expect(buildInstallScript(channel: v), buildInstallScript(), reason: v);
        expect(buildInstallScript(channel: 'unstable$v'), buildInstallScript(),
            reason: v);
      }
    });

    test('a route that is no network prefix', () {
      for (final v in values) {
        expect(() => buildTailscaleAdvertiseScript(['192.168.178.0/24$v']),
            throwsArgumentError,
            reason: v);
        expect(
            () => buildTailscaleAdvertiseScript(const ['192.168.178.0/24'],
                mine: ['192.168.178.0/24$v']),
            throwsArgumentError,
            reason: v);
      }
    });

    test('an ntfy server with another scheme than http(s) — and the message '
        'does not repeat it', () {
      for (final server in ['ntfy://geheim-thema', 'file:///etc/shadow', '']) {
        for (final build in [
          () => buildAlertsInstallScript(ntfyServer: server, ntfyTopic: 'pi'),
          () => buildTestAlertCommand(ntfyServer: server, ntfyTopic: 'pi'),
        ]) {
          expect(
              build,
              throwsA(isA<ArgumentError>().having(
                  (e) => '$e', 'message', isNot(contains('geheim')))),
              reason: server);
        }
      }
    });
  });

  // systemdStateCommand and the detection's `systemctl is-active <unit>` put
  // the unit into the command line as it is. That holds only as long as every
  // unit is a constant of the app that needs no quoting.
  test('the units that go into a command line unquoted are plain words', () {
    final word = RegExp(r'^[A-Za-z0-9@_.-]+$');
    for (final unit in [
      for (final s in knownSystemdServices) s.unit,
      for (final s in knownAptServices) s.unit,
    ]) {
      expect(unit, matches(word));
      expect(systemdStateCommand(unit), contains(' $unit '));
    }
  });
}
