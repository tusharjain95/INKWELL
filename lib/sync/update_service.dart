import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.notes,
    required this.downloadUrl,
    required this.assetName,
    required this.size,
  });

  final String version;
  final String notes;
  final Uri downloadUrl;
  final String assetName;
  final int size;
}

/// Compares "1.2.3" style versions. Returns true when [a] is newer than [b].
bool isNewerVersion(String a, String b) {
  List<int> parse(String v) {
    final core = v.trim().replaceFirst(RegExp(r'^[vV]'), '').split(RegExp(r'[-+]')).first;
    return core.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  }

  final x = parse(a);
  final y = parse(b);
  for (var i = 0; i < 3; i++) {
    final xi = i < x.length ? x[i] : 0;
    final yi = i < y.length ? y[i] : 0;
    if (xi != yi) return xi > yi;
  }
  return false;
}

/// In-app updates from GitHub Releases.
///
/// The release workflow bakes the repository name in at build time with
/// `--dart-define=UPDATE_REPO=owner/name`. Release assets are expected to be
/// `*.apk` for Android and `*setup.exe` for Windows.
class UpdateService {
  static const String repo = String.fromEnvironment('UPDATE_REPO');

  bool get supported => repo.isNotEmpty && (Platform.isAndroid || Platform.isWindows);

  Future<String> currentVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  /// Returns the newest release if it is newer than the installed version.
  Future<UpdateInfo?> check() async {
    if (!supported) return null;
    final r = await http.get(
      Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'inkwell-app',
      },
    ).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) return null;

    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final tag = (j['tag_name'] as String?) ?? '';
    if (!isNewerVersion(tag, await currentVersion())) return null;

    final wanted = Platform.isAndroid ? '.apk' : 'setup.exe';
    for (final a in ((j['assets'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      final name = (a['name'] as String?) ?? '';
      if (name.toLowerCase().endsWith(wanted)) {
        return UpdateInfo(
          version: tag.replaceFirst(RegExp(r'^[vV]'), ''),
          notes: (j['body'] as String?) ?? '',
          downloadUrl: Uri.parse(a['browser_download_url'] as String),
          assetName: name,
          size: (a['size'] as num?)?.toInt() ?? 0,
        );
      }
    }
    return null;
  }

  Future<File> download(UpdateInfo info, void Function(double) onProgress) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', info.downloadUrl)
        ..headers['User-Agent'] = 'inkwell-app';
      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        throw Exception('Download failed (HTTP ${resp.statusCode}).');
      }
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, info.assetName));
      final sink = file.openWrite();
      final total = resp.contentLength ?? info.size;
      var got = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress((got / total).clamp(0, 1).toDouble());
      }
      await sink.close();
      return file;
    } finally {
      client.close();
    }
  }

  /// Android: hands the APK to the system installer (the user confirms).
  /// Windows: runs the installer silently over the existing install, which
  /// relaunches the app when it finishes, then exits this process.
  Future<void> install(File file) async {
    if (Platform.isAndroid) {
      await OpenFilex.open(file.path,
          type: 'application/vnd.android.package-archive');
    } else if (Platform.isWindows) {
      await Process.start(
        file.path,
        ['/SILENT', '/SUPPRESSMSGBOXES', '/CLOSEAPPLICATIONS'],
        mode: ProcessStartMode.detached,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      exit(0);
    }
  }
}
