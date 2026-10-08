import 'package:evcc_updater/src/profile_transfer.dart';
import 'package:evcc_updater/src/profiles.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Small iteration count so the PBKDF2 stays fast in tests; the production
  // default (kExportKdfIterations) is much higher.
  const fastIters = 500;

  group('profile export encryption', () {
    test('round-trips content with the right passphrase', () async {
      const secret = '{"profiles":[{"name":"S","password":"geheim"}]}';
      final envelope = await encryptProfileExport(secret, 'korrekt batterie',
          iterations: fastIters);
      // The envelope must never contain the plaintext or the passphrase.
      expect(envelope, isNot(contains('geheim')));
      expect(envelope, isNot(contains('korrekt batterie')));
      expect(envelope, contains(kProfileExportFormat));

      final back =
          await decryptProfileExport(envelope, 'korrekt batterie');
      expect(back, secret);
    });

    test('wrong passphrase fails with a clear error', () async {
      final envelope =
          await encryptProfileExport('data', 'richtig', iterations: fastIters);
      await expectLater(
        decryptProfileExport(envelope, 'falsch'),
        throwsA(isA<ProfileTransferException>()
            .having((e) => e.message, 'message', contains('Passphrase'))),
      );
    });

    test('tampered ciphertext is rejected (authenticated encryption)',
        () async {
      final envelope =
          await encryptProfileExport('data', 'pw', iterations: fastIters);
      // Flip a character inside the base64 data field.
      final tampered = envelope.replaceFirst('"data":"A', '"data":"B');
      await expectLater(
        decryptProfileExport(
            tampered == envelope
                ? envelope.replaceFirst(RegExp(r'"data":"..'), '"data":"zz')
                : tampered,
            'pw'),
        throwsA(isA<ProfileTransferException>()),
      );
    });

    test('garbage / foreign JSON is rejected as not-an-export', () async {
      await expectLater(
        decryptProfileExport('not json at all', 'pw'),
        throwsA(isA<ProfileTransferException>()
            .having((e) => e.message, 'message', contains('keine Pi-Tool'))),
      );
      await expectLater(
        decryptProfileExport('{"format":"something-else"}', 'pw'),
        throwsA(isA<ProfileTransferException>()),
      );
    });

    test('a crafted iteration bomb is capped (no DoS via import file)',
        () async {
      final envelope =
          await encryptProfileExport('data', 'pw', iterations: fastIters);
      final bomb = envelope.replaceFirst(
          '"iterations":$fastIters', '"iterations":999999999');
      await expectLater(
        decryptProfileExport(bomb, 'pw'),
        throwsA(isA<ProfileTransferException>()),
      );
    });

    test('every export uses a fresh salt + nonce', () async {
      final a = await encryptProfileExport('x', 'pw', iterations: fastIters);
      final b = await encryptProfileExport('x', 'pw', iterations: fastIters);
      expect(a, isNot(b)); // deterministic output would leak via comparison
    });

    // The ntfy topic is kept per profile and works like a password: it has to
    // come along on a phone change, and only inside the sealed part.
    test('each profile\'s ntfy destination comes along, sealed', () async {
      const cfg = AppConfig(
        profiles: [
          Profile(
              name: 'Zuhause',
              host: '10.0.0.5',
              alertsNtfyServer: 'https://ntfy.example.org',
              alertsNtfyTopic: 'pi-tool-k7m2q9x4vb3dwz'),
          Profile(name: 'Eltern', host: '10.0.0.6'),
        ],
        activeIndex: 0,
        alertsNtfyTopic: 'app-weit-9999999999',
      );
      final envelope = await encryptProfileExport(
          encodeAppConfig(cfg), 'korrekt batterie',
          iterations: fastIters);
      expect(envelope, isNot(contains('pi-tool-k7m2q9x4vb3dwz')));
      expect(envelope, isNot(contains('app-weit-9999999999')));

      final imported = profilesForImport(parseAppConfig(
          await decryptProfileExport(envelope, 'korrekt batterie')));
      expect(imported.map((p) => p.name), ['Zuhause', 'Eltern']);
      expect(imported[0].alertsNtfyServer, 'https://ntfy.example.org');
      expect(imported[0].alertsNtfyTopic, 'pi-tool-k7m2q9x4vb3dwz');
      // No destination of its own: what the exporting app showed for it.
      expect(imported[1].alertsNtfyTopic, 'app-weit-9999999999');
    });
  });
}
