part of 'components.dart';

// V3-C >>> DATA, HUD & OVERLAYS (docs/EDIT_COMMANDS.md "V3-C"): unit charts,
// people tallies, stat figures, calendars, clock/date stamps, clock overlays,
// split screens, gauge HUDs, icon stickers/drops, social call-outs, toggles,
// audio waves, flag badges, presenter stats, info cards and stat titles.

const _dataHudTypes = [
  'unit_chart', 'people_grid', 'stat_figure', 'calendar_flip', 'clock_stamp', 'clock_overlay', 'split_screen', 'gauge_hud',
  'icon_sticker', 'icon_drop', 'social_cta', 'social_bug', 'ui_toggle', 'audio_wave', 'flag_badge', 'presenter_stats',
  'info_card', 'stat_title',
];

const _dataHudLabels = {
  'unit_chart': 'Unit Chart (pictograms)',
  'people_grid': 'People Tally',
  'stat_figure': 'Stat Figure',
  'calendar_flip': 'Calendar Flip',
  'clock_stamp': 'Date / Time Stamp',
  'clock_overlay': 'Clock Overlay',
  'split_screen': 'Split Comparison',
  'gauge_hud': 'Gauge HUD',
  'icon_sticker': 'Icon Sticker',
  'icon_drop': 'Icon Drop',
  'social_cta': 'Social Call-out',
  'social_bug': 'Social Bug',
  'ui_toggle': 'UI Toggle',
  'audio_wave': 'Audio Wave',
  'flag_badge': 'Flag Badge',
  'presenter_stats': 'Presenter Stats',
  'info_card': 'Info Card',
  'stat_title': 'Stat Title',
};

List<Map<String, dynamic>>? _dataHudBuild(Project p, Map<String, dynamic> c, _B b) {
  switch ('${c['type']}') {
    case 'unit_chart':
      return _unitChart(b, p);
    case 'people_grid':
      return _peopleGrid(b, p);
    case 'stat_figure':
      return _statFigure(b, p);
    case 'calendar_flip':
      return _calendarFlip(b);
    case 'clock_stamp':
      return _clockStamp(b);
    case 'clock_overlay':
      return _clockOverlay(b);
    case 'split_screen':
      return _splitScreen(b, p);
    case 'gauge_hud':
      return _gaugeHud(b);
    case 'icon_sticker':
      return _iconSticker(b, p);
    case 'icon_drop':
      return _iconDrop(b, p);
    case 'social_cta':
      return _socialCta(b, bug: false);
    case 'social_bug':
      return _socialCta(b, bug: true);
    case 'ui_toggle':
      return _uiToggle(b);
    case 'audio_wave':
      return _audioWave(b);
    case 'flag_badge':
      return _flagBadge(b);
    case 'presenter_stats':
      return _presenterStats(b);
    case 'info_card':
      return _infoCard(b);
    case 'stat_title':
      return _statTitle(b);
  }
  return null;
}

// ------------------------------------------------------------- helpers

/// Linear mix of two "#RRGGBB" colours.
String _dhLerp(String a, String b, double t) {
  int v(String s) {
    var x = s.replaceFirst('#', '');
    if (x.length == 8) x = x.substring(2);
    return int.tryParse(x, radix: 16) ?? 0xFFFFFF;
  }

  final ca = v(a), cb = v(b);
  final k = t.clamp(0.0, 1.0);
  int ch(int shift) => ((((ca >> shift) & 0xFF) * (1 - k)) + (((cb >> shift) & 0xFF) * k)).round().clamp(0, 255).toInt();
  String hx(int x) => x.toRadixString(16).padLeft(2, '0');
  return '#${hx(ch(16))}${hx(ch(8))}${hx(ch(0))}'.toUpperCase();
}

/// A fraction (≤ 1.5) of [full] or an absolute px value.
double _dhFrac(num v, double full) => v.abs() <= 1.5 ? v.toDouble() * full : v.toDouble();

/// Per-item time: `at` (s after the component start) or the default.
double _dhAt(Map<String, dynamic> s, double d) => (s['at'] as num?)?.toDouble() ?? d;

/// A text command with a text_style preset: the look keys of [_B.text]
/// (weight, colour, shadow) are dropped so the preset wins.
Map<String, dynamic> _dhStyled(Map<String, dynamic> m, String style, {Map<String, dynamic> extra = const {}}) {
  final out = Map<String, dynamic>.from(m)
    ..remove('font_weight')
    ..remove('text_color')
    ..remove('shadow')
    ..['text_style'] = style;
  out.addAll(extra);
  return out;
}

/// Sound hook (pop / ui_click / clock_tick / paper / tick live in lib/director/sfx.dart).
Map<String, dynamic>? _dhSfx(_B b, String kind, double time, {double? duration}) {
  if (b.c['sfx'] == false || b.c['sound'] == false) return null;
  return {'op': 'add_sfx', 'kind': kind, 'time': math.max(0.0, time), 'duration': ?duration};
}

/// Pop-in keyframes on [id] at [t]: 0 → [over]% → 100% (eased).
List<Map<String, dynamic>> _dhPop(_B b, String id, double t, {double over = 115, double dur = 0.26, double sx = 100, double sy = 100}) => [
      b.kf(id, 'scale', t, [0, 0, 100], 'ease_out'),
      b.kf(id, 'scale', t + dur * 0.55, [sx * over / 100, sy * over / 100, 100], 'easy_ease'),
      b.kf(id, 'scale', t + dur, [sx, sy, 100]),
    ];

/// Fades every direct child of the group out over the last [d] s.
List<Map<String, dynamic>> _dhFadeOutChildren(_B b, List<Map<String, dynamic>> cmds, double d) => [
      for (final cmd in List.of(cmds))
        if (cmd['op'] == 'add_layer' && cmd['type'] != 'null' && cmd['type'] != 'audio')
          {'op': 'animate_out', 'layer': cmd['id'], 'preset': 'fade', 'duration': d},
    ];

/// Icon: a null group [pre] at x, y with the vector icon (or media / short
/// text) drawn [size] px tall. [mono]: one colour (detail marks dropped).
List<Map<String, dynamic>> _dhIcon(
  _B b,
  Project p,
  String pre,
  dynamic icon,
  double x,
  double y,
  double size, {
  String? parent,
  String? main,
  String? detail,
  String? accent,
  bool mono = false,
  double? st,
  double? du,
  bool shadow = false,
}) {
  final s0 = st ?? b.start, d0 = du ?? b.dur;
  final cmds = <Map<String, dynamic>>[...b.nul(pre, x, y, parent: parent, st: s0, du: d0, name: 'Icon')];
  final g = b.id(pre);
  Map<String, dynamic> child(Map<String, dynamic> m) => {...m, 'parent': g, 'start': s0, 'duration': d0};
  final m = icon is String ? p.media[icon] : null;
  if (m != null && m.type != MediaType.audio) {
    final k = size / math.max(1, math.max(m.width, m.height));
    cmds.add(child(b.media('${pre}_img', m, 0, 0, widthPx: m.width * k)));
    if (shadow) cmds.add(b.fx(b.id('${pre}_img'), 'shadow', {'distance': size * 0.04, 'blur': size * 0.08, 'opacity': 50}));
    return cmds;
  }
  final vi = VectorIcons.byId(icon is String ? icon : null);
  if (vi == null) {
    final t = '${icon ?? '?'}';
    final fs = size * (t.length <= 2 ? 0.7 : (t.length <= 4 ? 0.42 : 0.26));
    cmds.add(child({...b.text('${pre}_txt', t, size * 1.6, size, 0, 0, fs, color: main ?? '#FFFFFF', weight: 900), 'font': 'Poppins'}));
    return cmds;
  }
  final cMain = main ?? vi.main, cDetail = detail ?? vi.detail, cAccent = mono ? cMain : (accent ?? vi.accent);
  final k = size / 100;
  List<List<double>> px(List<List<double>> rings) => [
        for (final r in rings) [for (int i = 0; i < r.length; i++) (r[i] - 50) * k],
      ];
  var n = 0;
  // mono: all filled main parts merge into one shape layer
  if (mono) {
    final fills = <List<double>>[];
    for (final part in vi.parts) {
      if (part.isText || part.role == 'detail' || part.stroke > 0) continue;
      fills.addAll(px(part.rings));
    }
    if (fills.isNotEmpty) {
      cmds.add(child({'op': 'add_layer', 'type': 'shape', 'id': b.id('${pre}_p${n++}'), 'rings': fills, 'closed': true, 'fill': cMain, 'stroke': 'none', 'stroke_width': 0}));
    }
  }
  for (final part in vi.parts) {
    if (mono && (part.role == 'detail' || part.isText)) continue;
    if (mono && part.stroke <= 0) continue;
    final color = switch (part.role) { 'detail' => cDetail, 'accent' => cAccent, _ => cMain };
    if (part.isText) {
      final fs = part.size * k;
      cmds.add(child({
        ...b.text('${pre}_p${n++}', part.text!, size, fs * 1.3, (part.x - 50) * k, (part.y - 50) * k, fs, color: color, weight: 400),
        'font': 'Anton',
      }));
      continue;
    }
    final pid = b.id('${pre}_p${n++}');
    cmds.add(child({
      'op': 'add_layer', 'type': 'shape', 'id': pid, 'rings': px(part.rings), 'closed': part.closed,
      'fill': part.stroke > 0 ? 'none' : color, 'stroke': part.stroke > 0 ? color : 'none', 'stroke_width': part.stroke * k,
    }));
    if (shadow && part.role == 'main' && part.stroke <= 0) {
      cmds.add(b.fx(pid, 'shadow', {'distance': size * 0.04, 'blur': size * 0.08, 'opacity': 50}));
    }
  }
  return cmds;
}

/// One-colour pictogram as a single shape layer when possible (fast grids).
List<Map<String, dynamic>> _dhPicto(_B b, Project p, String part, dynamic icon, double x, double y, double size, String color,
    {double? st, double? du, String? parent}) {
  final vi = VectorIcons.byId(icon is String ? icon : null);
  if (vi == null || !vi.parts.every((q) => q.isText || q.role == 'detail' || q.stroke <= 0)) return _dhIcon(b, p, part, icon, x, y, size, main: color, mono: true, st: st, du: du, parent: parent);
  final k = size / 100;
  final rings = <List<double>>[
    for (final q in vi.parts)
      if (!q.isText && q.role != 'detail')
        for (final r in q.rings) [for (int i = 0; i < r.length; i++) (r[i] - 50) * k + (i.isEven ? x : y)],
  ];
  return [
    {
      'op': 'add_layer', 'type': 'shape', 'id': b.id(part), 'name': vi.label, 'parent': parent ?? b.g, 'start': st ?? b.start,
      'duration': du ?? b.dur, 'rings': rings, 'closed': true, 'fill': color, 'stroke': 'none', 'stroke_width': 0,
    },
  ];
}

const _dhPalette = ['#FFFFFF', '#E53935', '#9E9E9E', '#2EE6E6', '#FFE000', '#2E5BD6'];

// ----------------------------------------------------------- 21 unit_chart

/// Total label + pictograms popping row by row, coloured by group; each
/// group's big number + 2-line label appears at the left when narrated.
List<Map<String, dynamic>> _unitChart(_B b, Project p) {
  var groups = b.specs('groups', 'count');
  if (groups.isEmpty) groups = [{'count': b.n('count', 45).round()}];
  final counts = [for (final g in groups) ((g['count'] as num?) ?? 1).round().clamp(0, 400).toInt()];
  final total = counts.fold<int>(0, (a, v) => a + v).clamp(1, 400).toInt();
  final cols = b.n('cols', 10).round().clamp(1, 40);
  final rows = (total / cols).ceil();
  final av = b.c['area'] is List && (b.c['area'] as List).length >= 4 ? [for (final v in b.c['area'] as List) (v as num)] : null;
  final x0 = av == null ? b.w * 0.42 : _dhFrac(av[0], b.w), y0 = av == null ? b.h * 0.24 : _dhFrac(av[1], b.h);
  final x1 = av == null ? b.w * 0.95 : _dhFrac(av[2], b.w), y1 = av == null ? b.h * 0.9 : _dhFrac(av[3], b.h);
  final labelH = b.h * 0.075;
  final cell = math.min((x1 - x0) / cols, (y1 - y0 - labelH) / math.max(1, rows));
  final size = cell * 0.86;
  final stagger = b.n('stagger', 0.03);
  final icon = b.c['media'] ?? b.str('icon', 'person');
  final cmds = b.group('Unit Chart', x: 0, y: 0);
  // total label: fades in from a blur
  final totalLabel = b.str('total_label', '$total ${b.str('unit', 'PEOPLE')}').toUpperCase();
  final gridW = cols * cell;
  final gx = x0 + ((x1 - x0) - gridW) / 2;
  final lid = b.id('total');
  final fs = b.n('label_size', b.h * 0.055);
  cmds.add({...b.text('total', totalLabel, gridW * 1.2, fs * 1.4, gx + gridW / 2, y0 + fs * 0.6, fs, color: '#FFFFFF', weight: 900), 'shadow': true, 'font': 'Poppins'});
  cmds.add(b.fx(lid, 'blur', {'amount': 30}, '${lid}_blur'));
  cmds.add({'op': 'set_keyframe', 'target': lid, 'effect': '${lid}_blur', 'prop': 'amount', 'time': b.start, 'value': 30, 'ease': 'ease_out'});
  cmds.add({'op': 'set_keyframe', 'target': lid, 'effect': '${lid}_blur', 'prop': 'amount', 'time': b.start + 0.5, 'value': 0});
  cmds.add(b.kf(lid, 'opacity', b.start, 0, 'ease_out'));
  cmds.add(b.kf(lid, 'opacity', b.start + 0.45, 100));
  // pictograms
  final t0 = b.start + b.n('grid_delay', 0.45);
  final top = y0 + labelH + cell / 2;
  var k = 0;
  for (int gi = 0; gi < groups.length; gi++) {
    final color = '${groups[gi]['color'] ?? _dhPalette[gi % _dhPalette.length]}';
    for (int j = 0; j < counts[gi] && k < total; j++, k++) {
      final r = k ~/ cols, c = k % cols;
      final x = gx + cell * (c + 0.5), y = top + cell * r;
      final t = t0 + k * stagger;
      if (t >= b.end - 0.05) continue;
      final part = 'u$k';
      final pc = _dhPicto(b, p, part, icon, x, y, size, color, st: t, du: b.end - t);
      cmds.addAll(pc);
      final id = pc.first['id'] as String; // shape (anchor = icon centre) or the icon's null group
      cmds.addAll(_dhPop(b, id, t, dur: 0.24));
    }
  }
  final gridEnd = t0 + total * stagger + 0.25;
  final pop = _dhSfx(b, 'pop', t0);
  if (pop != null) cmds.add(pop);
  // group labels at the left
  final lx = b.n('label_x', b.w * 0.06);
  final named = [for (int gi = 0; gi < groups.length; gi++) if ('${groups[gi]['label'] ?? ''}'.trim().isNotEmpty) gi];
  final slotH = math.min(b.h * 0.2, (y1 - y0) / math.max(1, named.length));
  for (int n = 0; n < named.length; n++) {
    final gi = named[n];
    final color = '${groups[gi]['color'] ?? _dhPalette[gi % _dhPalette.length]}';
    final at = b.start + _dhAt(groups[gi], gridEnd - b.start + 0.3 + n * 0.9);
    if (at >= b.end - 0.1) continue;
    final y = y0 + slotH * (n + 0.5);
    final nfs = slotH * 0.42, lfs = slotH * 0.14;
    final label = '${groups[gi]['label']}'.toUpperCase();
    final words = label.split(RegExp(r'\s+'));
    final half = (words.length / 2).ceil();
    final twoLines = words.length > 1 ? '${words.take(half).join(' ')}\n${words.skip(half).join(' ')}' : label;
    final numText = '${groups[gi]['number'] ?? counts[gi]}';
    final nw = numText.length * nfs * 0.62 + nfs * 0.2;
    final nid = b.id('g${gi}_num');
    cmds.add({
      ...b.text('g${gi}_num', numText, nw, nfs * 1.25, lx + nw / 2, y, nfs, color: color, weight: 900, align: 'left'),
      'font': 'Poppins', 'shadow': true, 'start': at, 'duration': b.end - at,
    });
    cmds.add(b.setp(nid, 'anchor', [0, nfs * 0.625, 0]));
    cmds.add(b.setp(nid, 'position', [lx, y, 0]));
    cmds.addAll(_dhPop(b, nid, at, over: 112, dur: 0.3));
    cmds.add({
      ...b.text('g${gi}_label', twoLines, b.w * 0.25, lfs * 2.8, lx + nw + lfs * 0.6 + b.w * 0.125, y, lfs, color: color, weight: 800, align: 'left'),
      'font': 'Poppins', 'shadow': true, 'start': at + 0.15, 'duration': b.end - at - 0.15,
      'animator': 'typewriter', 'anim_duration': math.min(0.6, label.length * 0.03 + 0.15),
    });
    final s = _dhSfx(b, 'pop', at);
    if (s != null) cmds.add(s);
  }
  return b.finish(cmds, enter: 'none', exit: null)..addAll(_dhFadeOutChildren(b, cmds, 0.35));
}

// --------------------------------------------------------- 22 people_grid

/// Navy tally board: names/roles grid on top, glowing red figures in rows;
/// the dead ones fade to grey (or get an X), then the count slides into the gap.
List<Map<String, dynamic>> _peopleGrid(_B b, Project p) {
  final total = b.n('total', 16).round().clamp(1, 120);
  final alive = b.n('alive', 6).round().clamp(0, total);
  final aliveColor = b.str('alive_color', '#C62828'), deadColor = b.str('dead_color', '#8A8A8A');
  final deadStyle = b.str('dead', 'fade');
  final rows = b.n('rows', 2).round().clamp(1, 6);
  final cols = (total / rows).ceil();
  final cmds = b.group('People Tally', x: 0, y: 0);
  if (b.flag('bg', true)) cmds.add(b.backdrop('bg', b.str('bg_color', '#0B1630'), color2: '#050A18', name: 'Tally backdrop'));
  final under = b.mediaOf(p, 'media');
  if (under != null) {
    final s = math.max(b.w / under.width, b.h / under.height);
    cmds.add(b.media('under', under, b.w / 2, b.h / 2, widthPx: under.width * s));
    cmds.add(b.setp(b.id('under'), 'opacity', b.n('underlay', 20)));
    cmds.add(b.fx(b.id('under'), 'mono', {'amount': 100}));
  }
  // names grid (3 columns in the top 35 %)
  final names = b.specs('names', 'name');
  final nfs = b.n('name_size', b.h * 0.024);
  for (int i = 0; i < names.length && i < 30; i++) {
    final col = i % 3, row = i ~/ 3;
    final x = b.w * (0.08 + col * 0.3), y = b.h * 0.07 + row * nfs * 2.9;
    if (y > b.h * 0.36) break;
    final t = b.start + 0.2 + i * 0.08;
    final name = '${names[i]['name'] ?? ''}'.toUpperCase();
    final role = '${names[i]['role'] ?? ''}';
    cmds.add({
      ...b.text('n$i', name, b.w * 0.28, nfs * 1.4, x + b.w * 0.14, y, nfs, color: '#FFFFFF', weight: 800, align: 'left'),
      'font': 'Poppins', 'start': t, 'duration': b.end - t, 'animator': 'typewriter', 'anim_duration': math.min(0.5, name.length * 0.03 + 0.1),
    });
    if (role.isNotEmpty) {
      cmds.add({
        ...b.text('r$i', role, b.w * 0.28, nfs * 1.2, x + b.w * 0.14, y + nfs * 1.25, nfs * 0.72, color: '#9FB0C8', weight: 500, align: 'left'),
        'font': 'Poppins', 'start': t + 0.1, 'duration': b.end - t - 0.1, 'animator': 'fade_up', 'anim_duration': 0.3,
      });
    }
  }
  // figures
  final aliveIdx = b.c['alive_index'] is List
      ? {for (final v in b.c['alive_index'] as List) (v as num).toInt()}
      : {for (int k = 0; k < alive; k++) ((k + 0.5) * total / math.max(1, alive)).floor().clamp(0, total - 1).toInt()};
  final figH = b.n('figure_size', b.h * (rows <= 2 ? 0.19 : 0.5 / rows));
  final spacing = math.min(b.w * 0.9 / cols, figH * 0.75);
  final rowYs = [for (int r = 0; r < rows; r++) rows == 2 ? (r == 0 ? b.h * 0.52 : b.h * 0.86) : b.h * (0.5 + 0.42 * (r + 0.5) / rows)];
  final deadAt = b.start + b.n('dead_at', 1.6);
  final icon = b.c['icon'] ?? 'person';
  for (int i = 0; i < total; i++) {
    final r = i ~/ cols, c = i % cols;
    final inRow = r == rows - 1 ? total - cols * (rows - 1) : cols;
    final x = b.w / 2 + (c - (inRow - 1) / 2) * spacing, y = rowYs[r];
    final t = b.start + 0.4 + i * 0.035;
    final isAlive = aliveIdx.contains(i);
    if (!isAlive) {
      final gp = _dhPicto(b, p, 'grey$i', icon, x, y, figH, deadColor, st: t, du: b.end - t);
      cmds.addAll(gp);
      final gid = gp.first['id'] as String;
      cmds.add(b.setp(gid, 'opacity', deadStyle == 'fade' ? 35 : 100));
    }
    final rp = _dhPicto(b, p, 'red$i', icon, x, y, figH, aliveColor, st: t, du: isAlive ? b.end - t : math.max(0.1, deadAt + 0.7 - t));
    cmds.addAll(rp);
    final rid = rp.first['id'] as String;
    cmds.add(b.fx(rid, 'glow', {'amount': 55, 'radius': 16}));
    cmds.addAll(_dhPop(b, rid, t, over: 110, dur: 0.3));
    if (!isAlive) {
      final td = deadAt + (i % 5) * 0.06;
      cmds.add(b.kf(rid, 'opacity', td, 100, 'ease_in'));
      cmds.add(b.kf(rid, 'opacity', td + 0.55, 0));
      if (deadStyle == 'x') {
        final xid = 'x$i';
        final s = figH * 0.32;
        cmds.add({
          ...b.path(xid, [[x - s, y - s], [x + s, y + s]], stroke: '#E01010', width: figH * 0.05),
          'rings': [[x - s, y - s, x + s, y + s], [x + s, y - s, x - s, y + s]], 'points': null, 'start': td, 'duration': b.end - td,
        });
        cmds.add(b.kf(b.id(xid), 'trim', td, [0, 0], 'ease_out'));
        cmds.add(b.kf(b.id(xid), 'trim', td + 0.3, [0, 100]));
      }
    }
  }
  final countText = b.str('count_text', '$alive ${b.str('count_label', 'SURVIVED')}').toUpperCase();
  final ca = b.start + b.n('count_at', b.n('dead_at', 1.6) + 1.1);
  if (ca < b.end - 0.1) {
    final cfs = b.n('count_size', b.h * 0.07);
    final cy = rows == 2 ? b.h * 0.69 : b.h * 0.42;
    final id = b.id('count');
    cmds.add({
      ...b.text('count', countText, b.w * 0.9, cfs * 1.3, b.w / 2, cy, cfs, color: aliveColor, weight: 900),
      'font': 'Poppins', 'shadow': true, 'start': ca, 'duration': b.end - ca,
    });
    cmds.add(b.fx(id, 'glow', {'amount': 50, 'radius': 18}));
    cmds.add(b.kf(id, 'position', ca, [b.w * 0.2, cy, 0], 'ease_out'));
    cmds.add(b.kf(id, 'position', ca + 0.45, [b.w / 2, cy, 0]));
    cmds.add(b.kf(id, 'opacity', ca, 0, 'ease_out'));
    cmds.add(b.kf(id, 'opacity', ca + 0.3, 100));
    final s = _dhSfx(b, 'whoosh', ca + 0.2);
    if (s != null) cmds.add(s);
  }
  return b.finish(cmds, enter: 'none', exit: null)..addAll(_dhFadeOutChildren(b, cmds, 0.4));
}

// --------------------------------------------------------- 23 stat_figure

String _dhNumber(double v, int decimals) {
  var s = v.toStringAsFixed(decimals);
  final neg = s.startsWith('-');
  if (neg) s = s.substring(1);
  final parts = s.split('.');
  final ip = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '${neg ? '-' : ''}$ip${parts.length > 1 ? '.${parts[1]}' : ''}';
}

/// Icon with a number above that steps (rolling digits) and turns red, a
/// typed small-caps label, and a figure silhouette tinting grey → red.
List<Map<String, dynamic>> _statFigure(_B b, Project p) {
  final size = b.n('size', b.h * 0.18);
  final x = b.n('x', b.w * 0.4), y = b.n('y', b.h * 0.55);
  final from = b.n('from', 0), to = b.n('to', 100);
  final steps = b.n('steps', 6).round().clamp(1, 40);
  final decimals = b.n('decimals', 0).round().clamp(0, 4);
  final unit = b.str('unit', ''), prefix = b.str('prefix', '');
  final cFrom = b.str('color_from', '#FFFFFF'), cTo = b.str('color_to', '#E53935');
  final stepDur = b.c['count'] is num ? b.n('count', 1.5) / steps : b.n('step_time', 0.25).clamp(0.04, 5).toDouble();
  final t0 = b.start + b.n('delay', 0.6);
  final cmds = b.group('Stat Figure', x: 0, y: 0);
  final icon = b.c['media'] ?? b.str('icon', 'scale');
  cmds.addAll(_dhIcon(b, p, 'icon', icon, x, y, size, main: b.c['icon_color'] as String?, shadow: true));
  cmds.addAll(_dhPop(b, b.id('icon'), b.start, over: 112, dur: 0.35));
  // rolling number above the icon
  final nfs = size * 0.42;
  final ny = y - size * 0.5 - nfs * 0.75;
  for (int k = 0; k <= steps; k++) {
    final ts = t0 + k * stepDur;
    if (ts >= b.end - 0.05) break;
    final last = k == steps || t0 + (k + 1) * stepDur >= b.end - 0.05;
    final te = last ? b.end : t0 + (k + 1) * stepDur + 0.12;
    final v = from + (to - from) * k / steps;
    final label = '$prefix${_dhNumber(v, decimals)}${unit.isEmpty ? '' : (RegExp(r'^[A-Za-z]').hasMatch(unit) ? ' $unit' : unit)}';
    final id = b.id('v$k');
    final color = _dhLerp(cFrom, cTo, steps == 0 ? 1 : k / steps);
    cmds.add({
      ...b.text('v$k', label, b.w * 0.5, nfs * 1.3, x, ny, nfs, color: color, weight: 900),
      'font': 'Poppins', 'shadow': true, 'start': ts, 'duration': math.max(0.05, te - ts),
    });
    if (k > 0) {
      cmds.add(b.kf(id, 'position', ts, [x, ny + nfs * 0.55, 0], 'ease_out'));
      cmds.add(b.kf(id, 'position', ts + 0.14, [x, ny, 0]));
      cmds.add(b.kf(id, 'opacity', ts, 0, 'ease_out'));
      cmds.add(b.kf(id, 'opacity', ts + 0.12, 100));
    }
    if (!last) {
      cmds.add(b.kf(id, 'position', te - 0.12, [x, ny, 0], 'ease_in'));
      cmds.add(b.kf(id, 'position', te, [x, ny - nfs * 0.55, 0]));
      cmds.add(b.kf(id, 'opacity', te - 0.12, 100, 'ease_in'));
      cmds.add(b.kf(id, 'opacity', te, 0));
    } else if (k > 0) {
      cmds.add(b.fx(id, 'glow', {'amount': 45, 'radius': 16}));
    }
    if (k > 0 && k <= 8) {
      final s = _dhSfx(b, 'tick', ts);
      if (s != null) cmds.add(s);
    }
  }
  // typed small-caps label under the icon
  final label = b.str('label', '').toUpperCase();
  if (label.isNotEmpty) {
    final lfs = size * 0.16;
    final lt = b.start + 0.35;
    cmds.add({
      ...b.text('label', label, b.w * 0.4, lfs * 1.5, x, y + size * 0.5 + lfs * 1.1, lfs, color: '#FFFFFF', weight: 800),
      'font': 'Poppins', 'letter_spacing': lfs * 0.12, 'shadow': true, 'start': lt, 'duration': b.end - lt,
      'animator': 'typewriter', 'anim_duration': math.min(0.8, label.length * 0.04 + 0.15),
    });
  }
  // figure silhouette tinting grey → red while the number steps
  final fig = b.c['figure'] ?? 'human';
  if (fig != 'none' && fig != false) {
    final fh = b.n('figure_size', size * 2.2);
    final fx = x + size * 0.6 + fh * 0.45, fy = y + size * 0.5 - fh / 2;
    final figMedia = fig is String ? p.media[fig] : null;
    final tEnd = t0 + steps * stepDur;
    if (figMedia != null) {
      cmds.add(b.media('fig', figMedia, fx, fy, heightPx: fh));
      final fid = b.id('fig');
      cmds.add(b.fx(fid, 'silhouette', {'color': '#8A8A8A', 'glow': 0}, '${fid}_grey'));
      cmds.add(b.fx(fid, 'tint', {'color': cTo, 'amount': 0}, '${fid}_tint'));
      cmds.add({'op': 'set_keyframe', 'target': fid, 'effect': '${fid}_tint', 'prop': 'amount', 'time': t0, 'value': 0, 'ease': 'easy_ease'});
      cmds.add({'op': 'set_keyframe', 'target': fid, 'effect': '${fid}_tint', 'prop': 'amount', 'time': tEnd, 'value': 100});
    } else {
      cmds.addAll(_dhPicto(b, p, 'fig_grey', 'person', fx, fy, fh, '#7A7A7A'));
      cmds.addAll(_dhPicto(b, p, 'fig_red', 'person', fx, fy, fh, cTo));
      final rid = b.id('fig_red');
      cmds.add(b.kf(rid, 'opacity', t0, 0, 'easy_ease'));
      cmds.add(b.kf(rid, 'opacity', tEnd, 100));
      cmds.add(b.fx(rid, 'glow', {'amount': 40, 'radius': 18}));
    }
    cmds.add({'op': 'animate_in', 'layer': b.id(figMedia != null ? 'fig' : 'fig_grey'), 'preset': 'fade', 'duration': 0.4});
  }
  return b.finish(cmds, enter: 'none', exit: null)..addAll(_dhFadeOutChildren(b, cmds, 0.3));
}

// -------------------------------------------------------- 61 calendar_flip

/// 3D tear-off calendar: pages flip up over the binding counting the days.
List<Map<String, dynamic>> _calendarFlip(_B b) {
  final from = b.n('from', 1).round(), to = b.n('to', 72).round();
  final maxPages = b.n('max_pages', 40).round().clamp(2, 120);
  final span = (to - from).abs();
  final stepN = math.max(1, (span / (maxPages - 1)).ceil());
  final vals = <int>[];
  for (var v = from; to >= from ? v < to : v > to; v += to >= from ? stepN : -stepN) {
    vals.add(v);
  }
  vals.add(to);
  final rate = b.n('rate', 4).clamp(0.5, 30).toDouble();
  final cw = _dhFrac(b.n('size', 0.2), b.w), ch = cw * 1.12;
  final tilt = b.c['tilt'] is List && (b.c['tilt'] as List).length >= 3
      ? [for (final v in (b.c['tilt'] as List).take(3)) (v as num).toDouble()]
      : [50.0, 0.0, -20.0];
  final x = b.n('x', b.w * 0.5), y = b.n('y', b.h * 0.48);
  final cmds = b.group('Calendar', x: x, y: y);
  cmds.add({'op': 'update_layer', 'layer': b.g, 'is3d': true});
  cmds.add(b.setp(b.g, 'rotation', tilt));
  Map<String, dynamic> d3(Map<String, dynamic> m, double z) => {...m, 'is3d': true, 'position': [...(m['position'] as List).take(2), z]};
  final n = vals.length;
  final zBack = n * 0.4 + 3;
  final headH = ch * 0.24, pageH = ch * 0.72;
  final headY = -ch / 2 + headH / 2, pageY = -ch / 2 + headH + pageH / 2 + ch * 0.02;
  cmds.add(d3(b.shape('back', 'rect', cw, ch, 0, ch * 0.015, fill: '#2B2B2B', fill2: '#151515', corner: cw * 0.04), zBack));
  cmds.add(b.fx(b.id('back'), 'shadow', {'distance': cw * 0.06, 'blur': cw * 0.08, 'opacity': 55}));
  final hc = b.str('header_color', '#E0245E');
  cmds.add(d3(b.shape('head', 'rect', cw, headH, 0, headY, fill: hc, fill2: _shade(hc, 0.75), corner: cw * 0.04), -0.5));
  final label = b.str('label', 'CALENDAR').toUpperCase();
  cmds.add(d3({
    ...b.text('head_txt', label, cw * 0.9, headH * 0.8, 0, headY + headH * 0.06, headH * 0.36, color: '#FFFFFF', weight: 900),
    'font': 'Poppins', 'letter_spacing': headH * 0.04,
  }, -0.6));
  for (final sx in [-0.3, 0.3]) {
    cmds.add(d3(b.shape('ring${sx < 0 ? 'l' : 'r'}', 'rect', cw * 0.05, headH * 0.5, cw * sx, -ch / 2, fill: '#D9D9D9', fill2: '#7A7A7A', corner: cw * 0.025), -0.7));
  }
  final t0 = b.start + b.n('delay', 0.5);
  final flip = math.min(0.42, 1.6 / rate);
  final nfs = pageH * 0.58;
  for (int i = 0; i < n; i++) {
    final tFlip = t0 + i / rate;
    final st = i == 0 ? b.start : t0 + (i - 1) / rate;
    final last = i == n - 1;
    final en = last ? b.end : tFlip + flip;
    if (st >= b.end) break;
    final du = math.max(0.05, math.min(en, b.end) - st);
    final z = i * 0.4;
    final pg = 'p$i';
    cmds.addAll(b.nul(pg, 0, -ch / 2 + headH, st: st, du: du, name: 'Page ${vals[i]}'));
    final pid = b.id(pg);
    cmds.add({'op': 'update_layer', 'layer': pid, 'is3d': true});
    cmds.add(b.setp(pid, 'position', [0, -ch / 2 + headH, z]));
    final rel = pageY - (-ch / 2 + headH);
    cmds.add({...d3(b.shape('${pg}_paper', 'rect', cw * 0.94, pageH, 0, rel, fill: '#FAFAFA', fill2: '#E4E4E4', corner: cw * 0.02), 0), 'parent': pid, 'start': st, 'duration': du});
    cmds.add({
      ...d3({...b.text('${pg}_num', '${vals[i]}', cw * 0.9, nfs * 1.25, 0, rel, nfs, color: '#1A1A1A', weight: 900), 'font': 'Poppins'}, -0.1),
      'parent': pid, 'start': st, 'duration': du,
    });
    if (!last && tFlip < b.end) {
      cmds.add(b.kf(pid, 'rotation', tFlip, [0, 0, 0], 'ease_in'));
      cmds.add(b.kf(pid, 'rotation', tFlip + flip, [-115, 0, 0]));
      cmds.add(b.kf(b.id('${pg}_paper'), 'opacity', tFlip + flip * 0.55, 100, 'ease_in'));
      cmds.add(b.kf(b.id('${pg}_paper'), 'opacity', tFlip + flip, 0));
      cmds.add(b.kf(b.id('${pg}_num'), 'opacity', tFlip + flip * 0.55, 100, 'ease_in'));
      cmds.add(b.kf(b.id('${pg}_num'), 'opacity', tFlip + flip, 0));
      if (i < 10) {
        final s = _dhSfx(b, 'paper', tFlip + flip * 0.5);
        if (s != null) cmds.add(s);
      }
    } else if (last && i > 0 && st + 0.4 < b.end) {
      final nid = b.id('${pg}_num');
      final tl = t0 + (i - 1) / rate + flip;
      cmds.add(b.kf(nid, 'scale', tl, [100, 100, 100], 'ease_out'));
      cmds.add(b.kf(nid, 'scale', tl + 0.18, [112, 112, 100], 'easy_ease'));
      cmds.add(b.kf(nid, 'scale', tl + 0.4, [100, 100, 100]));
    }
  }
  final caption = b.str('caption', '');
  if (caption.isNotEmpty) {
    final cfs = b.n('caption_size', b.h * 0.05);
    final ct = t0 + (n - 1) / rate + flip * 0.5;
    if (ct < b.end - 0.1) {
      cmds.add({
        'op': 'add_layer', 'type': 'text', 'id': b.id('caption'), 'name': caption, 'start': ct, 'duration': b.end - ct,
        'text': caption.toUpperCase(), 'width': b.w * 0.6, 'height': cfs * 1.4, 'position': [x, y + ch * 0.62, 0], 'font_size': cfs,
        'font': 'Poppins', 'font_weight': 900, 'text_color': '#FFFFFF', 'shadow': true, 'animator': 'typewriter_soft', 'anim_duration': 0.5,
      });
    }
  }
  return b.finish(cmds, enter: 'pop', exit: 'pop');
}

// ---------------------------------------------------------- 26 clock_stamp

/// Bottom-left italic digital date/time stamp: lines typed 10–15 cps, the
/// colon blinks 1 Hz, `retype` swaps a line on a time jump, a soft dark
/// gradient keeps it readable.
List<Map<String, dynamic>> _clockStamp(_B b) {
  var lines = b.specs('lines', 'text');
  if (lines.isEmpty) lines = [{'text': b.str('text', '12 DEC 1972')}];
  final size = b.n('size', b.h * 0.058);
  final x = b.n('x', b.w * 0.045);
  final gap = size * 1.28;
  final y = b.n('y', b.h * 0.9 - gap * (lines.length - 1));
  final cps = b.n('cps', 13).clamp(2, 80).toDouble();
  final color = b.str('color', '#FFFFFF');
  final blink = b.flag('blink_colon', true);
  final persist = b.flag('persist', false);
  final cmds = b.group('Clock Stamp', x: 0, y: 0);
  final dark = b.n('darken_below', 0.3);
  if (dark > 0) {
    final a = (dark <= 1 ? dark * 255 : dark * 2.55).round().clamp(0, 255);
    final top = y - size * 1.6;
    cmds.add({
      ...b.shape('shade', 'rect', b.w, b.h - top, b.w / 2, top + (b.h - top) / 2, fill: '#01000000', fill2: _alpha('#000000', a.toInt())), // fill 0 = none
      'name': 'Stamp shade',
    });
    cmds.add(b.kf(b.id('shade'), 'opacity', b.start, 0, 'ease_out'));
    cmds.add(b.kf(b.id('shade'), 'opacity', b.start + 0.4, 100));
  }
  // (line, text, start) segments: the original lines + retypes
  final segs = <(int, String, double)>[];
  var t = b.start + 0.15;
  for (int i = 0; i < lines.length; i++) {
    final text = '${lines[i]['text'] ?? ''}';
    final at = lines[i]['at'] is num ? b.start + (lines[i]['at'] as num).toDouble() : t;
    segs.add((i, text, at));
    t = at + text.length / cps + 0.25;
  }
  for (final r in b.specs('retype', 'text')) {
    var line = (r['line'] as num?)?.toInt() ?? -1;
    if (line < 0) {
      line = lines.length - 1;
      for (int i = 0; i < lines.length; i++) {
        if ('${lines[i]['text']}'.contains(':')) line = i;
      }
    }
    segs.add((line.clamp(0, lines.length - 1), '${r['text'] ?? ''}', b.start + ((r['at'] as num?)?.toDouble() ?? 1.5)));
  }
  var k = 0;
  for (final (line, text, st) in segs) {
    if (st >= b.end - 0.05 || text.isEmpty) continue;
    var en = b.end;
    for (final (l2, _, s2) in segs) {
      if (l2 == line && s2 > st + 1e-6 && s2 < en) en = s2;
    }
    final ly = y + line * gap;
    final typing = math.max(0.1, text.length / cps);
    final hasColon = blink && text.contains(':');
    final body = hasColon ? text.replaceAll(':', ' ') : text;
    Map<String, dynamic> line0(String part, String s, double st2) => {
          ...b.text(part, s, b.w * 0.6, size * 1.3, x + b.w * 0.3, ly, size, color: color, weight: 400, align: 'left'),
          'font': b.str('font', 'Share Tech Mono'), 'italic': b.flag('italic', true), 'letter_spacing': size * 0.06,
          'shadow': true, 'start': st2, 'duration': math.max(0.05, en - st2),
        };
    cmds.add({...line0('l$k', body, st), 'animator': 'typewriter', 'anim_duration': typing});
    final s = _dhSfx(b, 'typewriter', st, duration: typing);
    if (s != null && k < 6) cmds.add(s);
    if (hasColon) {
      final idx = text.indexOf(':');
      final colonOnly = String.fromCharCodes(text.codeUnits.map((u) => u == 0x3A ? u : 0x20));
      final ct = st + typing * (idx + 1) / text.length;
      if (ct < en - 0.05) {
        final cid = b.id('c$k');
        cmds.add(line0('c$k', colonOnly, ct));
        var on = true;
        var n = 0;
        for (var bt = ct + 0.5; bt < en - 0.02 && n < 240; bt += 0.5, n++) {
          on = !on;
          cmds.add(b.kf(cid, 'opacity', bt, on ? 100 : 0, 'hold'));
        }
      }
    }
    k++;
  }
  return b.finish(cmds, enter: 'none', exit: null)..addAll(persist ? const [] : _dhFadeOutChildren(b, cmds, 0.3));
}

// -------------------------------------------------------- 27 clock_overlay

/// Giant translucent clock face with spinning hands for durations ("8 DAYS").
List<Map<String, dynamic>> _clockOverlay(_B b) {
  final dia = b.n('scale', 140) / 100 * b.h * 0.75;
  final r = dia / 2;
  final x = b.n('x', b.w * 0.5), y = b.n('y', b.h * 0.5);
  final opacity = b.n('opacity', 30).clamp(0, 100).toDouble();
  final spin = b.n('spin', b.n('speed', 1)); // minute-hand turns per second
  final color = b.str('color', '#FFFFFF');
  final style = b.str('style', 'face');
  final glow = b.flag('glow', true);
  final rise = b.str('enter', 'fade') == 'rise';
  final cmds = b.group('Clock Overlay', x: x, y: y);
  final parts = <String>[];
  Map<String, dynamic> add(Map<String, dynamic> m) {
    parts.add(m['id'] as String);
    return m;
  }

  final lw = r * (style == 'line' ? 0.012 : 0.025);
  cmds.add(add(b.shape('ring', 'ellipse', dia, dia, 0, 0, fill: 'none', stroke: color, strokeWidth: lw)));
  final major = <List<double>>[], minor = <List<double>>[];
  final tickN = style == 'line' ? 12 : 60;
  for (int i = 0; i < tickN; i++) {
    final a = i * 2 * math.pi / tickN;
    final big = style == 'line' || i % 5 == 0;
    final r0 = r * (big ? 0.82 : 0.9), r1 = r * 0.95;
    (big ? major : minor).add([math.sin(a) * r0, -math.cos(a) * r0, math.sin(a) * r1, -math.cos(a) * r1]);
  }
  cmds.add(add({...b.path('ticks', const [[0, 0], [1, 0]], stroke: color, width: lw * 1.3), 'points': null, 'rings': major}));
  if (minor.isNotEmpty) cmds.add(add({...b.path('minor', const [[0, 0], [1, 0]], stroke: color, width: lw * 0.6), 'points': null, 'rings': minor}));
  if (style != 'line' && b.flag('numerals', true)) {
    final fs = r * 0.13;
    for (int i = 1; i <= 12; i++) {
      final a = i * 2 * math.pi / 12;
      cmds.add(add({
        ...b.text('n$i', '$i', fs * 2, fs * 1.3, math.sin(a) * r * 0.68, -math.cos(a) * r * 0.68, fs, color: color, weight: 700),
        'font': 'Poppins',
      }));
    }
  }
  // hands: shape boxes anchored at the centre pivot
  Map<String, dynamic> hand(String part, double len, double wid) => add({
        ...b.path(part, [[0, -len], [0, len * 0.14]], stroke: color, width: wid),
        'position': [0, 0, 0],
      });
  cmds.add(hand('hour', r * 0.5, lw * 2.6));
  cmds.add(hand('minute', r * 0.78, lw * 1.6));
  cmds.add(add(b.shape('cap', 'ellipse', lw * 5, lw * 5, 0, 0, fill: color)));
  for (final (part, len, wid) in [('hour', r * 0.5, lw * 2.6), ('minute', r * 0.78, lw * 1.6)]) {
    final id = b.id(part);
    final p0 = wid * 3 + 8; // shape box padding (see EditCommands._applyShape)
    cmds.add(b.setp(id, 'anchor', [p0, len + p0, 0]));
    final turns = spin * b.dur * (part == 'hour' ? 1 / 12 : 1);
    cmds.add(b.kf(id, 'rotation', b.start, [0, 0, part == 'hour' ? 300 : 0], 'linear'));
    cmds.add(b.kf(id, 'rotation', b.end, [0, 0, (part == 'hour' ? 300 : 0) + 360 * turns]));
  }
  for (final id in parts) {
    cmds.add(b.setp(id, 'opacity', opacity));
    if (glow) cmds.add(b.fx(id, 'glow', {'amount': 45, 'radius': 14}));
  }
  final blend = b.c['blend'];
  if (blend is String && blend != 'normal') {
    for (final id in parts) {
      cmds.add({'op': 'update_layer', 'layer': id, 'blend': blend});
    }
  }
  if (rise) {
    cmds.add(b.kf(b.g, 'position', b.start, [x, y + b.h * 0.18, 0], 'ease_out'));
    cmds.add(b.kf(b.g, 'position', b.start + 0.7, [x, y, 0]));
  }
  cmds.add(b.kf(b.g, 'scale', b.start, [92, 92, 100], 'ease_out'));
  cmds.add(b.kf(b.g, 'scale', b.end, [100, 100, 100]));
  final tick = b.c['sfx'] is String ? '${b.c['sfx']}' : 'clock_tick';
  final s = _dhSfx(b, tick, b.start, duration: b.dur);
  if (s != null) cmds.add(s);
  return b.finish(cmds, enter: 'fade_children', exit: null)..addAll(_dhFadeOutChildren(b, cmds, 0.5));
}

// --------------------------------------------------------- 24 split_screen

/// Two halves (media or panels) wiped in from a yellow divider, each with a
/// big label, a yellow value bar and an optional note.
List<Map<String, dynamic>> _splitScreen(_B b, Project p) {
  final orient = b.str('orientation', 'vertical');
  final angle = b.n('angle', orient == 'diagonal' ? 10 : 0);
  final dv = b.c['divider'] is Map ? Map<String, dynamic>.from(b.c['divider'] as Map) : const <String, dynamic>{};
  final dColor = '${dv['color'] ?? '#FFE000'}';
  final dWidth = (dv['width'] as num?)?.toDouble() ?? b.w * 0.006;
  final w = b.w, h = b.h;
  final cmds = b.group('Split Screen', x: 0, y: 0);
  final horiz = orient == 'horizontal';
  final tanA = math.tan(angle * math.pi / 180);
  // divider ends + half polygons (comp px)
  final List<double> d0, d1;
  final List<List<double>> halves;
  if (horiz) {
    d0 = [0, h / 2 + tanA * w / 2];
    d1 = [w, h / 2 - tanA * w / 2];
    halves = [
      [0, 0, w, 0, d1[0], d1[1], d0[0], d0[1]],
      [d0[0], d0[1], d1[0], d1[1], w, h, 0, h],
    ];
  } else {
    d0 = [w / 2 + tanA * h / 2, 0];
    d1 = [w / 2 - tanA * h / 2, h];
    halves = [
      [0, 0, d0[0], d0[1], d1[0], d1[1], 0, h],
      [d0[0], d0[1], w, 0, w, h, d1[0], d1[1]],
    ];
  }
  final mid = [w / 2, h / 2];
  final tDiv = b.start, tWipe = b.start + 0.25;
  final specs = [
    b.c['a'] is Map ? Map<String, dynamic>.from(b.c['a'] as Map) : <String, dynamic>{},
    b.c['b'] is Map ? Map<String, dynamic>.from(b.c['b'] as Map) : <String, dynamic>{},
  ];
  final values = [for (final s in specs) (s['value'] as num?)?.toDouble()];
  final maxV = b.n('max', [for (final v in values) if (v != null) v.abs()].fold<double>(0, math.max));
  for (int i = 0; i < 2; i++) {
    final s = specs[i];
    final poly = halves[i];
    double minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (int k = 0; k + 1 < poly.length; k += 2) {
      minX = math.min(minX, poly[k]);
      maxX = math.max(maxX, poly[k]);
      minY = math.min(minY, poly[k + 1]);
      maxY = math.max(maxY, poly[k + 1]);
    }
    final hid = b.id('half$i');
    final m = s['media'] is String ? p.media[s['media']] : null;
    final layerId = s['layer'] is String ? '${s['layer']}' : null;
    final panel = m == null && layerId == null;
    cmds.add({
      'op': 'add_layer', 'type': 'shape', 'id': hid, 'name': panel ? 'Panel ${i == 0 ? 'A' : 'B'}' : 'Half matte ${i == 0 ? 'A' : 'B'}',
      'start': b.start, 'duration': b.dur, 'rings': [poly], 'closed': true,
      'fill': panel ? '${s['color'] ?? (i == 0 ? '#16233D' : '#3A1518')}' : '#FFFFFF',
      if (panel) 'fill2': _shade('${s['color'] ?? (i == 0 ? '#16233D' : '#3A1518')}', 0.6),
      'stroke': 'none', 'stroke_width': 0,
    });
    // wipe out from the divider: anchor on the divider centre
    const pad = 8.0;
    cmds.add(b.setp(hid, 'anchor', [mid[0] - minX + pad, mid[1] - minY + pad, 0]));
    cmds.add(b.setp(hid, 'position', [mid[0], mid[1], 0]));
    final zero = horiz ? [100, 0, 100] : [0, 100, 100];
    cmds.add(b.kf(hid, 'scale', tWipe, zero, 'ease_out'));
    cmds.add(b.kf(hid, 'scale', tWipe + 0.5, [100, 100, 100]));
    if (m != null) {
      final hw = maxX - minX, hh = maxY - minY;
      final sc = math.max(hw / m.width, hh / m.height) * 1.04;
      cmds.add(b.media('media$i', m, (minX + maxX) / 2, (minY + maxY) / 2, widthPx: m.width * sc));
      cmds.add({'op': 'update_layer', 'layer': b.id('media$i'), 'matte': {'layer': hid, 'mode': 'alpha'}});
    } else if (layerId != null) {
      cmds.add({'op': 'update_layer', 'layer': layerId, 'matte': {'layer': hid, 'mode': 'alpha'}});
    }
  }
  final middle = b.mediaOf(p, 'middle');
  if (middle != null) {
    cmds.add(b.media('middle', middle, mid[0], h - b.h * 0.36, heightPx: h * 0.72));
    cmds.add({'op': 'animate_in', 'layer': b.id('middle'), 'preset': 'slide_up', 'duration': 0.6});
  }
  cmds.add({...b.path('divider', [d0, d1], stroke: dColor, width: dWidth), 'start': tDiv, 'duration': b.dur});
  cmds.add(b.kf(b.id('divider'), 'trim', tDiv, [50, 50], 'ease_out'));
  cmds.add(b.kf(b.id('divider'), 'trim', tDiv + 0.25, [0, 100]));
  cmds.add(b.fx(b.id('divider'), 'glow', {'amount': 40, 'radius': 12}));
  final sw = _dhSfx(b, 'whoosh', tWipe + 0.15); // whoosh peaks 0.38 s in: never before the component
  if (sw != null) cmds.add(sw);
  // labels, value bars, notes
  final lfs = b.n('label_size', h * 0.065);
  for (int i = 0; i < 2; i++) {
    final s = specs[i];
    final cx = horiz ? w / 2 : (i == 0 ? w * 0.25 : w * 0.75);
    final cy = horiz ? (i == 0 ? h * 0.25 : h * 0.75) : h * 0.3;
    final label = '${s['label'] ?? ''}'.toUpperCase();
    final tl = tWipe + 0.45 + i * 0.25;
    if (label.isNotEmpty && tl < b.end) {
      final lid = b.id('label$i');
      cmds.add({...b.text('label$i', label, w * 0.45, lfs * 1.3, cx, cy, lfs, color: '#FFFFFF', weight: 900), 'font': 'Poppins', 'shadow': true, 'start': tl, 'duration': b.end - tl});
      cmds.addAll(_dhPop(b, lid, tl, over: 110, dur: 0.3));
    }
    final v = values[i];
    final tb = tl + 0.3;
    if (v != null && tb < b.end) {
      final full = w * (horiz ? 0.5 : 0.36);
      final bw = maxV <= 0 ? full : full * (v.abs() / maxV).clamp(0.02, 1.0);
      final bh = h * 0.034;
      final by = cy + lfs * 1.05;
      final bx = cx - full / 2;
      final bid = b.id('bar$i');
      cmds.add({...b.shape('bar$i', 'rect', bw, bh, bx + bw / 2, by, fill: '${s['bar_color'] ?? dColor}', corner: bh * 0.2), 'start': tb, 'duration': b.end - tb});
      cmds.add(b.setp(bid, 'anchor', [0, bh / 2, 0]));
      cmds.add(b.setp(bid, 'position', [bx, by, 0]));
      cmds.add(b.kf(bid, 'scale', tb, [0, 100, 100], 'ease_out'));
      cmds.add(b.kf(bid, 'scale', tb + 0.6, [100, 100, 100]));
      final vt = '${s['value_text'] ?? '${_dhNumber(v, v == v.roundToDouble() ? 0 : 1)}${s['unit'] ?? b.str('unit', '')}'}';
      final vfs = lfs * 0.55;
      cmds.add({
        ...b.text('val$i', vt, w * 0.2, vfs * 1.3, bx + bw + vfs * 0.5 + w * 0.1, by, vfs, color: '#FFFFFF', weight: 800, align: 'left'),
        'font': 'Poppins', 'shadow': true, 'start': tb + 0.45, 'duration': math.max(0.05, b.end - tb - 0.45),
        'animator': 'typewriter', 'anim_duration': 0.3,
      });
    }
    final note = '${s['note'] ?? ''}';
    final tn = tb + 0.7;
    if (note.isNotEmpty && tn < b.end) {
      final nfs = lfs * 0.38;
      cmds.add({
        ...b.text('note$i', note, w * 0.4, nfs * 2.8, cx, cy + lfs * 1.05 + h * 0.06, nfs, color: '#E8E8E8', weight: 600),
        'font': 'Poppins', 'shadow': true, 'start': tn, 'duration': b.end - tn, 'animator': 'fade_up', 'anim_duration': 0.4,
      });
    }
  }
  return b.finish(cmds, enter: 'none', exit: null)..addAll(_dhFadeOutChildren(b, cmds, 0.3));
}

// ------------------------------------------------------------ 25 gauge_hud

/// Edge tick ruler with value labels scrolling under a fixed red pointer.
List<Map<String, dynamic>> _gaugeHud(_B b) {
  final side = b.str('side', 'right');
  final vertical = b.str('orientation', 'vertical') != 'horizontal';
  final from = b.n('from', 20000), to = b.n('to', 12000);
  final step = b.n('step', 1000).abs().clamp(1e-6, 1e12).toDouble();
  final every = b.n('label_every', 1).round().clamp(1, 100);
  final unit = b.str('unit', 'FT');
  final pColor = b.str('pointer_color', '#E01010');
  final color = b.str('color', '#FFFFFF');
  final win = vertical ? b.n('height', b.h * 0.7) : b.n('width', b.w * 0.6);
  final spacing = b.n('spacing', (vertical ? b.h : b.w) * 0.09);
  final fs = b.n('label_size', b.h * 0.022);
  final x = b.n('x', vertical ? (side == 'left' ? b.w * 0.105 : b.w * 0.895) : b.w * 0.5);
  final y = b.n('y', vertical ? b.h * 0.5 : (side == 'top' ? b.h * 0.1 : b.h * 0.9));
  final t0 = b.start + b.n('delay', 0.3);
  final scroll = b.n('scroll', math.max(0.5, b.dur - 0.9));
  final dir = side == 'left' || side == 'top' ? -1.0 : 1.0; // ticks grow toward the frame edge
  final cmds = b.group('Gauge HUD', x: x, y: y);
  // soft window matte (blurred rect) so the scale fades at both ends
  final mw = vertical ? fs * 14 : win, mh = vertical ? win : fs * 6;
  cmds.add({...b.shape('window', 'rect', mw, mh, vertical ? -dir * fs * 4 : 0, vertical ? 0 : -dir * fs * 1.5, fill: '#FFFFFF'), 'name': 'Gauge window'});
  cmds.add(b.fx(b.id('window'), 'blur', {'amount': 100}));
  cmds.addAll(b.nul('tape', 0, 0, name: 'Tape'));
  final tape = b.id('tape');
  final lo = math.min(from, to), hi = math.max(from, to);
  final extra = (win / spacing / 2).ceil() + 1;
  final major = <List<double>>[], minor = <List<double>>[];
  double pos(double v) => -(v - from) / step * spacing; // higher values up / left
  final labels = <(double, String)>[];
  var count = 0;
  final first = ((lo / step).floor() - extra), last = ((hi / step).ceil() + extra);
  for (var k = first; k <= last && count < 400; k++, count++) {
    final v = k * step;
    final at = pos(v);
    final len = fs * 1.2;
    major.add(vertical ? [0, at, dir * len, at] : [at, 0, at, dir * len]);
    for (int m = 1; m < 5; m++) {
      final a2 = at - m * spacing / 5;
      minor.add(vertical ? [0, a2, dir * len * 0.5, a2] : [a2, 0, a2, dir * len * 0.5]);
    }
    if (k % every == 0) labels.add((at, '${_dhNumber(v, step < 1 ? 1 : 0).replaceAll(',', '')} $unit'.trim()));
  }
  cmds.add({...b.path('major', const [[0, 0], [1, 0]], parent: tape, stroke: color, width: math.max(2.0, fs * 0.12)), 'points': null, 'rings': major});
  cmds.add({...b.path('minor', const [[0, 0], [1, 0]], parent: tape, stroke: color, width: math.max(1.0, fs * 0.07)), 'points': null, 'rings': minor});
  final layerIds = [b.id('major'), b.id('minor')];
  for (int i = 0; i < labels.length; i++) {
    final (at, s) = labels[i];
    final tw = fs * 7.5;
    final lx = vertical ? -dir * (fs * 0.6 + tw / 2) : at;
    final ly = vertical ? at : -dir * fs * 1.2;
    cmds.add({
      ...b.text('lab$i', s, tw, fs * 1.4, lx, ly, fs, color: color, weight: 700, align: vertical ? (dir > 0 ? 'right' : 'left') : 'center'),
      'parent': tape, 'font': 'Share Tech Mono', 'shadow': true,
    });
    layerIds.add(b.id('lab$i'));
  }
  for (final id in layerIds) {
    cmds.add({'op': 'update_layer', 'layer': id, 'matte': {'layer': b.id('window'), 'mode': 'alpha'}});
  }
  // scroll so "to" ends under the pointer
  final endOff = (to - from) / step * spacing;
  cmds.add(b.kf(tape, 'position', t0, [0, 0, 0], 'easy_ease'));
  cmds.add(b.kf(tape, 'position', t0 + scroll, vertical ? [0, endOff, 0] : [endOff, 0, 0]));
  // fixed pointer
  final ps = fs * 0.9;
  final List<List<double>> tri = vertical
      ? [[-dir * ps * 0.1, 0], [dir * ps * 1.4, -ps * 0.75], [dir * ps * 1.4, ps * 0.75]]
      : [[0, -dir * ps * 0.1], [-ps * 0.75, dir * ps * 1.4], [ps * 0.75, dir * ps * 1.4]];
  final px = vertical ? dir * fs * 1.5 : 0.0, py = vertical ? 0.0 : dir * fs * 1.5;
  cmds.add(b.path('pointer', [for (final q in tri) [q[0] + px, q[1] + py]], fill: pColor, stroke: 'none', width: 0, closed: true));
  cmds.add(b.fx(b.id('pointer'), 'glow', {'amount': 55, 'radius': 12}));
  cmds.add(b.path('pline', vertical ? [[-dir * fs * 0.4, 0], [dir * fs * 1.5, 0]] : [[0, -dir * fs * 0.4], [0, dir * fs * 1.5]], stroke: pColor, width: math.max(2.0, fs * 0.1)));
  return b.finish(cmds, enter: 'fade_children', exit: null)..addAll(_dhFadeOutChildren(b, cmds, 0.4));
}

// ----------------------------------------------------------- 30 icon_sticker

/// Yellow sticker disc beside the presenter; icons pop and squash-morph to
/// the next one on each spoken noun.
List<Map<String, dynamic>> _iconSticker(_B b, Project p) {
  var items = b.specs('items', 'icon');
  if (items.isEmpty) items = [{'icon': 'plane'}, {'icon': 'radio', 'at': 1.4}];
  final size = b.n('size', b.h * 0.13);
  final color = b.str('color', '#FFE500');
  final iconColor = b.str('icon_color', '#111111');
  final swap = b.str('swap', 'squash');
  final cmds = b.group('Icon Sticker', x: b.n('x', b.w * 0.8), y: b.n('y', b.h * 0.45));
  final disc = b.id('disc');
  cmds.add(b.shape('disc', 'ellipse', size, size, 0, 0, fill: color, fill2: _shade(color, 0.86)));
  cmds.add(b.fx(disc, 'shadow', {'distance': size * 0.05, 'blur': size * 0.12, 'opacity': 45}));
  cmds.addAll(_dhPop(b, disc, b.start, over: 115, dur: 0.3));
  final times = <double>[];
  for (int i = 0; i < items.length; i++) {
    times.add(b.start + _dhAt(items[i], i == 0 ? 0.2 : (times.last - b.start) + 1.2));
  }
  const sq = 0.12;
  for (int i = 0; i < items.length; i++) {
    final t = math.max(b.start + 0.12, times[i]);
    if (t >= b.end - 0.05) break;
    final next = i + 1 < items.length ? times[i + 1] : b.end;
    final en = math.min(b.end, i + 1 < items.length ? next + sq : b.end);
    final s = items[i];
    final icon = s['media'] ?? s['icon'] ?? s['text'];
    final part = 'i$i';
    cmds.addAll(_dhIcon(b, p, part, icon, 0, 0, size * 0.62,
        main: '${s['color'] ?? iconColor}',
        detail: color, accent: iconColor, st: t, du: math.max(0.05, en - t)));
    final gid = b.id(part);
    if (i == 0 || swap == 'pop') {
      cmds.addAll(_dhPop(b, gid, t, over: 115, dur: 0.25));
    } else if (swap == 'flip') {
      cmds.add(b.kf(gid, 'scale', t, [0, 100, 100], 'ease_out'));
      cmds.add(b.kf(gid, 'scale', t + sq, [100, 100, 100]));
    } else {
      cmds.add(b.kf(gid, 'scale', t, [130, 0, 100], 'ease_out'));
      cmds.add(b.kf(gid, 'scale', t + sq, [90, 115, 100], 'easy_ease'));
      cmds.add(b.kf(gid, 'scale', t + sq + 0.1, [100, 100, 100]));
    }
    if (i + 1 < items.length && next < b.end) {
      final out = switch (swap) { 'pop' => [0, 0, 100], 'flip' => [0, 100, 100], _ => [130, 0, 100] };
      cmds.add(b.kf(gid, 'scale', next - sq, [100, 100, 100], 'ease_in'));
      cmds.add(b.kf(gid, 'scale', next, out));
      if (swap == 'squash') {
        cmds.add(b.kf(disc, 'scale', next - sq, [100, 100, 100], 'ease_in'));
        cmds.add(b.kf(disc, 'scale', next, [112, 88, 100], 'easy_ease'));
        cmds.add(b.kf(disc, 'scale', next + sq, [96, 104, 100], 'easy_ease'));
        cmds.add(b.kf(disc, 'scale', next + sq + 0.12, [100, 100, 100]));
      }
    }
    final pop = _dhSfx(b, 'pop', t);
    if (pop != null) cmds.add(pop);
  }
  return b.finish(cmds, enter: 'none', exit: 'pop');
}

// ------------------------------------------------------------- 31 icon_drop

/// Big vector icon dropping from the top with a bounce (or rising).
List<Map<String, dynamic>> _iconDrop(_B b, Project p) {
  final size = b.n('size', b.h * 0.22);
  final x = b.n('x', b.w * 0.5), y = b.n('y', b.h * 0.5);
  final icon = b.c['media'] ?? b.c['preset'] ?? b.str('icon', 'stop');
  final rise = b.str('enter', 'drop') == 'rise';
  final bounce = b.flag('bounce', true);
  final cmds = b.group('Icon Drop', x: x, y: y);
  cmds.addAll(_dhIcon(b, p, 'icon', icon, 0, 0, size,
      main: b.c['color'] as String?, detail: b.c['detail_color'] as String?, shadow: b.flag('shadow', true)));
  final t = b.start;
  double land;
  if (rise) {
    land = t + 0.5;
    cmds.add(b.kf(b.g, 'position', t, [x, b.h + size, 0], 'back'));
    cmds.add(b.kf(b.g, 'position', land, [x, y, 0]));
  } else if (bounce) {
    land = t + 0.75 / 2.75;
    cmds.add(b.kf(b.g, 'position', t, [x, -size, 0], 'bounce'));
    cmds.add(b.kf(b.g, 'position', t + 0.75, [x, y, 0]));
  } else {
    land = t + 0.32;
    cmds.add(b.kf(b.g, 'position', t, [x, -size, 0], 'ease_in'));
    cmds.add(b.kf(b.g, 'position', land, [x, y, 0]));
    cmds.add(b.kf(b.g, 'scale', land, [100, 100, 100], 'ease_out'));
    cmds.add(b.kf(b.g, 'scale', land + 0.08, [112, 88, 100], 'easy_ease'));
    cmds.add(b.kf(b.g, 'scale', land + 0.24, [100, 100, 100]));
  }
  final s = _dhSfx(b, 'pop', land);
  if (s != null) cmds.add(s);
  return b.finish(cmds, enter: 'none', exit: 'pop');
}

// ------------------------------------------------------- 32 / 64 social_cta

const _dhPlatforms = {
  'youtube': ('YouTube', '#FF0000', 'SUBSCRIBE ON'),
  'whatsapp': ('WhatsApp', '#25D366', 'JOIN US ON'),
  'facebook': ('Facebook', '#1877F2', 'FOLLOW US ON'),
  'twitter': ('Twitter', '#1DA1F2', 'FOLLOW US ON'),
  'x': ('X', '#111111', 'FOLLOW US ON'),
  'instagram': ('Instagram', '#E1306C', 'FOLLOW US ON'),
  'telegram': ('Telegram', '#2AABEE', 'JOIN US ON'),
};

/// Our own simple platform glyph on a plate (no logos copied).
List<Map<String, dynamic>> _dhPlatformGlyph(_B b, String platform, String color, double s) {
  final cmds = <Map<String, dynamic>>[];
  final r = s / 2;
  String id(String part) => 'gl_$part';
  switch (platform) {
    case 'youtube':
      cmds.add(b.shape(id('plate'), 'rect', s * 1.3, s * 0.92, 0, 0, fill: color, fill2: _shade(color, 0.8), corner: s * 0.24));
      cmds.add(b.path(id('play'), [[-r * 0.32, -r * 0.4], [r * 0.48, 0], [-r * 0.32, r * 0.4]], fill: '#FFFFFF', stroke: 'none', width: 0, closed: true));
    case 'instagram':
      cmds.add(b.shape(id('plate'), 'rect', s, s, 0, 0, fill: '#C13584', fill2: '#F77737', corner: s * 0.26));
      cmds.add(b.shape(id('frame'), 'rect', s * 0.68, s * 0.68, 0, 0, fill: 'none', stroke: '#FFFFFF', strokeWidth: s * 0.07, corner: s * 0.2));
      cmds.add(b.shape(id('lens'), 'ellipse', s * 0.32, s * 0.32, 0, 0, fill: 'none', stroke: '#FFFFFF', strokeWidth: s * 0.07));
      cmds.add(b.shape(id('dot'), 'ellipse', s * 0.08, s * 0.08, s * 0.19, -s * 0.19, fill: '#FFFFFF'));
    case 'whatsapp':
      cmds.add(b.shape(id('plate'), 'ellipse', s, s, 0, 0, fill: color, fill2: _shade(color, 0.8)));
      cmds.add(b.shape(id('ring'), 'ellipse', s * 0.62, s * 0.62, 0, -s * 0.02, fill: 'none', stroke: '#FFFFFF', strokeWidth: s * 0.065));
      cmds.add(b.path(id('tail'), [[-r * 0.5, r * 0.28], [-r * 0.66, r * 0.68], [-r * 0.2, r * 0.52]], fill: '#FFFFFF', stroke: 'none', width: 0, closed: true));
      cmds.add(b.path(id('phone'), [[-r * 0.2, -r * 0.24], [-r * 0.06, r * 0.04], [r * 0.2, r * 0.22]], stroke: '#FFFFFF', width: s * 0.09));
    case 'telegram':
      cmds.add(b.shape(id('plate'), 'ellipse', s, s, 0, 0, fill: color, fill2: _shade(color, 0.8)));
      cmds.add(b.path(id('plane'), [[-r * 0.52, -r * 0.02], [r * 0.5, -r * 0.42], [r * 0.3, r * 0.48], [r * 0.02, r * 0.2], [-r * 0.12, r * 0.42], [-r * 0.14, r * 0.12]],
          fill: '#FFFFFF', stroke: 'none', width: 0, closed: true));
    case 'x':
    case 'twitter':
      cmds.add(b.shape(id('plate'), 'ellipse', s, s, 0, 0, fill: color, fill2: _shade(color, 0.8)));
      cmds.add({...b.path(id('x'), const [[0, 0], [1, 0]], stroke: '#FFFFFF', width: s * 0.08), 'points': null,
        'rings': [[-r * 0.36, -r * 0.36, r * 0.36, r * 0.36], [r * 0.36, -r * 0.36, -r * 0.36, r * 0.36]]});
    default: // facebook / custom: plate + bold initial
      cmds.add(b.shape(id('plate'), platform == 'facebook' ? 'ellipse' : 'rect', s, s, 0, 0, fill: color, fill2: _shade(color, 0.8), corner: s * 0.24));
      final src = b.str('line2', b.str('platform', '?'));
      final ch = platform == 'facebook' ? 'f' : b.str('glyph', src.isEmpty ? '?' : src.substring(0, 1).toUpperCase());
      cmds.add({...b.text(id('glyph'), ch, s, s, 0, s * 0.04, s * 0.68, color: '#FFFFFF', weight: 900), 'font': 'Poppins'});
  }
  return cmds;
}

/// Platform icon + 2-line white caps ("JOIN US ON / WhatsApp") with a
/// platform-colour swoosh; in 0.4 s, hold, out 0.3 s. social_bug: exits
/// with a pixel break-up.
List<Map<String, dynamic>> _socialCta(_B b0, {required bool bug}) {
  final platform = '${b0.c['platform'] ?? 'youtube'}'.toLowerCase();
  final info = _dhPlatforms[platform];
  final hold = b0.n('hold', 2.8);
  final b = b0.c['duration'] == null ? _B(b0.w, b0.h, {...b0.c, 'duration': 0.4 + hold + 0.3}, b0.now, b0.root) : b0;
  final color = b.str('color', info?.$2 ?? '#E53935');
  final s = b.n('size', b.h * 0.075);
  final cmds = b.group(bug ? 'Social Bug' : 'Social Call-out', x: b.n('x', b.w * 0.78), y: b.n('y', b.h * 0.7));
  // swoosh behind the text
  final line1 = b.str('line1', info?.$3 ?? 'FOLLOW US ON').toUpperCase();
  final line2 = b.str('line2', info?.$1 ?? b.str('platform', 'Custom'));
  final handle = b.str('handle', 'Mohitflix');
  final f1 = s * 0.3, f2 = s * 0.5, f3 = s * 0.27;
  final tw = math.max(line1.length * f1 * 0.66, math.max(line2.length * f2 * 0.62, (handle.length + 1) * f3 * 0.6)) + s * 0.3;
  final tx = s * 0.72;
  final sw = b.id('swoosh');
  cmds.add({
    ...b.path('swoosh', [[-s * 0.2, s * 0.42], [tx + tw * 0.45, s * 0.18], [tx + tw + s * 0.25, -s * 0.3]], stroke: color, width: s * 0.5, smooth: true),
    'name': 'Swoosh',
  });
  cmds.add(b.setp(sw, 'opacity', 85));
  cmds.add(b.kf(sw, 'trim', b.start + 0.05, [0, 0], 'ease_out'));
  cmds.add(b.kf(sw, 'trim', b.start + 0.4, [0, 100]));
  for (final m in _dhPlatformGlyph(b, platform, color, s)) {
    cmds.add(m);
  }
  final glyphIds = [for (final m in cmds) if (m['op'] == 'add_layer' && '${m['id']}'.contains('_gl_')) m['id'] as String];
  cmds.addAll(b.nul('glyph_g', 0, 0, name: 'Glyph'));
  for (final gid in glyphIds) {
    cmds.add({'op': 'update_layer', 'layer': gid, 'parent': b.id('glyph_g')});
  }
  if (glyphIds.isNotEmpty) cmds.add(b.fx(glyphIds.first, 'shadow', {'distance': s * 0.04, 'blur': s * 0.1, 'opacity': 45}));
  cmds.addAll(_dhPop(b, b.id('glyph_g'), b.start, over: 115, dur: 0.3));
  final hasHandle = handle.isNotEmpty && handle != 'none';
  final y1 = hasHandle ? -s * 0.42 : -s * 0.26, y2 = hasHandle ? s * 0.02 : s * 0.18, y3 = s * 0.45;
  final t1 = b.start + 0.1;
  cmds.add({
    ...b.text('l1', line1, tw, f1 * 1.3, tx + tw / 2, y1, f1, color: '#FFFFFF', weight: 800, align: 'left'),
    'font': 'Poppins', 'shadow': true, 'start': t1, 'duration': b.end - t1, 'animator': 'fade_up', 'anim_duration': 0.3,
  });
  cmds.add({
    ...b.text('l2', line2, tw, f2 * 1.3, tx + tw / 2, y2, f2, color: '#FFFFFF', weight: 900, align: 'left'),
    'font': 'Poppins', 'shadow': true, 'start': t1 + 0.08, 'duration': b.end - t1 - 0.08, 'animator': 'fade_up', 'anim_duration': 0.3,
  });
  if (hasHandle) {
    cmds.add({
      ...b.text('l3', '@$handle', tw, f3 * 1.3, tx + tw / 2, y3, f3, color: '#F2F2F2', weight: 700, align: 'left'),
      'font': 'Poppins', 'shadow': true, 'start': t1 + 0.18, 'duration': b.end - t1 - 0.18, 'animator': 'typewriter', 'anim_duration': 0.35,
    });
  }
  final pop = _dhSfx(b, 'pop', b.start + 0.05);
  if (pop != null) cmds.add(pop);
  final exit = b.str('exit', bug ? 'disintegrate' : 'fade');
  const out = 0.3;
  final te = b.end - out;
  if (exit == 'disintegrate') {
    for (final m in List.of(cmds)) {
      if (m['op'] != 'add_layer' || m['type'] == 'null' || m['type'] == 'audio') continue;
      final id = m['id'] as String;
      final fx = '${id}_break';
      cmds.add(b.fx(id, 'disintegrate', {'size': math.max(3, s * 0.07), 'drift': 60}, fx));
      cmds.add({'op': 'set_keyframe', 'target': id, 'effect': fx, 'prop': 'progress', 'time': te, 'value': 0, 'ease': 'ease_in'});
      cmds.add({'op': 'set_keyframe', 'target': id, 'effect': fx, 'prop': 'progress', 'time': b.end, 'value': 100});
    }
    final g = _dhSfx(b, 'glitch', te + 0.05);
    if (g != null) cmds.add(g);
    return b.finish(cmds, enter: 'none', exit: null);
  }
  if (exit == 'none') return b.finish(cmds, enter: 'none', exit: null);
  if (exit == 'fade') return b.finish(cmds, enter: 'none', exit: null)..addAll(_dhFadeOutChildren(b, cmds, out));
  return [...b.finish(cmds, enter: 'none', exit: null), {'op': 'animate_out', 'layer': b.g, 'preset': exit, 'duration': out}];
}

// ------------------------------------------------------------- 28 ui_toggle

/// iOS-style pill toggle: grey OFF → green ON (knob slides 0.15 s, 105 % bump).
List<Map<String, dynamic>> _uiToggle(_B b) {
  final w = _dhFrac(b.n('size', 0.1), b.w);
  final h = b.n('height', w * 0.5);
  final onColor = b.str('on_color', '#2ECC40'), offColor = b.str('off_color', '#8E8E93');
  final startOn = b.str('from', 'off') == 'on';
  final endOn = b.str('to', startOn ? 'off' : 'on') == 'on';
  final at = b.start + b.n('at', 0.5);
  final cmds = b.group('UI Toggle');
  cmds.add(b.shape('track_off', 'rect', w, h, 0, 0, fill: offColor, fill2: _shade(offColor, 0.85), corner: h / 2));
  final on = b.id('track_on');
  cmds.add(b.shape('track_on', 'rect', w, h, 0, 0, fill: onColor, fill2: _shade(onColor, 0.85), corner: h / 2));
  final kd = h * 0.84;
  final kx0 = (startOn ? 1 : -1) * (w / 2 - h / 2), kx1 = (endOn ? 1 : -1) * (w / 2 - h / 2);
  final knob = b.id('knob');
  cmds.add(b.shape('knob', 'ellipse', kd, kd, kx0, 0, fill: '#FFFFFF', fill2: '#E6E6E6'));
  cmds.add(b.fx(knob, 'shadow', {'distance': h * 0.05, 'blur': h * 0.12, 'opacity': 45}));
  cmds.add(b.setp(on, 'opacity', startOn ? 100 : 0));
  if (startOn != endOn && at < b.end) {
    cmds.add(b.kf(on, 'opacity', at, startOn ? 100 : 0, 'easy_ease'));
    cmds.add(b.kf(on, 'opacity', at + 0.15, endOn ? 100 : 0));
    cmds.add(b.kf(knob, 'position', at, [kx0, 0, 0], 'ease_out'));
    cmds.add(b.kf(knob, 'position', at + 0.15, [kx1, 0, 0]));
    cmds.add(b.kf(knob, 'scale', at + 0.12, [100, 100, 100], 'ease_out'));
    cmds.add(b.kf(knob, 'scale', at + 0.18, [105, 105, 100], 'easy_ease'));
    cmds.add(b.kf(knob, 'scale', at + 0.3, [100, 100, 100]));
    final s = _dhSfx(b, 'ui_click', at);
    if (s != null) cmds.add(s);
  }
  final label = b.str('label', '');
  if (label.isNotEmpty) {
    final fs = h * 0.5;
    final lw = label.length * fs * 0.66 + fs;
    cmds.add({...b.text('label', label.toUpperCase(), lw, fs * 1.3, -w / 2 - fs * 0.6 - lw / 2, 0, fs, color: '#FFFFFF', weight: 900, align: 'right'), 'font': 'Poppins', 'shadow': true});
  }
  final labels = b.c['labels'];
  if (labels == true || labels is List) {
    final names = labels is List && labels.length >= 2 ? ['${labels[0]}', '${labels[1]}'] : ['OFF', 'ON'];
    final fs = h * 0.34;
    for (final st in [false, true]) {
      final id = st ? 'on_txt' : 'off_txt';
      final tx = st ? -w * 0.18 : w * 0.18;
      cmds.add({...b.text(id, names[st ? 1 : 0], w * 0.5, fs * 1.3, tx, 0, fs, color: '#FFFFFF', weight: 900), 'font': 'Poppins'});
      final visibleStart = st == startOn;
      cmds.add(b.setp(b.id(id), 'opacity', visibleStart ? 100 : 0));
      if (startOn != endOn && at < b.end) {
        cmds.add(b.kf(b.id(id), 'opacity', at, visibleStart ? 100 : 0, 'easy_ease'));
        cmds.add(b.kf(b.id(id), 'opacity', at + 0.15, visibleStart ? 0 : 100));
      }
    }
  }
  return b.finish(cmds, enter: 'pop');
}

// ------------------------------------------------------------ 29 audio_wave

/// Waveform card: rounded bars dancing (deterministic), centre-weighted.
List<Map<String, dynamic>> _audioWave(_B b) {
  final ww = _dhFrac(b.n('width', 0.42), b.w), hh = _dhFrac(b.n('height', 0.16), b.h);
  final bars = b.n('bars', 40).round().clamp(4, 120);
  final color = b.str('color', '#7FB2FF'), bg = b.str('bg', '#0B1E6B');
  final speed = b.n('speed', 1).clamp(0.1, 5).toDouble();
  final levels = b.c['levels'] is List ? [for (final v in b.c['levels'] as List) (v as num).toDouble().clamp(0.0, 1.0).toDouble()] : const <double>[];
  final cmds = b.group('Audio Wave');
  if (b.flag('card', true)) {
    cmds.add(b.shape('card', 'rect', ww, hh, 0, 0, fill: bg, fill2: _shade(bg, 0.7), stroke: _alpha(color, 0x55), strokeWidth: math.max(1.5, hh * 0.012), corner: hh * 0.18));
    cmds.add(b.fx(b.id('card'), 'shadow', {'distance': hh * 0.06, 'blur': hh * 0.15, 'opacity': 50}));
  }
  final inner = ww * 0.86;
  final pitch = inner / bars;
  final bw = pitch * 0.58;
  final maxH = hh * 0.72;
  final step = math.max(0.11 / speed, b.dur / 36);
  final seed = b.root.hashCode & 0xFFFF;
  double noise(int i, int k) {
    final v = math.sin((i * 12.9898 + k * 78.233 + seed) * 0.5) * 43758.5453;
    return v - v.floorToDouble();
  }

  for (int i = 0; i < bars; i++) {
    final x = -inner / 2 + pitch * (i + 0.5);
    final env = levels.isNotEmpty ? levels[i % levels.length] : 0.35 + 0.65 * math.pow(math.sin(math.pi * (i + 0.5) / bars), 1.4).toDouble();
    final id = b.id('b$i');
    cmds.add(b.shape('b$i', 'rect', bw, maxH, x, 0, fill: color, corner: bw / 2));
    var k = 0;
    for (var t = b.start; t <= b.end + 1e-6; t += step, k++) {
      final q = math.max(0.06, env * (0.25 + 0.75 * noise(i, k)));
      cmds.add(b.kf(id, 'scale', t, [100, q * 100, 100], 'easy_ease'));
    }
  }
  final label = b.str('label', '');
  if (label.isNotEmpty) {
    final fs = hh * 0.2;
    cmds.add({
      ...b.text('label', label.toUpperCase(), ww, fs * 1.4, 0, hh / 2 + fs * 1.1, fs, color: '#FFFFFF', weight: 800),
      'font': 'Poppins', 'shadow': true, 'animator': 'typewriter', 'anim_duration': math.min(0.8, label.length * 0.04 + 0.1),
    });
  }
  return b.finish(cmds, enter: 'pop');
}

// ------------------------------------------------------------ 29 flag_badge

/// Round country flag badge (simple drawn flag, else colour disc + code).
List<Map<String, dynamic>> _flagBadge(_B b) {
  final size = b.n('size', b.h * 0.12);
  final country = b.str('country', 'IN');
  final flag = Flags.find(country);
  final cmds = b.group('Flag Badge');
  final k = size / 100;
  if (flag != null) {
    cmds.add(b.shape('base', 'ellipse', size * 0.98, size * 0.98, 0, 0, fill: '#202020'));
    final matte = b.id('clip');
    cmds.add({...b.shape('clip', 'ellipse', size, size, 0, 0, fill: '#FFFFFF'), 'name': 'Flag circle'});
    var n = 0;
    for (final part in flag.parts) {
      final id = b.id('f${n++}');
      cmds.add({
        'op': 'add_layer', 'type': 'shape', 'id': id, 'parent': b.g, 'start': b.start, 'duration': b.dur, 'name': '${flag.name} ${part.color}',
        'rings': [for (final r in part.rings) [for (int i = 0; i < r.length; i++) (r[i] - 50) * k]], 'closed': true,
        'fill': part.color, 'stroke': 'none', 'stroke_width': 0,
      });
      cmds.add({'op': 'update_layer', 'layer': id, 'matte': {'layer': matte, 'mode': 'alpha'}});
    }
    cmds.add(b.shape('gloss', 'ellipse', size * 0.8, size * 0.42, 0, -size * 0.22, fill: '#30FFFFFF', fill2: '#00FFFFFF'));
  } else {
    const palette = ['#1E40D0', '#C62828', '#2E7D32', '#6A1B9A', '#EF6C00', '#00838F'];
    final code = Flags.codeFor(country);
    cmds.add(b.shape('disc', 'ellipse', size, size, 0, 0, fill: b.str('color', palette[code.hashCode.abs() % palette.length])));
    cmds.add({...b.text('code', code, size, size * 0.5, 0, 0, size * 0.34, color: '#FFFFFF', weight: 900), 'font': 'Poppins'});
  }
  final ring = b.str('ring', '#FFFFFF');
  if (ring != 'none') cmds.add(b.shape('ring', 'ellipse', size, size, 0, 0, fill: 'none', stroke: ring, strokeWidth: b.n('ring_width', size * 0.05)));
  cmds.add(b.fx(b.id(flag != null ? 'base' : 'disc'), 'shadow', {'distance': size * 0.05, 'blur': size * 0.12, 'opacity': 50}));
  final label = b.str('label', '');
  if (label.isNotEmpty) {
    final fs = size * 0.2;
    final text = label == 'true' ? (flag?.name ?? country) : label;
    cmds.add({...b.text('label', text.toUpperCase(), size * 3, fs * 1.4, 0, size * 0.5 + fs * 1.1, fs, color: '#FFFFFF', weight: 900), 'font': 'Poppins', 'shadow': true});
  }
  return b.finish(cmds, enter: 'pop');
}

// -------------------------------------------------------- 33 presenter_stats

/// Stacked bold stat lines in the right third beside the presenter, each
/// typed when it is spoken.
List<Map<String, dynamic>> _presenterStats(_B b) {
  var lines = b.specs('lines', 'text');
  if (lines.isEmpty) lines = [{'text': '72 DAYS'}, {'text': '16 SURVIVORS', 'at': 1.4}];
  final size = b.n('size', b.h * 0.03);
  final x = b.n('x', b.w * 0.67), y = b.n('y', b.h * 0.3);
  final gap = b.n('gap', 1.6);
  final color = b.str('color', '#FFFFFF');
  final cps = b.n('cps', 22).clamp(4, 80).toDouble();
  final animator = b.str('animator', 'typewriter');
  final cmds = b.group('Presenter Stats', x: 0, y: 0);
  var prev = 0.0;
  for (int i = 0; i < lines.length; i++) {
    final text = '${lines[i]['text'] ?? ''}'.toUpperCase();
    final at = b.start + _dhAt(lines[i], i == 0 ? 0.2 : prev + 0.9);
    prev = at - b.start + text.length / cps;
    if (at >= b.end - 0.05 || text.isEmpty) continue;
    final fs = (lines[i]['size'] as num?)?.toDouble() ?? size;
    cmds.add({
      ...b.text('s$i', text, b.w * 0.3, fs * 1.35, x + b.w * 0.15, y + i * size * gap, fs, color: '${lines[i]['color'] ?? color}', weight: 800, align: 'left'),
      'font': 'Poppins', 'shadow': true, 'start': at, 'duration': b.end - at,
      'animator': animator, 'anim_duration': math.max(0.15, text.length / cps),
      if (lines[i]['lead_color'] != null || b.c['lead_color'] != null) 'lead_color': lines[i]['lead_color'] ?? b.c['lead_color'],
    });
    if (animator == 'typewriter' && i < 6) {
      final s = _dhSfx(b, 'typewriter', at, duration: math.max(0.15, text.length / cps));
      if (s != null) cmds.add(s);
    }
  }
  return b.finish(cmds, enter: 'none', exit: null)..addAll(_dhFadeOutChildren(b, cmds, 0.3));
}

// ---------------------------------------------- 33 lower_third bar_wipe

/// Gradient bar wiping L→R (0.25 s) with typed text; slides down on exit.
List<Map<String, dynamic>> _lowerThirdBarWipe(_B b) {
  final w = _dhFrac(b.n('width', 0.42), b.w), h = b.n('height', b.h * 0.062);
  final x = b.n('x', b.w * 0.05), y = b.n('y', b.h * 0.86);
  final grad = b.c['gradient'] is List && (b.c['gradient'] as List).length >= 2
      ? ['${(b.c['gradient'] as List)[0]}', '${(b.c['gradient'] as List)[1]}']
      : [b.str('color', '#E53935'), b.str('color2', '#7A0F2B')];
  final text = b.str('text', b.str('source', 'SUBSCRIBE FOR MORE'));
  final fs = b.n('size', h * 0.48);
  final cmds = b.group('Bar Lower Third', x: x, y: y);
  final bar = b.id('bar');
  // a rect turned −90° so its top→bottom gradient runs left→right
  cmds.add(b.shape('bar', 'rect', h, w, w / 2, 0, fill: grad[0], fill2: grad[1], corner: h * 0.12));
  cmds.add(b.setp(bar, 'rotation', [0, 0, -90]));
  cmds.add(b.setp(bar, 'anchor', [h / 2, 0, 0]));
  cmds.add(b.setp(bar, 'position', [0, 0, 0]));
  cmds.add(b.kf(bar, 'scale', b.start, [100, 0, 100], 'ease_out'));
  cmds.add(b.kf(bar, 'scale', b.start + 0.25, [100, 100, 100]));
  cmds.add(b.fx(bar, 'shadow', {'distance': h * 0.08, 'blur': h * 0.2, 'opacity': 45}));
  final t1 = b.start + 0.2;
  cmds.add({
    ...b.text('txt', text.toUpperCase(), w - fs, h, w / 2 + fs * 0.2, 0, fs, color: '#FFFFFF', weight: 900, align: 'left'),
    'font': 'Poppins', 'start': t1, 'duration': b.end - t1,
    'animator': b.str('animator', 'typewriter'), 'anim_duration': math.min(1.0, text.length * 0.035 + 0.1),
  });
  final kicker = b.str('kicker', '');
  if (kicker.isNotEmpty) {
    final kf = fs * 0.62;
    cmds.add({
      ...b.text('kicker', kicker.toUpperCase(), w, kf * 1.4, w / 2, -h / 2 - kf * 0.9, kf, color: grad[0], weight: 800, align: 'left'),
      'font': 'Poppins', 'shadow': true, 'start': t1, 'duration': b.end - t1, 'animator': 'fade_up', 'anim_duration': 0.3,
    });
  }
  final te = b.end - 0.4;
  cmds.add(b.kf(b.g, 'position', te, [x, y, 0], 'ease_in'));
  cmds.add(b.kf(b.g, 'position', b.end, [x, y + h * 2.6, 0]));
  return b.finish(cmds, enter: 'none', exit: null)..addAll(_dhFadeOutChildren(b, cmds, 0.4));
}

// ------------------------------------------------------- 33 info_card

/// Dark glass card bottom-left: title + detail lines (script / date / address).
List<Map<String, dynamic>> _infoCard(_B b) {
  final title = b.str('title', 'EVENT TITLE');
  var lines = b.list('lines');
  if (lines.isEmpty) lines = ['13 OCT 1972', 'MONTEVIDEO, URUGUAY'];
  final w = _dhFrac(b.n('width', 0.3), b.w);
  final tfs = b.n('title_size', b.h * 0.032), lfs = b.n('size', b.h * 0.022);
  final pad = tfs * 0.8;
  final h = pad * 2 + tfs * 1.3 + lines.length * lfs * 1.55;
  final x = b.n('x', b.w * 0.04 + w / 2), y = b.n('y', b.h * 0.92 - h / 2);
  final accent = b.str('accent', '#2EE6E6');
  final cmds = b.group('Info Card', x: x, y: y);
  cmds.add(b.shape('glass', 'rect', w, h, 0, 0, fill: '#C0161B24', fill2: '#A00A0D12', stroke: '#40FFFFFF', strokeWidth: math.max(1.5, h * 0.008), corner: h * 0.08));
  cmds.add(b.fx(b.id('glass'), 'shadow', {'distance': h * 0.05, 'blur': h * 0.16, 'opacity': 55}));
  cmds.add(b.shape('sheen', 'rect', w * 0.98, h * 0.45, 0, -h * 0.26, fill: '#18FFFFFF', fill2: '#00FFFFFF', corner: h * 0.07));
  cmds.add(b.shape('accent', 'rect', math.max(3.0, w * 0.012), h - pad * 1.2, -w / 2 + pad * 0.55, 0, fill: accent, corner: 2));
  final tx = -w / 2 + pad * 1.2;
  var ty = -h / 2 + pad + tfs * 0.65;
  cmds.add({
    ...b.text('title', title.toUpperCase(), w - pad * 2, tfs * 1.3, tx + (w - pad * 2) / 2, ty, tfs, color: '#FFFFFF', weight: 900, align: 'left'),
    'font': 'Poppins', 'start': b.start + 0.15, 'duration': b.dur - 0.15, 'animator': 'typewriter', 'anim_duration': math.min(0.8, title.length * 0.035 + 0.1),
  });
  ty += tfs * 0.65 + lfs * 0.95;
  for (int i = 0; i < lines.length; i++) {
    final t = b.start + 0.45 + i * 0.22;
    cmds.add({
      ...b.text('line$i', lines[i], w - pad * 2, lfs * 1.4, tx + (w - pad * 2) / 2, ty + i * lfs * 1.55, lfs, color: '#D6DCE4', weight: 600, align: 'left'),
      'font': 'Poppins', 'start': t, 'duration': b.end - t, 'animator': 'fade_up', 'anim_duration': 0.35,
    });
  }
  cmds.add(b.kf(b.g, 'position', b.start, [x, y + b.h * 0.03, 0], 'ease_out'));
  cmds.add(b.kf(b.g, 'position', b.start + 0.5, [x, y, 0]));
  return b.finish(cmds, enter: 'fade_children', exit: null)..addAll(_dhFadeOutChildren(b, cmds, 0.35));
}

// ------------------------------------------------------------ 63 stat_title

/// Two-line stat title: small line + the number line 1.6× bigger.
List<Map<String, dynamic>> _statTitle(_B b) {
  final line1 = b.str('line1', 'HE SURVIVED');
  final line2 = b.str('line2', '72 DAYS');
  final emphasis = b.n('emphasis', 1.6).clamp(0.5, 4).toDouble();
  final fs = b.n('size', b.h * 0.06);
  final style = b.str('style', 'red_outline');
  final textStyle = switch (style) { 'yellow' => 'stat_yellow', 'red' || 'red_outline' => 'stat_red_outline', _ => null };
  final cmds = b.group('Stat Title', x: b.n('x', b.w * 0.5), y: b.n('y', b.h * 0.5));
  final f2 = fs * emphasis;
  final y1 = -(f2 * 1.15) / 2 - fs * 0.2, y2 = fs * 0.55;
  Map<String, dynamic> line(String part, String text, double size, double y, double t) {
    final base = {
      ...b.text(part, text.toUpperCase(), b.w * 0.9, size * 1.3, 0, y, size, color: style == 'yellow' ? '#FFE000' : '#FFFFFF', weight: 900),
      'start': t, 'duration': b.end - t,
    };
    if (textStyle != null) return _dhStyled(base, textStyle, extra: {'anim_duration': math.min(1.0, text.length * 0.06 + 0.2)});
    return {...base, 'font': 'Poppins', 'shadow': true, 'animator': 'typewriter_soft', 'anim_duration': math.min(1.0, text.length * 0.06 + 0.2)};
  }

  cmds.add(line('l1', line1, fs, y1, b.start));
  final t2 = b.start + b.n('at2', math.min(0.9, line1.length * 0.05 + 0.3));
  if (t2 < b.end) cmds.add(line('l2', line2, f2, y2, t2));
  return b.finish(cmds, enter: 'none', exit: null)..addAll(_dhFadeOutChildren(b, cmds, 0.3));
}
// <<< V3-C
