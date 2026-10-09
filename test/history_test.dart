import 'package:evcc_updater/src/history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('round-trips entries through encode/parse', () {
    final list = [
      const HistoryEntry(when: '2026-06-29 14:00', text: 'evcc 0.1 → 0.2'),
    ];
    final back = parseHistory(encodeHistory(list));
    expect(back.single.when, '2026-06-29 14:00');
    expect(back.single.text, 'evcc 0.1 → 0.2');
  });

  test('the profile an action ran on travels with the entry', () {
    final back = parseHistory(encodeHistory(const [
      HistoryEntry(
          when: '2026-10-09 08:15',
          text: 'Pi-hole aktualisiert.',
          profile: 'Keller'),
    ]));
    expect(back.single.profile, 'Keller');
    expect(back.single.text, 'Pi-hole aktualisiert.');
  });

  test('entries from before the profile was recorded still load', () {
    final back = parseHistory(
        '[{"when":"2026-06-29 14:00","text":"evcc 0.1 → 0.2"}]');
    expect(back.single.when, '2026-06-29 14:00');
    expect(back.single.text, 'evcc 0.1 → 0.2');
    expect(back.single.profile, isEmpty);
    // … and are written back the way they came: no empty profile key.
    expect(encodeHistory(back),
        '[{"when":"2026-06-29 14:00","text":"evcc 0.1 → 0.2"}]');
  });

  group('historySubtitle', () {
    const tagged = HistoryEntry(
        when: '2026-10-09 08:15', text: 'Pi neu gestartet.', profile: 'Keller');
    const untagged =
        HistoryEntry(when: '2026-06-29 14:00', text: 'evcc 0.1 → 0.2');

    test('names the Pi behind the time when there is more than one profile',
        () {
      expect(historySubtitle(tagged, showProfile: true),
          '2026-10-09 08:15 · Keller');
    });

    test('is the time alone with a single profile', () {
      expect(historySubtitle(tagged, showProfile: false), '2026-10-09 08:15');
    });

    test('is the time alone for an entry without a profile', () {
      expect(historySubtitle(untagged, showProfile: true), '2026-06-29 14:00');
    });
  });

  test('parseHistory tolerates empty/garbage input', () {
    expect(parseHistory(''), isEmpty);
    expect(parseHistory('not json'), isEmpty);
    expect(parseHistory('{}'), isEmpty);
  });

  test('capHistory keeps the newest N', () {
    final many =
        List.generate(40, (i) => HistoryEntry(when: 't$i', text: 'e$i'));
    final capped = capHistory(many, 30);
    expect(capped.length, 30);
    expect(capped.first.text, 'e10');
    expect(capped.last.text, 'e39');
  });

  test('formatTimestamp pads to yyyy-MM-dd HH:mm', () {
    expect(formatTimestamp(DateTime(2026, 6, 29, 9, 5)), '2026-06-29 09:05');
  });
}
