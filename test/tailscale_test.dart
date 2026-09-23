import 'dart:convert';
import 'dart:io';

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

  // ---- Deinstallieren ----

  group('isTailnetClient (SSH_CONNECTION)', () {
    test('Handy im Tailnet, Pi über seine LAN-Adresse (eigene Subnet-Route)',
        () {
      // Kommt über tailscale0 mit 100.x-Absender an: isTailnetHost(host)
      // allein sähe nur die LAN-Adresse.
      expect(isTailnetClient('100.101.102.103 51234 192.168.178.64 22'),
          isTrue);
    });
    test('Pi über seine Tailnet-Adresse verbunden', () {
      expect(isTailnetClient('192.168.178.20 51234 100.64.0.5 22'), isTrue);
    });
    test('Grenzen von 100.64.0.0/10', () {
      expect(isTailnetClient('100.64.0.0 1 192.168.1.2 22'), isTrue);
      expect(isTailnetClient('100.127.255.255 1 192.168.1.2 22'), isTrue);
      expect(isTailnetClient('100.63.255.255 1 192.168.1.2 22'), isFalse);
      expect(isTailnetClient('100.128.0.1 1 192.168.1.2 22'), isFalse);
    });
    test('Tailscale-IPv6 (fd7a:115c:a1e0::/48), auch groß geschrieben', () {
      expect(isTailnetClient('fd7a:115c:a1e0::1234 51234 fd00::64 22'), isTrue);
      expect(isTailnetClient('fd00::20 51234 FD7A:115C:A1E0:AB12::5 22'),
          isTrue);
      expect(isTailnetClient('fd7a:115c:a1e1::1 51234 fd00::64 22'), isFalse);
    });
    test('IPv4-mapped-Adressen zählen wie IPv4', () {
      expect(isTailnetClient('::ffff:100.64.1.2 51234 ::ffff:192.168.1.2 22'),
          isTrue);
      expect(isTailnetClient('::ffff:192.168.1.5 51234 ::ffff:192.168.1.2 22'),
          isFalse);
    });
    test('Heimnetz, Link-Local mit Zone, leer und Unfug: nein', () {
      expect(isTailnetClient('192.168.178.20 51234 192.168.178.64 22'),
          isFalse);
      expect(isTailnetClient('fe80::1%eth0 51234 fe80::2%eth0 22'), isFalse);
      expect(isTailnetClient(''), isFalse);
      expect(isTailnetClient('  \n'), isFalse);
      expect(isTailnetClient('100.64.x.1 1 2 3'), isFalse);
      // Nur Client- und Server-Adresse zählen, nicht die Ports.
      expect(isTailnetClient('192.168.1.2 100 192.168.1.3 64'), isFalse);
    });
  });

  group('buildTailscaleUninstallScript', () {
    final keep = buildTailscaleUninstallScript(purge: false);
    final purge = buildTailscaleUninstallScript(purge: true);
    final both = {'behalten': keep, 'purge': purge};

    // Executable lines only — comments may talk about anything.
    List<String> code(String s) => [
          for (final l in s.split('\n'))
            if (l.trim().isNotEmpty && !l.trim().startsWith('#')) l.trim(),
        ];
    int firstIndex(String s, List<String> needles) => needles
        .map(s.indexOf)
        .where((i) => i >= 0)
        .reduce((a, b) => a < b ? a : b);
    // Everything that changes the Pi.
    const changes = [
      'tailscale logout',
      'systemctl disable',
      'systemctl enable',
      'systemctl stop',
      '"\$act" -y',
      'rm -f',
      'rm -rf',
      'apt-key',
    ];
    // The real (not simulated) apt run.
    int aptRun(String s) => s.indexOf('"\$act" -y');

    test('Marker ist die letzte Zeile und kommt genau einmal vor', () {
      expect(tailscaleRemovedMarker, 'TAILSCALE_REMOVED_OK');
      // Kein Teilstring des Install-Markers (und umgekehrt).
      expect(tailscaleRemovedMarker, isNot(contains('INSTALL')));
      for (final e in both.entries) {
        final s = e.value;
        expect(s.trimRight().split('\n').last,
            'echo $tailscaleRemovedMarker', reason: e.key);
        expect(tailscaleRemovedMarker.allMatches(s), hasLength(1),
            reason: e.key);
      }
    });

    test('Kopf: set -e, nicht-interaktiv, LC_ALL=C', () {
      for (final e in both.entries) {
        final c = code(e.value);
        expect(c.first, 'set -e', reason: e.key);
        expect(c, contains('export DEBIAN_FRONTEND=noninteractive'),
            reason: e.key);
        expect(c, contains('export LC_ALL=C'), reason: e.key);
      }
    });

    test('Skript kommt über stdin: kein exec, kein Heredoc', () {
      // `exec </dev/null` nähme bash den Rest des Skripts weg: stiller
      // Abbruch mitten im Rückbau, ohne Marker.
      for (final e in both.entries) {
        expect(e.value, isNot(matches(RegExp(r'\bexec\b'))), reason: e.key);
        expect(e.value, isNot(contains('<<')), reason: e.key);
      }
    });

    test('jedes apt-get: Lock-Timeout, kein Pty, stdin zu', () {
      for (final e in both.entries) {
        final apt = code(e.value).where((l) => l.contains('apt-get '));
        expect(apt, isNotEmpty, reason: e.key);
        for (final l in apt) {
          expect(l, contains('-o DPkg::Lock::Timeout=120'), reason: l);
          expect(l, contains('-o Dpkg::Use-Pty=0'), reason: l);
          expect(l, contains('</dev/null'), reason: l);
        }
      }
    });

    test('dpkg-query, systemctl und tailscale lesen nie das Skript-stdin', () {
      for (final e in both.entries) {
        // Lines that run them (a `command -v` existence check does not).
        for (final l in code(e.value).where((l) =>
            RegExp(r'(dpkg-query|systemctl|apt-key|tailscale logout)')
                .hasMatch(l.replaceAll(RegExp(r'command -v \S+'), '')))) {
          expect(l, contains('</dev/null'), reason: l);
        }
      }
    });

    test('nie autoremove, nie fremde oder geteilte Pakete', () {
      for (final e in both.entries) {
        final s = e.value;
        expect(s, isNot(contains('autoremove')), reason: e.key);
        expect(
            s,
            isNot(matches(RegExp(
                r'(curl|gnupg|iptables|iproute2|ca-certificates|docker)'))),
            reason: e.key);
      }
      expect(keep, contains('pkgs=tailscale'));
      expect(keep, isNot(contains('for p in ')));
      expect(purge, contains('for p in tailscale tailscale-archive-keyring; do'));
    });

    test('Wächter kommen vor jeder Änderung und enden mit exit 3', () {
      for (final e in both.entries) {
        final s = e.value;
        final first = firstIndex(s, changes);
        expect(s.lastIndexOf('UNINSTALL_REFUSED'), lessThan(first),
            reason: e.key);
        expect(s.lastIndexOf('exit 3'), lessThan(first), reason: e.key);
        final refusals = code(s).where((l) => l.contains('UNINSTALL_REFUSED'));
        // Tailnet-Sitzung, fremdes Binary, hold, Probelauf gescheitert,
        // apt nähme mehr mit.
        expect(refusals, hasLength(5), reason: e.key);
        for (final l in refusals) {
          expect(l, startsWith('echo "UNINSTALL_REFUSED: '), reason: l);
        }
        // Each refusal is followed directly by its exit 3.
        final lines = code(s);
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].contains('UNINSTALL_REFUSED')) {
            expect(lines[i + 1], 'exit 3', reason: lines[i]);
          }
        }
      }
    });

    test('Wächter 1: Sitzung über das Tailnet (SSH_CONNECTION der Vorfahren)',
        () {
      // sudo (env_reset) versteckt SSH_CONNECTION — die Kopie des Aufrufers
      // steht aber in der Umgebung eines Vorfahren.
      for (final e in both.entries) {
        final s = e.value;
        expect(s, contains('SSH_CONNECTION'), reason: e.key);
        expect(s, contains('/proc/'), reason: e.key);
        expect(s, contains(r'p=$PPID'), reason: e.key);
      }
    });

    test('Wächter 1 deckt in der Shell dieselben Adressen ab wie Dart', () {
      // Die case-Muster als RegExp nachgebaut und gegen isTailnetClient
      // gehalten: jede zweite Oktette 0–255, dazu die IPv6-Präfixe.
      final line = code(keep).firstWhere((l) => l.startsWith('100.6'));
      final globs = line.substring(0, line.lastIndexOf(')')).split('|');
      final shellMatch = RegExp('^(?:${globs.map(_globToRegex).join('|')})\$');
      for (var o = 0; o < 256; o++) {
        final ip = '100.$o.1.2';
        expect(shellMatch.hasMatch(ip), isTailnetClient('$ip 1 10.0.0.1 22'),
            reason: ip);
      }
      for (final ip in [
        '10.100.64.1',
        '1100.64.0.1',
        'fd7a:115c:a1e0::1',
        'FD7A:115C:A1E0:1::1',
        'fd7a:115c:a1e1::1',
        'fd00::1',
      ]) {
        expect(shellMatch.hasMatch(ip), isTailnetClient('$ip 1 10.0.0.1 22'),
            reason: ip);
      }
      expect(code(keep), contains(r'case "${ip#::ffff:}" in'));
    });

    test('Wächter 1: eigener Text, auch für die Heimnetz-Adresse über die '
        'freigegebene Route', () {
      // Wer schon über die Heimnetz-Adresse verbunden ist, bekäme sonst den
      // Rat, über die Heimnetz-Adresse zu verbinden.
      expect(
          tailscaleSessionRefusal,
          'Die Verbindung zum Pi läuft über Tailscale (auch unter der '
          'Heimnetz-Adresse, wenn der Pi das Heimnetz freigibt) und würde '
          'beim Entfernen abreißen – bitte im Heimnetz mit ausgeschaltetem '
          'Tailscale auf dem Handy erneut versuchen.');
      // Steht in "…" im Skript: nichts, was die Shell dort auswertet.
      expect(tailscaleSessionRefusal, isNot(matches(RegExp(r'["$`\\\n!]'))));
      for (final e in both.entries) {
        expect(code(e.value),
            contains('echo "UNINSTALL_REFUSED: $tailscaleSessionRefusal"'),
            reason: e.key);
        expect(e.value, isNot(contains('über die Heimnetz-Adresse verbinden')),
            reason: e.key);
      }
    });

    test('Wächter 2: Tailscale, das nicht dem Paket gehört (static, snap)', () {
      for (final e in both.entries) {
        final s = e.value;
        expect(s, contains('dpkg-query -S'), reason: e.key);
        for (final p in [
          '/usr/local/bin/tailscale',
          '/usr/bin/tailscale',
          '/snap/bin/tailscale',
          'command -v tailscale',
        ]) {
          expect(s, contains(p), reason: '${e.key}: $p');
        }
        expect(s, contains('readlink -f'), reason: e.key); // usrmerge
      }
    });

    test('Wächter 3: apt darf nichts anderes mitnehmen (Simulation)', () {
      for (final e in both.entries) {
        final s = e.value;
        final sim = s.indexOf('apt-get -s');
        expect(sim, greaterThanOrEqualTo(0), reason: e.key);
        expect(sim, lessThan(firstIndex(s, changes)), reason: e.key);
      }
    });

    // Vor ts_apt_failed/abmelden: ein Purge meldete den Pi sonst ab und
    // scheiterte erst danach an apt.
    int removalStart(String s) => s.indexOf('# ---- Removal ----');

    test('Wächter: festgehaltenes Paket (apt-mark hold), vor jeder Änderung',
        () {
      for (final e in both.entries) {
        final s = e.value;
        expect(s, contains(r"-f='${db:Status-Want}'"), reason: e.key);
        final hold = s.indexOf('= hold ]');
        expect(hold, greaterThanOrEqualTo(0), reason: e.key);
        expect(hold, lessThan(removalStart(s)), reason: e.key);
        expect(hold, lessThan(s.indexOf('apt-get -s')), reason: e.key);
        final refusal = code(s).firstWhere(
            (l) => l.contains('UNINSTALL_REFUSED') && l.contains('hold'));
        expect(refusal, contains(r'sudo apt-mark unhold $pk'));
        // Jedes Paket, das apt anfassen soll.
        expect(code(s), contains(r'for pk in $pkgs; do'), reason: e.key);
      }
    });

    test('Wächter: gescheiterter apt-Probelauf ist eine Ablehnung', () {
      for (final e in both.entries) {
        final s = e.value;
        final c = code(s);
        // Exit-Status und Fehlertext (stderr) bleiben erhalten.
        final sim = c.firstWhere((l) => l.contains('apt-get -s'));
        expect(sim, startsWith(r'if ! sim=$(apt-get -s '), reason: e.key);
        expect(sim, endsWith(r'</dev/null 2>&1); then'), reason: e.key);
        final i = c.indexOf(sim);
        expect(c[i + 1], r"""printf '%s\n' "$sim" | tail -n 5""",
            reason: e.key);
        expect(
            c[i + 2],
            'echo "UNINSTALL_REFUSED: Der apt-Probelauf ist fehlgeschlagen '
            '(Details oben) – nichts geändert."',
            reason: e.key);
        expect(c[i + 3], 'exit 3', reason: e.key);
        // Ausgewertet wird die festgehaltene Ausgabe, kein zweiter Lauf.
        expect(RegExp('apt-get -s').allMatches(s), hasLength(1),
            reason: e.key);
        expect(s, contains(r"""printf '%s\n' "$sim" | sed -n"""),
            reason: e.key);
        expect(s.indexOf(sim), lessThan(removalStart(s)), reason: e.key);
      }
    });

    test('tailscaled: nur disable vorher, Stoppen übernimmt der prerm', () {
      // disable --now vor apt: scheitert apt am Lock, wäre der Fernzugriff
      // weg und das Paket noch da.
      for (final e in both.entries) {
        final s = e.value;
        expect(s, isNot(contains('--now')), reason: e.key);
        expect(s, contains('systemctl disable tailscaled'), reason: e.key);
        expect(s.indexOf('systemctl disable tailscaled'), lessThan(aptRun(s)),
            reason: e.key);
        // Nach apt: läuft er noch, ist das ein Fehler vor dem Marker.
        final check = s.lastIndexOf('systemctl is-active --quiet tailscaled');
        expect(check, greaterThan(aptRun(s)), reason: e.key);
        expect(check, lessThan(s.indexOf('echo $tailscaleRemovedMarker')),
            reason: e.key);
        expect(s.indexOf('systemctl stop tailscaled'), greaterThan(aptRun(s)),
            reason: e.key);
      }
    });

    test('scheitert apt, bleibt der Dienst wie er war (wieder enable)', () {
      for (final e in both.entries) {
        final s = e.value;
        expect(s, contains('systemctl enable tailscaled'), reason: e.key);
        expect(s, contains('|| ts_apt_failed'), reason: e.key);
      }
    });

    test('Behalten: remove, Zustand und Quelle bleiben', () {
      final s = keep;
      expect(code(s), contains('act=remove'));
      expect(s, isNot(contains('act=purge')));
      // logout löscht das Profil und entwertet den Schlüssel.
      expect(s, isNot(contains('tailscale logout')));
      expect(s, isNot(contains('/var/lib/tailscale')));
      expect(s, isNot(contains('sources.list.d/tailscale.list')));
      expect(s, isNot(contains('tailscale-archive-keyring')));
      expect(s, isNot(contains('apt-key')));
      expect(s, isNot(contains('/etc/default/tailscaled')));
      expect(s, isNot(contains('rm -rf')));
    });

    test('Behalten ist wiederholbar: ein Paket im Zustand rc ist erledigt', () {
      expect(keep, contains('""|not-installed|config-files)'));
      expect(keep, isNot(contains('""|not-installed)')));
    });

    test('Purge nimmt die Weiterleitungsdatei mit, Behalten lässt sie stehen',
        () {
      // Behalten hält die Prefs samt freigegebenem Heimnetz — ohne die Datei
      // wäre die Weiterleitung nach einer Neuinstallation und dem nächsten
      // Neustart aus, während die Karte die Route als aktiv zeigt.
      final rm = "rm -f '$tailscaleForwardingConf'";
      expect(purge, contains(rm));
      expect(purge.indexOf(rm), greaterThan(aptRun(purge)));
      expect(keep, isNot(contains(rm)));
      for (final e in both.entries) {
        // Laufzeitwert bleibt (Docker).
        expect(e.value, isNot(contains('ip_forward')), reason: e.key);
      }
    });

    test('Purge: erst abmelden, dann disable, dann apt purge', () {
      final s = purge;
      expect(code(s), contains('act=purge'));
      final logout = s.indexOf('timeout 30 tailscale logout </dev/null');
      expect(logout, greaterThanOrEqualTo(0));
      expect(logout, lessThan(s.indexOf('systemctl disable tailscaled')));
      expect(logout, lessThan(aptRun(s)));
      // rc (nach einem früheren Behalten) wird mit gepurgt.
      expect(s, contains('""|not-installed)'));
      expect(s, isNot(contains('config-files')));
    });

    test('Purge: Zustand, Quelle, Schlüssel und Reste weg — nach apt', () {
      final s = purge;
      for (final p in [
        'rm -rf /var/lib/tailscale /var/cache/tailscale',
        'rm -f /etc/default/tailscaled',
        'rm -f /etc/apt/sources.list.d/tailscale.list',
        'rm -f /usr/share/keyrings/tailscale-archive-keyring.gpg',
        'rm -f /var/lib/apt/lists/pkgs.tailscale.com_*',
      ]) {
        expect(s, contains(p), reason: p);
        expect(s.indexOf(p), greaterThan(aptRun(s)), reason: p);
      }
      // Alt-Installationen (Buster): nur Tailscales Schlüssel aus der
      // geteilten trusted.gpg, nie die Datei selbst.
      expect(s, contains('del 2596A99EAAB33821893C0A79458CA832957F5868'));
      expect(s, isNot(matches(RegExp(r'rm [^\n]*trusted\.gpg'))));
    });

    test('Purge: Konfig-Backups der App, nur mit genauem Muster', () {
      final s = purge;
      final base = tailscaleForwardingConf.split('/').last;
      for (final b in ['tailscaled', 'tailscale.list', base]) {
        expect(s, contains('/var/backups/pi-tool/config-$b-[0-9]*.bak'),
            reason: b);
      }
      expect(s, isNot(contains('/var/backups/pi-tool/*')));
      expect(s, isNot(matches(RegExp(r'rm -rf? /var/backups'))));
      expect(keep, isNot(contains('/var/backups')));
    });

    test('rm -rf nur auf feste Pfade', () {
      for (final e in both.entries) {
        for (final l in code(e.value).where((l) => l.contains('rm -rf'))) {
          expect(l, isNot(contains(r'$')), reason: l);
          expect(l, isNot(contains('*')), reason: l);
        }
      }
    });

    test('Schlussprüfung vor dem Marker: Paketstatus und kein Binary mehr', () {
      for (final e in both.entries) {
        final s = e.value;
        final marker = s.indexOf('echo $tailscaleRemovedMarker');
        final verify = s.lastIndexOf(r'left=$(ts_bins)');
        expect(verify, greaterThan(aptRun(s)), reason: e.key);
        expect(verify, lessThan(marker), reason: e.key);
        expect(s.lastIndexOf('hash -r'), lessThan(verify), reason: e.key);
        expect(s.lastIndexOf('ts_status'), greaterThan(aptRun(s)),
            reason: e.key);
      }
      expect(purge.lastIndexOf('[ -e /var/lib/tailscale ]'),
          greaterThan(aptRun(purge)));
    });
  });

  // The real scripts in a real bash, against a sandboxed Pi: every system path
  // is rewritten into a temp dir, and dpkg-query/apt-get/systemctl/apt-key and
  // the tailscale CLI are stubs that keep their state in files. PATH starts
  // with the sandbox and the harness aborts if `tailscale` resolves anywhere
  // else, so a real client (the dev PC may run one) is never logged out.
  // Linux (CI) and Git Bash on Windows: plain `bash` there may be the WSL
  // launcher. Needs /proc for the tailnet guard.
  group('buildTailscaleUninstallScript in bash', () {
    late Directory tmp;
    String sb(String p) => '${tmp.path}/sb/$p';
    String state(String p) {
      final f = File(sb('state/$p'));
      return f.existsSync() ? f.readAsStringSync().trim() : 'GONE';
    }

    String calls() {
      final f = File(sb('state/calls'));
      final c = f.existsSync() ? f.readAsStringSync() : '';
      if (f.existsSync()) f.deleteSync();
      return c;
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tsun');
      File('${tmp.path}/setup.sh').writeAsStringSync(_sandboxSetup);
      File('${tmp.path}/harness.sh').writeAsStringSync(_sandboxHarness);
      final r = Process.runSync(_bash!, [_posixArg('${tmp.path}/setup.sh')]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<ProcessResult> run(
        {required bool purge,
        String conn = '192.168.1.20 5000 192.168.1.64 22'}) async {
      File('${tmp.path}/script.sh')
          .writeAsStringSync(buildTailscaleUninstallScript(purge: purge));
      final r = await Process.run(
          _bash!, [_posixArg('${tmp.path}/harness.sh'), conn],
          stdoutEncoding: utf8, stderrEncoding: utf8);
      expect(r.exitCode, isNot(99), reason: '${r.stdout}${r.stderr}');
      return r;
    }

    test('Behalten: Programm weg, Zustand, Quelle und Schlüssel bleiben; '
        'Wiederholung klappt', () async {
      var r = await run(purge: false);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect((r.stdout as String).trimRight().split('\n').last,
          tailscaleRemovedMarker);
      expect(state('tailscale'), 'config-files');
      expect(state('tailscale-archive-keyring'), 'installed');
      expect(state('enabled'), 'disabled');
      expect(File(sb('usr/bin/tailscale')).existsSync(), isFalse);
      expect(File(sb('var/lib/tailscale/tailscaled.state')).existsSync(),
          isTrue);
      expect(File(sb('etc/apt/sources.list.d/tailscale.list')).existsSync(),
          isTrue);
      expect(File(sb('etc/sysctl.d/99-pi-tool-tailscale.conf')).existsSync(),
          isTrue);
      final c = calls();
      expect(c, isNot(contains('tailscale logout')));
      expect(c, contains('remove -y tailscale'));

      // Retry after the package is already rc: nothing left to do, success.
      r = await run(purge: false);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(r.stdout, contains(tailscaleRemovedMarker));
      expect(calls(), isNot(contains('apt-get')));
    });

    test('Purge nach Behalten: alles von Tailscale weg, Fremdes bleibt',
        () async {
      await run(purge: false);
      calls();
      File(sb('etc/apt/trusted.gpg')).writeAsStringSync('legacy');
      final r = await run(purge: true);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(r.stdout, contains(tailscaleRemovedMarker));
      expect(state('tailscale'), 'GONE');
      expect(state('tailscale-archive-keyring'), 'GONE');
      for (final gone in [
        'var/lib/tailscale',
        'var/cache/tailscale',
        'etc/default/tailscaled',
        'etc/apt/sources.list.d/tailscale.list',
        'usr/share/keyrings/tailscale-archive-keyring.gpg',
        'var/lib/apt/lists/pkgs.tailscale.com_stable_InRelease',
        'var/backups/pi-tool/config-tailscaled-20260101-120000.bak',
        'var/backups/pi-tool/config-99-pi-tool-tailscale.conf-20260101-120000.bak',
      ]) {
        expect(FileSystemEntity.typeSync(sb(gone)),
            FileSystemEntityType.notFound,
            reason: gone);
      }
      for (final kept in [
        'etc/apt/sources.list.d/other.list',
        'etc/apt/trusted.gpg',
        'var/backups/pi-tool/config-mosquitto.conf-20260101-120000.bak',
        'var/backups/pi-tool/homeassistant-backup-1.tar.gz',
      ]) {
        expect(File(sb(kept)).existsSync(), isTrue, reason: kept);
      }
      final c = calls();
      expect(c, contains('purge -y tailscale tailscale-archive-keyring'));
      expect(c, contains('del 2596A99EAAB33821893C0A79458CA832957F5868'));
      // The binary went with the keep run: nothing left to log out with.
      expect(c, isNot(contains('tailscale logout')));
    });

    test('Purge frisch: abmelden, dann disable, dann apt', () async {
      final r = await run(purge: true);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      final c = calls();
      final logout = c.indexOf('tailscale logout');
      expect(logout, greaterThanOrEqualTo(0));
      expect(logout, lessThan(c.indexOf('systemctl disable tailscaled')));
      expect(c.indexOf('systemctl disable tailscaled'),
          lessThan(c.indexOf('purge -y')));
    });

    for (final conn in [
      '100.101.102.103 5000 192.168.1.64 22', // phone via this Pi's route
      '192.168.1.20 5000 100.64.0.5 22', // Pi via its tailnet address
      'fd00::5 5000 fd7a:115c:a1e0::64 22',
      '::ffff:100.64.0.9 5000 ::ffff:192.168.1.64 22',
    ]) {
      test('Sitzung über das Tailnet ($conn): abgelehnt, nichts geändert',
          () async {
        final r = await run(purge: true, conn: conn);
        expect(r.exitCode, 3, reason: '${r.stdout}${r.stderr}');
        expect((r.stdout as String).trim(),
            'UNINSTALL_REFUSED: $tailscaleSessionRefusal');
        expect(calls(), isEmpty);
        expect(state('tailscale'), 'installed');
        expect(state('enabled'), 'enabled');
      });
    }

    test('fremdes tailscale-Binary: abgelehnt, nichts geändert', () async {
      File(sb('usr/bin/tailscale')).copySync(sb('usr/local/bin/tailscale'));
      final r = await run(purge: false);
      expect(r.exitCode, 3, reason: '${r.stdout}${r.stderr}');
      expect(r.stdout, contains('UNINSTALL_REFUSED: Tailscale ist hier nicht'));
      expect(calls(), isEmpty);
      expect(state('tailscale'), 'installed');
    });

    test('apt würde mehr mitnehmen: abgelehnt nach der Simulation', () async {
      File(sb('state/dependent')).writeAsStringSync('');
      final r = await run(purge: true);
      expect(r.exitCode, 3, reason: '${r.stdout}${r.stderr}');
      expect(r.stdout, contains('UNINSTALL_REFUSED: apt würde auch pitool-dep'));
      expect(calls().trim().split('\n'), hasLength(1)); // only `apt-get -s`
      expect(state('enabled'), 'enabled');
    });

    // apt-mark hold: der Probelauf ohne -y geht durch, erst `-y` scheitert —
    // ein Purge hätte den Pi da schon abgemeldet.
    for (final (purge, pkg) in [
      (true, 'tailscale'),
      (true, 'tailscale-archive-keyring'),
      (false, 'tailscale'),
    ]) {
      test('$pkg festgehalten (${purge ? 'purge' : 'behalten'}): abgelehnt, '
          'nicht abgemeldet, nichts geändert', () async {
        File(sb('state/hold-$pkg')).writeAsStringSync('');
        final r = await run(purge: purge);
        expect(r.exitCode, 3, reason: '${r.stdout}${r.stderr}');
        final out = (r.stdout as String).trim();
        expect(out.split('\n'), hasLength(1), reason: out);
        expect(out, startsWith('UNINSTALL_REFUSED: Das Paket $pkg '));
        expect(out, contains('sudo apt-mark unhold $pkg'));
        expect(calls(), isEmpty); // weder abmelden noch apt noch systemctl
        expect(state('tailscale'), 'installed');
        expect(state('enabled'), 'enabled');
        expect(File(sb('var/lib/tailscale/tailscaled.state')).existsSync(),
            isTrue);
      });
    }

    test('Behalten: ein festgehaltener Schlüsselring stört nicht '
        '(den fasst Behalten nicht an)', () async {
      File(sb('state/hold-tailscale-archive-keyring')).writeAsStringSync('');
      final r = await run(purge: false);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(r.stdout, contains(tailscaleRemovedMarker));
      expect(state('tailscale-archive-keyring'), 'installed');
    });

    for (final purge in [true, false]) {
      test('apt-Probelauf scheitert (${purge ? 'purge' : 'behalten'}): '
          'abgelehnt mit apts Fehlertext, nicht abgemeldet', () async {
        File(sb('state/simfail')).writeAsStringSync('');
        final r = await run(purge: purge);
        expect(r.exitCode, 3, reason: '${r.stdout}${r.stderr}');
        final lines = (r.stdout as String).trimRight().split('\n');
        expect(
            lines.last,
            'UNINSTALL_REFUSED: Der apt-Probelauf ist fehlgeschlagen '
            '(Details oben) – nichts geändert.');
        expect(
            RegExp('UNINSTALL_REFUSED').allMatches(r.stdout as String),
            hasLength(1));
        // apts Meldung (stderr) steht davor, damit der Grund sichtbar ist.
        expect(r.stdout, contains('E: dpkg was interrupted'));
        final c = calls().trim().split('\n');
        expect(c, hasLength(1), reason: c.join('\n')); // only `apt-get -s`
        expect(c.single, contains('apt-get -s'));
        expect(state('tailscale'), 'installed');
        expect(state('enabled'), 'enabled');
      });
    }

    test('apt-Lock: Fehler ohne Marker, Dienst bleibt aktiviert', () async {
      File(sb('state/lock')).writeAsStringSync('');
      final r = await run(purge: false);
      expect(r.exitCode, 1, reason: '${r.stdout}${r.stderr}');
      expect(r.stdout, isNot(contains(tailscaleRemovedMarker)));
      expect(state('tailscale'), 'installed');
      expect(state('enabled'), 'enabled');
      expect(state('active'), 'active');
    });
  },
      skip: _bash == null
          ? 'braucht bash mit /proc (Linux oder Git Bash)'
          : false);
}

const String _gitBash = r'C:\Program Files\Git\bin\bash.exe';

/// Linux: `bash`. Windows: Git Bash when installed. Otherwise none.
final String? _bash = Platform.isLinux
    ? 'bash'
    : Platform.isWindows && File(_gitBash).existsSync()
        ? _gitBash
        : null;

/// Forward slashes: Git Bash reads `C:/…` paths as given.
String _posixArg(String path) => path.replaceAll(r'\', '/');

/// Builds `sb/` next to itself: a Pi with an apt-installed, enabled and
/// running Tailscale, plus unrelated files that must survive.
const String _sandboxSetup = r'''
T="$(cd "$(dirname "$0")" && pwd)/sb"
mkdir -p "$T"/stubs "$T"/state "$T"/usr/bin "$T"/usr/local/bin \
  "$T"/var/lib/tailscale "$T"/var/cache/tailscale "$T"/etc/default \
  "$T"/etc/apt/sources.list.d "$T"/etc/sysctl.d "$T"/usr/share/keyrings \
  "$T"/var/lib/apt/lists "$T"/var/backups/pi-tool
echo installed > "$T/state/tailscale"
echo installed > "$T/state/tailscale-archive-keyring"
echo enabled > "$T/state/enabled"
echo active > "$T/state/active"
for f in var/lib/tailscale/tailscaled.state etc/default/tailscaled \
  etc/apt/sources.list.d/tailscale.list etc/apt/sources.list.d/other.list \
  usr/share/keyrings/tailscale-archive-keyring.gpg \
  var/lib/apt/lists/pkgs.tailscale.com_stable_InRelease \
  etc/sysctl.d/99-pi-tool-tailscale.conf \
  var/backups/pi-tool/config-tailscaled-20260101-120000.bak \
  var/backups/pi-tool/config-99-pi-tool-tailscale.conf-20260101-120000.bak \
  var/backups/pi-tool/config-mosquitto.conf-20260101-120000.bak \
  var/backups/pi-tool/homeassistant-backup-1.tar.gz; do
  echo x > "$T/$f"
done
printf '%s\n' '#!/bin/bash' 'echo "tailscale $*" >> "$T/state/calls"' \
  > "$T/usr/bin/tailscale"
printf '%s\n' '#!/bin/bash' 'echo "apt-key $*" >> "$T/state/calls"' \
  > "$T/stubs/apt-key"
cat > "$T/stubs/dpkg-query" <<'STUB'
#!/bin/bash
if [ "$1" = -S ]; then
  if [ "$(cat "$T/state/tailscale" 2>/dev/null)" = installed ] &&
    [ "$2" = "$T/usr/bin/tailscale" ]; then
    echo "tailscale: $2"; exit 0
  fi
  exit 1
fi
p=${@: -1}
[ -f "$T/state/$p" ] || exit 1
case "$*" in
  *Status-Want*) if [ -f "$T/state/hold-$p" ]; then printf hold; else printf install; fi ;;
  *) printf '%s' "$(cat "$T/state/$p")" ;;
esac
STUB
cat > "$T/stubs/apt-get" <<'STUB'
#!/bin/bash
echo "apt-get $*" >> "$T/state/calls"
sim=; act=; pk=
for a; do
  case "$a" in
    -s) sim=1 ;;
    remove|purge) act=$a ;;
    -o|-y|DPkg::*|Dpkg::*) ;;
    *) pk="$pk $a" ;;
  esac
done
interrupted="E: dpkg was interrupted, you must manually run 'dpkg --configure -a' to correct the problem."
if [ -n "$sim" ]; then
  if [ -f "$T/state/simfail" ]; then echo "$interrupted" >&2; exit 100; fi
  for p in $pk; do
    if [ "$act" = purge ]; then echo "Purg $p [1.0]"; else echo "Remv $p [1.0]"; fi
  done
  if [ -f "$T/state/dependent" ]; then echo "Remv pitool-dep:arm64 [1.0]"; fi
  exit 0
fi
if [ -f "$T/state/lock" ]; then
  echo "E: Could not get lock /var/lib/dpkg/lock-frontend"; exit 100
fi
if [ -f "$T/state/simfail" ]; then echo "$interrupted" >&2; exit 100; fi
# A held package: the dry run above passes, `-y` does not.
for p in $pk; do
  if [ -f "$T/state/hold-$p" ]; then
    echo "E: Held packages were changed and -y was used without --allow-change-held-packages." >&2
    exit 100
  fi
done
for p in $pk; do
  if [ "$p" = tailscale ]; then
    echo inactive > "$T/state/active"   # prerm
    rm -f "$T/usr/bin/tailscale"
  fi
  if [ "$act" = purge ]; then
    rm -f "$T/state/$p"
    if [ "$p" = tailscale ]; then rm -rf "$T/var/lib/tailscale"; fi
  else
    echo config-files > "$T/state/$p"
  fi
done
STUB
cat > "$T/stubs/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >> "$T/state/calls"
case "$1" in
  is-enabled) e=$(cat "$T/state/enabled"); echo "$e"; [ "$e" = enabled ] ;;
  is-active) [ "$(cat "$T/state/active")" = active ] ;;
  disable) echo disabled > "$T/state/enabled" ;;
  enable) echo enabled > "$T/state/enabled" ;;
  stop) echo inactive > "$T/state/active" ;;
esac
STUB
chmod +x "$T"/stubs/* "$T/usr/bin/tailscale"
''';

/// Runs `script.sh` (next to itself) in the sandbox. The caller's
/// SSH_CONNECTION ($1) sits in the parent's environment only, the way sudo's
/// env_reset leaves it. Exit 99 = the harness itself refused.
const String _sandboxHarness = r'''
D="$(cd "$(dirname "$0")" && pwd)"
T="$D/sb"
sed -E "s#([ '])/(var|etc|usr|snap|sbin|bin)/#\1$T/\2/#g" "$D/script.sh" > "$D/run.sh"
if sed "s#$T#SANDBOX#g" "$D/run.sh" | grep -qE "[ ']/(var|etc|usr|snap|sbin|bin)/"; then
  echo "HARNESS: path outside the sandbox"; exit 99
fi
export PATH="$T/stubs:$T/usr/bin:/usr/bin:/bin"
case "$(command -v tailscale || true)" in
  ""|"$T"/*) ;;
  *) echo "HARNESS: tailscale outside the sandbox"; exit 99 ;;
esac
export T
env SSH_CONNECTION="$1" bash -c 'env -u SSH_CONNECTION bash "$0"; exit $?' "$D/run.sh"
''';

/// A shell `case` glob (only `*`, `[...]` and literals) as a RegExp body.
String _globToRegex(String glob) {
  final b = StringBuffer();
  for (var i = 0; i < glob.length; i++) {
    final c = glob[i];
    if (c == '*') {
      b.write('.*');
    } else if (c == '[') {
      final end = glob.indexOf(']', i);
      b.write(glob.substring(i, end + 1));
      i = end;
    } else {
      b.write(RegExp.escape(c));
    }
  }
  return b.toString();
}
