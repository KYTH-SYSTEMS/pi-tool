/// "What's eating my disk?" — a read-only sudo probe (du for subdirs + find for
/// files at one level) plus a pure parser + a byte formatter. Nothing mutates.
library;

import 'commands.dart' show shSingleQuote;

/// One entry in the storage view: a directory total or a file, biggest first.
typedef DiskEntry = ({String name, int bytes, bool isDir, String path});

/// Human-readable size, one decimal (B stays whole).
String formatBytes(int b) {
  if (b < 1024) return '$b B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = b / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(1)} ${units[i]}';
}

/// Read-only usage probe for [path]: immediate subdirectory totals (`du`) and
/// files at this level (`find`), each in a marked section. sudo so root-owned
/// paths are measurable; `-x` stays on one filesystem.
String buildStorageProbe(String path) {
  final p = shSingleQuote(path);
  final script = 'echo __DU__; du -x -b -d1 $p 2>/dev/null; '
      "echo __FIND__; find $p -maxdepth 1 -type f -printf '%s\\t%p\\n' 2>/dev/null";
  return 'LC_ALL=C sudo -S sh -c ${shSingleQuote(script)}';
}

/// Parses [output] into entries, biggest first. The `du` total line for
/// [queryPath] itself is dropped (it's the sum, not a child).
List<DiskEntry> parseStorageBreakdown(String output, {required String queryPath}) {
  final query = queryPath.replaceAll(RegExp(r'/+$'), '');
  final out = <DiskEntry>[];
  var section = '';
  for (final raw in output.split('\n')) {
    final line = raw.trimRight();
    if (line == '__DU__') {
      section = 'DU';
      continue;
    }
    if (line == '__FIND__') {
      section = 'FIND';
      continue;
    }
    if (section.isEmpty || line.isEmpty) continue;
    final tab = line.indexOf('\t');
    if (tab <= 0) continue;
    final bytes = int.tryParse(line.substring(0, tab).trim());
    if (bytes == null) continue;
    final path = line.substring(tab + 1).replaceAll(RegExp(r'/+$'), '');
    if (path.isEmpty) continue;
    if (section == 'DU' && path == query) continue; // the total for the query
    out.add((
      name: path.split('/').last,
      bytes: bytes,
      isDir: section == 'DU',
      path: path,
    ));
  }
  out.sort((a, b) => b.bytes.compareTo(a.bytes));
  return out;
}
