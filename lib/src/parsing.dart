/// Pure parsing and summarising of the output produced by the update sequence.
///
/// Kept free of I/O so every edge case can be unit-tested without a real SSH
/// session.
library;

/// Fixed-length mask used to redact the password from any visible text.
const String passwordMask = '********';

/// Parses the `dpkg-query -W -f='${db:Status-Status} ${Version}'` output.
///
/// Returns the version string only when the status word is exactly
/// `installed`. A removed-but-not-purged package (rc / `config-files` state)
/// still carries a Version in dpkg's database, so we must NOT treat it as
/// installed — otherwise the app would offer a no-op update for a removed evcc.
/// Returns null for any non-installed status or empty output.
String? parseInstalledVersion(String dpkgOutput) {
  final parts = dpkgOutput.trim().split(RegExp(r'\s+'));
  if (parts.length >= 2 && parts[0] == 'installed') return parts[1];
  return null;
}

/// Matches apt's "0 upgraded, 0 newly installed" summary, but only when the
/// count is a real zero — a leading digit (e.g. "10 upgraded") must not match.
final _nothingToUpgrade =
    RegExp(r'(?<!\d)0 upgraded, 0 newly installed');

/// Whether apt reports that nothing needs upgrading.
///
/// Note: for a full-upgrade this reflects the WHOLE system, not just evcc.
bool isAlreadyNewest(String aptOutput) {
  final out = aptOutput.toLowerCase();
  // A held-back package means an upgrade exists but is blocked — not "current".
  if (out.contains('kept back')) return false;
  return out.contains('is already the newest version') ||
      _nothingToUpgrade.hasMatch(out);
}

/// Extracts the backup archive path from the backup script's success marker
/// (`EVCC_BACKUP_OK ...`), or null when no backup was written.
String? parseBackupPath(String output) {
  const marker = 'EVCC_BACKUP_OK ';
  for (final line in output.split('\n')) {
    final t = line.trim();
    if (t.startsWith(marker)) {
      final path = t.substring(marker.length).trim();
      if (path.isNotEmpty) return path;
    }
  }
  return null;
}

/// Whether `systemctl is-active` reports the service as running.
bool isServiceActive(String systemctlOutput) {
  return systemctlOutput.trim() == 'active';
}

/// sudo's count of failed attempts as a line of its own — or behind sudo's
/// prompt, which ends without a line break (`sudo -S` after the last attempt).
final _sudoAttemptsLine = RegExp(
    r'^(?:\[sudo\] password for [^:]+: )?sudo: \d+ incorrect password attempts?$',
    caseSensitive: false);

/// Whether the output indicates that sudo rejected the password (C locale).
///
/// Matched per line, not as a substring of the whole output: a line that ENDS
/// with "Sorry, try again." (behind the prompt of `sudo -S` there is no line
/// break) or that IS "sudo: N incorrect password attempt(s)". The words alone
/// also occur in what a command prints — sudo's journal entry reads
/// "pi : 3 incorrect password attempts ; TTY=…" — and that is not a rejection.
/// Where stdout carries a payload (a file, a listing), hand in stderr only.
bool isSudoPasswordFailure(String output) {
  for (final raw in output.split('\n')) {
    final line = raw.trimRight();
    if (line.toLowerCase().endsWith('sorry, try again.') ||
        _sudoAttemptsLine.hasMatch(line)) {
      return true;
    }
  }
  return false;
}

/// dpkg's "(Reading database ... 45%" painting — matched without relying on the
/// English wording, so the German translation ("(Lese Datenbank ... 45%") from a
/// third-party installer that doesn't set `LC_ALL=C` disappears just the same.
/// The informative summary ("… 214428 files and directories currently
/// installed.)") does NOT match: it ends in text, not in the bare `...`/`NN%`.
final _dpkgReadProgress = RegExp(r'^\([^()]{0,60}\.\.\.\s*(?:\d{1,3}\s*%)?$');

/// debconf unpacking its templates, and apt's own progress bar. Same story:
/// both only ever appear because dpkg thinks it is painting a terminal.
final _debconfTemplates =
    RegExp(r'^Extracting templates from packages:\s*\d{1,3}%$');
final _aptProgressBar = RegExp(r'^Progress: \[\s*\d{1,3}%\]$');

bool _isProgressPainting(String line) {
  final t = line.trim();
  if (t.isEmpty) return false;
  return _dpkgReadProgress.hasMatch(t) ||
      _debconfTemplates.hasMatch(t) ||
      _aptProgressBar.hasMatch(t);
}

/// Strips the progress painting apt/dpkg emit for a terminal that isn't there.
///
/// apt hands dpkg a pseudo-terminal by default (`Dpkg::Use-Pty`, on even when
/// nothing is attached to a terminal — Debian #860931), so dpkg repaints its
/// read-database line every 5 %, separated by carriage returns. On a terminal
/// those overwrite each other; in a log view they pile up as
/// "(Reading database ... 5% (Reading database ... 10% …" and bury the output
/// that actually matters.
///
/// Two things happen here: carriage returns become line breaks (so pty output
/// can't collapse into one endless line), and lines that are nothing but
/// progress painting are dropped. Every informative line survives — including
/// dpkg's file-count summary. Display only: parsing always sees the raw output.
String stripProgressNoise(String text) {
  if (text.isEmpty) return text;
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return normalized
      .split('\n')
      .where((line) => !_isProgressPainting(line))
      .join('\n');
}

/// A run of letters (with their combining marks) and digits: the word a
/// password can sit inside.
final _wordRun = RegExp(r'[\p{L}\p{M}\p{N}]+', unicode: true);

/// Masks every literal occurrence of [password] in [text] with [passwordMask].
/// An empty [password] leaves [text] untouched.
///
/// A match is never cut out of the word around it: where the password sits
/// inside a longer run of letters and digits, the whole run becomes ONE mask.
/// "********pi" for `raspberrypi` shows where the password ends — and with the
/// old default password, the password itself. Matches that touch or overlap
/// share one mask too, so neither position nor length nor count can be read
/// off a shared log.
String redactPassword(String text, String password) {
  if (password.isEmpty) return text;
  // Defense in depth: on a NOPASSWD-sudo Pi the password line isn't consumed by
  // `sudo -S`, so `bash -s` may echo it word-split ("bash: line 1: <word>: not
  // found"). A literal full-string match would miss those fragments, so also
  // mask each whitespace-separated part (length ≥ 3 to avoid over-redacting).
  final needles = <String>{
    password,
    for (final part in password.split(RegExp(r'\s+')))
      if (part.length >= 3) part,
  };
  // Per code unit: masked or not. Only allocated once something matches.
  List<bool>? masked;
  for (final needle in needles) {
    // Next search from i + 1, not from behind the match: an occurrence that
    // overlaps the previous one counts as well.
    for (var i = text.indexOf(needle);
        i >= 0;
        i = text.indexOf(needle, i + 1)) {
      (masked ??= List<bool>.filled(text.length, false))
          .fillRange(i, i + needle.length, true);
    }
  }
  if (masked == null) return text;
  // Widen each match to its word: a run that holds a masked unit or borders
  // on one goes under the mask as a whole.
  for (final run in _wordRun.allMatches(text)) {
    final from = run.start > 0 ? run.start - 1 : 0;
    final to = run.end < text.length ? run.end + 1 : text.length;
    if (masked.sublist(from, to).contains(true)) {
      masked.fillRange(run.start, run.end, true);
    }
  }
  final out = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final start = i;
    final mask = masked[i];
    while (i < text.length && masked[i] == mask) {
      i++;
    }
    out.write(mask ? passwordMask : text.substring(start, i));
  }
  return out.toString();
}

/// Outcome category of a completed update run.
enum UpdateStatus {
  updated,
  alreadyCurrent,
  dryRunWouldUpdate,
  dryRunNoChange,
}

/// A human-facing summary of the run.
class UpdateSummary {
  final UpdateStatus status;
  final String message;
  final String? before;
  final String? after;

  const UpdateSummary({
    required this.status,
    required this.message,
    required this.before,
    required this.after,
  });
}

/// Turns the collected facts into a clear German result message.
///
/// [alreadyNewest] is interpreted in the scope of the chosen mode: for an
/// evcc-only run it means "evcc is current", for a [fullUpgrade] it means "the
/// whole system is current". The wording is branched accordingly so a
/// system-wide plan is never misreported as an evcc-specific update.
UpdateSummary summarize({
  required String? before,
  required String? after,
  required bool dryRun,
  required bool fullUpgrade,
  required bool alreadyNewest,
}) {
  if (dryRun) {
    if (fullUpgrade) {
      return UpdateSummary(
        status: alreadyNewest
            ? UpdateStatus.dryRunNoChange
            : UpdateStatus.dryRunWouldUpdate,
        message: alreadyNewest
            ? 'Probelauf: System ist komplett aktuell (evcc $before).'
            : 'Probelauf: System-Updates verfügbar (evcc installiert: $before).',
        before: before,
        after: after,
      );
    }
    return UpdateSummary(
      status: alreadyNewest
          ? UpdateStatus.dryRunNoChange
          : UpdateStatus.dryRunWouldUpdate,
      message: alreadyNewest
          ? 'Probelauf: evcc ist bereits aktuell ($before).'
          : 'Probelauf: Update für evcc verfügbar (installiert: $before).',
      before: before,
      after: after,
    );
  }

  final evccChanged = after != null && before != after;
  if (evccChanged) {
    return UpdateSummary(
      status: UpdateStatus.updated,
      message: 'evcc $before → $after aktualisiert.',
      before: before,
      after: after,
    );
  }

  if (fullUpgrade && !alreadyNewest) {
    return UpdateSummary(
      status: UpdateStatus.alreadyCurrent,
      message: 'evcc war schon aktuell ($before); '
          'übrige System-Pakete wurden aktualisiert.',
      before: before,
      after: after,
    );
  }

  return UpdateSummary(
    status: UpdateStatus.alreadyCurrent,
    message: 'evcc war schon aktuell ($before).',
    before: before,
    after: after,
  );
}
