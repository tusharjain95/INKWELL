import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// PBKDF2-HMAC-SHA256 work factor. Applied once per app session.
const int kKdfIterations = 210000;

// "INKENC1\0"
const List<int> _magic = [0x49, 0x4e, 0x4b, 0x45, 0x4e, 0x43, 0x31, 0x00];
const int _nonceLen = 12;
const int _macLen = 16;

String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class CryptoException implements Exception {
  CryptoException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Holds the key derived from the user's backup passphrase and encrypts or
/// decrypts everything that leaves the device (AES-256-GCM, random nonce).
///
/// File layout: magic(8) | nonce(12) | ciphertext | gcm-tag(16)
class Vault {
  Vault._(this._key, this._nameKey, this.salt);

  final SecretKey _key;
  final SecretKey _nameKey;
  final Uint8List salt;

  static final AesGcm _aes = AesGcm.with256bits();
  static final Hmac _hmac = Hmac.sha256();

  static Uint8List randomSalt() {
    final r = Random.secure();
    return Uint8List.fromList(List<int>.generate(16, (_) => r.nextInt(256)));
  }

  /// Derives the key in a background isolate so the UI never stalls.
  static Future<Vault> derive(
    String passphrase,
    Uint8List salt, {
    int iterations = kKdfIterations,
  }) async {
    final keyBytes = await Isolate.run(() async {
      final kdf = Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: iterations,
        bits: 256,
      );
      final key = await kdf.deriveKeyFromPassword(
        password: passphrase,
        nonce: salt,
      );
      return Uint8List.fromList(await key.extractBytes());
    });
    return fromKeyBytes(keyBytes, salt);
  }

  /// Builds a vault from raw key bytes. Used by [derive] and by tests.
  static Future<Vault> fromKeyBytes(Uint8List keyBytes, Uint8List salt) async {
    final key = SecretKey(keyBytes);
    // A separate sub-key for naming blobs, so the encryption key itself is
    // never used for anything but AES-GCM.
    final nameMac = await _hmac.calculateMac(
      utf8.encode('inkwell/blob-name/v1'),
      secretKey: key,
    );
    return Vault._(key, SecretKey(nameMac.bytes), salt);
  }

  Future<Uint8List> encrypt(List<int> clear) async {
    final box = await _aes.encrypt(clear, secretKey: _key);
    final out = BytesBuilder(copy: false)
      ..add(_magic)
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  Future<Uint8List> decrypt(List<int> data) async {
    if (data.length < _magic.length + _nonceLen + _macLen) {
      throw CryptoException('Not an Inkwell encrypted file.');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (data[i] != _magic[i]) {
        throw CryptoException('Not an Inkwell encrypted file.');
      }
    }
    final nonce = data.sublist(_magic.length, _magic.length + _nonceLen);
    final cipher = data.sublist(_magic.length + _nonceLen, data.length - _macLen);
    final mac = data.sublist(data.length - _macLen);
    try {
      final clear = await _aes.decrypt(
        SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
        secretKey: _key,
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw CryptoException('Wrong passphrase, or the data was modified.');
    }
  }

  /// Name an attachment is stored under in the repo: a keyed hash of its
  /// content hash. The repo never reveals file names, sizes of notes, or
  /// whether you hold a particular known file.
  Future<String> blobName(String contentHash) async {
    final mac = await _hmac.calculateMac(
      utf8.encode(contentHash),
      secretKey: _nameKey,
    );
    return toHex(mac.bytes);
  }

  static const String _checkText = 'inkwell-ok';

  /// Small encrypted marker stored in meta.json, used to detect a wrong
  /// passphrase before touching any real data.
  Future<Uint8List> makeCheck() => encrypt(utf8.encode(_checkText));

  Future<void> verifyCheck(List<int> check) async {
    try {
      final clear = await decrypt(check);
      if (utf8.decode(clear) != _checkText) throw CryptoException('x');
    } on CryptoException {
      throw CryptoException('Wrong backup passphrase for this repository.');
    }
  }
}
