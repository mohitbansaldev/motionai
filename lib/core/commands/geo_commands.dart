import 'dart:math' as math;

import '../geo/geo_projection.dart';
import '../geo/geo_spec.dart';
import '../geo/geo_styles.dart';
import '../model/anim_prop.dart';
import '../model/camera.dart';
import '../model/easing.dart';
import '../model/layer.dart';
import '../model/project.dart';
import '../presets/world_map.dart';
import 'edit_commands.dart';

/// win-40: GEO LAYERS + After Effects camera / view options.
///
///   add_geo {id?, name?, style?, projection?: equirectangular|mercator|natural_earth|globe,
///            focus?: country | center?: [lon, lat], zoom?, highlight?: country | [{code, fill, stroke, glow, extrude, label, from, to}],
///            routes?: [{points: [[lon,lat]...], color, width, dashed, glow, arrow, arc, from, to, label}],
///            pins?: [{lon, lat, label, color, kind: dot|ring|pulse|diamond, at}], graticule?, borders?, labels?, texture?,
///            font?, label_size?, border_width?, dim_others?, atmosphere?, start?, duration?, is3d?, width?, height?,
///            reveal?: {start?, duration?: 4} (keyframes geo_progress 0→100), fly?: {to, zoom?, start?, duration?}}
///   update_geo {layer, ...any add_geo key}
///   geo_fly {layer, to: country | [lon, lat], zoom?, from?: country | [lon, lat], from_zoom?, start?, duration?: 2.5, ease?, arc?: true}
///   set_camera {type?: one_node|two_node, lens_mm?, focus_lock?, blur_level?, aperture?, focus?, orientation?: [x, y, z], time?}
///   set_view_layout {layout: "1"|"2"|"4"|"1+3", views?: [active|front|left|top|back|right|bottom|custom1..3], custom?: {custom1: [yaw, pitch, dist]}}
class GeoCommands {
  static const ops = ['add_geo', 'update_geo', 'geo_fly', 'set_camera', 'set_view_layout'];

  static void run(Project p, Map<String, dynamic> c, double now, CommandResult r) {
    final comp = p.editComp;
    switch (c['op']) {
      case 'add_geo':
        addGeo(comp, c, now, r);
      case 'update_geo':
        final l = _geoLayer(comp, c['layer']);
        _apply(comp, l, c, now);
        r.log.add('Updated map ${l.name}');
      case 'geo_fly':
        geoFly(comp, _geoLayer(comp, c['layer']), c, now, r);
      case 'set_camera':
        setCamera(comp, c, now, r);
      case 'set_view_layout':
        setViewLayout(comp, c, r);
    }
  }

  // ------------------------------------------------------------- helpers

  static double? _num(Map<String, dynamic> c, String k) {
    final v = c[k];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    throw CommandError('"$k" must be a number');
  }

  static Layer _geoLayer(Composition comp, dynamic id) {
    if (id is! String) throw CommandError('Missing "layer" (the map layer id)');
    final l = comp.layerById(id);
    if (l == null) throw CommandError('No layer "$id"');
    if (l.geo == null) throw CommandError('Layer "$id" is not a map (add one with add_geo)');
    return l;
  }

  /// Bounding box [west, south, east, north] of a country (largest-ring aware).
  static List<double> countryBox(Country c) {
    // Use the ring with the most points (mainland) so far islands do not blow the box up.
    List<double> best = c.rings.first;
    for (final r in c.rings) {
      if (r.length > best.length) best = r;
    }
    double w = 999, s = 999, e = -999, n = -999;
    for (int i = 0; i + 1 < best.length; i += 2) {
      w = math.min(w, best[i]);
      e = math.max(e, best[i]);
      s = math.min(s, best[i + 1]);
      n = math.max(n, best[i + 1]);
    }
    return [w, s, e, n];
  }

  /// [lon, lat] (+ fitting zoom) from a country name / code or a [lon, lat] list.
  static (List<double>, double?) place(dynamic v, String projection, double w, double h) {
    if (v is List && v.length >= 2) return ([(v[0] as num).toDouble(), (v[1] as num).toDouble()], null);
    if (v is String) {
      if (!WorldMap.loaded) throw CommandError('World map data is not loaded yet');
      final c = WorldMap.find(v);
      if (c == null) throw CommandError('Unknown country "$v"');
      final b = countryBox(c);
      return ([(b[0] + b[2]) / 2, (b[1] + b[3]) / 2], GeoView.fitZoom(projection, w, h, b));
    }
    throw CommandError('A place is a country name / ISO code or [lon, lat]');
  }

  static void _checkStyle(String s) {
    try {
      GeoStyles.byId(s);
    } on FormatException catch (e) {
      throw CommandError(e.message);
    }
  }

  // ------------------------------------------------------------- add / update

  static void addGeo(Composition comp, Map<String, dynamic> c, double now, CommandResult r) {
    final id = (c['id'] as String?) ?? Ids.next('map');
    if (comp.layerById(id) != null) throw CommandError('Layer id "$id" already exists');
    final w = _num(c, 'width') ?? comp.width, h = _num(c, 'height') ?? comp.height;
    final start = _num(c, 'start') ?? now;
    final dur = _num(c, 'duration') ?? math.max(1.0, comp.duration - start);
    final l = Layer(
      id: id,
      name: (c['name'] as String?) ?? 'Map',
      type: LayerType.shape,
      start: start,
      duration: dur,
      width: w,
      height: h,
      is3D: c['is3d'] == true || c['is3D'] == true,
      geo: GeoSpec(),
    );
    l.prop(Props.position).staticValue = [comp.width / 2, comp.height / 2, 0];
    l.props[GeoProps.center] = AnimProp([0, 20]);
    l.props[GeoProps.zoom] = AnimProp([1]);
    l.props[GeoProps.progress] = AnimProp([100]);
    comp.layers.insert(0, l);
    _apply(comp, l, c, now);
    r.createdIds.add(id);
    r.log.add('Added map $id (${l.geo!.style}, ${l.geo!.projection})');
  }

  static void _apply(Composition comp, Layer l, Map<String, dynamic> c, double now) {
    final g = l.geo!;
    try {
      g.apply(c);
    } on FormatException catch (e) {
      throw CommandError(e.message);
    } on TypeError catch (e) {
      throw CommandError('Bad map option: $e');
    }
    _checkStyle(g.style);
    if (WorldMap.loaded) {
      final unknown = [for (final h in g.highlights) if (WorldMap.find(h.code) == null) h.code];
      if (unknown.isNotEmpty) throw CommandError('Unknown countries: ${unknown.join(', ')}');
    }
    // Auto labels: a highlight without "label" gets the country name when labels are on.
    for (final h in g.highlights) {
      h.label ??= g.labels ? '' : null;
    }
    final focus = c['focus'] ?? c['center'];
    if (focus != null) {
      final (ctr, fit) = place(focus, g.projection, l.width, l.height);
      l.props[GeoProps.center]!.staticValue = ctr;
      l.props[GeoProps.center]!.keyframes.clear();
      final z = _num(c, 'zoom') ?? fit;
      if (z != null) {
        l.props[GeoProps.zoom]!.staticValue = [z];
        l.props[GeoProps.zoom]!.keyframes.clear();
      }
    } else if (c['zoom'] != null) {
      l.props[GeoProps.zoom]!.staticValue = [_num(c, 'zoom')!];
    }
    if (c['progress'] != null) l.props[GeoProps.progress]!.staticValue = [_num(c, 'progress')!.clamp(0, 100).toDouble()];
    final rev = c['reveal'];
    if (rev != null) {
      final m = rev is Map ? Map<String, dynamic>.from(rev) : <String, dynamic>{};
      final s = (m['start'] as num?)?.toDouble() ?? l.start;
      final d = (m['duration'] as num?)?.toDouble() ?? math.min(4.0, l.duration);
      final pr = l.props[GeoProps.progress]!;
      pr.keyframes.clear();
      pr.setKeyframe(s, [0], easing: Easing.linear);
      pr.setKeyframe(s + d, [100]);
    }
    final fly = c['fly'];
    if (fly is Map) geoFly(comp, l, Map<String, dynamic>.from(fly), now, CommandResult());
  }

  // ------------------------------------------------------------- geo_fly

  static void geoFly(Composition comp, Layer l, Map<String, dynamic> c, double now, CommandResult r) {
    final g = l.geo!;
    if (c['to'] == null) throw CommandError('geo_fly needs "to" (country or [lon, lat])');
    final start = _num(c, 'start') ?? now;
    final dur = math.max(0.1, _num(c, 'duration') ?? 2.5);
    Easing ease;
    try {
      ease = c['ease'] == null ? const Easing.bezierCurve(0.65, 0, 0.35, 1) : Easing.fromJson(c['ease']);
    } on FormatException catch (e) {
      throw CommandError(e.message);
    }
    final cp = l.props[GeoProps.center]!, zp = l.props[GeoProps.zoom]!;
    var from = cp.valueAt(start);
    var fromZ = zp.valueAt(start)[0];
    if (c['from'] != null) {
      final (f, fz) = place(c['from'], g.projection, l.width, l.height);
      from = f;
      fromZ = _num(c, 'from_zoom') ?? fz ?? fromZ;
    } else if (c['from_zoom'] != null) {
      fromZ = _num(c, 'from_zoom')!;
    }
    final (to0, fit) = place(c['to'], g.projection, l.width, l.height);
    final toZ = _num(c, 'zoom') ?? fit ?? fromZ;
    // Shortest way round the Earth (the projection wraps longitudes).
    var dl = to0[0] - from[0];
    while (dl > 180) {
      dl -= 360;
    }
    while (dl < -180) {
      dl += 360;
    }
    final to = [from[0] + dl, to0[1]];
    cp.setKeyframe(start, from, easing: ease);
    cp.setKeyframe(start + dur, to, easing: ease);
    zp.setKeyframe(start, [fromZ], easing: ease);
    // Long flights pull back mid-way (Google-Earth style arc).
    final dist = math.sqrt(dl * dl + math.pow(to[1] - from[1], 2));
    if (c['arc'] != false && dist > 25) {
      final mid = math.max(0.35, math.min(fromZ, toZ) * (25 / dist).clamp(0.25, 0.8));
      zp.setKeyframe(start + dur / 2, [mid], easing: ease);
    }
    zp.setKeyframe(start + dur, [toZ], easing: ease);
    r.log.add('Map ${l.id} flies to ${c['to']} (${start.toStringAsFixed(2)}–${(start + dur).toStringAsFixed(2)} s)');
  }

  // ------------------------------------------------------------- camera

  static void setCamera(Composition comp, Map<String, dynamic> c, double now, CommandResult r) {
    final rig = comp.camera;
    final t = _num(c, 'time');
    void put(String k, List<double> v) {
      final p = rig.props[k]!;
      if (t != null) {
        p.setKeyframe(t, v);
      } else {
        p.staticValue = v;
      }
    }

    if (c['type'] != null) {
      final ty = '${c['type']}'.toLowerCase().replaceAll('-', '_').replaceAll(' ', '_');
      if (ty == 'one_node' || ty == '1' || ty == 'onenode') {
        if (rig.type != 'one_node') {
          // Keep the current aim: orientation from the point of interest.
          final pos = rig.props[CamProps.position]!.valueAt(now), poi = rig.props[CamProps.poi]!.valueAt(now);
          final dx = poi[0] - pos[0], dy = poi[1] - pos[1], dz = poi[2] - pos[2];
          final yaw = math.atan2(dx, dz) * 180 / math.pi;
          final pitch = math.atan2(dy, math.sqrt(dx * dx + dz * dz)) * 180 / math.pi;
          rig.props[CamProps.orientation]!.staticValue = [pitch, yaw, 0];
        }
        rig.type = 'one_node';
      } else if (ty == 'two_node' || ty == '2' || ty == 'twonode') {
        rig.type = 'two_node';
      } else {
        throw CommandError('Camera type is "one_node" or "two_node"');
      }
    }
    if (c['lens_mm'] != null || c['lens'] != null) {
      final mm = _num(c, c['lens_mm'] != null ? 'lens_mm' : 'lens')!;
      if (mm < 5 || mm > 1000) throw CommandError('lens_mm must be 5..1000 (presets: ${kLensPresetsMm.join(', ')})');
      put(CamProps.zoom, [zoomForLens(comp.width, mm)]);
    }
    if (c['focus_lock'] is bool) rig.focusLock = c['focus_lock'] as bool;
    if (c['blur_level'] != null) put(CamProps.blurLevel, [_num(c, 'blur_level')!.clamp(0, 400).toDouble()]);
    if (c['aperture'] != null) put(CamProps.aperture, [math.max(0.0, _num(c, 'aperture')!)]);
    if (c['focus'] != null) put(CamProps.focus, [math.max(1.0, _num(c, 'focus')!)]);
    if (c['orientation'] is List) {
      final o = [for (final x in c['orientation'] as List) (x as num).toDouble()];
      while (o.length < 3) {
        o.add(0);
      }
      put(CamProps.orientation, o.take(3).toList());
    }
    if (rig.mode != CameraMode.threeD && (c['type'] != null || c['lens_mm'] != null)) rig.mode = CameraMode.threeD;
    r.log.add('Camera: ${rig.type}, ${lensForZoom(comp.width, rig.props[CamProps.zoom]!.valueAt(now)[0]).toStringAsFixed(0)} mm'
        '${rig.focusLock ? ', focus locked to POI' : ''}');
  }

  // ------------------------------------------------------------- views

  static void setViewLayout(Composition comp, Map<String, dynamic> c, CommandResult r) {
    final layout = '${c['layout'] ?? comp.viewLayout}';
    if (!Composition.viewLayouts.contains(layout)) throw CommandError('layout is one of ${Composition.viewLayouts.join(', ')}');
    comp.viewLayout = layout;
    const kinds = ['active', 'front', 'left', 'top', 'back', 'right', 'bottom', 'custom1', 'custom2', 'custom3'];
    if (c['views'] is List) {
      final v = [for (final x in c['views'] as List) '$x'.toLowerCase().replaceAll(' ', '')];
      final bad = v.where((x) => !kinds.contains(x)).toList();
      if (bad.isNotEmpty) throw CommandError('Unknown views ${bad.join(', ')} (use ${kinds.join(', ')})');
      final next = List.of(comp.views);
      for (int i = 0; i < v.length && i < 4; i++) {
        next[i] = v[i];
      }
      comp.views = next;
    }
    if (c['custom'] is Map) {
      (c['custom'] as Map).forEach((k, v) {
        if (!'$k'.startsWith('custom') || v is! List) throw CommandError('custom: {custom1: [yaw, pitch, distance]}');
        comp.customViews['$k'] = [for (final x in v) (x as num).toDouble()];
      });
    }
    r.log.add('View layout $layout: ${comp.views.take(layout == '1' ? 1 : (layout == '2' ? 2 : 4)).join(', ')}');
  }
}
