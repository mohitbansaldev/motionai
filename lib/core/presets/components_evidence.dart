part of 'components.dart';

// V3-B >>> Evidence kit: articles, books, cards, notes (refpack PATTERN_LIBRARY_SPEC,
// P-B patterns 11–20 and 55–60). Everything is built from ordinary edit commands
// (one add_component = one undo step); paper, newsprint, grunge, splatters,
// stains and torn edges are drawn procedurally here (no bitmaps, no real covers).

const _evTypes = [
  'circle_mark', 'inset_circle', 'book', 'note_card', 'list_card', 'handwrite_card', 'quote_hole',
  'source_tag', 'photo_wall', 'stain', 'doodle', 'object_reveal',
];

const _evLabels = {
  'circle_mark': 'Circle Mark',
  'inset_circle': 'Inset Circle',
  'book': 'Book Reveal',
  'note_card': 'Note Card',
  'list_card': 'List Card',
  'handwrite_card': 'Handwritten Note',
  'quote_hole': 'Quote Card (Torn Hole)',
  'source_tag': 'Source Tag',
  'photo_wall': 'Photo Wall',
  'stain': 'Ink Stain',
  'doodle': 'Doodle',
  'object_reveal': 'Object Reveal',
};

/// V3 components, and the V3 variants of article / photo_card / character_label /
/// arrow_callout (only when V3 keys are used: older commands build exactly as before).
List<Map<String, dynamic>>? _evBuild(Project p, Map<String, dynamic> c, _B b) {
  switch ('${c['type']}') {
    case 'circle_mark':
      return _evCircleMark(b, p);
    case 'inset_circle':
      return _evInsetCircle(b, p);
    case 'book':
      return _evBook(b, p);
    case 'note_card':
      return _evNoteCard(b);
    case 'list_card':
      return _evListCard(b, p);
    case 'handwrite_card':
      return _evHandwriteCard(b, p);
    case 'quote_hole':
      return _evQuoteHole(b, p);
    case 'source_tag':
      return _evSourceTag(b, p);
    case 'photo_wall':
      return _evPhotoWall(b, p);
    case 'stain':
      return _evStain(b);
    case 'doodle':
      return _evDoodle(b);
    case 'object_reveal':
      return _evObjectReveal(b, p);
    case 'article':
      return _evArticleWanted(c) ? _evArticle(b, p) : null;
    case 'photo_card':
      return _evPhotoWanted(c) ? _evPhotoCard(b, p) : null;
    case 'character_label':
      return (c['style'] == 'plain' || c['style'] == 'print') ? _evPlainLabel(b, p) : null;
    case 'arrow_callout':
      return (c['circle'] == false || c['role'] != null || c['name'] != null) ? _evArrowLabel(b) : null;
  }
  return null;
}

// ------------------------------------------------------------------ helpers

/// Expo-out: fast start, long soft landing (slides, punch-ins, settles).
const Map<String, dynamic> _evExpoOut = {'type': 'bezier', 'x1': 0.16, 'y1': 1.0, 'x2': 0.3, 'y2': 1.0};

/// Expo-in: slow start, fast exit (slide-outs, drops).
const Map<String, dynamic> _evExpoIn = {'type': 'bezier', 'x1': 0.7, 'y1': 0.0, 'x2': 0.84, 'y2': 0.0};

/// Back-out with ≈ 6 % overshoot (book rise, pops).
const Map<String, dynamic> _evBack = {'type': 'bezier', 'x1': 0.3, 'y1': 1.45, 'x2': 0.6, 'y2': 1.0};

/// Pen stroke: accelerates in, lands softly.
const Map<String, dynamic> _evPen = {'type': 'bezier', 'x1': 0.45, 'y1': 0.0, 'x2': 0.2, 'y2': 1.0};

/// Long glide ease-out (note card glide, camera drifts).
const Map<String, dynamic> _evGlide = {'type': 'bezier', 'x1': 0.22, 'y1': 1.0, 'x2': 0.36, 'y2': 1.0};

/// Smooth in-out (camera moves between photos, zoom to a page).
const Map<String, dynamic> _evInOut = {'type': 'bezier', 'x1': 0.65, 'y1': 0.0, 'x2': 0.35, 'y2': 1.0};

/// Very steep in-out (whips).
const Map<String, dynamic> _evWhip = {'type': 'bezier', 'x1': 0.8, 'y1': 0.0, 'x2': 0.2, 'y2': 1.0};

Map<String, dynamic> _evKf(String id, String prop, double t, dynamic v, [dynamic ease = 'easy_ease']) =>
    {'op': 'set_keyframe', 'target': id, 'prop': prop, 'time': t, 'value': v, 'ease': ease};

Map<String, dynamic> _evMaskKf(String id, String mask, String prop, double t, dynamic v, [dynamic ease = 'easy_ease']) =>
    {'op': 'set_keyframe', 'target': id, 'mask': mask, 'prop': prop, 'time': t, 'value': v, 'ease': ease};

/// Stable seed from a string (ids), so a rebuild draws the same paper.
int _evSeed(String s) {
  var h = 7;
  for (final u in s.codeUnits) {
    h = (h * 31 + u) & 0x7FFFFFFF;
  }
  return h;
}

/// [b] with a default duration (when the command gave none).
_B _evWithDur(_B b, double d) =>
    b.c['duration'] is num ? b : _B(b.w, b.h, {...b.c, 'duration': math.max(0.2, d)}, b.now, b.root);

/// A size given as a fraction (≤ [limit]) of [ref] or in pixels.
double _evSize(_B b, String k, double def, double ref, {double limit = 2}) {
  final v = b.c[k];
  if (v is! num) return def * ref;
  return v <= limit ? v.toDouble() * ref : v.toDouble();
}

/// "#RRGGBB" from a colour that may carry an alpha ("#AARRGGBB").
String _evOpaque(String c) {
  final s = c.replaceFirst('#', '');
  return s.length == 8 ? '#${s.substring(2)}' : c;
}

/// Translucent highlighter colour unless the colour already has an alpha.
String _evInk(String c, int a) => c.replaceFirst('#', '').length == 8 ? c : _alpha(c, a);

/// Ellipse arc points (screen space: clockwise, -90° = 12 o'clock) with a hand
/// wobble and an optional radius growth over the sweep (overlapping pen ends).
List<List<double>> _evArc(double cx, double cy, double rx, double ry,
    {double from = -90, double sweep = 360, int steps = 40, double wobble = 0, double grow = 0, int seed = 0}) {
  final rnd = math.Random(seed);
  final p1 = rnd.nextDouble() * 2 * math.pi, p2 = rnd.nextDouble() * 2 * math.pi;
  final out = <List<double>>[];
  for (int i = 0; i <= steps; i++) {
    final u = i / steps;
    final a = (from + sweep * u) * math.pi / 180;
    final k = 1 + grow * u + wobble * (0.6 * math.sin(2 * a + p1) + 0.4 * math.sin(5 * a + p2));
    out.add([cx + math.cos(a) * rx * k, cy + math.sin(a) * ry * k]);
  }
  return out;
}

/// Organic blob outline (stains, splatters).
List<List<double>> _evBlob(double cx, double cy, double rx, double ry, {int n = 56, double rough = 0.5, int seed = 0}) {
  final rnd = math.Random(seed);
  final ph = [for (int i = 0; i < 4; i++) rnd.nextDouble() * 2 * math.pi];
  final out = <List<double>>[];
  for (int i = 0; i < n; i++) {
    final a = i / n * 2 * math.pi;
    final k = 1 +
        rough *
            (0.2 * math.sin(3 * a + ph[0]) + 0.13 * math.sin(5 * a + ph[1]) + 0.08 * math.sin(9 * a + ph[2]) +
                0.07 * (rnd.nextDouble() * 2 - 1));
    out.add([cx + math.cos(a) * rx * k, cy + math.sin(a) * ry * k]);
  }
  return out;
}

/// Rectangle outline with a torn / ragged edge (centred on cx, cy).
List<List<double>> _evRagged(double cx, double cy, double w, double h, {double jag = 6, double step = 12, int seed = 0}) {
  final rnd = math.Random(seed);
  final out = <List<double>>[];
  final ph = rnd.nextDouble() * 6.28;
  void edge(double x0, double y0, double x1, double y1, double nx, double ny) {
    final len = math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
    final n = math.max(2, (len / math.max(2, step)).round());
    for (int i = 0; i < n; i++) {
      final u = i / n;
      final j = jag * (0.55 * math.sin(u * len / (step * 3.1) + ph) + 0.45 * (rnd.nextDouble() * 2 - 1));
      out.add([x0 + (x1 - x0) * u + nx * j, y0 + (y1 - y0) * u + ny * j]);
    }
  }

  final l = cx - w / 2, r = cx + w / 2, t = cy - h / 2, bo = cy + h / 2;
  edge(l, t, r, t, 0, -1);
  edge(r, t, r, bo, 1, 0);
  edge(r, bo, l, bo, 0, 1);
  edge(l, bo, l, t, -1, 0);
  return out;
}

/// Rotates points about (cx, cy) by [deg].
List<List<double>> _evRot(List<List<double>> pts, double cx, double cy, double deg) {
  final a = deg * math.pi / 180, c = math.cos(a), s = math.sin(a);
  return [for (final p in pts) [cx + (p[0] - cx) * c - (p[1] - cy) * s, cy + (p[0] - cx) * s + (p[1] - cy) * c]];
}

List<double> _evFlat(List<List<double>> pts) => [for (final p in pts) ...p];

/// Closed filled polygon layer.
Map<String, dynamic> _evPoly(_B b, String part, List<List<double>> pts, String fill,
        {String? parent, double? st, double? du, bool smooth = false}) =>
    {...b.path(part, pts, stroke: 'none', width: 0, fill: fill, closed: true, smooth: smooth, parent: parent, st: st, du: du)};

/// Layer made of several sub-paths ([rings] = flat [x0, y0, x1, y1, ...] lists).
Map<String, dynamic> _evRings(_B b, String part, List<List<double>> rings,
        {String stroke = 'none', double width = 0, String fill = 'none', bool closed = false, String? parent, double? st, double? du, String? name}) =>
    {
      ...b.path(part, const [[0, 0], [1, 0]], stroke: stroke, width: width, fill: fill, closed: closed, parent: parent, st: st, du: du),
      'points': null,
      'rings': rings,
      'name': ?name,
    };

/// Left→right wipe-on reveal: a rect mask (layer pixels) growing from x0 to x1.
List<Map<String, dynamic>> _evWipe(String layer, double x0, double y0, double x1, double y1, double t, double d,
    {double feather = 0, dynamic ease = 'ease_out', String? id}) {
  final m = id ?? '${layer}_wipe';
  final cy = (y0 + y1) / 2, h = math.max(1.0, y1 - y0), w = math.max(1.0, x1 - x0);
  return [
    {'op': 'add_mask', 'layer': layer, 'id': m, 'shape': 'rect', 'center': [x0 + 0.5, cy], 'size': [1, h], 'feather': feather},
    _evMaskKf(layer, m, 'center', t, [x0 + 0.5, cy], ease),
    _evMaskKf(layer, m, 'center', t + d, [x0 + w / 2, cy]),
    _evMaskKf(layer, m, 'size', t, [1, h], ease),
    _evMaskKf(layer, m, 'size', t + d, [w, h]),
  ];
}

/// Adds `parent` to every add_layer command that has none (backdrop null).
List<Map<String, dynamic>> _evParented(List<Map<String, dynamic>> cmds, String parent) => [
      for (final c in cmds) (c['op'] == 'add_layer' && c['parent'] == null) ? {...c, 'parent': parent} : c,
    ];

/// [_B.finish] that ignores enter/exit names that are not animate_in/out presets
/// (component-specific moves such as "drop", "rise", "grow_from_point").
List<Map<String, dynamic>> _evFinish(_B b, List<Map<String, dynamic>> cmds, {String? enter, String? exit}) {
  bool std(dynamic v) =>
      v is String && (MotionPresets.transitions.contains(v) || v == 'none' || v == 'fade_children' || v == 'zoom_out_children');
  final c2 = Map<String, dynamic>.from(b.c);
  if (!std(c2['enter'])) c2.remove('enter');
  if (!std(c2['exit'])) c2.remove('exit');
  return _B(b.w, b.h, c2, b.now, b.root).finish(cmds, enter: enter, exit: exit);
}

/// Optional synthesised sound (`sfx: true` on the component).
Map<String, dynamic>? _evSfx(_B b, String kind, double t) =>
    b.c['sfx'] == true ? {'op': 'add_sfx', 'kind': kind, 'time': math.max(0.0, t)} : null;

/// Time of a spoken word/phrase from caption word timings (text layers with
/// `words`), first one in [from, to]; null when there are no captions.
double? _evWordTime(Project p, String phrase, double from, double to) {
  String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}\p{M}]+', unicode: true), '');
  final want = [for (final w in phrase.split(RegExp(r'\s+'))) if (norm(w).isNotEmpty) norm(w)];
  if (want.isEmpty) return null;
  double? best;
  for (final comp in {p.editComp, p.main}) {
    for (final l in comp.layers) {
      final ws = l.text?.words ?? const <WordTiming>[];
      for (int i = 0; i + want.length <= ws.length; i++) {
        final t = ws[i].start;
        if (t < from - 0.05 || t > to || (best != null && t >= best)) continue;
        var ok = true;
        for (int k = 0; k < want.length && ok; k++) {
          ok = norm(ws[i + k].word) == want[k];
        }
        if (ok) best = t;
      }
    }
    if (best != null) break;
  }
  return best;
}

/// Screen box [x0, y0, x1, y1] of a layer (2D projection of its corners).
List<double>? _evScreenBox(Composition comp, String id, double t) {
  final l = comp.layerById(id);
  if (l == null) return null;
  final m = Evaluator.worldMatrix(comp, l, t);
  final pts = [projectPoint(m, 0, 0), projectPoint(m, l.width, 0), projectPoint(m, l.width, l.height), projectPoint(m, 0, l.height)];
  return [
    pts.map((v) => v.x).reduce(math.min),
    pts.map((v) => v.y).reduce(math.min),
    pts.map((v) => v.x).reduce(math.max),
    pts.map((v) => v.y).reduce(math.max),
  ];
}

// ---------------------------------------------------------------- backdrops

/// Full-frame backdrops: grunge_red, grunge_navy, paper_grey, clean, newsprint_wall,
/// newspaper_collage, or a "#RRGGBB" colour. Returns [] for none/unknown. Part "bd"
/// (the Director adds its own "<id>_bg" under some components).
List<Map<String, dynamic>> _evBackdrop(_B b, String kind, {String part = 'bd'}) {
  if (kind == 'newsprint_wall') return _evNewsprintWall(b, part);
  if (kind == 'newspaper_collage') return _evCollage(b, part);
  final spec = switch (kind) {
    'grunge_red' => ('#8B0E14', '#3A0407', 'grunge', 75.0, 70.0),
    'grunge_navy' => ('#1B2A4A', '#070C18', 'grunge', 75.0, 70.0),
    'paper_grey' => ('#C9C6BF', '#9A968D', 'paper', 75.0, 55.0),
    'clean' => ('#F3F2EE', '#D9D8D3', 'paper', 20.0, 30.0),
    _ => null,
  };
  final id = b.id(part);
  if (spec == null) {
    if (!kind.startsWith('#')) return const [];
    return [b.backdrop(part, kind, color2: _shade(kind, 0.55)), b.fx(id, 'vignette', {'amount': 60})];
  }
  final (c1, c2, tex, texAmount, vig) = spec;
  final cmds = <Map<String, dynamic>>[
    b.backdrop(part, c1, color2: c2),
    b.fx(id, tex, {'amount': texAmount}),
    if (tex == 'grunge') b.fx(id, 'paper', {'amount': 25}),
    b.fx(id, 'vignette', {'amount': vig}),
  ];
  if (kind == 'paper_grey') {
    // Crumpled paper: soft light / dark crease lines.
    final rnd = math.Random(_evSeed(id));
    final light = <List<double>>[], dark = <List<double>>[];
    for (int i = 0; i < 16; i++) {
      var x = rnd.nextDouble() * b.w, y = rnd.nextDouble() * b.h;
      final a = rnd.nextDouble() * math.pi;
      final pts = <List<double>>[];
      for (int k = 0; k < 4; k++) {
        pts.add([x, y]);
        final len = b.w * (0.06 + rnd.nextDouble() * 0.12);
        final aa = a + (rnd.nextDouble() - 0.5) * 0.9;
        x += math.cos(aa) * len;
        y += math.sin(aa) * len;
      }
      light.add(_evFlat(pts));
      dark.add(_evFlat([for (final q in pts) [q[0] + 2.5, q[1] + 2.5]]));
    }
    cmds.add(_evRings(b, '${part}_crease_d', dark, stroke: '#26000000', width: b.h * 0.003, st: b.start, du: b.dur, parent: null, name: 'Creases')..remove('parent'));
    cmds.add(_evRings(b, '${part}_crease_l', light, stroke: '#38FFFFFF', width: b.h * 0.0025, st: b.start, du: b.dur, name: 'Creases')..remove('parent'));
    cmds.add(b.fx(b.id('${part}_crease_d'), 'blur', {'amount': 4}));
    cmds.add(b.fx(b.id('${part}_crease_l'), 'blur', {'amount': 3}));
  }
  return cmds;
}

/// Grey newsprint wall turned 25° about Y (perspective computed here, flat layers).
List<Map<String, dynamic>> _evNewsprintWall(_B b, String part) {
  final w = b.w, h = b.h, cx = w / 2, cy = h / 2;
  final th = b.n('wall_angle', 25) * math.pi / 180;
  final f = w * 1.2;
  List<double> pr(double x, double y) {
    final z = x * math.sin(th);
    final k = f / math.max(f * 0.25, f + z);
    return [cx + x * math.cos(th) * k, cy + y * k];
  }

  double kAt(double x) => f / math.max(f * 0.25, f + x * math.sin(th));
  final rnd = math.Random(_evSeed(b.id(part)));
  // The wall covers the frame; only what is on screen (+ a margin) is kept so
  // the layers (and their blur) stay about frame-sized.
  final mx = w * 0.12, my = h * 0.12;
  List<double>? seg(List<double> a, List<double> c) => _evClipSeg(a[0], a[1], c[0], c[1], -mx, -my, w + mx, h + my);
  bool onScreen(List<List<double>> q) => q.every((v) => v[0] > -mx && v[0] < w + mx && v[1] > -my && v[1] < h + my);
  final cmds = <Map<String, dynamic>>[b.backdrop('${part}_wall', '#D3CFC5', color2: '#B9B4A9')];
  final x0 = -1.7 * w, x1 = 1.7 * w, y0 = -1.15 * h, y1 = 1.15 * h;
  final wall = b.id('${part}_wall');
  cmds.add(b.fx(wall, 'paper', {'amount': 60}));
  cmds.add(b.fx(wall, 'grunge', {'amount': 18}));
  // Columns of body lines, a few headlines and photo blocks; three depth bands
  // so the stroke width follows the perspective.
  final colW = w * 0.3, gut = w * 0.035, lineGap = h * 0.03;
  final bands = [<List<double>>[], <List<double>>[], <List<double>>[]];
  final bandX = <double>[0, 0, 0];
  final heads = <List<double>>[], photos = <List<double>>[];
  for (var cx0 = x0 + gut; cx0 + colW < x1; cx0 += colW + gut) {
    final band = ((cx0 - x0) / (x1 - x0) * 3).floor().clamp(0, 2);
    bandX[band] = cx0;
    var y = y0 + h * 0.06;
    while (y < y1 - h * 0.05) {
      final r = rnd.nextDouble();
      if (r < 0.06) {
        // headline: two thick lines
        for (int k = 0; k < 2; k++) {
          final hx1 = cx0 + colW * (k == 0 ? 0.95 : 0.4 + rnd.nextDouble() * 0.4);
          final sgm = seg(pr(cx0, y), pr(hx1, y));
          if (sgm != null) heads.add(sgm);
          y += lineGap * 1.8;
        }
        y += lineGap * 0.6;
      } else if (r < 0.1) {
        final ph = h * (0.18 + rnd.nextDouble() * 0.16);
        final quad = [pr(cx0, y), pr(cx0 + colW, y), pr(cx0 + colW, y + ph), pr(cx0, y + ph)];
        if (onScreen(quad)) photos.add(_evFlat(quad));
        y += ph + lineGap * 1.2;
      } else {
        final paraEnd = rnd.nextDouble() < 0.14;
        final lx1 = cx0 + colW * (paraEnd ? 0.35 + rnd.nextDouble() * 0.5 : 1.0);
        final sgm = seg(pr(cx0, y), pr(lx1, y));
        if (sgm != null) bands[band].add(sgm);
        y += lineGap * (paraEnd ? 1.6 : 1.0);
      }
    }
  }
  if (photos.isNotEmpty) {
    cmds.add({..._evRings(b, '${part}_photos', photos, fill: '#8C887F', closed: true, st: b.start, du: b.dur, name: 'Newsprint photos')}..remove('parent'));
    cmds.add(b.fx(b.id('${part}_photos'), 'grain', {'amount': 30, 'size': 2}));
  }
  for (int i = 0; i < 3; i++) {
    if (bands[i].isEmpty) continue;
    final k = kAt(bandX[i] + colW / 2);
    final id = '${part}_lines$i';
    cmds.add({..._evRings(b, id, bands[i], stroke: '#77736B', width: h * 0.0075 * k, st: b.start, du: b.dur, name: 'Newsprint text')}..remove('parent'));
    cmds.add(b.fx(b.id(id), 'blur', {'amount': 3}));
  }
  if (heads.isNotEmpty) {
    cmds.add({..._evRings(b, '${part}_heads', heads, stroke: '#3B3934', width: h * 0.016, st: b.start, du: b.dur, name: 'Newsprint headlines')}..remove('parent'));
    cmds.add(b.fx(b.id('${part}_heads'), 'blur', {'amount': 3}));
  }
  cmds.addAll(_evVignette(b, '${part}_vig', 65));
  return cmds;
}

/// Segment a→c clipped to the rectangle (Liang–Barsky), or null when outside.
List<double>? _evClipSeg(double ax, double ay, double cx, double cy, double x0, double y0, double x1, double y1) {
  var t0 = 0.0, t1 = 1.0;
  final dx = cx - ax, dy = cy - ay;
  for (final (p, q) in [(-dx, ax - x0), (dx, x1 - ax), (-dy, ay - y0), (dy, y1 - ay)]) {
    if (p == 0) {
      if (q < 0) return null;
    } else {
      final r = q / p;
      if (p < 0) {
        if (r > t1) return null;
        if (r > t0) t0 = r;
      } else {
        if (r < t0) return null;
        if (r < t1) t1 = r;
      }
    }
  }
  if (t1 - t0 < 1e-6) return null;
  return [ax + dx * t0, ay + dy * t0, ax + dx * t1, ay + dy * t1];
}

/// Blurred newspaper clippings scattered at ±4° (three paper tones).
List<Map<String, dynamic>> _evCollage(_B b, String part) {
  final w = b.w, h = b.h;
  final rnd = math.Random(_evSeed(b.id(part)));
  final cmds = <Map<String, dynamic>>[b.backdrop(part, '#2B2825', color2: '#141210')];
  const tones = ['#E9E3D3', '#D8D0BC', '#F2EEE4'];
  final papers = [<List<double>>[], <List<double>>[], <List<double>>[]];
  final body = [<List<double>>[], <List<double>>[], <List<double>>[]];
  final heads = [<List<double>>[], <List<double>>[], <List<double>>[]];
  var n = 0;
  for (int row = 0; row < 3; row++) {
    for (int col = 0; col < 4; col++, n++) {
      final g = n % 3;
      final pcx = w * (0.12 + col * 0.26) + (rnd.nextDouble() - 0.5) * w * 0.08;
      final pcy = h * (0.17 + row * 0.33) + (rnd.nextDouble() - 0.5) * h * 0.1;
      final pw = w * (0.26 + rnd.nextDouble() * 0.1), ph = h * (0.32 + rnd.nextDouble() * 0.12);
      final rot = (rnd.nextDouble() * 2 - 1) * 4;
      List<List<double>> r(List<List<double>> pts) => _evRot(pts, pcx, pcy, rot);
      papers[g].add(_evFlat(r(_evRagged(pcx, pcy, pw, ph, jag: h * 0.004, step: h * 0.012, seed: rnd.nextInt(1 << 30)))));
      final lx0 = pcx - pw * 0.42, lx1 = pcx + pw * 0.42;
      var y = pcy - ph * 0.38;
      heads[g].add(_evFlat(r([[lx0, y], [lx0 + (lx1 - lx0) * (0.6 + rnd.nextDouble() * 0.35), y]])));
      y += ph * 0.13;
      while (y < pcy + ph * 0.42) {
        final e = rnd.nextDouble() < 0.15 ? 0.4 + rnd.nextDouble() * 0.4 : 1.0;
        body[g].add(_evFlat(r([[lx0, y], [lx0 + (lx1 - lx0) * e, y]])));
        y += ph * 0.055;
      }
    }
  }
  for (int g = 0; g < 3; g++) {
    final pid = '${part}_clip$g', bid = '${part}_text$g', hid = '${part}_head$g';
    cmds.add({..._evRings(b, pid, papers[g], fill: tones[g], closed: true, st: b.start, du: b.dur, name: 'Clippings')}..remove('parent'));
    cmds.add(b.fx(b.id(pid), 'shadow', {'distance': 8, 'blur': 12, 'opacity': 45}));
    cmds.add(b.fx(b.id(pid), 'blur', {'amount': 9}));
    cmds.add({..._evRings(b, bid, body[g], stroke: '#807A70', width: h * 0.006, st: b.start, du: b.dur, name: 'Clipping text')}..remove('parent'));
    cmds.add(b.fx(b.id(bid), 'blur', {'amount': 9}));
    cmds.add({..._evRings(b, hid, heads[g], stroke: '#2E2B27', width: h * 0.018, st: b.start, du: b.dur, name: 'Clipping headlines')}..remove('parent'));
    cmds.add(b.fx(b.id(hid), 'blur', {'amount': 9}));
  }
  cmds.addAll(_evVignette(b, '${part}_vig', 70));
  return cmds;
}

/// Full-frame transparent layer that only carries a vignette.
List<Map<String, dynamic>> _evVignette(_B b, String part, double amount) => [
      {
        'op': 'add_layer', 'type': 'solid', 'id': b.id(part), 'name': 'Vignette', 'color': '#00000000', 'width': b.w, 'height': b.h,
        'position': [b.w / 2, b.h / 2, 0], 'start': b.start, 'duration': b.dur,
      },
      b.fx(b.id(part), 'vignette', {'amount': amount}),
    ];

// -------------------------------------------------------------------- marks

/// Article-wide mark look.
class _EvInk {
  final String highlight, pen, paper, lines, ellipse;
  final bool multiply, dark;
  const _EvInk({
    required this.highlight,
    required this.pen,
    required this.paper,
    required this.lines,
    required this.ellipse,
    required this.multiply,
    required this.dark,
  });
}

/// Draws one mark (all its boxes) inside a content layer [parent] whose pixels
/// are [mw]×[mh] (boxes are 0..1 of it). Styles: highlight (blend normal or
/// multiply), brush, text_color, underline, circle, pen_circle (ellipse_style
/// "loop" = open loop with an overshoot tail), box, redact.
List<Map<String, dynamic>> _evDrawMark(_B b, _EvInk ink, String part, Map<String, dynamic> mk, String parent, MediaAsset? media,
    double mw, double mh, List<List<double>> boxes, double t1, double t2, double sw) {
  final cmds = <Map<String, dynamic>>[];
  final style = '${mk['style'] ?? 'highlight'}';
  final done = mk['done'] == true;
  final lineMode = '${mk['lines'] ?? ink.lines}';
  final double dmStyle = switch (style) {
    'pen_circle' => 0.35,
    'circle' => 0.6,
    'brush' => 0.55,
    'redact' => 0.25,
    _ => lineMode == 'sequential' ? 0.6 : 0.5,
  };
  final dm = done ? 0.02 : ((mk['duration'] as num?)?.toDouble() ?? dmStyle);
  final multiply = media != null && !ink.dark && '${mk['blend'] ?? (ink.multiply ? 'multiply' : 'normal')}' == 'multiply';
  final colorDefault = switch (style) {
    'highlight' || 'brush' => ink.highlight,
    'redact' => '#111111',
    'text_color' => ink.dark ? '#E8F53A' : '#D0202A',
    _ => ink.pen,
  };
  final color = '${mk['color'] ?? colorDefault}';
  final ellipse = '${mk['ellipse_style'] ?? ink.ellipse}';
  final seed = _evSeed(b.id(part));
  Map<String, dynamic> inContent(Map<String, dynamic> x, double lt) =>
      {...x, 'parent': parent, 'start': lt, 'duration': math.max(0.1, t2 - lt)};
  double lineStart(int j) {
    if (done || lineMode == 'together') return t1;
    return t1 + j * dm * (lineMode == 'sequential' ? 1.0 : 0.8);
  }

  // A duplicate of the page in its own pixels (for multiply / recolour looks).
  List<Map<String, dynamic>> inkCopy(String p, double lt, String dark, String light) {
    final id = b.id(p);
    return [
      {...b.media(p, media!, mw / 2, mh / 2, widthPx: mw, parent: parent, st: lt, du: math.max(0.1, t2 - lt)), 'name': 'Mark ink'},
      b.fx(id, 'duotone', {'dark': dark, 'light': light, 'amount': 100}),
    ];
  }

  // One pen ellipse around all boxes.
  if (style == 'pen_circle' || (style == 'circle' && ellipse == 'loop')) {
    double x0 = 1, y0 = 1, x1 = 0, y1 = 0;
    for (final bx in boxes) {
      x0 = math.min(x0, bx[0]);
      y0 = math.min(y0, bx[1]);
      x1 = math.max(x1, bx[2]);
      y1 = math.max(y1, bx[3]);
    }
    final bw = math.max(2.0, (x1 - x0) * mw), bh = math.max(2.0, (y1 - y0) * mh);
    final cx = (x0 + x1) / 2 * mw, cy = (y0 + y1) / 2 * mh;
    final lh = boxes.length > 1 ? bh / boxes.length : bh;
    final rx = bw / 2 + lh * 0.55, ry = bh / 2 + lh * 0.5;
    final List<List<double>> pts;
    if (ellipse == 'loop') {
      pts = [
        ..._evArc(cx, cy, rx, ry, from: -150, sweep: 340, steps: 36, wobble: 0.03, seed: seed),
        ..._evArc(cx, cy, rx, ry, from: 190, sweep: 42, steps: 8, wobble: 0.03, grow: 0.22, seed: seed).skip(1),
      ];
    } else {
      pts = _evArc(cx, cy, rx, ry, from: -160, sweep: 378, steps: 40, wobble: 0.025, grow: 0.07, seed: seed);
    }
    final id = b.id(part);
    cmds.add(inContent(b.path(part, pts, stroke: color, width: sw * (style == 'pen_circle' ? 0.95 : 1.1), smooth: true), t1));
    cmds.add(_evKf(id, 'trim', t1, [0, 0], _evPen));
    cmds.add(_evKf(id, 'trim', t1 + dm, [0, 100]));
    return cmds;
  }

  for (int j = 0; j < boxes.length; j++) {
    final bx = boxes[j];
    final x0 = bx[0] * mw, y0b = bx[1] * mh, x1 = bx[2] * mw, y1 = bx[3] * mh;
    final bw = math.max(2.0, x1 - x0), bh = math.max(2.0, y1 - y0b);
    final cx = (x0 + x1) / 2, cy = (y0b + y1) / 2;
    final pj = '${part}_$j';
    final id = b.id(pj);
    final lt = lineStart(j);
    switch (style) {
      case 'underline': {
        final y = y1 + bh * 0.16;
        final r = math.Random(seed + j);
        double jit() => (r.nextDouble() - 0.5) * bh * 0.08;
        final pts = <List<double>>[
          [x0 - bh * 0.1, y + jit()],
          [x0 + bw * 0.33, y + bh * 0.04 + jit()],
          [x0 + bw * 0.66, y - bh * 0.02 + jit()],
          [x1 + bh * 0.15, y + bh * 0.05 + jit()],
        ];
        cmds.add(inContent(b.path(pj, pts, stroke: color, width: sw * 1.15, smooth: true), lt));
        cmds.add(_evKf(id, 'trim', lt, [0, 0], _evPen));
        cmds.add(_evKf(id, 'trim', lt + dm, [0, 100]));
        break;
      }
      case 'circle': {
        final rx = bw / 2 + bh * 0.5, ry = bh / 2 + bh * 0.45;
        final pts = <List<double>>[
          for (int q = 0; q <= 26; q++)
            () {
              final a = (-100 + q * 400 / 26) * math.pi / 180;
              final rr = 1 + 0.04 * math.sin(3 * a) + 0.05 * q / 26;
              return [cx + math.cos(a) * rx * rr, cy + math.sin(a) * ry * rr];
            }(),
        ];
        cmds.add(inContent(b.path(pj, pts, stroke: color, width: sw * 1.1, smooth: true), lt));
        cmds.add(_evKf(id, 'trim', lt, [0, 0], _evPen));
        cmds.add(_evKf(id, 'trim', lt + dm, [0, 100]));
        break;
      }
      case 'box': {
        cmds.add(inContent(b.shape(pj, 'rect', bw * 1.06, bh * 1.3, cx, cy, fill: 'none', stroke: color, strokeWidth: sw), lt));
        cmds.add(_evKf(id, 'trim', lt, [0, 0], 'ease_out'));
        cmds.add(_evKf(id, 'trim', lt + dm, [0, 100]));
        break;
      }
      case 'redact': {
        cmds.add(inContent(b.shape(pj, 'rect', bw * 1.04, bh * 1.2, x0 - bw * 0.02, cy, fill: color), lt));
        cmds.add(b.setp(id, 'anchor', [0, bh * 0.6, 0]));
        cmds.add(_evKf(id, 'scale', lt, [0, 100, 100], _evExpoOut));
        cmds.add(_evKf(id, 'scale', lt + dm, [100, 100, 100]));
        final word = '${mk['word'] ?? ''}';
        if (word.isNotEmpty && j == 0) {
          final wt = lt + dm + 0.05;
          cmds.add({
            ...b.text('${pj}_w', word, bw * 1.04, bh * 1.2, cx, cy, bh * 0.78, color: '${mk['word_color'] ?? '#FFFFFF'}', weight: 800),
            'parent': parent, 'start': wt, 'duration': math.max(0.1, t2 - wt), 'animator': 'scramble', 'anim_duration': 0.8, 'font_family': 'monospace',
          });
        }
        break;
      }
      case 'text_color': {
        if (media != null) {
          cmds.addAll(inkCopy(pj, lt, _evOpaque(color), ink.paper));
          cmds.addAll(_evWipe(id, x0 - bh * 0.1, y0b - bh * 0.15, x1 + bh * 0.1, y1 + bh * 0.15, lt, dm, feather: bh * 0.4, ease: 'easy_ease'));
        } else {
          cmds.add(inContent(b.path(pj, [[x0, cy], [x1, cy]], stroke: _evOpaque(color), width: bh * 0.55), lt));
          cmds.add(_evKf(id, 'trim', lt, [0, 0], 'easy_ease'));
          cmds.add(_evKf(id, 'trim', lt + dm, [0, 100]));
        }
        break;
      }
      case 'brush': {
        // Rough-edged highlighter band (jittered outline), wiped on.
        final r = math.Random(seed + 17 * j);
        final pad = bh * 0.3, top = y0b - bh * 0.2, bot = y1 + bh * 0.2;
        final n = math.max(4, (bw / (bh * 0.35)).round());
        final pts = <List<double>>[
          for (int q = 0; q <= n; q++) [x0 - pad + (bw + pad * 2) * q / n, top + (r.nextDouble() - 0.5) * bh * 0.22],
          [x1 + pad + bh * 0.12, cy + (r.nextDouble() - 0.5) * bh * 0.3],
          for (int q = n; q >= 0; q--) [x0 - pad + (bw + pad * 2) * q / n, bot + (r.nextDouble() - 0.5) * bh * 0.22],
          [x0 - pad - bh * 0.1, cy + (r.nextDouble() - 0.5) * bh * 0.3],
        ];
        double minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
        for (final q in pts) {
          minX = math.min(minX, q[0]);
          maxX = math.max(maxX, q[0]);
          minY = math.min(minY, q[1]);
          maxY = math.max(maxY, q[1]);
        }
        const padL = 8.0; // shape-from-points padding (no stroke)
        final lw = maxX - minX, lh = maxY - minY;
        if (multiply) {
          final matte = b.id('${pj}_shape');
          cmds.add(inContent(_evPoly(b, '${pj}_shape', pts, '#FFFFFF'), lt));
          cmds.addAll(_evWipe(matte, padL, 0, padL + lw, lh + padL * 2, lt, dm, feather: bh * 0.3, ease: 'ease_out'));
          cmds.addAll(inkCopy(pj, lt, '#000000', _evOpaque(color)));
          cmds.add({'op': 'update_layer', 'layer': id, 'matte': {'layer': matte, 'mode': 'alpha'}});
        } else {
          cmds.add(inContent(_evPoly(b, pj, pts, _evInk(color, 0xA6)), lt));
          cmds.addAll(_evWipe(id, padL, 0, padL + lw, lh + padL * 2, lt, dm, feather: bh * 0.3, ease: 'ease_out'));
        }
        break;
      }
      case 'counter_box': {
        // A number in the document counts from → to inside a red box.
        if (j > 0) break;
        final steps = ((mk['steps'] as num?) ?? 6).toInt().clamp(1, 60);
        final from = (mk['from'] as num?)?.toDouble() ?? 0.0, to = (mk['to'] as num?)?.toDouble() ?? 100.0;
        cmds.add(inContent(b.shape(pj, 'rect', bw * 1.12, bh * 1.35, cx, cy, fill: ink.paper, stroke: _evOpaque(color), strokeWidth: sw), lt));
        cmds.add(_evKf(id, 'trim', lt, [0, 0], 'ease_out'));
        cmds.add(_evKf(id, 'trim', lt + 0.3, [0, 100]));
        cmds.add({
          ...b.text('${pj}_n', '', bw * 1.1, bh * 1.3, cx, cy, bh * 0.85, color: ink.dark ? '#E8F07A' : '#141414', weight: 900),
          'parent': parent, 'start': lt, 'duration': math.max(0.1, t2 - lt),
          'counter': {
            'from': from, 'to': to, 'decimals': ((mk['decimals'] as num?) ?? 0).toInt(), 'prefix': '${mk['prefix'] ?? ''}',
            'suffix': '${mk['suffix'] ?? ''}', 'delay': 0.25, 'duration': steps * 0.25,
          },
        });
        break;
      }
      default: // highlight
        if (multiply) {
          cmds.addAll(inkCopy(pj, lt, '#000000', _evOpaque(color)));
          cmds.addAll(_evWipe(id, x0 - bw * 0.02, y0b - bh * 0.18, x1 + bw * 0.02, y1 + bh * 0.18, lt, dm, feather: bh * 0.15));
        } else {
          final hc = ink.dark ? _evInk(color, 0x59) : _evInk(color, 0x8C);
          cmds.add(inContent(b.shape(pj, 'rect', bw * 1.04, bh * 1.25, x0 - bw * 0.02, cy, fill: hc, corner: bh * 0.1), lt));
          cmds.add(b.setp(id, 'anchor', [0, bh * 0.625, 0]));
          cmds.add(_evKf(id, 'scale', lt, [0, 100, 100], 'ease_out'));
          cmds.add(_evKf(id, 'scale', lt + dm, [100, 100, 100]));
        }
    }
  }
  return cmds;
}

// ------------------------------------------------------------------ article

bool _evArticleWanted(Map<String, dynamic> c) {
  const keys = [
    'fullbleed', 'tilt3d', 'perspective', 'focus', 'theme', 'scroll_whip', 'embed', 'lines', 'blend', 'highlight_color', 'pen_color',
    'ellipse_style', 'exit', 'sfx', 'text_tint',
  ];
  if (keys.any(c.containsKey)) return true;
  if (const ['newsprint_wall', 'newspaper_collage', 'clean', 'grunge_red', 'grunge_navy', 'paper_grey'].contains(c['backdrop'])) return true;
  if (c['enter'] == 'slide_up_over') return true;
  for (final m in (c['marks'] as List? ?? const [])) {
    if (m is! Map) continue;
    if (const ['pen_circle', 'brush', 'text_color', 'counter_box'].contains(m['style'])) return true;
    for (final k in const ['at_word', 'at', 'zoom', 'done', 'blend', 'id', 'lines', 'ellipse_style']) {
      if (m.containsKey(k)) return true;
    }
  }
  return false;
}

/// Article with the V3 upgrades (superset of the V1 article).
List<Map<String, dynamic>> _evArticle(_B b, Project p) {
  final items = b.mediaList(p, 'media');
  final cmds = <Map<String, dynamic>>[];
  final full = b.flag('fullbleed', false);
  final bg = b.str('backdrop', full ? 'none' : 'stars');
  final dark = b.str('theme', 'light') == 'dark';
  final overEnter = b.str('enter', 'slide_up') == 'slide_up_over';
  final gx = b.f('x', b.w / 2, b.w), gy = b.f('y', b.h / 2, b.h);

  // Backdrop (under a null so it can slide in with the page).
  if (bg != 'none') {
    final bgn = b.id('bgn');
    final back = <Map<String, dynamic>>[...b.nul('bgn', 0, 0, name: 'Article backdrop')];
    back.first.remove('parent');
    switch (bg) {
      case 'stars':
      case 'dust':
      case 'plain':
        back.add(b.backdrop('bg', b.str('bg', '#2A0E4F'), color2: b.str('bg2', '#0C0420')));
        back.add(b.fx(b.id('bg'), 'vignette', {'amount': 70}));
        if (bg == 'stars') back.addAll(b.atmos('stars', 'stars', amount: 45, speed: 0.3));
        if (bg == 'dust') back.addAll(b.atmos('dust', 'dust', amount: 40, speed: 0.4));
        break;
      default:
        back.addAll(_evBackdrop(b, bg));
    }
    cmds.add(back.first);
    cmds.addAll(_evParented(back.skip(1).toList(), bgn));
    if (overEnter) {
      cmds.add(_evKf(bgn, 'position', b.start, [0, b.h * 1.05, 0], _evExpoOut));
      cmds.add(_evKf(bgn, 'position', b.start + 0.3, [0, 0, 0]));
    }
  }

  cmds.addAll(b.group('Article', tilt: b.n('tilt', full ? 0 : -3)));
  final drift = b.c['drift'] is num ? b.n('drift', 5) : (full ? 3.0 : 5.0);
  cmds.add(_evKf(b.g, 'scale', b.start, [100, 100, 100], 'linear'));
  cmds.add(_evKf(b.g, 'scale', b.end, [100 + drift, 100 + drift, 100]));

  final hlDefault = switch (bg) {
    'newsprint_wall' || 'newspaper_collage' => '#E5F51A',
    'clean' => '#F0A0A0',
    _ => dark ? '#E8F53A' : '#FFE14D',
  };
  final ink = _EvInk(
    highlight: b.str('highlight_color', hlDefault),
    pen: b.str('pen_color', '#E0201B'),
    paper: b.str('paper', dark ? '#0B0B0C' : '#FBFAF5'),
    lines: b.str('lines', 'overlap'),
    ellipse: b.str('ellipse_style', 'pen'),
    multiply: b.str('blend', 'normal') == 'multiply',
    dark: dark,
  );
  final n = math.max(1, items.length);
  final slot = b.dur / n;
  final marks = b.specs('marks', 'phrase');
  for (int i = 0; i < n; i++) {
    final st = b.start + i * slot;
    final du = i == n - 1 ? b.end - st : slot;
    cmds.addAll(_evArticlePage(b, p, ink, i, items.isEmpty ? null : items[i], st, du,
        [for (final m in marks) if (((m['item'] as num?) ?? 0).toInt() == i) m], i == 0 ? b.str('enter', 'slide_up') : 'whip'));
  }

  // Exit: the page slides out to the left (or any animate_out preset).
  final exit = b.str('exit', 'none');
  if (exit == 'slide_left' || exit == 'slide_right') {
    final t0 = b.end - 0.42;
    final dir = exit == 'slide_left' ? -1 : 1;
    cmds.add(_evKf(b.g, 'position', t0, [gx, gy, 0], _evExpoIn));
    cmds.add(_evKf(b.g, 'position', b.end - 0.02, [gx + dir * b.w * 1.25, gy, 0]));
    final s = _evSfx(b, 'whoosh', b.end - 0.2);
    if (s != null) cmds.add(s);
  } else if (exit != 'none' && MotionPresets.transitions.contains(exit)) {
    cmds.add({'op': 'animate_out', 'layer': b.g, 'preset': exit, 'duration': 0.4});
  }

  // 3D settle: the whole page group goes into a precomp shown as one 3D layer.
  final t3 = b.c['tilt3d'];
  final persp = b.c['perspective'];
  if ((t3 != null && t3 != false) || persp is Map) {
    final ids = <String>{b.g};
    for (final c in cmds) {
      if (c['op'] == 'add_layer' && ids.contains(c['parent'])) ids.add('${c['id']}');
    }
    final pc = b.id('pc'), cl = b.id('3d');
    cmds.add({'op': 'precompose', 'layers': ids.toList(), 'id': pc, 'layer_id': cl, 'name': 'Article page (3D)'});
    cmds.add({'op': 'update_layer', 'layer': cl, 'is3d': true});
    cmds.add(b.setp(cl, 'anchor', [gx, gy, 0]));
    cmds.add(b.setp(cl, 'position', [gx, gy, 0]));
    List<double> v3(dynamic v, List<double> d) =>
        v is List && v.length >= 2 ? [for (int k = 0; k < 3; k++) k < v.length ? (v[k] as num).toDouble() : 0.0] : d;
    if (persp is Map) {
      final rx = (persp['rx'] as num?)?.toDouble() ?? 12.0, ry = (persp['ry'] as num?)?.toDouble() ?? 0.0;
      cmds.add(b.setp(cl, 'rotation', [rx, ry, 0]));
    }
    if (t3 != null && t3 != false) {
      final m = t3 is Map ? Map<String, dynamic>.from(t3) : const <String, dynamic>{};
      final from = v3(m['from'], [22, 0, -2]), to = v3(m['to'], [0, 0, -1]);
      final d = (m['duration'] as num?)?.toDouble() ?? 0.5;
      final at = b.start + ((m['at'] as num?)?.toDouble() ?? 0.0);
      cmds.add(_evKf(cl, 'rotation', at, from, _evExpoOut));
      cmds.add(_evKf(cl, 'rotation', at + d, to));
    }
  }

  final coming = b.c['coming_up'];
  if (coming != null && coming != false) {
    final text = (coming is String ? coming : 'Coming up next').toUpperCase();
    final fs = b.h * 0.03;
    final tw = text.length * fs * 0.66 + fs * 1.6;
    final t1 = b.start + 0.4;
    final tag = b.id('next');
    cmds.add({
      'op': 'add_layer', 'type': 'shape', 'id': tag, 'name': 'Coming up next', 'kind': 'rect', 'width': tw, 'height': fs * 1.9,
      'fill': b.str('tag_color', '#E53935'), 'corner': fs * 0.25, 'start': t1, 'duration': b.end - t1,
      'position': [b.w * 0.05 + tw / 2, b.h * 0.09, 0],
    });
    cmds.add({
      'op': 'add_layer', 'type': 'text', 'id': b.id('next_text'), 'text': text, 'width': tw, 'height': fs * 1.9, 'font_size': fs,
      'font_weight': 900, 'text_color': '#FFFFFF', 'shadow': false, 'start': t1, 'duration': b.end - t1,
      'position': [b.w * 0.05 + tw / 2, b.h * 0.09, 0], 'parent': tag,
    });
    cmds.add(b.setp(b.id('next_text'), 'position', [tw / 2, fs * 0.95, 0]));
    cmds.add({'op': 'animate_in', 'layer': tag, 'preset': 'slide_right', 'duration': 0.45});
  }
  return cmds;
}

List<Map<String, dynamic>> _evArticlePage(_B b, Project p, _EvInk ink, int i, MediaAsset? m, double st, double du,
    List<Map<String, dynamic>> marks, String enter) {
  final pre = 'a$i';
  final full = b.flag('fullbleed', false);
  final dark = ink.dark;
  final pw = full ? b.w : b.f('width', b.w * 0.5, b.w);
  final margin = full ? 0.0 : pw * 0.04;
  final iw0 = pw - margin * 2;
  final double mw = m?.width ?? iw0, mh = m?.height ?? iw0 * 1.3;
  final s = full ? math.max(b.w / math.max(1, mw), b.h / math.max(1, mh)) : iw0 / math.max(1, mw);
  final iw = mw * s, ih = mh * s;
  final maxH = b.h * b.n('window', full ? 1.0 : 0.8);
  final scroll = ih > maxH * 1.06 && b.c['scroll'] != false;
  final wh = scroll ? maxH : ih;
  final ph = wh + margin * 2;
  final cmds = <Map<String, dynamic>>[...b.nul('${pre}_page', 0, 0, st: st, du: du, name: 'Article page ${i + 1}')];
  final pg = b.id('${pre}_page');
  Map<String, dynamic> child(Map<String, dynamic> x) => {...x, 'parent': pg, 'start': st, 'duration': du};

  final paper = b.id('${pre}_paper');
  cmds.add(child(b.shape('${pre}_paper', 'rect', iw + margin * 2, ph, 0, 0, fill: ink.paper)));
  final torn = b.str('torn', full ? 'none' : 'bottom');
  if (torn != 'none') {
    for (final side in torn == 'both' ? ['top', 'bottom'] : [torn]) {
      cmds.add(b.fx(paper, 'torn_edge', {'side': const ['top', 'bottom', 'left', 'right'].contains(side) ? side : 'bottom', 'amount': 60}));
    }
  }
  if (!full) cmds.add(b.fx(paper, 'shadow', {'distance': 22, 'blur': 28, 'opacity': 60}));
  cmds.add(b.fx(paper, dark ? 'grunge' : 'paper', {'amount': dark ? 18 : 35}));

  final cid = b.id('${pre}_img');
  double yCenter(double o) => -wh / 2 + ih / 2 - o;
  final y0 = scroll ? yCenter(0) : 0.0;
  final kids = <(String, double, double)>[];
  if (m != null) {
    cmds.add(child(b.media('${pre}_img', m, 0, y0, widthPx: iw)));
    if (dark) {
      cmds.add(b.fx(cid, 'duotone', {'dark': b.str('text_tint', '#E8F07A'), 'light': ink.paper, 'amount': 100}));
      cmds.add(b.fx(cid, 'glow', {'amount': 35, 'radius': 6}));
      cmds.add(b.fx(cid, 'chromatic_aberration', {'amount': 30}));
    }
  } else {
    cmds.add(child(b.shape('${pre}_img', 'rect', mw, mh, 0, y0, fill: ink.paper)));
    final head = <List<double>>[
      [mw * 0.06, mh * 0.07, mw * 0.9, mh * 0.07],
      [mw * 0.06, mh * 0.115, mw * 0.62, mh * 0.115],
    ];
    final body = <List<double>>[
      for (int j = 0; j < 16; j++) [mw * 0.06, mh * (0.2 + j * 0.045), mw * (j % 4 == 3 ? 0.6 : 0.94), mh * (0.2 + j * 0.045)],
    ];
    cmds.add(_evRings(b, '${pre}_head', head, stroke: dark ? b.str('text_tint', '#E8F07A') : '#1A1A1A', width: mh * 0.022, parent: cid, st: st, du: du));
    cmds.add(_evRings(b, '${pre}_lines', body, stroke: dark ? '#B9C062' : '#A0A0A0', width: mh * 0.012, parent: cid, st: st, du: du));
    kids.add((b.id('${pre}_head'), mw * 0.06 - (mh * 0.022 * 3 + 8), mh * 0.07 - (mh * 0.022 * 3 + 8)));
    kids.add((b.id('${pre}_lines'), mw * 0.06 - (mh * 0.012 * 3 + 8), mh * 0.2 - (mh * 0.012 * 3 + 8)));
    if (dark) {
      cmds.add(b.fx(b.id('${pre}_head'), 'glow', {'amount': 35, 'radius': 6}));
      cmds.add(b.fx(b.id('${pre}_lines'), 'glow', {'amount': 30, 'radius': 5}));
    }
  }
  for (final e in ['curve', 'edge_blur']) {
    if (b.c[e] is num) {
      final params = e == 'curve' ? {'bend': b.n(e, 0)} : {'amount': b.n(e, 0)};
      cmds.add(b.fx(paper, e, params));
      cmds.add(b.fx(cid, e, params));
    }
  }

  // Marks with their times (delay / at / at_word / done), keeping their index.
  final timed = <(Map<String, dynamic>, List<List<double>>, double, int)>[];
  var auto = 0.9;
  final indexed = [for (int k = 0; k < marks.length; k++) (marks[k], k)];
  indexed.sort((a, c) {
    final ba = _markBoxes(a.$1), bc = _markBoxes(c.$1);
    return (ba.isEmpty ? 0.0 : ba.first[1]).compareTo(bc.isEmpty ? 0.0 : bc.first[1]);
  });
  for (final (mk, k) in indexed) {
    final boxes = _markBoxes(mk);
    if (boxes.isEmpty) continue;
    double? delay = (mk['delay'] as num?)?.toDouble();
    if (mk['at'] is num) delay = (mk['at'] as num).toDouble() - st;
    if (mk['at_word'] is String) {
      final wt = _evWordTime(p, '${mk['at_word']}', st, st + du);
      if (wt != null) delay = wt - st + 0.15; // the mark lands just after the word
    }
    if (mk['done'] == true) delay = 0;
    delay ??= auto;
    auto = delay + 1.7;
    timed.add((mk, boxes, delay, k));
  }
  timed.sort((a, c) => a.$3.compareTo(c.$3));

  // Whip target(s).
  final whip = b.c['scroll_whip'];
  final whipSpec = whip is Map ? Map<String, dynamic>.from(whip) : <String, dynamic>{};
  final whipDur = (whipSpec['duration'] as num?)?.toDouble() ?? 0.25;
  bool isWhip(Map<String, dynamic> mk, int k) {
    if (whip == null || whip == false) return false;
    if (whip == true) return true;
    final to = whipSpec['to_mark'];
    return to == null || (to is num && to.toInt() == k) || (to is String && mk['id'] == to);
  }

  // Scroll: pan down long screenshots, stopping on each mark.
  final stops = <double>[];
  final offsets = <double>[]; // scroll offset at each timed mark
  var whipped = false;
  if (scroll) {
    final maxO = ih - wh;
    final win = '${cid}_window';
    cmds.add({'op': 'add_mask', 'layer': cid, 'id': win, 'shape': 'rect', 'center': [mw / 2, (wh / 2) / s], 'size': [mw * 1.02, wh / s], 'feather': 0});
    for (final (kid, ox, oy) in kids) {
      cmds.add({'op': 'add_mask', 'layer': kid, 'id': '${kid}_window', 'shape': 'rect', 'center': [mw / 2 - ox, (wh / 2) / s - oy], 'size': [mw * 1.02, wh / s], 'feather': 0});
    }
    void key(double t, double o, dynamic ease) {
      cmds.add(_evKf(cid, 'position', t, [0, yCenter(o), 0], ease));
      cmds.add(_evMaskKf(cid, win, 'center', t, [mw / 2, (o + wh / 2) / s], ease));
      for (final (kid, ox, oy) in kids) {
        cmds.add(_evMaskKf(kid, '${kid}_window', 'center', t, [mw / 2 - ox, (o + wh / 2) / s - oy], ease));
      }
    }

    if (timed.isEmpty) {
      key(st + 0.6, 0, 'easy_ease');
      key(st + math.max(0.7, du - 0.3), maxO, 'easy_ease');
    } else {
      var lastT = st, lastO = 0.0;
      key(st, 0, 'easy_ease');
      for (final (mk, boxes, delay, k) in timed) {
        final cy = (boxes.first[1] + boxes.last[3]) / 2;
        final o = (cy * ih - wh / 2).clamp(0.0, maxO);
        offsets.add(o);
        final arrive = st + delay - 0.05;
        final w = isWhip(mk, k);
        final leave = math.max(lastT + 0.05, arrive - (w ? whipDur : 0.9));
        stops.add(leave);
        if (arrive > leave + 0.05 && (o - lastO).abs() > 0.5) {
          key(leave, lastO, w ? _evWhip : 'easy_ease');
          key(arrive, o, 'easy_ease');
          lastT = arrive;
          lastO = o;
          whipped = whipped || w;
        }
      }
    }
  } else {
    for (int k = 0; k < timed.length; k++) {
      offsets.add(0);
    }
  }

  // Mark layers live inside the content, in its own pixels.
  final sw = b.h * 0.006 / s;
  final markCentre = <int, List<double>>{}; // mark index → page-space centre
  final markTime = <int, double>{};
  final markId = <String, int>{};
  for (int k = 0; k < timed.length; k++) {
    final (mk, boxes, delay, idx) = timed[k];
    final t1 = st + delay;
    if (mk['id'] is String) markId['${mk['id']}'] = idx;
    final cxF = (boxes.map((e) => e[0]).reduce(math.min) + boxes.map((e) => e[2]).reduce(math.max)) / 2;
    final cyF = (boxes.first[1] + boxes.last[3]) / 2;
    final py = scroll ? yCenter(offsets[k]) + (cyF * mh - mh / 2) * s : (cyF * mh - mh / 2) * s;
    markCentre[idx] = [(cxF * mw - mw / 2) * s, py];
    markTime[idx] = t1;
    if (t1 >= st + du - 0.05) continue;
    var t2 = st + du;
    if (scroll && k + 1 < stops.length) t2 = math.min(t2, stops[k + 1] + 0.35);
    cmds.addAll(_evDrawMark(b, ink, '${pre}_m$k', mk, cid, m, mw, mh, boxes, t1, t2, sw));
  }

  // Embedded photo (target for zoom_into_photo): "<id>_embed".
  final emb = b.c['embed'];
  if (emb is Map && i == 0) {
    final e = Map<String, dynamic>.from(emb);
    final em = e['media'] is String ? p.media['${e['media']}'] : null;
    if (em != null && em.type != MediaType.audio) {
      double ex, ey, ew;
      final box = e['box'];
      double after = st + 0.6;
      if (box is List && box.length >= 4) {
        final bb = [for (final v in box.take(4)) (v as num).toDouble()];
        ex = (bb[0] + bb[2]) / 2 * mw;
        ew = (bb[2] - bb[0]).abs() * mw;
        ey = (bb[1] + bb[3]) / 2 * mh;
      } else {
        ew = (e['width'] as num?)?.toDouble() ?? 0.8;
        ew = ew <= 1.5 ? ew * mw : ew / s;
        final eh = em.height * ew / math.max(1, em.width);
        ex = mw / 2;
        var top = mh * 0.55 - eh / 2;
        final am = e['after_mark'];
        for (final (mk, boxes, delay, idx) in timed) {
          if ((am is num && am.toInt() == idx) || (am is String && mk['id'] == am)) {
            top = boxes.last[3] * mh + mh * 0.015;
            after = st + delay + 0.7;
          }
        }
        ey = math.min(top + eh / 2, mh - eh / 2);
      }
      if (e['at'] is num) after = st + (e['at'] as num).toDouble();
      final eid = b.id('embed');
      cmds.add({...b.media('embed', em, ex, ey, widthPx: ew, parent: cid, st: after, du: math.max(0.1, st + du - after)), 'name': 'Embedded photo'});
      final es = ew / math.max(1, em.width) * 100;
      cmds.add(b.fx(eid, 'shadow', {'distance': 6, 'blur': 10, 'opacity': 40}));
      cmds.add(_evKf(eid, 'scale', after, [es * 0.92, es * 0.92, 100], _evExpoOut));
      cmds.add(_evKf(eid, 'scale', after + 0.35, [es, es, 100]));
      cmds.add(_evKf(eid, 'opacity', after, 0, 'ease_out'));
      cmds.add(_evKf(eid, 'opacity', after + 0.2, 100));
    }
  }

  // Focus punch-ins: the page moves/scales so the mark sits in the centre.
  final focus = <(double, double, double, List<double>)>[]; // time, duration, zoom, centre
  for (final f in b.specs('focus', 'mark')) {
    final mref = f['mark'];
    final idx = mref is num ? mref.toInt() : (mref is String ? markId[mref] : null);
    final zoom = (f['zoom'] as num?)?.toDouble() ?? 1.9;
    final d = (f['duration'] as num?)?.toDouble() ?? 0.35;
    final c = idx == null ? null : markCentre[idx];
    if (c == null && zoom != 1) continue;
    final t = f['at'] is num ? st + (f['at'] as num).toDouble() : (idx != null && markTime[idx] != null ? markTime[idx]! - d - 0.05 : st + 1);
    focus.add((t, d, zoom, c ?? const [0.0, 0.0]));
  }
  for (final (mk, _, _, idx) in timed) {
    final z = mk['zoom'];
    if ((z == true || z is num) && markCentre[idx] != null && markTime[idx] != null) {
      focus.add((markTime[idx]! - 0.4, 0.35, z is num ? z.toDouble() : 1.9, markCentre[idx]!));
    }
  }
  focus.sort((a, c) => a.$1.compareTo(c.$1));
  if (focus.isNotEmpty) {
    var curP = [0.0, 0.0], curZ = 1.0;
    var lastEnd = st + 0.55;
    for (final (t, d, z, c) in focus) {
      final ta = math.max(t, lastEnd);
      if (ta >= st + du - 0.1) break;
      final np = z == 1 ? [0.0, 0.0] : [-c[0] * z, -c[1] * z];
      cmds.add(_evKf(pg, 'position', ta, [curP[0], curP[1], 0], _evExpoOut));
      cmds.add(_evKf(pg, 'scale', ta, [curZ * 100, curZ * 100, 100], _evExpoOut));
      cmds.add(_evKf(pg, 'position', ta + d, [np[0], np[1], 0]));
      cmds.add(_evKf(pg, 'scale', ta + d, [z * 100, z * 100, 100]));
      final s2 = _evSfx(b, 'whoosh', ta + d * 0.5);
      if (s2 != null) cmds.add(s2);
      curP = np;
      curZ = z;
      lastEnd = ta + d + 0.05;
    }
  }
  if (focus.isNotEmpty || whipped || b.str('enter', '') == 'slide_up_over' || b.str('exit', 'none').startsWith('slide')) {
    cmds.add(b.fx(paper, 'motion_blur', {'amount': 70}));
    cmds.add(b.fx(cid, 'motion_blur', {'amount': 70}));
  }

  if (enter == 'slide_up_over') {
    cmds.add(_evKf(pg, 'position', st, [0, b.h * 1.05, 0], _evExpoOut));
    cmds.add(_evKf(pg, 'position', st + 0.3, [0, 0, 0]));
  } else if (enter != 'none') {
    cmds.add({'op': 'animate_in', 'layer': pg, 'preset': MotionPresets.transitions.contains(enter) ? enter : 'slide_up', 'duration': 0.5});
  }
  final s1 = _evSfx(b, 'paper', st + 0.05);
  if (s1 != null) cmds.add(s1);
  return cmds;
}

// ------------------------------------------------------------ circle_mark

List<Map<String, dynamic>> _evCircleMark(_B b0, Project p) {
  final draw = b0.n('draw', 0.5), hold = b0.n('hold', 0.9);
  final undraw = b0.flag('undraw', true);
  final b = _evWithDur(b0, draw + hold + (undraw ? 0.4 : 0.6));
  var x = b.f('x', b.w / 2, b.w), y = b.f('y', b.h / 2, b.h);
  final attach = b.c['attach'];
  if (attach is String) {
    final pt = _screenPointOf(p.editComp, attach, b.start, b.vec('at', [0.5, 0.5]));
    if (pt != null) {
      x = pt[0];
      y = pt[1];
    }
  }
  final cw = b.f('width', b.h * 0.22, b.h), ch = b.n('height', cw);
  final color = b.str('color', '#F01818');
  final sw = _evSize(b, 'stroke', 0.012, b.h, limit: 0.2);
  final cmds = b.group('Circle Mark', x: 0, y: 0);
  final ring = b.id('ring');
  cmds.add(b.path('ring', _evArc(x, y, cw / 2, ch / 2, from: -90, sweep: 370, steps: 48, wobble: 0.012, grow: 0.035, seed: _evSeed(ring)),
      stroke: color, width: sw, smooth: true));
  cmds.add(_evKf(ring, 'trim', b.start, [0, 0], _evPen));
  cmds.add(_evKf(ring, 'trim', b.start + draw, [0, 100]));
  if (undraw) {
    final tu = math.max(b.start + draw + 0.05, b.end - 0.38);
    cmds.add(_evKf(ring, 'trim', tu, [0, 100], 'ease_in'));
    cmds.add(_evKf(ring, 'trim', b.end - 0.03, [100, 100]));
  }
  if (b.c['glow'] != false) cmds.add(b.fx(ring, 'glow', {'amount': b.c['glow'] is num ? b.n('glow', 45) : 45, 'radius': 10}));
  final s = _evSfx(b, 'tick', b.start);
  if (s != null) cmds.add(s);
  return _evFinish(b, cmds, enter: 'none', exit: null);
}

// ----------------------------------------------------------- inset_circle

List<Map<String, dynamic>> _evInsetCircle(_B b0, Project p) {
  final b = _evWithDur(b0, 4);
  final d = _evSize(b, 'size', 0.3, b.h);
  final x = b.f('x', b.w * 0.74, b.w), y = b.f('y', b.h * 0.4, b.h);
  final from = b.vec('from', [x, y + d * 0.6]);
  final ring = b.c['ring'] is Map ? Map<String, dynamic>.from(b.c['ring'] as Map) : const <String, dynamic>{};
  final rc = '${ring['color'] ?? b.str('ring_color', '#FFFFFF')}';
  final rw = (ring['width'] as num?)?.toDouble() ?? 6.0;
  final cmds = b.group('Inset Circle', x: x, y: y);
  cmds.add(b.shape('under', 'ellipse', d, d, 0, 0, fill: '#151515'));
  cmds.add(b.fx(b.id('under'), 'shadow', {'distance': 10, 'blur': 18, 'opacity': 60}));
  final m = b.mediaOf(p, 'media');
  if (m != null) {
    final s = d / math.max(1, math.min(m.width, m.height)) * 100;
    cmds.add({...b.media('img', m, 0, 0), 'scale': [s, s, 100]});
    cmds.add({'op': 'add_mask', 'layer': b.id('img'), 'shape': 'ellipse', 'center': [m.width / 2, m.height / 2], 'size': [d / s * 100, d / s * 100], 'feather': 1});
  }
  cmds.add(b.shape('ring', 'ellipse', d + rw, d + rw, 0, 0, fill: 'none', stroke: rc, strokeWidth: rw));
  final label = b.str('label', '');
  if (label.isNotEmpty) {
    final fs = b.f('label_size', b.h * 0.042, b.h);
    final tw = math.max(d, label.length * fs * 0.68 + fs);
    final t1 = b.start + 0.35;
    final yellow = b.str('label_style', 'yellow_outline') == 'yellow_outline';
    cmds.add({
      ...b.text('label', label.toUpperCase(), tw, fs * 1.5, 0, d / 2 + fs * 0.95, fs, color: yellow ? '#FFD21F' : '#FFFFFF', weight: 900),
      'start': t1, 'duration': math.max(0.1, b.end - t1), 'animator': 'word_pop', 'anim_duration': 0.35, 'shadow': !yellow, 'font': 'Poppins',
    });
    if (yellow) cmds.add(b.fx(b.id('label'), 'outline', {'width': 3, 'color': '#141414'}));
  }
  final enter = b.str('enter', 'grow_from_point');
  if (enter == 'grow_from_point') {
    cmds.add(_evKf(b.g, 'position', b.start, [from[0], from[1], 0], _evBack));
    cmds.add(_evKf(b.g, 'position', b.start + 0.45, [x, y, 0]));
    cmds.add(_evKf(b.g, 'scale', b.start, [4, 4, 100], _evBack));
    cmds.add(_evKf(b.g, 'scale', b.start + 0.45, [100, 100, 100]));
    cmds.add(_evKf(b.g, 'opacity', b.start, 0, 'ease_out'));
    cmds.add(_evKf(b.g, 'opacity', b.start + 0.1, 100));
  }
  final exit = b.str('exit', 'shrink_to_point');
  if (exit == 'shrink_to_point') {
    final t0 = math.max(b.start + 0.5, b.end - 0.35);
    cmds.add(_evKf(b.g, 'position', t0, [x, y, 0], _evExpoIn));
    cmds.add(_evKf(b.g, 'position', b.end - 0.02, [from[0], from[1], 0]));
    cmds.add(_evKf(b.g, 'scale', t0, [100, 100, 100], _evExpoIn));
    cmds.add(_evKf(b.g, 'scale', b.end - 0.02, [4, 4, 100]));
  }
  final s = _evSfx(b, 'pop', b.start + 0.1);
  if (s != null) cmds.add(s);
  return _evFinish(b, cmds,
      enter: enter == 'grow_from_point' ? 'none' : enter,
      exit: exit == 'shrink_to_point' ? null : (exit == 'none' ? null : exit));
}

// --------------------------------------------------------------------- book

List<Map<String, dynamic>> _evBook(_B b0, Project p) {
  final side = b0.str('enter', 'rise') == 'side_popin';
  final openAt0 = b0.n('open_at', 1.6);
  final pages = b0.specs('pages', 'text');
  final marks = b0.specs('marks', 'phrase');
  final zoomTo = b0.str('zoom_to', 'page') == 'page';
  bool filled(Map<String, dynamic> pg) => pg['media'] is String || '${pg['text'] ?? ''}'.trim().isNotEmpty;
  // win-30: two or more real pages are READ — zoom in first, hold each page
  // long enough to read (its marks play on it), then flip to the next.
  // (Before, the pages flipped by in 0.3 s and only the last one was seen.)
  final read = zoomTo && b0.c['read'] != false && pages.where(filled).length >= 2;
  final int flips = read ? math.min(pages.length - 1, 4) : b0.n('flips', 1).round().clamp(0, 4).toInt();
  final nPages = flips + 1;
  final tOpen = openAt0;
  final pageMarks = [for (int k = 0; k < nPages; k++) <Map<String, dynamic>>[]];
  for (final mk in marks) {
    var k = mk['page'] is num ? (mk['page'] as num).round().clamp(0, nPages - 1).toInt() : -1;
    if (k < 0 && read) {
      final ph = '${mk['phrase'] ?? ''}'.toLowerCase();
      for (int q = 0; q < nPages && q < pages.length; q++) {
        if (ph.isNotEmpty && '${pages[q]['text'] ?? ''}'.toLowerCase().contains(ph)) {
          k = q;
          break;
        }
      }
    }
    pageMarks[k < 0 ? nPages - 1 : k].add(mk);
  }
  double markSpan(List<Map<String, dynamic>> ms) => ms.fold(0.0, (a, m) => a + ('${m['style'] ?? 'highlight'}' == 'highlight' ? 0.9 : 0.6));
  // Times relative to the start: flipAt[k] turns page k, markAt[k] = its first mark.
  final flipAt = <double>[], markAt = <double>[];
  final double tZoom, tEnd;
  if (read) {
    tZoom = tOpen + 0.45;
    var tr = tZoom + 0.8 + 0.2;
    for (int k = 0; k < nPages; k++) {
      final words = k < pages.length ? '${pages[k]['text'] ?? ''}'.split(RegExp(r'\s+')).where((x) => x.isNotEmpty).length : 0;
      final hold = math.max((words / 3.2).clamp(1.6, 5.0).toDouble(), markSpan(pageMarks[k]) + 1.0);
      markAt.add(tr + 0.3);
      if (k < flips) {
        flipAt.add(tr + hold);
        tr = tr + hold + 0.35;
      } else {
        tr += hold;
      }
    }
    tEnd = tr + 1.2;
  } else {
    final tFlip0 = tOpen + 0.45;
    for (int k = 0; k < flips; k++) {
      flipAt.add(tFlip0 + k * 0.3);
    }
    tZoom = tFlip0 + flips * 0.3 + 0.1;
    final tMarks = (zoomTo ? tZoom + 0.8 : tZoom) + 0.3;
    for (int k = 0; k < nPages; k++) {
      markAt.add(tMarks);
    }
    tEnd = tMarks + marks.length * 1.0 + 3.0;
  }
  final b = _evWithDur(b0, math.max(6.0, tEnd));
  final w = b.w, h = b.h;
  final cmds = <Map<String, dynamic>>[];

  final bgKind = b.str('bg', side ? 'none' : 'grunge_red');
  if (bgKind != 'none' && bgKind != 'footage') cmds.addAll(_evBackdrop(b, bgKind));

  // Built at the zoomed-in size (crisp text), shown scaled down while closed.
  final ch = h * 0.86, cw = ch * 0.7;
  final coverH = _evSize(b, 'height', side ? 0.32 : 0.3, h);
  final k0 = coverH / ch * 100;
  final x = b.n('x', side ? w * 0.86 : w * 0.5), y = b.n('y', side ? h * 0.56 : h * 0.52);
  final tilt = b.n('tilt', 4);
  final colors = b.list('colors');
  final cCover = colors.isNotEmpty ? colors[0] : '#1D2B4F';
  final cTitle = colors.length > 1 ? colors[1] : '#F2D21B';
  final cText = colors.length > 2 ? colors[2] : '#F4EEDF';
  final title = b.str('title', 'THE BOOK');
  final author = b.str('author', '');
  cmds.addAll(b.group('Book', x: x, y: y));
  cmds.add(b.setp(b.g, 'scale', [k0, k0, 100]));
  final spine = b.id('spine');
  cmds.addAll(b.nul('spine', -cw / 2, 0, name: 'Spine'));
  Map<String, dynamic> on(String parent, Map<String, dynamic> x, [double? st, double? du]) =>
      {...x, 'parent': parent, 'start': ?st, 'duration': ?du};

  // Back board + page block (right side).
  cmds.add(on(spine, b.shape('back', 'rect', cw * 1.02, ch * 1.02, cw / 2 + cw * 0.01, ch * 0.005, fill: _shade(cCover, 0.7))));
  cmds.add(b.fx(b.id('back'), 'shadow', {'distance': 26, 'blur': 34, 'opacity': 65}));
  cmds.add(on(spine, b.shape('block', 'rect', cw * 0.985, ch * 0.975, cw / 2, 0, fill: '#F4EEDF', fill2: '#E9E0CB')));
  cmds.add(b.fx(b.id('block'), 'paper', {'amount': 40}));
  cmds.add(on(spine, _evRings(b, 'edges', [
    for (int k = 0; k < 7; k++) [cw * 0.985 - k * cw * 0.004, -ch * 0.47, cw * 0.985 - k * cw * 0.004, ch * 0.47],
  ], stroke: '#C9BEA6', width: 1.5)));

  // Page contents (right page), switched by the flips.
  final pageEnds = [for (int k = 0; k < nPages; k++) k < flips ? b.start + flipAt[k] : b.end];
  final pw = cw * 0.86, phh = ch * 0.88;
  for (int k = 0; k < nPages; k++) {
    final ps = b.start + (k == 0 ? 0 : flipAt[k - 1]);
    final pd = math.max(0.1, pageEnds[k] - ps);
    final spec = k < pages.length ? pages[k] : const <String, dynamic>{};
    final media = spec['media'] is String ? p.media['${spec['media']}'] : null;
    final pmarks = pageMarks[k];
    final tMarks = markAt[k];
    final part = 'pg$k';
    if (media != null && media.type != MediaType.audio) {
      final s = math.min(pw / math.max(1, media.width), phh / math.max(1, media.height));
      final mw = media.width, mh = media.height;
      cmds.add(on(spine, b.media(part, media, cw / 2, 0, widthPx: mw * s), ps, pd));
      final ink = _EvInk(highlight: b.str('highlight_color', '#F2C200'), pen: b.str('pen_color', '#D0202A'), paper: '#F4EEDF',
          lines: 'sequential', ellipse: 'pen', multiply: b.str('blend', 'multiply') == 'multiply', dark: false);
      var t = b.start + tMarks;
      for (int q = 0; q < pmarks.length; q++) {
        final boxes = _markBoxes(pmarks[q]);
        if (boxes.isEmpty) continue;
        final mt = pmarks[q]['delay'] is num ? b.start + (pmarks[q]['delay'] as num).toDouble() : t;
        cmds.addAll(_evDrawMark(b, ink, '${part}_m$q', pmarks[q], b.id(part), media, mw, mh, boxes, mt, b.end, h * 0.005 / s));
        t = mt + 0.6 * boxes.length + 0.5;
      }
    } else {
      final text = '${spec['text'] ?? ''}';
      final fs = ch * 0.034;
      if (text.isEmpty) {
        final r = math.Random(_evSeed(b.id(part)));
        final lines = <List<double>>[
          for (int q = 0; q < 22; q++)
            [cw / 2 - pw / 2, -phh / 2 + phh * (0.06 + q * 0.042), cw / 2 - pw / 2 + pw * (q % 6 == 5 ? 0.4 + r.nextDouble() * 0.4 : 1.0), -phh / 2 + phh * (0.06 + q * 0.042)],
        ];
        cmds.add(on(spine, _evRings(b, part, lines, stroke: '#9C9483', width: ch * 0.009), ps, pd));
      } else {
        var t = tMarks;
        final off = ps - b.start; // marks are relative to the page layer start
        final tmarks = <Map<String, dynamic>>[];
        for (final mk in pmarks) {
          final style = '${mk['style'] ?? 'highlight'}';
          final delay = mk['delay'] is num ? (mk['delay'] as num).toDouble() : t;
          tmarks.add({
            'phrase': '${mk['phrase'] ?? ''}',
            'style': style == 'pen_circle' ? 'circle' : (style == 'text_color' ? 'color' : style),
            'delay': math.max(0.0, delay - off),
            'duration': (mk['duration'] as num?)?.toDouble() ?? (style == 'highlight' ? 0.6 : 0.4),
            'color': '${mk['color'] ?? (style == 'highlight' ? _alpha(b.str('highlight_color', '#F2C200'), 0xB3) : b.str('pen_color', '#D0202A'))}',
          });
          t = delay + (style == 'highlight' ? 0.9 : 0.6);
        }
        cmds.add(on(spine, {
          ...b.text(part, text, pw, phh, cw / 2, 0, fs, color: '#2A2622', weight: 500, align: 'left'),
          'font': 'Playfair Display',
          if (tmarks.isNotEmpty) 'marks': tmarks,
        }, ps, pd));
      }
    }
  }

  // Cover (hinged at the spine): scales to the spine, then the inside of the cover opens left.
  final cover = b.id('cover');
  cmds.addAll(b.nul('cover', 0, 0, parent: spine, name: 'Cover'));
  final m = b.mediaOf(p, 'cover');
  cmds.add(on(cover, b.shape('cv', 'rect', cw * 1.02, ch * 1.02, cw / 2 + cw * 0.01, 0, fill: cCover, fill2: _shade(cCover, 0.72), corner: cw * 0.012)));
  cmds.add(b.fx(b.id('cv'), 'paper', {'amount': 35}));
  if (m != null) {
    final s = math.max(cw / math.max(1, m.width), ch / math.max(1, m.height));
    cmds.add(on(cover, b.media('cvimg', m, cw / 2, 0, widthPx: m.width * s)));
    cmds.add({'op': 'add_mask', 'layer': b.id('cvimg'), 'shape': 'rect', 'center': [m.width / 2, m.height / 2], 'size': [cw / s, ch / s], 'feather': 0});
  } else {
    cmds.add(on(cover, b.shape('cvspine', 'rect', cw * 0.06, ch * 1.02, cw * 0.04, 0, fill: _shade(cCover, 0.55))));
    cmds.add(on(cover, b.shape('cvframe', 'rect', cw * 0.84, ch * 0.9, cw * 0.54, 0, fill: 'none', stroke: cTitle, strokeWidth: cw * 0.008)));
    final tfs = math.min(ch * 0.085, cw * 0.78 / math.max(4, title.length * 0.55));
    cmds.add(on(cover, {...b.text('cvtitle', title.toUpperCase(), cw * 0.76, ch * 0.42, cw * 0.54, -ch * 0.12, tfs, color: cTitle, weight: 900), 'font': 'Playfair Display'}));
    cmds.add(on(cover, b.shape('cvrule', 'rect', cw * 0.3, ch * 0.006, cw * 0.54, ch * 0.13, fill: cTitle)));
    if (author.isNotEmpty) {
      cmds.add(on(cover, {...b.text('cvauthor', author.toUpperCase(), cw * 0.76, ch * 0.08, cw * 0.54, ch * 0.3, ch * 0.032, color: cText, weight: 700), 'font': 'Montserrat'}));
    }
  }
  cmds.add(on(cover, b.shape('cvshade', 'rect', cw * 1.02, ch * 1.02, cw / 2 + cw * 0.01, 0, fill: '#000000')));
  cmds.add(b.setp(b.id('cvshade'), 'opacity', 0));

  // Inside of the cover + left page (appear as the cover turns over).
  final inside = b.id('inside');
  final tO = b.start + tOpen;
  cmds.addAll(b.nul('inside', 0, 0, parent: spine, name: 'Inside cover'));
  cmds.add(on(inside, b.shape('lboard', 'rect', cw * 1.02, ch * 1.02, -cw / 2 - cw * 0.01, ch * 0.005, fill: _shade(cCover, 0.7))));
  cmds.add(on(inside, b.shape('lpage', 'rect', cw * 0.985, ch * 0.975, -cw / 2, 0, fill: '#EFE8D6', fill2: '#F6F1E4')));
  cmds.add(b.fx(b.id('lpage'), 'paper', {'amount': 40}));
  cmds.add(on(inside, b.shape('gutter', 'rect', cw * 0.08, ch * 0.975, -cw * 0.04, 0, fill: '#26000000')));
  cmds.add(b.fx(b.id('gutter'), 'blur', {'amount': 12}));
  cmds.add(b.setp(inside, 'scale', [0.5, 100, 100]));
  cmds.add(b.setp(inside, 'opacity', 0));

  // Open: cover folds to the spine (0.2 s), inside unfolds (0.2 s); the spine glides to the centre.
  cmds.add(_evKf(cover, 'scale', tO, [100, 100, 100], 'ease_in'));
  cmds.add(_evKf(cover, 'scale', tO + 0.2, [1, 100, 100]));
  cmds.add(_evKf(cover, 'opacity', tO + 0.19, 100, 'hold'));
  cmds.add(_evKf(cover, 'opacity', tO + 0.2, 0));
  // A light shade only (55 % read as the cover flashing black).
  cmds.add(_evKf(b.id('cvshade'), 'opacity', tO + 0.08, 0, 'ease_in'));
  cmds.add(_evKf(b.id('cvshade'), 'opacity', tO + 0.2, 22));
  cmds.add(_evKf(inside, 'opacity', tO + 0.19, 0, 'hold'));
  cmds.add(_evKf(inside, 'opacity', tO + 0.2, 100));
  cmds.add(_evKf(inside, 'scale', tO + 0.2, [1, 100, 100], 'ease_out'));
  cmds.add(_evKf(inside, 'scale', tO + 0.4, [100, 100, 100]));
  cmds.add(_evKf(spine, 'position', tO, [-cw / 2, 0, 0], _evInOut));
  cmds.add(_evKf(spine, 'position', tO + 0.4, [0, 0, 0]));
  final so = _evSfx(b, 'paper', tO);
  if (so != null) cmds.add(so);

  // Page flips: a leaf folds to the spine and lands on the left.
  for (int k = 0; k < flips; k++) {
    final tf = b.start + flipAt[k];
    final leaf = 'leaf$k', back = 'leafb$k';
    cmds.addAll(b.nul(leaf, 0, 0, parent: spine, st: tf, du: 0.15, name: 'Page flip'));
    cmds.add(on(b.id(leaf), b.shape('${leaf}_p', 'rect', cw * 0.985, ch * 0.975, cw / 2, 0, fill: '#F4EEDF', fill2: '#E2D8C2'), tf, 0.15));
    cmds.add(_evKf(b.id(leaf), 'scale', tf, [100, 100, 100], 'ease_in'));
    cmds.add(_evKf(b.id(leaf), 'scale', tf + 0.125, [1, 100, 100]));
    final bt = tf + 0.125;
    cmds.addAll(b.nul(back, 0, 0, parent: spine, st: bt, du: b.end - bt, name: 'Page back'));
    cmds.add(on(b.id(back), b.shape('${back}_p', 'rect', cw * 0.985, ch * 0.975, -cw / 2, 0, fill: '#F1EBDC', fill2: '#F6F1E4'), bt, b.end - bt));
    final r = math.Random(_evSeed(b.id(back)));
    cmds.add(on(b.id(back), _evRings(b, '${back}_l', [
      for (int q = 0; q < 22; q++)
        [-cw / 2 - pw / 2, -phh / 2 + phh * (0.06 + q * 0.042), -cw / 2 - pw / 2 + pw * (q % 6 == 5 ? 0.4 + r.nextDouble() * 0.4 : 1.0), -phh / 2 + phh * (0.06 + q * 0.042)],
    ], stroke: '#A39B89', width: ch * 0.009), bt, b.end - bt));
    cmds.add(_evKf(b.id(back), 'scale', bt, [1, 100, 100], 'ease_out'));
    cmds.add(_evKf(b.id(back), 'scale', bt + 0.125, [100, 100, 100]));
    final sf = _evSfx(b, 'paper', tf);
    if (sf != null) cmds.add(sf);
  }

  // Enter.
  if (side) {
    cmds.add(_evKf(b.g, 'position', b.start, [x, y + h * 0.18, 0], _evBack));
    cmds.add(_evKf(b.g, 'position', b.start + 0.45, [x, y, 0]));
    cmds.add(_evKf(b.g, 'scale', b.start, [k0 * 0.2, k0 * 0.2, 100], _evBack));
    cmds.add(_evKf(b.g, 'scale', b.start + 0.45, [k0, k0, 100]));
  } else {
    cmds.add(_evKf(b.g, 'position', b.start, [x, y + h * 0.75, 0], _evBack));
    cmds.add(_evKf(b.g, 'position', b.start + 0.6, [x, y, 0]));
    cmds.add(b.fx(b.id('cv'), 'motion_blur', {'amount': 60}));
  }
  // Zoom into the right page (tilted a little).
  if (zoomTo) {
    final tz = b.start + tZoom;
    final a = tilt * math.pi / 180;
    final px = w / 2 - math.cos(a) * cw / 2, py = h / 2 - math.sin(a) * cw / 2;
    cmds.add(_evKf(b.g, 'position', tz, [x, y, 0], _evInOut));
    cmds.add(_evKf(b.g, 'position', tz + 0.8, [px, py, 0]));
    cmds.add(_evKf(b.g, 'scale', tz, [k0, k0, 100], _evInOut));
    cmds.add(_evKf(b.g, 'scale', tz + 0.8, [100, 100, 100]));
    cmds.add(_evKf(b.g, 'rotation', tz, [0, 0, 0], _evInOut));
    cmds.add(_evKf(b.g, 'rotation', tz + 0.8, [0, 0, tilt]));
    // Slow push while the marks play.
    cmds.add(_evKf(b.g, 'scale', b.end, [104, 104, 100]));
  }
  return _evFinish(b, cmds, enter: 'none', exit: null);
}

// ---------------------------------------------------------------- note_card

List<Map<String, dynamic>> _evNoteCard(_B b0) {
  final b = _evWithDur(b0, 4);
  final paper = b.str('paper', 'notebook');
  final cw = _evSize(b, 'width', 0.32, b.w, limit: 1);
  final ch = b.c['height'] is num ? _evSize(b, 'height', 0.4, b.h, limit: 1) : (paper == 'sticky' ? cw : cw * 1.25);
  final x = b.f('x', b.w * 0.5, b.w), y = b.f('y', b.h * 0.5, b.h);
  final tilt = b.n('tilt', -6);
  final text = b.str('text', 'PLAN');
  final cmds = b.group('Note Card', x: x, y: y, tilt: tilt);
  final k = cw * 0.11; // curl size
  final sheet = b.id('sheet');
  switch (paper) {
    case 'sticky':
      cmds.add(b.shape('sheet', 'rect', cw, ch, 0, 0, fill: '#FFE873', fill2: '#F5D545'));
      cmds.add(b.fx(sheet, 'shadow', {'distance': 16, 'angle': 80, 'blur': 22, 'opacity': 50}));
      cmds.add(b.fx(sheet, 'paper', {'amount': 35}));
      cmds.add(b.shape('glue', 'rect', cw, ch * 0.14, 0, -ch / 2 + ch * 0.07, fill: '#14000000'));
      break;
    case 'torn':
      cmds.add(b.shape('sheet', 'rect', cw, ch, 0, 0, fill: '#FBFAF4', fill2: '#EFEBDF'));
      cmds.add(b.fx(sheet, 'torn_edge', {'side': 'top', 'amount': 70}));
      cmds.add(b.fx(sheet, 'shadow', {'distance': 16, 'blur': 22, 'opacity': 50}));
      cmds.add(b.fx(sheet, 'paper', {'amount': 50}));
      break;
    default: // notebook: ruled lines, margin, punched holes, curled corner
      cmds.add(_evPoly(b, 'sheet', [[-cw / 2, -ch / 2], [cw / 2, -ch / 2], [cw / 2, ch / 2 - k], [cw / 2 - k, ch / 2], [-cw / 2, ch / 2]], '#FCFBF4'));
      cmds.add(b.fx(sheet, 'shadow', {'distance': 16, 'blur': 22, 'opacity': 50}));
      cmds.add(b.fx(sheet, 'paper', {'amount': 45}));
      final rule = <List<double>>[
        for (var ly = -ch / 2 + ch * 0.17; ly < ch / 2 - ch * 0.05; ly += ch * 0.075)
          [-cw / 2 + cw * 0.03, ly, cw / 2 - (ly > ch / 2 - k * 1.2 ? k * 1.1 : cw * 0.03), ly],
      ];
      cmds.add(_evRings(b, 'rule', rule, stroke: '#9DB7D9', width: math.max(1.5, ch * 0.004)));
      cmds.add(b.path('margin', [[-cw / 2 + cw * 0.15, -ch / 2], [-cw / 2 + cw * 0.15, ch / 2]], stroke: '#E58A8A', width: math.max(1.5, ch * 0.004)));
      for (int q = 0; q < 3; q++) {
        cmds.add(b.shape('hole$q', 'ellipse', cw * 0.04, cw * 0.04, -cw / 2 + cw * 0.065, -ch * 0.3 + q * ch * 0.3, fill: '#3B3B3B'));
      }
      cmds.add(_evPoly(b, 'curl', [[cw / 2 - k, ch / 2], [cw / 2, ch / 2 - k], [cw / 2 - k * 1.08, ch / 2 - k * 1.08]], '#E9E5D7'));
      cmds.add(b.fx(b.id('curl'), 'shadow', {'distance': 5, 'angle': 135, 'blur': 6, 'opacity': 45}));
  }
  final fs = b.c['size'] is num ? b.n('size', 0) : math.min(ch * 0.22, cw * 0.86 / math.max(1, text.length * 0.62));
  final t1 = b.start + 0.28;
  cmds.add({
    ...b.text('word', text.toUpperCase(), cw * 0.92, fs * 1.6, 0, ch * 0.04, fs, color: b.str('text_color', '#B3121E'), weight: 900),
    'font': b.str('font', 'Permanent Marker'), 'start': t1, 'duration': math.max(0.1, b.end - t1),
    'animator': b.str('animator', 'write_on'), 'anim_duration': b.n('write', 0.45),
  });
  if (b.str('enter', 'drop') == 'drop') {
    final g = b.n('glide', 0.15) * b.w;
    final dirs = {'right': [1.0, 0.0], 'left': [-1.0, 0.0], 'up': [0.0, -1.0], 'down': [0.0, 1.0]};
    final dv = dirs[b.str('glide_from', 'right')] ?? dirs['right']!;
    final sx = x + dv[0] * g, sy = y + dv[1] * g;
    cmds.add(_evKf(b.g, 'position', b.start, [sx, sy, 0], 'ease_in'));
    cmds.add(_evKf(b.g, 'position', b.start + 0.25, [sx - dv[0] * g * 0.15, sy - dv[1] * g * 0.15, 0], _evGlide));
    cmds.add(_evKf(b.g, 'position', b.start + 1.0, [x, y, 0]));
    cmds.add(_evKf(b.g, 'scale', b.start, [135, 135, 100], 'ease_in'));
    cmds.add(_evKf(b.g, 'scale', b.start + 0.25, [100, 100, 100]));
    cmds.add(_evKf(b.g, 'rotation', b.start, [0, 0, tilt + 7], 'ease_in'));
    cmds.add(_evKf(b.g, 'rotation', b.start + 0.25, [0, 0, tilt + 2], _evGlide));
    cmds.add(_evKf(b.g, 'rotation', b.start + 1.0, [0, 0, tilt]));
    cmds.add(_evKf(b.g, 'opacity', b.start, 0, 'ease_out'));
    cmds.add(_evKf(b.g, 'opacity', b.start + 0.1, 100));
    cmds.add(b.fx(sheet, 'motion_blur', {'amount': 50}));
    final s = _evSfx(b, 'paper', b.start + 0.2);
    if (s != null) cmds.add(s);
  }
  return _evFinish(b, cmds, enter: 'none', exit: null);
}

/// Paper sheet for list / handwrite cards (notebook | plain | torn | media).
List<Map<String, dynamic>> _evSheet(_B b, Project p, double cw, double ch, String paper) {
  final cmds = <Map<String, dynamic>>[];
  final sheet = b.id('sheet');
  final m = p.media[paper];
  if (m != null && m.type != MediaType.audio) {
    final s = math.max(cw / math.max(1, m.width), ch / math.max(1, m.height));
    cmds.add(b.media('sheet', m, 0, 0, widthPx: m.width * s));
    cmds.add({'op': 'add_mask', 'layer': sheet, 'shape': 'rect', 'center': [m.width / 2, m.height / 2], 'size': [cw / s, ch / s], 'feather': 0});
    cmds.add(b.fx(sheet, 'shadow', {'distance': 16, 'blur': 22, 'opacity': 50}));
    return cmds;
  }
  cmds.add(b.shape('sheet', 'rect', cw, ch, 0, 0, fill: '#FCFBF4', fill2: '#F1EDE1'));
  if (paper == 'torn') cmds.add(b.fx(sheet, 'torn_edge', {'side': 'top', 'amount': 60}));
  cmds.add(b.fx(sheet, 'shadow', {'distance': 16, 'blur': 22, 'opacity': 50}));
  cmds.add(b.fx(sheet, 'paper', {'amount': 50}));
  if (paper == 'notebook') {
    final gap = b.f('size', b.h * 0.042, b.h) * 1.5;
    cmds.add(_evRings(b, 'rule', [
      for (var ly = -ch / 2 + gap * 1.45; ly < ch / 2 - gap * 0.3; ly += gap) [-cw / 2 + cw * 0.03, ly, cw / 2 - cw * 0.03, ly],
    ], stroke: '#9DB7D9', width: math.max(1.5, ch * 0.0035)));
    cmds.add(b.path('margin', [[-cw / 2 + cw * 0.11, -ch / 2], [-cw / 2 + cw * 0.11, ch / 2]], stroke: '#E58A8A', width: math.max(1.5, ch * 0.0035)));
  }
  return cmds;
}

// ---------------------------------------------------------------- list_card

List<Map<String, dynamic>> _evListCard(_B b0, Project p) {
  final items = b0.specs('items', 'text');
  final fs = b0.f('size', b0.h * 0.042, b0.h);
  final cps = b0.n('write_cps', 16);
  final interval = b0.n('item_interval', 0.4);
  final writes = [for (final it in items) ('${it['text'] ?? ''}'.length / cps).clamp(0.3, 1.6).toDouble()];
  var tEnd = 0.5;
  for (final wv in writes) {
    tEnd += wv + interval;
  }
  final b = _evWithDur(b0, tEnd + 1.6);
  final cw = _evSize(b, 'width', 0.36, b.w, limit: 1);
  final title = b.str('title', '');
  final lineH = fs * 1.5;
  final pad = cw * 0.12;
  final rows = items.length + (title.isEmpty ? 0 : 1);
  final ch = b.c['height'] is num ? _evSize(b, 'height', 0.6, b.h, limit: 1) : math.max(cw * 0.9, lineH * (rows + 1.2) + pad);
  final x = b.f('x', b.w * 0.5, b.w), y = b.f('y', b.h * 0.5, b.h), tilt = b.n('tilt', -3);
  final cmds = b.group('List Card', x: x, y: y, tilt: tilt);
  cmds.addAll(_evSheet(b, p, cw, ch, b.str('paper', 'notebook')));
  final font = b.str('font', 'Kalam');
  final inkColor = b.str('ink', '#1C2B5A');
  final left = -cw / 2 + pad;
  final tw = cw - pad * 1.4;
  var rowY = -ch / 2 + lineH * 1.45 - fs * 0.35;
  var t = b.start + 0.5;
  final popScale = b.n('pop_scale', 1.6) * 100;
  if (title.isNotEmpty) {
    final id = b.id('title');
    cmds.add({
      ...b.text('title', title, tw, lineH, 0, rowY, fs * 1.1, color: b.str('title_color', '#B3121E'), weight: 700, align: 'left'),
      'font': font, 'start': b.start + 0.2, 'duration': math.max(0.1, b.end - b.start - 0.2), 'animator': 'write_on', 'anim_duration': 0.5,
    });
    cmds.add(b.setp(id, 'anchor', [0, lineH / 2, 0]));
    cmds.add(b.setp(id, 'position', [left, rowY, 0]));
    rowY += lineH;
    t += 0.3;
  }
  final bullet = b.str('bullet', '•');
  for (int i = 0; i < items.length; i++) {
    final it = items[i];
    final ti = it['at'] is num ? b.start + (it['at'] as num).toDouble() : t;
    final part = 'item$i';
    final id = b.id(part);
    final text = '${bullet.isEmpty ? '' : '$bullet '}${it['text'] ?? ''}';
    cmds.add({
      ...b.text(part, text, tw, lineH, 0, rowY, fs, color: '${it['color'] ?? inkColor}', weight: 700, align: 'left'),
      'font': font, 'start': ti, 'duration': math.max(0.1, b.end - ti), 'animator': 'write_on', 'anim_duration': writes[i],
    });
    cmds.add(b.setp(id, 'anchor', [0, lineH / 2, 0]));
    cmds.add(b.setp(id, 'position', [left, rowY, 0]));
    if (popScale != 100) {
      cmds.add(_evKf(id, 'scale', ti, [popScale, popScale, 100], _evExpoOut));
      cmds.add(_evKf(id, 'scale', ti + 0.3, [100, 100, 100]));
    }
    final s = _evSfx(b, 'pop', ti);
    if (s != null) cmds.add(s);
    rowY += lineH;
    t = ti + writes[i] + interval;
  }
  // Enter: rises in with a small turn.
  cmds.add(_evKf(b.g, 'position', b.start, [x, y + b.h * 0.12, 0], _evExpoOut));
  cmds.add(_evKf(b.g, 'position', b.start + 0.45, [x, y, 0]));
  cmds.add(_evKf(b.g, 'rotation', b.start, [0, 0, tilt + 4], _evExpoOut));
  cmds.add(_evKf(b.g, 'rotation', b.start + 0.45, [0, 0, tilt]));
  cmds.add(_evKf(b.g, 'opacity', b.start, 0, 'ease_out'));
  cmds.add(_evKf(b.g, 'opacity', b.start + 0.15, 100));
  final exit = b.str('exit', 'drop');
  if (exit == 'drop') {
    final t0 = math.max(t, b.end - 0.5);
    cmds.add(_evKf(b.g, 'position', t0, [x, y, 0], 'ease_in'));
    cmds.add(_evKf(b.g, 'position', b.end - 0.02, [x, y + b.h * 1.1, 0]));
    cmds.add(_evKf(b.g, 'rotation', t0, [0, 0, tilt], 'ease_in'));
    cmds.add(_evKf(b.g, 'rotation', b.end - 0.02, [0, 0, tilt + 14]));
    cmds.add(b.fx(b.id('sheet'), 'motion_blur', {'amount': 50}));
  }
  return _evFinish(b, cmds, enter: 'none', exit: exit == 'drop' || exit == 'none' ? null : exit);
}

// ----------------------------------------------------------- handwrite_card

List<Map<String, dynamic>> _evHandwriteCard(_B b0, Project p) {
  final text = b0.str('text', 'We will walk out of here.');
  final cps = math.max(1.0, b0.n('write_cps', 8));
  final write = text.length / cps;
  final pen = b0.mediaOf(p, 'pen');
  final b = _evWithDur(b0, 0.5 + write + (pen != null ? 0.5 : 0) + 1.5 + 0.3);
  final fs = b.f('size', b.h * 0.042, b.h);
  final cw = _evSize(b, 'width', 0.42, b.w, limit: 1);
  final pad = cw * 0.1;
  final tw = cw - pad * 2;
  final cpl = math.max(4, (tw / (fs * 0.47)).floor());
  final nLines = math.max(1, (text.length / cpl).ceil());
  final lineH = fs * 1.5;
  final ch = b.c['height'] is num ? _evSize(b, 'height', 0.5, b.h, limit: 1) : math.max(cw * 0.62, pad * 2 + nLines * lineH + fs);
  final x = b.f('x', b.w * 0.5, b.w), y = b.f('y', b.h * 0.5, b.h), tilt = b.n('tilt', -2);
  final cmds = b.group('Handwritten Note', x: x, y: y, tilt: tilt);
  cmds.addAll(_evSheet(b, p, cw, ch, b.str('paper', 'notebook')));
  final t1 = b.start + 0.5;
  final th = nLines * lineH + fs * 0.4;
  final top = -ch / 2 + pad + (b.str('paper', 'notebook') == 'notebook' ? lineH * 0.45 : 0);
  cmds.add({
    ...b.text('text', text, tw, th, 0, top + th / 2, fs, color: b.str('ink', '#1C2B5A'), weight: 700, align: 'left'),
    'font': b.str('font', 'Kalam'), 'start': t1, 'duration': math.max(0.1, b.end - t1), 'animator': 'write_on', 'anim_duration': math.max(0.2, write),
  });
  if (pen != null) {
    final ph = _evSize(b, 'pen_size', 0.3, b.h);
    final s = ph / math.max(1, pen.height) * 100;
    final tip = b.vec('pen_tip', [0.06, 0.94]);
    final id = b.id('pen');
    cmds.add({...b.media('pen', pen, 0, 0), 'scale': [s, s, 100], 'start': t1, 'duration': math.max(0.1, b.end - t1)});
    cmds.add(b.setp(id, 'anchor', [pen.width * tip[0], pen.height * tip[1], 0]));
    final left = -tw / 2;
    final r = math.Random(_evSeed(id));
    var tt = t1;
    for (int l = 0; l < nLines; l++) {
      final chars = math.min(cpl, text.length - l * cpl);
      final ly = top + l * lineH + fs * 0.85;
      final lineEnd = left + math.min(tw, chars * fs * 0.47);
      final dt = chars / cps;
      final steps = math.max(1, (dt / 0.18).round());
      for (int q = 0; q <= steps; q++) {
        final u = q / steps;
        final lastKey = l == nLines - 1 && q == steps;
        cmds.add(_evKf(id, 'position', tt + dt * u, [left + (lineEnd - left) * u, ly + (r.nextDouble() - 0.5) * fs * 0.25, 0],
            lastKey ? _evExpoIn : 'linear'));
      }
      tt += dt;
    }
    cmds.add(_evKf(id, 'position', tt + 0.45, [cw * 0.9, ch * 1.4, 0]));
  }
  cmds.add(_evKf(b.g, 'opacity', b.start, 0, 'ease_out'));
  cmds.add(_evKf(b.g, 'opacity', b.start + 0.3, 100));
  cmds.add(_evKf(b.g, 'position', b.start, [x, y + b.h * 0.05, 0], _evExpoOut));
  cmds.add(_evKf(b.g, 'position', b.start + 0.5, [x, y, 0]));
  final s = _evSfx(b, 'paper', b.start + 0.1);
  if (s != null) cmds.add(s);
  return _evFinish(b, cmds, enter: 'none', exit: null);
}

// --------------------------------------------------------------- quote_hole

List<Map<String, dynamic>> _evQuoteHole(_B b0, Project p) {
  final b = _evWithDur(b0, 6);
  final w = b.w, h = b.h;
  final hole = b.c['hole'] is Map ? Map<String, dynamic>.from(b.c['hole'] as Map) : const <String, dynamic>{};
  double hv(String k, double d) => (hole[k] as num?)?.toDouble() ?? d;
  final hw = hv('w', 0.55) * w, hh = hv('h', 0.4) * h;
  final hx = (hv('x', 0.5) - 0.5) * w, hy = (hv('y', 0.42) - 0.5) * h;
  final rough = hv('roughness', 60) / 60;
  final jag = hh * 0.025 * rough;
  final card = b.str('card_color', '#1F2B45');
  final cmds = b.group('Quote Card', x: w / 2, y: h / 2);
  cmds.add(b.shape('card', 'rect', w * 1.04, h * 1.04, 0, 0, fill: card, fill2: _shade(card, 0.7)));
  cmds.add(b.fx(b.id('card'), 'grunge', {'amount': 25}));
  final seed = _evSeed(b.id('hole'));
  cmds.add(_evPoly(b, 'rim', _evRagged(hx, hy, hw + jag * 4, hh + jag * 4, jag: jag * 1.4, step: hh * 0.025, seed: seed), '#E6E1D4'));
  cmds.add(b.fx(b.id('rim'), 'shadow', {'distance': 8, 'blur': 14, 'opacity': 55}));
  final matte = b.id('hole');
  cmds.add(_evPoly(b, 'hole', _evRagged(hx, hy, hw, hh, jag: jag, step: hh * 0.02, seed: seed + 1), '#FFFFFF'));
  final plate = b.mediaOf(p, 'plate') ?? b.mediaOf(p, 'media');
  final pid = b.id('plate');
  if (plate != null) {
    final s = math.max((hw + jag * 3) / math.max(1, plate.width), (hh + jag * 3) / math.max(1, plate.height)) * 100;
    cmds.add({...b.media('plate', plate, hx, hy), 'scale': [s, s, 100], 'matte': {'layer': matte, 'mode': 'alpha'}});
    cmds.add(_evKf(pid, 'scale', b.start, [s, s, 100], 'linear'));
    cmds.add(_evKf(pid, 'scale', b.end, [s * 1.05, s * 1.05, 100]));
  } else {
    cmds.add({...b.shape('plate', 'rect', hw + jag * 3, hh + jag * 3, hx, hy, fill: '#3A4460', fill2: '#141A28'), 'matte': {'layer': matte, 'mode': 'alpha'}});
  }
  final source = b.str('source', '');
  var ty = hy + hh / 2 + h * 0.07;
  if (source.isNotEmpty) {
    final fs = h * 0.034;
    cmds.add({
      ...b.text('source', source.toUpperCase(), w * 0.8, fs * 1.5, 0, ty, fs, color: b.str('source_color', '#DDF06A'), weight: 800),
      'font': 'Montserrat', 'start': b.start + 0.3, 'duration': math.max(0.1, b.dur - 0.3), 'animator': 'typewriter',
      'anim_duration': math.min(0.9, source.length * 0.035 + 0.1),
    });
    ty += fs * 1.6;
  }
  final body = b.str('body', '');
  if (body.isNotEmpty) {
    final fs = b.n('size', h * 0.04);
    final lines = math.max(1, (body.length * fs * 0.5 / (w * 0.78)).ceil());
    final bh = lines * fs * 1.3 + fs * 0.4;
    final marks = <Map<String, dynamic>>[];
    var d = 1.2;
    for (final hp in b.list('highlights')) {
      marks.add({'phrase': hp, 'style': 'highlight', 'delay': d, 'duration': 0.6, 'color': _evInk(b.str('mark_color', '#C8323A'), 0xD9)});
      d += 0.9;
    }
    cmds.add({
      ...b.text('body', body, w * 0.8, bh, 0, ty + bh / 2, fs, color: '#FFFFFF', weight: 600),
      'font': 'Playfair Display', 'start': b.start + 0.5, 'duration': math.max(0.1, b.dur - 0.5), 'animator': 'fade_up', 'anim_duration': 0.5,
      if (marks.isNotEmpty) 'marks': [for (final mk in marks) {...mk, 'delay': (mk['delay'] as double) - 0.5}],
    });
  }
  // Settle 104 → 100 %.
  cmds.add(_evKf(b.g, 'scale', b.start, [104, 104, 100], _evExpoOut));
  cmds.add(_evKf(b.g, 'scale', b.start + 0.3, [100, 100, 100]));
  cmds.add(_evKf(b.g, 'opacity', b.start, 0, 'ease_out'));
  cmds.add(_evKf(b.g, 'opacity', b.start + 0.12, 100));
  return _evFinish(b, cmds, enter: 'none', exit: null);
}

// --------------------------------------------------------------- source_tag

List<Map<String, dynamic>> _evSourceTag(_B b0, Project p) {
  final b = _evWithDur(b0, 3.5);
  final text = b.str('text', 'Source – example.com');
  final fs = b.f('size', b.h * 0.024, b.h);
  final pw = text.length * fs * 0.52 + fs * 1.8, ph = fs * 1.9;
  var x = b.f('x', b.w * 0.5, b.w), y = b.f('y', b.h * 0.88, b.h);
  final attach = b.c['attach'];
  if (attach is String) {
    final pt = _screenPointOf(p.editComp, attach, b.start, b.vec('at', [0.5, 1.0]));
    if (pt != null) {
      x = pt[0];
      y = pt[1] + ph * 0.9;
    }
  }
  final cmds = b.group('Source Tag', x: x, y: y, tilt: b.n('tilt', 0));
  final pill = b.id('pill');
  cmds.add(b.shape('pill', 'rect', pw, ph, 0, 0, fill: b.str('color', '#F2A6A6'), corner: ph / 2));
  cmds.add(b.fx(pill, 'shadow', {'distance': 4, 'blur': 8, 'opacity': 35}));
  cmds.add(b.setp(pill, 'anchor', [0, ph / 2, 0]));
  cmds.add(b.setp(pill, 'position', [-pw / 2, 0, 0]));
  cmds.add(_evKf(pill, 'scale', b.start, [0, 100, 100], _evExpoOut));
  cmds.add(_evKf(pill, 'scale', b.start + 0.35, [100, 100, 100]));
  final t1 = b.start + 0.15;
  cmds.add({
    ...b.text('text', text, pw, ph, 0, 0, fs, color: b.str('text_color', '#5A1414'), weight: 600),
    'font': b.str('font', 'Playfair Display'), 'start': t1, 'duration': math.max(0.1, b.end - t1), 'animator': 'fade_up', 'anim_duration': 0.3,
  });
  return _evFinish(b, cmds, enter: 'none', exit: 'fade');
}

// --------------------------------------------------------------- photo_card

bool _evPhotoWanted(Map<String, dynamic> c) =>
    const ['frame', 'backdrop', 'title', 'key_phrase', 'mono', 'reveal_prop', 'push'].any(c.containsKey);

List<Map<String, dynamic>> _evPhotoCard(_B b0, Project p) {
  final b = _evWithDur(b0, 5);
  final w = b.w, h = b.h;
  final m = b.mediaOf(p, 'media');
  final bg = b.str('backdrop', 'none');
  final cmds = <Map<String, dynamic>>[];
  if (bg != 'none') cmds.addAll(_evBackdrop(b, bg));
  final aspect = m == null ? 0.66 : m.height / math.max(1, m.width);
  var pw = _evSize(b, 'width', bg != 'none' ? 0.6 : 0.24, w, limit: 1);
  final title = b.str('title', ''), key = b.str('key_phrase', '');
  final maxH = h * (title.isEmpty && key.isEmpty ? 0.72 : 0.52);
  if (pw * aspect > maxH) pw = maxH / aspect;
  final ph = pw * aspect;
  final frame = b.str('frame', 'polaroid');
  final border = pw * (frame == 'white_border' ? 0.025 : 0.04);
  final caption = b.str('caption', '');
  final capH = caption.isEmpty || frame != 'polaroid' ? 0.0 : pw * 0.16;
  final fw = pw + border * 2, fh = ph + border * 2 + capH;
  final cy = (title.isNotEmpty ? h * 0.05 : 0.0) - (key.isNotEmpty ? h * 0.05 : 0.0);
  final cmds2 = b.group('Photo Card', tilt: b.n('tilt', frame == 'torn_white' ? -2 : -4));
  cmds.addAll(cmds2);
  final fr = b.id('frame');
  final seed = _evSeed(fr);
  switch (frame) {
    case 'torn_white':
      cmds.add(_evPoly(b, 'frame', _evRagged(0, cy, fw + border, fh + border, jag: border * 0.45, step: border * 0.45, seed: seed), '#F7F5EF'));
      break;
    case 'curl_corner':
    case 'white_border':
    default:
      cmds.add(b.shape('frame', 'rect', fw, fh, 0, cy, fill: '#FFFFFF', corner: border * 0.3));
  }
  cmds.add(b.fx(fr, 'shadow', {'distance': 18, 'blur': 22, 'opacity': 60}));
  if (frame != 'torn_white') cmds.add(b.fx(fr, 'paper', {'amount': 40}));
  final py = cy - fh / 2 + border + ph / 2;
  final photo = b.id('photo');
  if (m != null) {
    cmds.add(b.media('photo', m, 0, py, widthPx: pw));
  } else {
    cmds.add(b.shape('photo', 'rect', pw, ph, 0, py, fill: '#7A7A7A', fill2: '#3E3E3E'));
  }
  if (b.flag('mono', frame == 'torn_white')) {
    cmds.add(b.fx(photo, 'mono', {'amount': 100}));
    cmds.add(b.fx(photo, 'grain', {'amount': 25, 'size': 2}));
  }
  if (frame == 'curl_corner') {
    final k = pw * 0.12;
    final ex = fw / 2, ey = cy + fh / 2;
    cmds.add(_evPoly(b, 'curl', [[ex - k, ey], [ex, ey - k], [ex - k * 1.1, ey - k * 1.1]], '#ECE8DE'));
    cmds.add(b.fx(b.id('curl'), 'shadow', {'distance': 6, 'angle': 135, 'blur': 8, 'opacity': 50}));
  }
  if (capH > 0) {
    cmds.add(b.text('cap', caption, pw, capH, 0, cy + fh / 2 - capH / 2 - border * 0.3, capH * 0.5, color: '#1A1A1A', weight: 800));
  }
  if (title.isNotEmpty) {
    final fs = math.min(h * 0.08, w * 0.9 / math.max(1, title.length * 0.62));
    final t1 = b.start + 0.3;
    cmds.add({
      ...b.text('title', title.toUpperCase(), w * 0.92, fs * 1.4, 0, cy - fh / 2 - fs * 0.95, fs, color: '#FFFFFF', weight: 900),
      'font': 'Poppins', 'shadow': true, 'start': t1, 'duration': math.max(0.1, b.end - t1), 'animator': 'typewriter',
      'anim_duration': math.min(1.2, title.length * 0.045 + 0.1),
    });
  }
  if (key.isNotEmpty) {
    final fs = math.min(h * 0.12, w * 0.9 / math.max(1, key.length * 0.62));
    final t1 = b.start + 0.8;
    cmds.add({
      ...b.text('key', key.toUpperCase(), w * 0.94, fs * 1.4, 0, cy + fh / 2 + fs * 0.8, fs, color: b.str('key_color', '#2EE6E6'), weight: 900),
      'font': 'Poppins', 'shadow': true, 'start': t1, 'duration': math.max(0.1, b.end - t1),
      if (b.c['reveal_prop'] == null) 'animator': 'word_pop',
      if (b.c['reveal_prop'] == null) 'anim_duration': 0.4,
    });
  }
  final push = b.n('push', bg != 'none' ? 5 : 0);
  if (push > 0) {
    cmds.add(_evKf(b.g, 'scale', b.start, [100, 100, 100], 'linear'));
    cmds.add(_evKf(b.g, 'scale', b.end, [100 + push * b.dur / 4, 100 + push * b.dur / 4, 100]));
  }
  final s = _evSfx(b, 'shutter', b.start + 0.05);
  if (s != null) cmds.add(s);
  final out = _evFinish(b, cmds, enter: bg != 'none' ? 'fade_children' : 'slide_up', exit: bg != 'none' ? null : 'pop');
  final prop = b.c['reveal_prop'];
  if (prop is String && key.isNotEmpty) {
    out.add({
      'op': 'add_component', 'type': 'object_reveal', 'id': b.id('roll'), 'media': prop, 'reveals': [b.id('key')],
      'start': b.start + 0.8, 'duration': b.n('roll', 1.3), 'y': b.n('y', h / 2) + cy + fh / 2 + math.min(h * 0.12, w * 0.9 / math.max(1, key.length * 0.62)) * 0.8,
    });
  }
  return out;
}

// ------------------------------------------------------------ object_reveal

List<Map<String, dynamic>> _evObjectReveal(_B b0, Project p) {
  final b = _evWithDur(b0, 1.4);
  final comp = p.editComp;
  final m = b.mediaOf(p, 'media');
  final size = _evSize(b, 'size', 0.22, b.h);
  final y = b.f('y', b.h * 0.6, b.h);
  final path = b.str('path', 'roll_lr');
  final ltr = !path.endsWith('_rl');
  final roll = path.startsWith('roll');
  final xa = ltr ? -size : b.w + size, xb = ltr ? b.w + size : -size;
  final cmds = b.group('Object Reveal', x: xa, y: y);
  final obj = b.id('obj');
  if (m != null) {
    final s = size / math.max(1, math.max(m.width, m.height)) * 100;
    cmds.add({...b.media('obj', m, 0, 0), 'scale': [s, s, 100]});
  } else {
    cmds.add(b.shape('obj', 'ellipse', size, size, 0, 0, fill: '#2A2A2A', stroke: '#111111', strokeWidth: size * 0.12));
  }
  cmds.add(b.fx(obj, 'motion_blur', {'amount': 50}));
  cmds.add(_evKf(b.g, 'position', b.start, [xa, y, 0], 'linear'));
  cmds.add(_evKf(b.g, 'position', b.end, [xb, y, 0]));
  if (roll) {
    final turns = (xb - xa).abs() / (math.pi * size) * 360 * (ltr ? 1 : -1);
    cmds.add(_evKf(obj, 'rotation', b.start, [0, 0, 0], 'linear'));
    cmds.add(_evKf(obj, 'rotation', b.end, [0, 0, turns]));
  }
  // Each revealed layer is wiped on exactly where the object passes.
  for (final id in b.list('reveals')) {
    final l = comp.layerById(id);
    final box = _evScreenBox(comp, id, b.start + b.dur / 2);
    if (l == null || box == null) continue;
    double tAt(double sx) => b.start + ((sx - xa) / (xb - xa)).clamp(0.0, 1.0) * b.dur;
    final ta = tAt(ltr ? box[0] : box[2]), tb = tAt(ltr ? box[2] : box[0]);
    final mid = '${id}_reveal';
    final lh = l.height;
    if (ltr) {
      cmds.add({'op': 'add_mask', 'layer': id, 'id': mid, 'shape': 'rect', 'center': [-1, lh / 2], 'size': [1, lh * 3], 'feather': 0});
      cmds.add(_evMaskKf(id, mid, 'center', ta, [-1, lh / 2], 'linear'));
      cmds.add(_evMaskKf(id, mid, 'center', tb, [l.width / 2, lh / 2]));
    } else {
      cmds.add({'op': 'add_mask', 'layer': id, 'id': mid, 'shape': 'rect', 'center': [l.width + 1, lh / 2], 'size': [1, lh * 3], 'feather': 0});
      cmds.add(_evMaskKf(id, mid, 'center', ta, [l.width + 1, lh / 2], 'linear'));
      cmds.add(_evMaskKf(id, mid, 'center', tb, [l.width / 2, lh / 2]));
    }
    cmds.add(_evMaskKf(id, mid, 'size', ta, [1, lh * 3], 'linear'));
    cmds.add(_evMaskKf(id, mid, 'size', tb, [l.width, lh * 3]));
  }
  final s = _evSfx(b, 'whoosh', b.start + b.dur / 2);
  if (s != null) cmds.add(s);
  return cmds;
}

// --------------------------------------------------------------- photo_wall

List<Map<String, dynamic>> _evPhotoWall(_B b0, Project p) {
  final photos = b0.mediaList(p, 'photos');
  final n = photos.isEmpty ? 4 : photos.length;
  final dwell = math.max(0.6, b0.n('dwell', 2.5));
  final b = _evWithDur(b0, n * dwell + 0.4);
  final w = b.w, h = b.h;
  final cmds = <Map<String, dynamic>>[..._evBackdrop(b, b.str('bg', 'paper_grey'))];
  final whip = b.str('move', 'pan') == 'whip';
  final range = b.n('tilt_range', 8);
  final size = _evSize(b, 'size', 0.56, h);
  final rnd = math.Random(_evSeed(b.id('wall')));
  cmds.addAll(b.group('Photo Wall', x: 0, y: 0));
  final centres = <List<double>>[];
  for (int k = 0; k < n; k++) {
    final m = photos.isEmpty ? null : photos[k];
    final aspect = m == null ? 0.75 : m.height / math.max(1, m.width);
    final ph = aspect >= 1 ? size : size * 0.82;
    final pw = ph / aspect;
    final cx = w / 2 + k * w * 0.62, cy = h / 2 + (k.isEven ? -1 : 1) * h * 0.06;
    centres.add([cx, cy]);
    final tilt = (rnd.nextDouble() * 2 - 1) * range;
    final arrive = b.start + k * dwell;
    final card = 'card$k';
    cmds.addAll(b.nul(card, cx, cy, name: 'Wall photo ${k + 1}'));
    cmds.add(b.setp(b.id(card), 'rotation', [0, 0, tilt.abs() < 2 ? (tilt < 0 ? -2.5 : 2.5) : tilt]));
    if (b.c['splatter'] != false) {
      final sr = math.Random(_evSeed(b.id('$card-s')));
      final drops = <List<double>>[];
      for (int q = 0; q < 14; q++) {
        final a = sr.nextDouble() * 2 * math.pi, dist = (0.55 + sr.nextDouble() * 0.45) * math.max(pw, ph) * 0.75;
        final r = math.max(pw, ph) * (0.012 + sr.nextDouble() * 0.03);
        drops.add(_evFlat(_evBlob(math.cos(a) * dist, math.sin(a) * dist, r, r, n: 12, rough: 0.4, seed: sr.nextInt(1 << 30))));
      }
      drops.add(_evFlat(_evBlob(0, 0, pw * 0.68, ph * 0.66, rough: 0.9, seed: sr.nextInt(1 << 30))));
      final sp = b.id('${card}_ink');
      cmds.add({..._evRings(b, '${card}_ink', drops, fill: '#E6121212', closed: true), 'parent': b.id(card)});
      final ta = math.max(b.start, arrive - (k == 0 ? 0 : 0.1));
      cmds.add(_evKf(sp, 'scale', ta, [35, 35, 100], _evExpoOut));
      cmds.add(_evKf(sp, 'scale', ta + 0.45, [100, 100, 100]));
    }
    final border = pw * 0.035;
    cmds.add({...b.shape('${card}_frame', 'rect', pw + border * 2, ph + border * 2, 0, 0, fill: '#F8F7F2'), 'parent': b.id(card)});
    cmds.add(b.fx(b.id('${card}_frame'), 'shadow', {'distance': 16, 'blur': 20, 'opacity': 55}));
    final pid = b.id('${card}_photo');
    if (m != null) {
      cmds.add(b.media('${card}_photo', m, 0, 0, widthPx: pw, parent: b.id(card)));
    } else {
      cmds.add({...b.shape('${card}_photo', 'rect', pw, ph, 0, 0, fill: '#8A8A8A', fill2: '#4A4A4A'), 'parent': b.id(card)});
    }
    if (!(k == n - 1 && b.c['color_last'] != false)) {
      cmds.add(b.fx(pid, 'mono', {'amount': 100}));
      cmds.add(b.fx(pid, 'grain', {'amount': 20, 'size': 2}));
    }
    if (whip) {
      cmds.add(b.fx(pid, 'motion_blur', {'amount': 80}));
      cmds.add(b.fx(b.id('${card}_frame'), 'motion_blur', {'amount': 80}));
    }
  }
  // Camera: the wall moves so each photo sits in the centre for "dwell" seconds.
  final move = whip ? 0.28 : 0.9;
  final drift = w * 0.018;
  for (int k = 0; k < n; k++) {
    final px = w / 2 - centres[k][0], py = h / 2 - centres[k][1];
    final ta = b.start + k * dwell;
    final tl = k == n - 1 ? b.end : b.start + (k + 1) * dwell - move;
    cmds.add(_evKf(b.g, 'position', ta, [px + drift / 2, py, 0], 'linear'));
    cmds.add(_evKf(b.g, 'position', math.max(ta + 0.05, tl), [px - drift / 2, py, 0], whip ? _evWhip : _evInOut));
    final s = _evSfx(b, whip ? 'whoosh' : 'swoosh_short', tl + move / 2);
    if (k < n - 1 && s != null) cmds.add(s);
  }
  return cmds;
}

// -------------------------------------------------------------- stain/doodle

List<Map<String, dynamic>> _evStain(_B b0) {
  final b = _evWithDur(b0, 4);
  final size = _evSize(b, 'size', 0.45, b.h);
  final x = b.f('x', b.w / 2, b.w), y = b.f('y', b.h / 2, b.h);
  final color = b.str('color', '#D00010');
  final tones = b.n('tones', 2).round().clamp(1, 3);
  final grow = math.max(0.05, b.n('grow', 0.5));
  final rough = b.n('roughness', 70) / 100;
  final cmds = b.group('Stain', x: x, y: y);
  final rnd = math.Random(_evSeed(b.id('stain')));
  for (int k = 0; k < tones; k++) {
    final r = size / 2 * (1 - k * 0.3);
    final c = k == 0 ? _alpha(color, 0xC8) : _alpha(_shade(color, 1 - k * 0.28), 0xE6);
    final part = 'tone$k';
    final ox = (rnd.nextDouble() - 0.5) * r * 0.2, oy = (rnd.nextDouble() - 0.5) * r * 0.2;
    final rings = <List<double>>[_evFlat(_evBlob(ox, oy, r, r * (0.85 + rnd.nextDouble() * 0.25), rough: rough * 1.2, seed: rnd.nextInt(1 << 30)))];
    if (k == 0) {
      for (int q = 0; q < 10; q++) {
        final a = rnd.nextDouble() * 2 * math.pi, dist = r * (1.05 + rnd.nextDouble() * 0.5);
        final rr = r * (0.03 + rnd.nextDouble() * 0.07);
        rings.add(_evFlat(_evBlob(math.cos(a) * dist, math.sin(a) * dist, rr, rr, n: 12, rough: 0.5, seed: rnd.nextInt(1 << 30))));
      }
    }
    final id = b.id(part);
    cmds.add({..._evRings(b, part, rings, fill: c, closed: true)});
    cmds.add(b.fx(id, 'blur', {'amount': 2}));
    final t0 = b.start + k * 0.08;
    cmds.add(_evKf(id, 'scale', t0, [4, 4, 100], _evExpoOut));
    cmds.add(_evKf(id, 'scale', t0 + grow, [100, 100, 100]));
  }
  return _evFinish(b, cmds, enter: 'none', exit: null);
}

List<Map<String, dynamic>> _evDoodle(_B b0) {
  final draw = math.max(0.1, b0.n('draw', 2.0));
  final b = _evWithDur(b0, draw + 2);
  final color = b.str('color', '#FFFFFF');
  final width = b.n('width', 4);
  final jitter = b.c['jitter'] != false;
  final cmds = b.group('Doodle', x: 0, y: 0);
  final specs = <Map<String, dynamic>>[];
  for (final v in (b.c['paths'] as List? ?? const [])) {
    if (v is Map) {
      specs.add(Map<String, dynamic>.from(v));
    } else if (v is List) {
      specs.add({'points': v});
    }
  }
  if (specs.isEmpty) {
    specs.add({
      'points': [[b.w * 0.3, b.h * 0.6], [b.w * 0.45, b.h * 0.45], [b.w * 0.62, b.h * 0.5]],
      'arrow': true,
    });
  }
  final paths = <List<List<double>>>[];
  for (final s in specs) {
    final raw = [
      for (final q in (s['points'] as List? ?? const []))
        if (q is List && q.length >= 2) [(q[0] as num).toDouble(), (q[1] as num).toDouble()],
    ];
    paths.add(raw);
  }
  double len(List<List<double>> pts) {
    var l = 0.0;
    for (int i = 1; i < pts.length; i++) {
      l += math.sqrt(math.pow(pts[i][0] - pts[i - 1][0], 2) + math.pow(pts[i][1] - pts[i - 1][1], 2));
    }
    return l;
  }

  final total = paths.fold<double>(0, (a, pth) => a + len(pth));
  var t = b.start;
  final rnd = math.Random(_evSeed(b.id('doodle')));
  for (int i = 0; i < paths.length; i++) {
    var pts = paths[i];
    if (pts.length < 2) continue;
    if (jitter) {
      final out = <List<double>>[];
      for (int q = 0; q < pts.length; q++) {
        out.add([pts[q][0] + (rnd.nextDouble() - 0.5) * width * 0.8, pts[q][1] + (rnd.nextDouble() - 0.5) * width * 0.8]);
        if (q + 1 < pts.length) {
          final mx = (pts[q][0] + pts[q + 1][0]) / 2, my = (pts[q][1] + pts[q + 1][1]) / 2;
          out.add([mx + (rnd.nextDouble() - 0.5) * width * 1.6, my + (rnd.nextDouble() - 0.5) * width * 1.6]);
        }
      }
      pts = out;
    }
    final s = specs[i];
    final d = total <= 0 ? draw / paths.length : draw * len(paths[i]) / total;
    final part = 'p$i';
    final id = b.id(part);
    cmds.add(b.path(part, pts,
        stroke: '${s['color'] ?? color}', width: (s['width'] as num?)?.toDouble() ?? width, smooth: true, closed: s['closed'] == true,
        arrowEnd: s['arrow'] == true));
    cmds.add(_evKf(id, 'trim', t, [0, 0], _evPen));
    cmds.add(_evKf(id, 'trim', t + d, [0, 100]));
    t += d;
  }
  final rawStamp = b.c['stamp'];
  final stamps = rawStamp is Map
      ? [Map<String, dynamic>.from(rawStamp)]
      : (rawStamp is String ? [<String, dynamic>{'text': rawStamp}] : b.specs('stamp', 'text'));
  for (int i = 0; i < stamps.length; i++) {
    final st = stamps[i];
    final text = '${st['text'] ?? ''}';
    if (text.isEmpty) continue;
    final fs = (st['size'] as num?)?.toDouble() ?? b.h * 0.07;
    final at = st['at'] is num ? b.start + (st['at'] as num).toDouble() : b.start + draw * 0.6;
    cmds.add({
      ...b.text('stamp$i', text.toUpperCase(), text.length * fs * 0.8 + fs, fs * 1.5, (st['x'] as num?)?.toDouble() ?? b.w / 2,
          (st['y'] as num?)?.toDouble() ?? b.h * 0.2, fs, color: '${st['color'] ?? color}', weight: 900),
      'font': '${st['font'] ?? 'Permanent Marker'}', 'start': at, 'duration': math.max(0.1, b.end - at), 'animator': 'random_pop',
      'anim_duration': math.min(1.2, text.length * 0.08 + 0.2),
    });
  }
  return _evFinish(b, cmds, enter: 'none', exit: null);
}

// --------------------------------------------------------- labels (pattern 20)

/// Plain / printed label: small red role over a big heavy name, no box.
List<Map<String, dynamic>> _evPlainLabel(_B b0, Project p) {
  final b = _evWithDur(b0, 4);
  var x = b.f('x', b.w * 0.5, b.w), y = b.f('y', b.h * 0.3, b.h);
  final attach = b.c['attach'];
  if (attach is String) {
    final pt = _screenPointOf(p.editComp, attach, b.start, b.vec('at', [0.5, 0.12]));
    if (pt != null) {
      x = pt[0];
      y = pt[1];
    }
  }
  final printed = b.str('style', 'plain') == 'print';
  final name = b.str('name', b.str('text', 'NAME')).toUpperCase();
  final role = b.str('role', '').toUpperCase();
  final fs = b.f('size', b.h * 0.05, b.h);
  final on = b.c['on'];
  final parent = on is String && p.editComp.layerById(on) != null ? on : null;
  final cmds = b.group('Label', x: x, y: y, tilt: b.n('tilt', 0), parent: parent);
  final nw = math.max(fs * 3, name.length * fs * 0.64 + fs);
  cmds.add({
    ...b.text('name', name, nw, fs * 1.3, nw / 2, 0, fs, color: b.str('color', printed ? '#141414' : '#FFFFFF'), weight: 900, align: 'left'),
    'font': 'Poppins', 'shadow': !printed, 'animator': 'fade_up', 'anim_duration': 0.35,
  });
  if (role.isNotEmpty) {
    final rfs = fs * 0.42;
    final rw = math.max(rfs * 3, role.length * rfs * 0.66 + rfs);
    final t1 = b.start + 0.15;
    cmds.add({
      ...b.text('role', role, rw, rfs * 1.4, rw / 2, -fs * 0.62 - rfs * 0.55, rfs, color: b.str('role_color', '#D0202A'), weight: 800, align: 'left'),
      'font': 'Poppins', 'shadow': !printed, 'start': t1, 'duration': math.max(0.1, b.end - t1), 'animator': 'typewriter',
      'anim_duration': math.min(0.6, role.length * 0.04 + 0.1),
    });
  }
  if (printed) {
    cmds.add(b.setp(b.id('name'), 'opacity', 92));
    cmds.add(b.fx(b.id('name'), 'grunge', {'amount': 25}));
  }
  return _evFinish(b, cmds, enter: 'none', exit: b.c['exit'] is String ? null : 'fade');
}

/// Arrow label: ≈180° arc arrow drawing on (0.25 s) toward the target, small role
/// line over a big name, no circle, no box.
List<Map<String, dynamic>> _evArrowLabel(_B b0) {
  final b = _evWithDur(b0, 4);
  final to = b.vec('to', [b.w * 0.62, b.h * 0.42]);
  final from = b.vec('from', [b.w * 0.36, b.h * 0.62]);
  final color = b.str('color', '#FFFFFF');
  final sw = b.n('stroke_width', b.h * 0.005);
  final cmds = b.group('Arrow Label', x: 0, y: 0);
  final mx = (from[0] + to[0]) / 2, my = (from[1] + to[1]) / 2;
  final r = math.sqrt(math.pow(to[0] - from[0], 2) + math.pow(to[1] - from[1], 2)) / 2;
  final a0 = math.atan2(from[1] - my, from[0] - mx);
  final side = b.n('bend', 1) >= 0 ? 1.0 : -1.0;
  final sweep = b.n('sweep', 180) * math.pi / 180;
  final flat = b.n('flatten', 0.7);
  final pts = <List<double>>[];
  for (int i = 0; i <= 24; i++) {
    final a = a0 + side * sweep * i / 24;
    // Flatten the arc perpendicular to the chord.
    final ux = math.cos(a), uy = math.sin(a);
    final cx = math.cos(a0), cy = math.sin(a0);
    final along = ux * cx + uy * cy, perp = -ux * cy + uy * cx;
    final px = along * cx - perp * flat * cy, py = along * cy + perp * flat * cx;
    pts.add([mx + px * r, my + py * r]);
  }
  // Leave a gap at the target so the head does not cover it.
  final cut = math.max(2, (pts.length * 0.06).round());
  final arc = pts.sublist(1, pts.length - cut);
  final id = b.id('arrow');
  final t0 = b.start + 0.25;
  cmds.add(b.path('arrow', arc, stroke: color, width: sw, smooth: true, arrowEnd: true));
  cmds.add(_evKf(id, 'trim', t0, [0, 0], 'ease_out'));
  cmds.add(_evKf(id, 'trim', t0 + 0.25, [0, 100]));
  final name = b.str('name', b.str('text', '')).toUpperCase();
  final role = b.str('role', '').toUpperCase();
  final fs = b.f('size', b.h * 0.05, b.h);
  final above = from[1] - fs * 0.5;
  if (name.isNotEmpty) {
    final nw = math.max(fs * 3, name.length * fs * 0.64 + fs);
    cmds.add({
      ...b.text('name', name, nw, fs * 1.3, from[0], above - fs * 0.4, fs, color: b.str('name_color', '#FFFFFF'), weight: 900),
      'font': 'Poppins', 'shadow': true, 'animator': 'fade_up', 'anim_duration': 0.3,
    });
  }
  if (role.isNotEmpty) {
    final rfs = fs * 0.42;
    final rw = math.max(rfs * 3, role.length * rfs * 0.66 + rfs);
    cmds.add({
      ...b.text('role', role, rw, rfs * 1.4, from[0], above - fs * 1.15 - rfs * 0.4, rfs, color: b.str('role_color', '#FF3B30'), weight: 800),
      'font': 'Poppins', 'shadow': true, 'animator': 'typewriter', 'anim_duration': math.min(0.5, role.length * 0.04 + 0.1),
    });
  }
  return _evFinish(b, cmds, enter: 'none', exit: null);
}
// <<< V3-B
