import '../engine/chroma.dart' show kChromaNamedColors; // CHROMA (Agent M)
import 'anim_prop.dart';
import 'layer.dart';

class ParamDef {
  final String key;
  final String label;
  final List<double> defaultValue;
  final double min;
  final double max;

  /// Named choices: the value is the index into this list (e.g. particle kind).
  final List<String> options;

  /// An (R,G,B) colour 0..255. Commands may also pass "#RRGGBB".
  final bool color;
  const ParamDef(this.key, this.label, this.defaultValue, this.min, this.max, {this.options = const [], this.color = false});

  /// Option name for a stored value (index), or null when not a choice param.
  String? optionOf(double v) => options.isEmpty ? null : options[v.round().clamp(0, options.length - 1)];
}

class EffectDef {
  final String type;
  final String label;
  final List<ParamDef> params;

  /// Grouping in the Effects panel: keying | color | stylize | distort | atmosphere | reveal | blur.
  final String category;
  const EffectDef(this.type, this.label, this.params, {this.category = 'stylize'});
}

/// Particle kinds for the `particles` effect (stored as an index).
const List<String> kParticleKinds = [
  'confetti', 'leaves', 'stars', 'rain', 'snow', 'smoke', 'dust', 'bokeh', 'streaks', 'birds', 'clouds',
];

/// Effects available in the editor. Each one is implemented by the
/// preview renderer (lib/ui/preview/layer_view.dart and lib/ui/preview/fx/).
class EffectsCatalog {
  static const List<EffectDef> all = [
    EffectDef('blur', 'Gaussian Blur', [
      ParamDef('amount', 'Blurriness', [10], 0, 100),
    ], category: 'blur'),
    EffectDef('color', 'Color Adjust', [
      ParamDef('brightness', 'Brightness', [0], -100, 100),
      ParamDef('contrast', 'Contrast', [0], -100, 100),
      ParamDef('saturation', 'Saturation', [0], -100, 100),
    ], category: 'color'),
    EffectDef('tint', 'Tint', [
      ParamDef('color', 'Color (R,G,B)', [255, 170, 80], 0, 255, color: true),
      ParamDef('amount', 'Amount', [50], 0, 100),
    ], category: 'color'),
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
    ], category: 'atmosphere'),
    EffectDef('gradient', 'Gradient Overlay', [
      ParamDef('amount', 'Darken bottom', [60], 0, 100),
      ParamDef('top', 'Darken top', [0], 0, 100),
    ]),
    EffectDef('letterbox', 'Letterbox', [
      ParamDef('amount', 'Bar size %', [12], 0, 40),
    ]),
    EffectDef('outline', 'Outline Stroke', [
      ParamDef('width', 'Width', [8], 0, 60),
      ParamDef('color', 'Color (R,G,B)', [255, 214, 0], 0, 255, color: true),
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
    ], category: 'atmosphere'),
    EffectDef('shatter', 'Shatter', [
      ParamDef('progress', 'Progress', [0], 0, 100),
      ParamDef('color', 'Shard color (R,G,B)', [255, 200, 40], 0, 255, color: true),
    ], category: 'reveal'),
    EffectDef('paper', 'Paper Texture', [
      ParamDef('amount', 'Amount', [60], 0, 100),
    ]),
    EffectDef('grunge', 'Grunge Texture', [
      ParamDef('amount', 'Amount', [60], 0, 100),
    ]),
    EffectDef('flicker', 'Light Flicker', [
      ParamDef('amount', 'Amount', [30], 0, 100),
    ], category: 'atmosphere'),

    // ------------------------------------------------ V1 motion FX (Agent B)
    EffectDef('silhouette', 'Silhouette Fill', [
      ParamDef('color', 'Color', [255, 193, 7], 0, 255, color: true),
      ParamDef('glow', 'Glow', [40], 0, 100),
    ], category: 'color'),
    EffectDef('mono', 'Black & White', [
      ParamDef('amount', 'Amount', [100], 0, 100),
    ], category: 'color'),
    EffectDef('duotone', 'Duotone', [
      ParamDef('dark', 'Dark color', [0, 0, 0], 0, 255, color: true),
      ParamDef('light', 'Light color', [255, 32, 32], 0, 255, color: true),
      ParamDef('amount', 'Amount', [100], 0, 100),
    ], category: 'color'),
    EffectDef('edge_blur', 'Edge Blur (tilt-shift)', [
      ParamDef('amount', 'Amount', [50], 0, 100),
    ], category: 'blur'),
    EffectDef('motion_blur', 'Motion Blur', [
      ParamDef('amount', 'Shutter', [50], 0, 100),
    ], category: 'blur'),
    EffectDef('curve', 'Curve (curved screen)', [
      ParamDef('bend', 'Bend', [35], -100, 100),
    ], category: 'distort'),
    EffectDef('sway', 'Wind Sway', [
      ParamDef('amount', 'Amount', [30], 0, 100),
      ParamDef('speed', 'Speed', [1], 0, 5),
    ], category: 'distort'),
    EffectDef('glass_frame', 'Glass Frame', [
      ParamDef('thickness', 'Thickness', [18], 0, 120),
      ParamDef('gloss', 'Gloss', [60], 0, 100),
    ], category: 'stylize'),
    EffectDef('torn_edge', 'Torn Paper Edge', [
      ParamDef('side', 'Side', [1], 0, 3, options: ['top', 'bottom', 'left', 'right']),
      ParamDef('amount', 'Amount', [40], 0, 100),
    ], category: 'stylize'),
    EffectDef('particles', 'Particles', [
      ParamDef('kind', 'Kind', [0], 0, 10, options: kParticleKinds),
      ParamDef('amount', 'Amount', [50], 0, 100),
      ParamDef('speed', 'Speed', [1], 0, 5),
      ParamDef('color', 'Color', [255, 255, 255], 0, 255, color: true),
      ParamDef('direction', 'Direction °', [0], -180, 180),
    ], category: 'atmosphere'),
    EffectDef('light_rays', 'Light Rays', [
      ParamDef('angle', 'Angle', [60], 0, 360),
      ParamDef('amount', 'Amount', [50], 0, 100),
      ParamDef('color', 'Color', [255, 230, 170], 0, 255, color: true),
    ], category: 'atmosphere'),
    EffectDef('reveal', 'Reveal Mask', [
      ParamDef('kind', 'Kind', [0], 0, 3, options: ['iris', 'ink', 'smoke', 'wipe']),
      ParamDef('progress', 'Progress', [100], 0, 100),
      ParamDef('softness', 'Softness', [20], 0, 100),
      ParamDef('cx', 'Center X %', [50], 0, 100),
      ParamDef('cy', 'Center Y %', [50], 0, 100),
    ], category: 'reveal'),
    EffectDef('flash', 'Flash', [
      ParamDef('amount', 'Amount', [0], 0, 100),
      ParamDef('color', 'Color', [255, 255, 255], 0, 255, color: true),
    ], category: 'reveal'),
    EffectDef('glitch', 'Glitch', [
      ParamDef('amount', 'Amount', [50], 0, 100),
    ], category: 'reveal'),

    // CHROMA (Agent M) >>> green / blue screen keyer (lib/ui/preview/fx/chroma_key.dart)
    EffectDef('chroma_key', 'Green Screen (Chroma Key)', [
      ParamDef('color', 'Key color', [0, 177, 64], 0, 255, color: true),
      ParamDef('tolerance', 'Tolerance', [50], 0, 100),
      ParamDef('softness', 'Edge softness', [20], 0, 100),
      ParamDef('spill', 'Spill suppression', [50], 0, 100),
      ParamDef('choke', 'Choke (− grow / + shrink)', [0], -50, 50),
      ParamDef('contrast', 'Matte contrast', [0], 0, 100),
      ParamDef('view', 'View', [0], 0, 1, options: ['final', 'matte']),
    ], category: 'keying'),
    // <<< CHROMA (Agent M)

    // V2-C >>> transition effects (lib/ui/preview/fx/transition_painters.dart)
    EffectDef('burn_edge', 'Burn Away', [
      ParamDef('progress', 'Progress', [0], 0, 100),
      ParamDef('cx', 'Start X %', [50], 0, 100),
      ParamDef('cy', 'Start Y %', [50], 0, 100),
      ParamDef('color', 'Glow color', [255, 140, 40], 0, 255, color: true),
      ParamDef('embers', 'Embers', [60], 0, 100),
    ], category: 'reveal'),
    EffectDef('page_curl', 'Page Curl', [
      ParamDef('progress', 'Progress', [0], 0, 100),
      ParamDef('angle', 'Direction °', [200], 0, 360),
      ParamDef('shadow', 'Shadow', [60], 0, 100),
      ParamDef('back', 'Back of page', [238, 230, 214], 0, 255, color: true),
    ], category: 'reveal'),
    // <<< V2-C
    // V2-D >>> realism (lib/ui/preview/fx/realism_painters.dart, lib/core/presets/realism.dart)
    EffectDef('contact_shadow', 'Contact Shadow', [
      ParamDef('opacity', 'Opacity', [55], 0, 100),
      ParamDef('softness', 'Softness', [50], 0, 100),
      ParamDef('length', 'Length', [50], 0, 100),
      ParamDef('angle', 'Light direction °', [120], 0, 360),
      ParamDef('color', 'Color', [12, 10, 8], 0, 255, color: true),
      ParamDef('cast', 'Cast shadow', [0], 0, 100),
      ParamDef('x0', 'Feet left %', [25], 0, 100),
      ParamDef('x1', 'Feet right %', [75], 0, 100),
      ParamDef('bottom', 'Feet line %', [100], 0, 100),
    ], category: 'stylize'),
    EffectDef('grade', 'Colour Grade (lift/gain)', [
      ParamDef('lift', 'Lift (R,G,B) %', [0, 0, 0], -50, 50),
      ParamDef('gain', 'Gain (R,G,B) %', [100, 100, 100], 0, 200),
      ParamDef('saturation', 'Saturation', [0], -100, 100),
      ParamDef('contrast', 'Contrast', [0], -100, 100),
      ParamDef('amount', 'Amount', [100], 0, 100),
    ], category: 'color'),
    EffectDef('haze', 'Atmospheric Haze', [
      ParamDef('amount', 'Amount', [25], 0, 100),
      ParamDef('color', 'Haze color', [196, 210, 224], 0, 255, color: true),
    ], category: 'atmosphere'),
    EffectDef('light_wrap', 'Light Wrap', [
      ParamDef('amount', 'Amount', [40], 0, 100),
      ParamDef('width', 'Width', [12], 1, 80),
      ParamDef('color', 'Light color', [255, 236, 210], 0, 255, color: true),
    ], category: 'color'),
    EffectDef('bloom', 'Bloom', [
      ParamDef('threshold', 'Threshold', [70], 0, 100),
      ParamDef('amount', 'Amount', [40], 0, 100),
      ParamDef('radius', 'Radius', [30], 1, 120),
    ], category: 'stylize'),
    EffectDef('halation', 'Film Halation', [
      ParamDef('amount', 'Amount', [35], 0, 100),
      ParamDef('radius', 'Radius', [18], 1, 80),
      ParamDef('threshold', 'Threshold', [72], 0, 100),
    ], category: 'stylize'),
    EffectDef('chromatic_aberration', 'Chromatic Aberration', [
      ParamDef('amount', 'Amount', [25], 0, 100),
    ], category: 'distort'),
    EffectDef('lens_distortion', 'Lens Distortion', [
      ParamDef('amount', 'Amount (+ barrel / − pincushion)', [20], -100, 100),
    ], category: 'distort'),
    EffectDef('gate_weave', 'Film Gate Weave', [
      ParamDef('amount', 'Weave', [30], 0, 100),
      ParamDef('flicker', 'Flicker', [25], 0, 100),
    ], category: 'atmosphere'),
    // <<< V2-D
  ];

  static const categories = ['keying', 'color', 'blur', 'stylize', 'distort', 'atmosphere', 'reveal']; // CHROMA (Agent M): + keying

  static String categoryLabel(String c) => const {
        'color': 'Color & looks',
        'blur': 'Blur',
        'stylize': 'Stylize',
        'distort': 'Distort',
        'atmosphere': 'Atmosphere',
        'reveal': 'Reveal & flash',
        'keying': 'Keying (green screen)', // CHROMA (Agent M)
      }[c] ??
      c;

  static ParamDef? paramDef(String type, String key) {
    for (final p in byType(type)?.params ?? const <ParamDef>[]) {
      if (p.key == key) return p;
    }
    return null;
  }

  /// Converts a non-numeric command value for an effect param: "#RRGGBB" for
  /// colour params, an option name (e.g. "snow") for choice params. Returns
  /// null when [v] is not such a value (callers then parse numbers as usual).
  /// Throws [ArgumentError] for an unknown option or bad colour.
  static List<double>? paramValues(String type, String key, dynamic v) {
    if (v is! String) return null;
    final def = paramDef(type, key);
    if (def == null) return null;
    if (def.options.isNotEmpty) {
      final i = def.options.indexOf(v.trim().toLowerCase());
      if (i < 0) throw ArgumentError('"$key" must be one of ${def.options.join(', ')} (got "$v")');
      return [i.toDouble()];
    }
    if (def.color || def.defaultValue.length == 3) {
      final named = kChromaNamedColors[v.trim().toLowerCase()]; // CHROMA (Agent M): "green" | "blue"
      if (named != null) return List.of(named);
      final s = v.trim().replaceFirst('#', '').replaceFirst('0x', '');
      final n = int.tryParse(s, radix: 16);
      if (n == null || (s.length != 6 && s.length != 8)) throw ArgumentError('Bad color "$v" for "$key" (use "#RRGGBB")');
      return [((n >> 16) & 0xFF).toDouble(), ((n >> 8) & 0xFF).toDouble(), (n & 0xFF).toDouble()];
    }
    return null;
  }

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
