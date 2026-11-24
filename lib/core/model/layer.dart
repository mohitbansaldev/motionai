import 'anim_prop.dart';

enum LayerType { video, image, text, solid, nullObject }

LayerType layerTypeFromName(String name) {
  final n = name.replaceAll('_', '').toLowerCase();
  if (n == 'null') return LayerType.nullObject;
  for (final t in LayerType.values) {
    if (t.name.toLowerCase() == n) return t;
  }
  throw FormatException('Unknown layer type "$name"');
}

/// Standard transform property keys on every layer.
class Props {
  static const anchor = 'anchor'; // [x, y, z] in layer pixels
  static const position = 'position'; // [x, y, z] in comp pixels
  static const scale = 'scale'; // [x%, y%, z%]
  static const rotation = 'rotation'; // [x°, y°, z°]
  static const opacity = 'opacity'; // [0..100]

  static const all = [anchor, position, scale, rotation, opacity];
}

/// One effect instance on a layer (blur, color adjust, tint...).
class Effect {
  String id;
  String type;
  bool enabled;
  final Map<String, AnimProp> params;

  Effect({required this.id, required this.type, this.enabled = true, Map<String, AnimProp>? params})
      : params = params ?? {};

  Effect copy() => Effect(
        id: id,
        type: type,
        enabled: enabled,
        params: params.map((k, v) => MapEntry(k, v.copy())),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'enabled': enabled,
        'params': params.map((k, v) => MapEntry(k, v.toJson())),
      };

  static Effect fromJson(Map<String, dynamic> j) => Effect(
        id: j['id'] as String,
        type: j['type'] as String,
        enabled: j['enabled'] as bool? ?? true,
        params: (j['params'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, AnimProp.fromJson(v as Map<String, dynamic>))),
      );
}

/// Text styling for text layers.
class TextData {
  String text;
  double fontSize;
  int color; // ARGB
  int fontWeight; // 100..900
  String align; // left | center | right
  String? fontFamily;

  TextData({
    this.text = 'Title',
    this.fontSize = 96,
    this.color = 0xFFFFFFFF,
    this.fontWeight = 700,
    this.align = 'center',
    this.fontFamily,
  });

  TextData copy() => TextData(
      text: text, fontSize: fontSize, color: color, fontWeight: fontWeight, align: align, fontFamily: fontFamily);

  Map<String, dynamic> toJson() => {
        'text': text,
        'fontSize': fontSize,
        'color': color,
        'fontWeight': fontWeight,
        'align': align,
        if (fontFamily != null) 'fontFamily': fontFamily,
      };

  static TextData fromJson(Map<String, dynamic> j) => TextData(
        text: j['text'] as String? ?? '',
        fontSize: (j['fontSize'] as num? ?? 96).toDouble(),
        color: j['color'] as int? ?? 0xFFFFFFFF,
        fontWeight: j['fontWeight'] as int? ?? 700,
        align: j['align'] as String? ?? 'center',
        fontFamily: j['fontFamily'] as String?,
      );
}

/// A layer in a composition. Times are in seconds of composition time.
///
/// Keyframe times are stored in composition time too, so moving a layer
/// shifts its keyframes with it (see [Layer.moveTo]).
class Layer {
  String id;
  String name;
  LayerType type;

  double start; // comp time where the layer begins
  double duration; // visible length on the timeline (comp seconds)
  double sourceIn; // offset into the source media (seconds)
  double speed; // playback speed of source media

  bool is3D;
  bool visible;
  bool locked;
  String? parentId;
  String blendMode;

  String? mediaId; // for video/image layers
  TextData? text;
  int color; // solid color (ARGB)

  /// Layer content size in pixels (media size, solid size, text box).
  double width;
  double height;

  final Map<String, AnimProp> props;
  final List<Effect> effects;

  Layer({
    required this.id,
    required this.name,
    required this.type,
    required this.start,
    required this.duration,
    required this.width,
    required this.height,
    this.sourceIn = 0,
    this.speed = 1,
    this.is3D = false,
    this.visible = true,
    this.locked = false,
    this.parentId,
    this.blendMode = 'normal',
    this.mediaId,
    this.text,
    this.color = 0xFF3D5AFE,
    Map<String, AnimProp>? props,
    List<Effect>? effects,
  })  : props = props ?? {},
        effects = effects ?? [] {
    _ensureDefaults();
  }

  void _ensureDefaults() {
    props.putIfAbsent(Props.anchor, () => AnimProp([width / 2, height / 2, 0]));
    props.putIfAbsent(Props.position, () => AnimProp([0, 0, 0]));
    props.putIfAbsent(Props.scale, () => AnimProp([100, 100, 100]));
    props.putIfAbsent(Props.rotation, () => AnimProp([0, 0, 0]));
    props.putIfAbsent(Props.opacity, () => AnimProp([100]));
  }

  double get end => start + duration;

  bool isActiveAt(double t) => visible && t >= start - 1e-9 && t < end - 1e-9;

  /// Source media time shown at composition time [t].
  double sourceTimeAt(double t) => sourceIn + (t - start) * speed;

  AnimProp prop(String key) {
    final p = props[key];
    if (p == null) throw ArgumentError('Layer "$name" has no property "$key"');
    return p;
  }

  /// Moves the layer to a new start time, shifting all its keyframes.
  void moveTo(double newStart) {
    final dt = newStart - start;
    start = newStart;
    for (final p in props.values) {
      p.shift(dt);
    }
    for (final e in effects) {
      for (final p in e.params.values) {
        p.shift(dt);
      }
    }
  }

  /// Every keyframe time on this layer (for timeline diamonds).
  List<double> allKeyframeTimes() {
    final s = <double>{};
    for (final p in props.values) {
      for (final k in p.keyframes) {
        s.add(k.time);
      }
    }
    for (final e in effects) {
      for (final p in e.params.values) {
        for (final k in p.keyframes) {
          s.add(k.time);
        }
      }
    }
    final l = s.toList()..sort();
    return l;
  }

  Effect? effectById(String id) {
    for (final e in effects) {
      if (e.id == id) return e;
    }
    return null;
  }

  Layer copy({String? newId}) => Layer(
        id: newId ?? id,
        name: name,
        type: type,
        start: start,
        duration: duration,
        width: width,
        height: height,
        sourceIn: sourceIn,
        speed: speed,
        is3D: is3D,
        visible: visible,
        locked: locked,
        parentId: parentId,
        blendMode: blendMode,
        mediaId: mediaId,
        text: text?.copy(),
        color: color,
        props: props.map((k, v) => MapEntry(k, v.copy())),
        effects: effects.map((e) => e.copy()).toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'start': start,
        'duration': duration,
        'sourceIn': sourceIn,
        'speed': speed,
        'is3D': is3D,
        'visible': visible,
        'locked': locked,
        if (parentId != null) 'parentId': parentId,
        'blendMode': blendMode,
        if (mediaId != null) 'mediaId': mediaId,
        if (text != null) 'text': text!.toJson(),
        'color': color,
        'width': width,
        'height': height,
        'props': props.map((k, v) => MapEntry(k, v.toJson())),
        'effects': effects.map((e) => e.toJson()).toList(),
      };

  static Layer fromJson(Map<String, dynamic> j) => Layer(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Layer',
        type: layerTypeFromName(j['type'] as String),
        start: (j['start'] as num).toDouble(),
        duration: (j['duration'] as num).toDouble(),
        width: (j['width'] as num).toDouble(),
        height: (j['height'] as num).toDouble(),
        sourceIn: (j['sourceIn'] as num? ?? 0).toDouble(),
        speed: (j['speed'] as num? ?? 1).toDouble(),
        is3D: j['is3D'] as bool? ?? false,
        visible: j['visible'] as bool? ?? true,
        locked: j['locked'] as bool? ?? false,
        parentId: j['parentId'] as String?,
        blendMode: j['blendMode'] as String? ?? 'normal',
        mediaId: j['mediaId'] as String?,
        text: j['text'] == null ? null : TextData.fromJson(j['text'] as Map<String, dynamic>),
        color: j['color'] as int? ?? 0xFF3D5AFE,
        props: (j['props'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, AnimProp.fromJson(v as Map<String, dynamic>))),
        effects: (j['effects'] as List? ?? []).map((e) => Effect.fromJson(e as Map<String, dynamic>)).toList(),
      );
}
