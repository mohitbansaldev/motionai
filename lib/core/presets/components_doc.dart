part of 'components.dart';

// V1 documentary kit: name tags, labels, callouts, titles, posters, screens,
// icon streams, scanner beams, silhouette crowds, rolling tiles.

/// "#RRGGBB" → "#AARRGGBB" with the given alpha (0..255).
String _alpha(String color, int a) {
  var s = color.replaceFirst('#', '');
  if (s.length == 8) s = s.substring(2);
  if (s.length != 6) s = 'FFFFFF';
  return '#${a.clamp(0, 255).toInt().toRadixString(16).padLeft(2, '0').toUpperCase()}$s';
}

/// Darker (k < 1) or lighter (k > 1) version of "#RRGGBB".
String _shade(String color, double k) {
  var s = color.replaceFirst('#', '');
  if (s.length == 8) s = s.substring(2);
  final v = int.tryParse(s, radix: 16) ?? 0x888888;
  int ch(int shift) => (((v >> shift) & 0xFF) * k).round().clamp(0, 255).toInt();
  String hx(int x) => x.toRadixString(16).padLeft(2, '0');
  return '#${hx(ch(16))}${hx(ch(8))}${hx(ch(0))}'.toUpperCase();
}

/// Screen point inside a layer's box (fx, fy in 0..1) at time [t].
List<double>? _screenPointOf(Composition comp, String layerId, double t, List<double> at) {
  if (comp.layerById(layerId) == null) return null;
  bool inside(Layer l) {
    Layer? cur = l;
    for (int i = 0; i < 32 && cur != null; i++) {
      if (cur.id == layerId) return true;
      cur = cur.parentId == null ? null : comp.layerById(cur.parentId!);
    }
    return false;
  }

  double x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
  for (final it in Evaluator.evaluate(comp, t)) {
    if (!inside(it.layer)) continue;
    for (final c in it.corners()) {
      x0 = math.min(x0, c.x);
      y0 = math.min(y0, c.y);
      x1 = math.max(x1, c.x);
      y1 = math.max(y1, c.y);
    }
  }
  if (!x0.isFinite) return null;
  return [x0 + (x1 - x0) * at[0], y0 + (y1 - y0) * at[1]];
}

/// Name + role on a yellow highlight bar that sweeps in.
List<Map<String, dynamic>> _nameTag(_B b) {
  final name = b.str('name', 'Name Surname');
  final role = b.str('role', 'Role or title');
  final fs = b.n('size', b.h * 0.055);
  final cmds = b.group('Name Tag', x: b.n('x', b.w * 0.07), y: b.n('y', b.h * 0.76));
  final nw = math.max(fs * 3, name.length * fs * 0.6 + fs * 0.6);
  cmds.add({
    ...b.text('name', name, nw, fs * 1.3, nw / 2, 0, fs, color: b.str('name_color', '#FFFFFF'), weight: 900, align: 'left'),
    'shadow': true, 'animator': 'slide_up', 'anim_duration': 0.45,
  });
  if (role.isNotEmpty) {
    final rfs = fs * 0.52;
    final rw = role.length * rfs * 0.58 + rfs * 1.4;
    final rh = rfs * 1.7;
    final ry = fs * 0.62 + rh / 2 + fs * 0.12;
    final t1 = b.start + 0.3;
    final bar = b.id('bar');
    cmds.add({...b.shape('bar', 'rect', rw, rh, 0, ry, fill: b.str('color', '#FFD400')), 'start': t1, 'duration': b.end - t1});
    cmds.add(b.setp(bar, 'anchor', [0, rh / 2, 0]));
    cmds.add(b.kf(bar, 'scale', t1, [0, 100, 100], 'ease_out'));
    cmds.add(b.kf(bar, 'scale', t1 + 0.4, [100, 100, 100]));
    cmds.add({
      ...b.text('role', role, rw, rh, rw / 2, ry, rfs, color: b.str('role_color', '#111111'), weight: 800),
      'start': t1 + 0.2, 'duration': b.end - t1 - 0.2, 'animator': 'fade_up', 'anim_duration': 0.3,
    });
  }
  return b.finish(cmds, enter: 'none', exit: 'slide_left');
}

/// Black (or red) tag pinned to a point (or to a layer via "attach").
List<Map<String, dynamic>> _characterLabel(_B b, Project p) {
  var x = b.n('x', b.w * 0.5), y = b.n('y', b.h * 0.3);
  final attach = b.c['attach'];
  if (attach is String) {
    final pt = _screenPointOf(p.editComp /* PRECOMP (Agent L) */, attach, b.start, b.vec('at', [0.5, 0.12]));
    if (pt != null) {
      x = pt[0];
      y = pt[1];
    }
  }
  final text = b.str('text', 'NAME').toUpperCase();
  final fs = b.n('size', b.h * 0.028);
  final right = b.str('side', x > b.w * 0.7 ? 'left' : 'right') != 'left';
  final red = b.str('style', 'black') == 'red';
  final accent = b.str('color', '#E53935');
  final cmds = b.group('Character Label', x: x, y: y);
  final s = right ? 1.0 : -1.0;
  final tw = text.length * fs * 0.66 + fs * 1.6, th = fs * 1.9;
  final ex = s * fs * 2.6, ey = -fs * 2.4; // elbow of the leader line
  final tagX = ex + s * (fs * 0.3 + tw / 2);
  cmds.add(b.shape('dot', 'ellipse', fs * 0.55, fs * 0.55, 0, 0, fill: accent, stroke: '#FFFFFF', strokeWidth: fs * 0.12));
  final line = b.id('line');
  cmds.add(b.path('line', [[0, 0], [ex, ey], [ex + s * fs * 0.3, ey]], stroke: '#FFFFFF', width: fs * 0.12));
  cmds.add(b.kf(line, 'trim', b.start, [0, 0], 'ease_out'));
  cmds.add(b.kf(line, 'trim', b.start + 0.35, [0, 100]));
  final t1 = b.start + 0.3;
  cmds.add({...b.shape('tag', 'rect', tw, th, tagX, ey, fill: red ? accent : '#111111', corner: fs * 0.18), 'start': t1, 'duration': b.end - t1});
  cmds.add(b.fx(b.id('tag'), 'shadow', {'distance': 6, 'blur': 10, 'opacity': 55}));
  if (!red) {
    cmds.add({...b.shape('accent', 'rect', fs * 0.32, th, tagX - s * (tw / 2 - fs * 0.16), ey, fill: accent), 'start': t1, 'duration': b.end - t1});
  }
  cmds.add({
    ...b.text('label', text, tw, th, tagX + s * fs * 0.15, ey, fs, color: '#FFFFFF', weight: 900),
    'start': t1, 'duration': b.end - t1, 'animator': 'typewriter', 'anim_duration': math.min(0.8, text.length * 0.05 + 0.1),
  });
  if (b.flag('glow', false)) cmds.add(b.fx(b.id('label'), 'glow', {'amount': 60, 'radius': 14}));
  cmds.add({'op': 'animate_in', 'layer': b.id('tag'), 'preset': 'pop', 'duration': 0.3});
  return b.finish(cmds, enter: 'none');
}

/// Curved arrow drawing on towards a glowing circle.
List<Map<String, dynamic>> _arrowCallout(_B b) {
  final to = b.vec('to', [b.w * 0.62, b.h * 0.42]);
  final from = b.vec('from', [b.w * 0.3, b.h * 0.72]);
  final r = b.n('radius', b.h * 0.08);
  final color = b.str('color', '#FF3B30');
  final sw = b.n('stroke_width', b.h * 0.006);
  final cmds = b.group('Arrow Callout', x: 0, y: 0);
  final dx = to[0] - from[0], dy = to[1] - from[1];
  final len = math.max(1.0, math.sqrt(dx * dx + dy * dy));
  final endPt = [to[0] - dx / len * r * 1.2, to[1] - dy / len * r * 1.2];
  final bend = b.n('bend', 0.3);
  final mid = [(from[0] + endPt[0]) / 2 - (endPt[1] - from[1]) * bend, (from[1] + endPt[1]) / 2 + (endPt[0] - from[0]) * bend];
  final arrow = b.id('arrow');
  cmds.add(b.path('arrow', [from, mid, endPt], stroke: color, width: sw, smooth: true, arrowEnd: true));
  cmds.add(b.kf(arrow, 'trim', b.start + 0.1, [0, 0], 'ease_out'));
  cmds.add(b.kf(arrow, 'trim', b.start + 0.7, [0, 100]));
  final halo = b.id('halo');
  cmds.add({...b.shape('halo', 'ellipse', r * 2.3, r * 2.3, to[0], to[1], fill: _alpha(color, 0x38)), 'start': b.start + 0.55, 'duration': b.dur - 0.55});
  cmds.add(b.fx(halo, 'blur', {'amount': 18}));
  cmds.add(b.kf(halo, 'scale', b.start + 0.55, [60, 60, 100], 'ease_out'));
  cmds.add(b.kf(halo, 'scale', b.start + 1.1, [100, 100, 100]));
  final ring = b.id('ring');
  cmds.add(b.shape('ring', 'ellipse', r * 2, r * 2, to[0], to[1], fill: 'none', stroke: color, strokeWidth: sw));
  cmds.add(b.kf(ring, 'trim', b.start, [0, 0], 'hold'));
  cmds.add(b.kf(ring, 'trim', b.start + 0.55, [0, 0], 'ease_out'));
  cmds.add(b.kf(ring, 'trim', b.start + 1.05, [0, 100]));
  cmds.add(b.fx(ring, 'glow', {'amount': 75, 'radius': 18}));
  final text = b.str('text', '');
  if (text.isNotEmpty) {
    final fs = b.n('size', b.h * 0.04);
    final tw = math.max(fs * 4, text.length * fs * 0.6 + fs);
    cmds.add({...b.text('text', text, tw, fs * 1.4, from[0], from[1] + fs * 0.9, fs, color: '#FFFFFF', weight: 800), 'shadow': true, 'animator': 'fade_up'});
  }
  return b.finish(cmds, enter: 'none', exit: null);
}

/// Glowing bar over the eyes.
List<Map<String, dynamic>> _censorBar(_B b) {
  final bw = b.n('width', b.w * 0.16), bh = b.n('height', b.h * 0.04);
  final cmds = b.group('Censor Bar', x: b.n('x', b.w / 2), y: b.n('y', b.h * 0.38), tilt: b.n('rotation', 0));
  final glow = b.flag('glow', true);
  final bar = b.id('bar');
  cmds.add(b.shape('bar', 'rect', bw, bh, 0, 0,
      fill: b.str('color', '#0A0A0A'), stroke: b.str('glow_color', '#FF2D2D'), strokeWidth: glow ? bh * 0.08 : 0, corner: bh * 0.15));
  if (glow) cmds.add(b.fx(bar, 'glow', {'amount': 70, 'radius': 18}));
  cmds.add(b.kf(bar, 'scale', b.start, [0, 100, 100], 'ease_out'));
  cmds.add(b.kf(bar, 'scale', b.start + 0.2, [100, 100, 100]));
  final text = b.str('text', '');
  if (text.isNotEmpty) {
    cmds.add({...b.text('text', text.toUpperCase(), bw, bh, 0, 0, bh * 0.55, color: b.str('glow_color', '#FF2D2D'), weight: 900), 'start': b.start + 0.2, 'duration': b.dur - 0.2});
  }
  return b.finish(cmds, enter: 'none', exit: null);
}

/// Points of a gravestone outline (flat bottom, round top).
List<List<double>> _gravestone(double w, double h, double cx, double cy) {
  final r = w / 2;
  final top = cy - h / 2 + r;
  return [
    [cx - w / 2, cy + h / 2],
    [cx - w / 2, top],
    for (int i = 1; i < 24; i++) [cx + math.cos(math.pi + math.pi * i / 24) * r, top + math.sin(math.pi + math.pi * i / 24) * r],
    [cx + w / 2, top],
    [cx + w / 2, cy + h / 2],
  ];
}

/// Gravestone / plaque with engraved text.
List<Map<String, dynamic>> _plaque(_B b) {
  final pw = b.n('width', b.w * 0.26), ph = pw * 1.3;
  final style = b.str('style', 'stone');
  final colors = switch (style) {
    'bronze' => ['#A07C3C', '#5B4219', '#F6DE9C', '#3D2C10'],
    'wood' => ['#8A5A2E', '#4E3016', '#F3E2C0', '#2E1C0C'],
    _ => ['#A2A29C', '#5E5E5A', '#2B2B29', '#46463F'],
  };
  final cmds = b.group('Plaque', y: b.n('y', b.h * 0.55));
  cmds.add({...b.shape('ground', 'ellipse', pw * 1.5, pw * 0.16, 0, ph / 2, fill: '#66000000')});
  cmds.add(b.fx(b.id('ground'), 'blur', {'amount': 16}));
  final stone = b.id('stone');
  cmds.add({...b.path('stone', _gravestone(pw, ph, 0, 0), stroke: colors[3], width: pw * 0.012, fill: colors[0], closed: true), 'fill2': colors[1]});
  cmds.add(b.fx(stone, 'grunge', {'amount': 65}));
  cmds.add(b.fx(stone, 'shadow', {'distance': 14, 'blur': 20, 'opacity': 55}));
  cmds.add(b.path('inner', _gravestone(pw * 0.84, ph * 0.86, 0, ph * 0.04), stroke: _alpha(colors[3], 0xAA), width: pw * 0.01, closed: true));
  final fs = pw * 0.07;
  final ink = colors[2];
  final title = b.str('title', 'IN MEMORY OF');
  final name = b.str('name', 'NAME');
  final dates = b.str('dates', '1835 – 1902');
  final text = b.str('text', 'Rest in peace');
  cmds.add({...b.text('title', title.toUpperCase(), pw * 0.8, fs * 1.4, 0, -ph * 0.16, fs * 0.8, color: ink, weight: 700), 'font_family': 'serif'});
  cmds.add({...b.text('name', name, pw * 0.8, fs * 2.2, 0, -ph * 0.02, fs * 1.5, color: ink, weight: 900), 'font_family': 'serif'});
  cmds.add({...b.text('dates', dates, pw * 0.8, fs * 1.4, 0, ph * 0.12, fs, color: ink, weight: 700), 'font_family': 'serif'});
  if (text.isNotEmpty) {
    cmds.add({...b.text('epitaph', text, pw * 0.72, fs * 3, 0, ph * 0.27, fs * 0.8, color: ink, weight: 500), 'font_family': 'serif'});
  }
  return b.finish(cmds, enter: 'slide_up', exit: null);
}

/// One vintage poster (paper, border, title, picture, body, footer).
List<Map<String, dynamic>> _posterParts(_B b, Project p, String pre, String parent, Map<String, dynamic> spec, double x, double y, double tilt, double st) {
  final pw = (spec['width'] as num?)?.toDouble() ?? b.w * 0.3;
  final ph = pw * 1.42;
  final du = b.end - st;
  String k(String part) => pre.isEmpty ? part : '${pre}_$part';
  final cmds = <Map<String, dynamic>>[...b.nul(k('poster'), x, y, parent: parent, st: st, du: du, name: 'Poster')];
  final g = b.id(k('poster'));
  Map<String, dynamic> child(Map<String, dynamic> m) => {...m, 'parent': g, 'start': st, 'duration': du};
  if (tilt != 0) cmds.add(b.setp(g, 'rotation', [0, 0, tilt]));
  final paper = b.id(k('paper'));
  cmds.add(child(b.shape(k('paper'), 'rect', pw, ph, 0, 0, fill: '${spec['paper'] ?? '#E9DCBF'}', fill2: '#D3BE94')));
  cmds.add(b.fx(paper, 'paper', {'amount': 85}));
  cmds.add(b.fx(paper, 'grunge', {'amount': 45}));
  cmds.add(b.fx(paper, 'shadow', {'distance': 14, 'blur': 18, 'opacity': 55}));
  const ink = '#2A1A0E';
  cmds.add(child(b.shape(k('border'), 'rect', pw * 0.9, ph * 0.92, 0, 0, fill: 'none', stroke: ink, strokeWidth: pw * 0.008)));
  final title = '${spec['title'] ?? 'WANTED'}'.toUpperCase();
  final tfs = math.min(pw * 0.16, pw * 1.5 / math.max(4, title.length));
  cmds.add(child({...b.text(k('title'), title, pw * 0.86, tfs * 1.3, 0, -ph * 0.36, tfs, color: ink, weight: 900), 'font_family': 'serif'}));
  final sub = '${spec['subtitle'] ?? 'WORKERS FOR THE NEW WORLD'}'.toUpperCase();
  cmds.add(child({...b.text(k('sub'), sub, pw * 0.82, pw * 0.08, 0, -ph * 0.255, pw * 0.042, color: ink, weight: 700), 'font_family': 'serif'}));
  final mid = spec['media'];
  final m = mid is String ? p.media[mid] : null;
  if (m != null && m.type != MediaType.audio) {
    final sw = math.min(pw * 0.72, ph * 0.36 * m.width / math.max(1, m.height));
    final img = b.id(k('img'));
    cmds.add(child(b.media(k('img'), m, 0, -ph * 0.02, widthPx: sw)));
    cmds.add(b.fx(img, 'color', {'saturation': -70, 'contrast': 10}));
    cmds.add(b.fx(img, 'tint', {'color': [190, 150, 100], 'amount': 40}));
  } else {
    cmds.add(child(b.shape(k('img'), 'rect', pw * 0.62, ph * 0.32, 0, -ph * 0.02, fill: '#C9B48A', stroke: ink, strokeWidth: pw * 0.006)));
  }
  final body = '${spec['body'] ?? 'Apply at the harbour office. Good wages, free passage.'}';
  cmds.add(child({...b.text(k('body'), body, pw * 0.8, ph * 0.13, 0, ph * 0.23, pw * 0.042, color: ink, weight: 600), 'font_family': 'serif'}));
  final footer = '${spec['footer'] ?? 'REWARD'}'.toUpperCase();
  cmds.add(child({...b.text(k('footer'), footer, pw * 0.8, pw * 0.11, 0, ph * 0.37, pw * 0.075, color: ink, weight: 900), 'font_family': 'serif'}));
  cmds.add({'op': 'animate_in', 'layer': g, 'preset': 'pop', 'duration': 0.4});
  return cmds;
}

/// Vintage poster, or a collage of posters ("items").
List<Map<String, dynamic>> _poster(_B b, Project p) {
  final items = b.specs('items', 'title');
  final cmds = b.group('Poster');
  if (items.isEmpty) {
    cmds.addAll(_posterParts(b, p, '', b.g, {...b.c, 'width': b.n('width', b.w * 0.3)}, 0, 0, b.n('tilt', -3), b.start));
    return b.finish(cmds, enter: 'none');
  }
  final n = items.length;
  final pw = b.n('width', b.w * (n > 2 ? 0.24 : 0.3));
  const tilts = [-6.0, 4.0, -3.0, 7.0, -5.0];
  for (int i = 0; i < n; i++) {
    final x = (i - (n - 1) / 2) * pw * 0.82;
    final y = (i.isEven ? -1 : 1) * b.h * 0.04;
    cmds.addAll(_posterParts(b, p, 'p$i', b.g, {...items[i], 'width': pw}, x, y, tilts[i % tilts.length], b.start + i * 0.3));
  }
  return b.finish(cmds, enter: 'none');
}

/// Curved glossy glass screen on a carbon grid, light-leak sweeps hide cuts.
List<Map<String, dynamic>> _glassScreen(_B b, Project p) {
  final medias = b.mediaList(p, 'media');
  final sw = b.n('width', b.w * 0.62), sh = sw * 9 / 16;
  final bend = b.n('bend', 22);
  final color = b.str('color', '#FF8A1F');
  final cmds = <Map<String, dynamic>>[];
  if (b.flag('backdrop', true)) {
    cmds.add(b.backdrop('bg', '#141418', color2: '#050507', name: 'Carbon backdrop'));
    final step = b.h / 18;
    final grid = <List<double>>[
      for (double x = 0; x <= b.w; x += step) [x, 0, x, b.h],
      for (double y = 0; y <= b.h; y += step) [0, y, b.w, y],
    ];
    cmds.add({
      'op': 'add_layer', 'type': 'shape', 'id': b.id('grid'), 'name': 'Carbon grid', 'start': b.start, 'duration': b.dur,
      'rings': grid, 'closed': false, 'fill': 'none', 'stroke': '#22FFFFFF', 'stroke_width': 1,
    });
    cmds.add(b.fx(b.id('bg'), 'vignette', {'amount': 80}));
    cmds.add(b.fx(b.id('bg'), 'grain', {'amount': 18}));
  }
  cmds.addAll(b.group('Glass Screen'));
  final frame = b.id('frame');
  cmds.add(b.shape('frame', 'rect', sw * 1.04, sh * 1.07, 0, 0, fill: '#0D0D10', stroke: '#5A5A66', strokeWidth: sw * 0.004, corner: sw * 0.025));
  cmds.add(b.fx(frame, 'shadow', {'distance': 24, 'blur': 34, 'opacity': 70}));
  cmds.add(b.fx(frame, 'glass_frame', {'thickness': b.n('thickness', 18), 'gloss': b.n('gloss', 70)}));
  cmds.add(b.fx(frame, 'curve', {'bend': bend}));
  final cuts = <double>[];
  if (medias.isEmpty) {
    cmds.add(b.shape('content', 'rect', sw, sh, 0, 0, fill: '#1E3A5F', fill2: '#0B1424', corner: sw * 0.012));
    cmds.add(b.fx(b.id('content'), 'curve', {'bend': bend}));
  } else {
    final every = b.n('every', medias.length > 1 ? 1.6 : b.dur);
    var i = 0;
    for (var t = b.start; t < b.end - 0.05 && i < 60; t += every, i++) {
      final m = medias[i % medias.length];
      final s = math.max(sw / math.max(1, m.width), sh / math.max(1, m.height));
      final du = math.min(every, b.end - t);
      final id = b.id('c$i');
      cmds.add(b.media('c$i', m, 0, 0, widthPx: m.width * s, st: t, du: du));
      cmds.add({'op': 'add_mask', 'layer': id, 'shape': 'rect', 'center': [m.width / 2, m.height / 2], 'size': [sw / s, sh / s], 'feather': 0});
      cmds.add(b.fx(id, 'curve', {'bend': bend}));
      if (i > 0) cuts.add(t);
    }
  }
  cmds.add(b.path('gloss', [[-sw * 0.5, -sh * 0.5], [-sw * 0.18, -sh * 0.5], [-sw * 0.42, sh * 0.5], [-sw * 0.5, sh * 0.5]],
      fill: '#16FFFFFF', stroke: 'none', width: 0, closed: true));
  cmds.add(b.kf(b.g, 'scale', b.start, [100, 100, 100], 'linear'));
  cmds.add(b.kf(b.g, 'scale', b.end, [104, 104, 100]));
  // Light-leak sweeps on every cut and every couple of seconds.
  final sweepEvery = b.n('sweep_every', 1.6);
  final sweeps = <double>{...cuts};
  for (var t = b.start + sweepEvery; t < b.end - 0.3; t += sweepEvery) {
    if (!cuts.any((c) => (c - t).abs() < sweepEvery / 2)) sweeps.add(t);
  }
  var k = 0;
  for (final t in sweeps.toList()..sort()) {
    final id = b.id('leak$k');
    cmds.add({
      'op': 'add_layer', 'type': 'shape', 'id': id, 'name': 'Light leak', 'kind': 'rect', 'width': b.w * 0.32, 'height': b.h * 1.5,
      'fill': _alpha(color, 0xCC), 'fill2': _alpha(color, 0x00), 'start': t - 0.28, 'duration': 0.56, 'position': [-b.w * 0.3, b.h / 2, 0],
    });
    cmds.add(b.setp(id, 'rotation', [0, 0, 14]));
    cmds.add(b.fx(id, 'blur', {'amount': 60}));
    cmds.add(b.kf(id, 'position', t - 0.28, [-b.w * 0.3, b.h / 2, 0], 'linear'));
    cmds.add(b.kf(id, 'position', t + 0.28, [b.w * 1.3, b.h / 2, 0]));
    k++;
  }
  return b.finish(cmds, enter: 'zoom_out', exit: null);
}

/// Viral 3D intro: bokeh + streaks, slammed 3D title, random-pop subtitle,
/// dotted zigzag, flashes, impact sound fading to silence, music drop.
List<Map<String, dynamic>> _titleSlam(_B b, Project p) {
  final t0 = b.start;
  final drop = math.min(b.n('drop', 2.6), math.max(0.5, b.dur - 0.2));
  final cmds = <Map<String, dynamic>>[];
  cmds.add(b.backdrop('bg', b.str('color', '#6A0F1F'), color2: b.str('color2', '#1C0307')));
  cmds.add(b.fx(b.id('bg'), 'vignette', {'amount': 70}));
  cmds.addAll(b.atmos('bokeh', 'bokeh', amount: 45, speed: 0.4, color: '#FFB27A'));
  cmds.addAll(b.atmos('streaks', 'streaks', amount: 30, speed: 1.4, color: '#FFC94A', direction: 35));
  cmds.addAll(b.group('Title Slam', y: b.n('y', b.h * 0.46)));
  final title = b.str('title', 'VIRAL 3D').toUpperCase();
  final sub = b.str('subtitle', 'ANIMATION').toUpperCase();
  final fs = b.n('size', b.h * 0.17), sfs = fs * 0.62;
  cmds.add({
    ...b.text('title', title, b.w * 0.95, fs * 1.3, 0, -fs * 0.45, fs, color: b.str('title_color', '#FFFFFF'), weight: 900),
    'extrude': {'depth': fs * 0.09, 'color': b.str('edge_color', '#8C8C8C')},
  });
  final subId = b.id('sub');
  cmds.add({
    ...b.text('sub', sub, b.w * 0.95, sfs * 1.3, 0, fs * 0.5, sfs, color: b.str('subtitle_color', '#FFD21F'), weight: 900),
    'animator': 'random_pop', 'anim_duration': 0.6, 'start': t0 + 0.15, 'duration': b.end - t0 - 0.15,
  });
  cmds.add(b.fx(subId, 'glow', {'amount': 85, 'radius': 22}));
  final zw = math.min(b.w * 0.6, sub.length * sfs * 0.72), zy = fs * 0.5 + sfs * 0.9;
  final zig = b.id('zigzag');
  cmds.add({
    ...b.path('zigzag', [for (int i = 0; i <= 10; i++) [-zw / 2 + i * zw / 10, zy + (i.isEven ? -1 : 1) * sfs * 0.12]],
        stroke: '#FFFFFF', width: b.h * 0.007, dash: [b.h * 0.007, b.h * 0.012]),
    'start': t0 + 0.3, 'duration': b.end - t0 - 0.3,
  });
  cmds.add(b.kf(zig, 'trim', t0 + 0.3, [0, 0], 'ease_out'));
  cmds.add(b.kf(zig, 'trim', t0 + 1.0, [0, 100]));
  // Slam in, small shake, punch on the drop.
  final g = b.g, cx = b.n('x', b.w / 2), cy = b.n('y', b.h * 0.46);
  cmds.add(b.kf(g, 'scale', t0, [190, 190, 100], 'ease_out'));
  cmds.add(b.kf(g, 'scale', t0 + 0.22, [100, 100, 100], 'linear'));
  cmds.add(b.kf(g, 'scale', t0 + drop - 0.02, [100, 100, 100], 'ease_out'));
  cmds.add(b.kf(g, 'scale', t0 + drop + 0.12, [112, 112, 100]));
  cmds.add(b.kf(g, 'scale', t0 + drop + 0.45, [104, 104, 100]));
  const jitter = [[0.0, 0.0], [14.0, -8.0], [-10.0, 6.0], [6.0, 4.0], [0.0, 0.0]];
  for (int i = 0; i < jitter.length; i++) {
    cmds.add(b.kf(g, 'position', t0 + 0.22 + i * 0.045, [cx + jitter[i][0], cy + jitter[i][1], 0], 'linear'));
  }
  // Red light-leak sweep into the drop, then white flashes on top.
  final leak = b.id('leak');
  final l0 = t0 + drop - 0.5;
  cmds.add({
    'op': 'add_layer', 'type': 'shape', 'id': leak, 'name': 'Light leak', 'kind': 'rect', 'width': b.w * 0.5, 'height': b.h * 1.5,
    'fill': _alpha(b.str('leak_color', '#FF2A2A'), 0xCC), 'fill2': _alpha(b.str('leak_color', '#FF2A2A'), 0x00),
    'start': math.max(t0, l0), 'duration': 0.6, 'position': [-b.w * 0.3, b.h / 2, 0],
  });
  cmds.add(b.setp(leak, 'rotation', [0, 0, 15]));
  cmds.add(b.fx(leak, 'blur', {'amount': 60}));
  cmds.add(b.kf(leak, 'position', math.max(t0, l0), [-b.w * 0.3, b.h / 2, 0], 'linear'));
  cmds.add(b.kf(leak, 'position', math.max(t0, l0) + 0.55, [b.w * 1.3, b.h / 2, 0]));
  cmds.addAll(b.flashes('flash', [t0, t0 + drop]));
  // Sound: impact at 0 decaying to silence, music drops in.
  final hit = b.audioOf(p, 'hit', const ['SFX impact', 'SFX hit']);
  if (hit != null) {
    final id = b.id('hit');
    final len = hit.duration > 0 ? math.min(hit.duration, drop) : drop;
    cmds.add({'op': 'add_layer', 'type': 'audio', 'media': hit.id, 'id': id, 'name': 'Impact', 'start': t0, 'duration': len, 'index': 9999});
    cmds.add(b.kf(id, 'volume', t0, 100, 'ease_out'));
    cmds.add(b.kf(id, 'volume', t0 + math.min(2.4, len), 0));
  }
  final music = b.audioOf(p, 'music', const []);
  if (music != null) {
    final id = b.id('music');
    cmds.add({
      'op': 'add_layer', 'type': 'audio', 'media': music.id, 'id': id, 'name': 'Music (drop)', 'start': t0 + drop,
      'duration': music.duration > 0 ? music.duration : math.max(1.0, b.dur - drop), 'index': 9999,
    });
    cmds.add(b.setp(id, 'volume', b.n('music_volume', 90)));
  }
  return cmds;
}

/// A cut-out (tree, cloud, pillar…) sweeping past the lens; hides a cut at
/// start + at + length / 2.
List<Map<String, dynamic>> _foregroundWipe(_B b, Project p) {
  final m = b.mediaOf(p, 'media');
  final at = b.start + b.n('at', 0);
  final len = b.n('length', 0.7);
  final left = b.str('direction', 'left') != 'right';
  final y = b.n('y', b.h * 0.5);
  final id = b.id('wipe');
  final double iw;
  final Map<String, dynamic> layer;
  if (m != null) {
    final ih = b.h * b.n('size', 1.5);
    iw = m.width * ih / math.max(1, m.height);
    layer = b.media('wipe', m, 0, y, heightPx: ih, st: at, du: len)..remove('parent');
  } else {
    iw = b.w * 1.1;
    layer = {
      'op': 'add_layer', 'type': 'shape', 'id': id, 'kind': 'ellipse', 'width': iw, 'height': b.h * 1.7,
      'fill': '#0B100A', 'start': at, 'duration': len, 'position': [0, y, 0],
    };
  }
  final x0 = left ? b.w + iw / 2 : -iw / 2, x1 = left ? -iw / 2 : b.w + iw / 2;
  return [
    {...layer, 'name': 'Foreground wipe'},
    b.kf(id, 'position', at, [x0, y, 0], 'linear'),
    b.kf(id, 'position', at + len, [x1, y, 0]),
    b.fx(id, 'blur', {'amount': m == null ? 30 : 6}),
    b.fx(id, 'motion_blur', {'amount': 70}),
  ];
}

/// App-style icon: rounded square or circle, photo or glyph, gloss.
List<Map<String, dynamic>> _badgeParts(_B b, Project p, String pre, String parent, Map<String, dynamic> spec, double x, double y, double size, double st, double du) {
  String k(String part) => '${pre}_$part';
  final cmds = <Map<String, dynamic>>[...b.nul(k('icon'), x, y, parent: parent, st: st, du: du, name: 'Icon')];
  final g = b.id(k('icon'));
  Map<String, dynamic> child(Map<String, dynamic> m) => {...m, 'parent': g, 'start': st, 'duration': du};
  final circle = '${spec['shape'] ?? 'rounded'}' == 'circle';
  final color = '${spec['color'] ?? '#2E7DF6'}';
  final plate = b.id(k('plate'));
  cmds.add(child(b.shape(k('plate'), circle ? 'ellipse' : 'rect', size, size, 0, 0,
      fill: color, fill2: '${spec['color2'] ?? _shade(color, 0.55)}', corner: size * 0.22)));
  cmds.add(b.fx(plate, 'shadow', {'distance': size * 0.05, 'blur': size * 0.12, 'opacity': 50}));
  if (spec['glow'] == true) cmds.add(b.fx(plate, 'glow', {'amount': 60, 'radius': 18}));
  final mid = spec['media'];
  final m = mid is String ? p.media[mid] : null;
  if (m != null && m.type != MediaType.audio) {
    final inner = size * (circle ? 0.86 : 0.8);
    final sc = inner / math.max(1, math.min(m.width, m.height));
    final img = b.id(k('img'));
    cmds.add(child(b.media(k('img'), m, 0, 0, widthPx: m.width * sc)));
    cmds.add({'op': 'add_mask', 'layer': img, 'shape': circle ? 'ellipse' : 'rect', 'center': [m.width / 2, m.height / 2], 'size': [inner / sc, inner / sc], 'feather': 0});
  } else {
    final glyph = '${spec['text'] ?? spec['label'] ?? '★'}';
    final fs = size * (glyph.length <= 2 ? 0.5 : (glyph.length <= 4 ? 0.3 : 0.2));
    cmds.add(child(b.text(k('glyph'), glyph, size, size, 0, 0, fs, color: '${spec['text_color'] ?? '#FFFFFF'}', weight: 900)));
  }
  cmds.add(child(b.shape(k('gloss'), 'ellipse', size * 0.78, size * 0.36, 0, -size * 0.24, fill: '#2EFFFFFF')));
  if (circle) cmds.add(child(b.shape(k('ring'), 'ellipse', size, size, 0, 0, fill: 'none', stroke: '${spec['ring'] ?? '#FFFFFF'}', strokeWidth: size * 0.04)));
  return cmds;
}

List<Map<String, dynamic>> _iconBadge(_B b, Project p) {
  final size = b.n('size', b.h * 0.16);
  final cmds = b.group('Icon Badge');
  cmds.addAll(_badgeParts(b, p, 'b', b.g, b.c, 0, 0, size, b.start, b.dur));
  final label = b.str('label_below', '');
  if (label.isNotEmpty) {
    final fs = size * 0.16;
    cmds.add(b.text('caption', label, size * 2.4, fs * 1.6, 0, size * 0.5 + fs * 1.1, fs, color: '#FFFFFF', weight: 800));
  }
  return b.finish(cmds, enter: 'pop');
}

List<Map<String, dynamic>> _iconSpecs(_B b, Project p) {
  final raw = b.specs('icons', 'media');
  final out = [
    for (final s in raw)
      if (s['media'] is String && p.media[s['media']] == null) {...s, 'text': s['media']}..remove('media') else s,
  ];
  if (out.isNotEmpty) return out;
  return [
    {'text': '₹', 'color': '#2E7D32'},
    {'text': '\$', 'color': '#1565C0'},
    {'text': '€', 'color': '#6A1B9A'},
    {'text': '¥', 'color': '#C62828'},
  ];
}

/// Icons flowing along a curved path from A to B (Layer.path + path_progress).
List<Map<String, dynamic>> _iconStream(_B b, Project p) {
  final icons = _iconSpecs(b, p);
  final from = b.vec('from', [b.w * 0.12, b.h * 0.75]), to = b.vec('to', [b.w * 0.88, b.h * 0.3]);
  final bend = b.n('bend', 0.35);
  final dx = to[0] - from[0], dy = to[1] - from[1];
  final mid = [(from[0] + to[0]) / 2 + dy * bend, (from[1] + to[1]) / 2 - dx * bend];
  final count = b.n('count', 8).round().clamp(1, 60);
  final interval = b.n('interval', 0.35), travel = b.n('travel', 2.4);
  final size = b.n('size', b.h * 0.1);
  final shape = b.str('shape', 'rounded');
  final cmds = b.group('Icon Stream', x: 0, y: 0);
  for (int i = 0; i < count; i++) {
    final st = b.start + i * interval;
    if (st >= b.end - 0.1) break;
    final du = math.min(travel, b.end - st);
    final spec = {'shape': shape, ...icons[i % icons.length]};
    cmds.addAll(_badgeParts(b, p, 'i$i', b.g, spec, 0, 0, size, st, du));
    final gid = b.id('i${i}_icon');
    cmds.add({'op': 'update_layer', 'layer': gid, 'path': {'points': [from, mid, to], 'smooth': true, 'orient': false}});
    cmds.add(b.kf(gid, 'path_progress', st, 0, 'linear'));
    cmds.add(b.kf(gid, 'path_progress', st + travel, 100));
    cmds.add(b.kf(gid, 'scale', st, [40, 40, 100], 'ease_out'));
    cmds.add(b.kf(gid, 'scale', st + 0.3, [100, 100, 100], 'linear'));
    cmds.add(b.kf(gid, 'scale', st + travel - 0.3, [100, 100, 100], 'ease_in'));
    cmds.add(b.kf(gid, 'scale', st + travel, [40, 40, 100]));
  }
  return b.finish(cmds, enter: 'none', exit: null);
}

/// Cone beam from a logo swinging between targets; the targets are only
/// visible inside the beam (track matte), labels pop when it reaches them.
List<Map<String, dynamic>> _scanner(_B b, Project p) {
  final color = b.str('color', '#FF2D2D');
  final origin = b.vec('origin', [b.w * 0.5, b.h * 0.86]);
  var targets = b.specs('targets', 'label');
  if (targets.isEmpty) targets = [{'label': 'TARGET 1'}, {'label': 'TARGET 2'}, {'label': 'TARGET 3'}];
  final n = targets.length;
  final th = b.n('target_size', b.h * 0.3);
  final dwell = b.n('dwell', 1.0), swing = b.n('swing', 0.6);
  final cmds = b.group('Scanner', x: 0, y: 0);
  final matte = b.id('beam_matte');
  final pts = <List<double>>[];
  for (int i = 0; i < n; i++) {
    final s = targets[i];
    final x = (s['x'] as num?)?.toDouble() ?? b.w * (n == 1 ? 0.5 : 0.18 + 0.64 * i / (n - 1));
    final y = (s['y'] as num?)?.toDouble() ?? b.h * 0.34;
    pts.add([x, y]);
    final mid = s['media'];
    final m = mid is String ? p.media[mid] : null;
    final tid = b.id('t$i');
    if (m != null && m.type != MediaType.audio) {
      cmds.add(b.media('t$i', m, x, y, heightPx: th));
      cmds.add(b.fx(tid, 'mono', {'amount': 100}));
    } else {
      cmds.add(b.shape('t$i', 'ellipse', th * 0.62, th * 0.8, x, y, fill: '#9A9A9A', fill2: '#5A5A5A'));
    }
    cmds.add({'op': 'update_layer', 'layer': tid, 'matte': {'layer': matte, 'mode': 'alpha'}});
  }
  double angle(List<double> t) => math.atan2(t[1] - origin[1], t[0] - origin[0]) * 180 / math.pi;
  var far = 0.0;
  for (final t in pts) {
    far = math.max(far, math.sqrt(math.pow(t[0] - origin[0], 2) + math.pow(t[1] - origin[1], 2)));
  }
  final len = far * 1.25 + th * 0.5;
  final half = math.tan(b.n('beam_angle', 16) / 2 * math.pi / 180) * len;
  cmds.addAll(b.nul('rig', origin[0], origin[1], name: 'Beam rig'));
  final rig = b.id('rig');
  final cone = [[0.0, 0.0], [len, -half], [len, half]];
  cmds.add(b.path('beam', cone, parent: rig, fill: _alpha(color, 0x55), stroke: 'none', width: 0, closed: true));
  cmds.add(b.fx(b.id('beam'), 'glow', {'amount': 60, 'radius': 24}));
  cmds.add({...b.path('beam_matte', cone, parent: rig, fill: '#FFFFFF', stroke: 'none', width: 0, closed: true), 'name': 'Beam matte'});
  // Swing from target to target.
  var t = b.start + 0.2;
  cmds.add(b.kf(rig, 'rotation', t, [0, 0, angle(pts.first) - 30], 'easy_ease'));
  final arrive = <double>[];
  for (int i = 0; i < n; i++) {
    t += swing;
    arrive.add(t);
    cmds.add(b.kf(rig, 'rotation', t, [0, 0, angle(pts[i])], 'hold'));
    t += dwell;
    if (i < n - 1) cmds.add(b.kf(rig, 'rotation', t, [0, 0, angle(pts[i])], 'easy_ease'));
  }
  // Labels.
  final fs = b.n('label_size', b.h * 0.026);
  for (int i = 0; i < n; i++) {
    final label = '${targets[i]['label'] ?? ''}'.toUpperCase();
    if (label.isEmpty || arrive[i] >= b.end) continue;
    final tw = label.length * fs * 0.66 + fs * 1.4;
    final ly = pts[i][1] + th * 0.56;
    cmds.add({...b.shape('tag$i', 'rect', tw, fs * 1.8, pts[i][0], ly, fill: color, corner: fs * 0.2), 'start': arrive[i], 'duration': b.end - arrive[i]});
    cmds.add({...b.text('label$i', label, tw, fs * 1.8, pts[i][0], ly, fs, color: '#FFFFFF', weight: 900), 'start': arrive[i], 'duration': b.end - arrive[i]});
    cmds.add({'op': 'animate_in', 'layer': b.id('tag$i'), 'preset': 'pop', 'duration': 0.25});
  }
  final logoSize = b.n('logo_size', b.h * 0.13);
  cmds.addAll(_badgeParts(b, p, 'logo', b.g,
      {'shape': 'circle', 'media': b.c['logo'], 'text': b.str('logo_text', 'AI'), 'color': b.str('logo_color', '#1A1A1A'), 'ring': color, 'glow': true},
      origin[0], origin[1], logoSize, b.start, b.dur));
  return b.finish(cmds, enter: 'none', exit: null);
}

/// Cut-outs filled with one glowing colour rising in a stagger; one can stay
/// in colour (with a glowing eye bar); labels type on above them.
List<Map<String, dynamic>> _silhouetteCrowd(_B b, Project p) {
  final medias = b.mediaList(p, 'media');
  final count = b.n('count', medias.isEmpty ? 7 : math.max(medias.length, 5)).round().clamp(1, 30);
  final color = b.str('color', '#FFC107');
  final glow = b.n('glow', 60);
  final hgt = b.n('height', b.h * 0.5), base = b.n('y', b.h * 1.0);
  final stagger = b.n('stagger', 0.12), rise = b.n('rise', 0.6);
  final highlight = b.c['highlight'] is num ? (b.c['highlight'] as num).toInt() : -1;
  final labels = b.list('labels');
  final eye = b.vec('eye', [0.5, 0.14]);
  final cmds = b.group('Silhouette Crowd', x: 0, y: 0);
  final spacing = b.w * 0.92 / count;
  for (int i = 0; i < count; i++) {
    final x = b.w * 0.04 + spacing * (i + 0.5);
    final hi = hgt * (1 + 0.08 * ((i * 37) % 5 - 2) / 2);
    final st = b.start + i * stagger;
    final du = b.end - st;
    final rest = base - hi / 2, from = base + hi * 0.6;
    final fid = b.id('f$i');
    var fw = hi * 0.42;
    if (medias.isNotEmpty) {
      final m = medias[i % medias.length];
      fw = m.width * hi / math.max(1, m.height);
      cmds.add(b.media('f$i', m, x, rest, heightPx: hi, st: st, du: du));
      if (i != highlight) cmds.add(b.fx(fid, 'silhouette', {'color': color, 'glow': glow}));
    } else {
      final fill = i == highlight ? '#B0BEC5' : color;
      cmds.addAll(b.nul('f$i', x, rest, st: st, du: du, name: 'Figure'));
      cmds.add({...b.shape('f${i}_head', 'ellipse', hi * 0.22, hi * 0.26, 0, -hi * 0.37, fill: fill), 'parent': fid, 'start': st, 'duration': du});
      cmds.add({...b.shape('f${i}_body', 'rect', hi * 0.4, hi * 0.66, 0, hi * 0.16, fill: fill, corner: hi * 0.14), 'parent': fid, 'start': st, 'duration': du});
      if (i != highlight) {
        cmds.add(b.fx(b.id('f${i}_head'), 'glow', {'amount': glow, 'radius': 18}));
        cmds.add(b.fx(b.id('f${i}_body'), 'glow', {'amount': glow, 'radius': 18}));
      }
    }
    cmds.add(b.kf(fid, 'position', st, [x, from, 0], 'ease_out'));
    cmds.add(b.kf(fid, 'position', st + rise, [x, rest, 0]));
    if (i == highlight && b.c['eye_bar'] != false) {
      final bid = b.id('bar$i');
      final bx = x + (eye[0] - 0.5) * fw, by = (eye[1] - 0.5) * hi;
      cmds.add({
        ...b.shape('bar$i', 'rect', hi * 0.24, hi * 0.05, bx, rest + by, fill: '#0A0A0A', stroke: '#FF2D2D', strokeWidth: hi * 0.006, corner: hi * 0.01),
        'start': st, 'duration': du,
      });
      cmds.add(b.fx(bid, 'glow', {'amount': 75, 'radius': 16}));
      cmds.add(b.kf(bid, 'position', st, [bx, from + by, 0], 'ease_out'));
      cmds.add(b.kf(bid, 'position', st + rise, [bx, rest + by, 0]));
    }
    if (i < labels.length && labels[i].trim().isNotEmpty) {
      final fs = b.n('label_size', b.h * 0.03);
      final text = labels[i].trim().toUpperCase();
      final t1 = st + rise;
      if (t1 < b.end) {
        cmds.add({
          ...b.text('l$i', text, math.max(spacing, text.length * fs * 0.66 + fs), fs * 1.5, x, rest - hi / 2 - fs * 1.1, fs, color: b.str('label_color', '#FFFFFF'), weight: 900),
          'start': t1, 'duration': b.end - t1, 'animator': 'typewriter', 'anim_duration': math.min(0.7, text.length * 0.05 + 0.1),
        });
        cmds.add(b.fx(b.id('l$i'), 'glow', {'amount': 60, 'radius': 14}));
      }
    }
  }
  if (b.flag('confetti', false)) cmds.addAll(b.atmos('confetti', 'confetti', amount: 50, speed: 1));
  return b.finish(cmds, enter: 'none', exit: null);
}

/// Slot-machine characters rolling on tiles ("200 Y"), optional word after.
List<Map<String, dynamic>> _numberTiles(_B b) {
  final text = b.str('text', '200 Y');
  final fs = b.n('size', b.h * 0.15);
  final tw = fs * 0.82, th = fs * 1.2, gap = fs * 0.1;
  final roll = b.n('roll', 1.2), stagger = b.n('stagger', 0.12);
  final chars = text.split('');
  double width = 0;
  for (final ch in chars) {
    width += (ch == ' ' ? tw * 0.45 : tw) + gap;
  }
  width -= gap;
  final cmds = b.group('Rolling Tiles', y: b.n('y', b.h * 0.45));
  const digits = '0123456789';
  const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  var x = -width / 2;
  var i = 0;
  var lastStop = b.start;
  final lh = fs * 1.15;
  for (final ch in chars) {
    if (ch == ' ') {
      x += tw * 0.45 + gap;
      continue;
    }
    final cx = x + tw / 2;
    final tile = b.id('tile$i');
    cmds.add(b.shape('tile$i', 'rect', tw, th, cx, 0, fill: b.str('tile_color', '#2B2B2B'), fill2: b.str('tile_color2', '#111111'), corner: fs * 0.08));
    cmds.add(b.fx(tile, 'shadow', {'distance': 8, 'blur': 12, 'opacity': 60}));
    final glyphs = digits.contains(ch) ? digits : letters;
    final spins = b.n('spins', 8).round() + i * 2;
    final lines = [for (int k = 0; k < spins; k++) glyphs[(i * 7 + k * 3 + 1) % glyphs.length], ch.toUpperCase()];
    final n = lines.length;
    final rh = n * lh;
    final st = b.start + 0.1 + i * stagger, en = st + roll + i * 0.08;
    lastStop = math.max(lastStop, en);
    double yOf(int k) => -(k + 0.5) * lh + rh / 2;
    final reel = b.id('r$i');
    cmds.add({
      ...b.text('r$i', lines.join('\n'), tw, rh, cx, yOf(0), fs, color: b.str('text_color', '#FFFFFF'), weight: 900),
      'name': 'Reel $ch',
    });
    final win = '${reel}_win';
    cmds.add({'op': 'add_mask', 'layer': reel, 'id': win, 'shape': 'rect', 'center': [tw / 2, lh * 0.5], 'size': [tw * 0.98, th * 0.96], 'feather': 0});
    cmds.add(b.kf(reel, 'position', st, [cx, yOf(0), 0], 'ease_out'));
    cmds.add(b.kf(reel, 'position', en, [cx, yOf(n - 1), 0]));
    cmds.add({'op': 'set_keyframe', 'target': reel, 'mask': win, 'prop': 'center', 'time': st, 'value': [tw / 2, lh * 0.5], 'ease': 'ease_out'});
    cmds.add({'op': 'set_keyframe', 'target': reel, 'mask': win, 'prop': 'center', 'time': en, 'value': [tw / 2, (n - 0.5) * lh]});
    cmds.add(b.shape('split$i', 'rect', tw, fs * 0.014, cx, 0, fill: '#AA000000'));
    x += tw + gap;
    i++;
  }
  final word = b.str('word', '');
  if (word.isNotEmpty) {
    final wfs = fs * 0.7;
    final t1 = math.min(lastStop, b.end - 0.3);
    final id = b.id('word');
    cmds.add({
      ...b.text('word', word.toUpperCase(), word.length * wfs * 0.8 + wfs, wfs * 1.3, 0, th / 2 + wfs * 0.8, wfs, color: b.str('word_color', '#E8B84A'), weight: 900),
      'start': t1, 'duration': b.end - t1, 'shadow': true,
    });
    cmds.add(b.fx(id, 'glow', {'amount': 55, 'radius': 18}));
    cmds.add({'op': 'animate_in', 'layer': id, 'preset': 'pop', 'duration': 0.45});
  }
  return b.finish(cmds, enter: 'none');
}

/// Big serif date/year; a shooting streak flies in and lights it up.
List<Map<String, dynamic>> _dateTitle(_B b) {
  final text = b.str('text', '1831');
  final fs = b.n('size', b.h * 0.3);
  final color = b.str('color', '#F4E6C8');
  final cmds = b.group('Date Title');
  final streak = b.flag('streak', true);
  final t0 = b.start;
  final hit = streak ? t0 + 0.4 : t0;
  if (streak) {
    final sid = b.id('streak');
    cmds.add({
      ...b.path('streak', [[-b.w * 0.6, -b.h * 0.5], [0, 0]], stroke: b.str('streak_color', '#FFF1C4'), width: b.h * 0.006),
      'start': t0, 'duration': 0.5,
    });
    cmds.add(b.kf(sid, 'trim', t0, [0, 6], 'linear'));
    cmds.add(b.kf(sid, 'trim', hit, [94, 100], 'linear'));
    cmds.add(b.kf(sid, 'trim', hit + 0.05, [100, 100]));
    cmds.add(b.fx(sid, 'glow', {'amount': 80, 'radius': 16}));
    final burst = b.id('burst');
    cmds.add({...b.shape('burst', 'ellipse', fs * 0.3, fs * 0.3, 0, 0, fill: '#FFFFFF'), 'start': hit, 'duration': 0.4});
    cmds.add(b.kf(burst, 'scale', hit, [0, 0, 100], 'ease_out'));
    cmds.add(b.kf(burst, 'scale', hit + 0.3, [900, 900, 100]));
    cmds.add(b.kf(burst, 'opacity', hit, 100, 'linear'));
    cmds.add(b.kf(burst, 'opacity', hit + 0.35, 0));
    cmds.add(b.fx(burst, 'blur', {'amount': 30}));
  }
  final date = b.id('date');
  cmds.add({
    ...b.text('date', text, b.w * 0.9, fs * 1.25, 0, 0, fs, color: color, weight: 700),
    'font_family': b.str('font', 'serif'), 'start': hit, 'duration': b.end - hit, 'shadow': true,
  });
  cmds.add(b.fx(date, 'glow', {'amount': 45, 'radius': 26}));
  cmds.add(b.kf(date, 'scale', hit, [130, 130, 100], 'ease_out'));
  cmds.add(b.kf(date, 'scale', hit + 0.35, [100, 100, 100], 'linear'));
  cmds.add(b.kf(date, 'scale', b.end, [106, 106, 100]));
  final sub = b.str('subtitle', '');
  if (sub.isNotEmpty) {
    final sfs = fs * 0.17;
    final sw = sub.length * sfs * 0.6 + sfs * 1.5;
    final sy = fs * 0.62 + sfs;
    final t1 = hit + 0.4;
    final bar = b.id('bar');
    cmds.add({...b.shape('bar', 'rect', sw, sfs * 1.6, -sw / 2, sy, fill: b.str('bar_color', '#C62828')), 'start': t1, 'duration': b.end - t1});
    cmds.add(b.setp(bar, 'anchor', [0, sfs * 0.8, 0]));
    cmds.add(b.kf(bar, 'scale', t1, [0, 100, 100], 'ease_out'));
    cmds.add(b.kf(bar, 'scale', t1 + 0.35, [100, 100, 100]));
    cmds.add({
      ...b.text('sub', sub, sw, sfs * 1.6, 0, sy, sfs, color: '#FFFFFF', weight: 800),
      'start': t1 + 0.15, 'duration': b.end - t1 - 0.15, 'animator': 'fade_up', 'anim_duration': 0.35,
    });
  }
  return b.finish(cmds, enter: 'none');
}

/// Year ruler that slides under a fixed red marker and stops on the year.
List<Map<String, dynamic>> _yearRuler(_B b) {
  final from = b.n('from', 1930).round(), to = math.max(b.n('to', 1970).round(), from + 1);
  final step = math.max(1, b.n('step', 10).round());
  final marker = b.n('marker', (from + to) / 2);
  final fs = b.n('size', b.h * 0.03);
  final spacing = b.n('spacing', b.w * 0.16);
  final pxYear = spacing / step;
  final slide = b.n('slide', 2.2);
  final color = b.str('color', '#E53935');
  final cmds = b.group('Timeline', x: b.n('x', b.w / 2), y: b.n('y', b.h * 0.82));
  cmds.add(b.shape('band', 'rect', b.w * 1.3, fs * 4.4, 0, fs * 0.7, fill: '#B0000000'));
  cmds.addAll(b.nul('ruler', 0, 0, name: 'Ruler'));
  final ruler = b.id('ruler');
  final minor = step >= 5 ? step / 5 : 1.0;
  final major = <List<double>>[], small = <List<double>>[];
  final y0 = (from - step * 3).toDouble(), y1 = (to + step * 3).toDouble();
  var count = 0;
  for (var yr = y0; yr <= y1 + 1e-9 && count < 600; yr += minor, count++) {
    final x = (yr - from) * pxYear;
    final isMajor = ((yr - from) / step - ((yr - from) / step).roundToDouble()).abs() < 1e-6;
    (isMajor ? major : small).add([x, -fs * (isMajor ? 0.9 : 0.4), x, 0]);
  }
  cmds.add({...b.path('ticks', const [[0, 0], [1, 0]], parent: ruler), 'points': null, 'rings': major, 'stroke': '#FFFFFF', 'stroke_width': 3});
  cmds.add({...b.path('minor', const [[0, 0], [1, 0]], parent: ruler), 'points': null, 'rings': small, 'stroke': '#99FFFFFF', 'stroke_width': 2});
  var k = 0;
  for (var yr = from - step * 3; yr <= to + step * 3; yr += step) {
    cmds.add({...b.text('y${k++}', '$yr', fs * 4, fs * 1.4, (yr - from) * pxYear, fs * 1.1, fs * 0.9, color: '#E0E0E0', weight: 700), 'parent': ruler});
  }
  final t0 = b.start + 0.3, t1 = t0 + slide;
  cmds.add(b.kf(ruler, 'position', t0, [0, 0, 0], 'ease_out'));
  cmds.add(b.kf(ruler, 'position', t1, [-(marker - from) * pxYear, 0, 0]));
  // Fixed marker.
  cmds.add(b.path('needle', [[0, -fs * 1.6], [0, fs * 0.5]], stroke: color, width: 5));
  cmds.add(b.path('arrowhead', [[-fs * 0.45, -fs * 2.1], [fs * 0.45, -fs * 2.1], [0, -fs * 1.5]], fill: color, stroke: 'none', width: 0, closed: true));
  final label = b.str('label', '${marker.round()}');
  final pw = label.length * fs * 0.72 + fs * 1.5;
  final t2 = t1 - 0.1;
  final pill = b.id('pill');
  cmds.add({...b.shape('pill', 'rect', pw, fs * 1.8, 0, -fs * 3.2, fill: color, corner: fs * 0.3), 'start': t2, 'duration': b.end - t2});
  cmds.add({...b.text('date', label.toUpperCase(), pw, fs * 1.8, 0, -fs * 3.2, fs, color: '#FFFFFF', weight: 900), 'start': t2, 'duration': b.end - t2});
  cmds.add({'op': 'animate_in', 'layer': pill, 'preset': 'pop', 'duration': 0.3});
  cmds.add({'op': 'animate_in', 'layer': b.id('date'), 'preset': 'pop', 'duration': 0.3});
  return b.finish(cmds, enter: 'fade_children', exit: null);
}
