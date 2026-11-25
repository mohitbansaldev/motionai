part of 'components.dart';

// ===== scene kit (Agent D) =====
// Maps: needle_pin, avatar_pin, map_fly, route_follow, plus the 'road' map
// style and `clouds: true` on map components. 3D: room, board.

const _sceneTypes = ['room', 'board', 'needle_pin', 'avatar_pin', 'map_fly', 'route_follow'];

const _sceneLabels = {
  'room': '3D Room',
  'board': 'Curved Board',
  'needle_pin': 'Needle Pin',
  'avatar_pin': 'Avatar Pin',
  'map_fly': 'Map Fly A→B',
  'route_follow': 'Route Follow',
};

/// Commands for the scene-kit components (null = not one of them).
List<Map<String, dynamic>>? _sceneBuild(Project p, Map<String, dynamic> c, _B b) {
  switch ('${c['type']}') {
    case 'map':
      final style = b.str('style', 'dark');
      if (style != 'road' && c['clouds'] != true) return null;
      return _MapKit.map(b, style: style, clouds: c['clouds'] == true);
    case 'needle_pin':
      return _MapKit.needlePin(b, p);
    case 'avatar_pin':
      return _MapKit.avatarPin(b, p);
    case 'map_fly':
      return _MapKit.mapFly(b, p);
    case 'route_follow':
      return _MapKit.routeFollow(b, p);
    case 'room':
      return _SceneKit.room(b, p);
    case 'board':
      return _SceneKit.board(b, p);
  }
  return null;
}

typedef _Place = ({List<double> pt, Country? country});

class _MapKit {
  static const _fill = '#C9A227', _fill2 = '#E53935';

  /// The "map" component with the extra 'road' style and drifting clouds.
  static List<Map<String, dynamic>> map(_B b, {required String style, bool clouds = false}) {
    final road = style == 'road';
    final base = _B(b.w, b.h, {...b.c, 'style': road ? 'paper' : style}, b.now, b.root);
    final cmds = Components._map(base);
    if (road) {
      final ocean = '${b.root}_ocean', world = '${b.root}_world';
      var at = cmds.length;
      for (int i = 0; i < cmds.length; i++) {
        final cmd = cmds[i];
        if (cmd['id'] == ocean && cmd['op'] == 'add_layer') cmd['color'] = '#A8D4E6';
        if (cmd['id'] == world && cmd['op'] == 'add_layer') {
          cmd['fill'] = '#F3EAD3';
          cmd['stroke'] = '#CDB991';
          at = i + 1;
        }
      }
      cmds.insert(at, {
        'op': 'add_layer', 'type': 'shape', 'id': '${b.root}_roads', 'name': 'Roads', 'parent': '${b.root}_g',
        'start': b.start, 'duration': b.dur, 'rings': roads(), 'closed': false, 'fill': 'none', 'stroke': '#E8A93A', 'stroke_width': 1.4,
      });
      cmds.add(b.fx(ocean, 'paper', {'amount': 45}));
    }
    if (clouds) cmds.addAll(_clouds(base));
    return cmds;
  }

  static List<Map<String, dynamic>> _clouds(_B b) => b.atmos('clouds', 'clouds', amount: 35, speed: 0.35, opacity: 85);

  static List<List<double>>? _roads;

  /// Decorative road network: each country's label point joined to its two
  /// nearest neighbours (map px).
  static List<List<double>> roads() {
    final cached = _roads;
    if (cached != null && cached.isNotEmpty) return cached;
    final pts = [for (final c in WorldMap.countries) WorldMap.project(c.labelLon, c.labelLat)];
    final out = <List<double>>[];
    final seen = <String>{};
    for (int i = 0; i < pts.length; i++) {
      final near = <(double, int)>[];
      for (int j = 0; j < pts.length; j++) {
        if (i == j) continue;
        final dx = pts[i][0] - pts[j][0], dy = pts[i][1] - pts[j][1];
        final d = dx * dx + dy * dy;
        if (d < 200 * 200) near.add((d, j));
      }
      near.sort((a, b) => a.$1.compareTo(b.$1));
      for (final n in near.take(2)) {
        final key = i < n.$2 ? '$i-${n.$2}' : '${n.$2}-$i';
        if (!seen.add(key)) continue;
        out.add([pts[i][0], pts[i][1], pts[n.$2][0], pts[n.$2][1]]);
      }
    }
    if (out.isEmpty) out.add([0, 0, 1, 1]);
    return _roads = out;
  }

  /// A place from a country name/code, [lat, lon], {lat, lon} or {country}.
  static _Place placeOf(dynamic v, String def) {
    if (v is List && v.length >= 2 && v[0] is num && v[1] is num) {
      return (pt: WorldMap.project((v[1] as num).toDouble(), (v[0] as num).toDouble()), country: null);
    }
    if (v is Map && v['lat'] is num && v['lon'] is num) {
      return (pt: WorldMap.project((v['lon'] as num).toDouble(), (v['lat'] as num).toDouble()), country: null);
    }
    final name = v == null ? def : (v is Map ? '${v['country'] ?? v['name'] ?? def}' : '$v');
    final ct = WorldMap.find(name);
    if (ct == null) throw ArgumentError('Unknown country "$name"');
    return (pt: WorldMap.project(ct.labelLon, ct.labelLat), country: ct);
  }

  /// `country` or `lon` + `lat` of a pin.
  static _Place pinPlace(_B b) {
    final lon = b.c['lon'], lat = b.c['lat'];
    if (lon is num && lat is num) return (pt: WorldMap.project(lon.toDouble(), lat.toDouble()), country: null);
    return placeOf(b.c['country'], 'India');
  }

  /// The map to draw on: the "map" param (validated) or, if [auto], the
  /// newest map component visible at the start.
  static String? findMap(Composition comp, _B b, {bool auto = true}) {
    final m = b.c['map'];
    if (m is String && m.isNotEmpty) {
      if (comp.layerById('${m}_g') == null || comp.layerById('${m}_world') == null) {
        throw ArgumentError('"map" must be the id of a map component (there is no "${m}_world")');
      }
      return m;
    }
    if (!auto) return null;
    for (final l in comp.layers) {
      if (l.type == LayerType.shape && l.id.endsWith('_world') && l.isActiveAt(b.start)) {
        final root = l.id.substring(0, l.id.length - '_world'.length);
        if (comp.layerById('${root}_g') != null) return root;
      }
    }
    return null;
  }

  static List<Map<String, dynamic>> newMap(_B b, String root,
      {List<String> countries = const [], String? focus, required String style, bool clouds = false, bool zoom = true}) {
    if (!WorldMap.loaded) throw ArgumentError('World map data is not loaded');
    final mb = _B(b.w, b.h, {
      'type': 'map', 'id': root, 'start': b.start, 'duration': b.dur, 'countries': countries, 'style': style,
      'focus': ?focus, 'zoom_time': 1.4, 'zoom_delay': 0.2, if (!zoom) 'zoom': false,
    }, b.now, root);
    return map(mb, style: style, clouds: clouds);
  }

  /// [x, y, scale%] for the map group that frames [bb] (map px).
  static List<double> frame(_B b, List<double> bb, double fill) {
    final cw = math.max(bb[2] - bb[0], 10.0), ch = math.max(bb[3] - bb[1], 10.0);
    final s = math.min(b.w * fill / cw, b.h * fill / ch);
    return [b.w / 2 - s * (bb[0] + bb[2]) / 2, b.h / 2 - s * (bb[1] + bb[3]) / 2, s * 100];
  }

  static List<double> _bbox(_Place pl) {
    final c = pl.country;
    if (c != null) return WorldMap.bbox(c);
    return [pl.pt[0] - 60, pl.pt[1] - 40, pl.pt[0] + 60, pl.pt[1] + 40];
  }

  /// Pin group on the map (keeps its screen size while the map zooms).
  static List<Map<String, dynamic>> _pinGroup(_B b, String map, List<double> pt, String name) => [
        {
          'op': 'add_layer', 'type': 'null', 'id': b.g, 'name': name, 'parent': '${map}_g', 'start': b.start, 'duration': b.dur,
          'position': [pt[0], pt[1], 0],
        },
        b.setp(b.g, 'anchor', [0, 0, 0]),
        {'op': 'scene_counter_scale', 'layer': b.g, 'of': '${map}_g', 'start': b.start, 'end': b.end},
      ];

  /// Resolves (or creates) the map for a pin; returns (map id, commands, delay before the pin lands).
  static (String, List<Map<String, dynamic>>, double) _pinMap(_B b, Project p, _Place place) {
    final existing = findMap(p.editComp, b);
    if (existing != null) return (existing, <Map<String, dynamic>>[], b.n('delay', 0.2));
    final root = '${b.root}_map';
    final name = place.country?.name;
    return (
      root,
      newMap(b, root, countries: [?name], focus: name, style: b.str('style', 'road'), clouds: b.flag('clouds', false)),
      b.n('delay', 1.6),
    );
  }

  /// Needle pin: long stick + glossy head dropping in with a bounce.
  static List<Map<String, dynamic>> needlePin(_B b, Project p) {
    final place = pinPlace(b);
    final (map, cmds, delay) = _pinMap(b, p, place);
    cmds.addAll(_pinGroup(b, map, place.pt, 'Needle Pin'));
    final t0 = math.min(b.start + delay, b.end - 0.2);
    final du = b.end - t0;
    final h = b.h;
    final stick = b.n('stick', h * 0.11), r = b.n('size', h * 0.018);
    final color = b.str('color', '#E53935');
    final drop = b.id('drop');
    cmds.add({...b.shape('shadow', 'ellipse', r * 2.6, r * 0.8, 0, 0, fill: '#66000000'), 'start': t0, 'duration': du});
    cmds.add(b.kf(b.id('shadow'), 'scale', t0, [20, 20, 100], 'ease_out'));
    cmds.add(b.kf(b.id('shadow'), 'scale', t0 + 0.6, [100, 100, 100]));
    cmds.addAll(b.nul('drop', 0, 0, st: t0, du: du, name: 'Needle'));
    cmds.add(b.kf(drop, 'position', t0, [0, -h * 0.45, 0], 'bounce'));
    cmds.add(b.kf(drop, 'position', t0 + 0.75, [0, 0, 0]));
    cmds.add(b.path('stick', [
      [0, 0],
      [0, -stick],
    ], stroke: '#DADADA', width: math.max(2.0, r * 0.28), parent: drop, st: t0, du: du));
    cmds.add({...b.shape('head', 'ellipse', r * 2, r * 2, 0, -stick, fill: color, stroke: '#FFFFFF', strokeWidth: r * 0.18), 'parent': drop, 'start': t0, 'duration': du});
    cmds.add({...b.shape('shine', 'ellipse', r * 0.6, r * 0.6, -r * 0.35, -stick - r * 0.35, fill: '#B3FFFFFF'), 'parent': drop, 'start': t0, 'duration': du});
    final label = b.str('label', place.country?.name ?? '');
    if (label.isNotEmpty) {
      final fs = b.n('label_size', h * 0.026);
      final pw = label.length * fs * 0.62 + fs * 1.4;
      final y = -stick - r - fs * 1.3;
      cmds.add({...b.shape('tag', 'rect', pw, fs * 1.8, 0, y, fill: '#FFFFFF', corner: fs * 0.3), 'parent': drop, 'start': t0, 'duration': du});
      cmds.add({...b.text('label', label, pw, fs * 1.8, 0, y, fs, color: '#111111', weight: 800), 'parent': drop, 'start': t0, 'duration': du});
    }
    final pulse = b.id('pulse');
    cmds.add({...b.shape('pulse', 'ellipse', r * 2, r * 2, 0, 0, fill: 'none', stroke: color, strokeWidth: r * 0.25), 'start': t0, 'duration': du});
    cmds.add(b.kf(pulse, 'opacity', t0 + 0.55, 0, 'hold'));
    cmds.add(b.kf(pulse, 'opacity', t0 + 0.6, 100, 'linear'));
    cmds.add(b.kf(pulse, 'opacity', t0 + 1.5, 0));
    cmds.add(b.kf(pulse, 'scale', t0 + 0.6, [100, 100, 100], 'ease_out'));
    cmds.add(b.kf(pulse, 'scale', t0 + 1.5, [420, 420, 100]));
    return cmds;
  }

  /// Round face photo in a ring with a pointer, as children of [parent].
  static List<Map<String, dynamic>> _avatarBody(_B b, Project p, String parent, double r, double st, double du, {String label = ''}) {
    final cmds = <Map<String, dynamic>>[];
    final ring = b.str('color', '#FFFFFF');
    final cy = -r * 1.55;
    Map<String, dynamic> on(Map<String, dynamic> c) => {...c, 'parent': parent, 'start': st, 'duration': du};
    cmds.add(on(b.path('point', [
      [-r * 0.42, cy + r * 0.8],
      [r * 0.42, cy + r * 0.8],
      [0, 0],
    ], stroke: ring, width: 1, fill: ring, closed: true)));
    cmds.add(on(b.shape('ring', 'ellipse', r * 2.2, r * 2.2, 0, cy, fill: ring)));
    final m = b.mediaOf(p, 'media') ?? b.mediaOf(p, 'avatar');
    if (m != null) {
      final s = (r * 2) / math.max(1, math.min(m.width, m.height)) * 100;
      cmds.add(on(b.media('face', m, 0, cy, widthPx: m.width * s / 100)));
      cmds.add({'op': 'add_mask', 'layer': b.id('face'), 'shape': 'ellipse', 'center': [m.width / 2, m.height / 2], 'size': [r * 2 / s * 100, r * 2 / s * 100], 'feather': 0});
    } else {
      cmds.add(on(b.shape('face', 'ellipse', r * 2, r * 2, 0, cy, fill: '#546E7A', fill2: '#263238')));
      final initial = label.isEmpty ? '?' : label.substring(0, 1).toUpperCase();
      cmds.add(on(b.text('initial', initial, r * 2, r * 2, 0, cy, r * 1.1, color: '#FFFFFF', weight: 900)));
    }
    if (label.isNotEmpty) {
      final fs = r * 0.5;
      final pw = label.length * fs * 0.62 + fs * 1.4;
      cmds.add(on(b.shape('pill', 'rect', pw, fs * 1.7, 0, cy - r * 1.1 - fs, fill: '#161616', stroke: ring, strokeWidth: 2, corner: fs * 0.85)));
      cmds.add(on(b.text('name', label, pw, fs * 1.7, 0, cy - r * 1.1 - fs, fs, color: '#FFFFFF', weight: 800)));
    }
    return cmds;
  }

  /// Avatar pin: round face photo pinned to a place on the map, pops in.
  static List<Map<String, dynamic>> avatarPin(_B b, Project p) {
    final place = pinPlace(b);
    final (map, cmds, delay) = _pinMap(b, p, place);
    cmds.addAll(_pinGroup(b, map, place.pt, 'Avatar Pin'));
    final t0 = math.min(b.start + delay, b.end - 0.2);
    final du = b.end - t0;
    final r = b.f('size', b.h * 0.055, b.h);
    cmds.addAll(b.nul('body', 0, 0, st: t0, du: du, name: 'Avatar'));
    cmds.addAll(_avatarBody(b, p, b.id('body'), r, t0, du, label: b.str('label', '')));
    cmds.add({'op': 'animate_in', 'layer': b.id('body'), 'preset': 'pop', 'duration': 0.5});
    return cmds;
  }

  static String _color(_B b, int i, String def) {
    final v = b.c['colors'];
    if (v is List && v.length > i) return '${v[i]}';
    if (v is Map) {
      final k = i == 0 ? 'from' : 'to';
      if (v[k] != null) return '${v[k]}';
    }
    if (v is String && i == 0) return v;
    return def;
  }

  /// Highlight of [pl]'s country on [map] (skipped if the map already has one).
  static List<Map<String, dynamic>> _highlight(_B b, Project p, String map, _Place pl, String part, String color, double st) {
    final c = pl.country;
    if (c == null) return const [];
    final g = '${map}_g';
    if (p.editComp.layers.any((l) => l.parentId == g && l.name == c.name)) return const [];
    final id = b.id(part);
    final du = math.max(0.2, b.end - st);
    final bb = WorldMap.bbox(c);
    final lp = WorldMap.project(c.labelLon, c.labelLat);
    final fs = math.max(8.0, math.min(60.0, (bb[2] - bb[0]) * 0.12));
    return [
      {
        'op': 'add_layer', 'type': 'shape', 'id': id, 'name': c.name, 'parent': g, 'start': st, 'duration': du,
        'rings': WorldMap.projectRings(c), 'closed': true, 'fill': color, 'stroke': '#FFFFFF', 'stroke_width': 2.5,
      },
      {'op': 'animate_in', 'layer': id, 'preset': 'fade', 'duration': 0.5},
      {
        'op': 'add_layer', 'type': 'text', 'id': '${id}_label', 'parent': g, 'start': st + 0.2, 'duration': math.max(0.2, du - 0.2),
        'text': c.name.toUpperCase(), 'font_size': fs, 'font_weight': 900, 'width': fs * 12, 'height': fs * 1.6,
        'position': [lp[0], lp[1], 0], 'shadow': true, 'animator': 'fade_up', 'anim_duration': 0.5,
      },
    ];
  }

  /// Map fly: the map pans/zooms from country A out to both, then in to B.
  static List<Map<String, dynamic>> mapFly(_B b, Project p) {
    final from = placeOf(b.c['from'], 'India'), to = placeOf(b.c['to'], 'United States of America');
    final cmds = <Map<String, dynamic>>[];
    var map = findMap(p.editComp, b, auto: false);
    if (map == null) {
      map = '${b.root}_map';
      cmds.addAll(newMap(b, map, style: b.str('style', 'dark'), clouds: b.flag('clouds', false), zoom: false));
    }
    final g = '${map}_g';
    final tA = b.start + math.min(0.4, b.dur * 0.1), tB = b.end - math.min(0.8, b.dur * 0.15);
    cmds.addAll(_highlight(b, p, map, from, 'hl_from', _color(b, 0, _fill), b.start));
    cmds.addAll(_highlight(b, p, map, to, 'hl_to', _color(b, 1, _fill2), b.start + (tB - b.start) * 0.6));
    final fa = frame(b, _bbox(from), 0.5), fz = frame(b, _bbox(to), 0.5);
    final ba = _bbox(from), bz = _bbox(to);
    final fu = frame(b, [math.min(ba[0], bz[0]), math.min(ba[1], bz[1]), math.max(ba[2], bz[2]), math.max(ba[3], bz[3])], 0.8);
    List<double> centre(List<double> bb) => [(bb[0] + bb[2]) / 2, (bb[1] + bb[3]) / 2];
    final ca = centre(ba), cz = centre(bz);
    final la = math.log(fa[2] / 100), lz = math.log(fz[2] / 100), lu = math.log(fu[2] / 100);
    final bump = math.max(0.0, (la + lz) / 2 - lu);
    const n = 10;
    for (int i = 0; i <= n; i++) {
      final u = i / n;
      final e = Easing.easyEase.transform(u);
      final s = math.exp(la + (lz - la) * e - bump * math.sin(math.pi * e));
      final mx = ca[0] + (cz[0] - ca[0]) * e, my = ca[1] + (cz[1] - ca[1]) * e;
      final t = tA + (tB - tA) * u;
      cmds.add(b.kf(g, 'position', t, [b.w / 2 - s * mx, b.h / 2 - s * my, 0], 'linear'));
      cmds.add(b.kf(g, 'scale', t, [s * 100, s * 100, 100], 'linear'));
    }
    return cmds;
  }

  /// Route follow: the route line draws, the map follows its tip (motion
  /// blur on) and an avatar pin travels along it.
  static List<Map<String, dynamic>> routeFollow(_B b, Project p) {
    final from = placeOf(b.c['from'], 'India'), to = placeOf(b.c['to'], 'United Kingdom');
    final cmds = <Map<String, dynamic>>[];
    var map = findMap(p.editComp, b, auto: false);
    final created = map == null;
    if (map == null) {
      map = '${b.root}_map';
      cmds.addAll(newMap(b, map, style: b.str('style', 'road'), zoom: false));
    }
    final g = '${map}_g';
    final a = from.pt, z = to.pt;
    final len = math.max(1.0, math.sqrt(math.pow(z[0] - a[0], 2) + math.pow(z[1] - a[1], 2)));
    final up = MotionPath.arc(a, z, len * 0.2), down = MotionPath.arc(a, z, -len * 0.2);
    final path = up.points.length > 1 && up.points[1][1] <= down.points[1][1] ? up : down;
    final pts = [for (final q in path.points) [q[0], q[1]]];
    final fit = math.max(b.w / WorldMap.width, b.h / WorldMap.height);
    final s = (b.w * 1.1 / len).clamp(fit, 14.0);
    final tA = b.start + math.min(0.5, b.dur * 0.1), tB = b.end - math.min(0.7, b.dur * 0.12);
    final color = b.str('color', '#E53935');
    final px = 1 / s; // one screen pixel in map px
    cmds.add(b.path('casing', pts, stroke: '#FFFFFF', width: 11 * px, smooth: true, parent: g));
    cmds.add(b.path('line', pts, stroke: color, width: 6 * px, smooth: true, parent: g));
    cmds.add(b.shape('a', 'ellipse', 16 * px, 16 * px, a[0], a[1], fill: color, stroke: '#FFFFFF', strokeWidth: 3 * px)..['parent'] = g);
    cmds.add({...b.shape('z', 'ellipse', 16 * px, 16 * px, z[0], z[1], fill: color, stroke: '#FFFFFF', strokeWidth: 3 * px), 'parent': g, 'start': tB, 'duration': math.max(0.2, b.end - tB)});
    cmds.add({'op': 'animate_in', 'layer': b.id('z'), 'preset': 'pop', 'duration': 0.4});
    for (final (part, pl, st) in [('from_name', from, b.start), ('to_name', to, tB)]) {
      final name = pl.country?.name ?? '';
      if (name.isEmpty) continue;
      final fs = 30 * px;
      cmds.add({
        ...b.text(part, name.toUpperCase(), fs * 14, fs * 1.6, pl.pt[0], pl.pt[1] + 34 * px, fs, color: '#1A1A1A', weight: 900),
        'parent': g, 'start': st, 'duration': math.max(0.2, b.end - st), 'shadow': false,
      });
    }
    final avatarMedia = b.mediaOf(p, 'avatar') ?? b.mediaOf(p, 'media');
    final av = b.id('av');
    cmds.add({
      'op': 'add_layer', 'type': 'null', 'id': av, 'name': 'Traveller', 'parent': g, 'start': b.start, 'duration': b.dur,
      'path': {'points': pts, 'smooth': true}, 'position': [0, 0, 0], 'scale': [100 / s, 100 / s, 100],
    });
    cmds.add(b.setp(av, 'anchor', [0, 0, 0]));
    if (avatarMedia != null) {
      cmds.addAll(_avatarBody(b, p, av, b.h * 0.045, b.start, b.dur));
    } else {
      cmds.add({...b.shape('tip', 'ellipse', b.h * 0.024, b.h * 0.024, 0, 0, fill: '#FFFFFF', stroke: color, strokeWidth: b.h * 0.006), 'parent': av});
      cmds.add(b.fx(b.id('tip'), 'glow', {'amount': 60, 'radius': 14}));
    }
    const n = 12;
    for (int i = 0; i <= n; i++) {
      final u = i / n;
      final e = Easing.easyEase.transform(u);
      final t = tA + (tB - tA) * u;
      final tip = path.sample(math.min(1.0, e + 0.02));
      cmds.add(b.kf(b.id('line'), 'trim', t, [0, e * 100], 'linear'));
      cmds.add(b.kf(b.id('casing'), 'trim', t, [0, e * 100], 'linear'));
      cmds.add(b.kf(av, 'path_progress', t, e * 100, 'linear'));
      cmds.add(b.kf(g, 'position', t, [b.w / 2 - s * tip.x, b.h / 2 - s * tip.y, 0], 'linear'));
      cmds.add(b.kf(g, 'scale', t, [s * 100, s * 100, 100], 'linear'));
    }
    cmds.add({'op': 'set_comp', 'motion_blur': true});
    if (b.flag('clouds', created)) cmds.addAll(_clouds(b));
    return cmds;
  }
}

class _SceneKit {
  static String _shade(String hex, double k) {
    var s = hex.replaceFirst('#', '');
    if (s.length == 6) s = 'FF$s';
    final v = int.tryParse(s, radix: 16) ?? 0xFF8A6A4F;
    int ch(int shift) => ((((v >> shift) & 0xFF) * k).round()).clamp(0, 255);
    final out = (0xFF << 24) | (ch(16) << 16) | (ch(8) << 8) | ch(0);
    return '#${out.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
  }

  /// 3D room / set (win-30): back wall, left + right walls, floor, optional
  /// ceiling as real 3D planes (each from its own media), people / props
  /// standing ON the floor at their depth (feet on the floor line, contact
  /// shadow, size by real height), and foreground objects close to the
  /// camera. Camera moves then give true parallax. Keys:
  ///   back|wall, left, right, floor, ceiling: media ids (else tinted planes)
  ///   items: [media id | {media, x (0..1 across the floor, or comp px > 2),
  ///          z (0 front..1 back), height (px at the front; default 62% of
  ///          the frame height for people), role: person|prop, shadow: bool}]
  ///   foreground: [{media, x (0..1), z (-0.6..0: in front of the room),
  ///          height, y (0 top..1 bottom of frame)}]
  ///   width, depth, height (px), color, floor_color, shadows (default true)
  static List<Map<String, dynamic>> room(_B b, Project p) {
    final w = b.w, h = b.h, cx = w / 2;
    final z0 = w * 1.38889; // home camera distance (defaultZoomFor)
    final rw = b.n('width', w * 1.2), rd = b.n('depth', z0 * 1.15), rh = b.n('height', h * 1.3);
    final zBack = z0 * 0.6, zFront = zBack - rd, zMid = (zBack + zFront) / 2;
    final floorY = b.n('floor_y', h / 2 + 0.22 * h * (zBack + z0) / z0);
    final color = b.str('color', '#8A6A4F');
    final floorColor = b.str('floor_color', _shade(color, 0.62));
    final shadows = b.c['shadows'] != false;
    final cmds = <Map<String, dynamic>>[
      {'op': 'set_camera_mode', 'mode': '3d'},
      {'op': 'add_layer', 'type': 'null', 'id': b.g, 'name': 'Room', 'start': b.start, 'duration': b.dur, 'is3d': true, 'position': [0, 0, 0]},
      b.setp(b.g, 'anchor', [0, 0, 0]),
    ];
    void plane(String part, String mediaKey, double pw, double ph, List<double> pos, List<double> rot, String fill, String fill2,
        {String? altKey}) {
      final m = b.mediaOf(p, mediaKey) ?? (altKey == null ? null : b.mediaOf(p, altKey));
      final id = b.id(part);
      if (m != null) {
        // win-30: cover the plane without stretching (a 16:9 wall photo on a
        // tall wall was squashed); a rect mask trims it to the plane.
        final mw = math.max(1, m.width), mh = math.max(1, m.height);
        final s = math.max(pw / mw, ph / mh);
        cmds.add({
          'op': 'add_layer', 'type': m.type == MediaType.video ? 'video' : 'image', 'media': m.id, 'id': id, 'name': 'Room $part',
          'parent': b.g, 'start': b.start, 'duration': b.dur, 'fit': 'none', 'is3d': true,
          'position': pos, 'scale': [s * 100, s * 100, 100],
        });
        if ((pw / mw - ph / mh).abs() > 1e-6 * s) {
          cmds.add({'op': 'add_mask', 'layer': id, 'shape': 'rect', 'center': [mw / 2, mh / 2], 'size': [pw / s, ph / s], 'feather': 0});
        }
      } else {
        cmds.add({
          'op': 'add_layer', 'type': 'shape', 'id': id, 'name': 'Room $part', 'parent': b.g, 'start': b.start, 'duration': b.dur,
          'kind': 'rect', 'width': pw, 'height': ph, 'position': pos, 'fill': fill, 'fill2': fill2, 'is3d': true,
        });
      }
      if (rot.any((v) => v != 0)) cmds.add(b.setp(id, 'rotation', rot));
    }

    plane('back', 'back', rw, rh, [cx, floorY - rh / 2, zBack], [0, 0.01, 0], color, _shade(color, 0.8), altKey: 'wall');
    plane('floor', 'floor', rw, rd, [cx, floorY, zMid], [-90, 0, 0], floorColor, _shade(floorColor, 0.6));
    plane('left', 'left', rd, rh, [cx - rw / 2, floorY - rh / 2, zMid], [0, 90, 0], _shade(color, 0.72), _shade(color, 0.5), altKey: 'wall');
    plane('right', 'right', rd, rh, [cx + rw / 2, floorY - rh / 2, zMid], [0, -90, 0], _shade(color, 0.72), _shade(color, 0.5), altKey: 'wall');
    if (b.c['ceiling'] != null) {
      plane('ceiling', 'ceiling', rw, rd, [cx, floorY - rh, zMid], [90, 0, 0], _shade(color, 0.4), _shade(color, 0.3));
    }
    // A flat (invisible) separator: things added above it are always drawn
    // in front of the walls and floor (3D layers sort only between flat ones).
    cmds.add({
      'op': 'add_layer', 'type': 'solid', 'id': b.id('sep'), 'name': 'Room front', 'color': '#00000000', 'width': 2, 'height': 2,
      'start': b.start, 'duration': b.dur, 'position': [0, 0, 0],
    });
    // Cut-outs standing on the floor, back to front (people and props).
    final specs = b.specs('items', 'media');
    final items = <(MediaAsset, Map<String, dynamic>)>[
      for (final it in specs)
        if (p.media['${it['media']}'] != null && p.media['${it['media']}']!.type != MediaType.audio) (p.media['${it['media']}']!, it),
    ];
    for (int i = 0; i < items.length; i++) {
      final (m, it) = items[i];
      final person = '${it['role'] ?? 'person'}' == 'person';
      final ih = (it['height'] as num?)?.toDouble() ?? (person ? h * 0.62 : h * 0.3);
      final s = ih / math.max(1, m.height) * 100;
      final zf = ((it['z'] as num?)?.toDouble() ?? 0.55).clamp(0.0, 1.0);
      final z = zFront + rd * zf;
      final depthK = (z + z0) / z0;
      final sx = (it['x'] as num?)?.toDouble();
      final double x;
      if (sx == null) {
        x = cx + (i + 1 - (items.length + 1) / 2) * rw / (items.length + 1);
      } else if (sx <= 2) {
        x = cx + (sx - 0.5) * rw * 0.9; // fraction across the floor
      } else {
        x = cx + (sx - cx) * depthK; // comp px at the front plane
      }
      final id = b.id('item$i');
      cmds.add({
        'op': 'add_layer', 'type': m.type == MediaType.video ? 'video' : 'image', 'media': m.id, 'id': id, 'name': m.name,
        'parent': b.g, 'start': b.start, 'duration': b.dur, 'fit': 'none', 'is3d': true,
        // Feet exactly on the floor plane at this depth (anchor = centre).
        'position': [x, floorY - ih / 2, z], 'scale': [s, s, 100],
      });
      cmds.add(b.setp(id, 'rotation', [0, 0.01, 0]));
      if (shadows && it['shadow'] != false) {
        cmds.add({'op': 'add_effect', 'layer': id, 'effect': 'contact_shadow', 'params': {'opacity': 60, 'softness': 45, 'angle': 90}});
      }
    }
    // Foreground objects between the camera and the room (depth cue + natural wipes).
    final fg = b.specs('foreground', 'media');
    for (int i = 0; i < fg.length; i++) {
      final it = fg[i];
      final m = p.media['${it['media']}'];
      if (m == null || m.type == MediaType.audio) continue;
      final zf = ((it['z'] as num?)?.toDouble() ?? -0.35).clamp(-0.9, 0.0);
      final z = zFront + zf * z0; // in front of the room
      final k = (z + z0) / z0;
      final ih = ((it['height'] as num?)?.toDouble() ?? h * 0.9) * k;
      final s = ih / math.max(1, m.height) * 100;
      final fx = ((it['x'] as num?)?.toDouble() ?? (i.isEven ? 0.08 : 0.92));
      final fy = ((it['y'] as num?)?.toDouble() ?? 1.0);
      final id = b.id('fg$i');
      cmds.add({
        'op': 'add_layer', 'type': 'image', 'media': m.id, 'id': id, 'name': 'FG ${m.name}', 'parent': b.g,
        'start': b.start, 'duration': b.dur, 'fit': 'none', 'is3d': true,
        'position': [cx + (fx * w - cx) * k, h / 2 + (fy * h - h / 2) * k - ih / 2 * (fy >= 0.99 ? 1 : 0), z], 'scale': [s, s, 100],
      });
      cmds.add(b.setp(id, 'rotation', [0, 0.01, 0]));
    }
    return cmds;
  }

  /// Curved board (wood or glass) with a picture that pops out with overshoot.
  static List<Map<String, dynamic>> board(_B b, Project p) {
    final m = b.mediaOf(p, 'media');
    final bw = b.f('width', b.w * 0.46, b.w);
    final inset = bw * 0.07;
    final pw = bw - inset * 2;
    final ph = m == null ? pw * 0.62 : pw * m.height / math.max(1, m.width);
    final title = b.str('title', '');
    final titleH = title.isEmpty ? 0.0 : bw * 0.13;
    final bh = ph + inset * 2 + titleH;
    final bend = b.n('curve', b.n('bend', 35)).clamp(0.0, 100.0);
    final glass = b.str('frame', 'wood') == 'glass';
    final cmds = b.group('Board', tilt: b.n('tilt', 0));
    final panel = b.id('panel'), pic = b.id('pic');
    cmds.add(b.shape('panel', 'rect', bw, bh, 0, 0,
        fill: glass ? '#40FFFFFF' : '#8B5A2B', fill2: glass ? '#14FFFFFF' : '#4A2C14', corner: bw * 0.02));
    if (glass) {
      cmds.add(b.fx(panel, 'glass_frame', {'thickness': 22, 'gloss': 75}));
    } else {
      cmds.add(b.fx(panel, 'grunge', {'amount': 35}));
      cmds.add(b.fx(panel, 'shadow', {'distance': 22, 'blur': 26, 'opacity': 60}));
    }
    cmds.add(b.fx(panel, 'curve', {'bend': bend}, '${panel}_curve'));
    final double s;
    if (m != null) {
      s = pw / math.max(1, m.width) * 100;
      cmds.add(b.media('pic', m, 0, -titleH / 2, widthPx: pw));
    } else {
      s = 100;
      cmds.add(b.shape('pic', 'rect', pw, ph, 0, -titleH / 2, fill: '#D8CBB0', fill2: '#A8987A'));
    }
    cmds.add(b.fx(pic, 'curve', {'bend': bend}, '${pic}_curve'));
    if (title.isNotEmpty) {
      final ty = bh / 2 - inset * 0.6 - titleH / 2;
      cmds.add(b.text('title', title, pw, titleH, 0, ty, titleH * 0.62, color: glass ? '#FFFFFF' : '#F6D98A', weight: 900));
      cmds.add(b.fx(b.id('title'), 'curve', {'bend': bend}, '${b.id('title')}_curve'));
    }
    if (b.flag('pop', true)) {
      final t1 = b.start + b.n('pop_at', 0.9);
      cmds.add(b.fx(pic, 'shadow', {'distance': 30, 'blur': 30, 'opacity': 65}));
      cmds.add(b.kf(pic, 'scale', t1, [s, s, 100], 'back'));
      cmds.add(b.kf(pic, 'scale', t1 + 0.55, [s * 1.18, s * 1.18, 100]));
      cmds.add(b.kf(pic, 'rotation', t1, [0, 0, 0], 'back'));
      cmds.add(b.kf(pic, 'rotation', t1 + 0.55, [0, 0, -3]));
      cmds.add({'op': 'set_keyframe', 'target': pic, 'effect': '${pic}_curve', 'prop': 'bend', 'time': t1, 'value': bend, 'ease': 'easy_ease'});
      cmds.add({'op': 'set_keyframe', 'target': pic, 'effect': '${pic}_curve', 'prop': 'bend', 'time': t1 + 0.45, 'value': 0});
    }
    return b.finish(cmds, enter: 'pop');
  }
}
// ===== end scene kit =====
