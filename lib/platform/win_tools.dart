import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Where the Windows build finds its bundled helper programs and keeps
/// downloaded models. CI puts ffmpeg.exe / ffprobe.exe / onnxruntime.dll next
/// to motionai.exe and whisper.cpp in a `whisper` sub-folder.
class WinTools {
  static String get exeDir => File(Platform.resolvedExecutable).parent.path;

  static String _bundled(String name) {
    final p = '$exeDir${Platform.pathSeparator}$name';
    return File(p).existsSync() ? p : name; // fall back to PATH (developer PCs)
  }

  static String get ffmpeg => _bundled('ffmpeg.exe');
  static String get ffprobe => _bundled('ffprobe.exe');

  static String? get whisperCli {
    for (final n in ['whisper\\whisper-cli.exe', 'whisper\\main.exe', 'whisper-cli.exe']) {
      final p = '$exeDir\\$n';
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  static String get onnxRuntimeDll => '$exeDir\\onnxruntime.dll';

  /// App data sub-folder (e.g. models), created on demand.
  static Future<Directory> dataDir(String name) async {
    final root = await getApplicationSupportDirectory();
    final d = Directory('${root.path}${Platform.pathSeparator}$name');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Downloads [url] to [dest] once (atomic rename). [onProgress] gets 0..1.
  static Future<File> download(String url, File dest, {void Function(double)? onProgress, int minBytes = 1024}) async {
    if (await dest.exists() && await dest.length() >= minBytes) return dest;
    final part = File('${dest.path}.part');
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(url)));
      if (res.statusCode != 200) throw HttpException('Download failed (${res.statusCode}) for $url');
      final total = res.contentLength ?? 0;
      final sink = part.openWrite();
      var got = 0;
      var lastReport = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0 && got - lastReport > 512 * 1024) {
          lastReport = got;
          onProgress?.call(got / total);
        }
      }
      await sink.close();
      if (got < minBytes) throw const HttpException('Download was incomplete');
      if (await dest.exists()) await dest.delete();
      await part.rename(dest.path);
      onProgress?.call(1);
      return dest;
    } finally {
      client.close();
      if (await part.exists()) part.delete().ignore();
    }
  }

  /// Opens Explorer with [path] selected.
  static Future<void> showInFolder(String path) async {
    if (!Platform.isWindows) return;
    await Process.start('explorer.exe', ['/select,', path.replaceAll('/', '\\')]);
  }

  /// The user's Videos\MotionAI folder (default export folder).
  static String defaultExportDir() {
    final home = Platform.environment['USERPROFILE'] ?? exeDir;
    return '$home\\Videos\\MotionAI';
  }
}
