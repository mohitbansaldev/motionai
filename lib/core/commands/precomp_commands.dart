import 'dart:convert';
import 'dart:math' as math;

import '../engine/precomp.dart';
import '../model/anim_prop.dart';
import '../model/camera.dart';
import '../model/layer.dart';
import '../model/project.dart';
import 'edit_commands.dart';

/// Nested compositions (precomps) — Agent L. Called from [EditCommands] by
/// one-line hooks marked `PRECOMP (Agent L)`.
///
/// Ops:
/// - `add_comp` {id?, name?, width?, height?, duration?, fps?, background?} → a new empty comp
/// - `precompose` {layers: [ids] | layer, name?, id? (comp id), layer_id?, move_attributes?: bool}
///   moves the layers into a new comp and puts one comp layer in their place;
///   the picture stays identical. `move_attributes: false` (one layer only) keeps
///   the layer's transform, effects, masks and keyframes on the comp layer and
///   puts only its content (at rest) inside a comp of the layer's size.
/// - `unprecompose` {layer, keep_comp?: bool, force?: bool} puts a comp layer's
///   layers back in its place (inverse of precompose).
/// - `open_comp` / `set_active_comp` {comp: id | "main"} — the comp edit commands work on.
/// - `remove_comp` {comp} — deletes an unused comp.
/// - any op + `in_comp: id` runs that op inside another comp.
/// - `add_layer` {type: "comp", comp: id, loop?} · `update_layer` {loop?, comp?}
class PrecompCommands {
  static const ops = ['add_comp', 'precompose', 'unprecompose', 'open_comp', 'set_active_comp', 'remove_comp'];

  /// Suffix of the hidden parent stand-ins precompose makes for parents that
  /// stay outside (unprecompose maps them back to the real parent).
  static const proxySuffix = '~parent';

  static void run(Project p, Map<String, dynamic> c, double now, CommandResult r) {
    switch (c['op']) {
      case 'add_comp':
        _addComp(p, c, r);
        break;
      case 'precompose':
        _precompose(p, c, r);
        break;
      case 'unprecompose':
        _unprecompose(p, c, r);
        break;
      case 'open_comp':
      case 'set_active_comp':
        final id = c['comp'] ?? c['id'];
        if (id == null || id == 'main') {
          p.editCompId = null;
          break;
        }
        final comp = _comp(p, id);
        p.editCompId = comp.id == p.main.id ? null : comp.id;
        r.log.add('Editing comp ${comp.name} (${comp.id})');
        break;
      case 'remove_comp':
        final comp = _comp(p, c['comp'] ?? c['id']);
        if (comp.id == p.main.id) throw CommandError('The main comp cannot be removed');
        final users = Precomp.usersOf(p, comp.id);
        if (users.isNotEmpty) {
          throw CommandError('Comp "${comp.id}" is used by layer(s) ${users.map((u) => u.$2.id).join(', ')}; remove them first');
        }
        p.comps.remove(comp.id);
        if (p.editCompId == comp.id) p.editCompId = null;
        break;
    }
  }

  /// `in_comp`: runs [body] with [Project.editComp] set to that comp. Returns
  /// false (and does nothing) when the command has no `in_comp`.
  static bool scoped(Project p, Map<String, dynamic> c, void Function(Map<String, dynamic>) body) {
    final id = c['in_comp'];
    if (id == null) return false;
    final target = _comp(p, id);
    final prev = p.editCompId;
    p.editCompId = target.id == p.main.id ? null : target.id;
    try {
      body(Map<String, dynamic>.from(c)..remove('in_comp'));
    } finally {
      p.editCompId = prev;
    }
    return true;
  }

  // ------------------------------------------------------- add_layer hooks

  /// The child comp of an `add_layer {type: comp, comp: id}`; checks loops.
  static Composition childFor(Project p, Composition host, Map<String, dynamic> c) {
    final id = c['comp'] ?? c['comp_id'];
    if (id == null) {
      throw CommandError('add_layer comp needs "comp": a comp id. Comps: ${_compList(p)}');
    }
    final child = _comp(p, id);
    _checkNest(p, host, child);
    return child;
  }

  /// `add_layer` / `update_layer` keys for comp layers: comp, loop.
  static void applyLayer(Project p, Composition host, Layer l, Map<String, dynamic> c, {Composition? child}) {
    if (child != null) {
      l.compId = child.id;
      if (c['name'] == null) l.name = child.name;
    } else if (c['comp'] != null && l.type == LayerType.comp) {
      final nc = _comp(p, c['comp']);
      _checkNest(p, host, nc);
      l.compId = nc.id;
      l.width = nc.width;
      l.height = nc.height;
    }
    if (c['loop'] != null && l.type == LayerType.comp) l.loop = c['loop'] == true;
  }

  /// After `set_comp`: comp layers showing [comp] take its new size.
  static void afterSetComp(Project p, Composition comp) {
    for (final (_, l) in Precomp.usersOf(p, comp.id)) {
      l.width = comp.width;
      l.height = comp.height;
    }
  }

  // -------------------------------------------------------------- add_comp

  static void _addComp(Project p, Map<String, dynamic> c, CommandResult r) {
    final base = p.editComp;
    final id = (c['id'] as String?) ?? Ids.next('comp');
    if (p.compById(id) != null) throw CommandError('Comp id "$id" already exists');
    double n(String k, double d) {
      final v = c[k];
      if (v == null) return d;
      if (v is! num || v <= 0) throw CommandError('"$k" must be a positive number');
      return v.toDouble();
    }

    final comp = Composition(
      id: id,
      name: (c['name'] as String?) ?? 'Comp ${p.comps.length + 1}',
      width: n('width', base.width),
      height: n('height', base.height),
      fps: n('fps', base.fps).clamp(1, 120).toDouble(),
      duration: n('duration', base.duration),
      background: c['background'] == null ? 0x00000000 : _color(c['background']),
    );
    p.comps[id] = comp;
    r.createdIds.add(id);
    r.log.add('Added comp ${comp.name} ($id)');
  }

  // ------------------------------------------------------------ precompose

  static void _precompose(Project p, Map<String, dynamic> c, CommandResult r) {
    final host = p.editComp;
    final raw = c['layers'] ?? (c['layer'] != null ? [c['layer']] : null);
    if (raw is! List || raw.isEmpty) throw CommandError('precompose needs "layers": [layer ids]');
    final ids = <String>{};
    for (final e in raw) {
      final id = '$e';
      if (host.layerById(id) == null) {
        throw CommandError('No layer "$id". Layers: ${host.layers.map((l) => '${l.id} (${l.name})').join(', ')}');
      }
      ids.add(id);
    }
    final compId = (c['id'] as String?) ?? Ids.next('comp');
    if (p.compById(compId) != null) throw CommandError('Comp id "$compId" already exists');
    final moveAttributes = c['move_attributes'] != false;
    if (!moveAttributes) {
      if (ids.length != 1) throw CommandError('move_attributes: false works on exactly one layer');
      _precomposeLeave(p, host, host.requireLayer(ids.single), compId, c, r);
      return;
    }

    // Track mattes travel with their layers (both directions), or the look changes.
    var grew = true;
    while (grew) {
      grew = false;
      for (final l in host.layers) {
        final m = l.matte;
        if (m == null || m.layerId == l.id || host.layerById(m.layerId) == null) continue;
        if (ids.contains(l.id) && !ids.contains(m.layerId)) {
          ids.add(m.layerId);
          grew = true;
          r.log.add('Also moved matte layer ${m.layerId}');
        } else if (!ids.contains(l.id) && ids.contains(m.layerId)) {
          ids.add(l.id);
          grew = true;
          r.log.add('Also moved ${l.id} (uses ${m.layerId} as matte)');
        }
      }
    }

    final layerId = (c['layer_id'] as String?) ?? Ids.next('L');
    if (host.layerById(layerId) != null && !ids.contains(layerId)) throw CommandError('Layer id "$layerId" already exists');
    final name = (c['name'] as String?) ?? 'Precomp ${p.comps.length + 1}';
    final moved = [for (final l in host.layers) if (ids.contains(l.id)) l];
    final firstIndex = host.layers.indexWhere((l) => ids.contains(l.id));
    final start = moved.map((l) => l.start).reduce(math.min);
    final end = moved.map((l) => l.end).reduce(math.max);

    final child = Composition(
      id: compId,
      name: name,
      width: host.width,
      height: host.height,
      fps: host.fps,
      duration: math.max(host.duration, end),
      background: 0x00000000,
      motionBlur: host.motionBlur,
    );
    // 3D layers keep seeing the same 3D camera (2D cameras stay on the comp layer).
    if (host.camera.mode == CameraMode.threeD && moved.any((l) => l.is3D)) child.camera = host.camera.copy();

    // Parents that stay outside: hidden stand-ins inside the child.
    final proxies = <String, Layer>{};
    String? proxyFor(String hostId, int depth) {
      if (ids.contains(hostId)) return hostId;
      final have = proxies[hostId];
      if (have != null) return have.id;
      final src = host.layerById(hostId);
      if (src == null || depth > 32) return null;
      final px = src.copy(newId: '$hostId$proxySuffix')
        ..type = LayerType.nullObject
        ..name = '${src.name} (parent)'
        ..mediaId = null
        ..text = null
        ..shape = null
        ..matte = null
        ..compId = null
        ..parentId = null;
      px.effects.clear();
      px.masks.clear();
      proxies[hostId] = px;
      final pp = src.parentId;
      if (pp != null && pp != src.id) px.parentId = proxyFor(pp, depth + 1);
      return px.id;
    }

    for (final l in moved) {
      final pid = l.parentId;
      if (pid != null && !ids.contains(pid)) {
        l.parentId = proxyFor(pid, 0);
        r.log.add('${l.name} keeps following ${host.layerById(pid)?.name ?? pid}');
      }
    }
    host.layers.removeWhere((l) => ids.contains(l.id));
    for (final o in host.layers) {
      if (o.parentId != null && ids.contains(o.parentId)) {
        r.log.add('${o.name} lost its parent ${o.parentId} (moved into $name)');
        o.parentId = null;
      }
    }
    child.layers
      ..addAll(moved)
      ..addAll(proxies.values);
    p.comps[compId] = child;

    final layer = Layer(
      id: layerId,
      name: name,
      type: LayerType.comp,
      start: start,
      duration: end - start,
      width: host.width,
      height: host.height,
      sourceIn: start,
      compId: compId,
    );
    layer.prop(Props.position).staticValue = [host.width / 2, host.height / 2, 0];
    host.layers.insert(firstIndex.clamp(0, host.layers.length), layer);
    r.createdIds
      ..add(compId)
      ..add(layerId);
    r.log.add('Precomposed ${moved.length} layer(s) into $name ($compId), comp layer $layerId');
    _checkDepth(p);
  }

  static void _checkDepth(Project p) {
    final problems = Precomp.validate(p);
    if (problems.isNotEmpty) throw CommandError(problems.first);
  }

  /// "Leave all attributes": the layer itself becomes the comp layer (same id,
  /// transform, effects, masks, matte, parent, path, keyframes); only its
  /// content goes into a comp of the layer's size.
  static void _precomposeLeave(Project p, Composition host, Layer l, String compId, Map<String, dynamic> c, CommandResult r) {
    final name = (c['name'] as String?) ?? '${l.name} comp';
    final child = Composition(
      id: compId,
      name: name,
      width: l.width,
      height: l.height,
      fps: host.fps,
      duration: math.max(host.duration, l.end),
      background: 0x00000000,
    );
    final inner = Layer(
      id: l.id,
      name: l.name,
      type: l.type,
      start: l.start,
      duration: l.duration,
      width: l.width,
      height: l.height,
      sourceIn: l.sourceIn,
      speed: l.speed,
      mediaId: l.mediaId,
      text: l.text?.copy(),
      shape: l.shape?.copy(),
      color: l.color,
      compId: l.compId,
      loop: l.loop,
    );
    inner.prop(Props.position).staticValue = [l.width / 2, l.height / 2, 0];
    for (final k in [Props.volume, Props.trim]) {
      final v = l.props[k];
      if (v != null) inner.props[k] = v.copy();
    }
    child.layers.add(inner);
    p.comps[compId] = child;

    l
      ..type = LayerType.comp
      ..compId = compId
      ..loop = false
      ..mediaId = null
      ..text = null
      ..shape = null
      ..sourceIn = l.start
      ..speed = 1
      ..name = name;
    l.props.remove(Props.trim);
    r.createdIds.add(compId);
    r.log.add('Precomposed ${inner.name} into $name ($compId); ${l.id} is now its comp layer');
    _checkDepth(p);
  }

  // ---------------------------------------------------------- unprecompose

  static void _unprecompose(Project p, Map<String, dynamic> c, CommandResult r) {
    final host = p.editComp;
    final id = c['layer'];
    final cl = id is String ? host.layerById(id) : null;
    if (cl == null || cl.type != LayerType.comp) {
      throw CommandError('unprecompose needs "layer": a comp layer. Comp layers: '
          '${host.layers.where((l) => l.type == LayerType.comp).map((l) => l.id).join(', ')}');
    }
    final child = Precomp.childOf(p, cl);
    if (child == null) throw CommandError('Comp "${cl.compId}" of layer "${cl.id}" does not exist');
    if ((cl.speed - 1).abs() > 1e-9) throw CommandError('Set the comp layer speed back to 1 before unprecomposing');
    final force = c['force'] == true;

    final problems = <String>[];
    final op = cl.prop(Props.opacity);
    if (op.isAnimated || (op.staticValue[0] - 100).abs() > 1e-9) problems.add('opacity');
    if (cl.effects.isNotEmpty) problems.add('effects');
    if (cl.masks.isNotEmpty) problems.add('masks');
    if (cl.matte != null) problems.add('track matte');
    if (cl.blendMode != 'normal') problems.add('blend mode');
    if (cl.loop) problems.add('loop (only the first pass comes out)');
    if (child.camera.mode != CameraMode.off && jsonEncode(child.camera.toJson()) != jsonEncode(host.camera.toJson())) {
      problems.add("the inner comp's own camera");
    }
    if (problems.isNotEmpty && !force) {
      throw CommandError('unprecompose would lose the comp layer\'s ${problems.join(', ')}; '
          'pass "force": true to do it anyway');
    }

    // The comp layer's transform → a null parent (skipped when it is neutral).
    Layer? xform;
    if (!_neutralTransform(cl, child)) {
      const keys = [Props.anchor, Props.position, Props.scale, Props.rotation, Props.pathProgress];
      xform = Layer(
        id: Ids.next('L'),
        name: '${cl.name} transform',
        type: LayerType.nullObject,
        start: cl.start,
        duration: cl.duration,
        width: cl.width,
        height: cl.height,
        is3D: cl.is3D,
        parentId: cl.parentId,
        props: {for (final k in keys) if (cl.props[k] != null) k: cl.props[k]!.copy()},
        path: cl.path?.copy(),
      );
      if (child.width != cl.width || child.height != cl.height) {
        // The renderer stretches the child to the layer box.
        final sx = cl.width / child.width, sy = cl.height / child.height;
        xform.props[Props.scale] = _scaled(xform.prop(Props.scale), sx, sy);
      }
    }

    final dt = cl.start - cl.sourceIn;
    final winS = cl.start, winE = cl.end;
    final referenced = <String>{
      for (final l in child.layers) ...[if (l.parentId != null) l.parentId!, if (l.matte != null) l.matte!.layerId],
    };
    final idMap = <String, String>{};
    final out = <Layer>[];
    for (final src in child.layers) {
      // Stand-ins for parents that stayed outside → the real parent again.
      if (src.id.endsWith(proxySuffix) && src.type == LayerType.nullObject) {
        final orig = src.id.substring(0, src.id.length - proxySuffix.length);
        if (orig != cl.id && host.layerById(orig) != null) {
          idMap[src.id] = orig;
          continue;
        }
      }
      final l = src.copy();
      l.moveTo(l.start + dt);
      final overlaps = l.end > winS + 1e-9 && l.start < winE - 1e-9;
      if (!overlaps) {
        if (!referenced.contains(src.id)) {
          r.log.add('Dropped ${l.name} (outside the comp layer\'s time)');
          continue;
        }
      } else {
        if (l.start < winS) {
          final d = winS - l.start;
          l.sourceIn += d * l.speed;
          l.duration -= d;
          l.start = winS;
        }
        if (l.end > winE) l.duration = winE - l.start;
      }
      if (host.layerById(l.id) != null && l.id != cl.id) {
        final nid = Ids.next('L');
        idMap[l.id] = nid;
        l.id = nid;
      }
      out.add(l);
    }
    for (final l in out) {
      final pid = l.parentId;
      if (pid != null && idMap.containsKey(pid)) l.parentId = idMap[pid];
      final m = l.matte;
      if (m != null && idMap.containsKey(m.layerId)) l.matte = LayerMatte(idMap[m.layerId]!, mode: m.mode);
      if (l.parentId == null && xform != null) l.parentId = xform.id;
    }

    final idx = host.indexOf(cl.id);
    host.layers
      ..removeAt(idx)
      ..insertAll(idx, [...out, if (xform != null) xform]);
    for (final o in host.layers) {
      if (o.parentId == cl.id) {
        o.parentId = xform?.id;
        if (xform == null) r.log.add('${o.name} lost its parent ${cl.id}');
      }
      if (o.matte?.layerId == cl.id) {
        o.matte = null;
        r.log.add('${o.name} lost its track matte ${cl.id}');
      }
    }
    if (c['keep_comp'] != true && Precomp.usersOf(p, child.id).isEmpty && p.editCompId != child.id) {
      p.comps.remove(child.id);
    }
    r.createdIds.addAll(out.map((l) => l.id));
    r.log.add('Unprecomposed ${cl.name}: ${out.length} layer(s) back in ${host.name}');
  }

  static bool _neutralTransform(Layer l, Composition child) {
    if (l.is3D || l.parentId != null || (l.path != null && l.path!.points.isNotEmpty)) return false;
    if (l.width != child.width || l.height != child.height) return false;
    for (final k in [Props.anchor, Props.position, Props.scale, Props.rotation]) {
      if (l.prop(k).isAnimated) return false;
    }
    final a = l.prop(Props.anchor).staticValue, pos = l.prop(Props.position).staticValue;
    final s = l.prop(Props.scale).staticValue, rot = l.prop(Props.rotation).staticValue;
    bool near(double x, double y) => (x - y).abs() < 1e-6;
    return near(a[0], pos[0]) && near(a[1], pos[1]) && near(s[0], 100) && near(s[1], 100) && near(rot[2], 0);
  }

  static AnimProp _scaled(AnimProp p, double sx, double sy) {
    final q = p.copy();
    List<double> f(List<double> v) => [v[0] * sx, v[1] * sy, ...v.skip(2)];
    q.staticValue = f(q.staticValue);
    for (final k in q.keyframes) {
      k.value = f(k.value);
    }
    return q;
  }

  // --------------------------------------------------------------- helpers

  static void _checkNest(Project p, Composition host, Composition child) {
    try {
      Precomp.checkCanNest(p, host.id, child.id);
    } on PrecompError catch (e) {
      throw CommandError(e.message);
    }
  }

  static Composition _comp(Project p, dynamic id) {
    final c = id == null ? null : p.compById('$id');
    if (c == null) throw CommandError('No comp "$id". Comps: ${_compList(p)}');
    return c;
  }

  static String _compList(Project p) =>
      ['main (${p.main.name})', ...p.comps.values.map((c) => '${c.id} (${c.name})')].join(', ');

  static int _color(dynamic v) {
    if (v is int) return v;
    if (v is String) {
      if (v == 'none' || v == 'transparent') return 0;
      var s = v.trim().replaceFirst('#', '').replaceFirst('0x', '');
      if (s.length == 6) s = 'FF$s';
      final n = int.tryParse(s, radix: 16);
      if (n != null && s.length == 8) return n;
    }
    throw CommandError('Bad color ${jsonEncode(v)} (use "#RRGGBB")');
  }
}
