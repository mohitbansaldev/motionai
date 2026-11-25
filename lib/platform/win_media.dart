import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'byte_queue.dart';
import 'ffmpeg_args.dart';
import 'win_tools.dart';

/// Windows implementation of the media bridge, built on the bundled
/// ffmpeg.exe / ffprobe.exe (raw RGBA pipes for frames and encoding).
class WinMedia {
  static final Map<String, ProbeInfo> _probeCache = {};

  static Future<ProbeInfo> probe(String path) async {
    final f = File(path);
    final key = '$path|${f.existsSync() ? f.lastModifiedSync().millisecondsSinceEpoch : 0}';
    final cached = _probeCache[key];
    if (cached != null) return cached;
    final r = await Process.run(WinTools.ffprobe, probeArgs(path), stdoutEncoding: utf8, stderrEncoding: utf8);
    if (r.exitCode != 0) throw FfmpegException('Cannot read this file', '${r.stderr}');
    final info = parseProbe('${r.stdout}');
    _probeCache[key] = info;
    return info;
  }

  static Future<Uint8List> _runBytes(List<String> args) async {
    final r = await Process.run(WinTools.ffmpeg, args, stdoutEncoding: null, stderrEncoding: utf8);
    if (r.exitCode != 0) throw FfmpegException('FFmpeg failed', '${r.stderr}');
    final out = r.stdout;
    return out is Uint8List ? out : Uint8List.fromList((out as List).cast<int>());
  }

  static Future<void> _run(List<String> args, {String what = 'FFmpeg failed'}) async {
    final r = await Process.run(WinTools.ffmpeg, args, stdoutEncoding: utf8, stderrEncoding: utf8);
    if (r.exitCode != 0) throw FfmpegException(what, '${r.stderr}');
  }

  // ------------------------------------------------------------ frames

  static Future<(int, int, Uint8List)?> frameAt(String path, double seconds, {int maxSize = 1280}) async {
    final info = await probe(path);
    if (!info.hasVideo) return null;
    final (tw, th) = fitSize(info.displayWidth, info.displayHeight, maxSize);
    var t = seconds;
    for (var attempt = 0; attempt < 3; attempt++) {
      final bytes = await _runBytes(frameArgs(path, t, tw, th));
      if (bytes.length >= tw * th * 4) return (tw, th, Uint8List.sublistView(bytes, 0, tw * th * 4));
      // Past the last frame: step back a little.
      t = (t - 0.25 - attempt * 0.5).clamp(0.0, double.infinity).toDouble();
    }
    return null;
  }

  static Future<Uint8List?> thumbnailJpeg(String path, double seconds, {int maxSize = 512}) async {
    final info = await probe(path);
    if (!info.hasVideo) return null;
    final (tw, th) = fitSize(info.displayWidth, info.displayHeight, maxSize);
    final bytes = await _runBytes(thumbArgs(path, seconds, tw, th));
    if (bytes.isEmpty && seconds > 0.3) return thumbnailJpeg(path, seconds - 0.3, maxSize: maxSize);
    return bytes.isEmpty ? null : bytes;
  }

  static final Map<String, _FrameReader> _readers = {};

  static Future<(int, int, Uint8List)?> readerFrame(String key, String path, double seconds, {int maxSize = 1920}) async {
    var r = _readers[key];
    if (r == null || r.path != path || r.maxSize != maxSize) {
      await r?.release();
      final info = await probe(path);
      if (!info.hasVideo) return null;
      r = _FrameReader(path, info, maxSize);
      _readers[key] = r;
    }
    final f = await r.frameAt(seconds);
    return f == null ? null : (r.width, r.height, f);
  }

  static Future<void> readerReleaseAll() async {
    final all = _readers.values.toList();
    _readers.clear();
    for (final r in all) {
      await r.release();
    }
  }

  // ------------------------------------------------------------- audio

  static Future<bool> extractAudio(String path, String out) async {
    final info = await probe(path);
    if (!info.hasAudio) return false;
    try {
      await _run(extractAudioArgs(path, out));
    } on FfmpegException {
      await _run(extractAudioArgs(path, out, reencode: true), what: 'Could not extract the audio');
    }
    return File(out).existsSync();
  }

  static Future<double> wav16k(String path, String out, {double sourceIn = 0, double duration = 0}) async {
    final info = await probe(path);
    if (!info.hasAudio) throw const FfmpegException('No readable audio in this file');
    await _run(wav16kArgs(path, out, sourceIn: sourceIn, duration: duration), what: 'Could not decode the audio');
    final dur = duration > 0 ? duration : (info.duration - sourceIn);
    return dur < 0.5 ? 0.5 : dur;
  }

  // ------------------------------------------------------------ encoder

  /// 'auto' or one of [kEncoders]. Set by the export screen.
  static String preferredEncoder = 'auto';
  static String? lastEncoder;
  static List<String>? _working;

  /// Encoders that really work on this PC (GPU drivers present), best first.
  /// win-30: an encoder that fails with the main FFmpeg is tried again with
  /// the bundled compat FFmpeg (older NVENC API); the reason of every failure
  /// is kept in [encoderErrors] for the export screen.
  static Future<List<String>> workingEncoders({bool refresh = false}) async {
    final cached = _working;
    if (cached != null && !refresh) return cached;
    final ok = <String>[];
    encoderErrors.clear();
    encoderBinary.clear();
    for (final e in kEncoders) {
      final err = await _probe(WinTools.ffmpeg, e);
      if (err == null) {
        ok.add(e);
        encoderBinary[e] = WinTools.ffmpeg;
        continue;
      }
      final compat = WinTools.ffmpegCompat;
      final err2 = compat == null ? 'no compat FFmpeg bundled' : await _probe(compat, e);
      if (compat != null && err2 == null) {
        ok.add(e);
        encoderBinary[e] = compat;
      } else {
        encoderErrors[e] = compat == null ? err : '$err\n(compat FFmpeg: $err2)';
      }
    }
    if (!ok.contains('libx264')) {
      ok.add('libx264');
      encoderBinary['libx264'] = WinTools.ffmpeg;
    }
    return _working = ok;
  }

  /// Why each GPU encoder failed its test (empty when all work).
  static final Map<String, String> encoderErrors = {};

  /// Which ffmpeg.exe runs each working encoder (main or compat).
  static final Map<String, String> encoderBinary = {};

  /// Null when [enc] encodes a test clip with [ffmpeg], else the error text.
  static Future<String?> _probe(String ffmpeg, String enc) async {
    try {
      final r = await Process.run(ffmpeg, encoderProbeArgs(enc)).timeout(const Duration(seconds: 20));
      if (r.exitCode == 0) return null;
      final msg = '${r.stderr}'.trim().split(RegExp(r'[\r\n]+')).where((x) => x.trim().isNotEmpty).take(3).join(' · ');
      return msg.isEmpty ? 'exit code ${r.exitCode}' : msg;
    } catch (e) {
      return '$e';
    }
  }

  static Process? _enc;
  static String? _encOut;
  static Future<void>? _encStderr;
  static final StringBuffer _encLog = StringBuffer();

  static Future<void> encoderStart({
    required String outPath,
    required int width,
    required int height,
    required double fps,
    required int bitrate,
  }) async {
    await encoderCancel();
    final working = await workingEncoders();
    final enc = preferredEncoder != 'auto' && working.contains(preferredEncoder) ? preferredEncoder : working.first;
    lastEncoder = enc;
    _encLog.clear();
    final p = await Process.start(encoderBinary[enc] ?? WinTools.ffmpeg, encoderArgs(enc, outPath, width, height, fps, bitrate));
    _enc = p;
    _encOut = outPath;
    _encStderr = p.stderr.transform(utf8.decoder).forEach(_encLog.write);
    p.stdout.drain<void>().ignore();
  }

  static Future<void> encoderFrame(Uint8List rgba, int width, int height) async {
    final p = _enc;
    if (p == null) throw StateError('Encoder not started');
    try {
      p.stdin.add(rgba);
      await p.stdin.flush();
    } catch (_) {
      throw FfmpegException('The video encoder stopped', _encLog.toString());
    }
  }

  static Future<void> encoderFinish({
    required String finalPath,
    required double duration,
    required List<Map<String, dynamic>> audio,
  }) async {
    final p = _enc;
    final tmp = _encOut;
    if (p == null || tmp == null) throw StateError('Encoder not started');
    _enc = null;
    await p.stdin.close();
    final code = await p.exitCode;
    await _encStderr;
    if (code != 0) throw FfmpegException('Video encoding failed', _encLog.toString());

    final clips = <MixClip>[];
    for (final m in audio) {
      try {
        final path = '${m['path']}';
        final info = await probe(path);
        if (!info.hasAudio) continue;
        final c = MixClip.fromMap(m, mono: info.audioChannels == 1);
        if (c.audible) clips.add(c);
      } catch (_) {
        // Skip clips whose audio can't be read.
      }
    }
    final script = File('$tmp.filter.txt');
    if (clips.isNotEmpty) await script.writeAsString(mixFilterGraph(clips, duration));
    try {
      await _run(muxArgs(tmp, clips, duration, finalPath, script.path), what: 'Audio mixing failed');
    } finally {
      if (await script.exists()) script.delete().ignore();
      File(tmp).delete().ignore();
    }
  }

  static Future<void> encoderCancel() async {
    final p = _enc;
    _enc = null;
    if (p == null) return;
    try {
      await p.stdin.close();
    } catch (_) {}
    p.kill();
    await p.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    final out = _encOut;
    if (out != null) File(out).delete().ignore();
  }

  // ------------------------------------------------------------- saving

  /// Copies the export into [dir] (default Videos\MotionAI) and returns the path.
  static Future<String> saveToFolder(String path, String name, {String? dir}) async {
    final d = Directory(dir ?? WinTools.defaultExportDir());
    if (!await d.exists()) await d.create(recursive: true);
    final dest = '${d.path}\\$name';
    if (File(path).absolute.path.toLowerCase() == File(dest).absolute.path.toLowerCase()) return dest;
    await File(path).copy(dest);
    return dest;
  }
}

/// Sequential decoder for export: one ffmpeg process per layer that streams
/// constant-rate RGBA frames; it only restarts when time jumps.
class _FrameReader {
  final String path;
  final ProbeInfo info;
  final int maxSize;
  late final int width, height;
  late final double fps;
  Process? _p;
  ByteQueue? _q;
  double _t0 = 0;
  int _index = -1; // index of [_last] in the current stream
  Uint8List? _last;
  bool _eof = false;

  _FrameReader(this.path, this.info, this.maxSize) {
    final (w, h) = fitSize(info.displayWidth, info.displayHeight, maxSize);
    width = w;
    height = h;
    fps = info.fps;
  }

  int get _frameBytes => width * height * 4;

  Future<void> _open(double t) async {
    await _close();
    _t0 = t < 0 ? 0 : t;
    _index = -1;
    _eof = false;
    final p = await Process.start(WinTools.ffmpeg, readerArgs(path, _t0, width, height, fps));
    p.stderr.drain<void>().ignore();
    _p = p;
    _q = ByteQueue(p.stdout, highWater: _frameBytes * 3);
  }

  Future<void> _close() async {
    final p = _p, q = _q;
    _p = null;
    _q = null;
    if (q != null) await q.cancel();
    if (p != null) {
      p.kill();
      await p.exitCode.timeout(const Duration(seconds: 3), onTimeout: () => -1);
    }
  }

  Future<Uint8List?> frameAt(double t) async {
    var want = _p == null ? -1 : ((t - _t0) * fps + 1e-3).floor();
    if (_p == null || want < 0 || want < _index || want > _index + fps * 1.5) {
      await _open(t);
      want = 0;
    }
    while (_index < want && !_eof) {
      final f = await _q!.read(_frameBytes);
      if (f == null) {
        _eof = true; // past the end: keep showing the last frame
        break;
      }
      _last = f;
      _index++;
    }
    return _last;
  }

  Future<void> release() async {
    await _close();
    _last = null;
  }
}

class FfmpegException implements Exception {
  final String message;
  final String log;
  const FfmpegException(this.message, [this.log = '']);

  @override
  String toString() {
    final lines = log.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
    final tail = lines.length > 4 ? lines.sublist(lines.length - 4) : lines;
    return tail.isEmpty ? message : '$message: ${tail.join(' | ')}';
  }
}
