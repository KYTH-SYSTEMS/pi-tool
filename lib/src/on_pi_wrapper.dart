/// Generation stamp of the on-Pi timer wrappers (auto-update, scheduled
/// backups, health alerts).
///
/// A wrapper is written to the Pi when its timer is set up and stays there: a
/// fix made in the app does not reach a Pi until that timer is set up again.
/// So every wrapper carries [wrapperStampLine] as its second line, every
/// status probe reports whether the installed file has it, and the sheet of a
/// timer whose wrapper is older says so. Pure + Flutter-free.
///
/// Raise [wrapperGeneration] whenever the behaviour of a wrapper changes.
library;

/// 2 = v0.71.0: tar gets only existing paths, the Pi-hole export is not picked
/// by exit code, the status line names failures, alerts are remembered only
/// once delivered. Wrappers from before carry no stamp at all.
///
/// 3 (after v0.71.0): the alerts wrapper refreshes the package lists itself,
/// debounces by problem class and reads its ntfy destination from a root-only
/// file; the auto-update wrapper repairs and waits for apt locks like a
/// Pi-Job, reports package lists that did not load, keeps a log, finishes
/// when systemd asks it to stop and ignores a start right after its setup.
/// The backup wrapper is unchanged — the number is shared.
const int wrapperGeneration = 3;

/// Second line of every wrapper, right after the shebang.
const String wrapperStampLine = '# pi-tool-wrapper $wrapperGeneration';

/// The two halves of the status-probe fragment, with the unit name between
/// them (kept as constants so the probes stay compile-time strings). Prints
/// `WRAPPER current`, `WRAPPER old` or `WRAPPER none`. No sudo: the wrappers
/// are world-readable — which is why nothing secret may be written into one
/// (the ntfy destination of the alerts wrapper has a file of its own).
const String wrapperProbeHead = 'echo "WRAPPER \$(f=/usr/local/lib/';
const String wrapperProbeTail = '.sh; if [ -f "\$f" ]; then '
    'grep -qxF \'$wrapperStampLine\' "\$f" && echo current || echo old; '
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

/// Where systemd remembers when a `Persistent=true` timer last fired. A timer
/// that is started while this file says a run was due since then triggers at
/// once — so the remove scripts take it along: left behind, it would start
/// the job the moment the timer is set up again. Never `touch` it: its mtime
/// means "last run".
String timerStampPath(String unit) =>
    '/var/lib/systemd/timers/stamp-$unit.timer';
