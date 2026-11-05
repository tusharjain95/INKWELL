import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';
import 'settings.dart';

class SetupCodeException implements Exception {
  SetupCodeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A single text code that carries this device's setup (sync sign-in, backup
/// passphrase, Telegram bot) to another device. It is encrypted with a PIN
/// chosen when the code is made, so it is safe to send to yourself through
/// Telegram saved messages, e-mail or a notes app.
class SetupCode {
  static const String prefix = 'INKWELL1.';
  static const int minPin = 6;

  /// What gets copied. The Telegram hub switch is deliberately left out: the
  /// hub must run on one device only.
  static Map<String, dynamic> snapshot(AppSettings s) => {
        'v': 1,
        'provider': s.syncProvider.name,
        'gh': {
          'token': s.config.token,
          'repo': s.config.repo,
          'branch': s.config.branch,
          'pass': s.config.passphrase,
        },
        'drive': {
          'refresh': s.driveRefreshToken,
          'email': s.driveEmail,
          'pass': s.drivePassphrase,
        },
        'tg': {'token': s.telegramToken, 'chat': s.telegramChat},
        'relay': {'url': s.botUrl, 'key': s.botKey},
      };

  static Future<String> create(AppSettings s, String pin) =>
      encode(snapshot(s), pin);

  static Future<String> encode(Map<String, dynamic> data, String pin) async {
    if (pin.length < minPin) {
      throw SetupCodeException('Use a PIN of at least $minPin characters.');
    }
    final salt = Vault.randomSalt();
    final vault = await Vault.derive(pin, salt);
    final box = await vault.encrypt(utf8.encode(jsonEncode(data)));
    final out = BytesBuilder(copy: false)
      ..add(salt)
      ..add(box);
    return prefix + base64Url.encode(out.toBytes()).replaceAll('=', '');
  }

  static Future<Map<String, dynamic>> decode(String code, String pin) async {
    final text = code.trim().replaceAll(RegExp(r'\s+'), '');
    if (!text.startsWith(prefix)) {
      throw SetupCodeException('That does not look like an Inkwell setup code.');
    }
    Uint8List raw;
    try {
      var b = text.substring(prefix.length);
      while (b.length % 4 != 0) {
        b += '=';
      }
      raw = base64Url.decode(b);
    } catch (_) {
      throw SetupCodeException('The setup code is damaged. Copy it again in full.');
    }
    if (raw.length < 16 + 20) {
      throw SetupCodeException('The setup code is too short. Copy it again in full.');
    }
    final salt = Uint8List.fromList(raw.sublist(0, 16));
    final vault = await Vault.derive(pin, salt);
    try {
      final clear = await vault.decrypt(raw.sublist(16));
      return (jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>();
    } on CryptoException {
      throw SetupCodeException('Wrong PIN, or the code was changed.');
    } catch (_) {
      throw SetupCodeException('The setup code could not be read.');
    }
  }

  /// Applies a decoded code to this device. Returns a short summary.
  static Future<String> apply(AppSettings s, Map<String, dynamic> d) async {
    Map<String, dynamic> m(String k) =>
        (d[k] is Map) ? (d[k] as Map).cast<String, dynamic>() : const {};
    String str(Map<String, dynamic> x, String k) => (x[k] as String?) ?? '';
    final done = <String>[];

    final gh = m('gh');
    if (str(gh, 'token').isNotEmpty && str(gh, 'repo').isNotEmpty) {
      await s.saveSync(s.config.copyWith(
        token: str(gh, 'token'),
        repo: str(gh, 'repo'),
        branch: str(gh, 'branch').isEmpty ? 'main' : str(gh, 'branch'),
        passphrase: str(gh, 'pass'),
      ));
      done.add('GitHub sync');
    }
    final dr = m('drive');
    if (str(dr, 'refresh').isNotEmpty) {
      await s.saveDrive(
        refreshToken: str(dr, 'refresh'),
        email: str(dr, 'email'),
        passphrase: str(dr, 'pass'),
      );
      done.add('Google Drive sync');
    }
    final provider = SyncProvider.values.firstWhere(
      (p) => p.name == d['provider'],
      orElse: () => s.syncProvider,
    );
    await s.setSyncProvider(provider);

    final tg = m('tg');
    final relay = m('relay');
    if (str(tg, 'token').isNotEmpty) {
      await s.saveHub(
        url: str(relay, 'url'),
        key: str(relay, 'key'),
        token: str(tg, 'token'),
        chat: str(tg, 'chat'),
      );
      done.add('Telegram bot');
    }
    return done.isEmpty ? 'The code held no settings.' : 'Set up: ${done.join(', ')}.';
  }
}
