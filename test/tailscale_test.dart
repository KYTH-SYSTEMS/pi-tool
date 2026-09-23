import 'package:evcc_updater/src/services/pi_service.dart';
import 'package:evcc_updater/src/services/tailscale.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('scripts / commands', () {
    test('install uses the official script + marker', () {
      expect(tailscaleInstallScript, contains('tailscale.com/install.sh'));
      expect(tailscaleInstallScript, contains('TAILSCALE_INSTALLED'));
    });
    test('a failed download cannot pass as success', () {
      // `curl … | sh` returns sh's exit code: with curl missing or the download
      // failing, sh ran an empty script, exited 0 and the marker followed.
      expect(tailscaleInstallScript, contains('set -o pipefail'));
    });
    test('the marker only follows an actually installed binary', () {
      final s = tailscaleInstallScript;
      expect(s, contains('command -v tailscale'));
      expect(s.indexOf('command -v tailscale'),
          lessThan(s.indexOf('echo TAILSCALE_INSTALLED')));
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
    test('logout nimmt auch die Weiterleitungsdatei der App mit', () {
      // Nach `tailscale logout` sind die Routen weg — die Datei würde sonst bei
      // jedem Start weiter die IPv4-Weiterleitung einschalten, und die Karte
      // böte keinen Weg mehr, sie zu entfernen.
      expect(tailscaleLogoutCommand, contains('tailscale logout &&'));
      expect(tailscaleLogoutCommand, contains('rm -f $tailscaleForwardingConf'));
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
  // ---- Heimnetz freigeben (Subnet Router) ----

  group('parseLanSubnets', () {
    test('NetworkManager (Bookworm/Trixie): Netz der Default-Route', () {
      const out = '''
default via 192.168.178.1 dev eth0 proto dhcp src 192.168.178.64 metric 100
192.168.178.0/24 dev eth0 proto kernel scope link src 192.168.178.64 metric 100
''';
      expect(parseLanSubnets(out), ['192.168.178.0/24']);
    });

    test('dhcpcd (Buster/Bullseye) meldet die Netzroute als proto dhcp', () {
      const out = '''
default via 192.168.1.1 dev wlan0 proto dhcp src 192.168.1.23 metric 303
192.168.1.0/24 dev wlan0 proto dhcp scope link src 192.168.1.23 metric 303
''';
      expect(parseLanSubnets(out), ['192.168.1.0/24']);
    });

    test('Docker-, Tailscale- und Bridge-Netze zählen nicht zum Heimnetz', () {
      const out = '''
default via 192.168.178.1 dev eth0 proto dhcp src 192.168.178.125 metric 100
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1 linkdown
172.18.0.0/16 dev br-3f2a proto kernel scope link src 172.18.0.1
192.168.178.0/24 dev eth0 proto kernel scope link src 192.168.178.125 metric 100
''';
      expect(parseLanSubnets(out), ['192.168.178.0/24']);
    });

    test('LAN-Kabel und WLAN im selben Netz: einmal, nicht doppelt', () {
      const out = '''
default via 192.168.178.1 dev eth0 proto dhcp src 192.168.178.64 metric 100
default via 192.168.178.1 dev wlan0 proto dhcp src 192.168.178.65 metric 600
192.168.178.0/24 dev eth0 proto kernel scope link src 192.168.178.64 metric 100
192.168.178.0/24 dev wlan0 proto kernel scope link src 192.168.178.65 metric 600
''';
      expect(parseLanSubnets(out), ['192.168.178.0/24']);
    });

    test('ohne Default-Route: private Netze echter Schnittstellen', () {
      const out = '''
10.0.0.0/24 dev eth0 proto kernel scope link src 10.0.0.5
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1 linkdown
''';
      expect(parseLanSubnets(out), ['10.0.0.0/24']);
    });

    test('öffentliche, Link-Local- und CGNAT-Netze werden nie angeboten', () {
      const out = '''
default via 203.0.113.1 dev eth0
203.0.113.0/24 dev eth0 proto kernel scope link src 203.0.113.7
169.254.0.0/16 dev eth0 scope link metric 1000
100.64.0.0/10 dev eth0 proto kernel scope link src 100.64.0.9
''';
      expect(parseLanSubnets(out), isEmpty);
    });

    test('Müll, leere Ausgabe und nicht kanonische Präfixe: nichts', () {
      expect(parseLanSubnets(''), isEmpty);
      expect(parseLanSubnets('bash: ip: command not found'), isEmpty);
      expect(
          parseLanSubnets('default via 192.168.1.1 dev eth0\n'
              '192.168.1.7/24 dev eth0 scope link\n'),
          isEmpty);
    });
  });

  group('isPrivateIpv4Prefix', () {
    test('die drei RFC-1918-Bereiche', () {
      expect(isPrivateIpv4Prefix('10.1.0.0/16'), isTrue);
      expect(isPrivateIpv4Prefix('172.16.0.0/12'), isTrue);
      expect(isPrivateIpv4Prefix('172.31.5.0/24'), isTrue);
      expect(isPrivateIpv4Prefix('192.168.178.0/24'), isTrue);
    });
    test('außerhalb, zu breit oder kaputt', () {
      expect(isPrivateIpv4Prefix('172.32.0.0/16'), isFalse);
      expect(isPrivateIpv4Prefix('192.168.0.0/15'), isFalse); // breiter als /16
      expect(isPrivateIpv4Prefix('8.8.8.0/24'), isFalse);
      expect(isPrivateIpv4Prefix('192.168.178.0'), isFalse);
      expect(isPrivateIpv4Prefix('192.168.178.1/24'), isFalse); // Host-Bits
      expect(isPrivateIpv4Prefix('192.168.300.0/24'), isFalse);
      expect(isPrivateIpv4Prefix("192.168.1.0/24'; reboot; '"), isFalse);
    });
  });

  group('parseAdvertisedRoutes (tailscale debug prefs)', () {
    test('liest AdvertiseRoutes, Exit-Routen fallen heraus', () {
      const out = '{\n\t"ControlURL": "https://controlplane.tailscale.com",\n'
          '\t"AdvertiseRoutes": [\n\t\t"192.168.178.0/24",\n'
          '\t\t"0.0.0.0/0",\n\t\t"::/0"\n\t],\n\t"RouteAll": false\n}\n';
      expect(parseAdvertisedRoutes(out), ['192.168.178.0/24']);
    });
    test('null und [] heißen: nichts angeboten', () {
      expect(parseAdvertisedRoutes('{"AdvertiseRoutes": null}'), isEmpty);
      expect(parseAdvertisedRoutes('{"AdvertiseRoutes": []}'), isEmpty);
      expect(parseAdvertisedRoutes('{"RouteAll": true}'), isEmpty);
    });
    test('nicht lesbar (Fehler, kein JSON): null = unbekannt', () {
      expect(parseAdvertisedRoutes(''), isNull);
      expect(
          parseAdvertisedRoutes('Access denied: prefs access denied'), isNull);
    });
    test('eine Warnzeile vor dem JSON stört nicht', () {
      const out = 'Warning: client version "1.90.1" != tailscaled server '
          'version "1.90.2"\n{"AdvertiseRoutes": ["10.0.0.0/24"]}';
      expect(parseAdvertisedRoutes(out), ['10.0.0.0/24']);
    });
  });

  group('parseApprovedRoutes (tailscale status --json --peers=false)', () {
    const running = '''
{
  "BackendState": "Running",
  "TailscaleIPs": ["100.101.102.103", "fd7a:115c:a1e0::1234"],
  "Self": {
    "HostName": "raspberrypi",
    "DNSName": "evcc-pi.tail1234.ts.net.",
    "TailscaleIPs": ["100.101.102.103", "fd7a:115c:a1e0::1234"],
    "AllowedIPs": ["100.101.102.103/32", "fd7a:115c:a1e0::1234/128",
                   "192.168.178.0/24", "0.0.0.0/0", "::/0"],
    "PrimaryRoutes": ["192.168.178.0/24"]
  }
}''';

    test('freigegeben = AllowedIPs ohne eigene Adressen und Exit-Routen', () {
      expect(parseApprovedRoutes(running), ['192.168.178.0/24']);
    });
    test('noch nicht freigegeben: AllowedIPs trägt nur die eigenen Adressen',
        () {
      const out = '{"BackendState": "Running", "Self": {"TailscaleIPs": '
          '["100.64.0.5"], "AllowedIPs": ["100.64.0.5/32"]}}';
      expect(parseApprovedRoutes(out), isEmpty);
    });
    test('nicht Running oder kaputt: null', () {
      expect(parseApprovedRoutes('{"BackendState": "NeedsLogin", "Self": {}}'),
          isNull);
      expect(parseApprovedRoutes(''), isNull);
    });
    test('Gerätename für die Konsole: erstes Label des MagicDNS-Namens', () {
      expect(parseTailnetMachineName(running), 'evcc-pi');
      expect(
          parseTailnetMachineName(
              '{"BackendState": "Running", "Self": {"HostName": "zirkel"}}'),
          'zirkel');
      expect(parseTailnetMachineName('kaputt'), isNull);
    });
  });

  group('SubnetRoutes.share', () {
    test('kein Heimnetz erkannt: nicht verfügbar', () {
      expect(const SubnetRoutes().share, RouteShare.unavailable);
    });
    test('Heimnetz bekannt, nicht angeboten: aus', () {
      expect(const SubnetRoutes(lan: ['192.168.178.0/24']).share,
          RouteShare.off);
    });
    test('angeboten, aber nicht freigegeben: ausstehend', () {
      expect(
          const SubnetRoutes(
                  lan: ['192.168.178.0/24'], advertised: ['192.168.178.0/24'])
              .share,
          RouteShare.pending);
    });
    test('angeboten und freigegeben: aktiv', () {
      expect(
          const SubnetRoutes(
              lan: ['192.168.178.0/24'],
              advertised: ['192.168.178.0/24'],
              approved: ['192.168.178.0/24']).share,
          RouteShare.active);
    });
    test('fremde, von Hand gesetzte Routen zählen nicht als Heimnetz', () {
      const r = SubnetRoutes(
          lan: ['192.168.178.0/24'],
          advertised: ['10.8.0.0/24'],
          approved: ['10.8.0.0/24']);
      expect(r.share, RouteShare.off);
      expect(r.sharedLan, isEmpty);
    });
    test('übersteht die JSON-Runde (gemerkter Stand der Karte)', () {
      const r = SubnetRoutes(
          lan: ['192.168.178.0/24'],
          advertised: ['192.168.178.0/24'],
          machine: 'evcc-pi');
      final back = SubnetRoutes.fromJson(r.toJson());
      expect(back.share, RouteShare.pending);
      expect(back.machine, 'evcc-pi');
      expect(back.lan, ['192.168.178.0/24']);
    });
    test('ServiceStatus trägt den Zustand durch toJson/fromJson/copyWith', () {
      const s = ServiceStatus(
          id: 'tailscale',
          name: 'Tailscale',
          installed: true,
          active: true,
          version: '100.64.0.5',
          routes: SubnetRoutes(
              lan: ['192.168.178.0/24'],
              advertised: ['192.168.178.0/24'],
              approved: ['192.168.178.0/24']));
      final back = ServiceStatus.fromJson(s.toJson());
      expect(back.routes?.share, RouteShare.active);
      expect(ServiceStatus.fromJson(const {'id': 'x'}).routes, isNull);
      expect(
          s.copyWith(updateAvailable: true).routes?.share, RouteShare.active);
    });
  });

  group('Routen zusammenführen', () {
    test('freigeben ergänzt, statt fremde Routen zu überschreiben', () {
      expect(routesWithLan(['10.8.0.0/24'], ['192.168.178.0/24']),
          ['10.8.0.0/24', '192.168.178.0/24']);
      expect(routesWithLan(['192.168.178.0/24'], ['192.168.178.0/24']),
          ['192.168.178.0/24']);
    });
    test('beenden nimmt nur das Heimnetz heraus', () {
      expect(
          routesWithoutLan(
              ['10.8.0.0/24', '192.168.178.0/24'], ['192.168.178.0/24']),
          ['10.8.0.0/24']);
      expect(routesWithoutLan(['192.168.178.0/24'], ['192.168.178.0/24']),
          isEmpty);
    });
  });

  group('Skripte: Heimnetz freigeben/beenden', () {
    test('freigeben: IPv4-Weiterleitung dauerhaft, dann tailscale set, Marker',
        () {
      final s = buildTailscaleAdvertiseScript(['192.168.178.0/24']);
      expect(s, contains('set -e'));
      expect(s, contains('net.ipv4.ip_forward = 1'));
      expect(s, contains(tailscaleForwardingConf));
      expect(
          s, contains("tailscale set --advertise-routes='192.168.178.0/24'"));
      // `set` statt `up`: `up` verlangt, dass jede gesetzte Option erneut
      // genannt wird, und würde sonst scheitern oder Einstellungen verwerfen.
      expect(s, isNot(contains('tailscale up')));
      expect(s.indexOf('sysctl -p'), lessThan(s.indexOf('tailscale set')));
      expect(s.indexOf('tailscale set'),
          lessThan(s.indexOf('echo $tailscaleRoutesMarker')));
      // IPv6-Weiterleitung bewusst NICHT: für IPv4-Routen unnötig.
      expect(s, isNot(contains('ipv6')));
    });

    test('mehrere Netze kommagetrennt in EINEM gequoteten Argument', () {
      final s =
          buildTailscaleAdvertiseScript(['10.8.0.0/24', '192.168.178.0/24']);
      expect(
          s, contains("--advertise-routes='10.8.0.0/24,192.168.178.0/24'"));
    });

    test('leere Liste nimmt alle Routen und die Weiterleitungsdatei weg', () {
      final s = buildTailscaleAdvertiseScript(const []);
      expect(s, contains("tailscale set --advertise-routes=''"));
      expect(s, contains('rm -f $tailscaleForwardingConf'));
      expect(s, isNot(contains('net.ipv4.ip_forward = 1')));
      // Laufzeitwert bleibt: Docker & Co. brauchen die Weiterleitung womöglich.
      expect(s, isNot(contains('ip_forward=0')));
      expect(s, contains('echo $tailscaleRoutesMarker'));
    });

    test('bleiben fremde Routen übrig, bleibt auch die Weiterleitung', () {
      final s = buildTailscaleAdvertiseScript(['10.8.0.0/24']);
      expect(s, isNot(contains('rm -f')));
      expect(s, contains('net.ipv4.ip_forward = 1'));
    });

    test('nur Präfix-förmige Einträge landen im Root-Skript', () {
      expect(() => buildTailscaleAdvertiseScript(["1.2.3.0/24'; reboot; '"]),
          throwsArgumentError);
      expect(() => buildTailscaleAdvertiseScript([r'$(reboot)/24']),
          throwsArgumentError);
    });

    test('von Hand gesetzte IPv6- oder öffentliche Routen gehen unverändert mit',
        () {
      // Früher warf das: freigeben UND beenden waren auf solchen Pis blockiert.
      final s = buildTailscaleAdvertiseScript(
          ['fd00::/64', '203.0.113.0/24'], mine: const []);
      expect(s, contains("--advertise-routes='fd00::/64,203.0.113.0/24'"));
    });

    test('die Datei merkt sich, welche Routen von der App stammen', () {
      final s = buildTailscaleAdvertiseScript(
          ['10.8.0.0/24', '192.168.178.0/24'],
          mine: ['192.168.178.0/24']);
      expect(s, contains("'# routes=192.168.178.0/24'"));
    });

    test('ohne Routen, aber mit Exit-Node: Weiterleitung bleibt', () {
      final s = buildTailscaleAdvertiseScript(const [], keepForwarding: true);
      expect(s, contains("tailscale set --advertise-routes=''"));
      expect(s, isNot(contains('rm -f')));
      expect(s, contains('net.ipv4.ip_forward = 1'));
    });

    test('eigene Routen in der Datei: nur private IPv4-Netze', () {
      expect(() => buildTailscaleAdvertiseScript(['fd00::/64'], mine: ['fd00::/64']),
          throwsArgumentError);
    });
  });

  group('Merker der App und Exit-Node', () {
    test('parseAppRoutes liest die Routen aus der eigenen sysctl-Datei', () {
      const file = '# Pi-Tool: Tailscale-Heimnetz (Subnet Router)\n'
          '# routes=192.168.178.0/24,10.0.0.0/24\n'
          'net.ipv4.ip_forward = 1\n';
      expect(parseAppRoutes(file), ['192.168.178.0/24', '10.0.0.0/24']);
      expect(parseAppRoutes(''), isEmpty); // Datei fehlt
      // Ältere Datei ohne Merker oder Unfug darin: nichts übernehmen.
      expect(parseAppRoutes('net.ipv4.ip_forward = 1'), isEmpty);
      expect(parseAppRoutes('# routes=1.2.3.4;reboot'), isEmpty);
    });

    test('parseAdvertisesExitNode', () {
      expect(parseAdvertisesExitNode('{"AdvertiseRoutes": ["0.0.0.0/0", "::/0"]}'),
          isTrue);
      expect(parseAdvertisesExitNode('{"AdvertiseRoutes": ["192.168.1.0/24"]}'),
          isFalse);
      expect(parseAdvertisesExitNode(''), isFalse);
    });

    test('neues Heimnetz: die alte, von der App gesetzte Route bleibt sichtbar '
        'und beendbar', () {
      // Router getauscht: der Pi hängt jetzt in 192.168.1.0/24, angeboten ist
      // noch das alte Netz. Ohne Merker galt die alte Route als „von Hand" —
      // unsichtbar und aus der App nicht mehr zu beenden.
      const r = SubnetRoutes(
          lan: ['192.168.1.0/24'],
          advertised: ['192.168.178.0/24'],
          approved: ['192.168.178.0/24'],
          mine: ['192.168.178.0/24']);
      expect(r.sharedLan, ['192.168.178.0/24']);
      expect(r.share, RouteShare.active);
      expect(r.lanAdvertised, isFalse); // das neue Netz kann dazu
    });

    test('lanAdvertised', () {
      expect(
          const SubnetRoutes(
                  lan: ['192.168.178.0/24'], advertised: ['192.168.178.0/24'])
              .lanAdvertised,
          isTrue);
      expect(const SubnetRoutes().lanAdvertised, isFalse);
    });

    test('mine übersteht die JSON-Runde', () {
      const r = SubnetRoutes(mine: ['192.168.178.0/24']);
      expect(SubnetRoutes.fromJson(r.toJson()).mine, ['192.168.178.0/24']);
    });
  });

  group('Neu anmelden trotz gesetzter Routen', () {
    // Ein abgelaufener Schlüssel (NeedsLogin) plus eine gesetzte Route: Dann
    // verweigert ein nacktes `tailscale up` und nennt die Flags, die es sehen
    // will. Ohne diese Wiederholung liefe „Verbinden" nach Monaten ins Leere.
    const refused = '''
Error: changing settings via 'tailscale up' requires mentioning all
non-default flags. To proceed, either re-run your command with --reset or
use the command below to explicitly mention the current value of
all non-default settings:

	tailscale up --advertise-routes=192.168.178.0/24 --operator=pi
''';

    test('liest die vorgeschlagenen Flags aus', () {
      expect(parseTailscaleUpRestateFlags(refused),
          ['--advertise-routes=192.168.178.0/24', '--operator=pi']);
    });
    test('Unterstriche in Werten (Benutzer-/Hostnamen) sind erlaubt', () {
      expect(
          parseTailscaleUpRestateFlags(
              refused.replaceFirst('--operator=pi', '--operator=pi_admin')),
          ['--advertise-routes=192.168.178.0/24', '--operator=pi_admin']);
    });
    test('Schalter ohne Wert gehen auch durch', () {
      expect(
          parseTailscaleUpRestateFlags(refused.replaceFirst(
              '--operator=pi', '--accept-dns=false --ssh')),
          [
            '--advertise-routes=192.168.178.0/24',
            '--accept-dns=false',
            '--ssh'
          ]);
    });
    test('keine Weigerung: null', () {
      expect(
          parseTailscaleUpRestateFlags('To authenticate, visit:\n\n'
              'https://login.tailscale.com/a/abc'),
          isNull);
    });
    test('alles, was nicht wie ein schlichtes Flag aussieht: null', () {
      expect(
          parseTailscaleUpRestateFlags(refused.replaceFirst(
              '--operator=pi', '--hostname="mein pi"')),
          isNull);
      expect(
          parseTailscaleUpRestateFlags(
              refused.replaceFirst('--operator=pi', '--operator=pi;reboot')),
          isNull);
      expect(
          parseTailscaleUpRestateFlags(
              refused.replaceFirst('--operator=pi', r'--operator=$(id)')),
          isNull);
    });
    test('das Up-Skript nimmt die Flags einzeln gequotet mit', () {
      final s = buildTailscaleUpScript(
          ['--advertise-routes=192.168.178.0/24', '--operator=pi']);
      expect(
          s,
          contains("setsid tailscale up '--advertise-routes=192.168.178.0/24' "
              "'--operator=pi' >"));
      expect(tailscaleUpScript, contains('setsid tailscale up >'));
    });
  });
}
