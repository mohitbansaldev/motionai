// win-43: ON-SCREEN TRANSFORM GIZMOS + CAMERA TOOLS (After Effects / Blender style).
//
// Move arrows (X red, Y green, Z blue, free-move square), rotation rings and
// scale boxes for the selected layer or the 3D camera (its body and its point
// of interest), in the Active Camera view and every working view (Top, Front,
// Left, Custom…). Camera tools orbit / pan / dolly the active camera with the
// mouse. Every change goes through the edit commands (one undo step per drag).
//
// Shortcuts (editor): W move · E rotate · R scale · C camera tools (cycles
// orbit → pan → dolly) · X world / local axes.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix3, Matrix4, Vector3, Vector4;

import '../../core/engine/evaluator.dart';
import '../../core/model/camera.dart';
import '../../core/model/layer.dart';
import '../../core/model/project.dart';
import '../../state/editor_controller.dart';

/// Viewer tool state (UI only, not saved in the project).
class ViewTools extends ChangeNotifier {
  ViewTools._();
  static final ViewTools instance = ViewTools._();

  static const transformTools = ['move', 'rotate', 'scale'];
  static const cameraTools = ['orbit', 'pan', 'dolly'];
  static const labels = {
    'move': 'Move (W)', 'rotate': 'Rotate (E)', 'scale': 'Scale (R)',
    'orbit': 'Orbit camera (C)', 'pan': 'Pan camera (C)', 'dolly': 'Dolly camera (C)',
  };
  static const icons = {
    'move': Icons.open_with_rounded, 'rotate': Icons.threesixty_rounded, 'scale': Icons.open_in_full_rounded,
    'orbit': Icons.threed_rotation_rounded, 'pan': Icons.pan_tool_outlined, 'dolly': Icons.zoom_in_map_rounded,
  };

  String _tool = 'move';
  bool _local = false;
  bool _gizmos = true;

  String get tool => _tool;
  bool get local => _local;
  bool get gizmos => _gizmos;
  bool get isCameraTool => cameraTools.contains(_tool);

  set tool(String t) {
    if (t == _tool) return;
    _tool = t;
    notifyListeners();
  }

  set local(bool v) {
    if (v == _local) return;
    _local = v;
    notifyListeners();
  }

  set gizmos(bool v) {
    if (v == _gizmos) return;
    _gizmos = v;
    notifyListeners();
  }

  /// C: from a transform tool → orbit; then orbit → pan → dolly → orbit.
  void cycleCamera() {
    final i = cameraTools.indexOf(_tool);
    tool = cameraTools[(i + 1) % cameraTools.length];
  }
}

const _axisColors = [Color(0xFFFF4F5E), Color(0xFF59E07A), Color(0xFF4F8BFF)];
const _hot = Color(0xFFFFFFFF);
const _free = Color(0xFFFFD54F);

/// A way to put world points on a viewer's screen (comp px of that viewer).
class GizmoView {
  final Offset? Function(Vector3 world) project;

  /// World directions of the viewer's screen right and down (free move).
  final Vector3 right, down;

  /// World position of the viewer's eye (null = orthographic).
  final Vector3? eye;
  GizmoView(this.project, this.right, this.down, {this.eye});

  static Offset? _apply(Matrix4 m, Vector3 p) {
    final v = m.transform(Vector4(p.x, p.y, p.z, 1));
    if (v.w <= 1e-6) return null;
    return Offset(v.x / v.w, v.y / v.w);
  }

  /// The Active Camera view (3D layers and the 3D camera's world).
  factory GizmoView.active(Composition comp, double t) {
    final cam = Evaluator.camera3D(comp, t);
    final proj = Evaluator.projection(cam);
    final cam2 = Evaluator.camera2D(comp, t);
    final m = cam2.multiplied(proj);
    return GizmoView((p) => _apply(m, p), cam.right, cam.down, eye: cam.position);
  }

  /// The Active Camera view for 2D layers (comp space through the 2D camera).
  factory GizmoView.flat(Composition comp, double t) {
    final cam2 = Evaluator.camera2D(comp, t);
    return GizmoView((p) {
      final v = cam2.transform3(Vector3(p.x, p.y, 0));
      return Offset(v.x, v.y);
    }, Vector3(1, 0, 0), Vector3(0, 1, 0));
  }

  /// A working view (Top / Front / Custom…).
  factory GizmoView.working(ViewCam vc) => GizmoView((p) {
        final q = vc.toScreen(p);
        return q.visible ? Offset(q.x, q.y) : null;
      }, vc.cam.right, vc.cam.down, eye: vc.ortho ? null : vc.cam.position);
}

/// What a gizmo moves: a layer, the camera body or its point of interest.
class GizmoTarget {
  final String kind; // layer | camera | poi
  final Layer? layer;
  final Vector3 origin;
  final List<Vector3> axes; // unit world directions for X, Y, Z
  final bool flat; // 2D layer: X and Y only
  final Matrix3? toParent; // world delta → parent-space delta (parented layers)

  GizmoTarget._(this.kind, this.layer, this.origin, this.axes, this.flat, this.toParent);

  bool get canRotate => kind != 'poi';
  bool get canScale => kind == 'layer';

  static GizmoTarget? forLayer(Composition comp, Layer l, double t, {required bool local}) {
    if (l.locked) return null;
    final m = Evaluator.worldMatrix(comp, l, t, {});
    final a = l.prop(Props.anchor).valueAt(t);
    final o = m.transform3(Vector3(a[0], a[1], a.length > 2 ? a[2] : 0));
    List<Vector3> axes = [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)];
    if (local) {
      final s = m.storage;
      final lx = Vector3(s[0], s[1], s[2]), ly = Vector3(s[4], s[5], s[6]), lz = Vector3(s[8], s[9], s[10]);
      if (lx.length > 1e-9 && ly.length > 1e-9 && lz.length > 1e-9) axes = [lx.normalized(), ly.normalized(), lz.normalized()];
    }
    Matrix3? toParent;
    final pid = l.parentId;
    final parent = pid == null ? null : comp.layerById(pid);
    if (parent != null) {
      final pm = Evaluator.worldMatrix(comp, parent, t, {}).getRotation();
      final inv = Matrix3.copy(pm);
      if (inv.invert() != 0) toParent = inv;
    }
    return GizmoTarget._('layer', l, o, axes, !l.is3D, toParent);
  }

  static GizmoTarget? forCamera(Composition comp, double t, String part, {required bool local}) {
    if (comp.camera.mode != CameraMode.threeD) return null;
    final cam = Evaluator.camera3D(comp, t);
    final world = [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)];
    if (part == 'poi') {
      if (comp.camera.type == 'one_node') return null;
      final q = comp.camera.prop(CamProps.poi).valueAt(t);
      return GizmoTarget._('poi', null, Vector3(q[0], q[1], q[2]), world, false, null);
    }
    final p = comp.camera.prop(CamProps.position).valueAt(t);
    final axes = local ? [cam.right.normalized(), cam.down.normalized(), cam.forward.normalized()] : world;
    return GizmoTarget._('camera', null, Vector3(p[0], p[1], p[2]), axes, false, null);
  }
}

/// A grabbed part: tool + axis (0 X, 1 Y, 2 Z, 3 free / uniform).
class GizmoHandle {
  final String tool;
  final int axis;
  const GizmoHandle(this.tool, this.axis);
  @override
  bool operator ==(Object o) => o is GizmoHandle && o.tool == tool && o.axis == axis;
  @override
  int get hashCode => Object.hash(tool, axis);
}

/// Screen geometry of a gizmo in one viewer.
class GizmoGeom {
  final GizmoTarget target;
  final String tool;
  final Offset o;
  final List<Offset?> ends; // axis tips (null = axis points at the viewer)
  final List<double> worldLen; // world length of each drawn axis
  final List<List<Offset>> rings; // rotate: projected circle per axis
  final List<double> ringSign;
  final double len; // drawn arrow length (comp px)
  final Offset? freeR, freeD; // screen vector of view right / down (worldLen[0] long)
  final double freeLen;
  GizmoGeom._(this.target, this.tool, this.o, this.ends, this.worldLen, this.rings, this.ringSign, this.len, this.freeR, this.freeD, this.freeLen);

  static GizmoGeom? build(GizmoTarget tg, GizmoView v, String tool, double len) {
    final o = v.project(tg.origin);
    if (o == null) return null;
    final ends = <Offset?>[];
    final wl = <double>[];
    for (int i = 0; i < 3; i++) {
      if (tg.flat && i == 2) {
        ends.add(null);
        wl.add(0);
        continue;
      }
      final probe = v.project(tg.origin + tg.axes[i] * 100);
      final px = probe == null ? 0.0 : (probe - o).distance;
      if (px < len * 0.02) {
        ends.add(null);
        wl.add(0);
        continue;
      }
      final k = 100 * len / px;
      final e = v.project(tg.origin + tg.axes[i] * k);
      // Foreshortened axes (pointing at the viewer) are hidden.
      if (e == null || (e - o).distance < len * 0.18) {
        ends.add(null);
        wl.add(k);
        continue;
      }
      ends.add(e);
      wl.add(k);
    }
    final valid = [for (int i = 0; i < 3; i++) if (wl[i] > 0) wl[i]];
    final kAvg = valid.isEmpty ? 100.0 : valid.reduce((a, b) => a + b) / valid.length;
    final rings = <List<Offset>>[];
    final signs = <double>[];
    if (tool == 'rotate') {
      for (int i = 0; i < 3; i++) {
        if (tg.flat && i != 2) {
          rings.add(const []);
          signs.add(1);
          continue;
        }
        final b1 = tg.axes[(i + 1) % 3], b2 = tg.axes[(i + 2) % 3];
        final pts = <Offset>[];
        for (int s = 0; s <= 64; s++) {
          final a = s / 64 * 2 * math.pi;
          final p = v.project(tg.origin + (b1 * math.cos(a) + b2 * math.sin(a)) * (kAvg * 0.8));
          if (p != null) pts.add(p);
        }
        rings.add(pts);
        // Screen winding of the ring (rotation sign).
        double sign = 1;
        if (pts.length > 17) {
          final a = pts[0] - o, b = pts[16] - o;
          final cross = a.dx * b.dy - a.dy * b.dx;
          sign = cross >= 0 ? 1 : -1;
        }
        signs.add(sign);
      }
    }
    final fr = v.project(tg.origin + v.right * kAvg), fd = v.project(tg.origin + v.down * kAvg);
    return GizmoGeom._(tg, tool, o, ends, wl, rings, signs, len, fr == null ? null : fr - o, fd == null ? null : fd - o, kAvg);
  }

  static double _segDist(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final l2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (l2 < 1e-9) return (p - a).distance;
    final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / l2).clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  /// The handle under [p] (comp px), within [tol].
  GizmoHandle? hit(Offset p, double tol) {
    switch (tool) {
      case 'rotate':
        GizmoHandle? best;
        var bd = tol;
        for (int i = 0; i < 3; i++) {
          final r = rings[i];
          for (int s = 0; s + 1 < r.length; s++) {
            final d = _segDist(p, r[s], r[s + 1]);
            if (d < bd) {
              bd = d;
              best = GizmoHandle('rotate', i);
            }
          }
        }
        return best;
      case 'scale':
        if ((p - o).distance < tol * 1.4) return const GizmoHandle('scale', 3);
        for (int i = 0; i < 3; i++) {
          final e = ends[i];
          if (e != null && (p - e).distance < tol * 1.5) return GizmoHandle('scale', i);
        }
        for (int i = 0; i < 3; i++) {
          final e = ends[i];
          if (e != null && _segDist(p, o, e) < tol * 0.7) return GizmoHandle('scale', i);
        }
        return null;
      default:
        GizmoHandle? best;
        var bd = tol;
        for (int i = 0; i < 3; i++) {
          final e = ends[i];
          if (e == null) continue;
          final d = _segDist(p, o + (e - o) * 0.18, e);
          if (d < bd) {
            bd = d;
            best = GizmoHandle('move', i);
          }
        }
        if (best != null) return best;
        if ((p - o).distance < tol * 1.6) return const GizmoHandle('move', 3);
        return null;
    }
  }
}

/// One drag of a gizmo handle → the edit commands for the current pointer.
class GizmoDrag {
  final Composition comp;
  final double t;
  final GizmoGeom g;
  final GizmoHandle h;
  final Offset start;
  late final List<double> startPos, startPoi, startRot, startScale;

  GizmoDrag(this.comp, this.t, this.g, this.h, this.start) {
    final tg = g.target;
    if (tg.kind == 'layer') {
      final l = tg.layer!;
      startPos = List.of(l.prop(Props.position).valueAt(t));
      startRot = List.of(l.prop(Props.rotation).valueAt(t));
      startScale = List.of(l.prop(Props.scale).valueAt(t));
      startPoi = const [];
    } else {
      final rig = comp.camera;
      startPos = List.of(rig.prop(CamProps.position).valueAt(t));
      startPoi = List.of(rig.prop(CamProps.poi).valueAt(t));
      startRot = List.of(rig.prop(CamProps.rotation).valueAt(t));
      startScale = const [];
    }
  }

  static double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;

  /// World movement for a screen drag [d] along axis i (or free).
  Vector3 _worldMove(Offset d) {
    final tg = g.target;
    if (h.axis < 3) {
      final e = g.ends[h.axis]!;
      final sv = e - g.o;
      final l2 = _dot(sv, sv);
      final u = l2 < 1e-9 ? 0.0 : _dot(d, sv) / l2;
      return tg.axes[h.axis] * (u * g.worldLen[h.axis]);
    }
    // Free move in the viewer's screen plane.
    var w = Vector3.zero();
    final fr = g.freeR, fd = g.freeD;
    if (fr != null && fd != null) {
      // Solve d = a·fr + b·fd (fr, fd are not always orthogonal on screen).
      final det = fr.dx * fd.dy - fr.dy * fd.dx;
      if (det.abs() > 1e-9) {
        final a = (d.dx * fd.dy - d.dy * fd.dx) / det;
        final b = (fr.dx * d.dy - fr.dy * d.dx) / det;
        w = (_viewRight * a + _viewDown * b) * g.freeLen;
      }
    }
    if (tg.flat) w.z = 0;
    return w;
  }

  double? _lastAngle;
  double _turned = 0;
  Vector3 _viewRight = Vector3(1, 0, 0);
  Vector3 _viewDown = Vector3(0, 1, 0);

  /// The viewer's screen axes (free move); call before [update].
  void setView(GizmoView v) {
    _viewRight = v.right.normalized();
    _viewDown = v.down.normalized();
  }

  List<Map<String, dynamic>> update(Offset p) {
    final d = p - start;
    final tg = g.target;
    switch (h.tool) {
      case 'move':
        var w = _worldMove(d);
        if (tg.toParent != null) w = tg.toParent!.transform(w);
        final np = [startPos[0] + w.x, startPos[1] + w.y, (startPos.length > 2 ? startPos[2] : 0) + w.z];
        if (tg.kind == 'layer') {
          return [
            {'op': 'set_property', 'target': tg.layer!.id, 'prop': Props.position, 'value': tg.flat ? [np[0], np[1], startPos.length > 2 ? startPos[2] : 0] : np},
          ];
        }
        if (tg.kind == 'poi') {
          return [
            {'op': 'set_property', 'target': 'camera', 'prop': CamProps.poi, 'value': [startPoi[0] + w.x, startPoi[1] + w.y, startPoi[2] + w.z]},
          ];
        }
        return [
          {'op': 'set_property', 'target': 'camera', 'prop': CamProps.position, 'value': np},
        ];
      case 'rotate':
        final i = h.axis;
        // Accumulate the angle around the gizmo centre (turns past 180° keep going).
        final a1 = math.atan2(p.dy - g.o.dy, p.dx - g.o.dx);
        final last = _lastAngle ?? math.atan2(start.dy - g.o.dy, start.dx - g.o.dx);
        var da = a1 - last;
        while (da > math.pi) {
          da -= 2 * math.pi;
        }
        while (da < -math.pi) {
          da += 2 * math.pi;
        }
        _lastAngle = a1;
        _turned += da;
        final deg = _turned * 180 / math.pi * (i < g.ringSign.length ? g.ringSign[i] : 1);
        final r = List<double>.of(startRot);
        while (r.length < 3) {
          r.add(0);
        }
        r[i] = startRot.length > i ? startRot[i] + deg : deg;
        return [
          {'op': 'set_property', 'target': tg.kind == 'layer' ? tg.layer!.id : 'camera', 'prop': Props.rotation, 'value': r},
        ];
      case 'scale':
        final s = List<double>.of(startScale);
        while (s.length < 3) {
          s.add(100);
        }
        if (h.axis == 3) {
          final f = math.max(0.01, 1 + (d.dx - d.dy) / (g.len * 1.5));
          for (int j = 0; j < 3; j++) {
            s[j] = startScale.length > j ? startScale[j] * f : 100 * f;
          }
        } else {
          final e = g.ends[h.axis]!;
          final dir = (e - g.o) / math.max(1e-9, (e - g.o).distance);
          final f = math.max(0.01, 1 + _dot(d, dir) / g.len);
          s[h.axis] = (startScale.length > h.axis ? startScale[h.axis] : 100) * f;
        }
        return [
          {'op': 'set_property', 'target': tg.layer!.id, 'prop': Props.scale, 'value': s},
        ];
    }
    return const [];
  }
}

/// Camera tools: orbit / pan / dolly the active camera (3D), or the 2D
/// camera's rotation / pan / zoom.
class CameraNav {
  final Composition comp;
  final double t;
  final String tool;
  final Offset start;
  late final List<double> pos, poi, ori, pan2, zoom2, rot2;
  late final Camera3DState cam;

  CameraNav(this.comp, this.t, this.tool, this.start) {
    final r = comp.camera;
    cam = Evaluator.camera3D(comp, t);
    pos = List.of(r.prop(CamProps.position).valueAt(t));
    poi = List.of(r.prop(CamProps.poi).valueAt(t));
    ori = List.of(r.prop(CamProps.orientation).valueAt(t));
    pan2 = List.of(r.prop(CamProps.pan).valueAt(t));
    zoom2 = List.of(r.prop(CamProps.zoom2d).valueAt(t));
    rot2 = List.of(r.prop(CamProps.rotation2d).valueAt(t));
  }

  static List<double> _v(Vector3 v) => [v.x, v.y, v.z];

  /// Rodrigues rotation of [v] around unit [k] by [a] radians.
  static Vector3 _rot(Vector3 v, Vector3 k, double a) {
    final c = math.cos(a), s = math.sin(a);
    return v * c + k.cross(v) * s + k * (k.dot(v) * (1 - c));
  }

  List<Map<String, dynamic>> update(Offset p, {double wheel = 0}) {
    final d = p - start;
    final rig = comp.camera;
    if (rig.mode == CameraMode.twoD) {
      final z = (zoom2.first / 100).clamp(0.01, 1000.0);
      switch (tool) {
        case 'orbit':
          return [
            {'op': 'set_property', 'target': 'camera', 'prop': CamProps.rotation2d, 'value': [rot2.first + d.dx * 0.3]},
          ];
        case 'pan':
          return [
            {'op': 'set_property', 'target': 'camera', 'prop': CamProps.pan, 'value': [pan2[0] - d.dx / z, pan2[1] - d.dy / z]},
          ];
        default:
          final f = math.exp(-(d.dy + wheel) * 0.004);
          return [
            {'op': 'set_property', 'target': 'camera', 'prop': CamProps.zoom2d, 'value': [(zoom2.first * f).clamp(1.0, 100000.0)]},
          ];
      }
    }
    final P = Vector3(pos[0], pos[1], pos[2]), Q = Vector3(poi[0], poi[1], poi[2]);
    final dist = math.max(10.0, (Q - P).length);
    // World units per screen pixel at the point of interest's distance.
    final upp = dist / math.max(1.0, cam.zoom);
    switch (tool) {
      case 'orbit':
        if (rig.type == 'one_node') {
          return [
            {'op': 'set_property', 'target': 'camera', 'prop': CamProps.orientation, 'value': [ori[0] + d.dy * 0.25, ori[1] - d.dx * 0.25, ori.length > 2 ? ori[2] : 0]},
          ];
        }
        // Orbit the camera around its point of interest: yaw about world up (−Y), pitch about the camera's right.
        var v = P - Q;
        v = _rot(v, Vector3(0, -1, 0), -d.dx * 0.006);
        final right = cam.right.normalized();
        final pitched = _rot(v, _rot(right, Vector3(0, -1, 0), -d.dx * 0.006), d.dy * 0.006);
        // Avoid flipping over the poles.
        final up = pitched.normalized().dot(Vector3(0, -1, 0)).abs();
        if (up < 0.985) v = pitched;
        return [
          {'op': 'set_property', 'target': 'camera', 'prop': CamProps.position, 'value': _v(Q + v)},
        ];
      case 'pan':
        final m = (cam.right * (-d.dx) + cam.down * (-d.dy)) * upp;
        return [
          {'op': 'set_property', 'target': 'camera', 'prop': CamProps.position, 'value': _v(P + m)},
          if (rig.type != 'one_node') {'op': 'set_property', 'target': 'camera', 'prop': CamProps.poi, 'value': _v(Q + m)},
        ];
      default: // dolly: along the view direction (two-node: toward the point of interest, which stays)
        final amount = (-(d.dy) * 2.5 - wheel * 2.0) * upp;
        final f = cam.forward.normalized();
        if (rig.type == 'one_node') {
          return [
            {'op': 'set_property', 'target': 'camera', 'prop': CamProps.position, 'value': _v(P + f * amount)},
          ];
        }
        final np = P + f * math.min(amount, dist - 5);
        return [
          {'op': 'set_property', 'target': 'camera', 'prop': CamProps.position, 'value': _v(np)},
        ];
    }
  }
}

/// Draws a gizmo (in the viewer's comp px; [px] = one screen pixel).
class GizmoPainter extends CustomPainter {
  final GizmoGeom g;
  final GizmoHandle? hot;
  final double px;
  GizmoPainter(this.g, this.hot, this.px);

  @override
  void paint(Canvas canvas, Size size) {
    final o = g.o;
    Paint line(Color c, double w) => Paint()
      ..color = c
      ..strokeWidth = w * px
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final shadow = Paint()
      ..color = const Color(0x88000000)
      ..strokeWidth = 5 * px
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    bool isHot(int i) => hot != null && hot!.axis == i && hot!.tool == g.tool;

    switch (g.tool) {
      case 'rotate':
        for (int i = 0; i < 3; i++) {
          final r = g.rings[i];
          if (r.length < 2) continue;
          final path = Path()..moveTo(r.first.dx, r.first.dy);
          for (final p in r.skip(1)) {
            path.lineTo(p.dx, p.dy);
          }
          canvas.drawPath(path, shadow);
          canvas.drawPath(path, line(isHot(i) ? _hot : _axisColors[i], isHot(i) ? 3.2 : 2.2));
        }
        canvas.drawCircle(o, 3.5 * px, Paint()..color = _free);
      case 'scale':
        for (int i = 0; i < 3; i++) {
          final e = g.ends[i];
          if (e == null) continue;
          final col = isHot(i) ? _hot : _axisColors[i];
          canvas.drawLine(o, e, shadow);
          canvas.drawLine(o, e, line(col, 2.2));
          final r = Rect.fromCenter(center: e, width: 11 * px, height: 11 * px);
          canvas.drawRect(r.inflate(1.2 * px), Paint()..color = const Color(0x99000000));
          canvas.drawRect(r, Paint()..color = col);
        }
        final c = Rect.fromCenter(center: o, width: 13 * px, height: 13 * px);
        canvas.drawRect(c.inflate(1.2 * px), Paint()..color = const Color(0x99000000));
        canvas.drawRect(c, Paint()..color = isHot(3) ? _hot : _free);
      default:
        for (int i = 0; i < 3; i++) {
          final e = g.ends[i];
          if (e == null) continue;
          final col = isHot(i) ? _hot : _axisColors[i];
          final dir = (e - o) / math.max(1e-9, (e - o).distance);
          final nrm = Offset(-dir.dy, dir.dx);
          final base = e - dir * (14 * px);
          canvas.drawLine(o + dir * (6 * px), base, shadow);
          canvas.drawLine(o + dir * (6 * px), base, line(col, isHot(i) ? 3.2 : 2.4));
          final head = Path()
            ..moveTo(e.dx, e.dy)
            ..lineTo(base.dx + nrm.dx * 6 * px, base.dy + nrm.dy * 6 * px)
            ..lineTo(base.dx - nrm.dx * 6 * px, base.dy - nrm.dy * 6 * px)
            ..close();
          canvas.drawPath(head, Paint()..color = const Color(0x99000000)..style = PaintingStyle.stroke..strokeWidth = 2 * px);
          canvas.drawPath(head, Paint()..color = col);
          _label(canvas, 'XYZ'[i], e + dir * (9 * px), col);
        }
        final sq = Rect.fromCenter(center: o, width: 12 * px, height: 12 * px);
        canvas.drawRect(sq.inflate(1.2 * px), Paint()..color = const Color(0x99000000));
        canvas.drawRect(sq, Paint()..color = (isHot(3) ? _hot : _free).withValues(alpha: 0.9));
    }
  }

  void _label(Canvas canvas, String s, Offset at, Color col) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: col, fontSize: 11 * px, fontWeight: FontWeight.w800, shadows: const [Shadow(blurRadius: 3, color: Colors.black)])),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant GizmoPainter old) => true;
}

/// The gizmo target for the editor's selection in a viewer (null = nothing
/// to show). [working] = a working 3D view (2D layers have no gizmo there).
GizmoTarget? gizmoTargetFor(EditorController c, {required bool working, String cameraPart = 'camera'}) {
  final tools = ViewTools.instance;
  if (!tools.gizmos || tools.isCameraTool || c.playing) return null;
  final comp = c.comp;
  if (c.cameraSelected) {
    if (!working) return null; // the active camera cannot grab itself
    return GizmoTarget.forCamera(comp, c.time, cameraPart, local: tools.local);
  }
  final l = c.selectedLayer;
  if (l == null || l.type == LayerType.audio) return null;
  if (working && !l.is3D) return null;
  return GizmoTarget.forLayer(comp, l, c.time, local: tools.local);
}

/// The tool a target can use ([tool] when it can, else move).
String toolFor(GizmoTarget tg, String tool) {
  if (tool == 'scale' && !tg.canScale) return 'move';
  if (tool == 'rotate' && !tg.canRotate) return 'move';
  return ViewTools.transformTools.contains(tool) ? tool : 'move';
}

/// The view for a target in the Active Camera viewer.
GizmoView activeViewFor(Composition comp, double t, GizmoTarget tg) =>
    tg.flat ? GizmoView.flat(comp, t) : GizmoView.active(comp, t);
