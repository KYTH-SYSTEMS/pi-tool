import 'package:evcc_updater/src/commands.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildConsoleExec', () {
    test('a plain command runs as-is, no password needed', () {
      final r = buildConsoleExec('df -h');
      expect(r.exec, 'df -h');
      expect(r.sudo, isFalse);
    });

    test('leading sudo → -S -p so the password is read from stdin', () {
      final r = buildConsoleExec('sudo apt-get update');
      expect(r.sudo, isTrue);
      expect(r.exec, "sudo -S -p '' apt-get update");
    });

    test('trims and collapses spacing after sudo', () {
      final r = buildConsoleExec('  sudo   systemctl restart evcc  ');
      expect(r.sudo, isTrue);
      expect(r.exec, "sudo -S -p '' systemctl restart evcc");
    });

    test('sudo not at the very start is a normal command', () {
      final r = buildConsoleExec('echo sudo rules');
      expect(r.sudo, isFalse);
      expect(r.exec, 'echo sudo rules');
    });

    test('bare "sudo" is still treated as sudo (empty remainder)', () {
      final r = buildConsoleExec('sudo');
      expect(r.sudo, isTrue);
      expect(r.exec, "sudo -S -p ''");
    });
  });
}
