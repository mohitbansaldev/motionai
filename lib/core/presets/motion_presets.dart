import 'dart:math' as math;

import '../model/anim_prop.dart';
import '../model/easing.dart';
import '../model/effects_catalog.dart';
import '../model/layer.dart';
import '../model/project.dart';

/// Layer in/out animations (transitions) and one-tap looks (styles).
class MotionPresets {
  static const transitions = [
    'fade', 'zoom_in', 'zoom_out', 'slide_left', 'slide_right', 'slide_up', 'slide_down',
    'blur', 'spin', 'pop', 'whip', 'shatter',
  ];

  static String transitionLabel(String t) => const {
        'fade': 'Fade',
        'zoom_in': 'Zoom In',
        'zoom_out': 'Zoom Out',
        'slide_left': 'Slide Left',
        'slide_right': 'Slide Right',
        'slide_up': 'Slide Up',
        'slide_down': 'Slide Down',
        'blur': 'Blur',
        'spin': 'Spin',
        'pop': 'Pop',
        'whip': 'Whip Pan',
        'shatter': 'Shatter',
      }[t] ??
      t;

  /// Animates [layer] in at its start (isIn) or out at its end.
  static void animate(Composition comp, Layer layer, String preset, {required bool isIn, double duration = 0.6}) {
    if (!transitions.contains(preset)) {
      throw ArgumentError('Unknown transition "$preset". Available: ${transitions.join(', ')}');
    }
    final d = math.min(duration, layer.duration / 2).clamp(comp.frameDuration, 10.0);
    final tA = isIn ? layer.start : layer.end - d; // animation start
    final tB = isIn ? layer.start + d : layer.end - comp.frameDuration; // animation end

    // "Rest" values = value at the inner end of the animation.
    final restT = isIn ? tB : tA;
    final ease = isIn ? Easing.easeOut : Easing.easeIn;

    void anim(String key, List<double> Function(List<double> rest) offValue, [Easing? e]) {
      final p = layer.prop(key);
      final rest = p.valueAt(restT);
      final off = offValue(List.of(rest));
      if (isIn) {
        p.setKeyframe(tA, off, easing: e ?? ease);
        p.setKeyframe(tB, rest);
      } else {
        p.setKeyframe(tA, rest, easing: e ?? ease);
        p.setKeyframe(tB, off);
      }
    }

    final w = comp.width, h = comp.height;
    switch (preset) {
      case 'fade':
        anim(Props.opacity, (r) => [0]);
        break;
      case 'zoom_in':
        anim(Props.scale, (r) => [r[0] * 0.6, r[1] * 0.6, r[2]]);
        anim(Props.opacity, (r) => [0]);
        break;
      case 'zoom_out':
        anim(Props.scale, (r) => [r[0] * 1.5, r[1] * 1.5, r[2]]);
        anim(Props.opacity, (r) => [0]);
        break;
      case 'slide_left':
        anim(Props.position, (r) => [r[0] + (isIn ? w : -w), r[1], r[2]]);
        break;
      case 'slide_right':
        anim(Props.position, (r) => [r[0] + (isIn ? -w : w), r[1], r[2]]);
        break;
      case 'slide_up':
        anim(Props.position, (r) => [r[0], r[1] + (isIn ? h : -h), r[2]]);
        break;
      case 'slide_down':
        anim(Props.position, (r) => [r[0], r[1] + (isIn ? -h : h), r[2]]);
        break;
      case 'spin':
        anim(Props.rotation, (r) => [r[0], r[1], r[2] + (isIn ? -180 : 180)]);
        anim(Props.scale, (r) => [0, 0, r[2]]);
        break;
      case 'pop':
        anim(Props.scale, (r) => [0, 0, r[2]], isIn ? Easing.back : Easing.easeIn);
        break;
      case 'shatter':
        final sid = '${layer.id}_${isIn ? 'in' : 'out'}_shatter';
        layer.effects.removeWhere((e) => e.id == sid);
        final sfx = EffectsCatalog.create('shatter', sid);
        final prog = sfx.params['progress']!;
        if (isIn) {
          prog.setKeyframe(tA, [100], easing: Easing.easeOut);
          prog.setKeyframe(tB, [0]);
        } else {
          prog.setKeyframe(tA, [0], easing: Easing.easeOut);
          prog.setKeyframe(tB, [100]);
        }
        layer.effects.add(sfx);
        break;
      case 'blur':
      case 'whip':
        final fxId = '${layer.id}_${isIn ? 'in' : 'out'}_blur';
        layer.effects.removeWhere((e) => e.id == fxId);
        final fx = EffectsCatalog.create('blur', fxId);
        final amount = fx.params['amount']!..staticValue = [0];
        final strong = preset == 'whip' ? 60.0 : 40.0;
        if (isIn) {
          amount.setKeyframe(tA, [strong], easing: ease);
          amount.setKeyframe(tB, [0]);
        } else {
          amount.setKeyframe(tA, [0], easing: ease);
          amount.setKeyframe(tB, [strong]);
        }
        layer.effects.add(fx);
        if (preset == 'whip') {
          anim(Props.position, (r) => [r[0] + (isIn ? w * 0.6 : -w * 0.6), r[1], r[2]], Easing(isIn ? EaseType.easeOut : EaseType.easeIn));
        } else {
          anim(Props.opacity, (r) => [0]);
        }
        break;
    }
  }

  // ------------------------------------------------------------- styles

  static const styles = ['cinematic_doc', 'shorts_punch', 'retro_film', 'noir', 'warm_travel', 'clean_minimal'];

  static String styleLabel(String s) => const {
        'cinematic_doc': 'Cinematic Doc',
        'shorts_punch': 'Shorts Punch',
        'retro_film': 'Retro Film',
        'noir': 'Noir',
        'warm_travel': 'Warm Travel',
        'clean_minimal': 'Clean Minimal',
      }[s] ??
      s;

  /// Applies a look to visual media layers (video/image) and returns a log.
  static List<String> applyStyle(Composition comp, String style, {List<String>? layerIds}) {
    if (!styles.contains(style)) {
      throw ArgumentError('Unknown style "$style". Available: ${styles.join(', ')}');
    }
    final targets = comp.layers
        .where((l) => (layerIds == null || layerIds.contains(l.id)) &&
            (l.type == LayerType.video || l.type == LayerType.image))
        .toList();
    if (targets.isEmpty) throw ArgumentError('apply_style needs at least one video or image layer');

    final look = switch (style) {
      'cinematic_doc' => {'color': [0.0, 18.0, -25.0], 'tint': [70.0, 130.0, 160.0, 12.0], 'vignette': 65.0, 'grain': 18.0, 'letterbox': 11.0},
      'shorts_punch' => {'color': [6.0, 25.0, 25.0], 'vignette': 25.0},
      'retro_film' => {'color': [4.0, -10.0, -30.0], 'tint': [255.0, 180.0, 90.0, 30.0], 'vignette': 55.0, 'grain': 45.0, 'light_leak': 40.0},
      'noir' => {'color': [-5.0, 35.0, -100.0], 'vignette': 75.0, 'grain': 30.0, 'letterbox': 11.0},
      'warm_travel' => {'color': [8.0, 10.0, 12.0], 'tint': [255.0, 170.0, 80.0, 20.0], 'vignette': 30.0, 'light_leak': 25.0},
      _ => {'color': [5.0, 5.0, -5.0]},
    };

    for (final l in targets) {
      // Remove previous style effects so styles can be swapped.
      l.effects.removeWhere((e) => e.id.startsWith('${l.id}_style_'));
      void add(String type, Map<String, List<double>> params) {
        final fx = EffectsCatalog.create(type, '${l.id}_style_$type');
        params.forEach((k, v) => fx.params[k]!.staticValue = v);
        l.effects.add(fx);
      }

      final c = look['color'] as List<double>?;
      if (c != null) add('color', {'brightness': [c[0]], 'contrast': [c[1]], 'saturation': [c[2]]});
      final t = look['tint'] as List<double>?;
      if (t != null) add('tint', {'color': [t[0], t[1], t[2]], 'amount': [t[3]]});
      final v = look['vignette'] as double?;
      if (v != null) add('vignette', {'amount': [v]});
      final g = look['grain'] as double?;
      if (g != null) add('grain', {'amount': [g]});
      final ll = look['light_leak'] as double?;
      if (ll != null) add('light_leak', {'amount': [ll]});
      final lb = look['letterbox'] as double?;
      if (lb != null) add('letterbox', {'amount': [lb]});
    }
    return ['Applied ${styleLabel(style)} to ${targets.length} layer(s)'];
  }

  /// Default mask props for a layer.
  static Mask newMask(Layer l, String id, {String shape = 'ellipse', bool invert = false}) => Mask(
        id: id,
        shape: shape,
        invert: invert,
        props: {
          'center': AnimProp([l.width / 2, l.height / 2]),
          'size': AnimProp([l.width * 0.6, l.height * 0.6]),
          'feather': AnimProp([40]),
        },
      );
}
