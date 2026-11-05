import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

class RepoSetupException implements Exception {
  RepoSetupException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One-tap helpers for the GitHub sync setup.
class GitHubSetup {
  GitHubSetup(this.token, {http.Client? client}) : _http = client ?? http.Client();

  final String token;
  final http.Client _http;

  /// Where to create a token that is allowed to make a repository.
  static const String tokenUrl =
      'https://github.com/settings/tokens/new?scopes=repo&description=Inkwell%20sync';

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${token.trim()}',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'inkwell-app',
        'Content-Type': 'application/json',
      };

  /// Creates a private repository and returns "owner/name". If the name is
  /// already taken by the signed-in user, that repository is reused.
  Future<String> createPrivateRepo({String name = 'inkwell-sync'}) async {
    http.Response r;
    try {
      r = await _http
          .post(
            Uri.parse('https://api.github.com/user/repos'),
            headers: _headers,
            body: jsonEncode({
              'name': name,
              'private': true,
              'description': 'Encrypted Inkwell notes (do not edit)',
              'auto_init': false,
            }),
          )
          .timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw RepoSetupException('GitHub did not answer in time.');
    } catch (e) {
      throw RepoSetupException('Could not reach GitHub: $e');
    }

    if (r.statusCode == 201) {
      return (jsonDecode(r.body) as Map)['full_name'] as String;
    }
    if (r.statusCode == 401) {
      throw RepoSetupException('GitHub rejected the token. Create a new one and paste it again.');
    }
    if (r.statusCode == 403 || r.statusCode == 404) {
      throw RepoSetupException(
          'This token cannot create repositories. Fine-grained tokens cannot. '
          'Use the "Create token" button to make a classic token with the repo permission, '
          'or create an empty private repository by hand.');
    }
    if (r.statusCode == 422) {
      // Probably "name already exists": reuse it.
      final login = await _login();
      final check = await _http
          .get(Uri.parse('https://api.github.com/repos/$login/$name'), headers: _headers)
          .timeout(const Duration(seconds: 25));
      if (check.statusCode == 200) return '$login/$name';
    }
    throw RepoSetupException('GitHub could not create the repository (${r.statusCode}).');
  }

  Future<String> _login() async {
    final r = await _http
        .get(Uri.parse('https://api.github.com/user'), headers: _headers)
        .timeout(const Duration(seconds: 25));
    if (r.statusCode != 200) {
      throw RepoSetupException('GitHub rejected the token (${r.statusCode}).');
    }
    return (jsonDecode(r.body) as Map)['login'] as String;
  }

  /// A strong, easy-to-copy passphrase such as "kt7p-w2mx-9qfa-hc4d-rv8n".
  static String generatePassphrase({Random? random}) {
    final r = random ?? Random.secure();
    const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
    String group() => List.generate(4, (_) => alphabet[r.nextInt(alphabet.length)]).join();
    return List.generate(5, (_) => group()).join('-');
  }
}
