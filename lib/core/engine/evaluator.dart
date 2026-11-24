import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../model/camera.dart';
import '../model/layer.dart';
import '../model/project.dart';

const double _deg = math.pi / 180;
const double kNearPlane = 1.0;

/// A layer ready to draw at one moment in time.
class RenderItem {
  final Layer layer;

  /// Maps layer-local pixels (0..width, 0..height) to composition pixels.
  /// May contain perspective (use [project] for points).
  final Matrix4 matrix;
  final double opacity; // 0..1
  final double depth; // camera-space distance of the layer center (3D only)
  final double dofBlur; // depth-of-field blur radius in px (0 = sharp)

  RenderItem({
    required this.layer,
    required this.matrix,
    required this.opacity,
    required this.depth,
    required this.dofBlur,
  });

  /// Projects a layer-local point to composition pixels.
  Vector2 project(double x, double y) => projectPoint(matrix, x, y);

  /// The four corners of the layer on screen (TL, TR, BR, BL).
  List<Vector2> corners() => [
        project(0, 0),
        project(layer.width, 0),
        project(layer.width, layer.height),
        project(0, layer.height),
      ];

  bool containsPoint(double x, double y) => pointInQuad(Vector2(x, y), corners());
}

Vector2 projectPoint(Matrix4 m, double x, double y) {
  final v = m.transform(Vector4(x, y, 0, 1));
  final w = v.w.abs() < 1e-9 ? 1e-9 : v.w;
  return Vector2(v.x / w, v.y / w);
}

bool pointInQuad(Vector2 p, List<Vector2> q) {
  bool inside = false;
  for (int i = 0, j = q.length - 1; i < q.length; j = i++) {
    final a = q[i], b = q[j];
    if (((a.y > p.y) != (b.y > p.y)) && (p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x)) {
      inside = !inside;
    }
  }
  return inside;
}

/// Camera basis in composition space (x right, y down, z away from viewer).
class Camera3DState {
  final Vector3 position;
  final Vector3 right;
  final Vector3 down;
  final Vector3 forward;
  final double zoom;
  final double cx, cy;
  final double focus;
  final double aperture;

  Camera3DState({
    required this.position,
    required this.right,
    required this.down,
    required this.forward,
    required this.zoom,
    required this.cx,
    required this.cy,
    required this.focus,
    required this.aperture,
  });

  /// Distance of a world point along the view direction.
  double depthOf(Vector3 world) => (world - position).dot(forward);
}

class Evaluator {
  /// Everything visible at time [t], in paint order (first = bottom).
  static List<RenderItem> evaluate(Composition comp, double t) {
    final worldCache = <String, Matrix4>{};
    final cam = camera3D(comp, t);
    final proj = projection(cam);
    final cam2d = camera2D(comp, t);

    final items = <RenderItem>[];
    final group3D = <RenderItem>[];

    void flush3D() {
      if (group3D.isEmpty) return;
      // Far first; stable for equal depth.
      final indexed = group3D.asMap().entries.toList()
        ..sort((a, b) {
          final c = b.value.depth.compareTo(a.value.depth);
          return c != 0 ? c : a.key.compareTo(b.key);
        });
      items.addAll(indexed.map((e) => e.value));
      group3D.clear();
    }

    // layers[0] is the top layer, so paint from the end.
    for (int i = comp.layers.length - 1; i >= 0; i--) {
      final layer = comp.layers[i];
      if (!layer.isActiveAt(t) || layer.type == LayerType.nullObject || layer.type == LayerType.audio) continue;
      final opacity = (layer.prop(Props.opacity).scalarAt(t) / 100).clamp(0.0, 1.0);
      if (opacity <= 0) continue;
      final world = worldMatrix(comp, layer, t, worldCache);

      if (layer.is3D) {
        // Cull layers crossing behind the camera.
        bool behind = false;
        for (final c in [
          Vector3(0, 0, 0),
          Vector3(layer.width, 0, 0),
          Vector3(layer.width, layer.height, 0),
          Vector3(0, layer.height, 0),
        ]) {
          if (cam.depthOf(world.transformed3(c)) < kNearPlane) {
            behind = true;
            break;
          }
        }
        if (behind) continue;
        final center = world.transformed3(Vector3(layer.width / 2, layer.height / 2, 0));
        final depth = cam.depthOf(center);
        double blur = 0;
        if (comp.camera.mode == CameraMode.threeD && cam.aperture > 0) {
          blur = cam.aperture * 0.4 * (depth - cam.focus).abs() / math.max(depth, 1.0);
        }
        group3D.add(RenderItem(
          layer: layer,
          matrix: cam2d.multiplied(proj).multiplied(world),
          opacity: opacity,
          depth: depth,
          dofBlur: blur,
        ));
      } else {
        flush3D();
        items.add(RenderItem(
          layer: layer,
          matrix: cam2d.multiplied(world),
          opacity: opacity,
          depth: 0,
          dofBlur: 0,
        ));
      }
    }
    flush3D();
    return items;
  }

  /// Layer transform: T(position) · Rx · Ry · Rz · S(scale) · T(-anchor).
  static Matrix4 localMatrix(Layer l, double t) {
    final p = l.prop(Props.position).valueAt(t);
    final a = l.prop(Props.anchor).valueAt(t);
    final s = l.prop(Props.scale).valueAt(t);
    final r = l.prop(Props.rotation).valueAt(t);
    final is3D = l.is3D;
    final m = Matrix4.translationValues(p[0], p[1], is3D ? p[2] : 0);
    if (is3D) {
      if (r[0] != 0) m.multiply(Matrix4.rotationX(r[0] * _deg));
      if (r[1] != 0) m.multiply(Matrix4.rotationY(r[1] * _deg));
    }
    if (r[2] != 0) m.multiply(Matrix4.rotationZ(r[2] * _deg));
    m.multiply(Matrix4.diagonal3Values(s[0] / 100, s[1] / 100, is3D ? s[2] / 100 : 1));
    m.multiply(Matrix4.translationValues(-a[0], -a[1], is3D ? -a[2] : 0));
    return m;
  }

  /// Local matrix combined with the parent chain.
  static Matrix4 worldMatrix(Composition comp, Layer l, double t, [Map<String, Matrix4>? cache, int depth = 0]) {
    final cached = cache?[l.id];
    if (cached != null) return cached;
    var m = localMatrix(l, t);
    final pid = l.parentId;
    if (pid != null && depth < 16) {
      final parent = comp.layerById(pid);
      if (parent != null && parent.id != l.id) {
        m = worldMatrix(comp, parent, t, cache, depth + 1).multiplied(m);
      }
    }
    cache?[l.id] = m;
    return m;
  }

  /// The active 3D camera, or the fixed default one when mode is not 3D.
  static Camera3DState camera3D(Composition comp, double t) {
    final w = comp.width, h = comp.height;
    final rig = comp.camera;
    Vector3 pos, poi;
    double zoom, roll, focus, aperture;
    if (rig.mode == CameraMode.threeD) {
      final p = rig.prop(CamProps.position).valueAt(t);
      final q = rig.prop(CamProps.poi).valueAt(t);
      pos = Vector3(p[0], p[1], p[2]);
      poi = Vector3(q[0], q[1], q[2]);
      zoom = math.max(1.0, rig.prop(CamProps.zoom).scalarAt(t));
      roll = rig.prop(CamProps.roll).scalarAt(t);
      focus = rig.prop(CamProps.focus).scalarAt(t);
      aperture = math.max(0.0, rig.prop(CamProps.aperture).scalarAt(t));
    } else {
      zoom = defaultZoomFor(w);
      pos = Vector3(w / 2, h / 2, -zoom);
      poi = Vector3(w / 2, h / 2, 0);
      roll = 0;
      focus = zoom;
      aperture = 0;
    }
    var f = poi - pos;
    if (f.length < 1e-6) f = Vector3(0, 0, 1);
    f.normalize();
    var r = Vector3(0, 1, 0).cross(f);
    if (r.length < 1e-6) r = Vector3(1, 0, 0);
    r.normalize();
    var d = f.cross(r)..normalize();
    if (roll != 0) {
      final c = math.cos(roll * _deg), s = math.sin(roll * _deg);
      final r2 = r * c + d * s;
      final d2 = d * c - r * s;
      r = r2;
      d = d2;
    }
    return Camera3DState(
      position: pos,
      right: r,
      down: d,
      forward: f,
      zoom: zoom,
      cx: w / 2,
      cy: h / 2,
      focus: focus,
      aperture: aperture,
    );
  }

  /// World → composition-screen matrix with perspective in the w row.
  static Matrix4 projection(Camera3DState c) {
    final row0 = c.right * c.zoom + c.forward * c.cx;
    final row1 = c.down * c.zoom + c.forward * c.cy;
    final row3 = c.forward;
    final m = Matrix4.zero();
    void setRow(int i, Vector3 v, double tw) {
      m.setEntry(i, 0, v.x);
      m.setEntry(i, 1, v.y);
      m.setEntry(i, 2, v.z);
      m.setEntry(i, 3, tw);
    }

    setRow(0, row0, -row0.dot(c.position));
    setRow(1, row1, -row1.dot(c.position));
    // Constant z keeps the matrix invertible (Flutter hit-testing needs it).
    m.setEntry(2, 3, 1);
    setRow(3, row3, -row3.dot(c.position));
    return m;
  }

  /// Screen-space 2D camera (identity unless mode is twoD).
  static Matrix4 camera2D(Composition comp, double t) {
    final rig = comp.camera;
    if (rig.mode != CameraMode.twoD) return Matrix4.identity();
    final cx = comp.width / 2, cy = comp.height / 2;
    final pan = rig.prop(CamProps.pan).valueAt(t);
    final z = rig.prop(CamProps.zoom2d).scalarAt(t) / 100;
    var rot = rig.prop(CamProps.rotation2d).scalarAt(t);
    final amp = rig.prop(CamProps.shake).scalarAt(t);
    double sx = 0, sy = 0;
    if (amp > 0) {
      final f = rig.prop(CamProps.shakeSpeed).scalarAt(t);
      sx = amp * shakeNoise(t * f, 0.0);
      sy = amp * shakeNoise(t * f, 3.7);
      rot += amp * 0.02 * shakeNoise(t * f, 7.1);
    }
    return Matrix4.translationValues(cx, cy, 0)
      ..multiply(Matrix4.rotationZ(-rot * _deg))
      ..multiply(Matrix4.diagonal3Values(z, z, 1))
      ..multiply(Matrix4.translationValues(-(pan[0] + sx), -(pan[1] + sy), 0));
  }

  /// Smooth deterministic pseudo-noise in about -1..1.
  static double shakeNoise(double x, double seed) =>
      math.sin(x * 6.13 + seed) * 0.5 + math.sin(x * 13.71 + seed * 2.3) * 0.3 + math.sin(x * 27.1 + seed * 4.1) * 0.2;
}
