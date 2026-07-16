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

/// Whether the output indicates that sudo rejected the password.
bool isSudoPasswordFailure(String output) {
  final out = output.toLowerCase();
  return out.contains('incorrect password') || out.contains('sorry, try again');
}

/// Replaces every literal occurrence of [password] in [text] with
/// [passwordMask]. An empty [password] leaves [text] untouched.
String redactPassword(String text, String password) {
  if (password.isEmpty) return text;
  var out = text.replaceAll(password, passwordMask);
  // Defense in depth: on a NOPASSWD-sudo Pi the password line isn't consumed by
  // `sudo -S`, so `bash -s` may echo it word-split ("bash: line 1: <word>: not
  // found"). A literal full-string match would miss those fragments, so also
  // mask each whitespace-separated part (length ≥ 3 to avoid over-redacting).
  for (final part in password.split(RegExp(r'\s+'))) {
    if (part.length >= 3 && part != password) {
      out = out.replaceAll(part, passwordMask);
    }
  }
  return out;
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
