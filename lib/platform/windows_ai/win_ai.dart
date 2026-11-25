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
import 'depth.dart'; // V2-E
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

  // V2-E >>> depth from photo (photo_to_3d / depth_map). Runs on every
  // platform: the ONNX depth model on Windows ([model] auto|depth), the
  // pure-Dart estimate elsewhere or as the fallback ([model] fake).
  static Future<(String?, String?)> _depthEngine(String model, void Function(String)? onStatus) async {
    if (model == 'fake') return (null, null);
    if (!Platform.isWindows) {
      if (model == 'depth') throw UnsupportedError('The depth model runs in the Windows app; use model "auto" or "fake" here.');
      return (null, null);
    }
    final dll = onnxRuntimePath;
    if (!File(dll).existsSync()) {
      if (model == 'depth') throw StateError('The AI engine (onnxruntime.dll) is missing next to MotionAI. Reinstall MotionAI.');
      return (null, null);
    }
    try {
      final path = await ModelStore.ensure(Depth.model,
          onProgress: (p) => _status('Downloading the depth model once (${Depth.model.sizeLabel})… ${(p * 100).round()}%', onStatus));
      return (dll, path);
    } catch (e) {
      if (model == 'depth') rethrow;
      _status('Depth model unavailable ($e); using the built-in estimate', onStatus);
      return (null, null);
    }
  }

  /// Splits a photo into depth layers (PNG files "<outPrefix>_<i>.png");
  /// see [Depth.photoTo3dFile] for the result map.
  static Future<Map<String, dynamic>> photoTo3d(String path, String outPrefix,
      {required double mediaWidth, int layers = 4, double pad = 0, String model = 'auto', void Function(String status)? onStatus}) async {
    final (dll, modelPath) = await _depthEngine(model, onStatus);
    _status(modelPath == null ? 'Estimating depth and building layers…' : 'Reading depth with AI and building layers…', onStatus);
    return _photoTo3dIsolate(path, outPrefix, mediaWidth, layers, pad, dll, modelPath, _threads, model == 'depth');
  }

  // Separate functions so the isolate closures capture only plain values.
  static Future<Map<String, dynamic>> _photoTo3dIsolate(String path, String outPrefix, double mediaWidth, int layers, double pad,
          String? dll, String? modelPath, int threads, bool require) =>
      Isolate.run(() => Depth.photoTo3dFile(
          path: path, outPrefix: outPrefix, mediaWidth: mediaWidth, layers: layers, pad: pad,
          ortLibrary: dll, modelPath: modelPath, threads: threads, requireModel: require));

  /// Grayscale depth PNG of a photo (near = white); see [Depth.depthMapFile].
  static Future<Map<String, dynamic>> depthMap(String path, String outPath, {String model = 'auto', void Function(String status)? onStatus}) async {
    final (dll, modelPath) = await _depthEngine(model, onStatus);
    _status('Reading depth…', onStatus);
    return _depthMapIsolate(path, outPath, dll, modelPath, _threads, model == 'depth');
  }

  static Future<Map<String, dynamic>> _depthMapIsolate(String path, String outPath, String? dll, String? modelPath, int threads, bool require) =>
      Isolate.run(() => Depth.depthMapFile(
          path: path, outPath: outPath, ortLibrary: dll, modelPath: modelPath, threads: threads, requireModel: require));
  // <<< V2-E

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
