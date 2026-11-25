import 'dart:convert';
import 'dart:math' as math;

import '../engine/precomp.dart';
import '../model/layer.dart';
import '../model/project.dart';
import '../presets/motion_presets.dart';
import '../presets/scene3d.dart';
import '../presets/shots.dart';
import '../presets/transition_registry.dart';
import '../presets/doc_transitions.dart'; // V2-lead
import 'edit_commands.dart';

/// Shots & sequences (V2-B). Called from [EditCommands] by the `// V2-B`
/// hooks.
///
/// - `add_shot` builds a whole parallax shot in ONE command: a precomp with
///   its own 3D camera holding the plate and the cut-outs (sized and put on
///   the ground by role, made 3D on depth bands, contact shadows, a soft
///   floor plane), camera moves that never touch a layer or show an empty
///   edge, atmosphere, title / caption, and ONE comp layer in main. The shot
///   id is the id of the precomp AND of its comp layer in main.
/// - `sequence` builds shots back to back with transitions between them.
/// - `update_shot` rebuilds a shot with changed fields; `remove_shot`
///   deletes it (optionally closing the gap).
///
/// Shot specs are kept in [Project.seqShots] so a shot can be rebuilt.
class ShotCommands {
  static const ops = ['add_shot', 'update_shot', 'remove_shot', 'sequence'];

  static const _specKeys = [
    'id', 'name', 'start', 'duration', 'plate', 'layers', 'ground', 'ground_color', 'floor', 'camera', 'atmosphere',
    'look', 'title', 'caption', 'style', 'keep_far_visible', 'index',
  ];

  static void run(Project p, Map<String, dynamic> c, CommandResult r, void Function(Map<String, dynamic>) exec) {
    final op = '${c['op']}';
    try {
      switch (op) {
        case 'add_shot':
          addShot(p, c, r, exec);
          break;
        case 'update_shot':
          _updateShot(p, c, r, exec);
          break;
        case 'remove_shot':
          _removeShot(p, c, r);
          break;
        case 'sequence':
          _sequence(p, c, r, exec);
          break;
      }
    } on CommandError catch (e) {
      throw CommandError(e.message.startsWith(op) ? e.message : '$op: ${e.message}');
    } on ArgumentError catch (e) {
      throw CommandError('$op: ${e.message}');
    }
  }

  // ------------------------------------------------------------- helpers

  static double? _n(Map c, String k) {
    final v = c[k];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    throw CommandError('"$k" must be a number');
  }

  static Map<String, dynamic> _json(Map m) => Map<String, dynamic>.from(jsonDecode(jsonEncode(m)) as Map);

  static bool _idFree(Project p, String id) => p.compById(id) == null && p.main.layerById(id) == null && !p.seqShots.containsKey(id);

  static String _newId(Project p, {Set<String> taken = const {}}) {
    for (int i = p.seqShots.length + 1;; i++) {
      final id = 'shot$i';
      if (_idFree(p, id) && !taken.contains(id)) return id;
    }
  }

  /// End of the last shot in main (0 when there is none).
  static double lastShotEnd(Project p) {
    var end = 0.0;
    for (final id in p.seqShots.keys) {
      final l = p.main.layerById(id);
      if (l != null && l.end > end) end = l.end;
    }
    return end;
  }

  static MediaAsset _media(Project p, dynamic id, String what) {
    final m = id is String ? p.media[id] : null;
    if (m == null || m.type == MediaType.audio) {
      final avail = p.media.values.where((m) => m.type != MediaType.audio).map((m) => m.id).join(', ');
      throw CommandError('$what needs an image or video media id (got ${jsonEncode(id)}). Media: ${avail.isEmpty ? '(none imported)' : avail}');
    }
    return m;
  }

  static String _layerType(MediaAsset m) => m.type == MediaType.video ? 'video' : 'image';

  /// Atmosphere spec → {kind: amount}.
  static Map<String, double> _atmos(dynamic a) {
    if (a == null || a == false || a == 'none') return const {};
    final out = <String, double>{};
    if (a is String) {
      out[a] = -1.0;
    } else if (a is List) {
      for (final e in a) {
        out['$e'] = -1.0;
      }
    } else if (a is Map) {
      a.forEach((k, v) {
        if (v == false || v == 0) return;
        out['$k'] = v is num ? v.toDouble() : -1.0;
      });
    } else {
      throw CommandError('atmosphere must be a name, a list of names or {name: amount}');
    }
    return out;
  }

  static const atmosphereKinds = [
    'dust', 'rain', 'snow', 'smoke', 'fog', 'haze', 'light_rays', 'birds', 'leaves', 'bokeh', 'embers', 'clouds', 'stars',
  ];

  // ------------------------------------------------------------- add_shot

  /// Builds one shot. Returns the shot id.
  static String addShot(Project p, Map<String, dynamic> c, CommandResult r, void Function(Map<String, dynamic>) exec,
      {Set<String> taken = const {}}) {
    final main = p.main;
    main.motionBlur = true; // V2-lead: camera moves inside shots need main's motion blur on to show it.
    final w = main.width, h = main.height;
    final id = (c['id'] as String?) ?? _newId(p, taken: taken);
    if (!_idFree(p, id)) throw CommandError('id "$id" is already used (shot, comp or layer in main)');
    final styleId = c['style'] as String?;
    final style = styleId == null ? null : ShotStyles.byId(styleId);
    if (styleId != null && style == null) throw CommandError('Unknown style "$styleId". Styles: ${ShotStyles.ids.join(', ')}');
    final dur = (_n(c, 'duration') ?? 6).clamp(0.5, 600.0).toDouble();
    final start = math.max(0.0, _n(c, 'start') ?? lastShotEnd(p));
    final floor = (_n(c, 'floor') ?? ShotRoles.defaultFloor).clamp(0.55, 1.2).toDouble();
    final name = (c['name'] as String?) ?? 'Shot ${p.seqShots.length + 1}';
    final log = r.log;

    void x(Map<String, dynamic> cmd) => exec({...cmd, 'in_comp': id});

    exec({'op': 'add_comp', 'id': id, 'name': name, 'width': w, 'height': h, 'fps': main.fps, 'duration': dur});
    final comp = p.comps[id]!;
    comp.motionBlur = true;

    // Plate (background, cover) — or a dark gradient backdrop.
    final plateId = '${id}_plate';
    if (c['plate'] != null) {
      final m = _media(p, c['plate'], 'plate');
      x({'op': 'add_layer', 'type': _layerType(m), 'media': m.id, 'id': plateId, 'name': 'Plate', 'fit': 'cover', 'start': 0, 'duration': dur});
    } else {
      x({
        'op': 'add_layer', 'type': 'shape', 'kind': 'rect', 'id': plateId, 'name': 'Backdrop', 'width': w, 'height': h,
        'position': [w / 2, h / 2, 0], 'fill': '#1B2330', 'fill2': '#07090D', 'start': 0, 'duration': dur,
      });
    }

    // Cut-outs, back to front.
    final raw = c['layers'];
    if (raw != null && raw is! List) throw CommandError('"layers" must be a list of {media, role?, x?, ground?, height?, flip?, effects?}');
    final specs = <({int i, Map<String, dynamic> m, String role, MediaAsset media})>[];
    final roleList = [...ShotRoles.roles];
    final rawList = raw is List ? raw : const [];
    for (int i = 0; i < rawList.length; i++) {
      final e = rawList[i];
      final m = e is String ? <String, dynamic>{'media': e} : (e is Map ? Map<String, dynamic>.from(e) : null);
      if (m == null) throw CommandError('layers[$i] must be {media, role?, ...}');
      final media = _media(p, m['media'], 'layers[$i]');
      final role = (m['role'] as String?) ?? ShotRoles.guess(media.width, media.height);
      if (!roleList.contains(role)) throw CommandError('layers[$i]: unknown role "$role". Roles: ${roleList.join(', ')}');
      specs.add((i: i, m: m, role: role, media: media));
    }
    specs.sort((a, b) {
      final d = ShotRoles.order(a.role).compareTo(ShotRoles.order(b.role));
      return d != 0 ? d : a.i.compareTo(b.i);
    });

    final perRole = <String, int>{};
    final cut = <({String id, String role, bool auto, bool hero, double area, bool grounded})>[];
    final usedIds = <String>{plateId};
    for (final s in specs) {
      final k = perRole[s.role] = (perRole[s.role] ?? 0) + 1;
      final lid = (s.m['id'] as String?) ?? '${id}_${s.role}$k';
      if (!usedIds.add(lid)) throw CommandError('layer id "$lid" is used twice in this shot');
      final size = ShotRoles.size(s.role, s.media.width, s.media.height, w, h, height: _n(s.m, 'height'));
      final cx = (_n(s.m, 'x') ?? ShotRoles.defaultX(s.role, k - 1)) * w;
      final g = _n(s.m, 'ground');
      final double cy;
      if (s.role == 'sky' && g == null) {
        cy = -0.02 * h + size.h / 2;
      } else {
        cy = (g ?? ShotRoles.groundLine(s.role, floor)) * h - size.h / 2;
      }
      final sc = size.h / math.max(1, s.media.height) * 100;
      x({
        'op': 'add_layer', 'type': _layerType(s.media), 'media': s.media.id, 'id': lid, 'name': s.m['name'] ?? s.media.name,
        'fit': 'none', 'position': [cx, cy, 0], 'scale': [s.m['flip'] == true ? -sc : sc, sc, 100], 'start': 0, 'duration': dur,
      });
      final fx = s.m['effects'];
      if (fx is List) {
        for (final e in fx) {
          if (e is String) {
            x({'op': 'add_effect', 'layer': lid, 'effect': e});
          } else if (e is Map) {
            x({'op': 'add_effect', 'layer': lid, 'effect': e['effect'] ?? e['type'], if (e['params'] is Map) 'params': e['params']});
          }
        }
      }
      cut.add((
        id: lid,
        role: s.role,
        auto: g == null && ShotRoles.grounded.contains(s.role),
        hero: s.m['hero'] == true || s.m['focus'] == true,
        area: size.w * size.h,
        grounded: ShotRoles.grounded.contains(s.role) || (g != null && s.role != 'sky'),
      ));
    }

    // Depth.
    x({
      'op': 'make_3d',
      'layers': [plateId, ...cut.map((e) => e.id)],
      'bands': {plateId: 'sky', for (final e in cut) e.id: ShotRoles.band(e.role)},
      'start': 0,
    });

    // Feet on the floor plane (make_3d keeps the picture; stacking nudges
    // within a band are corrected here).
    final floorY = ShotGeometry.floorY(comp, floor);
    for (final e in cut) {
      if (e.auto) ShotGeometry.snapToFloor(comp, comp.requireLayer(e.id), floorY);
    }

    // Ground mode: auto (contact shadows + soft floor) | shadows | none | media id.
    final ground = c['ground'] ?? 'auto';
    final groundStr = ground == false ? 'none' : (ground == true ? 'auto' : '$ground');
    MediaAsset? floorMedia;
    if (!const ['auto', 'shadows', 'none'].contains(groundStr)) floorMedia = _media(p, ground, 'ground');
    if (groundStr != 'none') {
      for (final e in cut) {
        if (!e.grounded) continue;
        ShotGeometry.addContactShadow(comp, comp.requireLayer(e.id), '${e.id}_shadow');
        r.createdIds.add('${e.id}_shadow');
      }
    }

    // Hero = the most important cut-out.
    String? hero;
    for (final e in cut) {
      if (e.hero) {
        hero = e.id;
        break;
      }
    }
    if (hero == null) {
      for (final role in const ['mid', 'near', 'far', 'front']) {
        var best = -1.0;
        for (final e in cut) {
          if (e.role == role && e.area > best) {
            best = e.area;
            hero = e.id;
          }
        }
        if (hero != null) break;
      }
    }

    // Camera.
    final camSpec = c['camera'];
    List<Map<String, dynamic>> moves;
    var relative = false;
    if (camSpec == 'none' || camSpec == false) {
      moves = const [];
    } else if (camSpec is List) {
      moves = [for (final m in camSpec) Map<String, dynamic>.from(m as Map)];
    } else if (camSpec is Map) {
      moves = [Map<String, dynamic>.from(camSpec)];
    } else if (camSpec != null) {
      throw CommandError('camera must be a list of {move, target?, start, duration, intensity}');
    } else {
      moves = style?.camera ?? ShotStyles.defaultCamera(hasHero: hero != null, duration: dur);
      relative = true;
    }
    String? target(dynamic t) {
      if (t == null) return null;
      final s = '$t';
      if (s == 'hero') return hero;
      if (comp.layerById(s) != null) return s;
      for (final e in cut) {
        if (e.role == s) return e.id;
      }
      for (final l in comp.layers) {
        if (l.mediaId == s) return l.id;
      }
      throw CommandError('camera target "$s" is not a layer of this shot. Layers: ${[plateId, ...cut.map((e) => e.id)].join(', ')} (or "hero")');
    }

    final camLog = <Map<String, dynamic>>[];
    for (int i = 0; i < moves.length; i++) {
      final m = moves[i];
      final mv = '${m['move'] ?? 'drift'}';
      if (!Scene3D.moves.contains(mv)) throw CommandError('camera[$i]: unknown move "$mv". Moves: ${Scene3D.moves.join(', ')}');
      double st, du;
      if (relative) {
        st = ((m['u0'] as num?) ?? 0).toDouble() * dur;
        du = ((m['u1'] as num?) ?? 1).toDouble() * dur - st;
      } else {
        st = _n(m, 'start') ?? (i == 0 ? 0.0 : (camLog.isEmpty ? 0.0 : (camLog.last['start'] as double) + (camLog.last['duration'] as double)));
        du = _n(m, 'duration') ?? (dur - st);
      }
      st = st.clamp(0.0, math.max(0.0, dur - 0.1)).toDouble();
      du = math.min(du, dur - st);
      if (du < 0.1) continue;
      final tg = target(m['target']);
      final cmd = <String, dynamic>{
        'op': 'camera_shot', 'move': mv, 'start': st, 'duration': du,
        'intensity': m['intensity'] ?? m['amount'] ?? 0.5,
        'target': ?tg,
        if (m['point'] != null) 'point': m['point'],
        if (m['ease'] != null) 'ease': m['ease'],
        if (m['direction'] != null) 'direction': m['direction'],
      };
      x(cmd);
      camLog.add({'move': mv, 'start': st, 'duration': du, 'target': ?tg});
    }
    comp.duration = dur; // camera_shot may extend the comp; the shot keeps its length

    // Far layers stay visible over the mid band.
    if (c['keep_far_visible'] != false) {
      ShotGeometry.keepFarVisible(
        comp,
        [for (final e in cut) if (e.role == 'far') comp.requireLayer(e.id)],
        [for (final e in cut) if (e.role == 'mid') comp.requireLayer(e.id)],
        dur,
        log: log,
      );
    }

    // Floor plane (after the camera so it never sits under the lens).
    if ((groundStr == 'auto' || floorMedia != null) && cut.any((e) => e.grounded)) {
      var color = 0xFF231B13;
      if (c['ground_color'] != null) {
        final s = '${c['ground_color']}'.replaceFirst('#', '');
        final v = int.tryParse(s.length == 6 ? 'FF$s' : s, radix: 16);
        if (v == null) throw CommandError('Bad ground_color "${c['ground_color']}" (use "#RRGGBB")');
        color = v;
      }
      final f = ShotGeometry.buildFloor(comp, '${id}_floor', floorY, dur, media: floorMedia, color: color, log: log);
      if (f != null) r.createdIds.add(f.id);
    }

    // No empty edges at any time of the shot.
    ShotGeometry.ensureCover(comp, comp.requireLayer(plateId), dur, log: log);

    // Atmosphere (flat, over the picture).
    final atm = _atmos(c.containsKey('atmosphere') ? c['atmosphere'] : style?.atmosphere);
    for (final e in atm.entries) {
      _addAtmosphere(id, e.key, e.value, w, h, dur, x);
    }

    // Title / caption.
    if (c['title'] != null) _addTitle(id, c['title'], w, h, dur, x);
    if (c['caption'] != null) _addCaption(id, c['caption'], w, h, dur, x);

    // ONE comp layer in main.
    exec({
      'op': 'add_layer', 'in_comp': main.id, 'type': 'comp', 'comp': id, 'id': id, 'name': name, 'start': start, 'duration': dur,
      if (c['index'] is num) 'index': c['index'],
    });
    final cl = main.requireLayer(id);
    final look = c.containsKey('look') ? c['look'] : style?.look;
    if (look != null && look != 'none' && look != false) ShotLooks.apply(cl, '$look');

    final spec = <String, dynamic>{
      for (final k in _specKeys)
        if (c.containsKey(k)) k: c[k],
    }
      ..['id'] = id
      ..['start'] = start
      ..['duration'] = dur
      ..remove('index');
    p.seqShots[id] = {
      'spec': _json(spec),
      'hero': ?hero,
      'layers': {for (final e in cut) e.id: e.role},
      'camera': camLog,
    };
    Precomp.touch();
    log.add('Shot $id "$name": ${start.toStringAsFixed(2)}–${(start + dur).toStringAsFixed(2)} s, '
        '${cut.length} cut-out(s)${hero == null ? '' : ', hero $hero'}, camera ${camLog.map((m) => m['move']).join(' → ')}');
    return id;
  }

  static void _addAtmosphere(String id, String kind, double amount, double w, double h, double dur, void Function(Map<String, dynamic>) x) {
    if (!atmosphereKinds.contains(kind)) {
      throw CommandError('Unknown atmosphere "$kind". Use ${atmosphereKinds.join(', ')}');
    }
    final lid = '${id}_atmo_$kind';
    double a(double d) => amount < 0 ? d : amount.clamp(0.0, 100.0).toDouble();
    if (kind == 'haze') {
      x({
        'op': 'add_layer', 'type': 'shape', 'kind': 'rect', 'id': lid, 'name': 'Haze', 'width': w, 'height': h,
        'position': [w / 2, h / 2, 0], 'fill': '#B0D5DCE3', 'fill2': '#00D5DCE3', 'start': 0, 'duration': dur,
      });
      x({'op': 'set_property', 'target': lid, 'prop': 'opacity', 'value': a(30)});
      return;
    }
    x({
      'op': 'add_layer', 'type': 'solid', 'id': lid, 'name': 'Atmosphere $kind', 'color': '#00000000', 'width': w, 'height': h,
      'position': [w / 2, h / 2, 0], 'start': 0, 'duration': dur,
    });
    if (kind == 'light_rays') {
      x({'op': 'add_effect', 'layer': lid, 'effect': 'light_rays', 'params': {'amount': a(40), 'angle': 60}});
      return;
    }
    final particle = switch (kind) {
      'fog' => 'smoke',
      'embers' => 'dust',
      _ => kind,
    };
    final speed = switch (kind) {
      'smoke' || 'fog' || 'clouds' => 0.4,
      'dust' || 'bokeh' => 0.5,
      'birds' => 0.6,
      _ => 1.0,
    };
    final def = switch (kind) {
      'rain' => 55.0,
      'snow' => 45.0,
      'birds' => 15.0,
      'smoke' || 'fog' => 30.0,
      _ => 35.0,
    };
    x({
      'op': 'add_effect', 'layer': lid, 'effect': 'particles',
      'params': {'kind': particle, 'amount': a(def), 'speed': speed, if (kind == 'embers') 'color': '#FFB347'},
    });
    if (kind == 'smoke' || kind == 'fog') x({'op': 'set_property', 'target': lid, 'prop': 'opacity', 'value': 70});
  }

  static double _y(dynamic at, double h, double d) {
    if (at is List && at.length >= 2 && at[1] is num) return (at[1] as num).toDouble() * h;
    return switch ('$at') {
      'top' => h * 0.2,
      'bottom' || 'lower' => h * 0.74,
      _ => h * d,
    };
  }

  static void _addTitle(String id, dynamic t, double w, double h, double dur, void Function(Map<String, dynamic>) x) {
    final m = t is String ? <String, dynamic>{'text': t} : Map<String, dynamic>.from(t as Map);
    final text = '${m['text'] ?? ''}';
    if (text.isEmpty) throw CommandError('title needs "text"');
    final at = m['at'] is num ? (m['at'] as num).toDouble().clamp(0.0, math.max(0.0, dur - 0.5)).toDouble() : 0.5;
    final y = _y(m['position'] ?? (m['at'] is num ? null : m['at']), h, 0.45);
    final cx = m['position'] is List ? ((m['position'] as List)[0] as num).toDouble() * w : w / 2;
    final tid = '${id}_title';
    x({
      'op': 'add_layer', 'type': 'text', 'id': tid, 'text': text, 'start': at, 'duration': math.max(0.4, dur - at - 0.1),
      'width': w * 0.86, 'height': h * 0.22, 'position': [cx, y, 0], 'font_size': h * 0.1, 'font_weight': 900,
      if (m['font'] != null) 'font': m['font'] else 'text_style': m['text_style'] ?? 'doc_title',
      'animator': 'fade_up', 'anim_duration': 1.0, 'shadow': true,
    });
    x({'op': 'animate_out', 'layer': tid, 'preset': 'fade', 'duration': 0.5});
    if (m['subtitle'] != null) {
      final sid = '${id}_subtitle';
      final st = math.min(at + 0.5, math.max(0.0, dur - 0.5));
      x({
        'op': 'add_layer', 'type': 'text', 'id': sid, 'text': '${m['subtitle']}', 'start': st, 'duration': math.max(0.4, dur - st - 0.1),
        'width': w * 0.8, 'height': h * 0.09, 'position': [cx, y + h * 0.12, 0], 'font_size': h * 0.042, 'font_weight': 500,
        if (m['font'] != null) 'font': m['font'],
        'text_color': '#E9E1D2', 'animator': 'fade_up', 'anim_duration': 0.8, 'shadow': true,
      });
      x({'op': 'animate_out', 'layer': sid, 'preset': 'fade', 'duration': 0.5});
    }
  }

  static void _addCaption(String id, dynamic t, double w, double h, double dur, void Function(Map<String, dynamic>) x) {
    final m = t is String ? <String, dynamic>{'text': t} : Map<String, dynamic>.from(t as Map);
    final text = '${m['text'] ?? ''}';
    if (text.isEmpty) throw CommandError('caption needs "text"');
    final at = (m['at'] is num ? (m['at'] as num).toDouble() : 0.8).clamp(0.0, math.max(0.0, dur - 0.5)).toDouble();
    final du = m['duration'] is num ? (m['duration'] as num).toDouble() : dur - at - 0.3;
    final pos = '${m['position'] ?? 'bottom_left'}';
    final bw = w * 0.6;
    final (double px, double py, String align) = switch (pos) {
      'bottom' => (w / 2, h * 0.88, 'center'),
      'top_left' => (w * 0.06 + bw / 2, h * 0.1, 'left'),
      'top' => (w / 2, h * 0.1, 'center'),
      _ => (w * 0.06 + bw / 2, h * 0.88, 'left'),
    };
    final cid = '${id}_caption';
    x({
      'op': 'add_layer', 'type': 'text', 'id': cid, 'text': text, 'start': at, 'duration': math.max(0.4, math.min(du, dur - at)),
      'width': bw, 'height': h * 0.08, 'position': [px, py, 0], 'font_size': h * 0.038, 'align': align,
      if (m['font'] != null) 'font': m['font'] else 'text_style': m['text_style'] ?? 'typewriter',
      'animator': 'typewriter', 'anim_duration': math.min(1.2, 0.05 * text.length + 0.3), 'shadow': true,
    });
    x({'op': 'animate_out', 'layer': cid, 'preset': 'fade', 'duration': 0.4});
  }

  // ---------------------------------------------------------- remove_shot

  static Map<String, dynamic> _entry(Project p, dynamic id) {
    final e = id is String ? p.seqShots[id] : null;
    if (e is! Map) {
      throw CommandError('No shot "$id". Shots: ${p.seqShots.isEmpty ? '(none)' : p.seqShots.keys.join(', ')}');
    }
    return Map<String, dynamic>.from(e);
  }

  /// Deletes shot [id] (comp layer in main + precomp). Returns the removed
  /// comp layer's (start, end) or null when it was not in main.
  static (double, double)? _remove(Project p, String id) {
    final main = p.main;
    final users = Precomp.usersOf(p, id);
    for (final (comp, l) in users) {
      if (comp.id != main.id || l.id != id) {
        throw CommandError('shot comp "$id" is also used by layer ${l.id} in ${comp.name}; remove that first');
      }
    }
    final l = main.layerById(id);
    (double, double)? span;
    if (l != null) {
      span = (l.start, l.end);
      main.layers.remove(l);
      for (final o in main.layers) {
        if (o.parentId == id) o.parentId = null;
        if (o.matte?.layerId == id) o.matte = null;
      }
    }
    p.comps.remove(id);
    if (p.editCompId == id) p.editCompId = null;
    p.seqShots.remove(id);
    Precomp.touch();
    return span;
  }

  static void _removeShot(Project p, Map<String, dynamic> c, CommandResult r) {
    final id = c['shot'] ?? c['id'];
    _entry(p, id);
    final span = _remove(p, '$id');
    r.log.add('Removed shot $id');
    if (c['ripple'] == true && span != null) {
      final (s0, _) = span;
      final later = p.main.layers.where((l) => l.start > s0 + 1e-6).toList();
      if (later.isEmpty) return;
      final first = later.map((l) => l.start).reduce(math.min);
      final shift = first - s0;
      for (final l in later) {
        l.moveTo(l.start - shift);
      }
      r.log.add('Closed the ${shift.toStringAsFixed(2)} s gap');
    }
  }

  // ---------------------------------------------------------- update_shot

  static void _updateShot(Project p, Map<String, dynamic> c, CommandResult r, void Function(Map<String, dynamic>) exec) {
    final id = '${c['shot'] ?? c['id']}';
    final entry = _entry(p, id);
    final old = Map<String, dynamic>.from(entry['spec'] as Map);
    final merged = <String, dynamic>{...old};
    for (final k in _specKeys) {
      if (k == 'id') continue;
      if (c.containsKey(k)) merged[k] = c[k];
    }
    final main = p.main;
    final oldLayer = main.layerById(id);
    final idx = oldLayer == null ? 0 : main.indexOf(id);
    final oldStart = oldLayer?.start ?? (old['start'] as num? ?? 0).toDouble();
    final oldDur = oldLayer?.duration ?? (old['duration'] as num? ?? 6).toDouble();
    if (!c.containsKey('start')) merged['start'] = oldStart;
    // Transitions on the comp layer (opacity keys, in/out effects) survive
    // when the shot keeps its timing.
    final keep = oldLayer?.copy();
    _remove(p, id);
    addShot(p, {...merged, 'id': id, 'index': idx}, r, exec);
    final nl = main.requireLayer(id);
    final newDur = nl.duration;
    if (keep != null && (nl.start - keep.start).abs() < 1e-6 && (newDur - keep.duration).abs() < 1e-6) {
      for (final k in [Props.opacity, Props.position, Props.scale, Props.rotation]) {
        nl.props[k] = keep.prop(k).copy();
      }
      nl.is3D = keep.is3D;
      nl.parentId = keep.parentId;
      nl.matte = keep.matte;
      nl.blendMode = keep.blendMode;
      for (final e in keep.effects) {
        if (!e.id.startsWith('${id}_style_')) nl.effects.add(e.copy());
      }
    } else if (keep != null) {
      r.log.add('Shot $id changed timing: re-apply its transitions if it had any');
    }
    if (c['ripple'] == true && (newDur - oldDur).abs() > 1e-6) {
      final oldEnd = oldStart + oldDur, delta = newDur - oldDur;
      for (final l in main.layers) {
        if (l.id != id && l.start >= oldEnd - 1e-6) l.moveTo(math.max(0.0, l.start + delta));
      }
      if (main.contentEnd > main.duration) main.duration = main.contentEnd;
    }
  }

  // ------------------------------------------------------------- sequence

  /// Fallback presets (animate_in on the incoming shot) for transitions no
  /// provider registered.
  static String? fallbackPreset(String type) {
    const alias = {
      'dissolve': 'fade', 'crossfade': 'fade', 'dip_white': 'flash', 'white_flash': 'flash', 'ink_bleed': 'ink',
      'smoke_dissolve': 'smoke', 'iris_in': 'iris', 'whip_pan': 'whip',
    };
    final t = alias[type] ?? type;
    return MotionPresets.transitions.contains(t) ? t : null;
  }

  static void _sequence(Project p, Map<String, dynamic> c, CommandResult r, void Function(Map<String, dynamic>) exec) {
    final shots = c['shots'];
    if (shots is! List || shots.isEmpty) throw CommandError('sequence needs "shots": [add_shot specs...]');
    final n = shots.length;
    final specs = <Map<String, dynamic>>[];
    for (int i = 0; i < n; i++) {
      if (shots[i] is! Map) throw CommandError('shots[$i] must be an add_shot spec');
      specs.add(Map<String, dynamic>.from(shots[i] as Map)..remove('op'));
    }
    double durOf(int i) => ((specs[i]['duration'] as num?) ?? 6).toDouble().clamp(0.5, 600.0).toDouble();

    // Transitions per gap (i → i+1).
    final trans = List<Map<String, dynamic>?>.filled(math.max(0, n - 1), null);
    if (c['transition'] != null) {
      final d = c['transition'];
      for (int i = 0; i < n - 1; i++) {
        trans[i] = d is Map ? Map<String, dynamic>.from(d) : {'type': '$d', if (c['transition_duration'] is num) 'duration': c['transition_duration']};
      }
    }
    final tl = c['transitions'];
    if (tl != null && tl is! List) throw CommandError('"transitions" must be a list of {between: [i, i+1], type, duration}');
    for (final t in (tl as List? ?? const [])) {
      if (t is! Map) throw CommandError('each transition is {between: [i, i+1], type, duration}');
      final b = t['between'];
      final i = b is List && b.isNotEmpty && b[0] is num ? (b[0] as num).toInt() : (t['after'] is num ? (t['after'] as num).toInt() : -1);
      if (i < 0 || i >= n - 1 || (b is List && b.length > 1 && b[1] is num && (b[1] as num).toInt() != i + 1)) {
        throw CommandError('transition between ${jsonEncode(b)}: use two neighbouring shot indexes [i, i+1] (0-based, $n shots)');
      }
      trans[i] = Map<String, dynamic>.from(t);
    }

    // Start times (an overlap pulls the next shot in).
    final overlaps = <double>[];
    for (int i = 0; i < n - 1; i++) {
      final t = trans[i];
      final type = '${t?['type'] ?? 'cut'}';
      final d = ((t?['duration'] as num?) ?? 0.6).toDouble().clamp(0.0, math.min(durOf(i), durOf(i + 1)) / 2).toDouble();
      overlaps.add(type == 'cut' || t?['overlap'] == false ? 0.0 : d);
      if (t != null) {
        t['type'] = type;
        t['duration'] = d;
      }
    }
    var cur = math.max(0.0, _n(c, 'start') ?? lastShotEnd(p));
    final ids = <String>[];
    final taken = <String>{};
    for (int i = 0; i < n; i++) {
      final spec = {...specs[i], 'start': cur};
      if (spec['id'] == null) {
        spec['id'] = _newId(p, taken: taken);
      }
      taken.add('${spec['id']}');
      try {
        ids.add(addShot(p, spec, r, exec, taken: taken));
      } on CommandError catch (e) {
        throw CommandError('shots[$i]: ${e.message}');
      }
      cur = cur + durOf(i) - (i < n - 1 ? overlaps[i] : 0);
    }

    // Transitions.
    final main = p.main;
    for (int i = 0; i < n - 1; i++) {
      final t = trans[i];
      if (t == null || t['type'] == 'cut') continue;
      final type = t['type'] as String;
      final out = main.requireLayer(ids[i]), inc = main.requireLayer(ids[i + 1]);
      final d = (t['duration'] as num).toDouble();
      final params = <String, dynamic>{...t, 'overlap': overlaps[i]}..remove('between');
      // V2-lead: documentary transitions go through the full `transition` op (overlap handles, SFX on the cut, beat snap).
      if (DocTransitions.byId(type) != null) {
        final extra = <String, dynamic>{...t}..remove('between')..remove('type')..remove('duration')..remove('overlap');
        exec({'op': 'transition', 'from': out.id, 'to': inc.id, 'type': type, 'duration': d, if (extra.isNotEmpty) 'params': extra});
        r.log.add('Transition $type between ${out.id} and ${inc.id}');
        continue;
      }
      final fn = TransitionRegistry.lookup(type);
      if (fn != null) {
        fn(main, out, inc, params);
        r.log.add('Transition $type between ${out.id} and ${inc.id}');
        continue;
      }
      final preset = fallbackPreset(type);
      if (preset == null) {
        final reg = TransitionRegistry.names;
        throw CommandError('Unknown transition "$type". Use cut, ${reg.isEmpty ? '' : '${reg.join(', ')}, '}${MotionPresets.transitions.join(', ')}');
      }
      MotionPresets.animate(main, inc, preset, isIn: true, duration: math.max(d, main.frameDuration * 2));
      r.log.add('Transition $type (${preset == type ? '' : '$preset, '}animate_in) on ${inc.id}');
    }
    r.log.add('Sequence: ${ids.length} shots, ${p.main.layerById(ids.first)!.start.toStringAsFixed(2)}–${p.main.layerById(ids.last)!.end.toStringAsFixed(2)} s');
  }

  // ------------------------------------------------------------- summary

  /// Shots for the AI project summary.
  static List<Map<String, dynamic>> summary(Project p) {
    String f(double v) => v.toStringAsFixed(2);
    final out = <Map<String, dynamic>>[];
    for (final e in p.seqShots.entries) {
      final v = e.value;
      if (v is! Map) continue;
      final l = p.main.layerById(e.key);
      final spec = v['spec'] is Map ? v['spec'] as Map : const {};
      out.add({
        'id': e.key,
        if (l != null) 'name': l.name,
        if (l != null) 'start': f(l.start),
        if (l != null) 'end': f(l.end),
        if (spec['style'] != null) 'style': spec['style'],
        if (spec['plate'] != null) 'plate': spec['plate'],
        if (v['layers'] is Map) 'layers': v['layers'],
        if (v['hero'] != null) 'hero': v['hero'],
        if (v['camera'] is List) 'camera': [for (final m in v['camera'] as List) if (m is Map) '${m['move']}${m['target'] == null ? '' : '→${m['target']}'}'],
      });
    }
    out.sort((a, b) => double.parse('${a['start'] ?? 0}').compareTo(double.parse('${b['start'] ?? 0}')));
    return out;
  }

  // ------------------------------------------------- default layer timing

  /// Components that are a whole set / backdrop: without a duration they
  /// span the rest of the comp. Pop-up overlays keep 5 s.
  static const fullSpanComponents = {
    'map', 'tv_frame', 'glass_screen', 'room', 'board', 'map_fly', 'route_follow', 'silhouette_crowd', 'poster', 'plaque', 'article',
  };

  /// `add_component` defaults: start 0 (not the playhead); set components
  /// last to the end of the comp (or shot) when no duration is given.
  static Map<String, dynamic> componentDefaults(Composition comp, Map<String, dynamic> c) {
    if (c['start'] != null && c['duration'] != null) return c;
    final out = Map<String, dynamic>.from(c);
    final hadStart = c['start'] != null;
    out['start'] ??= 0.0;
    if (out['duration'] == null && !hadStart && fullSpanComponents.contains('${c['type']}')) {
      final st = (out['start'] as num).toDouble();
      out['duration'] = math.max(comp.frameDuration, comp.duration - st);
    }
    return out;
  }
}
