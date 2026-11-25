part of 'components.dart';

// Article highlight: a screenshot on torn paper, tilted, over a starry
// backdrop; long screenshots scroll; highlighter sweeps, hand-drawn circles,
// underlines and redaction bars (scrambling to a word) on given boxes;
// several screenshots can follow each other; "Coming up next" tag.
//
// Marks: {box: [x0, y0, x1, y1] (0..1 of the screenshot, top-left origin) or
// boxes: [[...], ...] (one per line), style: highlight|circle|underline|redact|box,
// delay (s after the page appears), duration, color, word (redact: the word
// the scramble settles on), item (which screenshot, default 0)}. Boxes come
// from the phrase finder (lib/ai/phrase_finder.dart) when only a phrase is known.

List<List<double>> _markBoxes(Map<String, dynamic> m) {
  List<double>? one(dynamic v) {
    if (v is List && v.length >= 4 && v.every((e) => e is num)) {
      final x0 = (v[0] as num).toDouble(), y0 = (v[1] as num).toDouble(), x1 = (v[2] as num).toDouble(), y1 = (v[3] as num).toDouble();
      return [
        math.min(x0, x1).clamp(0.0, 1.0), math.min(y0, y1).clamp(0.0, 1.0),
        math.max(x0, x1).clamp(0.0, 1.0), math.max(y0, y1).clamp(0.0, 1.0),
      ];
    }
    return null;
  }

  final out = <List<double>>[];
  final single = one(m['box']);
  if (single != null) out.add(single);
  for (final v in (m['boxes'] as List? ?? const [])) {
    final b = one(v);
    if (b != null) out.add(b);
  }
  return out;
}

List<Map<String, dynamic>> _article(_B b, Project p) {
  final items = b.mediaList(p, 'media');
  final cmds = <Map<String, dynamic>>[];
  final bg = b.str('backdrop', 'stars');
  if (bg != 'none') {
    cmds.add(b.backdrop('bg', b.str('bg', '#2A0E4F'), color2: b.str('bg2', '#0C0420')));
    cmds.add(b.fx(b.id('bg'), 'vignette', {'amount': 70}));
    if (bg == 'stars') cmds.addAll(b.atmos('stars', 'stars', amount: 45, speed: 0.3));
    if (bg == 'dust') cmds.addAll(b.atmos('dust', 'dust', amount: 40, speed: 0.4));
  }
  cmds.addAll(b.group('Article', tilt: b.n('tilt', -3)));
  cmds.add(b.kf(b.g, 'scale', b.start, [100, 100, 100], 'linear'));
  cmds.add(b.kf(b.g, 'scale', b.end, [100 + b.n('drift', 5), 100 + b.n('drift', 5), 100]));
  final n = math.max(1, items.length);
  final slot = b.dur / n;
  final marks = b.specs('marks', 'phrase');
  for (int i = 0; i < n; i++) {
    final st = b.start + i * slot;
    final du = i == n - 1 ? b.end - st : slot;
    cmds.addAll(_articlePage(b, i, items.isEmpty ? null : items[i], st, du,
        [for (final m in marks) if (((m['item'] as num?) ?? 0).toInt() == i) m], i == 0 ? b.str('enter', 'slide_up') : 'whip'));
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
    // The text is parented to the tag: its position is in the tag's own pixels.
    cmds.add(b.setp(b.id('next_text'), 'position', [tw / 2, fs * 0.95, 0]));
    cmds.add({'op': 'animate_in', 'layer': tag, 'preset': 'slide_right', 'duration': 0.45});
  }
  return cmds;
}

List<Map<String, dynamic>> _articlePage(_B b, int i, MediaAsset? m, double st, double du, List<Map<String, dynamic>> marks, String enter) {
  final pre = 'a$i';
  final pw = b.f('width', b.w * 0.5, b.w);
  final margin = pw * 0.04;
  final iw = pw - margin * 2;
  // Page content in its own pixels (mw × mh) shown at scale s.
  final double mw = m?.width ?? iw, mh = m?.height ?? iw * 1.3;
  final s = iw / math.max(1, mw);
  final ih = mh * s;
  final maxH = b.h * b.n('window', 0.8);
  final scroll = ih > maxH * 1.06 && b.c['scroll'] != false;
  final wh = scroll ? maxH : ih;
  final ph = wh + margin * 2;
  final cmds = <Map<String, dynamic>>[...b.nul('${pre}_page', 0, 0, st: st, du: du, name: 'Article page ${i + 1}')];
  final pg = b.id('${pre}_page');
  Map<String, dynamic> child(Map<String, dynamic> x) => {...x, 'parent': pg, 'start': st, 'duration': du};

  final paper = b.id('${pre}_paper');
  cmds.add(child(b.shape('${pre}_paper', 'rect', pw, ph, 0, 0, fill: b.str('paper', '#FBFAF5'))));
  final torn = b.str('torn', 'bottom');
  if (torn != 'none') {
    for (final side in torn == 'both' ? ['top', 'bottom'] : [torn]) {
      cmds.add(b.fx(paper, 'torn_edge', {'side': const ['top', 'bottom', 'left', 'right'].contains(side) ? side : 'bottom', 'amount': 60}));
    }
  }
  cmds.add(b.fx(paper, 'shadow', {'distance': 22, 'blur': 28, 'opacity': 60}));
  cmds.add(b.fx(paper, 'paper', {'amount': 35}));

  // Content: the screenshot, or a placeholder page with text lines.
  final cid = b.id('${pre}_img');
  double yCenter(double o) => -wh / 2 + ih / 2 - o;
  final y0 = scroll ? yCenter(0) : 0.0;
  // Children of the content (placeholder text lines) with their pixel origin
  // in content pixels: masks do not clip children, so they get the window too.
  final kids = <(String, double, double)>[];
  if (m != null) {
    cmds.add(child(b.media('${pre}_img', m, 0, y0, widthPx: iw)));
  } else {
    cmds.add(child(b.shape('${pre}_img', 'rect', mw, mh, 0, y0, fill: '#FFFFFF')));
    final head = <List<double>>[
      [mw * 0.06, mh * 0.07, mw * 0.9, mh * 0.07],
      [mw * 0.06, mh * 0.115, mw * 0.62, mh * 0.115],
    ];
    final body = <List<double>>[
      for (int j = 0; j < 16; j++) [mw * 0.06, mh * (0.2 + j * 0.045), mw * (j % 4 == 3 ? 0.6 : 0.94), mh * (0.2 + j * 0.045)],
    ];
    cmds.add({...b.path('${pre}_head', const [[0, 0], [1, 0]], parent: cid, st: st, du: du), 'points': null, 'rings': head, 'stroke': '#1A1A1A', 'stroke_width': mh * 0.022});
    cmds.add({...b.path('${pre}_lines', const [[0, 0], [1, 0]], parent: cid, st: st, du: du), 'points': null, 'rings': body, 'stroke': '#A0A0A0', 'stroke_width': mh * 0.012});
    // Same box placement as EditCommands' shape-from-points (pad = stroke × 3 + 8).
    kids.add((b.id('${pre}_head'), mw * 0.06 - (mh * 0.022 * 3 + 8), mh * 0.07 - (mh * 0.022 * 3 + 8)));
    kids.add((b.id('${pre}_lines'), mw * 0.06 - (mh * 0.012 * 3 + 8), mh * 0.2 - (mh * 0.012 * 3 + 8)));
  }
  for (final e in ['curve', 'edge_blur']) {
    if (b.c[e] is num) {
      final params = e == 'curve' ? {'bend': b.n(e, 0)} : {'amount': b.n(e, 0)};
      cmds.add(b.fx(paper, e, params));
      cmds.add(b.fx(cid, e, params));
    }
  }

  // Marks with their times, sorted by position for the scroll stops.
  final timed = <(Map<String, dynamic>, List<List<double>>, double)>[];
  var auto = 0.9;
  final sorted = [...marks]..sort((a, c) {
      final ba = _markBoxes(a), bc = _markBoxes(c);
      return (ba.isEmpty ? 0.0 : ba.first[1]).compareTo(bc.isEmpty ? 0.0 : bc.first[1]);
    });
  for (final mk in sorted) {
    final boxes = _markBoxes(mk);
    if (boxes.isEmpty) continue; // a phrase that was not located
    final delay = (mk['delay'] as num?)?.toDouble() ?? auto;
    auto = delay + 1.7;
    timed.add((mk, boxes, delay));
  }
  timed.sort((a, c) => a.$3.compareTo(c.$3));

  // Scroll: pan down long screenshots, stopping on each mark.
  final stops = <double>[]; // time each mark's scroll move starts (for mark end times)
  if (scroll) {
    final maxO = ih - wh;
    final win = '${cid}_window';
    cmds.add({'op': 'add_mask', 'layer': cid, 'id': win, 'shape': 'rect', 'center': [mw / 2, (wh / 2) / s], 'size': [mw * 1.02, wh / s], 'feather': 0});
    for (final (kid, ox, oy) in kids) {
      cmds.add({'op': 'add_mask', 'layer': kid, 'id': '${kid}_window', 'shape': 'rect', 'center': [mw / 2 - ox, (wh / 2) / s - oy], 'size': [mw * 1.02, wh / s], 'feather': 0});
    }
    void key(double t, double o, String ease) {
      cmds.add(b.kf(cid, 'position', t, [0, yCenter(o), 0], ease));
      cmds.add({'op': 'set_keyframe', 'target': cid, 'mask': win, 'prop': 'center', 'time': t, 'value': [mw / 2, (o + wh / 2) / s], 'ease': ease});
      for (final (kid, ox, oy) in kids) {
        cmds.add({'op': 'set_keyframe', 'target': kid, 'mask': '${kid}_window', 'prop': 'center', 'time': t, 'value': [mw / 2 - ox, (o + wh / 2) / s - oy], 'ease': ease});
      }
    }

    if (timed.isEmpty) {
      key(st + 0.6, 0, 'easy_ease');
      key(st + math.max(0.7, du - 0.3), maxO, 'easy_ease');
    } else {
      var lastT = st, lastO = 0.0;
      key(st, 0, 'easy_ease');
      for (final (_, boxes, delay) in timed) {
        final cy = (boxes.first[1] + boxes.last[3]) / 2;
        final o = (cy * ih - wh / 2).clamp(0.0, maxO);
        final arrive = st + delay - 0.05;
        final leave = math.max(lastT + 0.05, arrive - 0.9);
        stops.add(leave);
        if (arrive > leave + 0.05 && (o - lastO).abs() > 0.5) {
          key(leave, lastO, 'easy_ease');
          key(arrive, o, 'easy_ease');
          lastT = arrive;
          lastO = o;
        }
      }
    }
  }

  // Mark layers live inside the content, in its own pixels.
  final sw = b.h * 0.006 / s;
  for (int k = 0; k < timed.length; k++) {
    final (mk, boxes, delay) = timed[k];
    final t1 = st + delay;
    if (t1 >= st + du - 0.05) continue;
    var t2 = st + du;
    if (scroll && k + 1 < stops.length) t2 = math.min(t2, stops[k + 1] + 0.35);
    final style = '${mk['style'] ?? 'highlight'}';
    final dm = (mk['duration'] as num?)?.toDouble() ?? (style == 'circle' ? 0.6 : 0.5);
    final colorDefault = switch (style) { 'highlight' => '#8CFFE14D', 'redact' => '#111111', _ => '#E53935' };
    final color = '${mk['color'] ?? colorDefault}';
    for (int j = 0; j < boxes.length; j++) {
      final bx = boxes[j];
      final x0 = bx[0] * mw, y0b = bx[1] * mh, x1 = bx[2] * mw, y1 = bx[3] * mh;
      final bw = math.max(2.0, x1 - x0), bh = math.max(2.0, y1 - y0b);
      final cx = (x0 + x1) / 2, cy = (y0b + y1) / 2;
      final part = '${pre}_m${k}_$j';
      final id = b.id(part);
      final lt = t1 + j * dm * 0.8; // multi-line marks run line after line
      Map<String, dynamic> inContent(Map<String, dynamic> x) => {...x, 'parent': cid, 'start': lt, 'duration': math.max(0.1, t2 - lt)};
      switch (style) {
        case 'underline':
          final y = y1 + bh * 0.18;
          cmds.add(inContent(b.path(part, [[x0, y], [cx, y + bh * 0.06], [x1, y - bh * 0.03]], stroke: color, width: sw * 1.2, smooth: true)));
          cmds.add(b.kf(id, 'trim', lt, [0, 0], 'ease_out'));
          cmds.add(b.kf(id, 'trim', lt + dm, [0, 100]));
          break;
        case 'circle':
          final rx = bw / 2 + bh * 0.5, ry = bh / 2 + bh * 0.45;
          final pts = <List<double>>[
            for (int q = 0; q <= 26; q++)
              () {
                final a = (-100 + q * 400 / 26) * math.pi / 180;
                final r = 1 + 0.04 * math.sin(3 * a) + 0.05 * q / 26;
                return [cx + math.cos(a) * rx * r, cy + math.sin(a) * ry * r];
              }(),
          ];
          cmds.add(inContent(b.path(part, pts, stroke: color, width: sw * 1.1, smooth: true)));
          cmds.add(b.kf(id, 'trim', lt, [0, 0], 'ease_out'));
          cmds.add(b.kf(id, 'trim', lt + dm, [0, 100]));
          break;
        case 'box':
          cmds.add(inContent(b.shape(part, 'rect', bw * 1.06, bh * 1.3, cx, cy, fill: 'none', stroke: color, strokeWidth: sw)));
          cmds.add(b.kf(id, 'trim', lt, [0, 0], 'ease_out'));
          cmds.add(b.kf(id, 'trim', lt + dm, [0, 100]));
          break;
        case 'redact':
          cmds.add(inContent(b.shape(part, 'rect', bw * 1.04, bh * 1.2, x0 - bw * 0.02, cy, fill: color)));
          cmds.add(b.setp(id, 'anchor', [0, bh * 0.6, 0]));
          cmds.add(b.kf(id, 'scale', lt, [0, 100, 100], 'ease_out'));
          cmds.add(b.kf(id, 'scale', lt + 0.25, [100, 100, 100]));
          final word = '${mk['word'] ?? ''}';
          if (word.isNotEmpty && j == 0) {
            final wt = lt + 0.3;
            cmds.add({
              ...b.text('${part}_w', word, bw * 1.04, bh * 1.2, cx, cy, bh * 0.78, color: '${mk['word_color'] ?? '#FFFFFF'}', weight: 800),
              'parent': cid, 'start': wt, 'duration': math.max(0.1, t2 - wt), 'animator': 'scramble', 'anim_duration': 0.8, 'font_family': 'monospace',
            });
          }
          break;
        default: // highlight
          cmds.add(inContent(b.shape(part, 'rect', bw * 1.04, bh * 1.25, x0 - bw * 0.02, cy, fill: color, corner: bh * 0.1)));
          cmds.add(b.setp(id, 'anchor', [0, bh * 0.625, 0]));
          cmds.add(b.kf(id, 'scale', lt, [0, 100, 100], 'ease_out'));
          cmds.add(b.kf(id, 'scale', lt + dm, [100, 100, 100]));
      }
    }
  }
  if (enter != 'none') cmds.add({'op': 'animate_in', 'layer': pg, 'preset': enter, 'duration': 0.5});
  return cmds;
}
