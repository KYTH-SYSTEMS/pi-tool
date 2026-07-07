/// Lightweight remote file browser over the normal SSH exec channel (ls +
/// base64) — no separate SFTP subsystem, so the FakeSshRunner covers it too.
/// Pure command builders, listing parser and path helpers (unit-testable).
library;

import 'commands.dart' show shSingleQuote;

/// Lists a directory (sudo, so root-only paths work too). `-p` marks dirs with
/// a trailing slash, `-A` shows dotfiles but not `.`/`..`.
String buildListDirCommand(String path) =>
    "sudo -S -p '' ls -1Ap ${shSingleQuote(path)} 2>&1";

/// Reads a file base64-encoded, so any bytes survive the text channel intact.
String buildReadFileCommand(String path) =>
    "sudo -S -p '' base64 ${shSingleQuote(path)} 2>&1";

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
