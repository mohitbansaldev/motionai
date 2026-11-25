part of 'components.dart';

// V3-D: speech_bubble upgrade (documentary patterns 42 + 53).
//
//   speech_bubble {text | messages: [{text, at (s after start)}], style: comic|clean|radio,
//     tail_to: [x, y] | layer id, attach: layer id (follows it), x?, y?, width?, size?,
//     cps: 30 (typewriter letters/s, 0 = no typing), type_delay: 0.15, caps: true,
//     exit: pop|puff|fade|none, blink: period s | {period}, auto_fade: true, sound: false}
//
// White rounded bubble with a 2-3 px black outline and a tail that points at
// the speaker; pops 0 → 110 → 100 % in 0.2 s; black heavy caps typed in;
// messages swap in place; Comic Neue for the comic style.

List<Map<String, dynamic>> _bubbleV3(_B b0, Project p, Composition comp) {
  final c = b0.c;
  final style = '${c['style'] ?? 'comic'}'.toLowerCase();
  if (!const ['comic', 'clean', 'radio'].contains(style)) {
    throw ArgumentError('speech_bubble style must be comic, clean or radio (got "$style")');
  }
  final caps = c['caps'] != false;
  final cps = (c['cps'] as num?)?.toDouble() ?? 30;
  final typeDelay = (c['type_delay'] as num?)?.toDouble() ?? 0.15;
  // Messages (times relative to the bubble start).
  final msgs = <(String, double)>[];
  if (c['messages'] is List) {
    var auto = 0.0;
    for (final m in c['messages'] as List) {
      final text = m is Map ? '${m['text'] ?? ''}' : '$m';
      final at = m is Map && m['at'] is num ? (m['at'] as num).toDouble() : auto;
      msgs.add((text, at));
      auto = at + 0.6 + text.length / math.max(1.0, cps <= 0 ? 30 : cps) + 1.2;
    }
    msgs.sort((x, y) => x.$2.compareTo(y.$2));
  }
  if (msgs.isEmpty) msgs.add((b0.str('text', '"Quote"'), 0));
  String shown(String t) => caps ? t.toUpperCase() : t;
  double typeTime(String t) => cps <= 0 ? 0 : TextClusters.count(t) / cps;
  // Length: given, or until the last message has been read (+ hold).
  final autoDur = msgs.last.$2 + typeDelay + typeTime(msgs.last.$1) + 1.8;
  final dur = (c['duration'] as num?)?.toDouble() ?? (c['messages'] is List || c['auto_fade'] == true ? autoDur : 5.0);
  final b = _B(b0.w, b0.h, {...c, 'duration': dur}, b0.now, b0.root);
  final start = b.start, end = b.start + dur;

  // Size from the longest message.
  final w = b.f('width', b.w * 0.22, b.w);
  final fs = b.n('size', w * 0.085);
  var longest = 0;
  for (final (t, _) in msgs) {
    longest = math.max(longest, TextClusters.count(t));
  }
  final lines = math.max(1, (longest * fs * 0.62 / (w * 0.84)).ceil());
  final h = math.max(fs * 2.4, lines * fs * 1.25 + fs * 1.3);
  final outline = math.max(2.0, b.h / 1080 * 3);

  // Where it points: attach (follows a layer) / tail_to (point or layer).
  (double, double)? target;
  Layer? attach;
  if (c['attach'] is String) {
    attach = comp.layerById('${c['attach']}');
    if (attach == null) throw ArgumentError('speech_bubble attach: no layer "${c['attach']}"');
  }
  (double, double) topOf(Layer l) {
    final m = Evaluator.worldMatrix(comp, l, start);
    final v = projectPoint(m, l.width / 2, l.height * 0.08);
    return (v.x, v.y);
  }

  final tt = c['tail_to'];
  if (tt is List && tt.length >= 2 && tt[0] is num && tt[1] is num) {
    target = ((tt[0] as num).toDouble(), (tt[1] as num).toDouble());
  } else if (tt is String) {
    final l = comp.layerById(tt);
    if (l == null) throw ArgumentError('speech_bubble tail_to: no layer "$tt"');
    target = topOf(l);
  } else if (attach != null) {
    target = topOf(attach);
  }
  // Bubble centre: given, else up and to the side of the target, inside the frame.
  var cx = b.f('x', b.w / 2, b.w), cy = b.f('y', b.h / 2, b.h);
  if (target != null && c['x'] == null && c['y'] == null) {
    final side = target.$1 > b.w * 0.62 ? -1.0 : 1.0;
    cx = (target.$1 + side * (w * 0.45 + b.w * 0.04)).clamp(w / 2 + 12, b.w - w / 2 - 12).toDouble();
    cy = (target.$2 - h * 0.5 - fs * 2.6).clamp(h / 2 + 12, b.h - h / 2 - 12).toDouble();
  }
  // Group: optionally parented to the attach layer (position in its space,
  // scale compensated so the bubble keeps its size).
  final restScale = (c['scale'] as num?)?.toDouble() ?? 100;
  var gx = cx, gy = cy, gs = restScale;
  if (attach != null) {
    final m = Evaluator.worldMatrix(comp, attach, start);
    final inv = m.clone();
    if (inv.determinant().abs() > 1e-12) {
      inv.invert();
      final lp = projectPoint(inv, cx, cy);
      gx = lp.x;
      gy = lp.y;
      final ps = attach.prop(Props.scale).valueAt(start);
      gs = restScale * 100 / math.max(1.0, ps[0].abs());
    }
  }
  final cmds = <Map<String, dynamic>>[
    {
      'op': 'add_layer', 'type': 'null', 'id': b.g, 'name': 'Speech Bubble', 'start': start, 'duration': dur,
      'position': [gx, gy, 0], if (attach != null) 'parent': attach.id,
    },
    {'op': 'set_property', 'target': b.g, 'prop': 'anchor', 'value': [0, 0, 0]},
  ];
  final children = <String>[];

  // Tail (group-local; the group's screen scale is 1 at rest).
  final hw = w / 2, hh = h / 2;
  final tx = target == null ? -w * 0.32 : target.$1 - cx, ty = target == null ? hh + fs * 1.6 : target.$2 - cy;
  final vertical = tx.abs() / hw <= ty.abs() / hh;
  final double bx, by, px, py;
  if (vertical) {
    bx = (tx * 0.35).clamp(-hw * 0.6, hw * 0.6).toDouble();
    by = ty >= 0 ? hh - outline : -hh + outline;
    px = 1;
    py = 0;
  } else {
    bx = tx >= 0 ? hw - outline : -hw + outline;
    by = (ty * 0.35).clamp(-hh * 0.5, hh * 0.5).toDouble();
    px = 0;
    py = 1;
  }
  final dist = math.sqrt((tx - bx) * (tx - bx) + (ty - by) * (ty - by));
  final len = (dist - fs * 0.4).clamp(fs * 0.9, math.max(fs * 3.2, hh * 1.8)).toDouble();
  final ux = dist < 1e-6 ? 0.0 : (tx - bx) / dist, uy = dist < 1e-6 ? 1.0 : (ty - by) / dist;
  final tip = [bx + ux * len, by + uy * len];
  final bw = math.min((vertical ? hw : hh) * 0.3, fs * 0.75);
  List<List<double>> tri(double inset) => [
        [bx - px * (bw - inset) - ux * inset * 2, by - py * (bw - inset) - uy * inset * 2],
        [tip[0] - ux * inset * 1.6, tip[1] - uy * inset * 1.6],
        [bx + px * (bw - inset) - ux * inset * 2, by + py * (bw - inset) - uy * inset * 2],
      ];
  final fill = style == 'radio' ? '#F4F7FA' : '#FFFFFF';
  final ink = '#111111';
  final hasLine = style != 'clean';
  // Outline tail under the box, fill-only tail over the box edge (no seam).
  cmds.add(b.path('tail', tri(0), stroke: hasLine ? ink : 'none', width: hasLine ? outline : 0, fill: fill, closed: true));
  children.add(b.id('tail'));
  final box = b.shape('box', 'rect', w, h, 0, 0, fill: fill, stroke: hasLine ? ink : null, strokeWidth: hasLine ? outline : 0,
      corner: style == 'radio' ? fs * 0.35 : math.min(h / 2, fs * 1.1));
  if (style == 'radio') box['dash'] = [outline * 4, outline * 2.5];
  cmds.add(box);
  children.add(b.id('box'));
  if (style == 'clean') cmds.add(b.fx(b.id('box'), 'shadow', {'distance': 8, 'blur': 18, 'opacity': 35}));
  cmds.add(b.path('tailfill', tri(outline * 1.2), stroke: 'none', width: 0, fill: fill, closed: true));
  children.add(b.id('tailfill'));

  // Messages: typed in, swapped in place.
  final font = switch (style) { 'clean' => 'Poppins', 'radio' => 'Roboto Mono', _ => 'Comic Neue' };
  final weight = switch (style) { 'clean' => 900, 'radio' => 700, _ => 700 };
  final textIds = <String>[];
  for (int i = 0; i < msgs.length; i++) {
    final (t, at) = msgs[i];
    final s0 = start + at + (i == 0 ? typeDelay : 0.05);
    final s1 = i + 1 < msgs.length ? start + msgs[i + 1].$2 : end;
    if (s1 <= s0 + 0.05) continue;
    final part = msgs.length == 1 ? 'txt' : 'txt$i';
    final cmd = b.text(part, shown(t), w * 0.86, h, 0, 0, fs, color: ink, weight: weight);
    cmd['start'] = s0;
    cmd['duration'] = s1 - s0;
    cmd['font'] = font;
    final ty2 = typeTime(t);
    if (ty2 > 0) {
      cmd['animator'] = 'typewriter';
      cmd['anim_duration'] = ty2.clamp(0.05, 30.0).toDouble();
    } else {
      cmd['animator'] = 'none';
    }
    cmds.add(cmd);
    children.add(b.id(part));
    textIds.add(b.id(part));
  }

  // Pop in: 0 → 110 → 100 % in 0.2 s.
  cmds.add(b.kf(b.g, 'scale', start, [0, 0, 100], 'ease_out'));
  cmds.add(b.kf(b.g, 'scale', start + 0.13, [gs * 1.1, gs * 1.1, 100], 'easy_ease'));
  cmds.add(b.kf(b.g, 'scale', start + 0.2, [gs, gs, 100], 'easy_ease'));

  // Blink: the whole bubble flashes on/off every period.
  final bl = c['blink'];
  final period = bl is num ? bl.toDouble() : (bl is Map && bl['period'] is num ? (bl['period'] as num).toDouble() : 0.0);
  if (period > 0.05) {
    for (final id in children) {
      for (var t = start + 0.3; t < end - 0.4; t += period) {
        cmds.add(b.kf(id, 'opacity', t, 100, 'hold'));
        cmds.add(b.kf(id, 'opacity', t + period * 0.65, 0, 'hold'));
      }
      cmds.add(b.kf(id, 'opacity', math.max(start + 0.3, end - 0.4), 100, 'hold'));
    }
  }

  // Exit.
  final exit = c['exit'] is String ? '${c['exit']}' : (c['auto_fade'] == true ? 'fade' : 'pop');
  switch (exit) {
    case 'pop':
      cmds.add(b.kf(b.g, 'scale', end - 0.2, [gs, gs, 100], 'easy_ease'));
      cmds.add(b.kf(b.g, 'scale', end - 0.12, [gs * 1.1, gs * 1.1, 100], 'ease_in'));
      cmds.add(b.kf(b.g, 'scale', end - 0.02, [0, 0, 100], 'ease_in'));
    case 'puff':
      cmds.add(b.kf(b.g, 'scale', end - 0.25, [gs, gs, 100], 'ease_in'));
      cmds.add(b.kf(b.g, 'scale', end - 0.13, [0, 0, 100], 'ease_in'));
      final ps = math.max(w, h) * 1.7;
      cmds.add({
        'op': 'add_layer', 'type': 'solid', 'id': b.id('puff'), 'name': 'Bubble puff', 'color': '#00000000',
        'width': ps, 'height': ps, 'position': [cx, cy, 0], 'start': end - 0.25, 'duration': 0.3,
      });
      cmds.add(b.fx(b.id('puff'), 'puff', {'amount': 100}));
    case 'fade':
      for (final id in children) {
        cmds.add(b.kf(id, 'opacity', end - 0.35, 100, 'easy_ease'));
        cmds.add(b.kf(id, 'opacity', end - 0.02, 0, 'easy_ease'));
      }
    case 'none':
      break;
    default:
      throw ArgumentError('speech_bubble exit must be pop, puff, fade or none (got "$exit")');
  }

  if (c['sound'] == true) {
    cmds.add({'op': 'add_sfx', 'kind': style == 'radio' ? 'radio_crackle' : 'pop', 'time': start + 0.05});
    for (final id in textIds) {
      if (cps > 0) cmds.add({'op': 'add_sfx', 'kind': 'typewriter', 'layer': id});
    }
    if (exit == 'puff') cmds.add({'op': 'add_sfx', 'kind': 'puff', 'time': end - 0.2});
  }
  return cmds;
}
