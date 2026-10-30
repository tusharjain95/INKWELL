import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class DriveAuthException implements Exception {
  DriveAuthException(this.message, {this.needsSignIn = false});
  final String message;

  /// The saved sign-in is no longer valid; the user must sign in again.
  final bool needsSignIn;
  @override
  String toString() => message;
}

/// What the user must do to approve the sign-in on google.com/device.
class DeviceCode {
  DeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.expiresAt,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUrl;
  final DateTime expiresAt;
  final Duration interval;
}

class DriveTokens {
  DriveTokens(this.accessToken, this.refreshToken, this.expiresIn);
  final String accessToken;
  final String refreshToken;
  final Duration expiresIn;
}

/// Google sign-in for Drive using the OAuth "limited-input device" flow:
/// the app shows a short code, the user enters it at google.com/device on any
/// browser, and the app polls until approved. It needs no redirect handling,
/// so it behaves the same on Android and Windows.
///
/// Inkwell only asks for the `drive.file` scope (the only Drive scope the
/// device flow allows): it can see just the files it created itself, never the
/// rest of the user's Drive. Plus the account's email address, to show who is
/// signed in.
class DriveAuth {
  DriveAuth({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  static const String clientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
  static const String clientSecret =
      String.fromEnvironment('GOOGLE_CLIENT_SECRET');

  /// Whether this build was given Google OAuth credentials.
  static bool get configured => clientId.isNotEmpty && clientSecret.isNotEmpty;

  static const String scope =
      'https://www.googleapis.com/auth/drive.file email';

  static final Uri _deviceUri = Uri.parse('https://oauth2.googleapis.com/device/code');
  static final Uri _tokenUri = Uri.parse('https://oauth2.googleapis.com/token');
  static final Uri _userInfoUri =
      Uri.parse('https://openidconnect.googleapis.com/v1/userinfo');

  Future<DeviceCode> start() async {
    if (!configured) {
      throw DriveAuthException(
          'This build has no Google credentials. See "Google Drive sync" in the README.');
    }
    final r = await _post(_deviceUri, {'client_id': clientId, 'scope': scope});
    final j = _json(r);
    if (r.statusCode != 200 || j['device_code'] == null) {
      throw DriveAuthException(
          'Google would not start sign-in: ${j['error_description'] ?? j['error'] ?? r.statusCode}');
    }
    return DeviceCode(
      deviceCode: j['device_code'] as String,
      userCode: j['user_code'] as String,
      verificationUrl:
          (j['verification_url'] ?? j['verification_uri'] ?? 'https://www.google.com/device')
              as String,
      expiresAt: DateTime.now()
          .add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 1800)),
      interval: Duration(seconds: (j['interval'] as num?)?.toInt() ?? 5),
    );
  }

  /// Polls until the user approves, denies, or the code expires.
  /// [cancelled] lets the UI stop the wait.
  Future<DriveTokens> waitForApproval(
    DeviceCode code, {
    bool Function()? cancelled,
  }) async {
    var wait = code.interval;
    while (true) {
      await Future<void>.delayed(wait);
      if (cancelled?.call() == true) {
        throw DriveAuthException('Sign-in cancelled.');
      }
      if (DateTime.now().isAfter(code.expiresAt)) {
        throw DriveAuthException('The code expired. Start sign-in again.');
      }
      final r = await _post(_tokenUri, {
        'client_id': clientId,
        'client_secret': clientSecret,
        'device_code': code.deviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      });
      final j = _json(r);
      if (r.statusCode == 200 && j['access_token'] != null) {
        final refresh = j['refresh_token'] as String?;
        if (refresh == null || refresh.isEmpty) {
          throw DriveAuthException(
              'Google did not return a long-lived sign-in. Remove Inkwell at '
              'myaccount.google.com/permissions and try again.');
        }
        return DriveTokens(
          j['access_token'] as String,
          refresh,
          Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 3600),
        );
      }
      switch (j['error']) {
        case 'authorization_pending':
          break;
        case 'slow_down':
          wait += const Duration(seconds: 5);
        case 'access_denied':
          throw DriveAuthException('Sign-in was declined.');
        case 'expired_token':
          throw DriveAuthException('The code expired. Start sign-in again.');
        default:
          throw DriveAuthException(
              'Google sign-in failed: ${j['error_description'] ?? j['error'] ?? r.statusCode}');
      }
    }
  }

  /// Exchanges the saved refresh token for a fresh access token.
  Future<DriveTokens> refresh(String refreshToken) async {
    final r = await _post(_tokenUri, {
      'client_id': clientId,
      'client_secret': clientSecret,
      'refresh_token': refreshToken,
      'grant_type': 'refresh_token',
    });
    final j = _json(r);
    if (r.statusCode == 200 && j['access_token'] != null) {
      return DriveTokens(
        j['access_token'] as String,
        refreshToken,
        Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 3600),
      );
    }
    if (j['error'] == 'invalid_grant') {
      throw DriveAuthException(
          'Your Google sign-in has expired or was revoked. Sign in to Google Drive again in Settings.',
          needsSignIn: true);
    }
    throw DriveAuthException(
        'Could not refresh the Google sign-in: ${j['error_description'] ?? j['error'] ?? r.statusCode}');
  }

  Future<String?> emailFor(String accessToken) async {
    try {
      final r = await _http
          .get(_userInfoUri, headers: {'Authorization': 'Bearer $accessToken'})
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      return _json(r)['email'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<http.Response> _post(Uri uri, Map<String, String> body) async {
    try {
      return await _http.post(uri, body: body).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw DriveAuthException('Google did not respond in time. Check your connection.');
    } on http.ClientException catch (e) {
      throw DriveAuthException('Network error: ${e.message}');
    }
  }

  Map<String, dynamic> _json(http.Response r) {
    try {
      final v = jsonDecode(r.body);
      return v is Map<String, dynamic> ? v : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}

/// Hands out a valid access token, refreshing it shortly before it expires.
class DriveTokenSource {
  DriveTokenSource(this._auth, this._refreshToken);

  final DriveAuth _auth;
  final String _refreshToken;
  String? _access;
  DateTime _expires = DateTime.fromMillisecondsSinceEpoch(0);

  Future<String> token({bool force = false}) async {
    if (!force &&
        _access != null &&
        DateTime.now().isBefore(_expires.subtract(const Duration(minutes: 2)))) {
      return _access!;
    }
    final t = await _auth.refresh(_refreshToken);
    _access = t.accessToken;
    _expires = DateTime.now().add(t.expiresIn);
    return _access!;
  }
}
