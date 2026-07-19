import 'dart:convert';

import 'package:evcc_updater/src/commands.dart';
import 'package:evcc_updater/src/demo.dart';
import 'package:evcc_updater/src/files.dart';
import 'package:evcc_updater/src/parsing.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:flutter_test/flutter_test.dart';

const _cfg = SshConfig(host: 'demo', port: 22, username: 'pi', password: 'x');

void main() {
  group('detection batch', () {
    final sections = splitDetectSections(demoResponseFor(detectShellCommand));

    test('canned document parses into the expected sections', () {
      expect(sections['EVCC_V'], 'installed 0.207.0');
      expect(sections['EVCC_SVC'], 'active');
      expect(sections['OS'], contains('bookworm'));
      expect(sections['PIHOLE_V'], contains('Core version is v6.0.6'));
      expect(sections['PIHOLE_S'], contains('Blocking is enabled'));
      expect(sections['PENDING'], contains('upgraded'));
      expect(sections['DISK'], contains('29%'));
    });

    test('the REAL parsers accept the canned values', () {
      expect(parseInstalledVersion(sections['EVCC_V']!), '0.207.0');
      expect(isServiceActive(sections['EVCC_SVC']!), isTrue);
    });
  });

  test('detectInstall probes return believable values', () {
    expect(parseInstalledVersion(demoResponseFor(versionQuery)), '0.207.0');
    expect(isServiceActive(demoResponseFor(serviceStatus)), isTrue);
    expect(demoResponseFor(dockerListCommand), isEmpty);
  });

  test('file browser: listing + preview decode', () {
    final entries =
        parseDirListing(demoResponseFor(buildListDirCommand('/home/pi')));
    expect(entries.map((e) => e.name), containsAll(<String>['backups', 'evcc.yaml']));
    expect(entries.firstWhere((e) => e.name == 'backups').isDir, isTrue);
    expect(entries.firstWhere((e) => e.name == 'evcc.yaml').isDir, isFalse);

    final b64 = demoResponseFor(buildReadFileCommand('/home/pi/evcc.yaml')).trim();
    expect(utf8.decode(base64.decode(b64)), contains('evcc'));
  });

  group('DemoSshRunner', () {
    test('connect/close are no-ops; unknown command succeeds empty', () async {
      final r = DemoSshRunner(_cfg);
      await r.connect();
      final res = await r.run('an unknown command');
      expect(res.exitCode, 0);
      expect(res.stdout, isEmpty);
      expect(res.stderr, isEmpty);
      await r.close();
    });

    test('streams whole lines to onOutput', () async {
      final r = DemoSshRunner(_cfg);
      final lines = <String>[];
      await r.run(detectShellCommand, onOutput: lines.add);
      expect(lines, isNotEmpty);
      expect(lines.every((l) => l.endsWith('\n')), isTrue);
    });

    test('never emits a sudo-failure token', () {
      // A safety invariant: canned output must not trip isSudoPasswordFailure.
      final out = demoResponseFor(detectShellCommand).toLowerCase();
      expect(out.contains('incorrect password'), isFalse);
      expect(out.contains('sorry, try again'), isFalse);
    });
  });

  test('demo evcc API client returns a charging loadpoint', () async {
    final state = await buildDemoApiClient()
        .fetchState(scheme: 'http', host: 'demo', port: '7070');
    expect(state.loadpoints, isNotEmpty);
    expect(state.loadpoints.first.charging, isTrue);
  });
}
