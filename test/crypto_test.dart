import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkwell/core/crypto.dart';

Future<Vault> _vault([int fill = 7]) => Vault.fromKeyBytes(
      Uint8List.fromList(List.filled(32, fill)),
      Uint8List(16),
    );

void main() {
  test('encrypt then decrypt returns the original bytes', () async {
    final v = await _vault();
    final enc = await v.encrypt(utf8.encode('hello inkwell'));
    expect(utf8.decode(await v.decrypt(enc)), 'hello inkwell');
  });

  test('every encryption uses a fresh nonce', () async {
    final v = await _vault();
    final a = await v.encrypt(utf8.encode('same'));
    final b = await v.encrypt(utf8.encode('same'));
    expect(a, isNot(equals(b)));
  });

  test('tampered data is rejected', () async {
    final v = await _vault();
    final enc = await v.encrypt(utf8.encode('secret'));
    enc[enc.length - 1] ^= 0xff;
    expect(v.decrypt(enc), throwsA(isA<CryptoException>()));
  });

  test('the wrong key cannot decrypt', () async {
    final enc = await (await _vault(7)).encrypt(utf8.encode('secret'));
    expect((await _vault(8)).decrypt(enc), throwsA(isA<CryptoException>()));
  });

  test('random bytes are not mistaken for an encrypted file', () async {
    final v = await _vault();
    expect(v.decrypt(List.filled(64, 1)), throwsA(isA<CryptoException>()));
  });

  test('blob names are stable, keyed and hex', () async {
    final a = await _vault(7);
    final b = await _vault(8);
    final n1 = await a.blobName('abc123');
    expect(n1, await a.blobName('abc123'));
    expect(n1, isNot(await b.blobName('abc123')));
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(n1), isTrue);
  });

  test('passphrase check passes with the right key, fails with another', () async {
    final good = await _vault(7);
    final check = await good.makeCheck();
    await good.verifyCheck(check);
    expect((await _vault(8)).verifyCheck(check), throwsA(isA<CryptoException>()));
  });

  test('derive is deterministic for the same passphrase and salt', () async {
    final salt = Uint8List.fromList(List.generate(16, (i) => i));
    final a = await Vault.derive('correct horse', salt, iterations: 1000);
    final b = await Vault.derive('correct horse', salt, iterations: 1000);
    final c = await Vault.derive('wrong horse', salt, iterations: 1000);
    final enc = await a.encrypt(utf8.encode('x'));
    expect(utf8.decode(await b.decrypt(enc)), 'x');
    expect(c.decrypt(enc), throwsA(isA<CryptoException>()));
  });
}
