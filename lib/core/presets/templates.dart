import 'dart:convert';
import 'dart:math' as math;

import '../commands/edit_commands.dart';
import '../model/layer.dart';
import '../model/project.dart';
import 'components.dart';
import 'world_map.dart';

/// Starter templates: ready-made animated scenes built only from edit
/// commands, so they work without any media and stay fully editable.
class ProjectTemplate {
  final String id;
  final String name;
  final String subtitle;
  final double width, height;
  final double duration;
  final List<Map<String, dynamic>> Function(double w, double h) commands;
  const ProjectTemplate(this.id, this.name, this.subtitle, this.width, this.height, this.duration, this.commands);
}

class Templates {
  static final all = <ProjectTemplate>[
    ProjectTemplate('doc_intro', 'Documentary Intro', 'Cinematic 3D title, slow push', 1920, 1080, 7, (w, h) => [
          {'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'name': 'Background', 'color': '#0E1420', 'is3d': true, 'width': w * 1.6, 'height': h * 1.6},
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'light_leak', 'params': {'amount': 35, 'speed': 0.6}},
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'grain', 'params': {'amount': 22}},
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'vignette', 'params': {'amount': 70}},
          {'op': 'add_layer', 'type': 'text', 'id': 'title', 'text': 'THE FORGOTTEN FORT', 'font_size': 140, 'font_weight': 900, 'is3d': true, 'animator': 'fade_up', 'anim_duration': 1.6, 'start': 0.4, 'duration': 6.6},
          {'op': 'add_layer', 'type': 'text', 'id': 'sub', 'text': 'A documentary', 'font_size': 54, 'font_weight': 400, 'is3d': true, 'position': [w / 2, h / 2 + 130, 0], 'animator': 'typewriter', 'anim_duration': 1.2, 'start': 1.6, 'duration': 5.4, 'text_color': '#C9D1E0'},
          {'op': 'parallax_rig', 'layers': ['bg', 'sub', 'title'], 'depth': 450, 'push': 380, 'start': 0, 'duration': 7},
          {'op': 'animate_out', 'layer': 'title', 'preset': 'blur', 'duration': 0.8},
          {'op': 'animate_out', 'layer': 'sub', 'preset': 'fade', 'duration': 0.8},
        ]),
    ProjectTemplate('shorts_hook', 'Shorts Hook', 'Punchy 9:16 opener with shake', 1080, 1920, 4, (w, h) => [
          {'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'name': 'Background', 'color': '#1B0F3A'},
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'light_leak', 'params': {'amount': 60, 'speed': 2}},
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'gradient', 'params': {'amount': 50, 'top': 30}},
          {'op': 'add_layer', 'type': 'text', 'id': 'hook', 'text': 'YOU WON\'T BELIEVE THIS', 'font_size': 130, 'font_weight': 900, 'width': w * 0.9, 'height': 600, 'animator': 'word_pop', 'anim_duration': 0.9, 'highlight_color': '#FFD54F'},
          {'op': 'add_layer', 'type': 'text', 'id': 'cta', 'text': 'watch till the end', 'font_size': 56, 'box_color': '#CC000000', 'position': [w / 2, h * 0.72, 0], 'start': 1.2, 'duration': 2.8, 'animator': 'slide_up', 'anim_duration': 0.4},
          {'op': 'camera_move', 'preset': 'zoom_in_2d', 'start': 0, 'duration': 4, 'amount': 12},
          {'op': 'camera_move', 'preset': 'shake', 'start': 0.9, 'duration': 0.5, 'amount': 14},
        ]),
    ProjectTemplate('quote', 'Quote Card', 'Typewriter quote, warm grain', 1080, 1080, 6, (w, h) => [
          {'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'name': 'Background', 'color': '#2A1E14'},
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'grain', 'params': {'amount': 35}},
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'vignette', 'params': {'amount': 65}},
          {'op': 'add_layer', 'type': 'text', 'id': 'q', 'text': '"History is not the past. It is the present."', 'font_size': 72, 'font_weight': 600, 'width': w * 0.82, 'height': 500, 'animator': 'typewriter', 'anim_duration': 2.5, 'text_color': '#F6E7CF'},
          {'op': 'add_layer', 'type': 'text', 'id': 'a', 'text': '— Your Name', 'font_size': 44, 'position': [w / 2, h * 0.78, 0], 'start': 2.6, 'duration': 3.4, 'animator': 'fade_up', 'anim_duration': 0.8, 'text_color': '#D9B98C'},
          {'op': 'camera_move', 'preset': 'zoom_in_2d', 'start': 0, 'duration': 6, 'amount': 6},
        ]),
    ProjectTemplate('title_3d', '3D Title Orbit', 'Title floating in 3D space', 1920, 1080, 6, (w, h) => [
          {'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'name': 'Background', 'color': '#06080D'},
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'light_leak', 'params': {'amount': 25, 'speed': 1}},
          {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'MOTION AI', 'font_size': 220, 'font_weight': 900, 'is3d': true, 'animator': 'word_pop', 'anim_duration': 0.8},
          {'op': 'add_effect', 'layer': 't', 'effect': 'glow', 'params': {'amount': 55, 'radius': 24}},
          {'op': 'add_layer', 'type': 'text', 'id': 't2', 'text': 'create anything', 'font_size': 60, 'is3d': true, 'position': [w / 2, h / 2 + 170, -200], 'start': 0.8, 'duration': 5.2, 'animator': 'fade_up', 'text_color': '#3DD6E0'},
          {'op': 'camera_move', 'preset': 'orbit', 'start': 0, 'duration': 6, 'amount': 28},
        ]),
  ];
}

// ===========================================================================
// Scene templates (Agent G — library & templates): insertable at the playhead
// into the open project. Each template is a command list with slots (text,
// media, colour). Saved templates ("Save as template") carry layer JSON.
// ===========================================================================

/// One fillable value of a scene template.
class TemplateSlot {
  final String key, label;
  final String kind; // text | media | medias | color
  final dynamic initial; // text / '#RRGGBB' / media id (project id or lib:<id>) / list of ids
  final String media; // image | video | audio | any (media kinds)
  final int max; // medias: most items
  final String hint;
  const TemplateSlot(this.key, this.label, {this.kind = 'text', this.initial, this.media = 'any', this.max = 6, this.hint = ''});

  bool get isMedia => kind == 'media' || kind == 'medias';

  Map<String, dynamic> toJson() => {
        'key': key, 'label': label, 'kind': kind,
        if (initial != null) 'initial': initial,
        'media': media, 'max': max,
        if (hint.isNotEmpty) 'hint': hint,
      };

  static TemplateSlot fromJson(Map<String, dynamic> j) => TemplateSlot('${j['key']}', '${j['label'] ?? j['key']}',
      kind: '${j['kind'] ?? 'text'}', initial: j['initial'], media: '${j['media'] ?? 'any'}', max: (j['max'] as num? ?? 6).toInt(), hint: '${j['hint'] ?? ''}');

  TemplateSlot withInitial(dynamic v) => TemplateSlot(key, label, kind: kind, initial: v, media: media, max: max, hint: hint);
}

/// Values + helpers a built-in template's builder reads.
class TemplateCtx {
  final Project project;
  final double start;
  final Map<String, dynamic> values;
  final List<TemplateSlot> slots;
  TemplateCtx(this.project, this.start, this.values, this.slots);

  double get w => project.main.width;
  double get h => project.main.height;
  double t(num x) => start + x;

  dynamic _raw(String k) {
    final v = values[k];
    if (v != null && !(v is String && v.trim().isEmpty)) return v;
    for (final s in slots) {
      if (s.key == k) return s.initial;
    }
    return null;
  }

  String s(String k, [String d = '']) {
    final v = _raw(k);
    return v == null ? d : '$v';
  }

  double n(String k, double d) {
    final v = _raw(k);
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}'.trim()) ?? d;
  }

  /// Comma-separated text slot → list.
  List<String> list(String k) {
    final v = _raw(k);
    if (v is List) return [for (final e in v) if ('$e'.trim().isNotEmpty) '$e'.trim()];
    return '${v ?? ''}'.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  /// A project media item from a media slot (null when empty or unknown).
  MediaAsset? media(String k) {
    final v = _raw(k);
    final id = v is List ? (v.isEmpty ? null : '${v.first}') : v?.toString();
    return id == null ? null : project.media[id];
  }

  List<MediaAsset> medias(String k) {
    final v = _raw(k);
    final ids = v is List ? [for (final e in v) '$e'] : (v is String && v.isNotEmpty ? [v] : const <String>[]);
    return [for (final i in ids) if (project.media[i] != null) project.media[i]!];
  }

  List<String> mediaIds(String k) => [for (final m in medias(k)) m.id];

  /// add_layer for a photo/video scaled to [heightPx] (or cover the frame).
  Map<String, dynamic> mediaLayer(String id, MediaAsset m, {double? x, double? y, double? heightPx, double? widthPx, double st = 0, double du = 5, String? name}) {
    final double s;
    if (heightPx != null) {
      s = heightPx / math.max(1, m.height) * 100;
    } else if (widthPx != null) {
      s = widthPx / math.max(1, m.width) * 100;
    } else {
      s = math.max(w / math.max(1, m.width), h / math.max(1, m.height)) * 100;
    }
    return {
      'op': 'add_layer', 'type': m.type == MediaType.video ? 'video' : 'image', 'media': m.id, 'id': id, 'name': name ?? m.name,
      'start': t(st), 'duration': du, 'fit': 'none', 'position': [x ?? w / 2, y ?? h / 2, 0], 'scale': [s, s, 100],
    };
  }

  Map<String, dynamic> rect(String id, double rw, double rh, double x, double y, String fill,
          {String? fill2, String kind = 'rect', double st = 0, double du = 5, String? name, double corner = 0}) =>
      {
        'op': 'add_layer', 'type': 'shape', 'id': id, 'kind': kind, 'width': rw, 'height': rh, 'position': [x, y, 0],
        'fill': fill, 'fill2': ?fill2, 'corner': corner, 'start': t(st), 'duration': du, 'name': ?name,
      };

  Map<String, dynamic> kf(String id, String prop, num time, dynamic v, [String ease = 'easy_ease']) =>
      {'op': 'set_keyframe', 'target': id, 'prop': prop, 'time': t(time), 'value': v, 'ease': ease};
}

typedef TemplateBuilder = List<Map<String, dynamic>> Function(TemplateCtx c);

/// An insertable scene: built-in (command builder) or saved (layer JSON).
class SceneTemplate {
  final String id, name, category, subtitle;
  final double duration;
  final List<TemplateSlot> slots;
  final List<String> needsOps; // hidden unless EditCommands.ops has all of them
  final List<String> needsComponents; // hidden unless Components.types has all of them
  final double previewTime; // seconds after the start for the gallery thumbnail
  final TemplateBuilder? builder;
  // Saved templates.
  final List<Map<String, dynamic>> layers; // Layer.toJson(), times from 0, top first
  final Map<String, List<String>> slotLayers; // slot key → template layer ids
  final double width, height; // composition size it was made at
  final DateTime? created;

  const SceneTemplate({
    required this.id,
    required this.name,
    required this.category,
    this.subtitle = '',
    this.duration = 5,
    this.slots = const [],
    this.needsOps = const [],
    this.needsComponents = const [],
    this.previewTime = 1.2,
    this.builder,
    this.layers = const [],
    this.slotLayers = const {},
    this.width = 1920,
    this.height = 1080,
    this.created,
  });

  bool get saved => builder == null;

  /// False when the ops/components it needs are not on this build.
  bool get available => needsOps.every(EditCommands.ops.contains) && needsComponents.every(Components.types.contains);

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'category': category, 'subtitle': subtitle, 'duration': duration, 'preview': previewTime,
        'slots': [for (final s in slots) s.toJson()],
        'layers': layers,
        'slot_layers': slotLayers,
        'width': width, 'height': height,
        'created': (created ?? DateTime.now()).toIso8601String(),
      };

  static SceneTemplate fromJson(Map<String, dynamic> j) => SceneTemplate(
        id: '${j['id']}',
        name: '${j['name'] ?? 'My template'}',
        category: '${j['category'] ?? SceneTemplates.mine}',
        subtitle: '${j['subtitle'] ?? ''}',
        duration: (j['duration'] as num? ?? 5).toDouble(),
        previewTime: (j['preview'] as num? ?? 1).toDouble(),
        slots: [for (final s in (j['slots'] as List? ?? const [])) if (s is Map) TemplateSlot.fromJson(Map<String, dynamic>.from(s))],
        layers: [for (final l in (j['layers'] as List? ?? const [])) if (l is Map) Map<String, dynamic>.from(l)],
        slotLayers: {
          for (final e in (j['slot_layers'] as Map? ?? const {}).entries) '${e.key}': [for (final v in (e.value as List? ?? const [])) '$v'],
        },
        width: (j['width'] as num? ?? 1920).toDouble(),
        height: (j['height'] as num? ?? 1080).toDouble(),
        created: DateTime.tryParse('${j['created'] ?? ''}'),
      );

  SceneTemplate withSlots(List<TemplateSlot> s) => SceneTemplate(
        id: id, name: name, category: category, subtitle: subtitle, duration: duration, slots: s, needsOps: needsOps,
        needsComponents: needsComponents, previewTime: previewTime, builder: builder, layers: layers, slotLayers: slotLayers,
        width: width, height: height, created: created,
      );
}

/// Built-in scene templates, insertion and "save as template".
class SceneTemplates {
  static const mine = 'My templates';
  static const categories = ['Intros', 'Showcases', 'Transitions', 'Captions', 'Lower thirds', 'Endings', 'Maps', '3D'];

  /// Built-ins available on this build (gated templates hidden).
  static List<SceneTemplate> get available => [for (final t in builtIn) if (t.available) t];

  static SceneTemplate? byId(String id) {
    for (final t in builtIn) {
      if (t.id == id) return t;
    }
    return null;
  }

  // ------------------------------------------------------------ insertion

  /// The template's commands with fresh, unique layer ids, starting at [start].
  static List<Map<String, dynamic>> commands(Project p, SceneTemplate t, {double start = 0, Map<String, dynamic> values = const {}, String? prefix}) {
    final b = t.builder;
    if (b == null) throw CommandError('"${t.name}" is a saved template: use SceneTemplates.insert');
    final raw = b(TemplateCtx(p, start, values, t.slots));
    return prefixIds(raw, prefix ?? Ids.next('t'));
  }

  /// Inserts [t] at [start] (all-or-nothing). Media slot values must be
  /// project media ids (import library assets first).
  static CommandResult insert(Project p, SceneTemplate t, {double start = 0, Map<String, dynamic> values = const {}}) {
    if (!t.saved) {
      return EditCommands.runAtomic(p, {'op': 'batch', 'commands': commands(p, t, start: start, values: values)}, now: start);
    }
    final snap = ProjectSnapshot.take(p);
    try {
      return _insertLayers(p, t, start, values);
    } catch (e) {
      ProjectSnapshot.restore(p, snap);
      if (e is CommandError) rethrow;
      throw CommandError('$e');
    }
  }

  static const _refKeys = ['id', 'layer', 'target', 'parent', 'new_id', 'map', 'attach', 'cut_to', 'behind'];

  /// Gives every id the template defines (and component parts `<id>_x`) the
  /// [prefix], so a template can be inserted any number of times.
  static List<Map<String, dynamic>> prefixIds(List<Map<String, dynamic>> cmds, String prefix) {
    final defined = <String>{};
    final components = <String>{};
    void collect(Map c) {
      if (c['op'] == 'batch' && c['commands'] is List) {
        for (final x in c['commands'] as List) {
          if (x is Map) collect(x);
        }
      }
      final id = c['id'];
      if (id is String && (c['op'] == 'add_layer' || c['op'] == 'add_component')) defined.add(id);
      if (id is String && c['op'] == 'add_component') components.add(id);
      if (c['new_id'] is String) defined.add(c['new_id'] as String);
    }

    for (final c in cmds) {
      collect(c);
    }
    String fix(dynamic v) {
      if (v is! String || v == 'camera') return '$v';
      if (defined.contains(v) || components.any((k) => v.startsWith('${k}_'))) return '${prefix}_$v';
      return v;
    }

    Map<String, dynamic> one(Map c) {
      final out = <String, dynamic>{};
      final isLayerOp = c['op'] == 'add_layer' || c['op'] == 'add_component';
      c.forEach((k, v) {
        final key = '$k';
        if (key == 'commands' && v is List) {
          out[key] = [for (final x in v) if (x is Map) one(x)];
        } else if (key == 'id' && !isLayerOp) {
          out[key] = v; // effect / mask ids
        } else if (_refKeys.contains(key) && v is String) {
          out[key] = fix(v);
        } else if (key == 'layers' && v is List) {
          out[key] = [for (final x in v) fix(x)];
        } else if (key == 'bands' && v is Map) {
          out[key] = {for (final e in v.entries) fix(e.key): e.value};
        } else if (key == 'matte' && v is Map) {
          out[key] = {...Map<String, dynamic>.from(v), if (v['layer'] is String) 'layer': fix(v['layer'])};
        } else {
          out[key] = v;
        }
      });
      return out;
    }

    return [for (final c in cmds) one(c)];
  }

  static CommandResult _insertLayers(Project p, SceneTemplate t, double start, Map<String, dynamic> values) {
    final comp = p.main;
    final prefix = Ids.next('t');
    final idMap = {for (final l in t.layers) '${l['id']}': '${prefix}_${l['id']}'};
    final kx = comp.width / math.max(1, t.width), ky = comp.height / math.max(1, t.height);
    final k = math.min(kx, ky);
    final added = <Layer>[];
    for (final src in t.layers) {
      final j = jsonDecode(jsonEncode(src)) as Map<String, dynamic>;
      j['id'] = idMap['${src['id']}'];
      final pid = j['parentId'];
      if (pid != null) {
        if (idMap.containsKey(pid)) {
          j['parentId'] = idMap[pid];
        } else {
          j.remove('parentId');
        }
      }
      if (j['matte'] is Map) {
        final m = j['matte'] as Map;
        if (idMap.containsKey(m['layer'])) {
          m['layer'] = idMap[m['layer']];
        } else {
          j.remove('matte');
        }
      }
      final l = Layer.fromJson(j);
      final mid = l.mediaId;
      if (mid != null && p.media[mid] == null) {
        // Filled by a media slot below; otherwise this layer can't be shown.
        final slotted = t.slotLayers.values.any((ids) => ids.contains('${src['id']}'));
        if (!slotted) throw CommandError('Template layer "${l.name}" needs media that is not in this project');
      }
      l.moveTo(start + l.start);
      if (l.parentId == null && (kx - 1).abs() + (ky - 1).abs() > 1e-6) {
        final pos = l.prop(Props.position);
        List<double> mv(List<double> v) => [v[0] * kx, v[1] * ky, v.length > 2 ? v[2] : 0];
        pos.staticValue = mv(pos.staticValue);
        for (final f in pos.keyframes) {
          f.value = mv(f.value);
        }
        final sc = l.prop(Props.scale);
        List<double> sv(List<double> v) => [v[0] * k, v[1] * k, v.length > 2 ? v[2] : 100];
        sc.staticValue = sv(sc.staticValue);
        for (final f in sc.keyframes) {
          f.value = sv(f.value);
        }
      }
      added.add(l);
    }
    comp.layers.insertAll(0, added);
    final cmds = <Map<String, dynamic>>[];
    for (final s in t.slots) {
      final targets = [for (final id in t.slotLayers[s.key] ?? const <String>[]) if (idMap[id] != null) idMap[id]!];
      final v = values.containsKey(s.key) ? values[s.key] : s.initial;
      if (s.kind == 'text') {
        if (v is String) {
          for (final id in targets) {
            cmds.add({'op': 'update_layer', 'layer': id, 'text': v});
          }
        }
      } else if (s.isMedia) {
        final chosen = v is List ? (v.isEmpty ? null : '${v.first}') : (v is String && v.isNotEmpty ? v : null);
        for (final id in targets) {
          final l = comp.layerById(id)!;
          if (chosen != null && chosen != l.mediaId) {
            if (p.media[chosen] == null) throw CommandError('No media "$chosen" for "${s.label}"');
            cmds.add({'op': 'replace_media', 'layer': id, 'media': chosen});
          } else if (p.media[l.mediaId] == null) {
            throw CommandError('Pick media for "${s.label}"');
          }
        }
      } else if (s.kind == 'color' && v is String) {
        for (final id in targets) {
          cmds.add({'op': 'update_layer', 'layer': id, 'color': v});
        }
      }
    }
    final r = CommandResult();
    if (cmds.isNotEmpty) {
      final sub = EditCommands.runAtomic(p, {'op': 'batch', 'commands': cmds}, now: start);
      r.log.addAll(sub.log);
    }
    final end = added.fold(0.0, (m, l) => math.max(m, l.end));
    if (end > comp.duration) comp.duration = end;
    r.createdIds.addAll([for (final l in added) l.id]);
    r.log.add('Inserted template ${t.name}');
    return r;
  }

  // ------------------------------------------------------------ save as template

  /// The layers that go into a template made from [ids]: the given layers,
  /// their descendants, their parents (so positions stay right) and matte layers.
  static List<String> closure(Composition comp, Iterable<String> ids) {
    final set = <String>{...ids.where((id) => comp.layerById(id) != null)};
    var grew = true;
    while (grew) {
      grew = false;
      for (final l in comp.layers) {
        final add = !set.contains(l.id) &&
            ((l.parentId != null && set.contains(l.parentId)) || // child of a chosen layer
                comp.layers.any((o) => set.contains(o.id) && (o.parentId == l.id || o.matte?.layerId == l.id)));
        if (add) {
          set.add(l.id);
          grew = true;
        }
      }
    }
    return [for (final l in comp.layers) if (set.contains(l.id)) l.id];
  }

  /// Makes a saved template from layers of [p] (see [closure]): every text
  /// layer becomes a text slot, every media item a media slot (initial =
  /// the project media id; the library swaps in `lib:<id>` when saving).
  static SceneTemplate fromLayers(Project p, Iterable<String> ids, {required String name, String category = mine, String subtitle = ''}) {
    final comp = p.main;
    final chosen = closure(comp, ids);
    if (chosen.isEmpty) throw CommandError('Select at least one layer');
    final layers = [for (final id in chosen) comp.layerById(id)!];
    final t0 = layers.fold(double.infinity, (m, l) => math.min(m, l.start));
    final t1 = layers.fold(0.0, (m, l) => math.max(m, l.end));
    final slots = <TemplateSlot>[];
    final slotLayers = <String, List<String>>{};
    final mediaSlot = <String, String>{};
    var nText = 0, nMedia = 0;
    final out = <Map<String, dynamic>>[];
    for (final l in layers) {
      final c = l.copy()..moveTo(l.start - t0);
      out.add(c.toJson());
      if (l.type == LayerType.text && l.text != null && l.text!.text.trim().isNotEmpty) {
        final key = 'text_${++nText}';
        final txt = l.text!.text;
        slots.add(TemplateSlot(key, 'Text: ${txt.length > 28 ? '${txt.substring(0, 28)}…' : txt}', initial: txt));
        slotLayers[key] = [l.id];
      }
      final mid = l.mediaId;
      if (mid != null) {
        var key = mediaSlot[mid];
        if (key == null) {
          key = 'media_${++nMedia}';
          mediaSlot[mid] = key;
          final m = p.media[mid];
          slots.add(TemplateSlot(key, 'Media: ${m?.name ?? l.name}',
              kind: 'media', initial: mid, media: m == null ? 'any' : m.type.name, max: 1));
          slotLayers[key] = [];
        }
        slotLayers[key]!.add(l.id);
      }
    }
    return SceneTemplate(
      id: 'user_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      name: name,
      category: category,
      subtitle: subtitle.isEmpty ? '${layers.length} layers · ${(t1 - t0).toStringAsFixed(1)} s' : subtitle,
      duration: t1 - t0,
      previewTime: math.min(1.2, (t1 - t0) / 2),
      slots: slots,
      layers: out,
      slotLayers: slotLayers,
      width: comp.width,
      height: comp.height,
      created: DateTime.now(),
    );
  }

  // ------------------------------------------------------------ built-ins

  static final builtIn = <SceneTemplate>[
    // ---------------------------------------------------------------- Intros
    SceneTemplate(
      id: 'viral_3d_intro', name: 'Viral 3D Intro', category: 'Intros',
      subtitle: 'Title slam → curved glass screen showcase of your clips',
      duration: 7, previewTime: 0.9,
      slots: const [
        TemplateSlot('title', 'Title', initial: 'VIRAL 3D'),
        TemplateSlot('subtitle', 'Subtitle', initial: 'ANIMATION'),
        TemplateSlot('clips', 'Clips for the glass screen (1–6)', kind: 'medias', media: 'any', max: 6),
        TemplateSlot('color', 'Backdrop colour', kind: 'color', initial: '#6A0F1F'),
        TemplateSlot('music', 'Music (drops at 2.6 s)', kind: 'media', media: 'audio'),
      ],
      builder: (c) {
        const drop = 2.6;
        final clips = c.mediaIds('clips');
        final show = clips.isEmpty ? 4.0 : math.max(3.2, clips.length * 1.6);
        final music = c.media('music');
        return [
          {
            'op': 'add_component', 'type': 'title_slam', 'id': 'slam', 'start': c.t(0), 'duration': drop + 0.3,
            'title': c.s('title', 'VIRAL 3D'), 'subtitle': c.s('subtitle', 'ANIMATION'), 'color': c.s('color', '#6A0F1F'), 'drop': drop,
            if (music != null && music.type == MediaType.audio) 'music': music.id,
          },
          {
            'op': 'add_component', 'type': 'glass_screen', 'id': 'glass', 'start': c.t(drop), 'duration': show,
            if (clips.isNotEmpty) 'media': clips, 'every': 1.6,
          },
        ];
      },
    ),
    SceneTemplate(
      id: 'years_ago_tiles', name: "Number tiles '200 years ago'", category: 'Intros',
      subtitle: 'Rolling tiles on an old paper map, gold word bounces in',
      duration: 4.5, previewTime: 2.2,
      slots: const [
        TemplateSlot('text', 'Number', initial: '200 Y'),
        TemplateSlot('word', 'Word after', initial: 'AGO'),
        TemplateSlot('tile', 'Tile colour', kind: 'color', initial: '#2B2B2B'),
      ],
      builder: (c) => [
        if (WorldMap.loaded)
          {'op': 'add_component', 'type': 'map', 'id': 'map', 'start': c.t(0), 'duration': 4.5, 'style': 'paper'}
        else
          c.rect('paper', c.w, c.h, c.w / 2, c.h / 2, '#D9CDB4', fill2: '#A8977A', du: 4.5, name: 'Old paper'),
        {'op': 'add_effect', 'layer': WorldMap.loaded ? 'map_ocean' : 'paper', 'effect': 'grain', 'params': {'amount': 30}},
        {'op': 'add_component', 'type': 'number_tiles', 'id': 'tiles', 'start': c.t(0.2), 'duration': 4.3, 'text': c.s('text', '200 Y'), 'word': c.s('word'), 'tile_color': c.s('tile', '#2B2B2B')},
      ],
    ),
    SceneTemplate(
      id: 'date_title_intro', name: 'Big year title', category: 'Intros',
      subtitle: 'Shooting streak lights a huge serif year',
      duration: 4, previewTime: 1.6,
      slots: const [
        TemplateSlot('text', 'Year / date', initial: '1831'),
        TemplateSlot('subtitle', 'Place or name', initial: 'KENTUCKY'),
        TemplateSlot('bg', 'Background', kind: 'color', initial: '#0B0A12'),
      ],
      builder: (c) => [
        c.rect('bg', c.w, c.h, c.w / 2, c.h / 2, c.s('bg', '#0B0A12'), fill2: '#000000', du: 4, name: 'Background'),
        {'op': 'add_effect', 'layer': 'bg', 'effect': 'vignette', 'params': {'amount': 70}},
        {'op': 'add_component', 'type': 'date_title', 'id': 'date', 'start': c.t(0), 'duration': 4, 'text': c.s('text', '1831'), 'subtitle': c.s('subtitle')},
      ],
    ),
    // ---------------------------------------------------------------- Showcases
    SceneTemplate(
      id: 'glass_montage', name: 'Glass screen montage', category: 'Showcases',
      subtitle: 'Curved glossy screen on carbon, light leaks hide the cuts',
      duration: 5, previewTime: 1.0,
      slots: const [
        TemplateSlot('clips', 'Clips / photos (1–6)', kind: 'medias', max: 6),
        TemplateSlot('color', 'Light-leak colour', kind: 'color', initial: '#FF8A1F'),
      ],
      builder: (c) {
        final clips = c.mediaIds('clips');
        return [
          {
            'op': 'add_component', 'type': 'glass_screen', 'id': 'glass', 'start': c.t(0), 'duration': clips.isEmpty ? 5 : math.max(3.2, clips.length * 1.6),
            if (clips.isNotEmpty) 'media': clips, 'color': c.s('color', '#FF8A1F'),
          },
        ];
      },
    ),
    SceneTemplate(
      id: 'article_reveal', name: 'Article reveal', category: 'Showcases',
      subtitle: 'Screenshot on torn paper, highlighter sweep + red circle',
      duration: 6, previewTime: 2.4,
      slots: const [
        TemplateSlot('shot', 'Screenshot', kind: 'media', media: 'image'),
        TemplateSlot('coming', '"Coming up" tag (empty = none)'),
        TemplateSlot('bg', 'Backdrop colour', kind: 'color', initial: '#2A0E4F'),
      ],
      builder: (c) {
        final shot = c.media('shot');
        final coming = c.s('coming');
        return [
          {
            'op': 'add_component', 'type': 'article', 'id': 'art', 'start': c.t(0), 'duration': 6,
            if (shot != null) 'media': shot.id,
            'bg': c.s('bg', '#2A0E4F'),
            'marks': [
              {'box': [0.08, 0.20, 0.78, 0.25], 'style': 'highlight', 'delay': 1.0},
              {'box': [0.10, 0.42, 0.52, 0.47], 'style': 'circle', 'delay': 2.4},
            ],
            'coming_up': coming.isEmpty ? false : coming,
          },
        ];
      },
    ),
    SceneTemplate(
      id: 'silhouette_reveal', name: 'Silhouette crowd reveal', category: 'Showcases',
      subtitle: 'Glowing filled people rise in a stagger, labels type on',
      duration: 5, previewTime: 2.2,
      slots: const [
        TemplateSlot('people', 'People cut-outs (PNG)', kind: 'medias', media: 'image', max: 12),
        TemplateSlot('labels', 'Labels (comma separated)', initial: 'FARMER, WORKER, SOLDIER'),
        TemplateSlot('color', 'Silhouette colour', kind: 'color', initial: '#FFC107'),
      ],
      builder: (c) => [
        c.rect('bg', c.w, c.h, c.w / 2, c.h / 2, '#1A1206', fill2: '#050302', du: 5, name: 'Background'),
        {'op': 'add_effect', 'layer': 'bg', 'effect': 'vignette', 'params': {'amount': 75}},
        {
          'op': 'add_component', 'type': 'silhouette_crowd', 'id': 'crowd', 'start': c.t(0), 'duration': 5,
          if (c.mediaIds('people').isNotEmpty) 'media': c.mediaIds('people'),
          'labels': c.list('labels'), 'color': c.s('color', '#FFC107'), 'confetti': true,
        },
      ],
    ),
    SceneTemplate(
      id: 'scanner', name: 'Scanner', category: 'Showcases',
      subtitle: 'Cone beam from a logo swings over faces, red labels pop',
      duration: 6, previewTime: 1.4,
      slots: const [
        TemplateSlot('logo', 'Logo', kind: 'media', media: 'image'),
        TemplateSlot('logo_text', 'Logo text (no logo)', initial: 'AI'),
        TemplateSlot('faces', 'Faces / photos', kind: 'medias', media: 'image', max: 5),
        TemplateSlot('labels', 'Labels (comma separated)', initial: 'SUSPECT 1, SUSPECT 2, SUSPECT 3'),
        TemplateSlot('color', 'Beam colour', kind: 'color', initial: '#FF2D2D'),
      ],
      builder: (c) {
        final faces = c.mediaIds('faces');
        final labels = c.list('labels');
        final n = math.max(1, math.max(faces.length, labels.length));
        final logo = c.media('logo');
        return [
          c.rect('bg', c.w, c.h, c.w / 2, c.h / 2, '#0A0A0D', fill2: '#000000', du: 0.4 + n * 1.6 + 1.2, name: 'Background'),
          {
            'op': 'add_component', 'type': 'scanner', 'id': 'scan', 'start': c.t(0), 'duration': 0.4 + n * 1.6 + 1.2,
            if (logo != null) 'logo': logo.id, 'logo_text': c.s('logo_text', 'AI'), 'color': c.s('color', '#FF2D2D'),
            'targets': [
              for (int i = 0; i < n; i++) {if (i < faces.length) 'media': faces[i], 'label': i < labels.length ? labels[i] : ''},
            ],
          },
        ];
      },
    ),
    SceneTemplate(
      id: 'icon_flow', name: 'Icon flow A→B', category: 'Showcases',
      subtitle: 'App icons stream along an arc between two places',
      duration: 5, previewTime: 2.0,
      slots: const [
        TemplateSlot('icons', 'Icons (logos, flags…)', kind: 'medias', media: 'image', max: 8),
        TemplateSlot('glyphs', 'Or short texts (comma separated)', initial: '₹, \$, €, ¥'),
        TemplateSlot('from', 'From label', initial: 'INDIA'),
        TemplateSlot('to', 'To label', initial: 'USA'),
      ],
      builder: (c) {
        final a = [c.w * 0.14, c.h * 0.74], b = [c.w * 0.86, c.h * 0.3];
        final icons = [...c.mediaIds('icons'), ...c.list('glyphs')];
        final fs = c.h * 0.04;
        Map<String, dynamic> label(String id, String text, List<double> at) => {
              'op': 'add_layer', 'type': 'text', 'id': id, 'text': text.toUpperCase(), 'font_size': fs, 'font_weight': 900,
              'width': c.w * 0.3, 'height': fs * 1.6, 'position': [at[0], at[1] + c.h * 0.09, 0], 'start': c.t(0), 'duration': 5,
              'animator': 'fade_up', 'anim_duration': 0.5, 'shadow': true,
            };
        return [
          c.rect('bg', c.w, c.h, c.w / 2, c.h / 2, '#10243A', fill2: '#060B12', du: 5, name: 'Background'),
          c.rect('dot_a', c.h * 0.05, c.h * 0.05, a[0], a[1], '#FFD54F', kind: 'ellipse', du: 5, name: 'Point A'),
          c.rect('dot_b', c.h * 0.05, c.h * 0.05, b[0], b[1], '#FFD54F', kind: 'ellipse', du: 5, name: 'Point B'),
          label('from_label', c.s('from', 'A'), a),
          label('to_label', c.s('to', 'B'), b),
          {'op': 'add_component', 'type': 'icon_stream', 'id': 'flow', 'start': c.t(0.3), 'duration': 4.7, 'from': a, 'to': b, 'count': 10, if (icons.isNotEmpty) 'icons': icons},
        ];
      },
    ),
    SceneTemplate(
      id: 'year_ruler', name: 'Year ruler', category: 'Showcases',
      subtitle: 'Ruler slides under a red marker and stops on the year',
      duration: 4, previewTime: 2.6,
      slots: const [
        TemplateSlot('from', 'From year', initial: '1930'),
        TemplateSlot('to', 'To year', initial: '1970'),
        TemplateSlot('marker', 'Stop on year', initial: '1947'),
        TemplateSlot('label', 'Label (empty = the year)'),
        TemplateSlot('color', 'Marker colour', kind: 'color', initial: '#E53935'),
      ],
      builder: (c) {
        final from = c.n('from', 1930), to = c.n('to', 1970);
        return [
          {
            'op': 'add_component', 'type': 'timeline', 'id': 'ruler', 'start': c.t(0), 'duration': 4,
            'from': from, 'to': math.max(to, from + 1), 'marker': c.n('marker', (from + to) / 2), 'color': c.s('color', '#E53935'),
            if (c.s('label').isNotEmpty) 'label': c.s('label'),
          },
        ];
      },
    ),
    // ---------------------------------------------------------------- Transitions
    SceneTemplate(
      id: 'flash_hit', name: 'White flash hit', category: 'Transitions',
      subtitle: 'Full-frame flash to hide a cut (put it on the cut)',
      duration: 0.5, previewTime: 0.1,
      slots: const [TemplateSlot('color', 'Flash colour', kind: 'color', initial: '#FFFFFF')],
      builder: (c) => [
        {'op': 'add_layer', 'type': 'solid', 'id': 'flash', 'name': 'Flash', 'color': c.s('color', '#FFFFFF'), 'start': c.t(0), 'duration': 0.5},
        c.kf('flash', 'opacity', 0, 100, 'ease_out'),
        c.kf('flash', 'opacity', 0.45, 0, 'linear'),
      ],
    ),
    SceneTemplate(
      id: 'light_leak', name: 'Light-leak sweep', category: 'Transitions',
      subtitle: 'Soft coloured light sweeps across the frame',
      duration: 0.8, previewTime: 0.4,
      slots: const [TemplateSlot('color', 'Leak colour', kind: 'color', initial: '#FF8A1F')],
      builder: (c) {
        final col = c.s('color', '#FF8A1F').replaceFirst('#', '');
        final rgb = col.length >= 6 ? col.substring(col.length - 6) : 'FF8A1F';
        return [
          {
            'op': 'add_layer', 'type': 'shape', 'id': 'leak', 'name': 'Light leak', 'kind': 'rect', 'width': c.w * 0.4, 'height': c.h * 1.5,
            'fill': '#CC$rgb', 'fill2': '#00$rgb', 'start': c.t(0), 'duration': 0.8, 'position': [-c.w * 0.3, c.h / 2, 0],
          },
          {'op': 'set_property', 'target': 'leak', 'prop': 'rotation', 'value': [0, 0, 14]},
          {'op': 'add_effect', 'layer': 'leak', 'effect': 'blur', 'params': {'amount': 60}},
          c.kf('leak', 'position', 0, [-c.w * 0.3, c.h / 2, 0], 'linear'),
          c.kf('leak', 'position', 0.8, [c.w * 1.3, c.h / 2, 0]),
        ];
      },
    ),
    SceneTemplate(
      id: 'foreground_wipe', name: 'Foreground wipe', category: 'Transitions',
      subtitle: 'A tree / pillar cut-out sweeps past the lens',
      duration: 0.8, previewTime: 0.35,
      slots: const [
        TemplateSlot('media', 'Cut-out (tree, cloud, pillar)', kind: 'media', media: 'image'),
        TemplateSlot('direction', 'Direction (left / right)', initial: 'left'),
      ],
      builder: (c) => [
        {
          'op': 'add_component', 'type': 'foreground_wipe', 'id': 'wipe', 'start': c.t(0), 'duration': 0.8, 'length': 0.7,
          if (c.media('media') != null) 'media': c.media('media')!.id, 'direction': c.s('direction', 'left') == 'right' ? 'right' : 'left',
        },
      ],
    ),
    SceneTemplate(
      id: 'ink_reveal', name: 'Ink bleed reveal', category: 'Transitions',
      subtitle: 'A photo (or title) bleeds in like ink',
      duration: 4, previewTime: 0.5,
      slots: const [
        TemplateSlot('media', 'Photo / clip', kind: 'media'),
        TemplateSlot('title', 'Title (no photo)', initial: 'CHAPTER TWO'),
      ],
      builder: (c) {
        final m = c.media('media');
        return [
          if (m != null && m.type != MediaType.audio)
            c.mediaLayer('shot', m, du: 4)
          else ...[
            c.rect('bg', c.w, c.h, c.w / 2, c.h / 2, '#1B0B0B', fill2: '#050202', du: 4, name: 'Background'),
            {'op': 'add_layer', 'type': 'text', 'id': 'shot', 'text': c.s('title', 'CHAPTER TWO'), 'font_size': c.h * 0.12, 'font_weight': 900, 'start': c.t(0), 'duration': 4, 'shadow': true},
          ],
          {'op': 'animate_in', 'layer': 'shot', 'preset': 'ink', 'duration': 1.0},
        ];
      },
    ),
    // ---------------------------------------------------------------- Captions
    SceneTemplate(
      id: 'glow_word', name: 'Glow word', category: 'Captions',
      subtitle: 'One dramatic glowing word',
      duration: 3, previewTime: 1.0,
      slots: const [TemplateSlot('text', 'Word', initial: 'BETRAYAL')],
      builder: (c) => [
        {'op': 'add_component', 'type': 'glow_word', 'id': 'word', 'start': c.t(0), 'duration': 3, 'text': c.s('text', 'BETRAYAL')},
      ],
    ),
    SceneTemplate(
      id: 'word_pop_caption', name: 'Word-pop caption', category: 'Captions',
      subtitle: 'Bold caption, words pop in with a highlight',
      duration: 3, previewTime: 1.2,
      slots: const [
        TemplateSlot('text', 'Caption', initial: 'NOBODY KNEW THE TRUTH'),
        TemplateSlot('highlight', 'Highlight colour', kind: 'color', initial: '#FFD54F'),
      ],
      builder: (c) => [
        {
          'op': 'add_layer', 'type': 'text', 'id': 'cap', 'text': c.s('text', 'NOBODY KNEW THE TRUTH'), 'font_size': c.h * 0.07, 'font_weight': 900,
          'width': c.w * 0.8, 'height': c.h * 0.2, 'position': [c.w / 2, c.h * 0.8, 0], 'start': c.t(0), 'duration': 3,
          'animator': 'word_pop', 'anim_duration': 0.9, 'highlight_color': c.s('highlight', '#FFD54F'), 'shadow': true,
        },
      ],
    ),
    SceneTemplate(
      id: 'scramble_title', name: 'Scramble title', category: 'Captions',
      subtitle: 'Letters decode left to right',
      duration: 3, previewTime: 0.6,
      slots: const [TemplateSlot('text', 'Text', initial: 'CLASSIFIED')],
      builder: (c) => [
        {
          'op': 'add_layer', 'type': 'text', 'id': 'scr', 'text': c.s('text', 'CLASSIFIED'), 'font_size': c.h * 0.11, 'font_weight': 900,
          'start': c.t(0), 'duration': 3, 'animator': 'scramble', 'anim_duration': 1.2, 'shadow': true,
        },
      ],
    ),
    // ---------------------------------------------------------------- Lower thirds
    SceneTemplate(
      id: 'name_tag_intro', name: 'Name tag intro', category: 'Lower thirds',
      subtitle: 'Photo with slow push, name + role on a yellow highlight bar',
      duration: 5, previewTime: 2.0,
      slots: const [
        TemplateSlot('photo', 'Photo / clip of the person', kind: 'media'),
        TemplateSlot('name', 'Name', initial: 'Name Surname'),
        TemplateSlot('role', 'Role', initial: 'Role or title'),
        TemplateSlot('color', 'Bar colour', kind: 'color', initial: '#FFD400'),
      ],
      builder: (c) {
        final m = c.media('photo');
        final cmds = <Map<String, dynamic>>[];
        if (m != null && m.type != MediaType.audio) {
          final s = math.max(c.w / math.max(1, m.width), c.h / math.max(1, m.height)) * 100;
          cmds
            ..add(c.mediaLayer('photo', m, du: 5))
            ..add(c.kf('photo', 'scale', 0, [s, s, 100], 'linear'))
            ..add(c.kf('photo', 'scale', 5, [s * 1.08, s * 1.08, 100]));
        }
        cmds.add({
          'op': 'add_component', 'type': 'name_tag', 'id': 'tag', 'start': c.t(0.5), 'duration': 4.5,
          'name': c.s('name', 'Name Surname'), 'role': c.s('role', 'Role or title'), 'color': c.s('color', '#FFD400'),
        });
        return cmds;
      },
    ),
    SceneTemplate(
      id: 'source_line', name: 'Source line', category: 'Lower thirds',
      subtitle: 'Cited source with highlighted words',
      duration: 5, previewTime: 1.2,
      slots: const [
        TemplateSlot('source', 'Source', initial: 'Source: The Hindu'),
        TemplateSlot('text', 'Text', initial: 'The fort was built in 1726'),
        TemplateSlot('highlights', 'Highlight words (comma separated)', initial: '1726'),
      ],
      builder: (c) => [
        {'op': 'add_component', 'type': 'lower_third', 'id': 'src', 'start': c.t(0), 'duration': 5, 'source': c.s('source'), 'text': c.s('text'), 'highlights': c.list('highlights')},
      ],
    ),
    SceneTemplate(
      id: 'character_tag', name: 'Character label', category: 'Lower thirds',
      subtitle: 'Black/red tag pinned on someone in the picture',
      duration: 4, previewTime: 1.0,
      slots: const [
        TemplateSlot('text', 'Label', initial: 'THE BROKER'),
        TemplateSlot('style', 'Style (black / red)', initial: 'red'),
      ],
      builder: (c) => [
        {'op': 'add_component', 'type': 'character_label', 'id': 'lbl', 'start': c.t(0), 'duration': 4, 'text': c.s('text', 'NAME'), 'style': c.s('style', 'black') == 'red' ? 'red' : 'black', 'x': c.w * 0.5, 'y': c.h * 0.32},
      ],
    ),
    // ---------------------------------------------------------------- Endings
    SceneTemplate(
      id: 'subscribe_end', name: 'Subscribe end card', category: 'Endings',
      subtitle: 'Thanks line + subscribe pop-up',
      duration: 5, previewTime: 1.6,
      slots: const [
        TemplateSlot('line', 'Line', initial: 'Thanks for watching'),
        TemplateSlot('cta', 'Button text', initial: 'SUBSCRIBE'),
        TemplateSlot('bg', 'Background', kind: 'color', initial: '#0E1420'),
      ],
      builder: (c) => [
        c.rect('bg', c.w, c.h, c.w / 2, c.h / 2, c.s('bg', '#0E1420'), fill2: '#000000', du: 5, name: 'Background'),
        {
          'op': 'add_layer', 'type': 'text', 'id': 'thanks', 'text': c.s('line', 'Thanks for watching'), 'font_size': c.h * 0.08, 'font_weight': 800,
          'position': [c.w / 2, c.h * 0.4, 0], 'start': c.t(0), 'duration': 5, 'animator': 'fade_up', 'anim_duration': 0.8, 'shadow': true,
        },
        {'op': 'add_component', 'type': 'cta', 'id': 'cta', 'start': c.t(0.8), 'duration': 4.2, 'text': c.s('cta', 'SUBSCRIBE')},
      ],
    ),
    SceneTemplate(
      id: 'memorial', name: 'In memory plaque', category: 'Endings',
      subtitle: 'Gravestone / plaque with engraved text, falling dust',
      duration: 5, previewTime: 1.5,
      slots: const [
        TemplateSlot('name', 'Name', initial: 'NAME'),
        TemplateSlot('dates', 'Dates', initial: '1835 – 1902'),
        TemplateSlot('text', 'Epitaph', initial: 'Rest in peace'),
        TemplateSlot('style', 'Style (stone / bronze / wood)', initial: 'stone'),
      ],
      builder: (c) => [
        c.rect('bg', c.w, c.h, c.w / 2, c.h / 2, '#202226', fill2: '#08090A', du: 5, name: 'Background'),
        {'op': 'add_effect', 'layer': 'bg', 'effect': 'vignette', 'params': {'amount': 80}},
        {
          'op': 'add_component', 'type': 'plaque', 'id': 'plaque', 'start': c.t(0), 'duration': 5, 'name': c.s('name', 'NAME'), 'dates': c.s('dates'), 'text': c.s('text'),
          'style': const ['stone', 'bronze', 'wood'].contains(c.s('style')) ? c.s('style') : 'stone',
        },
      ],
    ),
    // ---------------------------------------------------------------- Maps
    SceneTemplate(
      id: 'country_focus', name: 'Country zoom', category: 'Maps',
      subtitle: 'World map zooms to a highlighted country',
      duration: 5, previewTime: 3.0,
      slots: const [
        TemplateSlot('country', 'Country', initial: 'India'),
        TemplateSlot('style', 'Style (dark / paper / blue)', initial: 'dark'),
      ],
      builder: (c) {
        final country = c.s('country', 'India');
        return [
          {
            'op': 'add_component', 'type': 'map', 'id': 'map', 'start': c.t(0), 'duration': 5, 'countries': [country], 'focus': country,
            'style': const ['dark', 'paper', 'blue'].contains(c.s('style')) ? c.s('style') : 'dark',
          },
        ];
      },
    ),
    SceneTemplate(
      id: 'map_journey', name: 'Map journey', category: 'Maps',
      subtitle: 'Route line draws between countries, camera follows the tip',
      duration: 6, previewTime: 2.5,
      needsComponents: const ['route_follow'],
      slots: const [
        TemplateSlot('from', 'From country', initial: 'India'),
        TemplateSlot('to', 'To country', initial: 'United Kingdom'),
        TemplateSlot('avatar', 'Traveller face (round pin)', kind: 'media', media: 'image'),
      ],
      builder: (c) => [
        {
          'op': 'add_component', 'type': 'route_follow', 'id': 'route', 'start': c.t(0), 'duration': 6, 'from': c.s('from', 'India'), 'to': c.s('to', 'United Kingdom'),
          if (c.media('avatar') != null) 'avatar': c.media('avatar')!.id,
        },
      ],
    ),
    SceneTemplate(
      id: 'map_fly', name: 'Map fly A→B', category: 'Maps',
      subtitle: 'Camera flies across the map from one country to another',
      duration: 6, previewTime: 2.0,
      needsComponents: const ['map_fly'],
      slots: const [
        TemplateSlot('from', 'From country', initial: 'India'),
        TemplateSlot('to', 'To country', initial: 'United States of America'),
      ],
      builder: (c) => [
        {'op': 'add_component', 'type': 'map', 'id': 'map', 'start': c.t(0), 'duration': 6, 'countries': [c.s('from', 'India'), c.s('to', 'United States of America')], 'zoom': false},
        {'op': 'add_component', 'type': 'map_fly', 'id': 'fly', 'map': 'map', 'start': c.t(0), 'duration': 6, 'from': c.s('from', 'India'), 'to': c.s('to', 'United States of America')},
      ],
    ),
    // ---------------------------------------------------------------- 3D
    SceneTemplate(
      id: 'village_flythrough', name: 'Village fly-through', category: '3D',
      subtitle: 'Flat cut-outs played deep: drift → fly to the hut → push through the door',
      duration: 6, previewTime: 1.0,
      needsOps: const ['make_3d', 'camera_shot'],
      slots: const [
        TemplateSlot('sky', 'Sky', kind: 'media', media: 'image'),
        TemplateSlot('houses', 'Houses (cut-outs, reused at depths)', kind: 'medias', media: 'image', max: 4),
        TemplateSlot('hero', 'Hero hut (cut-out)', kind: 'media', media: 'image'),
        TemplateSlot('grass', 'Grass strip (cut-out)', kind: 'media', media: 'image'),
        TemplateSlot('plant', 'Near plant / reeds (cut-out)', kind: 'media', media: 'image'),
        TemplateSlot('interior', 'Interior insert', kind: 'media', media: 'image'),
      ],
      builder: _village,
    ),
    SceneTemplate(
      id: 'photo_parallax', name: 'Photo parallax title', category: '3D',
      subtitle: 'Photo far back, title in front, camera pushes in',
      duration: 5, previewTime: 2.5,
      slots: const [
        TemplateSlot('photo', 'Photo', kind: 'media', media: 'image'),
        TemplateSlot('title', 'Title', initial: 'THE LOST CITY'),
      ],
      builder: (c) {
        final m = c.media('photo');
        return [
          if (m != null)
            {...c.mediaLayer('photo', m, du: 5), 'is3d': true}
          else
            {...c.rect('photo', c.w, c.h, c.w / 2, c.h / 2, '#22324A', fill2: '#0A0F18', du: 5, name: 'Background'), 'is3d': true},
          {'op': 'add_layer', 'type': 'text', 'id': 'title', 'text': c.s('title', 'THE LOST CITY'), 'font_size': c.h * 0.12, 'font_weight': 900, 'is3d': true, 'start': c.t(0), 'duration': 5, 'animator': 'fade_up', 'anim_duration': 1.2, 'shadow': true},
          {'op': 'parallax_rig', 'layers': ['photo', 'title'], 'depth': 600, 'push': 400, 'start': c.t(0), 'duration': 5},
        ];
      },
    ),
  ];

  /// Village fly-through recipe (reference: flat cut-outs at many depths,
  /// low drift → fly to the hero hut → fast push into the door with motion
  /// blur → 0.4 s interior insert).
  static List<Map<String, dynamic>> _village(TemplateCtx c) {
    final w = c.w, h = c.h;
    const du = 6.0;
    final cmds = <Map<String, dynamic>>[];
    final bands = <String, String>{};
    final order = <String>[];
    void put(String id, Map<String, dynamic> cmd, String band) {
      cmds.add(cmd);
      bands[id] = band;
      order.add(id);
    }

    Map<String, dynamic> cut(String id, MediaAsset m, double x, double y, double hh) => c.mediaLayer(id, m, x: x, y: y, heightPx: hh, du: du);
    final sky = c.media('sky');
    put('sky', sky != null ? c.mediaLayer('sky', sky, du: du) : c.rect('sky', w * 1.2, h * 1.2, w / 2, h / 2, '#8EC3EE', fill2: '#F6DDB4', du: du, name: 'Sky'), 'sky');
    put('ground', c.rect('ground', w * 1.4, h * 0.45, w / 2, h * 0.86, '#7A9A45', fill2: '#3E5A22', du: du, name: 'Ground'), 'far');
    final houses = c.medias('houses');
    const spots = [[0.16, 0.62, 0.20], [0.36, 0.60, 0.17], [0.74, 0.62, 0.22], [0.9, 0.64, 0.16]];
    final count = houses.isEmpty ? 3 : math.min(4, math.max(houses.length, 3));
    for (int i = 0; i < count; i++) {
      final s = spots[i];
      final id = 'house$i';
      final hh = h * s[2] * 1.6;
      if (houses.isNotEmpty) {
        put(id, cut(id, houses[i % houses.length], w * s[0], h * s[1], hh), i.isEven ? 'far' : 'mid');
      } else {
        put(id, c.rect(id, hh * 1.2, hh, w * s[0], h * s[1], '#A07856', fill2: '#6D4C35', du: du, name: 'House ${i + 1}', corner: 6), i.isEven ? 'far' : 'mid');
      }
    }
    final hero = c.media('hero');
    if (hero != null) {
      put('hero', cut('hero', hero, w * 0.54, h * 0.6, h * 0.42), 'mid');
    } else {
      put('hero', c.rect('hero', h * 0.5, h * 0.36, w * 0.54, h * 0.6, '#B98B62', fill2: '#7B5536', du: du, name: 'Hero hut', corner: 8), 'mid');
      put('door', c.rect('door', h * 0.1, h * 0.18, w * 0.54, h * 0.69, '#2A1A10', du: du, name: 'Door', corner: 4), 'mid');
    }
    final grass = c.media('grass');
    put('grass', grass != null ? c.mediaLayer('grass', grass, x: w / 2, y: h * 0.8, widthPx: w * 1.3, du: du) : c.rect('grass', w * 1.3, h * 0.14, w / 2, h * 0.8, '#4E7F2C', fill2: '#2D4D17', du: du, name: 'Grass strip', corner: 40), 'near');
    final plant = c.media('plant');
    put('plant', plant != null ? cut('plant', plant, w * 0.9, h * 0.72, h * 0.95) : c.rect('plant', w * 0.1, h * 0.9, w * 0.92, h * 0.78, '#26401A', kind: 'ellipse', du: du, name: 'Reeds'), 'front');
    put('birds', {'op': 'add_layer', 'type': 'solid', 'id': 'birds', 'name': 'Birds', 'color': '#00000000', 'width': w, 'height': h, 'start': c.t(0), 'duration': du}, 'sky');
    cmds.add({'op': 'add_effect', 'layer': 'birds', 'effect': 'particles', 'params': {'kind': 'birds', 'amount': 20, 'speed': 0.6}});
    cmds.add({'op': 'add_effect', 'layer': 'plant', 'effect': 'sway', 'params': {'amount': 30, 'speed': 0.8}});
    cmds.add({'op': 'make_3d', 'layers': order, 'bands': bands, 'start': c.t(0)});
    cmds.add({'op': 'set_comp', 'motion_blur': true});
    final target = hero == null ? 'door' : 'hero';
    cmds.add({'op': 'camera_shot', 'move': 'drift', 'start': c.t(0), 'duration': 2.4});
    cmds.add({'op': 'camera_shot', 'move': 'fly_to', 'target': 'hero', 'start': c.t(2.4), 'duration': 2.0});
    final interior = c.media('interior');
    cmds.add(interior != null
        ? {...c.mediaLayer('interior', interior, du: 0.6), 'start': c.t(5.2)}
        : c.rect('interior', w, h, w / 2, h / 2, '#4A2E1A', fill2: '#120A05', st: 5.2, du: 0.6, name: 'Interior'));
    cmds.add({'op': 'camera_shot', 'move': 'push_through', 'target': target, 'start': c.t(4.4), 'duration': 0.8, 'cut_to': 'interior'});
    return cmds;
  }
}
