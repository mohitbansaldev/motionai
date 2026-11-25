// V3-A: MAPS & GEO ops (MotionAI V3, P-A).
//
// - Op aliases for the geo components: {"op": "status_ring", ...} ==
//   {"op": "add_component", "type": "status_ring", ...} (one undo step).
// - map_tilt {map?, tilt: 38, roll: -10, at?, duration: 0.6, scale?}: the map
//   (its group and everything on it) pitches back in 3D.
// - camera_move {preset: "punch_in", point?, target?, layer?|map?, amount: 2.6,
//   duration: 0.45, start?, ease?: ease_in, blur: true, sound: true}.

import 'dart:math' as math;

import '../engine/evaluator.dart';
import '../model/anim_prop.dart';
import '../model/camera.dart';
import '../model/easing.dart';
import '../model/layer.dart';
import '../model/project.dart';
import 'edit_commands.dart' show CommandError, CommandResult;

typedef _Exec = void Function(Map<String, dynamic> cmd);

class MapCommands {
  /// Ops that are the same as add_component with that type.
  static const componentOps = [
    'status_ring', 'signal_rings', 'pulse_rings', 'geo_label', 'path_text', 'terrain_label', 'map_watermark',
    'search_sweep', 'sketch_map', 'route_follow',
  ];
  static const ops = [...componentOps, 'map_tilt'];

  static void run(Project p, Map<String, dynamic> c, double now, CommandResult r, _Exec exec) {
    final op = '${c['op']}';
    if (componentOps.contains(op)) {
      exec({...c, 'op': 'add_component', 'type': op});
      return;
    }
    if (op == 'map_tilt') {
      tilt(p, c, now, r, exec);
      return;
    }
    throw CommandError('Unknown map op "$op"');
  }

  static double? _num(Map<String, dynamic> c, String k) {
    final v = c[k];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    throw CommandError('"$k" must be a number');
  }

  static Easing _ease(dynamic v, Easing def) {
    if (v is! String) return def;
    try {
      return Easing.parse(v);
    } on FormatException catch (e) {
      throw CommandError(e.message);
    }
  }

  /// Map component id from "map" (or the visible map at [t]).
  static String _mapId(Composition comp, dynamic m, double t) {
    if (m is String && m.isNotEmpty) {
      final id = m.endsWith('_g') ? m.substring(0, m.length - 2) : m;
      if (comp.layerById('${id}_g') == null) throw CommandError('"map": no map component "$m" (no layer ${id}_g)');
      return id;
    }
    for (final l in comp.layers) {
      if (l.type == LayerType.shape && l.id.endsWith('_world') && l.isActiveAt(t)) {
        final root = l.id.substring(0, l.id.length - '_world'.length);
        if (comp.layerById('${root}_g') != null) return root;
      }
    }
    for (final l in comp.layers) {
      if (l.id.endsWith('_world')) {
        final root = l.id.substring(0, l.id.length - '_world'.length);
        if (comp.layerById('${root}_g') != null) return root;
      }
    }
    throw CommandError('No map in this comp: add a map component first (or pass "map")');
  }

  static void _shift(AnimProp prop, double dx, double dy) {
    List<double> f(List<double> v) => [v[0] + dx, v.length > 1 ? v[1] + dy : dy, if (v.length > 2) ...v.sublist(2)];
    prop.staticValue = f(prop.staticValue);
    for (final k in prop.keyframes) {
      k.value = f(k.value);
    }
  }

  // ------------------------------------------------------------- map_tilt

  /// Moves the map group (and everything parented to it) into a precomp
  /// 1.6× the frame (so the far edge stays covered), makes the comp layer
  /// 3D and pitches it back by [tilt]° with a [roll]° roll.
  static void tilt(Project p, Map<String, dynamic> c, double now, CommandResult r, _Exec exec) {
    final comp = p.editComp;
    final at = _num(c, 'at') ?? _num(c, 'start') ?? now;
    final map = _mapId(comp, c['map'], at);
    final g = comp.requireLayer('${map}_g');
    final ids = <String>{g.id};
    var grew = true;
    while (grew) {
      grew = false;
      for (final l in comp.layers) {
        final pid = l.parentId;
        if (pid != null && ids.contains(pid) && ids.add(l.id)) grew = true;
      }
    }
    final compId = '${c['id'] ?? '${map}_tilt'}';
    final layerId = '${c['layer_id'] ?? '${map}_tilted'}';
    exec({'op': 'precompose', 'layers': [for (final l in comp.layers) if (ids.contains(l.id)) l.id], 'id': compId, 'layer_id': layerId, 'name': 'Map (tilted)'});
    final child = p.comps[compId];
    final cl = comp.layerById(layerId);
    if (child == null || cl == null) throw CommandError('map_tilt: could not precompose the map');
    const f = 1.6;
    final w = child.width, h = child.height;
    final dx = (f - 1) * w / 2, dy = (f - 1) * h / 2;
    child.width = w * f;
    child.height = h * f;
    for (final l in child.layers) {
      if (l.parentId == null) _shift(l.prop(Props.position), dx, dy);
    }
    cl.width = w * f;
    cl.height = h * f;
    cl.prop(Props.anchor).staticValue = [w * f / 2, h * f / 2, 0];
    cl.is3D = true;
    final tiltDeg = (_num(c, 'tilt') ?? 38).clamp(-80.0, 80.0);
    final roll = _num(c, 'roll') ?? -10;
    final du = math.max(comp.frameDuration, _num(c, 'duration') ?? 0.6);
    final ease = _ease(c['ease'], Easing.easyEase);
    final rot = cl.prop(Props.rotation);
    rot.setKeyframe(at, [0, 0, 0], easing: ease);
    rot.setKeyframe(at + du, [-tiltDeg, 0, roll], easing: Easing.easyEase);
    // Lean in a little so the near edge fills the frame as it pitches.
    final sc = cl.prop(Props.scale);
    final s1 = _num(c, 'scale') ?? 100 + tiltDeg.abs() * 0.35;
    sc.setKeyframe(at, [100, 100, 100], easing: ease);
    sc.setKeyframe(at + du, [s1, s1, 100], easing: Easing.easyEase);
    r.log.add('Tilted map $map by $tiltDeg° (roll $roll°) at ${at.toStringAsFixed(2)} s: comp layer $layerId, precomp $compId');
  }

  // ------------------------------------------------------------- punch_in

  /// camera_move {preset: "punch_in"}: a fast ease-in zoom (×amount) toward
  /// a point with motion blur and a whoosh. On the 2D camera, or on a
  /// layer / map group when "layer" or "map" is given (or the camera is 3D).
  /// Returns false for other presets.
  static bool cameraMove(Project p, Map<String, dynamic> c, double now, _Exec exec) {
    if (c['preset'] != 'punch_in') return false;
    final comp = p.editComp;
    final start = _num(c, 'start') ?? now;
    final du = math.max(comp.frameDuration, _num(c, 'duration') ?? 0.45);
    final end = start + du;
    var k = _num(c, 'amount') ?? 2.6;
    if (k > 10) k /= 100; // given in percent (260)
    if (k <= 0.05) throw CommandError('punch_in "amount" is the zoom factor (e.g. 2.6)');
    final ease = _ease(c['ease'], Easing.easeIn);

    // Target layer (scaled instead of the camera).
    Layer? target;
    final lid = c['layer'] ?? c['map'];
    if (lid is String && lid.isNotEmpty) {
      target = comp.layerById(lid) ?? comp.layerById('${lid}_g');
      if (target == null) throw CommandError('punch_in: no layer or map "$lid"');
    } else if (comp.camera.mode == CameraMode.threeD) {
      throw CommandError('punch_in uses the 2D camera, but this comp uses the 3D camera: pass "layer" (or "map") to punch in on it, or use camera_shot');
    }

    // The point (comp px on screen at "start"): point, a layer's centre, or the frame centre.
    var sx = comp.width / 2, sy = comp.height / 2;
    final pt = c['point'];
    final tgt = c['target'];
    if (pt is List && pt.length >= 2 && pt[0] is num && pt[1] is num) {
      sx = (pt[0] as num).toDouble();
      sy = (pt[1] as num).toDouble();
    } else if (tgt is String && tgt.isNotEmpty) {
      final tl = comp.layerById(tgt);
      if (tl == null) throw CommandError('punch_in: no layer "$tgt"');
      final m = Evaluator.worldMatrix(comp, tl, start);
      final a = tl.prop(Props.anchor).valueAt(start);
      final ax = tl.type == LayerType.nullObject ? a[0] : tl.width / 2, ay = tl.type == LayerType.nullObject ? a[1] : tl.height / 2;
      sx = m[0] * ax + m[4] * ay + m[12];
      sy = m[1] * ax + m[5] * ay + m[13];
    }

    if (target != null) {
      // Scale the layer about the point (in its parent's space).
      final pos = target.prop(Props.position), scl = target.prop(Props.scale);
      final p0 = pos.valueAt(start), s0 = scl.valueAt(start);
      final p1 = [sx - k * (sx - p0[0]), sy - k * (sy - p0[1]), p0.length > 2 ? p0[2] : 0.0];
      pos.setKeyframe(start, p0, easing: ease);
      pos.setKeyframe(end, p1, easing: Easing.hold);
      scl.setKeyframe(start, s0, easing: ease);
      scl.setKeyframe(end, [s0[0] * k, s0[1] * k, s0.length > 2 ? s0[2] : 100.0], easing: Easing.hold);
    } else {
      final rig = comp.camera;
      final wasFlat = rig.mode != CameraMode.twoD;
      rig.mode = CameraMode.twoD;
      final pan = rig.prop(CamProps.pan), zoom = rig.prop(CamProps.zoom2d);
      final pan0 = wasFlat ? [comp.width / 2, comp.height / 2] : pan.valueAt(start);
      final z0 = wasFlat ? 100.0 : math.max(1.0, zoom.scalarAt(start));
      if (wasFlat && !pan.isAnimated && !zoom.isAnimated) {
        pan.staticValue = [comp.width / 2, comp.height / 2];
        zoom.staticValue = [100];
      }
      // World point under the screen point; it stays put on screen.
      final qx = pan0[0] + (sx - comp.width / 2) * 100 / z0, qy = pan0[1] + (sy - comp.height / 2) * 100 / z0;
      final z1 = z0 * k;
      final cen = c['center'] == true;
      final pan1 = cen ? [qx, qy] : [qx - (qx - pan0[0]) * z0 / z1, qy - (qy - pan0[1]) * z0 / z1];
      pan.setKeyframe(start, [pan0[0], pan0[1]], easing: ease);
      pan.setKeyframe(end, pan1, easing: Easing.hold);
      zoom.setKeyframe(start, [z0], easing: ease);
      zoom.setKeyframe(end, [z1], easing: Easing.hold);
    }
    if (c['blur'] != false) exec({'op': 'set_comp', 'motion_blur': true});
    if (end > comp.duration) comp.duration = end;
    final snd = c['sound'];
    if (snd != false) exec({'op': 'add_sfx', 'kind': snd is String ? snd : 'whoosh', 'time': end});
    return true;
  }
}
