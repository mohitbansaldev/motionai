import 'dart:math' as math;

import '../core/commands/edit_commands.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../director/sfx.dart';
import 'audio_cache.dart';
import 'auto_mix.dart';
import 'beat_sync.dart';
import 'music_analysis.dart';
import 'sfx_library.dart';

/// Sound-design edit ops (dispatched from EditCommands; each expands into
/// ordinary commands, so they are atomic and undoable):
///
///   add_sfx   {kind | mood, time?, volume?, duration?, layer?, id?}
///   beat_sync {mode: cuts|pops|drop, music?, beats?, bpm?, offset?, downbeats?, layers?, tolerance?, at?, drop?, preroll?, fade_in?}
///   auto_mix  {roles?, duck?, fades?, targets?, speech?}
class SoundCommands {
  static const ops = ['add_sfx', 'beat_sync', 'auto_mix'];

  static List<Map<String, dynamic>> build(Project p, Map<String, dynamic> c, double now) => switch (c['op']) {
        'add_sfx' => _addSfx(p, c, now),
        'beat_sync' => _beatSync(p, c, now),
        'auto_mix' => _autoMix(p, c),
        _ => throw CommandError('Unknown sound op ${c['op']}'),
      };

  // ------------------------------------------------------------- add_sfx

  static List<Map<String, dynamic>> _addSfx(Project p, Map<String, dynamic> c, double now) {
    final comp = p.main;
    var kind = c['kind'] is String ? '${c['kind']}' : null;
    if (kind == null && c['mood'] is String) {
      kind = AutoMix.bedForMood('${c['mood']}');
      if (kind == null) throw CommandError('No ambience for mood "${c['mood']}". Beds: ${Sfx.beds.join(', ')}');
    }
    if (kind == null || !Sfx.all.contains(kind)) {
      throw CommandError('add_sfx needs "kind": one of ${Sfx.all.join(', ')} (or "mood" for an ambience bed)');
    }
    final String k = kind;
    final time = _num(c, 'time') ?? now;
    final volume = _num(c, 'volume');
    final id = c['id'] is String ? '${c['id']}' : Ids.next('sfx');
    if (comp.layerById(id) != null) throw CommandError('Layer id "$id" already exists');

    // Typewriter synced letter by letter to a text layer's typewriter animator.
    if (k == 'typewriter' && c['layer'] is String) {
      final l = comp.layerById('${c['layer']}');
      if (l == null || l.text == null) throw CommandError('add_sfx typewriter: "${c['layer']}" is not a text layer');
      final dur = l.text!.animDuration > 0 ? l.text!.animDuration : 1.0;
      final times = Sfx.typingTimes(l.text!.text, dur);
      if (times.isEmpty) throw CommandError('Text layer "${l.id}" has no letters');
      final a = _ensure(() => SfxLibrary.typingSync(p, times));
      return [
        {'op': 'add_layer', 'type': 'audio', 'media': a.id, 'id': id, 'name': 'SFX typing', 'start': l.start, 'duration': a.duration, 'index': 1 << 20},
        {'op': 'set_property', 'target': id, 'prop': 'volume', 'value': volume ?? AutoMix.volumeFor(SfxLibrary.lufs('typewriter'), const MixTargets().sfx)},
      ];
    }

    final a = _ensure(() => SfxLibrary.ensureSync(p, k));
    final duration = _num(c, 'duration');
    if (Sfx.isBed(k) && duration != null && duration > a.duration + 0.05) {
      final cmds = AutoMix.ambience(p, [(time, time + duration, k)], {k: a.id}, tag: id, volume: volume);
      if (cmds.isNotEmpty) return cmds;
    }
    // One-shot: the peak lands on [time]; a head that would start before 0 is skipped.
    final pk = Sfx.peak(k);
    final start = math.max(0.0, time - pk);
    final skip = math.max(0.0, pk - time);
    final len = math.min(a.duration, duration ?? a.duration) - skip;
    if (len <= 0.01) throw CommandError('add_sfx: nothing left of "$k" at time $time');
    return [
      {
        'op': 'add_layer', 'type': 'audio', 'media': a.id, 'id': id, 'name': SfxLibrary.nameFor(k),
        'start': start, 'duration': len, if (skip > 0) 'source_in': skip, 'index': 1 << 20,
      },
      {
        'op': 'set_property', 'target': id, 'prop': 'volume',
        'value': volume ?? AutoMix.volumeFor(SfxLibrary.lufs(k), Sfx.isBed(k) ? const MixTargets().ambience : const MixTargets().sfx),
      },
    ];
  }

  static MediaAsset _ensure(MediaAsset Function() f) {
    try {
      return f();
    } on ArgumentError catch (e) {
      throw CommandError('${e.message}');
    } catch (e) {
      throw CommandError('Could not write the sound file: $e');
    }
  }

  // ------------------------------------------------------------- beat_sync

  static List<Map<String, dynamic>> _beatSync(Project p, Map<String, dynamic> c, double now) {
    final comp = p.main;
    final mode = '${c['mode'] ?? 'cuts'}';
    if (!['cuts', 'pops', 'drop'].contains(mode)) throw CommandError('beat_sync "mode" must be cuts, pops or drop');
    final layers = (c['layers'] as List?)?.map((e) => '$e').toList();
    for (final id in layers ?? const <String>[]) {
      if (comp.layerById(id) == null) throw CommandError('No layer "$id"');
    }
    Layer? music;
    if (c['music'] != null) {
      music = comp.layerById('${c['music']}');
      if (music == null) throw CommandError('No music layer "${c['music']}"');
    }

    if (mode == 'drop') {
      music ??= _musicLayers(p).firstOrNull;
      if (music == null) throw CommandError('beat_sync drop needs "music": an audio layer id');
      final media = music.mediaId == null ? null : p.media[music.mediaId];
      final a = media == null ? null : AudioCache.musicFor(media);
      final drop = _num(c, 'drop') ?? a?.mainDrop ?? a?.downbeats.where((d) => d > 4).firstOrNull;
      if (drop == null) {
        throw CommandError('No drop known for "${music.id}". Analyse the music in the Sound sheet first, or pass "drop": seconds into the music file');
      }
      return BeatSync.hitOnDrop(p, music.id, drop,
          at: _num(c, 'at') ?? now, preroll: _num(c, 'preroll') ?? 0, fadeIn: _num(c, 'fade_in') ?? 0);
    }

    final beats = _beats(p, c, music);
    if (beats.isEmpty) {
      throw CommandError('beat_sync needs beats: analyse the music in the Sound sheet first, or pass "bpm" (+ "offset"), or "beats": [seconds]');
    }
    final tol = _num(c, 'tolerance');
    return mode == 'cuts'
        ? BeatSync.snapCuts(p, beats, tolerance: tol ?? 0.25, layers: layers)
        : BeatSync.popsOnBeats(p, beats, layers: layers, tolerance: tol ?? 0.35);
  }

  static List<Layer> _musicLayers(Project p) => [
        for (final l in p.main.layers)
          if (l.type == LayerType.audio && AutoMix.roleOf(p, l) == 'music') l,
      ];

  /// Beats on the composition timeline from the command or the cache.
  static List<double> _beats(Project p, Map<String, dynamic> c, Layer? music) {
    final comp = p.main;
    final down = c['downbeats'] == true;
    if (c['beats'] is List) {
      return [for (final v in c['beats'] as List) if (v is num) v.toDouble()]..sort();
    }
    final bpm = _num(c, 'bpm');
    if (bpm != null) {
      if (bpm < 30 || bpm > 300) throw CommandError('bpm must be between 30 and 300');
      final offset = _num(c, 'offset') ?? music?.start ?? 0;
      final g = MusicAnalysis.grid(bpm, offset: offset, duration: comp.duration);
      return down ? g.downbeats : g.beats;
    }
    // Analysed music: the chosen layer plus its loops (same media).
    final candidates = music != null
        ? [for (final l in comp.layers) if (l.type == LayerType.audio && l.mediaId == music.mediaId) l]
        : _musicLayers(p);
    MusicAnalysis? of(Layer l) {
      final m = l.mediaId == null ? null : p.media[l.mediaId];
      return m == null ? null : AudioCache.musicFor(m);
    }

    return BeatSync.timelineBeats(candidates, of, downbeats: down);
  }

  // ------------------------------------------------------------- auto_mix

  static List<Map<String, dynamic>> _autoMix(Project p, Map<String, dynamic> c) {
    final comp = p.main;
    final roles = <String, String>{};
    if (c['roles'] is Map) {
      (c['roles'] as Map).forEach((k, v) {
        if (comp.layerById('$k') == null) throw CommandError('auto_mix roles: no layer "$k"');
        if (!AutoMix.roles.contains('$v')) throw CommandError('auto_mix role must be ${AutoMix.roles.join(', ')}');
        roles['$k'] = '$v';
      });
    }
    final t = c['targets'] is Map ? Map<String, dynamic>.from(c['targets'] as Map) : const <String, dynamic>{};
    double tv(String k, double d) => (t[k] as num?)?.toDouble() ?? d;
    const def = MixTargets();
    final targets = MixTargets(
      voice: tv('voice', def.voice),
      music: tv('music', def.music),
      sfx: tv('sfx', def.sfx),
      ambience: tv('ambience', def.ambience),
      musicDuck: tv('music_duck', def.musicDuck),
      ambienceDuck: tv('ambience_duck', def.ambienceDuck),
    );
    final loudness = <String, double>{};
    for (final m in p.media.values) {
      final v = AudioCache.lufsFor(m);
      if (v != null) loudness[m.id] = v;
    }
    List<(double, double)>? speech;
    if (c['speech'] is List) {
      speech = [
        for (final s in c['speech'] as List)
          if (s is List && s.length >= 2 && s[0] is num && s[1] is num) ((s[0] as num).toDouble(), (s[1] as num).toDouble()),
      ];
    } else {
      // Measured voice activity of the voice tracks, when known.
      final found = <(double, double)>[];
      var any = false;
      for (final l in comp.layers) {
        if (l.type != LayerType.audio && l.type != LayerType.video) continue;
        if ((roles[l.id] ?? AutoMix.roleOf(p, l)) != 'voice') continue;
        final m = l.mediaId == null ? null : p.media[l.mediaId];
        final sp = m == null ? null : AudioCache.speechFor(m);
        if (sp == null) continue;
        any = true;
        found.addAll(AutoMix.toComp(sp, l));
      }
      if (any) speech = found;
    }
    return AutoMix.plan(p,
        roles: roles, loudness: loudness, speech: speech, duck: c['duck'] != false, fades: c['fades'] != false, targets: targets);
  }

  static double? _num(Map<String, dynamic> c, String k) {
    final v = c[k];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    throw CommandError('"$k" must be a number');
  }
}
