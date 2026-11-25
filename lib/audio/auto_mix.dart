import 'dart:math' as math;
import 'dart:typed_data';

import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../director/sfx.dart';
import '../director/story_builder.dart';
import 'loudness.dart';
import 'sfx_library.dart';

/// Loudness targets per track type (approx. LUFS; RMS-gated proxy).
class MixTargets {
  final double voice, music, sfx, ambience;

  /// How far music dips under the voice (dB), and ambience.
  final double musicDuck, ambienceDuck;
  const MixTargets({
    this.voice = -16,
    this.music = -28,
    this.sfx = -20,
    this.ambience = -32,
    this.musicDuck = -10,
    this.ambienceDuck = -6,
  });

  double of(String role) => switch (role) {
        'voice' => voice,
        'music' => music,
        'sfx' => sfx,
        'ambience' => ambience,
        _ => music,
      };
}

/// Automatic mix: per-track loudness normalisation, ducking under the voice,
/// fades in/out, and ambience beds per scene mood. Pure: returns edit
/// commands (volume properties / keyframes and audio layers).
class AutoMix {
  static const roles = ['voice', 'music', 'sfx', 'ambience', 'none'];

  /// Typical loudness assumed when a file has not been measured yet.
  static const assumed = {'voice': -20.0, 'music': -12.0, 'sfx': -18.0, 'ambience': -30.0};

  static const fadeIn = {'music': 0.6, 'ambience': 1.5};
  static const fadeOut = {'music': 1.5, 'ambience': 1.5};

  /// Mood keyword → ambience bed.
  static String? bedForMood(String mood) {
    final m = mood.toLowerCase();
    bool has(List<String> w) => w.any(m.contains);
    if (Sfx.beds.contains(m)) return m;
    if (has(['rain', 'storm', 'monsoon', 'barish', 'baarish'])) return 'rain_bed';
    if (has(['night', 'cricket', 'village', 'raat', 'forest', 'jungle'])) return 'night_bed';
    if (has(['fire', 'war', 'battle', 'camp', 'burn', 'aag', 'yudh'])) return 'fire_bed';
    if (has(['crowd', 'market', 'protest', 'rally', 'street', 'bazaar', 'city', 'station', 'stadium', 'bheed'])) return 'crowd_bed';
    if (has(['wind', 'desert', 'mountain', 'empty', 'lonely', 'cold', 'snow', 'hawa', 'sea', 'ocean'])) return 'wind_bed';
    if (has(['clock', 'time', 'deadline', 'countdown', 'suspense', 'waiting'])) return 'clock_tick';
    if (has(['office', 'room', 'interior', 'court', 'calm', 'quiet', 'tense', 'lab', 'hospital'])) return 'room_tone';
    return null;
  }

  /// Guesses the role of an audio-carrying layer.
  static String roleOf(Project p, Layer l) {
    if (l.type != LayerType.audio && l.type != LayerType.video) return 'none';
    final m = l.mediaId == null ? null : p.media[l.mediaId];
    final k = m == null ? null : SfxLibrary.kindOf(m);
    final name = '${l.name} ${m?.name ?? ''}'.toLowerCase();
    if (k != null || name.startsWith('sfx ')) {
      final bed = (k != null && Sfx.isBed(k)) || name.contains('bed') || name.contains('ambience');
      return bed ? 'ambience' : 'sfx';
    }
    if (name.contains('ambience') || name.contains('ambient') || name.contains(' bed')) return 'ambience';
    if (name.contains('music') || name.contains('song') || name.contains('bgm') || name.contains('beat')) return 'music';
    if (RegExp(r'\b(voice|vo|narration|narrator|voiceover|tts|dub)\b').hasMatch(name) || name.contains('voice')) return 'voice';
    return l.type == LayerType.video ? 'voice' : 'music';
  }

  /// Volume (percent, 0-200) that brings a track measured at [measured] LUFS
  /// to [target].
  static double volumeFor(double measured, double target) {
    final g = Loudness.dbToGain(Loudness.gainTo(measured, target)) * 100;
    return (g.clamp(0.0, 200.0) * 10).roundToDouble() / 10;
  }

  /// The mix plan for the whole composition.
  ///
  /// [roles] overrides the guessed role per layer id; [loudness] gives the
  /// measured LUFS per media id (generated SFX are known; others fall back
  /// to [assumed]); [speech] are voice intervals in composition seconds
  /// (default: the time ranges of the voice layers).
  static List<Map<String, dynamic>> plan(
    Project p, {
    Map<String, String> roles = const {},
    Map<String, double> loudness = const {},
    List<(double, double)>? speech,
    bool duck = true,
    bool fades = true,
    MixTargets targets = const MixTargets(),
  }) {
    final comp = p.main;
    final tracks = <(Layer, String)>[];
    for (final l in comp.layers) {
      if (l.type != LayerType.audio && l.type != LayerType.video) continue;
      final role = roles[l.id] ?? roleOf(p, l);
      if (role == 'none') continue;
      tracks.add((l, role));
    }
    final voiceRanges = speech ??
        [
          for (final (l, r) in tracks)
            if (r == 'voice') (l.start, l.end),
        ];
    final total = comp.duration;
    final cmds = <Map<String, dynamic>>[];
    for (final (l, role) in tracks) {
      final m = l.mediaId == null ? null : p.media[l.mediaId];
      final k = m == null ? null : SfxLibrary.kindOf(m);
      final measured = (m == null ? null : loudness[m.id]) ?? (k != null ? SfxLibrary.lufs(k) : null) ?? assumed[role] ?? -20.0;
      final base = volumeFor(measured, targets.of(role));
      cmds.add({'op': 'clear_keyframes', 'target': l.id, 'prop': 'volume'});
      cmds.add({'op': 'set_property', 'target': l.id, 'prop': 'volume', 'value': base});
      if (role != 'music' && role != 'ambience') continue;

      // Envelope: ducking (gain factor) × fades.
      final duckDb = role == 'music' ? targets.musicDuck : targets.ambienceDuck;
      final env = duck && voiceRanges.isNotEmpty
          ? StoryBuilder.duckEnvelope(voiceRanges, total, 1, Loudness.dbToGain(duckDb))
          : <(double, double)>[(0, 1), (total, 1)];
      final fi = fades && !_continues(tracks, l, role, atStart: true) ? math.min(fadeIn[role]!, l.duration / 3) : 0.0;
      final fo = fades && !_continues(tracks, l, role, atStart: false) ? math.min(fadeOut[role]!, l.duration / 3) : 0.0;
      double fade(double t) {
        var g = 1.0;
        if (fi > 0 && t < l.start + fi) g *= ((t - l.start) / fi).clamp(0.0, 1.0);
        if (fo > 0 && t > l.end - fo) g *= ((l.end - t) / fo).clamp(0.0, 1.0);
        return g;
      }

      final times = <double>{l.start, l.end, if (fi > 0) l.start + fi, if (fo > 0) l.end - fo};
      for (final e in env) {
        if (e.$1 > l.start && e.$1 < l.end) times.add(e.$1);
      }
      final sorted = times.toList()..sort();
      if (sorted.length <= 2 && fi == 0 && fo == 0 && _gainAt(env, l.start) == 1 && _gainAt(env, l.end) == 1) continue;
      var last = -1e9;
      for (final t in sorted) {
        if (t - last < 0.005) continue;
        last = t;
        final v = (base * _gainAt(env, t) * fade(t) * 10).roundToDouble() / 10;
        cmds.add({'op': 'set_keyframe', 'target': l.id, 'prop': 'volume', 'time': _r(t), 'value': v, 'ease': 'linear'});
      }
    }
    return cmds;
  }

  /// Ambience bed layers for [scenes] = (start, end, mood or bed kind).
  /// [bedMedia] maps bed kind → audio media id (see SfxLibrary.ensureSync).
  /// Long scenes tile the loopable bed; each scene fades in and out.
  static List<Map<String, dynamic>> ambience(Project p, List<(double, double, String)> scenes, Map<String, String> bedMedia,
      {MixTargets targets = const MixTargets(), String tag = 'amb', double fade = 1.0, double? volume}) {
    final cmds = <Map<String, dynamic>>[];
    var n = 0;
    for (final (s0, s1, mood) in scenes) {
      final kind = bedForMood(mood);
      if (kind == null || s1 - s0 < 0.3) continue;
      final media = p.media[bedMedia[kind]];
      if (media == null) continue;
      final vol = volume ?? volumeFor(SfxLibrary.kindOf(media) != null ? SfxLibrary.lufs(kind) : (assumed['ambience']!), targets.ambience);
      final len = media.duration > 0.5 ? media.duration : Sfx.length(kind);
      final f = math.min(fade, (s1 - s0) / 3);
      var t = s0;
      final ids = <String>[];
      while (t < s1 - 0.05 && ids.length < 200) {
        final d = math.min(len, s1 - t);
        final id = '${tag}_${n++}';
        ids.add(id);
        cmds.add({'op': 'add_layer', 'type': 'audio', 'media': media.id, 'id': id, 'name': 'Ambience ${Sfx.info(kind).$1}', 'start': _r(t), 'duration': _r(d), 'index': 1 << 20});
        cmds.add({'op': 'set_property', 'target': id, 'prop': 'volume', 'value': vol});
        t += d;
      }
      if (ids.isEmpty || f <= 0.05) continue;
      // Fade the first tile in and the last tile out.
      cmds.addAll([
        {'op': 'set_keyframe', 'target': ids.first, 'prop': 'volume', 'time': _r(s0), 'value': 0.0, 'ease': 'linear'},
        {'op': 'set_keyframe', 'target': ids.first, 'prop': 'volume', 'time': _r(math.min(s0 + f, s0 + len)), 'value': vol, 'ease': 'linear'},
      ]);
      final lastStart = s0 + len * (ids.length - 1);
      cmds.addAll([
        {'op': 'set_keyframe', 'target': ids.last, 'prop': 'volume', 'time': _r(math.max(lastStart + 0.002, s1 - f)), 'value': vol, 'ease': 'linear'},
        {'op': 'set_keyframe', 'target': ids.last, 'prop': 'volume', 'time': _r(s1), 'value': 0.0, 'ease': 'linear'},
      ]);
    }
    return cmds;
  }

  /// Voice activity from PCM energy: (start, end) seconds.
  static List<(double, double)> speechIntervals(Float32List mono, int sampleRate, {double minGap = 0.35, double minLength = 0.15}) {
    final hop = math.max(1, (sampleRate * 0.02).round());
    final nf = mono.length ~/ hop;
    if (nf == 0) return const [];
    final db = Float64List(nf);
    for (int f = 0; f < nf; f++) {
      var s = 0.0;
      for (int i = f * hop; i < (f + 1) * hop; i++) {
        s += mono[i] * mono[i];
      }
      db[f] = s <= 0 ? -120 : 10 * math.log(s / hop) / math.ln10;
    }
    final sorted = [...db]..sort();
    final noise = sorted[(nf * 0.1).floor()];
    final loud = sorted[(nf * 0.95).floor().clamp(0, nf - 1)];
    final thr = math.max(-55.0, math.max(noise + 8, loud - 30));
    final out = <(double, double)>[];
    int? s0;
    var lastOn = -1;
    for (int f = 0; f < nf; f++) {
      if (db[f] > thr) {
        s0 ??= f;
        lastOn = f;
      } else if (s0 != null && (f - lastOn) * hop / sampleRate > minGap) {
        out.add((s0 * hop / sampleRate, (lastOn + 1) * hop / sampleRate));
        s0 = null;
      }
    }
    if (s0 != null) out.add((s0 * hop / sampleRate, (lastOn + 1) * hop / sampleRate));
    return [for (final i in out) if (i.$2 - i.$1 >= minLength) i];
  }

  /// [intervals] in source seconds of [l]'s media → composition seconds.
  static List<(double, double)> toComp(List<(double, double)> intervals, Layer l) {
    final out = <(double, double)>[];
    for (final (a, b) in intervals) {
      final s = math.max(l.start, l.start + (a - l.sourceIn) / l.speed);
      final e = math.min(l.end, l.start + (b - l.sourceIn) / l.speed);
      if (e > s) out.add((s, e));
    }
    return out;
  }

  static bool _continues(List<(Layer, String)> tracks, Layer l, String role, {required bool atStart}) {
    for (final (o, r) in tracks) {
      if (o.id == l.id || r != role) continue;
      if (atStart && (o.end - l.start).abs() < 0.05) return true;
      if (!atStart && (o.start - l.end).abs() < 0.05) return true;
    }
    return false;
  }

  static double _gainAt(List<(double, double)> env, double t) {
    if (env.isEmpty) return 1;
    if (t <= env.first.$1) return env.first.$2;
    for (int i = 1; i < env.length; i++) {
      if (t <= env[i].$1) {
        final a = env[i - 1], b = env[i];
        final k = (t - a.$1) / math.max(1e-6, b.$1 - a.$1);
        return a.$2 + (b.$2 - a.$2) * k;
      }
    }
    return env.last.$2;
  }

  static double _r(double v) => (v * 10000).roundToDouble() / 10000;
}
