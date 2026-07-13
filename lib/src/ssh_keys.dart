/// Client-side SSH key generation. The private key is created ON THE PHONE
/// (pure Dart, `cryptography`) and never touches the Pi — only the public key is
/// installed into `~/.ssh/authorized_keys`. Encoders are pure + unit-tested; the
/// private-key round-trip is proven by loading it back with `SSHKeyPair.fromPem`.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'commands.dart' show shSingleQuote;

/// A freshly generated Ed25519 key: the OpenSSH private key (to store in the
/// profile) and the `authorized_keys` line (to install on the Pi).
class GeneratedSshKey {
  const GeneratedSshKey(
      {required this.privateKeyPem, required this.publicKeyLine});
  final String privateKeyPem;
  final String publicKeyLine;
}

/// SSH wire "string": a 4-byte big-endian length prefix + the bytes.
Uint8List _sshString(List<int> bytes) {
  final b = BytesBuilder();
  b.add(_u32(bytes.length));
  b.add(bytes);
  return b.toBytes();
}

Uint8List _u32(int n) =>
    Uint8List.fromList([(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]);

/// The `ssh-ed25519` public key blob: string "ssh-ed25519" + string pub.
Uint8List _publicBlob(Uint8List publicKey) {
  final b = BytesBuilder();
  b.add(_sshString(utf8.encode('ssh-ed25519')));
  b.add(_sshString(publicKey));
  return b.toBytes();
}

/// Restricts a key comment to a safe token — a newline (or any other char) in
/// the comment must never break the single-line `authorized_keys` format or
/// inject a second key entry.
String _safeComment(String c) {
  final cleaned = c.replaceAll(RegExp(r'[^A-Za-z0-9@._+-]'), '-');
  return cleaned.isEmpty ? 'pi-tool' : cleaned;
}

/// One `authorized_keys` line: `ssh-ed25519 <base64 blob> <comment>`.
String encodeAuthorizedKey(
    {required Uint8List publicKey, required String comment}) {
  return 'ssh-ed25519 ${base64.encode(_publicBlob(publicKey))} ${_safeComment(comment)}';
}

/// Encodes an **unencrypted** `openssh-key-v1` private key (PEM). [seed] is the
/// 32-byte Ed25519 seed, [publicKey] the 32-byte public key.
String encodeOpenSshPrivateKey({
  required Uint8List seed,
  required Uint8List publicKey,
  required String comment,
  Random? random,
}) {
  final rnd = random ?? Random.secure();
  final pubBlob = _publicBlob(publicKey);

  // Private section: checkint (twice), keytype, pub, priv (seed||pub), comment.
  final check = Uint8List.fromList(List.generate(4, (_) => rnd.nextInt(256)));
  final priv = BytesBuilder();
  priv.add(check);
  priv.add(check);
  priv.add(_sshString(utf8.encode('ssh-ed25519')));
  priv.add(_sshString(publicKey));
  priv.add(_sshString(Uint8List.fromList([...seed, ...publicKey])));
  priv.add(_sshString(utf8.encode(_safeComment(comment))));
  // Pad to the cipher block size (8 for "none") with 1,2,3,…
  var privBytes = priv.toBytes();
  final pad = (8 - (privBytes.length % 8)) % 8;
  if (pad > 0) {
    privBytes = Uint8List.fromList(
        [...privBytes, for (var i = 1; i <= pad; i++) i]);
  }

  final body = BytesBuilder();
  body.add(utf8.encode('openssh-key-v1'));
  body.add([0]); // NUL terminator
  body.add(_sshString(utf8.encode('none'))); // ciphername
  body.add(_sshString(utf8.encode('none'))); // kdfname
  body.add(_sshString(const [])); // kdf options (empty)
  body.add(_u32(1)); // number of keys
  body.add(_sshString(pubBlob)); // public key
  body.add(_sshString(privBytes)); // private section

  final b64 = base64.encode(body.toBytes());
  final lines = <String>[];
  for (var i = 0; i < b64.length; i += 70) {
    lines.add(b64.substring(i, i + 70 > b64.length ? b64.length : i + 70));
  }
  return '-----BEGIN OPENSSH PRIVATE KEY-----\n'
      '${lines.join('\n')}\n'
      '-----END OPENSSH PRIVATE KEY-----\n';
}

/// Generates a fresh Ed25519 key pair on the device.
Future<GeneratedSshKey> generateSshKey({String comment = 'pi-tool'}) async {
  final kp = await Ed25519().newKeyPair();
  final seed = Uint8List.fromList(await kp.extractPrivateKeyBytes());
  final publicKey = Uint8List.fromList((await kp.extractPublicKey()).bytes);
  return GeneratedSshKey(
    privateKeyPem:
        encodeOpenSshPrivateKey(seed: seed, publicKey: publicKey, comment: comment),
    publicKeyLine: encodeAuthorizedKey(publicKey: publicKey, comment: comment),
  );
}

/// Idempotently installs [publicKeyLine] into the connecting user's
/// `~/.ssh/authorized_keys` (no root needed — it's the user's own home). Prints
/// `KEY_INSTALLED` on success (the caller verifies the marker, not the exit).
String buildInstallAuthorizedKeyScript(String publicKeyLine) {
  final q = shSingleQuote(publicKeyLine);
  return 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && '
      'touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && '
      '{ grep -qxF $q ~/.ssh/authorized_keys || echo $q >> ~/.ssh/authorized_keys; } && '
      'echo KEY_INSTALLED';
}
