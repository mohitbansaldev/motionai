import 'anim_prop.dart';

enum LayerType { video, image, text, solid, nullObject, audio }

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
  static const volume = 'volume'; // [0..200] % for video/audio layers

  static const all = [anchor, position, scale, rotation, opacity, volume];
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
/// Timing of one spoken word (captions), in composition seconds.
class WordTiming {
  String word;
  double start;
  double end;
  WordTiming(this.word, this.start, this.end);
  Map<String, dynamic> toJson() => {'w': word, 's': start, 'e': end};
  static WordTiming fromJson(Map<String, dynamic> j) =>
      WordTiming(j['w'] as String, (j['s'] as num).toDouble(), (j['e'] as num).toDouble());
}

/// Text animators: how text appears when the layer starts.
class TextAnimators {
  static const all = ['none', 'typewriter', 'word_pop', 'fade_up', 'slide_up', 'karaoke'];
  static String label(String a) => const {
        'none': 'None',
        'typewriter': 'Typewriter',
        'word_pop': 'Word Pop',
        'fade_up': 'Fade Up',
        'slide_up': 'Slide Up',
        'karaoke': 'Word Highlight',
      }[a] ??
      a;
}

class TextData {
  String text;
  double fontSize;
  int color; // ARGB
  int fontWeight; // 100..900
  String align; // left | center | right
  String? fontFamily;
  String animator; // see TextAnimators
  double animDuration; // seconds for the intro animation
  int highlightColor; // karaoke highlight
  int boxColor; // 0 = no background box
  bool shadow;
  List<WordTiming> words; // optional per-word timings (captions)

  TextData({
    this.text = 'Title',
    this.fontSize = 96,
    this.color = 0xFFFFFFFF,
    this.fontWeight = 700,
    this.align = 'center',
    this.fontFamily,
    this.animator = 'none',
    this.animDuration = 0.8,
    this.highlightColor = 0xFFFFD54F,
    this.boxColor = 0,
    this.shadow = true,
    List<WordTiming>? words,
  }) : words = words ?? [];

  TextData copy() => TextData(
        text: text,
        fontSize: fontSize,
        color: color,
        fontWeight: fontWeight,
        align: align,
        fontFamily: fontFamily,
        animator: animator,
        animDuration: animDuration,
        highlightColor: highlightColor,
        boxColor: boxColor,
        shadow: shadow,
        words: words.map((w) => WordTiming(w.word, w.start, w.end)).toList(),
      );

  Map<String, dynamic> toJson() => {
        'text': text,
        'fontSize': fontSize,
        'color': color,
        'fontWeight': fontWeight,
        'align': align,
        if (fontFamily != null) 'fontFamily': fontFamily,
        'animator': animator,
        'animDuration': animDuration,
        'highlightColor': highlightColor,
        'boxColor': boxColor,
        'shadow': shadow,
        if (words.isNotEmpty) 'words': words.map((w) => w.toJson()).toList(),
      };

  static TextData fromJson(Map<String, dynamic> j) => TextData(
        text: j['text'] as String? ?? '',
        fontSize: (j['fontSize'] as num? ?? 96).toDouble(),
        color: j['color'] as int? ?? 0xFFFFFFFF,
        fontWeight: j['fontWeight'] as int? ?? 700,
        align: j['align'] as String? ?? 'center',
        fontFamily: j['fontFamily'] as String?,
        animator: j['animator'] as String? ?? 'none',
        animDuration: (j['animDuration'] as num? ?? 0.8).toDouble(),
        highlightColor: j['highlightColor'] as int? ?? 0xFFFFD54F,
        boxColor: j['boxColor'] as int? ?? 0,
        shadow: j['shadow'] as bool? ?? true,
        words: (j['words'] as List? ?? []).map((e) => WordTiming.fromJson(e as Map<String, dynamic>)).toList(),
      );
}

/// A shape mask on a layer. Props (layer pixels): center [x,y], size [w,h], feather [px].
class Mask {
  String id;
  String shape; // rect | ellipse
  bool invert;
  final Map<String, AnimProp> props;

  Mask({required this.id, this.shape = 'ellipse', this.invert = false, Map<String, AnimProp>? props})
      : props = props ?? {};

  Mask copy() => Mask(id: id, shape: shape, invert: invert, props: props.map((k, v) => MapEntry(k, v.copy())));

  Map<String, dynamic> toJson() => {
        'id': id,
        'shape': shape,
        'invert': invert,
        'props': props.map((k, v) => MapEntry(k, v.toJson())),
      };

  static Mask fromJson(Map<String, dynamic> j) => Mask(
        id: j['id'] as String,
        shape: j['shape'] as String? ?? 'ellipse',
        invert: j['invert'] as bool? ?? false,
        props: (j['props'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, AnimProp.fromJson(v as Map<String, dynamic>))),
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
  final List<Mask> masks;

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
    List<Mask>? masks,
  })  : props = props ?? {},
        effects = effects ?? [],
        masks = masks ?? [] {
    _ensureDefaults();
  }

  void _ensureDefaults() {
    props.putIfAbsent(Props.anchor, () => AnimProp([width / 2, height / 2, 0]));
    props.putIfAbsent(Props.position, () => AnimProp([0, 0, 0]));
    props.putIfAbsent(Props.scale, () => AnimProp([100, 100, 100]));
    props.putIfAbsent(Props.rotation, () => AnimProp([0, 0, 0]));
    props.putIfAbsent(Props.opacity, () => AnimProp([100]));
    props.putIfAbsent(Props.volume, () => AnimProp([100]));
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
    for (final m in masks) {
      for (final p in m.props.values) {
        p.shift(dt);
      }
    }
    for (final w in text?.words ?? const <WordTiming>[]) {
      w.start += dt;
      w.end += dt;
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

  Mask? maskById(String id) {
    for (final m in masks) {
      if (m.id == id) return m;
    }
    return null;
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
        masks: masks.map((m) => m.copy()).toList(),
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
        if (masks.isNotEmpty) 'masks': masks.map((m) => m.toJson()).toList(),
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
        masks: (j['masks'] as List? ?? []).map((e) => Mask.fromJson(e as Map<String, dynamic>)).toList(),
      );
}
