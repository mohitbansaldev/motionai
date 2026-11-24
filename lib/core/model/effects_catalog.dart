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

/// Effects available in milestone 1. Each one is implemented by the
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
