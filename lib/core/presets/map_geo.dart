part of 'components.dart';

// V3-A >>> MAPS & GEO documentary patterns (MotionAI V3, P-A).
// Satellite map style + label grammar, box city tags, route_follow / map_route
// upgrades, status / signal / pulse rings, geo labels, text on paths, terrain
// labels, giant ghost country words, search sweep and sketch map.
// Every builder returns ordinary edit commands (one add_component = one undo step).

const _geoTypes = [
  'map_watermark', 'geo_label', 'path_text', 'terrain_label', 'status_ring', 'signal_rings', 'pulse_rings',
  'search_sweep', 'sketch_map',
];

const _geoLabels = {
  'map_watermark': 'Ghost Country Word',
  'geo_label': 'Geo Label (hook pointer)',
  'path_text': 'Text on Path',
  'terrain_label': 'Terrain Label',
  'status_ring': 'Status Ring',
  'signal_rings': 'Signal Rings',
  'pulse_rings': 'Pulse Rings',
  'search_sweep': 'Search Sweep',
  'sketch_map': 'Sketch Map + Compass',
};

/// Commands for the V3 geo components and the V3 forms of map / map_pin /
/// map_route / route_follow (null = not one of them; the older builders run).
List<Map<String, dynamic>>? _geoBuild(Project p, Map<String, dynamic> c, _B b) {
  switch ('${c['type']}') {
    case 'map':
      return _Geo.wantsMap(c) ? _Geo.map(b) : null;
    case 'map_pin':
      return c['tag_style'] == 'box' ? _Geo.cityTag(b, p) : null;
    case 'map_route':
      return _Geo.wantsRoute(c) ? _Geo.mapRoute(b, p) : null;
    case 'route_follow':
      return _Geo.wantsRoute(c) || c['style'] == 'satellite' ? _Geo.routeFollow(b, p) : null;
    case 'map_watermark':
      return _Geo.watermark(b, p);
    case 'geo_label':
      return _Geo.geoLabel(b, p);
    case 'path_text':
      return _Geo.pathText(b, p);
    case 'terrain_label':
      return _Geo.terrainLabel(b, p);
    case 'status_ring':
      return _Geo.statusRing(b, p);
    case 'signal_rings':
      return _Geo.rings(b, p, pulse: c['preset'] == 'pulse');
    case 'pulse_rings':
      return _Geo.rings(b, p, pulse: c['preset'] != 'radio');
    case 'search_sweep':
      return _Geo.searchSweep(b, p);
    case 'sketch_map':
      return _Geo.sketchMap(b, p);
  }
  return null;
}

class _Geo {
  static const red = '#D0202A';
  static const satPalette = ['#A83232', '#B0309A', '#5560B8', '#2A9D8F'];
  static const font = 'Poppins';

  // ----------------------------------------------------------------- helpers

  /// "#RRGGBB" (or "#AARRGGBB") with alpha [a] 0..1 → "#AARRGGBB".
  static String alpha(String hex, double a) {
    var s = hex.replaceFirst('#', '');
    if (s.length == 8) s = s.substring(2);
    if (s.length != 6) return hex;
    final aa = (a.clamp(0.0, 1.0) * 255).round().toRadixString(16).padLeft(2, '0').toUpperCase();
    return '#$aa${s.toUpperCase()}';
  }

  /// A size param: ≤ 1 = fraction of the frame height, else pixels.
  static double px(_B b, String k, double def) {
    final v = b.n(k, def);
    return v <= 1.0 ? v * b.h : v;
  }

  /// Percent or fraction → percent (0.6 → 60, 60 → 60).
  static double pct(_B b, String k, double def) {
    final v = b.n(k, def);
    return v <= 1.0 ? v * 100 : v;
  }

  static double mapScale(Project p, String map, double t) {
    final g = p.editComp.layerById('${map}_g');
    if (g == null) return 1;
    return math.max(1e-3, g.prop(Props.scale).valueAt(t)[0].abs() / 100);
  }

  /// Uniform world scale of a layer (its parents included) at [t].
  static double worldScale(Composition comp, Layer l, double t) {
    final m = Evaluator.worldMatrix(comp, l, t);
    final sx = math.sqrt(m[0] * m[0] + m[1] * m[1]);
    return sx < 1e-6 ? 1 : sx;
  }

  /// Angle normalised to [-90, 90) so text along it reads left→right / bottom→top.
  static double readable(double deg) => ((deg + 90) % 180 + 180) % 180 - 90;

  /// When an easy-eased 0..1 move reaches [v] (fraction of the move's time).
  static double whenEased(double v) {
    double lo = 0, hi = 1;
    for (int i = 0; i < 30; i++) {
      final mid = (lo + hi) / 2;
      if (Easing.easyEase.transform(mid) < v) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (lo + hi) / 2;
  }

  /// Principal axis of a country's main landmass (map px): angle in degrees,
  /// elongation (long / short) and approximate long-axis length.
  static (double, double, double) axis(Country c) {
    List<double>? best;
    double bestArea = -1;
    for (final r in WorldMap.projectRings(c)) {
      double minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9;
      for (int i = 0; i + 1 < r.length; i += 2) {
        minX = math.min(minX, r[i]);
        maxX = math.max(maxX, r[i]);
        minY = math.min(minY, r[i + 1]);
        maxY = math.max(maxY, r[i + 1]);
      }
      final a = (maxX - minX) * (maxY - minY);
      if (a > bestArea) {
        bestArea = a;
        best = r;
      }
    }
    final r = best;
    if (r == null || r.length < 6) return (0, 1, 10);
    final n = r.length ~/ 2;
    double mx = 0, my = 0;
    for (int i = 0; i + 1 < r.length; i += 2) {
      mx += r[i];
      my += r[i + 1];
    }
    mx /= n;
    my /= n;
    double xx = 0, xy = 0, yy = 0;
    for (int i = 0; i + 1 < r.length; i += 2) {
      final dx = r[i] - mx, dy = r[i + 1] - my;
      xx += dx * dx;
      xy += dx * dy;
      yy += dy * dy;
    }
    xx /= n;
    xy /= n;
    yy /= n;
    final tr = xx + yy, det = xx * yy - xy * xy;
    final disc = math.sqrt(math.max(0.0, tr * tr / 4 - det));
    final l1 = tr / 2 + disc, l2 = math.max(1e-6, tr / 2 - disc);
    final ang = 0.5 * math.atan2(2 * xy, xx - yy) * 180 / math.pi;
    return (ang, math.sqrt(l1 / l2), 4 * math.sqrt(math.max(0.0, l1)));
  }

  /// Label rotation for a country: a number (degrees), "auto" (thin countries
  /// get the long axis, others 0) or anything else = 0.
  static double labelRotation(Country c, dynamic mode, {double minElong = 2.2}) {
    if (mode is num) return mode.toDouble();
    if (mode != 'auto') return 0;
    final (ang, elong, _) = axis(c);
    return elong >= minElong ? readable(ang) : 0;
  }

  /// A text layer (map or screen units) with the documentary label look:
  /// heavy caps, white, soft shadow; pops 120→100 % in 0.25 s (or another
  /// text animator such as typewriter).
  static List<Map<String, dynamic>> label(_B b, String id, String? parent, String text, double x, double y, double fs, double t, double end,
      {double rot = 0, String animator = 'pop', double opacity = 100, String color = '#FFFFFF', int weight = 900, bool shadow = true, String align = 'center'}) {
    final w = fs * (text.length * 0.78 + 1.5), h = fs * 1.5;
    final typed = animator == 'typewriter';
    final cmds = <Map<String, dynamic>>[
      {
        'op': 'add_layer', 'type': 'text', 'id': id, 'name': text.length > 24 ? text.substring(0, 24) : text, 'parent': ?parent,
        'start': t, 'duration': math.max(0.1, end - t), 'text': text, 'font': font, 'font_size': fs, 'font_weight': weight,
        'text_color': color, 'width': w, 'height': h, 'position': [x, y, 0], 'shadow': shadow, 'align': align,
        if (animator != 'pop') 'animator': animator,
        if (animator != 'pop') 'anim_duration': typed ? (text.length * 0.055).clamp(0.3, 1.2) : 0.5,
      },
    ];
    if (rot != 0) cmds.add(b.setp(id, 'rotation', [0, 0, rot]));
    if (animator == 'pop') {
      cmds.addAll([
        b.kf(id, 'scale', t, [120, 120, 100], 'ease_out'),
        b.kf(id, 'scale', t + 0.25, [100, 100, 100]),
        b.kf(id, 'opacity', t, 0, 'ease_out'),
        b.kf(id, 'opacity', t + 0.15, opacity),
      ]);
    } else if (opacity < 100) {
      cmds.add(b.setp(id, 'opacity', opacity));
    }
    return cmds;
  }

  /// A highlighted country on map group [g] (fill fades in, label pops).
  /// Sizes in screen px are divided by the map scale [s].
  static List<Map<String, dynamic>> country(_B b, {required String g, required String id, required Country c, required double t, required double end,
      required double s, String fill = '#A83232', double fillOpacity = 0.62, double strokePx = 1.6, String? label, double? labelPx,
      double labelOpacity = 100, dynamic rotate = 'auto', String animator = 'pop', double opacity = 100}) {
    final du = math.max(0.2, end - t);
    final cmds = <Map<String, dynamic>>[
      {
        'op': 'add_layer', 'type': 'shape', 'id': id, 'name': c.name, 'parent': g, 'start': t, 'duration': du,
        'rings': WorldMap.projectRings(c), 'closed': true, 'fill': alpha(fill, fillOpacity), 'stroke': '#E6FFFFFF',
        'stroke_width': strokePx / s,
      },
      b.kf(id, 'opacity', t, 0, 'ease_out'),
      b.kf(id, 'opacity', t + 0.35, opacity),
    ];
    if (label != null && label.isNotEmpty) {
      final text = label.toUpperCase();
      final lp = WorldMap.project(c.labelLon, c.labelLat);
      var fs = (labelPx ?? b.h * 0.06) / s;
      final rot = labelRotation(c, rotate);
      if (rot != 0) {
        final (_, _, len) = axis(c);
        fs = math.min(fs, len * 0.95 / math.max(1.0, text.length * 0.72));
      }
      final lt = t + 0.15;
      cmds.addAll(_Geo.label(b, '${id}_label', g, text, lp[0], lp[1], fs, lt, end,
          rot: rot, animator: animator, opacity: labelOpacity * opacity / 100));
    }
    return cmds;
  }

  static List<List<double>>? _borders;

  /// Every country outline, lightly simplified (map px) for the thin border
  /// layer drawn over the satellite texture.
  static List<List<double>> borders() {
    final cached = _borders;
    if (cached != null && cached.isNotEmpty) return cached;
    double r1(double v) => (v * 10).roundToDouble() / 10;
    final out = <List<double>>[];
    for (final c in WorldMap.countries) {
      for (final r in WorldMap.projectRings(c)) {
        final n = r.length ~/ 2;
        final step = n > 24 ? 2 : 1;
        final ring = <double>[];
        for (int i = 0; i < n; i += step) {
          ring
            ..add(r1(r[i * 2]))
            ..add(r1(r[i * 2 + 1]));
        }
        if (ring.length >= 6) out.add(ring);
      }
    }
    if (out.isEmpty) out.add([0, 0, 1, 0, 1, 1]);
    return _borders = out;
  }

  /// "bounds": [[lat, lon], [lat, lon]] (any two corners) → map px box.
  static List<double>? bounds(dynamic v) {
    if (v is! List || v.length < 2 || v[0] is! List || v[1] is! List) return null;
    final a = v[0] as List, z = v[1] as List;
    if (a.length < 2 || z.length < 2) return null;
    final p0 = WorldMap.project((a[1] as num).toDouble(), (a[0] as num).toDouble());
    final p1 = WorldMap.project((z[1] as num).toDouble(), (z[0] as num).toDouble());
    return [math.min(p0[0], p1[0]), math.min(p0[1], p1[1]), math.max(p0[0], p1[0]), math.max(p0[1], p1[1])];
  }

  /// World frame and final frame ([x, y, scale%] of the map group) of a map spec.
  static (List<double>, List<double>) framing(_B b) {
    final fitWorld = math.max(b.w / WorldMap.width, b.h / WorldMap.height);
    final world = _MapKit.frame(b, [0, 300, WorldMap.width, 1500], 1.0);
    world[2] = math.max(world[2], fitWorld * 100);
    final bx = bounds(b.c['bounds']);
    if (bx != null) return (world, _MapKit.frame(b, bx, b.n('fill', 0.8)));
    final focus = b.c['focus'];
    final fc = focus == null ? null : WorldMap.find('$focus');
    if (fc != null) return (world, _MapKit.frame(b, WorldMap.bbox(fc), b.n('fill', 0.6)));
    return (world, world);
  }

  /// The visible map (or "map"), else a new satellite map: (map id, commands, map scale at start).
  static (String, List<Map<String, dynamic>>, double) ensureMap(_B b, Project p, {String? focus, List<List<double>>? box}) {
    final existing = _MapKit.findMap(p.editComp, b);
    if (existing != null) return (existing, <Map<String, dynamic>>[], mapScale(p, existing, b.start));
    final root = '${b.root}_map';
    final mb = _B(b.w, b.h, {
      'type': 'map', 'id': root, 'start': b.start, 'duration': b.dur, 'style': b.str('map_style', 'satellite'), 'zoom': false,
      'focus': ?focus, 'bounds': ?box,
    }, b.now, root);
    final (_, fin) = framing(mb);
    return (root, map(mb), fin[2] / 100);
  }

  // ------------------------------------------------------- 1. satellite map

  static const _mapKeys = [
    'fill_opacity', 'stroke_width', 'label_size', 'label_opacity', 'label_rotate', 'label_animator', 'label_stagger',
    'focus_dim', 'cities', 'bounds', 'tilt', 'zoom_rotation',
  ];

  static bool wantsMap(Map<String, dynamic> c) => c['style'] == 'satellite' || _mapKeys.any(c.containsKey);

  static bool wantsRoute(Map<String, dynamic> c) =>
      const ['label', 'arrow_head', 'line_style', 'vehicle', 'land_highlight', 'trail_fade', 'label_at', 'follow_tangent'].any(c.containsKey);

  /// World map with the V3 grammar: style "satellite" (dark Blue Marble
  /// texture, teal ocean, thin light borders), semi-transparent country fills,
  /// heavy caps labels that pop when named, box city tags.
  static List<Map<String, dynamic>> map(_B b) {
    if (!WorldMap.loaded) throw ArgumentError('World map data is not loaded');
    final style = b.str('style', 'dark');
    final sat = style == 'satellite';
    final hasBounds = bounds(b.c['bounds']) != null;
    final base = _B(b.w, b.h, {
      ...b.c, 'style': sat ? 'dark' : style, 'countries': const [],
      if (hasBounds) 'focus': null,
    }, b.now, b.root);
    final cmds = _MapKit.map(base, style: sat ? 'dark' : style, clouds: b.c['clouds'] == true);
    final g = b.g, root = b.root;
    final (world, fin) = framing(b);
    final s = fin[2] / 100;
    if (hasBounds) {
      if (b.c['zoom'] == false) {
        cmds.add(b.setp(g, 'position', [fin[0], fin[1], 0]));
        cmds.add(b.setp(g, 'scale', [fin[2], fin[2], 100]));
      } else {
        final t1 = b.start + b.n('zoom_delay', 0.3), zoom = b.n('zoom_time', 2.5);
        for (final (t, v) in [(t1, world), (t1 + zoom, fin)]) {
          cmds.add(b.kf(g, 'position', t, [v[0], v[1], 0]));
          cmds.add(b.kf(g, 'scale', t, [v[2], v[2], 100]));
        }
      }
    }
    // Continent → region ease with a slight rotation (about the frame centre).
    final zr = b.n('zoom_rotation', 0);
    if (zr != 0) {
      final keys = [
        for (final cmd in cmds)
          if (cmd['op'] == 'set_keyframe' && cmd['target'] == g && cmd['prop'] == 'position') cmd,
      ]..sort((x, y) => (x['time'] as num).compareTo(y['time'] as num));
      if (keys.length >= 2) {
        final last = keys.last;
        final v = last['value'] as List;
        final px0 = (v[0] as num).toDouble(), py0 = (v[1] as num).toDouble();
        final mx = (b.w / 2 - px0) / s, my = (b.h / 2 - py0) / s;
        final a = zr * math.pi / 180, ca = math.cos(a), sa = math.sin(a);
        last['value'] = [b.w / 2 - s * (ca * mx - sa * my), b.h / 2 - s * (sa * mx + ca * my), 0];
        cmds.add(b.kf(g, 'rotation', (keys.first['time'] as num).toDouble(), [0, 0, 0]));
        cmds.add(b.kf(g, 'rotation', (last['time'] as num).toDouble(), [0, 0, zr]));
      }
    }
    if (sat) {
      for (final cmd in cmds) {
        if (cmd['op'] == 'add_layer' && cmd['id'] == '${root}_ocean') cmd['color'] = '#08171C';
      }
      final at = cmds.indexWhere((cmd) => cmd['op'] == 'add_layer' && cmd['id'] == '${root}_world');
      cmds.insertAll(at < 0 ? cmds.length : at + 1, [
        {
          'op': 'add_layer', 'type': 'solid', 'id': '${root}_sat', 'name': 'Satellite', 'color': '#00000000', 'parent': g,
          'width': WorldMap.width, 'height': WorldMap.height, 'position': [WorldMap.width / 2, WorldMap.height / 2, 0],
          'start': b.start, 'duration': b.dur,
        },
        b.fx('${root}_sat', 'map_texture', {'amount': pct(b, 'texture_opacity', 100)}),
        {
          'op': 'add_layer', 'type': 'shape', 'id': '${root}_borders', 'name': 'Borders', 'parent': g, 'start': b.start, 'duration': b.dur,
          'rings': borders(), 'closed': true, 'fill': 'none', 'stroke': '#59FFFFFF', 'stroke_width': b.n('border_width', 0.9) / s,
        },
      ]);
      if (b.c['effects'] != false) {
        cmds.add({
          'op': 'add_layer', 'type': 'solid', 'id': '${root}_vig', 'name': 'Map Vignette', 'color': '#00000000',
          'width': b.w, 'height': b.h, 'position': [b.w / 2, b.h / 2, 0], 'start': b.start, 'duration': b.dur,
        });
        cmds.add(b.fx('${root}_vig', 'vignette', {'amount': 65, 'size': 55}));
      }
    }

    // Named countries.
    final fillOp = (b.n('fill_opacity', sat ? 0.62 : 1.0)).clamp(0.0, 100.0);
    final fo = fillOp > 1 ? fillOp / 100 : fillOp;
    final strokePx = b.n('stroke_width', sat ? 1.6 : 2.0);
    final labelPx = px(b, 'label_size', 0.06);
    final labelOp = pct(b, 'label_opacity', 100);
    final rotate = b.c['label_rotate'] ?? (sat ? 'auto' : 0);
    final animator = b.str('label_animator', 'pop');
    final stagger = b.n('label_stagger', 0.6);
    final focus = b.c['focus'] == null ? null : WorldMap.find('${b.c['focus']}');
    final dim = pct(b, 'focus_dim', 60);
    var delay = b.n('delay', 0.6);
    var i = 0;
    for (final item in (b.c['countries'] as List? ?? const [])) {
      final spec = item is Map ? Map<String, dynamic>.from(item) : {'code': '$item'};
      final c = WorldMap.find('${spec['code'] ?? spec['name']}');
      if (c == null) throw ArgumentError('Unknown country "${spec['code'] ?? spec['name']}"');
      final t = b.start + ((spec['at'] as num?)?.toDouble() ?? delay);
      final lab = spec['label'];
      cmds.addAll(country(b,
          g: g, id: '${root}_c$i', c: c, t: t, end: b.end, s: s,
          fill: '${spec['fill'] ?? (sat ? satPalette[i % satPalette.length] : '#C9A227')}',
          fillOpacity: fo, strokePx: strokePx,
          label: lab == false ? null : (lab is String ? lab : c.name),
          labelPx: labelPx, labelOpacity: labelOp, rotate: spec['label_rotate'] ?? rotate, animator: animator,
          opacity: focus != null && focus.name != c.name ? dim : 100));
      delay += stagger;
      i++;
    }
    // City tags: tiny white boxes with black caps.
    var ci = 0;
    for (final item in (b.c['cities'] as List? ?? const [])) {
      if (item is! Map || item['lat'] is! num || item['lon'] is! num) {
        throw ArgumentError('cities: each city needs {name, lat, lon, at?}');
      }
      final pt = WorldMap.project((item['lon'] as num).toDouble(), (item['lat'] as num).toDouble());
      final t = b.start + ((item['at'] as num?)?.toDouble() ?? delay);
      final cb = _B(b.w, b.h, {
        'start': t, 'duration': math.max(0.2, b.end - t), 'side': item['side'] ?? 'right',
        'label_size': item['size'] ?? b.c['tag_size'] ?? 0.022,
      }, b.now, '${root}_city$ci');
      cmds.addAll(_MapKit._pinGroup(cb, root, pt, 'City ${item['name'] ?? ci}'));
      cmds.addAll(tagBody(cb, '${item['name'] ?? ''}', t, cb.end));
      delay += stagger * 0.5;
      ci++;
    }
    // 3D pitch (pattern 4): the map group moves into a tilted precomp.
    if (b.c['tilt'] is num && b.n('tilt', 0) != 0) {
      cmds.add({
        'op': 'map_tilt', 'map': root, 'tilt': b.n('tilt', 38), 'roll': b.n('roll', -10),
        'at': b.start + b.n('tilt_at', math.max(0.0, delay)), 'duration': b.n('tilt_duration', 0.6),
      });
    }
    return cmds;
  }

  /// White box with black caps next to a small dot, children of [b.g]
  /// (a counter-scaled pin group: sizes in screen px).
  static List<Map<String, dynamic>> tagBody(_B b, String label, double t, double end) {
    final fs = px(b, 'label_size', 0.022).clamp(4.0, 400.0);
    final r = fs * 0.3;
    final du = math.max(0.1, end - t);
    Map<String, dynamic> on(Map<String, dynamic> c) => {...c, 'start': t, 'duration': du};
    final cmds = <Map<String, dynamic>>[
      on(b.shape('dot', 'ellipse', r * 2, r * 2, 0, 0, fill: '#FFFFFF', stroke: '#111111', strokeWidth: r * 0.45)),
      b.kf(b.id('dot'), 'scale', t, [0, 0, 100], 'back'),
      b.kf(b.id('dot'), 'scale', t + 0.25, [100, 100, 100]),
    ];
    final text = label.toUpperCase();
    if (text.isEmpty) return cmds;
    final tw = text.length * fs * 0.68 + fs * 0.9, th = fs * 1.5;
    final side = b.str('side', 'right');
    final (x, y) = switch (side) {
      'left' => (-(r * 1.6 + tw / 2), 0.0),
      'top' => (0.0, -(r * 1.6 + th / 2)),
      'bottom' => (0.0, r * 1.6 + th / 2),
      _ => (r * 1.6 + tw / 2, 0.0),
    };
    cmds.add(on(b.shape('box', 'rect', tw, th, x, y, fill: '#FFFFFF', corner: fs * 0.12)));
    cmds.add(b.fx(b.id('box'), 'shadow', {'distance': 3, 'blur': 6, 'opacity': 45}));
    cmds.add(on(b.text('tag', text, tw, th, x, y, fs, color: '#111111', weight: 800)..['font'] = font));
    for (final id in [b.id('box'), b.id('tag')]) {
      cmds.addAll([
        b.kf(id, 'scale', t + 0.05, [120, 120, 100], 'ease_out'),
        b.kf(id, 'scale', t + 0.3, [100, 100, 100]),
        b.kf(id, 'opacity', t + 0.05, 0, 'ease_out'),
        b.kf(id, 'opacity', t + 0.2, 100),
      ]);
    }
    return cmds;
  }

  /// map_pin {tag_style: "box"}: city tag on a map (the visible one if no "map").
  static List<Map<String, dynamic>> cityTag(_B b, Project p) {
    final (map, cmds, _) = ensureMap(b, p);
    final _Place place = b.c['lat'] is num && b.c['lon'] is num
        ? (pt: WorldMap.project(b.n('lon', 0), b.n('lat', 0)), country: null)
        : _MapKit.placeOf(b.c['country'] ?? b.c['place'], 'India');
    cmds.addAll(_MapKit._pinGroup(b, map, place.pt, 'City Tag'));
    final t = b.start + b.n('delay', 0);
    cmds.addAll(tagBody(b, b.str('label', place.country?.name ?? ''), t, b.end));
    return cmds;
  }

  // --------------------------------------------- 2 + 6. routes and labels

  /// Route label ("11 MINS"): heavy caps at [at] (0..1) along [path], along
  /// its tangent, wiping in over 0.4 s at [t].
  static List<Map<String, dynamic>> routeLabel(_B b, String id, String parent, MotionPath path, String text, double fs, double t, double end,
      {double at = 0.5, bool tangent = true}) {
    final sm = path.sample(at.clamp(0.0, 1.0));
    final rot = tangent ? readable(sm.angle) : 0.0;
    final rr = rot * math.pi / 180;
    final nx = math.sin(rr), ny = -math.cos(rr); // "above" the line
    final x = sm.x + nx * fs * 0.85, y = sm.y + ny * fs * 0.85;
    final cmds = label(b, id, parent, text.toUpperCase(), x, y, fs, t, end, rot: rot, animator: 'none');
    final fx = '${id}_wipe';
    cmds.add(b.fx(id, 'reveal', {'kind': 'wipe', 'progress': 0, 'softness': 25}, fx));
    cmds.add({'op': 'set_keyframe', 'target': id, 'effect': fx, 'prop': 'progress', 'time': t, 'value': 0, 'ease': 'ease_out'});
    cmds.add({'op': 'set_keyframe', 'target': id, 'effect': fx, 'prop': 'progress', 'time': t + 0.4, 'value': 100});
    return cmds;
  }

  /// map_route V3: white arc (solid/dashed, arrowhead) drawing on, with an
  /// optional duration label at its midpoint along the tangent.
  static List<Map<String, dynamic>> mapRoute(_B b, Project p) {
    final (map, cmds, s0) = ensureMap(b, p);
    final g = '${map}_g';
    final from = _MapKit.placeOf(b.c['from'], 'India'), to = _MapKit.placeOf(b.c['to'], 'United Kingdom');
    final a = from.pt, z = to.pt;
    final bend = b.n('bend', 0.25);
    final dx = z[0] - a[0], dy = z[1] - a[1];
    final mid = [(a[0] + z[0]) / 2 - dy * bend, (a[1] + z[1]) / 2 + dx * bend];
    final pts = [a, mid, z];
    final draw = b.n('draw', 1.4);
    final s = math.max(1e-3, s0);
    final w = px(b, 'line_width', 0.0045) / s;
    final dashed = b.str('line_style', b.c['dashed'] == true ? 'dashed' : 'solid') == 'dashed';
    final line = b.id('line');
    cmds.add(b.path('line', pts,
        stroke: b.str('color', '#FFFFFF'), width: w, smooth: true, parent: g, dash: dashed ? [w * 2.6, w * 1.8] : null, arrowEnd: b.flag('arrow_head', true)));
    cmds.add(b.kf(line, 'trim', b.start, [0, 0]));
    cmds.add(b.kf(line, 'trim', b.start + draw, [0, 100]));
    final text = b.str('label', '');
    if (text.isNotEmpty) {
      final at = b.n('label_at', 0.5);
      final t = b.start + draw * whenEased(at);
      cmds.addAll(routeLabel(b, b.id('label'), g, MotionPath(points: pts, smooth: true), text, px(b, 'label_size', 0.045) / s, t, b.end,
          at: at, tangent: b.flag('follow_tangent', true)));
    }
    return cmds;
  }

  /// route_follow V3: white arrow (solid/dashed) draws A→B in ~2.2 s while
  /// the map drifts toward the tip; optional vehicle cut-out oriented along
  /// the path, trail fade, arrival highlight + label, duration label.
  static List<Map<String, dynamic>> routeFollow(_B b, Project p) {
    final from = _MapKit.placeOf(b.c['from'], 'India'), to = _MapKit.placeOf(b.c['to'], 'United Kingdom');
    final cmds = <Map<String, dynamic>>[];
    var map = _MapKit.findMap(p.editComp, b, auto: false);
    final created = map == null;
    if (map == null) {
      map = '${b.root}_map';
      cmds.addAll(Components.build(p, {
        'type': 'map', 'id': map, 'start': b.start, 'duration': b.dur, 'style': b.str('style', 'satellite'), 'zoom': false,
        'clouds': b.flag('clouds', false),
      }, b.now));
    }
    final g = '${map}_g';
    final a = from.pt, z = to.pt;
    final len = math.max(1.0, math.sqrt(math.pow(z[0] - a[0], 2) + math.pow(z[1] - a[1], 2)));
    final bend = b.n('bend', 0.2);
    final up = MotionPath.arc(a, z, len * bend), down = MotionPath.arc(a, z, -len * bend);
    final path0 = up.points.length > 1 && up.points[1][1] <= down.points[1][1] ? up : down;
    final pts = [for (final q in path0.points) [q[0], q[1]]];
    final path = MotionPath(points: pts, smooth: true);
    // Framing: the whole route at "fill", drifting toward the tip.
    double minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9;
    for (int i = 0; i <= 20; i++) {
      final q = path.sample(i / 20);
      minX = math.min(minX, q.x);
      maxX = math.max(maxX, q.x);
      minY = math.min(minY, q.y);
      maxY = math.max(maxY, q.y);
    }
    final fit = math.max(b.w / WorldMap.width, b.h / WorldMap.height);
    final fr = _MapKit.frame(b, [minX - 20, minY - 20, maxX + 20, maxY + 20], b.n('fill', 0.62));
    final s = (fr[2] / 100).clamp(fit, 14.0);
    final cx0 = (minX + maxX) / 2, cy0 = (minY + maxY) / 2;
    final follow = b.n('follow', 0.35).clamp(0.0, 1.0), push = b.n('push', 0.08);
    final tA = b.start + math.min(b.n('delay', 0.4), b.dur * 0.2);
    final tB = math.min(tA + b.n('draw', 2.2), b.end - math.min(0.4, b.dur * 0.1));
    final px1 = 1 / s; // one screen pixel in map px
    final w = px(b, 'line_width', 0.0045) * px1;
    final color = b.str('color', '#FFFFFF');
    final dashed = b.str('line_style', b.c['dashed'] == true ? 'dashed' : 'solid') == 'dashed';
    final trail = b.c['trail_fade'] is num ? b.n('trail_fade', 0.3) : (b.c['trail_fade'] == true ? 0.3 : 0.0);
    // Highlights first (under the line): origin at the start, destination on arrival.
    bool shown(Country c) => p.editComp.layers.any((l) => l.parentId == g && l.name == c.name);
    final fc = from.country, tc = to.country;
    if (fc != null && b.flag('from_highlight', true) && (created || !shown(fc))) {
      cmds.addAll(country(b, g: g, id: b.id('land_from'), c: fc, t: b.start + 0.1, end: b.end, s: s, fill: '#5560B8', label: fc.name, labelPx: b.h * 0.05));
    }
    final lh = b.c['land_highlight'];
    if (tc != null && lh != false && (created || !shown(tc))) {
      final spec = lh is Map ? Map<String, dynamic>.from(lh) : const <String, dynamic>{};
      final lab = spec['label'];
      cmds.addAll(country(b,
          g: g, id: b.id('land'), c: tc, t: tB, end: b.end, s: s * (1 + push), fill: '${spec['fill'] ?? '#A83232'}',
          label: lab == false ? null : (lab is String ? lab : tc.name), labelPx: b.h * 0.06));
    }
    cmds.add({...b.path('shade', pts, stroke: '#73000000', width: w * 2.4, smooth: true, parent: g, dash: dashed ? [w * 2.6, w * 1.8] : null)});
    cmds.add(b.path('line', pts,
        stroke: color, width: w, smooth: true, parent: g, dash: dashed ? [w * 2.6, w * 1.8] : null, arrowEnd: b.flag('arrow_head', true)));
    final dot = 14 * px1 * b.h / 1080;
    cmds.add(b.shape('a', 'ellipse', dot, dot, a[0], a[1], fill: '#FFFFFF', stroke: '#111111', strokeWidth: dot * 0.2)..['parent'] = g);
    cmds.add({...b.shape('z', 'ellipse', dot, dot, z[0], z[1], fill: '#FFFFFF', stroke: '#111111', strokeWidth: dot * 0.2), 'parent': g, 'start': tB, 'duration': math.max(0.2, b.end - tB)});
    cmds.add(b.kf(b.id('z'), 'scale', tB, [0, 0, 100], 'back'));
    cmds.add(b.kf(b.id('z'), 'scale', tB + 0.3, [100, 100, 100]));
    // Traveller: vehicle cut-out (oriented), avatar, or a glowing tip.
    final veh = b.mediaOf(p, 'vehicle');
    final avatar = b.mediaOf(p, 'avatar');
    final av = b.id('av');
    if (veh != null || avatar != null || b.c['vehicle'] == null) {
      cmds.add({
        'op': 'add_layer', 'type': 'null', 'id': av, 'name': 'Traveller', 'parent': g, 'start': b.start, 'duration': b.dur,
        'path': {'points': pts, 'smooth': true, 'orient': veh != null && b.flag('orient', true)}, 'position': [0, 0, 0], 'scale': [100 / s, 100 / s, 100],
      });
      cmds.add(b.setp(av, 'anchor', [0, 0, 0]));
      if (veh != null) {
        cmds.add({...b.media('veh', veh, 0, 0, widthPx: px(b, 'vehicle_size', 0.09)), 'parent': av});
        if (b.c['vehicle_angle'] is num) cmds.add(b.setp(b.id('veh'), 'rotation', [0, 0, b.n('vehicle_angle', 0)]));
        cmds.add(b.fx(b.id('veh'), 'shadow', {'distance': 10, 'blur': 10, 'opacity': 55}));
      } else if (avatar != null) {
        cmds.addAll(_MapKit._avatarBody(b, p, av, b.h * 0.045, b.start, b.dur));
      } else {
        cmds.add({...b.shape('tip', 'ellipse', b.h * 0.02, b.h * 0.02, 0, 0, fill: '#FFFFFF'), 'parent': av});
        cmds.add(b.fx(b.id('tip'), 'glow', {'amount': 70, 'radius': 14}));
      }
    } else {
      throw ArgumentError('vehicle "${b.c['vehicle']}" is not an imported photo/video id');
    }
    const n = 12;
    for (int i = 0; i <= n; i++) {
      final u = i / n;
      final e = Easing.easyEase.transform(u);
      final t = tA + (tB - tA) * u;
      final tip = path.sample(e);
      final sc = s * (1 + push * e);
      final cx = cx0 + (tip.x - cx0) * follow, cy = cy0 + (tip.y - cy0) * follow;
      final ts = trail > 0 ? math.max(0.0, e - trail) * 100 : 0.0;
      for (final id in [b.id('line'), b.id('shade')]) {
        cmds.add(b.kf(id, 'trim', t, [ts, e * 100], 'linear'));
      }
      cmds.add(b.kf(av, 'path_progress', t, e * 100, 'linear'));
      cmds.add(b.kf(g, 'position', t, [b.w / 2 - sc * cx, b.h / 2 - sc * cy, 0], 'linear'));
      cmds.add(b.kf(g, 'scale', t, [sc * 100, sc * 100, 100], 'linear'));
    }
    if (trail > 0) {
      // The tail finishes fading after arrival.
      for (final id in [b.id('line'), b.id('shade')]) {
        cmds.add(b.kf(id, 'trim', math.min(b.end, tB + 0.6), [100, 100]));
      }
    }
    final text = b.str('label', '');
    if (text.isNotEmpty) {
      final at = b.n('label_at', 0.5);
      final t = tA + (tB - tA) * whenEased(at);
      cmds.addAll(routeLabel(b, b.id('label'), g, path, text, b.h * b.n('label_size', 0.045) / s, t, b.end,
          at: at, tangent: b.flag('follow_tangent', true)));
    }
    cmds.add({'op': 'set_comp', 'motion_blur': true});
    return cmds;
  }

  // --------------------------------------------- 7. rings on things / places

  /// Group null for an overlay: on a layer ("attach"), a map place (lat+lon /
  /// "place" / at:{lat, lon}) or a comp point (x, y | at:[x, y]). Children are
  /// in screen px.
  static List<Map<String, dynamic>> anchorGroup(_B b, Project p, String name) {
    final comp = p.editComp;
    final att = b.c['attach'];
    if (att is String && att.isNotEmpty) {
      final l = comp.layerById(att);
      if (l == null) throw ArgumentError('No layer "$att" to attach to');
      final an = l.prop(Props.anchor).valueAt(b.start);
      final k = 100 / worldScale(comp, l, b.start);
      return [
        {
          'op': 'add_layer', 'type': 'null', 'id': b.g, 'name': name, 'parent': att, 'start': b.start, 'duration': b.dur,
          'position': [an[0], an[1], 0], 'scale': [k, k, 100],
        },
        b.setp(b.g, 'anchor', [0, 0, 0]),
      ];
    }
    final at = b.c['at'];
    final geo = (b.c['lat'] is num && b.c['lon'] is num) || b.c['place'] != null || (at is Map && at['lat'] is num);
    if (geo) {
      final (map, cmds, _) = ensureMap(b, p);
      final _Place pl = b.c['lat'] is num && b.c['lon'] is num
          ? (pt: WorldMap.project(b.n('lon', 0), b.n('lat', 0)), country: null)
          : _MapKit.placeOf(at is Map ? at : b.c['place'], 'India');
      cmds.addAll(_MapKit._pinGroup(b, map, pl.pt, name));
      return cmds;
    }
    final xy = at is List && at.length >= 2 ? b.vec('at', [b.w / 2, b.h / 2]) : [b.n('x', b.w / 2), b.n('y', b.h / 2)];
    return b.group(name, x: xy[0], y: xy[1]);
  }

  /// Red dashed ring spinning around a vehicle / place (4 s per turn).
  static List<Map<String, dynamic>> statusRing(_B b, Project p) {
    final cmds = anchorGroup(b, p, 'Status Ring');
    final r = px(b, 'size', 0.06), sw = px(b, 'stroke_width', 0.006);
    final color = b.str('color', red);
    final circ = 2 * math.pi * r;
    final seg = circ / math.max(4, b.n('dashes', 16));
    final id = b.id('ring');
    cmds.add({
      ...b.shape('ring', 'ellipse', r * 2, r * 2, 0, 0, fill: 'none', stroke: color, strokeWidth: sw),
      if (b.flag('dashed', true)) 'dash': [seg * 0.62, seg * 0.38],
    });
    if (b.flag('glow', true)) cmds.add(b.fx(id, 'glow', {'amount': 45, 'radius': 8}));
    final spin = b.n('spin', 4);
    if (spin > 0) {
      cmds.add(b.kf(id, 'rotation', b.start, [0, 0, 0], 'linear'));
      cmds.add(b.kf(id, 'rotation', b.end, [0, 0, 360 * b.dur / spin]));
    }
    cmds.add(b.kf(id, 'scale', b.start, [0, 0, 100], 'back'));
    cmds.add(b.kf(id, 'scale', b.start + 0.35, [100, 100, 100]));
    return cmds;
  }

  /// Expanding, fading rings: radio signal (red, flattened, 0.75 s) or a
  /// generic pulse (white concentric, 4 rings, 1.2 s).
  static List<Map<String, dynamic>> rings(_B b, Project p, {required bool pulse}) {
    final cmds = anchorGroup(b, p, pulse ? 'Pulse Rings' : 'Signal Rings');
    final color = b.str('color', pulse ? '#FFFFFF' : red);
    final count = b.n('count', pulse ? 4 : 3).round().clamp(1, 8);
    final period = math.max(0.2, b.n('period', pulse ? 1.2 : 0.75));
    final flatten = b.n('flatten', pulse ? 0 : 0.35).clamp(0.0, 0.95);
    final maxR = px(b, 'max_radius', pulse ? 0.1 : 0.12);
    final sw = px(b, 'stroke_width', pulse ? 0.004 : 0.005);
    final peak = pct(b, 'opacity', 100);
    final t0 = b.start + b.n('delay', 0);
    for (int i = 0; i < count; i++) {
      final id = b.id('ring$i');
      cmds.add(b.shape('ring$i', 'ellipse', maxR * 2, maxR * 2 * (1 - flatten), 0, 0, fill: 'none', stroke: color, strokeWidth: sw));
      final first = t0 + i * period / count;
      if (first > b.start + 1e-6) cmds.add(b.kf(id, 'opacity', b.start, 0, 'hold'));
      var cycles = 0;
      for (var c0 = first; c0 < b.end && cycles < 300; c0 += period, cycles++) {
        final c1 = c0 + period * 0.98;
        cmds.addAll([
          b.kf(id, 'scale', c0, [12, 12, 100], 'ease_out'),
          b.kf(id, 'scale', c1, [100, 100, 100], 'hold'),
          b.kf(id, 'opacity', c0, peak, 'ease_in'),
          b.kf(id, 'opacity', c1, 0, 'hold'),
        ]);
      }
    }
    return cmds;
  }

  // --------------------------------------------------- 8. geo label, path text

  /// "CRASH SITE" anchored to a point with a hooked pointer line.
  static List<Map<String, dynamic>> geoLabel(_B b, Project p) {
    final cmds = anchorGroup(b, p, 'Geo Label');
    final text = b.str('text', 'CRASH SITE').toUpperCase();
    final fs = px(b, 'size', 0.04);
    final color = b.str('color', '#FFFFFF');
    final left = b.str('side', 'right') == 'left';
    final sx = left ? -1.0 : 1.0;
    final l = px(b, 'length', 0.12);
    final pointer = b.str('pointer', 'hook');
    final t0 = b.start + b.n('delay', 0);
    final du = math.max(0.1, b.end - t0);
    final r = fs * 0.2;
    cmds.add({...b.shape('dot', 'ellipse', r * 2, r * 2, 0, 0, fill: color, stroke: '#111111', strokeWidth: r * 0.4), 'start': t0, 'duration': du});
    cmds.add(b.kf(b.id('dot'), 'scale', t0, [0, 0, 100], 'back'));
    cmds.add(b.kf(b.id('dot'), 'scale', t0 + 0.25, [100, 100, 100]));
    double ex = 0, ey = -l;
    if (pointer != 'none') {
      final List<List<double>> pts = pointer == 'line'
          ? [[0, 0], [sx * l * 0.5, -l]]
          : [[0, 0], [0, -l * 0.62], [sx * l * 0.12, -l * 0.94], [sx * l * 0.42, -l]];
      ex = pts.last[0];
      ey = pts.last[1];
      final id = b.id('pointer');
      cmds.add(b.path('pointer', pts, stroke: color, width: math.max(1.5, fs * 0.08), smooth: pointer == 'hook', st: t0, du: du));
      cmds.add(b.fx(id, 'shadow', {'distance': 2, 'blur': 4, 'opacity': 60}));
      cmds.add(b.kf(id, 'trim', t0 + 0.1, [0, 0]));
      cmds.add(b.kf(id, 'trim', t0 + 0.5, [0, 100]));
    }
    final tw = fs * (text.length * 0.78 + 1.5);
    final gap = fs * 0.35;
    final tt = t0 + (pointer == 'none' ? 0.1 : 0.45);
    cmds.addAll(label(b, b.id('text'), b.g, text, ex + sx * (gap + tw / 2), ey, fs, tt, b.end,
        animator: b.str('animator', 'typewriter'), color: color, align: left ? 'right' : 'left'));
    return cmds;
  }

  /// Text along a path: one letter layer per character, rotated to the
  /// tangent, typed on letter by letter.
  static List<Map<String, dynamic>> pathText(_B b, Project p) {
    final comp = p.editComp;
    final text = b.str('text', 'PLAN TO GO').toUpperCase();
    String? parent;
    List<List<double>> pts;
    var smooth = true;
    final pl = b.c['path_layer'];
    if (pl is String) {
      final l = comp.layerById(pl);
      final sh = l?.shape;
      if (l == null || sh == null || sh.rings.isEmpty || sh.rings.first.length < 4) {
        throw ArgumentError('path_layer "$pl" must be a shape layer with points (a line/path)');
      }
      final m = Evaluator.localMatrix(l, b.start);
      final r = sh.rings.first;
      pts = [
        for (int i = 0; i + 1 < r.length; i += 2) [m[0] * r[i] + m[4] * r[i + 1] + m[12], m[1] * r[i] + m[5] * r[i + 1] + m[13]],
      ];
      parent = l.parentId;
      smooth = sh.smooth;
    } else if (b.c['points'] is List && (b.c['points'] as List).length >= 2) {
      pts = [for (final q in b.c['points'] as List) [((q as List)[0] as num).toDouble(), (q[1] as num).toDouble()]];
    } else {
      pts = [for (final q in MotionPath.arc([b.w * 0.2, b.h * 0.64], [b.w * 0.8, b.h * 0.5], b.h * 0.12).points) [q[0], q[1]]];
    }
    final path = MotionPath(points: pts, smooth: smooth);
    final len = math.max(1.0, path.length);
    final pLayer = parent == null ? null : comp.layerById(parent);
    final unit = pLayer == null ? 1.0 : worldScale(comp, pLayer, b.start);
    final fs = px(b, 'size', 0.04) / unit;
    final spacing = b.n('spacing', 0.1);
    final chars = text.runes.map(String.fromCharCode).take(80).toList();
    double adv(String ch) => ch == ' ' ? fs * 0.4 : fs * (0.7 + spacing);
    final total = chars.fold<double>(0, (s, ch) => s + adv(ch));
    final start = b.c['offset'] is num ? b.n('offset', 0) * len : math.max(0.0, (len - total) / 2);
    final lift = b.n('lift', 0.65) * fs;
    final typing = b.flag('typing', true);
    final cps = math.max(1.0, b.n('cps', 14));
    final color = b.str('color', '#FFFFFF');
    final cmds = <Map<String, dynamic>>[];
    var cum = start;
    var k = 0;
    final t0 = b.start + b.n('delay', 0);
    for (final ch in chars) {
      final a = adv(ch);
      if (ch != ' ') {
        final sm = path.sample(((cum + a / 2) / len).clamp(0.0, 1.0));
        final rr = sm.angle * math.pi / 180;
        final x = sm.x + math.sin(rr) * lift, y = sm.y - math.cos(rr) * lift;
        final t = typing ? t0 + k / cps : t0;
        final id = b.id('ch$k');
        cmds.add({
          'op': 'add_layer', 'type': 'text', 'id': id, 'name': 'Path text $ch', 'parent': ?parent, 'start': t,
          'duration': math.max(0.1, b.end - t), 'text': ch, 'font': font, 'font_size': fs, 'font_weight': 900, 'text_color': color,
          'width': fs * 1.4, 'height': fs * 1.5, 'position': [x, y, 0], 'shadow': true,
        });
        cmds.add(b.setp(id, 'rotation', [0, 0, sm.angle]));
        if (typing) {
          cmds.add(b.kf(id, 'scale', t, [140, 140, 100], 'ease_out'));
          cmds.add(b.kf(id, 'scale', t + 0.12, [100, 100, 100]));
        }
        k++;
      }
      cum += a;
    }
    if (cmds.isEmpty) throw ArgumentError('path_text needs "text"');
    return cmds;
  }

  // ------------------------------------------------ 4. terrain label (+ peaks)

  static const _andes = [
    [-4.0, -79.6], [-14.0, -74.6], [-22.0, -68.2], [-33.0, -70.0], [-46.0, -72.6],
  ];

  /// Letter-spaced label laid along a map feature (mountain range, river)
  /// with optional peak hatch glyphs.
  static List<Map<String, dynamic>> terrainLabel(_B b, Project p) {
    final raw = b.c['along'] is List && (b.c['along'] as List).length >= 2 ? b.c['along'] as List : _andes;
    final ll = [for (final q in raw) [((q as List)[0] as num).toDouble(), (q[1] as num).toDouble()]];
    var pts = [for (final q in ll) WorldMap.project(q[1], q[0])];
    double minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
    for (final q in ll) {
      minLat = math.min(minLat, q[0]);
      maxLat = math.max(maxLat, q[0]);
      minLon = math.min(minLon, q[1]);
      maxLon = math.max(maxLon, q[1]);
    }
    final padLat = math.max(3.0, (maxLat - minLat) * 0.25), padLon = math.max(3.0, (maxLon - minLon) * 0.6);
    final (map, cmds, s0) = ensureMap(b, p, box: [
      [minLat - padLat, minLon - padLon],
      [maxLat + padLat, maxLon + padLon],
    ]);
    final g = '${map}_g';
    final s = math.max(1e-3, s0);
    // Read left→right / bottom→top.
    final d0 = pts.first, d1 = pts.last;
    final dir = math.atan2(d1[1] - d0[1], d1[0] - d0[0]);
    final steep = math.cos(dir).abs() < 0.5;
    if (steep ? math.sin(dir) > 0 : math.cos(dir) < 0) pts = pts.reversed.toList();
    final path = MotionPath(points: pts, smooth: true);
    final text = b.str('text', 'ANDES').toUpperCase();
    final fs = px(b, 'size', 0.045) / s;
    final letters = text.runes.map(String.fromCharCode).toList();
    final n = letters.length;
    final t0 = b.start + b.n('delay', 0.2);
    final color = b.str('color', '#FFFFFF');
    final spread = b.n('spread', 0.8).clamp(0.1, 1.0);
    for (int i = 0; i < n; i++) {
      if (letters[i] == ' ') continue;
      final u = (1 - spread) / 2 + spread * (i + 0.5) / n;
      final sm = path.sample(u);
      final t = t0 + i * b.n('stagger', 0.06);
      final id = b.id('l$i');
      cmds.add({
        'op': 'add_layer', 'type': 'text', 'id': id, 'name': 'Terrain ${letters[i]}', 'parent': g, 'start': t, 'duration': math.max(0.1, b.end - t),
        'text': letters[i], 'font': font, 'font_size': fs, 'font_weight': 800, 'text_color': color, 'width': fs * 1.4, 'height': fs * 1.5,
        'position': [sm.x, sm.y, 0], 'shadow': true,
      });
      cmds.add(b.setp(id, 'rotation', [0, 0, sm.angle]));
      cmds.add(b.kf(id, 'opacity', t, 0, 'ease_out'));
      cmds.add(b.kf(id, 'opacity', t + 0.3, pct(b, 'opacity', 90)));
    }
    if (b.str('glyphs', 'peaks') == 'peaks') {
      final rings = <List<double>>[];
      final gsz = fs * 0.32;
      final step = math.max(fs * 1.1, path.length / 60);
      var side = 1.0;
      for (double d = step / 2; d < path.length && rings.length < 120; d += step) {
        final sm = path.sample(d / path.length);
        final rr = sm.angle * math.pi / 180;
        final off = fs * (1.15 + 0.35 * ((rings.length * 7) % 3) / 2);
        final x = sm.x + math.sin(rr) * off * side, y = sm.y - math.cos(rr) * off * side;
        rings.add([x - gsz, y + gsz * 0.55, x, y - gsz * 0.55, x + gsz, y + gsz * 0.55]);
        side = -side;
      }
      final id = b.id('peaks');
      cmds.add({
        'op': 'add_layer', 'type': 'shape', 'id': id, 'name': 'Peaks', 'parent': g, 'start': t0, 'duration': math.max(0.1, b.end - t0),
        'rings': rings, 'closed': false, 'fill': 'none', 'stroke': '#B3FFFFFF', 'stroke_width': fs * 0.08,
      });
      cmds.add(b.kf(id, 'opacity', t0, 0, 'ease_out'));
      cmds.add(b.kf(id, 'opacity', t0 + 0.6, 100));
    }
    return cmds;
  }

  // ---------------------------------------------- 5. giant ghost country word

  static List<Map<String, dynamic>> watermark(_B b, Project p) {
    final code = b.str('code', b.str('country', 'Chile'));
    final c = WorldMap.find(code);
    if (c == null) throw ArgumentError('Unknown country "$code"');
    final (map, cmds, s0) = ensureMap(b, p, focus: c.name);
    final s = math.max(1e-3, s0);
    final g = '${map}_g';
    final text = b.str('text', c.name).toUpperCase();
    final fs = px(b, 'size', 0.35) / s;
    final rot = labelRotation(c, b.c['rotate'] ?? 'auto', minElong: 1.4);
    final lp = WorldMap.project(c.labelLon, c.labelLat);
    final id = b.id('word');
    final op = pct(b, 'opacity', 60);
    cmds.add({
      'op': 'add_layer', 'type': 'text', 'id': id, 'name': 'Ghost $text', 'parent': g, 'start': b.start, 'duration': b.dur,
      'text': text, 'font': font, 'font_size': fs, 'font_weight': 900, 'text_color': b.str('color', '#FFFFFF'),
      'width': fs * (text.length * 0.8 + 1), 'height': fs * 1.3, 'position': [lp[0], lp[1], 0], 'shadow': false,
    });
    if (rot != 0) cmds.add(b.setp(id, 'rotation', [0, 0, rot]));
    cmds.add(b.kf(id, 'opacity', b.start, 0, 'ease_out'));
    cmds.add(b.kf(id, 'opacity', b.start + 0.8, op));
    cmds.add(b.kf(id, 'scale', b.start, [100, 100, 100], 'linear'));
    cmds.add(b.kf(id, 'scale', b.end, [104, 104, 100]));
    return cmds;
  }

  // --------------------------------------------------------- 9. search sweep

  static List<Map<String, dynamic>> searchSweep(_B b0, Project p) {
    final b = b0.c['duration'] == null ? _B(b0.w, b0.h, {...b0.c, 'duration': 4.5}, b0.now, b0.root) : b0;
    final w = b.w, h = b.h;
    final cmds = b.group('Search Sweep', x: w / 2, y: h / 2);
    // Ground (slowly trucking) with the place name lying on it.
    cmds.addAll(b.nul('ground_g', 0, 0, name: 'Ground'));
    final gg = b.id('ground_g');
    final ground = b.mediaOf(p, 'ground');
    if (ground != null) {
      final k = math.max(w * 1.14 / math.max(1, ground.width), h * 1.14 / math.max(1, ground.height));
      cmds.add(b.media('ground', ground, 0, 0, widthPx: ground.width * k, parent: gg));
      cmds.add(b.fx(b.id('ground'), 'color', {'brightness': -12, 'contrast': 8, 'saturation': -55}));
    } else {
      cmds.add({...b.shape('ground', 'rect', w * 1.16, h * 1.16, 0, 0, fill: b.str('ground_color', '#6E7A83'), fill2: '#39434B'), 'parent': gg});
      cmds.add(b.fx(b.id('ground'), 'grunge', {'amount': 55}));
      cmds.add(b.fx(b.id('ground'), 'grain', {'amount': 22, 'size': 2}));
    }
    cmds.add(b.kf(gg, 'position', b.start, [-w * 0.025, 0, 0], 'easy_ease'));
    cmds.add(b.kf(gg, 'position', b.end, [w * 0.025, 0, 0]));
    cmds.add(b.kf(gg, 'scale', b.start, [100, 100, 100], 'linear'));
    cmds.add(b.kf(gg, 'scale', b.end, [106, 106, 100]));
    final place = b.str('place', 'ANDES').toUpperCase();
    if (place.isNotEmpty) {
      final fs = px(b, 'place_size', 0.2);
      cmds.add({
        ...b.text('place', place, fs * (place.length * 0.8 + 1), fs * 1.3, 0, h * 0.06, fs, color: '#7A1420', weight: 900),
        'font': font, 'parent': gg,
      });
      cmds.add(b.setp(b.id('place'), 'rotation', [0, 0, b.n('place_angle', -7)]));
      cmds.add(b.setp(b.id('place'), 'opacity', 88));
    }
    // Vehicle on its path (top-down helicopter: cut-out or vector).
    final raw = b.c['path'] is List && (b.c['path'] as List).length >= 2
        ? [for (final q in b.c['path'] as List) [((q as List)[0] as num).toDouble(), (q[1] as num).toDouble()]]
        : [[-0.12, 0.78], [0.3, 0.42], [0.62, 0.6], [1.12, 0.22]];
    final pts = [for (final q in raw) [(q[0] - 0.5) * w, (q[1] - 0.5) * h]];
    final path = MotionPath(points: pts, smooth: true);
    final vs = b.n('vehicle_size', 0.08) <= 1 ? b.n('vehicle_size', 0.08) * w : b.n('vehicle_size', 0.08);
    final heli = b.id('heli');
    // Searchlight: soft white ellipse wandering just ahead of the vehicle.
    final beamW = b.n('beam_size', 0.12) * w;
    final beam = b.id('beam');
    cmds.add(b.shape('beam', 'ellipse', beamW, beamW * 0.78, 0, 0, fill: '#FFFFFF'));
    cmds.add(b.fx(beam, 'blur', {'amount': 55}));
    cmds.add(b.setp(beam, 'opacity', 40));
    const steps = 18;
    for (int i = 0; i <= steps; i++) {
      final u = i / steps;
      final e = Easing.easyEase.transform(u);
      final t = b.start + b.dur * u;
      final q = path.sample(math.min(1.0, e + 0.07));
      final wx = math.sin(t * 1.9 + 0.7) * w * 0.045, wy = math.cos(t * 1.4) * h * 0.05;
      cmds.add(b.kf(beam, 'position', t, [q.x + wx, q.y + wy, 0], 'linear'));
    }
    cmds.add({
      'op': 'add_layer', 'type': 'null', 'id': heli, 'name': 'Vehicle', 'parent': b.g, 'start': b.start, 'duration': b.dur,
      'path': {'points': pts, 'smooth': true, 'orient': true}, 'position': [0, 0, 0],
    });
    cmds.add(b.setp(heli, 'anchor', [0, 0, 0]));
    cmds.add(b.kf(heli, 'path_progress', b.start, 0, 'easy_ease'));
    cmds.add(b.kf(heli, 'path_progress', b.end, 100));
    final veh = b.mediaOf(p, 'vehicle');
    if (veh != null) {
      cmds.add({...b.media('veh', veh, 0, 0, widthPx: vs), 'parent': heli});
      if (b.c['vehicle_angle'] is num) cmds.add(b.setp(b.id('veh'), 'rotation', [0, 0, b.n('vehicle_angle', 0)]));
      cmds.add(b.fx(b.id('veh'), 'shadow', {'distance': vs * 0.35, 'angle': 60, 'blur': 10, 'opacity': 55}));
    } else {
      Map<String, dynamic> on(Map<String, dynamic> c) => {...c, 'parent': heli};
      cmds.add(on(b.shape('tail', 'rect', vs * 0.5, vs * 0.06, -vs * 0.36, 0, fill: '#2A3036')));
      cmds.add(on(b.shape('fin', 'rect', vs * 0.05, vs * 0.2, -vs * 0.6, 0, fill: '#2A3036')));
      cmds.add(on(b.shape('body', 'ellipse', vs * 0.46, vs * 0.24, 0, 0, fill: '#3A4148', fill2: '#1E2328')));
      cmds.add(on(b.shape('glass', 'ellipse', vs * 0.14, vs * 0.15, vs * 0.15, 0, fill: '#8FB3C7')));
      cmds.add(b.fx(b.id('body'), 'shadow', {'distance': vs * 0.35, 'angle': 60, 'blur': 10, 'opacity': 55}));
      cmds.addAll(b.nul('rotor', 0, 0, parent: heli, name: 'Rotor'));
      final rotor = b.id('rotor');
      cmds.add({...b.shape('blade1', 'rect', vs * 1.05, vs * 0.035, 0, 0, fill: '#B3101418'), 'parent': rotor});
      cmds.add({...b.shape('blade2', 'rect', vs * 0.035, vs * 1.05, 0, 0, fill: '#B3101418'), 'parent': rotor});
      cmds.add(b.kf(rotor, 'rotation', b.start, [0, 0, 0], 'linear'));
      cmds.add(b.kf(rotor, 'rotation', b.end, [0, 0, 360 * 3.5 * b.dur]));
    }
    final lab = b.str('label', 'SEARCH BEGINS').toUpperCase();
    if (lab.isNotEmpty) {
      final fs = px(b, 'label_size', 0.035);
      cmds.addAll(label(b, b.id('label'), b.g, lab, -w * 0.5 + w * 0.07 + fs * (lab.length * 0.78 + 1.5) / 2, h * 0.36, fs, b.start + 0.6, b.end,
          animator: 'typewriter', align: 'left'));
    }
    if (b.flag('snow', true)) cmds.addAll(b.atmos('snow', 'snow', amount: 45, speed: 0.8));
    cmds.add({
      'op': 'add_layer', 'type': 'solid', 'id': b.id('vig'), 'name': 'Vignette', 'color': '#00000000', 'width': w, 'height': h,
      'position': [w / 2, h / 2, 0], 'start': b.start, 'duration': b.dur,
    });
    cmds.add(b.fx(b.id('vig'), 'vignette', {'amount': 65, 'size': 55}));
    return cmds;
  }

  // ----------------------------------------------------------- 10. sketch map

  static List<Map<String, dynamic>> sketchMap(_B b0, Project p) {
    final b = b0.c['duration'] == null ? _B(b0.w, b0.h, {...b0.c, 'duration': 7.0}, b0.now, b0.root) : b0;
    final w = b.w, h = b.h;
    final cmds = <Map<String, dynamic>>[
      b.backdrop('backdrop', b.str('bg', '#123236'), color2: '#071619', name: 'Sketch backdrop'),
    ];
    cmds.add(b.fx(b.id('backdrop'), 'vignette', {'amount': 60, 'size': 55}));
    final dirs = b.specs('directions', 'label');
    // Terrain photos revealed per direction (under the parchment).
    for (int i = 0; i < dirs.length; i++) {
      final m = p.media['${dirs[i]['reveal'] ?? ''}'];
      if (m == null || m.type == MediaType.audio) continue;
      final at = b.start + ((dirs[i]['at'] as num?)?.toDouble() ?? (1.6 + i * 1.8));
      final next = i + 1 < dirs.length ? b.start + ((dirs[i + 1]['at'] as num?)?.toDouble() ?? (1.6 + (i + 1) * 1.8)) : b.end;
      final k = math.max(w / math.max(1, m.width), h / math.max(1, m.height)) * 1.04;
      final id = b.id('photo$i');
      cmds.add({
        'op': 'add_layer', 'type': m.type == MediaType.video ? 'video' : 'image', 'media': m.id, 'id': id, 'name': 'Reveal ${dirs[i]['label'] ?? i}',
        'start': at, 'duration': math.max(0.2, next + 0.3 - at), 'fit': 'none', 'position': [w / 2, h / 2, 0], 'scale': [k * 100, k * 100, 100],
      });
      cmds.add(b.kf(id, 'opacity', at, 0, 'ease_out'));
      cmds.add(b.kf(id, 'opacity', at + 0.3, 100));
      cmds.add(b.kf(id, 'scale', at, [k * 100, k * 100, 100], 'linear'));
      cmds.add(b.kf(id, 'scale', next + 0.3, [k * 106, k * 106, 100]));
    }
    // Parchment group (slides in; slides aside when a photo is revealed).
    final pw = w * b.n('paper_width', 0.6), ph = h * 0.74;
    cmds.addAll(b.group('Sketch Map', x: w * 0.42, y: h * 0.52, tilt: -2));
    final paperColor = b.str('paper', 'parchment') == 'white' ? '#F4F1EA' : '#E6D6B3';
    cmds.add(b.shape('paper', 'rect', pw, ph, 0, 0, fill: paperColor, fill2: '#CDB88E'));
    cmds.add(b.fx(b.id('paper'), 'paper', {'amount': 75}));
    cmds.add(b.fx(b.id('paper'), 'torn_edge', {'side': 'right', 'amount': 55}));
    cmds.add(b.fx(b.id('paper'), 'shadow', {'distance': 18, 'blur': 24, 'opacity': 60}));
    cmds.add(b.kf(b.g, 'position', b.start, [-w * 0.4, h * 0.52, 0], 'ease_out'));
    cmds.add(b.kf(b.g, 'position', b.start + 0.6, [w * 0.42, h * 0.52, 0]));
    final firstReveal = dirs.indexWhere((d) => p.media['${d['reveal'] ?? ''}'] != null);
    if (firstReveal >= 0) {
      final at = b.start + ((dirs[firstReveal]['at'] as num?)?.toDouble() ?? (1.6 + firstReveal * 1.8));
      final side = '${dirs[firstReveal]['side'] ?? 'right'}';
      final tx = side == 'left' ? w * 0.78 : w * 0.18;
      cmds.add(b.kf(b.g, 'position', at - 0.05, [w * 0.42, h * 0.52, 0], 'easy_ease'));
      cmds.add(b.kf(b.g, 'position', at + 0.45, [tx, h * 0.55, 0]));
      cmds.add(b.kf(b.g, 'scale', at - 0.05, [100, 100, 100], 'easy_ease'));
      cmds.add(b.kf(b.g, 'scale', at + 0.45, [62, 62, 100]));
    }
    // Ink sketch items with typed labels and red block arrows.
    const ink = '#2B2118';
    var k = 0;
    for (final it in b.specs('items', 'label')) {
      final x = (((it['x'] as num?)?.toDouble() ?? 0.5) - 0.5) * pw, y = (((it['y'] as num?)?.toDouble() ?? 0.5) - 0.5) * ph;
      final t = b.start + ((it['at'] as num?)?.toDouble() ?? (0.7 + k * 0.5));
      final sz = ph * 0.09;
      final pts = _icon('${it['icon'] ?? 'dot'}', x, y, sz);
      final iid = b.id('icon$k');
      cmds.add({
        'op': 'add_layer', 'type': 'shape', 'id': iid, 'parent': b.g, 'start': t, 'duration': math.max(0.1, b.end - t), 'name': 'Sketch ${it['icon'] ?? 'dot'}',
        'rings': pts, 'closed': false, 'fill': 'none', 'stroke': ink, 'stroke_width': math.max(2.0, sz * 0.07),
      });
      cmds.add(b.kf(iid, 'trim', t, [0, 0], 'ease_out'));
      cmds.add(b.kf(iid, 'trim', t + 0.45, [0, 100]));
      final lab = '${it['label'] ?? ''}'.toUpperCase();
      if (lab.isNotEmpty) {
        final fs = ph * 0.045;
        final lw = fs * (lab.length * 0.7 + 1);
        cmds.add({
          ...b.text('label$k', lab, lw, fs * 1.4, x, y + sz * 0.95, fs, color: ink, weight: 400), 'font': 'Special Elite',
          'start': t + 0.3, 'duration': math.max(0.1, b.end - t - 0.3), 'animator': 'typewriter', 'anim_duration': (lab.length * 0.05).clamp(0.3, 1.0),
        });
      }
      final arrow = it['arrow'];
      if (arrow is String && arrow.isNotEmpty) cmds.addAll(_blockArrow(b, 'arrow$k', arrow, x, y, sz * 1.6, t + 0.2, b.g));
      k++;
    }
    // Direction call-outs: red block arrow + typed label at the frame edge.
    for (int i = 0; i < dirs.length; i++) {
      final d = dirs[i];
      final at = b.start + ((d['at'] as num?)?.toDouble() ?? (1.6 + i * 1.8));
      final side = '${d['side'] ?? (i.isEven ? 'right' : 'left')}';
      final (x, y) = switch (side) {
        'left' => (w * 0.12, h * 0.5),
        'up' || 'top' => (w * 0.5, h * 0.14),
        'down' || 'bottom' => (w * 0.5, h * 0.84),
        _ => (w * 0.88, h * 0.5),
      };
      final next = i + 1 < dirs.length ? b.start + ((dirs[i + 1]['at'] as num?)?.toDouble() ?? (1.6 + (i + 1) * 1.8)) : b.end;
      final cb = _B(w, h, {...b.c, 'start': at, 'duration': math.max(0.2, next - at)}, b.now, '${b.root}_dir$i');
      if (d['arrow'] != false) cmds.addAll(_blockArrow(cb, 'arrow', side, x, y, h * 0.12, at, null));
      final lab = '${d['label'] ?? ''}'.toUpperCase();
      if (lab.isNotEmpty) {
        final fs = h * 0.045;
        final ly = side == 'down' || side == 'bottom' ? y - h * 0.11 : y + h * 0.11;
        final half = math.min(fs * (lab.length * 0.39 + 0.75), w / 2);
        cmds.addAll(label(cb, cb.id('label'), null, lab, x.clamp(half, w - half), ly, fs, at + 0.15, next,
            animator: 'typewriter'));
      }
    }
    // Chrome compass: rolls in (−180 → 0), needle settles, re-aims per heading.
    final comp = b.c['compass'] is Map ? Map<String, dynamic>.from(b.c['compass'] as Map) : <String, dynamic>{};
    if (b.c['compass'] != false) {
      final cs = (comp['size'] as num?)?.toDouble() ?? h * 0.24;
      final cx = (comp['x'] as num?)?.toDouble() ?? w * 0.83, cy = (comp['y'] as num?)?.toDouble() ?? h * 0.74;
      final cbz = _B(w, h, {...b.c, 'x': cx, 'y': cy}, b.now, '${b.root}_compass');
      cmds.addAll(cbz.group('Compass', x: cx, y: cy));
      cmds.add(cbz.shape('rim', 'ellipse', cs, cs, 0, 0, fill: '#F2F4F6', fill2: '#6E7378', stroke: '#2A2D30', strokeWidth: cs * 0.012));
      cmds.add(cbz.fx(cbz.id('rim'), 'shadow', {'distance': 14, 'blur': 18, 'opacity': 65}));
      cmds.add(cbz.shape('face', 'ellipse', cs * 0.84, cs * 0.84, 0, 0, fill: '#1B2226', fill2: '#0C1013'));
      cmds.add({...cbz.shape('ticks', 'star', cs * 0.78, cs * 0.78, 0, 0, fill: 'none', stroke: '#8099A6', strokeWidth: cs * 0.006), 'sides': 8, 'inner': 0.22});
      for (final (l, dx, dy) in [('N', 0.0, -0.31), ('E', 0.31, 0.0), ('S', 0.0, 0.31), ('W', -0.31, 0.0)]) {
        cmds.add(cbz.text('t$l', l, cs * 0.14, cs * 0.12, cs * dx, cs * dy, cs * 0.085, color: l == 'N' ? '#E04848' : '#E8EEF2', weight: 800));
      }
      cmds.addAll(cbz.nul('needle', 0, 0, name: 'Needle'));
      final needle = cbz.id('needle');
      cmds.add({
        ...cbz.path('north', [[0, -cs * 0.3], [cs * 0.05, 0], [-cs * 0.05, 0]], stroke: '#7A0E14', width: 1, fill: red, closed: true),
        'parent': needle,
      });
      cmds.add({
        ...cbz.path('south', [[0, cs * 0.3], [cs * 0.05, 0], [-cs * 0.05, 0]], stroke: '#8A9196', width: 1, fill: '#E8EEF2', closed: true),
        'parent': needle,
      });
      cmds.add(cbz.shape('hub', 'ellipse', cs * 0.06, cs * 0.06, 0, 0, fill: '#C9CED2', stroke: '#3A3F44', strokeWidth: cs * 0.008));
      final tIn = b.start + 0.3;
      cmds.add(cbz.kf(cbz.g, 'position', tIn, [w + cs, cy, 0], 'ease_out'));
      cmds.add(cbz.kf(cbz.g, 'position', tIn + 0.8, [cx, cy, 0]));
      cmds.add(cbz.kf(cbz.g, 'rotation', tIn, [0, 0, -180], 'ease_out'));
      cmds.add(cbz.kf(cbz.g, 'rotation', tIn + 0.8, [0, 0, 0]));
      // Headings: [{at, deg}] or one per direction.
      final heads = <(double, double)>[];
      for (final hd in (comp['heading'] as List? ?? const [])) {
        if (hd is Map && hd['deg'] is num) heads.add((b.start + ((hd['at'] as num?)?.toDouble() ?? 1.2), (hd['deg'] as num).toDouble()));
      }
      if (heads.isEmpty) {
        heads.add((tIn + 0.8, 0));
        for (int i = 0; i < dirs.length; i++) {
          final side = '${dirs[i]['side'] ?? (i.isEven ? 'right' : 'left')}';
          final deg = switch (side) { 'left' => -90.0, 'up' || 'top' => 0.0, 'down' || 'bottom' => 180.0, _ => 90.0 };
          heads.add((b.start + ((dirs[i]['at'] as num?)?.toDouble() ?? (1.6 + i * 1.8)), deg));
        }
      }
      var prev = 140.0;
      var last = b.start;
      cmds.add(cbz.kf(needle, 'rotation', b.start, [0, 0, prev], 'hold'));
      for (final (t0, deg) in heads) {
        final t = math.max(t0, last + 0.01);
        cmds.add(cbz.kf(needle, 'rotation', t, [0, 0, prev], 'elastic'));
        cmds.add(cbz.kf(needle, 'rotation', t + 0.9, [0, 0, deg], 'hold'));
        prev = deg;
        last = t + 0.9;
      }
    }
    return cmds;
  }

  /// Ink icon strokes (open polylines, parent px) for sketch_map items.
  static List<List<double>> _icon(String kind, double x, double y, double s) {
    switch (kind) {
      case 'mountain':
      case 'peaks':
        return [
          [x - s, y + s * 0.5, x - s * 0.35, y - s * 0.55, x + s * 0.05, y + s * 0.1, x + s * 0.4, y - s * 0.35, x + s, y + s * 0.5],
        ];
      case 'camp':
      case 'tent':
        return [
          [x - s * 0.6, y + s * 0.45, x, y - s * 0.5, x + s * 0.6, y + s * 0.45, x - s * 0.6, y + s * 0.45],
          [x, y - s * 0.5, x, y + s * 0.45],
        ];
      case 'plane':
      case 'crash':
        return [
          [x - s * 0.7, y, x + s * 0.7, y],
          [x - s * 0.1, y - s * 0.55, x + s * 0.1, y, x - s * 0.1, y + s * 0.55],
          [x - s * 0.6, y - s * 0.22, x - s * 0.6, y + s * 0.22],
        ];
      case 'x':
        return [
          [x - s * 0.4, y - s * 0.4, x + s * 0.4, y + s * 0.4],
          [x + s * 0.4, y - s * 0.4, x - s * 0.4, y + s * 0.4],
        ];
      case 'river':
        return [
          [x - s, y - s * 0.3, x - s * 0.5, y + s * 0.1, x, y - s * 0.15, x + s * 0.5, y + s * 0.2, x + s, y - s * 0.1],
        ];
      default:
        final r = s * 0.18;
        return [
          [for (int i = 0; i <= 12; i++) ...[x + r * math.cos(i * math.pi / 6), y + r * math.sin(i * math.pi / 6)]],
        ];
    }
  }

  /// Red block arrow pointing [dir] (left|right|up|down), popping in.
  static List<Map<String, dynamic>> _blockArrow(_B b, String part, String dir, double x, double y, double len, double t, String? parent) {
    final hw = len * 0.22, head = len * 0.42, hh = len * 0.42;
    // Pointing right, centred on 0,0.
    final base = [
      [-len / 2, -hw / 2], [len / 2 - head, -hw / 2], [len / 2 - head, -hh / 2 - hw / 4], [len / 2, 0.0],
      [len / 2 - head, hh / 2 + hw / 4], [len / 2 - head, hw / 2], [-len / 2, hw / 2],
    ];
    final ang = switch (dir) { 'left' => math.pi, 'up' || 'top' => -math.pi / 2, 'down' || 'bottom' => math.pi / 2, _ => 0.0 };
    final c = math.cos(ang), s = math.sin(ang);
    final pts = [for (final q in base) [x + q[0] * c - q[1] * s, y + q[0] * s + q[1] * c]];
    final id = b.id(part);
    return [
      {
        'op': 'add_layer', 'type': 'shape', 'id': id, 'name': 'Block arrow', 'parent': ?parent, 'start': t, 'duration': math.max(0.1, b.end - t),
        'points': pts, 'closed': true, 'fill': red, 'stroke': '#7A0E14', 'stroke_width': 2,
      },
      b.fx(id, 'shadow', {'distance': 6, 'blur': 8, 'opacity': 50}),
      b.kf(id, 'scale', t, [0, 0, 100], 'back'),
      b.kf(id, 'scale', t + 0.3, [100, 100, 100]),
    ];
  }
}
// <<< V3-A
