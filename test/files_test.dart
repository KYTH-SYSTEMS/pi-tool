import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:evcc_updater/src/files.dart';
import 'package:evcc_updater/src/parsing.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bash for the real-shell groups. On Windows `bash` may be the WSL
/// launcher, so they only run with an explicit Git Bash
/// (PITOOL_TEST_BASH=C:\Program Files\Git\bin\bash.exe).
final String? _bash =
    Platform.isWindows ? Platform.environment['PITOOL_TEST_BASH'] : 'bash';

/// Skip reason for the real-bash groups, or false when a bash is at hand.
final Object _needsBash =
    _bash == null ? 'needs bash (PITOOL_TEST_BASH on Windows)' : false;

/// The plain tools the commands under test use; each gets a pass-through
/// wrapper in the sandbox.
const _realTools = [
  'base64', 'bash', 'chmod', 'chown', 'dirname', 'find', 'head', 'mkdir',
  'mktemp', 'mv', 'rm',
];

class _Run {
  _Run(this.code, this.out, this.err);
  final int code;
  final String out;
  final String err;
}

/// A throwaway directory tree for running the file browser's commands in a
/// real bash. PATH holds ONLY `bin/`: pass-through wrappers for [_realTools]
/// (chmod and chown also log their call) and a `sudo` that takes the password
/// from stdin like `sudo -S` — nothing else on the host can be reached. Every
/// path a test hands to a command lies below [root].
class _Box {
  _Box() : _dir = Directory.systemTemp.createTempSync('pitool-files') {
    // The directory as bash names it: with a `C:/…` in PATH the colon would
    // split the entry and the stubs would not be found.
    final facts = (Process.runSync(_bash!, [
      '-c',
      'cd "\$0" && pwd && command -v ${_realTools.join(' ')}',
      _dir.path,
    ]).stdout as String)
        .trim()
        .split('\n');
    if (facts.length != _realTools.length + 1) {
      throw StateError('sandbox probe: $facts');
    }
    root = facts.first.trim();
    Directory(host('bin')).createSync();
    Directory(host('home/pi')).createSync(recursive: true);
    for (var i = 0; i < _realTools.length; i++) {
      final name = _realTools[i];
      final log = name == 'chmod' || name == 'chown'
          ? "echo \"$name \$*\" >> '$root/calls'\n"
          : '';
      File(host('bin/$name')).writeAsStringSync(
          '#!/bin/sh\n${log}exec "${facts[i + 1].trim()}" "\$@"\n');
    }
    // Like `sudo -S [-p prompt]`: the password is the first line on stdin.
    File(host('bin/sudo')).writeAsStringSync(r'''#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    -p) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
IFS= read -r pw
if [ "$pw" != sekret ]; then
  echo "Sorry, try again." >&2
  echo "sudo: 1 incorrect password attempt" >&2
  exit 1
fi
exec "$@"
''');
    Process.runSync(_bash!, ['-c', r'chmod +x "$0"/bin/*', _dir.path]);
  }

  final Directory _dir;

  /// The sandbox as bash names it (`/tmp/…` in Git Bash).
  late final String root;

  /// [rel] below the sandbox as dart:io reaches it.
  String host(String rel) => '${_dir.path}/$rel';

  /// Prepares fixtures with the host's own tools; [script] runs with the
  /// sandbox as its working directory and touches nothing outside it. Returns
  /// whether it succeeded. `ln -s` gives Git Bash's emulated links where
  /// Windows grants no real ones — a script that needs links ends in a
  /// `[ -L … ]` and the test skips itself on false.
  bool setup(String script) => Process.runSync(
          _bash!, ['-c', 'cd "\$0" && { $script\n}', _dir.path],
          environment: {'MSYS': 'winsymlinks:lnk'}).exitCode ==
      0;

  /// Runs [command] the way the app does: one command line in a shell, the
  /// sudo password on stdin.
  Future<_Run> exec(String command, {String password = 'sekret'}) =>
      _run(['-c', "export PATH='$root/bin'; $command"], '$password\n');

  /// Feeds [script] to `bash -s` on stdin, like the app's root shell.
  Future<_Run> script(String script) =>
      _run(['-s'], "export PATH='$root/bin'\n$script\n");

  Future<_Run> _run(List<String> args, String stdin) async {
    final p = await Process.start(_bash!, args, workingDirectory: _dir.path);
    final out = p.stdout.transform(utf8.decoder).join();
    final err = p.stderr.transform(utf8.decoder).join();
    p.stdin.add(utf8.encode(stdin));
    await p.stdin.close();
    return _Run(await p.exitCode, await out, await err);
  }

  /// The chmod/chown calls so far, one `name args` line each.
  List<String> get calls {
    final f = File(host('calls'));
    return f.existsSync()
        ? f.readAsLinesSync().where((l) => l.isNotEmpty).toList()
        : const [];
  }

  /// Entry names in [rel], sorted (hidden ones included).
  List<String> ls(String rel) => Directory(host(rel))
      .listSync(followLinks: false)
      .map((e) => e.path.replaceAll(r'\', '/').split('/').last)
      .toList()
    ..sort();

  /// Through bash first: dart:io on Windows cannot name a file that ends in a
  /// space, so it could not remove what the listing tests create.
  void dispose() {
    Process.runSync(_bash!, ['-c', r'rm -rf -- "$0"', _dir.path]);
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
  }
}

void main() {
  group('isProbablyTextFile', () {
    test('plain ASCII and UTF-8 (umlauts) count as text', () {
      expect(isProbablyTextFile(Uint8List.fromList(utf8.encode('hello\nwelt'))),
          isTrue);
      expect(
          isProbablyTextFile(
              Uint8List.fromList(utf8.encode('grün änderte Größe'))),
          isTrue);
    });

    test('a NUL byte marks the file as binary', () {
      expect(isProbablyTextFile(Uint8List.fromList([104, 105, 0, 104])),
          isFalse);
    });

    test('an empty file is editable text', () {
      expect(isProbablyTextFile(Uint8List(0)), isTrue);
    });

    test('a PNG header is binary (high control-byte ratio)', () {
      expect(
          isProbablyTextFile(Uint8List.fromList(
              [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])),
          isFalse);
    });
  });

  group('commands', () {
    test('list + read are sudo and shell-quoted', () {
      // LC_ALL=C for sudo's messages; stderr stays on its own stream.
      expect(
          buildListDirCommand('/etc'),
          "LC_ALL=C sudo -S -p '' find -H '/etc' -mindepth 1 -maxdepth 1 "
          r"-printf '%y%Y\t%f\0'");
      // Size-capped read (head -c) so a huge file can't OOM the app.
      expect(
          buildReadFileCommand('/etc/evcc.yaml'),
          "LC_ALL=C sudo -S -p '' bash -c "
          r"""'set -o pipefail; head -c 524288 -- "$1" | base64' """
          "bash '/etc/evcc.yaml'");
      expect(buildListDirCommand("/x';reboot;'"), contains(r"'\''"));
      expect(buildReadFileCommand("/x';reboot;'"), contains(r"'\''"));
    });

    test('upload: base64-decodes atomically into the target dir + marker', () {
      final s = buildUploadScript(path: '/etc/evcc.yaml', base64Content: 'aGk=');
      expect(s, contains('base64 -d'));
      expect(s, contains('mv -f')); // atomic rename over the target
      expect(s, contains("'/etc/evcc.yaml'"));
      expect(s, contains('aGk=')); // the payload
      expect(s, contains('UPLOAD_OK')); // success marker the caller verifies
    });

    test('upload: creates the target dir before mktemp (migration to a new Pi)',
        () {
      // Found by audit 2026-08-15: on a target Pi that was never backed up,
      // /var/backups/evcc does not exist, mktemp fails, set -e kills the
      // script and the whole migration dies AFTER installing on the target.
      final s = buildUploadScript(
          path: '/var/backups/evcc/evcc-backup-1.tar.gz', base64Content: 'aGk=');
      expect(s, contains('mkdir -p "\$dir"'));
      expect(s.indexOf('mkdir -p'), lessThan(s.indexOf('mktemp')));
    });

    test('upload: hostile path + content are single-quoted (no injection)', () {
      final s = buildUploadScript(
          path: "/x';reboot;'", base64Content: "YQ==';reboot;'");
      expect(s, contains(r"'\''")); // escaped, not executable
      expect(s, isNot(contains('\n;reboot;')));
    });

    test('download: size probe + base64 stream, quoted, no sudo needed', () {
      // Backups are world-readable (0644) by design — no sudo, no password.
      expect(buildFileSizeCommand('/var/backups/pi-tool/a.tar.gz'),
          "wc -c < '/var/backups/pi-tool/a.tar.gz'");
      expect(buildDownloadFileCommand('/var/backups/pi-tool/a.tar.gz'),
          "base64 -- '/var/backups/pi-tool/a.tar.gz'");
      expect(buildFileSizeCommand("/x';reboot;'"), contains(r"'\''"));
      expect(buildDownloadFileCommand("/x';reboot;'"), contains(r"'\''"));
    });

    test('download limit bounds the transfer (48 MB)', () {
      expect(kBackupDownloadLimit, 48 * 1024 * 1024);
    });

    test('delete: file rm -f, dir rm -rf, both -- and quoted', () {
      expect(buildDeleteCommand(path: '/tmp/a', isDir: false),
          "LC_ALL=C sudo -S -p '' rm -f -- '/tmp/a'");
      expect(buildDeleteCommand(path: '/tmp/d', isDir: true),
          "LC_ALL=C sudo -S -p '' rm -rf -- '/tmp/d'");
      expect(buildDeleteCommand(path: "/x';reboot;'", isDir: false),
          contains(r"'\''"));
    });
  });

  group('parseDirListing', () {
    List<(String, bool)> parsed(String out) =>
        [for (final e in parseDirListing(out)) (e.name, e.isDir)];

    test('dirs first, then files, alphabetical', () {
      expect(
          parsed('dd\tetc\x00ff\tzeta.txt\x00dd\tapps\x00ff\talpha.conf\x00'), [
        ('apps', true),
        ('etc', true),
        ('alpha.conf', false),
        ('zeta.txt', false),
      ]);
    });

    test('a symlink counts as what it points to', () {
      // %Y: d for /bin -> usr/bin, N for a dangling link, L for a loop.
      expect(
          parsed('ld\tbin\x00lf\tvmlinuz\x00lN\tdangling\x00lL\tloop\x00'), [
        ('bin', true),
        ('dangling', false),
        ('loop', false),
        ('vmlinuz', false),
      ]);
    });

    test('a symlink is flagged as one, whatever it points to', () {
      // %y is the entry itself: only then can deleting say what it removes.
      final byName = {
        for (final e in parseDirListing('ld\tbin\x00dd\tusr\x00lf\tvmlinuz\x00'
            'ff\tnotes.txt\x00lN\tdangling\x00'))
          e.name: e.isLink
      };
      expect(byName, {
        'bin': true,
        'usr': false,
        'vmlinuz': true,
        'notes.txt': false,
        'dangling': true,
      });
    });

    test('names stay as they are: spaces, tabs, line breaks', () {
      // They go into the paths of open and delete — a trimmed name is
      // another file.
      expect(
          parsed('ff\ttrailing \x00ff\t leading\x00ff\ta\tb\x00'
              'ff\tline\nbreak\x00dd\tdir \x00'),
          [
            ('dir ', true),
            (' leading', false),
            ('a\tb', false),
            ('line\nbreak', false),
            ('trailing ', false),
          ]);
    });

    test('empty listing → empty', () {
      expect(parseDirListing(''), isEmpty);
    });

    test('a record cut off before its terminator is not an entry', () {
      expect(parsed('ff\tdone\x00ff\thalf'), [('done', false)]);
    });

    test('text that is not a record is not an entry', () {
      // What used to turn up as a file: a message in the listing's stream.
      expect(parseDirListing('Sorry, try again.\n'), isEmpty);
      expect(
          parseDirListing("find: '/x': No such file or directory\n\x00"),
          isEmpty);
      expect(parseDirListing('\x00\x00ff\t\x00'), isEmpty);
      // One type letter only is not this listing's format.
      expect(parseDirListing('f\tnotes.txt\x00'), isEmpty);
    });
  });

  group('buildListDirCommand in bash', () {
    late _Box box;
    setUp(() => box = _Box());
    tearDown(() => box.dispose());

    Future<List<(String, bool)>> list(String rel) async {
      final r = await box.exec(buildListDirCommand('${box.root}/$rel'));
      expect(r.code, 0, reason: r.err);
      expect(r.err, isEmpty);
      return [for (final e in parseDirListing(r.out)) (e.name, e.isDir)];
    }

    /// The names in [rel] the listing flags as symlinks, sorted.
    Future<List<String>> linkNames(String rel) async {
      final r = await box.exec(buildListDirCommand('${box.root}/$rel'));
      expect(r.code, 0, reason: r.err);
      return [
        for (final e in parseDirListing(r.out))
          if (e.isLink) e.name
      ]..sort();
    }

    test('directories, files, hidden files, names with spaces', () async {
      expect(
          box.setup('mkdir home/pi/dir "home/pi/dir with space"\n'
              ': > home/pi/file.txt\n'
              ': > "home/pi/two words"\n'
              ': > "home/pi/trailing "\n'
              ': > "home/pi/ leading"\n'
              ': > home/pi/.hidden'),
          isTrue);
      expect(await list('home/pi'), [
        ('dir', true),
        ('dir with space', true),
        (' leading', false),
        ('.hidden', false),
        ('file.txt', false),
        ('trailing ', false),
        ('two words', false),
      ]);
      expect(await linkNames('home/pi'), isEmpty);
    });

    test('an empty directory lists nothing', () async {
      expect(await list('home/pi'), isEmpty);
    });

    test('names with umlauts arrive as they are, LC_ALL=C or not', () async {
      // The command pins the C locale for sudo's messages. find must not
      // escape what is no ASCII there — it prints names raw into a pipe.
      Directory(box.host('home/pi/Müll')).createSync();
      File(box.host('home/pi/grün.txt')).writeAsBytesSync(const []);
      expect(await list('home/pi'), [('Müll', true), ('grün.txt', false)]);
    });

    test('symlinks: to a directory, to a file, dangling', () async {
      final links = box.setup('mkdir home/pi/target\n'
          ': > home/pi/target/inside.txt\n'
          ': > home/pi/file.txt\n'
          'ln -s target home/pi/to-dir\n'
          'ln -s file.txt home/pi/to-file\n'
          'ln -s nowhere home/pi/dangling\n'
          '[ -L home/pi/to-dir ] && [ -L home/pi/dangling ]');
      if (!links) {
        markTestSkipped('no symlinks on this platform');
        return;
      }
      // merged-usr: /bin, /lib and /sbin are such links — as files they could
      // not be entered.
      expect(await list('home/pi'), [
        ('target', true),
        ('to-dir', true),
        ('dangling', false),
        ('file.txt', false),
        ('to-file', false),
      ]);
      // Each of them is flagged as the link it is; what they point to is not.
      expect(await linkNames('home/pi'), ['dangling', 'to-dir', 'to-file']);
      // … and entering one lists what it points to.
      expect(await list('home/pi/to-dir'), [('inside.txt', false)]);
      expect(await linkNames('home/pi/to-dir'), isEmpty);
    });

    test('a missing directory: nothing listed, exit status and message',
        () async {
      final r = await box.exec(buildListDirCommand('${box.root}/home/nope'));
      expect(r.code, isNot(0));
      expect(r.out, isEmpty);
      expect(r.err, contains('No such file or directory'));
    });

    test('a rejected sudo password: nothing listed, sudo says so on stderr',
        () async {
      expect(box.setup(': > home/pi/file.txt'), isTrue);
      final r = await box.exec(buildListDirCommand('${box.root}/home/pi'),
          password: 'falsch');
      expect(r.code, isNot(0));
      expect(r.out, isEmpty);
      expect(isSudoPasswordFailure(r.err), isTrue);
    });

    test('a hostile path stays one argument', () async {
      // mkdir is on the sandbox PATH and the shell runs in the sandbox: a
      // name that broke out of its quotes would leave `pwned` there.
      expect(box.setup('mkdir "home/pi/a\'; mkdir pwned; \'"'), isTrue);
      expect(await list("home/pi/a'; mkdir pwned; '"), isEmpty);
      expect(box.ls('home/pi'), ["a'; mkdir pwned; '"]);
      expect(Directory(box.host('pwned')).existsSync(), isFalse);
    });
  }, skip: _needsBash);

  group('buildReadFileCommand in bash', () {
    late _Box box;
    setUp(() => box = _Box());
    tearDown(() => box.dispose());

    Future<_Run> read(String rel, {String password = 'sekret'}) => box.exec(
        buildReadFileCommand('${box.root}/$rel'),
        password: password);

    Uint8List decoded(_Run r) =>
        base64.decode(r.out.replaceAll(RegExp(r'\s'), ''));

    test('any bytes arrive intact', () async {
      final bytes = Uint8List.fromList(
          [...utf8.encode('grün\n'), 0, 1, 2, 0xff, 0xfe, 10]);
      File(box.host('home/pi/data.bin')).writeAsBytesSync(bytes);
      final r = await read('home/pi/data.bin');
      expect(r.code, 0, reason: r.err);
      expect(r.err, isEmpty);
      expect(decoded(r), bytes);
    });

    test('an empty file: exit 0 and no bytes', () async {
      File(box.host('home/pi/empty')).writeAsBytesSync(const []);
      final r = await read('home/pi/empty');
      expect(r.code, 0, reason: r.err);
      expect(decoded(r), isEmpty);
    });

    test('a file over the preview limit is cut at the limit', () async {
      File(box.host('home/pi/big'))
          .writeAsBytesSync(Uint8List(kFilePreviewLimit + 4096));
      final r = await read('home/pi/big');
      expect(r.code, 0, reason: r.err);
      expect(decoded(r), hasLength(kFilePreviewLimit));
    });

    test('a name with a space and a quote', () async {
      expect(box.setup('printf hallo > "home/pi/it\'s here.txt"'), isTrue);
      final r = await read("home/pi/it's here.txt");
      expect(r.code, 0, reason: r.err);
      expect(utf8.decode(decoded(r)), 'hallo');
    });

    test('a missing file: no output, exit status and message', () async {
      final r = await read('home/pi/nope');
      expect(r.code, isNot(0));
      expect(r.out, isEmpty);
      expect(r.err, contains('nope'));
    });

    test('a directory is not an empty file', () async {
      final r = await read('home/pi');
      expect(r.code, isNot(0));
      expect(r.out, isEmpty);
    });

    test('a rejected sudo password: no output, sudo says so on stderr',
        () async {
      File(box.host('home/pi/secret')).writeAsStringSync('geheim');
      final r = await read('home/pi/secret', password: 'falsch');
      expect(r.code, isNot(0));
      expect(r.out, isEmpty);
      expect(isSudoPasswordFailure(r.err), isTrue);
    });
  }, skip: _needsBash);

  group('buildUploadScript in bash', () {
    late _Box box;
    setUp(() => box = _Box());
    tearDown(() => box.dispose());

    Future<_Run> upload(String rel, String content) => box.script(
        buildUploadScript(
            path: '${box.root}/$rel',
            base64Content: base64.encode(utf8.encode(content))));

    String text(String rel) => File(box.host(rel)).readAsStringSync();

    final tmpName = RegExp(r'/\.pitool-up\.[A-Za-z0-9]{6}$');

    test('a new file: written, 0644, marker, nothing left behind', () async {
      final r = await upload('home/pi/notes.txt', 'neu\n');
      expect(r.code, 0, reason: r.err);
      expect(r.out.trim(), 'UPLOAD_OK');
      expect(text('home/pi/notes.txt'), 'neu\n');
      expect(box.ls('home/pi'), ['notes.txt']);
      // Nothing to take over: only the default mode is set.
      expect(box.calls, hasLength(1));
      expect(box.calls.single, startsWith('chmod 644 ${box.root}/home/pi/'));
      expect(tmpName.hasMatch(box.calls.single), isTrue);
    });

    test('an existing file keeps its owner and its mode', () async {
      File(box.host('home/pi/.env')).writeAsStringSync('ALT=1\n');
      expect(box.setup('chmod 600 home/pi/.env'), isTrue);
      final r = await upload('home/pi/.env', 'NEU=2\n');
      expect(r.code, 0, reason: r.err);
      expect(r.out.trim(), 'UPLOAD_OK');
      expect(text('home/pi/.env'), 'NEU=2\n');
      expect(box.ls('home/pi'), ['.env']);
      final dest = '${box.root}/home/pi/.env';
      final calls = box.calls;
      // No `chmod 644` in between: the temp file stays 0600 (mktemp) until it
      // has the owner and mode of the file it replaces — the new content of a
      // 0600 file is never readable for everyone.
      expect(calls, hasLength(2));
      final tmp = calls[0].substring('chown --reference=$dest '.length);
      expect(tmpName.hasMatch(tmp), isTrue);
      // Owner first: chown may clear mode bits that chmod then sets again.
      expect(calls, [
        'chown --reference=$dest $tmp',
        'chmod --reference=$dest $tmp',
      ]);
      // Git Bash only emulates modes; where they are real, 0600 must survive.
      if (!Platform.isWindows) {
        expect(File(box.host('home/pi/.env')).statSync().mode & 0x1ff, 0x180);
      }
    });

    test('a directory of that name: refused, nothing moved into it', () async {
      expect(box.setup('mkdir home/pi/backup\n: > home/pi/backup/keep.txt'),
          isTrue);
      final r = await upload('home/pi/backup', 'x');
      expect(r.code, isNot(0));
      expect(r.out, isNot(contains('UPLOAD_OK')));
      expect(r.out, contains('Verzeichnis'));
      expect(box.ls('home/pi'), ['backup']);
      expect(box.ls('home/pi/backup'), ['keep.txt']);
    });

    test('a symlink to a directory: refused as well', () async {
      final links = box.setup('mkdir home/pi/real\n'
          'ln -s real home/pi/link\n'
          '[ -L home/pi/link ]');
      if (!links) {
        markTestSkipped('no symlinks on this platform');
        return;
      }
      final r = await upload('home/pi/link', 'x');
      expect(r.code, isNot(0));
      expect(r.out, isNot(contains('UPLOAD_OK')));
      expect(box.ls('home/pi/real'), isEmpty);
    });

    test('a symlink to a file: the upload replaces the link, not its target',
        () async {
      final links = box.setup('printf alt > home/pi/real.txt\n'
          'ln -s real.txt home/pi/link.txt\n'
          '[ -L home/pi/link.txt ]');
      if (!links) {
        markTestSkipped('no symlinks on this platform');
        return;
      }
      final r = await upload('home/pi/link.txt', 'neu');
      expect(r.code, 0, reason: r.err);
      expect(r.out.trim(), 'UPLOAD_OK');
      // What the app's question says before it: the link is gone, and the
      // file it pointed to is as it was.
      expect(
          box.setup('[ ! -L home/pi/link.txt ] && '
              '[ "\$(cat home/pi/real.txt)" = alt ]'),
          isTrue);
      // Git Bash only emulates links, and a rename over one lands under the
      // emulation's own name; where they are real, the name now holds the
      // uploaded file itself.
      if (!Platform.isWindows) {
        expect(text('home/pi/link.txt'), 'neu');
        expect(box.ls('home/pi'), ['link.txt', 'real.txt']);
      }
    });

    test('a failure half-way: no temp file stays, the old file is untouched',
        () async {
      File(box.host('home/pi/notes.txt')).writeAsStringSync('alt\n');
      final r = await box.script(buildUploadScript(
          path: '${box.root}/home/pi/notes.txt', base64Content: '!!!'));
      expect(r.code, isNot(0));
      expect(r.out, isNot(contains('UPLOAD_OK')));
      expect(text('home/pi/notes.txt'), 'alt\n');
      expect(box.ls('home/pi'), ['notes.txt']);
    });

    test('a target directory that does not exist yet is created', () async {
      final r = await upload('var/backups/evcc/evcc-backup-1.tar.gz', 'tgz');
      expect(r.code, 0, reason: r.err);
      expect(text('var/backups/evcc/evcc-backup-1.tar.gz'), 'tgz');
    });

    test('a hostile name is one file, not a command', () async {
      final r = await upload("home/pi/a'; mkdir pwned; '.txt", 'x');
      expect(r.code, 0, reason: r.err);
      expect(box.ls('home/pi'), ["a'; mkdir pwned; '.txt"]);
      expect(Directory(box.host('pwned')).existsSync(), isFalse);
    });
  }, skip: _needsBash);

  group('buildDeleteCommand in bash', () {
    late _Box box;
    setUp(() => box = _Box());
    tearDown(() => box.dispose());

    Future<_Run> delete(String rel, {required bool isDir}) =>
        box.exec(buildDeleteCommand(path: '${box.root}/$rel', isDir: isDir));

    test('a file, and a directory with what is in it', () async {
      expect(
          box.setup('mkdir home/pi/dir\n'
              ': > home/pi/dir/inside.txt\n'
              ': > home/pi/file.txt\n'
              ': > home/pi/keep.txt'),
          isTrue);
      final file = await delete('home/pi/file.txt', isDir: false);
      expect(file.code, 0, reason: file.err);
      final dir = await delete('home/pi/dir', isDir: true);
      expect(dir.code, 0, reason: dir.err);
      expect(box.ls('home/pi'), ['keep.txt']);
    });

    test('a directory deleted as a file stays, with all that is in it',
        () async {
      expect(box.setup('mkdir home/pi/dir\n: > home/pi/dir/inside.txt'),
          isTrue);
      final r = await delete('home/pi/dir', isDir: false);
      expect(r.code, isNot(0));
      expect(box.ls('home/pi/dir'), ['inside.txt']);
    });

    // The files tab lists a symlink to a directory as a folder. The app
    // deletes it as the link it is (`rm -f`); with `-r` rm would not follow
    // it either.
    for (final isDir in [false, true]) {
      test(
          'a symlink to a directory, rm ${isDir ? '-rf' : '-f'}: only the '
          'link goes', () async {
        final links = box.setup('mkdir home/pi/target\n'
            ': > home/pi/target/inside.txt\n'
            'ln -s target home/pi/to-dir\n'
            '[ -L home/pi/to-dir ]');
        if (!links) {
          markTestSkipped('no symlinks on this platform');
          return;
        }
        final r = await delete('home/pi/to-dir', isDir: isDir);
        expect(r.code, 0, reason: r.err);
        expect(box.ls('home/pi'), ['target']);
        expect(box.ls('home/pi/target'), ['inside.txt']);
      });
    }

    test('a dangling symlink is removed like any other link', () async {
      final links = box.setup('ln -s nowhere home/pi/dangling\n'
          ': > home/pi/keep.txt\n'
          '[ -L home/pi/dangling ]');
      if (!links) {
        markTestSkipped('no symlinks on this platform');
        return;
      }
      final r = await delete('home/pi/dangling', isDir: false);
      expect(r.code, 0, reason: r.err);
      expect(box.ls('home/pi'), ['keep.txt']);
    });
  }, skip: _needsBash);

  group('path helpers', () {
    test('join respects an existing trailing slash', () {
      expect(joinRemotePath('/home/pi', 'x'), '/home/pi/x');
      expect(joinRemotePath('/', 'etc'), '/etc');
    });
    test('parent walks up and clamps at root', () {
      expect(parentRemotePath('/home/pi/backups'), '/home/pi');
      expect(parentRemotePath('/etc'), '/');
      expect(parentRemotePath('/'), '/');
    });
  });
}
