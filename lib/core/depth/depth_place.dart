// V2-E (Depth from photo): places the layers of a split photo exactly over
// the original layer and pushes each to its depth ("compose flat, play
// deep", same projection maths as make_3d in lib/core/presets/scene3d.dart).
//
// With the home 3D camera at C = (w/2, h/2, −zoom) a homothety about C by
// a factor k (position p → C + (p − C)·k, scale ×k) leaves a layer's picture
// unchanged on screen, so the first frame is identical to the flat photo.
import 'dart:math' as math;

import '../model/anim_prop.dart';
import '../model/effects_catalog.dart';
import '../model/layer.dart';

class DepthPlace {
  /// Camera distance of each layer in units of the home camera distance,
  /// from the mean depth of its slice (0 far … 1 near). Inverse depth is
  /// linear in [depths]; [intensity] 0..1 sets how deep the scene is
  /// (0.5: far ≈ 2.75×, near ≈ 0.63×). Strictly decreasing far → near.
  static List<double> factors(List<double> depths, {double intensity = 0.5}) {
    final i = intensity.clamp(0.0, 1.0);
    final far = 1 + 3.5 * i, near = 1 / (1 + 1.2 * i);
    final dMin = 1 / far, dMax = 1 / near;
    final out = <double>[];
    for (final m in depths) {
      var f = 1 / (dMin + m.clamp(0.0, 1.0) * (dMax - dMin));
      if (out.isNotEmpty) f = math.min(f, out.last * 0.97);
      out.add(math.max(f, 0.25));
    }
    return out;
  }

  static void mapProp(AnimProp p, List<double> Function(List<double>) f) {
    p.staticValue = f(p.staticValue);
    for (final k in p.keyframes) {
      k.value = f(k.value);
    }
  }

  /// Effects that act per pixel and so look the same split over layers;
  /// frame-wide looks (vignette, grain, letterbox, …) stay on the far layer
  /// only so they aren't stacked N times.
  static bool perPixelEffect(String type) {
    if (type == 'blur') return true;
    final cat = EffectsCatalog.byType(type)?.category;
    return cat == 'color' || cat == 'keying';
  }

  /// A copy of [src] showing a [width]×[height] image whose pixel (u, v)
  /// is the source photo's pixel (x + k·u, y + k·v): same timing, transform,
  /// effects and masks, re-expressed so it lands exactly over [src].
  static Layer overlay(Layer src,
      {required String id,
      required String mediaId,
      required double width,
      required double height,
      required double x,
      required double y,
      double k = 1,
      bool keepAllEffects = true}) {
    final l = src.copy(newId: id);
    l.type = LayerType.image;
    l.mediaId = mediaId;
    l.width = width;
    l.height = height;
    mapProp(l.prop(Props.anchor), (a) => [(a[0] - x) / k, (a[1] - y) / k, a.length > 2 ? a[2] : 0]);
    mapProp(l.prop(Props.scale), (s) => [s[0] * k, s[1] * k, s.length > 2 ? s[2] : 100]);
    for (final m in l.masks) {
      final c = m.props['center'];
      if (c != null) mapProp(c, (v) => [(v[0] - x) / k, (v[1] - y) / k]);
      final s = m.props['size'];
      if (s != null) mapProp(s, (v) => [for (final e in v) e / k]);
      final f = m.props['feather'];
      if (f != null) mapProp(f, (v) => [for (final e in v) e / k]);
    }
    if (!keepAllEffects) l.effects.removeWhere((e) => !perPixelEffect(e.type));
    return l;
  }

  /// A 2D layer's ignored 3D values (X/Y rotation, anchor Z) are zeroed
  /// before it becomes 3D, so it looks the same.
  static void flatten(Layer l) {
    mapProp(l.prop(Props.rotation), (v) => [0, 0, v[2]]);
    mapProp(l.prop(Props.anchor), (v) => [v[0], v[1], 0]);
    mapProp(l.prop(Props.position), (v) => [v[0], v[1], 0]);
  }

  /// Homothety of an unparented layer about the home camera
  /// (cx, cy, −z0) by [k]: the picture stays the same, the layer moves to
  /// k × its camera distance. A 2D layer becomes 3D (flattened first).
  static void pushTo(Layer l, double k, double cx, double cy, double z0) {
    if (!l.is3D) flatten(l);
    l.is3D = true;
    mapProp(l.prop(Props.position), (v) => [cx + (v[0] - cx) * k, cy + (v[1] - cy) * k, -z0 + ((v.length > 2 ? v[2] : 0) + z0) * k]);
    mapProp(l.prop(Props.scale), (v) => [v[0] * k, v[1] * k, v.length > 2 ? v[2] : 100]);
    final path = l.path;
    if (path != null && (k - 1).abs() > 1e-12) {
      l.path = MotionPath(points: [for (final p in path.points) [p[0] * k, p[1] * k]], smooth: path.smooth, orient: path.orient);
    }
  }

  /// Layer names for [n] depth layers, far first.
  static List<String> labels(int n) => switch (n) {
        2 => const ['far', 'near'],
        3 => const ['far', 'mid', 'front'],
        4 => const ['far', 'mid', 'near', 'front'],
        5 => const ['sky', 'far', 'mid', 'near', 'front'],
        _ => [for (var i = 0; i < n; i++) i == 0 ? 'sky' : (i == n - 1 ? 'front' : 'depth $i')],
      };
}
