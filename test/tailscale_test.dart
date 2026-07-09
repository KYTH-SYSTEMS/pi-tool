import 'package:evcc_updater/src/services/tailscale.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('scripts / commands', () {
    test('install uses the official script + marker', () {
      expect(tailscaleInstallScript, contains('tailscale.com/install.sh'));
      expect(tailscaleInstallScript, contains('TAILSCALE_INSTALLED'));
    });
    test('up runs detached (setsid) into a mktemp file, not a fixed /tmp path',
        () {
      expect(tailscaleUpScript, contains('tailscale up'));
      expect(tailscaleUpScript, contains('setsid'));
      expect(tailscaleUpScript, contains('mktemp')); // no predictable root temp
      expect(tailscaleUpScript, isNot(contains('/tmp/pi-tool-tailscale')));
    });
    test('down/logout run via sudo with LC_ALL=C (localized sudo detection)', () {
      expect(tailscaleDownCommand, contains('LC_ALL=C sudo -S'));
      expect(tailscaleLogoutCommand, contains('LC_ALL=C sudo -S'));
    });
  });

  group('parseTailscaleAuthUrl', () {
    test('extracts the login URL from up output', () {
      const out = 'To authenticate, visit:\n\n'
          'https://login.tailscale.com/a/abc123def\n';
      expect(parseTailscaleAuthUrl(out),
          'https://login.tailscale.com/a/abc123def');
    });
    test('null when already connected (no URL)', () {
      expect(parseTailscaleAuthUrl('Success.'), isNull);
    });
  });

  group('parseTailscaleIp', () {
    test('finds the 100.x tailnet IP', () {
      expect(parseTailscaleIp('100.101.102.103'), '100.101.102.103');
    });
    test('null when there is none', () {
      expect(parseTailscaleIp('192.168.1.5'), isNull);
    });
  });

  group('parseTailscaleStatus', () {
    test('up: installed + connected + IP', () {
      const out = '100.101.102.103  my-pi  linux  -\n100.101.102.103';
      final s = parseTailscaleStatus(out);
      expect(s.installed, isTrue);
      expect(s.up, isTrue);
      expect(s.ip, '100.101.102.103');
    });
    test('stopped: installed but not up', () {
      final s = parseTailscaleStatus('Tailscale is stopped.');
      expect(s.installed, isTrue);
      expect(s.up, isFalse);
      expect(s.ip, isNull);
    });
    test('not installed', () {
      final s = parseTailscaleStatus('tailscale: command not found');
      expect(s.installed, isFalse);
    });
  });
}
