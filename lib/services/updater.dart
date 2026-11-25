import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// In-app updates from GitHub Releases. Each CI build is compiled with
/// --dart-define=BUILD_NUMBER=N.
///  - Android: release "build-N" (marked latest) with MotionAI.apk.
///  - Windows: newest release "win-N" (never marked latest) with
///    MotionAI-Setup.exe.
class Updater {
  static const releasesRepo = 'mohitbansaldev/motionai';
  static const current = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);
  static const windowsInstaller = 'MotionAI-Setup.exe';
  static const windowsPortable = 'MotionAI-Windows-portable.zip';

  /// Returns the newer release, or null if up to date.
  /// Throws [UpdateCheckError] when releases can't be read (e.g. private repo).
  static Future<UpdateInfo?> check() => Platform.isWindows ? _checkWindows() : _checkAndroid();

  static Future<http.Response> _get(String path) async {
    final res = await http
        .get(Uri.parse('https://api.github.com/repos/$releasesRepo/$path'), headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 15));
    if (res.statusCode == 404) {
      throw UpdateCheckError('Releases are not public, so the app can\'t see new builds yet.');
    }
    if (res.statusCode != 200) throw UpdateCheckError('Update check failed (${res.statusCode}).');
    return res;
  }

  static Future<UpdateInfo?> _checkAndroid() async {
    final res = await _get('releases/latest');
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

  static Future<UpdateInfo?> _checkWindows() async {
    final res = await _get('releases?per_page=60');
    return pickWindowsRelease(jsonDecode(res.body) as List, current);
  }

  /// Newest non-draft "win-N" release with the installer, if newer than
  /// [current]. `olderUrl` carries the portable zip.
  static UpdateInfo? pickWindowsRelease(List releases, int current) {
    UpdateInfo? best;
    for (final r in releases) {
      if (r is! Map || r['draft'] == true || r['prerelease'] == true) continue;
      final m = RegExp(r'^win-(\d+)$').firstMatch('${r['tag_name']}');
      if (m == null) continue;
      final n = int.parse(m[1]!);
      if (n <= current || (best != null && n <= best.build)) continue;
      String? setup, zip;
      for (final a in (r['assets'] as List? ?? const [])) {
        if (a is! Map) continue;
        if (a['name'] == windowsInstaller) setup = '${a['browser_download_url']}';
        if (a['name'] == windowsPortable) zip = '${a['browser_download_url']}';
      }
      if (setup == null) continue;
      best = UpdateInfo(n, setup, zip, '${r['body'] ?? ''}');
    }
    return best;
  }

  /// Windows: downloads the installer to the temp folder. [onProgress] 0..1.
  static Future<String> downloadInstaller(UpdateInfo u, {void Function(double)? onProgress}) async {
    final dest = File('${Directory.systemTemp.path}\\MotionAI-Setup-${u.build}.exe');
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(u.url)));
      if (res.statusCode != 200) throw UpdateCheckError('Download failed (${res.statusCode}).');
      final total = res.contentLength ?? 0;
      final sink = dest.openWrite();
      var got = 0;
      await for (final c in res.stream) {
        sink.add(c);
        got += c.length;
        if (total > 0) onProgress?.call(got / total);
      }
      await sink.close();
      return dest.path;
    } finally {
      client.close();
    }
  }

  /// Starts the installer and quits so it can replace the app's files.
  static Future<void> runInstallerAndExit(String path) async {
    await Process.start(path, const ['/SILENT', '/CLOSEAPPLICATIONS', '/RESTARTAPPLICATIONS'], mode: ProcessStartMode.detached);
    exit(0);
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
