// V3-E: the documentary pattern registry ("story grammar"). Every visual
// pattern of the Nitish-Rajput-style reference clips (PATTERN_LIBRARY_SPEC
// 1–65) plus the MotionAI features those clips use, as data: id, label,
// category, the cues that trigger it, a keyword lexicon (English, Hindi in
// Devanagari, romanised Hinglish), default hold, typical in/out transition,
// what precedes/follows it, its sound, and a builder that returns MotionAI
// edit commands.
//
// Builders call the new V3 components/ops BY NAME (route_follow, unit_chart,
// clock_stamp, powder_burst, mood_flood…). Each step lists alternatives:
// the first one whose ops/components/transitions/effects exist on this
// build is used, and when it fails at run time the next one is tried
// (PatternRuntime in pattern_engine.dart). The last alternative is always
// built from plain layers, so every pattern works before and after the other
// V3 branches merge.

import 'dart:math' as math;

import '../core/model/project.dart';

/// One step of a pattern: alternatives in order of preference. Each
/// alternative is a list of edit commands; `{"op":"@call","name":…}` means
/// "the op or component called name" and `{"op":"@transition","type":…}`
/// "the transition called type" (resolved at run time).
class PStep {
  final String label;
  final List<List<Map<String, dynamic>>> alts;
  final bool optional;
  const PStep(this.label, this.alts, {this.optional = false});
}

/// A fillable value of a pattern (also its template slot).
class PSlot {
  final String key, label;
  final String kind; // text | media | medias
  final String media; // image | video | any
  final dynamic initial;
  const PSlot(this.key, this.label, {this.kind = 'text', this.media = 'image', this.initial});
}

typedef PatternBuilder = List<PStep> Function(PatternCtx c);

class DocPattern {
  final String id;
  final int n; // catalogue number in PATTERN_LIBRARY_SPEC (0 = existing MotionAI feature)
  final String label;
  final String category; // maps | evidence | data | overlay | transition | mood | character | presenter | shot
  final String role; // broll | overlay | transition | presenter | mood
  final Map<String, double> cues; // cue type → weight
  final List<String> keywords; // extra lexicon (en / hi / hinglish), "*" = prefix
  final double hold; // default seconds on screen
  final String enter, exit; // typical transitions in / out
  final List<String> precede, follow; // patterns or roles that usually come before / after
  final List<String> sfx; // sound cues (spec names; mapped to synth kinds)
  final String when; // one line for command_spec "WHEN TO USE"
  final String primary; // the op / component / transition it is built on
  final bool fullscreen; // brings its own backdrop (plate is a dark solid)
  final List<PSlot> slots;
  final PatternBuilder build;

  const DocPattern(
    this.id,
    this.n,
    this.label,
    this.category,
    this.role, {
    required this.cues,
    this.keywords = const [],
    this.hold = 3.5,
    this.enter = 'cut',
    this.exit = 'cut',
    this.precede = const [],
    this.follow = const [],
    this.sfx = const [],
    required this.when,
    required this.primary,
    this.fullscreen = false,
    this.slots = const [],
    required this.build,
  });

  bool get isTransition => role == 'transition';
  bool get isEvidence => category == 'evidence' && follow.contains('reenactment');

  Map<String, dynamic> toJson() => {
        'id': id,
        if (n > 0) 'n': n,
        'label': label,
        'category': category,
        'role': role,
        'cues': cues,
        if (keywords.isNotEmpty) 'keywords': keywords,
        'hold': hold,
        'enter': enter,
        'exit': exit,
        if (precede.isNotEmpty) 'precede': precede,
        if (follow.isNotEmpty) 'follow': follow,
        if (sfx.isNotEmpty) 'sfx': sfx,
        'when': when,
        'primary': primary,
        'slots': [for (final s in slots) s.key],
      };
}

/// What a builder knows: beat time, slot values, ids, frame size.
class PatternCtx {
  final Project project;
  final double start, end;
  final Map<String, dynamic> slots;
  final String pfx;
  final String? plate; // the beat's background layer
  final String? prevPlate; // the previous beat's background (transitions)
  final String tone; // snow | desert | neutral …
  final double reveal; // absolute time the key reveal lands

  PatternCtx(this.project,
      {required this.start, required this.end, this.slots = const {}, required this.pfx, this.plate, this.prevPlate, this.tone = 'neutral', double? reveal})
      : reveal = (reveal ?? start + (end - start) * 0.3).clamp(start + 0.1, math.max(start + 0.1, end - 0.3)).toDouble();

  double get w => project.editComp.width;
  double get h => project.editComp.height;
  double get d => end - start;
  double get rv => reveal;
  double t(double x) => start + x;
  String id(String part) => '${pfx}_$part';

  dynamic raw(String k) {
    final v = slots[k];
    if (v == null || (v is String && v.trim().isEmpty) || (v is List && v.isEmpty)) return null;
    return v;
  }

  String s(String k, [String d = '']) {
    final v = raw(k);
    if (v == null) return d;
    if (v is List) return v.map((e) => '$e').join(', ');
    return '$v';
  }

  double n(String k, double d) {
    final v = raw(k);
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}'.replaceAll(RegExp(r'[^0-9.\-]'), '')) ?? d;
  }

  List<String> list(String k, [List<String> d = const []]) {
    final v = raw(k);
    if (v is List) return [for (final e in v) if ('$e'.trim().isNotEmpty) '$e'.trim()];
    if (v is String) return v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    return d;
  }

  /// Visual media of slot [k] (photo/video id of this project), or null.
  MediaAsset? media(String k) {
    final v = raw(k);
    final id = v is List ? (v.isEmpty ? null : '${v.first}') : v?.toString();
    final m = id == null ? null : project.media[id];
    return m == null || m.type == MediaType.audio ? null : m;
  }

  List<MediaAsset> medias(String k) {
    final v = raw(k);
    final ids = v is List ? [for (final e in v) '$e'] : (v is String ? v.split(',').map((e) => e.trim()).toList() : const <String>[]);
    return [for (final i in ids) if (project.media[i] != null && project.media[i]!.type != MediaType.audio) project.media[i]!];
  }

  List<String> places([List<String> d = const ['Chile']]) {
    final l = list('places');
    if (l.isNotEmpty) return l;
    final p = s('place');
    return p.isEmpty ? d : [p];
  }

  String upper(String k, String d) => s(k, d).toUpperCase();

  // ---------------------------------------------------------- command helpers

  /// "the op or component [name]" with [args] (resolved at run time).
  Map<String, dynamic> call(String name, String part, Map<String, dynamic> args, {double? at, double? du}) => {
        'op': '@call', 'name': name, 'id': id(part), 'start': at ?? start, 'duration': du ?? (end - (at ?? start)), ...args,
      };

  Map<String, dynamic> comp(String type, String part, Map<String, dynamic> args, {double? at, double? du}) => {
        'op': 'add_component', 'type': type, 'id': id(part), 'start': at ?? start, 'duration': du ?? (end - (at ?? start)), ...args,
      };

  Map<String, dynamic> text(String part, String text,
      {double? x, double? y, double size = 0.065, String color = '#FFFFFF', int weight = 900, String? font = 'Poppins', String? animator = 'word_pop',
      double animDur = 0.45, double? at, double? du, String align = 'center', double? width, double? height, bool shadow = true, String? box,
      String? parent, String? style, Map<String, dynamic> extra = const {}}) {
    final st = at ?? start;
    final fs = size * h;
    return {
      'op': 'add_layer', 'type': 'text', 'id': id(part), 'name': text.length > 24 ? text.substring(0, 24) : text, 'text': text,
      'start': st, 'duration': du ?? math.max(0.2, end - st), 'font_size': fs, 'font_weight': weight, 'text_color': color,
      'font': ?font, 'text_style': ?style, 'align': align, 'width': width ?? w * 0.86, 'height': height ?? fs * 2.6,
      'position': [x ?? w / 2, y ?? h / 2, 0], 'shadow': shadow, if (box != null) 'box_color': box,
      if (animator != null) 'animator': animator, if (animator != null) 'anim_duration': animDur, 'parent': ?parent, ...extra,
    };
  }

  Map<String, dynamic> shape(String part, String kind, double sw, double sh, double x, double y,
          {String fill = '#FFFFFF', String? fill2, String? stroke, double? strokeWidth, double corner = 0, int? sides, double? at, double? du,
          List<double>? dash, String? parent, String? name, List<List<double>>? points}) =>
      {
        'op': 'add_layer', 'type': 'shape', 'id': id(part), 'kind': kind, 'width': sw, 'height': sh, if (points == null) 'position': [x, y, 0], 'fill': fill,
        'fill2': ?fill2, 'stroke': ?stroke, 'stroke_width': ?strokeWidth, 'corner': corner, 'sides': ?sides, 'dash': ?dash,
        'start': at ?? start, 'duration': du ?? math.max(0.2, end - (at ?? start)), 'parent': ?parent, 'name': name ?? part,
        if (points != null) 'points': points,
      };

  Map<String, dynamic> solid(String part, String color, {double? at, double? du, bool adjustment = false, String? name}) => {
        'op': 'add_layer', 'type': 'solid', 'id': id(part), 'color': color, 'start': at ?? start, 'duration': du ?? math.max(0.2, end - (at ?? start)),
        if (adjustment) 'adjustment': true, 'name': name ?? part,
      };

  Map<String, dynamic> group(String part, double x, double y, {double? at, double? du}) => {
        'op': 'add_layer', 'type': 'null', 'id': id(part), 'name': part, 'start': at ?? start, 'duration': du ?? math.max(0.2, end - (at ?? start)),
        'position': [x, y, 0],
      };

  Map<String, dynamic> anchor0(String part) => {'op': 'set_property', 'target': id(part), 'prop': 'anchor', 'value': [0, 0, 0]};

  Map<String, dynamic> media2(String part, MediaAsset m, {double? x, double? y, double? heightPx, double? widthPx, double? at, double? du, String? parent, bool cover = false}) {
    final double sc;
    if (heightPx != null) {
      sc = heightPx / math.max(1, m.height) * 100;
    } else if (widthPx != null) {
      sc = widthPx / math.max(1, m.width) * 100;
    } else {
      sc = (cover ? math.max(w / math.max(1, m.width), h / math.max(1, m.height)) : math.min(w / math.max(1, m.width), h / math.max(1, m.height))) * 100;
    }
    return {
      'op': 'add_layer', 'type': m.type == MediaType.video ? 'video' : 'image', 'media': m.id, 'id': id(part), 'name': m.name,
      'start': at ?? start, 'duration': du ?? math.max(0.2, end - (at ?? start)), 'fit': 'none', 'position': [x ?? w / 2, y ?? h / 2, 0],
      'scale': [sc, sc, 100], 'parent': ?parent,
    };
  }

  Map<String, dynamic> kf(String part, String prop, double time, dynamic v, [String ease = 'easy_ease']) =>
      {'op': 'set_keyframe', 'target': id(part), 'prop': prop, 'time': time, 'value': v, 'ease': ease};

  Map<String, dynamic> kfL(String layer, String prop, double time, dynamic v, [String ease = 'easy_ease']) =>
      {'op': 'set_keyframe', 'target': layer, 'prop': prop, 'time': time, 'value': v, 'ease': ease};

  Map<String, dynamic> set(String part, String prop, dynamic v) => {'op': 'set_property', 'target': id(part), 'prop': prop, 'value': v};

  Map<String, dynamic> rot(String part, double deg) => set(part, 'rotation', [0, 0, deg]);

  Map<String, dynamic> fx(String layer, String effect, Map<String, dynamic> params, {String? fxId}) =>
      {'op': 'add_effect', 'layer': layer, 'effect': effect, 'id': fxId ?? '${layer}_${effect}_fx', 'params': params};

  Map<String, dynamic> fxKey(String layer, String fxId, String param, double time, dynamic v, [String ease = 'easy_ease']) =>
      {'op': 'set_effect_param', 'layer': layer, 'effect': fxId, 'param': param, 'time': time, 'value': v, 'ease': ease};

  /// Scale pop 0 → over% → 100 at [at].
  List<Map<String, dynamic>> pop(String part, double at, {double over = 115, double dur = 0.25, double from = 0}) => [
        kf(part, 'scale', at, [from, from, 100], 'ease_out'),
        kf(part, 'scale', at + dur * 0.6, [over, over, 100], 'easy_ease'),
        kf(part, 'scale', at + dur, [100, 100, 100], 'easy_ease'),
      ];

  List<Map<String, dynamic>> fade(String part, double at, {double dur = 0.3, double from = 0, double to = 100}) =>
      [kf(part, 'opacity', at, from, 'ease_out'), kf(part, 'opacity', at + dur, to, 'easy_ease')];

  List<Map<String, dynamic>> drawOn(String part, double at, {double dur = 0.5}) =>
      [kf(part, 'trim', at, [0, 0], 'ease_out'), kf(part, 'trim', at + dur, [0, 100], 'easy_ease')];

  /// Transition between the previous and this beat's plates: [type] with
  /// [params], then [fallbacks] (existing transitions), then an animate_in.
  List<PStep> transition(String type, Map<String, dynamic> params, List<(String, Map<String, dynamic>)> fallbacks, {String anim = 'fade'}) {
    final a = prevPlate, b = plate;
    if (b == null) return const [];
    if (a == null) {
      return [
        PStep('enter', [
          [{'op': 'animate_in', 'layer': b, 'preset': anim, 'duration': 0.5}],
        ], optional: true),
      ];
    }
    return [
      PStep(type, [
        [{'op': '@transition', 'type': type, 'layers': [a, b], 'at': start, ...params}],
        for (final f in fallbacks) [{'op': 'transition', 'type': f.$1, 'layers': [a, b], 'at': start, ...f.$2}],
        [{'op': 'animate_in', 'layer': b, 'preset': anim, 'duration': 0.5}],
      ], optional: true),
    ];
  }
}

/// Small shared builder kits (fallbacks made of plain layers).
class _Kit {
  static const cyan = '#2EE6E6', yellow = '#FFE000', blue = '#1E40D0', red = '#D0202A', darkRed = '#7A1420';

  static String spaced(String s) => s.toUpperCase().split('').join(' ');

  /// Radio / pulse rings: [count] ellipses expanding and fading in a loop.
  static List<Map<String, dynamic>> rings(PatternCtx c, String part, double x, double y, String color,
      {int count = 3, double period = 0.75, double flatten = 0.35, double radius = 220, double width = 6}) {
    final out = <Map<String, dynamic>>[];
    final cycles = (c.d / period).ceil().clamp(1, 40);
    for (int k = 0; k < count; k++) {
      final p = '${part}_$k';
      out.add(c.shape(p, 'ellipse', radius * 2, radius * 2 * flatten, x, y, fill: 'none', stroke: color, strokeWidth: width));
      for (int i = 0; i < cycles; i++) {
        final s = c.start + i * period + k * period / count;
        if (s >= c.end) break;
        out.add(c.kf(p, 'scale', s, [8, 8, 100], 'ease_out'));
        out.add(c.kf(p, 'scale', s + period * 0.98, [100, 100, 100], 'hold'));
        out.add(c.kf(p, 'opacity', s, 95, 'linear'));
        out.add(c.kf(p, 'opacity', s + period * 0.98, 0, 'hold'));
      }
    }
    return out;
  }

  /// Pictogram grid (unit chart / survivor tally): groups of coloured people
  /// popping in row by row.
  static List<Map<String, dynamic>> people(PatternCtx c, String part, List<(int, String)> groups,
      {int cols = 10, List<double> area = const [0.12, 0.3, 0.88, 0.86], double stagger = 0.03, double? at, bool glow = false}) {
    final total = groups.fold<int>(0, (a, g) => a + g.$1);
    final shown = total.clamp(1, 60);
    final k = total / shown; // people per icon
    final rows = (shown / cols).ceil();
    final x0 = area[0] * c.w, y0 = area[1] * c.h, x1 = area[2] * c.w, y1 = area[3] * c.h;
    final cw = (x1 - x0) / cols, ch = math.min((y1 - y0) / math.max(1, rows), cw * 1.6);
    final iw = math.min(cw, ch / 1.6) * 0.62;
    final out = <Map<String, dynamic>>[];
    var t = at ?? c.rv;
    var idx = 0;
    for (final g in groups) {
      final n = (g.$1 / k).round();
      for (int i = 0; i < n && idx < shown; i++, idx++) {
        final col = idx % cols, row = idx ~/ cols;
        final cx = x0 + cw * (col + 0.5), cy = y0 + ch * (row + 0.5);
        final p = '${part}_$idx';
        out.add(c.group(p, cx, cy, at: t));
        out.add(c.anchor0(p));
        out.add(c.shape('${p}_h', 'ellipse', iw * 0.5, iw * 0.5, 0, -iw * 0.55, fill: g.$2, parent: c.id(p), at: t));
        out.add(c.shape('${p}_b', 'rect', iw * 0.78, iw * 0.9, 0, iw * 0.25, fill: g.$2, corner: iw * 0.3, parent: c.id(p), at: t));
        if (glow) out.add(c.fx(c.id('${p}_b'), 'glow', {'amount': 45, 'radius': 14}));
        out.addAll(c.pop(p, t, over: 112, dur: 0.22));
        t += stagger;
      }
    }
    return out;
  }

  /// A text card: paper rect + text, grouped, dropping in rotated.
  static List<Map<String, dynamic>> card(PatternCtx c, String part, String text,
      {double w = 0.32, double h = 0.4, String paper = '#F7F3E8', String color = '#B3121E', String font = 'Poppins', double size = 0.085,
      double tilt = -6, double glide = 0.12, bool ruled = true, String? animator}) {
    final cw = c.w * w, ch = c.h * h;
    final x = c.n('x', c.w * 0.44), y = c.n('y', c.h * 0.5);
    final out = <Map<String, dynamic>>[
      c.group(part, x, y),
      c.anchor0(part),
      c.shape('${part}_paper', 'rect', cw, ch, 0, 0, fill: paper, corner: cw * 0.012, parent: c.id(part)),
      c.fx(c.id('${part}_paper'), 'shadow', {'distance': 16, 'blur': 22, 'opacity': 55}),
      c.fx(c.id('${part}_paper'), 'paper', {'amount': 55}),
    ];
    if (ruled) {
      for (int i = 1; i <= 6; i++) {
        out.add(c.shape('${part}_rule$i', 'rect', cw * 0.86, 2, 0, -ch / 2 + ch * i / 7.2, fill: '#9FB8D8', parent: c.id(part)));
      }
      out.add(c.shape('${part}_margin', 'rect', 2, ch, -cw * 0.36, 0, fill: '#E08A8A', parent: c.id(part)));
    }
    out.add(c.text('${part}_txt', text, x: 0, y: 0, size: size, color: color, font: font, width: cw * 0.86, height: ch * 0.8, parent: c.id(part),
        animator: animator, shadow: false));
    // drop in 0.25 s (rotated), glide 0.75 s ease-out
    out.addAll([
      c.kf(part, 'position', c.start, [x, -ch, 0], 'ease_in'),
      c.kf(part, 'position', c.start + 0.25, [x, y, 0], 'ease_out'),
      c.kf(part, 'position', c.start + 1.0, [x + c.w * glide, y, 0], 'easy_ease'),
      c.kf(part, 'rotation', c.start, [0, 0, tilt * 1.6], 'ease_in'),
      c.kf(part, 'rotation', c.start + 0.25, [0, 0, tilt], 'easy_ease'),
    ]);
    return out;
  }

  /// Plain stacked text lines typed one after another.
  static List<Map<String, dynamic>> lines(PatternCtx c, String part, List<String> lines,
      {double x = 0.05, double y = 0.78, double size = 0.055, String font = 'Roboto Mono', double cps = 13, double gap = 0.5, String color = '#FFFFFF',
      int weight = 700, String align = 'left', double width = 0.6}) {
    final out = <Map<String, dynamic>>[];
    var t = c.rv - 0.15;
    for (int i = 0; i < lines.length; i++) {
      final fs = size * c.h;
      final lw = c.w * width;
      out.add(c.text('${part}_$i', lines[i], x: align == 'left' ? c.w * x + lw / 2 : c.w * x, y: c.h * y + i * fs * 1.25, size: size, font: font,
          weight: weight, color: color, align: align, width: lw, height: fs * 1.5, animator: 'typewriter',
          animDur: (lines[i].length / cps).clamp(0.2, 3.0), at: math.min(t, c.end - 0.3)));
      t += lines[i].length / cps + gap;
    }
    return out;
  }

  /// Dark gradient backdrop.
  static Map<String, dynamic> backdrop(PatternCtx c, String part, String c1, String c2) =>
      c.shape(part, 'rect', c.w, c.h, c.w / 2, c.h / 2, fill: c1, fill2: c2);
}

/// The registry.
class PatternLibrary {
  static DocPattern? byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }

  static List<String> get ids => [for (final p in all) p.id];

  /// Ids per category, in catalogue order.
  static Map<String, List<String>> get byCategory {
    final out = <String, List<String>>{};
    for (final p in all) {
      (out[p.category] ??= []).add(p.id);
    }
    return out;
  }

  static List<Map<String, dynamic>> catalogJson() => [for (final p in all) p.toJson()];

  static const _place = [PSlot('places', 'Countries (comma separated)', initial: 'Chile, Argentina')];
  static const _route = [PSlot('from', 'From', initial: 'Uruguay'), PSlot('to', 'To', initial: 'Chile')];
  static const _photo = [PSlot('media', 'Photo', kind: 'media')];
  static const _quote = [
    PSlot('media', 'Screenshot / page photo', kind: 'media'),
    PSlot('quote', 'Quoted passage', initial: 'The plane crashed into the mountains and the survivors waited for rescue.'),
    PSlot('highlight', 'Phrase to highlight', initial: 'crashed into the mountains'),
    PSlot('circle', 'Word to circle', initial: 'survivors'),
    PSlot('source', 'Source', initial: 'Source – archive.org'),
  ];

  static final List<DocPattern> all = [
    // ===================================================== P-A maps & geo
    DocPattern('satellite_country_map', 1, 'Satellite country map', 'maps', 'broll',
        cues: {'place': 1.0}, keywords: ['map', 'naksha', 'नक्शा', 'desh', 'देश', 'country'], hold: 4, exit: 'powder_burst',
        follow: ['route_arrow_follow', 'reenactment_shot'], sfx: ['pop', 'whoosh'], when: 'a country or city is named',
        primary: 'map', fullscreen: true, slots: [..._place, PSlot('city', 'City tag (optional)')], build: _countryMap),
    DocPattern('route_arrow_follow', 2, 'Route arrow follow', 'maps', 'broll',
        cues: {'route': 1.0}, keywords: ['se', 'से', 'tak', 'तक', 'from', 'to', 'flew', 'उड़ान'], hold: 4.5, precede: ['satellite_country_map'],
        sfx: ['whoosh', 'pop'], when: '"went/flew from X to Y", "X se Y tak"', primary: 'route_follow', fullscreen: true, slots: _route, build: _routeFollow),
    DocPattern('map_zoom_punch', 3, 'Map zoom punch', 'maps', 'broll',
        cues: {'emphasis': 0.5, 'place': 0.35, 'turning_point': 0.4}, hold: 2.5, precede: ['satellite_country_map'], sfx: ['whoosh'],
        when: 'emphasis or a twist while on a map (0.45 s ×2.6 punch-in)', primary: 'camera_move:punch_in', fullscreen: true, slots: _place, build: _zoomPunch),
    DocPattern('map_tilt_3d', 4, 'Map tilt 3D + terrain label', 'maps', 'broll',
        cues: {'terrain': 1.0}, keywords: ['andes', 'एंडीज', 'pahad', 'पहाड़', 'mountain*', 'nadi', 'नदी', 'border', 'सीमा'], hold: 4,
        sfx: ['whoosh'], when: 'mountains, rivers, borders, ranges', primary: 'terrain_label', fullscreen: true,
        slots: [..._place, PSlot('terrain', 'Terrain name', initial: 'ANDES')], build: _tilt3d),
    DocPattern('giant_ghost_country', 5, 'Giant ghost country word', 'maps', 'overlay',
        cues: {'place': 0.55}, hold: 4, sfx: [], when: 'a country is the subject of a long map beat (huge 60% word behind)', primary: 'map_watermark',
        fullscreen: true, slots: _place, build: _ghost),
    DocPattern('route_duration_label', 6, 'Route duration label', 'maps', 'broll',
        cues: {'route': 0.7, 'duration': 0.6}, keywords: ['mins', 'minute*', 'ghante', 'घंटे'], hold: 4, sfx: ['whoosh'],
        when: 'a journey and how long it took ("11 MINS" on the arc)', primary: 'map_route', fullscreen: true,
        slots: [..._route, PSlot('label', 'Duration label', initial: '11 MINS')], build: _routeDuration),
    DocPattern('signal_rings', 7, 'Signal / radio rings', 'maps', 'overlay',
        cues: {'radio': 1.0}, keywords: ['radio', 'रेडियो', 'signal*', 'सिग्नल', 'mayday', 'sos'], hold: 3.5, sfx: ['radio_crackle'],
        when: 'radio calls, signals, SOS from a place or vehicle', primary: 'signal_rings', slots: [PSlot('label', 'Label', initial: 'MAYDAY')], build: _signalRings),
    DocPattern('status_ring', 7, 'Status ring (spinning)', 'maps', 'overlay',
        cues: {'search': 0.3, 'radio': 0.3}, hold: 4, sfx: [], when: 'tracking one vehicle on a map (red dashed ring spinning)', primary: 'status_ring',
        slots: [PSlot('label', 'Label', initial: 'FAIRCHILD 571')], build: _statusRing),
    DocPattern('geo_label', 8, 'Geo label / path text', 'maps', 'overlay',
        cues: {'crash': 0.5, 'place': 0.3, 'concept': 0.25}, keywords: ['crash site', 'site', 'jagah', 'जगह'], hold: 3.5, sfx: ['pop'],
        when: 'naming a spot on terrain ("CRASH SITE" with a hooked pointer)', primary: 'geo_label', slots: [PSlot('text', 'Label', initial: 'CRASH SITE')], build: _geoLabel),
    DocPattern('search_sweep', 9, 'Search sweep', 'maps', 'broll',
        cues: {'search': 1.0}, keywords: ['helicopter', 'हेलीकॉप्टर', 'talash', 'तलाश', 'rescue'], hold: 4.5, sfx: ['whoosh'],
        when: '"a search began over X" (searchlight over the ground, place name on the snow)', primary: 'search_sweep', fullscreen: true,
        slots: [PSlot('place', 'Place on the ground', initial: 'ANDES'), PSlot('label', 'Small label', initial: 'SEARCH DAY 1'), PSlot('vehicle', 'Helicopter cut-out (top-down)', kind: 'media')],
        build: _searchSweep),
    DocPattern('sketch_map', 10, 'Sketch map + compass', 'maps', 'broll',
        cues: {'direction': 1.0}, keywords: ['which way', 'kis taraf', 'किस तरफ', 'disha', 'दिशा', 'compass'], hold: 5, sfx: ['paper', 'pop'],
        when: 'directions / "which way?" decisions', primary: 'sketch_map', fullscreen: true,
        slots: [PSlot('items', 'Directions (comma separated)', initial: 'WEST, EAST')], build: _sketchMap),

    // ===================================================== P-B evidence
    DocPattern('doc_highlight_circle', 11, 'Document highlight + pen circle', 'evidence', 'broll',
        cues: {'article': 1.0, 'quote': 0.35}, keywords: ['akhbar', 'अखबार', 'report', 'रिपोर्ट', 'according to', 'के मुताबिक'], hold: 5,
        follow: ['reenactment'], sfx: ['paper'], when: 'any article/news/web source is quoted — ALWAYS followed by a reenactment of the fact',
        primary: 'article', fullscreen: true, slots: _quote, build: _docHighlight),
    DocPattern('book_reveal_open', 12, 'Book reveal + open', 'evidence', 'broll',
        cues: {'book': 1.0}, keywords: ['kitab', 'किताब', 'book', 'likha', 'लिखा', 'author'], hold: 7, follow: ['reenactment'], sfx: ['paper', 'pop'],
        when: 'a book is named (6–10 s beat: cover rises, opens, highlights)', primary: 'book', fullscreen: true,
        slots: [PSlot('media', 'Cover photo (optional)', kind: 'media'), PSlot('title', 'Title', initial: 'MIRACLE IN THE ANDES'), PSlot('author', 'Author', initial: 'NANDO PARRADO'),
          PSlot('quote', 'Page text', initial: 'We had to survive, whatever it took.'), PSlot('highlight', 'Phrase to highlight', initial: 'whatever it took')],
        build: _book),
    DocPattern('zoom_out_to_source', 13, 'Zoom out to source', 'evidence', 'transition',
        cues: {'article': 0.4, 'archive': 0.3}, hold: 1.2, precede: ['reenactment_shot'], follow: ['doc_highlight_circle'], sfx: ['whoosh'],
        when: 'proving a claim just shown: pull back from the photo to the article it is in', primary: 'zoom_out_of_photo', build: _zoomOutToSource),
    DocPattern('source_tag', 14, 'Source tag pill', 'evidence', 'overlay',
        cues: {'article': 0.5, 'archive': 0.3}, keywords: ['source', 'सूत्र'], hold: 3, sfx: ['pop'], when: 'under any photo or page that needs its source',
        primary: 'source_tag', slots: [PSlot('source', 'Source', initial: 'Source – archive.org')], build: _sourceTag),
    DocPattern('grunge_photo_title', 15, 'Grunge photo title', 'evidence', 'broll',
        cues: {'organisation': 0.9}, keywords: ['team', 'टीम', 'club', 'क्लब', 'regiment'], hold: 4.5, sfx: ['typewriter', 'whoosh'],
        when: 'introducing a group / organisation with an archive photo', primary: 'photo_card', fullscreen: true,
        slots: [..._photo, PSlot('title', 'Title', initial: 'OLD CHRISTIANS CLUB'), PSlot('key', 'Key phrase (cyan)', initial: 'RUGBY TEAM')], build: _grungeTitle),
    DocPattern('note_card', 16, 'Note card (key concept)', 'evidence', 'broll',
        cues: {'concept': 1.0}, keywords: ['plan', 'योजना', 'pact', 'समझौता', 'rule', 'नियम', 'kasam', 'कसम'], hold: 3, sfx: ['paper'],
        when: 'an abstract key concept: PLAN, PACT, RULE, PROMISE', primary: 'note_card', fullscreen: true, slots: [PSlot('text', 'Word', initial: 'PACT')], build: _noteCard),
    DocPattern('photo_wall', 17, 'Archive photo wall', 'evidence', 'broll',
        cues: {'archive': 0.9, 'recap': 0.3}, keywords: ['photo', 'तस्वीर', 'archive'], hold: 6, sfx: ['whoosh', 'shutter'],
        when: 'an archive montage of who they were', primary: 'photo_wall', fullscreen: true,
        slots: [PSlot('photos', 'Photos', kind: 'medias')], build: _photoWall),
    DocPattern('handwrite_card', 18, 'Handwritten note', 'evidence', 'broll',
        cues: {'handwritten': 1.0}, keywords: ['chitthi', 'चिट्ठी', 'letter', 'note', 'diary', 'डायरी'], hold: 4, follow: ['reenactment'],
        sfx: ['marker_squeak'], when: 'a handwritten note/letter/diary is quoted', primary: 'handwrite_card', fullscreen: true,
        slots: [PSlot('text', 'Text', initial: 'We are alive')], build: _handwrite),
    DocPattern('emblem_badge', 19, 'Emblem / crest badge', 'evidence', 'overlay',
        cues: {'organisation': 0.7}, hold: 3, sfx: ['glitch'], when: 'an organisation tied to a place (our own crest, glitch entrance)', primary: 'badge',
        slots: [PSlot('label', 'Name', initial: 'URUGUAYAN AIR FORCE')], build: _emblem),
    DocPattern('surface_labels', 20, 'Surface labels (role + name)', 'character', 'overlay',
        cues: {'person': 0.7}, keywords: ['naam', 'नाम', 'named', 'captain', 'pilot'], hold: 3, sfx: ['pop'],
        when: 'naming a person in the picture (small red role over a big name, no box)', primary: 'character_label',
        slots: [PSlot('name', 'Name', initial: 'NANDO PARRADO'), PSlot('role', 'Role', initial: 'SURVIVOR')], build: _surfaceLabels),

    // ===================================================== P-C data, HUD, overlays
    DocPattern('unit_chart', 21, 'Unit chart (pictograms)', 'data', 'broll',
        cues: {'total_breakdown': 1.0, 'people_count': 0.8}, keywords: ['passengers', 'यात्री', 'log', 'लोग', 'mein se', 'में से'], hold: 5,
        sfx: ['pop'], when: 'a total and its breakdown ("45 PASSENGERS: 19 players…")', primary: 'unit_chart', fullscreen: true,
        slots: [PSlot('total', 'Total', initial: '45'), PSlot('label', 'Total label', initial: '45 PASSENGERS'), PSlot('groups', 'Groups count:label (comma separated)', initial: '19:PLAYERS, 26:FAMILY & CREW')],
        build: _unitChart),
    DocPattern('people_grid_tally', 22, 'Survivor tally grid', 'data', 'broll',
        cues: {'survivors': 1.0}, keywords: ['survivors', 'bache', 'बचे', 'zinda', 'ज़िंदा'], hold: 5, sfx: ['pop', 'braam'],
        when: 'survivor / casualty tallies (alive glow red, dead fade grey)', primary: 'people_grid', fullscreen: true,
        slots: [PSlot('total', 'Total', initial: '45'), PSlot('alive', 'Alive', initial: '16'), PSlot('label', 'Count text', initial: '16 SURVIVORS')], build: _peopleGrid),
    DocPattern('stat_figure', 23, 'Stat figure (value changing)', 'data', 'broll',
        cues: {'stat_change': 1.0}, keywords: ['badh', 'बढ़', 'ghat', 'घट', 'kam', 'कम'], hold: 4, sfx: ['tick'],
        when: 'a value changes over time (weight, money, fuel, temperature)', primary: 'stat_figure', fullscreen: true,
        slots: [PSlot('from', 'From', initial: '80'), PSlot('to', 'To', initial: '40'), PSlot('unit', 'Unit', initial: 'KG'), PSlot('label', 'Label', initial: 'BODY WEIGHT')],
        build: _statFigure),
    DocPattern('comparison_split', 24, 'Comparison split', 'data', 'broll',
        cues: {'comparison': 1.0}, keywords: ['lekin', 'लेकिन', 'jabki', 'जबकि', 'vs'], hold: 4.5, sfx: ['whoosh'],
        when: 'two clashing numbers side by side', primary: 'split_screen', fullscreen: true,
        slots: [PSlot('a', 'Left label', initial: 'OFFICIAL'), PSlot('a_value', 'Left value', initial: '8 DAYS'), PSlot('b', 'Right label', initial: 'REALITY'), PSlot('b_value', 'Right value', initial: '72 DAYS')],
        build: _split),
    DocPattern('gauge_hud', 25, 'Gauge HUD ruler', 'data', 'overlay',
        cues: {'gauge': 1.0}, keywords: ['feet', 'फीट', 'altitude', 'ऊंचाई', 'speed', 'रफ्तार'], hold: 4, sfx: ['tick'],
        when: 'altitude / speed / depth changing during action', primary: 'gauge_hud',
        slots: [PSlot('from', 'From', initial: '20000'), PSlot('to', 'To', initial: '13000'), PSlot('unit', 'Unit', initial: 'FT')], build: _gauge),
    DocPattern('clock_stamp', 26, 'Clock / date stamp', 'data', 'overlay',
        cues: {'date': 0.9, 'time': 1.0, 'day_count': 1.0}, keywords: ['tarikh', 'तारीख', 'din', 'दिन', 'baje', 'बजे'], hold: 3.5, sfx: ['typewriter'],
        when: 'an exact date / time / day count is spoken (typed bottom-left, digital font)', primary: 'clock_stamp',
        slots: [PSlot('lines', 'Lines (comma separated)', initial: 'DAY 61, 12 DEC 1972')], build: _clockStamp),
    DocPattern('stat_behind_silhouettes', 27, 'Stat behind silhouettes', 'data', 'broll',
        cues: {'number': 0.8, 'people_count': 0.4}, hold: 3.5, sfx: ['pop'], when: 'a striking number over a scene (yellow letters drop behind the people)',
        primary: 'letter_drop', slots: [PSlot('text', 'Stat', initial: '60KM'), PSlot('cutout', 'Foreground cut-out (PNG)', kind: 'media')], build: _statBehind),
    DocPattern('ui_toggle', 28, 'UI toggle', 'data', 'overlay',
        cues: {'device': 1.0}, keywords: ['chalu', 'चालू', 'band', 'बंद', 'switch', 'engine'], hold: 3, sfx: ['ui_click'],
        when: 'a device or system starts or stops', primary: 'ui_toggle', slots: [PSlot('label', 'Label', initial: 'RADIO')], build: _toggle),
    DocPattern('audio_wave_flag', 29, 'Audio wave + flag badge', 'data', 'broll',
        cues: {'broadcast': 1.0}, keywords: ['broadcast', 'प्रसारण', 'announcement', 'ऐलान'], hold: 4, sfx: ['radio_crackle'],
        when: 'a broadcast / announcement (waveform card + round flag)', primary: 'audio_wave', fullscreen: true,
        slots: [PSlot('country', 'Country', initial: 'Chile'), PSlot('label', 'Caption', initial: 'RADIO BROADCAST')], build: _audioWave),
    DocPattern('icon_sticker', 30, 'Icon sticker beside presenter', 'overlay', 'overlay',
        cues: {'list': 0.7, 'object': 0.3}, hold: 3, precede: ['presenter'], sfx: ['pop'],
        when: 'the presenter lists items on camera (yellow disc, icons swap on each noun)', primary: 'icon_sticker',
        slots: [PSlot('items', 'Items (comma separated)', initial: 'FOOD, WATER, FIRE')], build: _iconSticker),
    DocPattern('icon_drop', 31, 'Icon drop', 'overlay', 'overlay',
        cues: {'concept': 0.45, 'emphasis': 0.3}, keywords: ['stop', 'ruko', 'रुको', 'deal', 'haan', 'nahi', 'warning'], hold: 2.5, sfx: ['pop'],
        when: 'a one-word idea (STOP, deal, yes/no, warning) dropping in', primary: 'icon_drop',
        slots: [PSlot('icon', 'Icon (stop|check|cross|warning|heart)', initial: 'stop'), PSlot('label', 'Label', initial: 'STOP')], build: _iconDrop),
    DocPattern('social_cta', 32, 'Social CTA pill', 'presenter', 'overlay',
        cues: {'cta': 1.0}, hold: 2.8, precede: ['presenter'], sfx: ['pop'], when: '2–3 s into a presenter stint > 5 s, once per ~40 s, platforms rotate',
        primary: 'social_cta', slots: [PSlot('platform', 'Platform', initial: 'whatsapp'), PSlot('handle', 'Handle', initial: 'Mohitflix')], build: _socialCta),
    DocPattern('presenter_stats', 33, 'Presenter stat lines', 'presenter', 'overlay',
        cues: {'number': 0.6, 'date': 0.3}, hold: 3.5, precede: ['presenter'], sfx: ['typewriter'],
        when: 'numbers said on camera (typed white lines in the right third)', primary: 'presenter_stats',
        slots: [PSlot('lines', 'Lines (comma separated)', initial: '45 ON BOARD, 16 SURVIVED')], build: _presenterStats),
    DocPattern('kinetic_text', 34, 'Kinetic typed line', 'overlay', 'overlay',
        cues: {'quote': 0.5, 'emphasis': 0.4}, hold: 3, sfx: ['typewriter'], when: 'an emotional line to read on screen (newest letters red)',
        primary: 'typewriter', slots: [PSlot('text', 'Text', initial: 'THEY WERE ALONE')], build: _kinetic),

    // ===================================================== P-D transitions, mood, character FX
    DocPattern('zoom_blur', 35, 'Zoom blur', 'transition', 'transition',
        cues: {}, hold: 0.4, precede: ['doc_highlight_circle'], follow: ['reenactment_shot'], sfx: ['whoosh'],
        when: 'evidence → reenactment, macro → presenter, leaving an archive photo', primary: 'zoom_blur', build: _zoomBlur),
    DocPattern('debris_burst', 36, 'Debris burst', 'transition', 'transition',
        cues: {}, hold: 0.75, sfx: ['ice_crash'], when: 'the default scene change (ice/snow/dust shards burst at the lens)', primary: 'debris_burst', build: _debrisBurst),
    DocPattern('slide_film', 37, 'Slide film carousel', 'transition', 'transition',
        cues: {'archive': 0.5}, hold: 1.0, sfx: ['shutter'], when: 'reconstruction → the real archive photo', primary: 'slide_film', build: _slideFilm),
    DocPattern('slice', 38, 'Slice bands', 'transition', 'transition',
        cues: {}, hold: 0.4, sfx: ['whoosh'], when: 'energetic change between two related shots', primary: 'slice', build: _slice),
    DocPattern('slant_wipe', 38, 'Slant wipe', 'transition', 'transition',
        cues: {}, hold: 0.75, sfx: ['whoosh'], when: 'a panel slides in at 10° (map compresses aside)', primary: 'slant_wipe', build: _slantWipe),
    DocPattern('shrink_to_card', 38, 'Shrink to card', 'transition', 'transition',
        cues: {}, hold: 0.8, sfx: ['whoosh'], when: 'footage becomes a card on a grunge backdrop', primary: 'shrink_to_card', build: _shrinkToCard),
    DocPattern('emerge', 38, 'Emerge from point', 'transition', 'transition',
        cues: {}, hold: 0.75, sfx: ['whoosh'], when: 'the next card grows out of a point/layer', primary: 'emerge', build: _emerge),
    DocPattern('mood_flood', 39, 'Mood flood (red dread)', 'mood', 'mood',
        cues: {'dread': 1.0}, keywords: ['maut', 'मौत', 'death', 'umeed khatam', 'उम्मीद खत्म'], hold: 3, follow: ['cut_to_black', 'presenter'],
        sfx: ['braam'], when: 'death, despair or a negative twist (on the pause; then hard cut)', primary: 'mood_flood', build: _moodFlood),
    DocPattern('grade_swap', 39, 'Grade swap (hope)', 'mood', 'mood',
        cues: {'hope': 1.0}, keywords: ['umeed', 'उम्मीद', 'zinda', 'ज़िंदा', 'rescued', 'chamatkar'], hold: 3, sfx: ['riser'],
        when: 'hope / rescue: snap to saturated warm colour', primary: 'grade_swap', build: _gradeSwap),
    DocPattern('ink_bleed_duotone', 40, 'Ink bleed duotone', 'transition', 'transition',
        cues: {'turning_point': 0.8}, keywords: ['achanak', 'अचानक', 'suddenly', 'tabhi', 'तभी'], hold: 1.2, sfx: ['whoosh'],
        when: 'turning points (navy duotone of the same image bleeds in)', primary: 'ink_bleed', build: _inkDuotone),
    DocPattern('cut_to_black', 41, 'Cut to black + silence', 'mood', 'mood',
        cues: {'crash': 0.6}, hold: 1.5, precede: ['crash_to_black'], follow: ['presenter'], sfx: ['impact'],
        when: 'right after the crash / the worst moment (never followed by a presenter joke)', primary: 'cut_to_black', build: _cutToBlack),
    DocPattern('lightning', 41, 'Lightning flash', 'mood', 'overlay',
        cues: {'lightning': 1.0}, keywords: ['bijli', 'बिजली', 'toofan', 'तूफान', 'storm'], hold: 1.5, sfx: ['thunder'],
        when: 'storms, lightning, thunder', primary: 'lightning', build: _lightning),
    DocPattern('speech_bubble_comic', 42, 'Comic speech bubble', 'character', 'overlay',
        cues: {'dialogue': 1.0, 'quote': 0.6}, keywords: ['kaha', 'कहा', 'bola', 'बोला', 'said'], hold: 3, sfx: ['pop'],
        when: 'dialogue / a character speaks (white comic bubble, typed caps)', primary: 'speech_bubble',
        slots: [PSlot('text', 'Text', initial: 'WE ARE ALIVE!')], build: _bubble),
    DocPattern('swing_in', 43, 'Swing in', 'character', 'overlay',
        cues: {'emphasis': 0.25}, hold: 2.5, sfx: ['whoosh'], when: 'a card or cut-out swings in big (background blur → sharp)', primary: 'swing_in',
        slots: [PSlot('text', 'Text', initial: 'SURVIVORS')], build: _swingIn),
    DocPattern('presenter_punch_in', 43, 'Presenter punch-in', 'presenter', 'transition',
        cues: {'emphasis': 0.4, 'question': 0.2}, hold: 0.25, sfx: ['whoosh'], when: 'back to the presenter on emphasis (150% blurred → 100% in 0.25 s)',
        primary: 'punch_in', build: _punchIn),
    DocPattern('swap_layer', 43, 'Swap layer', 'character', 'overlay',
        cues: {}, hold: 3, sfx: ['pop'], when: 'one cut-out swapped for another in place', primary: 'swap_layer',
        slots: [PSlot('text', 'Before', initial: 'BEFORE'), PSlot('text2', 'After', initial: 'AFTER')], build: _swapLayer),
    DocPattern('rack_focus', 43, 'Rack focus', 'character', 'overlay',
        cues: {'witness': 0.3}, hold: 3.5, sfx: [], when: 'shifting attention between two subjects', primary: 'set_dof', build: _rackFocus),
    DocPattern('eye_zoom_through', 43, 'Eye zoom through', 'transition', 'transition',
        cues: {'witness': 0.5}, hold: 1.2, sfx: ['riser'], when: 'into a memory through the eye', primary: 'push_through', build: _eyeZoom),
    DocPattern('powder_burst', 47, 'Powder burst', 'transition', 'transition',
        cues: {'snow': 0.4, 'desert': 0.4}, hold: 0.6, sfx: ['whoosh'], when: 'in/out of the presenter in snowy or desert stories, any scene change (signature)',
        primary: 'powder_burst', build: _powderBurst),
    DocPattern('eye_reflection', 48, 'Eye reflection', 'transition', 'transition',
        cues: {'witness': 1.0}, keywords: ['dekha', 'देखा', 'saw', 'witness'], hold: 0.5, sfx: ['whoosh'], when: 'event → a witness reacting', primary: 'eye_reflection',
        build: _eyeReflection),
    DocPattern('holes', 49, 'Burn holes', 'transition', 'transition',
        cues: {}, hold: 0.4, sfx: ['impact'], when: 'harsh exit from a gruesome still to the presenter', primary: 'holes', build: _holes),
    DocPattern('shatter_ice', 49, 'Ice shatter', 'transition', 'transition',
        cues: {'crash': 0.3}, hold: 1.0, sfx: ['ice_crash'], when: 'a frozen image breaking apart', primary: 'shatter', build: _shatterIce),
    DocPattern('spotlight_subject', 50, 'Spotlight subject', 'character', 'mood',
        cues: {'pain': 0.8, 'person': 0.3}, keywords: ['dard', 'दर्द', 'ghayal', 'घायल'], hold: 3.5, sfx: ['heartbeat'],
        when: 'pointing at one person among many, injury or danger (others mono, red tint)', primary: 'spotlight_subject',
        slots: [PSlot('cutout', 'Subject cut-out (PNG)', kind: 'media')], build: _spotlight),
    DocPattern('pulse', 51, 'Pain pulse', 'mood', 'mood',
        cues: {'pain': 0.7}, keywords: ['cheekh', 'चीख', 'scream'], hold: 3, sfx: ['heartbeat'], when: 'pain or a scream (red pulse 1 Hz + heartbeat)',
        primary: 'pulse', build: _pulse),
    DocPattern('montage', 52, 'Smash recap montage', 'evidence', 'broll',
        cues: {'recap': 1.0}, keywords: ['yaad karo', 'याद करो', 'flashback', 'remember'], hold: 3.5, follow: ['presenter'], sfx: ['glitch'],
        when: 'a one-breath recap / flashback before the presenter', primary: 'montage', fullscreen: true,
        slots: [PSlot('photos', 'Photos / clips', kind: 'medias')], build: _montage),
    DocPattern('speech_bubble_puff', 53, 'Bubble with puff exit', 'character', 'overlay',
        cues: {'dialogue': 0.5}, hold: 3, sfx: ['pop'], when: 'a short shout that vanishes in a cartoon puff', primary: 'speech_bubble',
        slots: [PSlot('text', 'Text', initial: 'HELP!')], build: _bubblePuff),
    DocPattern('sun_glare_entry', 54, 'Sun glare entry', 'mood', 'transition',
        cues: {'sunrise': 0.8, 'hope': 0.3}, keywords: ['subah', 'सुबह', 'suraj', 'सूरज', 'sunrise'], hold: 0.75, sfx: ['riser'],
        when: 'a new morning / sunlight (overexposed bloom fading in)', primary: 'exposure_in', build: _sunGlare),
    DocPattern('article_focus', 55, 'Article focus punch', 'evidence', 'broll',
        cues: {'article': 0.8}, keywords: ['website', 'वेबसाइट', 'tweet', 'post'], hold: 4.5, follow: ['reenactment'], sfx: ['paper', 'whoosh'],
        when: 'a web page / dark-theme article: slide up over the shot and punch into the mark', primary: 'article', fullscreen: true, slots: _quote,
        build: _articleFocus),
    DocPattern('circle_mark', 56, 'Circle mark on photo', 'evidence', 'overlay',
        cues: {'object': 0.4, 'witness': 0.25}, keywords: ['dekho', 'देखो', 'yahan', 'यहां', 'notice', 'look'], hold: 2.5, sfx: ['marker_squeak'],
        when: 'a critical detail in a photo (red circle draws clockwise from 12)', primary: 'circle_mark', build: _circleMark),
    DocPattern('inset_circle', 57, 'Inset circle', 'evidence', 'overlay',
        cues: {'object': 0.8, 'radio': 0.4}, hold: 3, sfx: ['pop'], when: 'an object/place a character mentions (round inset grows from a point)',
        primary: 'inset_circle', slots: [PSlot('media', 'Object photo', kind: 'media'), PSlot('label', 'Label', initial: 'RADIO')], build: _insetCircle),
    DocPattern('quote_hole', 58, 'Quote in a torn hole', 'evidence', 'broll',
        cues: {'second_source': 1.0}, keywords: ['podcast', 'interview', 'इंटरव्यू'], hold: 4.5, follow: ['reenactment'], sfx: ['paper'],
        when: 'a softer second source (podcast, show, interview)', primary: 'quote_hole', fullscreen: true,
        slots: [PSlot('media', 'Plate photo', kind: 'media'), PSlot('source', 'Source', initial: 'PODCAST, 2019'), PSlot('quote', 'Quote', initial: 'We made a pact that day.'), PSlot('highlight', 'Highlight', initial: 'a pact')],
        build: _quoteHole),
    DocPattern('list_card', 59, 'List card', 'evidence', 'broll',
        cues: {'list': 1.0}, keywords: ['saman', 'सामान', 'list', 'cheezen', 'चीजें'], hold: 4, sfx: ['marker_squeak', 'pop'],
        when: 'an inventory, list or plan written item by item', primary: 'list_card', fullscreen: true,
        slots: [PSlot('items', 'Items (comma separated)', initial: 'CHOCOLATE, WINE, CRACKERS')], build: _listCard),
    DocPattern('stain_doodle', 60, 'Stain + doodle', 'evidence', 'overlay',
        cues: {'technique': 1.0}, keywords: ['trick', 'tarika', 'तरीका', 'jugaad', 'जुगाड़'], hold: 4, sfx: ['marker_squeak'],
        when: 'explaining a technique / trick on a top-down plate', primary: 'doodle', build: _stainDoodle),
    DocPattern('calendar_flip', 61, 'Calendar flip', 'data', 'broll',
        cues: {'duration': 0.9, 'day_count': 0.5}, keywords: ['kitne din', 'कितने दिन', 'how many days', 'hafte', 'हफ्ते'], hold: 4, sfx: ['paper'],
        when: 'a duration in days/weeks or "kitne din?" (tear-off calendar counting)', primary: 'calendar_flip', fullscreen: true,
        slots: [PSlot('from', 'From day', initial: '1'), PSlot('to', 'To day', initial: '72')], build: _calendarFlip),
    DocPattern('clock_overlay', 62, 'Giant clock overlay', 'data', 'overlay',
        cues: {'duration': 0.6, 'time': 0.3}, keywords: ['ghante', 'घंटे', 'hours', 'samay', 'समय'], hold: 3.5, sfx: ['clock_tick'],
        when: 'time passing / hours of waiting (30% clock face, hands spinning)', primary: 'clock_overlay',
        slots: [PSlot('text', 'Duration text', initial: '8 DAYS')], build: _clockOverlay),
    DocPattern('stat_title', 63, 'Stat title', 'data', 'broll',
        cues: {'number': 0.7, 'emphasis': 0.3}, hold: 3, sfx: ['pop'], when: 'a big number with one line of context (number line 1.6×)', primary: 'stat_title',
        fullscreen: true, slots: [PSlot('line1', 'Number', initial: '72 DAYS'), PSlot('line2', 'Context', initial: 'IN THE ANDES')], build: _statTitle),
    DocPattern('social_bug', 64, 'Social bug (disintegrate)', 'presenter', 'overlay',
        cues: {'cta': 0.6}, hold: 2.8, precede: ['presenter'], sfx: ['pop'], when: 'the channel bug on a long presenter stint (exits in pixels)',
        primary: 'social_cta', slots: [PSlot('platform', 'Platform', initial: 'youtube'), PSlot('handle', 'Handle', initial: 'Mohitflix')], build: _socialBug),
    DocPattern('map_labels_typed', 65, 'Typed map labels', 'maps', 'broll',
        cues: {'place': 0.7}, hold: 4, sfx: ['typewriter'], when: 'several countries named in one breath (labels typed in, staggered)', primary: 'map',
        fullscreen: true, slots: [PSlot('places', 'Countries (comma separated)', initial: 'Chile, Argentina, Uruguay')], build: _mapLabelsTyped),

    // ===================================================== existing MotionAI features used by the clips
    DocPattern('presenter', 0, 'Presenter (A-roll)', 'presenter', 'presenter',
        cues: {'presenter': 1.0, 'question': 0.5, 'cta': 0.4}, keywords: ['aap', 'आप', 'dosto', 'दोस्तों', 'you'], hold: 4, enter: 'cut',
        when: 'every 12–25 s, before a climax, questions to the viewer (warm grade)', primary: 'aroll',
        slots: [PSlot('media', 'Presenter clip', kind: 'media', media: 'video')], build: _presenter),
    DocPattern('reenactment_shot', 0, 'Reenactment shot', 'shot', 'broll',
        cues: {}, hold: 4, precede: ['doc_highlight_circle', 'book_reveal_open'], sfx: [], when: 'right after evidence: reconstruct the fact (add_shot with mannequins / cut-outs)',
        primary: 'add_shot', slots: [PSlot('media', 'Plate photo', kind: 'media'), PSlot('cutouts', 'Cut-outs', kind: 'medias')], build: _reenactment),
    DocPattern('crane_down_reveal', 0, 'Crane-down reveal', 'shot', 'broll',
        cues: {'terrain': 0.2}, hold: 4.5, when: 'opening a location: tilt down from sky to the scene', primary: 'add_shot', slots: _photo, build: _craneDown),
    DocPattern('push_between_subjects', 0, 'Push between subjects', 'shot', 'broll',
        cues: {'person': 0.2}, hold: 4, when: 'moving through a group of people', primary: 'add_shot', slots: [..._photo, PSlot('cutouts', 'Cut-outs', kind: 'medias')], build: _pushBetween),
    DocPattern('rack_focus_encounter', 0, 'Rack-focus encounter', 'shot', 'broll',
        cues: {'witness': 0.3}, hold: 4, when: 'two people meet / one notices the other', primary: 'set_dof', slots: _photo, build: _rackEncounter),
    DocPattern('fog_tracking', 0, 'Fog tracking + gauge', 'shot', 'broll',
        cues: {'gauge': 0.5, 'snow': 0.2}, hold: 4.5, when: 'a plane/vehicle moving through fog, altitude falling', primary: 'add_shot', slots: _photo, build: _fogTracking),
    DocPattern('human_detail_insert', 0, 'Human detail insert', 'shot', 'broll',
        cues: {'pain': 0.2, 'object': 0.2}, hold: 2.5, when: 'hands, eyes, objects: a tight insert between wide shots', primary: 'camera push', slots: _photo, build: _detailInsert),
    DocPattern('crash_to_black', 0, 'Crash → black', 'mood', 'broll',
        cues: {'crash': 1.0}, keywords: ['crash', 'क्रैश', 'takra', 'टकरा', 'dhamaka', 'धमाका'], hold: 2.5, follow: ['cut_to_black'], sfx: ['impact'],
        when: 'the crash itself: impact shake, then hard cut to black and silence', primary: 'camera_shake', slots: _photo, build: _crashToBlack),
    DocPattern('censor_bar', 0, 'Censor bar', 'character', 'overlay',
        cues: {}, hold: 3, when: 'ALWAYS over AI likenesses of real people', primary: 'censor_bar', build: _censor),
    DocPattern('push_through', 0, 'Push through', 'transition', 'transition',
        cues: {}, hold: 1.2, sfx: ['whoosh'], when: 'flying through a door/window into the next scene', primary: 'push_through', build: _pushThrough),
    DocPattern('foreground_wipe', 0, 'Foreground wipe', 'transition', 'transition',
        cues: {}, hold: 0.8, sfx: ['whoosh'], when: 'hiding a cut behind something passing the lens', primary: 'foreground_wipe', build: _foregroundWipe),
    DocPattern('map_drop', 0, 'Map drop / cloud wipe', 'transition', 'transition',
        cues: {}, hold: 1.5, precede: ['satellite_country_map'], sfx: ['whoosh'], when: 'from a map down through clouds to the place', primary: 'map_drop', build: _mapDrop),
    DocPattern('flash_cut', 0, 'Flash cut', 'transition', 'transition',
        cues: {}, hold: 0.5, sfx: ['impact'], when: 'impact cut on a beat / light flash into the presenter', primary: 'flash_cut', build: _flashCut),
    DocPattern('light_leak_wipe', 0, 'Light leak wipe', 'transition', 'transition',
        cues: {}, hold: 1.0, sfx: ['whoosh'], when: 'warm, soft cut into the presenter', primary: 'light_leak_wipe', build: _lightLeak),
  ];

  // ============================================================ builders

  static List<PStep> _countryMap(PatternCtx c) {
    final places = c.places();
    final city = c.s('city');
    return [
      PStep('map', [
        [c.call('map', 'map', {'countries': places, 'focus': places.first, 'style': 'satellite', 'fill_opacity': 0.62, 'stroke_width': 1.5, 'label_size': 0.06})],
        [c.comp('map', 'map', {'countries': places, 'focus': places.first, 'style': 'dark'})],
        [c.text('label', places.first.toUpperCase(), size: 0.09, at: c.rv)],
      ]),
      if (city.isNotEmpty)
        PStep('city', [
          [c.text('city', city.toUpperCase(), size: 0.032, color: '#000000', box: '#FFFFFF', weight: 800, y: c.h * 0.58, at: c.rv + 0.5, shadow: false, width: c.w * 0.3)],
        ], optional: true),
    ];
  }

  static List<PStep> _routeFollow(PatternCtx c) {
    final from = c.s('from', 'Uruguay'), to = c.s('to', 'Chile');
    final v = c.media('vehicle');
    return [
      PStep('route', [
        [
          c.call('route_follow', 'route', {
            'from': from, 'to': to, 'arrow_head': true, 'line_style': c.s('line_style', 'solid'), 'orient': true, 'trail_fade': true, 'style': 'satellite',
            'land_highlight': {'fill': '#A83232', 'label': to.toUpperCase()}, if (v != null) 'vehicle': v.id,
          }),
        ],
        [c.comp('route_follow', 'route', {'from': from, 'to': to})],
        [c.comp('map', 'route', {'countries': [from, to], 'route': [from, to], 'focus': to, 'style': 'dark'})],
        [c.text('label', '${from.toUpperCase()}  →  ${to.toUpperCase()}', size: 0.07, at: c.rv)],
      ]),
    ];
  }

  static List<PStep> _zoomPunch(PatternCtx c) {
    final places = c.places();
    final at = math.max(c.rv, c.end - 0.7);
    return [
      PStep('map', [
        [c.comp('map', 'map', {'countries': places, 'focus': places.first, 'style': 'dark'})],
        [c.text('label', places.first.toUpperCase(), size: 0.09)],
      ]),
      PStep('punch', [
        [{'op': 'camera_move', 'preset': 'punch_in', 'point': [c.w / 2, c.h / 2], 'amount': 2.6, 'start': at, 'duration': 0.45}],
        [
          {'op': 'camera_move', 'preset': 'zoom_in_2d', 'amount': 160, 'start': at, 'duration': 0.45, 'ease': 'ease_in'},
          {'op': 'camera_move', 'preset': 'zoom_out_2d', 'amount': 160, 'start': c.end - 1 / 30, 'duration': 1 / 30, 'ease': 'linear'},
        ],
      ], optional: true),
    ];
  }

  static List<PStep> _tilt3d(PatternCtx c) {
    final places = c.places(const ['Chile', 'Argentina']);
    final label = c.upper('terrain', 'ANDES');
    return [
      PStep('map', [
        [c.call('map', 'map', {'countries': places, 'focus': places.first, 'style': 'satellite', 'tilt': 38, 'tilt_at': 0.6})],
        [c.comp('map', 'map', {'countries': places, 'focus': places.first, 'style': 'dark'})],
        [_Kit.backdrop(c, 'bg', '#1C2B33', '#070C10')],
      ]),
      PStep('terrain', [
        [c.call('terrain_label', 'terrain', {'map': c.id('map'), 'text': label, 'spacing': 0.6, 'glyphs': 'peaks'}, at: c.t(0.8))],
        [
          c.text('terrain', _Kit.spaced(label), size: 0.05, weight: 800, animator: 'fade_up', animDur: 0.8, at: c.t(0.8), y: c.h * 0.56),
          c.rot('terrain', -12),
        ],
      ]),
    ];
  }

  static List<PStep> _ghost(PatternCtx c) {
    final country = c.places().first;
    return [
      PStep('map', [
        [c.comp('map', 'map', {'countries': [country], 'focus': country, 'style': 'dark'})],
        [_Kit.backdrop(c, 'bg', '#1C2B33', '#070C10')],
      ], optional: true),
      PStep('ghost', [
        [c.call('map_watermark', 'ghost', {'map': c.id('map'), 'code': country, 'opacity': 0.6, 'rotate': 'auto'})],
        [
          c.text('ghost', country.toUpperCase(), size: 0.35, animator: 'fade_up', animDur: 0.9, x: c.w * 0.58, width: c.w * 1.7, height: c.h * 0.6, shadow: false),
          c.rot('ghost', -14),
          c.set('ghost', 'opacity', 55),
        ],
      ]),
    ];
  }

  static List<PStep> _routeDuration(PatternCtx c) {
    final from = c.s('from', 'Uruguay'), to = c.s('to', 'Chile');
    final label = c.upper('label', '11 MINS');
    return [
      PStep('route', [
        [
          c.comp('map', 'map', {'countries': [from, to], 'focus': to, 'style': 'dark'}),
          c.call('map_route', 'route', {'map': c.id('map'), 'from': from, 'to': to, 'label': label, 'label_at': 0.5, 'follow_tangent': true}),
        ],
        [
          c.comp('map', 'map', {'countries': [from, to], 'route': [from, to], 'focus': to, 'style': 'dark'}),
          c.text('label', label, size: 0.06, at: c.rv, animator: 'slide_up', animDur: 0.4, y: c.h * 0.42),
          c.rot('label', -8),
        ],
        [c.text('label', '${from.toUpperCase()} → ${to.toUpperCase()}  $label', size: 0.06, at: c.rv)],
      ]),
    ];
  }

  static List<PStep> _signalRings(PatternCtx c) {
    final x = c.n('x', c.w * 0.5), y = c.n('y', c.h * 0.48);
    final color = c.s('color', '#E01818');
    final label = c.upper('label', '');
    return [
      PStep('rings', [
        [c.call('signal_rings', 'rings', {'x': x, 'y': y, 'color': color, 'count': 3, 'period': 0.75, 'flatten': 0.35, 'max_radius': c.h * 0.22})],
        _Kit.rings(c, 'rings', x, y, color, radius: c.h * 0.22),
      ]),
      if (label.isNotEmpty)
        PStep('label', [
          [c.text('label', label, size: 0.04, y: y + c.h * 0.14, at: c.rv, color: '#FFFFFF', weight: 800)],
        ], optional: true),
    ];
  }

  static List<PStep> _statusRing(PatternCtx c) {
    final x = c.n('x', c.w * 0.5), y = c.n('y', c.h * 0.5);
    final r = c.h * 0.11;
    final turns = c.d / 4;
    return [
      PStep('ring', [
        [c.call('status_ring', 'ring', {'x': x, 'y': y, 'color': '#E01818', 'dashed': true, 'spin': 4, 'radius': r})],
        [
          c.shape('ring', 'ellipse', r * 2, r * 2, x, y, fill: 'none', stroke: '#E01818', strokeWidth: 6, dash: [22, 14]),
          c.kf('ring', 'rotation', c.start, [0, 0, 0], 'linear'),
          c.kf('ring', 'rotation', c.end, [0, 0, 360 * turns], 'linear'),
          ...c.pop('ring', c.start, dur: 0.3),
        ],
      ]),
      if (c.s('label').isNotEmpty)
        PStep('label', [
          [c.text('label', c.upper('label', ''), size: 0.032, weight: 800, x: x, y: y + r + c.h * 0.04, at: c.rv, animator: 'typewriter', animDur: 0.6)],
        ], optional: true),
    ];
  }

  static List<PStep> _geoLabel(PatternCtx c) {
    final text = c.upper('text', 'CRASH SITE');
    final x = c.n('x', c.w * 0.55), y = c.n('y', c.h * 0.55);
    return [
      PStep('label', [
        [c.call('geo_label', 'geo', {'text': text, 'at': [x, y], 'pointer': 'hook'}, at: c.rv)],
        [c.comp('character_label', 'geo', {'text': text, 'x': x, 'y': y, 'style': 'black'}, at: c.rv)],
        [
          c.shape('hook', 'line', 10, 10, 0, 0, fill: 'none', stroke: '#FFFFFF', strokeWidth: 4, at: c.rv, points: [[x, y], [x + c.w * 0.04, y - c.h * 0.09], [x + c.w * 0.1, y - c.h * 0.09]]),
          ...c.drawOn('hook', c.rv, dur: 0.3),
          c.text('geo', text, size: 0.04, weight: 900, x: x + c.w * 0.2, y: y - c.h * 0.09, align: 'left', width: c.w * 0.2, at: c.rv + 0.25, animator: 'typewriter', animDur: 0.5),
        ],
      ]),
    ];
  }

  static List<PStep> _searchSweep(PatternCtx c) {
    final place = c.upper('place', 'ANDES');
    final label = c.upper('label', 'SEARCH');
    final v = c.media('vehicle');
    final snow = c.tone == 'snow' || c.tone == 'neutral';
    final pts = [
      [c.w * 0.35, c.h * 0.45], [c.w * 0.58, c.h * 0.55], [c.w * 0.5, c.h * 0.38], [c.w * 0.66, c.h * 0.5],
    ];
    return [
      PStep('sweep', [
        [c.call('search_sweep', 'sweep', {'place': place, 'label': label, if (v != null) 'vehicle': v.id, 'beam_size': 0.12, 'snow': snow, 'duration': c.d})],
        [
          _Kit.backdrop(c, 'ground', '#5E6A72', '#2A3238'),
          c.fx(c.id('ground'), 'grain', {'amount': 25}),
          c.text('place', place, size: 0.17, color: _Kit.darkRed, animator: null, width: c.w * 1.2, height: c.h * 0.4, shadow: false),
          c.rot('place', -6),
          c.set('place', 'opacity', 85),
          c.shape('beam', 'ellipse', c.w * 0.24, c.w * 0.16, pts[0][0], pts[0][1], fill: '#FFFFFF'),
          c.fx(c.id('beam'), 'blur', {'amount': 45}),
          c.set('beam', 'opacity', 50),
          for (int i = 0; i < pts.length; i++) c.kf('beam', 'position', c.start + c.d * i / (pts.length - 1), [pts[i][0], pts[i][1], 0], 'easy_ease'),
          if (v != null) c.media2('heli', v, widthPx: c.w * 0.08, x: pts[0][0], y: pts[0][1] - c.h * 0.08),
          if (v != null)
            for (int i = 0; i < pts.length; i++) c.kf('heli', 'position', c.start + c.d * i / (pts.length - 1) + 0.15, [pts[i][0], pts[i][1] - c.h * 0.08, 0], 'easy_ease'),
          c.text('label', label, size: 0.03, weight: 700, x: c.w * 0.2, y: c.h * 0.86, align: 'left', width: c.w * 0.3, at: c.rv, animator: 'typewriter', animDur: 0.7),
          if (snow) c.solid('snow', '#00000000'),
          if (snow) c.fx(c.id('snow'), 'particles', {'kind': 'snow', 'amount': 45, 'speed': 1.2}),
        ],
      ]),
    ];
  }

  static List<PStep> _sketchMap(PatternCtx c) {
    final dirs = c.list('items', const ['WEST', 'EAST']);
    final cx = c.w * 0.74, cy = c.h * 0.3, cr = c.h * 0.11;
    return [
      PStep('sketch', [
        [
          c.call('sketch_map', 'sketch', {
            'paper': 'torn',
            'compass': {'x': cx, 'y': cy, 'size': cr * 2, 'heading': [{'at': 0, 'deg': -180}, {'at': 1.0, 'deg': 0}]},
            'directions': [for (int i = 0; i < dirs.length; i++) {'label': dirs[i], 'side': i.isEven ? 'left' : 'right', 'arrow': true, 'at': 1.2 + i * 1.2}],
          }),
        ],
        [
          _Kit.backdrop(c, 'bg', '#123A3E', '#061A1C'),
          c.shape('paper', 'rect', c.w * 0.72, c.h * 0.78, c.w * 0.46, c.h * 0.52, fill: '#E8DCC0', fill2: '#CDBB94'),
          c.fx(c.id('paper'), 'paper', {'amount': 80}),
          c.fx(c.id('paper'), 'torn_edge', {'side': 'top', 'amount': 60}),
          c.rot('paper', -2),
          c.shape('compass', 'ellipse', cr * 2, cr * 2, cx, cy, fill: '#2A2E33', stroke: '#C8CED6', strokeWidth: 8),
          c.shape('needle', 'polygon', cr * 0.35, cr * 1.7, cx, cy, fill: _Kit.red, sides: 3),
          c.kf('needle', 'rotation', c.start, [0, 0, -180], 'ease_out'),
          c.kf('needle', 'rotation', c.start + 1.0, [0, 0, 8], 'elastic'),
          c.kf('needle', 'rotation', c.start + 1.6, [0, 0, 0], 'easy_ease'),
          for (int i = 0; i < dirs.length; i++) ...[
            c.text('dir$i', dirs[i].toUpperCase(), size: 0.06, color: '#2A1A10', font: 'Special Elite', weight: 400, x: i.isEven ? c.w * 0.26 : c.w * 0.62,
                y: c.h * 0.62, width: c.w * 0.3, at: c.start + 1.2 + i * 1.2, animator: 'typewriter', animDur: 0.5, shadow: false),
            c.shape('arrow$i', 'line', 10, 10, 0, 0, fill: 'none', stroke: _Kit.red, strokeWidth: 14, at: c.start + 1.2 + i * 1.2,
                points: i.isEven ? [[c.w * 0.42, c.h * 0.72], [c.w * 0.14, c.h * 0.72]] : [[c.w * 0.5, c.h * 0.72], [c.w * 0.78, c.h * 0.72]]),
            {'op': 'update_layer', 'layer': c.id('arrow$i'), 'arrow_end': true},
            ...c.drawOn('arrow$i', c.start + 1.2 + i * 1.2, dur: 0.4),
          ],
        ],
      ]),
    ];
  }

  static String _hl(PatternCtx c, String quote) {
    final h = c.s('highlight');
    if (h.isNotEmpty && quote.contains(h)) return h;
    final w = quote.split(RegExp(r'\s+'));
    return w.take(math.min(4, w.length)).join(' ');
  }

  static String _circleWord(PatternCtx c, String quote) {
    final w = c.s('circle');
    if (w.isNotEmpty && quote.contains(w)) return w;
    final m = RegExp(r'\d[\d,.]*').firstMatch(quote);
    if (m != null) return m.group(0)!;
    final words = quote.split(RegExp(r'\s+')).where((x) => x.length > 4).toList();
    return words.isEmpty ? '' : words.last.replaceAll(RegExp(r'[^\wऀ-ॿ]'), '');
  }

  static List<PStep> _docHighlight(PatternCtx c) {
    final m = c.media('media');
    final quote = c.s('quote', c.s('line', 'According to the report, the plane crashed into the mountains.'));
    final hl = _hl(c, quote), circle = _circleWord(c, quote);
    return [
      PStep('article', [
        [
          c.call('article', 'doc', {
            if (m != null) 'media': m.id, 'lines': 'sequential', 'perspective': {'rx': 6, 'ry': -12}, 'backdrop': 'newsprint_wall', 'exit': 'slide_left',
            'marks': [
              {'phrase': hl, 'style': 'highlight', 'color': '#E5F51A', 'delay': 0.8},
              if (circle.isNotEmpty) {'phrase': circle, 'style': 'pen_circle', 'color': _Kit.red, 'delay': 1.6},
            ],
          }),
        ],
        if (m != null)
          [
            c.comp('article', 'doc', {
              'media': m.id,
              'marks': [
                {'box': [0.08, 0.30, 0.80, 0.36], 'style': 'highlight', 'delay': 0.8},
                {'box': [0.12, 0.46, 0.44, 0.52], 'style': 'circle', 'delay': 1.9},
              ],
            }),
          ],
        [
          c.comp('source_card', 'doc', {
            'source': c.s('source', 'Source – news report'), 'headline': c.s('headline'), 'body': quote, 'highlights': [hl],
            if (circle.isNotEmpty) 'circle': circle,
          }),
        ],
      ]),
    ];
  }

  static List<PStep> _book(PatternCtx c) {
    final m = c.media('media');
    final title = c.upper('title', 'THE BOOK');
    final author = c.upper('author', '');
    final quote = c.s('quote', c.s('line', 'We had to survive, whatever it took.'));
    final hl = _hl(c, quote);
    return [
      PStep('book', [
        [
          c.call('book', 'book', {
            'cover': m?.id ?? {'title': title, 'author': author, 'colors': ['#6E1A1A', '#F2E6C8']},
            'pages': [quote], 'bg': '#8B0E14', 'enter': c.s('enter', 'rise'), 'open_at': 1.4, 'flips': 1, 'zoom_to': 'page', 'tilt': 4,
            'marks': [{'phrase': hl, 'style': 'highlight', 'color': '#F2C200'}],
          }),
        ],
        [
          _Kit.backdrop(c, 'bg', '#8B0E14', '#3A0508'),
          c.fx(c.id('bg'), 'grunge', {'amount': 55}),
          if (m != null)
            c.comp('photo_card', 'cover', {'media': m.id, 'caption': title, 'width': c.w * 0.3, 'tilt': -3})
          else
            c.comp('source_card', 'cover', {'source': author.isEmpty ? 'BOOK' : author, 'headline': title, 'body': quote, 'highlights': [hl], 'style': 'paper'}),
        ],
      ]),
    ];
  }

  static List<PStep> _zoomOutToSource(PatternCtx c) =>
      c.transition('zoom_out_of_photo', {}, const [('focus_pull', {}), ('flash_cut', {})], anim: 'zoom_out');

  static List<PStep> _sourceTag(PatternCtx c) {
    final src = c.s('source', 'Source – archive.org');
    return [
      PStep('tag', [
        [c.call('source_tag', 'tag', {'text': src, 'color': '#F2A6A6', 'text_color': '#5A1414', 'font': 'serif', 'x': c.w * 0.5, 'y': c.h * 0.88}, at: c.rv)],
        [
          c.text('tag', src, size: 0.028, color: '#5A1414', box: '#F2A6A6', font: 'Playfair Display', weight: 700, y: c.h * 0.88, width: c.w * 0.36, at: c.rv,
              animator: 'fade_up', animDur: 0.3, shadow: false),
        ],
      ]),
    ];
  }

  static List<PStep> _grungeTitle(PatternCtx c) {
    final m = c.media('media');
    final title = c.upper('title', 'THE TEAM');
    final key = c.upper('key', '');
    return [
      PStep('backdrop', [
        [_Kit.backdrop(c, 'bg', '#1A2A4E', '#070D1C'), c.fx(c.id('bg'), 'grunge', {'amount': 60})],
      ]),
      PStep('photo', [
        [c.call('photo_card', 'photo', {if (m != null) 'media': m.id, 'frame': 'torn_white', 'backdrop': 'grunge_navy', 'caption': '', 'width': c.w * 0.72})],
        if (m != null) [c.comp('photo_card', 'photo', {'media': m.id, 'caption': '', 'width': c.w * 0.6, 'tilt': -2})],
        [c.shape('photo', 'rect', c.w * 0.6, c.h * 0.5, c.w / 2, c.h * 0.5, fill: '#D8D4CC', fill2: '#8A8680')],
      ]),
      PStep('title', [
        [
          c.text('title', title, size: 0.075, y: c.h * 0.14, at: c.start + 0.4, animator: 'typewriter', animDur: (title.length / 14).clamp(0.3, 2.0)),
          if (key.isNotEmpty) c.text('key', key, size: 0.12, color: _Kit.cyan, y: c.h * 0.86, at: c.rv + 0.4, animator: 'slide_up', animDur: 0.5),
        ],
      ]),
    ];
  }

  static List<PStep> _noteCard(PatternCtx c) {
    final text = c.upper('text', c.upper('concept', 'PLAN'));
    return [
      PStep('note', [
        [
          c.call('note_card', 'note', {
            'text': text, 'paper': 'notebook', 'text_color': '#B3121E', 'x': c.w * 0.44, 'y': c.h * 0.5, 'width': c.w * 0.32, 'enter': 'drop', 'tilt': -6, 'glide': 0.15,
          }),
        ],
        _Kit.card(c, 'note', text),
      ]),
    ];
  }

  static List<PStep> _photoWall(PatternCtx c) {
    final photos = c.medias('photos');
    final n = photos.isEmpty ? 4 : math.min(photos.length, 6);
    final gap = c.w * 0.36;
    final dwell = math.max(1.2, c.d / n);
    return [
      PStep('wall', [
        [c.call('photo_wall', 'wall', {'photos': [for (final p in photos) p.id], 'bg': 'paper_grey', 'splatter': true, 'dwell': 2.5, 'move': 'pan', 'tilt_range': 8})],
        [
          _Kit.backdrop(c, 'bg', '#9A9A95', '#5E5E5A'),
          c.fx(c.id('bg'), 'paper', {'amount': 80}),
          c.group('wall', c.w * 0.5, c.h * 0.5),
          c.anchor0('wall'),
          for (int i = 0; i < n; i++) ...[
            c.shape('ink$i', 'ellipse', c.h * 0.55, c.h * 0.42, i * gap + c.w * 0.03, c.h * 0.04, fill: '#151515', parent: c.id('wall'), at: c.start + i * dwell * 0.8),
            ...c.pop('ink$i', c.start + i * dwell * 0.8, over: 105, dur: 0.4),
            c.shape('frame$i', 'rect', c.h * 0.5, c.h * 0.6, i * gap, 0, fill: '#FFFFFF', parent: c.id('wall')),
            c.fx(c.id('frame$i'), 'shadow', {'distance': 14, 'blur': 20, 'opacity': 60}),
            c.rot('frame$i', (i.isEven ? -1 : 1) * (4 + i % 3 * 2.0)),
            if (photos.isNotEmpty) c.media2('ph$i', photos[i % photos.length], heightPx: c.h * 0.52, x: i * gap, y: -c.h * 0.02, parent: c.id('wall')),
            if (photos.isNotEmpty) c.rot('ph$i', (i.isEven ? -1 : 1) * (4 + i % 3 * 2.0)),
            if (photos.isNotEmpty && i < n - 1) c.fx(c.id('ph$i'), 'mono', {'amount': 100}),
          ],
          for (int i = 0; i < n; i++) c.kf('wall', 'position', c.start + i * dwell, [c.w * 0.5 - i * gap, c.h * 0.5, 0], i == 0 ? 'easy_ease' : 'ease_out'),
        ],
      ]),
    ];
  }

  static List<PStep> _handwrite(PatternCtx c) {
    final text = c.s('text', c.s('quote', 'We are alive'));
    return [
      PStep('note', [
        [c.call('handwrite_card', 'note', {'text': text, 'font': 'Kalam', 'paper': 'notebook', 'write_cps': 8, 'x': c.w * 0.5, 'y': c.h * 0.5})],
        [
          c.shape('paper', 'rect', c.w * 0.52, c.h * 0.46, c.w / 2, c.h / 2, fill: '#F4EEDD', fill2: '#E2D8BE'),
          c.fx(c.id('paper'), 'shadow', {'distance': 16, 'blur': 22, 'opacity': 55}),
          c.fx(c.id('paper'), 'paper', {'amount': 60}),
          c.rot('paper', -2),
          c.text('ink', text, size: 0.07, color: '#1A1A3A', font: 'Kalam', weight: 700, width: c.w * 0.46, height: c.h * 0.4, at: c.start + 0.3,
              animator: 'typewriter', animDur: (text.length / 8).clamp(0.4, math.max(0.5, c.d - 1.5)), shadow: false),
          c.rot('ink', -2),
        ],
      ]),
    ];
  }

  static List<PStep> _emblem(PatternCtx c) {
    final label = c.upper('label', 'ORGANISATION');
    final initials = label.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).map((w) => w[0]).take(3).join();
    return [
      PStep('badge', [
        [c.comp('badge', 'badge', {'label': label, 'enter': 'glitch_flash'}, at: c.rv)],
        [c.comp('icon_badge', 'badge', {'text': initials, 'shape': 'circle', 'color': _Kit.blue}, at: c.rv)],
        [c.text('badge', label, size: 0.06, at: c.rv)],
      ]),
    ];
  }

  static List<PStep> _surfaceLabels(PatternCtx c) {
    final name = c.upper('name', 'NAME');
    final role = c.upper('role', '');
    final x = c.n('x', c.w * 0.5), y = c.n('y', c.h * 0.62);
    return [
      PStep('label', [
        [c.call('arrow_callout', 'label', {'circle': false, 'role': role, 'name': name, 'text': name, 'from': [x + c.w * 0.12, y - c.h * 0.12], 'to': [x, y]}, at: c.rv)],
        [
          if (role.isNotEmpty) c.text('role', role, size: 0.028, color: _Kit.red, weight: 800, x: x, y: y - c.h * 0.045, at: c.rv, animator: 'fade_up', animDur: 0.3),
          c.text('name', name, size: 0.06, weight: 900, x: x, y: y, at: c.rv + 0.1, animator: 'word_pop', animDur: 0.35),
        ],
      ]),
    ];
  }

  static List<(int, String)> _groups(PatternCtx c, int total) {
    const colors = [_Kit.cyan, _Kit.yellow, '#FF6B6B', '#FFFFFF', '#9B8CFF'];
    final out = <(int, String)>[];
    var i = 0;
    for (final g in c.list('groups')) {
      final m = RegExp(r'^(\d+)').firstMatch(g);
      if (m == null) continue;
      out.add((int.parse(m.group(1)!), colors[i++ % colors.length]));
    }
    final sum = out.fold<int>(0, (a, g) => a + g.$1);
    if (out.isEmpty) return [(total, '#FFFFFF')];
    if (sum < total) out.add((total - sum, '#6E7A84'));
    return out;
  }

  static List<String> _groupLabels(PatternCtx c) => [
        for (final g in c.list('groups'))
          if (RegExp(r'^\d+').hasMatch(g)) g.replaceFirst(':', ' ').toUpperCase(),
      ];

  static List<PStep> _unitChart(PatternCtx c) {
    final total = c.n('total', 45).round().clamp(1, 100000);
    final label = c.upper('label', '$total');
    final groups = _groups(c, total);
    final labels = _groupLabels(c);
    return [
      PStep('chart', [
        [
          c.call('unit_chart', 'chart', {
            'icon': 'person', 'total_label': label, 'cols': 10, 'area': [0.3, 0.28, 0.92, 0.88], 'stagger': 0.03,
            'groups': [for (int i = 0; i < groups.length; i++) {'count': groups[i].$1, 'color': groups[i].$2, if (i < labels.length) 'label': labels[i], 'at': 1.2 + i * 1.0}],
          }),
        ],
        [
          c.text('total', label, size: 0.075, y: c.h * 0.14, at: c.start + 0.2, animator: 'fade_up', animDur: 0.5),
          ..._Kit.people(c, 'p', groups, area: const [0.32, 0.28, 0.92, 0.88], at: c.start + 0.6),
          for (int i = 0; i < labels.length && i < groups.length; i++)
            c.text('g$i', labels[i], size: 0.042, color: groups[i].$2, x: c.w * 0.16, y: c.h * (0.36 + i * 0.14), width: c.w * 0.26,
                at: math.min(c.end - 0.3, c.start + 1.4 + i * 1.0), animator: 'fade_up', animDur: 0.35),
        ],
      ]),
    ];
  }

  static List<PStep> _peopleGrid(PatternCtx c) {
    final total = c.n('total', 45).round().clamp(1, 100000);
    final alive = c.n('alive', 16).round().clamp(0, total);
    final label = c.upper('label', '$alive SURVIVORS');
    return [
      PStep('grid', [
        [
          c.call('people_grid', 'grid', {
            'total': total, 'alive': alive, 'alive_color': '#C62828', 'dead_color': '#8A8A8A', 'dead': 'fade', 'rows': 2, 'count_text': label, 'count_at': c.rv - c.start,
          }),
        ],
        [
          _Kit.backdrop(c, 'bg', '#14214A', '#060B1E'),
          ..._Kit.people(c, 'alive', [(alive, '#C62828')], cols: 10, area: const [0.1, 0.3, 0.9, 0.52], at: c.start + 0.4, glow: true),
          ..._Kit.people(c, 'dead', [(total - alive, '#8A8A8A')], cols: 15, area: const [0.1, 0.58, 0.9, 0.88], at: c.start + 0.4, stagger: 0.015),
          c.text('count', label, size: 0.07, y: c.h * 0.14, at: c.rv, animator: 'slide_up', animDur: 0.4),
        ],
      ]),
    ];
  }

  static List<PStep> _statFigure(PatternCtx c) {
    final from = c.n('from', 80), to = c.n('to', 40);
    final unit = c.upper('unit', '');
    final label = c.upper('label', '');
    return [
      PStep('stat', [
        [
          c.call('stat_figure', 'stat', {
            'icon': c.s('icon', 'scale'), 'from': from, 'to': to, 'steps': 6, 'label': label, 'unit': unit, 'figure': 'human',
            'color_from': '#FFFFFF', 'color_to': _Kit.red, 'duration': c.d,
          }),
        ],
        [
          c.text('num', '${from.round()}', size: 0.16, y: c.h * 0.44, animator: null,
              extra: {'counter': {'from': from, 'to': to, 'delay': 0.6, 'duration': math.min(2.5, c.d - 1), 'suffix': unit.isEmpty ? '' : ' $unit'}}),
          c.text('lbl', label, size: 0.04, weight: 800, y: c.h * 0.62, at: c.start + 0.5, animator: 'typewriter', animDur: 0.6),
        ],
      ]),
    ];
  }

  static List<PStep> _split(PatternCtx c) {
    final a = c.upper('a', 'A'), b = c.upper('b', 'B');
    final av = c.upper('a_value', ''), bv = c.upper('b_value', '');
    return [
      PStep('split', [
        [
          c.call('split_screen', 'split', {
            'orientation': 'vertical', 'a': {'label': a, 'value': av}, 'b': {'label': b, 'value': bv, 'note': c.s('note')},
            'divider': {'color': _Kit.yellow, 'width': 8}, 'enter': 'wipe',
          }),
        ],
        [
          _Kit.backdrop(c, 'bg', '#1A1F26', '#07090C'),
          c.shape('div', 'rect', 8, c.h, c.w / 2, c.h / 2, fill: _Kit.yellow),
          c.kf('div', 'scale', c.start, [100, 0, 100], 'ease_out'),
          c.kf('div', 'scale', c.start + 0.25, [100, 100, 100], 'easy_ease'),
          c.text('a', a, size: 0.06, x: c.w * 0.25, y: c.h * 0.36, width: c.w * 0.44, at: c.start + 0.3),
          c.text('b', b, size: 0.06, x: c.w * 0.75, y: c.h * 0.36, width: c.w * 0.44, at: c.start + 0.5),
          if (av.isNotEmpty) c.text('av', av, size: 0.1, color: _Kit.yellow, x: c.w * 0.25, y: c.h * 0.56, width: c.w * 0.44, at: c.rv),
          if (bv.isNotEmpty) c.text('bv', bv, size: 0.1, color: _Kit.yellow, x: c.w * 0.75, y: c.h * 0.56, width: c.w * 0.44, at: c.rv + 0.6),
        ],
      ]),
    ];
  }

  static List<PStep> _gauge(PatternCtx c) {
    final from = c.n('from', 20000), to = c.n('to', 13000);
    final unit = c.upper('unit', 'FT');
    final range = (from - to).abs();
    final step = range <= 0 ? 1000.0 : _niceStep(range / 6);
    final x = c.w * 0.9;
    final ticks = <Map<String, dynamic>>[];
    final hi = math.max(from, to), lo = math.min(from, to);
    final spacing = c.h * 0.12;
    var k = 0;
    for (var v = (hi / step).ceil() * step; v >= lo - step && k < 14; v -= step, k++) {
      final y = (hi - v) / step * spacing;
      ticks.add(c.shape('t$k', 'rect', c.w * 0.025, 4, 0, y, fill: '#FFFFFF', parent: c.id('scale')));
      ticks.add(c.text('l$k', '${v.round()} $unit', size: 0.024, weight: 700, x: -c.w * 0.06, y: y, width: c.w * 0.1, align: 'right', animator: null, parent: c.id('scale')));
    }
    final y0 = c.h / 2 - (hi - from) / step * spacing, y1 = c.h / 2 - (hi - to) / step * spacing;
    return [
      PStep('gauge', [
        [c.call('gauge_hud', 'gauge', {'orientation': 'vertical', 'side': 'right', 'unit': unit, 'from': from, 'to': to, 'step': step, 'label_every': 1, 'pointer_color': '#E01010', 'duration': c.d})],
        [
          c.group('scale', x, y0),
          c.anchor0('scale'),
          ...ticks,
          c.kf('scale', 'position', c.start + 0.2, [x, y0, 0], 'easy_ease'),
          c.kf('scale', 'position', c.end - 0.2, [x, y1, 0], 'easy_ease'),
          c.shape('ptr', 'polygon', c.h * 0.03, c.h * 0.03, x - c.w * 0.022, c.h / 2, fill: '#E01010', sides: 3),
          c.rot('ptr', 90),
        ],
      ]),
    ];
  }

  static double _niceStep(double raw) {
    final p = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    for (final m in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
      if (raw <= m * p) return m * p;
    }
    return 10 * p;
  }

  static List<PStep> _clockStamp(PatternCtx c) {
    final lines = c.list('lines', [for (final k in const ['day', 'date', 'time']) if (c.s(k).isNotEmpty) c.upper(k, '')]);
    final ls = lines.isEmpty ? const ['DAY 1'] : lines.take(3).toList();
    return [
      PStep('darken', [
        [c.shape('dark', 'rect', c.w, c.h * 0.45, c.w / 2, c.h * 0.78, fill: '#00000000', fill2: '#A0000000')],
      ], optional: true),
      PStep('stamp', [
        [c.call('clock_stamp', 'stamp', {'lines': ls, 'x': 0.045, 'y': 0.78, 'size': 0.058, 'blink_colon': true, 'darken_below': 0.3, 'persist': false}, at: c.rv - 0.15)],
        _Kit.lines(c, 'stamp', ls, font: 'Share Tech Mono'),
        _Kit.lines(c, 'stamp', ls),
      ]),
    ];
  }

  static List<PStep> _statBehind(PatternCtx c) {
    final text = c.upper('text', c.upper('number', '60KM'));
    final cut = c.media('cutout');
    return [
      PStep('stat', [
        [c.text('stat', text, size: 0.13, style: 'stat_yellow', animator: 'letter_drop', animDur: 0.08 * text.length + 0.3, at: c.rv, y: c.h * 0.4)],
        [c.text('stat', text, size: 0.13, color: _Kit.yellow, animator: 'random_pop', animDur: 0.08 * text.length + 0.3, at: c.rv, y: c.h * 0.4)],
      ]),
      if (cut != null) PStep('front', [[c.media2('front', cut, heightPx: c.h * 0.8, y: c.h * 0.6)]]),
    ];
  }

  static List<PStep> _toggle(PatternCtx c) {
    final x = c.n('x', c.w * 0.5), y = c.n('y', c.h * 0.5);
    final pw = c.w * 0.1, ph = c.w * 0.04;
    final at = c.rv + 0.5;
    return [
      PStep('toggle', [
        [c.call('ui_toggle', 'toggle', {'from': 'off', 'to': 'on', 'at': at - c.start, 'x': x, 'y': y, 'size': 0.1, 'on_color': '#2ECC40', 'labels': ['OFF', 'ON']})],
        [
          c.group('toggle', x, y),
          c.anchor0('toggle'),
          c.shape('off', 'rect', pw, ph, 0, 0, fill: '#5A5F66', corner: ph / 2, parent: c.id('toggle')),
          c.shape('on', 'rect', pw, ph, 0, 0, fill: '#2ECC40', corner: ph / 2, parent: c.id('toggle')),
          ...c.fade('on', at, dur: 0.15),
          c.shape('knob', 'ellipse', ph * 0.82, ph * 0.82, -pw / 2 + ph / 2, 0, fill: '#FFFFFF', parent: c.id('toggle')),
          c.kf('knob', 'position', at, [-pw / 2 + ph / 2, 0, 0], 'ease_out'),
          c.kf('knob', 'position', at + 0.15, [pw / 2 - ph / 2, 0, 0], 'easy_ease'),
          ...c.pop('toggle', c.start, over: 105, dur: 0.3),
          c.kf('toggle', 'scale', at + 0.1, [100, 100, 100], 'easy_ease'),
          c.kf('toggle', 'scale', at + 0.2, [105, 105, 100], 'easy_ease'),
          c.kf('toggle', 'scale', at + 0.32, [100, 100, 100], 'easy_ease'),
          if (c.s('label').isNotEmpty) c.text('lbl', c.upper('label', ''), size: 0.035, weight: 800, x: x, y: y + ph * 1.2, at: c.start + 0.2, animator: 'fade_up', animDur: 0.3),
        ],
      ]),
    ];
  }

  static List<PStep> _audioWave(PatternCtx c) {
    final country = c.s('country', c.places().first);
    final cw = c.w * 0.52, ch = c.h * 0.2;
    final cx = c.w * 0.54, cy = c.h * 0.5;
    const bars = 24;
    final rnd = math.Random(country.hashCode);
    final wave = <Map<String, dynamic>>[
      c.shape('card', 'rect', cw, ch, cx, cy, fill: '#0B1E6B', corner: ch * 0.18),
      c.fx(c.id('card'), 'shadow', {'distance': 12, 'blur': 18, 'opacity': 50}),
    ];
    for (int i = 0; i < bars; i++) {
      final p = 'bar$i';
      final bx = cx - cw * 0.44 + cw * 0.88 * i / (bars - 1);
      wave.add(c.shape(p, 'rect', cw * 0.012, ch * 0.7, bx, cy, fill: '#7FB2FF', corner: cw * 0.006));
      for (double t = c.start; t < c.end; t += 0.2) {
        wave.add(c.kf(p, 'scale', t, [100, 15 + rnd.nextDouble() * 85, 100], 'easy_ease'));
      }
    }
    final code = country.length <= 3 ? country.toUpperCase() : country.substring(0, 3).toUpperCase();
    return [
      PStep('wave', [
        [c.call('audio_wave', 'wave', {'width': cw, 'height': ch, 'color': '#7FB2FF', 'bg': '#0B1E6B', 'bars': 40, 'x': cx, 'y': cy})],
        wave,
      ]),
      PStep('flag', [
        [c.call('flag_badge', 'flag', {'country': country, 'size': 0.14, 'x': cx - cw / 2 - c.h * 0.1, 'y': cy}, at: c.start + 0.3)],
        [
          c.shape('flag', 'ellipse', c.h * 0.16, c.h * 0.16, cx - cw / 2 - c.h * 0.1, cy, fill: '#D52B1E', stroke: '#FFFFFF', strokeWidth: 6, at: c.start + 0.3),
          ...c.pop('flag', c.start + 0.3),
          c.text('code', code, size: 0.045, x: cx - cw / 2 - c.h * 0.1, y: cy, width: c.h * 0.16, at: c.start + 0.4, animator: null),
        ],
      ]),
      if (c.s('label').isNotEmpty)
        PStep('label', [[c.text('lbl', c.upper('label', ''), size: 0.035, weight: 800, y: cy + ch * 0.8, at: c.rv, animator: 'typewriter', animDur: 0.6)]], optional: true),
    ];
  }

  static List<PStep> _iconSticker(PatternCtx c) {
    final items = c.list('items', const ['ITEM']).take(5).toList();
    final x = c.w * 0.8, y = c.h * 0.45, r = c.h * 0.09;
    final span = c.d - 0.4;
    final out = <Map<String, dynamic>>[
      c.shape('disc', 'ellipse', r * 2, r * 2, x, y, fill: '#FFE500'),
      ...c.pop('disc', c.start, over: 115),
    ];
    for (int i = 0; i < items.length; i++) {
      final t = c.start + 0.2 + span * i / items.length;
      final du = span / items.length;
      out.add(c.text('it$i', items[i].toUpperCase(), size: 0.032, color: '#111111', weight: 900, x: x, y: y, width: r * 1.8, height: r, at: t, du: du, animator: null, shadow: false));
      out.add(c.kf('it$i', 'scale', t, [130, 70, 100], 'ease_out'));
      out.add(c.kf('it$i', 'scale', t + 0.25, [100, 100, 100], 'elastic'));
      if (i > 0) {
        out.add(c.kf('disc', 'scale', t - 0.05, [100, 100, 100], 'ease_in'));
        out.add(c.kf('disc', 'scale', t + 0.05, [118, 86, 100], 'ease_out'));
        out.add(c.kf('disc', 'scale', t + 0.25, [100, 100, 100], 'elastic'));
      }
    }
    return [
      PStep('sticker', [
        [
          c.call('icon_sticker', 'sticker', {
            'items': [for (int i = 0; i < items.length; i++) {'text': items[i], 'at': 0.2 + span * i / items.length}], 'color': '#FFE500', 'x': 0.8, 'y': 0.45, 'size': 0.13, 'swap': 'squash',
          }),
        ],
        out,
      ]),
    ];
  }

  static List<PStep> _iconDrop(PatternCtx c) {
    final preset = c.s('icon', 'stop').toLowerCase();
    final label = c.upper('label', preset.toUpperCase());
    final x = c.n('x', c.w * 0.5), y = c.n('y', c.h * 0.46), s = c.h * 0.22;
    final shape = <Map<String, dynamic>>[];
    switch (preset) {
      case 'check':
        shape.add(c.shape('icon', 'line', 10, 10, 0, 0, fill: 'none', stroke: '#2ECC40', strokeWidth: s * 0.14,
            points: [[x - s * 0.4, y], [x - s * 0.1, y + s * 0.3], [x + s * 0.45, y - s * 0.35]]));
      case 'cross':
        shape.add(c.shape('icon', 'path', 10, 10, 0, 0, fill: 'none', stroke: _Kit.red, strokeWidth: s * 0.14,
            points: [[x - s * 0.4, y - s * 0.4], [x + s * 0.4, y + s * 0.4], [x, y], [x + s * 0.4, y - s * 0.4], [x - s * 0.4, y + s * 0.4]]));
      case 'warning':
        shape.add(c.shape('icon', 'polygon', s, s, x, y, fill: '#FFC400', sides: 3, stroke: '#111111', strokeWidth: 8));
      case 'heart':
        shape.add(c.shape('icon', 'star', s, s, x, y, fill: '#E53950', sides: 5));
      default:
        shape.add(c.shape('icon', 'polygon', s, s, x, y, fill: _Kit.red, sides: 8, stroke: '#FFFFFF', strokeWidth: 8));
        shape.add(c.rot('icon', 22.5));
    }
    return [
      PStep('icon', [
        [c.call('icon_drop', 'icon', {'preset': preset, 'enter': 'drop', 'bounce': true, 'x': x, 'y': y, 'size': 0.22}, at: c.rv)],
        [
          c.group('drop', 0, 0, at: c.rv),
          c.anchor0('drop'),
          ...shape.map((m) => m['op'] == 'add_layer' ? {...m, 'start': c.rv, 'duration': c.end - c.rv, 'parent': c.id('drop')} : m),
          c.text('lbl', label, size: 0.05, x: x, y: y + s * 0.72, at: c.rv + 0.25, animator: 'word_pop', animDur: 0.3),
          c.kf('drop', 'position', c.rv, [0, -c.h * 0.7, 0], 'bounce'),
          c.kf('drop', 'position', c.rv + 0.5, [0, 0, 0], 'easy_ease'),
        ],
      ]),
    ];
  }

  static const _platformColors = {
    'whatsapp': '#25D366', 'facebook': '#1877F2', 'twitter': '#1DA1F2', 'instagram': '#E1306C', 'youtube': '#FF0000', 'telegram': '#2AABEE',
  };

  static List<PStep> _socialCta(PatternCtx c, {bool bug = false}) {
    final platform = c.s('platform', bug ? 'youtube' : 'whatsapp').toLowerCase();
    final handle = c.s('handle', 'Mohitflix');
    final color = _platformColors[platform] ?? '#FFFFFF';
    final name = platform.isEmpty ? handle : platform[0].toUpperCase() + platform.substring(1);
    final hold = math.min(3.0, c.d);
    return [
      PStep('cta', [
        [c.call('social_cta', 'cta', {'platform': platform, 'handle': handle, 'line1': 'JOIN US ON', 'color': color, 'x': 0.78, 'y': 0.7, 'hold': hold, if (bug) 'exit': 'disintegrate'}, du: hold + 0.7)],
        [c.comp('cta', 'cta', {'text': bug ? '@$handle' : 'JOIN US ON $name', 'color': color}, du: hold + 0.7)],
        [c.text('cta', bug ? '@$handle' : 'JOIN US ON ${name.toUpperCase()}', size: 0.035, x: c.w * 0.78, y: c.h * 0.7, width: c.w * 0.3, du: hold + 0.7)],
      ]),
    ];
  }

  static List<PStep> _socialBug(PatternCtx c) => _socialCta(c, bug: true);

  static List<PStep> _presenterStats(PatternCtx c) {
    final lines = c.list('lines', [c.upper('number', 'STAT')]).take(4).toList();
    return [
      PStep('stats', [
        [c.call('presenter_stats', 'stats', {'lines': [for (int i = 0; i < lines.length; i++) {'text': lines[i], 'at': (c.rv - c.start) + i * 0.9}]})],
        _Kit.lines(c, 'stats', lines, x: 0.66, y: 0.34, size: 0.032, font: 'Poppins', cps: 18, gap: 0.5, weight: 800, width: 0.3),
      ]),
    ];
  }

  static List<PStep> _kinetic(PatternCtx c) {
    final text = c.upper('text', c.upper('line', 'TEXT'));
    final dur = (text.length / 16).clamp(0.4, 3.0).toDouble();
    return [
      PStep('text', [
        [c.text('line', text, size: 0.07, animator: 'word_fade_grey', animDur: dur, at: c.rv)],
        [c.text('line', text, size: 0.07, animator: 'typewriter', animDur: dur, at: c.rv, extra: {'lead_color': '#E53935', 'lead_chars': 3})],
      ]),
    ];
  }

  // ---- transitions
  static String _tone(PatternCtx c) => c.tone == 'snow' ? 'cold' : (c.tone == 'desert' ? 'warm' : 'neutral');

  static List<PStep> _zoomBlur(PatternCtx c) => c.transition('zoom_blur', {'flash': true}, const [('flash_cut', {}), ('whip_pan', {})], anim: 'zoom_in');

  static List<PStep> _debrisBurst(PatternCtx c) => c.transition('debris_burst', {'kind': c.tone == 'desert' ? 'dust' : 'snow', 'pre_roll': 1.2, 'tail': 0.5, 'tone': _tone(c)},
      [('smoke_reveal', {'tone': _tone(c)}), ('flash_cut', {})], anim: 'smoke');

  static List<PStep> _slideFilm(PatternCtx c) => c.transition('slide_film', {}, const [('film_burn', {}), ('dip_to_black', {})]);

  static List<PStep> _slice(PatternCtx c) => c.transition('slice', {'bands': 4}, const [('glitch_cut', {}), ('whip_pan', {})], anim: 'slide_left');

  static List<PStep> _slantWipe(PatternCtx c) => c.transition('slant_wipe', {'angle': 10}, const [('whip_pan', {'direction': 'left'})], anim: 'slide_left');

  static List<PStep> _shrinkToCard(PatternCtx c) => c.transition('shrink_to_card', {'bg': 'grunge_red'}, const [('focus_pull', {})], anim: 'zoom_out');

  static List<PStep> _emerge(PatternCtx c) => c.transition('emerge', {}, const [('focus_pull', {})], anim: 'zoom_in');

  static List<PStep> _inkDuotone(PatternCtx c) =>
      c.transition('ink_bleed', {'incoming': 'duotone_of_outgoing', 'tone': 'cold'}, const [('smoke_reveal', {'tone': 'cold'})], anim: 'ink');

  static List<PStep> _eyeZoom(PatternCtx c) => c.transition('push_through', {'preview_inside': true, 'point': [c.w / 2, c.h * 0.45], 'size': [c.w * 0.08, c.h * 0.06], 'shape': 'ellipse'},
      const [('focus_pull', {})], anim: 'zoom_in');

  static List<PStep> _powderBurst(PatternCtx c) {
    final kind = c.tone == 'desert' ? 'sand' : 'snow';
    return c.transition('powder_burst', {'direction': c.s('direction', 'right'), 'color': kind == 'sand' ? '#E8D2A6' : '#FFFFFF', 'density': 80, 'linger': 0.3, 'kind': kind},
        [('debris_burst', {'kind': kind}), ('smoke_reveal', {'tone': _tone(c)}), ('flash_cut', {})], anim: 'smoke');
  }

  static List<PStep> _eyeReflection(PatternCtx c) => c.transition('eye_reflection', {}, [
        ('zoom_into_photo', {'point': [c.w / 2, c.h * 0.45], 'size': [c.w * 0.15, c.h * 0.15]}),
        ('focus_pull', {}),
      ], anim: 'zoom_out');

  static List<PStep> _holes(PatternCtx c) => c.transition('holes', {}, const [('burn_edge', {}), ('glitch_cut', {})], anim: 'iris');

  static List<PStep> _shatterIce(PatternCtx c) =>
      c.transition('shatter', {'tone': 'ice', 'lead_in': 1.0, 'shard_color': '#BFE6FF'}, const [('glitch_cut', {})], anim: 'shatter');

  static List<PStep> _pushThrough(PatternCtx c) =>
      c.transition('push_through', {'point': [c.w / 2, c.h * 0.5], 'size': [c.w * 0.2, c.h * 0.3]}, const [('flash_cut', {})], anim: 'zoom_in');

  static List<PStep> _foregroundWipe(PatternCtx c) => c.transition('foreground_wipe', {'direction': c.s('direction', 'left')}, const [('whip_pan', {})], anim: 'slide_left');

  static List<PStep> _mapDrop(PatternCtx c) => c.transition('map_drop', {}, const [('smoke_reveal', {})], anim: 'zoom_in');

  static List<PStep> _flashCut(PatternCtx c) => c.transition('flash_cut', {}, const [('dip_to_black', {'color': '#FFFFFF'})], anim: 'flash');

  static List<PStep> _lightLeak(PatternCtx c) => c.transition('light_leak_wipe', {'tone': 'warm'}, const [('film_burn', {})], anim: 'fade');

  static List<PStep> _punchIn(PatternCtx c) {
    final p = c.plate;
    if (p == null) return const [];
    return [
      PStep('punch', [
        [{'op': 'animate_in', 'layer': p, 'preset': 'punch_in', 'duration': 0.25}],
        [
          c.fx(p, 'blur', {'amount': 0}, fxId: '${p}_punch_blur'),
          c.fxKey(p, '${p}_punch_blur', 'amount', c.start, 30, 'ease_out'),
          c.fxKey(p, '${p}_punch_blur', 'amount', c.start + 0.25, 0, 'easy_ease'),
          {'op': 'animate_in', 'layer': p, 'preset': 'zoom_out', 'duration': 0.25},
        ],
      ], optional: true),
    ];
  }

  static List<PStep> _sunGlare(PatternCtx c) {
    final p = c.plate;
    if (p == null) return const [];
    if (c.prevPlate != null) {
      return c.transition('exposure_in', {'from': 3.0, 'duration': 0.75}, const [('light_leak_wipe', {'tone': 'warm'})], anim: 'flash');
    }
    return [
      PStep('glare', [
        [{'op': 'animate_in', 'layer': p, 'preset': 'exposure_in', 'duration': 0.75}],
        [
          c.fx(p, 'flash', {'amount': 0, 'color': '#FFF2D0'}, fxId: '${p}_glare'),
          c.fxKey(p, '${p}_glare', 'amount', c.start, 95, 'ease_out'),
          c.fxKey(p, '${p}_glare', 'amount', c.start + 0.75, 0, 'easy_ease'),
          c.fx(p, 'light_rays', {'amount': 50, 'angle': 30, 'color': '#FFE6B0'}, fxId: '${p}_rays'),
        ],
      ], optional: true),
    ];
  }

  // ---- mood
  static List<PStep> _moodFlood(PatternCtx c) {
    final at = c.rv;
    return [
      PStep('flood', [
        [{'op': 'mood_flood', 'color': '#D0202A', 'from': 'bottom_left', 'duration': 0.9, 'at': at, 'hold': math.max(1.0, c.end - at - 0.9), 'sfx': false}],
        [
          c.solid('flood', '#00000000', at: at, adjustment: true),
          c.fx(c.id('flood'), 'duotone', {'dark': '#5A0A10', 'light': '#E0283A', 'amount': 100}),
          c.fx(c.id('flood'), 'vignette', {'amount': 70}),
          ...c.fade('flood', at, dur: 0.85),
        ],
      ]),
    ];
  }

  static List<PStep> _gradeSwap(PatternCtx c) => [
        PStep('grade', [
          [{'op': 'grade_swap', 'to': 'hope', 'at': c.rv}],
          [
            c.solid('grade', '#00000000', at: c.rv, adjustment: true),
            c.fx(c.id('grade'), 'color', {'saturation': 40, 'brightness': 6, 'contrast': 8}),
            c.fx(c.id('grade'), 'tint', {'color': '#FFB347', 'amount': 16}),
          ],
        ]),
      ];

  static List<PStep> _cutToBlack(PatternCtx c) {
    final at = c.start;
    final hold = math.min(1.5, c.d);
    return [
      PStep('black', [
        [{'op': 'cut_to_black', 'at': at, 'hold': hold, 'silence': true}],
        [c.solid('black', '#000000', at: at, du: hold)],
      ]),
    ];
  }

  static List<PStep> _lightning(PatternCtx c) {
    final at = c.rv;
    final x = c.w * 0.62;
    return [
      PStep('bolt', [
        [{'op': 'lightning', 'at': [at, at + 0.15], 'bolt': true, 'x': x, 'color': '#DDE6FF', 'sfx': false}],
        [
          c.solid('flash', '#DDE6FF', at: at, du: 0.5),
          c.kf('flash', 'opacity', at, 85, 'linear'),
          c.kf('flash', 'opacity', at + 0.06, 10, 'linear'),
          c.kf('flash', 'opacity', at + 0.15, 70, 'linear'),
          c.kf('flash', 'opacity', at + 0.45, 0, 'ease_out'),
          c.shape('bolt', 'line', 10, 10, 0, 0, fill: 'none', stroke: '#FFFFFF', strokeWidth: 7, at: at, du: 0.35, points: [
            [x, 0], [x - c.w * 0.03, c.h * 0.22], [x + c.w * 0.02, c.h * 0.3], [x - c.w * 0.04, c.h * 0.55], [x + c.w * 0.01, c.h * 0.62], [x - c.w * 0.03, c.h * 0.85],
          ]),
          c.fx(c.id('bolt'), 'glow', {'amount': 80, 'radius': 30}),
        ],
      ]),
    ];
  }

  static List<PStep> _bubble(PatternCtx c) {
    final text = c.upper('text', c.upper('quote', 'HELLO!'));
    return [
      PStep('bubble', [
        [c.call('speech_bubble', 'bubble', {'text': text, 'style': 'comic', 'type_delay': 0.2, 'x': c.n('x', c.w * 0.62), 'y': c.n('y', c.h * 0.3)}, at: c.rv)],
        [c.comp('speech_bubble', 'bubble', {'text': text}, at: c.rv)],
      ]),
    ];
  }

  static List<PStep> _bubblePuff(PatternCtx c) {
    final text = c.upper('text', 'HELP!');
    return [
      PStep('bubble', [
        [c.call('speech_bubble', 'bubble', {'text': text, 'style': 'comic', 'exit': 'puff', 'blink': {'period': 0.5}}, at: c.rv)],
        [c.comp('speech_bubble', 'bubble', {'text': text}, at: c.rv)],
      ]),
    ];
  }

  static List<PStep> _swingIn(PatternCtx c) {
    final text = c.upper('text', 'TEXT');
    return [
      PStep('card', [
        [c.text('card', text, size: 0.1, at: c.rv, animator: null)],
      ]),
      PStep('swing', [
        [{'op': 'animate_in', 'layer': c.id('card'), 'preset': 'swing_in', 'duration': 0.5}],
        [
          c.kf('card', 'rotation', c.rv, [0, 0, 20], 'ease_out'),
          c.kf('card', 'rotation', c.rv + 0.5, [0, 0, 0], 'easy_ease'),
          c.kf('card', 'scale', c.rv, [250, 250, 100], 'ease_out'),
          c.kf('card', 'scale', c.rv + 0.5, [100, 100, 100], 'easy_ease'),
          ...c.fade('card', c.rv, dur: 0.2),
        ],
      ], optional: true),
      if (c.plate != null)
        PStep('bg blur', [
          [
            c.fx(c.plate!, 'blur', {'amount': 0}, fxId: '${c.plate}_swing_blur'),
            c.fxKey(c.plate!, '${c.plate}_swing_blur', 'amount', c.rv, 18, 'ease_out'),
            c.fxKey(c.plate!, '${c.plate}_swing_blur', 'amount', c.rv + 0.6, 0, 'easy_ease'),
          ],
        ], optional: true),
    ];
  }

  static List<PStep> _swapLayer(PatternCtx c) {
    final a = c.upper('text', 'BEFORE'), b = c.upper('text2', 'AFTER');
    final at = c.rv + 0.6;
    return [
      PStep('a', [[c.text('a', a, size: 0.1, du: at - c.start, animator: null)]]),
      PStep('b', [[c.text('b', b, size: 0.1, at: at, animator: null)]]),
      PStep('swap', [
        [{'op': 'swap_layer', 'layer': c.id('a'), 'with': c.id('b'), 'at': at, 'transition': 'pop'}],
        c.pop('b', at, over: 115, dur: 0.25),
      ], optional: true),
    ];
  }

  static List<PStep> _rackFocus(PatternCtx c) {
    final p = c.plate;
    if (p == null) return const [];
    return [
      PStep('focus', [
        [{'op': 'set_dof', 'keys': [{'t': c.start, 'focus': 'near'}, {'t': c.rv, 'focus': 'far'}]}],
        [
          c.fx(p, 'blur', {'amount': 0}, fxId: '${p}_rack'),
          c.fxKey(p, '${p}_rack', 'amount', c.start, 10, 'easy_ease'),
          c.fxKey(p, '${p}_rack', 'amount', c.rv, 0, 'easy_ease'),
        ],
      ], optional: true),
    ];
  }

  static List<PStep> _spotlight(PatternCtx c) {
    final p = c.plate;
    final cut = c.media('cutout');
    final pain = c.slots['pain'] == true || c.s('tint').isNotEmpty;
    return [
      if (cut != null) PStep('subject', [[c.media2('subject', cut, heightPx: c.h * 0.78, y: c.h * 0.58)]]),
      if (p != null)
        PStep('spotlight', [
          [
            {
              'op': 'spotlight_subject', 'layers': [p], if (cut != null) 'keep': [c.id('subject')], 'others': {'mono': 100, 'dim': 15},
              if (pain) 'tint': {'color': '#D0101A', 'amount': 70}, 'start': c.rv, 'duration': c.end - c.rv, 'release': 0.5,
            },
          ],
          [
            c.fx(p, 'mono', {'amount': 0}, fxId: '${p}_spot_mono'),
            c.fxKey(p, '${p}_spot_mono', 'amount', c.rv, 0, 'ease_out'),
            c.fxKey(p, '${p}_spot_mono', 'amount', c.rv + 0.4, 100, 'easy_ease'),
            c.fx(p, 'color', {'brightness': -15}, fxId: '${p}_spot_dim'),
            if (cut != null && pain) c.fx(c.id('subject'), 'tint', {'color': '#D0101A', 'amount': 60}),
          ],
        ], optional: true),
    ];
  }

  static List<PStep> _pulse(PatternCtx c) {
    final p = c.plate;
    if (p == null) return const [];
    final keys = <Map<String, dynamic>>[];
    for (double t = c.rv; t < c.end - 0.1; t += 1.0) {
      keys.add(c.fxKey(p, '${p}_pulse', 'amount', t, 0, 'ease_out'));
      keys.add(c.fxKey(p, '${p}_pulse', 'amount', t + 0.2, 70, 'easy_ease'));
      keys.add(c.fxKey(p, '${p}_pulse', 'amount', t + 0.7, 0, 'easy_ease'));
    }
    return [
      PStep('pulse', [
        [{'op': 'pulse', 'layer': p, 'effect': 'tint', 'param': 'amount', 'from': 0, 'to': 70, 'period': 1.0, 'start': c.rv, 'duration': c.end - c.rv}],
        [c.fx(p, 'tint', {'color': '#D0101A', 'amount': 0}, fxId: '${p}_pulse'), ...keys],
      ], optional: true),
    ];
  }

  static List<PStep> _montage(PatternCtx c) {
    final media = c.medias('photos');
    const every = 0.35;
    final cuts = (c.d / every).floor().clamp(1, 14);
    const looks = ['mono', 'duotone_green', 'red', 'magenta', 'grunge', 'mono'];
    final out = <Map<String, dynamic>>[];
    for (int i = 0; i < cuts; i++) {
      final t = c.start + i * every;
      final du = i == cuts - 1 ? c.end - t : every;
      final p = 'm$i';
      if (media.isNotEmpty) {
        out.add(c.media2(p, media[i % media.length], at: t, du: du, cover: true));
      } else {
        out.add(c.shape(p, 'rect', c.w, c.h, c.w / 2, c.h / 2, fill: i.isEven ? '#2A2A2A' : '#6A1A1A', fill2: '#050505', at: t, du: du));
      }
      final id = c.id(p);
      switch (looks[i % looks.length]) {
        case 'mono':
          out.add(c.fx(id, 'mono', {'amount': 100}));
        case 'duotone_green':
          out.add(c.fx(id, 'duotone', {'dark': '#06200C', 'light': '#7CFF6B', 'amount': 100}));
        case 'red':
          out.add(c.fx(id, 'tint', {'color': '#D0101A', 'amount': 75}));
        case 'magenta':
          out.add(c.fx(id, 'duotone', {'dark': '#1A0420', 'light': '#FF4FD8', 'amount': 100}));
        default:
          out.add(c.fx(id, 'grunge', {'amount': 70}));
      }
    }
    return [
      PStep('montage', [
        [c.call('montage', 'montage', {'media': [for (final m in media) m.id], 'every': every, 'looks': ['threshold', 'duotone_green', 'red_paint', 'magenta', 'grunge', 'crop'], 'zoom': 8})],
        out,
      ]),
    ];
  }

  static List<PStep> _articleFocus(PatternCtx c) {
    final m = c.media('media');
    final quote = c.s('quote', c.s('line', 'According to the report, the plane crashed into the mountains.'));
    final hl = _hl(c, quote);
    return [
      PStep('article', [
        if (m != null)
          [
            c.comp('article', 'doc', {
              'media': m.id, 'fullbleed': true, 'enter': 'slide_up_over', 'tilt3d': {'from': [22, 0, -2], 'to': [0, 0, -1], 'duration': 0.5},
              'focus': [{'mark': 0, 'at': c.rv - c.start + 0.4, 'zoom': 1.9, 'duration': 0.35}], 'drift': true,
              'marks': [{'phrase': hl, 'style': 'highlight', 'delay': c.rv - c.start, 'ellipse_style': 'loop'}],
            }),
          ],
        if (m != null) [c.comp('article', 'doc', {'media': m.id, 'marks': [{'box': [0.08, 0.30, 0.80, 0.36], 'style': 'highlight', 'delay': 0.8}]})],
        [c.comp('source_card', 'doc', {'source': c.s('source', 'Source – website'), 'body': quote, 'highlights': [hl]})],
      ]),
    ];
  }

  static List<PStep> _circleMark(PatternCtx c) {
    final x = c.n('x', c.w * 0.55), y = c.n('y', c.h * 0.45);
    final cw = c.n('width', c.w * 0.16), chh = c.n('height', c.h * 0.2);
    final at = c.rv;
    return [
      PStep('circle', [
        [c.call('circle_mark', 'circle', {'x': x, 'y': y, 'width': cw, 'height': chh, 'color': '#F01818', 'stroke': 0.012, 'glow': true, 'draw': 0.5, 'hold': 0.9, 'undraw': true}, at: at)],
        [
          c.shape('circle', 'ellipse', cw, chh, x, y, fill: 'none', stroke: '#F01818', strokeWidth: c.h * 0.012, at: at),
          c.rot('circle', -90),
          c.fx(c.id('circle'), 'glow', {'amount': 50, 'radius': 16}),
          ...c.drawOn('circle', at, dur: 0.5),
          c.kf('circle', 'trim', at + 1.4, [0, 100], 'ease_in'),
          c.kf('circle', 'trim', at + 1.8, [100, 100], 'easy_ease'),
        ],
      ]),
    ];
  }

  static List<PStep> _insetCircle(PatternCtx c) {
    final m = c.media('media');
    final x = c.n('x', c.w * 0.72), y = c.n('y', c.h * 0.4), size = c.h * 0.3;
    final fx = c.n('from_x', c.w * 0.45), fy = c.n('from_y', c.h * 0.6);
    final label = c.upper('label', '');
    final at = c.rv;
    final fallback = <Map<String, dynamic>>[
      c.group('inset', x, y, at: at),
      c.anchor0('inset'),
      if (m != null) ...[
        c.media2('photo', m, heightPx: size * math.max(1.0, m.height / math.max(1, math.min(m.width, m.height))), x: 0, y: 0, at: at, parent: c.id('inset')),
        {'op': 'add_mask', 'layer': c.id('photo'), 'shape': 'ellipse', 'center': [m.width / 2, m.height / 2], 'size': [math.min(m.width, m.height), math.min(m.width, m.height)], 'feather': 2},
      ] else
        c.shape('photo', 'ellipse', size, size, 0, 0, fill: '#3A4048', fill2: '#15181C', at: at, parent: c.id('inset')),
      c.shape('ring', 'ellipse', size, size, 0, 0, fill: 'none', stroke: '#FFFFFF', strokeWidth: 6, at: at, parent: c.id('inset')),
      c.kf('inset', 'position', at, [fx, fy, 0], 'ease_out'),
      c.kf('inset', 'position', at + 0.4, [x, y, 0], 'easy_ease'),
      c.kf('inset', 'scale', at, [5, 5, 100], 'ease_out'),
      c.kf('inset', 'scale', at + 0.4, [100, 100, 100], 'easy_ease'),
      if (label.isNotEmpty) c.text('label', label, size: 0.05, color: '#FFD21F', x: x, y: y + size * 0.62, at: at + 0.35, animator: 'word_pop', animDur: 0.3, width: c.w * 0.4),
    ];
    return [
      PStep('inset', [
        [
          c.call('inset_circle', 'inset', {
            if (m != null) 'media': m.id, 'from': [fx, fy], 'x': x, 'y': y, 'size': 0.3, 'ring': {'color': '#FFFFFF', 'width': 6}, 'label': label,
            'label_style': 'yellow_outline', 'enter': 'grow_from_point', 'exit': 'shrink_to_point',
          }, at: at),
        ],
        fallback,
      ]),
    ];
  }

  static List<PStep> _quoteHole(PatternCtx c) {
    final m = c.media('media');
    final quote = c.s('quote', c.s('line', 'We made a pact that day.'));
    final src = c.upper('source', 'INTERVIEW');
    final hl = _hl(c, quote);
    final cw = c.w * 0.55, ch = c.h * 0.42;
    return [
      PStep('quote', [
        [
          c.call('quote_hole', 'quote', {
            if (m != null) 'plate': m.id, 'source': src, 'body': quote, 'highlights': [hl], 'hole': {'w': 0.55, 'h': 0.4, 'x': 0.5, 'y': 0.42, 'roughness': 60},
            'card_color': '#1F2B45', 'source_color': '#DDF06A', 'mark_color': '#C8323A',
          }),
        ],
        [
          if (m != null) c.media2('plate', m, cover: true),
          c.group('card', c.w / 2, c.h * 0.46),
          c.anchor0('card'),
          c.shape('paper', 'rect', cw, ch, 0, 0, fill: '#1F2B45', parent: c.id('card')),
          c.fx(c.id('paper'), 'torn_edge', {'side': 'top', 'amount': 60}),
          c.fx(c.id('paper'), 'shadow', {'distance': 14, 'blur': 24, 'opacity': 60}),
          c.text('src', src, size: 0.03, color: '#DDF06A', weight: 800, x: 0, y: -ch * 0.34, width: cw * 0.86, align: 'left', parent: c.id('card'), animator: 'typewriter', animDur: 0.5),
          c.text('body', quote, size: 0.042, weight: 600, x: 0, y: ch * 0.06, width: cw * 0.86, height: ch * 0.62, align: 'left', parent: c.id('card'), animator: 'fade_up',
              animDur: 0.4, at: c.start + 0.3, extra: {'marks': [{'phrase': hl, 'style': 'highlight', 'color': '#C8323A', 'delay': c.rv - c.start, 'duration': 0.6}]}),
          c.kf('card', 'scale', c.start, [104, 104, 100], 'ease_out'),
          c.kf('card', 'scale', c.start + 0.3, [100, 100, 100], 'easy_ease'),
        ],
      ]),
    ];
  }

  static List<PStep> _listCard(PatternCtx c) {
    final items = c.list('items', const ['ONE', 'TWO', 'THREE']).take(6).toList();
    final cw = c.w * 0.42, ch = c.h * 0.7;
    final out = <Map<String, dynamic>>[
      c.group('list', c.w * 0.5, c.h * 0.5),
      c.anchor0('list'),
      c.shape('paper', 'rect', cw, ch, 0, 0, fill: '#F6F1E2', parent: c.id('list')),
      c.fx(c.id('paper'), 'shadow', {'distance': 14, 'blur': 22, 'opacity': 55}),
      c.fx(c.id('paper'), 'paper', {'amount': 60}),
    ];
    for (int i = 0; i < items.length; i++) {
      final t = math.min(c.end - 0.3, c.rv + i * 0.4);
      final y = -ch * 0.36 + ch * 0.72 * i / math.max(1, items.length - 1);
      out.add(c.text('it$i', '• ${items[i]}', size: 0.05, color: '#1A1A3A', font: 'Kalam', weight: 700, x: 0, y: y, width: cw * 0.84, align: 'left', at: t,
          parent: c.id('list'), animator: 'fade_up', animDur: 0.25, shadow: false));
      out.addAll(c.pop('it$i', t, over: 160, dur: 0.3));
    }
    return [
      PStep('list', [
        [c.call('list_card', 'list', {'items': items, 'font': 'Kalam', 'item_interval': 0.4, 'pop_scale': 1.6, 'exit': 'drop'})],
        out,
      ]),
    ];
  }

  static List<PStep> _stainDoodle(PatternCtx c) {
    final x = c.n('x', c.w * 0.5), y = c.n('y', c.h * 0.5);
    final at = c.rv;
    return [
      PStep('stain', [
        [c.call('stain', 'stain', {'x': x, 'y': y, 'size': 0.45, 'color': '#D00010', 'tones': 2, 'grow': 0.5, 'roughness': 70}, at: at)],
        [
          c.shape('stain', 'ellipse', c.h * 0.45, c.h * 0.4, x, y, fill: '#D00010', at: at),
          c.set('stain', 'opacity', 70),
          c.shape('stain2', 'ellipse', c.h * 0.25, c.h * 0.22, x + c.h * 0.12, y - c.h * 0.08, fill: '#8A000A', at: at + 0.15),
          ...c.pop('stain', at, over: 104, dur: 0.5),
          ...c.pop('stain2', at + 0.15, over: 104, dur: 0.5),
        ],
      ]),
      PStep('doodle', [
        [c.call('doodle', 'doodle', {'paths': [[[x - c.w * 0.2, y + c.h * 0.25], [x, y + c.h * 0.32], [x + c.w * 0.2, y + c.h * 0.22]]], 'color': '#FFFFFF', 'width': 4, 'draw': 2.0, 'jitter': true}, at: at + 0.6)],
        [
          c.shape('doodle', 'path', 10, 10, 0, 0, fill: 'none', stroke: '#FFFFFF', strokeWidth: 5, at: at + 0.6,
              points: [[x - c.w * 0.2, y + c.h * 0.25], [x - c.w * 0.07, y + c.h * 0.33], [x + c.w * 0.07, y + c.h * 0.3], [x + c.w * 0.2, y + c.h * 0.22]]),
          {'op': 'update_layer', 'layer': c.id('doodle'), 'smooth': true, 'arrow_end': true},
          ...c.drawOn('doodle', at + 0.6, dur: 2.0),
        ],
      ], optional: true),
    ];
  }

  static List<PStep> _calendarFlip(PatternCtx c) {
    final from = c.n('from', 1), to = c.n('to', 72);
    final x = c.w * 0.5, y = c.h * 0.5, size = c.w * 0.2;
    return [
      PStep('calendar', [
        [c.call('calendar_flip', 'cal', {'from': from, 'to': to, 'rate': 4, 'header_color': '#E0245E', 'label': 'CALENDAR', 'x': x, 'y': y, 'size': 0.2, 'tilt': [50, 0, -20]})],
        [
          c.group('cal', x, y),
          c.anchor0('cal'),
          c.shape('page', 'rect', size, size * 1.1, 0, 0, fill: '#FAFAFA', corner: size * 0.04, parent: c.id('cal')),
          c.fx(c.id('page'), 'shadow', {'distance': 16, 'blur': 24, 'opacity': 55}),
          c.shape('head', 'rect', size, size * 0.24, 0, -size * 0.43, fill: '#E0245E', corner: size * 0.04, parent: c.id('cal')),
          c.text('lbl', 'CALENDAR', size: 0.026, weight: 800, x: 0, y: -size * 0.43, width: size, parent: c.id('cal'), animator: null, shadow: false),
          c.text('day', '${from.round()}', size: 0.16, color: '#141414', x: 0, y: size * 0.12, width: size, parent: c.id('cal'), animator: null, shadow: false,
              extra: {'counter': {'from': from, 'to': to, 'delay': 0.4, 'duration': math.max(0.5, math.min(c.d - 0.8, (to - from).abs() / 24))}}),
          c.rot('cal', -6),
          ...c.pop('cal', c.start, over: 108, dur: 0.35),
        ],
      ]),
    ];
  }

  static List<PStep> _clockOverlay(PatternCtx c) {
    final r = c.h * 0.7;
    final x = c.w / 2, y = c.h / 2;
    final text = c.upper('text', '');
    final ticks = [
      for (int i = 0; i < 12; i++) ...[
        c.shape('tick$i', 'rect', 8, r * 0.1, r * 0.88 * math.sin(i * math.pi / 6), -r * 0.88 * math.cos(i * math.pi / 6), fill: '#FFFFFF', parent: c.id('clock')),
        c.rot('tick$i', i * 30.0),
      ],
    ];
    return [
      PStep('clock', [
        [c.call('clock_overlay', 'clock', {'opacity': 0.3, 'scale': 1.4, 'spin': 2, 'sfx': false})],
        [
          c.group('clock', x, y),
          c.anchor0('clock'),
          c.shape('face', 'ellipse', r * 2, r * 2, 0, 0, fill: 'none', stroke: '#FFFFFF', strokeWidth: 12, parent: c.id('clock')),
          ...ticks,
          c.shape('hour', 'rect', 14, r * 0.5, 0, -r * 0.25, fill: '#FFFFFF', parent: c.id('clock')),
          c.shape('min', 'rect', 8, r * 0.8, 0, -r * 0.4, fill: '#FFFFFF', parent: c.id('clock')),
          {'op': 'set_property', 'target': c.id('hour'), 'prop': 'anchor', 'value': [7, r * 0.5, 0]},
          {'op': 'set_property', 'target': c.id('min'), 'prop': 'anchor', 'value': [4, r * 0.8, 0]},
          c.set('hour', 'position', [0, 0, 0]),
          c.set('min', 'position', [0, 0, 0]),
          c.kf('min', 'rotation', c.start, [0, 0, 0], 'linear'),
          c.kf('min', 'rotation', c.end, [0, 0, 720 * c.d / 2], 'linear'),
          c.kf('hour', 'rotation', c.start, [0, 0, 0], 'linear'),
          c.kf('hour', 'rotation', c.end, [0, 0, 60 * c.d / 2], 'linear'),
          c.set('clock', 'opacity', 30),
        ],
      ]),
      if (text.isNotEmpty) PStep('text', [[c.text('dur', text, size: 0.13, color: _Kit.yellow, at: c.rv, animator: 'random_pop', animDur: 0.5)]], optional: true),
    ];
  }

  static List<PStep> _statTitle(PatternCtx c) {
    final l1 = c.upper('line1', c.upper('number', '100'));
    final l2 = c.upper('line2', '');
    return [
      PStep('title', [
        [c.call('stat_title', 'title', {'line1': l1, 'line2': l2, 'emphasis': 1.6}, at: c.rv - 0.2)],
        [c.text('l1', l1, size: 0.13, style: 'stat_red_outline', y: c.h * 0.44, at: c.rv - 0.2, animator: 'typewriter_soft', animDur: 0.5)],
        [
          c.text('l1', l1, size: 0.13, color: '#FFFFFF', y: c.h * 0.44, at: c.rv - 0.2, animator: 'word_pop', animDur: 0.4),
          if (l2.isNotEmpty) c.text('l2', l2, size: 0.06, color: '#FFFFFF', weight: 800, y: c.h * 0.58, at: c.rv + 0.2, animator: 'fade_up', animDur: 0.4),
        ],
      ]),
    ];
  }

  static List<PStep> _mapLabelsTyped(PatternCtx c) {
    final places = c.places(const ['Chile', 'Argentina', 'Uruguay']);
    return [
      PStep('map', [
        [c.call('map', 'map', {'countries': places, 'style': 'satellite', 'label_animator': 'typewriter', 'label_stagger': 0.6, 'label_rotate': 'auto'})],
        [c.comp('map', 'map', {'countries': places, 'style': 'dark'})],
        [c.text('label', places.join(' · ').toUpperCase(), size: 0.06, animator: 'typewriter', animDur: 1.2, at: c.rv)],
      ]),
    ];
  }

  // ---- existing features
  static List<PStep> _presenter(PatternCtx c) => const [];

  /// Scale keys on the plate, relative to its current scale (resolved at run time).
  static List<Map<String, dynamic>> _platePush(PatternCtx c, {double from = 1.0, double to = 1.1, String ease = 'easy_ease'}) {
    final p = c.plate;
    if (p == null) return const [];
    return [
      {'op': '@scale_keys', 'layer': p, 'from': from, 'to': to, 'start': c.start, 'end': c.end, 'ease': ease},
    ];
  }

  static List<PStep> _reenactment(PatternCtx c) {
    final m = c.media('media');
    final cuts = c.medias('cutouts');
    return [
      if (m != null || cuts.isNotEmpty)
        PStep('shot', [
          [
            {
              'op': 'add_shot', 'id': c.id('shot'), 'start': c.start, 'duration': c.d, if (m != null) 'plate': m.id,
              'layers': [for (final k in cuts) {'media': k.id}], 'style': 'character_focus', 'look': 'none',
              if (c.tone == 'snow') 'atmosphere': 'snow',
            },
          ],
          _platePush(c),
        ], optional: true),
      if (m == null && cuts.isEmpty) PStep('push', [_platePush(c)], optional: true),
    ];
  }

  static List<PStep> _craneDown(PatternCtx c) {
    final m = c.media('media');
    return [
      if (m != null)
        PStep('shot', [
          [{'op': 'add_shot', 'id': c.id('shot'), 'start': c.start, 'duration': c.d, 'plate': m.id, 'layers': [], 'camera': [{'move': 'reveal', 'start': 0, 'duration': c.d, 'intensity': 0.6}]}],
          _platePush(c, from: 1.15, to: 1.05),
        ], optional: true)
      else
        PStep('push', [_platePush(c, from: 1.15, to: 1.05)], optional: true),
    ];
  }

  static List<PStep> _pushBetween(PatternCtx c) {
    final m = c.media('media');
    final cuts = c.medias('cutouts');
    return [
      if (m != null)
        PStep('shot', [
          [
            {'op': 'add_shot', 'id': c.id('shot'), 'start': c.start, 'duration': c.d, 'plate': m.id, 'layers': [for (final k in cuts) {'media': k.id}], 'style': 'crowd_pass'},
          ],
          _platePush(c, to: 1.14),
        ], optional: true)
      else
        PStep('push', [_platePush(c, to: 1.14)], optional: true),
    ];
  }

  static List<PStep> _rackEncounter(PatternCtx c) => [
        PStep('push', [_platePush(c, to: 1.06)], optional: true),
        ..._rackFocus(c),
      ];

  static List<PStep> _fogTracking(PatternCtx c) => [
        PStep('push', [_platePush(c, to: 1.08)], optional: true),
        PStep('fog', [
          [c.solid('fog', '#00000000'), c.fx(c.id('fog'), 'particles', {'kind': 'smoke', 'amount': 55, 'speed': 0.8, 'color': '#D8E0E6'})],
        ], optional: true),
        ..._gauge(c),
      ];

  static List<PStep> _detailInsert(PatternCtx c) => [
        PStep('push', [_platePush(c, to: 1.18, ease: 'ease_out')], optional: true),
        if (c.plate != null) PStep('vignette', [[c.fx(c.plate!, 'vignette', {'amount': 70}, fxId: '${c.plate}_detail_vig')]], optional: true),
      ];

  static List<PStep> _crashToBlack(PatternCtx c) {
    final at = c.rv;
    final hold = math.min(1.5, math.max(0.4, c.end - at - 0.4));
    return [
      PStep('push', [_platePush(c, to: 1.12, ease: 'ease_in')], optional: true),
      PStep('shake', [
        [{'op': 'camera_shake', 'start': at, 'duration': 0.5, 'amount': 70, 'style': 'impact'}],
      ], optional: true),
      PStep('black', [
        [{'op': 'cut_to_black', 'at': c.end - hold, 'hold': hold, 'silence': true}],
        [c.solid('black', '#000000', at: c.end - hold, du: hold)],
      ]),
    ];
  }

  static List<PStep> _censor(PatternCtx c) => [
        PStep('bar', [
          [c.comp('censor_bar', 'censor', {'x': c.n('x', c.w / 2), 'y': c.n('y', c.h * 0.38), 'width': c.w * 0.18, 'height': c.h * 0.05})],
          [c.shape('censor', 'rect', c.w * 0.18, c.h * 0.05, c.w / 2, c.h * 0.38, fill: '#000000')],
        ]),
      ];
}
