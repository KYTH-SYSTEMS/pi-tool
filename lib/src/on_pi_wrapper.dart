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
const int wrapperGeneration = 2;

/// Second line of every wrapper, right after the shebang.
const String wrapperStampLine = '# pi-tool-wrapper $wrapperGeneration';

/// The two halves of the status-probe fragment, with the unit name between
/// them (kept as constants so the probes stay compile-time strings). Prints
/// `WRAPPER current`, `WRAPPER old` or `WRAPPER none`. No sudo: the wrappers
/// are world-readable.
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
