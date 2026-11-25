// win-30: general reusable documentary scenes (inspired by the 360 pack).
// Every template builds its own precomp (own 3D camera) from slots, so any
// images work: pieces, people, photos and maps are fitted, grounded and timed
// automatically. One comp layer is added to the main timeline.
import 'dart:math' as math;

import '../model/project.dart';
import 'templates.dart';

/// Keyframe inside a precomp (times relative to the precomp start).
Map<String, dynamic> _k(String comp, String target, String prop, double t, Object v, [String ease = 'easy_ease']) =>
    {'op': 'set_keyframe', 'in_comp': comp, 'target': target, 'prop': prop, 'time': t, 'value': v, 'ease': ease};

Map<String, dynamic> _in(String comp, Map<String, dynamic> c) => {'in_comp': comp, ...c};

/// Scale (%) that shows media [m] [px] tall.
double _sh(MediaAsset m, double px) => px / math.max(1, m.height) * 100;

/// Scale (%) that covers a [w]×[h] area with [m].
double _cover(MediaAsset m, double w, double h) => math.max(w / math.max(1, m.width), h / math.max(1, m.height)) * 100;

/// Precomp + its comp layer in main + a grade on top.
List<Map<String, dynamic>> _comp(TemplateCtx c, String id, String name, double du, {String bg = '#000000', bool threeD = true}) => [
      {'op': 'add_comp', 'id': id, 'name': name, 'width': c.w, 'height': c.h, 'duration': du, 'background': bg},
      if (threeD) _in(id, {'op': 'set_camera_mode', 'mode': '3d'}),
      _in(id, {'op': 'set_comp', 'motion_blur': true}),
    ];

List<Map<String, dynamic>> _finish(TemplateCtx c, String id, double du, {double vignette = 55, double grain = 16}) => [
      _in(id, {'op': 'add_layer', 'type': 'solid', 'id': '${id}_grade', 'name': 'Grade', 'adjustment': true, 'color': '#00000000'}),
      _in(id, {'op': 'add_effect', 'layer': '${id}_grade', 'effect': 'vignette', 'params': {'amount': vignette, 'size': 45}}),
      _in(id, {'op': 'add_effect', 'layer': '${id}_grade', 'effect': 'grain', 'params': {'amount': grain, 'size': 2}}),
      {'op': 'add_layer', 'type': 'comp', 'comp': id, 'id': '${id}_layer', 'start': c.t(0), 'duration': du},
    ];

/// The win-30 template set.
List<SceneTemplate> setTemplates() => const [
      SceneTemplate(
        id: 'set_photo_pile_title', name: 'Photo pile → title', category: '3D sets',
        subtitle: 'Photos fly in stacked, scatter over a map/paper while the camera settles on the title',
        duration: 6.4, previewTime: 3.2,
        slots: [
          TemplateSlot('background', 'Background (map / paper / texture)', kind: 'media', media: 'image'),
          TemplateSlot('photos', 'Photos (3–8)', kind: 'medias', media: 'image', max: 8),
          TemplateSlot('title', 'Title', initial: 'HISTORY OF WARGAMING'),
          TemplateSlot('duration', 'Duration (s)', initial: '6.4'),
        ],
        builder: _photoPile,
      ),
      SceneTemplate(
        id: 'set_pieces_on_board', name: 'Pieces placed on a board', category: '3D sets',
        subtitle: 'Hands place two pieces (countries, leaders, companies…) on a glossy floor; camera pulls back',
        duration: 8.6, previewTime: 4.5,
        slots: [
          TemplateSlot('left_piece', 'Left piece (cut-out)', kind: 'media', media: 'image'),
          TemplateSlot('right_piece', 'Right piece (cut-out)', kind: 'media', media: 'image'),
          TemplateSlot('hand', 'Hand reaching down (cut-out, optional)', kind: 'media', media: 'image'),
          TemplateSlot('backdrop', 'Backdrop', kind: 'media', media: 'image'),
          TemplateSlot('floor', 'Floor texture (top-down)', kind: 'media', media: 'image'),
          TemplateSlot('duration', 'Duration (s)', initial: '8.6'),
        ],
        builder: _piecesOnBoard,
      ),
      SceneTemplate(
        id: 'set_stage_lineup', name: 'Stage line-up (real depth)', category: '3D sets',
        subtitle: 'People stand at different depths on a stage; the camera pulls back, then passes them one by one',
        duration: 12, previewTime: 3,
        slots: [
          TemplateSlot('people', 'People (full-body cut-outs, 1–5)', kind: 'medias', media: 'image', max: 5),
          TemplateSlot('backdrop', 'Stage / curtain backdrop', kind: 'media', media: 'image'),
          TemplateSlot('hold', 'Seconds on each person', initial: '3'),
        ],
        builder: _stageLineup,
      ),
      SceneTemplate(
        id: 'set_topics_to_idea', name: 'Topics → one idea', category: 'Explainers',
        subtitle: 'Photos with labels on a line, then a brace joins them into one conclusion',
        duration: 5.4, previewTime: 4.8,
        slots: [
          TemplateSlot('photos', 'Photos (2–5)', kind: 'medias', media: 'image', max: 5),
          TemplateSlot('labels', 'Labels (comma-separated)', initial: 'WAR, ECONOMY, TECHNOLOGY'),
          TemplateSlot('conclusion', 'Conclusion', initial: 'WORLD POLITICS'),
          TemplateSlot('background', 'Background texture', kind: 'media', media: 'image'),
        ],
        builder: _topicsToIdea,
      ),
      SceneTemplate(
        id: 'set_pinned_portraits', name: 'Pinned portraits on a map', category: 'Evidence',
        subtitle: 'Portraits pinned on a map with a label each; the camera travels pin to pin',
        duration: 9.2, previewTime: 1.5,
        slots: [
          TemplateSlot('map', 'Map / board background', kind: 'media', media: 'image'),
          TemplateSlot('portraits', 'Portraits (2–5)', kind: 'medias', media: 'image', max: 5),
          TemplateSlot('labels', 'Labels (comma-separated)', initial: 'NAME ONE, NAME TWO, NAME THREE'),
          TemplateSlot('hold', 'Seconds per portrait', initial: '3.1'),
        ],
        builder: _pinnedPortraits,
      ),
    ];

// ------------------------------------------------------------ photo pile → title

List<Map<String, dynamic>> _photoPile(TemplateCtx c) {
  const id = 'pile';
  final w = c.w, h = c.h, k = w / 1920;
  final du = c.n('duration', 6.4).clamp(4.0, 20.0).toDouble();
  final settle = math.min(3.0, du * 0.45), out = du - 1.1;
  final cmds = _comp(c, id, 'Photo pile → title', du);
  cmds.addAll([
    _in(id, {'op': 'add_layer', 'type': 'null', 'id': 'world', 'name': 'World', 'is3d': true, 'position': [w / 2, h / 2, 0]}),
    _in(id, {'op': 'set_property', 'target': 'world', 'prop': 'anchor', 'value': [0, 0, 0]}),
  ]);
  final bg = c.media('background');
  if (bg != null) {
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'image', 'media': bg.id, 'id': 'bg', 'name': 'Background', 'parent': 'world', 'is3d': true, 'fit': 'none', 'position': [0, 0, 0], 'scale': [_cover(bg, w, h) * 2, _cover(bg, w, h) * 2, 100]}));
    cmds.add(_in(id, {'op': 'add_effect', 'layer': 'bg', 'effect': 'color', 'params': {'brightness': -22, 'contrast': 8, 'saturation': -18}}));
  } else {
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': 'bg', 'name': 'Background', 'parent': 'world', 'is3d': true, 'kind': 'rect', 'width': w * 2, 'height': h * 2, 'fill': '#2B3A2F', 'fill2': '#0E1510', 'position': [0, 0, 0]}));
  }
  cmds.add(_in(id, {'op': 'add_layer', 'type': 'text', 'id': 'title', 'name': 'Title', 'parent': 'world', 'is3d': true, 'text': c.s('title', 'TITLE'), 'font': 'Montserrat', 'font_size': 100 * k, 'font_weight': 900, 'text_color': '#ECE7DA', 'align': 'center', 'width': 1900 * k, 'position': [-10 * k, -20 * k, -25]}));
  cmds.add(_in(id, {'op': 'set_property', 'target': 'title', 'prop': 'rotation', 'value': [0, -6, -3]}));
  cmds.add(_in(id, {'op': 'add_effect', 'layer': 'title', 'effect': 'shadow', 'params': {'distance': 8, 'angle': 120, 'blur': 14, 'opacity': 75}}));
  // Cards above the title (a 2D separator splits the depth sort).
  cmds.add(_in(id, {'op': 'add_layer', 'type': 'solid', 'id': 'sep', 'name': 'sep', 'color': '#00000000', 'width': 2, 'height': 2, 'position': [0, 0, 0]}));
  final photos = c.medias('photos');
  const spots = [
    [-574.0, -292, -5, 440], [40, -282, -7, 500], [625, 165, -10, 410], [-650, 318, 4, 470],
    [20, 262, -8, 520], [600, -300, 6, 420], [-680, -20, 8, 380], [700, 420, -4, 380],
  ];
  final n = photos.isEmpty ? 5 : math.min(8, photos.length);
  for (var i = 0; i < n; i++) {
    final sp = spots[i];
    final cid = 'card$i';
    final x = sp[0] * k, y = sp[1] * k, rot = sp[2].toDouble(), cw = sp[3] * k, z = -40.0 - i * 6.0;
    final sx = x * 0.37, sy = y * 0.37; // stacked start
    if (photos.isNotEmpty) {
      final m = photos[i];
      final s = cw / math.max(1, m.width) * 100;
      cmds.add(_in(id, {'op': 'add_layer', 'type': 'image', 'media': m.id, 'id': cid, 'name': 'Photo ${i + 1}', 'parent': 'world', 'is3d': true, 'fit': 'none', 'position': [sx, sy, z], 'scale': [s, s, 100]}));
      cmds.add(_in(id, {'op': 'add_effect', 'layer': cid, 'effect': 'outline', 'params': {'width': (11 / (s / 100)).round(), 'color': '#E8E0CC'}}));
    } else {
      cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': cid, 'name': 'Photo ${i + 1}', 'parent': 'world', 'is3d': true, 'kind': 'rect', 'width': cw, 'height': cw * 0.62, 'fill': '#8A7458', 'fill2': '#3E3326', 'stroke': '#E8E0CC', 'stroke_width': 11, 'position': [sx, sy, z]}));
    }
    cmds.add(_in(id, {'op': 'add_effect', 'layer': cid, 'effect': 'shadow', 'params': {'distance': 16, 'angle': 130, 'blur': 22, 'opacity': 80}}));
    cmds.addAll([
      _k(id, cid, 'position', 0.9, [sx, sy, z]), _k(id, cid, 'position', settle - 0.1, [x, y, z]),
      _k(id, cid, 'position', out, [x, y, z]), _k(id, cid, 'position', du - 0.2, [x * 0.7, y * 0.7, z]),
      _k(id, cid, 'rotation', 0.9, [0, 0, rot * 1.6]), _k(id, cid, 'rotation', settle - 0.1, [0, 0, rot]),
      _k(id, cid, 'rotation', out, [0, 0, rot]), _k(id, cid, 'rotation', du - 0.2, [0, 0, rot * 1.6]),
    ]);
  }
  cmds.addAll([
    _k(id, 'world', 'rotation', 0, [34, 0, -11]), _k(id, 'world', 'rotation', settle, [0, 0.01, 0]),
    _k(id, 'world', 'rotation', out, [0, 0.01, 0]), _k(id, 'world', 'rotation', du - 0.1, [22, 0, -6]),
    _k(id, 'world', 'scale', 0, [158, 158, 100]), _k(id, 'world', 'scale', settle, [100, 100, 100]),
    _k(id, 'world', 'scale', out, [103, 103, 100]), _k(id, 'world', 'scale', du - 0.1, [130, 130, 100]),
  ]);
  cmds.addAll(_finish(c, id, du, vignette: 60, grain: 18));
  cmds.addAll([
    _in(id, {'op': 'add_layer', 'type': 'solid', 'id': 'fade', 'name': 'Fade', 'color': '#000000'}),
    _k(id, 'fade', 'opacity', 0, [100], 'linear'), _k(id, 'fade', 'opacity', 0.4, [0], 'linear'),
    _k(id, 'fade', 'opacity', du - 0.9, [0], 'linear'), _k(id, 'fade', 'opacity', du - 0.1, [100], 'linear'),
  ]);
  return cmds;
}

// ------------------------------------------------------------ pieces on a board

List<Map<String, dynamic>> _piecesOnBoard(TemplateCtx c) {
  const id = 'board';
  final w = c.w, h = c.h, k = w / 1920;
  final du = c.n('duration', 8.6).clamp(5.0, 20.0).toDouble();
  final cmds = _comp(c, id, 'Pieces on a board', du, bg: '#05070A');
  final bd = c.media('backdrop');
  if (bd != null) {
    // Far wall: ~2× the frame at z 1500 so the whole camera move stays covered.
    final s = math.max(3894 * k / math.max(1, bd.width), 2174 * k / math.max(1, bd.height)) * 100;
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'image', 'media': bd.id, 'id': 'wall', 'name': 'Backdrop', 'is3d': true, 'fit': 'none', 'position': [w / 2, -87 * k, 1500], 'scale': [s, s, 100]}));
  } else {
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': 'wall', 'name': 'Backdrop', 'is3d': true, 'kind': 'rect', 'width': w * 2.9, 'height': h * 2.9, 'fill': '#1B3A4A', 'fill2': '#05070A', 'position': [w / 2, -87 * k, 1500]}));
  }
  final fl = c.media('floor');
  for (var i = 0; i < 3; i++) {
    final dx = (i - 1) * 2040.0 * k;
    final fid = 'floor$i';
    if (fl != null) {
      final s = 2040 * k / math.max(1, fl.width) * 100;
      cmds.add(_in(id, {'op': 'add_layer', 'type': 'image', 'media': fl.id, 'id': fid, 'name': 'Floor ${i + 1}', 'is3d': true, 'fit': 'none', 'position': [w / 2 + dx, 1000 * k, 520], 'scale': [s, s, 100]}));
    } else {
      cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': fid, 'name': 'Floor ${i + 1}', 'is3d': true, 'kind': 'rect', 'width': 2040 * k, 'height': 2040 * k, 'fill': '#2A2C30', 'fill2': '#0C0D0F', 'position': [w / 2 + dx, 1000 * k, 520]}));
    }
    cmds.add(_in(id, {'op': 'set_property', 'target': fid, 'prop': 'rotation', 'value': [-90, 0, 0]}));
  }
  cmds.add(_in(id, {'op': 'add_layer', 'type': 'solid', 'id': 'fog', 'name': 'Fog', 'is3d': true, 'color': '#00000000', 'width': 4200 * k, 'height': 2600 * k, 'position': [w / 2, 500 * k, 900]}));
  cmds.add(_in(id, {'op': 'add_effect', 'layer': 'fog', 'effect': 'particles', 'params': {'kind': 'smoke', 'amount': 30, 'speed': 0.35, 'color': '#2C5F80'}}));
  cmds.add(_in(id, {'op': 'add_layer', 'type': 'solid', 'id': 'sep', 'name': 'sep', 'color': '#00000000', 'width': 2, 'height': 2, 'position': [0, 0, 0]}));
  final kh = 354 * k;
  final hand = c.media('hand');
  final floorY = 1000 * k;
  void piece(String side, MediaAsset? m, double xEnd, double xStart, double yStart, double tilt, double t0, double tLand, double tLift, bool mirror) {
    final g = 'g_$side', pc = 'p_$side', rf = 'r_$side', hd = 'h_$side';
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'null', 'id': g, 'name': '$side group', 'is3d': true, 'position': [xStart, yStart, 0]}));
    cmds.add(_in(id, {'op': 'set_property', 'target': g, 'prop': 'anchor', 'value': [0, 0, 0]}));
    if (m != null) {
      final s = _sh(m, kh);
      cmds.add(_in(id, {'op': 'add_layer', 'type': 'image', 'media': m.id, 'id': pc, 'name': '$side piece', 'parent': g, 'is3d': true, 'fit': 'none', 'position': [0, -kh / 2, 0], 'scale': [s, s, 100]}));
      cmds.add(_in(id, {'op': 'add_layer', 'type': 'image', 'media': m.id, 'id': rf, 'name': '$side reflection', 'parent': g, 'is3d': true, 'fit': 'none', 'position': [0, kh / 2, 1], 'scale': [s, -s, 100]}));
    } else {
      cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': pc, 'name': '$side piece', 'parent': g, 'is3d': true, 'kind': 'rect', 'width': kh * 0.4, 'height': kh, 'corner': kh * 0.08, 'fill': side == 'left' ? '#2E5BD6' : '#D0202A', 'position': [0, -kh / 2, 0]}));
      cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': rf, 'name': '$side reflection', 'parent': g, 'is3d': true, 'kind': 'rect', 'width': kh * 0.4, 'height': kh, 'corner': kh * 0.08, 'fill': side == 'left' ? '#2E5BD6' : '#D0202A', 'position': [0, kh / 2, 1]}));
    }
    cmds.add(_in(id, {'op': 'add_effect', 'layer': pc, 'effect': 'contact_shadow', 'params': {'opacity': 70, 'softness': 40, 'angle': 90}}));
    cmds.addAll([_k(id, rf, 'opacity', tLand - 0.15, [0], 'linear'), _k(id, rf, 'opacity', tLand + 0.05, [18])]);
    if (hand != null) {
      final s = _sh(hand, 360 * k);
      final hx = (mirror ? 22 : -22) * k, hy = -kh - 478 * k;
      cmds.add(_in(id, {'op': 'add_layer', 'type': 'image', 'media': hand.id, 'id': hd, 'name': '$side hand', 'parent': g, 'is3d': true, 'fit': 'none', 'position': [hx, hy, -6], 'scale': [mirror ? -s : s, s, 100]}));
      cmds.addAll([_k(id, hd, 'position', tLift, [hx, hy, -6]), _k(id, hd, 'position', tLift + 0.8, [hx + (mirror ? 400 : -380) * k, hy - 1200 * k, -6], 'ease_in')]);
    }
    cmds.addAll([
      _k(id, g, 'position', t0, [xStart, yStart, 0]), _k(id, g, 'position', tLand, [xEnd, floorY, 0], 'ease_out'),
      _k(id, g, 'rotation', t0, [0, 0, tilt]), _k(id, g, 'rotation', tLand, [0, 0.01, 0]),
    ]);
  }

  piece('left', c.media('left_piece'), 672 * k, 822 * k, 330 * k, 16, 0, 0.95, 1.9, false);
  piece('right', c.media('right_piece'), 1230 * k, 2130 * k, 600 * k, -26, 1.45, 2.4, 3.1, true);
  final cam = [
    [0.0, 700 * k, 560 * k, -1000.0, 'ease_out'], [1.4, 760 * k, 600 * k, -1450.0, 'easy_ease'],
    [4.0, w / 2, h / 2, -2667 * k, 'linear'], [du, w / 2, 520 * k, -2960 * k, 'linear'],
  ];
  for (final p in cam) {
    final t = p[0] as double, x = p[1] as double, y = p[2] as double, z = p[3] as double, e = p[4] as String;
    cmds.addAll([_k(id, 'camera', 'position', t, [x, y, z], e), _k(id, 'camera', 'poi', t, [x, y, 0], e), _k(id, 'camera', 'focus', t, [-z], e)]);
  }
  cmds.add(_in(id, {'op': 'set_property', 'target': 'camera', 'prop': 'aperture', 'value': 14}));
  cmds.addAll(_finish(c, id, du, vignette: 60, grain: 15));
  return cmds;
}

// ------------------------------------------------------------ stage line-up

List<Map<String, dynamic>> _stageLineup(TemplateCtx c) {
  const id = 'stage';
  final w = c.w, h = c.h, k = w / 1920;
  final people = c.medias('people');
  final n = people.isEmpty ? 3 : math.min(5, people.length);
  final hold = c.n('hold', 3).clamp(1.5, 8.0).toDouble();
  final intro = 5.5;
  final du = intro + n * hold + 1.0;
  final cmds = _comp(c, id, 'Stage line-up', du, bg: '#030405');
  final bd = c.media('backdrop');
  if (bd != null) {
    final cs = math.max(6192 * k / math.max(1, bd.width), 3456 * k / math.max(1, bd.height)) * 100;
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'image', 'media': bd.id, 'id': 'curtain', 'name': 'Backdrop', 'is3d': true, 'fit': 'none', 'position': [w / 2 + 340 * k, 380 * k, 2700], 'scale': [cs, cs, 100]}));
    cmds.add(_in(id, {'op': 'add_effect', 'layer': 'curtain', 'effect': 'color', 'params': {'brightness': -18, 'contrast': 6, 'saturation': -20}}));
  } else {
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': 'curtain', 'name': 'Backdrop', 'is3d': true, 'kind': 'rect', 'width': w * 4.5, 'height': h * 4, 'fill': '#2A3240', 'fill2': '#06080B', 'position': [w / 2 + 340 * k, 380 * k, 2700]}));
  }
  cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': 'floor', 'name': 'Stage floor', 'is3d': true, 'kind': 'rect', 'width': 7000 * k, 'height': 3400 * k, 'fill': '#0A0B0D', 'fill2': '#14161A', 'position': [w / 2 + 840 * k, 1000 * k, 1200]}));
  cmds.add(_in(id, {'op': 'set_property', 'target': 'floor', 'prop': 'rotation', 'value': [-90, 0, 0]}));
  cmds.add(_in(id, {'op': 'add_layer', 'type': 'solid', 'id': 'sep', 'name': 'sep', 'color': '#00000000', 'width': 2, 'height': 2, 'position': [0, 0, 0]}));
  final ph = 600 * k, floorY = 1000 * k;
  final xs = <double>[], zs = <double>[];
  for (var i = 0; i < n; i++) {
    // First person close to the camera, the others further back, alternating sides.
    final x = w * 0.4 + i * 820 * k;
    final z = i == 0 ? 0.0 : 1300.0;
    xs.add(x);
    zs.add(z);
    final pid = 'man$i';
    if (people.isNotEmpty) {
      final m = people[i];
      cmds.add(_in(id, {'op': 'add_layer', 'type': 'image', 'media': m.id, 'id': pid, 'name': m.name, 'is3d': true, 'fit': 'none', 'position': [x, floorY - ph / 2, z], 'scale': [_sh(m, ph), _sh(m, ph), 100]}));
    } else {
      cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': pid, 'name': 'Person ${i + 1}', 'is3d': true, 'kind': 'rect', 'width': ph * 0.33, 'height': ph, 'corner': ph * 0.1, 'fill': '#6B5A45', 'position': [x, floorY - ph / 2, z]}));
    }
    cmds.add(_in(id, {'op': 'set_property', 'target': pid, 'prop': 'rotation', 'value': [0, 0.01, 0]}));
    cmds.add(_in(id, {'op': 'add_effect', 'layer': pid, 'effect': 'contact_shadow', 'params': {'opacity': 65, 'softness': 50, 'angle': 90}}));
  }
  // Camera: close-up on person 1 → wide → past person 1 to each person behind.
  final keys = <List<Object>>[
    [0.0, xs[0], 470 * k, -520.0, 'easy_ease'],
    [intro, (xs[0] + xs.last) / 2 * 0.5 + w * 0.25, 560 * k, -2667 * k, 'easy_ease'],
  ];
  var t = intro;
  for (var i = n == 1 ? 0 : 1; i < n; i++) {
    keys.add([t + 1.9, xs[i], 540 * k, zs[i] - 2000, 'easy_ease']);
    keys.add([t + hold, xs[i], 520 * k, zs[i] - 1750, 'linear']);
    t += hold;
  }
  if (n == 1) keys.add([du, xs[0], 520 * k, -1100.0, 'linear']);
  keys.add([du, (keys.last[1] as double), 540 * k, (keys.last[3] as double) - 600, 'linear']);
  for (final kk in keys) {
    final tt = (kk[0] as double).clamp(0.0, du).toDouble(), x = kk[1] as double, y = kk[2] as double, z = kk[3] as double, e = kk[4] as String;
    cmds.addAll([_k(id, 'camera', 'position', tt, [x, y, z], e), _k(id, 'camera', 'poi', tt, [x, y, z + 2667 * k], e)]);
    final focusZ = zs.reduce((a, b) => (a - (z + 2000)).abs() < (b - (z + 2000)).abs() ? a : b);
    cmds.add(_k(id, 'camera', 'focus', tt, [(focusZ - z).abs().clamp(300.0, 6000.0)], e));
  }
  cmds.add(_in(id, {'op': 'set_property', 'target': 'camera', 'prop': 'aperture', 'value': 20}));
  cmds.addAll(_finish(c, id, du, vignette: 75, grain: 20));
  return cmds;
}

// ------------------------------------------------------------ topics → one idea

List<Map<String, dynamic>> _topicsToIdea(TemplateCtx c) {
  const id = 'topics';
  final w = c.w, h = c.h, k = w / 1920;
  final photos = c.medias('photos');
  final labels = c.list('labels');
  final n = math.max(2, math.min(5, math.max(photos.length, labels.length)));
  final du = 3.4 + n * 0.7;
  final cmds = _comp(c, id, 'Topics → one idea', du, bg: '#666666', threeD: false);
  final bg = c.media('background');
  if (bg != null) {
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'image', 'media': bg.id, 'id': 'bg', 'name': 'Background', 'fit': 'none', 'position': [w / 2, h / 2], 'scale': [_cover(bg, w, h) * 1.6, _cover(bg, w, h) * 1.6, 100]}));
    cmds.add(_in(id, {'op': 'add_effect', 'layer': 'bg', 'effect': 'color', 'params': {'brightness': -28, 'contrast': -5, 'saturation': -30}}));
  } else {
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': 'bg', 'name': 'Background', 'kind': 'rect', 'width': w * 1.6, 'height': h * 1.6, 'fill': '#6A6A6A', 'fill2': '#4A4A4A', 'position': [w / 2, h / 2]}));
    cmds.add(_in(id, {'op': 'add_effect', 'layer': 'bg', 'effect': 'grunge', 'params': {'amount': 40}}));
  }
  final gap = 1740 * k / n;
  final cw = math.min(540 * k, gap - 40 * k), ch = cw * 0.81, cy = 386 * k, lineY = 668 * k;
  final xs = [for (var i = 0; i < n; i++) 90 * k + gap * (i + 0.5)];
  for (var i = 0; i < n; i++) {
    final x = xs[i], tl = 0.45 + i * 0.78;
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': 'bd$i', 'name': 'Border ${i + 1}', 'kind': 'rect', 'width': cw + 12, 'height': ch + 12, 'fill': '#F4F4F2', 'position': [x, cy]}));
    cmds.add(_in(id, {'op': 'add_effect', 'layer': 'bd$i', 'effect': 'shadow', 'params': {'distance': 8, 'angle': 120, 'blur': 16, 'opacity': 55}}));
    if (i < photos.length) {
      final m = photos[i];
      final s = math.max(cw / math.max(1, m.width), ch / math.max(1, m.height));
      cmds.add(_in(id, {'op': 'add_layer', 'type': 'image', 'media': m.id, 'id': 'ph$i', 'name': 'Photo ${i + 1}', 'fit': 'none', 'position': [x, cy], 'scale': [s * 100, s * 100, 100]}));
      cmds.add(_in(id, {'op': 'add_mask', 'layer': 'ph$i', 'shape': 'rect', 'center': [m.width / 2, m.height / 2], 'size': [cw / s, ch / s]}));
    } else {
      cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': 'ph$i', 'name': 'Photo ${i + 1}', 'kind': 'rect', 'width': cw, 'height': ch, 'fill': '#8C8C8C', 'fill2': '#3C3C3C', 'position': [x, cy]}));
    }
    final label = i < labels.length ? labels[i] : 'TOPIC ${i + 1}';
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'text', 'id': 'lb$i', 'name': label, 'text': label, 'font': 'Oswald', 'font_size': 78 * k * math.min(1, 3 / n * 1.15), 'font_weight': 700, 'text_color': '#FFFFFF', 'align': 'center', 'width': gap, 'position': [x, 100 * k], 'start': tl, 'duration': du - tl, 'animator': 'typewriter_soft', 'anim_duration': 0.45}));
    final td = tl + 0.07;
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': 'dot$i', 'name': 'Dot ${i + 1}', 'kind': 'ellipse', 'width': 24 * k, 'height': 24 * k, 'fill': '#FFFFFF', 'position': [x, lineY], 'start': td - 0.05, 'duration': du - td + 0.05}));
    cmds.addAll([_k(id, 'dot$i', 'scale', td, [0, 0, 100], 'back'), _k(id, 'dot$i', 'scale', td + 0.3, [100, 100, 100])]);
  }
  final lineEnd = 0.45 + (n - 1) * 0.78 + 0.4;
  cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': 'line', 'name': 'Timeline', 'kind': 'line', 'points': [[90 * k, lineY], [w - 90 * k, lineY]], 'stroke': '#FFFFFF', 'stroke_width': 6 * k, 'fill': 'none'}));
  cmds.addAll([_k(id, 'line', 'trim', 0.2, [0, 0], 'linear'), _k(id, 'line', 'trim', lineEnd, [0, 100])]);
  final b0 = lineEnd + 0.5, by = 762 * k, mid = w / 2;
  cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': 'brace', 'name': 'Brace', 'kind': 'path', 'smooth': true, 'closed': false, 'points': [[xs.first, lineY], [xs.first + 27 * k, by - 20 * k], [xs.first + 175 * k, by], [mid - 80 * k, by + 2 * k], [mid, 810 * k], [mid + 80 * k, by + 2 * k], [xs.last - 175 * k, by], [xs.last - 27 * k, by - 20 * k], [xs.last, lineY]], 'stroke': '#FFFFFF', 'stroke_width': 7 * k, 'fill': 'none'}));
  cmds.addAll([_k(id, 'brace', 'trim', b0, [50, 50], 'ease_out'), _k(id, 'brace', 'trim', b0 + 0.55, [0, 100])]);
  cmds.add(_in(id, {'op': 'add_layer', 'type': 'text', 'id': 'idea', 'name': 'Conclusion', 'text': c.s('conclusion', 'ONE IDEA'), 'font': 'Oswald', 'font_size': 120 * k, 'font_weight': 700, 'text_color': '#FFFFFF', 'align': 'center', 'width': 1500 * k, 'position': [mid, 905 * k], 'start': b0 + 0.05, 'duration': du - b0 - 0.05, 'animator': 'typewriter_soft', 'anim_duration': 1.0}));
  cmds.addAll([
    _k(id, 'camera', 'pan', 0, [w / 2, 340 * k], 'hold'), _k(id, 'camera', 'pan', b0 - 0.45, [w / 2, 340 * k], 'easy_ease'),
    _k(id, 'camera', 'pan', b0 - 0.12, [w / 2, h / 2]),
  ]);
  // 2D camera for the pan.
  cmds.insert(2, _in(id, {'op': 'set_camera_mode', 'mode': '2d'}));
  cmds.addAll(_finish(c, id, du, vignette: 35, grain: 16));
  return cmds;
}

// ------------------------------------------------------------ pinned portraits on a map

List<Map<String, dynamic>> _pinnedPortraits(TemplateCtx c) {
  const id = 'pins';
  final w = c.w, k = w / 1920;
  final portraits = c.medias('portraits');
  final labels = c.list('labels');
  final n = math.max(2, math.min(5, math.max(portraits.length, labels.length)));
  final hold = c.n('hold', 3.1).clamp(1.5, 8.0).toDouble();
  final du = n * hold;
  final cmds = _comp(c, id, 'Pinned portraits', du, bg: '#C9B48A', threeD: false);
  cmds.insert(1, _in(id, {'op': 'set_camera_mode', 'mode': '2d'}));
  final map = c.media('map');
  final mw = 4540 * k, mh = 2534 * k;
  if (map != null) {
    final s = math.max(mw / math.max(1, map.width), mh / math.max(1, map.height)) * 100;
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'image', 'media': map.id, 'id': 'map', 'name': 'Map', 'fit': 'none', 'position': [mw / 2, mh / 2], 'scale': [s, s, 100]}));
    cmds.add(_in(id, {'op': 'add_effect', 'layer': 'map', 'effect': 'color', 'params': {'brightness': -4, 'contrast': -4, 'saturation': -12}}));
  } else {
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': 'map', 'name': 'Map', 'kind': 'rect', 'width': mw, 'height': mh, 'fill': '#D8C39A', 'fill2': '#A88A5C', 'position': [mw / 2, mh / 2]}));
    cmds.add(_in(id, {'op': 'add_effect', 'layer': 'map', 'effect': 'paper', 'params': {'amount': 60}}));
  }
  const spots = [[900.0, 1450.0, 1], [2550.0, 640.0, -1], [2950.0, 1680.0, 1], [1500.0, 520.0, 1], [3700.0, 1100.0, -1]];
  final ch = 760 * k, cw = 640 * k;
  final pts = <List<num>>[];
  for (var i = 0; i < n; i++) {
    final sp = spots[i];
    final x = sp[0] * k, y = sp[1] * k, side = sp[2].toDouble();
    pts.add([x, y, side]);
    if (i < portraits.length) {
      final m = portraits[i];
      final s = math.max(cw / math.max(1, m.width), ch / math.max(1, m.height));
      cmds.add(_in(id, {'op': 'add_layer', 'type': 'image', 'media': m.id, 'id': 'card$i', 'name': 'Portrait ${i + 1}', 'fit': 'none', 'position': [x, y], 'scale': [s * 100, s * 100, 100]}));
      cmds.add(_in(id, {'op': 'add_mask', 'layer': 'card$i', 'shape': 'rect', 'center': [m.width / 2, m.height / 2], 'size': [cw / s, ch / s]}));
    } else {
      cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': 'card$i', 'name': 'Portrait ${i + 1}', 'kind': 'rect', 'width': cw, 'height': ch, 'fill': '#5A5A5A', 'fill2': '#202020', 'position': [x, y]}));
    }
    cmds.add(_in(id, {'op': 'add_effect', 'layer': 'card$i', 'effect': 'shadow', 'params': {'distance': 18, 'angle': 125, 'blur': 26, 'opacity': 75}}));
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': 'curl$i', 'name': 'Curl ${i + 1}', 'kind': 'path', 'closed': true, 'points': [[x + cw / 2, y + ch / 2 - 70 * k], [x + cw / 2 - 70 * k, y + ch / 2], [x + cw / 2 - 18 * k, y + ch / 2 - 18 * k]], 'fill': '#E9E1CF'}));
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': 'pin$i', 'name': 'Pin ${i + 1}', 'kind': 'ellipse', 'width': 56 * k, 'height': 56 * k, 'fill': '#E0141E', 'fill2': '#8A0A10', 'position': [x, y - ch / 2 + 24 * k]}));
    cmds.add(_in(id, {'op': 'add_effect', 'layer': 'pin$i', 'effect': 'shadow', 'params': {'distance': 10, 'angle': 120, 'blur': 10, 'opacity': 70}}));
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'shape', 'id': 'pinhi$i', 'name': 'Pin highlight ${i + 1}', 'kind': 'ellipse', 'width': 16 * k, 'height': 12 * k, 'fill': '#FFB0B0', 'position': [x - 10 * k, y - ch / 2 + 14 * k]}));
    final label = i < labels.length ? labels[i] : 'NAME ${i + 1}';
    final t0 = i * hold + (i == 0 ? 0.45 : 0.6);
    cmds.add(_in(id, {'op': 'add_layer', 'type': 'text', 'id': 'lab$i', 'name': 'Label ${i + 1}', 'text': ' $label ', 'font': 'DM Serif Display', 'font_size': 80 * k, 'font_weight': 400, 'text_color': '#111111', 'box_color': '#F7F5EF', 'align': side > 0 ? 'left' : 'right', 'width': 1050 * k, 'position': [side > 0 ? x + cw / 2 + 40 * k + 525 * k : x - cw / 2 - 40 * k - 525 * k, y - 30 * k], 'start': t0, 'duration': du - t0, 'animator': 'typewriter', 'anim_duration': 0.55}));
    cmds.add(_in(id, {'op': 'add_effect', 'layer': 'lab$i', 'effect': 'shadow', 'params': {'distance': 6, 'angle': 120, 'blur': 10, 'opacity': 55}}));
  }
  for (var i = 0; i < n; i++) {
    final p = pts[i];
    final cx = p[0] + p[2] * 250 * k, cy = p[1];
    final a = i * hold, b = math.min(du, a + hold - 0.8);
    cmds.addAll([
      _k(id, 'camera', 'pan', a + (i == 0 ? 0 : 0.6), [cx, cy], 'easy_ease'), _k(id, 'camera', 'pan', b, [cx + p[2] * 150 * k, cy - 30 * k], 'linear'),
      _k(id, 'camera', 'zoom2d', a + (i == 0 ? 0 : 0.6), [96], 'easy_ease'), _k(id, 'camera', 'zoom2d', b, [106], 'linear'),
    ]);
  }
  cmds.addAll(_finish(c, id, du, vignette: 40, grain: 14));
  return cmds;
}
