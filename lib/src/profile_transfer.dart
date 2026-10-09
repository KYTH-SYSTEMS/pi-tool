/// Encrypted profile export/import ("Handy-Wechsel"): the whole AppConfig JSON
/// is sealed with AES-256-GCM under a PBKDF2-derived key from a user
/// passphrase. Pure Dart (package:cryptography) — no native plugin, nothing in
/// the startup path. The file contains CREDENTIALS, hence authenticated
/// encryption and a deliberately slow KDF.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart' show DartPbkdf2;

/// Envelope format marker (bump on breaking changes).
const String kProfileExportFormat = 'pitool-profiles-v1';

/// PBKDF2-HMAC-SHA256 iterations for real exports: the figure OWASP gives for
/// this KDF. The file holds root credentials, so guessing its passphrase
/// offline has to stay expensive. On a phone that is seconds of computing,
/// hence the background isolate in [_deriveKey]. A file keeps the count it was
/// written with (200000 up to v0.71.0) and is read with that.
const int kExportKdfIterations = 600000;

/// The shortest passphrase the export dialog accepts.
const int kExportMinPassphraseLength = 10;

/// Upper bound accepted on import — a crafted file must not be able to freeze
/// the app with a billion iterations.
const int _kMaxKdfIterations = 1000000;

/// From this many iterations on the key is derived in a background isolate.
/// Below it the derivation is one short burst that is not worth a second
/// isolate. No real export is that weak, only test files are — and a widget
/// test, with its fake clock, would wait forever for an isolate's answer.
const int _kIsolateKdfIterations = 2000;

class ProfileTransferException implements Exception {
  final String message;
  const ProfileTransferException(this.message);
  @override
  String toString() => message;
}

Pbkdf2 _kdf(int iterations) =>
    Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);

/// The AES key for [passphrase] and [salt]. A real export's iteration count
/// is computed off the calling isolate, so the UI does not stand still for it.
Future<SecretKey> _deriveKey(
    String passphrase, List<int> salt, int iterations) async {
  if (iterations >= _kIsolateKdfIterations) {
    try {
      return SecretKey(await _deriveKeyInIsolate(
          passphrase, Uint8List.fromList(salt), iterations));
    } catch (_) {
      // No second isolate to be had: derive here instead. The UI stutters for
      // the duration, but the export or import still works.
    }
  }
  return _kdf(iterations)
      .deriveKeyFromPassword(password: passphrase, nonce: salt);
}

/// A function of its own, so that the closure sent to the isolate captures
/// these three values and nothing else of the caller.
Future<Uint8List> _deriveKeyInIsolate(
        String passphrase, Uint8List salt, int iterations) =>
    Isolate.run(() => _deriveKeyBytes(passphrase, salt, iterations));

/// Runs in the background isolate. `pauseFrequency: 0`: by default DartPbkdf2
/// sleeps every 2000 iterations to let the UI breathe, which an isolate of
/// its own has no use for.
Future<Uint8List> _deriveKeyBytes(
    String passphrase, Uint8List salt, int iterations) async {
  final key = await DartPbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
    pauseFrequency: 0,
  ).deriveKeyFromPassword(password: passphrase, nonce: salt);
  return Uint8List.fromList(await key.extractBytes());
}

/// Seals [plaintext] (the AppConfig JSON) under [passphrase]. Returns the
/// envelope JSON to write to the export file.
Future<String> encryptProfileExport(
  String plaintext,
  String passphrase, {
  int iterations = kExportKdfIterations,
}) async {
  final salt = SecretKeyData.random(length: 16).bytes;
  final key = await _deriveKey(passphrase, salt, iterations);
  final algo = AesGcm.with256bits();
  final nonce = algo.newNonce();
  final box = await algo.encrypt(utf8.encode(plaintext),
      secretKey: key, nonce: nonce);
  return jsonEncode({
    'format': kProfileExportFormat,
    'kdf': 'pbkdf2-hmac-sha256',
    'iterations': iterations,
    'salt': base64.encode(salt),
    'nonce': base64.encode(box.nonce),
    'cipher': 'aes-256-gcm',
    'data': base64.encode(box.cipherText),
    'mac': base64.encode(box.mac.bytes),
  });
}

/// Opens an export [envelope] with [passphrase] and returns the AppConfig
/// JSON. Throws [ProfileTransferException] with a German message on any
/// problem (wrong file, wrong passphrase, tampering).
Future<String> decryptProfileExport(
    String envelope, String passphrase) async {
  final Map<String, dynamic> j;
  try {
    final decoded = jsonDecode(envelope);
    if (decoded is! Map<String, dynamic>) throw const FormatException();
    j = decoded;
  } catch (_) {
    throw const ProfileTransferException(
        'Das ist keine Pi-Tool-Export-Datei.');
  }
  if (j['format'] != kProfileExportFormat) {
    throw const ProfileTransferException(
        'Das ist keine Pi-Tool-Export-Datei (oder ein neueres Format).');
  }
  final iterations = j['iterations'];
  if (iterations is! int || iterations < 1 || iterations > _kMaxKdfIterations) {
    throw const ProfileTransferException('Export-Datei ist beschädigt.');
  }
  final List<int> salt, nonce, data, mac;
  try {
    salt = base64.decode(j['salt'] as String);
    nonce = base64.decode(j['nonce'] as String);
    data = base64.decode(j['data'] as String);
    mac = base64.decode(j['mac'] as String);
  } catch (_) {
    throw const ProfileTransferException('Export-Datei ist beschädigt.');
  }
  final key = await _deriveKey(passphrase, salt, iterations);
  try {
    final clear = await AesGcm.with256bits().decrypt(
      SecretBox(data, nonce: nonce, mac: Mac(mac)),
      secretKey: key,
    );
    return utf8.decode(clear);
  } catch (_) {
    // GCM authentication failure — wrong passphrase or a modified file.
    throw const ProfileTransferException(
        'Falsche Passphrase (oder die Datei wurde verändert).');
  }
}
