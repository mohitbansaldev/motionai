// PLACEHOLDER owned by Agent E (feat/winai): E's real implementation replaces
// this file at merge. Until then it delegates to Agent A's interim Windows
// implementations in lib/platform/ so the feat/windows build is usable.
// Signatures are the agreed contract — keep them exactly.
import 'dart:io';

import '../../ai/ai_settings.dart';
import '../../core/model/layer.dart';
import '../image_ops.dart';
import '../whisper_cli.dart';
import '../win_cutout.dart';
import '../win_tools.dart';
import '../win_tts.dart';

class WinAi {
  /// Subject cut-out: transparent PNG of the subject + background plate.
  static Future<(int, int)> cutout(String path, String fgPath, String bgPath) => WinCutout.cutout(path, fgPath, bgPath);

  /// Erases the white area of [maskPngPath] from [imagePath] into [outPath].
  static Future<void> inpaint(String imagePath, String maskPngPath, String outPath) async {
    await ImageOps.inpaint(imagePath, maskPngPath, outPath);
  }

  /// Upright, size-limited copy of any photo at [outPath] (.jpg or .png).
  static Future<(int, int)> normalizeImage(String inPath, String outPath) async {
    final dot = outPath.lastIndexOf('.');
    final base = dot > 0 ? outPath.substring(0, dot) : outPath;
    final (written, w, h) = await ImageOps.normalizeImage(inPath, base);
    if (written != outPath) await File(written).rename(outPath);
    return (w, h);
  }

  /// One WAV per line with an installed Windows voice: (path, seconds).
  static Future<List<(String, double)>> tts(List<String> texts, String dir,
          {String lang = 'hi-IN', double rate = 1.0, double pitch = 1.0}) =>
      WinTts.speak(texts, dir, lang: lang, rate: rate, pitch: pitch);

  /// Word timings (seconds of [wavPath], a 16 kHz mono WAV).
  static Future<List<WordTiming>> words(String wavPath,
      {String? language, String? prompt, void Function(String status)? onStatus}) async {
    final exe = WinTools.whisperCli;
    if (exe == null) throw StateError('Speech-to-text engine (whisper-cli.exe) is missing. Reinstall MotionAI.');
    final name = WhisperCli.normalizeModel((await AiSettings.load()).whisperModel);
    final m = await WhisperCli.ensureModel(name,
        onProgress: (p) => onStatus?.call('Downloading the speech model once… ${(p * 100).round()}%'));
    onStatus?.call('Listening on this PC…');
    final words = await WhisperCli.transcribe(
      exe: exe,
      model: m,
      wav: wavPath,
      language: language,
      prompt: prompt,
      onProgress: (p) => onStatus?.call('Listening on this PC… $p%'),
    );
    return [for (final (w, a, b) in words) WordTiming(w, a, b)];
  }
}
