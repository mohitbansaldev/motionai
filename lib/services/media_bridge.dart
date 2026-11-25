import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../platform/win_media.dart';
import '../platform/win_tools.dart';
import '../platform/windows_ai/win_ai.dart';

/// Platform media helpers with one Dart API:
///  - Android: Kotlin (android/app/src/main/kotlin/.../MediaBridge.kt)
///  - Windows: bundled FFmpeg, ONNX Runtime and pure-Dart image code
///    (lib/platform/).
/// Exact video frames, audio extraction, MP4 encoding with audio mix,
/// cut-out, erase, voice-over and saving.
class MediaBridge {
  static const _ch = MethodChannel('motionai/media');
  static bool get _win => Platform.isWindows;

  /// RGBA frame of [path] at [seconds], scaled to fit [maxSize] px.
  /// Returns (width, height, rgbaBytes) or null.
  static Future<(int, int, Uint8List)?> frameAt(String path, double seconds, {int maxSize = 1280}) async {
    if (_win) return WinMedia.frameAt(path, seconds, maxSize: maxSize);
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('frameAt', {
        'path': path,
        'timeUs': (seconds * 1e6).round(),
        'maxSize': maxSize,
      });
      if (r == null) return null;
      return (r['width'] as int, r['height'] as int, r['rgba'] as Uint8List);
    } on MissingPluginException {
      return null;
    }
  }

  /// Frame-exact sequential decoding for export. [key] identifies the
  /// reader (use the layer id) so each layer keeps its own decoder.
  static Future<(int, int, Uint8List)?> readerFrame(String key, String path, double seconds, {int maxSize = 1920}) async {
    if (_win) return WinMedia.readerFrame(key, path, seconds, maxSize: maxSize);
    final r = await _ch.invokeMapMethod<String, dynamic>('readerFrame', {
      'key': key,
      'path': path,
      'timeUs': (seconds * 1e6).round(),
      'maxSize': maxSize,
    });
    if (r == null) return null;
    return (r['width'] as int, r['height'] as int, r['rgba'] as Uint8List);
  }

  static Future<void> readerReleaseAll() => _win ? WinMedia.readerReleaseAll() : _ch.invokeMethod('readerReleaseAll');

  /// On-device AI subject cut-out (ML Kit). Writes a transparent PNG of the
  /// subject to [fgPath] and a background plate to [bgPath].
  static Future<(int, int)> cutout(String path, String fgPath, String bgPath) async {
    if (_win) return WinAi.cutout(path, fgPath, bgPath);
    final r = await _ch.invokeMapMethod<String, dynamic>('cutout', {'path': path, 'fg': fgPath, 'bg': bgPath});
    return (r!['width'] as int, r['height'] as int);
  }

  /// Converts any phone photo to an upright JPEG/PNG. [outBase] has no extension.
  static Future<(String, int, int)?> normalizeImage(String path, String outBase) async {
    if (_win) {
      try {
        final out = '$outBase${path.toLowerCase().endsWith('.png') ? '.png' : '.jpg'}';
        final (w, h) = await WinAi.normalizeImage(path, out);
        return (out, w, h);
      } catch (_) {
        return null; // fall back to Flutter's own decoder
      }
    }
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('normalizeImage', {'path': path, 'out': outBase});
      if (r == null) return null;
      return (r['path'] as String, r['width'] as int, r['height'] as int);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null; // fall back to Flutter's own decoder
    }
  }

  /// Erases the white area of [maskPath] (same size as the image) on the phone.
  static Future<String> inpaint(String path, String maskPath, String outPath) async {
    if (_win) {
      await WinAi.inpaint(path, maskPath, outPath);
      return outPath;
    }
    final r = await _ch.invokeMapMethod<String, dynamic>('inpaint', {'path': path, 'mask': maskPath, 'out': outPath});
    return r!['path'] as String;
  }

  /// JPEG thumbnail for sending to the AI.
  static Future<Uint8List?> thumbnailJpeg(String path, double seconds, {int maxSize = 512}) async {
    if (_win) return WinMedia.thumbnailJpeg(path, seconds, maxSize: maxSize);
    try {
      return await _ch.invokeMethod<Uint8List>('thumbnailJpeg', {
        'path': path,
        'timeUs': (seconds * 1e6).round(),
        'maxSize': maxSize,
      });
    } on MissingPluginException {
      return null;
    }
  }

  /// Copies the audio track of a video into an .m4a file (no re-encoding).
  static Future<bool> extractAudio(String videoPath, String outPath) async {
    if (_win) return WinMedia.extractAudio(videoPath, outPath);
    final ok = await _ch.invokeMethod<bool>('extractAudio', {'path': videoPath, 'out': outPath});
    return ok ?? false;
  }

  /// Decodes audio (from a video or audio file) to 16 kHz mono WAV for
  /// speech-to-text. Returns the seconds written.
  static Future<double> wav16k(String path, String outPath, {double sourceIn = 0, double duration = 0}) async {
    if (_win) return WinMedia.wav16k(path, outPath, sourceIn: sourceIn, duration: duration);
    final r = await _ch.invokeMethod<num>('wav16k', {'path': path, 'out': outPath, 'sourceIn': sourceIn, 'duration': duration});
    return (r ?? 0).toDouble();
  }

  /// Reads each line with the phone's text-to-speech voice. Returns
  /// (wav path, seconds) per line.
  static Future<List<(String, double)>> tts(List<String> texts, String dir,
      {String lang = 'hi-IN', double rate = 1.0, double pitch = 1.0}) async {
    if (_win) return WinAi.tts(texts, dir, lang: lang, rate: rate, pitch: pitch);
    final r = await _ch.invokeMethod<List>('tts', {'texts': texts, 'lang': lang, 'rate': rate, 'pitch': pitch, 'dir': dir});
    return [for (final e in r ?? const []) ('${(e as Map)['path']}', (e['duration'] as num).toDouble())];
  }

  static Future<void> encoderStart({
    required String outPath,
    required int width,
    required int height,
    required double fps,
    required int bitrate,
  }) =>
      _win
          ? WinMedia.encoderStart(outPath: outPath, width: width, height: height, fps: fps, bitrate: bitrate)
          : _ch.invokeMethod('encoderStart', {
        'out': outPath,
        'width': width,
        'height': height,
        'fps': fps,
        'bitrate': bitrate,
      });

  static Future<void> encoderFrame(Uint8List rgba, int width, int height) => _win
      ? WinMedia.encoderFrame(rgba, width, height)
      : _ch.invokeMethod('encoderFrame', {'rgba': rgba, 'width': width, 'height': height});

  /// Finishes video, mixes [audio] clips and writes the final MP4 to [finalPath].
  /// Each audio entry: {path, start, sourceIn, duration, volume}.
  static Future<void> encoderFinish({
    required String finalPath,
    required double duration,
    required List<Map<String, dynamic>> audio,
  }) =>
      _win
          ? WinMedia.encoderFinish(finalPath: finalPath, duration: duration, audio: audio)
          : _ch.invokeMethod('encoderFinish', {'final': finalPath, 'duration': duration, 'audio': audio});

  static Future<void> encoderCancel() => _win ? WinMedia.encoderCancel() : _ch.invokeMethod('encoderCancel');

  /// Saves an MP4 to the phone's Movies/MotionAI folder (shows in Gallery).
  /// On Windows: copies it into Videos\MotionAI and returns the file path.
  static Future<String?> saveToGallery(String path, String name) => _win
      ? WinMedia.saveToFolder(path, name)
      : _ch.invokeMethod<String>('saveToGallery', {'path': path, 'name': name});

  /// Android share sheet; on Windows opens Explorer with the file selected.
  static Future<void> share(String path) =>
      _win ? WinTools.showInFolder(path) : _ch.invokeMethod('share', {'path': path});
}
