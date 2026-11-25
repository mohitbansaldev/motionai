import 'dart:convert';

import '../model/effects_catalog.dart';
import '../model/layer.dart';
import '../model/project.dart';
import 'edit_commands.dart';

/// Command keys for the motion-FX features (track matte, motion path, text
/// extrude, comp motion blur, named effect params). Called from
/// [EditCommands] so that file only needs one-line hooks.
class FxCommands {
  /// `add_layer` / `update_layer` keys:
  /// - `matte`: {"layer": id, "mode": "alpha"|"inverse"} | id | null/"none"
  /// - `path`: {"points": [[x,y],...], "smooth": true, "orient": false}
  ///   or {"from": [x,y], "to": [x,y], "bend": px, "orient": bool}; null/"none" removes.
  ///   While a path is set, position X/Y is an offset from the path; when a
  ///   path is first added (and the command has no "position") the offset is
  ///   reset to 0 so the layer sits on the path. Keyframe `path_progress` 0..100.
  static void applyLayer(Composition comp, Layer l, Map<String, dynamic> c) {
    if (c.containsKey('matte')) l.matte = _matte(comp, l, c['matte']);
    if (c.containsKey('path')) _path(l, c['path'], hasPosition: c['position'] != null);
  }

  static LayerMatte? _matte(Composition comp, Layer l, dynamic v) {
    if (v == null || v == false || v == 'none') return null;
    String? id;
    var mode = 'alpha';
    if (v is String) {
      id = v;
    } else if (v is Map) {
      id = v['layer']?.toString();
      if (v['mode'] != null) mode = '${v['mode']}';
    }
    if (id == null) throw CommandError('matte needs {"layer": id, "mode": "alpha" | "inverse"}');
    if (!LayerMatte.modes.contains(mode)) throw CommandError('matte mode must be "alpha" or "inverse", got "$mode"');
    if (id == l.id) throw CommandError('A layer cannot be its own matte');
    if (comp.layerById(id) == null) {
      throw CommandError('Matte layer "$id" does not exist. Layers: ${comp.layers.map((o) => o.id).join(', ')}');
    }
    return LayerMatte(id, mode: mode);
  }

  static List<double> _pt(dynamic p) {
    if (p is List && p.length >= 2 && p[0] is num && p[1] is num) {
      return [(p[0] as num).toDouble(), (p[1] as num).toDouble()];
    }
    throw CommandError('Each path point needs [x, y], got ${jsonEncode(p)}');
  }

  static void _path(Layer l, dynamic v, {required bool hasPosition}) {
    final pos = l.prop(Props.position);
    if (v == null || v == false || v == 'none') {
      final old = l.path;
      if (old != null && !pos.isAnimated) {
        // Keep the layer where it currently is on the path.
        final prog = (l.props[Props.pathProgress]?.valueAt(l.start).first ?? 0) / 100;
        final s = old.sample(prog);
        final p = pos.staticValue;
        pos.staticValue = [p[0] + s.x, p[1] + s.y, p[2]];
      }
      l.path = null;
      return;
    }
    MotionPath path;
    if (v is List) {
      path = MotionPath(points: [for (final p in v) _pt(p)]);
    } else if (v is Map) {
      final orient = v['orient'] == true;
      if (v['points'] is List) {
        final pts = [for (final p in v['points'] as List) _pt(p)];
        if (pts.isEmpty) throw CommandError('path needs at least one point');
        path = MotionPath(points: pts, smooth: v['smooth'] != false, orient: orient);
      } else if (v['from'] != null && v['to'] != null) {
        final bend = v['bend'] is num ? (v['bend'] as num).toDouble() : 0.0;
        path = MotionPath.arc(_pt(v['from']), _pt(v['to']), bend, orient: orient);
      } else {
        throw CommandError('path needs "points": [[x,y],...] or "from"/"to" (+ "bend")');
      }
    } else {
      throw CommandError('path must be {"points": [[x,y],...], "smooth": true, "orient": false}');
    }
    final had = l.path != null;
    l.path = path;
    if (!had && !hasPosition && !pos.isAnimated) {
      pos.staticValue = [0, 0, pos.staticValue[2]];
    }
  }

  /// Text keys: `extrude`: depth | {"depth": px, "color": "#RRGGBB"} | 0/"none".
  static void applyText(TextData t, Map<String, dynamic> c, int Function(dynamic) color) {
    final v = c['extrude'];
    if (v == null) return;
    if (v == 'none' || v == false) {
      t.extrude = 0;
    } else if (v is num) {
      t.extrude = v.toDouble().clamp(0.0, 400.0);
    } else if (v is Map) {
      if (v['depth'] is num) t.extrude = (v['depth'] as num).toDouble().clamp(0.0, 400.0);
      if (v['color'] != null) t.extrudeColor = color(v['color']);
      if (v['depth'] == null && t.extrude <= 0) t.extrude = 12;
    } else {
      throw CommandError('extrude must be a depth in px or {"depth": px, "color": "#RRGGBB"}');
    }
    if (c['extrude_color'] != null) t.extrudeColor = color(c['extrude_color']);
  }

  /// `set_comp` keys: `motion_blur`: bool.
  static void applyComp(Composition comp, Map<String, dynamic> c) {
    if (c['motion_blur'] != null) comp.motionBlur = c['motion_blur'] == true;
  }

  /// Named effect values ("#FFC107" colours, "snow" particle kind, "top"
  /// side…) → numbers. Null when [v] is a plain number/list.
  static List<double>? effectValue(String type, String key, dynamic v) {
    try {
      return EffectsCatalog.paramValues(type, key, v);
    } on ArgumentError catch (e) {
      throw CommandError('${e.message}');
    }
  }
}
