import 'dart:convert';
import 'dart:math' as math;

import '../model/anim_prop.dart';
import '../model/camera.dart';
import '../model/easing.dart';
import '../model/effects_catalog.dart';
import '../model/layer.dart';
import '../model/project.dart';
import '../presets/camera_presets.dart';
import '../presets/components.dart';
import '../presets/motion_presets.dart';
import 'fx_commands.dart'; // FX (Agent B)
import '../engine/precomp.dart'; // PRECOMP (Agent L)
import 'precomp_commands.dart'; // PRECOMP (Agent L)

/// Thrown when a command is invalid. The message is written so an AI agent
/// can read it and correct its next command.
class CommandError implements Exception {
  final String message;
  CommandError(this.message);
  @override
  String toString() => 'CommandError: $message';
}

class CommandResult {
  final List<String> createdIds = [];
  final List<String> log = [];

  Map<String, dynamic> toJson() => {'ok': true, 'created': createdIds, 'log': log};
}

/// Saves/restores a whole project as JSON. Used for undo and for making
/// command batches atomic (all-or-nothing).
class ProjectSnapshot {
  static String take(Project p) => jsonEncode(p.toJson());

  static void restore(Project p, String snapshot) {
    final r = Project.fromJson(jsonDecode(snapshot) as Map<String, dynamic>);
    p.name = r.name;
    p.media
      ..clear()
      ..addAll(r.media);
    p.main = r.main;
    // PRECOMP (Agent L): nested comps are part of every snapshot.
    p.comps
      ..clear()
      ..addAll(r.comps);
    if (p.editCompId != null && p.comps[p.editCompId] == null) p.editCompId = null;
    Precomp.touch();
  }
}

/// The edit-command layer. Every change to a project — from the UI or from
/// the AI agent — is a JSON command like:
///
///   {"op": "set_keyframe", "target": "L1", "prop": "position",
///    "time": 2.0, "value": [960, 540, 0], "ease": "easy_ease"}
///
/// See docs/EDIT_COMMANDS.md for the full list.
class EditCommands {
  static const ops = [
    'add_layer', 'remove_layer', 'duplicate_layer', 'update_layer', 'reorder_layer',
    'trim_layer', 'split_layer', 'set_property', 'set_keyframe', 'remove_keyframe',
    'clear_keyframes', 'set_ease', 'add_effect', 'remove_effect', 'set_effect_param',
    'set_camera_mode', 'camera_move', 'parallax_rig', 'set_comp', 'batch',
    'animate_in', 'animate_out', 'apply_style', 'add_mask', 'update_mask', 'remove_mask',
    'add_component', 'replace_media',
    ...PrecompCommands.ops, // PRECOMP (Agent L)
  ];

  /// Runs one command (or a batch). If anything fails the project is
  /// restored to exactly how it was before, and a [CommandError] is thrown.
  static CommandResult runAtomic(Project project, Map<String, dynamic> cmd, {double now = 0}) {
    final snap = ProjectSnapshot.take(project);
    try {
      final r = CommandResult();
      _run(project, cmd, now, r);
      Precomp.touch(); // PRECOMP (Agent L)
      return r;
    } catch (e) {
      ProjectSnapshot.restore(project, snap);
      if (e is CommandError) rethrow;
      throw CommandError(e is ArgumentError ? '${e.message}' : e.toString());
    }
  }

  /// Parses JSON text: a single command object, a list, or {"commands": [...]}.
  static Map<String, dynamic> parse(String text) {
    final decoded = jsonDecode(text);
    if (decoded is List) return {'op': 'batch', 'commands': decoded};
    if (decoded is Map<String, dynamic>) {
      if (!decoded.containsKey('op') && decoded['commands'] is List) {
        return {'op': 'batch', 'commands': decoded['commands']};
      }
      return decoded;
    }
    throw CommandError('Expected a JSON object or list of commands');
  }

  static void _run(Project project, Map<String, dynamic> c, double now, CommandResult r) {
    final op = c['op'];
    if (op is! String) throw CommandError('Missing "op". Valid ops: ${ops.join(', ')}');
    if (PrecompCommands.scoped(project, c, (c2) => _run(project, c2, now, r))) return; // PRECOMP (Agent L): in_comp
    final comp = project.editComp; // PRECOMP (Agent L): the comp being edited (main unless a precomp is open)
    switch (op) {
      case 'batch':
        final list = c['commands'];
        if (list is! List) throw CommandError('batch needs "commands": [...]');
        for (int i = 0; i < list.length; i++) {
          try {
            _run(project, Map<String, dynamic>.from(list[i] as Map), now, r);
          } on CommandError catch (e) {
            throw CommandError('commands[$i] (${(list[i] as Map)['op']}): ${e.message}');
          }
        }
        break;

      case 'add_layer':
        _addLayer(project, c, now, r);
        break;

      case 'remove_layer':
        final l = _layer(comp, c['layer']);
        comp.layers.remove(l);
        for (final o in comp.layers) {
          if (o.parentId == l.id) o.parentId = null;
        }
        r.log.add('Removed ${l.name}');
        break;

      case 'duplicate_layer':
        final l = _layer(comp, c['layer']);
        final id = (c['new_id'] as String?) ?? Ids.next('L');
        _checkNewId(comp, id);
        final d = l.copy(newId: id)..name = '${l.name} copy';
        comp.layers.insert(comp.indexOf(l.id), d);
        r.createdIds.add(id);
        break;

      case 'update_layer':
        _updateLayer(project, _layer(comp, c['layer']), c);
        break;

      case 'reorder_layer':
        final l = _layer(comp, c['layer']);
        final idx = _int(c, 'index');
        comp.layers.remove(l);
        comp.layers.insert(idx.clamp(0, comp.layers.length), l);
        break;

      case 'trim_layer':
        final l = _layer(comp, c['layer']);
        final newIn = _optNum(c, 'in');
        final newOut = _optNum(c, 'out');
        final end = newOut ?? l.end;
        if (newIn != null) {
          final dt = newIn - l.start;
          l.sourceIn += dt * l.speed;
          l.start = newIn; // keyframes stay where they are in comp time
        }
        final dur = end - l.start;
        if (dur < comp.frameDuration) throw CommandError('trim leaves layer "${l.id}" with no duration');
        l.duration = dur;
        if (l.sourceIn < -1e-6) {
          if (l.type == LayerType.video) throw CommandError('trim goes before the start of the source media');
          l.sourceIn = 0;
        }
        break;

      case 'split_layer':
        final l = _layer(comp, c['layer']);
        final t = _optNum(c, 'time') ?? now;
        if (t <= l.start + 1e-6 || t >= l.end - 1e-6) {
          throw CommandError('split time $t is outside layer "${l.id}" (${l.start}..${l.end})');
        }
        final id = (c['new_id'] as String?) ?? Ids.next('L');
        _checkNewId(comp, id);
        final b = l.copy(newId: id)..name = '${l.name} (2)';
        b.sourceIn = l.sourceTimeAt(t);
        b.start = t;
        b.duration = l.end - t;
        l.duration = t - l.start;
        comp.layers.insert(comp.indexOf(l.id), b);
        r.createdIds.add(id);
        break;

      case 'set_property':
        final p = _prop(comp, c);
        _write(p.prop, p.component, now, c['value'], keyframe: false, ease: null);
        break;

      case 'set_keyframe':
        final p = _prop(comp, c);
        final t = _optNum(c, 'time') ?? now;
        _write(p.prop, p.component, t, c['value'], keyframe: true, ease: _ease(c['ease']));
        break;

      case 'remove_keyframe':
        final p = _prop(comp, c);
        final t = _optNum(c, 'time') ?? now;
        if (!p.prop.removeKeyframe(t)) throw CommandError('No keyframe on "${c['prop']}" at $t');
        break;

      case 'clear_keyframes':
        final p = _prop(comp, c);
        p.prop.clearKeyframes(_optNum(c, 'time') ?? now);
        break;

      case 'set_ease':
        final p = _prop(comp, c);
        final t = _optNum(c, 'time') ?? now;
        final k = p.prop.keyframeAt(t);
        if (k == null) throw CommandError('No keyframe on "${c['prop']}" at $t');
        k.easing = _ease(c['ease']) ?? Easing.easyEase;
        break;

      case 'add_effect':
        final l = _layer(comp, c['layer']);
        final type = c['effect'] as String? ?? '';
        final id = (c['id'] as String?) ?? Ids.next('fx');
        final lenient = contractEffects.contains(type);
        final e = lenient && EffectsCatalog.byType(type) == null ? Effect(id: id, type: type) : EffectsCatalog.create(type, id);
        final params = c['params'];
        if (params is Map) {
          params.forEach((k, v) {
            final ap = e.params[k];
            final values = FxCommands.effectValue(type, '$k', v) ?? _paramValues(type, '$k', v); // FX (Agent B): "#hex" / option names
            if (ap == null) {
              if (!lenient) throw CommandError('Effect "$type" has no param "$k". Params: ${e.params.keys.join(', ')}');
              e.params['$k'] = AnimProp(values);
            } else {
              ap.staticValue = _fitList(ap, values);
            }
          });
        }
        l.effects.add(e);
        r.createdIds.add(id);
        break;

      case 'remove_effect':
        final l = _layer(comp, c['layer']);
        final e = _effect(l, c['effect']);
        l.effects.remove(e);
        break;

      case 'set_effect_param':
        final l = _layer(comp, c['layer']);
        final e = _effect(l, c['effect']);
        final key = c['param'] as String? ?? '';
        final ap = e.params[key];
        if (ap == null) throw CommandError('Effect "${e.type}" has no param "$key". Params: ${e.params.keys.join(', ')}');
        final t = _optNum(c, 'time');
        _write(ap, null, t ?? now, FxCommands.effectValue(e.type, key, c['value']) ?? c['value'], // FX (Agent B)
            keyframe: t != null, ease: _ease(c['ease']));
        break;

      case 'set_camera_mode':
        try {
          comp.camera.mode = cameraModeFromName('${c['mode']}');
        } on FormatException catch (e) {
          throw CommandError('${e.message}. Use "off", "2d" or "3d"');
        }
        break;

      case 'camera_move':
        final preset = c['preset'] as String? ?? '';
        CameraPresets.apply(
          comp,
          preset,
          start: _optNum(c, 'start') ?? now,
          duration: _optNum(c, 'duration') ?? 3,
          amount: _optNum(c, 'amount'),
          ease: _ease(c['ease']) ?? Easing.easyEase,
          direction: c['direction'] as String? ?? 'left',
        );
        _extendComp(comp, (_optNum(c, 'start') ?? now) + (_optNum(c, 'duration') ?? 3));
        break;

      case 'parallax_rig':
        final ids = (c['layers'] as List?)?.map((e) => '$e').toList();
        if (ids == null || ids.isEmpty) throw CommandError('parallax_rig needs "layers": [backId, ..., frontId]');
        for (final id in ids) {
          _layer(comp, id);
        }
        CameraPresets.parallaxRig(
          comp,
          ids,
          depthStep: _optNum(c, 'depth') ?? 500,
          push: _optNum(c, 'push') ?? 350,
          start: _optNum(c, 'start') ?? now,
          duration: _optNum(c, 'duration') ?? 4,
          ease: _ease(c['ease']) ?? Easing.easyEase,
        );
        break;

      case 'animate_in':
      case 'animate_out':
        final l = _layer(comp, c['layer']);
        var preset = c['preset'] as String? ?? 'fade';
        if (!MotionPresets.transitions.contains(preset) && contractTransitions.containsKey(preset)) {
          preset = contractTransitions[preset]!; // renderer transition not on this build yet
        }
        MotionPresets.animate(comp, l, preset, isIn: op == 'animate_in', duration: _optNum(c, 'duration') ?? 0.6);
        break;

      case 'apply_style':
        final ids = (c['layers'] as List?)?.map((e) => '$e').toList();
        r.log.addAll(MotionPresets.applyStyle(comp, c['style'] as String? ?? '', layerIds: ids));
        break;

      case 'add_mask':
        final l = _layer(comp, c['layer']);
        final id = (c['id'] as String?) ?? Ids.next('mask');
        final shape = c['shape'] as String? ?? 'ellipse';
        if (shape != 'ellipse' && shape != 'rect') throw CommandError('Mask shape must be "ellipse" or "rect"');
        final m = MotionPresets.newMask(l, id, shape: shape, invert: c['invert'] == true);
        for (final k in ['center', 'size', 'feather']) {
          if (c[k] != null) m.props[k]!.staticValue = _fitList(m.props[k]!, _values(c[k]));
        }
        l.masks.add(m);
        r.createdIds.add(id);
        break;

      case 'update_mask':
        final l = _layer(comp, c['layer']);
        final m = _mask(l, c['mask']);
        if (c['shape'] != null) m.shape = c['shape'] == 'rect' ? 'rect' : 'ellipse';
        if (c['invert'] != null) m.invert = c['invert'] == true;
        break;

      case 'remove_mask':
        final l = _layer(comp, c['layer']);
        l.masks.remove(_mask(l, c['mask']));
        break;

      case 'replace_media':
        // Swap a layer's photo/video, keeping its on-screen size and position.
        final l = _layer(comp, c['layer']);
        final m = project.media['${c['media']}'];
        if (m == null) throw CommandError('No media "${c['media']}"');
        if (l.width > 0 && m.width > 0) {
          final k = l.width / m.width;
          final sc = l.prop(Props.scale);
          List<double> scaled(List<double> v) => [v[0] * k, v[1] * k, v[2]];
          sc.staticValue = scaled(sc.staticValue);
          for (final kf in sc.keyframes) {
            kf.value = scaled(kf.value);
          }
          final an = l.prop(Props.anchor);
          List<double> anc(List<double> v) => [v[0] / k, v[1] / k, v[2]];
          an.staticValue = anc(an.staticValue);
          for (final kf in an.keyframes) {
            kf.value = anc(kf.value);
          }
        }
        l.mediaId = m.id;
        l.width = m.width;
        l.height = m.height;
        if (m.type == MediaType.image && l.type == LayerType.video) l.type = LayerType.image;
        break;

      case 'add_component':
        final cmds = Components.build(project, c, now);
        for (int i = 0; i < cmds.length; i++) {
          try {
            _run(project, cmds[i], now, r);
          } on CommandError catch (e) {
            throw CommandError('component ${c['type']}: ${e.message}');
          }
        }
        break;

      // PRECOMP (Agent L) >>>
      case 'add_comp':
      case 'precompose':
      case 'unprecompose':
      case 'open_comp':
      case 'set_active_comp':
      case 'remove_comp':
        PrecompCommands.run(project, c, now, r);
        break;
      // <<< PRECOMP (Agent L)

      case 'set_comp':
        if (c['name'] != null) comp.name = '${c['name']}';
        if (c['width'] != null) comp.width = _num(c, 'width');
        if (c['height'] != null) comp.height = _num(c, 'height');
        if (c['fps'] != null) comp.fps = _num(c, 'fps').clamp(1, 120).toDouble();
        if (c['duration'] != null) comp.duration = math.max(comp.frameDuration, _num(c, 'duration'));
        if (c['background'] != null) comp.background = _color(c['background']);
        FxCommands.applyComp(comp, c); // FX (Agent B): motion_blur
        PrecompCommands.afterSetComp(project, comp); // PRECOMP (Agent L): comp layers follow the size
        break;

      default:
        throw CommandError('Unknown op "$op". Valid ops: ${ops.join(', ')}');
    }
  }

  // ---------------------------------------------------------------- layers

  static void _addLayer(Project project, Map<String, dynamic> c, double now, CommandResult r) {
    final comp = project.editComp; // PRECOMP (Agent L)
    final LayerType type;
    try {
      type = layerTypeFromName('${c['type']}');
    } on FormatException catch (e) {
      throw CommandError('${e.message}. Use video, image, text, solid, shape, null, audio or comp');
    }
    final id = (c['id'] as String?) ?? Ids.next('L');
    _checkNewId(comp, id);
    final start = _optNum(c, 'start') ?? now;

    MediaAsset? media;
    if (type == LayerType.video || type == LayerType.image || type == LayerType.audio) {
      final mid = c['media'] as String?;
      media = mid == null ? null : project.media[mid];
      if (media == null) {
        throw CommandError('add_layer ${type.name} needs "media" = an imported media id. '
            'Available: ${project.media.values.map((m) => '${m.id} (${m.type.name})').join(', ')}');
      }
      final expected = switch (type) {
        LayerType.video => MediaType.video,
        LayerType.audio => MediaType.audio,
        _ => MediaType.image,
      };
      if (media.type != expected && !(type == LayerType.audio && media.type == MediaType.video)) {
        throw CommandError('Media "${media.id}" is ${media.type.name}, not ${expected.name}');
      }
    }

    final child = type == LayerType.comp ? PrecompCommands.childFor(project, comp, c) : null; // PRECOMP (Agent L)
    double w, h;
    if (type == LayerType.audio) {
      w = 100;
      h = 100;
    } else if (child != null) {
      // PRECOMP (Agent L): a comp layer is the size of its comp.
      w = child.width;
      h = child.height;
    } else if (media != null) {
      w = media.width;
      h = media.height;
    } else if (type == LayerType.text) {
      w = _optNum(c, 'width') ?? comp.width * 0.8;
      h = _optNum(c, 'height') ?? 220;
    } else if (type == LayerType.nullObject) {
      w = 100;
      h = 100;
    } else if (type == LayerType.shape) {
      w = _optNum(c, 'width') ?? 400;
      h = _optNum(c, 'height') ?? 400;
    } else {
      w = _optNum(c, 'width') ?? comp.width;
      h = _optNum(c, 'height') ?? comp.height;
    }

    double duration;
    final sourceIn = _optNum(c, 'source_in') ?? 0;
    if (c['duration'] != null) {
      duration = _num(c, 'duration');
    } else if (type == LayerType.video || type == LayerType.audio) {
      duration = math.max(comp.frameDuration, media!.duration - sourceIn);
    } else if (child != null) {
      duration = math.max(comp.frameDuration, child.duration - sourceIn); // PRECOMP (Agent L)
    } else {
      duration = 5;
    }

    final layer = Layer(
      id: id,
      name: c['name'] as String? ?? media?.name ?? _defaultName(type),
      type: type,
      start: start,
      duration: duration,
      width: w,
      height: h,
      sourceIn: sourceIn,
      is3D: c['is3d'] == true,
      mediaId: media?.id,
      color: c['color'] != null ? _color(c['color']) : 0xFF3D5AFE,
      text: type == LayerType.text ? TextData() : null,
    );
    layer.prop(Props.position).staticValue = [comp.width / 2, comp.height / 2, 0];

    // Fit media into the frame (contain by default).
    final fit = c['fit'] as String? ?? (media != null && type != LayerType.audio ? 'contain' : 'none');
    if (fit != 'none') {
      final sx = comp.width / w, sy = comp.height / h;
      final s = (fit == 'cover' ? math.max(sx, sy) : math.min(sx, sy)) * 100;
      layer.prop(Props.scale).staticValue = [s, s, 100];
    }
    if (type == LayerType.text) _applyText(layer, c);
    if (type == LayerType.shape) {
      layer.shape = ShapeData();
      _applyShape(layer, c, placeFromPoints: c['position'] == null);
    }
    if (c['parent'] != null) {
      final pid = '${c['parent']}';
      if (comp.layerById(pid) == null) throw CommandError('Parent "$pid" does not exist');
      layer.parentId = pid;
    }
    FxCommands.applyLayer(comp, layer, c); // FX (Agent B): matte, path
    if (child != null) PrecompCommands.applyLayer(project, comp, layer, c, child: child); // PRECOMP (Agent L)
    if (c['position'] != null) {
      final p = layer.prop(Props.position);
      p.staticValue = _fitList(p, _values(c['position']));
    }
    if (c['scale'] != null) {
      final p = layer.prop(Props.scale);
      p.staticValue = _fitList(p, _values(c['scale']));
    }

    final index = c['index'] is num ? (c['index'] as num).toInt().clamp(0, comp.layers.length) : 0;
    comp.layers.insert(index, layer);
    _extendComp(comp, layer.end);
    r.createdIds.add(id);
    r.log.add('Added ${layer.name} ($id)');
  }

  static void _updateLayer(Project project, Layer l, Map<String, dynamic> c) {
    final comp = project.editComp; // PRECOMP (Agent L)
    if (c['name'] != null) l.name = '${c['name']}';
    if (c['start'] != null) l.moveTo(_num(c, 'start'));
    if (c['duration'] != null) l.duration = math.max(comp.frameDuration, _num(c, 'duration'));
    if (c['source_in'] != null) l.sourceIn = math.max(0.0, _num(c, 'source_in'));
    if (c['speed'] != null) {
      final s = _num(c, 'speed');
      if (s <= 0 || s > 16) throw CommandError('speed must be between 0 and 16');
      l.speed = s;
    }
    if (c['is3d'] != null) l.is3D = c['is3d'] == true;
    if (c['visible'] != null) l.visible = c['visible'] == true;
    if (c['locked'] != null) l.locked = c['locked'] == true;
    if (c.containsKey('parent')) {
      final pid = c['parent'] as String?;
      if (pid != null) {
        final p = _layer(comp, pid);
        // Prevent parent loops.
        var cur = p;
        for (int i = 0; i < 32; i++) {
          if (cur.id == l.id) throw CommandError('Parenting "${l.id}" to "$pid" would create a loop');
          final next = cur.parentId == null ? null : comp.layerById(cur.parentId!);
          if (next == null) break;
          cur = next;
        }
      }
      l.parentId = pid;
    }
    if (c['blend'] != null) l.blendMode = '${c['blend']}';
    if (c['color'] != null) {
      if (l.type == LayerType.text) {
        l.text!.color = _color(c['color']);
      } else {
        l.color = _color(c['color']);
      }
    }
    if (c['width'] != null) l.width = _num(c, 'width');
    if (c['height'] != null) l.height = _num(c, 'height');
    if (l.type == LayerType.text) _applyText(l, c);
    if (l.type == LayerType.shape) _applyShape(l, c, placeFromPoints: false);
    FxCommands.applyLayer(comp, l, c); // FX (Agent B): matte, path
    PrecompCommands.applyLayer(project, comp, l, c); // PRECOMP (Agent L): loop, comp
    _extendComp(comp, l.end);
  }

  /// Shape params: kind, points [[x,y]...] (composition px), rings, closed, smooth,
  /// sides, inner, corner, fill, fill2, stroke, stroke_width, dash [on,off],
  /// arrow_start, arrow_end.
  static void _applyShape(Layer l, Map<String, dynamic> c, {required bool placeFromPoints}) {
    final sh = l.shape ??= ShapeData();
    if (c['kind'] != null) {
      final k = '${c['kind']}';
      const kinds = ['rect', 'ellipse', 'polygon', 'star', 'path', 'line'];
      if (!kinds.contains(k)) throw CommandError('Unknown shape kind "$k". Use ${kinds.join(', ')}');
      sh.kind = k == 'line' ? 'path' : k;
      if (k == 'line') sh.closed = false;
    }
    if (c['closed'] != null) sh.closed = c['closed'] == true;
    if (c['smooth'] != null) sh.smooth = c['smooth'] == true;
    if (c['sides'] != null) sh.sides = _int(c, 'sides').clamp(3, 64);
    if (c['inner'] != null) sh.inner = _num(c, 'inner').clamp(0.05, 1.0);
    if (c['corner'] != null) sh.corner = math.max(0.0, _num(c, 'corner'));
    if (c['fill'] != null) sh.fill = c['fill'] == 'none' ? 0 : _color(c['fill']);
    if (c['fill2'] != null) sh.fill2 = c['fill2'] == 'none' ? 0 : _color(c['fill2']);
    if (c['stroke'] != null) sh.stroke = c['stroke'] == 'none' ? 0 : _color(c['stroke']);
    if (c['stroke_width'] != null) sh.strokeWidth = math.max(0.0, _num(c, 'stroke_width'));
    if (c['dash'] != null) sh.dash = c['dash'] == 'none' ? [] : _values(c['dash']);
    if (c['arrow_start'] != null) sh.arrowStart = c['arrow_start'] == true;
    if (c['arrow_end'] != null) sh.arrowEnd = c['arrow_end'] == true;
    List<List<double>>? rings;
    if (c['points'] is List) {
      final pts = <double>[];
      for (final p in c['points'] as List) {
        final v = _values(p);
        if (v.length < 2) throw CommandError('Each point needs [x, y]');
        pts..add(v[0])..add(v[1]);
      }
      rings = [pts];
    } else if (c['rings'] is List) {
      rings = [for (final r in c['rings'] as List) _values(r)];
    }
    if (rings != null) {
      if (sh.kind != 'path') sh.kind = 'path';
      if (c['closed'] == null && c['points'] != null) sh.closed = false;
      // Fit the layer box around the points (+ room for stroke and arrowheads).
      double minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
      for (final r in rings) {
        for (int i = 0; i + 1 < r.length; i += 2) {
          minX = math.min(minX, r[i]);
          maxX = math.max(maxX, r[i]);
          minY = math.min(minY, r[i + 1]);
          maxY = math.max(maxY, r[i + 1]);
        }
      }
      if (!minX.isFinite) throw CommandError('Shape has no points');
      final pad = sh.strokeWidth * 3 + 8;
      sh.rings = [
        for (final r in rings) [for (int i = 0; i < r.length; i++) i.isEven ? r[i] - minX + pad : r[i] - minY + pad],
      ];
      l.width = maxX - minX + pad * 2;
      l.height = maxY - minY + pad * 2;
      l.prop(Props.anchor).staticValue = [l.width / 2, l.height / 2, 0];
      if (placeFromPoints) {
        l.prop(Props.position).staticValue = [minX - pad + l.width / 2, minY - pad + l.height / 2, 0];
      }
    }
  }

  static void _applyText(Layer l, Map<String, dynamic> c) {
    final t = l.text ??= TextData();
    final v = c['text'];
    if (v is String) t.text = v;
    if (v is Map) {
      final m = Map<String, dynamic>.from(v);
      if (m['text'] != null) t.text = '${m['text']}';
      if (m['font_size'] != null) t.fontSize = _num(m, 'font_size');
      if (m['color'] != null) t.color = _color(m['color']);
    }
    if (c['font_size'] != null) t.fontSize = _num(c, 'font_size');
    if (c['font_weight'] != null) t.fontWeight = _int(c, 'font_weight').clamp(100, 900);
    if (c['align'] != null) t.align = '${c['align']}';
    if (c['font_family'] != null) t.fontFamily = '${c['font_family']}';
    if (c['text_color'] != null) t.color = _color(c['text_color']);
    if (c['animator'] != null) {
      final a = '${c['animator']}';
      if (!TextAnimators.all.contains(a) && !contractAnimators.contains(a)) {
        throw CommandError('Unknown animator "$a". Available: ${TextAnimators.all.join(', ')}');
      }
      t.animator = a;
    }
    if (c['anim_duration'] != null) t.animDuration = _num(c, 'anim_duration').clamp(0.05, 30.0);
    if (c['highlight_color'] != null) t.highlightColor = _color(c['highlight_color']);
    if (c['box_color'] != null) t.boxColor = c['box_color'] == 'none' ? 0 : _color(c['box_color']);
    if (c['shadow'] != null) t.shadow = c['shadow'] == true;
    if (c['outline'] != null) t.outline = math.max(0.0, _num(c, 'outline'));
    FxCommands.applyText(t, c, _color); // FX (Agent B): extrude
    if (c['marks'] is List) {
      t.marks = [
        for (final m in c['marks'] as List)
          TextMark(
            '${(m as Map)['phrase']}',
            style: '${m['style'] ?? 'highlight'}',
            color: m['color'] != null
                ? _color(m['color'])
                : (m['style'] == 'circle' || m['style'] == 'underline')
                    ? 0xFFE53935
                    : 0xCCFFE14D,
            start: l.start + ((m['delay'] as num?) ?? 0.5).toDouble(),
            duration: ((m['duration'] as num?) ?? 0.6).toDouble(),
          ),
      ];
    }
    if (c['counter'] is Map) {
      final m = Map<String, dynamic>.from(c['counter'] as Map);
      t.counter = CounterSpec(
        from: (m['from'] as num? ?? 0).toDouble(),
        to: (m['to'] as num? ?? 100).toDouble(),
        start: l.start + (m['delay'] as num? ?? 0).toDouble(),
        duration: (m['duration'] as num? ?? 1.5).toDouble(),
        decimals: (m['decimals'] as num? ?? 0).toInt(),
        prefix: '${m['prefix'] ?? ''}',
        suffix: '${m['suffix'] ?? ''}',
      );
    }
    if (c['words'] is List) {
      t.words = [
        for (final w in c['words'] as List)
          WordTiming('${(w as Map)['w']}', (w['s'] as num).toDouble(), (w['e'] as num).toDouble()),
      ];
    }
    if (l.type == LayerType.text && c['name'] == null && v != null && l.name == 'Text') {
      l.name = t.text.length > 24 ? '${t.text.substring(0, 24)}…' : t.text;
    }
  }

  static String _defaultName(LayerType t) => switch (t) {
        LayerType.video => 'Video',
        LayerType.image => 'Image',
        LayerType.text => 'Text',
        LayerType.solid => 'Solid',
        LayerType.nullObject => 'Null',
        LayerType.audio => 'Audio',
        LayerType.shape => 'Shape',
        LayerType.comp => 'Comp', // PRECOMP (Agent L)
      };

  static void _extendComp(Composition comp, double end) {
    if (end > comp.duration) comp.duration = end;
  }

  // ------------------------------------------- V1 renderer contract (B/C)
  // Names from docs/V1_PLAN.md that the renderer branch (feat/fx) implements.
  // Until both branches are merged they are accepted and stored as plain data
  // so components and the AI can already use them; afterwards these lists are
  // harmless (known names take the normal path).
  static const contractEffects = [
    'silhouette', 'mono', 'duotone', 'edge_blur', 'curve', 'glass_frame', 'torn_edge',
    'particles', 'light_rays', 'sway', 'reveal', 'motion_blur',
  ];
  static const contractAnimators = ['random_pop', 'scramble'];

  /// Contract transitions → closest existing one when the renderer lacks it.
  static const contractTransitions = {
    'iris': 'zoom_in', 'ink': 'fade', 'smoke': 'blur', 'spin': 'spin', 'flash': 'fade', 'glitch_flash': 'whip',
  };
  static const contractProps = <String, List<double>>{'path_progress': [0]};

  /// String options of effect params, stored as their index.
  static const contractEnums = <String, Map<String, List<String>>>{
    'particles': {'kind': ['confetti', 'leaves', 'stars', 'rain', 'snow', 'smoke', 'dust', 'bokeh', 'streaks', 'birds', 'clouds']},
    'reveal': {'kind': ['iris', 'ink', 'smoke', 'wipe']},
    'torn_edge': {'side': ['top', 'bottom', 'left', 'right']},
  };

  /// Effect param value: numbers, "#RRGGBB" colours (→ [r, g, b]) or enum names (→ index).
  static List<double> _paramValues(String effect, String key, dynamic v) {
    if (v is bool) return [v ? 1 : 0];
    if (v is String) {
      final options = contractEnums[effect]?[key];
      if (options != null) {
        if (options.contains(v)) return [options.indexOf(v).toDouble()];
        throw CommandError('Effect "$effect": unknown $key "$v". Use ${options.join(', ')}');
      }
      final argb = _color(v);
      return [((argb >> 16) & 0xFF).toDouble(), ((argb >> 8) & 0xFF).toDouble(), (argb & 0xFF).toDouble()];
    }
    return _values(v);
  }

  // --------------------------------------------------------------- helpers

  static Layer _layer(Composition comp, dynamic id) {
    if (id is! String) throw CommandError('Missing "layer" id');
    final l = comp.layerById(id);
    if (l == null) {
      throw CommandError('No layer "$id". Layers: ${comp.layers.map((l) => '${l.id} (${l.name})').join(', ')}');
    }
    return l;
  }

  static void _checkNewId(Composition comp, String id) {
    if (comp.layerById(id) != null) throw CommandError('Layer id "$id" already exists');
  }

  static Effect _effect(Layer l, dynamic id) {
    final e = id is String ? l.effectById(id) : null;
    if (e == null) {
      throw CommandError('No effect "$id" on "${l.id}". Effects: ${l.effects.map((e) => '${e.id} (${e.type})').join(', ')}');
    }
    return e;
  }

  static Mask _mask(Layer l, dynamic id) {
    final m = id is String ? l.maskById(id) : null;
    if (m == null) {
      throw CommandError('No mask "$id" on "${l.id}". Masks: ${l.masks.map((m) => m.id).join(', ')}');
    }
    return m;
  }

  /// Resolves "target" (layer id or "camera") + "prop" (optionally "prop.x").
  static ({AnimProp prop, int? component}) _prop(Composition comp, Map<String, dynamic> c) {
    final target = c['target'] ?? c['layer'];
    final raw = c['prop'];
    if (raw is! String) throw CommandError('Missing "prop"');
    String key = raw;
    int? component;
    final dot = raw.indexOf('.');
    if (dot > 0) {
      key = raw.substring(0, dot);
      component = const {'x': 0, 'y': 1, 'z': 2}[raw.substring(dot + 1)];
      if (component == null) throw CommandError('Bad component in "$raw" (use .x, .y or .z)');
    }
    final Map<String, AnimProp> props;
    if (target == 'camera') {
      props = comp.camera.props;
    } else if (c['effect'] != null) {
      props = _effect(_layer(comp, target), c['effect']).params;
    } else if (c['mask'] != null) {
      props = _mask(_layer(comp, target), c['mask']).props;
    } else {
      props = _layer(comp, target).props;
    }
    var p = props[key];
    if (p == null && target != 'camera' && c['effect'] == null && c['mask'] == null && contractProps.containsKey(key)) {
      p = props[key] = AnimProp(List.of(contractProps[key]!)); // e.g. path_progress before the renderer merge
    }
    if (p == null) throw CommandError('No property "$key" on $target. Properties: ${props.keys.join(', ')}');
    if (component != null && component >= p.dims) throw CommandError('"$key" has only ${p.dims} dimension(s)');
    return (prop: p, component: component);
  }

  static void _write(AnimProp p, int? component, double t, dynamic value,
      {required bool keyframe, required Easing? ease}) {
    if (value == null) throw CommandError('Missing "value"');
    List<double> v;
    if (component != null) {
      v = p.valueAt(t);
      v[component] = _values(value).first;
    } else {
      v = _fitList(p, _values(value));
    }
    if (keyframe) {
      p.setKeyframe(t, v, easing: ease);
    } else {
      p.setValue(t, v);
    }
  }

  static List<double> _fitList(AnimProp p, List<double> v) {
    if (v.length == p.dims) return v;
    if (v.length == 1) return List.filled(p.dims, v[0]);
    if (v.length > p.dims) return v.sublist(0, p.dims);
    return [...v, ...p.staticValue.sublist(v.length)];
  }

  static List<double> _values(dynamic v) {
    if (v is num) return [v.toDouble()];
    if (v is List && v.isNotEmpty && v.every((e) => e is num)) {
      return v.map((e) => (e as num).toDouble()).toList();
    }
    throw CommandError('Value must be a number or list of numbers, got ${jsonEncode(v)}');
  }

  static Easing? _ease(dynamic e) {
    if (e == null) return null;
    try {
      return Easing.fromJson(e);
    } on FormatException catch (ex) {
      throw CommandError('${ex.message}. Use linear, hold, ease_in, ease_out, easy_ease, bounce, elastic, back '
          'or {"type":"bezier","x1":..,"y1":..,"x2":..,"y2":..}');
    }
  }

  static double _num(Map<String, dynamic> c, String k) {
    final v = c[k];
    if (v is num) return v.toDouble();
    throw CommandError('"$k" must be a number');
  }

  static double? _optNum(Map<String, dynamic> c, String k) => c[k] == null ? null : _num(c, k);

  static int _int(Map<String, dynamic> c, String k) => _num(c, k).round();

  static int _color(dynamic v) {
    if (v is int) return v;
    if (v is String) {
      var s = v.trim().replaceFirst('#', '').replaceFirst('0x', '');
      if (s.length == 6) s = 'FF$s';
      final n = int.tryParse(s, radix: 16);
      if (n != null && s.length == 8) return n;
    }
    throw CommandError('Bad color ${jsonEncode(v)} (use "#RRGGBB")');
  }
}
