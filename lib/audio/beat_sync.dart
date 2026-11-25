import 'dart:math' as math;

import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../director/sfx.dart';
import '../director/story_builder.dart';
import 'music_analysis.dart';

/// Beat-sync tools. Pure functions: they read the project and return edit
/// commands (run them with EditCommands.runAtomic / controller.run), so the
/// whole sync is one undo step.
class BeatSync {
  /// Nearest beat to [t] within [tolerance] seconds, or null.
  static double? nearest(List<double> beats, double t, double tolerance) {
    if (beats.isEmpty) return null;
    var lo = 0, hi = beats.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (beats[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    double? best;
    for (final i in [lo - 1, lo]) {
      if (i < 0 || i >= beats.length) continue;
      final d = (beats[i] - t).abs();
      if (d <= tolerance + 1e-9 && (best == null || d < (best - t).abs())) best = beats[i];
    }
    return best;
  }

  /// Beat times of [a] (seconds into the music file) on the composition
  /// timeline of the music [layer] (only those it actually plays).
  static List<double> toComp(List<double> sourceTimes, Layer layer) {
    final out = <double>[];
    for (final s in sourceTimes) {
      final t = layer.start + (s - layer.sourceIn) / layer.speed;
      if (t >= layer.start - 1e-6 && t <= layer.end + 1e-6) out.add(t);
    }
    return out;
  }

  /// Beats of every analysed piece of a (possibly looped) music track on the
  /// timeline: [layers] are the music layers, [analysisOf] their analysis.
  static List<double> timelineBeats(Iterable<Layer> layers, MusicAnalysis? Function(Layer) analysisOf, {bool downbeats = false}) {
    final out = <double>[];
    for (final l in layers) {
      final a = analysisOf(l);
      if (a != null) out.addAll(toComp(downbeats ? a.downbeats : a.beats, l));
    }
    out.sort();
    return out;
  }

  /// Visual "shots": top-level layers that are not audio, not the A-roll
  /// (long video with sound) and not full-length backgrounds.
  static List<Layer> shots(Composition comp, {Iterable<String>? only}) {
    final ids = only?.toSet();
    return [
      for (final l in comp.layers)
        if (l.type != LayerType.audio &&
            (l.parentId == null || comp.layerById(l.parentId!) == null) &&
            (ids == null || ids.contains(l.id)) &&
            !(ids == null && l.type == LayerType.video && l.duration >= comp.duration * 0.5) &&
            !(ids == null && l.start <= 0.05 && l.end >= comp.duration - 0.05))
          l,
    ];
  }

  /// Cut times (shot starts and ends) of the composition.
  static List<double> cutTimes(Composition comp, {Iterable<String>? only}) {
    final ts = <double>[];
    for (final l in shots(comp, only: only)) {
      if (l.start > 0.05) ts.add(l.start);
      if (l.end < comp.duration - 0.05) ts.add(l.end);
    }
    ts.sort();
    final out = <double>[];
    for (final t in ts) {
      if (out.isEmpty || t - out.last > 1 / comp.fps) out.add(t);
    }
    return out;
  }

  /// Moves every cut (where shots start/end) onto the nearest beat within
  /// [tolerance]. A shot's start and end move independently (its keyframes
  /// move with its start, children of component groups move with their
  /// group), and generated SFX sitting on a cut move with it.
  static List<Map<String, dynamic>> snapCuts(Project p, List<double> beats,
      {double tolerance = 0.25, Iterable<String>? layers, double minShot = 0.3}) {
    final comp = p.main;
    final sorted = [...beats]..sort();
    final frame = 1 / comp.fps;
    final cuts = cutTimes(comp, only: layers);
    // Cut → new time, keeping cuts in order and shots long enough.
    final moved = <double, double>{};
    var prevNew = -1e9;
    for (final t in cuts) {
      final b = nearest(sorted, t, tolerance);
      var nt = b ?? t;
      if (nt - prevNew < minShot) nt = t;
      if ((nt - t).abs() > 1e-4) moved[t] = nt;
      prevNew = nt;
    }
    if (moved.isEmpty) return const [];
    double map(double t) {
      for (final e in moved.entries) {
        if ((e.key - t).abs() <= frame * 0.75) return e.value;
      }
      return t;
    }

    final cmds = <Map<String, dynamic>>[];
    for (final l in shots(comp, only: layers)) {
      final ns = l.start > 0.05 ? map(l.start) : l.start;
      final ne = l.end < comp.duration - 0.05 ? map(l.end) : l.end;
      if ((ns - l.start).abs() < 1e-6 && (ne - l.end).abs() < 1e-6) continue;
      if (ne - ns < minShot) continue;
      cmds.addAll(_retime(comp, l, ns, ne));
    }
    // Sound effects placed on a cut (start + peak == cut) follow it.
    for (final l in comp.layers) {
      if (l.type != LayerType.audio) continue;
      final kind = _sfxKind(p, l);
      if (kind == null) continue;
      final hit = l.start + Sfx.peak(kind);
      for (final e in moved.entries) {
        if ((e.key - hit).abs() <= frame * 1.5) {
          cmds.add({'op': 'update_layer', 'layer': l.id, 'start': _r(math.max(0.0, l.start + e.value - e.key))});
          break;
        }
      }
    }
    return cmds;
  }

  /// Moves layers (text pops, cards, component groups — default every
  /// top-level text layer) so they start on the nearest beat (or downbeat).
  static List<Map<String, dynamic>> popsOnBeats(Project p, List<double> beats, {Iterable<String>? layers, double tolerance = 0.35}) {
    final comp = p.main;
    final sorted = [...beats]..sort();
    final ids = layers?.toSet();
    final cmds = <Map<String, dynamic>>[];
    for (final l in comp.layers) {
      final top = l.parentId == null || comp.layerById(l.parentId!) == null;
      final pick = ids == null ? (top && l.type == LayerType.text) : ids.contains(l.id);
      if (!pick) continue;
      final b = nearest(sorted, l.start, tolerance);
      if (b == null || (b - l.start).abs() < 1e-4) continue;
      cmds.addAll(_retime(comp, l, b, l.end + (b - l.start)));
    }
    return cmds;
  }

  /// "Hit on the drop": re-cues the music [layer] so the drop at [dropSource]
  /// (seconds into the file) lands exactly at composition time [at]. With
  /// [preroll] 0 the music starts right on the drop (silence → slam, as in
  /// title_slam); otherwise that many seconds of build-up play before it,
  /// fading in over [fadeIn].
  static List<Map<String, dynamic>> hitOnDrop(Project p, String layer, double dropSource,
      {required double at, double preroll = 0, double fadeIn = 0, double? level}) {
    final comp = p.main;
    final l = comp.layerById(layer);
    if (l == null) throw ArgumentError('No layer "$layer"');
    final media = l.mediaId == null ? null : p.media[l.mediaId];
    final mediaLen = media != null && media.duration > 0 ? media.duration : double.infinity;
    var start = math.max(0.0, at - math.max(0.0, preroll) / l.speed);
    var sourceIn = dropSource - (at - start) * l.speed;
    if (sourceIn < 0) {
      start += -sourceIn / l.speed;
      sourceIn = 0;
    }
    final keepEnd = math.max(l.end, comp.duration);
    var dur = math.min(keepEnd - start, (mediaLen - sourceIn) / l.speed);
    dur = math.max(comp.frameDuration, dur);
    final vol = level ?? l.prop(Props.volume).scalarAt(l.start + l.duration / 2);
    final cmds = <Map<String, dynamic>>[
      {'op': 'update_layer', 'layer': l.id, 'start': _r(start), 'duration': _r(dur), 'source_in': _r(sourceIn)},
    ];
    final fade = math.min(fadeIn, at - start);
    if (fade > 0.05) {
      cmds.addAll([
        {'op': 'clear_keyframes', 'target': l.id, 'prop': 'volume'},
        {'op': 'set_keyframe', 'target': l.id, 'prop': 'volume', 'time': _r(start), 'value': 0.0, 'ease': 'ease_in'},
        {'op': 'set_keyframe', 'target': l.id, 'prop': 'volume', 'time': _r(start + fade), 'value': _r(vol), 'ease': 'linear'},
      ]);
    }
    return cmds;
  }

  /// Snaps storyboard beats (Director) to music beats before building:
  /// every boundary between consecutive story beats moves to the nearest
  /// music beat within [tolerance]. Changes [story] in place.
  static void snapStoryboard(List<Beat> story, List<double> beats, {double tolerance = 0.3, double minLength = 0.8}) {
    final sorted = [...beats]..sort();
    final kept = story.where((b) => b.keep).toList()..sort((a, b) => a.start.compareTo(b.start));
    for (int i = 1; i < kept.length; i++) {
      final a = kept[i - 1], b = kept[i];
      final cut = b.start;
      final nb = nearest(sorted, cut, tolerance);
      if (nb == null) continue;
      if (nb - a.start < minLength || b.end - nb < minLength) continue;
      if ((a.end - cut).abs() < 0.05) a.end = nb;
      b.start = nb;
    }
  }

  // ------------------------------------------------------------- helpers

  /// Commands moving [l] to start at [ns] and end at [ne]; its descendants
  /// move with the start (and are cut to the new end).
  static List<Map<String, dynamic>> _retime(Composition comp, Layer l, double ns, double ne) {
    final ds = ns - l.start;
    final cmds = <Map<String, dynamic>>[
      {'op': 'update_layer', 'layer': l.id, 'start': _r(ns), 'duration': _r(ne - ns)},
    ];
    for (final c in _descendants(comp, l.id)) {
      final cs = c.start + ds;
      var ce = c.end + ds;
      if ((c.end - l.end).abs() < 1e-3 || ce > ne) ce = ne;
      if (ce - cs < comp.frameDuration) continue;
      cmds.add({'op': 'update_layer', 'layer': c.id, 'start': _r(cs), 'duration': _r(ce - cs)});
    }
    return cmds;
  }

  static List<Layer> _descendants(Composition comp, String id) {
    final out = <Layer>[];
    final todo = [id];
    final seen = <String>{id};
    while (todo.isNotEmpty) {
      final cur = todo.removeLast();
      for (final l in comp.layers) {
        if (l.parentId == cur && seen.add(l.id)) {
          out.add(l);
          todo.add(l.id);
        }
      }
    }
    return out;
  }

  static String? _sfxKind(Project p, Layer l) {
    final m = l.mediaId == null ? null : p.media[l.mediaId];
    final name = (m?.name ?? l.name).trim();
    if (!name.startsWith('SFX ')) return null;
    final k = name.substring(4).trim();
    return Sfx.all.contains(k) ? k : null;
  }

  static double _r(double v) => (v * 10000).roundToDouble() / 10000;
}
