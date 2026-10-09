import 'package:evcc_updater/src/commands.dart' show autoUpdateBusyWayOut;
import 'package:evcc_updater/src/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Proves the generated AppLocalizations resolves per locale end-to-end.
void main() {
  Future<AppLocalizations> l10nFor(WidgetTester tester, Locale locale) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      home: Builder(builder: (c) {
        l10n = c.l10n;
        return const SizedBox();
      }),
    ));
    return l10n;
  }

  testWidgets('German locale → German strings', (tester) async {
    final l10n = await l10nFor(tester, const Locale('de'));
    expect(l10n.settingsLanguageTitle, 'Sprache');
  });

  testWidgets('English locale → English strings', (tester) async {
    final l10n = await l10nFor(tester, const Locale('en'));
    expect(l10n.settingsLanguageTitle, 'Language');
  });

  // The reset of the load error state is the one place a user confirms
  // losing everything: both languages say what is lost and how it comes back.
  testWidgets('the reset confirmation names the loss and the import, de + en',
      (tester) async {
    final de = await l10nFor(tester, const Locale('de'));
    expect(de.loadFailedReset, 'Gespeicherte Daten zurücksetzen');
    expect(de.loadFailedResetBody, contains('Passwörtern und SSH-Keys'));
    expect(de.loadFailedResetBody, contains('„Profile importieren“'));
    expect(de.loadFailedResetBody, contains('\n\n'));

    final en = await l10nFor(tester, const Locale('en'));
    expect(en.loadFailedReset, 'Reset stored data');
    expect(en.loadFailedResetBody, contains('passwords and SSH keys'));
    expect(en.loadFailedResetBody, contains('"Import profiles"'));
    expect(en.loadFailedResetBody, contains('\n\n'));
  });

  // Texts the UI layer used to carry in German only, or in English that read
  // as "we stop in order to follow".
  testWidgets('log lines of the UI layer exist in both languages',
      (tester) async {
    final en = await l10nFor(tester, const Locale('en'));
    expect(en.logStopFollowRequested,
        'No longer following – the job keeps running on the Pi.');
    expect(en.logMigrationTarget('Keller', '10.0.0.7'),
        '— Target Pi “Keller” (10.0.0.7) —');
    final de = await l10nFor(tester, const Locale('de'));
    expect(de.logMigrationTarget('Keller', '10.0.0.7'),
        '— Ziel-Pi „Keller“ (10.0.0.7) —');
  });

  // A unit set up by v0.71.0 or earlier has no runtime cap: while such a run
  // hangs, "try again in a few minutes" alone would come back for good. The
  // way out is named by the labels the app shows.
  testWidgets('the refusal while the automatic updates run names the way out, '
      'de + en', (tester) async {
    final de = await l10nFor(tester, const Locale('de'));
    expect(de.statusAutoUpdateBusy, contains('Es wurde nichts gestartet.'));
    expect(de.statusAutoUpdateBusy, contains('Tab „${de.tabAutomation}“'));
    expect(de.statusAutoUpdateBusy, contains('(„${de.changeSchedule}“)'));
    expect(de.statusAutoUpdateBusy,
        contains('„sudo systemctl stop pi-tool-autoupdate.service“'));
    // The logic layer's sentence for reboot and shutdown is the same one, in
    // that layer's quotes.
    expect(de.statusAutoUpdateBusy,
        endsWith(autoUpdateBusyWayOut.replaceAll('"', '“')));

    final en = await l10nFor(tester, const Locale('en'));
    expect(en.statusAutoUpdateBusy, contains('Nothing was started.'));
    expect(en.statusAutoUpdateBusy, contains('“${en.tabAutomation}” tab'));
    expect(en.statusAutoUpdateBusy, contains('(“${en.changeSchedule}”)'));
    expect(en.statusAutoUpdateBusy,
        contains('“sudo systemctl stop pi-tool-autoupdate.service”'));
    // Not "a stuck run": the Pi ends a run at the unit's cap, counted from
    // its start (commands_test ties the six hours to that cap).
    expect(en.statusAutoUpdateBusy,
        contains('the Pi itself ends a run that takes longer than six hours'));
  });

  // A Pi-hole v5 source: asked before the target is touched, and the result
  // names both services. The question refers to its own button by its label.
  testWidgets('the migration helper says what moves and what does not, de + en',
      (tester) async {
    final de = await l10nFor(tester, const Locale('de'));
    expect(de.dialogMigratePiholeV5Body, contains('„${de.actionContinue}“'));
    expect(de.dialogMigratePiholeV5Body,
        contains('Bis jetzt wurde am Ziel-Pi nichts geändert.'));
    expect(de.statusMigratedEvccOnly, startsWith('evcc ist umgezogen'));
    expect(de.statusMigratedEvccOnly, contains('Pi-hole wurde nicht umgezogen'));
    expect(de.errorMigratePiholeV5,
        endsWith('Am Ziel-Pi wurde nichts geändert.'));

    final en = await l10nFor(tester, const Locale('en'));
    expect(en.dialogMigratePiholeV5Title, 'Move evcc only?');
    expect(en.dialogMigratePiholeV5Body, contains('“${en.actionContinue}”'));
    expect(en.dialogMigratePiholeV5Body,
        contains('Nothing has been changed on the target Pi so far.'));
    expect(en.statusMigratedEvccOnly, startsWith('evcc was moved'));
    expect(en.statusMigratedEvccOnly, contains('Pi-hole was not moved'));
    expect(en.statusMigrationCancelled,
        'Migration cancelled — nothing was changed on the target Pi.');
    expect(en.errorMigratePiholeV5,
        endsWith('Nothing was changed on the target Pi.'));
  });

  // Neither is a failure, and neither text calls it one.
  testWidgets('a dismissed share sheet and an import next to an action, en',
      (tester) async {
    final en = await l10nFor(tester, const Locale('en'));
    expect(
        en.statusBackupNotSaved('pihole-backup.zip'),
        'Backup not saved: the share sheet was closed without a choice. '
        'pihole-backup.zip is still on the Pi.');
    expect(en.snackImportDecrypting, 'Decrypting the import …');
    expect(
        en.snackImportBusy,
        'An action is running — the profiles were not imported. Start the '
        'import again once it has finished.');
  });
}
