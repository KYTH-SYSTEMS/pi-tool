import 'package:evcc_updater/src/services/pi_connect.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isPiConnectCompatible (Bookworm+ = Debian 12+)', () {
    test('bookworm (12) and trixie (13) are compatible', () {
      expect(isPiConnectCompatible('PRETTY_NAME="Debian 12"\nVERSION_ID="12"'),
          isTrue);
      expect(isPiConnectCompatible('VERSION_ID="13"'), isTrue);
    });
    test('bullseye (11) and older are NOT compatible', () {
      expect(isPiConnectCompatible('VERSION_ID="11"'), isFalse);
      expect(isPiConnectCompatible('VERSION_ID="10"'), isFalse);
    });
    test('unknown / missing version → not compatible (fail-safe)', () {
      expect(isPiConnectCompatible(''), isFalse);
      expect(isPiConnectCompatible('PRETTY_NAME="Something"'), isFalse);
    });
  });

  group('commands set the user dbus env for over-SSH use', () {
    test('every rpi-connect command exports XDG_RUNTIME_DIR', () {
      for (final c in [
        piConnectStatusCommand,
        piConnectOnCommand,
        piConnectOffCommand,
        piConnectSigninCommand,
        piConnectSignoutCommand,
      ]) {
        expect(c, contains('XDG_RUNTIME_DIR=/run/user/'));
        expect(c, contains('rpi-connect'));
      }
    });
    test('install script installs lite + enables linger (headless)', () {
      expect(piConnectInstallScript, contains('rpi-connect-lite'));
      expect(piConnectInstallScript, contains('enable-linger'));
      expect(piConnectInstallScript, contains('PICONNECT_INSTALLED'));
    });
  });

  group('parseSigninUrl', () {
    test('extracts the verify URL from signin output', () {
      const out = 'Complete sign in by visiting '
          'https://connect.raspberrypi.com/verify/ABCD-1234\n';
      expect(parseSigninUrl(out), 'https://connect.raspberrypi.com/verify/ABCD-1234');
    });
    test('null when there is no URL', () {
      expect(parseSigninUrl('some error'), isNull);
    });
  });

  group('parsePiConnectStatus', () {
    test('not installed when the CLI is missing', () {
      final s = parsePiConnectStatus('rpi-connect: command not found');
      expect(s.installed, isFalse);
    });
    test('installed + signed in + on', () {
      final s = parsePiConnectStatus(
          'Signed in: yes\nScreen sharing: on\nRemote shell: on');
      expect(s.installed, isTrue);
      expect(s.signedIn, isTrue);
      expect(s.on, isTrue);
    });
    test('installed but not signed in', () {
      final s = parsePiConnectStatus('Signed in: no');
      expect(s.installed, isTrue);
      expect(s.signedIn, isFalse);
    });
  });
}
