// BULK (Agent N): multi-layer edit commands.
import 'dart:convert';
import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../engine/evaluator.dart';
import '../engine/precomp.dart';
import '../model/anim_prop.dart';
import '../model/layer.dart';
import '../model/project.dart';
import 'edit_commands.dart';

/// Bulk / multi-selection ops — Agent N. Called from [EditCommands] by a
/// one-line hook marked `BULK (Agent N)`. Every op works on the comp being
/// edited ([Project.editComp]); `in_comp` works as for any other op.
///
/// Layer sets (`layers`) are: a list of ids, the string `"selection"` (the
/// editor's current selection, see [selection]), or omitted with a `filter`:
/// `{type?: "text"|["text","image"], name_contains?, is3d?, in_range?: [t0, t1],
///   visible?, locked?, has_effect?, parent?}`. `layers` + `filter` = both must match.
///
/// - `for_layers` {layers | filter, command: {... "$layer" ...} | commands: [...], skip_errors?}
///   runs the command once per layer with `"$layer"` replaced by its id
///   (also inside strings, e.g. "new_id": "$layer_b"); `"$index"` → 0, 1, 2…,
///   `"$layer_start"` / `"$layer_end"` → the layer's times.
/// - `select` {layers | filter, mode?: replace|add|remove} — selects layers in the editor.
/// - `align` {layers, mode: left|center|right|top|middle|bottom, to?: selection|comp|"layer id", time?}
/// - `distribute` {layers, axis: horizontal|vertical, by?: center|gap, time?}
/// - `align_time` {layers, mode: start|end|playhead|stagger|sequence, time?, step? (s), frames?, gap?, order?: given|stack|time}
/// - `shift_time` {layers, by (s)}
/// - `transform_layers` {layers, move?: [dx, dy], scale? (factor), rotate? (deg), center?: [x, y], time?}
/// - `offset_property` {layer, prop ("position", "scale.x"…), by? | factor?, effect?} — relative change of the value and every keyframe
/// - `parent_layers` {layers, parent: id | null, keep_visual?: true}
/// - `group_layers` {layers, id?, name?} — a null parent at the selection centre; looks unchanged
/// - `paste_layers` {layers: [layer JSON], media?: [...], comps?: [...], time?, index?, offset?: [dx, dy]}
/// - `paste_effects` {layer, effects: [effect JSON], replace?: false}
/// - `paste_animation` {layer, props: {name: prop JSON}, from_start?: s}
class BulkCommands {
  static const ops = [
    'for_layers', 'select', 'align', 'distribute', 'align_time', 'shift_time', 'transform_layers',
    'offset_property', 'parent_layers', 'group_layers', 'paste_layers', 'paste_effects', 'paste_animation',
  ];

  /// The editor's selection (set by the editor before each command) for
  /// `layers: "selection"`.
  static List<String> selection = const [];

  static void run(Project p, Map<String, dynamic> c, double now, CommandResult r, void Function(Map<String, dynamic>) exec) {
    final comp = p.editComp;
    final t = _optNum(c, 'time') ?? now;
    switch (c['op']) {
      case 'for_layers':
        final cmds = expand(p, c);
        final skip = c['skip_errors'] == true;
        var done = 0;
        for (final (id, cmd) in cmds) {
          String? snap;
          if (skip) snap = ProjectSnapshot.take(p);
          try {
            exec(cmd);
            done++;
          } on CommandError catch (e) {
            if (!skip) throw CommandError('for_layers [$id] (${cmd['op']}): ${e.message}');
            ProjectSnapshot.restore(p, snap!);
            r.log.add('Skipped $id: ${e.message}');
          } on ArgumentError catch (e) {
            if (!skip) throw CommandError('for_layers [$id] (${cmd['op']}): ${e.message}');
            ProjectSnapshot.restore(p, snap!);
            r.log.add('Skipped $id: ${e.message}');
          }
        }
        r.log.add('for_layers: ran on $done layer(s)');
        break;
      case 'select':
        final ids = resolveLayers(p, c, allowEmpty: true);
        final mode = '${c['mode'] ?? 'replace'}';
        if (!const ['replace', 'add', 'remove'].contains(mode)) throw CommandError('select mode must be replace, add or remove');
        r.selection = ids;
        r.selectionMode = mode;
        r.log.add('Selected ${ids.length} layer(s)');
        break;
      case 'align':
        _align(comp, resolveLayers(p, c), c, t);
        break;
      case 'distribute':
        _distribute(comp, resolveLayers(p, c), c, t);
        break;
      case 'align_time':
        _alignTime(comp, resolveLayers(p, c), c, now);
        break;
      case 'shift_time':
        final ids = resolveLayers(p, c);
        var by = _num(c, 'by');
        final minStart = ids.map((id) => comp.layerById(id)!.start).reduce(math.min);
        if (minStart + by < 0) by = -minStart;
        for (final id in ids) {
          final l = comp.layerById(id)!;
          l.moveTo(l.start + by);
          _extend(comp, l.end);
        }
        break;
      case 'transform_layers':
        _transform(comp, resolveLayers(p, c), c, t);
        break;
      case 'offset_property':
        _offsetProperty(comp, c);
        break;
      case 'parent_layers':
        final ids = resolveLayers(p, c);
        final pid = c['parent'] as String?;
        if (pid != null && comp.layerById(pid) == null) throw CommandError('No parent layer "$pid"');
        for (final id in ids) {
          if (id == pid) continue;
          reparent(comp, comp.layerById(id)!, pid, t, keepVisual: c['keep_visual'] != false);
        }
        break;
      case 'group_layers':
        _group(p, comp, resolveLayers(p, c), c, t, r);
        break;
      case 'paste_layers':
        _paste(p, comp, c, now, r);
        break;
      case 'paste_effects':
        final l = _layer(comp, c['layer']);
        final list = c['effects'];
        if (list is! List) throw CommandError('paste_effects needs "effects": [effect JSON]');
        if (c['replace'] == true) l.effects.clear();
        for (final e in list) {
          final fx = Effect.fromJson(Map<String, dynamic>.from(e as Map));
          fx.id = Ids.next('fx');
          l.effects.add(fx);
          r.createdIds.add(fx.id);
        }
        break;
      case 'paste_animation':
        final l = _layer(comp, c['layer']);
        final props = c['props'];
        if (props is! Map) throw CommandError('paste_animation needs "props": {name: prop JSON}');
        final from = _optNum(c, 'from_start');
        final dt = from == null ? 0.0 : l.start - from;
        props.forEach((k, v) {
          final cur = l.props['$k'];
          if (cur == null) return; // e.g. volume on a text layer
          final src = AnimProp.fromJson(Map<String, dynamic>.from(v as Map));
          List<double> fit(List<double> x) => [for (int i = 0; i < cur.dims; i++) i < x.length ? x[i] : cur.staticValue[i]];
          final q = AnimProp(fit(src.staticValue), keyframes: [for (final kf in src.keyframes) kf.copy()..value = fit(kf.value)]);
          q.shift(dt);
          l.props['$k'] = q;
        });
        break;
      default:
        throw CommandError('Unknown bulk op "${c['op']}"');
    }
  }

  // ------------------------------------------------------------ layer sets

  /// Ids (in the order given, or comp order for a filter) of the layers
  /// named by `layers` and/or `filter`.
  static List<String> resolveLayers(Project p, Map<String, dynamic> c, {bool allowEmpty = false}) {
    final comp = p.editComp;
    final raw = c['layers'] ?? (c['layer'] is String && c['op'] != 'for_layers' ? [c['layer']] : null);
    final filter = c['filter'];
    List<String> ids;
    if (raw == 'selection' || raw == r'$selection') {
      ids = [for (final id in selection) if (comp.layerById(id) != null) id];
    } else if (raw is List) {
      ids = [];
      for (final e in raw) {
        final id = '$e';
        if (comp.layerById(id) == null) {
          throw CommandError('No layer "$id". Layers: ${comp.layers.map((l) => '${l.id} (${l.name})').join(', ')}');
        }
        if (!ids.contains(id)) ids.add(id);
      }
    } else if (raw == null) {
      if (filter == null) throw CommandError('${c['op']} needs "layers": [ids] | "selection", or a "filter"');
      ids = [for (final l in comp.layers) l.id];
    } else {
      throw CommandError('"layers" must be a list of layer ids or "selection"');
    }
    if (filter != null) {
      if (filter is! Map) throw CommandError('"filter" must be an object');
      final f = Map<String, dynamic>.from(filter);
      ids = [for (final id in ids) if (matches(comp.layerById(id)!, f)) id];
    }
    if (ids.isEmpty && !allowEmpty) throw CommandError('${c['op']}: no layers match');
    return ids;
  }

  /// Filter keys: type, name_contains, is3d, in_range [t0, t1], visible, locked, has_effect, parent.
  static bool matches(Layer l, Map<String, dynamic> f) {
    for (final k in f.keys) {
      const known = ['type', 'name_contains', 'is3d', 'in_range', 'visible', 'locked', 'has_effect', 'parent'];
      if (!known.contains(k)) throw CommandError('Unknown filter key "$k". Use ${known.join(', ')}');
    }
    final type = f['type'];
    if (type != null) {
      final types = type is List ? type.map((e) => '$e').toList() : ['$type'];
      final names = <LayerType>[];
      for (final n in types) {
        try {
          names.add(layerTypeFromName(n));
        } on FormatException catch (e) {
          throw CommandError('filter type: ${e.message}');
        }
      }
      if (!names.contains(l.type)) return false;
    }
    final name = f['name_contains'];
    if (name != null && !l.name.toLowerCase().contains('$name'.toLowerCase())) return false;
    if (f['is3d'] != null && l.is3D != (f['is3d'] == true)) return false;
    if (f['visible'] != null && l.visible != (f['visible'] == true)) return false;
    if (f['locked'] != null && l.locked != (f['locked'] == true)) return false;
    if (f['parent'] != null && l.parentId != '${f['parent']}') return false;
    final fx = f['has_effect'];
    if (fx != null && !l.effects.any((e) => e.type == '$fx')) return false;
    final range = f['in_range'];
    if (range != null) {
      if (range is! List || range.length != 2 || range.any((e) => e is! num)) {
        throw CommandError('in_range must be [t0, t1] in seconds');
      }
      final t0 = (range[0] as num).toDouble(), t1 = (range[1] as num).toDouble();
      if (!(l.end > t0 + 1e-9 && l.start < t1 - 1e-9)) return false;
    }
    return true;
  }

  /// `for_layers` → one (layer id, command) per layer, placeholders filled.
  static List<(String, Map<String, dynamic>)> expand(Project p, Map<String, dynamic> c) {
    final comp = p.editComp;
    final ids = resolveLayers(p, c);
    final one = c['command'];
    final many = c['commands'];
    final List<Map<String, dynamic>> templates;
    if (one is Map) {
      templates = [Map<String, dynamic>.from(one)];
    } else if (many is List && many.isNotEmpty && many.every((e) => e is Map)) {
      templates = [for (final m in many) Map<String, dynamic>.from(m as Map)];
    } else {
      throw CommandError('for_layers needs "command": {"op": ..., "layer": "\$layer", ...}');
    }
    for (final tpl in templates) {
      if (tpl['op'] is! String) throw CommandError('for_layers command needs an "op"');
    }
    final out = <(String, Map<String, dynamic>)>[];
    for (int i = 0; i < ids.length; i++) {
      final l = comp.layerById(ids[i])!;
      for (final tpl in templates) {
        out.add((l.id, Map<String, dynamic>.from(_fill(tpl, l, i) as Map)));
      }
    }
    return out;
  }

  static dynamic _fill(dynamic v, Layer l, int index) {
    if (v is String) {
      if (v == r'$index') return index;
      if (v == r'$layer_start') return l.start;
      if (v == r'$layer_end') return l.end;
      return v.contains(r'$layer') ? v.replaceAll(r'$layer', l.id) : v;
    }
    if (v is Map) return {for (final e in v.entries) '${e.key}': _fill(e.value, l, index)};
    if (v is List) return [for (final e in v) _fill(e, l, index)];
    return v;
  }

  // ------------------------------------------------------------- geometry

  /// Screen box (comp px, no camera) of [l] at [t]: [minX, minY, maxX, maxY].
  static List<double> bounds(Composition comp, Layer l, double t) {
    final m = Evaluator.worldMatrix(comp, l, t);
    double x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    for (final (x, y) in [(0.0, 0.0), (l.width, 0.0), (l.width, l.height), (0.0, l.height)]) {
      final v = m.transform3(Vector3(x, y, 0));
      x0 = math.min(x0, v.x);
      y0 = math.min(y0, v.y);
      x1 = math.max(x1, v.x);
      y1 = math.max(y1, v.y);
    }
    return [x0, y0, x1, y1];
  }

  /// Union box of several layers.
  static List<double> unionBounds(Composition comp, Iterable<Layer> layers, double t) {
    double x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    for (final l in layers) {
      final b = bounds(comp, l, t);
      x0 = math.min(x0, b[0]);
      y0 = math.min(y0, b[1]);
      x1 = math.max(x1, b[2]);
      y1 = math.max(y1, b[3]);
    }
    return [x0, y0, x1, y1];
  }

  static Matrix4 _parentMatrix(Composition comp, Layer l, double t) {
    final pid = l.parentId;
    final parent = pid == null ? null : comp.layerById(pid);
    return parent == null || parent.id == l.id ? Matrix4.identity() : Evaluator.worldMatrix(comp, parent, t);
  }

  /// Moves [l] by (dx, dy) on screen (comp px): position and every
  /// position keyframe, converted into the parent's space.
  static void moveWorld(Composition comp, Layer l, double dx, double dy, double t) {
    if (dx == 0 && dy == 0) return;
    final inv = Matrix4.copy(_parentMatrix(comp, l, t));
    var lx = dx, ly = dy;
    if (inv.invert() != 0) {
      final v = inv.transform3(Vector3(dx, dy, 0)) - inv.transform3(Vector3.zero());
      lx = v.x;
      ly = v.y;
    }
    final p = l.prop(Props.position);
    List<double> add(List<double> v) => [v[0] + lx, v[1] + ly, ...v.skip(2)];
    p.staticValue = add(p.staticValue);
    for (final k in p.keyframes) {
      k.value = add(k.value);
    }
  }

  /// Layers of [ids] in parent-before-child order, skipping (when
  /// [dropFollowers]) layers whose ancestor is also in the set — they follow it.
  static List<Layer> _ordered(Composition comp, List<String> ids, {bool dropFollowers = false}) {
    final set = ids.toSet();
    bool hasAncestorIn(Layer l) {
      var cur = l.parentId;
      for (int i = 0; i < 32 && cur != null; i++) {
        if (set.contains(cur)) return true;
        cur = comp.layerById(cur)?.parentId;
      }
      return false;
    }

    int depth(Layer l) {
      var d = 0;
      var cur = l.parentId;
      while (cur != null && d < 32) {
        d++;
        cur = comp.layerById(cur)?.parentId;
      }
      return d;
    }

    final layers = [for (final id in ids) comp.layerById(id)!];
    if (dropFollowers) layers.removeWhere(hasAncestorIn);
    final order = {for (int i = 0; i < layers.length; i++) layers[i].id: i};
    layers.sort((a, b) {
      final c = depth(a).compareTo(depth(b));
      return c != 0 ? c : order[a.id]!.compareTo(order[b.id]!);
    });
    return layers;
  }

  static bool _placeable(Layer l) => l.type != LayerType.audio;

  static void _align(Composition comp, List<String> ids, Map<String, dynamic> c, double t) {
    final mode = '${c['mode'] ?? c['edge'] ?? ''}';
    const modes = ['left', 'center', 'right', 'top', 'middle', 'bottom'];
    if (!modes.contains(mode)) throw CommandError('align mode must be one of ${modes.join(', ')}');
    final layers = [for (final l in _ordered(comp, ids)) if (_placeable(l)) l];
    if (layers.isEmpty) throw CommandError('align: nothing to align (audio layers have no position)');
    final to = '${c['to'] ?? (layers.length > 1 ? 'selection' : 'comp')}';
    List<double> ref;
    if (to == 'comp') {
      ref = [0, 0, comp.width, comp.height];
    } else if (to == 'selection') {
      ref = unionBounds(comp, layers, t);
    } else {
      final key = comp.layerById(to);
      if (key == null) throw CommandError('align "to" must be selection, comp or a layer id');
      ref = bounds(comp, key, t);
    }
    for (final l in layers) {
      if (l.id == to) continue;
      final b = bounds(comp, l, t); // after parents moved
      double dx = 0, dy = 0;
      switch (mode) {
        case 'left':
          dx = ref[0] - b[0];
        case 'center':
          dx = (ref[0] + ref[2]) / 2 - (b[0] + b[2]) / 2;
        case 'right':
          dx = ref[2] - b[2];
        case 'top':
          dy = ref[1] - b[1];
        case 'middle':
          dy = (ref[1] + ref[3]) / 2 - (b[1] + b[3]) / 2;
        case 'bottom':
          dy = ref[3] - b[3];
      }
      moveWorld(comp, l, dx, dy, t);
    }
  }

  static void _distribute(Composition comp, List<String> ids, Map<String, dynamic> c, double t) {
    final axis = '${c['axis'] ?? 'horizontal'}';
    if (axis != 'horizontal' && axis != 'vertical') throw CommandError('distribute axis must be horizontal or vertical');
    final by = '${c['by'] ?? 'center'}';
    if (by != 'center' && by != 'gap') throw CommandError('distribute "by" must be center or gap');
    final layers = [for (final l in _ordered(comp, ids, dropFollowers: true)) if (_placeable(l)) l];
    if (layers.length < 3) throw CommandError('distribute needs at least 3 layers');
    final h = axis == 'horizontal';
    final boxes = {for (final l in layers) l.id: bounds(comp, l, t)};
    double lo(Layer l) => boxes[l.id]![h ? 0 : 1];
    double hi(Layer l) => boxes[l.id]![h ? 2 : 3];
    double mid(Layer l) => (lo(l) + hi(l)) / 2;
    layers.sort((a, b) => mid(a).compareTo(mid(b)));
    final n = layers.length;
    final targets = <String, double>{}; // new low edge
    if (by == 'center') {
      final a = mid(layers.first), b = mid(layers.last);
      for (int i = 0; i < n; i++) {
        final l = layers[i];
        targets[l.id] = a + (b - a) * i / (n - 1) - (hi(l) - lo(l)) / 2;
      }
    } else {
      final span = hi(layers.last) - lo(layers.first);
      final total = layers.fold(0.0, (s, l) => s + hi(l) - lo(l));
      final gap = (span - total) / (n - 1);
      var x = lo(layers.first);
      for (final l in layers) {
        targets[l.id] = x;
        x += hi(l) - lo(l) + gap;
      }
    }
    for (final l in layers) {
      final d = targets[l.id]! - lo(l);
      moveWorld(comp, l, h ? d : 0, h ? 0 : d, t);
    }
  }

  static void _alignTime(Composition comp, List<String> ids, Map<String, dynamic> c, double now) {
    final mode = '${c['mode'] ?? 'start'}';
    const modes = ['start', 'end', 'playhead', 'stagger', 'sequence'];
    if (!modes.contains(mode)) throw CommandError('align_time mode must be one of ${modes.join(', ')}');
    final layers = [for (final id in ids) comp.layerById(id)!];
    final order = '${c['order'] ?? 'given'}';
    if (order == 'stack') {
      layers.sort((a, b) => comp.indexOf(a.id).compareTo(comp.indexOf(b.id)));
    } else if (order == 'time') {
      final idx = {for (int i = 0; i < layers.length; i++) layers[i].id: i};
      layers.sort((a, b) {
        final c = a.start.compareTo(b.start);
        return c != 0 ? c : idx[a.id]!.compareTo(idx[b.id]!);
      });
    } else if (order != 'given') {
      throw CommandError('align_time order must be given, stack or time');
    }
    final time = _optNum(c, 'time');
    switch (mode) {
      case 'start':
      case 'playhead':
        final at = math.max(0.0, time ?? now);
        for (final l in layers) {
          l.moveTo(at);
        }
      case 'end':
        final at = time ?? now;
        for (final l in layers) {
          l.moveTo(math.max(0.0, at - l.duration));
        }
      case 'stagger':
        final frames = _optNum(c, 'frames');
        final step = frames != null ? frames / comp.fps : (_optNum(c, 'step') ?? 0.2);
        final base = math.max(0.0, time ?? layers.first.start);
        for (int i = 0; i < layers.length; i++) {
          layers[i].moveTo(math.max(0.0, comp.snapToFrame(base + step * i)));
        }
      case 'sequence':
        final gap = _optNum(c, 'gap') ?? 0;
        var at = math.max(0.0, time ?? layers.first.start);
        for (final l in layers) {
          l.moveTo(at);
          at = l.end + gap;
        }
    }
    for (final l in layers) {
      _extend(comp, l.end);
    }
  }

  static void _transform(Composition comp, List<String> ids, Map<String, dynamic> c, double t) {
    final layers = [for (final l in _ordered(comp, ids, dropFollowers: true)) if (_placeable(l)) l];
    if (layers.isEmpty) return;
    final mv = c['move'] == null ? const [0.0, 0.0] : _list(c['move']);
    final k = _optNum(c, 'scale') ?? 1.0;
    if (k <= 0) throw CommandError('transform_layers scale must be > 0');
    final deg = _optNum(c, 'rotate') ?? 0.0;
    List<double> center;
    if (c['center'] != null) {
      center = _list(c['center']);
    } else {
      final b = unionBounds(comp, layers, t);
      center = [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2];
    }
    final rad = deg * math.pi / 180, cs = math.cos(rad), sn = math.sin(rad);
    for (final l in layers) {
      // Where the layer's position (its anchor) is on screen now.
      final pos = l.prop(Props.position).valueAt(t);
      final w = _parentMatrix(comp, l, t).transform3(Vector3(pos[0], pos[1], 0));
      final rx = w.x - center[0], ry = w.y - center[1];
      final nx = center[0] + (rx * cs - ry * sn) * k + mv[0];
      final ny = center[1] + (rx * sn + ry * cs) * k + mv[1];
      moveWorld(comp, l, nx - w.x, ny - w.y, t);
      if (k != 1) {
        final s = l.prop(Props.scale);
        List<double> f(List<double> v) => [v[0] * k, v[1] * k, ...v.skip(2)];
        s.staticValue = f(s.staticValue);
        for (final kf in s.keyframes) {
          kf.value = f(kf.value);
        }
      }
      if (deg != 0) {
        final r = l.prop(Props.rotation);
        List<double> f(List<double> v) => [v[0], v[1], v[2] + deg];
        r.staticValue = f(r.staticValue);
        for (final kf in r.keyframes) {
          kf.value = f(kf.value);
        }
      }
    }
  }

  static void _offsetProperty(Composition comp, Map<String, dynamic> c) {
    final l = _layer(comp, c['layer']);
    final raw = c['prop'];
    if (raw is! String) throw CommandError('offset_property needs "prop"');
    var key = raw;
    int? component;
    final dot = raw.indexOf('.');
    if (dot > 0) {
      key = raw.substring(0, dot);
      component = const {'x': 0, 'y': 1, 'z': 2}[raw.substring(dot + 1)];
      if (component == null) throw CommandError('Bad component in "$raw" (use .x, .y or .z)');
    }
    final Map<String, AnimProp> props;
    if (c['effect'] != null) {
      final e = l.effectById('${c['effect']}');
      if (e == null) throw CommandError('No effect "${c['effect']}" on "${l.id}"');
      props = e.params;
    } else {
      props = l.props;
    }
    final p = props[key];
    if (p == null) throw CommandError('No property "$key" on ${l.id}. Properties: ${props.keys.join(', ')}');
    if (component != null && component >= p.dims) throw CommandError('"$key" has only ${p.dims} dimension(s)');
    final by = c['by'] == null ? null : _list(c['by']);
    final factor = _optNum(c, 'factor');
    if (by == null && factor == null) throw CommandError('offset_property needs "by" (added) or "factor" (multiplied)');
    List<double> f(List<double> v) {
      final out = List.of(v);
      for (int i = 0; i < out.length; i++) {
        if (component != null && i != component) continue;
        // A single number applies to every component (scale: x and y, not z).
        final double? add = by == null
            ? null
            : component != null
                ? by[0]
                : by.length == 1
                    ? (key == Props.scale && i == 2 ? 0.0 : by[0])
                    : (i < by.length ? by[i] : 0.0);
        if (add != null) out[i] += add;
        if (factor != null && !(key == Props.scale && component == null && i == 2)) out[i] *= factor;
      }
      return out;
    }

    p.staticValue = f(p.staticValue);
    for (final kf in p.keyframes) {
      kf.value = f(kf.value);
    }
  }

  // ------------------------------------------------------------ parenting

  /// Sets [l]'s parent to [pid] (null = none). With [keepVisual] its
  /// position/rotation/scale (and their keyframes) are converted so the
  /// layer stays where it is on screen at time [t].
  static void reparent(Composition comp, Layer l, String? pid, double t, {bool keepVisual = true}) {
    if (pid != null) {
      var cur = comp.layerById(pid);
      for (int i = 0; i < 32 && cur != null; i++) {
        if (cur.id == l.id) throw CommandError('Parenting "${l.id}" to "$pid" would create a loop');
        cur = cur.parentId == null ? null : comp.layerById(cur.parentId!);
      }
    }
    if (l.parentId == pid) return;
    if (keepVisual) {
      final a = _parentMatrix(comp, l, t);
      final newParent = pid == null ? null : comp.layerById(pid);
      final b = newParent == null ? Matrix4.identity() : Matrix4.copy(Evaluator.worldMatrix(comp, newParent, t));
      if (b.invert() != 0) {
        final m = b.multiplied(a); // old parent space → new parent space
        final o = m.transform3(Vector3.zero());
        final ex = m.transform3(Vector3(1, 0, 0)) - o, ey = m.transform3(Vector3(0, 1, 0)) - o;
        final angle = math.atan2(ex.y, ex.x) * 180 / math.pi;
        final sx = ex.length;
        final det = ex.x * ey.y - ex.y * ey.x;
        final sy = (det < 0 ? -1 : 1) * ey.length;
        final pos = l.prop(Props.position);
        List<double> mp(List<double> v) {
          final w = m.transform3(Vector3(v[0], v[1], 0));
          return [w.x, w.y, ...v.skip(2)];
        }

        pos.staticValue = mp(pos.staticValue);
        for (final kf in pos.keyframes) {
          kf.value = mp(kf.value);
        }
        if ((sx - 1).abs() > 1e-9 || (sy - 1).abs() > 1e-9) {
          final s = l.prop(Props.scale);
          List<double> ms(List<double> v) => [v[0] * sx, v[1] * sy, ...v.skip(2)];
          s.staticValue = ms(s.staticValue);
          for (final kf in s.keyframes) {
            kf.value = ms(kf.value);
          }
        }
        if (angle.abs() > 1e-9) {
          final r = l.prop(Props.rotation);
          List<double> mr(List<double> v) => [v[0], v[1], v[2] + angle];
          r.staticValue = mr(r.staticValue);
          for (final kf in r.keyframes) {
            kf.value = mr(kf.value);
          }
        }
      }
    }
    l.parentId = pid;
  }

  static void _group(Project p, Composition comp, List<String> ids, Map<String, dynamic> c, double t, CommandResult r) {
    final layers = [for (final id in ids) comp.layerById(id)!];
    final placed = layers.where(_placeable).toList();
    final b = placed.isEmpty ? [comp.width / 2, comp.height / 2, comp.width / 2, comp.height / 2] : unionBounds(comp, placed, t);
    final id = (c['id'] as String?) ?? Ids.next('L');
    if (comp.layerById(id) != null) throw CommandError('Layer id "$id" already exists');
    final start = layers.map((l) => l.start).reduce(math.min);
    final end = layers.map((l) => l.end).reduce(math.max);
    final g = Layer(
      id: id,
      name: (c['name'] as String?) ?? 'Group',
      type: LayerType.nullObject,
      start: start,
      duration: math.max(comp.frameDuration, end - start),
      width: 100,
      height: 100,
    );
    g.prop(Props.position).staticValue = [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2, 0];
    final index = layers.map((l) => comp.indexOf(l.id)).reduce(math.min);
    comp.layers.insert(index, g);
    // Only the top of each chain gets the new parent; children keep theirs.
    final set = ids.toSet();
    for (final l in layers) {
      if (l.parentId != null && set.contains(l.parentId)) continue;
      reparent(comp, l, id, t);
    }
    r.createdIds.add(id);
    r.selection = [id];
    r.log.add('Grouped ${layers.length} layer(s) under null "${g.name}" ($id)');
  }

  // ------------------------------------------------------------- clipboard

  /// The clipboard command for copying [ids] of [comp]: a `paste_layers`
  /// command carrying the layers (comp order), the media and nested comps
  /// they use — so pasting works in another comp or project.
  static Map<String, dynamic> clipboardFor(Project p, Composition comp, Iterable<String> ids) {
    final set = ids.toSet();
    final layers = [for (final l in comp.layers) if (set.contains(l.id)) l];
    final media = <String, MediaAsset>{};
    final comps = <String, Composition>{};
    void collect(Layer l, int depth) {
      final m = l.mediaId == null ? null : p.media[l.mediaId!];
      if (m != null) media[m.id] = m;
      final cid = l.compId;
      if (l.type == LayerType.comp && cid != null && !comps.containsKey(cid) && depth < 16) {
        final child = p.compById(cid);
        if (child != null && child.id != p.main.id) {
          comps[cid] = child;
          for (final cl in child.layers) {
            collect(cl, depth + 1);
          }
        }
      }
    }

    for (final l in layers) {
      collect(l, 0);
    }
    return {
      'op': 'paste_layers',
      'layers': [for (final l in layers) l.toJson()],
      if (media.isNotEmpty) 'media': [for (final m in media.values) m.toJson()],
      if (comps.isNotEmpty) 'comps': [for (final k in comps.values) k.toJson()],
      'from_comp': comp.id,
    };
  }

  static void _paste(Project p, Composition comp, Map<String, dynamic> c, double now, CommandResult r) {
    final list = c['layers'];
    if (list is! List || list.isEmpty) throw CommandError('paste_layers needs "layers": [layer JSON]');
    for (final m in (c['media'] as List? ?? const [])) {
      final a = MediaAsset.fromJson(Map<String, dynamic>.from(m as Map));
      p.media.putIfAbsent(a.id, () => a);
    }
    for (final k in (c['comps'] as List? ?? const [])) {
      final child = Composition.fromJson(jsonDecode(jsonEncode(k)) as Map<String, dynamic>);
      if (p.compById(child.id) == null) p.comps[child.id] = child;
    }
    final layers = <Layer>[];
    for (final j in list) {
      try {
        layers.add(Layer.fromJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>));
      } catch (e) {
        throw CommandError('paste_layers: bad layer JSON ($e)');
      }
    }
    final idMap = <String, String>{};
    for (final l in layers) {
      idMap[l.id] = Ids.next('L');
    }
    for (final l in layers) {
      if (l.mediaId != null && p.media[l.mediaId!] == null) {
        throw CommandError('paste_layers: layer "${l.name}" uses media "${l.mediaId}" which is not in this project');
      }
      if (l.type == LayerType.comp) {
        final cid = l.compId;
        if (cid == null || p.compById(cid) == null) throw CommandError('paste_layers: comp "$cid" of "${l.name}" is missing');
        try {
          Precomp.checkCanNest(p, comp.id, cid);
        } on PrecompError catch (e) {
          throw CommandError(e.message);
        }
      }
      l.id = idMap[l.id]!;
      final pid = l.parentId;
      if (pid != null) l.parentId = idMap[pid] ?? (comp.layerById(pid) != null ? pid : null);
      final m = l.matte;
      if (m != null) {
        final mid = idMap[m.layerId] ?? (comp.layerById(m.layerId) != null ? m.layerId : null);
        l.matte = mid == null ? null : LayerMatte(mid, mode: m.mode);
      }
    }
    final time = _optNum(c, 'time');
    if (time != null) {
      final first = layers.map((l) => l.start).reduce(math.min);
      final dt = math.max(0.0, time) - first;
      for (final l in layers) {
        l.moveTo(l.start + dt);
      }
    }
    if (c['offset'] != null) {
      final o = _list(c['offset']);
      for (final l in layers) {
        final pos = l.prop(Props.position);
        List<double> f(List<double> v) => [v[0] + o[0], v[1] + (o.length > 1 ? o[1] : 0), ...v.skip(2)];
        pos.staticValue = f(pos.staticValue);
        for (final kf in pos.keyframes) {
          kf.value = f(kf.value);
        }
      }
    }
    final index = c['index'] is num ? (c['index'] as num).toInt().clamp(0, comp.layers.length) : 0;
    comp.layers.insertAll(index, layers);
    for (final l in layers) {
      _extend(comp, l.end);
      r.createdIds.add(l.id);
    }
    r.selection = [for (final l in layers) l.id];
    r.log.add('Pasted ${layers.length} layer(s)');
    final problems = Precomp.validate(p);
    if (problems.isNotEmpty) throw CommandError(problems.first);
  }

  // --------------------------------------------------------------- helpers

  static void _extend(Composition comp, double end) {
    if (end > comp.duration) comp.duration = end;
  }

  static Layer _layer(Composition comp, dynamic id) {
    if (id is! String) throw CommandError('Missing "layer" id');
    final l = comp.layerById(id);
    if (l == null) throw CommandError('No layer "$id". Layers: ${comp.layers.map((l) => l.id).join(', ')}');
    return l;
  }

  static List<double> _list(dynamic v) {
    if (v is num) return [v.toDouble()];
    if (v is List && v.isNotEmpty && v.every((e) => e is num)) return [for (final e in v) (e as num).toDouble()];
    throw CommandError('Expected a number or list of numbers, got ${jsonEncode(v)}');
  }

  static double _num(Map<String, dynamic> c, String k) {
    final v = c[k];
    if (v is num) return v.toDouble();
    throw CommandError('"$k" must be a number');
  }

  static double? _optNum(Map<String, dynamic> c, String k) => c[k] == null ? null : _num(c, k);
}
