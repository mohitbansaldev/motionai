import 'anim_prop.dart';
import 'layer.dart';

class ParamDef {
  final String key;
  final String label;
  final List<double> defaultValue;
  final double min;
  final double max;
  const ParamDef(this.key, this.label, this.defaultValue, this.min, this.max);
}

class EffectDef {
  final String type;
  final String label;
  final List<ParamDef> params;
  const EffectDef(this.type, this.label, this.params);
}

/// Effects available in the editor. Each one is implemented by the
/// preview renderer (lib/ui/preview/layer_view.dart). The native engine
/// (milestone 2) will add glow, light leaks, displacement, particles...
class EffectsCatalog {
  static const List<EffectDef> all = [
    EffectDef('blur', 'Gaussian Blur', [
      ParamDef('amount', 'Blurriness', [10], 0, 100),
    ]),
    EffectDef('color', 'Color Adjust', [
      ParamDef('brightness', 'Brightness', [0], -100, 100),
      ParamDef('contrast', 'Contrast', [0], -100, 100),
      ParamDef('saturation', 'Saturation', [0], -100, 100),
    ]),
    EffectDef('tint', 'Tint', [
      ParamDef('color', 'Color (R,G,B)', [255, 170, 80], 0, 255),
      ParamDef('amount', 'Amount', [50], 0, 100),
    ]),
    EffectDef('vignette', 'Vignette', [
      ParamDef('amount', 'Amount', [60], 0, 100),
      ParamDef('size', 'Size', [60], 0, 100),
    ]),
    EffectDef('glow', 'Glow', [
      ParamDef('amount', 'Intensity', [50], 0, 100),
      ParamDef('radius', 'Radius', [20], 1, 100),
    ]),
    EffectDef('grain', 'Film Grain', [
      ParamDef('amount', 'Amount', [25], 0, 100),
      ParamDef('size', 'Size', [2], 1, 8),
    ]),
    EffectDef('light_leak', 'Light Leak', [
      ParamDef('amount', 'Amount', [45], 0, 100),
      ParamDef('speed', 'Speed', [1], 0, 5),
    ]),
    EffectDef('gradient', 'Gradient Overlay', [
      ParamDef('amount', 'Darken bottom', [60], 0, 100),
      ParamDef('top', 'Darken top', [0], 0, 100),
    ]),
    EffectDef('letterbox', 'Letterbox', [
      ParamDef('amount', 'Bar size %', [12], 0, 40),
    ]),
    EffectDef('outline', 'Outline Stroke', [
      ParamDef('width', 'Width', [8], 0, 60),
      ParamDef('color', 'Color (R,G,B)', [255, 214, 0], 0, 255),
    ]),
    EffectDef('shadow', 'Drop Shadow', [
      ParamDef('distance', 'Distance', [14], 0, 200),
      ParamDef('angle', 'Angle', [60], 0, 360),
      ParamDef('blur', 'Softness', [12], 0, 80),
      ParamDef('opacity', 'Opacity', [55], 0, 100),
    ]),
    EffectDef('dust', 'Dust Particles', [
      ParamDef('amount', 'Amount', [40], 0, 100),
      ParamDef('size', 'Size', [2], 0.5, 8),
    ]),
    EffectDef('shatter', 'Shatter', [
      ParamDef('progress', 'Progress', [0], 0, 100),
      ParamDef('color', 'Shard color (R,G,B)', [255, 200, 40], 0, 255),
    ]),
    EffectDef('paper', 'Paper Texture', [
      ParamDef('amount', 'Amount', [60], 0, 100),
    ]),
    EffectDef('grunge', 'Grunge Texture', [
      ParamDef('amount', 'Amount', [60], 0, 100),
    ]),
    EffectDef('flicker', 'Light Flicker', [
      ParamDef('amount', 'Amount', [30], 0, 100),
    ]),
  ];

  static EffectDef? byType(String type) {
    for (final e in all) {
      if (e.type == type) return e;
    }
    return null;
  }

  static Effect create(String type, String id) {
    final def = byType(type);
    if (def == null) {
      throw ArgumentError('Unknown effect "$type". Available: ${all.map((e) => e.type).join(', ')}');
    }
    return Effect(
      id: id,
      type: type,
      params: {for (final p in def.params) p.key: AnimProp(p.defaultValue)},
    );
  }
}
