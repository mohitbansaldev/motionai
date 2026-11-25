// Speech-to-text on Windows (Agent E): the bundled whisper.cpp CLI
// (`whisper\whisper-cli.exe` next to motionai.exe) with a ggml model that is
// downloaded once from Hugging Face (ggerganov/whisper.cpp).
//
// whisper-cli reads its command line in the ANSI code page, which mangles a
// Hindi prompt or a non-English user folder. So the arguments go in a UTF-8
// response file ("@job.args"), and every path in it is a short ASCII name
// relative to the working folder (the models folder; the WAV is copied there).
import 'dart:convert';
import 'dart:io';

import 'model_store.dart';

/// One recognised word, in seconds of the input WAV.
typedef Word = (String word, double start, double end);

class Whisper {
  static const defaultModel = 'base';

  /// ggml models (sizes and SHA-1 from whisper.cpp's models/README.md).
  static const models = <String, ModelSpec>{
    'tiny': ModelSpec(
      fileName: 'ggml-tiny.bin',
      urls: ['https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin'],
      bytes: 77691713,
      hashKind: HashKind.sha1,
      hash: 'bd577a113a864445d4c299885e0cb97d4ba92b5f',
      label: 'speech model (tiny)',
    ),
    'base': ModelSpec(
      fileName: 'ggml-base.bin',
      urls: ['https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin'],
      bytes: 147951465,
      hashKind: HashKind.sha1,
      hash: '465707469ff3a37a2b9b8d8f89f2f99de7299dac',
      label: 'speech model (base)',
    ),
    'small': ModelSpec(
      fileName: 'ggml-small.bin',
      urls: ['https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin'],
      bytes: 487601967,
      hashKind: HashKind.sha1,
      hash: '55356645c2b361a969dfd0ef2c5a50d530afd8d5',
      label: 'speech model (small)',
    ),
  };

  static ModelSpec model(String? name) => models[name] ?? models[defaultModel]!;

  /// whisper.cpp language code: "hi-IN" → "hi", null/""/"auto" → "auto".
  static String language(String? lang) {
    final l = (lang ?? '').trim().toLowerCase();
    if (l.isEmpty || l == 'auto') return 'auto';
    return l.split(RegExp('[-_]')).first;
  }

  /// Arguments for word-level timings with full JSON output
  /// (`<outBase>.json`, one segment per word plus token timestamps).
  static List<String> args({
    required String model,
    required String wav,
    required String outBase,
    String? language,
    String? prompt,
    int threads = 4,
  }) {
    final p = (prompt ?? '').replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    return [
      '-m', model,
      '-f', wav,
      '-l', Whisper.language(language),
      '-t', '$threads',
      '-ml', '1',
      '-sow',
      '-ojf',
      '-of', outBase,
      '-pp',
      if (p.isNotEmpty) ...['--prompt', p],
    ];
  }

  /// Response-file text for [args]: one argument per line, "\n" endings.
  static String responseFile(List<String> args) => '${args.map((a) => a.replaceAll(RegExp(r'[\r\n]'), ' ')).join('\n')}\n';

  /// Progress percentage from a whisper.cpp stderr line, or null.
  static int? progress(String line) {
    final m = RegExp(r'progress\s*=\s*(\d+)\s*%').firstMatch(line);
    return m == null ? null : int.parse(m[1]!);
  }

  static final _special = RegExp(r'^\s*(\[_[^\]]*\]|<\|[^|]*\|>)\s*$');
  static final _nonSpeech = RegExp(r'^\s*(\[[^\]]*\]|\([^)]*\)|\*[^*]*\*|♪+|♫+)\s*$');
  static final _punctOnly = RegExp(r'^[^\p{L}\p{N}]+$', unicode: true);

  static double? _ms(Object? offsets, String key) {
    if (offsets is Map && offsets[key] is num) return (offsets[key] as num) / 1000;
    return null;
  }

  static double? _stamp(Object? ts, String key) {
    // "00:01:02,345" → 62.345
    final v = ts is Map ? ts[key] : null;
    if (v is! String) return null;
    final m = RegExp(r'^(\d+):(\d+):(\d+)[,.](\d+)$').firstMatch(v.trim());
    if (m == null) return null;
    return int.parse(m[1]!) * 3600 + int.parse(m[2]!) * 60 + int.parse(m[3]!) + int.parse(m[4]!.padRight(3, '0').substring(0, 3)) / 1000;
  }

  static (double, double)? _span(Map o) {
    final a = _ms(o['offsets'], 'from') ?? _stamp(o['timestamps'], 'from');
    final b = _ms(o['offsets'], 'to') ?? _stamp(o['timestamps'], 'to');
    if (a == null || b == null) return null;
    return (a, b < a ? a : b);
  }

  /// Word timings from whisper.cpp `--output-json-full` (or plain `-oj`)
  /// output. Words come from the segment text; token timestamps time them
  /// when tokens and words line up, otherwise the segment time is shared by
  /// word length. Non-speech tags ("[BLANK_AUDIO]", "(music)") are dropped
  /// and punctuation-only pieces are glued to the previous word.
  static List<Word> parseJson(String json) {
    Object? j;
    try {
      j = jsonDecode(json);
    } on FormatException {
      // Older builds don't escape control characters inside strings.
      j = jsonDecode(json.replaceAll(RegExp(r'[\u0000-\u001F]'), ' '));
    }
    final segs = (j is Map ? j['transcription'] : null);
    if (segs is! List) return const [];
    final out = <Word>[];
    for (final s in segs) {
      if (s is! Map) continue;
      final text = '${s['text'] ?? ''}'.trim();
      if (text.isEmpty || _nonSpeech.hasMatch(text)) continue;
      final span = _span(s);
      if (span == null) continue;
      final (a, b) = span;
      final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

      // Token groups: a token starting with a space begins a new word.
      final groups = <(double, double)>[];
      final tokens = s['tokens'];
      if (tokens is List) {
        var started = false;
        for (final t in tokens) {
          if (t is! Map) continue;
          final tt = '${t['text'] ?? ''}';
          if (tt.isEmpty || _special.hasMatch(tt)) continue;
          final ts = _span(t);
          if (ts == null) continue;
          if (!started || tt.startsWith(' ')) {
            if (tt.trim().isEmpty) continue;
            groups.add(ts);
            started = true;
          } else {
            final last = groups.removeLast();
            groups.add((last.$1, ts.$2 > last.$2 ? ts.$2 : last.$2));
          }
        }
      }
      if (groups.length == words.length && words.isNotEmpty) {
        for (var i = 0; i < words.length; i++) {
          final (ga, gb) = groups[i];
          // Keep inside the segment (token times can spill a little).
          final s0 = ga.clamp(a, b).toDouble(), s1 = gb.clamp(a, b).toDouble();
          out.add((words[i], s0, s1 < s0 ? s0 : s1));
        }
      } else {
        final total = words.fold<int>(0, (n, w) => n + w.runes.length);
        var acc = 0;
        for (final w in words) {
          final s0 = a + (b - a) * acc / total;
          acc += w.runes.length;
          out.add((w, s0, a + (b - a) * acc / total));
        }
      }
    }
    // Glue punctuation-only "words" to the previous word; keep times ordered.
    final merged = <Word>[];
    for (final w in out) {
      if (merged.isNotEmpty && _punctOnly.hasMatch(w.$1)) {
        final p = merged.removeLast();
        merged.add(('${p.$1}${w.$1}', p.$2, w.$3 > p.$3 ? w.$3 : p.$3));
        continue;
      }
      if (merged.isNotEmpty && w.$2 < merged.last.$2) {
        merged.add((w.$1, merged.last.$2, w.$3 < merged.last.$2 ? merged.last.$2 : w.$3));
      } else {
        merged.add(w);
      }
    }
    return merged;
  }

  /// The bundled CLI next to the app, or null.
  static String? findCli(String exeDir) {
    for (final n in ['whisper\\whisper-cli.exe', 'whisper\\main.exe', 'whisper-cli.exe']) {
      final p = '$exeDir\\$n';
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  /// Transcribes [wavPath] (16 kHz mono WAV) with [cli] and the model at
  /// [modelPath]. Returns words in seconds of the WAV.
  static Future<List<Word>> transcribe({
    required String cli,
    required String modelPath,
    required String wavPath,
    String? language,
    String? prompt,
    void Function(int percent)? onProgress,
  }) async {
    final work = File(modelPath).parent;
    final modelName = File(modelPath).uri.pathSegments.last;
    final job = 'stt_${DateTime.now().microsecondsSinceEpoch}';
    final sep = Platform.pathSeparator;
    final wavCopy = File('${work.path}$sep$job.wav');
    final rsp = File('${work.path}$sep$job.args');
    final jsonOut = File('${work.path}$sep$job.json');
    final threads = Platform.numberOfProcessors.clamp(1, 8).toInt();
    final a = args(model: modelName, wav: '$job.wav', outBase: job, language: language, prompt: prompt, threads: threads);
    try {
      await File(wavPath).copy(wavCopy.path);
      await rsp.writeAsString(responseFile(a), encoding: utf8);
      var (code, log) = await _run(cli, ['@$job.args'], work.path, onProgress);
      if (code != 0 && !jsonOut.existsSync() && RegExp(r"not found '@|response file").hasMatch(log)) {
        // Very old whisper.cpp without response files: plain arguments.
        (code, log) = await _run(cli, a, work.path, onProgress);
      }
      if (code != 0 || !jsonOut.existsSync()) {
        final lines = log.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
        final hint = lines.lastWhere((l) => l.contains('error') || l.contains('failed'), orElse: () => lines.isEmpty ? 'exit $code' : lines.last);
        throw StateError('Speech-to-text failed: ${hint.trim()}');
      }
      return parseJson(utf8.decode(await jsonOut.readAsBytes(), allowMalformed: true));
    } finally {
      for (final f in [wavCopy, rsp, jsonOut]) {
        try {
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }
  }

  static Future<(int, String)> _run(String cli, List<String> args, String cwd, void Function(int)? onProgress) async {
    final p = await Process.start(cli, args, workingDirectory: cwd);
    final log = StringBuffer();
    final errDone = p.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).forEach((l) {
      log.writeln(l);
      final pr = progress(l);
      if (pr != null) onProgress?.call(pr);
    });
    final outDone = p.stdout.transform(const Utf8Decoder(allowMalformed: true)).forEach((_) {});
    final code = await p.exitCode;
    await errDone;
    await outDone;
    return (code, log.toString());
  }
}
