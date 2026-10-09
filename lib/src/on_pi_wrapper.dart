/// Generation stamp of the on-Pi timer wrappers (auto-update, scheduled
/// backups, health alerts).
///
/// A wrapper is written to the Pi when its timer is set up and stays there: a
/// fix made in the app does not reach a Pi until that timer is set up again.
/// So every wrapper carries its stamp line as its second line, every status
/// probe reports the generation of the installed file, and the sheet of a
/// timer whose wrapper is older than the app's says so. Pure + Flutter-free.
///
/// Each wrapper has a generation of its own. Raise the one of the wrapper
/// whose behaviour changes — and only that one: the sheet's hint to set the
/// timer up again must appear only where doing so changes something.
library;

/// 2 = v0.71.0, all three wrappers: tar gets only existing paths, the Pi-hole
/// export is not picked by exit code, the status line names failures, alerts
/// are remembered only once delivered. Wrappers from before carry no stamp at
/// all.
///
/// The backup wrapper is still the one of v0.71.0.
const int scheduledBackupWrapperGeneration = 2;

/// 3 (after v0.71.0): repairs and waits for apt locks like a Pi-Job, reports
/// package lists that did not load, keeps a log, finishes when systemd asks it
/// to stop and ignores a start right after its setup.
const int autoUpdateWrapperGeneration = 3;

/// 3 (after v0.71.0): refreshes the package lists itself, debounces by problem
/// class, reads its ntfy destination from a root-only file and names the Pi
/// in the title of a push.
const int alertsWrapperGeneration = 3;

const String _stampPrefix = '# pi-tool-wrapper ';

/// The stamp line of v0.71.0 — the only one that version accepts: its probe
/// is `grep -qxF '# pi-tool-wrapper 2'`, and it calls every wrapper without
/// exactly that line outdated, a later generation included. Several phones
/// per Pi are common. On one still on v0.71.0 such a wrapper would show the
/// hint to set the timer up again, and following it writes the wrapper of
/// v0.71.0 back: the schedule as that sheet opens (daily 04:00), the ntfy
/// topic in the world-readable wrapper — after which the newer phone asks.
///
/// So every wrapper past generation 2 carries this line too, right after its
/// own stamp. It has to stay for as long as v0.71.0 is in the field. No later
/// version needs a line like it: the probes since report the number they find
/// ([wrapperProbeTail]).
const String wrapperStampOfV071 = '${_stampPrefix}2';

/// The first lines of each wrapper, right after the shebang: its own stamp
/// and, past generation 2, [wrapperStampOfV071].
///
/// The backup wrapper is generation 2: its stamp is that line. Once raised it
/// gets the second line like the other two (on_pi_wrapper_test.dart runs the
/// probe of v0.71.0 against all three).
const String scheduledBackupWrapperStamp =
    '$_stampPrefix$scheduledBackupWrapperGeneration';
const String autoUpdateWrapperStamp =
    '$_stampPrefix$autoUpdateWrapperGeneration\n$wrapperStampOfV071';
const String alertsWrapperStamp =
    '$_stampPrefix$alertsWrapperGeneration\n$wrapperStampOfV071';

/// The two halves of the status-probe fragment, with the unit name between
/// them (kept as constants so the probes stay compile-time strings). Prints
/// `WRAPPER <n>`: the highest generation among the wrapper's stamp lines, 0
/// for a file without one — a wrapper from before the stamps, or one the SSH
/// user cannot read. `WRAPPER none` without a wrapper. The number, not a
/// verdict: what counts as old is for [parseWrapperOutdated] to say, so that
/// no app calls a wrapper outdated for carrying a stamp it does not know yet.
/// No sudo: the wrappers are world-readable — which is why nothing secret may
/// be written into one (the ntfy destination of the alerts wrapper has a file
/// of its own).
const String wrapperProbeHead = 'echo "WRAPPER \$(f=/usr/local/lib/';
const String wrapperProbeTail = '.sh; if [ -f "\$f" ]; then '
    'sed -n \'s/^$_stampPrefix\\([0-9][0-9]*\\)\$/\\1/p\' "\$f" 2>/dev/null | '
    'sort -n | tail -n 1 | grep . || echo 0; else echo none; fi)"';

final RegExp _wrapperLineRe = RegExp(r'^WRAPPER ([0-9]{1,9})$');

/// Whether a status probe's output says the installed wrapper is of an older
/// generation than [generation], the app's own for that wrapper. A newer one
/// never is: an app that is behind has nothing to renew it with. Neither is a
/// missing wrapper or a probe without the line (a cut-off answer) — there is
/// nothing the user could renew, or nothing known.
bool parseWrapperOutdated(String statusOutput, int generation) {
  for (final line in statusOutput.split('\n')) {
    final m = _wrapperLineRe.firstMatch(line.trim());
    if (m != null) return int.parse(m.group(1)!) < generation;
  }
  return false;
}

/// The schedules the app builds: daily or on one weekday, at a wall-clock
/// time (`*-*-* 04:00:00`, `Sun *-*-* 04:00:00`).
final RegExp _onCalendarRe = RegExp(
    r'^(?:(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) )?\*-\*-\* (?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$');

/// [onCalendar] if it is such a schedule; throws [ArgumentError] otherwise.
/// The value lands unquoted in a timer unit inside a heredoc of a root script
/// — a line break in it could end that heredoc or add a directive — so the
/// install builders do not rely on their callers alone.
String checkOnCalendar(String onCalendar) {
  if (!_onCalendarRe.hasMatch(onCalendar)) {
    throw ArgumentError.value(
        onCalendar, 'onCalendar', 'kein gültiger Zeitplan');
  }
  return onCalendar;
}

/// The two halves of the status-probe fragment that reports the installed
/// schedule, with the unit name between them. Prints `ONCALENDAR <value>`:
/// the `OnCalendar=` line of the timer unit as the app wrote it — every app
/// version wrote that unit to this path, with this one line. Without a timer
/// the value is empty. No sudo: unit files are world-readable.
const String onCalendarProbeHead =
    'echo "ONCALENDAR \$(sed -n \'s/^OnCalendar=//p\' /etc/systemd/system/';
const String onCalendarProbeTail = '.timer 2>/dev/null | head -n 1)"';

/// The installed schedule in a status probe's output. Null when the probe
/// reports none (no timer, an unreadable unit, a cut-off answer) or something
/// the app does not build ([checkOnCalendar]) — a unit edited by hand.
String? parseInstalledOnCalendar(String statusOutput) {
  for (final line in statusOutput.split('\n')) {
    final t = line.trim();
    if (t.startsWith('ONCALENDAR ')) {
      final value = t.substring(11).trim();
      return _onCalendarRe.hasMatch(value) ? value : null;
    }
  }
  return null;
}

/// Where systemd remembers when a `Persistent=true` timer last fired. A timer
/// that is started while this file says a run was due since then triggers at
/// once — so the remove scripts take it along: left behind, it would start
/// the job the moment the timer is set up again. Never `touch` it: its mtime
/// means "last run".
String timerStampPath(String unit) =>
    '/var/lib/systemd/timers/stamp-$unit.timer';
