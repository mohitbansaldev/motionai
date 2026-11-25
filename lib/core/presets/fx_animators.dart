import 'dart:math' as math;

import '../model/anim_prop.dart';
import '../model/easing.dart';
import '../model/effects_catalog.dart';
import '../model/layer.dart';
import '../model/project.dart';

/// V3-D: character / presenter animators for `animate_in` / `animate_out`:
///
///   punch_in    — enters at 150% blurred and snaps to 100% (0.25 s, expo-out);
///                 the presenter-return punch.
///   swing_in    — swings in from `rotation` (20°) and `scale_from` (2.5×)
///                 with motion blur; `background`: layer id that goes blurred
///                 → sharp at the same time.
///   exposure_in — sun-glare entry: over-exposed (`from` 3.0) with bloom,
///                 settling to normal.
///
/// Out variants play the same move backwards. Every key is eased.
class FxAnimators {
  static const presets = ['punch_in', 'swing_in', 'exposure_in'];

  static bool handles(String preset) => presets.contains(preset);

  static const _expoOut = Easing.bezierCurve(0.16, 1, 0.3, 1);
  static const _outCubic = Easing.bezierCurve(0.33, 1, 0.68, 1);
  static const _inCubic = Easing.bezierCurve(0.32, 0, 0.67, 0);

  static double? _num(Map<String, dynamic>? c, String k) {
    final v = c?[k];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    throw ArgumentError('$k must be a number');
  }

  /// Default length of each preset (s).
  static double defaultDuration(String preset) => switch (preset) { 'punch_in' => 0.25, 'swing_in' => 0.6, _ => 0.75 };

  /// Animates [l] with [preset]. [duration] null = the preset default.
  /// [c] holds extra params (rotation, scale_from, background, from, color).
  static void animate(Composition comp, Layer l, String preset, {required bool isIn, double? duration, Map<String, dynamic>? c}) {
    if (!handles(preset)) throw ArgumentError('Unknown animator "$preset". Available: ${presets.join(', ')}');
    final fr = comp.frameDuration;
    final d = math.min(duration ?? defaultDuration(preset), l.duration / 2).clamp(fr * 2, 10.0).toDouble();
    final tA = isIn ? l.start : l.end - d;
    final tB = isIn ? l.start + d : l.end - fr;
    final rest = isIn ? tB : tA;
    // (time, value) pairs from the "off" end to the rest end, eased toward rest.
    void prop(String key, List<double> Function(List<double> r) off, Easing e) {
      final p = l.prop(key);
      final r = p.valueAt(rest);
      p.keyframes.removeWhere((k) => k.time >= tA - kTimeEpsilon && k.time <= tB + kTimeEpsilon);
      if (isIn) {
        p.setKeyframe(tA, off(List.of(r)), easing: e);
        p.setKeyframe(tB, r, easing: e);
      } else {
        p.setKeyframe(tA, r, easing: _reverse(e));
        p.setKeyframe(tB, off(List.of(r)), easing: _reverse(e));
      }
    }

    Effect effect(String type, String tag) {
      final id = '${l.id}_${isIn ? 'in' : 'out'}_$tag';
      l.effects.removeWhere((x) => x.id == id);
      final e = EffectsCatalog.create(type, id);
      l.effects.add(e);
      return e;
    }

    void param(AnimProp p, double off, double restV, Easing e) {
      if (isIn) {
        p.setKeyframe(tA, [off], easing: e);
        p.setKeyframe(tB, [restV], easing: e);
      } else {
        p.setKeyframe(tA, [restV], easing: _reverse(e));
        p.setKeyframe(tB, [off], easing: _reverse(e));
      }
    }

    switch (preset) {
      case 'punch_in':
        prop(Props.scale, (r) => [r[0] * 1.5, r[1] * 1.5, r[2]], _expoOut);
        param(effect('blur', 'punch').params['amount']!..staticValue = [0], 40, 0, _expoOut);
        effect('motion_blur', 'punch_mb').params['amount']!.staticValue = [100];
      case 'swing_in':
        final rot = _num(c, 'rotation') ?? 20;
        final sc = (_num(c, 'scale_from') ?? 2.5).clamp(0.05, 10.0);
        prop(Props.rotation, (r) => [r[0], r[1], r[2] + rot], _expoOut);
        prop(Props.scale, (r) => [r[0] * sc, r[1] * sc, r[2]], _expoOut);
        param(effect('blur', 'swing').params['amount']!..staticValue = [0], 30, 0, _expoOut);
        prop(Props.opacity, (r) => [0], _outCubic);
        effect('motion_blur', 'swing_mb').params['amount']!.staticValue = [100];
        final bgId = c?['background'];
        if (bgId is String && bgId != l.id) {
          final bg = comp.layerById(bgId);
          if (bg == null) throw ArgumentError('swing_in background: no layer "$bgId"');
          final id = '${bg.id}_${isIn ? 'in' : 'out'}_swingbg';
          bg.effects.removeWhere((x) => x.id == id);
          final e = EffectsCatalog.create('blur', id);
          final amt = e.params['amount']!..staticValue = [0];
          if (isIn) {
            amt.setKeyframe(tA, [24], easing: _outCubic);
            amt.setKeyframe(tB, [0], easing: _outCubic);
          } else {
            amt.setKeyframe(tA, [0], easing: _inCubic);
            amt.setKeyframe(tB, [24], easing: _inCubic);
          }
          bg.effects.add(e);
        }
      case 'exposure_in':
        final from = (_num(c, 'from') ?? 3.0).clamp(1.0, 8.0);
        final f = ((from - 1) / 2.2).clamp(0.0, 1.0) * 100;
        final col = c?['color'] is String ? (EffectsCatalog.paramValues('flash', 'color', c!['color']) ?? const [255.0, 241.0, 214.0]) : const [255.0, 241.0, 214.0];
        final fl = effect('flash', 'exposure');
        fl.params['color']!.staticValue = List.of(col);
        param(fl.params['amount']!, f, 0, _outCubic);
        final bl = effect('bloom', 'exposure_bloom');
        bl.params['threshold']!.staticValue = [35];
        bl.params['radius']!.staticValue = [60];
        param(bl.params['amount']!, 95, 0, _outCubic);
        final rays = effect('light_rays', 'exposure_rays');
        rays.params['color']!.staticValue = List.of(col);
        rays.params['angle']!.staticValue = [120];
        param(rays.params['amount']!, 80, 0, _outCubic);
    }
  }

  /// The mirror of an ease (for out animations).
  static Easing _reverse(Easing e) {
    if (e.type != EaseType.bezier) return e;
    return Easing.bezierCurve(1 - e.x2, 1 - e.y2, 1 - e.x1, 1 - e.y1);
  }
}
