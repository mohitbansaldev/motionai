import 'dart:convert';
import 'dart:io';

import 'win_tools.dart';

/// Speech-to-text on Windows with the bundled whisper.cpp command-line tool
/// (`whisper\whisper-cli.exe`) and a ggml model downloaded once.
class WhisperCli {
  static String modelUrl(String name) => 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$name.bin';

  static String normalizeModel(String name) => const ['tiny', 'base', 'small'].contains(name) ? name : 'base';

  /// Arguments for word-level JSON output (one segment per word).
  static List<String> args({
    required String model,
    required String wav,
    required String outBase,
    String? language,
    String? prompt,
    int threads = 4,
  }) =>
      [
        '-m', model,
        '-f', wav,
        '-l', language ?? 'auto',
        '-t', '$threads',
        '-ml', '1',
        '-sow',
        '-oj',
        '-of', outBase,
        '-pp',
        if (prompt != null && prompt.isNotEmpty) ...['--prompt', prompt],
      ];

  static double _ts(dynamic v) {
    // "00:01:02,345" → 62.345
    if (v is! String) return double.nan;
    final m = RegExp(r'^(\d+):(\d+):(\d+)[,.](\d+)$').firstMatch(v.trim());
    if (m == null) return double.nan;
    return int.parse(m[1]!) * 3600 + int.parse(m[2]!) * 60 + int.parse(m[3]!) + int.parse(m[4]!.padRight(3, '0').substring(0, 3)) / 1000;
  }

  /// Words (text, start s, end s) from whisper.cpp `-oj` output. Segments
  /// holding several words get their time spread evenly; non-speech tags
  /// like "[BLANK_AUDIO]" or "(music)" are dropped.
  static List<(String, double, double)> parseJson(String json) {
    final j = jsonDecode(json);
    final segs = (j is Map ? j['transcription'] : null) as List? ?? const [];
    final out = <(String, double, double)>[];
    for (final s in segs) {
      if (s is! Map) continue;
      final text = '${s['text'] ?? ''}'.trim();
      if (text.isEmpty || text.startsWith('[') || text.startsWith('(') || text.startsWith('*')) continue;
      double a, b;
      final off = s['offsets'];
      if (off is Map && off['from'] is num && off['to'] is num) {
        a = (off['from'] as num) / 1000;
        b = (off['to'] as num) / 1000;
      } else {
        final ts = s['timestamps'];
        a = _ts(ts is Map ? ts['from'] : null);
        b = _ts(ts is Map ? ts['to'] : null);
        if (a.isNaN || b.isNaN) continue;
      }
      if (b < a) b = a;
      final parts = text.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
      for (var i = 0; i < parts.length; i++) {
        out.add((parts[i], a + (b - a) * i / parts.length, a + (b - a) * (i + 1) / parts.length));
      }
    }
    // Glue punctuation-only "words" to the previous word.
    final merged = <(String, double, double)>[];
    for (final w in out) {
      if (merged.isNotEmpty && RegExp(r'^[^\p{L}\p{N}]+$', unicode: true).hasMatch(w.$1)) {
        final p = merged.removeLast();
        merged.add(('${p.$1}${w.$1}', p.$2, w.$3));
      } else {
        merged.add(w);
      }
    }
    return merged;
  }

  /// Progress percentage from a whisper.cpp stderr line, or null.
  static int? parseProgress(String line) {
    final m = RegExp(r'progress\s*=\s*(\d+)\s*%').firstMatch(line);
    return m == null ? null : int.parse(m[1]!);
  }

  static Future<String> ensureModel(String name, {void Function(double)? onProgress}) async {
    final dir = await WinTools.dataDir('models');
    final f = File('${dir.path}\\ggml-$name.bin');
    await WinTools.download(modelUrl(name), f, onProgress: onProgress, minBytes: 10 << 20);
    return f.path;
  }

  /// Runs whisper-cli on a 16 kHz WAV; returns words in WAV seconds.
  static Future<List<(String, double, double)>> transcribe({
    required String exe,
    required String model,
    required String wav,
    String? language,
    String? prompt,
    void Function(int percent)? onProgress,
  }) async {
    final outBase = wav.replaceFirst(RegExp(r'\.wav$', caseSensitive: false), '');
    final threads = Platform.numberOfProcessors.clamp(1, 8).toInt();
    final p = await Process.start(exe, args(model: model, wav: wav, outBase: outBase, language: language, prompt: prompt, threads: threads),
        workingDirectory: File(exe).parent.path);
    final log = StringBuffer();
    final errDone = p.stderr.transform(utf8.decoder).transform(const LineSplitter()).forEach((l) {
      log.writeln(l);
      final pr = parseProgress(l);
      if (pr != null) onProgress?.call(pr);
    });
    final outDone = p.stdout.transform(utf8.decoder).forEach(log.write);
    final code = await p.exitCode;
    await errDone;
    await outDone;
    final jsonFile = File('$outBase.json');
    if (code != 0 || !jsonFile.existsSync()) {
      final tail = log.toString().trim().split('\n');
      throw StateError('Speech-to-text failed: ${tail.isEmpty ? code : tail.last}');
    }
    try {
      final bytes = await jsonFile.readAsBytes();
      return parseJson(utf8.decode(bytes, allowMalformed: true));
    } finally {
      jsonFile.delete().ignore();
    }
  }
}
