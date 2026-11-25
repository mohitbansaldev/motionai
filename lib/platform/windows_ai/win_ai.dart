// Windows AI layer (Agent E, feat/winai). The phone does these in Kotlin
// (MediaBridge.kt); on Windows they run on the PC, fully offline after a
// one-time model download:
//  - cutout:         U²-Net-p salient-object model via ONNX Runtime (FFI to the
//                    bundled onnxruntime.dll) + Dart pre/post-processing.
//  - inpaint:        pure-Dart port of the phone's multi-scale diffusion fill.
//  - normalizeImage: pure-Dart decode + EXIF rotation (package:image).
//  - tts:            installed Windows voices via PowerShell (System.Speech,
//                    and OneCore voices such as Hindi Kalpana/Hemant).
//  - words:          bundled whisper.cpp CLI + ggml model.
// Heavy work runs in background isolates. Signatures are the agreed contract.
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import '../../ai/ai_settings.dart';
import '../../core/model/layer.dart';
import 'image_io.dart';
import 'inpaint.dart';
import 'model_store.dart';
import 'segment.dart';
import 'tts.dart';
import 'whisper.dart';

class WinAi {
  /// Folder of motionai.exe (bundled helpers live here).
  static String get exeDir => File(Platform.resolvedExecutable).parent.path;

  /// ONNX Runtime library bundled by CI next to the exe.
  static String get onnxRuntimePath => '$exeDir${Platform.pathSeparator}onnxruntime.dll';

  /// Status of the last model download / step (for UIs that want to show it).
  static void Function(String status)? statusListener;

  static void _status(String s, void Function(String)? local) {
    local?.call(s);
    statusListener?.call(s);
  }

  static void _needWindows(String what) {
    if (!Platform.isWindows) throw UnsupportedError('$what on this platform is handled by the phone app.');
  }

  static int get _threads => math.max(1, Platform.numberOfProcessors ~/ 2);

  /// Subject cut-out: transparent PNG of the subject + background plate.
  static Future<(int, int)> cutout(String path, String fgPath, String bgPath, {void Function(String status)? onStatus}) async {
    _needWindows('Photo cut-out');
    final dll = onnxRuntimePath;
    if (!File(dll).existsSync()) throw StateError('The cut-out engine (onnxruntime.dll) is missing next to MotionAI. Reinstall MotionAI.');
    final model = await ModelStore.ensure(Segment.model,
        onProgress: (p) => _status('Downloading the cut-out model once (${Segment.model.sizeLabel})… ${(p * 100).round()}%', onStatus));
    _status('Finding the subject…', onStatus);
    return _cutoutIsolate(dll, model, path, fgPath, bgPath, _threads);
  }

  // Separate function so the isolate closure captures only plain strings.
  static Future<(int, int)> _cutoutIsolate(String dll, String model, String path, String fg, String bg, int threads) =>
      Isolate.run(() => Segment.cutoutFile(dll, model, path, fg, bg, threads));

  /// Erases the white area of [maskPngPath] from [imagePath] into [outPath].
  static Future<void> inpaint(String imagePath, String maskPngPath, String outPath) async {
    await _inpaintIsolate(imagePath, maskPngPath, outPath);
  }

  static Future<(int, int)> _inpaintIsolate(String image, String mask, String out) =>
      Isolate.run(() => Inpaint.file(image, mask, out));

  /// Upright, size-limited copy of any photo at [outPath] (.jpg or .png).
  static Future<(int, int)> normalizeImage(String inPath, String outPath) => _normalizeIsolate(inPath, outPath);

  static Future<(int, int)> _normalizeIsolate(String inPath, String outPath) =>
      Isolate.run(() => ImageIo.normalizeFile(inPath, outPath));

  /// One WAV per line with an installed Windows voice: (path, seconds).
  static Future<List<(String, double)>> tts(List<String> texts, String dir,
      {String lang = 'hi-IN', double rate = 1.0, double pitch = 1.0}) async {
    _needWindows('Windows voices');
    final res = await WinTtsEngine.speak(texts, dir, lang: lang, rate: rate, pitch: pitch);
    final note = WinTtsEngine.lastNotice;
    if (note != null) _status(note, null);
    return res;
  }

  /// Word timings (seconds of [wavPath], a 16 kHz mono WAV).
  static Future<List<WordTiming>> words(String wavPath,
      {String? language, String? prompt, void Function(String status)? onStatus}) async {
    _needWindows('Speech-to-text');
    final cli = Whisper.findCli(exeDir);
    if (cli == null) throw StateError('The speech-to-text engine (whisper-cli.exe) is missing. Reinstall MotionAI.');
    final spec = Whisper.model((await AiSettings.load()).whisperModel);
    final model = await ModelStore.ensure(spec,
        onProgress: (p) => _status('Downloading the ${spec.label} once (${spec.sizeLabel})… ${(p * 100).round()}%', onStatus));
    _status('Listening on this PC…', onStatus);
    final words = await Whisper.transcribe(
      cli: cli,
      modelPath: model,
      wavPath: wavPath,
      language: language,
      prompt: prompt,
      onProgress: (p) => _status('Listening on this PC… $p%', onStatus),
    );
    return [for (final (w, a, b) in words) WordTiming(w, a, b)];
  }
}
