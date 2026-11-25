// V2-A (Bridge): check_scene — a pure-Dart lint of a composition over a
// time range. Every problem names its layer(s) and time and carries a
// "fix": edit commands for run_commands. Uses the evaluator for projected
// (3D) positions, so it is exact for transforms and needs no rendering.

import 'dart:io';
import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../core/engine/evaluator.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../core/presets/scene3d.dart';

class SceneIssue {
  /// black_gap | ends_early | starts_late | empty_edges | floating |
  /// text_overlap | text_off_frame | text_unsafe | broken_effect | missing_media |
  /// flat_parallax | flat_set (win-30)
  final String kind;
  final String severity; // error | warning | info
  final List<String> layers;
  final double? time;
  final double? until;
  final String message;
  final List<Map<String, dynamic>> fix;
  final String? hint;

  SceneIssue(this.kind, this.severity, this.message,
      {this.layers = const [], this.time, this.until, this.fix = const [], this.hint});

  static double _r(double v) => (v * 100).roundToDouble() / 100;

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'severity': severity,
        if (layers.length == 1) 'layer': layers.first,
        if (layers.length > 1) 'layers': layers,
        if (time != null) 'time': _r(time!),
        if (until != null) 'until': _r(until!),
        'message': message,
        if (fix.isNotEmpty) 'fix': fix,
        if (hint != null) 'hint': hint,
      };
}

/// Known rendering bugs to warn about until they are fixed elsewhere.
class KnownBroken {
  /// Blur on a 3D layer makes it invisible (V2 plan bug 1).
  static bool blurOn3D = true;

  /// `scramble` breaks Devanagari conjuncts (V2 plan bug 2).
  static bool scrambleDevanagari = true;
}

class SceneCheck {
  /// Frame edges and safe margin (fraction of each side).
  static const double safeMargin = 0.05;

  static const _ops = {'image', 'video', 'solid'};

  static bool _visual(Layer l) => l.visible && l.type != LayerType.audio && l.type != LayerType.nullObject;
  static String _fmt(double t) => t.toStringAsFixed(2);
  static double _r3(double v) => (v * 1000).roundToDouble() / 1000;
  static List<double> _rl(List<double> v) => [for (final x in v) (x * 100).roundToDouble() / 100];

  /// Image layers that are probably cut-outs (transparent PNG/WebP), not backgrounds.
  static bool isCutOut(Project p, Layer l) {
    if (l.type != LayerType.image) return false;
    if (RegExp(r'\b(sky|background|backdrop|bg)\b').hasMatch(l.name.toLowerCase())) return false;
    final a = p.media[l.mediaId];
    if (a == null) return false;
    final path = a.path.toLowerCase();
    final name = '${a.name} ${l.name}'.toLowerCase();
    return path.endsWith('.png') || path.endsWith('.webp') || path.endsWith('.gif') || RegExp(r'cut[ _-]?out').hasMatch(name);
  }

  /// Runs every check. [playhead] enables the "started at the playhead"
  /// check; [fileExists] defaults to the real file system.
  static List<SceneIssue> run(Project p, Composition comp,
      {double? from, double? to, double? playhead, bool Function(String path)? fileExists, int samples = 10}) {
    final dur = comp.duration;
    final fd = comp.frameDuration;
    final f0 = (from ?? 0).clamp(0.0, dur).toDouble();
    var f1 = (to ?? dur).clamp(f0, dur).toDouble();
    if (f1 - f0 < fd) f1 = math.min(dur, f0 + fd);
    final n = samples.clamp(2, 40);
    final last = math.max(f0, f1 - fd * 0.5);
    final times = [for (var i = 0; i < n; i++) f0 + (last - f0) * i / (n - 1)];
    final evals = <double, List<RenderItem>>{for (final t in times) t: Evaluator.evaluate(comp, t, velocity: false)};
    List<RenderItem> at(double t) => evals[t] ??= Evaluator.evaluate(comp, t, velocity: false);

    final out = <SceneIssue>[];
    final fixed = <String>{};
    _gaps(comp, f0, f1, out, fixed);
    _endsEarly(comp, f0, f1, out, fixed);
    if (playhead != null) _startsLate(comp, f0, f1, playhead, out);
    _edges(p, comp, times, at, out);
    _floating(p, comp, times, at, out);
    _parallax(p, comp, times, at, out); // win-30
    _text(comp, f0, f1, times, at, out);
    _effects(comp, out);
    _media(p, comp, fileExists ?? (path) => File(path).existsSync(), out);
    const rank = {'error': 0, 'warning': 1, 'info': 2};
    out.sort((a, b) {
      final r = rank[a.severity]!.compareTo(rank[b.severity]!);
      return r != 0 ? r : (a.time ?? -1).compareTo(b.time ?? -1);
    });
    return out;
  }

  /// Every fix of [issues] once, in order (for run_commands).
  static List<Map<String, dynamic>> fixAll(List<SceneIssue> issues) {
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final i in issues) {
      for (final c in i.fix) {
        if (seen.add(c.toString())) out.add(c);
      }
    }
    return out;
  }

  // ------------------------------------------------------------ props

  /// Commands that set [prop] of [l] to f(value) everywhere (static value or every keyframe).
  static List<Map<String, dynamic>> mapProp(Layer l, String prop, List<double> Function(List<double> v) f) {
    final p = l.prop(prop);
    if (!p.isAnimated) return [{'op': 'set_property', 'target': l.id, 'prop': prop, 'value': _rl(f(List.of(p.staticValue)))}];
    return [
      for (final k in p.keyframes) {'op': 'set_keyframe', 'target': l.id, 'prop': prop, 'time': k.time, 'value': _rl(f(List.of(k.value)))},
    ];
  }

  static List<Map<String, dynamic>> _shift(Layer l, double dx, double dy) =>
      mapProp(l, Props.position, (v) => [v[0] + dx, v[1] + dy, if (v.length > 2) v[2]]);

  /// Screen px → layer position units (3D layers move less on screen the farther they are).
  static double _toWorld(Composition comp, RenderItem it, double t) {
    if (!it.layer.is3D) return 1;
    final z = Evaluator.camera3D(comp, t).zoom;
    return it.depth > 1 ? it.depth / z : 1;
  }

  // ------------------------------------------------------------ (a) timing

  static List<(double, double)> _active(Composition comp, double f0, double f1) {
    final mattes = {for (final l in comp.layers) if (l.matte != null) l.matte!.layerId};
    final iv = <(double, double)>[
      for (final l in comp.layers)
        if (_visual(l) && !mattes.contains(l.id) && l.end > f0 && l.start < f1) (math.max(f0, l.start), math.min(f1, l.end)),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(double, double)>[];
    for (final i in iv) {
      if (merged.isNotEmpty && i.$1 <= merged.last.$2 + 1e-6) {
        merged[merged.length - 1] = (merged.last.$1, math.max(merged.last.$2, i.$2));
      } else {
        merged.add(i);
      }
    }
    return merged;
  }

  static void _gaps(Composition comp, double f0, double f1, List<SceneIssue> out, Set<String> fixed) {
    final fd = comp.frameDuration;
    final act = _active(comp, f0, f1);
    final gaps = <(double, double)>[];
    var cur = f0;
    for (final (a, b) in act) {
      if (a - cur >= fd * 0.9) gaps.add((cur, a));
      cur = math.max(cur, b);
    }
    if (f1 - cur >= fd * 0.9) gaps.add((cur, f1));
    for (final (g0, g1) in gaps) {
      final enders = [
        for (final l in comp.layers)
          if (_visual(l) && l.type != LayerType.text && (l.end - g0).abs() <= fd * 0.6) l,
      ];
      final starters = [
        for (final l in comp.layers)
          if (_visual(l) && l.type != LayerType.text && (l.start - g1).abs() <= fd * 0.6 && l.type != LayerType.video) l,
      ];
      final fix = <Map<String, dynamic>>[];
      String? hint;
      if (enders.isNotEmpty) {
        for (final l in enders) {
          fix.add({'op': 'trim_layer', 'layer': l.id, 'out': _r3(g1)});
          fixed.add(l.id);
        }
        if (g1 >= comp.duration - fd * 0.6) hint = 'Or end the composition there: {"op":"set_comp","duration":${_r3(g0)}}.';
      } else if (starters.isNotEmpty) {
        for (final l in starters) {
          fix.add({'op': 'trim_layer', 'layer': l.id, 'in': _r3(g0)});
        }
      } else if (g1 >= comp.duration - fd * 0.6 && g0 > 0) {
        fix.add({'op': 'set_comp', 'duration': _r3(g0)});
      }
      final ids = [for (final l in enders.isNotEmpty ? enders : starters) l.id];
      out.add(SceneIssue('black_gap', 'error',
          'Nothing is visible from ${_fmt(g0)} to ${_fmt(g1)} s (empty/black frames)'
          '${enders.isNotEmpty ? ': ${ids.join(', ')} end at ${_fmt(g0)} s' : ''}.',
          layers: ids, time: g0, until: g1, fix: fix, hint: hint));
    }
  }

  /// Same "set": both 3D, built together (same start) or the same parent.
  static bool _siblings(Layer a, Layer b, double fd) =>
      (a.is3D && b.is3D) || (a.start - b.start).abs() <= fd * 1.5 || (a.parentId != null && a.parentId == b.parentId);

  static bool _overlap(Layer a, Layer b, double fd) => a.start < b.end - fd * 0.5 && a.end > b.start + fd * 0.5;

  static void _endsEarly(Composition comp, double f0, double f1, List<SceneIssue> out, Set<String> fixed) {
    final fd = comp.frameDuration;
    final eps = fd * 0.6;
    final vis = [for (final l in comp.layers) if (_visual(l) && l.type != LayerType.text) l];
    for (final l in vis) {
      if (!_ops.contains(l.type.name) && l.type != LayerType.comp) continue;
      if (fixed.contains(l.id) || l.end <= f0 + eps || l.end >= f1 - eps) continue;
      if (l.prop(Props.opacity).scalarAt(l.end - fd) <= 5) continue; // faded out on purpose
      final sibs = [for (final s in vis) if (s.id != l.id && _overlap(s, l, fd) && _siblings(s, l, fd)) s];
      final later = [for (final s in sibs) if (s.end > l.end + math.max(fd, 0.1)) s];
      if (later.isEmpty) continue;
      // A cut: a new layer that is not part of the set starts right there.
      final cut = vis.any((s) => s.id != l.id && (s.start - l.end).abs() <= eps && !sibs.contains(s));
      if (cut) continue;
      final until = math.min(f1, later.map((s) => s.end).reduce(math.max));
      out.add(SceneIssue('ends_early', 'warning',
          '${l.name} (${l.id}) ends at ${_fmt(l.end)} s while ${later.first.id}${later.length > 1 ? ' and ${later.length - 1} more' : ''} '
          'of its set continue to ${_fmt(until)} s: it vanishes mid-shot (layers default to a short duration).',
          layers: [l.id], time: l.end, until: until, fix: [{'op': 'trim_layer', 'layer': l.id, 'out': _r3(until)}]));
    }
  }

  static void _startsLate(Composition comp, double f0, double f1, double playhead, List<SceneIssue> out) {
    final fd = comp.frameDuration;
    if (playhead <= f0 + fd * 0.6) return;
    final vis = [for (final l in comp.layers) if (_visual(l) && l.type != LayerType.text) l];
    for (final l in vis) {
      if (l.start <= f0 + fd * 0.6 || l.start >= f1 || (l.start - playhead).abs() > fd * 1.5) continue;
      final early = [
        for (final s in vis)
          if (s.id != l.id && s.start <= f0 + fd * 0.6 && s.end > l.start + fd && (s.is3D == l.is3D || s.parentId == l.parentId)) s,
      ];
      if (early.isEmpty) continue;
      final setStart = early.map((s) => s.start).reduce(math.min).clamp(f0, f1).toDouble();
      out.add(SceneIssue('starts_late', 'warning',
          '${l.name} (${l.id}) starts at ${_fmt(l.start)} s, the playhead, while its set starts at ${_fmt(setStart)} s '
          '(layers added without "start" begin at the playhead).',
          layers: [l.id], time: l.start, fix: [
            {'op': 'update_layer', 'layer': l.id, 'start': _r3(setStart)},
            {'op': 'trim_layer', 'layer': l.id, 'out': _r3(l.end)},
          ]));
    }
  }

  // ------------------------------------------------------------ (b) empty edges

  static bool _covers(Project p, RenderItem it) {
    final l = it.layer;
    if (it.opacity < 0.98 || it.matte != null || l.masks.isNotEmpty || l.blendMode != 'normal') return false;
    if (l.effects.any((e) => e.enabled && e.type.contains('chroma'))) return false;
    if (l.type == LayerType.image) return !isCutOut(p, l);
    return l.type == LayerType.video || l.type == LayerType.solid;
  }

  static List<Vector2> _grid(Composition comp) {
    const cols = 12, rows = 7;
    final w = comp.width, h = comp.height;
    return [
      for (var j = 0; j < rows; j++)
        for (var i = 0; i < cols; i++) Vector2(1 + (w - 2) * i / (cols - 1), 1 + (h - 2) * j / (rows - 1)),
    ];
  }

  static bool _border(Vector2 v, Composition comp) => v.x < 2 || v.y < 2 || v.x > comp.width - 2 || v.y > comp.height - 2;

  /// Quad of [it]'s layer scaled by [s] about its anchor at [t].
  static List<Vector2> _scaledQuad(RenderItem it, double t, double s) {
    final l = it.layer;
    final a = l.prop(Props.anchor).valueAt(t);
    Vector2 c(double x, double y) => it.project(a[0] + (x - a[0]) * s, a[1] + (y - a[1]) * s);
    return [c(0, 0), c(l.width, 0), c(l.width, l.height), c(0, l.height)];
  }

  static void _edges(Project p, Composition comp, List<double> times, List<RenderItem> Function(double) at, List<SceneIssue> out) {
    final grid = _grid(comp);
    var maxFrac = 0.0;
    double? worstT;
    var worstFrac = 2.0;
    var worstSides = <String>{};
    for (final t in times) {
      final cover = [for (final it in at(t)) if (_covers(p, it)) it.corners()];
      var hit = 0;
      final sides = <String>{};
      for (final g in grid) {
        if (cover.any((q) => pointInQuad(g, q))) {
          hit++;
        } else if (_border(g, comp)) {
          if (g.x < 2) sides.add('left');
          if (g.x > comp.width - 2) sides.add('right');
          if (g.y < 2) sides.add('top');
          if (g.y > comp.height - 2) sides.add('bottom');
        }
      }
      final frac = hit / grid.length;
      maxFrac = math.max(maxFrac, frac);
      if (sides.isNotEmpty && frac < worstFrac) {
        worstFrac = frac;
        worstT = t;
        worstSides = sides;
      }
    }
    if (worstT == null || maxFrac < 0.9 || worstFrac < 0.05) return; // never filled (a design), or a black gap
    // The background: the covering layer that covers most of the frame then.
    RenderItem? bg;
    var best = -1;
    for (final it in at(worstT)) {
      if (!_covers(p, it)) continue;
      final q = it.corners();
      final k = grid.where((g) => pointInQuad(g, q)).length;
      if (k > best) {
        best = k;
        bg = it;
      }
    }
    final where = worstSides.join('/');
    if (bg == null) {
      out.add(SceneIssue('empty_edges', 'warning', 'Empty canvas at the $where edge at ${_fmt(worstT)} s: no background layer covers it.',
          time: worstT));
      return;
    }
    // Scale needed so the background covers the frame corners at every sample.
    final l = bg.layer;
    final corners = [Vector2(1, 1), Vector2(comp.width - 1, 1), Vector2(comp.width - 1, comp.height - 1), Vector2(1, comp.height - 1)];
    var need = 1.0;
    for (final t in times) {
      final it = at(t).where((x) => x.layer.id == l.id).firstOrNull;
      if (it == null) continue;
      bool ok(double s) => corners.every((c) => pointInQuad(c, _scaledQuad(it, t, s)));
      if (ok(1)) continue;
      if (!ok(4)) {
        need = 4;
        break;
      }
      var lo = 1.0, hi = 4.0;
      for (var i = 0; i < 20; i++) {
        final m = (lo + hi) / 2;
        if (ok(m)) {
          hi = m;
        } else {
          lo = m;
        }
      }
      need = math.max(need, hi);
    }
    final s = _r3(math.min(need * 1.02, 4.0));
    out.add(SceneIssue('empty_edges', 'warning',
        'Empty canvas at the $where edge at ${_fmt(worstT)} s: ${l.name} (${l.id}) does not cover the frame during the move.',
        layers: [l.id],
        time: worstT,
        fix: need > 1.001 ? mapProp(l, Props.scale, (v) => [v[0] * s, v[1] * s, if (v.length > 2) v[2]]) : const [],
        hint: need >= 4 ? 'It needs more than 4× scale: shorten or soften the camera move instead.' : 'Scales it ×$s about its anchor.'));
  }

  // ------------------------------------------------------------ (c) floating

  static void _floating(Project p, Composition comp, List<double> times, List<RenderItem> Function(double) at, List<SceneIssue> out) {
    final h = comp.height, w = comp.width;
    final candidates = [
      for (final l in comp.layers)
        if (_visual(l) && l.is3D && isCutOut(p, l) && const {'near', 'mid'}.contains(Scene3D.bandOf(comp, l, math.max(l.start, times.first)))) l,
    ];
    for (final l in candidates) {
      double? worstT, worstBottom;
      RenderItem? worstItem;
      for (final t in times) {
        final items = at(t);
        final idx = items.indexWhere((x) => x.layer.id == l.id);
        if (idx < 0) continue;
        final it = items[idx];
        final q = it.corners();
        final bottom = q.map((v) => v.y).reduce(math.max);
        final x0 = math.max(0.0, q.map((v) => v.x).reduce(math.min)), x1 = math.min(w, q.map((v) => v.x).reduce(math.max));
        if (bottom >= h * 0.9 || bottom <= 0 || x1 <= x0) continue;
        // Something behind it (not the sky) under its bottom edge = it stands on it.
        final y = math.min(h - 1, bottom + h * 0.04);
        final probes = [for (var k = 1; k <= 5; k++) Vector2(x0 + (x1 - x0) * k / 6, y)];
        final behind = [
          for (final b in items.take(idx))
            if (b.layer.type != LayerType.solid && b.layer.type != LayerType.text && (!b.layer.is3D || Scene3D.bandOf(comp, b.layer, t) != 'sky'))
              b.corners(),
        ];
        final supported = probes.where((pt) => behind.any((qq) => pointInQuad(pt, qq))).length >= 3;
        if (supported) continue;
        if (worstBottom == null || bottom < worstBottom) {
          worstBottom = bottom;
          worstT = t;
          worstItem = it;
        }
      }
      if (worstT == null || worstItem == null || worstBottom == null) continue;
      final wb = worstBottom;
      final dy = (h * 0.96 - wb) * _toWorld(comp, worstItem, worstT);
      out.add(SceneIssue('floating', 'warning',
          'Cut-out ${l.name} (${l.id}) may be floating at ${_fmt(worstT)} s: its bottom edge is at y=${wb.round()} '
          '(${(wb / h * 100).round()}% of the height) with no ground under it.',
          layers: [l.id],
          time: worstT,
          fix: l.parentId == null ? _shift(l, 0, dy) : const [],
          hint: 'Check with preview_shot. Fix moves it down so it stands on the bottom of the frame; or add a ground/foreground layer under it.'));
    }
  }

  // ------------------------------------------------------------ win-30: depth / parallax

  /// Centre of an item on screen.
  static Vector2 _centre(RenderItem it) {
    final q = it.corners();
    var x = 0.0, y = 0.0;
    for (final v in q) {
      x += v.x;
      y += v.y;
    }
    return Vector2(x / q.length, y / q.length);
  }

  /// When the 3D camera moves, layers at different depths must move by
  /// different amounts on screen (parallax). Flags (a) moves where every 3D
  /// layer slides by about the same amount ("everything moves with the
  /// camera") and (b) sets whose background is one flat photo while the
  /// camera trucks sideways (the room never changes perspective).
  static void _parallax(Project p, Composition comp, List<double> times, List<RenderItem> Function(double) at, List<SceneIssue> out) {
    if (times.length < 2) return;
    final w = comp.width, h = comp.height;
    double? flatT0, flatT1, flatSpread, flatMove;
    double? plateT;
    String? plateId;
    for (var k = 0; k + 1 < times.length; k++) {
      final t0 = times[k], t1 = times[k + 1];
      final a = {for (final it in at(t0)) if (it.layer.is3D && _visual(it.layer)) it.layer.id: it};
      final b = {for (final it in at(t1)) if (it.layer.is3D && _visual(it.layer)) it.layer.id: it};
      final moves = <(double, double, RenderItem)>[]; // (screen move px, depth, item)
      for (final id in a.keys) {
        final i0 = a[id]!, i1 = b[id];
        if (i1 == null) continue;
        // Only layers that do not animate themselves: their screen motion
        // then comes from the camera alone.
        final l = i0.layer;
        if (l.prop(Props.position).isAnimated || l.parentId != null) continue;
        final d = (_centre(i1) - _centre(i0)).length;
        if (!d.isFinite) continue;
        moves.add((d, i0.depth, i0));
      }
      if (moves.length < 2) continue;
      final mean = moves.map((m) => m.$1).reduce((x, y) => x + y) / moves.length;
      if (mean < w * 0.01) continue; // camera (nearly) still in this step
      final mx = moves.map((m) => m.$1).reduce(math.max), mn = moves.map((m) => m.$1).reduce(math.min);
      final spread = (mx - mn) / math.max(1e-6, mean);
      if (spread < 0.25 && (flatSpread == null || spread < flatSpread)) {
        flatSpread = spread;
        flatT0 = t0;
        flatT1 = t1;
        flatMove = mean;
      }
      // One big image covering most of the frame while the move is sideways.
      final sideways = moves.any((m) {
        final c0 = _centre(a[m.$3.layer.id]!), c1 = _centre(b[m.$3.layer.id]!);
        return (c1.x - c0.x).abs() > w * 0.01 && (c1.x - c0.x).abs() > (c1.y - c0.y).abs();
      });
      if (sideways && plateId == null) {
        final plates = [
          for (final m in moves)
            if (m.$3.layer.type == LayerType.image && !isCutOut(p, m.$3.layer) && _area(m.$3) > w * h * 0.75) m.$3.layer.id,
        ];
        final images = moves.where((m) => m.$3.layer.type == LayerType.image && !isCutOut(p, m.$3.layer)).length;
        if (plates.length == 1 && images == 1) {
          plateId = plates.first;
          plateT = t0;
        }
      }
    }
    if (flatT0 != null && flatT1 != null) {
      out.add(SceneIssue('flat_parallax', 'warning',
          'No parallax between ${_fmt(flatT0)} and ${_fmt(flatT1)} s: every 3D layer moves about ${flatMove!.round()} px on screen '
          '(spread ${(flatSpread! * 100).round()}%), so the scene looks like one flat picture moving with the camera.',
          time: flatT0,
          until: flatT1,
          hint: 'Spread the layers in depth (far plate ≥2× the distance of the subject, a foreground object close to the camera) '
              'and move the camera sideways/arc instead of only pushing straight in. Near layers should move clearly more than far ones.'));
    }
    if (plateId != null) {
      out.add(SceneIssue('flat_set', 'info',
          'The set is one flat photo ($plateId) while the camera moves sideways at ${_fmt(plateT!)} s: walls and floor inside it '
          'cannot change perspective.',
          layers: [plateId],
          time: plateT,
          hint: 'Build the set from separate layers (back wall, side walls / columns, floor plane rotated X -90, foreground props) '
              'or keep this shot to slow push-ins and small arcs.'));
    }
  }

  static double _area(RenderItem it) {
    final q = it.corners();
    var s = 0.0;
    for (var i = 0; i < q.length; i++) {
      final a = q[i], b = q[(i + 1) % q.length];
      s += a.x * b.y - b.x * a.y;
    }
    return (s / 2).abs();
  }

  // ------------------------------------------------------------ (d) text

  static double _charW(int c) {
    if (c == 0x20) return 0.28;
    if (c >= 0x30 && c <= 0x39) return 0.58;
    if (c >= 0x41 && c <= 0x5A) return 0.66;
    if (c >= 0x61 && c <= 0x7A) return 0.53;
    if (c >= 0x0900 && c <= 0x097F) {
      if (c == 0x094D || c == 0x093C || c == 0x0901 || c == 0x0902) return 0;
      if (c >= 0x093E && c <= 0x094C) return 0.22; // vowel signs
      return 0.62;
    }
    if (c < 0x80) return 0.4;
    return 0.6;
  }

  /// Estimated drawn text box in layer pixels [x0, y0, x1, y1] (text is
  /// wrapped to the layer width and centred vertically, like LayerView).
  static List<double> textRect(Layer l, double t) {
    final td = l.text ?? TextData();
    final fs = td.fontSize;
    final str = td.counter?.valueAt(t) ?? td.text;
    final boxW = l.width;
    var maxW = 0.0;
    var lines = 0;
    for (final line in str.split('\n')) {
      var lw = 0.0;
      for (final r in line.runes) {
        lw += _charW(r) * fs;
      }
      if (td.fontWeight >= 700) lw *= 1.05;
      if (boxW <= 0 || lw <= boxW) {
        lines++;
        maxW = math.max(maxW, lw);
      } else {
        lines += (lw / boxW).ceil();
        maxW = boxW;
      }
    }
    var cw = maxW, ch = math.max(1, lines) * fs * 1.15;
    if (td.boxColor != 0) {
      cw += fs * 0.7;
      ch += fs * 0.24;
    }
    final x0 = switch (td.align) { 'left' => 0.0, 'right' => boxW - cw, _ => (boxW - cw) / 2 };
    final y0 = (l.height - ch) / 2;
    return [x0, y0, x0 + cw, y0 + ch];
  }

  /// Screen bounds [x0, y0, x1, y1] of the text of [it].
  static List<double> textBounds(RenderItem it, double t) {
    final r = textRect(it.layer, t);
    final ps = [it.project(r[0], r[1]), it.project(r[2], r[1]), it.project(r[2], r[3]), it.project(r[0], r[3])];
    return [
      ps.map((v) => v.x).reduce(math.min),
      ps.map((v) => v.y).reduce(math.min),
      ps.map((v) => v.x).reduce(math.max),
      ps.map((v) => v.y).reduce(math.max),
    ];
  }

  static void _text(Composition comp, double f0, double f1, List<double> times, List<RenderItem> Function(double) at, List<SceneIssue> out) {
    final w = comp.width, h = comp.height;
    final texts = [for (final l in comp.layers) if (_visual(l) && l.type == LayerType.text && l.end > f0 && l.start < f1) l];
    if (texts.isEmpty) return;
    // "Settled" times of a text layer: away from its in/out animations.
    bool settled(Layer l, double t) {
      final m = math.min(1.0, l.duration * 0.25);
      return t >= l.start + m - 1e-9 && t <= l.end - m + 1e-9;
    }

    final ts = <double>{...times, for (final l in texts) ((math.max(l.start, f0) + math.min(l.end, f1)) / 2)}.toList()..sort();
    final offDone = <String>{};
    final pairDone = <String>{};
    for (final t in ts) {
      final items = [for (final it in at(t)) if (it.layer.type == LayerType.text && settled(it.layer, t)) it];
      final boxes = {for (final it in items) it.layer.id: textBounds(it, t)};
      for (final it in items) {
        final l = it.layer;
        if (offDone.contains(l.id)) continue;
        final b = boxes[l.id]!;
        final off = b[0] < -2 || b[1] < -2 || b[2] > w + 2 || b[3] > h + 2;
        final mx = w * safeMargin, my = h * safeMargin;
        final unsafe = b[0] < mx || b[1] < my || b[2] > w - mx || b[3] > h - my;
        if (!off && !unsafe) continue;
        offDone.add(l.id);
        final bw = b[2] - b[0], bh = b[3] - b[1];
        final safeW = w - 2 * mx, safeH = h - 2 * my;
        final fix = <Map<String, dynamic>>[];
        String? hint;
        if (bw > safeW || bh > safeH) {
          final k = math.min(safeW / bw, safeH / bh) * 0.97;
          fix.add({'op': 'update_layer', 'layer': l.id, 'font_size': (l.text!.fontSize * k).floorToDouble()});
          hint = 'Too big for the frame: smaller font (or more line breaks).';
        } else if (l.parentId == null) {
          final dx = b[0] < mx ? mx - b[0] + 2 : (b[2] > w - mx ? (w - mx) - b[2] - 2 : 0.0);
          final dy = b[1] < my ? my - b[1] + 2 : (b[3] > h - my ? (h - my) - b[3] - 2 : 0.0);
          final k = _toWorld(comp, it, t);
          fix.addAll(_shift(l, dx * k, dy * k));
        }
        out.add(SceneIssue(off ? 'text_off_frame' : 'text_unsafe', off ? 'error' : 'warning',
            'Text ${l.id} "${_short(l.text?.text ?? '')}" ${off ? 'goes off the frame' : 'is outside the 5% safe area'} at ${_fmt(t)} s '
            '(box ${b.map((v) => v.round()).join(', ')}).',
            layers: [l.id], time: t, fix: fix, hint: hint));
      }
      for (var i = 0; i < items.length; i++) {
        for (var j = i + 1; j < items.length; j++) {
          final a = items[i], c = items[j]; // c is painted later = on top
          final key = '${a.layer.id}|${c.layer.id}';
          if (pairDone.contains(key)) continue;
          final p = boxes[a.layer.id]!, q = boxes[c.layer.id]!;
          final ix = math.min(p[2], q[2]) - math.max(p[0], q[0]), iy = math.min(p[3], q[3]) - math.max(p[1], q[1]);
          if (ix <= 0 || iy <= 0) continue;
          final small = math.min((p[2] - p[0]) * (p[3] - p[1]), (q[2] - q[0]) * (q[3] - q[1]));
          if (small <= 0 || ix * iy < small * 0.15) continue;
          pairDone.add(key);
          final top = c.layer;
          final below = (q[1] + q[3]) / 2 >= (p[1] + p[3]) / 2;
          final dy = below ? (p[3] - q[1]) + h * 0.02 : -((q[3] - p[1]) + h * 0.02);
          out.add(SceneIssue('text_overlap', 'warning',
              'Texts ${a.layer.id} and ${top.id} overlap at ${_fmt(t)} s.',
              layers: [a.layer.id, top.id],
              time: t,
              fix: top.parentId == null ? _shift(top, 0, dy * _toWorld(comp, c, t)) : const [],
              hint: 'Fix moves ${top.id} ${below ? 'down' : 'up'}; or shorten one of them in time.'));
        }
      }
    }
  }

  static String _short(String s) {
    final one = s.replaceAll('\n', ' ');
    return one.length > 30 ? '${one.substring(0, 30)}…' : one;
  }

  // ------------------------------------------------------------ (e) effects

  static void _effects(Composition comp, List<SceneIssue> out) {
    for (final l in comp.layers) {
      if (KnownBroken.blurOn3D && l.is3D) {
        for (final e in l.effects) {
          if (!e.enabled || e.type != 'blur') continue;
          out.add(SceneIssue('broken_effect', 'warning',
              'Blur ${e.id} on 3D layer ${l.id} can make the layer invisible (known bug).',
              layers: [l.id],
              fix: [{'op': 'remove_effect', 'layer': l.id, 'effect': e.id}],
              hint: 'For depth blur use the 3D camera\'s aperture/focus instead.'));
        }
      }
      final td = l.text;
      if (KnownBroken.scrambleDevanagari && td != null && td.animator == 'scramble' && RegExp('[ऀ-ॿ]').hasMatch(td.text)) {
        out.add(SceneIssue('broken_effect', 'warning', 'The scramble animator breaks Devanagari conjuncts on ${l.id} (known bug).',
            layers: [l.id], fix: [{'op': 'update_layer', 'layer': l.id, 'animator': 'fade_up'}]));
      }
    }
  }

  // ------------------------------------------------------------ (f) media

  static void _media(Project p, Composition comp, bool Function(String) exists, List<SceneIssue> out) {
    final checked = <String, bool>{};
    for (final l in comp.layers) {
      if (l.type == LayerType.comp) {
        if (l.compId == null || p.comps[l.compId] == null) {
          out.add(SceneIssue('missing_media', 'error', 'Precomp layer ${l.id} points to a composition that does not exist.', layers: [l.id]));
        }
        continue;
      }
      final id = l.mediaId;
      if (id == null || !(l.type == LayerType.image || l.type == LayerType.video || l.type == LayerType.audio)) continue;
      final a = p.media[id];
      if (a == null) {
        out.add(SceneIssue('missing_media', 'error', 'Layer ${l.id} uses media "$id", which is not in the project.', layers: [l.id]));
        continue;
      }
      final ok = checked[a.path] ??= exists(a.path);
      if (!ok) {
        out.add(SceneIssue('missing_media', 'error', 'Media file of ${l.id} is missing on disk: ${a.path}',
            layers: [l.id], hint: 'Find the file and import_media it again, then point the layer to the new media id (or remove the layer).'));
      }
    }
  }
}
