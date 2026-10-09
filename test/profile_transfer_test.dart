import 'dart:convert';

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
      // Flip one bit of the ciphertext itself: unlike swapping base64
      // characters this changes the data whatever the random bytes are.
      final j = jsonDecode(envelope) as Map<String, dynamic>;
      final data = base64.decode(j['data'] as String);
      data[0] ^= 0x01;
      j['data'] = base64.encode(data);
      await expectLater(
        decryptProfileExport(jsonEncode(j), 'pw'),
        throwsA(isA<ProfileTransferException>()
            .having((e) => e.message, 'message', contains('verändert'))),
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

  // The real parameters, slow on purpose — these derive the key in the
  // background isolate, which the fast tests above never reach.
  group('profile export with the real parameters', () {
    // Seconds per derivation on a desktop; a loaded CI runner gets more room
    // than the default 30 s.
    const slow = Timeout(Duration(minutes: 3));

    test('the export asks for 600000 rounds and at least 10 characters', () {
      expect(kExportKdfIterations, 600000);
      expect(kExportMinPassphraseLength, 10);
    });

    test('an export written with the defaults records its rounds and reads back',
        () async {
      const secret = '{"profiles":[{"name":"S","password":"geheim"}]}';
      final envelope = await encryptProfileExport(secret, 'korrekt batterie');
      final j = jsonDecode(envelope) as Map<String, dynamic>;
      expect(j['iterations'], 600000);
      expect(await decryptProfileExport(envelope, 'korrekt batterie'), secret);
    }, timeout: slow);

    test('a file written by v0.71.0 (200000 rounds) still imports', () async {
      // Produced by the v0.71.0 code. The round count is read from the file.
      const v071 = '{"format":"pitool-profiles-v1","kdf":"pbkdf2-hmac-sha256",'
          '"iterations":200000,"salt":"li7EmcXs4D4C3NF1RaqwsQ==",'
          '"nonce":"M9zyBvqQ+gH+/OZk","cipher":"aes-256-gcm",'
          '"data":"tJ3kF5H7rl4/amWj15DvdNBNIwcMZ7lhb6HeDumcqZrFzBINXbDBH4cV9Hcp'
          'UBAibo6yrN4+eIScz2HkltKqFA2R0rSs","mac":"Nl7xkFRVEepmPq2sgO+U1g=="}';
      expect(
        await decryptProfileExport(v071, 'altes passwort'),
        '{"profiles":[{"name":"Zuhause","host":"192.0.2.10"}],"activeIndex":0}',
      );
      await expectLater(
        decryptProfileExport(v071, 'falsches passwort'),
        throwsA(isA<ProfileTransferException>()
            .having((e) => e.message, 'message', contains('Passphrase'))),
      );
    }, timeout: slow);
  });
}
