import 'dart:math' as math;

import '../engine/evaluator.dart';
import '../engine/text_clusters.dart'; // V2-F
import '../model/easing.dart'; // SCENE (Agent D)
import '../model/layer.dart';
import '../model/project.dart';
import 'world_map.dart';

part 'components_doc.dart';
part 'components_article.dart';
part 'map_kit.dart'; // SCENE (Agent D): maps + 3D room/board
part 'components_fx.dart'; // V3-D: speech_bubble upgrade (messages, typing, tail_to/attach, styles, puff exit)

/// Documentary kit: ready-made, fully editable groups of layers built from
/// ordinary edit commands. Every component is a null "group" layer (anchor at
/// 0,0) with child layers positioned relative to it, so moving/scaling the
/// group moves everything.
class Components {
  static const types = [
    'source_card', 'lower_third', 'badge', 'photo_card', 'pin', 'route_arrow',
    'speech_bubble', 'cta', 'timeline', 'counter', 'glow_word', 'map', 'map_pin', 'map_route', 'tv_frame',
    // V1 doc kit
    'name_tag', 'character_label', 'arrow_callout', 'censor_bar', 'plaque', 'poster', 'glass_screen',
    'title_slam', 'foreground_wipe', 'icon_stream', 'icon_badge', 'scanner', 'silhouette_crowd',
    'number_tiles', 'date_title', 'article',
    ..._sceneTypes, // SCENE (Agent D)
  ];

  static String label(String t) => const {
        'source_card': 'Source Card',
        'lower_third': 'Source Line',
        'badge': 'Badge',
        'photo_card': 'Photo Card',
        'pin': 'Pin + Label',
        'route_arrow': 'Route Arrow',
        'speech_bubble': 'Speech Bubble',
        'cta': 'Subscribe Pop-up',
        'timeline': 'Timeline',
        'counter': 'Number Counter',
        'glow_word': 'Glow Word',
        'map': 'World Map',
        'map_pin': 'Map Pin',
        'map_route': 'Map Route',
        'tv_frame': 'TV Frame',
        'name_tag': 'Name Tag',
        'character_label': 'Character Label',
        'arrow_callout': 'Arrow Callout',
        'censor_bar': 'Censor Bar',
        'plaque': 'Plaque / Gravestone',
        'poster': 'Vintage Poster',
        'glass_screen': 'Glass Screen',
        'title_slam': 'Title Slam Intro',
        'foreground_wipe': 'Foreground Wipe',
        'icon_stream': 'Icon Stream',
        'icon_badge': 'Icon Badge',
        'scanner': 'Scanner Beam',
        'silhouette_crowd': 'Silhouette Crowd',
        'number_tiles': 'Rolling Tiles',
        'date_title': 'Date Title',
        'article': 'Article Highlight',
      }[t] ??
      _sceneLabels[t] ?? // SCENE (Agent D)
      t;

  static List<Map<String, dynamic>> build(Project p, Map<String, dynamic> c, double now) {
    final type = '${c['type']}';
    if (!types.contains(type)) {
      throw ArgumentError('Unknown component "$type". Available: ${types.join(', ')}');
    }
    final comp = p.editComp; // PRECOMP (Agent L): the comp being edited
    final b = _B(comp.width, comp.height, c, now, '${c['id'] ?? Ids.next(type)}');
    final scene = _sceneBuild(p, c, b); // SCENE (Agent D)
    if (scene != null) return scene;
    switch (type) {
      case 'source_card':
        return _sourceCard(b);
      case 'lower_third':
        return _lowerThird(b);
      case 'badge':
        return _badge(b, p);
      case 'photo_card':
        return _photoCard(b, p);
      case 'pin':
        return _pin(b, null);
      case 'route_arrow':
        return _route(b, null);
      case 'speech_bubble':
        return c['style'] == 'classic' ? _bubble(b) : _bubbleV3(b, p, comp); // V3-D
      case 'cta':
        return _cta(b);
      case 'timeline':
        return _timeline(b);
      case 'counter':
        return _counter(b);
      case 'glow_word':
        return _glowWord(b, p);
      case 'map':
        return _map(b);
      case 'map_pin':
        return _mapPin(b, comp.layerById('${c['map']}_world') != null);
      case 'map_route':
        return _mapRoute(b);
      case 'tv_frame':
        return _tv(b);
      case 'name_tag':
        return _nameTag(b);
      case 'character_label':
        return _characterLabel(b, p);
      case 'arrow_callout':
        return _arrowCallout(b);
      case 'censor_bar':
        return _censorBar(b);
      case 'plaque':
        return _plaque(b);
      case 'poster':
        return _poster(b, p);
      case 'glass_screen':
        return _glassScreen(b, p);
      case 'title_slam':
        return _titleSlam(b, p);
      case 'foreground_wipe':
        return _foregroundWipe(b, p);
      case 'icon_stream':
        return _iconStream(b, p);
      case 'icon_badge':
        return _iconBadge(b, p);
      case 'scanner':
        return _scanner(b, p);
      case 'silhouette_crowd':
        return _silhouetteCrowd(b, p);
      case 'number_tiles':
        return _numberTiles(b);
      case 'date_title':
        return _dateTitle(b);
      case 'article':
        return _article(b, p);
    }
    return const [];
  }

  // ------------------------------------------------------------------ parts

  static List<Map<String, dynamic>> _sourceCard(_B b) {
    final cw = b.n('width', b.w * 0.42);
    final pad = cw * 0.06;
    final fsSrc = cw * 0.034, fsHead = cw * 0.05, fsBody = cw * 0.038;
    final source = b.str('source', 'Source: example.com');
    final headline = b.str('headline', '');
    final body = b.str('body', 'Add the quoted passage from your source here.');
    double lines(String t, double fs) => math.max(1, (t.length * fs * 0.52 / (cw - pad * 2)).ceilToDouble());
    final hSrc = fsSrc * 1.5;
    final hHead = headline.isEmpty ? 0.0 : lines(headline, fsHead) * fsHead * 1.25;
    final hBody = lines(body, fsBody) * fsBody * 1.35;
    final ch = pad * 2 + hSrc + (headline.isEmpty ? 0 : hHead + pad * 0.4) + hBody + pad * 0.4;
    final top = -ch / 2 + pad;
    final paper = b.str('style', 'white') == 'paper';
    final cmds = b.group('Source Card', tilt: b.n('tilt', -2));
    cmds.add(b.shape('card', 'rect', cw, ch, 0, 0, fill: paper ? '#F2E9D8' : '#FFFFFF', corner: cw * 0.01));
    cmds.add({'op': 'add_effect', 'layer': b.id('card'), 'effect': 'shadow', 'params': {'distance': 18, 'blur': 18, 'opacity': 60}});
    if (paper) cmds.add({'op': 'add_effect', 'layer': b.id('card'), 'effect': 'paper', 'params': {'amount': 70}});
    var y = top;
    cmds.add(b.text('src', source, cw - pad * 2, hSrc, 0, y + hSrc / 2, fsSrc, color: '#C62828', weight: 800, align: 'left'));
    y += hSrc;
    if (headline.isNotEmpty) {
      y += pad * 0.2;
      cmds.add(b.text('head', headline, cw - pad * 2, hHead, 0, y + hHead / 2, fsHead, color: '#111111', weight: 900, align: 'left'));
      y += hHead + pad * 0.2;
    }
    final marks = <Map<String, dynamic>>[];
    var delay = 0.7;
    for (final h in b.list('highlights')) {
      marks.add({'phrase': h, 'style': 'highlight', 'delay': delay, 'duration': 0.7});
      delay += 0.8;
    }
    final circle = b.str('circle', '');
    if (circle.isNotEmpty) marks.add({'phrase': circle, 'style': 'circle', 'delay': delay, 'duration': 0.6});
    final underline = b.str('underline', '');
    if (underline.isNotEmpty) marks.add({'phrase': underline, 'style': 'underline', 'delay': delay + 0.3, 'duration': 0.5});
    cmds.add({
      ...b.text('body', body, cw - pad * 2, hBody, 0, y + hBody / 2, fsBody, color: '#222222', weight: 500, align: 'left'),
      'marks': marks,
    });
    return b.finish(cmds, enter: 'pop');
  }

  static List<Map<String, dynamic>> _lowerThird(_B b) {
    final w = b.n('width', b.w * 0.5);
    final fs = b.n('size', b.h * 0.026);
    final x = b.n('x', b.w * 0.05), y = b.n('y', b.h * 0.84);
    final cmds = b.group('Source Line', x: x, y: y);
    final source = b.str('source', 'Source: example.com');
    final text = b.str('text', '');
    cmds.add(b.shape('bar', 'rect', fs * 0.25, fs * 3.4, fs * 0.125, fs * 1.2, fill: b.str('color', '#FFC400')));
    cmds.add(b.text('src', source, w, fs * 1.4, fs * 0.6 + w / 2, 0, fs * 0.95, color: b.str('color', '#FFC400'), weight: 800, align: 'left'));
    if (text.isNotEmpty) {
      cmds.add({
        ...b.text('txt', text, w, fs * 2.8, fs * 0.6 + w / 2, fs * 1.9, fs * 0.85, color: '#FFFFFF', weight: 500, align: 'left'),
        'marks': [for (final h in b.list('highlights')) {'phrase': h, 'style': 'highlight', 'delay': 0.6, 'duration': 0.6}],
      });
    }
    return b.finish(cmds, enter: 'slide_right');
  }

  static List<Map<String, dynamic>> _badge(_B b, Project p) {
    final r = b.n('size', b.w * 0.07);
    final label = b.str('label', '');
    final cmds = b.group('Badge');
    cmds.add(b.shape('disc', 'ellipse', r * 2, r * 2, 0, 0, fill: b.str('color', '#C62828')));
    final media = b.c['media'];
    if (media != null && p.media['$media'] != null) {
      final m = p.media['$media']!;
      final s = (r * 1.7) / math.min(m.width, m.height) * 100;
      cmds.add({'op': 'add_layer', 'type': 'image', 'media': media, 'id': b.id('img'), 'parent': b.g, 'start': b.start, 'duration': b.dur, 'fit': 'none', 'position': [0, 0, 0], 'scale': [s, s, 100]});
      cmds.add({'op': 'add_mask', 'layer': b.id('img'), 'shape': 'ellipse', 'center': [m.width / 2, m.height / 2], 'size': [r * 1.7 / s * 100, r * 1.7 / s * 100], 'feather': 0});
    }
    cmds.add(b.shape('ring', 'ellipse', r * 2.1, r * 2.1, 0, 0, fill: 'none', stroke: '#FFFFFF', strokeWidth: r * 0.09));
    if (label.isNotEmpty) {
      final fs = r * 0.32;
      final pw = math.max(r * 1.7, label.length * fs * 0.62 + fs * 1.4);
      cmds.add(b.shape('pill', 'rect', pw, fs * 1.8, 0, r * 0.95, fill: '#161616', stroke: '#FFFFFF', strokeWidth: 3, corner: fs * 0.9));
      cmds.add(b.text('label', label.toUpperCase(), pw, fs * 1.8, 0, r * 0.95, fs, color: '#FFFFFF', weight: 900));
    }
    final breakAt = b.c['break_at'];
    if (breakAt is num) {
      for (final part in ['disc', 'ring', if (label.isNotEmpty) 'pill', if (label.isNotEmpty) 'label', if (media != null) 'img']) {
        final fx = '${b.id(part)}_shatter';
        final t0 = b.start + breakAt.toDouble();
        cmds.add({'op': 'add_effect', 'layer': b.id(part), 'effect': 'shatter', 'id': fx});
        cmds.add({'op': 'set_keyframe', 'target': b.id(part), 'effect': fx, 'prop': 'progress', 'time': t0, 'value': 0, 'ease': 'ease_out'});
        cmds.add({'op': 'set_keyframe', 'target': b.id(part), 'effect': fx, 'prop': 'progress', 'time': t0 + 0.9, 'value': 100});
      }
    }
    return b.finish(cmds, enter: 'pop', exit: breakAt is num ? null : 'pop');
  }

  static List<Map<String, dynamic>> _photoCard(_B b, Project p) {
    final mid = b.c['media'];
    final m = mid == null ? null : p.media['$mid'];
    if (m == null) throw ArgumentError('photo_card needs "media" = an image or video id');
    final pw = b.n('width', b.w * 0.24);
    final ph = m.height * pw / m.width;
    final border = pw * 0.04;
    final caption = b.str('caption', '');
    final capH = caption.isEmpty ? 0.0 : pw * 0.16;
    final fh = ph + border * 2 + capH;
    final cmds = b.group('Photo Card', tilt: b.n('tilt', -4));
    cmds.add(b.shape('frame', 'rect', pw + border * 2, fh, 0, 0, fill: '#FFFFFF', corner: border * 0.3));
    cmds.add({'op': 'add_effect', 'layer': b.id('frame'), 'effect': 'shadow', 'params': {'distance': 16, 'blur': 16, 'opacity': 55}});
    final s = pw / m.width * 100;
    cmds.add({
      'op': 'add_layer', 'type': m.type == MediaType.video ? 'video' : 'image', 'media': m.id, 'id': b.id('photo'), 'parent': b.g,
      'start': b.start, 'duration': b.dur, 'fit': 'none', 'position': [0, -fh / 2 + border + ph / 2, 0], 'scale': [s, s, 100],
    });
    if (caption.isNotEmpty) {
      cmds.add(b.text('cap', caption, pw, capH, 0, fh / 2 - capH / 2 - border * 0.3, capH * 0.5, color: '#1A1A1A', weight: 800));
    }
    return b.finish(cmds, enter: b.str('enter', 'slide_up'));
  }

  static List<Map<String, dynamic>> _pin(_B b, String? parent) {
    final r = b.n('size', b.w * 0.009);
    final label = b.str('label', '');
    final cmds = b.group('Pin', parent: parent);
    cmds.add(b.shape('pulse', 'ellipse', r * 2, r * 2, 0, 0, fill: 'none', stroke: b.str('color', '#FF3B30'), strokeWidth: r * 0.3));
    cmds.add({'op': 'set_keyframe', 'target': b.id('pulse'), 'prop': 'scale', 'time': b.start + 0.3, 'value': 100, 'ease': 'ease_out'});
    cmds.add({'op': 'set_keyframe', 'target': b.id('pulse'), 'prop': 'scale', 'time': b.start + 1.4, 'value': 380});
    cmds.add({'op': 'set_keyframe', 'target': b.id('pulse'), 'prop': 'opacity', 'time': b.start + 0.3, 'value': 100});
    cmds.add({'op': 'set_keyframe', 'target': b.id('pulse'), 'prop': 'opacity', 'time': b.start + 1.4, 'value': 0});
    cmds.add(b.shape('dot', 'ellipse', r * 2, r * 2, 0, 0, fill: b.str('color', '#FF3B30'), stroke: '#FFFFFF', strokeWidth: r * 0.35));
    if (label.isNotEmpty) {
      final fs = b.n('label_size', b.h * 0.024);
      final pw = label.length * fs * 0.6 + fs * 1.2;
      cmds.add(b.shape('tag', 'rect', pw, fs * 1.7, 0, -r - fs * 1.3, fill: '#FFFFFF', corner: fs * 0.3));
      cmds.add(b.text('label', label, pw, fs * 1.7, 0, -r - fs * 1.3, fs, color: '#111111', weight: 800));
    }
    return b.finish(cmds, enter: 'pop');
  }

  static List<Map<String, dynamic>> _route(_B b, String? parent, {List<double>? from, List<double>? to}) {
    final a = from ?? b.vec('from', [b.w * 0.3, b.h * 0.6]);
    final z = to ?? b.vec('to', [b.w * 0.7, b.h * 0.4]);
    final bend = b.n('bend', 0.25);
    final dx = z[0] - a[0], dy = z[1] - a[1];
    final mid = [(a[0] + z[0]) / 2 - dy * bend, (a[1] + z[1]) / 2 + dx * bend];
    final width = b.n('stroke_width', b.w * 0.004);
    final drawTime = b.n('draw', 1.2);
    final id = b.id('line');
    return [
      {
        'op': 'add_layer', 'type': 'shape', 'id': id, 'name': 'Route Arrow', 'start': b.start, 'duration': b.dur,
        if (parent != null) 'parent': parent,
        'points': [a, mid, z], 'smooth': true, 'closed': false, 'fill': 'none',
        'stroke': b.str('color', '#FFFFFF'), 'stroke_width': width, 'arrow_end': true,
        if (b.c['dashed'] == true) 'dash': [width * 3, width * 2.2],
      },
      {'op': 'set_keyframe', 'target': id, 'prop': 'trim', 'time': b.start, 'value': [0, 0], 'ease': 'easy_ease'},
      {'op': 'set_keyframe', 'target': id, 'prop': 'trim', 'time': b.start + drawTime, 'value': [0, 100]},
    ];
  }

  static List<Map<String, dynamic>> _bubble(_B b) {
    final text = b.str('text', '"Quote"');
    final w = b.n('width', b.w * 0.18);
    final fs = b.n('size', w * 0.09);
    final h = math.max(fs * 2.6, (text.length * fs * 0.55 / (w * 0.85)).ceil() * fs * 1.3 + fs * 1.2);
    final cmds = b.group('Speech Bubble');
    cmds.add(b.shape('box', 'rect', w, h, 0, 0, fill: '#FFFFFF', corner: fs * 0.8));
    cmds.add({
      'op': 'add_layer', 'type': 'shape', 'id': b.id('tail'), 'parent': b.g, 'start': b.start, 'duration': b.dur,
      'points': [[-w * 0.3, h / 2 - 2], [-w * 0.42, h / 2 + fs * 1.4], [-w * 0.12, h / 2 - 2]], 'closed': true, 'fill': '#FFFFFF',
    });
    cmds.add(b.text('txt', text, w * 0.86, h, 0, 0, fs, color: '#111111', weight: 700));
    return b.finish(cmds, enter: 'pop');
  }

  static List<Map<String, dynamic>> _cta(_B b) {
    final text = b.str('text', 'SUBSCRIBE');
    final fs = b.n('size', b.h * 0.03);
    final pw = text.length * fs * 0.68 + fs * 2;
    final cmds = b.group('Subscribe Pop-up', x: b.n('x', b.w * 0.84), y: b.n('y', b.h * 0.86));
    cmds.add(b.shape('pill', 'rect', pw, fs * 2, 0, 0, fill: b.str('color', '#E53935'), corner: fs));
    cmds.add(b.text('txt', text, pw, fs * 2, 0, 0, fs, color: '#FFFFFF', weight: 900));
    return b.finish(cmds, enter: 'slide_left', exit: 'slide_right');
  }

  static List<Map<String, dynamic>> _timeline(_B b) =>
      b.str('style', 'ruler') == 'classic' ? _timelineClassic(b) : _yearRuler(b);

  static List<Map<String, dynamic>> _timelineClassic(_B b) {
    final from = b.n('from', 1930).round(), to = b.n('to', 1970).round();
    final step = math.max(1, b.n('step', 10).round());
    final marker = b.n('marker', (from + to) / 2);
    final w = b.n('width', b.w * 0.7);
    final fs = b.n('size', b.h * 0.022);
    final cmds = b.group('Timeline', x: b.n('x', b.w / 2), y: b.n('y', b.h * 0.88));
    double xOf(num year) => -w / 2 + (year - from) / math.max(1, to - from) * w;
    cmds.add({'op': 'add_layer', 'type': 'shape', 'id': b.id('axis'), 'parent': b.g, 'start': b.start, 'duration': b.dur,
      'points': [[-w / 2, 0], [w / 2, 0]], 'fill': 'none', 'stroke': '#FFFFFF', 'stroke_width': 3});
    final ticks = <List<double>>[];
    var i = 0;
    for (int yv = from; yv <= to; yv += step) {
      ticks.add([xOf(yv), -fs * 0.4, xOf(yv), fs * 0.4]);
      cmds.add(b.text('y${i++}', '${yv}s', fs * 4, fs * 1.4, xOf(yv), fs * 1.3, fs * 0.8, color: '#CFCFCF', weight: 600));
    }
    cmds.add({'op': 'add_layer', 'type': 'shape', 'id': b.id('ticks'), 'parent': b.g, 'start': b.start, 'duration': b.dur,
      'rings': ticks, 'closed': false, 'fill': 'none', 'stroke': '#FFFFFF', 'stroke_width': 3, 'position': [0, 0, 0]});
    final mk = b.id('marker');
    cmds.add(b.shape('marker', 'ellipse', fs * 1.1, fs * 1.1, xOf(from), 0, fill: '#FFFFFF'));
    cmds.add({'op': 'set_keyframe', 'target': mk, 'prop': 'position', 'time': b.start + 0.4, 'value': [xOf(from), 0, 0], 'ease': 'easy_ease'});
    cmds.add({'op': 'set_keyframe', 'target': mk, 'prop': 'position', 'time': b.start + 1.8, 'value': [xOf(marker), 0, 0]});
    final label = b.str('label', '${marker.round()}');
    final pw = label.length * fs * 0.7 + fs * 1.5;
    cmds.add({...b.shape('pill', 'rect', pw, fs * 1.8, fs * 0.55, -fs * 1.6, fill: b.str('color', '#C62828'), corner: fs * 0.3), 'parent': mk});
    cmds.add({...b.text('date', label.toUpperCase(), pw, fs * 1.8, fs * 0.55, -fs * 1.6, fs, color: '#FFFFFF', weight: 900), 'parent': mk});
    return b.finish(cmds, enter: 'fade_children');
  }

  static List<Map<String, dynamic>> _counter(_B b) {
    final fs = b.n('size', b.h * 0.12);
    final cmds = b.group('Counter');
    final id = b.id('num');
    cmds.add({
      ...b.text('num', '', b.w * 0.9, fs * 1.5, 0, 0, fs, color: b.str('color', '#7CFF6B'), weight: 900),
      'counter': {
        'from': b.n('from', 0), 'to': b.n('to', 100), 'decimals': b.n('decimals', 0).round(),
        'prefix': b.str('prefix', ''), 'suffix': b.str('suffix', ''), 'delay': 0.2, 'duration': b.n('count', 1.6),
      },
    });
    if (b.c['glow'] != false) {
      cmds.add({'op': 'add_effect', 'layer': id, 'effect': 'glow', 'params': {'amount': 70, 'radius': 18}});
    }
    return b.finish(cmds, enter: 'pop');
  }

  static List<Map<String, dynamic>> _glowWord(_B b, Project p) {
    final fs = b.n('size', b.h * 0.16);
    final text = b.str('text', 'WORD').toUpperCase();
    final cmds = b.group('Glow Word');
    final id = b.id('word');
    cmds.add({...b.text('word', text, b.w * 0.95, fs * 1.4, 0, 0, fs, color: b.str('color', '#FFF3D6'), weight: 900), 'outline': fs * 0.035});
    cmds.add({'op': 'add_effect', 'layer': id, 'effect': 'glow', 'params': {'amount': 80, 'radius': 22}});
    cmds.add({'op': 'add_effect', 'layer': id, 'effect': 'flicker', 'params': {'amount': 25}});
    // Place the word just below another layer (e.g. a cut-out person) for depth.
    final behind = b.c['behind'];
    if (behind is String) {
      final i = p.editComp.indexOf(behind); // PRECOMP (Agent L)
      if (i >= 0) cmds.add({'op': 'reorder_layer', 'layer': id, 'index': i + 2});
    }
    return b.finish(cmds, enter: 'zoom_out_children');
  }

  static List<Map<String, dynamic>> _tv(_B b) {
    final w = b.n('width', b.w * 0.42);
    final h = w * 0.78;
    final cmds = b.group('TV Frame');
    cmds.add(b.shape('body', 'rect', w, h, 0, 0, fill: '#4A3A2C', fill2: '#2A2019', corner: w * 0.05));
    cmds.add(b.shape('screen', 'rect', w * 0.72, h * 0.72, -w * 0.08, 0, fill: 'none', stroke: '#111111', strokeWidth: w * 0.025, corner: w * 0.06));
    cmds.add(b.shape('knob1', 'ellipse', w * 0.07, w * 0.07, w * 0.4, -h * 0.18, fill: '#1A1A1A', stroke: '#8A7A6A', strokeWidth: 3));
    cmds.add(b.shape('knob2', 'ellipse', w * 0.07, w * 0.07, w * 0.4, 0, fill: '#1A1A1A', stroke: '#8A7A6A', strokeWidth: 3));
    cmds.add({'op': 'add_effect', 'layer': b.id('body'), 'effect': 'shadow', 'params': {'distance': 20, 'blur': 24, 'opacity': 60}});
    return b.finish(cmds, enter: 'pop');
  }

  // -------------------------------------------------------------- map kit

  static const _mapStyles = {
    'dark': ['#0B1622', '#26313D', '#3A4756'],
    'paper': ['#D9CDB4', '#B8A98A', '#8E7F63'],
    'blue': ['#0E4A6B', '#2E6E4F', '#5C8F70'],
  };

  /// World map: ocean + all countries + highlighted ones, optional zoom to a country.
  static List<Map<String, dynamic>> _map(_B b) {
    if (!WorldMap.loaded) throw ArgumentError('World map data is not loaded');
    final style = _mapStyles[b.str('style', 'dark')] ?? _mapStyles['dark']!;
    final g = b.g, world = '${b.root}_world';
    final cmds = <Map<String, dynamic>>[
      {'op': 'add_layer', 'type': 'solid', 'id': '${b.root}_ocean', 'name': 'Map Ocean', 'color': style[0], 'start': b.start, 'duration': b.dur, 'index': 999},
      {'op': 'add_layer', 'type': 'null', 'id': g, 'name': 'World Map', 'start': b.start, 'duration': b.dur, 'position': [0, 0, 0]},
      {'op': 'set_property', 'target': g, 'prop': 'anchor', 'value': [0, 0, 0]},
    ];
    // Base land: one shape with every country (cheap to draw, cached).
    final rings = <List<double>>[];
    for (final c in WorldMap.countries) {
      rings.addAll(WorldMap.projectRings(c));
    }
    cmds.add({
      'op': 'add_layer', 'type': 'shape', 'id': world, 'name': 'Countries', 'parent': g, 'start': b.start, 'duration': b.dur,
      'rings': rings, 'closed': true, 'fill': style[1], 'stroke': style[2], 'stroke_width': 1.2,
    });
    // Highlighted countries.
    var delay = 0.6;
    var idx = 0;
    for (final item in (b.c['countries'] as List? ?? const [])) {
      final spec = item is Map ? Map<String, dynamic>.from(item) : {'code': '$item'};
      final country = WorldMap.find('${spec['code'] ?? spec['name']}');
      if (country == null) throw ArgumentError('Unknown country "${spec['code'] ?? spec['name']}"');
      final cid = '${b.root}_c${idx++}';
      cmds.add({
        'op': 'add_layer', 'type': 'shape', 'id': cid, 'name': country.name, 'parent': g, 'start': b.start + delay, 'duration': b.dur - delay,
        'rings': WorldMap.projectRings(country), 'closed': true, 'fill': spec['fill'] ?? '#C9A227', 'stroke': '#FFFFFF', 'stroke_width': 2.5,
      });
      cmds.add({'op': 'animate_in', 'layer': cid, 'preset': 'fade', 'duration': 0.5});
      if (spec['label'] != false) {
        final lp = WorldMap.project(country.labelLon, country.labelLat);
        final bb = WorldMap.bbox(country);
        final fs = math.max(8.0, math.min(60.0, (bb[2] - bb[0]) * 0.12));
        cmds.add({
          'op': 'add_layer', 'type': 'text', 'id': '${cid}_label', 'parent': g, 'start': b.start + delay + 0.2, 'duration': b.dur - delay - 0.2,
          'text': '${spec['label'] is String ? spec['label'] : country.name}'.toUpperCase(), 'font_size': fs, 'font_weight': 900,
          'width': fs * 12, 'height': fs * 1.6, 'position': [lp[0], lp[1], 0], 'shadow': true, 'animator': 'fade_up', 'anim_duration': 0.5,
        });
      }
      delay += 0.4;
    }
    // Framing: fit the world, then zoom to the focus country.
    final fitWorld = math.max(b.w / WorldMap.width, b.h / WorldMap.height);
    List<double> frame(List<double> bb, double fill) {
      final cw = math.max(bb[2] - bb[0], 10.0), ch = math.max(bb[3] - bb[1], 10.0);
      final s = math.min(b.w * fill / cw, b.h * fill / ch);
      return [b.w / 2 - s * (bb[0] + bb[2]) / 2, b.h / 2 - s * (bb[1] + bb[3]) / 2, s * 100];
    }

    final worldFrame = frame([0, 300, WorldMap.width, 1500], 1.0);
    worldFrame[2] = math.max(worldFrame[2], fitWorld * 100);
    final focus = b.c['focus'];
    final fc = focus == null ? null : WorldMap.find('$focus');
    if (focus != null && fc == null) throw ArgumentError('Unknown focus country "$focus"');
    if (fc == null) {
      cmds.add({'op': 'set_property', 'target': g, 'prop': 'position', 'value': [worldFrame[0], worldFrame[1], 0]});
      cmds.add({'op': 'set_property', 'target': g, 'prop': 'scale', 'value': [worldFrame[2], worldFrame[2], 100]});
    } else {
      final f = frame(WorldMap.bbox(fc), b.n('fill', 0.6));
      final zoom = b.n('zoom_time', 2.5);
      final t1 = b.start + b.n('zoom_delay', 0.3);
      if (b.c['zoom'] == false) {
        cmds.add({'op': 'set_property', 'target': g, 'prop': 'position', 'value': [f[0], f[1], 0]});
        cmds.add({'op': 'set_property', 'target': g, 'prop': 'scale', 'value': [f[2], f[2], 100]});
      } else {
        for (final kv in [
          [t1, worldFrame],
          [t1 + zoom, f],
        ]) {
          final t = kv[0] as double;
          final v = kv[1] as List<double>;
          cmds.add({'op': 'set_keyframe', 'target': g, 'prop': 'position', 'time': t, 'value': [v[0], v[1], 0], 'ease': 'easy_ease'});
          cmds.add({'op': 'set_keyframe', 'target': g, 'prop': 'scale', 'time': t, 'value': [v[2], v[2], 100], 'ease': 'easy_ease'});
        }
      }
    }
    if (b.c['effects'] != false) {
      cmds.add({'op': 'add_effect', 'layer': '${b.root}_ocean', 'effect': 'vignette', 'params': {'amount': 70}});
    }
    return cmds;
  }

  /// Pin on a map made with the "map" component (lat/lon).
  static List<Map<String, dynamic>> _mapPin(_B b, bool mapExists) {
    final map = '${b.c['map']}';
    if (!mapExists) throw ArgumentError('map_pin needs "map" = the id of a map component');
    final lat = b.n('lat', 0), lon = b.n('lon', 0);
    final pt = WorldMap.project(lon, lat);
    final sub = _B(b.w, b.h, {...b.c, 'x': pt[0], 'y': pt[1], 'size': b.n('size', 6), 'label_size': b.n('label_size', 14)}, b.now, b.root);
    return _pin(sub, '${map}_g');
  }

  /// Curved arrow between two lat/lon points on a map component.
  static List<Map<String, dynamic>> _mapRoute(_B b) {
    final map = '${b.c['map']}';
    final from = b.vec('from', [0, 0]), to = b.vec('to', [0, 0]); // [lat, lon]
    final a = WorldMap.project(from[1], from[0]);
    final z = WorldMap.project(to[1], to[0]);
    final sub = _B(b.w, b.h, {...b.c, 'stroke_width': b.n('stroke_width', 3)}, b.now, b.root);
    return _route(sub, '${map}_g', from: a, to: z);
  }
}

/// Small helper for building component commands.
class _B {
  final double w, h;
  final Map<String, dynamic> c;
  final double now;
  final String root;
  _B(this.w, this.h, this.c, this.now, this.root);

  String get g => '${root}_g';
  String id(String part) => '${root}_$part';
  double get start => (c['start'] as num?)?.toDouble() ?? now;
  double get dur => (c['duration'] as num?)?.toDouble() ?? 5;
  double n(String k, num d) => (c[k] as num?)?.toDouble() ?? d.toDouble();
  String str(String k, String d) => c[k] == null ? d : '${c[k]}';
  List<String> list(String k) => [for (final v in (c[k] as List? ?? const [])) '$v'];
  List<double> vec(String k, List<double> d) {
    final v = c[k];
    if (v is List && v.length >= 2) return [(v[0] as num).toDouble(), (v[1] as num).toDouble()];
    return d;
  }

  List<Map<String, dynamic>> group(String name, {double? x, double? y, double tilt = 0, String? parent}) => [
        {
          'op': 'add_layer', 'type': 'null', 'id': g, 'name': name, 'start': start, 'duration': dur,
          'position': [x ?? n('x', w / 2), y ?? n('y', h / 2), 0],
          if (parent != null) 'parent': parent,
        },
        {'op': 'set_property', 'target': g, 'prop': 'anchor', 'value': [0, 0, 0]},
        if (tilt != 0) {'op': 'set_property', 'target': g, 'prop': 'rotation', 'value': [0, 0, tilt]},
        if (c['scale'] is num) {'op': 'set_property', 'target': g, 'prop': 'scale', 'value': c['scale']},
      ];

  Map<String, dynamic> shape(String part, String kind, double sw, double sh, double x, double y,
          {String fill = '#FFFFFF', String? fill2, String? stroke, double strokeWidth = 0, double corner = 0}) =>
      {
        'op': 'add_layer', 'type': 'shape', 'id': id(part), 'parent': g, 'start': start, 'duration': dur,
        'kind': kind, 'width': sw, 'height': sh, 'position': [x, y, 0], 'fill': fill,
        if (fill2 != null) 'fill2': fill2,
        if (stroke != null) 'stroke': stroke,
        'stroke_width': strokeWidth, 'corner': corner,
      };

  Map<String, dynamic> text(String part, String t, double tw, double th, double x, double y, double fs,
          {String color = '#FFFFFF', int weight = 700, String align = 'center'}) =>
      {
        'op': 'add_layer', 'type': 'text', 'id': id(part), 'parent': g, 'start': start, 'duration': dur,
        'text': t, 'width': tw, 'height': th, 'position': [x, y, 0], 'font_size': fs, 'font_weight': weight,
        'text_color': color, 'align': align, 'shadow': false, 'name': t.length > 20 ? t.substring(0, 20) : t,
      };

  // ---------------------------------------------------------- V1 helpers

  double get end => start + dur;
  bool flag(String k, bool d) => c[k] == null ? d : c[k] == true;

  /// A null layer (anchor 0,0) used as a sub-group.
  List<Map<String, dynamic>> nul(String part, double x, double y, {String? parent, double? st, double? du, String? name}) => [
        {
          'op': 'add_layer', 'type': 'null', 'id': id(part), 'name': name ?? part, 'parent': parent ?? g,
          'start': st ?? start, 'duration': du ?? dur, 'position': [x, y, 0],
        },
        {'op': 'set_property', 'target': id(part), 'prop': 'anchor', 'value': [0, 0, 0]},
      ];

  Map<String, dynamic> kf(String layerId, String prop, double t, dynamic v, [String ease = 'easy_ease']) =>
      {'op': 'set_keyframe', 'target': layerId, 'prop': prop, 'time': t, 'value': v, 'ease': ease};

  Map<String, dynamic> setp(String layerId, String prop, dynamic v) => {'op': 'set_property', 'target': layerId, 'prop': prop, 'value': v};

  Map<String, dynamic> fx(String layerId, String effect, [Map<String, dynamic>? params, String? fxId]) =>
      {'op': 'add_effect', 'layer': layerId, 'effect': effect, if (params != null) 'params': params, if (fxId != null) 'id': fxId};

  /// Open or closed path from points in the parent's coordinates.
  Map<String, dynamic> path(String part, List<List<double>> pts,
          {String stroke = '#FFFFFF', double width = 4, String fill = 'none', bool smooth = false, bool closed = false,
          List<double>? dash, bool arrowEnd = false, String? parent, double? st, double? du}) =>
      {
        'op': 'add_layer', 'type': 'shape', 'id': id(part), 'parent': parent ?? g, 'start': st ?? start, 'duration': du ?? dur,
        'points': pts, 'smooth': smooth, 'closed': closed, 'fill': fill, 'stroke': stroke, 'stroke_width': width,
        if (dash != null) 'dash': dash, if (arrowEnd) 'arrow_end': true,
      };

  /// Photo/video child scaled to [widthPx] (or to [heightPx]) and centred on x,y.
  Map<String, dynamic> media(String part, MediaAsset m, double x, double y,
      {double? widthPx, double? heightPx, String? parent, double? st, double? du}) {
    final s = (heightPx != null ? heightPx / math.max(1, m.height) : (widthPx ?? m.width) / math.max(1, m.width)) * 100;
    return {
      'op': 'add_layer', 'type': m.type == MediaType.video ? 'video' : 'image', 'media': m.id, 'id': id(part),
      'parent': parent ?? g, 'start': st ?? start, 'duration': du ?? dur, 'fit': 'none',
      'position': [x, y, 0], 'scale': [s, s, 100],
    };
  }

  /// Full-frame background (gradient from [color] at the top to [color2]).
  Map<String, dynamic> backdrop(String part, String color, {String? color2, String name = 'Backdrop'}) => {
        'op': 'add_layer', 'type': 'shape', 'id': id(part), 'name': name, 'kind': 'rect', 'start': start, 'duration': dur,
        'width': w, 'height': h, 'position': [w / 2, h / 2, 0], 'fill': color, if (color2 != null) 'fill2': color2,
      };

  /// Full-frame transparent layer carrying a particles effect (atmosphere).
  List<Map<String, dynamic>> atmos(String part, String kind,
          {double amount = 40, double speed = 1, String? color, double? direction, double opacity = 100, double? st, double? du}) =>
      [
        {
          'op': 'add_layer', 'type': 'solid', 'id': id(part), 'name': 'Atmosphere $kind', 'color': '#00000000',
          'width': w, 'height': h, 'position': [w / 2, h / 2, 0], 'start': st ?? start, 'duration': du ?? dur,
        },
        fx(id(part), 'particles', {
          'kind': kind, 'amount': amount, 'speed': speed,
          if (color != null) 'color': color,
          if (direction != null) 'direction': direction,
        }),
        if (opacity < 100) setp(id(part), 'opacity', opacity),
      ];

  /// Full-frame flashes peaking at [times] (absolute).
  List<Map<String, dynamic>> flashes(String part, List<double> times, {String color = '#FFFFFF', double fade = 0.28}) {
    final lid = id(part);
    final cmds = <Map<String, dynamic>>[
      {
        'op': 'add_layer', 'type': 'solid', 'id': lid, 'name': 'Flash', 'color': color, 'width': w, 'height': h,
        'position': [w / 2, h / 2, 0], 'start': start, 'duration': dur,
      },
    ];
    for (final t in times) {
      if (t > start + 0.02) cmds.add(kf(lid, 'opacity', t - 0.06, 0, 'ease_in'));
      cmds.add(kf(lid, 'opacity', t, 100, 'ease_out'));
      cmds.add(kf(lid, 'opacity', t + fade, 0, 'linear'));
    }
    return cmds;
  }

  /// One media id (photo or video) from param [k], if it exists.
  MediaAsset? mediaOf(Project p, String k) {
    final v = c[k];
    final m = v is String ? p.media[v] : null;
    return m != null && m.type != MediaType.audio ? m : null;
  }

  /// Media ids from a string or a list param.
  List<MediaAsset> mediaList(Project p, String k) {
    final v = c[k];
    final ids = v is List ? [for (final e in v) '$e'] : (v is String ? [v] : const <String>[]);
    return [for (final i in ids) if (p.media[i] != null && p.media[i]!.type != MediaType.audio) p.media[i]!];
  }

  /// An audio media id from param [k], or a project sound named one of [names].
  MediaAsset? audioOf(Project p, String k, List<String> names) {
    final v = c[k];
    if (v == false || v == 'none') return null;
    final m = v is String ? p.media[v] : null;
    if (m != null && m.type != MediaType.image) return m;
    if (v != null) return null;
    for (final n in names) {
      for (final a in p.media.values) {
        if (a.type == MediaType.audio && a.name == n) return a;
      }
    }
    return null;
  }

  /// List of maps from a list param (other values become {key: value}).
  List<Map<String, dynamic>> specs(String k, String key) => [
        for (final v in (c[k] as List? ?? const []))
          v is Map ? Map<String, dynamic>.from(v) : {key: v},
      ];

  /// Adds the enter/exit animation for the group.
  List<Map<String, dynamic>> finish(List<Map<String, dynamic>> cmds, {String? enter, String? exit = 'pop'}) {
    final e = c['enter'] is String ? '${c['enter']}' : enter;
    if (e == 'fade_children' || e == 'zoom_out_children') {
      for (final cmd in List.of(cmds)) {
        if (cmd['op'] == 'add_layer' && cmd['parent'] == g) {
          cmds.add({'op': 'animate_in', 'layer': cmd['id'], 'preset': e == 'fade_children' ? 'fade' : 'zoom_out', 'duration': 0.5});
        }
      }
    } else if (e != null && e != 'none') {
      cmds.add({'op': 'animate_in', 'layer': g, 'preset': e, 'duration': 0.5});
    }
    final x = c['exit'] is String ? '${c['exit']}' : exit;
    if (x != null && x != 'none') cmds.add({'op': 'animate_out', 'layer': g, 'preset': x, 'duration': 0.4});
    return cmds;
  }
}
