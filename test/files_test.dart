import 'package:evcc_updater/src/files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('commands', () {
    test('list + read are sudo and shell-quoted', () {
      expect(buildListDirCommand('/etc'), "sudo -S -p '' ls -1Ap '/etc' 2>&1");
      expect(buildReadFileCommand('/etc/evcc.yaml'),
          "sudo -S -p '' base64 '/etc/evcc.yaml' 2>&1");
      expect(buildListDirCommand("/x';reboot;'"), contains(r"'\''"));
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
