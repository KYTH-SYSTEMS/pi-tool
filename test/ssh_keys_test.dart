import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:evcc_updater/src/ssh_keys.dart';
import 'package:flutter_test/flutter_test.dart';

import 'on_pi_sandbox.dart';

void main() {
  group('encodeAuthorizedKey', () {
    test('is a valid ssh-ed25519 line whose blob re-encodes the key type', () {
      final pub = Uint8List.fromList(List.generate(32, (i) => i));
      final line = encodeAuthorizedKey(publicKey: pub, comment: 'pi-tool@handy');
      expect(line, startsWith('ssh-ed25519 '));
      expect(line, endsWith(' pi-tool@handy'));
      // The base64 middle field decodes to: string "ssh-ed25519" + string pub.
      final blob = base64.decode(line.split(' ')[1]);
      // First SSH string: 4-byte length (11) + "ssh-ed25519".
      expect(blob.sublist(0, 4), [0, 0, 0, 11]);
      expect(utf8.decode(blob.sublist(4, 15)), 'ssh-ed25519');
      // Then a 32-byte string = our public key.
      expect(blob.sublist(15, 19), [0, 0, 0, 32]);
      expect(blob.sublist(19, 51), pub);
    });

    test('sanitises a hostile comment (no authorized_keys line injection)', () {
      final pub = Uint8List(32);
      final line = encodeAuthorizedKey(
          publicKey: pub, comment: 'evil\nssh-rsa AAAAB3Nz backdoor');
      // Exactly one line — no newline smuggled a second key in.
      expect(line.split('\n'), hasLength(1));
      expect(line, isNot(contains(' ssh-rsa ')));
    });
  });

  group('encodeOpenSshPrivateKey', () {
    test('wraps a PEM that dartssh2 can actually load (round-trip)', () {
      // A fixed 32-byte seed + matching public (arbitrary here; loadability is
      // what proves the openssh-key-v1 framing is correct).
      final seed = Uint8List.fromList(List.generate(32, (i) => (i * 7) & 0xff));
      final pub = Uint8List.fromList(List.generate(32, (i) => (i * 3) & 0xff));
      final pem =
          encodeOpenSshPrivateKey(seed: seed, publicKey: pub, comment: 'x');
      expect(pem, startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'));
      expect(pem.trimRight(), endsWith('-----END OPENSSH PRIVATE KEY-----'));
      // The real proof: dartssh2 parses it without error → framing is valid.
      final keys = SSHKeyPair.fromPem(pem);
      expect(keys, hasLength(1));
    });
  });

  group('generateSshKey', () {
    test('produces a pair that dartssh2 loads', () async {
      final k = await generateSshKey(comment: 'pi-tool@test');
      expect(k.publicKeyLine, startsWith('ssh-ed25519 '));
      // Loads as a real identity (valid openssh-key-v1 framing).
      final keys = SSHKeyPair.fromPem(k.privateKeyPem);
      expect(keys, hasLength(1));
      // The authorized line embeds a 32-byte ed25519 public key.
      final blob = base64.decode(k.publicKeyLine.split(' ')[1]);
      expect(blob.sublist(15, 19), [0, 0, 0, 32]);
    });

    test('two generations differ (fresh randomness)', () async {
      final a = await generateSshKey();
      final b = await generateSshKey();
      expect(a.publicKeyLine, isNot(b.publicKeyLine));
      expect(a.privateKeyPem, isNot(b.privateKeyPem));
    });
  });

  group('buildInstallAuthorizedKeyScript', () {
    test('appends idempotently to ~/.ssh with a success marker, no sudo', () {
      final s = buildInstallAuthorizedKeyScript('ssh-ed25519 AAAA comment');
      expect(s, contains('mkdir -p ~/.ssh'));
      expect(s, contains('chmod 700 ~/.ssh'));
      expect(s, contains('chmod 600 ~/.ssh/authorized_keys'));
      expect(s, contains('grep -qxF')); // only append if not already present
      expect(s, contains('KEY_INSTALLED'));
      expect(s, isNot(contains('sudo'))); // the user's own ~/.ssh — no root
    });

    test('single-quotes the key line (no shell injection)', () {
      final s = buildInstallAuthorizedKeyScript("ssh-ed25519 AAA x';rm -rf ~;'");
      expect(s, contains(r"'\''")); // the embedded quote is escaped
      expect(s, isNot(contains('>> ~/.ssh/authorized_keys\nrm -rf')));
    });
  });

  // The script in a REAL bash with HOME pointed into a sandbox: what ends up
  // in authorized_keys is checked, byte for byte.
  group('buildInstallAuthorizedKeyScript in bash', () {
    late PiSandbox pi;
    const file = '/home/pi/.ssh/authorized_keys';
    const key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPiTool pi-tool@handy';
    const other = 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7 stefan@pc';

    setUp(() => pi = PiSandbox());
    tearDown(() => pi.dispose());

    Future<void> install(String line) async {
      final r = await pi.run(
          "export HOME='${pi.root}/home/pi'\n"
          '${buildInstallAuthorizedKeyScript(line)}',
          rebase: false);
      expect(r.code, 0, reason: '${r.out}${r.err}');
      expect(r.lines, ['KEY_INSTALLED']);
    }

    test('a last line without a newline is ended before the key is appended',
        () async {
      // Glued to that line the new key would be part of the other key's
      // comment — and the login with it refused.
      pi.put(file, other);
      await install(key);
      expect(pi.read(file), '$other\n$key\n');
    });

    test('a file that ends with a newline gets no blank line', () async {
      pi.put(file, '$other\n');
      await install(key);
      expect(pi.read(file), '$other\n$key\n');
    });

    test('no ~/.ssh yet: the file holds the key and nothing else', () async {
      await install(key);
      expect(pi.read(file), '$key\n');
    });

    test('installing the same key twice keeps one line', () async {
      pi.put(file, other);
      await install(key);
      await install(key);
      expect(pi.read(file), '$other\n$key\n');
    });

    test('a key that already is the unterminated last line is left alone',
        () async {
      pi.put(file, '$other\n$key');
      await install(key);
      expect(pi.read(file), '$other\n$key');
    });
  }, skip: needsBash);
}
