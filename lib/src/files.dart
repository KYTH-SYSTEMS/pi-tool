/// Lightweight remote file browser over the normal SSH exec channel (find +
/// base64) — no separate SFTP subsystem, so the FakeSshRunner covers it too.
/// Pure command builders, listing parser and path helpers (unit-testable).
library;

import 'dart:typed_data';

import 'commands.dart' show shSingleQuote;

/// Max bytes for in-app editing of a file from the browser — keeps the editor
/// and the base64 write payload bounded (config-sized files, not logs/dumps).
const int kFileEditLimit = 256 * 1024;

/// Cheap text-vs-binary heuristic for the file browser's edit affordance:
/// a NUL byte or a high ratio of control bytes (outside tab/newline/CR) means
/// binary. UTF-8 multi-byte sequences (umlauts) pass untouched — only C0
/// control bytes count against the file.
bool isProbablyTextFile(Uint8List bytes) {
  if (bytes.isEmpty) return true;
  var control = 0;
  for (final b in bytes) {
    if (b == 0) return false; // NUL never appears in text files
    if (b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0D) control++;
  }
  return control / bytes.length < 0.05;
}

/// Lists a directory (sudo, so root-only paths work too): one
/// `<type>\t<name>\0` record per entry, dotfiles included, without `.`/`..`.
///
/// `%Y` is the type BEHIND a symlink (`d` for /bin -> usr/bin on a merged-usr
/// system, `N` for a dangling link) — `ls -p` marked such a link as a file and
/// it could not be entered. `-H` follows a link only when it is the directory
/// asked for. NUL-terminated because a name may hold anything else, a line
/// break included. Messages of sudo and find stay on stderr (LC_ALL=C: sudo's
/// are matched in English), so none of them can turn up as an entry.
String buildListDirCommand(String path) =>
    "LC_ALL=C sudo -S -p '' find -H ${shSingleQuote(path)} "
    r"-mindepth 1 -maxdepth 1 -printf '%Y\t%f\0'";

/// Max bytes fetched for a file preview — caps memory so tapping a multi-GB
/// log/db/.img can't OOM the app.
const int kFilePreviewLimit = 512 * 1024;

/// Reads (up to [kFilePreviewLimit] bytes of) a file base64-encoded, so any
/// bytes survive the text channel intact. The size cap is server-side.
///
/// A plain pipeline ends with the status of base64, whatever became of `head`
/// — a file that could not be read used to arrive as an empty one. With
/// `pipefail` a failed read (missing, a directory, an I/O error) is the status
/// of the command, and head's message stays on stderr. bash, like the root
/// scripts: not every `sh` (dash) knows pipefail.
String buildReadFileCommand(String path) =>
    "LC_ALL=C sudo -S -p '' bash -c "
    "'set -o pipefail; head -c $kFilePreviewLimit -- \"\$1\" | base64' "
    'bash ${shSingleQuote(path)}';

/// Max bytes for an upload — keeps the base64 payload (transported inside the
/// script over stdin) and the app's memory bounded.
const int kFileUploadLimit = 8 * 1024 * 1024;

/// Writes [base64Content] (a whole file) to [path] as root. The payload is
/// base64 (safe charset) and single-quoted, so arbitrary bytes/names can't
/// inject shell. Decodes into a temp file in the SAME directory, then `mv -f`
/// (atomic rename) so a half-written upload never truncates an existing file.
/// Prints `UPLOAD_OK` — the caller verifies that marker, not the exit code.
///
/// A new file is root's, 0644. One that replaces an existing file takes over
/// that file's owner and mode — a service user's 0600 `.env` stays what it
/// was. A directory at [path] is refused: `mv` would move the temp file INTO
/// it and report success. The temp file never outlives a failure.
String buildUploadScript({required String path, required String base64Content}) {
  return 'set -e\n'
      'dest=${shSingleQuote(path)}\n'
      'if [ -d "\$dest" ]; then\n'
      '  echo "Pi-Tool: Das Ziel ist ein Verzeichnis – nichts hochgeladen."\n'
      '  exit 1\n'
      'fi\n'
      'dir=\$(dirname "\$dest")\n'
      // The directory may legitimately not exist yet: the migration helper
      // uploads backups to /var/backups/… on a TARGET Pi that has never been
      // backed up (those dirs are created by the backup scripts, which run on
      // the source). Without this, mktemp fails and the whole migration dies
      // after the target was already installed. No-op for the file browser.
      'mkdir -p "\$dir"\n'
      'tmp=\$(mktemp "\$dir/.pitool-up.XXXXXX")\n'
      'trap \'rm -f "\$tmp"\' EXIT\n'
      'printf %s ${shSingleQuote(base64Content)} | base64 -d > "\$tmp"\n'
      'chmod 644 "\$tmp"\n'
      // Owner first: chown may clear mode bits that chmod then sets again.
      'if [ -f "\$dest" ]; then\n'
      '  chown --reference="\$dest" "\$tmp"\n'
      '  chmod --reference="\$dest" "\$tmp"\n'
      'fi\n'
      // -T: should a directory appear at the target after the check above,
      // mv fails instead of moving into it.
      'mv -fT "\$tmp" "\$dest"\n'
      'echo UPLOAD_OK\n';
}

/// Max bytes for a backup download to the phone — bounds the transient base64
/// string held in memory during the transfer.
const int kBackupDownloadLimit = 48 * 1024 * 1024;

/// File size in bytes (no sudo — the backup archives are world-readable 0644
/// by design, see the backup scripts).
String buildFileSizeCommand(String path) => 'wc -c < ${shSingleQuote(path)}';

/// Streams a whole file base64-encoded (no sudo). The caller checks the size
/// via [buildFileSizeCommand] BEFORE running this ([kBackupDownloadLimit]).
String buildDownloadFileCommand(String path) =>
    'base64 -- ${shSingleQuote(path)}';

/// Deletes a file (`rm -f`) or directory (`rm -rf`) as root. `--` stops option
/// parsing and the path is single-quoted.
String buildDeleteCommand({required String path, required bool isDir}) =>
    // LC_ALL=C so isSudoPasswordFailure can flag a rejected password (localized
    // Pis print a translated sudo error otherwise).
    "LC_ALL=C sudo -S -p '' rm -${isDir ? 'rf' : 'f'} -- ${shSingleQuote(path)}";

/// One directory entry.
typedef DirEntry = ({String name, bool isDir});

/// Parses [buildListDirCommand] output: dirs first, then files, alphabetical.
/// A record is `<type>\t<name>` up to its NUL; what follows the last NUL was
/// cut off and is no entry. The name is taken as it is — trimmed, it would
/// name another file in the paths of open and delete.
List<DirEntry> parseDirListing(String out) {
  final entries = <DirEntry>[];
  final records = out.split('\x00')..removeLast();
  for (final r in records) {
    if (r.length < 3 || r[1] != '\t') continue;
    final name = r.substring(2);
    if (name == '.' || name == '..') continue;
    entries.add((name: name, isDir: r[0] == 'd'));
  }
  entries.sort((a, b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return entries;
}

/// Joins a remote directory and a child name with a single slash.
String joinRemotePath(String base, String name) =>
    base.endsWith('/') ? '$base$name' : '$base/$name';

/// The parent directory of [path] (clamped at root).
String parentRemotePath(String path) {
  if (path == '/' || path.isEmpty) return '/';
  final trimmed =
      path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  final i = trimmed.lastIndexOf('/');
  return i <= 0 ? '/' : trimmed.substring(0, i);
}
