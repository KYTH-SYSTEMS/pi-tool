/// Encrypted profile export/import ("Handy-Wechsel"): the whole AppConfig JSON
/// is sealed with AES-256-GCM under a PBKDF2-derived key from a user
/// passphrase. Pure Dart (package:cryptography) — no native plugin, nothing in
/// the startup path. The file contains CREDENTIALS, hence authenticated
/// encryption and a deliberately slow KDF.
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Envelope format marker (bump on breaking changes).
const String kProfileExportFormat = 'pitool-profiles-v1';

/// PBKDF2-HMAC-SHA256 iterations for real exports. High enough to slow down
/// offline guessing, low enough for a one-off action on a phone (~1 s).
const int kExportKdfIterations = 200000;

/// Upper bound accepted on import — a crafted file must not be able to freeze
/// the app with a billion iterations.
const int _kMaxKdfIterations = 1000000;

class ProfileTransferException implements Exception {
  final String message;
  const ProfileTransferException(this.message);
  @override
  String toString() => message;
}

Pbkdf2 _kdf(int iterations) =>
    Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);

/// Seals [plaintext] (the AppConfig JSON) under [passphrase]. Returns the
/// envelope JSON to write to the export file.
Future<String> encryptProfileExport(
  String plaintext,
  String passphrase, {
  int iterations = kExportKdfIterations,
}) async {
  final salt = SecretKeyData.random(length: 16).bytes;
  final key = await _kdf(iterations)
      .deriveKeyFromPassword(password: passphrase, nonce: salt);
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
  final key = await _kdf(iterations)
      .deriveKeyFromPassword(password: passphrase, nonce: salt);
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
