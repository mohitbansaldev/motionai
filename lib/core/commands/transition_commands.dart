import 'dart:convert';
import 'dart:math' as math;

import '../../audio/audio_cache.dart';
import '../../audio/auto_mix.dart';
import '../../audio/beat_sync.dart';
import '../../audio/sfx_library.dart';
import '../../director/sfx.dart';
import '../model/layer.dart';
import '../model/project.dart';
import '../presets/doc_transitions.dart';
import 'edit_commands.dart';

/// V2-C: the `transition` op (documentary transitions between two shots).
///
///   transition {from, to (or layers: [from, to]), type, duration?, at? (cut, default to.start),
///               sound?: true|false|"sfx_kind"|[kinds], snap_to_beat?: false, beats?: [s],
///               beat_tolerance?: 0.25, params?: {...}}
///   list_transitions {} — the catalog as JSON in the log.
///
/// Visuals come from [DocTransitions]; this adds beat snapping and sound.
/// Runs inside the dispatcher, so it is atomic and one undo step.
class TransitionCommands {
  static const ops = ['transition', 'list_transitions'];

  static const _reserved = {
    'op', 'from', 'to', 'layers', 'type', 'duration', 'at', 'sound', 'snap_to_beat', 'beats', 'beat_tolerance', 'params', 'in_comp',
  };

  static void run(Project p, Map<String, dynamic> c, double now, CommandResult r, void Function(Map<String, dynamic>) exec) {
    if (c['op'] == 'list_transitions') {
      r.log.add(jsonEncode(DocTransitions.catalogJson()));
      return;
    }
    final comp = p.editComp;
    String? fromId = c['from'] is String ? c['from'] as String : null;
    String? toId = c['to'] is String ? c['to'] as String : null;
    final ls = c['layers'];
    if (ls is List && ls.length >= 2) {
      fromId ??= '${ls[0]}';
      toId ??= '${ls[1]}';
    }
    // V3-D >>> ink_bleed {incoming: "duotone_of_outgoing"} without "to": the outgoing is split at the cut
    final inc = c['incoming'] ?? (c['params'] is Map ? (c['params'] as Map)['incoming'] : null);
    if (toId == null && fromId != null && inc == 'duotone_of_outgoing') {
      final src = comp.layerById(fromId);
      if (src != null) {
        final at = c['at'] is num ? (c['at'] as num).toDouble() : src.start + src.duration / 2;
        toId = '${fromId}_duo';
        exec({'op': 'split_layer', 'layer': fromId, 'time': at, 'new_id': toId});
      }
    }
    // <<< V3-D
    if (fromId == null || toId == null) throw CommandError('transition needs "from" (outgoing layer id) and "to" (incoming layer id)');
    Layer find(String id) {
      final l = comp.layerById(id);
      if (l == null) throw CommandError('No layer "$id". Layers: ${comp.layers.map((l) => '${l.id} (${l.name})').join(', ')}');
      return l;
    }

    final a = find(fromId), b = find(toId);
    final type = '${c['type'] ?? ''}';
    final def = DocTransitions.byId(type);
    if (def == null) throw CommandError('Unknown transition type "$type". Types: ${DocTransitions.types.join(', ')}');

    final params = <String, dynamic>{};
    c.forEach((k, v) {
      if (!_reserved.contains(k)) params[k] = v;
    });
    if (c['params'] is Map) params.addAll(Map<String, dynamic>.from(c['params'] as Map));
    if (c['duration'] != null) params['duration'] = _num(c, 'duration');

    // Cut time, optionally snapped to the music.
    var cut = c['at'] != null ? _num(c, 'at') : b.start;
    if (c['snap_to_beat'] == true) {
      final beats = _beats(p, comp, c);
      final tol = c['beat_tolerance'] != null ? _num(c, 'beat_tolerance') : 0.25;
      if (beats.isEmpty) {
        r.log.add('snap_to_beat: no analysed music (analyse it in the Sound sheet or pass "beats") — cut kept at ${cut.toStringAsFixed(2)} s');
      } else {
        final nb = BeatSync.nearest(beats, cut, tol);
        if (nb != null && (nb - cut).abs() > 1e-6) {
          r.log.add('Cut moved to the beat at ${nb.toStringAsFixed(3)} s');
          cut = nb;
        }
      }
    }
    params['at'] = cut;

    final TransitionResult res;
    try {
      res = DocTransitions.run(comp, a, b, type, params, project: p);
    } on ArgumentError catch (e) {
      throw CommandError('transition $type: ${e.message}');
    }
    r.createdIds.addAll(res.created);
    r.log.addAll(res.log);
    r.log.add('${def.label}: ${a.name} → ${b.name}, cut at ${res.cut.toStringAsFixed(2)} s (${res.start.toStringAsFixed(2)}–${res.end.toStringAsFixed(2)} s)');

    for (final kind in _sounds(c['sound'], def)) {
      _addSound(p, comp, b, kind, res, exec, r);
    }
  }

  static List<String> _sounds(dynamic s, TransitionDef def) {
    if (s == null || s == true) return def.sounds;
    if (s == false) return const [];
    final list = s is List ? [for (final e in s) '$e'] : ['$s'];
    for (final k in list) {
      if (!Sfx.all.contains(k)) throw CommandError('transition sound "$k" is not a sound. Sounds: ${Sfx.all.join(', ')}');
    }
    return list;
  }

  /// One generated SFX on the timeline of [comp], its peak on the cut (beds
  /// fill the transition window with short fades instead).
  static void _addSound(Project p, Composition comp, Layer incoming, String kind, TransitionResult res,
      void Function(Map<String, dynamic>) exec, CommandResult r) {
    final MediaAsset asset;
    try {
      asset = SfxLibrary.ensureSync(p, kind);
    } on ArgumentError catch (e) {
      throw CommandError('${e.message}');
    } catch (e) {
      throw CommandError('Could not write the sound file: $e');
    }
    final id = 'tr_${incoming.id}_sfx_$kind';
    final vol = AutoMix.volumeFor(SfxLibrary.lufs(kind), Sfx.isBed(kind) ? const MixTargets().ambience + 6 : const MixTargets().sfx);
    if (Sfx.isBed(kind)) {
      final start = math.max(0.0, res.start - 0.1);
      final len = math.min(asset.duration, res.end + 0.3 - start);
      exec({'op': 'add_layer', 'type': 'audio', 'media': asset.id, 'id': id, 'name': SfxLibrary.nameFor(kind), 'start': start, 'duration': len, 'index': 1 << 20});
      exec({'op': 'set_keyframe', 'target': id, 'prop': 'volume', 'time': start, 'value': 0, 'ease': 'ease_out'});
      exec({'op': 'set_keyframe', 'target': id, 'prop': 'volume', 'time': start + len * 0.3, 'value': vol, 'ease': 'ease_in'});
      exec({'op': 'set_keyframe', 'target': id, 'prop': 'volume', 'time': start + len, 'value': 0, 'ease': 'ease_in'});
    } else {
      final pk = Sfx.peak(kind);
      final start = math.max(0.0, res.cut - pk);
      final skip = math.max(0.0, pk - res.cut);
      final len = asset.duration - skip;
      if (len <= 0.01) return;
      exec({
        'op': 'add_layer', 'type': 'audio', 'media': asset.id, 'id': id, 'name': SfxLibrary.nameFor(kind),
        'start': start, 'duration': len, if (skip > 0) 'source_in': skip, 'index': 1 << 20,
      });
      exec({'op': 'set_property', 'target': id, 'prop': 'volume', 'value': vol});
    }
    r.createdIds.add(id);
  }

  /// Beats on the timeline: "beats" in the command, else the analysed music layers.
  static List<double> _beats(Project p, Composition comp, Map<String, dynamic> c) {
    if (c['beats'] is List) {
      return [for (final v in c['beats'] as List) if (v is num) v.toDouble()]..sort();
    }
    final music = [
      for (final l in comp.layers)
        if (l.type == LayerType.audio && AutoMix.roleOf(p, l) == 'music') l,
    ];
    return BeatSync.timelineBeats(music, (l) {
      final m = l.mediaId == null ? null : p.media[l.mediaId];
      return m == null ? null : AudioCache.musicFor(m);
    });
  }

  static double _num(Map<String, dynamic> c, String k) {
    final v = c[k];
    if (v is num) return v.toDouble();
    throw CommandError('"$k" must be a number');
  }
}
