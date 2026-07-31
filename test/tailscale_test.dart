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

  group('isTailnetHost', () {
    test('numeric CGNAT range (100.x) is a tailnet host', () {
      expect(isTailnetHost('100.64.1.5'), isTrue);
      expect(isTailnetHost('100.100.100.100'), isTrue);
    });
    test('MagicDNS names (*.ts.net) are tailnet hosts', () {
      expect(isTailnetHost('raspberrypi.tail1234.ts.net'), isTrue);
      expect(isTailnetHost('PI.TAIL1234.TS.NET'), isTrue); // case-insensitive
    });
    test('LAN IPs and plain hostnames are NOT tailnet hosts', () {
      expect(isTailnetHost('192.168.178.64'), isFalse);
      expect(isTailnetHost('10.0.0.5'), isFalse);
      expect(isTailnetHost('raspberrypi.local'), isFalse);
      expect(isTailnetHost('100potatoes.example.com'), isFalse); // not 100.
      expect(isTailnetHost(''), isFalse);
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

  group('remoteAccessCandidates', () {
    test('beide bekannt: Heim-Adresse zuerst (schnell, ohne VPN)', () {
      expect(
        remoteAccessCandidates(
            lanHost: '192.168.178.125', tailscaleIp: '100.64.0.5', lastGood: ''),
        ['192.168.178.125', '100.64.0.5'],
      );
    });

    test('zuletzt erfolgreich war das Tailnet: dann das zuerst', () {
      expect(
        remoteAccessCandidates(
            lanHost: '192.168.178.125',
            tailscaleIp: '100.64.0.5',
            lastGood: '100.64.0.5'),
        ['100.64.0.5', '192.168.178.125'],
      );
    });

    test('veralteter lastGood (Pi hat eine neue LAN-IP) wird ignoriert', () {
      expect(
        remoteAccessCandidates(
            lanHost: '192.168.178.125',
            tailscaleIp: '100.64.0.5',
            lastGood: '192.168.178.99'),
        ['192.168.178.125', '100.64.0.5'],
      );
    });

    test('nur eine Adresse bekannt: kein Rückfall, also keine Wartezeit', () {
      expect(
        remoteAccessCandidates(
            lanHost: '192.168.178.125', tailscaleIp: '', lastGood: ''),
        ['192.168.178.125'],
      );
      expect(
        remoteAccessCandidates(
            lanHost: '', tailscaleIp: '100.64.0.5', lastGood: ''),
        ['100.64.0.5'],
      );
    });

    test('nichts bekannt: leer', () {
      expect(
        remoteAccessCandidates(lanHost: '  ', tailscaleIp: '', lastGood: ''),
        isEmpty,
      );
    });
  });
}
