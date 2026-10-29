import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class TreeEntry {
  const TreeEntry(this.path, this.sha);
  final String path;
  final String sha;
}

class GitHubException implements Exception {
  GitHubException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

/// The branch moved between reading it and updating it (another device
/// pushed first). The sync is simply retried.
class RefConflictException extends GitHubException {
  RefConflictException()
      : super('The branch changed while syncing.', status: 422);
}

/// Thin wrapper over the GitHub Git Data API. Uses blobs, trees and commits
/// so a whole sync lands as one atomic commit, however many files it touches.
class GitHubClient {
  GitHubClient({
    required this.token,
    required this.repo,
    required this.branch,
    http.Client? client,
  }) : _http = client ?? http.Client();

  final String token;

  /// "owner/name"
  final String repo;
  final String branch;
  final http.Client _http;

  static const String _api = 'https://api.github.com';

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'inkwell-app',
      };

  Uri _repoUri(String path) => Uri.parse('$_api/repos/$repo$path');

  Future<http.Response> _request(
    String method,
    Uri uri, {
    Object? body,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    try {
      final headers = {..._headers};
      if (body != null) headers['Content-Type'] = 'application/json';
      final encoded = body == null ? null : jsonEncode(body);
      final Future<http.Response> call;
      switch (method) {
        case 'POST':
          call = _http.post(uri, headers: headers, body: encoded);
        case 'PATCH':
          call = _http.patch(uri, headers: headers, body: encoded);
        default:
          call = _http.get(uri, headers: headers);
      }
      return await call.timeout(timeout);
    } on TimeoutException {
      throw GitHubException('GitHub did not respond in time. Check your connection.');
    } on SocketException {
      throw GitHubException('No network connection.');
    } on http.ClientException catch (e) {
      throw GitHubException('Network error: ${e.message}');
    }
  }

  String _message(http.Response r) {
    try {
      final m = (jsonDecode(r.body) as Map)['message'];
      if (m is String) return m;
    } catch (_) {}
    return 'HTTP ${r.statusCode}';
  }

  /// Throws a readable [GitHubException] for any non-2xx response.
  void _check(http.Response r) {
    final s = r.statusCode;
    if (s >= 200 && s < 300) return;
    final msg = _message(r);
    if (s == 401) {
      throw GitHubException(
          'GitHub rejected the token. It may have expired or been revoked.',
          status: s);
    }
    if (s == 403 || s == 429) {
      if (msg.toLowerCase().contains('rate limit')) {
        throw GitHubException('GitHub rate limit reached. Try again shortly.',
            status: s);
      }
      throw GitHubException(
          'Access denied. The token needs "Contents: Read and write" on this repository.',
          status: s);
    }
    if (s == 404) {
      throw GitHubException(
          'Repository or branch not found. Check the owner/name and that the token can access it.',
          status: s);
    }
    throw GitHubException('GitHub error: $msg', status: s);
  }

  Future<Map<String, dynamic>> _getJson(String path,
      {Duration timeout = const Duration(seconds: 60)}) async {
    final r = await _request('GET', _repoUri(path), timeout: timeout);
    _check(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Whether the repository is private. Inkwell refuses to sync to a public
  /// repository, even though everything in it is encrypted.
  Future<bool> isPrivate() async {
    final r = await _request('GET', Uri.parse('$_api/repos/$repo'));
    _check(r);
    return (jsonDecode(r.body) as Map)['private'] == true;
  }

  /// Latest commit on the branch, or null when the branch does not exist yet.
  Future<String?> headSha() async {
    final r = await _request('GET', _repoUri('/git/ref/heads/$branch'));
    if (r.statusCode == 404 || r.statusCode == 409) {
      // Distinguish "no such repo / no access" from "branch missing".
      await isPrivate();
      return null;
    }
    _check(r);
    final obj = (jsonDecode(r.body) as Map)['object'] as Map;
    return obj['sha'] as String;
  }

  Future<String> treeShaOfCommit(String commitSha) async {
    final j = await _getJson('/git/commits/$commitSha');
    return (j['tree'] as Map)['sha'] as String;
  }

  /// Path -> blob sha for every file in the tree.
  Future<Map<String, String>> listTree(String treeSha) async {
    final j = await _getJson('/git/trees/$treeSha?recursive=1',
        timeout: const Duration(seconds: 120));
    if (j['truncated'] == true) {
      throw GitHubException(
          'The sync repository is too large to list. Use a dedicated, fresh repository.');
    }
    return {
      for (final e in (j['tree'] as List).cast<Map<String, dynamic>>())
        if (e['type'] == 'blob') e['path'] as String: e['sha'] as String,
    };
  }

  Future<Uint8List> getBlob(String sha) async {
    final j = await _getJson('/git/blobs/$sha',
        timeout: const Duration(minutes: 5));
    final content = (j['content'] as String).replaceAll(RegExp(r'\s'), '');
    return base64Decode(content);
  }

  Future<String> createBlob(List<int> bytes) async {
    final r = await _request(
      'POST',
      _repoUri('/git/blobs'),
      body: {'content': base64Encode(bytes), 'encoding': 'base64'},
      timeout: const Duration(minutes: 5),
    );
    _check(r);
    return (jsonDecode(r.body) as Map)['sha'] as String;
  }

  Future<String> createTree(String baseTree, List<TreeEntry> entries) async {
    final r = await _request(
      'POST',
      _repoUri('/git/trees'),
      body: {
        'base_tree': baseTree,
        'tree': [
          for (final e in entries)
            {'path': e.path, 'mode': '100644', 'type': 'blob', 'sha': e.sha},
        ],
      },
      timeout: const Duration(minutes: 2),
    );
    _check(r);
    return (jsonDecode(r.body) as Map)['sha'] as String;
  }

  Future<String> createCommit(String message, String tree, String parent) async {
    final r = await _request(
      'POST',
      _repoUri('/git/commits'),
      body: {
        'message': message,
        'tree': tree,
        'parents': [parent],
      },
    );
    _check(r);
    return (jsonDecode(r.body) as Map)['sha'] as String;
  }

  /// Fast-forwards the branch. Fails with [RefConflictException] if somebody
  /// else pushed in the meantime, so two devices can never overwrite each
  /// other.
  Future<void> updateRef(String commitSha) async {
    final r = await _request(
      'PATCH',
      _repoUri('/git/refs/heads/$branch'),
      body: {'sha': commitSha, 'force': false},
    );
    if (r.statusCode == 422) throw RefConflictException();
    _check(r);
  }
}
