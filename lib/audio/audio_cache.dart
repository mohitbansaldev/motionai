import '../core/model/project.dart';
import 'music_analysis.dart';
import 'sfx_library.dart';

/// In-memory results of audio analysis, by media file path, so edit commands
/// (which run synchronously) can use beats and loudness measured earlier by
/// the Sound sheet, the Director or the platform layer.
///
/// Fill it with [AudioAnalyzer] (lib/audio/pcm_source.dart) or [putMusic].
class AudioCache {
  static final Map<String, MusicAnalysis> _music = {};
  static final Map<String, double> _lufs = {};
  static final Map<String, List<(double, double)>> _speech = {};

  static MusicAnalysis? musicFor(MediaAsset m) => _music[m.path];

  /// Measured (or, for generated SFX, computed) loudness in approx. LUFS.
  static double? lufsFor(MediaAsset m) {
    final v = _lufs[m.path];
    if (v != null) return v;
    final k = SfxLibrary.kindOf(m);
    return k == null ? null : SfxLibrary.lufs(k);
  }

  /// Voice activity of a voice-over / A-roll file, in source seconds.
  static List<(double, double)>? speechFor(MediaAsset m) => _speech[m.path];

  static void putMusic(MediaAsset m, MusicAnalysis a) {
    _music[m.path] = a;
    _lufs[m.path] = a.loudness;
  }

  static void putLoudness(MediaAsset m, double lufs) => _lufs[m.path] = lufs;

  static void putSpeech(MediaAsset m, List<(double, double)> intervals) => _speech[m.path] = intervals;

  static void clear() {
    _music.clear();
    _lufs.clear();
    _speech.clear();
  }
}
