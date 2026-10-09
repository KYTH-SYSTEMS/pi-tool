import 'dart:convert';

import 'package:evcc_updater/main.dart';
import 'package:evcc_updater/src/alerts.dart';
import 'package:evcc_updater/src/auto_update.dart';
import 'package:evcc_updater/src/commands.dart';
import 'package:evcc_updater/src/demo.dart';
import 'package:evcc_updater/src/files.dart';
import 'package:evcc_updater/src/keep_alive.dart';
import 'package:evcc_updater/src/l10n.dart';
import 'package:evcc_updater/src/parsing.dart';
import 'package:evcc_updater/src/pi_job.dart';
import 'package:evcc_updater/src/profiles.dart';
import 'package:evcc_updater/src/scheduled_backup.dart';
import 'package:evcc_updater/src/security_check.dart';
import 'package:evcc_updater/src/services/tailscale.dart';
import 'package:evcc_updater/src/ssh_runner.dart';
import 'package:evcc_updater/src/update_check.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _cfg = SshConfig(host: 'demo', port: 22, username: 'pi', password: 'x');

/// A fresh install, terms accepted: the state a Play reviewer starts from.
class _FreshStore extends AppConfigStore {
  @override
  Future<AppConfig> load() async => const AppConfig(
        profiles: [Profile(name: 'S')],
        activeIndex: 0,
        disclaimerAccepted: true,
      );
  @override
  Future<void> save(AppConfig c) async {}
}

class _NoKeepAlive implements KeepAliveService {
  @override
  Future<void> begin(String message,
      {required String channelName,
      required String channelDescription}) async {}
  @override
  Future<void> end() async {}
}

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

    test('ends with the end marker, like a batch that ran through', () {
      // Without it the detection would read the document as cut off, and the
      // demo — the Play reviewers' way into the app — would show no cards.
      expect(sections.keys.last, detectEndKey);
      // The very line a real batch echoes last.
      final lastLine = const LineSplitter()
          .convert(demoResponseFor(detectShellCommand))
          .last;
      expect(buildDetectBatch(const []), contains('\necho $lastLine\n'));
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
    // The whole sample directory, none of it a symlink.
    expect(entries, hasLength(5));
    expect(entries.any((e) => e.isLink), isFalse);

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

  // The three on-Pi timers of the Automatik tab. Their root scripts count as
  // done only with their marker, and the sheets read the Pi's state before
  // they open — so the demo Pi has to answer both, and remember in between.
  group('on-Pi timers in the demo', () {
    void noLog(String _) {}

    test('automatic updates: off, on with the schedule that was set, changed, '
        'off again', () async {
      final u = buildDemoUpdater();
      var st = await u.readAutoUpdateStatus(config: _cfg, onLog: noLog);
      expect(st.enabled, isFalse);
      expect(st.nextRun, isNull);
      expect(st.schedule, isNull);

      await u.enableAutoUpdate(
          config: _cfg, onCalendar: 'Wed *-*-* 22:00:00', onLog: noLog);
      st = await u.readAutoUpdateStatus(config: _cfg, onLog: noLog);
      expect(st.enabled, isTrue);
      expect(st.schedule, (weekly: true, hour: 22, weekday: 3));
      expect(st.nextRun, matches(RegExp(r'^Wed \d{4}-\d\d-\d\d 22:00:00$')));
      // Just set up: no run yet, and the wrapper is this version's.
      expect(st.lastResult, isNull);
      expect(st.wrapperOutdated, isFalse);

      await u.enableAutoUpdate(
          config: _cfg, onCalendar: '*-*-* 05:00:00', onLog: noLog);
      st = await u.readAutoUpdateStatus(config: _cfg, onLog: noLog);
      expect(st.schedule, (weekly: false, hour: 5, weekday: 7));

      await u.disableAutoUpdate(config: _cfg, onLog: noLog);
      st = await u.readAutoUpdateStatus(config: _cfg, onLog: noLog);
      expect(st.enabled, isFalse);
      expect(st.schedule, isNull);
    });

    test('scheduled backups: off, on with time and retention as set, off again',
        () async {
      final u = buildDemoUpdater();
      var st = await u.readScheduledBackupStatus(config: _cfg, onLog: noLog);
      expect(st.enabled, isFalse);
      expect(st.hour, isNull);
      expect(st.keep, isNull);

      await u.enableScheduledBackup(
          config: _cfg, onCalendar: '*-*-* 01:00:00', keep: 14, onLog: noLog);
      st = await u.readScheduledBackupStatus(config: _cfg, onLog: noLog);
      expect(st.enabled, isTrue);
      expect(st.hour, 1);
      expect(st.keep, 14);
      expect(st.nextRun, matches(RegExp(r'^\w{3} \d{4}-\d\d-\d\d 01:00:00$')));
      expect(st.lastResult, isNull);
      expect(st.wrapperOutdated, isFalse);

      await u.disableScheduledBackup(config: _cfg, onLog: noLog);
      st = await u.readScheduledBackupStatus(config: _cfg, onLog: noLog);
      expect(st.enabled, isFalse);
      expect(st.keep, isNull);
    });

    test('Health-Alerts: off, on, a test push, off again', () async {
      final u = buildDemoUpdater();
      var st = await u.readAlertsStatus(config: _cfg, onLog: noLog);
      expect(st.enabled, isFalse);

      await u.enableAlerts(
          config: _cfg,
          ntfyServer: 'https://ntfy.sh',
          ntfyTopic: 'pi-tool-k7m2q9x4vb3dwz',
          onLog: noLog);
      st = await u.readAlertsStatus(config: _cfg, onLog: noLog);
      expect(st.enabled, isTrue);
      expect(st.lastCheck, isNull); // the first check is still to come
      expect(st.wrapperOutdated, isFalse);
      await u.sendTestAlert(
          config: _cfg,
          ntfyServer: 'https://ntfy.sh',
          ntfyTopic: 'pi-tool-k7m2q9x4vb3dwz',
          onLog: noLog);

      await u.disableAlerts(config: _cfg, onLog: noLog);
      st = await u.readAlertsStatus(config: _cfg, onLog: noLog);
      expect(st.enabled, isFalse);
    });

    test('one timer does not switch another, and every demo has its own Pi',
        () async {
      final u = buildDemoUpdater();
      await u.enableScheduledBackup(
          config: _cfg, onCalendar: '*-*-* 03:00:00', keep: 7, onLog: noLog);
      expect((await u.readAutoUpdateStatus(config: _cfg, onLog: noLog)).enabled,
          isFalse);
      expect((await u.readAlertsStatus(config: _cfg, onLog: noLog)).enabled,
          isFalse);
      expect(
          (await buildDemoUpdater()
                  .readScheduledBackupStatus(config: _cfg, onLog: noLog))
              .enabled,
          isFalse);
    });

    test('the next run is the next time the schedule comes round', () {
      String? next(String onCalendar, DateTime now) => parseAutoUpdateStatus(
              demoResponseFor(autoUpdateStatusCommand,
                  pi: DemoPi()..autoUpdate = onCalendar, now: now))
          .nextRun;
      // Friday 2026-10-09, noon.
      final now = DateTime(2026, 10, 9, 12);
      expect(next('*-*-* 22:00:00', now), 'Fri 2026-10-09 22:00:00');
      expect(next('*-*-* 04:00:00', now), 'Sat 2026-10-10 04:00:00');
      expect(next('*-*-* 12:00:00', now), 'Sat 2026-10-10 12:00:00');
      expect(next('Sun *-*-* 04:00:00', now), 'Sun 2026-10-11 04:00:00');
      expect(next('Fri *-*-* 04:00:00', now), 'Fri 2026-10-16 04:00:00');
      // Over the end of a month and of a year.
      expect(next('*-*-* 01:00:00', DateTime(2026, 12, 31, 23)),
          'Fri 2027-01-01 01:00:00');
    });

    test('without a timer the probes answer like a Pi that has none', () {
      for (final probe in [
        autoUpdateStatusCommand,
        scheduledBackupStatusCommand,
        alertsStatusCommand,
      ]) {
        final lines = demoResponseFor(probe).trim().split('\n');
        expect(lines.first, 'ENABLED disabled', reason: probe);
        expect(lines, contains('WRAPPER none'), reason: probe);
      }
    });

    // Every other root script still ends without a marker in the demo — the
    // cards offer no restore or uninstall there.
    test('a root script that is none of the six gets no marker', () {
      expect(demoResponseFor(installShellCommand, stdin: 'echo RESTORE_OK\n'),
          isEmpty);
      // The marker has to be the script's last line, not a word in it.
      expect(
          demoResponseFor(installShellCommand,
              stdin: '# AUTOUPDATE_INSTALLED\necho other\n'),
          isEmpty);
    });
  });

  // The same three paths through the UI, as a Play reviewer walks them: each
  // has to end the way it does against a real Pi.
  group('Automatik tab in the demo', () {
    Future<void> openAutomatik(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('de'),
        home: UpdaterPage(
          store: _FreshStore(),
          updateChecker:
              UpdateChecker(getJson: (_) async => <String, dynamic>{}),
          keepAlive: _NoKeepAlive(),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('demoEntry')));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.bolt_outlined));
      await tester.pumpAndSettle();
    }

    Finder inSheet(Finder what) =>
        find.descendant(of: find.byType(BottomSheet), matching: what);

    Future<void> open(WidgetTester tester, String tile) async {
      await tester.tap(find.text(tile));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget, reason: tile);
    }

    Future<void> press(WidgetTester tester, Finder button) async {
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
    }

    List<int?> pickerValues(WidgetTester tester) => [
          for (final p in tester.widgetList<DropdownButton<int>>(
              inSheet(find.byType(DropdownButton<int>))))
            p.value
        ];

    testWidgets('automatic updates: on, shown as on with its schedule, off',
        (tester) async {
      await openAutomatik(tester);
      await open(tester, 'Automatische Updates');
      expect(inSheet(find.text('Aktuell aus.')), findsOneWidget);
      await tester.tap(find.text('Wöchentlich'));
      await tester.pumpAndSettle();
      await press(tester, find.widgetWithText(FilledButton, 'Einschalten'));
      expect(find.text('Automatische Updates aktiv.'), findsOneWidget);
      expect(find.textContaining('fehlgeschlagen'), findsNothing);

      await open(tester, 'Automatische Updates');
      expect(inSheet(find.textContaining('Aktuell aktiv · nächste: Sun ')),
          findsOneWidget);
      // The sheet opens with what was set: weekly, 04:00, Sunday.
      expect(
          tester
              .widget<SegmentedButton<bool>>(
                  find.byType(SegmentedButton<bool>))
              .selected,
          {true});
      expect(pickerValues(tester), [4, 7]);
      expect(find.byKey(const Key('wrapperOutdatedHint')), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Zeitplan ändern'),
          findsOneWidget);
      await press(tester, find.widgetWithText(TextButton, 'Ausschalten'));
      expect(find.text('Automatische Updates deaktiviert.'), findsOneWidget);

      await open(tester, 'Automatische Updates');
      expect(inSheet(find.text('Aktuell aus.')), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Einschalten'), findsOneWidget);
    });

    testWidgets('scheduled backups: on, shown as on with time and retention, '
        'off', (tester) async {
      await openAutomatik(tester);
      await open(tester, 'Geplante Backups');
      expect(inSheet(find.text('Aktuell aus.')), findsOneWidget);
      // Another retention than the default.
      await tester.tap(inSheet(find.byType(DropdownButton<int>)).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('14').last);
      await tester.pumpAndSettle();
      await press(tester, find.widgetWithText(FilledButton, 'Einschalten'));
      expect(find.text('Geplante Backups aktiv.'), findsOneWidget);

      await open(tester, 'Geplante Backups');
      expect(inSheet(find.textContaining('Aktuell aktiv · nächste: ')),
          findsOneWidget);
      expect(pickerValues(tester), [3, 14]);
      expect(find.byKey(const Key('wrapperOutdatedHint')), findsNothing);
      await press(tester, find.widgetWithText(TextButton, 'Ausschalten'));
      expect(find.text('Geplante Backups deaktiviert.'), findsOneWidget);

      await open(tester, 'Geplante Backups');
      expect(inSheet(find.text('Aktuell aus.')), findsOneWidget);
    });

    testWidgets('Health-Alerts: on with the topic of the sheet, shown as on '
        'with that topic, a test push, off', (tester) async {
      await openAutomatik(tester);
      await open(tester, 'Health-Alerts');
      expect(inSheet(find.text('Aktuell aus.')), findsOneWidget);
      String topicField() => tester
          .widget<TextField>(inSheet(find.byType(TextField)).first)
          .controller!
          .text;
      final topic = topicField();
      expect(topic, startsWith('pi-tool-'));
      await press(tester, find.widgetWithText(FilledButton, 'Einschalten'));
      expect(find.text('Health-Alerts aktiv (ntfy: $topic).'), findsOneWidget);
      expect(find.textContaining('fehlgeschlagen'), findsNothing);

      await open(tester, 'Health-Alerts');
      expect(inSheet(find.textContaining('Aktuell aktiv · letzte Prüfung: ')),
          findsOneWidget);
      // The topic the demo Pi pushes to — not an empty field with the hint
      // that the app does not know it.
      expect(topicField(), topic);
      expect(find.textContaining('nicht gespeichert'), findsNothing);
      expect(find.byKey(const Key('wrapperOutdatedHint')), findsNothing);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
      await tester.pumpAndSettle();
      expect(inSheet(find.text('Test-Benachrichtigung gesendet — prüf dein ntfy.')),
          findsOneWidget);
      await press(tester, find.widgetWithText(TextButton, 'Ausschalten'));
      expect(find.text('Health-Alerts deaktiviert.'), findsOneWidget);

      await open(tester, 'Health-Alerts');
      expect(inSheet(find.text('Aktuell aus.')), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Einschalten'), findsOneWidget);
    });
  });

  test('demo evcc API client returns a charging loadpoint', () async {
    final state = await buildDemoApiClient()
        .fetchState(scheme: 'http', host: 'demo', port: '7070');
    expect(state.loadpoints, isNotEmpty);
    expect(state.loadpoints.first.charging, isTrue);
  });
}
