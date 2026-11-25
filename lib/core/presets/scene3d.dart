import 'dart:convert';
import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../engine/evaluator.dart';
import '../model/anim_prop.dart';
import '../model/camera.dart';
import '../model/easing.dart';
import '../model/layer.dart';
import '../model/project.dart';

/// "Compose flat, play deep" (Agent D): `make_3d` puts flat layers on depth
/// bands without changing the first frame, `camera_shot` flies the 3D camera
/// through them, and shots / recipes are saved by name in the project.
///
/// Projection (see [Evaluator.projection]): a point at camera-space depth `d`
/// lands at `c + zoom · (x − cam) / d`. With the home camera (at
/// `(w/2, h/2, −zoom)` looking at `(w/2, h/2, 0)`) a layer at `z = 0` is drawn
/// exactly like a 2D layer, so pushing it to depth `d` and scaling it (and its
/// offset from the frame centre) by `d / zoom` keeps it pixel-identical.
class Scene3D {
  static const bands = ['sky', 'far', 'mid', 'near', 'front'];
  static const moves = ['drift', 'fly_to', 'push_through', 'pass_by', 'reveal', 'pull_back', 'orbit', 'truck', 'arc', 'crane'];

  /// The camera never gets closer than this (px) to any layer it can see.
  static const double minClearance = 30;

  /// Camera distance of each band, in units of the home camera distance.
  static double bandFactor(String band) => switch (band) {
        'sky' => 4.0,
        'far' => 2.0,
        'near' => 0.7,
        'front' => 0.45,
        _ => 1.0,
      };

  static String bandLabel(String band) => const {
        'sky': 'Sky',
        'far': 'Far',
        'mid': 'Mid',
        'near': 'Near',
        'front': 'Front',
      }[band] ??
      band;

  static String moveLabel(String move) => const {
        'drift': 'Drift',
        'fly_to': 'Fly to',
        'push_through': 'Push through',
        'pass_by': 'Pass by',
        'reveal': 'Reveal',
        'pull_back': 'Pull back',
        'orbit': 'Orbit',
        'truck': 'Truck (sideways)',
        'arc': 'Arc around',
        'crane': 'Crane up',
      }[move] ??
      move;

  static double homeZoom(Composition comp) => defaultZoomFor(comp.width);

  static bool isVisual(Layer l) => l.type != LayerType.audio && l.type != LayerType.nullObject;

  // ------------------------------------------------------------- hierarchy

  static Map<String, List<Layer>> _children(Composition comp) {
    final m = <String, List<Layer>>{};
    for (final l in comp.layers) {
      final p = l.parentId;
      if (p != null && p != l.id && comp.layerById(p) != null) (m[p] ??= []).add(l);
    }
    return m;
  }

  static Layer rootOf(Composition comp, Layer l) {
    var cur = l;
    for (int i = 0; i < 32; i++) {
      final pid = cur.parentId;
      final p = pid == null ? null : comp.layerById(pid);
      if (p == null || p.id == cur.id) break;
      cur = p;
    }
    return cur;
  }

  /// [root] and all its descendants, parents before children.
  static List<Layer> _subtree(Layer root, Map<String, List<Layer>> kids) {
    final out = <Layer>[];
    final seen = <String>{};
    void walk(Layer l, int depth) {
      if (depth > 32 || !seen.add(l.id)) return;
      out.add(l);
      for (final k in kids[l.id] ?? const <Layer>[]) {
        walk(k, depth + 1);
      }
    }

    walk(root, 0);
    return out;
  }

  // --------------------------------------------------------------- bands

  /// Screen box [x0, y0, x1, y1] of the visual layers in [ls] at [t].
  static List<double>? screenBox(Composition comp, Iterable<Layer> ls, double t) {
    final proj = Evaluator.projection(Evaluator.camera3D(comp, t));
    double x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    for (final l in ls) {
      if (!isVisual(l)) continue;
      final w = Evaluator.worldMatrix(comp, l, t);
      final m = l.is3D ? proj.multiplied(w) : w;
      for (final c in <List<double>>[
        [0, 0],
        [l.width, 0],
        [l.width, l.height],
        [0, l.height],
      ]) {
        final p = projectPoint(m, c[0], c[1]);
        if (!p.x.isFinite || !p.y.isFinite) continue;
        x0 = math.min(x0, p.x);
        y0 = math.min(y0, p.y);
        x1 = math.max(x1, p.x);
        y1 = math.max(y1, p.y);
      }
    }
    if (!x0.isFinite) return null;
    return [x0, y0, x1, y1];
  }

  /// Band from type, name, size and position: sky/solid/full-frame
  /// background → sky; small things in the top half → far; wide strips on
  /// the bottom edge → near; large layers touching a frame edge → front.
  static String guessBand(Layer l, List<double>? box, double w, double h) {
    final name = l.name.toLowerCase();
    bool has(String re) => RegExp(re).hasMatch(name);
    if (has(r'\b(sky|background|backdrop|bg)\b')) return 'sky';
    if (box == null) return 'mid';
    final ix0 = math.max(0.0, box[0]), iy0 = math.max(0.0, box[1]);
    final ix1 = math.min(w, box[2]), iy1 = math.min(h, box[3]);
    final vis = (ix1 > ix0 && iy1 > iy0) ? (ix1 - ix0) * (iy1 - iy0) / (w * h) : 0.0;
    final bw = box[2] - box[0], bh = box[3] - box[1];
    const tol = 0.02;
    final touches = box[0] <= w * tol || box[1] <= h * tol || box[2] >= w * (1 - tol) || box[3] >= h * (1 - tol);
    if (vis >= 0.92) return 'sky';
    if (l.type == LayerType.solid && vis >= 0.5) return 'sky';
    if (has(r'(plant|reed|tree|bush|foreground|leaves|leaf)')) return 'front';
    if (bw >= w * 0.6 && bh <= h * 0.4 && box[3] >= h * 0.9) return 'near';
    if ((vis >= 0.12 || bh >= h * 0.5) && touches) return 'front';
    if (vis < 0.12 && (box[1] + box[3]) / 2 < h * 0.5) return 'far';
    return 'mid';
  }

  /// Band of a layer converted by [make3D] (from its depth with the home camera).
  static String bandOf(Composition comp, Layer l, double t) {
    if (!l.is3D) return 'flat';
    final r = rootOf(comp, l);
    final z = r.prop(Props.position).valueAt(t)[2];
    final k = (z + homeZoom(comp)) / homeZoom(comp);
    String best = 'mid';
    double bestD = double.infinity;
    for (final b in bands) {
      final d = (math.log(math.max(k, 1e-3)) - math.log(bandFactor(b))).abs();
      if (d < bestD) {
        bestD = d;
        best = b;
      }
    }
    return best;
  }

  // ---------------------------------------------------------------- make_3d

  /// Converts layers to 3D on depth bands; the frame at [start] is unchanged.
  /// Returns the ids of the converted group roots.
  static List<String> make3D(Composition comp,
      {List<String>? layerIds, Map<String, String> bands = const {}, required double start, List<String>? log}) {
    for (final e in bands.entries) {
      if (!Scene3D.bands.contains(e.value)) {
        throw ArgumentError('Unknown band "${e.value}" for "${e.key}". Use ${Scene3D.bands.join(', ')}');
      }
      if (comp.layerById(e.key) == null) throw ArgumentError('make_3d bands: no layer "${e.key}"');
    }
    List<Layer> wanted;
    if (layerIds != null && layerIds.isNotEmpty) {
      wanted = [];
      for (final id in layerIds) {
        final l = comp.layerById(id);
        if (l == null) {
          throw ArgumentError('make_3d: no layer "$id". Layers: ${comp.layers.map((l) => l.id).join(', ')}');
        }
        wanted.add(l);
      }
    } else {
      wanted = comp.layers.where((l) => isVisual(l) && l.isActiveAt(start)).toList();
      if (wanted.isEmpty) wanted = comp.layers.where(isVisual).toList();
    }
    if (wanted.isEmpty) throw ArgumentError('make_3d: there are no layers to put in depth');
    // Track mattes go with their layer.
    final ids = {for (final l in wanted) l.id};
    for (final l in List.of(wanted)) {
      final m = l.matte;
      final ml = m == null ? null : comp.layerById(m.layerId);
      if (ml != null && ids.add(ml.id)) wanted.add(ml);
    }

    final kids = _children(comp);
    final roots = <Layer>[];
    final seen = <String>{};
    for (final l in wanted) {
      final r = rootOf(comp, l);
      if (seen.add(r.id)) roots.add(r);
    }
    final w = comp.width, h = comp.height, cx = w / 2, cy = h / 2;
    final z0 = homeZoom(comp);

    // Measure everything before changing anything.
    final infos = <_RootInfo>[];
    for (final r in roots) {
      final sub = _subtree(r, kids);
      String? band = bands[r.id];
      if (band == null) {
        for (final s in sub) {
          final b = bands[s.id];
          if (b != null) {
            band = b;
            break;
          }
        }
      }
      band ??= guessBand(r, screenBox(comp, sub, start), w, h);
      infos.add(_RootInfo(r, sub, band));
    }

    if (comp.camera.mode == CameraMode.twoD) log?.add('make_3d: the 2D camera is replaced by the 3D camera');
    homeCamera(comp, start);

    // Depth per root: bands far→near; inside a band, layers higher in the
    // stack sit a little closer so the stacking order survives camera tilt.
    final idx = {for (int i = 0; i < comp.layers.length; i++) comp.layers[i].id: i};
    final childStep = z0 * 0.002;
    for (final band in Scene3D.bands) {
      final group = infos.where((i) => i.band == band).toList()
        ..sort((a, b) => (idx[b.root.id] ?? 0).compareTo(idx[a.root.id] ?? 0));
      var maxN = 0;
      for (final i in group) {
        maxN = math.max(maxN, i.sub.where(isVisual).length);
      }
      final step = z0 * 0.006 + maxN * childStep;
      for (int k = 0; k < group.length; k++) {
        group[k].depth = math.max(z0 * 0.2, bandFactor(band) * z0 - k * step);
      }
    }

    final out = <String>[];
    for (final i in infos) {
      final r = i.root;
      if (r.is3D) {
        if (bands[r.id] == null) {
          log?.add('${r.name} is already 3D: kept where it is');
          continue;
        }
        final d0 = r.prop(Props.position).valueAt(start)[2] + z0;
        if (d0 <= minClearance) continue;
        _pushBack(r, i.depth / d0, i.depth - z0, cx, cy, flat: false);
        out.add(r.id);
        continue;
      }
      _pushBack(r, i.depth / z0, i.depth - z0, cx, cy, flat: true);
      _convertChildren(comp, i, start, cx, cy, childStep, idx);
      out.add(r.id);
      log?.add('${r.name} → ${i.band}');
    }
    return out;
  }

  static void _mapProp(AnimProp p, List<double> Function(List<double>) f) {
    p.staticValue = f(p.staticValue);
    for (final k in p.keyframes) {
      k.value = f(k.value);
    }
  }

  /// A 2D layer's ignored 3D values (X/Y rotation, anchor Z) are zeroed.
  static void _flatten(Layer l) {
    _mapProp(l.prop(Props.rotation), (v) => [0, 0, v[2]]);
    _mapProp(l.prop(Props.anchor), (v) => [v[0], v[1], 0]);
  }

  static void _scalePath(Layer l, double k) {
    final path = l.path;
    if (path == null || (k - 1).abs() < 1e-12) return;
    l.path = MotionPath(points: [for (final p in path.points) [p[0] * k, p[1] * k]], smooth: path.smooth, orient: path.orient);
  }

  /// Moves a root layer to depth `z` (scale/offset ×[k] about the frame centre).
  static void _pushBack(Layer l, double k, double z, double cx, double cy, {required bool flat}) {
    if (flat) _flatten(l);
    l.is3D = true;
    _mapProp(l.prop(Props.position), (v) => [cx + (v[0] - cx) * k, cy + (v[1] - cy) * k, z]);
    _mapProp(l.prop(Props.scale), (v) => [v[0] * k, v[1] * k, v[2]]);
    _scalePath(l, k);
  }

  /// Children ride on their root's plane; each visual child is nudged a few
  /// px toward the camera (by stacking order) with exact scale compensation,
  /// so the first frame still matches to sub-pixel precision.
  static void _convertChildren(Composition comp, _RootInfo info, double t, double cx, double cy, double step, Map<String, int> idx) {
    final r = info.root;
    final desc = info.sub.where((l) => l.id != r.id).toList();
    if (desc.isEmpty) return;
    final flat = <String>{};
    for (final l in desc) {
      if (l.is3D) continue;
      flat.add(l.id);
      l.is3D = true;
      _flatten(l);
      _mapProp(l.prop(Props.position), (v) => [v[0], v[1], 0]);
    }
    final world = {for (final l in info.sub) l.id: Evaluator.worldMatrix(comp, l, t)};
    final vis = info.sub.where(isVisual).toList()..sort((a, b) => (idx[b.id] ?? 0).compareTo(idx[a.id] ?? 0));
    final rank = {for (int k = 0; k < vis.length; k++) vis[k].id: k};
    final rootRank = rank[r.id] ?? 0;
    final d = info.depth;
    final delta = <String, double>{r.id: 0};
    for (final l in desc) {
      final pid = l.parentId;
      final pd = delta[pid] ?? 0.0;
      var dl = isVisual(l) && flat.contains(l.id) ? (rank[l.id]! - rootRank) * step : pd;
      if ((dl - pd).abs() < 1e-9 || pid == null) {
        delta[l.id] = pd;
        continue;
      }
      final wp = world[pid];
      if (wp == null) {
        delta[l.id] = pd;
        continue;
      }
      final inv = Matrix4.copy(wp);
      if (inv.invert().abs() < 1e-12 || d - dl < minClearance || d - pd < minClearance) {
        delta[l.id] = pd; // scaled to nothing right now: keep it on the plane
        continue;
      }
      delta[l.id] = dl;
      final s = (d - dl) / (d - pd);
      final b = Matrix4.translationValues(cx, cy, -(dl - pd))
        ..multiply(Matrix4.diagonal3Values(s, s, 1))
        ..multiply(Matrix4.translationValues(-cx, -cy, 0));
      final m = inv.multiplied(b).multiplied(wp);
      _mapProp(l.prop(Props.position), (v) {
        final q = m.transformed3(Vector3(v[0], v[1], v[2]));
        return [q.x, q.y, q.z];
      });
      _mapProp(l.prop(Props.scale), (v) => [v[0] * s, v[1] * s, v[2]]);
      _scalePath(l, s);
    }
  }

  /// Puts the 3D camera at its home position at [t] (a cut if it was elsewhere).
  static void homeCamera(Composition comp, double t) {
    final rig = comp.camera;
    final was3D = rig.mode == CameraMode.threeD;
    rig.mode = CameraMode.threeD;
    final z = homeZoom(comp);
    final w = comp.width, h = comp.height;
    final values = <String, List<double>>{
      CamProps.position: [w / 2, h / 2, -z],
      CamProps.poi: [w / 2, h / 2, 0],
      CamProps.zoom: [z],
      CamProps.roll: [0],
    };
    for (final e in values.entries) {
      final p = rig.prop(e.key);
      if (!was3D || !p.isAnimated) {
        p.keyframes.clear();
        p.staticValue = List.of(e.value);
        continue;
      }
      cutKey(p, t, e.value, comp.frameDuration);
    }
  }

  // ------------------------------------------------------------ camera_shot

  static Vector3 _v(List<double> l) => Vector3(l[0], l[1], l.length > 2 ? l[2] : 0);
  static List<double> _l(Vector3 v) => [v.x, v.y, v.z];

  static bool _close(List<double> a, List<double> b, [double eps = 1e-6]) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > eps) return false;
    }
    return true;
  }

  /// Sets a keyframe at [t]; if the value jumps there, the old value holds
  /// until one frame before (a cut, not a glide).
  static void cutKey(AnimProp p, double t, List<double> v, double frame, {Easing? easing}) {
    final cur = p.valueAt(t);
    if (!_close(cur, v, 1e-4)) p.setKeyframe(t - frame, cur, easing: Easing.hold);
    p.setKeyframe(t, v, easing: easing);
  }

  /// Removes keyframes in [a, b] (keeping the value at [a] if none are left).
  static void clearRange(AnimProp p, double a, double b) {
    final v = p.valueAt(a);
    p.keyframes.removeWhere((k) => k.time >= a - kTimeEpsilon && k.time <= b + kTimeEpsilon);
    if (p.keyframes.isEmpty) p.staticValue = v;
  }

  /// World-space box of [l] (and its descendants): centre + width/height.
  static ({Vector3 center, double w, double h})? worldBox(Composition comp, Layer l, double t) {
    final kids = _children(comp);
    double x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity, zs = 0;
    var n = 0;
    for (final s in _subtree(l, kids)) {
      if (!isVisual(s)) continue;
      final wm = Evaluator.worldMatrix(comp, s, t);
      for (final c in <List<double>>[
        [0, 0],
        [s.width, 0],
        [s.width, s.height],
        [0, s.height],
      ]) {
        final p = wm.transformed3(Vector3(c[0], c[1], 0));
        x0 = math.min(x0, p.x);
        y0 = math.min(y0, p.y);
        x1 = math.max(x1, p.x);
        y1 = math.max(y1, p.y);
        zs += p.z;
        n++;
      }
    }
    if (n == 0) {
      final p = Evaluator.worldMatrix(comp, l, t).transformed3(Vector3.zero());
      return (center: p, w: 0, h: 0);
    }
    return (center: Vector3((x0 + x1) / 2, (y0 + y1) / 2, zs / n), w: x1 - x0, h: y1 - y0);
  }

  /// Ray through screen point [sx],[sy] at time [t].
  static Vector3 _ray(Camera3DState cam, double sx, double sy) =>
      cam.forward + cam.right * ((sx - cam.cx) / cam.zoom) + cam.down * ((sy - cam.cy) / cam.zoom);

  /// Where the target is: a layer, a tapped screen point (on the topmost 3D
  /// layer under it) or the point the camera looks at.
  static ({Vector3 center, double w, double h}) _target(Composition comp, String? target, List<double>? point, double t, Camera3DState cam, Vector3 poi) {
    if (target != null) {
      final b = worldBox(comp, comp.requireLayer(target), t);
      if (b != null) {
        final d = math.max(minClearance, (b.center - cam.position).dot(cam.forward));
        final nominal = comp.width * 0.2 * d / cam.zoom;
        return (center: b.center, w: b.w > 1 ? b.w : nominal, h: b.h > 1 ? b.h : nominal * comp.height / comp.width);
      }
    }
    if (point != null && point.length >= 2) {
      final dir = _ray(cam, point[0], point[1]);
      final items = Evaluator.evaluate(comp, t);
      for (int i = items.length - 1; i >= 0; i--) {
        final it = items[i];
        if (!it.layer.is3D || !it.containsPoint(point[0], point[1])) continue;
        final wm = Evaluator.worldMatrix(comp, it.layer, t);
        final o = wm.transformed3(Vector3.zero());
        final nrm = (wm.transformed3(Vector3(1, 0, 0)) - o).cross(wm.transformed3(Vector3(0, 1, 0)) - o);
        final den = dir.dot(nrm);
        if (den.abs() < 1e-12) continue;
        final s = (o - cam.position).dot(nrm) / den;
        if (s <= 0) continue;
        final hit = cam.position + dir * s;
        final d = (hit - cam.position).dot(cam.forward);
        final size = comp.width * 0.25 * d / cam.zoom;
        return (center: hit, w: size, h: size * comp.height / comp.width);
      }
      final d = math.max(minClearance * 4, (poi - cam.position).dot(cam.forward));
      final hit = cam.position + dir * d;
      final size = comp.width * 0.25 * d / cam.zoom;
      return (center: hit, w: size, h: size * comp.height / comp.width);
    }
    final d = math.max(minClearance * 4, (poi - cam.position).dot(cam.forward));
    final size = comp.width * 0.3 * d / cam.zoom;
    return (center: poi, w: size, h: size * comp.height / comp.width);
  }

  /// Distance (px) from the camera to the nearest visible 3D layer
  /// rectangle at time [t] (infinity when there is none).
  static double nearestLayerDistance(Composition comp, double t) {
    final cam = Evaluator.camera3D(comp, t);
    final cache = <String, Matrix4>{};
    var best = double.infinity;
    for (final l in comp.layers) {
      if (!l.is3D || !isVisual(l) || !l.isActiveAt(t)) continue;
      if (l.prop(Props.opacity).scalarAt(t) <= 0) continue;
      final wm = Evaluator.worldMatrix(comp, l, t, cache);
      final o = wm.transformed3(Vector3.zero());
      final u = wm.transformed3(Vector3(l.width, 0, 0)) - o;
      final v = wm.transformed3(Vector3(0, l.height, 0)) - o;
      final uu = u.length2, vv = v.length2;
      if (uu < 1e-9 || vv < 1e-9) continue;
      final rel = cam.position - o;
      final a = (rel.dot(u) / uu).clamp(0.0, 1.0);
      final b = (rel.dot(v) / vv).clamp(0.0, 1.0);
      final closest = o + u * a + v * b;
      best = math.min(best, (cam.position - closest).length);
    }
    return best;
  }

  /// Uniform scale (about its anchor) [l] needs to cover the whole frame at [t].
  static double coverScale(Composition comp, Layer l, double t) {
    final cam = Evaluator.camera3D(comp, t);
    final wm = Evaluator.worldMatrix(comp, l, t);
    final inv = Matrix4.copy(wm);
    if (inv.invert().abs() < 1e-12) return 1;
    final o = wm.transformed3(Vector3.zero());
    final nrm = (wm.transformed3(Vector3(1, 0, 0)) - o).cross(wm.transformed3(Vector3(0, 1, 0)) - o);
    final a = l.prop(Props.anchor).valueAt(t);
    var need = 1.0;
    for (final sc in <List<double>>[
      [0, 0],
      [comp.width, 0],
      [comp.width, comp.height],
      [0, comp.height],
    ]) {
      final dir = _ray(cam, sc[0], sc[1]);
      final den = dir.dot(nrm);
      if (den.abs() < 1e-12) return 99;
      final s = (o - cam.position).dot(nrm) / den;
      if (s <= 0) return 99;
      final q = inv.transformed3(cam.position + dir * s);
      double side(double u, double anchor, double size) {
        if (u < 0) return anchor <= 1e-6 ? 99 : (anchor - u) / anchor;
        if (u > size) return size - anchor <= 1e-6 ? 99 : (u - anchor) / (size - anchor);
        return 1;
      }

      need = math.max(need, side(q.x, a[0], l.width));
      need = math.max(need, side(q.y, a[1], l.height));
    }
    return need;
  }

  /// Writes a 3D camera move. Returns ids of layers it created (the flash of `cut_to`).
  static List<String> cameraShot(
    Composition comp, {
    required String move,
    String? target,
    List<double>? point,
    required double start,
    required double duration,
    Easing? ease,
    String? cutTo,
    double intensity = 0.5,
    String direction = 'right',
    List<String>? log,
  }) {
    if (!moves.contains(move)) throw ArgumentError('Unknown camera_shot move "$move". Use ${moves.join(', ')}');
    if (target != null && comp.layerById(target) == null) {
      throw ArgumentError('camera_shot: no layer "$target". Layers: ${comp.layers.map((l) => l.id).join(', ')}');
    }
    if (cutTo != null && comp.layerById(cutTo) == null) throw ArgumentError('camera_shot: no cut_to layer "$cutTo"');
    final dur = math.max(duration, comp.frameDuration * 2);
    final end = start + dur;
    final rig = comp.camera;
    if (rig.mode != CameraMode.threeD) {
      homeCamera(comp, start);
      log?.add('Camera switched to 3D (run make_3d first so the layers have depth)');
    }
    final w = comp.width, h = comp.height;
    final cam = Evaluator.camera3D(comp, start);
    final p0 = cam.position.clone();
    final q0 = _v(rig.prop(CamProps.poi).valueAt(start));
    final zoom = cam.zoom;
    final fwd = cam.forward, right = cam.right;
    final f = intensity.clamp(0.0, 1.0) * 2;
    final tb = _target(comp, target, point, start, cam, q0);
    final tc = tb.center;
    final sizeMax = math.max(tb.w / w, tb.h / h), sizeMin = math.min(tb.w / w, tb.h / h);
    var d0 = (tc - p0).dot(fwd);
    if (d0 < minClearance * 2) d0 = math.max(minClearance * 2, (tc - p0).length);
    final e = ease ?? (move == 'push_through' ? Easing.easeIn : Easing.easyEase);
    final keys = <_Key>[];
    var sampled = false;
    Vector3 front(Vector3 at, double dist) => Vector3(at.x, at.y, at.z - dist);

    switch (move) {
      case 'drift':
        keys.add(_Key(0, p0, q0));
        keys.add(_Key(1, p0 + right * (0.06 * w * f) + fwd * (0.1 * d0 * f), q0 + right * (0.045 * w * f) + fwd * (0.1 * d0 * f)));
        break;
      case 'fly_to':
        final fill = (0.35 + 0.2 * f).clamp(0.3, 0.8);
        final dEnd = math.min(math.max(zoom * sizeMax / fill, minClearance * 3), math.max(d0 * 0.85, minClearance * 3));
        keys.add(_Key(0, p0, q0));
        keys.add(_Key(1, front(tc, dEnd), tc));
        break;
      case 'push_through':
        final dEnd = math.max(minClearance + 15, zoom * sizeMin / 1.15);
        keys.add(_Key(0, p0, q0));
        keys.add(_Key(1, front(tc, dEnd), tc));
        comp.motionBlur = true;
        break;
      case 'pass_by':
        final a = 0.2 * w * math.max(f, 0.2) * (direction == 'left' ? -1 : 1);
        keys.add(_Key(0, p0, q0));
        keys.add(_Key(1, p0 + right * (a * 2) + fwd * (0.15 * d0 * f), tc + right * (a * 0.6)));
        break;
      case 'reveal':
        Layer? fl;
        var flDepth = double.infinity;
        for (final it in Evaluator.evaluate(comp, start)) {
          if (!it.layer.is3D || it.layer.id == target) continue;
          if (it.depth >= d0 - minClearance * 2 || it.depth <= minClearance * 3) continue;
          final bb = _bounds(it.corners());
          final ix = math.min(w, bb[2]) - math.max(0.0, bb[0]), iy = math.min(h, bb[3]) - math.max(0.0, bb[1]);
          if (ix <= 0 || iy <= 0 || ix * iy < w * h * 0.02) continue;
          if (it.depth < flDepth) {
            flDepth = it.depth;
            fl = it.layer;
          }
        }
        final fb = fl == null ? null : worldBox(comp, fl, start);
        if (fb == null || fb.w <= 1 || fb.h <= 1) {
          log?.add('reveal: no near/front layer in front of the target, sliding in from the side');
          keys.add(_Key(0, p0 - right * (0.22 * w * math.max(f, 0.4)), q0 - right * (0.18 * w * math.max(f, 0.4))));
          keys.add(_Key(1, p0 + fwd * (0.06 * d0 * f), tc));
        } else {
          final dS = math.max(minClearance * 3, zoom * math.min(fb.w / w, fb.h / h) / 1.1);
          final c = fb.center;
          var side = (p0.x - c.x).sign;
          if ((p0.x - c.x).abs() < w * 0.05) side = 1;
          keys.add(_Key(0, front(c, dS), Vector3(c.x, c.y, tc.z)));
          keys.add(_Key(1, p0 + right * (side * 0.08 * w * f) + fwd * (0.06 * d0 * f), tc));
          log?.add('reveal: starts behind ${fl!.name}');
        }
        break;
      case 'pull_back':
        final dC = math.max(minClearance * 2.5, zoom * sizeMax / (1.5 + 1.5 * f));
        keys.add(_Key(0, front(tc, dC), tc));
        keys.add(_Key(1, p0, q0));
        break;
      case 'truck':
        // win-30: a real sideways dolly — camera and aim slide together, so
        // every depth moves at its own speed (the strongest parallax).
        final a = 0.22 * w * math.max(f, 0.3) * (direction == 'left' ? -1 : 1);
        keys.add(_Key(0, p0 - right * (a * 0.5), q0 - right * (a * 0.5)));
        keys.add(_Key(1, p0 + right * (a * 0.5) + fwd * (0.04 * d0 * f), q0 + right * (a * 0.5) + fwd * (0.04 * d0 * f)));
        break;
      case 'arc':
        // win-30: a wider orbit (up to 40°) that also pushes in a little.
        final theta = math.min(40.0, 12 + 28 * intensity.clamp(0.0, 1.0)) * (direction == 'left' ? -1 : 1) * math.pi / 180;
        const n = 10;
        final rel = p0 - tc;
        for (int i = 0; i <= n; i++) {
          final u = i / n;
          final ev = e.transform(u);
          final a = theta * (ev - 0.5);
          final c = math.cos(a), s = math.sin(a);
          final k = 1 - 0.15 * f * ev / 2;
          final pos = Vector3(tc.x + (rel.x * c - rel.z * s) * k, p0.y, tc.z + (rel.x * s + rel.z * c) * k);
          keys.add(_Key(u, pos, q0 + (tc - q0) * ev));
        }
        sampled = true;
        break;
      case 'crane':
        // win-30: rises (or sinks with direction "down") while tilting toward the target.
        final up = (direction == 'down' ? -1.0 : 1.0) * 0.22 * h * math.max(f, 0.3);
        final down = cam.down;
        keys.add(_Key(0, p0 + down * (up * 0.5), q0));
        keys.add(_Key(1, p0 - down * (up * 0.5) + fwd * (0.05 * d0 * f), tc - down * (up * 0.15)));
        break;
      case 'orbit':
        final theta = math.min(25.0, 8 + 24 * intensity.clamp(0.0, 1.0)) * (direction == 'left' ? -1 : 1) * math.pi / 180;
        const n = 8;
        final rel = p0 - tc;
        for (int i = 0; i <= n; i++) {
          final u = i / n;
          final ev = e.transform(u);
          final a = theta * ev;
          final c = math.cos(a), s = math.sin(a);
          final pos = Vector3(tc.x + rel.x * c - rel.z * s, p0.y, tc.z + rel.x * s + rel.z * c);
          keys.add(_Key(u, pos, q0 + (tc - q0) * ev));
        }
        sampled = true;
        break;
    }

    // Backgrounds: 3D layers that fill the whole frame before the move.
    final bgs = <Layer>[];
    for (final it in Evaluator.evaluate(comp, start)) {
      if (!it.layer.is3D) continue;
      final q = it.corners();
      if ([
        [1.0, 1.0],
        [w - 1, 1.0],
        [w - 1, h - 1],
        [1.0, h - 1],
      ].every((p) => pointInQuad(Vector2(p[0], p[1]), q))) {
        bgs.add(it.layer);
      }
    }

    const props = [CamProps.position, CamProps.poi, CamProps.zoom];
    final saved = {for (final k in props) k: rig.prop(k).copy()};
    void write(double lam) {
      for (final k in props) {
        rig.props[k] = saved[k]!.copy();
        clearRange(rig.prop(k), start, end);
      }
      for (int i = 0; i < keys.length; i++) {
        final k = keys[i];
        final pos = p0 + (k.pos - p0) * lam;
        final poi = q0 + (k.poi - q0) * lam;
        final t = start + dur * k.u;
        final easing = sampled ? Easing.linear : (i == 0 ? e : Easing.easyEase);
        if (i == 0) {
          cutKey(rig.prop(CamProps.position), t, _l(pos), comp.frameDuration, easing: easing);
          cutKey(rig.prop(CamProps.poi), t, _l(poi), comp.frameDuration, easing: easing);
          cutKey(rig.prop(CamProps.zoom), t, [zoom], comp.frameDuration, easing: Easing.linear);
        } else {
          rig.prop(CamProps.position).setKeyframe(t, _l(pos), easing: easing);
          rig.prop(CamProps.poi).setKeyframe(t, _l(poi), easing: easing);
        }
      }
      rig.prop(CamProps.zoom).setKeyframe(end, [zoom], easing: Easing.linear);
    }

    double clearance() {
      final n = math.max(24, (dur * comp.fps / 2).ceil()).clamp(24, 120);
      var m = double.infinity;
      for (int i = 0; i <= n; i++) {
        m = math.min(m, nearestLayerDistance(comp, math.min(start + dur * i / n, end - 1e-4)));
      }
      return m;
    }

    var bestLam = 1.0, bestClear = -1.0;
    double? written;
    for (final lam in const [1.0, 0.85, 0.7, 0.55, 0.4, 0.25, 0.1, 0.0]) {
      write(lam);
      written = lam;
      final c = clearance();
      if (c >= minClearance) {
        bestLam = lam;
        bestClear = c;
        break;
      }
      if (c > bestClear) {
        bestClear = c;
        bestLam = lam;
      }
    }
    if (written != bestLam) write(bestLam);
    if (bestLam < 1) {
      log?.add('camera_shot $move: shortened to ${(bestLam * 100).round()}% to stay ${minClearance.round()} px from every layer');
    }

    // No empty edges: grow full-frame backgrounds that the move would uncover.
    for (final l in bgs) {
      var need = 1.0;
      for (int i = 0; i <= 16; i++) {
        final t = math.min(start + dur * i / 16, end - 1e-4);
        if (!l.isActiveAt(t)) continue;
        need = math.max(need, coverScale(comp, l, t));
      }
      if (need > 1.0005) {
        final s = math.min(need * 1.01, 3.0);
        _mapProp(l.prop(Props.scale), (v) => [v[0] * s, v[1] * s, v[2]]);
        log?.add('${l.name} scaled ×${s.toStringAsFixed(2)} so the move shows no empty edges');
      }
    }

    final created = <String>[];
    if (cutTo != null) created.addAll(_cut(comp, cutTo, end, log));
    return created;
  }

  static List<double> _bounds(List<Vector2> q) {
    double x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    for (final p in q) {
      x0 = math.min(x0, p.x);
      y0 = math.min(y0, p.y);
      x1 = math.max(x1, p.x);
      y1 = math.max(y1, p.y);
    }
    return [x0, y0, x1, y1];
  }

  /// Ends the current 3D set at [end] and cuts to [cutTo] behind a short white flash.
  static List<String> _cut(Composition comp, String cutTo, double end, List<String>? log) {
    final cl = comp.requireLayer(cutTo);
    final kids = _children(comp);
    final keep = {for (final l in _subtree(cl, kids)) l.id};
    final fd = comp.frameDuration;
    for (final l in comp.layers) {
      if (keep.contains(l.id) || !l.is3D || l.type == LayerType.audio) continue;
      if (l.start < end - 1e-6 && l.end > end + 1e-6) l.duration = math.max(fd, end - l.start);
    }
    // The cut-to shot is shown flat (the camera is inside the door by now).
    if (cl.is3D) {
      final z0 = homeZoom(comp);
      if (cl.parentId == null) {
        final z = cl.prop(Props.position).valueAt(end)[2];
        final k = (z + z0) / z0;
        if (k > 1e-3) {
          final cx = comp.width / 2, cy = comp.height / 2;
          _mapProp(cl.prop(Props.position), (v) => [cx + (v[0] - cx) / k, cy + (v[1] - cy) / k, 0]);
          _mapProp(cl.prop(Props.scale), (v) => [v[0] / k, v[1] / k, v[2]]);
          _scalePath(cl, 1 / k);
        }
      }
      for (final id in keep) {
        final l = comp.layerById(id)!;
        l.is3D = false;
        if (l.id != cl.id) _mapProp(l.prop(Props.position), (v) => [v[0], v[1], 0]);
      }
    }
    if (cl.start < end - 1e-6) {
      final dt = end - cl.start;
      if (dt < cl.duration - fd) {
        cl.sourceIn += dt * cl.speed;
        cl.duration -= dt;
        cl.start = end;
      }
    }
    cl.visible = true;
    final fid = comp.layerById('${cutTo}_flash') == null ? '${cutTo}_flash' : Ids.next('flash');
    final st = math.max(0.0, end - 0.12);
    final flash = Layer(
      id: fid,
      name: 'Flash',
      type: LayerType.solid,
      start: st,
      duration: end + 0.33 - st,
      width: comp.width,
      height: comp.height,
      color: 0xFFFFFFFF,
    );
    flash.prop(Props.position).staticValue = [comp.width / 2, comp.height / 2, 0];
    final op = flash.prop(Props.opacity);
    op.setKeyframe(st, [0], easing: Easing.easeIn);
    op.setKeyframe(end, [100], easing: Easing.easeOut);
    op.setKeyframe(end + 0.3, [0], easing: Easing.linear);
    comp.layers.insert(0, flash);
    if (comp.duration < flash.end) comp.duration = flash.end;
    log?.add('Cut to ${cl.name} at ${end.toStringAsFixed(2)} s');
    return [fid];
  }

  // ------------------------------------------------------------------ pins

  /// Keeps [l] the same size on screen while its parent map [of] zooms:
  /// its scale is the inverse of the map's (sampled between [a] and [b]).
  static void counterScale(Composition comp, Layer l, Layer of, double a, double b) {
    final sp = of.prop(Props.scale);
    final p = l.prop(Props.scale);
    List<double> inv(double t) {
      final s = math.max(1e-3, sp.valueAt(t)[0].abs());
      return [1e4 / s, 1e4 / s, 100];
    }

    p.keyframes.clear();
    if (!sp.isAnimated) {
      p.staticValue = inv(a);
      return;
    }
    final times = <double>{a, b};
    for (final k in sp.keyframes) {
      if (k.time > a && k.time < b) times.add(k.time);
    }
    // Every frame while the map zooms (1/scale is not linear in time).
    final z0 = math.max(a, sp.keyframes.first.time), z1 = math.min(b, sp.keyframes.last.time);
    final fd = comp.frameDuration;
    for (var t = z0 + fd; t < z1 - 1e-6 && times.length < 2000; t += fd) {
      times.add(t);
    }
    for (final t in times.toList()..sort()) {
      p.setKeyframe(t, inv(t), easing: Easing.linear);
    }
  }
}

class _RootInfo {
  final Layer root;
  final List<Layer> sub;
  final String band;
  double depth = 0;
  _RootInfo(this.root, this.sub, this.band);
}

class _Key {
  final double u;
  final Vector3 pos, poi;
  _Key(this.u, this.pos, this.poi);
}

/// Saved shots (camera + 3D arrangement) and recipes (a layer's move,
/// transition, atmosphere, look and frame), stored by name in the project.
class SceneStore {
  static Map<String, dynamic> _json(Object o) => Map<String, dynamic>.from(jsonDecode(jsonEncode(o)) as Map);

  static Map<String, dynamic> _rel(AnimProp a, double t0, {double? from, double? to}) {
    final c = a.copy();
    if (from != null && to != null) {
      c.keyframes.removeWhere((k) => k.time < from - kTimeEpsilon || k.time > to + kTimeEpsilon);
      if (c.keyframes.isEmpty) c.staticValue = a.valueAt(from);
    }
    c.shift(-t0);
    return c.toJson();
  }

  static AnimProp _abs(dynamic j, double t) =>
      AnimProp.fromJson(Map<String, dynamic>.from(j as Map))..shift(t);

  // --------------------------------------------------------------- shots

  static void saveShot(Project p, String name, {double? from, double? to}) {
    if (name.trim().isEmpty) throw ArgumentError('save_shot needs a "name"');
    final comp = p.editComp;
    final times = comp.camera.allKeyframeTimes();
    final t0 = from ?? (times.isEmpty ? 0.0 : times.first);
    final t1 = math.max(t0, to ?? (times.isEmpty ? t0 : times.last));
    final cam = <String, dynamic>{
      for (final k in CamProps.threeDProps)
        if (comp.camera.props[k] != null) k: _rel(comp.camera.props[k]!, t0, from: t0, to: t1),
    };
    final layers = <String, dynamic>{};
    for (final l in comp.layers) {
      if (!l.is3D) continue;
      if (l.end < t0 - 1e-6 || l.start > t1 + 1e-6) continue;
      layers[l.id] = {
        'name': l.name,
        if (l.parentId != null) 'parent': l.parentId,
        'props': {for (final k in [Props.position, Props.scale, Props.rotation, Props.anchor]) k: _rel(l.prop(k), t0)},
      };
    }
    p.shots[name] = _json({
      'mode': comp.camera.mode.name,
      'span': t1 - t0,
      'camera': cam,
      'layers': layers,
      if (comp.motionBlur) 'motionBlur': true,
    });
  }

  /// Re-applies a saved shot at [start]. [map] renames saved layer ids
  /// (saved id → layer in this comp). Returns how many layers were placed.
  static int loadShot(Project p, String name, {required double start, Map<String, String> map = const {}, List<String>? log}) {
    final s = p.shots[name];
    if (s is! Map) {
      throw ArgumentError('No shot "$name". Saved shots: ${p.shots.keys.isEmpty ? '(none)' : p.shots.keys.join(', ')}');
    }
    final comp = p.editComp;
    final rig = comp.camera;
    final span = (s['span'] as num? ?? 0).toDouble();
    final mode = CameraMode.values.firstWhere((m) => m.name == s['mode'], orElse: () => CameraMode.threeD);
    if (mode == CameraMode.threeD && rig.mode != CameraMode.threeD) Scene3D.homeCamera(comp, start);
    rig.mode = mode;
    final cam = s['camera'];
    if (cam is Map) {
      for (final e in cam.entries) {
        final cur = rig.props['${e.key}'];
        if (cur == null) continue;
        final sv = _abs(e.value, start);
        if (sv.keyframes.isEmpty) {
          if (cur.isAnimated) {
            Scene3D.cutKey(cur, start, sv.staticValue, comp.frameDuration);
          } else {
            cur.staticValue = List.of(sv.staticValue);
          }
          continue;
        }
        Scene3D.clearRange(cur, start, start + span);
        for (int i = 0; i < sv.keyframes.length; i++) {
          final k = sv.keyframes[i];
          if (i == 0) {
            Scene3D.cutKey(cur, k.time, k.value, comp.frameDuration, easing: k.easing);
          } else {
            cur.setKeyframe(k.time, k.value, easing: k.easing);
          }
        }
      }
    }
    var placed = 0;
    final ls = s['layers'];
    if (ls is Map) {
      for (final e in ls.entries) {
        final id = map['${e.key}'] ?? '${e.key}';
        final l = comp.layerById(id);
        final props = e.value is Map ? (e.value as Map)['props'] : null;
        if (l == null || props is! Map) continue;
        l.is3D = true;
        for (final pe in props.entries) {
          final key = '${pe.key}';
          final cur = l.props[key];
          final v = _abs(pe.value, start);
          if (cur == null || cur.dims != v.dims) continue;
          l.props[key] = v;
        }
        placed++;
      }
      if (placed < ls.length) log?.add('load_shot: ${ls.length - placed} saved layer(s) are not in this comp (give "layers": {saved: new})');
    }
    if (s['motionBlur'] == true) comp.motionBlur = true;
    final end = start + span;
    if (comp.duration < end) comp.duration = end;
    return placed;
  }

  // -------------------------------------------------------------- recipes

  static const _moveProps = [Props.position, Props.scale, Props.rotation, Props.opacity];

  static void saveRecipe(Project p, String name, Layer l) {
    if (name.trim().isEmpty) throw ArgumentError('save_recipe needs a "name"');
    final t0 = l.start;
    final props = <String, dynamic>{};
    for (final k in _moveProps) {
      final a = l.props[k];
      if (a == null || !a.isAnimated) continue;
      final base = a.valueAt(t0);
      final mode = k == Props.opacity
          ? 'abs'
          : k == Props.scale
              ? (base.every((v) => v.abs() > 1e-6) ? 'ratio' : 'abs')
              : 'delta';
      props[k] = {
        'mode': mode,
        'keys': [
          for (final kf in a.keyframes)
            {
              't': kf.time - t0,
              'v': [
                for (int i = 0; i < kf.value.length; i++)
                  mode == 'delta' ? kf.value[i] - base[i] : (mode == 'ratio' ? kf.value[i] / base[i] : kf.value[i]),
              ],
              'e': kf.easing.toJson(),
            },
        ],
      };
    }
    final fx = <dynamic>[];
    for (final e in l.effects) {
      final c = e.copy();
      for (final ap in c.params.values) {
        ap.shift(-t0);
      }
      fx.add(c.toJson());
    }
    final masks = <dynamic>[];
    for (final m in l.masks) {
      final c = m.copy();
      for (final ap in c.props.values) {
        ap.shift(-t0);
      }
      masks.add(c.toJson());
    }
    p.recipes[name] = _json({
      'source': l.name,
      'w': l.width,
      'h': l.height,
      'props': props,
      'effects': fx,
      'masks': masks,
      'blend': l.blendMode,
      if (l.text != null) 'animator': l.text!.animator,
      if (l.text != null) 'animDuration': l.text!.animDuration,
    });
  }

  static void applyRecipe(Project p, String name, Layer l, {double? start}) {
    final r = p.recipes[name];
    if (r is! Map) {
      throw ArgumentError('No recipe "$name". Recipes: ${p.recipes.keys.isEmpty ? '(none)' : p.recipes.keys.join(', ')}');
    }
    final t = start ?? l.start;
    final props = r['props'];
    if (props is Map) {
      for (final pe in props.entries) {
        final a = l.props['${pe.key}'];
        final spec = pe.value;
        if (a == null || spec is! Map || spec['keys'] is! List) continue;
        final mode = '${spec['mode']}';
        final keys = spec['keys'] as List;
        if (keys.isEmpty) continue;
        final base = a.valueAt(t);
        final span = ((keys.last as Map)['t'] as num).toDouble();
        Scene3D.clearRange(a, t, t + span);
        for (final kv in keys) {
          final k = Map<String, dynamic>.from(kv as Map);
          final vals = [for (final v in k['v'] as List) (v as num).toDouble()];
          final out = List<double>.generate(a.dims, (i) {
            final v = i < vals.length ? vals[i] : (mode == 'ratio' ? 1.0 : (mode == 'delta' ? 0.0 : base[i]));
            return switch (mode) {
              'delta' => base[i] + v,
              'ratio' => base[i] * v,
              _ => v,
            };
          });
          a.setKeyframe(t + (k['t'] as num).toDouble(), out, easing: Easing.fromJson(k['e']));
        }
      }
    }
    final fx = r['effects'];
    if (fx is List) {
      for (final j in fx) {
        final e = Effect.fromJson(Map<String, dynamic>.from(j as Map));
        e.id = Ids.next('fx');
        for (final ap in e.params.values) {
          ap.shift(t);
        }
        l.effects.removeWhere((x) => x.type == e.type);
        l.effects.add(e);
      }
    }
    final masks = r['masks'];
    if (masks is List && masks.isNotEmpty) {
      final rw = (r['w'] as num? ?? l.width).toDouble(), rh = (r['h'] as num? ?? l.height).toDouble();
      final kx = rw > 0 ? l.width / rw : 1.0, ky = rh > 0 ? l.height / rh : 1.0;
      l.masks.clear();
      for (final j in masks) {
        final m = Mask.fromJson(Map<String, dynamic>.from(j as Map));
        m.id = Ids.next('mask');
        for (final e in m.props.entries) {
          e.value.shift(t);
          if (e.key == 'center' || e.key == 'size') {
            Scene3D._mapProp(e.value, (v) => [v[0] * kx, if (v.length > 1) v[1] * ky, ...v.skip(2)]);
          }
        }
        l.masks.add(m);
      }
    }
    if (r['blend'] is String) l.blendMode = r['blend'] as String;
    final anim = r['animator'];
    if (l.text != null && anim is String && TextAnimators.all.contains(anim)) {
      l.text!.animator = anim;
      if (r['animDuration'] is num) l.text!.animDuration = (r['animDuration'] as num).toDouble();
    }
  }

  static bool deleteRecipe(Project p, String name) => p.recipes.remove(name) != null;
}
