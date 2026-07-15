import 'package:evcc_updater/src/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isGatedTab', () {
    test('Verwaltung is always open', () {
      expect(isGatedTab(kTabVerwaltung), isFalse);
    });
    test('Automatik/Terminal/Dateien are gated', () {
      expect(isGatedTab(kTabAutomatik), isTrue);
      expect(isGatedTab(kTabTerminal), isTrue);
      expect(isGatedTab(kTabDateien), isTrue);
    });
  });

  group('tabAllowed', () {
    test('gated tabs need a connection', () {
      expect(tabAllowed(kTabTerminal, connected: false), isFalse);
      expect(tabAllowed(kTabTerminal, connected: true), isTrue);
    });
    test('Verwaltung is allowed even when disconnected', () {
      expect(tabAllowed(kTabVerwaltung, connected: false), isTrue);
    });
  });

  group('tabAfterDisconnect', () {
    test('a gated tab falls back to Verwaltung', () {
      expect(tabAfterDisconnect(kTabTerminal), kTabVerwaltung);
      expect(tabAfterDisconnect(kTabDateien), kTabVerwaltung);
    });
    test('Verwaltung stays put', () {
      expect(tabAfterDisconnect(kTabVerwaltung), kTabVerwaltung);
    });
  });
}
