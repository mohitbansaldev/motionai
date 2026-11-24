import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Native Android helpers (Kotlin, see android/app/src/main/kotlin/.../MediaBridge.kt):
/// exact video frames, audio extraction, MP4 encoding with audio mix,
/// and saving to the phone's gallery.
class MediaBridge {
  static const _ch = MethodChannel('motionai/media');

  /// RGBA frame of [path] at [seconds], scaled to fit [maxSize] px.
  /// Returns (width, height, rgbaBytes) or null.
  static Future<(int, int, Uint8List)?> frameAt(String path, double seconds, {int maxSize = 1280}) async {
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
    final r = await _ch.invokeMapMethod<String, dynamic>('readerFrame', {
      'key': key,
      'path': path,
      'timeUs': (seconds * 1e6).round(),
      'maxSize': maxSize,
    });
    if (r == null) return null;
    return (r['width'] as int, r['height'] as int, r['rgba'] as Uint8List);
  }

  static Future<void> readerReleaseAll() => _ch.invokeMethod('readerReleaseAll');

  /// On-device AI subject cut-out (ML Kit). Writes a transparent PNG of the
  /// subject to [fgPath] and a background plate to [bgPath].
  static Future<(int, int)> cutout(String path, String fgPath, String bgPath) async {
    final r = await _ch.invokeMapMethod<String, dynamic>('cutout', {'path': path, 'fg': fgPath, 'bg': bgPath});
    return (r!['width'] as int, r['height'] as int);
  }

  /// Converts any phone photo to an upright JPEG/PNG. [outBase] has no extension.
  static Future<(String, int, int)?> normalizeImage(String path, String outBase) async {
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
    final r = await _ch.invokeMapMethod<String, dynamic>('inpaint', {'path': path, 'mask': maskPath, 'out': outPath});
    return r!['path'] as String;
  }

  /// JPEG thumbnail for sending to the AI.
  static Future<Uint8List?> thumbnailJpeg(String path, double seconds, {int maxSize = 512}) async {
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
    final ok = await _ch.invokeMethod<bool>('extractAudio', {'path': videoPath, 'out': outPath});
    return ok ?? false;
  }

  static Future<void> encoderStart({
    required String outPath,
    required int width,
    required int height,
    required double fps,
    required int bitrate,
  }) =>
      _ch.invokeMethod('encoderStart', {
        'out': outPath,
        'width': width,
        'height': height,
        'fps': fps,
        'bitrate': bitrate,
      });

  static Future<void> encoderFrame(Uint8List rgba, int width, int height) =>
      _ch.invokeMethod('encoderFrame', {'rgba': rgba, 'width': width, 'height': height});

  /// Finishes video, mixes [audio] clips and writes the final MP4 to [finalPath].
  /// Each audio entry: {path, start, sourceIn, duration, volume}.
  static Future<void> encoderFinish({
    required String finalPath,
    required double duration,
    required List<Map<String, dynamic>> audio,
  }) =>
      _ch.invokeMethod('encoderFinish', {'final': finalPath, 'duration': duration, 'audio': audio});

  static Future<void> encoderCancel() => _ch.invokeMethod('encoderCancel');

  /// Saves an MP4 to the phone's Movies/MotionAI folder (shows in Gallery).
  static Future<String?> saveToGallery(String path, String name) =>
      _ch.invokeMethod<String>('saveToGallery', {'path': path, 'name': name});

  static Future<void> share(String path) => _ch.invokeMethod('share', {'path': path});
}
