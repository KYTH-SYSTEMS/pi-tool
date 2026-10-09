/// Generation stamp of the on-Pi timer wrappers (auto-update, scheduled
/// backups, health alerts).
///
/// A wrapper is written to the Pi when its timer is set up and stays there: a
/// fix made in the app does not reach a Pi until that timer is set up again.
/// So every wrapper carries its stamp line as its second line, every status
/// probe reports whether the installed file has it, and the sheet of a timer
/// whose wrapper is older says so. Pure + Flutter-free.
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

/// Second line of each wrapper, right after the shebang.
const String scheduledBackupWrapperStamp =
    '$_stampPrefix$scheduledBackupWrapperGeneration';
const String autoUpdateWrapperStamp =
    '$_stampPrefix$autoUpdateWrapperGeneration';
const String alertsWrapperStamp = '$_stampPrefix$alertsWrapperGeneration';

/// The three parts of the status-probe fragment: the unit name goes between
/// the first two, the stamp line of that unit's wrapper between the last two
/// (kept as constants so the probes stay compile-time strings). Prints
/// `WRAPPER current`, `WRAPPER old` or `WRAPPER none`. "old" is every file
/// without exactly that line — one stamped with another number as well as one
/// from before the stamps. No sudo: the wrappers are world-readable — which is
/// why nothing secret may be written into one (the ntfy destination of the
/// alerts wrapper has a file of its own).
const String wrapperProbeHead = 'echo "WRAPPER \$(f=/usr/local/lib/';
const String wrapperProbeMid = '.sh; if [ -f "\$f" ]; then grep -qxF \'';
const String wrapperProbeTail = '\' "\$f" && echo current || echo old; '
    'else echo none; fi)"';

/// Whether a status probe's output says the installed wrapper is from an
/// older generation. A missing wrapper or a probe without the line (an
/// unreadable file, a cut-off answer) is not "outdated" — there is nothing the
/// user could renew, or nothing known.
bool parseWrapperOutdated(String statusOutput) {
  for (final line in statusOutput.split('\n')) {
    if (line.trim() == 'WRAPPER old') return true;
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
