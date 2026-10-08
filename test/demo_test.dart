import 'dart:convert';

import 'package:evcc_updater/src/commands.dart';
import 'package:evcc_updater/src/demo.dart';
import 'package:evcc_updater/src/files.dart';
import 'package:evcc_updater/src/parsing.dart';
import 'package:evcc_updater/src/pi_job.dart';
import 'package:evcc_updater/src/security_check.dart';
import 'package:evcc_updater/src/services/tailscale.dart';
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

    test('Tailscale is connected on the demo Pi (backend Running, a 100.x)',
        () {
      final ts = parseTailscaleStatus(sections['TAILSCALE']!,
          self: sections['TS_SELF']!);
      expect(ts.installed, isTrue);
      expect(ts.up, isTrue);
      expect(ts.needsLogin, isFalse);
      expect(ts.ip, '100.101.102.103');
      expect(isTailnetClient('${ts.ip} 50000 ${ts.ip} 22'), isTrue,
          reason: 'inside 100.64.0.0/10, like a real tailnet address');
    });
  });

  test('demo cards: evcc + connected Tailscale → evcc address over the tailnet',
      () async {
    final services =
        await buildDemoUpdater().detectServices(config: _cfg, onLog: (_) {});
    expect(services.any((s) => s.id == 'evcc' && s.installed), isTrue);
    final ts = services.firstWhere((s) => s.id == 'tailscale');
    expect(ts.active, isTrue);
    expect(ts.detail, 'Verbunden · 100.101.102.103');
    expect(evccTailnetUrl(scheme: 'http', tailnetIp: ts.version, port: '7070'),
        'http://100.101.102.103:7070');
    // No home network on offer: the demo has no sample backend for sharing
    // it, so the card must not show an action that could only fail.
    expect(ts.routes?.share, RouteShare.unavailable);
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

  // The demo answers through the wrapper the real updater builds — so the test
  // goes through the updater too, not through a hand-written command string.
  test('terminal: the canned answers survive the console wrapper', () async {
    final u = buildDemoUpdater();
    Future<String> run(String cmd) =>
        u.runConsoleCommand(config: _cfg, command: cmd, onLog: (_) {});
    expect(await run('pwd'), '/home/pi\n');
    expect(await run('whoami'), 'pi\n');
    expect(await run('echo hallo # Kommentar'), 'hallo # Kommentar\n');
    expect(await run('df -h'), contains('/dev/root'));
    // Anything unknown (and every sudo command) gets the demo note.
    expect(await run('sudo systemctl restart evcc'), contains('Demo-Modus'));
  });

  test('demo security check yields real findings, not five unknowns', () {
    // Audit 2026-08-15: the probe fell through to the benign default, so the
    // sheet claimed "Keine Warnungen" above five "Konnte nicht ermittelt".
    final findings = parseSecurityReport(demoResponseFor(buildSecurityProbe()));
    expect(findings.any((f) => f.detail.startsWith('Konnte nicht')), isFalse);
    expect(findings.where((f) => f.level == SecurityLevel.warn), isNotEmpty);
    // And the offered fix is one the demo actually models.
    final updates =
        findings.firstWhere((f) => f.title.contains('Sicherheitsupdates'));
    expect(securityFixFor(updates), SecurityFix.autoUpdates);
  });

  // The demo is the Play reviewers' entry point: every job-backed update must
  // end cleanly (RC 0 + the kind's markers), never as "Verbindung weg".
  group('Pi-Jobs in the demo', () {
    test('upgradeSystem, run, updateAptPackage, repair, Pi-hole complete',
        () async {
      final u = buildDemoUpdater();
      final log = <String>[];
      final started = <JobRef>[];
      final sys = await u.upgradeSystem(
          config: _cfg, onLog: log.add, onJobStarted: started.add);
      expect(sys.listsIncomplete, isFalse);
      final summary = await u.run(
          config: _cfg,
          fullUpgrade: false,
          dryRun: false,
          onLog: log.add,
          onJobStarted: started.add);
      expect(summary.status, UpdateStatus.alreadyCurrent);
      expect(summary.before, '0.207.0');
      await u.run(
          config: _cfg, fullUpgrade: true, dryRun: false, onLog: log.add);
      await u.updateAptPackage(
          config: _cfg, package: 'grafana', onLog: log.add);
      await u.repairPackageState(config: _cfg, onLog: log.add);
      await u.updatePihole(config: _cfg, onLog: log.add);
      expect(started.map((r) => r.kind),
          [jobKindSystemUpgrade, jobKindEvccUpdate]);
      expect(log.join('\n'), contains('grafana ist aktuell.'));
      expect(log.join('\n'), isNot(contains('PITOOL_JOB_')));
    });

    test('re-follow works in the demo', () async {
      final o = await buildDemoUpdater().followJob(
          config: _cfg, jobId: '0123456789abcdef', onLog: (_) {});
      expect(o.success, isTrue);
    });

    test('the job answer carries the id from argv', () {
      const id = 'aaaaaaaaaaaaaaaa';
      final out = demoResponseFor(jobStartCommand(id));
      expect(out, startsWith('PITOOL_JOB_STARTED $id '));
      expect(out, endsWith('\nPITOOL_JOB_RC $id 0\n'));
      expect(classifyJobRun(stdout: out, stderr: '', exitCode: 0, id: id),
          isA<JobRunRc>());
    });

    test('detection has an empty JOB section → no job', () {
      final sections = splitDetectSections(demoResponseFor(detectShellCommand));
      expect(sections.containsKey('JOB'), isTrue);
      expect(parseJobStatus(sections['JOB']!), isNull);
    });

    test('the reboot guard answers like a successful reboot', () async {
      await buildDemoUpdater().reboot(config: _cfg, onLog: (_) {});
      await buildDemoUpdater().shutdown(config: _cfg, onLog: (_) {});
    });
  });

  test('demo evcc API client returns a charging loadpoint', () async {
    final state = await buildDemoApiClient()
        .fetchState(scheme: 'http', host: 'demo', port: '7070');
    expect(state.loadpoints, isNotEmpty);
    expect(state.loadpoints.first.charging, isTrue);
  });
}
