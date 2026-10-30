import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'drive_auth.dart';

class DriveException implements Exception {
  DriveException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

class DriveFile {
  const DriveFile({
    required this.id,
    required this.name,
    required this.md5,
    this.modified,
    this.created,
  });

  final String id;
  final String name;

  /// Content hash computed by Drive. Inkwell's encrypted files use a fresh
  /// random nonce on every write, so this changes whenever the file is rewritten.
  final String md5;
  final DateTime? modified;
  final DateTime? created;

  factory DriveFile.fromJson(Map<String, dynamic> j) => DriveFile(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        md5: (j['md5Checksum'] as String?) ?? '',
        modified: DateTime.tryParse((j['modifiedTime'] as String?) ?? ''),
        created: DateTime.tryParse((j['createdTime'] as String?) ?? ''),
      );
}

/// Minimal Google Drive v3 client. With the `drive.file` scope Inkwell can only
/// see files it created itself, so everything lives in one folder named
/// [folderName] that the client finds (or creates) on first use.
class DriveClient {
  DriveClient(this._tokens, {http.Client? client}) : _http = client ?? http.Client();

  final DriveTokenSource _tokens;
  final http.Client _http;

  static const String _api = 'https://www.googleapis.com/drive/v3';
  static const String _upload = 'https://www.googleapis.com/upload/drive/v3';
  static const String folderName = 'Inkwell Sync';
  static const String _folderMime = 'application/vnd.google-apps.folder';
  String? _folderId;

  /// The sync folder's id. If several exist (two devices created it at the
  /// same moment) the oldest wins, so every device converges on one.
  Future<String> _folder() async {
    final cached = _folderId;
    if (cached != null) return cached;
    Future<List<DriveFile>> find() async {
      final uri = Uri.parse('$_api/files').replace(queryParameters: {
        'q': "mimeType = '$_folderMime' and name = '$folderName' and trashed = false",
        'pageSize': '100',
        'fields': 'files($_fields)',
      });
      final r = await _send('GET', uri);
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final all = [
        for (final f in (j['files'] as List? ?? const []))
          DriveFile.fromJson((f as Map).cast<String, dynamic>())
      ]..sort((a, b) => (a.created ?? DateTime(0)).compareTo(b.created ?? DateTime(0)));
      return all;
    }

    var found = await find();
    if (found.isEmpty) {
      await _send(
        'POST',
        Uri.parse('$_api/files').replace(queryParameters: {'fields': _fields}),
        headers: {'Content-Type': 'application/json'},
        body: Uint8List.fromList(utf8.encode(jsonEncode({'name': folderName, 'mimeType': _folderMime}))),
      );
      found = await find();
    }
    if (found.isEmpty) throw DriveException('Could not create the Inkwell folder in Google Drive.');
    return _folderId = found.first.id;
  }

  static const String _fields = 'id,name,md5Checksum,modifiedTime,createdTime';

  /// Every file in the sync folder (all pages).
  Future<List<DriveFile>> list() async {
    final folder = await _folder();
    final out = <DriveFile>[];
    String? page;
    do {
      final uri = Uri.parse('$_api/files').replace(queryParameters: {
        'q': "'$folder' in parents and trashed = false",
        'pageSize': '1000',
        'fields': 'nextPageToken,files($_fields)',
        if (page != null) 'pageToken': page,
      });
      final r = await _send('GET', uri);
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      for (final f in (j['files'] as List? ?? const [])) {
        out.add(DriveFile.fromJson((f as Map).cast<String, dynamic>()));
      }
      page = j['nextPageToken'] as String?;
    } while (page != null);
    return out;
  }

  Future<Uint8List> download(String id) async {
    final r = await _send('GET', Uri.parse('$_api/files/$id?alt=media'),
        timeout: const Duration(minutes: 3));
    return r.bodyBytes;
  }

  Future<String?> md5Of(String id) async {
    final r = await _send(
        'GET', Uri.parse('$_api/files/$id').replace(queryParameters: {'fields': 'md5Checksum'}));
    return (jsonDecode(r.body) as Map)['md5Checksum'] as String?;
  }

  Future<DriveFile> create(String name, Uint8List bytes) async {
    final folder = await _folder();
    final boundary = 'inkwell${Random().nextInt(1 << 31)}';
    final body = buildMultipart(
      boundary,
      {
        'name': name,
        'parents': [folder],
      },
      bytes,
    );
    final uri = Uri.parse('$_upload/files')
        .replace(queryParameters: {'uploadType': 'multipart', 'fields': _fields});
    final r = await _send(
      'POST',
      uri,
      headers: {'Content-Type': 'multipart/related; boundary=$boundary'},
      body: body,
      timeout: const Duration(minutes: 3),
    );
    return DriveFile.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<DriveFile> update(String id, Uint8List bytes) async {
    final uri = Uri.parse('$_upload/files/$id')
        .replace(queryParameters: {'uploadType': 'media', 'fields': _fields});
    final r = await _send(
      'PATCH',
      uri,
      headers: {'Content-Type': 'application/octet-stream'},
      body: bytes,
      timeout: const Duration(minutes: 3),
    );
    return DriveFile.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> delete(String id) async {
    try {
      await _send('DELETE', Uri.parse('$_api/files/$id'));
    } on DriveException catch (e) {
      if (e.status != 404) rethrow; // already gone
    }
  }

  /// A multipart/related body: JSON metadata, then the raw file bytes.
  static Uint8List buildMultipart(
      String boundary, Map<String, Object?> metadata, Uint8List bytes) {
    final head = utf8.encode('--$boundary\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n\r\n'
        '${jsonEncode(metadata)}\r\n'
        '--$boundary\r\n'
        'Content-Type: application/octet-stream\r\n\r\n');
    final tail = utf8.encode('\r\n--$boundary--');
    final out = BytesBuilder(copy: false)
      ..add(head)
      ..add(bytes)
      ..add(tail);
    return out.toBytes();
  }

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    Uint8List? body,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    var refreshed = false;
    for (var attempt = 0;; attempt++) {
      final token = await _tokens.token();
      final req = http.Request(method, uri)
        ..headers['Authorization'] = 'Bearer $token'
        ..headers.addAll(headers ?? const {});
      if (body != null) req.bodyBytes = body;

      http.Response res;
      try {
        res = await http.Response.fromStream(
            await _http.send(req).timeout(timeout));
      } on TimeoutException {
        if (attempt < 2) continue;
        throw DriveException('Google Drive did not respond in time. Check your connection.');
      } on http.ClientException catch (e) {
        if (attempt < 2) {
          await Future<void>.delayed(Duration(seconds: 1 << attempt));
          continue;
        }
        throw DriveException('Network error: ${e.message}');
      }

      final code = res.statusCode;
      if (code >= 200 && code < 300) return res;

      if (code == 401 && !refreshed) {
        refreshed = true;
        await _tokens.token(force: true);
        continue;
      }
      final transient = code == 429 || code >= 500 || _isRateLimit(res);
      if (transient && attempt < 3) {
        await Future<void>.delayed(Duration(seconds: 1 << (attempt + 1)));
        continue;
      }
      throw DriveException(_message(res), status: code);
    }
  }

  bool _isRateLimit(http.Response r) {
    if (r.statusCode != 403) return false;
    final b = r.body;
    return b.contains('rateLimitExceeded') ||
        b.contains('userRateLimitExceeded') ||
        b.contains('backendError');
  }

  String _message(http.Response r) {
    String detail = '';
    try {
      final e = (jsonDecode(r.body) as Map)['error'];
      if (e is Map) detail = (e['message'] as String?) ?? '';
    } catch (_) {}
    switch (r.statusCode) {
      case 401:
        return 'Google rejected the sign-in. Sign in to Google Drive again in Settings.';
      case 403:
        if (r.body.contains('storageQuotaExceeded')) {
          return 'Your Google Drive storage is full.';
        }
        if (r.body.contains('accessNotConfigured') ||
            r.body.contains('SERVICE_DISABLED')) {
          return 'The Google Drive API is not enabled for this app\'s Google Cloud project.';
        }
        return 'Google Drive refused the request. ${detail.isEmpty ? '' : detail}'.trim();
      case 404:
        return 'File not found in Google Drive.';
      default:
        return 'Google Drive error ${r.statusCode}${detail.isEmpty ? '' : ': $detail'}';
    }
  }
}
