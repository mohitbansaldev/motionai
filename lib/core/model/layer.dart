import 'anim_prop.dart';
import 'motion_path.dart';

export 'motion_path.dart';

enum LayerType { video, image, text, solid, nullObject, audio, shape, comp /* PRECOMP (Agent L): nested composition */ }

LayerType layerTypeFromName(String name) {
  final n = name.replaceAll('_', '').toLowerCase();
  if (n == 'null') return LayerType.nullObject;
  if (n == 'precomp' || n == 'composition') return LayerType.comp; // PRECOMP (Agent L)
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
  static const trim = 'trim'; // [start%, end%] draw-on for shape layers
  static const pathProgress = 'path_progress'; // [0..100] position along Layer.path

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
  static const all = [
    'none', 'typewriter', 'word_pop', 'fade_up', 'slide_up', 'karaoke', 'random_pop', 'scramble',
    'write_on', // V3-B: soft left→right wipe per word, like handwriting
    'typewriter_soft', 'letter_drop', 'word_fade_grey', // V3-C
  ];
  static String label(String a) => const {
        'none': 'None',
        'typewriter': 'Typewriter',
        'word_pop': 'Word Pop',
        'fade_up': 'Fade Up',
        'slide_up': 'Slide Up',
        'karaoke': 'Word Highlight',
        'random_pop': 'Random Pop',
        'scramble': 'Scramble',
        'write_on': 'Write On', // V3-B
        'typewriter_soft': 'Soft Typewriter', // V3-C
        'letter_drop': 'Letter Drop', // V3-C
        'word_fade_grey': 'Grey → Word Fade', // V3-C
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
  List<TextMark> marks;
  CounterSpec? counter;
  double outline; // outline-only text stroke width (0 = filled text)
  double extrude; // 3D extruded edge depth in px (0 = none)
  int extrudeColor; // colour of the extruded edge (ARGB)
  // V3-C >>> filled text with a coloured edge, italic, tracking, typewriter
  // lead colour, per-word reveal times (word_fade_grey)
  double stroke; // edge width px drawn behind the filled letters (0 = none)
  int strokeColor; // ARGB
  bool italic;
  double letterSpacing; // px
  int leadColor; // typewriter: newest letters in this colour (0 = off)
  int leadChars; // how many newest letters
  List<double> wordTimes; // seconds after the layer start, one per word
  int dimColor; // word_fade_grey: colour before a word is spoken (0 = grey)
  // <<< V3-C

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
    List<TextMark>? marks,
    this.counter,
    this.outline = 0,
    this.extrude = 0,
    this.extrudeColor = 0xFF8A8A8A,
    // V3-C >>>
    this.stroke = 0,
    this.strokeColor = 0xFFFFFFFF,
    this.italic = false,
    this.letterSpacing = 0,
    this.leadColor = 0,
    this.leadChars = 0,
    List<double>? wordTimes,
    this.dimColor = 0,
    // <<< V3-C
  })  : words = words ?? [],
        marks = marks ?? [],
        wordTimes = wordTimes ?? []; // V3-C

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
        marks: marks.map((m) => TextMark.fromJson(m.toJson())).toList(),
        counter: counter == null ? null : CounterSpec.fromJson(counter!.toJson()),
        outline: outline,
        extrude: extrude,
        extrudeColor: extrudeColor,
        // V3-C >>>
        stroke: stroke,
        strokeColor: strokeColor,
        italic: italic,
        letterSpacing: letterSpacing,
        leadColor: leadColor,
        leadChars: leadChars,
        wordTimes: List.of(wordTimes),
        dimColor: dimColor,
        // <<< V3-C
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
        if (marks.isNotEmpty) 'marks': marks.map((m) => m.toJson()).toList(),
        if (counter != null) 'counter': counter!.toJson(),
        if (outline > 0) 'outline': outline,
        if (extrude > 0) 'extrude': extrude,
        if (extrude > 0) 'extrudeColor': extrudeColor,
        // V3-C >>>
        if (stroke > 0) 'stroke': stroke,
        if (stroke > 0) 'strokeColor': strokeColor,
        if (italic) 'italic': true,
        if (letterSpacing != 0) 'letterSpacing': letterSpacing,
        if (leadColor != 0) 'leadColor': leadColor,
        if (leadChars > 0) 'leadChars': leadChars,
        if (wordTimes.isNotEmpty) 'wordTimes': wordTimes,
        if (dimColor != 0) 'dimColor': dimColor,
        // <<< V3-C
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
        marks: (j['marks'] as List? ?? []).map((e) => TextMark.fromJson(e as Map<String, dynamic>)).toList(),
        counter: j['counter'] == null ? null : CounterSpec.fromJson(j['counter'] as Map<String, dynamic>),
        outline: (j['outline'] as num? ?? 0).toDouble(),
        extrude: (j['extrude'] as num? ?? 0).toDouble(),
        extrudeColor: j['extrudeColor'] as int? ?? 0xFF8A8A8A,
        // V3-C >>>
        stroke: (j['stroke'] as num? ?? 0).toDouble(),
        strokeColor: j['strokeColor'] as int? ?? 0xFFFFFFFF,
        italic: j['italic'] as bool? ?? false,
        letterSpacing: (j['letterSpacing'] as num? ?? 0).toDouble(),
        leadColor: j['leadColor'] as int? ?? 0,
        leadChars: (j['leadChars'] as num? ?? 0).toInt(),
        wordTimes: [for (final v in (j['wordTimes'] as List? ?? const [])) (v as num).toDouble()],
        dimColor: j['dimColor'] as int? ?? 0,
        // <<< V3-C
      );
}

/// Vector shape content for shape layers. Coordinates are layer pixels.
/// `rings` holds one flat [x0,y0,x1,y1,...] list per sub-path (paths, lines,
/// map outlines); rect/ellipse/polygon/star use the layer box instead.
class ShapeData {
  String kind; // rect | ellipse | polygon | star | path
  List<List<double>> rings;
  bool closed;
  bool smooth;
  int sides;
  double inner; // star inner radius ratio
  double corner;
  int fill; // ARGB, 0 = none
  int fill2; // gradient end colour (top→bottom), 0 = none
  int stroke; // ARGB, 0 = none
  double strokeWidth;
  List<double> dash; // [on, off] px, empty = solid
  bool arrowStart;
  bool arrowEnd;

  ShapeData({
    this.kind = 'rect',
    List<List<double>>? rings,
    this.closed = true,
    this.smooth = false,
    this.sides = 6,
    this.inner = 0.5,
    this.corner = 0,
    this.fill = 0xFFFFFFFF,
    this.fill2 = 0,
    this.stroke = 0,
    this.strokeWidth = 0,
    List<double>? dash,
    this.arrowStart = false,
    this.arrowEnd = false,
  })  : rings = rings ?? [],
        dash = dash ?? [];

  ShapeData copy() => ShapeData.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'kind': kind,
        if (rings.isNotEmpty) 'rings': rings,
        'closed': closed,
        'smooth': smooth,
        'sides': sides,
        'inner': inner,
        'corner': corner,
        'fill': fill,
        'fill2': fill2,
        'stroke': stroke,
        'strokeWidth': strokeWidth,
        if (dash.isNotEmpty) 'dash': dash,
        'arrowStart': arrowStart,
        'arrowEnd': arrowEnd,
      };

  static ShapeData fromJson(Map<String, dynamic> j) => ShapeData(
        kind: j['kind'] as String? ?? 'rect',
        rings: (j['rings'] as List? ?? [])
            .map((r) => (r as List).map((v) => (v as num).toDouble()).toList())
            .toList(),
        closed: j['closed'] as bool? ?? true,
        smooth: j['smooth'] as bool? ?? false,
        sides: (j['sides'] as num? ?? 6).toInt(),
        inner: (j['inner'] as num? ?? 0.5).toDouble(),
        corner: (j['corner'] as num? ?? 0).toDouble(),
        fill: j['fill'] as int? ?? 0xFFFFFFFF,
        fill2: j['fill2'] as int? ?? 0,
        stroke: j['stroke'] as int? ?? 0,
        strokeWidth: (j['strokeWidth'] as num? ?? 0).toDouble(),
        dash: (j['dash'] as List? ?? []).map((v) => (v as num).toDouble()).toList(),
        arrowStart: j['arrowStart'] as bool? ?? false,
        arrowEnd: j['arrowEnd'] as bool? ?? false,
      );
}

/// An animated annotation on part of a text: highlighter sweep, hand-drawn
/// circle, underline or colour change. Times are composition seconds.
class TextMark {
  String phrase;
  String style; // highlight | circle | underline | color
  int color;
  double start;
  double duration;
  TextMark(this.phrase, {this.style = 'highlight', this.color = 0xCCFFE14D, this.start = 0, this.duration = 0.6});

  Map<String, dynamic> toJson() => {'p': phrase, 'st': style, 'c': color, 's': start, 'd': duration};
  static TextMark fromJson(Map<String, dynamic> j) => TextMark(j['p'] as String,
      style: j['st'] as String? ?? 'highlight',
      color: j['c'] as int? ?? 0xCCFFE14D,
      start: (j['s'] as num? ?? 0).toDouble(),
      duration: (j['d'] as num? ?? 0.6).toDouble());
}

/// Counts a number up (or down) over time: "$1.2B", "95%", "3,000,000".
class CounterSpec {
  double from, to, start, duration;
  int decimals;
  String prefix, suffix;
  CounterSpec({this.from = 0, this.to = 100, this.start = 0, this.duration = 1.5, this.decimals = 0, this.prefix = '', this.suffix = ''});

  String valueAt(double t) {
    final p = duration <= 0 ? 1.0 : ((t - start) / duration).clamp(0.0, 1.0);
    final e = 1 - (1 - p) * (1 - p) * (1 - p);
    final v = from + (to - from) * e;
    var str = v.toStringAsFixed(decimals);
    final neg = str.startsWith('-');
    if (neg) str = str.substring(1);
    final parts = str.split('.');
    final intPart = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    return '$prefix${neg ? '-' : ''}$intPart${parts.length > 1 ? '.${parts[1]}' : ''}$suffix';
  }

  Map<String, dynamic> toJson() =>
      {'from': from, 'to': to, 'start': start, 'duration': duration, 'decimals': decimals, 'prefix': prefix, 'suffix': suffix};
  static CounterSpec fromJson(Map<String, dynamic> j) => CounterSpec(
        from: (j['from'] as num? ?? 0).toDouble(),
        to: (j['to'] as num? ?? 100).toDouble(),
        start: (j['start'] as num? ?? 0).toDouble(),
        duration: (j['duration'] as num? ?? 1.5).toDouble(),
        decimals: (j['decimals'] as num? ?? 0).toInt(),
        prefix: j['prefix'] as String? ?? '',
        suffix: j['suffix'] as String? ?? '',
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
  ShapeData? shape;
  int color; // solid color (ARGB)

  /// Layer content size in pixels (media size, solid size, text box).
  double width;
  double height;

  final Map<String, AnimProp> props;
  final List<Effect> effects;
  final List<Mask> masks;

  /// Track matte (see [LayerMatte]); null = none.
  LayerMatte? matte;

  // PRECOMP (Agent L) >>>
  /// For [LayerType.comp]: id of the nested composition in `Project.comps`.
  /// Child time = sourceIn + (t - start) * speed (see `Precomp.childTime`).
  String? compId;

  /// For [LayerType.comp]: repeat the nested comp when its time runs past its duration.
  bool loop;
  // <<< PRECOMP (Agent L)

  // V2-D >>>
  /// Adjustment layer: its effects (and masks / opacity as a mix) apply to
  /// everything below it in the comp instead of to its own pixels.
  bool adjustment = false;
  // <<< V2-D

  MotionPath? _path;

  /// Motion path (see [MotionPath]); setting one adds the `path_progress` prop.
  MotionPath? get path => _path;
  set path(MotionPath? p) {
    _path = p;
    if (p != null) props.putIfAbsent(Props.pathProgress, () => AnimProp([0]));
  }

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
    this.shape,
    this.color = 0xFF3D5AFE,
    Map<String, AnimProp>? props,
    List<Effect>? effects,
    List<Mask>? masks,
    this.matte,
    MotionPath? path,
    this.compId, // PRECOMP (Agent L)
    this.loop = false, // PRECOMP (Agent L)
  })  : props = props ?? {},
        effects = effects ?? [],
        masks = masks ?? [] {
    _ensureDefaults();
    this.path = path;
  }

  void _ensureDefaults() {
    props.putIfAbsent(Props.anchor, () => AnimProp([width / 2, height / 2, 0]));
    props.putIfAbsent(Props.position, () => AnimProp([0, 0, 0]));
    props.putIfAbsent(Props.scale, () => AnimProp([100, 100, 100]));
    props.putIfAbsent(Props.rotation, () => AnimProp([0, 0, 0]));
    props.putIfAbsent(Props.opacity, () => AnimProp([100]));
    props.putIfAbsent(Props.volume, () => AnimProp([100]));
    if (type == LayerType.shape) props.putIfAbsent(Props.trim, () => AnimProp([0, 100]));
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
    for (final m in text?.marks ?? const <TextMark>[]) {
      m.start += dt;
    }
    final ctr = text?.counter;
    if (ctr != null) ctr.start += dt;
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
        shape: shape?.copy(),
        color: color,
        props: props.map((k, v) => MapEntry(k, v.copy())),
        effects: effects.map((e) => e.copy()).toList(),
        masks: masks.map((m) => m.copy()).toList(),
        matte: matte,
        path: _path?.copy(),
        compId: compId, // PRECOMP (Agent L)
        loop: loop, // PRECOMP (Agent L)
      )..adjustment = adjustment; // V2-D

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
        if (shape != null) 'shape': shape!.toJson(),
        'color': color,
        'width': width,
        'height': height,
        'props': props.map((k, v) => MapEntry(k, v.toJson())),
        'effects': effects.map((e) => e.toJson()).toList(),
        if (masks.isNotEmpty) 'masks': masks.map((m) => m.toJson()).toList(),
        if (matte != null) 'matte': matte!.toJson(),
        if (_path != null) 'path': _path!.toJson(),
        if (compId != null) 'compId': compId, // PRECOMP (Agent L)
        if (loop) 'loop': true, // PRECOMP (Agent L)
        if (adjustment) 'adjustment': true, // V2-D
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
        shape: j['shape'] == null ? null : ShapeData.fromJson(j['shape'] as Map<String, dynamic>),
        color: j['color'] as int? ?? 0xFF3D5AFE,
        props: (j['props'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, AnimProp.fromJson(v as Map<String, dynamic>))),
        effects: (j['effects'] as List? ?? []).map((e) => Effect.fromJson(e as Map<String, dynamic>)).toList(),
        masks: (j['masks'] as List? ?? []).map((e) => Mask.fromJson(e as Map<String, dynamic>)).toList(),
        matte: j['matte'] is Map ? LayerMatte.fromJson(Map<String, dynamic>.from(j['matte'] as Map)) : null,
        path: j['path'] is Map ? MotionPath.fromJson(Map<String, dynamic>.from(j['path'] as Map)) : null,
        compId: j['compId'] as String?, // PRECOMP (Agent L)
        loop: j['loop'] as bool? ?? false, // PRECOMP (Agent L)
      )..adjustment = j['adjustment'] == true; // V2-D
}
