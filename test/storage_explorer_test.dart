import 'package:evcc_updater/src/storage_explorer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatBytes', () {
    test('scales B/KB/MB/GB with one decimal', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });
  });

  group('buildStorageProbe', () {
    test('sudo probe with du + find and a quoted path', () {
      final cmd = buildStorageProbe('/home/pi');
      expect(cmd, startsWith('LC_ALL=C sudo -S sh -c '));
      expect(cmd, contains('__DU__'));
      expect(cmd, contains('du -x'));
      expect(cmd, contains('-maxdepth 1'));
      expect(cmd, contains('__FIND__'));
    });

    test('a path with a quote is shell-escaped', () {
      final cmd = buildStorageProbe("/x';reboot;'");
      expect(cmd, contains(r"'\''"));
      expect(cmd, isNot(contains('du -x -b -d1 /x;reboot')));
    });
  });

  group('parseStorageBreakdown', () {
    const out = '''
__DU__
4096\t/home/pi/.cache
20480\t/home/pi/big-dir
30000\t/home/pi
__FIND__
100000\t/home/pi/huge.img
50\t/home/pi/notes.txt
''';

    test('merges dirs + files, drops the query total, sorts biggest first', () {
      final r = parseStorageBreakdown(out, queryPath: '/home/pi');
      expect(r.map((e) => e.name),
          ['huge.img', 'big-dir', '.cache', 'notes.txt']);
      expect(r.first.bytes, 100000);
      expect(r.first.isDir, isFalse);
      // The dir total line for the query path itself is excluded.
      expect(r.any((e) => e.name == 'pi'), isFalse);
      // Dirs vs files classified from their section.
      expect(r.firstWhere((e) => e.name == 'big-dir').isDir, isTrue);
      expect(r.firstWhere((e) => e.name == '.cache').isDir, isTrue);
    });

    test('garbled output yields no entries, never throws', () {
      expect(parseStorageBreakdown('nonsense', queryPath: '/x'), isEmpty);
    });
  });
}
