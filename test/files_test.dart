import 'package:evcc_updater/src/files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('commands', () {
    test('list + read are sudo and shell-quoted', () {
      expect(buildListDirCommand('/etc'), "sudo -S -p '' ls -1Ap '/etc' 2>&1");
      // Size-capped read (head -c) so a huge file can't OOM the app.
      expect(buildReadFileCommand('/etc/evcc.yaml'),
          contains("head -c 524288 '/etc/evcc.yaml'"));
      expect(buildReadFileCommand('/etc/evcc.yaml'), endsWith('| base64'));
      expect(buildListDirCommand("/x';reboot;'"), contains(r"'\''"));
    });

    test('upload: base64-decodes atomically into the target dir + marker', () {
      final s = buildUploadScript(path: '/etc/evcc.yaml', base64Content: 'aGk=');
      expect(s, contains('base64 -d'));
      expect(s, contains('mv -f')); // atomic rename over the target
      expect(s, contains("'/etc/evcc.yaml'"));
      expect(s, contains('aGk=')); // the payload
      expect(s, contains('UPLOAD_OK')); // success marker the caller verifies
    });

    test('upload: hostile path + content are single-quoted (no injection)', () {
      final s = buildUploadScript(
          path: "/x';reboot;'", base64Content: "YQ==';reboot;'");
      expect(s, contains(r"'\''")); // escaped, not executable
      expect(s, isNot(contains('\n;reboot;')));
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
    test('dirs first (trailing /), then files, alphabetical; skips errors', () {
      const out = 'etc/\n'
          'zeta.txt\n'
          'apps/\n'
          'alpha.conf\n'
          'ls: cannot access foo: Permission denied\n';
      final e = parseDirListing(out);
      expect(e.map((x) => x.name).toList(), ['apps', 'etc', 'alpha.conf', 'zeta.txt']);
      expect(e.first.isDir, isTrue);
      expect(e.last.isDir, isFalse);
    });
    test('empty / all-error listing → empty', () {
      expect(parseDirListing(''), isEmpty);
      expect(parseDirListing('ls: /x: No such file or directory'), isEmpty);
    });
  });

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
