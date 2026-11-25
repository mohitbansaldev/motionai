import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart' show Matrix4, Vector3;

import '../engine/evaluator.dart';
import '../engine/precomp.dart';
import '../model/anim_prop.dart';
import '../model/camera.dart';
import '../model/easing.dart';
import '../model/effects_catalog.dart';
import '../model/layer.dart';
import '../model/project.dart';
import 'camera_presets.dart';

part 'doc_transitions_v3.dart'; // V3-D: powder/debris bursts, zoom blur, eye reflection, holes, shatter, slice, film slide…

// V2-C: documentary transitions between two shots / layers.
//
// Everything here is pure model code: a transition only writes keyframes,
// masks, effects (incl. the `burn_edge` / `page_curl` effects drawn by
// lib/ui/preview/fx/transition_painters.dart) and a few helper layers, so the
// preview and the export render it with the same renderer.
//
// Naming (so a transition can be re-applied / replaced cleanly):
//   effects + masks on the outgoing layer:  <from>_trout_<kind>
//   effects + masks on the incoming layer:  <to>_trin_<kind>
//   helper layers (overlays, colour copy, SFX):  tr_<to>_<kind>

/// One parameter of a transition (for the catalog / MCP tool schemas).
class TransitionParam {
  final String name;
  final String type; // number | string | point | size | layer | media | bool | color
  final Object? defaultValue;
  final String description;
  final List<String> options;
  const TransitionParam(this.name, this.type, this.defaultValue, this.description, {this.options = const []});

  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type,
        if (defaultValue != null) 'default': defaultValue,
        'description': description,
        if (options.isNotEmpty) 'options': options,
      };
}

/// A transition type: label, what it suits, defaults and params.
class TransitionDef {
  final String id;
  final String label;
  final String bestFor;
  final double duration; // default length (s)
  final double pre; // share of the duration before the cut (0..1)
  final List<String> sounds; // default SFX kinds (peak on the cut)
  final List<TransitionParam> params;
  const TransitionDef(this.id, this.label, this.bestFor,
      {required this.duration, this.pre = 0.5, this.sounds = const ['whoosh'], this.params = const []});

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'best_for': bestFor,
        'default_duration': duration,
        'cut_at': pre,
        'sound': sounds,
        'params': [for (final p in params) p.toJson()],
      };
}

/// What a transition did (used by the `transition` op).
class TransitionResult {
  final String type;
  final double cut, start, end;
  final List<String> created;
  final List<String> log;
  TransitionResult(this.type, this.cut, this.start, this.end, this.created, this.log);
}

/// Screen box (composition px).
class _Box {
  final double x0, y0, x1, y1;
  const _Box(this.x0, this.y0, this.x1, this.y1);
  double get w => x1 - x0;
  double get h => y1 - y0;
  double get cx => (x0 + x1) / 2;
  double get cy => (y0 + y1) / 2;
  static _Box around(double cx, double cy, double w, double h) => _Box(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2);
}

// Eases (cubic-bezier, After Effects graph style).
const _inOut = Easing.bezierCurve(0.65, 0, 0.35, 1);
const _whip = Easing.bezierCurve(0.82, 0, 0.18, 1);
const _expoIn = Easing.bezierCurve(0.7, 0, 0.84, 0);
const _expoOut = Easing.bezierCurve(0.16, 1, 0.3, 1);
const _inCubic = Easing.bezierCurve(0.32, 0, 0.67, 0);
const _outCubic = Easing.bezierCurve(0.33, 1, 0.68, 1);
const _soft = Easing.bezierCurve(0.45, 0, 0.55, 1);

class DocTransitions {
  static const _dir = TransitionParam('direction', 'string', 'left', 'travel direction', options: ['left', 'right', 'up', 'down']);
  static const _tone = TransitionParam('tone', 'string', 'warm', 'colour preset', options: ['warm', 'cold', 'neutral']);
  static const _target = TransitionParam('target', 'layer', null,
      'layer to fly into (door/window/arch): a layer of this comp or of the outgoing shot precomp; default the frame centre');
  static const _point = TransitionParam('point', 'point', null, '[x, y] screen point instead of target');
  static const _size = TransitionParam('size', 'size', null, '[w, h] screen size of the region at point');
  static const _center = [
    TransitionParam('cx', 'number', 50, 'centre X % of the frame'),
    TransitionParam('cy', 'number', 50, 'centre Y % of the frame'),
  ];

  static const List<TransitionDef> catalog = [
    TransitionDef('push_through', 'Push Through', 'flying through a door, window, arch or screen into the next scene',
        duration: 1.2, pre: 0.75, sounds: ['whoosh'], params: [
          _target, _point, _size,
          TransitionParam('shape', 'string', 'rect', 'opening shape', options: ['rect', 'ellipse']),
        ]),
    TransitionDef('foreground_wipe', 'Foreground Wipe', 'hiding a cut behind a pillar / tree / person passing the lens',
        duration: 0.8, sounds: ['whoosh'], params: [
          _dir,
          TransitionParam('media', 'media', null, 'cut-out image (tree, pillar, person PNG); default a generated silhouette'),
          TransitionParam('shape', 'string', 'pillar', 'generated silhouette', options: ['pillar', 'tree', 'person']),
          TransitionParam('width', 'number', 0.55, 'object width as a share of the frame width'),
        ]),
    TransitionDef('zoom_into_photo', 'Zoom Into Photo', 'a framed photo / newspaper / screen in the scene becomes the next shot',
        duration: 1.6, pre: 0.55, sounds: ['swoosh_long'], params: [
          TransitionParam('layer', 'layer', null, 'the picture layer (this comp or inside the outgoing precomp)'),
          _point, _size,
        ]),
    TransitionDef('map_drop', 'Map Drop', 'diving from a map or aerial view down through clouds to the place',
        duration: 1.5, pre: 0.55, sounds: ['swoosh_long', 'sub_drop'], params: [
          _target, _point,
          TransitionParam('push', 'number', 1.06, 'how much closer the incoming shot ends (1 = no crop)'),
        ]),
    TransitionDef('match_cut', 'Match Cut', 'two shots with the same shape (eye → moon, coin → planet)',
        duration: 0.6, sounds: ['swoosh_short'], params: [
          TransitionParam('from_point', 'point', null, '[x, y] of the shape in the outgoing shot (screen px)'),
          TransitionParam('to_point', 'point', null, '[x, y] of the shape in the incoming shot'),
          TransitionParam('from_size', 'number', 300, 'shape size (px) in the outgoing shot'),
          TransitionParam('to_size', 'number', 300, 'shape size (px) in the incoming shot'),
        ]),
    TransitionDef('whip_pan', 'Whip Pan', 'energetic jumps between places or times', duration: 0.45, sounds: ['whoosh'], params: [_dir]),
    TransitionDef('parallax_slide', 'Parallax Slide', 'sliding between two 3D photo shots (make_3d precomps): layers move by depth',
        duration: 1.0, sounds: ['swoosh_long'], params: [_dir]),
    TransitionDef('paper_tear', 'Paper Tear', 'archive / newspaper stories: the shot is ripped away like paper',
        duration: 0.9, pre: 0.35, sounds: ['paper'], params: [_dir]),
    TransitionDef('burn_edge', 'Burn Edge', 'old letters, maps and photos burning away to the next scene',
        duration: 1.6, sounds: ['fire_bed'], params: [..._center, _tone]),
    TransitionDef('page_turn', 'Page Turn', 'book / diary / archive chapters: the page curls away',
        duration: 1.2, sounds: ['paper'], params: [TransitionParam('angle', 'number', 200, 'direction the page turns (degrees, 180 = to the left)')]),
    TransitionDef('focus_pull', 'Focus Pull', 'calm, reflective moments; changing subject', duration: 1.0, sounds: ['reverse_cymbal']),
    TransitionDef('dolly_zoom', 'Dolly Zoom (Vertigo)', 'shock and realisation before a reveal',
        duration: 1.6, pre: 0.85, sounds: ['riser', 'hit']),
    TransitionDef('film_burn', 'Film Burn', 'flashbacks, memories, vintage footage', duration: 1.0, sounds: ['reverse_cymbal'], params: [_tone]),
    TransitionDef('light_leak_wipe', 'Light Leak Wipe', 'travel, warm nostalgic moments', duration: 1.0, sounds: ['swoosh_long'], params: [_tone]),
    TransitionDef('ink_bleed', 'Ink Bleed', 'history, art, handwritten documents', duration: 1.2, sounds: ['swoosh_long'],
        params: [..._center, TransitionParam('tone', 'string', 'neutral', 'ink tint', options: ['warm', 'cold', 'neutral']),
          TransitionParam('incoming', 'string', null, 'V3-D: "duotone_of_outgoing" = the incoming is a navy duotone of the same image (turning points)')]),
    TransitionDef('smoke_reveal', 'Smoke Reveal', 'war, mystery, legends', duration: 1.4, sounds: ['swoosh_long'],
        params: [TransitionParam('tone', 'string', 'neutral', 'smoke colour', options: ['warm', 'cold', 'neutral'])]),
    TransitionDef('bw_to_colour', 'B&W to Colour', 'the past coming to life: an old photo blooms into colour',
        duration: 2.0, pre: 0.1, sounds: ['shutter'], params: _center),
    TransitionDef('glitch_cut', 'Glitch Cut', 'tech, hacking, breaking news, tension', duration: 0.6, sounds: ['glitch']),
    TransitionDef('flash_cut', 'Flash Cut', 'camera-flash / impact cut on a beat', duration: 0.5, pre: 0.4,
        sounds: ['swoosh_reverse', 'hit'], params: [TransitionParam('color', 'color', '#FFFFFF', 'flash colour'), _tone]),
    TransitionDef('dip_to_black', 'Dip to Black', 'time passing, chapter ends, solemn moments', duration: 0.9,
        sounds: ['swoosh_reverse'], params: [TransitionParam('color', 'color', '#000000', 'dip colour')]),
    // V3-D >>> transitions, mood & character FX (doc_transitions_v3.dart)
    ..._v3Catalog,
    // <<< V3-D
  ];

  static List<String> get types => [for (final d in catalog) d.id];

  static TransitionDef? byId(String id) {
    for (final d in catalog) {
      if (d.id == id) return d;
    }
    return null;
  }

  static List<Map<String, dynamic>> catalogJson() => [for (final d in catalog) d.toJson()];

  /// Registers every type with a transition registry (lib/core/presets/transition_registry.dart).
  static void registerAll(
      void Function(String name, void Function(Composition comp, Layer outgoing, Layer incoming, Map<String, dynamic> params) fn) register) {
    for (final d in catalog) {
      register(d.id, (comp, outgoing, incoming, params) => apply(comp, outgoing, incoming, d.id, params));
    }
  }

  /// Applies transition [type] from [outgoing] to [incoming] in [comp].
  /// [params]: `at` (cut, default incoming.start), `duration`, plus the
  /// type's params. A `Project` under `_project` (or [project]) lets it reach
  /// into shot precomps.
  static void apply(Composition comp, Layer outgoing, Layer incoming, String type, Map<String, dynamic> params, {Project? project}) {
    run(comp, outgoing, incoming, type, params, project: project ?? (params['_project'] is Project ? params['_project'] as Project : null));
  }

  /// Like [apply], returning what was done. Throws [ArgumentError] on bad input.
  static TransitionResult run(Composition comp, Layer a, Layer b, String type, Map<String, dynamic> params, {Project? project}) {
    final def = byId(type);
    if (def == null) throw ArgumentError('Unknown transition "$type". Types: ${types.join(', ')}');
    if (a.id == b.id) throw ArgumentError('transition needs two different layers');
    for (final l in [a, b]) {
      if (l.type == LayerType.audio || l.type == LayerType.nullObject) throw ArgumentError('"${l.id}" is not a visual layer');
      if (comp.layerById(l.id) == null) throw ArgumentError('"${l.id}" is not in comp "${comp.id}"');
    }
    final x = _Ctx(comp, a, b, def, params, project);
    x.prepare();
    switch (type) {
      case 'push_through':
        x.pushThrough();
      case 'foreground_wipe':
        x.foregroundWipe();
      case 'zoom_into_photo':
        x.zoomIntoPhoto();
      case 'map_drop':
        x.mapDrop();
      case 'match_cut':
        x.matchCut();
      case 'whip_pan':
        x.whipPan();
      case 'parallax_slide':
        x.parallaxSlide();
      case 'paper_tear':
        x.paperTear();
      case 'burn_edge':
        x.burnEdge();
      case 'page_turn':
        x.pageTurn();
      case 'focus_pull':
        x.focusPull();
      case 'dolly_zoom':
        x.dollyZoom();
      case 'film_burn':
        x.filmBurn();
      case 'light_leak_wipe':
        x.lightLeakWipe();
      case 'ink_bleed':
        x.inkBleed();
      case 'smoke_reveal':
        x.smokeReveal();
      case 'bw_to_colour':
        x.bwToColour();
      case 'glitch_cut':
        x.glitchCut();
      case 'flash_cut':
        x.flashCut();
      case 'dip_to_black':
        x.dipToBlack();
      // V3-D >>>
      default:
        x.v3(type);
      // <<< V3-D
    }
    if (comp.duration < b.end) comp.duration = b.end;
    return TransitionResult(type, x.cut, x.t0, x.t1, x.created, x.log);
  }

  /// Removes what an earlier transition into [incoming] / out of [outgoing] added.
  static void clean(Composition comp, Layer outgoing, Layer incoming) {
    outgoing.effects.removeWhere((e) => e.id.startsWith('${outgoing.id}_trout_'));
    outgoing.masks.removeWhere((m) => m.id.startsWith('${outgoing.id}_trout_'));
    incoming.effects.removeWhere((e) => e.id.startsWith('${incoming.id}_trin_'));
    incoming.masks.removeWhere((m) => m.id.startsWith('${incoming.id}_trin_'));
    final prefix = 'tr_${incoming.id}_';
    final gone = {for (final l in comp.layers) if (l.id.startsWith(prefix)) l.id};
    if (gone.isEmpty) return;
    comp.layers.removeWhere((l) => gone.contains(l.id));
    for (final l in comp.layers) {
      if (gone.contains(l.parentId)) l.parentId = null;
      if (gone.contains(l.matte?.layerId)) l.matte = null;
    }
  }
}

/// Working state of one transition.
class _Ctx {
  final Composition comp;
  final Layer a, b;
  final TransitionDef def;
  final Map<String, dynamic> params;
  final Project? project;
  final List<String> created = [];
  final List<String> log = [];

  late double cut, dur, t0, t1, fr;

  // Rest transforms: outgoing at t0, incoming at t1.
  late List<double> aPos, aScale, aRot, bPos, bScale, bRot;
  late double aOpacity, bOpacity;

  _Ctx(this.comp, this.a, this.b, this.def, this.params, this.project);

  double get w => comp.width;
  double get h => comp.height;

  // ------------------------------------------------------------ params

  double? optNum(String k) {
    final v = params[k];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    throw ArgumentError('transition "$k" must be a number');
  }

  double n(String k, double d) => optNum(k) ?? d;

  String str(String k, String d) {
    final v = params[k];
    return v == null ? d : '$v';
  }

  String choice(String k, String d, List<String> options) {
    final v = str(k, d).toLowerCase();
    if (!options.contains(v)) throw ArgumentError('transition "$k" must be one of ${options.join(', ')} (got "$v")');
    return v;
  }

  List<double>? vec(String k) {
    final v = params[k];
    if (v == null) return null;
    if (v is num) return [v.toDouble()];
    if (v is List && v.isNotEmpty && v.every((e) => e is num)) return [for (final e in v) (e as num).toDouble()];
    throw ArgumentError('transition "$k" must be a number or [x, y]');
  }

  /// Direction unit vector (screen) from the `direction` param.
  (double, double) dirVec([String d = 'left']) => switch (choice('direction', d, const ['left', 'right', 'up', 'down'])) {
        'right' => (1.0, 0.0),
        'up' => (0.0, -1.0),
        'down' => (0.0, 1.0),
        _ => (-1.0, 0.0),
      };

  List<double> toneRgb(String tone, {List<double> warm = const [255, 160, 70], List<double> cold = const [120, 175, 255], List<double> neutral = const [235, 235, 235]}) =>
      switch (tone) { 'cold' => cold, 'neutral' => neutral, _ => warm };

  // ------------------------------------------------------------ timing

  /// Works out the cut and window, arranges overlaps/trims and samples the
  /// rest transforms. Per-type tweaks (hard cuts) call [hardCut] afterwards.
  void prepare() {
    fr = comp.frameDuration;
    cut = optNum('at') ?? b.start;
    dur = math.max(fr * 4, optNum('duration') ?? def.duration);
    final pre = def.pre;
    if (cut <= a.start + fr) throw ArgumentError('cut ${cut.toStringAsFixed(2)} s is not after the start of "${a.id}" (${a.start.toStringAsFixed(2)} s)');
    if (cut >= b.end - fr) throw ArgumentError('cut ${cut.toStringAsFixed(2)} s is not before the end of "${b.id}" (${b.end.toStringAsFixed(2)} s)');
    // Fit the window into the two layers.
    final maxPre = (cut - a.start) * 0.98, maxPost = (b.end - cut) * 0.98;
    var d = dur;
    if (pre > 0 && d * pre > maxPre) d = maxPre / pre;
    if (pre < 1 && d * (1 - pre) > maxPost) d = maxPost / (1 - pre);
    if (d < dur - 1e-6) log.add('${def.label}: shortened to ${d.toStringAsFixed(2)} s to fit the shots');
    dur = math.max(fr * 2, d);
    t0 = cut - dur * pre;
    t1 = cut + dur * (1 - pre);

    DocTransitions.clean(comp, a, b);
    _setStart(b, t0);
    _setEnd(a, t1);

    aPos = a.prop(Props.position).valueAt(t0);
    aScale = a.prop(Props.scale).valueAt(t0);
    aRot = a.prop(Props.rotation).valueAt(t0);
    aOpacity = a.prop(Props.opacity).valueAt(t0)[0];
    bPos = b.prop(Props.position).valueAt(t1);
    bScale = b.prop(Props.scale).valueAt(t1);
    bRot = b.prop(Props.rotation).valueAt(t1);
    bOpacity = b.prop(Props.opacity).valueAt(t1)[0];
    for (final p in [Props.position, Props.scale, Props.rotation, Props.opacity]) {
      _clear(a.prop(p), t0, t1);
      _clear(b.prop(p), t0, t1);
    }
    incomingOnTop(true);
  }

  /// Hard cut: the outgoing ends and the incoming starts exactly at the cut.
  void hardCut() {
    _setEnd(a, cut);
    _setStart(b, cut);
  }

  static void _clear(AnimProp p, double from, double to) {
    final v = p.valueAt(from);
    p.keyframes.removeWhere((k) => k.time >= from - kTimeEpsilon && k.time <= to + kTimeEpsilon);
    if (p.keyframes.isEmpty) p.staticValue = v;
  }

  /// Seconds of source media a layer has before its start / after its end.
  double _headRoom(Layer l) {
    if (l.type == LayerType.video) return l.sourceIn / l.speed;
    if (l.type == LayerType.comp && !l.loop) return l.sourceIn / l.speed;
    return double.infinity;
  }

  double _tailRoom(Layer l) {
    final p = project;
    if (l.type == LayerType.video && p != null) {
      final m = l.mediaId == null ? null : p.media[l.mediaId];
      if (m != null && m.duration > 0) return math.max(0.0, (m.duration - l.sourceTimeAt(l.end)) / l.speed);
    }
    if (l.type == LayerType.comp && !l.loop && p != null) {
      final c = Precomp.childOf(p, l);
      if (c != null) return math.max(0.0, (c.duration - l.sourceTimeAt(l.end)) / l.speed);
    }
    return double.infinity;
  }

  /// Moves the start of [l] to [ns]: trims (uses source handles) when it can,
  /// otherwise shifts the content earlier.
  void _setStart(Layer l, double ns) {
    final dt = ns - l.start;
    if (dt.abs() < 1e-9) return;
    final end = l.end;
    if (dt > 0) {
      l.sourceIn += dt * l.speed;
      l.start = ns;
      l.duration = math.max(fr, end - ns);
      return;
    }
    final need = -dt;
    final use = math.min(need, _headRoom(l));
    final rest = need - use;
    if (rest > 1e-9) {
      l.moveTo(l.start - rest);
      log.add('"${l.id}" has no handle before its start: it now plays ${rest.toStringAsFixed(2)} s earlier');
    }
    l.sourceIn = math.max(0.0, l.sourceIn - use * l.speed);
    l.start = ns;
    l.duration = math.max(fr, end - ns);
  }

  /// Moves the end of [l] to [ne] (as far as its source allows).
  void _setEnd(Layer l, double ne) {
    if (ne > l.end) {
      final room = _tailRoom(l);
      final want = ne - l.end;
      if (want > room + 1e-6) {
        log.add('"${l.id}" has only ${room.toStringAsFixed(2)} s of source after its end: it ends early');
        ne = l.end + room;
      }
    }
    l.duration = math.max(fr, ne - l.start);
  }

  // ------------------------------------------------------------ stacking

  /// Puts [b] directly above [a] ([top] true) or [a] directly above [b].
  void incomingOnTop(bool top) {
    final upper = top ? b : a, lower = top ? a : b;
    final iu = comp.indexOf(upper.id), il = comp.indexOf(lower.id);
    if (iu < il) return;
    // V2-lead: move the LOWER layer down to just below the upper one (not the upper one up),
    // so chained transitions in a sequence keep earlier shots above later ones.
    comp.layers.remove(lower);
    comp.layers.insert(comp.indexOf(upper.id) + 1, lower);
  }

  /// A full-frame helper layer above both shots.
  Layer overlay(String kind, {String name = 'Transition', LayerType type = LayerType.solid, int color = 0x00000000, double? start, double? end, double? width, double? height}) {
    final id = 'tr_${b.id}_$kind';
    final s = start ?? t0, e = end ?? t1;
    final l = Layer(
      id: id,
      name: name,
      type: type,
      start: s,
      duration: math.max(fr, e - s),
      width: width ?? w,
      height: height ?? h,
      color: color,
    );
    l.prop(Props.position).staticValue = [w / 2, h / 2, 0];
    final idx = math.min(comp.indexOf(a.id), comp.indexOf(b.id));
    comp.layers.insert(math.max(0, idx), l);
    created.add(id);
    return l;
  }

  // ------------------------------------------------------------ effects

  Effect fx(Layer l, String type, {Map<String, List<double>> values = const {}, String? tag}) {
    final role = l.id == a.id ? 'trout' : 'trin';
    final id = '${l.id}_${role}_${tag ?? type}';
    l.effects.removeWhere((e) => e.id == id);
    final e = EffectsCatalog.create(type, id);
    values.forEach((k, v) {
      final p = e.params[k];
      if (p == null) throw ArgumentError('effect $type has no param $k');
      p.staticValue = v;
    });
    l.effects.add(e);
    return e;
  }

  /// Keyframes for an effect param: list of (time, value, easing).
  static void keys(AnimProp p, List<(double, double, Easing)> ks) {
    for (final (t, v, e) in ks) {
      p.setKeyframe(t, [v], easing: e);
    }
  }

  static void key(AnimProp p, double t, List<double> v, Easing e) => p.setKeyframe(t, v, easing: e);

  // ------------------------------------------------------------ geometry

  /// Evaluated item of [l] at [t] (2D world matrix when it is not drawn then).
  Matrix4 _matrixAt(Composition c, Layer l, double t) {
    for (final it in Evaluator.evaluate(c, t, velocity: false)) {
      if (it.layer.id == l.id) return it.matrix;
    }
    return Evaluator.worldMatrix(c, l, t);
  }

  static _Box _boxOf(List<(double, double)> pts) {
    double x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    for (final (x, y) in pts) {
      x0 = math.min(x0, x);
      y0 = math.min(y0, y);
      x1 = math.max(x1, x);
      y1 = math.max(y1, y);
    }
    return _Box(x0, y0, x1, y1);
  }

  static (double, double) _proj(Matrix4 m, double x, double y) {
    final v = projectPoint(m, x, y);
    return (v.x, v.y);
  }

  _Box _screenBox(Matrix4 m, double lw, double lh) =>
      _boxOf([_proj(m, 0, 0), _proj(m, lw, 0), _proj(m, lw, lh), _proj(m, 0, lh)]);

  /// Screen point → layer pixels for matrix [m] (inverse of the plane homography).
  static (double, double) _toLayer(Matrix4 m, double sx, double sy) {
    final a00 = m.entry(0, 0), a01 = m.entry(0, 1), a02 = m.entry(0, 3);
    final a10 = m.entry(1, 0), a11 = m.entry(1, 1), a12 = m.entry(1, 3);
    final a20 = m.entry(3, 0), a21 = m.entry(3, 1), a22 = m.entry(3, 3);
    final c00 = a11 * a22 - a12 * a21, c01 = a02 * a21 - a01 * a22, c02 = a01 * a12 - a02 * a11;
    final c10 = a12 * a20 - a10 * a22, c11 = a00 * a22 - a02 * a20, c12 = a02 * a10 - a00 * a12;
    final c20 = a10 * a21 - a11 * a20, c21 = a01 * a20 - a00 * a21, c22 = a00 * a11 - a01 * a10;
    final x = c00 * sx + c01 * sy + c02, y = c10 * sx + c11 * sy + c12, z = c20 * sx + c21 * sy + c22;
    final zz = z.abs() < 1e-12 ? 1e-12 : z;
    return (x / zz, y / zz);
  }

  /// The region to fly into: a layer of this comp, a layer inside the
  /// outgoing precomp, or point/size params. Returns (box, separate layer in this comp).
  (_Box, Layer?) region(String key, {double defaultShare = 0.3}) {
    final id = params[key] ?? params['target'] ?? params['layer'];
    if (id is String) {
      final l = comp.layerById(id);
      if (l != null) {
        if (l.id == b.id) throw ArgumentError('transition $key cannot be the incoming layer');
        return (_screenBox(_matrixAt(comp, l, t0), l.width, l.height), l.id == a.id ? null : l);
      }
      final p = project;
      final child = p == null ? null : Precomp.childOf(p, a);
      final inner = child?.layerById(id);
      if (child != null && inner != null) {
        final ct = Precomp.childTime(a, child, t0) ?? 0;
        final mi = _matrixAt(child, inner, ct);
        final ma = _matrixAt(comp, a, t0);
        final corners = [
          for (final (x, y) in [(0.0, 0.0), (inner.width, 0.0), (inner.width, inner.height), (0.0, inner.height)]) _proj(mi, x, y),
        ];
        return (_boxOf([for (final (x, y) in corners) _proj(ma, x, y)]), null);
      }
      throw ArgumentError('transition $key: no layer "$id" in this comp${child != null ? ' or in the outgoing precomp' : ''}');
    }
    final pt = vec('point');
    if (pt != null && pt.length >= 2) {
      final s = vec('size');
      final sw = s == null ? w * defaultShare : s[0];
      final sh = s == null ? h * defaultShare : (s.length > 1 ? s[1] : s[0]);
      return (_Box.around(pt[0], pt[1], math.max(8.0, sw), math.max(8.0, sh)), null);
    }
    return (_Box.around(w / 2, h / 2, w * defaultShare, h * defaultShare), null);
  }

  /// Zoom keys about screen point (qx, qy): factor [k] of the rest transform.
  void zoomKey(Layer l, double t, double k, double qx, double qy, List<double> pos, List<double> sc, Easing e) {
    final p = l.parentId == null ? [qx + (pos[0] - qx) * k, qy + (pos[1] - qy) * k, pos[2]] : List.of(pos);
    key(l.prop(Props.position), t, p, e);
    key(l.prop(Props.scale), t, [sc[0] * k, sc[1] * k, sc[2]], e);
  }

  /// Multiplies the scale of [l] after [t] (static value and later keys).
  void scaleAfter(Layer l, double t, double k) {
    if ((k - 1).abs() < 1e-6) return;
    final p = l.prop(Props.scale);
    p.staticValue = [p.staticValue[0] * k, p.staticValue[1] * k, p.staticValue[2]];
    for (final kf in p.keyframes) {
      if (kf.time > t + kTimeEpsilon) kf.value = [kf.value[0] * k, kf.value[1] * k, kf.value[2]];
    }
  }

  /// Rect mask on [l] covering screen box [bx] (seen through matrix [m]).
  Mask boxMask(Layer l, Matrix4 m, _Box bx, {String tag = 'mask', bool invert = false, String shape = 'rect', double feather = 0}) {
    final pts = [
      _toLayer(m, bx.x0, bx.y0),
      _toLayer(m, bx.x1, bx.y0),
      _toLayer(m, bx.x1, bx.y1),
      _toLayer(m, bx.x0, bx.y1),
    ];
    final lb = _boxOf(pts);
    final role = l.id == a.id ? 'trout' : 'trin';
    final id = '${l.id}_${role}_$tag';
    l.masks.removeWhere((x) => x.id == id);
    final mask = Mask(id: id, shape: shape, invert: invert, props: {
      'center': AnimProp([lb.cx, lb.cy]),
      'size': AnimProp([math.max(2.0, lb.w), math.max(2.0, lb.h)]),
      'feather': AnimProp([feather]),
    });
    l.masks.add(mask);
    return mask;
  }

  // ================================================================ types

  // 1. Camera flies through an opening of the outgoing shot; the incoming
  //    shot is seen through it and fills the frame at the cut.
  void pushThrough() {
    incomingOnTop(false);
    final (r, door) = region('target');
    final shape = choice('shape', 'rect', const ['rect', 'ellipse']);
    final share = math.max(r.w / w, r.h / h).clamp(0.02, 1.0);
    final k = (1.4 / share).clamp(2.0, 40.0);
    final qx = r.cx, qy = r.cy;
    final ma = _matrixAt(comp, a, t0);
    // The opening becomes a hole in the outgoing shot (and in a separate door layer).
    final hole = boxMask(a, ma, r, tag: 'hole', invert: true, shape: shape, feather: shape == 'ellipse' ? math.min(r.w, r.h) * 0.08 : 0);
    // V2-lead: the hole only exists during the transition (before t0 it is closed: a 0-size inverted mask hides nothing).
    final holeSize = List<double>.of(hole.props['size']!.staticValue);
    hole.props['size']!.setKeyframe(t0 - fr, [0, 0], easing: Easing.hold);
    hole.props['size']!.setKeyframe(t0, holeSize, easing: Easing.hold);
    zoomKey(a, t0, 1, qx, qy, aPos, aScale, _expoIn);
    zoomKey(a, cut, k, qx, qy, aPos, aScale, _expoIn);
    keys(fx(a, 'blur').params['amount']!..staticValue = [0], [(t0, 0, _expoIn), (cut, 30, _expoIn)]);
    fx(a, 'motion_blur', values: {'amount': [100]});
    _setEnd(a, cut + fr);
    if (door != null) {
      final dPos = door.prop(Props.position).valueAt(t0), dSc = door.prop(Props.scale).valueAt(t0);
      _clear(door.prop(Props.position), t0, t1);
      _clear(door.prop(Props.scale), t0, t1);
      final md = _matrixAt(comp, door, t0);
      final id = '${door.id}_trout_hole';
      door.masks.removeWhere((m) => m.id == id);
      final pts = [_toLayer(md, r.x0, r.y0), _toLayer(md, r.x1, r.y1)];
      door.masks.add(Mask(id: id, shape: shape, invert: true, props: {
        'center': AnimProp([(pts[0].$1 + pts[1].$1) / 2, (pts[0].$2 + pts[1].$2) / 2]),
        'size': AnimProp([(pts[1].$1 - pts[0].$1).abs() * 0.92, (pts[1].$2 - pts[0].$2).abs() * 0.92]),
        'feather': AnimProp([0]),
      }));
      zoomKey(door, t0, 1, qx, qy, dPos, dSc, _expoIn);
      zoomKey(door, cut, k, qx, qy, dPos, dSc, _expoIn);
      if (door.end > cut + fr && door.start < cut) door.duration = cut + fr - door.start;
      if (comp.indexOf(door.id) > comp.indexOf(b.id)) {
        comp.layers.remove(door);
        comp.layers.insert(comp.indexOf(b.id), door);
      }
    }
    // The space beyond the opening: grows from the hole to the full frame.
    final rb = (share * 1.6).clamp(0.35, 0.92);
    zoomKey(b, t0, rb, qx, qy, bPos, bScale, _inOut);
    zoomKey(b, cut, 1, qx, qy, bPos, bScale, _inOut);
    keys(fx(b, 'blur').params['amount']!..staticValue = [0], [(t0, 10, _inOut), (cut, 22, _outCubic), (t1, 0, _outCubic)]);
  }

  // 2. A dark foreground object sweeps across the lens; the incoming shot is
  //    revealed behind its centre line.
  void foregroundWipe() {
    final (dx, dy) = dirVec('left');
    final horizontal = dy == 0;
    final mid = params['media'];
    final share = n('width', 0.55).clamp(0.15, 1.5);
    final Layer obj;
    final p = project;
    final media = mid is String && p != null ? p.media[mid] : null;
    if (mid is String && media == null) throw ArgumentError('foreground_wipe: no media "$mid"');
    if (media != null) {
      obj = overlay('fg', name: 'Foreground wipe', type: LayerType.image, width: media.width, height: media.height);
      obj.mediaId = media.id;
      final s = (horizontal ? h * 1.35 / math.max(1, media.height) : w * 1.35 / math.max(1, media.width)) * 100;
      obj.prop(Props.scale).staticValue = [s, s, 100];
      fx(obj, 'color', values: {'brightness': [-45], 'contrast': [10], 'saturation': [-30]});
    } else {
      final ow = horizontal ? w * share : w * 1.4, oh = horizontal ? h * 1.4 : h * share;
      obj = overlay('fg', name: 'Foreground wipe', type: LayerType.shape, width: ow, height: oh);
      obj.shape = _silhouette(choice('shape', 'pillar', const ['pillar', 'tree', 'person']), ow, oh, horizontal);
      fx(obj, 'blur', values: {'amount': [10]}); // defocused: it is right in front of the lens
    }
    final ext = horizontal ? (obj.width * obj.prop(Props.scale).staticValue[0] / 100) : (obj.height * obj.prop(Props.scale).staticValue[1] / 100);
    final span = (horizontal ? w : h) / 2 + ext / 2 + 4;
    final c0 = (w / 2 - dx * span, h / 2 - dy * span), c1 = (w / 2 + dx * span, h / 2 + dy * span);
    key(obj.prop(Props.position), t0, [c0.$1, c0.$2, 0], _soft);
    key(obj.prop(Props.position), t1, [c1.$1, c1.$2, 0], _soft);
    fx(obj, 'motion_blur', values: {'amount': [100]});
    // Incoming revealed on the trailing side of the object's centre line.
    final mb = _matrixAt(comp, b, t1);
    final big = (horizontal ? w : h) * 3;
    _Box half(double cx, double cy) {
      if (horizontal) return dx < 0 ? _Box(cx, -h, cx + big, h * 2) : _Box(cx - big, -h, cx, h * 2);
      return dy < 0 ? _Box(-w, cy, w * 2, cy + big) : _Box(-w, cy - big, w * 2, cy);
    }

    final m = boxMask(b, mb, half(c0.$1, c0.$2), tag: 'wipe', feather: (horizontal ? w : h) * 0.03);
    final end = boxMask(b, mb, half(c1.$1, c1.$2), tag: 'wipe_end');
    b.masks.remove(end);
    for (final k in ['center', 'size']) {
      final from = m.props[k]!.staticValue, to = end.props[k]!.staticValue;
      key(m.props[k]!, t0, from, _soft);
      key(m.props[k]!, t1, to, _soft);
      key(m.props[k]!, t1 + fr, [for (final v in to) k == 'size' ? v * 4 : v], Easing.hold);
    }
  }

  static ShapeData _silhouette(String kind, double ow, double oh, bool vertical) {
    final rings = <List<double>>[];
    void poly(List<(double, double)> pts) => rings.add([for (final (x, y) in pts) ...[x * ow, y * oh]]);
    switch (kind) {
      case 'tree':
        // Trunk + a lumpy canopy.
        poly([(0.42, 1.0), (0.45, 0.55), (0.55, 0.55), (0.58, 1.0)]);
        final pts = <(double, double)>[];
        for (int i = 0; i < 48; i++) {
          final th = i / 48 * math.pi * 2;
          final r = 0.42 + 0.06 * math.sin(th * 5 + 1.3) + 0.03 * math.sin(th * 11);
          pts.add((0.5 + math.cos(th) * r, 0.36 + math.sin(th) * r * 0.42));
        }
        poly(pts);
      case 'person':
        final head = <(double, double)>[];
        for (int i = 0; i < 32; i++) {
          final th = i / 32 * math.pi * 2;
          head.add((0.5 + math.cos(th) * 0.17, 0.2 + math.sin(th) * 0.09));
        }
        poly(head);
        poly([(0.08, 1.0), (0.12, 0.45), (0.3, 0.32), (0.7, 0.32), (0.88, 0.45), (0.92, 1.0)]);
      default:
        return ShapeData(kind: 'rect', fill: 0xFF0A0B0D, fill2: 0xFF1A1714, corner: math.min(ow, oh) * 0.04);
    }
    return ShapeData(kind: 'path', rings: rings, closed: true, smooth: true, fill: 0xFF07090A, fill2: 0xFF141210);
  }

  // 3. A picture inside the outgoing scene fills the frame and becomes the shot.
  void zoomIntoPhoto() {
    final (r, photo) = region('layer', defaultShare: 0.4);
    final kk = math.max(w / math.max(1, r.w), h / math.max(1, r.h)) * 1.02;
    final k = math.max(1.01, kk);
    // Fixed point so that the photo's centre lands on the frame centre.
    final qx = (r.cx * k - w / 2) / (k - 1), qy = (r.cy * k - h / 2) / (k - 1);
    zoomKey(a, t0, 1, qx, qy, aPos, aScale, _inOut);
    zoomKey(a, t1, k, qx, qy, aPos, aScale, _inOut);
    keys(fx(a, 'blur').params['amount']!..staticValue = [0], [(t0, 0, _inCubic), (t1, 8, _inCubic)]);
    if (photo != null) {
      final pPos = photo.prop(Props.position).valueAt(t0), pSc = photo.prop(Props.scale).valueAt(t0);
      _clear(photo.prop(Props.position), t0, t1);
      _clear(photo.prop(Props.scale), t0, t1);
      zoomKey(photo, t0, 1, qx, qy, pPos, pSc, _inOut);
      zoomKey(photo, t1, k, qx, qy, pPos, pSc, _inOut);
      if (photo.end > t1 && photo.start < t1) photo.duration = t1 - photo.start;
      if (comp.indexOf(photo.id) < comp.indexOf(b.id)) {
        comp.layers.remove(b);
        comp.layers.insert(comp.indexOf(photo.id), b);
      }
    }
    // Incoming locked to the zoom: it matches the photo at t0, rest at t1.
    zoomKey(b, t0, 1 / k, qx, qy, bPos, bScale, _inOut);
    zoomKey(b, t1, 1, qx, qy, bPos, bScale, _inOut);
    final mb = _matrixAt(comp, b, t1);
    final rr = _Box(qx + (r.x0 - qx) * k, qy + (r.y0 - qy) * k, qx + (r.x1 - qx) * k, qy + (r.y1 - qy) * k);
    final m = boxMask(b, mb, rr, tag: 'frame', feather: 2);
    final sz = m.props['size']!;
    final s0 = List.of(sz.staticValue);
    key(sz, t1 - fr, s0, Easing.hold);
    key(sz, t1, [b.width * 4, b.height * 4], Easing.hold);
    keys(b.prop(Props.opacity), [(t0, 0, _inOut), (cut, bOpacity, _inOut)]);
  }

  // 4. Dive from a map / aerial view through clouds into the next shot.
  void mapDrop() {
    final (r, _) = region('target', defaultShare: 0.2);
    const k = 6.0;
    zoomKey(a, t0, 1, r.cx, r.cy, aPos, aScale, _expoIn);
    zoomKey(a, cut, k, r.cx, r.cy, aPos, aScale, _expoIn);
    keys(fx(a, 'blur').params['amount']!..staticValue = [0], [(t0, 0, _expoIn), (cut, 25, _expoIn)]);
    _setEnd(a, cut + fr);
    _setStart(b, cut - fr);
    // Clouds rushing past the lens.
    final clouds = overlay('clouds', name: 'Clouds');
    final pf = fx(clouds, 'particles', values: {'kind': [kParticleKinds.indexOf('clouds').toDouble()], 'amount': [90], 'speed': [4], 'direction': [-90]});
    pf.params['color']!.staticValue = [255, 255, 255];
    keys(clouds.prop(Props.opacity), [(t0, 0, _inCubic), (cut - dur * 0.2, 100, _soft), (cut + dur * 0.2, 100, _outCubic), (t1, 0, _outCubic)]);
    zoomKey(clouds, t0, 1, w / 2, h / 2, [w / 2, h / 2, 0], [100, 100, 100], _inCubic);
    zoomKey(clouds, t1, 2.6, w / 2, h / 2, [w / 2, h / 2, 0], [100, 100, 100], _inCubic);
    final fog = overlay('fog', name: 'Cloud fog', color: 0xFFF4F7FA);
    keys(fog.prop(Props.opacity), [(t0 + dur * 0.25, 0, _inCubic), (cut, 92, _outCubic), (cut + (t1 - cut) * 0.6, 0, _outCubic)]);
    // Landing: the incoming shot keeps moving in and settles.
    final push = n('push', 1.06).clamp(1.0, 1.5);
    zoomKey(b, cut, 1, w / 2, h / 2, bPos, bScale, _expoOut);
    zoomKey(b, t1, push, w / 2, h / 2, bPos, bScale, _expoOut);
    scaleAfter(b, t1, push);
    keys(fx(b, 'blur').params['amount']!..staticValue = [0], [(cut, 20, _expoOut), (t1, 0, _expoOut)]);
  }

  // 5. Shape match: both shots move so the shapes line up at the cut.
  void matchCut() {
    final fp = vec('from_point') ?? [w / 2, h / 2];
    final tp = vec('to_point') ?? fp;
    final fsv = vec('from_size') ?? [h * 0.3];
    final tsv = vec('to_size') ?? fsv;
    final fs = math.max(4.0, fsv.reduce(math.max)), ts = math.max(4.0, tsv.reduce(math.max));
    if (fp.length < 2 || tp.length < 2) throw ArgumentError('match_cut from_point / to_point must be [x, y]');
    // Track of the matched shape: from (fp, fs) → slight push → (tp, ts).
    final track = [(t0, fp[0], fp[1], fs, _inCubic), (cut, fp[0], fp[1], fs * 1.06, _outCubic), (t1, tp[0], tp[1], ts, _outCubic)];
    void follow(Layer l, double ox, double oy, double os, List<double> pos, List<double> sc, {bool fromCut = false}) {
      for (final (t, x, y, s, e) in track) {
        if (fromCut && t < cut - 1e-9) continue;
        final m = s / os;
        final p = l.parentId == null ? [x + (pos[0] - ox) * m, y + (pos[1] - oy) * m, pos[2]] : List.of(pos);
        key(l.prop(Props.position), t, p, e);
        key(l.prop(Props.scale), t, [sc[0] * m, sc[1] * m, sc[2]], e);
      }
    }

    follow(a, fp[0], fp[1], fs, aPos, aScale);
    follow(b, tp[0], tp[1], ts, bPos, bScale, fromCut: true);
    _setStart(b, cut - fr * 2);
    keys(b.prop(Props.opacity), [(cut - fr * 1.5, 0, Easing.easyEase), (cut + fr * 1.5, bOpacity, Easing.easyEase)]);
    keys(fx(b, 'flash').params['amount']!, [(cut - fr * 1.5, 0, _outCubic), (cut, 30, _outCubic), (cut + fr * 5, 0, _outCubic)]);
  }

  // 6. Whip pan: both shots slide as one strip, peak speed on the cut.
  void whipPan() {
    final (dx, dy) = dirVec('left');
    final span = dy == 0 ? w : h;
    final sx = dy == 0 ? 1.16 : 1.0, sy = dy == 0 ? 1.0 : 1.16;
    key(a.prop(Props.position), t0, aPos, _whip);
    key(a.prop(Props.position), t1, [aPos[0] + dx * span, aPos[1] + dy * span, aPos[2]], _whip);
    key(b.prop(Props.position), t0, [bPos[0] - dx * span, bPos[1] - dy * span, bPos[2]], _whip);
    key(b.prop(Props.position), t1, bPos, _whip);
    key(a.prop(Props.scale), t0, aScale, _inCubic);
    key(a.prop(Props.scale), cut, [aScale[0] * sx, aScale[1] * sy, aScale[2]], _inCubic);
    key(b.prop(Props.scale), cut, [bScale[0] * sx, bScale[1] * sy, bScale[2]], _outCubic);
    key(b.prop(Props.scale), t1, bScale, _outCubic);
    for (final l in [a, b]) {
      fx(l, 'motion_blur', values: {'amount': [100]});
    }
    keys(fx(a, 'blur').params['amount']!..staticValue = [0], [(t0, 0, _inCubic), (cut, 16, _inCubic)]);
    keys(fx(b, 'blur').params['amount']!..staticValue = [0], [(cut, 16, _outCubic), (t1, 0, _outCubic)]);
  }

  // 7. Parallax slide: inner layers of shot precomps move by depth.
  void parallaxSlide() {
    final (dx, dy) = dirVec('left');
    final p = project;
    final ca = p == null ? null : Precomp.childOf(p, a);
    final cb = p == null ? null : Precomp.childOf(p, b);
    var inner = 0;
    if (ca != null) inner += _slideInner(a, ca, dx, dy, out: true);
    if (cb != null && cb != ca) inner += _slideInner(b, cb, dx, dy, out: false);
    if (ca == null) {
      key(a.prop(Props.position), t0, aPos, _inOut);
      key(a.prop(Props.position), t1, [aPos[0] + dx * w * (dy == 0 ? 1 : 0), aPos[1] + dy * h, aPos[2]], _inOut);
      fx(a, 'motion_blur', values: {'amount': [60]});
    }
    if (cb == null) {
      key(b.prop(Props.position), t0, [bPos[0] - dx * w * (dy == 0 ? 1 : 0), bPos[1] - dy * h, bPos[2]], _inOut);
      key(b.prop(Props.position), t1, bPos, _inOut);
      fx(b, 'motion_blur', values: {'amount': [60]});
    }
    if (inner == 0) log.add('parallax_slide: no shot precomps (make_3d inside a precomp) — slid the layers as a whole');
  }

  int _slideInner(Layer host, Composition child, double dx, double dy, {required bool out}) {
    final ls = [for (final l in child.layers) if (l.type != LayerType.audio && l.type != LayerType.nullObject && l.parentId == null) l];
    if (ls.isEmpty) return 0;
    double ct(double t) => host.sourceIn + (t - host.start) * host.speed;
    final c0 = ct(t0), c1 = ct(t1);
    final cam = Evaluator.camera3D(child, c0);
    final depth = <Layer, double>{};
    for (final l in ls) {
      final pos = l.prop(Props.position).valueAt(c0);
      depth[l] = l.is3D ? math.max(1.0, cam.depthOf(Vector3(pos[0], pos[1], pos[2]))) : cam.zoom;
    }
    final dmin = depth.values.reduce(math.min), dmax = depth.values.reduce(math.max);
    final spanX = child.width, spanY = child.height;
    for (int i = 0; i < ls.length; i++) {
      final l = ls[i];
      final d = depth[l]!;
      // Nearness 0 (far) .. 1 (near): by depth for 3D, by stacking order for 2D.
      final near = dmax - dmin > 1 ? (dmax - d) / (dmax - dmin) : (ls.length <= 1 ? 0.0 : (ls.length - 1 - i) / (ls.length - 1));
      final f = 1 + 0.7 * near;
      final world = l.is3D ? d / cam.zoom : 1.0;
      final ox = dx * spanX * f * world, oy = dy * spanY * f * world;
      final pp = l.prop(Props.position);
      final rest = pp.valueAt(out ? c0 : c1);
      _clear(pp, c0, c1);
      if (out) {
        key(pp, c0, rest, _inOut);
        key(pp, c1, [rest[0] + ox, rest[1] + oy, rest[2]], _inOut);
      } else {
        key(pp, c0, [rest[0] - ox, rest[1] - oy, rest[2]], _inOut);
        key(pp, c1, rest, _inOut);
      }
      l.effects.removeWhere((e) => e.id == '${l.id}_trpx_mb');
      l.effects.add(EffectsCatalog.create('motion_blur', '${l.id}_trpx_mb')..params['amount']!.staticValue = [70]);
    }
    if (project != null && project!.main.layers.where((x) => x.compId == child.id).length > 1) {
      log.add('parallax_slide: comp "${child.id}" is used more than once — every copy slides');
    }
    return ls.length;
  }

  // 8a. Paper tear: the shot is ripped away, the next one is underneath.
  void paperTear() {
    incomingOnTop(false);
    final (dx, dy) = dirVec('left');
    final side = dy == 0 ? (dx < 0 ? 3 : 2) : (dy < 0 ? 1 : 0); // torn on the trailing side
    final span = (dy == 0 ? w : h) * 1.2;
    final ta = t0 + dur * 0.12;
    keys(fx(a, 'torn_edge', values: {'side': [side.toDouble()]}).params['amount']!, [(t0, 0, _outCubic), (ta, 55, _outCubic)]);
    fx(a, 'shadow', values: {'distance': [24], 'blur': [26], 'opacity': [65]});
    key(a.prop(Props.position), t0, aPos, _outCubic);
    key(a.prop(Props.position), ta, [aPos[0] - dx * 14, aPos[1] - dy * 14, aPos[2]], _inCubic); // anticipation
    key(a.prop(Props.position), t1, [aPos[0] + dx * span, aPos[1] + dy * span, aPos[2]], _inCubic);
    final rz = (dx + dy) < 0 ? -9.0 : 9.0;
    key(a.prop(Props.rotation), ta, aRot, _inCubic);
    key(a.prop(Props.rotation), t1, [aRot[0], aRot[1], aRot[2] + rz], _inCubic);
    fx(a, 'motion_blur', values: {'amount': [70]});
    key(b.prop(Props.scale), t0, [bScale[0] * 1.06, bScale[1] * 1.06, bScale[2]], _outCubic);
    key(b.prop(Props.scale), t1, bScale, _outCubic);
    keys(fx(b, 'color').params['brightness']!, [(t0, -25, _outCubic), (t1, 0, _outCubic)]);
  }

  // 8b. Burning edge with glow and embers eats the outgoing shot.
  void burnEdge() {
    incomingOnTop(false);
    final tone = choice('tone', 'warm', const ['warm', 'cold', 'neutral']);
    final e = fx(a, 'burn_edge', values: {
      'cx': [n('cx', 50)],
      'cy': [n('cy', 50)],
      'color': toneRgb(tone, warm: const [255, 140, 40], cold: const [110, 190, 255], neutral: const [255, 200, 120]),
    });
    keys(e.params['progress']!, [(t0, 0, const Easing.bezierCurve(0.4, 0, 0.6, 1)), (t1, 100, _outCubic)]);
    keys(fx(b, 'color').params['brightness']!, [(t0, -20, _outCubic), (t1, 0, _outCubic)]);
  }

  // 8c. Page curl (drawn by the page_curl effect).
  void pageTurn() {
    incomingOnTop(false);
    final e = fx(a, 'page_curl', values: {'angle': [n('angle', 200)]});
    keys(e.params['progress']!, [(t0, 0, _inOut), (t1, 100, _inOut)]);
    keys(fx(b, 'color').params['brightness']!, [(t0, -30, _outCubic), (t1, 0, _outCubic)]);
  }

  // 9. Focus pull: defocus out, sharpen in, with a brightness breathe.
  void focusPull() {
    final tb = cut - dur * 0.2, te = cut + dur * 0.15;
    keys(fx(a, 'blur').params['amount']!..staticValue = [0], [(t0, 0, _inCubic), (cut, 45, _inCubic)]);
    keys(fx(a, 'color').params['brightness']!, [(t0, 0, _inOut), (cut, 12, _inOut)]);
    key(a.prop(Props.scale), t0, aScale, _inOut);
    key(a.prop(Props.scale), cut, [aScale[0] * 1.03, aScale[1] * 1.03, aScale[2]], _inOut);
    keys(b.prop(Props.opacity), [(tb, 0, _inOut), (te, bOpacity, _inOut)]);
    keys(fx(b, 'blur').params['amount']!..staticValue = [0], [(tb, 45, _outCubic), (t1, 0, _outCubic)]);
    keys(fx(b, 'color').params['brightness']!, [(tb, 12, _inOut), (t1, 0, _inOut)]);
    key(b.prop(Props.scale), tb, [bScale[0] * 1.03, bScale[1] * 1.03, bScale[2]], _inOut);
    key(b.prop(Props.scale), t1, bScale, _inOut);
  }

  // 10. Vertigo on the outgoing shot, then a hard cut.
  void dollyZoom() {
    hardCut();
    final p = project;
    final child = p == null ? null : Precomp.childOf(p, a);
    if (child != null && child.camera.mode == CameraMode.threeD) {
      final c0 = a.sourceIn + (t0 - a.start) * a.speed;
      CameraPresets.apply(child, 'dolly_zoom', start: c0, duration: (cut - t0) * a.speed, ease: _inOut);
      log.add('dolly_zoom: real 3D dolly zoom inside "${child.id}"');
    } else {
      key(a.prop(Props.scale), t0, aScale, _inOut);
      key(a.prop(Props.scale), cut, [aScale[0] * 1.16, aScale[1] * 1.16, aScale[2]], _inOut);
    }
    keys(fx(a, 'curve').params['bend']!..staticValue = [0], [(t0, 0, _inOut), (cut, -38, _inOut)]);
    keys(fx(a, 'vignette', values: {'size': [55]}).params['amount']!, [(t0, 0, _inOut), (cut, 50, _inOut)]);
    keys(fx(b, 'flash').params['amount']!, [(cut, 35, _expoOut), (t1, 0, _expoOut)]);
    key(b.prop(Props.scale), cut, [bScale[0] * 1.04, bScale[1] * 1.04, bScale[2]], _expoOut);
    key(b.prop(Props.scale), t1, bScale, _expoOut);
  }

  // 11a. Film burn: a hot orange burn blooms over the cut.
  void filmBurn() {
    final tone = choice('tone', 'warm', const ['warm', 'cold', 'neutral']);
    final col = switch (tone) { 'cold' => 0xFF6FA8FF, 'neutral' => 0xFFFFE6C2, _ => 0xFFFF7A1A };
    final burn = overlay('burn', name: 'Film burn', color: col);
    final rv = fx(burn, 'reveal', values: {'kind': [2], 'softness': [70], 'cx': [62], 'cy': [40]});
    keys(rv.params['progress']!, [(t0, 0, _inCubic), (cut, 100, _inCubic)]);
    fx(burn, 'light_leak', values: {'amount': [85], 'speed': [3]});
    keys(fx(burn, 'flash', values: {'color': [255, 244, 220]}).params['amount']!, [(t0, 0, _inCubic), (cut, 75, _outCubic), (t1, 0, _outCubic)]);
    keys(burn.prop(Props.opacity), [(cut, 100, _outCubic), (t1, 0, _outCubic)]);
    hardCut();
    final warm = toneRgb(tone, warm: const [255, 210, 150], cold: const [190, 215, 255], neutral: const [255, 245, 230]);
    keys(fx(a, 'flash', values: {'color': warm}).params['amount']!, [(t0, 0, _inCubic), (cut, 60, _inCubic)]);
    keys(fx(b, 'flash', values: {'color': warm}).params['amount']!, [(cut, 60, _outCubic), (t1, 0, _outCubic)]);
  }

  // 11b. A soft light leak sweeps across; the cut dissolves under its brightest part.
  void lightLeakWipe() {
    final tone = choice('tone', 'warm', const ['warm', 'cold', 'neutral']);
    final rgb = switch (tone) { 'cold' => 0x7FB8FF, 'neutral' => 0xFFF1DC, _ => 0xFF8A1F };
    final leak = overlay('leak', name: 'Light leak', type: LayerType.shape, width: w * 0.75, height: h * 1.6);
    leak.shape = ShapeData(kind: 'rect', fill: 0xDD000000 | rgb, fill2: 0x00000000 | rgb);
    leak.prop(Props.rotation).staticValue = [0, 0, 14];
    fx(leak, 'blur', values: {'amount': [80]});
    key(leak.prop(Props.position), t0, [-w * 0.45, h / 2, 0], _soft);
    key(leak.prop(Props.position), t1, [w * 1.45, h / 2, 0], _soft);
    final wash = overlay('wash', name: 'Light wash', color: 0xFF000000 | rgb);
    keys(wash.prop(Props.opacity), [(t0, 0, _inOut), (cut, 45, _inOut), (t1, 0, _inOut)]);
    keys(b.prop(Props.opacity), [(cut - dur * 0.15, 0, _inOut), (cut + dur * 0.15, bOpacity, _inOut)]);
    final c = toneRgb(tone, warm: const [255, 200, 140], cold: const [200, 225, 255], neutral: const [255, 250, 240]);
    keys(fx(a, 'flash', values: {'color': c}).params['amount']!, [(t0, 0, _inOut), (cut, 35, _inOut)]);
    keys(fx(b, 'flash', values: {'color': c}).params['amount']!, [(cut, 35, _inOut), (t1, 0, _inOut)]);
  }

  // 11c. Ink bleed reveal.
  void inkBleed() {
    final rv = fx(b, 'reveal', values: {'kind': [1], 'softness': [35], 'cx': [n('cx', 50)], 'cy': [n('cy', 50)]});
    keys(rv.params['progress']!, [(t0, 0, _soft), (t1, 100, _soft)]);
    keys(fx(a, 'color').params['brightness']!, [(t0, 0, _inOut), (t1, -22, _inOut)]);
    final tone = choice('tone', 'neutral', const ['warm', 'cold', 'neutral']);
    if (tone != 'neutral') {
      final c = tone == 'warm' ? const [140.0, 90.0, 40.0] : const [50.0, 75.0, 110.0];
      keys(fx(b, 'tint', values: {'color': c}).params['amount']!, [(t0, 45, _inOut), (t1, 0, _inOut)]);
    }
    key(b.prop(Props.scale), t0, [bScale[0] * 1.05, bScale[1] * 1.05, bScale[2]], _outCubic);
    key(b.prop(Props.scale), t1, bScale, _outCubic);
    this.v3InkDuo(); // V3-D: incoming "duotone_of_outgoing"
  }

  // 11d. Smoke reveal with drifting smoke over the cut.
  void smokeReveal() {
    final rv = fx(b, 'reveal', values: {'kind': [2], 'softness': [45]});
    keys(rv.params['progress']!, [(t0, 0, _soft), (t1, 100, _soft)]);
    final tone = choice('tone', 'neutral', const ['warm', 'cold', 'neutral']);
    final smoke = overlay('smoke', name: 'Smoke');
    final pf = fx(smoke, 'particles', values: {'kind': [kParticleKinds.indexOf('smoke').toDouble()], 'amount': [80], 'speed': [0.8], 'direction': [-80]});
    pf.params['color']!.staticValue = toneRgb(tone, warm: const [255, 225, 195], cold: const [205, 220, 240], neutral: const [232, 232, 232]);
    keys(smoke.prop(Props.opacity), [(t0, 0, _inOut), (cut, 85, _inOut), (t1, 0, _inOut)]);
    keys(fx(a, 'blur').params['amount']!..staticValue = [0], [(t0, 0, _inOut), (t1, 12, _inOut)]);
  }

  // 12. B&W → colour: the incoming starts as an old photo, colour blooms radially.
  void bwToColour() {
    final bloom0 = cut + (t1 - cut) * 0.25;
    // Colour copy of the incoming shot, revealed with a soft iris.
    final copy = b.copy(newId: 'tr_${b.id}_colour')..name = '${b.name} (colour)';
    copy.effects.removeWhere((e) => e.id.contains('_trin_') || e.id.contains('_trout_'));
    copy.masks.removeWhere((m) => m.id.contains('_trin_') || m.id.contains('_trout_'));
    copy.sourceIn = b.sourceTimeAt(bloom0);
    copy.start = bloom0;
    copy.duration = math.max(fr, t1 - bloom0);
    final iris = EffectsCatalog.create('reveal', '${copy.id}_trin_iris');
    iris.params['softness']!.staticValue = [75];
    iris.params['cx']!.staticValue = [n('cx', 50)];
    iris.params['cy']!.staticValue = [n('cy', 50)];
    keys(iris.params['progress']!, [(bloom0, 0, _inOut), (t1, 100, _inOut)]);
    copy.effects.add(iris);
    comp.layers.insert(comp.indexOf(b.id), copy);
    created.add(copy.id);
    // The incoming itself: old photo look until the bloom has finished.
    _setStart(b, cut - fr * 2);
    _setEnd(a, cut + fr * 2);
    keys(b.prop(Props.opacity), [(cut - fr * 2, 0, Easing.easyEase), (cut + fr * 2, bOpacity, Easing.easyEase)]);
    void old(String type, String param, double v, {Map<String, List<double>> values = const {}}) {
      keys(fx(b, type, values: values).params[param]!, [(cut, v, Easing.hold), (t1, 0, Easing.hold)]);
    }

    old('mono', 'amount', 100);
    old('tint', 'amount', 38, values: {'color': [205, 165, 115]});
    old('grain', 'amount', 42);
    old('vignette', 'amount', 68);
    keys(fx(b, 'flash').params['amount']!, [(cut, 55, _expoOut), (cut + fr * 8, 0, _expoOut)]);
  }

  // 13a. Glitch cut: stepped RGB-split bursts around a hard cut.
  void glitchCut() {
    hardCut();
    void bursts(Layer l, double from, double to, bool rising, List<double> pos) {
      final g = fx(l, 'glitch').params['amount']!;
      final pp = l.prop(Props.position);
      const steps = 7;
      for (int i = 0; i <= steps; i++) {
        final k = i / steps;
        final t = from + (to - from) * k;
        final strength = rising ? 0.35 + 0.65 * k : 1 - k;
        final on = i.isEven || (rising ? i == steps : i == 0);
        final v = (rising ? i == 0 : i == steps) ? 0.0 : (on ? 100.0 * strength : 15.0 * strength);
        g.setKeyframe(t, [v], easing: Easing.hold);
        final j = (i.isEven ? 1.0 : -1.0) * w * 0.012 * strength * ((i * 7919) % 3 - 1);
        final end = rising ? i == 0 : i == steps;
        pp.setKeyframe(t, end ? pos : [pos[0] + j, pos[1], pos[2]], easing: Easing.hold);
      }
    }

    bursts(a, cut - (cut - t0) * 0.8, cut, true, aPos);
    bursts(b, cut, cut + (t1 - cut) * 0.8, false, bPos);
    keys(fx(b, 'flash').params['amount']!, [(cut, 40, _expoOut), (cut + fr * 3, 0, _expoOut)]);
  }

  // 13b. Flash cut.
  void flashCut() {
    hardCut();
    final tone = str('tone', '');
    final col = params['color'] is String
        ? _rgb('${params['color']}')
        : tone == 'warm'
            ? <double>[255, 236, 210]
            : tone == 'cold'
                ? <double>[215, 232, 255]
                : <double>[255, 255, 255];
    keys(fx(a, 'flash', values: {'color': col}).params['amount']!, [(t0, 0, _expoIn), (cut, 100, _expoIn)]);
    keys(fx(b, 'flash', values: {'color': col}).params['amount']!, [(cut, 100, _expoOut), (t1, 0, _expoOut)]);
    key(b.prop(Props.scale), cut, [bScale[0] * 1.05, bScale[1] * 1.05, bScale[2]], _expoOut);
    key(b.prop(Props.scale), t1, bScale, _expoOut);
  }

  // 13c. Dip to black (or any colour).
  void dipToBlack() {
    hardCut();
    final col = params['color'] is String ? _argb('${params['color']}') : 0xFF000000;
    final dip = overlay('dip', name: 'Dip', color: col);
    keys(dip.prop(Props.opacity), [(t0, 0, _inCubic), (cut - fr, 100, _inCubic), (cut + fr, 100, _outCubic), (t1, 0, _outCubic)]);
  }

  static int _argb(String s) {
    var v = s.trim().replaceFirst('#', '').replaceFirst('0x', '');
    if (v.length == 6) v = 'FF$v';
    final n = int.tryParse(v, radix: 16);
    if (n == null || v.length != 8) throw ArgumentError('Bad color "$s" (use "#RRGGBB")');
    return n;
  }

  static List<double> _rgb(String s) {
    final n = _argb(s);
    return [((n >> 16) & 0xFF).toDouble(), ((n >> 8) & 0xFF).toDouble(), (n & 0xFF).toDouble()];
  }
}
