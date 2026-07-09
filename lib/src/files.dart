/// Lightweight remote file browser over the normal SSH exec channel (ls +
/// base64) — no separate SFTP subsystem, so the FakeSshRunner covers it too.
/// Pure command builders, listing parser and path helpers (unit-testable).
library;

import 'commands.dart' show shSingleQuote;

/// Lists a directory (sudo, so root-only paths work too). `-p` marks dirs with
/// a trailing slash, `-A` shows dotfiles but not `.`/`..`.
String buildListDirCommand(String path) =>
    "sudo -S -p '' ls -1Ap ${shSingleQuote(path)} 2>&1";

/// Max bytes fetched for a file preview — caps memory so tapping a multi-GB
/// log/db/.img can't OOM the app.
const int kFilePreviewLimit = 512 * 1024;

/// Reads (up to [kFilePreviewLimit] bytes of) a file base64-encoded, so any
/// bytes survive the text channel intact. The size cap is server-side.
String buildReadFileCommand(String path) =>
    "sudo -S -p '' head -c $kFilePreviewLimit ${shSingleQuote(path)} 2>/dev/null | base64";

/// Max bytes for an upload — keeps the base64 payload (transported inside the
/// script over stdin) and the app's memory bounded.
const int kFileUploadLimit = 8 * 1024 * 1024;

/// Writes [base64Content] (a whole file) to [path] as root. The payload is
/// base64 (safe charset) and single-quoted, so arbitrary bytes/names can't
/// inject shell. Decodes into a temp file in the SAME directory, then `mv -f`
/// (atomic rename) so a half-written upload never truncates an existing file.
/// Prints `UPLOAD_OK` — the caller verifies that marker, not the exit code.
String buildUploadScript({required String path, required String base64Content}) {
  final q = shSingleQuote(path);
  return 'set -e\n'
      'dir=\$(dirname $q)\n'
      'tmp=\$(mktemp "\$dir/.pitool-up.XXXXXX")\n'
      'printf %s ${shSingleQuote(base64Content)} | base64 -d > "\$tmp"\n'
      'chmod 644 "\$tmp"\n'
      'mv -f "\$tmp" $q\n'
      'echo UPLOAD_OK\n';
}

/// Deletes a file (`rm -f`) or directory (`rm -rf`) as root. `--` stops option
/// parsing and the path is single-quoted.
String buildDeleteCommand({required String path, required bool isDir}) =>
    // LC_ALL=C so isSudoPasswordFailure can flag a rejected password (localized
    // Pis print a translated sudo error otherwise).
    "LC_ALL=C sudo -S -p '' rm -${isDir ? 'rf' : 'f'} -- ${shSingleQuote(path)}";

/// One directory entry.
typedef DirEntry = ({String name, bool isDir});

/// Parses [buildListDirCommand] output: dirs first, then files, alphabetical.
/// Skips error lines (permission denied, no such file) and `.`/`..`.
List<DirEntry> parseDirListing(String out) {
  final entries = <DirEntry>[];
  for (final raw in out.split('\n')) {
    final l = raw.trimRight();
    if (l.isEmpty) continue;
    if (l.startsWith('ls:') ||
        l.contains('Permission denied') ||
        l.contains('No such file')) {
      continue;
    }
    final isDir = l.endsWith('/');
    final name = isDir ? l.substring(0, l.length - 1) : l;
    if (name.isEmpty || name == '.' || name == '..') continue;
    entries.add((name: name, isDir: isDir));
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
