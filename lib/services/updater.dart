import 'dart:convert';

import 'package:http/http.dart' as http;

/// In-app updates from GitHub Releases. Each CI build is tagged "build-N"
/// and the app is compiled with --dart-define=BUILD_NUMBER=N.
class Updater {
  static const releasesRepo = 'mohitbansaldev/motionai';
  static const current = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);

  /// Returns the newer release, or null if up to date.
  /// Throws [UpdateCheckError] when releases can't be read (e.g. private repo).
  static Future<UpdateInfo?> check() async {
    final res = await http
        .get(Uri.parse('https://api.github.com/repos/$releasesRepo/releases/latest'),
            headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 404) {
      throw UpdateCheckError('Releases are not public, so the app can\'t see new builds yet.');
    }
    if (res.statusCode != 200) throw UpdateCheckError('Update check failed (${res.statusCode}).');
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final n = int.tryParse('${j['tag_name']}'.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    if (n <= current) return null;
    String? apk;
    String? older;
    for (final a in (j['assets'] as List? ?? [])) {
      final name = '${(a as Map)['name']}';
      if (name == 'MotionAI.apk') apk = '${a['browser_download_url']}';
      if (name == 'MotionAI-older-phones.apk') older = '${a['browser_download_url']}';
    }
    if (apk == null) return null;
    return UpdateInfo(n, apk, older, '${j['body'] ?? ''}');
  }
}

class UpdateInfo {
  final int build;
  final String url;
  final String? olderUrl;
  final String notes;
  UpdateInfo(this.build, this.url, this.olderUrl, this.notes);
}

class UpdateCheckError implements Exception {
  final String message;
  UpdateCheckError(this.message);
  @override
  String toString() => message;
}
