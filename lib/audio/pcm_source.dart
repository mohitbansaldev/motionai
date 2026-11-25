import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;

import '../core/model/project.dart';
import '../services/media_bridge.dart';
import 'audio_cache.dart';
import 'auto_mix.dart';
import 'loudness.dart';
import 'music_analysis.dart';
import 'wav.dart';

/// Mono float PCM decoded from a media file.
class PcmBuffer {
  final Float32List mono;
  final int sampleRate;
  const PcmBuffer(this.mono, this.sampleRate);
  double get duration => sampleRate <= 0 ? 0 : mono.length / sampleRate;
}

/// Decodes audio (from an audio OR video file) to mono PCM. The platform
/// layer implements this for formats Dart can't read (mp3/m4a/aac/mp4…):
///
///   * Android: [Wav16kBridgeSource] (MediaBridge.wav16k → 16 kHz WAV) — built in.
///   * Windows: set `PcmSources.platform = MyFfmpegSource()` at start-up
///     (e.g. `ffmpeg -ss <in> -t <dur> -i <path> -ac 1 -ar 22050 -f wav <tmp>`
///     then `Wav.decode`).
abstract class PcmSource {
  /// [sampleRate] is a preference (16000–44100 all work for analysis);
  /// [sourceIn]/[duration] select a range (duration 0 = to the end).
  /// Returns null when this source can't decode [path].
  Future<PcmBuffer?> load(String path, {int sampleRate = 22050, double sourceIn = 0, double duration = 0});
}

/// Reads .wav files directly (any rate / bit depth), on every platform.
class WavFileSource implements PcmSource {
  const WavFileSource();

  @override
  Future<PcmBuffer?> load(String path, {int sampleRate = 22050, double sourceIn = 0, double duration = 0}) async {
    if (!path.toLowerCase().endsWith('.wav')) return null;
    final f = File(path);
    if (!f.existsSync()) return null;
    try {
      final a = Wav.decode(await f.readAsBytes());
      return _range(PcmBuffer(a.mono(), a.sampleRate), sourceIn, duration);
    } on FormatException {
      return null;
    }
  }
}

/// Android: the Kotlin MediaBridge decodes anything the phone can play to a
/// 16 kHz mono WAV, which [Wav] then reads.
class Wav16kBridgeSource implements PcmSource {
  const Wav16kBridgeSource();

  @override
  Future<PcmBuffer?> load(String path, {int sampleRate = 22050, double sourceIn = 0, double duration = 0}) async {
    final tmp = File('${Directory.systemTemp.path}${Platform.pathSeparator}pcm_${DateTime.now().microsecondsSinceEpoch}.wav');
    try {
      final secs = await MediaBridge.wav16k(path, tmp.path, sourceIn: sourceIn, duration: duration);
      if (secs <= 0 || !tmp.existsSync()) return null;
      final a = Wav.decode(await tmp.readAsBytes());
      return PcmBuffer(a.mono(), a.sampleRate);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } on FormatException {
      return null;
    } finally {
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } on FileSystemException {
          // ignore
        }
      }
    }
  }
}

/// The decoder chain: WAV in Dart → the platform's source → Android bridge.
class PcmSources {
  /// Set by the platform layer (Windows: an FFmpeg-based [PcmSource]).
  static PcmSource? platform;

  static Future<PcmBuffer?> load(String path, {int sampleRate = 22050, double sourceIn = 0, double duration = 0}) async {
    for (final s in <PcmSource>[const WavFileSource(), if (platform != null) platform!, if (Platform.isAndroid) const Wav16kBridgeSource()]) {
      final b = await s.load(path, sampleRate: sampleRate, sourceIn: sourceIn, duration: duration);
      if (b != null && b.mono.isNotEmpty) return b;
    }
    return null;
  }
}

PcmBuffer _range(PcmBuffer b, double sourceIn, double duration) {
  if (sourceIn <= 0 && duration <= 0) return b;
  final s = (sourceIn * b.sampleRate).round().clamp(0, b.mono.length);
  final e = duration <= 0 ? b.mono.length : (s + duration * b.sampleRate).round().clamp(s, b.mono.length);
  return PcmBuffer(Float32List.sublistView(b.mono, s, e), b.sampleRate);
}

/// Decodes + analyses media in a background isolate and fills [AudioCache].
/// Results are also kept as small JSON files in the temp folder, so a
/// re-opened project doesn't decode the same song twice.
class AudioAnalyzer {
  static final Map<String, Future<MusicAnalysis?>> _running = {};

  static Future<MusicAnalysis?> music(MediaAsset m) {
    final cached = AudioCache.musicFor(m);
    if (cached != null) return Future.value(cached);
    return _running.putIfAbsent(m.path, () async {
      try {
        final disk = await _readDisk(m);
        if (disk != null) {
          AudioCache.putMusic(m, disk);
          return disk;
        }
        final pcm = await PcmSources.load(m.path);
        if (pcm == null) return null;
        final a = await Isolate.run(() => MusicAnalysis.analyze(pcm.mono, pcm.sampleRate));
        AudioCache.putMusic(m, a);
        await _writeDisk(m, a);
        return a;
      } finally {
        _running.remove(m.path);
      }
    });
  }

  /// Loudness + voice activity of a voice-over / A-roll file.
  static Future<double?> voice(MediaAsset m) async {
    final pcm = await PcmSources.load(m.path, sampleRate: 16000);
    if (pcm == null) return null;
    final (lufs, speech) = await Isolate.run(() => (Loudness.lufs(pcm.mono, pcm.sampleRate), AutoMix.speechIntervals(pcm.mono, pcm.sampleRate)));
    AudioCache.putLoudness(m, lufs);
    AudioCache.putSpeech(m, speech);
    return lufs;
  }

  /// Loudness only (SFX, ambience).
  static Future<double?> loudness(MediaAsset m) async {
    final known = AudioCache.lufsFor(m);
    if (known != null) return known;
    final pcm = await PcmSources.load(m.path, sampleRate: 16000);
    if (pcm == null) return null;
    final v = await Isolate.run(() => Loudness.lufs(pcm.mono, pcm.sampleRate));
    AudioCache.putLoudness(m, v);
    return v;
  }

  static File _diskFile(MediaAsset m) {
    final f = File(m.path);
    final stamp = f.existsSync() ? '${f.lengthSync()}_${f.lastModifiedSync().millisecondsSinceEpoch}' : '';
    final key = crypto.md5.convert(utf8.encode('${m.path}|$stamp|v1')).toString();
    return File('${Directory.systemTemp.path}${Platform.pathSeparator}motionai_audio${Platform.pathSeparator}$key.json');
  }

  static Future<MusicAnalysis?> _readDisk(MediaAsset m) async {
    try {
      final f = _diskFile(m);
      if (!f.existsSync()) return null;
      return MusicAnalysis.fromJson(Map<String, dynamic>.from(jsonDecode(await f.readAsString()) as Map));
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeDisk(MediaAsset m, MusicAnalysis a) async {
    try {
      final f = _diskFile(m);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(a.toJson()));
    } catch (_) {
      // cache only
    }
  }
}
