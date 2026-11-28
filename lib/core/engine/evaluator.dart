import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../model/camera.dart';
import '../model/layer.dart';
import '../model/project.dart';
import '../presets/realism.dart'; // V2-D

const double _deg = math.pi / 180;
/// Layers closer to the camera than this (px) are culled: a layer almost
/// touching the lens projects to a gigantic size and can stall the GPU.
const double kNearPlane = 25.0;

/// A layer ready to draw at one moment in time.
class RenderItem {
  final Layer layer;

  /// Maps layer-local pixels (0..width, 0..height) to composition pixels.
  /// May contain perspective (use [project] for points).
  final Matrix4 matrix;
  final double opacity; // 0..1
  final double depth; // camera-space distance of the layer center (3D only)
  final double dofBlur; // depth-of-field blur radius in px (0 = sharp)

  /// On-screen movement of the layer centre over the last frame (comp px),
  /// set when motion blur is wanted (comp `motionBlur` or a `motion_blur` effect).
  final double vx, vy;

  /// Track matte: the evaluated matte layer (drawn only as a mask).
  final RenderItem? matte;
  final bool matteInverse;

  /// win-30: only this part of the layer is drawn ([x0, y0, x1, y1] in
  /// layer-local px) — set when the layer reaches behind the camera (a big
  /// background or floor during a pass-by / orbit). The part in view is
  /// drawn instead of culling the whole layer (which gave black frames).
  final List<double>? crop;

  /// 3D only: unit normal of the layer's plane (toward the camera) and the
  /// camera's distance to that plane — orders stacked parallel layers.
  final double nx, ny, nz, planeDist;

  RenderItem({
    required this.layer,
    required this.matrix,
    required this.opacity,
    required this.depth,
    required this.dofBlur,
    this.vx = 0,
    this.vy = 0,
    this.matte,
    this.matteInverse = false,
    this.crop,
    this.nx = 0,
    this.ny = 0,
    this.nz = 0,
    this.planeDist = 0,
  });

  RenderItem withExtras({double? vx, double? vy, RenderItem? matte, bool? matteInverse}) => RenderItem(
        layer: layer,
        matrix: matrix,
        opacity: opacity,
        depth: depth,
        dofBlur: dofBlur,
        crop: crop,
        nx: nx,
        ny: ny,
        nz: nz,
        planeDist: planeDist,
        vx: vx ?? this.vx,
        vy: vy ?? this.vy,
        matte: matte ?? this.matte,
        matteInverse: matteInverse ?? this.matteInverse,
      );

  /// Screen speed in comp px per frame.
  double get speed => math.sqrt(vx * vx + vy * vy);

  /// Projects a layer-local point to composition pixels.
  Vector2 project(double x, double y) => projectPoint(matrix, x, y);

  /// The four corners of the layer (its drawn [crop] if any) on screen (TL, TR, BR, BL).
  List<Vector2> corners() {
    final c = crop;
    if (c != null) return [project(c[0], c[1]), project(c[2], c[1]), project(c[2], c[3]), project(c[0], c[3])];
    return [
      project(0, 0),
      project(layer.width, 0),
      project(layer.width, layer.height),
      project(0, layer.height),
    ];
  }

  /// Matrix for drawing: maps the [crop] box (0..drawWidth, 0..drawHeight) to the screen.
  Matrix4 get drawMatrix {
    final c = crop;
    if (c == null) return matrix;
    return matrix.multiplied(Matrix4.translationValues(c[0], c[1], 0));
  }

  double get drawWidth => crop == null ? layer.width : crop![2] - crop![0];
  double get drawHeight => crop == null ? layer.height : crop![3] - crop![1];

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

/// Camera matrices for one moment, shared by every layer.
class _Frame {
  final Composition comp;
  final double t;
  final Map<String, Matrix4> worldCache = {};
  final Camera3DState cam;
  final Matrix4 proj;
  final Matrix4 cam2d;

  /// cam2d · proj, computed once per frame instead of once per 3D layer.
  final Matrix4 camProj;

  /// True when [cam2d] is the identity (camera mode is not 2D).
  final bool flat2d;

  /// win-40: orthographic working view (no perspective divide).
  final bool ortho;

  /// camera position · forward, for depth along the view axis.
  final double camDot;
  _Frame._(this.comp, this.t, this.cam, this.proj, this.cam2d, this.flat2d, {this.ortho = false})
      : camProj = flat2d ? proj : cam2d.multiplied(proj),
        camDot = cam.position.dot(cam.forward);

  factory _Frame(Composition comp, double t, {ViewCam? view}) {
    if (view != null) return _Frame._(comp, t, view.cam, view.proj, Matrix4.identity(), true, ortho: view.ortho); // win-40
    final cam = Evaluator.camera3D(comp, t);
    return _Frame._(comp, t, cam, Evaluator.projection(cam), Evaluator.camera2D(comp, t), comp.camera.mode != CameraMode.twoD);
  }

  /// Depth of layer-local (x, y) for [world] is a0·x + a1·y + a2.
  (double, double, double) depthCoefs(Matrix4 world) {
    final m = world.storage, f = cam.forward;
    final fx = f.x, fy = f.y, fz = f.z;
    return (
      m[0] * fx + m[1] * fy + m[2] * fz,
      m[4] * fx + m[5] * fy + m[6] * fz,
      m[12] * fx + m[13] * fy + m[14] * fz - camDot,
    );
  }
}

class Evaluator {
  /// Everything visible at time [t], in paint order (first = bottom).
  ///
  /// [velocity] false skips the motion-blur velocity (a second evaluation at
  /// t − 1 frame); the live preview passes false while playing, where motion
  /// blur is not drawn anyway.
  static List<RenderItem> evaluate(Composition comp, double t, {bool velocity = true, ViewCam? view}) {
    final f = _Frame(comp, t, view: view); // win-40: working 3D views (Top, Front, Custom…)
    if (view != null) velocity = false;
    _Frame? prev; // previous frame, for motion-blur velocity (lazy)

    // Layers used as a track matte by another layer are not drawn themselves.
    Set<String>? matteIds;
    for (final l in comp.layers) {
      final m = l.matte;
      if (m != null && m.layerId != l.id) (matteIds ??= <String>{}).add(m.layerId);
    }

    final items = <RenderItem>[];
    final group3D = <RenderItem>[];

    void flush3D() {
      if (group3D.isEmpty) return;
      if (group3D.length == 1) {
        items.add(group3D.first);
      } else {
        final key = stackedDepthKeys(group3D);
        // Far first; stable for equal depth.
        final order = List<int>.generate(group3D.length, (i) => i)
          ..sort((a, b) {
            final c = key[b].compareTo(key[a]);
            return c != 0 ? c : a.compareTo(b);
          });
        for (final i in order) {
          items.add(group3D[i]);
        }
      }
      group3D.clear();
    }

    // layers[0] is the top layer, so paint from the end.
    for (int i = comp.layers.length - 1; i >= 0; i--) {
      final layer = comp.layers[i];
      if (!layer.isActiveAt(t) || (layer.type == LayerType.nullObject && !layer.adjustment) || layer.type == LayerType.audio) continue; // V2-D: adjustment nulls
      if (matteIds != null && matteIds.contains(layer.id)) continue;
      if (view != null && !layer.is3D) continue; // win-40: working views show 3D layers only (like AE)
      var item = _item(f, layer);
      if (item == null) continue;

      // Track matte.
      final m = layer.matte;
      if (m != null && m.layerId != layer.id) {
        final ml = comp.layerById(m.layerId);
        if (ml != null) {
          final active = t >= ml.start - 1e-9 && t < ml.end - 1e-9 &&
              ml.type != LayerType.nullObject && ml.type != LayerType.audio;
          final mi = active ? _item(f, ml) : null;
          if (mi == null) {
            if (!m.inverse) continue; // nothing to show through
          } else {
            item = item.withExtras(matte: mi, matteInverse: m.inverse);
          }
        }
      }

      // Motion blur velocity: where the centre was one frame ago.
      if (velocity && (comp.motionBlur || _hasMotionBlurFx(layer))) {
        prev ??= _Frame(comp, t - comp.frameDuration);
        final before = _screenMatrix(prev, layer);
        if (before != null) {
          final cx = layer.width / 2, cy = layer.height / 2;
          final now = projectPoint(item.matrix, cx, cy);
          final was = projectPoint(before, cx, cy);
          final vx = now.x - was.x, vy = now.y - was.y;
          if (vx.isFinite && vy.isFinite) item = item.withExtras(vx: vx, vy: vy);
        }
      }

      if (layer.is3D) {
        group3D.add(item);
      } else {
        flush3D();
        items.add(item);
      }
    }
    flush3D();
    return items;
  }

  static bool _hasMotionBlurFx(Layer l) {
    for (final e in l.effects) {
      if (e.enabled && e.type == 'motion_blur') return true;
    }
    return false;
  }

  /// Layer → screen matrix, or null if a 3D layer crosses the near plane.
  static Matrix4? _screenMatrix(_Frame f, Layer layer) {
    final world = worldMatrix(f.comp, layer, f.t, f.worldCache);
    if (!layer.is3D) return f.flat2d ? world.clone() : f.cam2d.multiplied(world);
    if (_crossesNearPlane(f.depthCoefs(world), layer)) return null;
    return f.camProj.multiplied(world);
  }

  /// True when a corner of the 3D layer is closer to the camera than [kNearPlane].
  static bool _crossesNearPlane((double, double, double) d, Layer layer) {
    final (a0, a1, a2) = d;
    final w = layer.width * a0, h = layer.height * a1;
    return a2 < kNearPlane || w + a2 < kNearPlane || w + h + a2 < kNearPlane || h + a2 < kNearPlane;
  }

  /// Paint-order depth per 3D item. Centre depth, except for stacks of
  /// parallel layers lying close together (pages of a tilted calendar, cards
  /// on a tilted board): their centres sit at different depths once tilted,
  /// so a big back plate could sort in front of the pages on it (V3-C bug:
  /// the calendar went black when tilted). A stack sorts by the distance to
  /// each plane instead — always right for parallel planes — around the
  /// stack's mean depth.
  static List<double> stackedDepthKeys(List<RenderItem> g) {
    final n = g.length;
    final key = [for (final it in g) it.depth];
    final root = List<int>.generate(n, (i) => i);
    int find(int i) {
      while (root[i] != i) {
        root[i] = root[root[i]];
        i = root[i];
      }
      return i;
    }

    var any = false;
    for (int i = 0; i < n; i++) {
      final a = g[i];
      if (a.planeDist <= 0) continue;
      for (int j = i + 1; j < n; j++) {
        final b = g[j];
        if (b.planeDist <= 0) continue;
        final dot = a.nx * b.nx + a.ny * b.ny + a.nz * b.nz;
        if (dot < 0.9995) continue;
        final gap = (a.planeDist - b.planeDist).abs();
        if (gap > 0.02 * math.max(1.0, math.min(a.depth, b.depth))) continue;
        final ra = find(i), rb = find(j);
        if (ra != rb) {
          root[rb] = ra;
          any = true;
        }
      }
    }
    if (!any) return key;
    final groups = <int, List<int>>{};
    for (int i = 0; i < n; i++) {
      (groups[find(i)] ??= []).add(i);
    }
    for (final m in groups.values) {
      if (m.length < 2) continue;
      var mean = 0.0;
      for (final i in m) {
        mean += g[i].depth;
      }
      mean /= m.length;
      // Farthest plane first; equal planes keep their layer order.
      final byPlane = [...m]..sort((a, b) {
          final c = g[b].planeDist.compareTo(g[a].planeDist);
          return c != 0 ? c : a.compareTo(b);
        });
      for (int r = 0; r < byPlane.length; r++) {
        key[byPlane[r]] = mean - r * 1e-6 * math.max(1.0, mean);
      }
    }
    return key;
  }

  /// The part of a layer that crosses the near plane worth drawing:
  /// layer rect ∩ (depth ≥ 2 × near plane) ∩ view frustum (+10% margin),
  /// as a box [x0, y0, x1, y1] in layer px — or null when nothing is in view
  /// or the box would still reach behind the camera. [m] maps layer-local
  /// points to the screen with w = depth; [d] gives depth = d0·x + d1·y + d2.
  static List<double>? nearCrop(Matrix4 m, (double, double, double) d, double lw, double lh, double cw, double ch) {
    final s = m.storage;
    final (a0, a1, a2) = d;
    final mx = cw * 0.1, my = ch * 0.1;
    // Half-planes a·x + b·y + c ≥ 0 in layer-local coordinates.
    final planes = <List<double>>[
      [a0, a1, a2 - kNearPlane * 2],
      [s[0] + mx * a0, s[4] + mx * a1, s[12] + mx * a2], // screen x ≥ −mx
      [(cw + mx) * a0 - s[0], (cw + mx) * a1 - s[4], (cw + mx) * a2 - s[12]], // x ≤ cw + mx
      [s[1] + my * a0, s[5] + my * a1, s[13] + my * a2], // y ≥ −my
      [(ch + my) * a0 - s[1], (ch + my) * a1 - s[5], (ch + my) * a2 - s[13]], // y ≤ ch + my
    ];
    var poly = <List<double>>[
      [0, 0],
      [lw, 0],
      [lw, lh],
      [0, lh],
    ];
    for (final pl in planes) {
      double side(List<double> p) => pl[0] * p[0] + pl[1] * p[1] + pl[2];
      final out = <List<double>>[];
      for (int i = 0; i < poly.length; i++) {
        final p = poly[i], q = poly[(i + 1) % poly.length];
        final sp = side(p), sq = side(q);
        if (sp >= 0) out.add(p);
        if ((sp >= 0) != (sq >= 0)) {
          final k = sp / (sp - sq);
          out.add([p[0] + (q[0] - p[0]) * k, p[1] + (q[1] - p[1]) * k]);
        }
      }
      poly = out;
      if (poly.length < 3) return null;
    }
    double x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    for (final p in poly) {
      x0 = math.min(x0, p[0]);
      y0 = math.min(y0, p[1]);
      x1 = math.max(x1, p[0]);
      y1 = math.max(y1, p[1]);
    }
    x0 = x0.clamp(0.0, lw);
    y0 = y0.clamp(0.0, lh);
    x1 = x1.clamp(0.0, lw);
    y1 = y1.clamp(0.0, lh);
    if (x1 - x0 < 1 || y1 - y0 < 1) return null;
    // The box corners must all be in front of the near plane too.
    for (final p in [
      [x0, y0],
      [x1, y0],
      [x1, y1],
      [x0, y1],
    ]) {
      if (a0 * p[0] + a1 * p[1] + a2 < kNearPlane) return null;
    }
    return [x0, y0, x1, y1];
  }

  static RenderItem? _item(_Frame f, Layer layer) {
    final t = f.t;
    final opacity = (layer.prop(Props.opacity).scalarAt(t) / 100).clamp(0.0, 1.0);
    if (opacity <= 0) return null;
    final world = worldMatrix(f.comp, layer, t, f.worldCache);

    if (layer.is3D) {
      final d = f.depthCoefs(world);
      List<double>? crop;
      if (_crossesNearPlane(d, layer)) {
        // Draw only the part in view (in front of the camera); cull when none.
        crop = nearCrop(f.camProj.multiplied(world), d, layer.width, layer.height, f.comp.width, f.comp.height);
        if (crop == null) return null;
      }
      final cx = crop == null ? layer.width / 2 : (crop[0] + crop[2]) / 2;
      final cy = crop == null ? layer.height / 2 : (crop[1] + crop[3]) / 2;
      final depth = d.$1 * cx + d.$2 * cy + d.$3;
      double blur = 0;
      if (f.comp.camera.mode == CameraMode.threeD && f.cam.aperture > 0) {
        blur = f.cam.aperture * 0.4 * (depth - f.cam.focus).abs() / math.max(depth, 1.0);
      }
      // V2-D >>> w = 1 at the layer centre (same projection): compositor
      // blurs inside the perspective transform are sized correctly.
      final mat = f.camProj.multiplied(world);
      if (!f.ortho) Realism.normalizeW(mat, depth); // win-40: ortho views have w = 1 already
      // <<< V2-D
      final ws = world.storage;
      var n = Vector3(ws[0], ws[1], ws[2]).cross(Vector3(ws[4], ws[5], ws[6]));
      var pd = 0.0;
      if (n.length2 > 1e-18) {
        n.normalize();
        pd = n.dot(Vector3(ws[12], ws[13], ws[14]) - f.cam.position);
        if (pd > 0) {
          n = -n;
        } else {
          pd = -pd;
        }
      }
      return RenderItem(
        layer: layer,
        matrix: mat,
        opacity: opacity,
        depth: depth,
        dofBlur: blur,
        crop: crop,
        nx: n.x,
        ny: n.y,
        nz: n.z,
        planeDist: pd,
      );
    }
    return RenderItem(
      layer: layer,
      // The world matrix is cached for this frame only; parents share it, so copy.
      matrix: f.flat2d ? world.clone() : f.cam2d.multiplied(world),
      opacity: opacity,
      depth: 0,
      dofBlur: 0,
    );
  }

  /// Layer transform: T(position) · Rx · Ry · Rz · S(scale) · T(-anchor).
  /// With a motion path the position is the path point at `path_progress`
  /// plus the layer's own position (as an offset); `orient` adds the path
  /// direction to the Z rotation.
  static Matrix4 localMatrix(Layer l, double t) {
    final p = l.prop(Props.position).valueAt(t);
    final a = l.prop(Props.anchor).valueAt(t);
    final s = l.prop(Props.scale).valueAt(t);
    final r = l.prop(Props.rotation).valueAt(t);
    final is3D = l.is3D;
    double rz = r[2];
    final path = l.path;
    if (path != null && path.points.isNotEmpty) {
      final prog = (l.props[Props.pathProgress]?.scalarAt(t) ?? 0) / 100;
      final ps = path.sample(prog);
      p[0] += ps.x;
      p[1] += ps.y;
      if (path.orient) rz += ps.angle;
    }
    // Built directly (no temporary rotation / scale matrices): the linear
    // part is L = Rx·Ry·Rz·S and the translation p − L·anchor.
    double r00 = 1, r01 = 0, r02 = 0, r10 = 0, r11 = 1, r12 = 0, r20 = 0, r21 = 0, r22 = 1;
    if (is3D) {
      if (r[0] != 0) {
        final c = math.cos(r[0] * _deg), sn = math.sin(r[0] * _deg);
        // R = Rx
        r11 = c;
        r12 = -sn;
        r21 = sn;
        r22 = c;
      }
      if (r[1] != 0) {
        final c = math.cos(r[1] * _deg), sn = math.sin(r[1] * _deg);
        // R = R · Ry, Ry = [c 0 s; 0 1 0; -s 0 c]
        final a00 = r00 * c - r02 * sn, a02 = r00 * sn + r02 * c;
        final a10 = r10 * c - r12 * sn, a12 = r10 * sn + r12 * c;
        final a20 = r20 * c - r22 * sn, a22 = r20 * sn + r22 * c;
        r00 = a00;
        r02 = a02;
        r10 = a10;
        r12 = a12;
        r20 = a20;
        r22 = a22;
      }
    }
    if (rz != 0) {
      final c = math.cos(rz * _deg), sn = math.sin(rz * _deg);
      // R = R · Rz, Rz = [c -s 0; s c 0; 0 0 1]
      final a00 = r00 * c + r01 * sn, a01 = r01 * c - r00 * sn;
      final a10 = r10 * c + r11 * sn, a11 = r11 * c - r10 * sn;
      final a20 = r20 * c + r21 * sn, a21 = r21 * c - r20 * sn;
      r00 = a00;
      r01 = a01;
      r10 = a10;
      r11 = a11;
      r20 = a20;
      r21 = a21;
    }
    final sx = s[0] / 100, sy = s[1] / 100, sz = is3D ? s[2] / 100 : 1.0;
    final l00 = r00 * sx, l01 = r01 * sy, l02 = r02 * sz;
    final l10 = r10 * sx, l11 = r11 * sy, l12 = r12 * sz;
    final l20 = r20 * sx, l21 = r21 * sy, l22 = r22 * sz;
    final ax = a[0], ay = a[1], az = is3D ? a[2] : 0.0;
    final pz = is3D ? p[2] : 0.0;
    // Column-major.
    return Matrix4(
      l00, l10, l20, 0, //
      l01, l11, l21, 0, //
      l02, l12, l22, 0, //
      p[0] - (l00 * ax + l01 * ay + l02 * az),
      p[1] - (l10 * ax + l11 * ay + l12 * az),
      pz - (l20 * ax + l21 * ay + l22 * az),
      1,
    );
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
      // win-40 >>> one-node camera aims with its orientation; blur level; focus lock
      final o = rig.props[CamProps.orientation]?.valueAt(t);
      if (rig.type == 'one_node' && o != null) {
        final fwd = oneNodeForward(o[0], o[1]);
        poi = pos + fwd * zoom;
        roll += o.length > 2 ? o[2] : 0;
      }
      final bl = rig.props[CamProps.blurLevel]?.scalarAt(t) ?? 100;
      aperture *= math.max(0.0, bl) / 100;
      if (rig.focusLock) focus = (poi - pos).length;
      // <<< win-40
      // V2-D >>> camera_shake
      final sh = Realism.shake3D(rig, t, pos, poi, zoom);
      if (sh != null) {
        pos = sh.$1;
        poi = sh.$2;
        roll += sh.$3;
      }
      // <<< V2-D
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
    // win-43 >>> AE camera Orientation (two-node) + X/Y/Z Rotation on top of the aim:
    // X tilts (+ = look down), Y pans (+ = turn right), Z rolls.
    if (rig.mode == CameraMode.threeD) {
      double rx = 0, ry = 0;
      final o = rig.props[CamProps.orientation]?.valueAt(t);
      if (rig.type != 'one_node' && o != null) {
        rx += o[0];
        ry += o.length > 1 ? o[1] : 0;
        roll += o.length > 2 ? o[2] : 0;
      }
      final rot = rig.props[CamProps.rotation]?.valueAt(t);
      if (rot != null) {
        rx += rot[0];
        ry += rot.length > 1 ? rot[1] : 0;
        roll += rot.length > 2 ? rot[2] : 0;
      }
      if (ry != 0) {
        final c = math.cos(ry * _deg), s = math.sin(ry * _deg);
        final f2 = f * c + r * s;
        r = r * c - f * s;
        f = f2;
      }
      if (rx != 0) {
        final c = math.cos(rx * _deg), s = math.sin(rx * _deg);
        final f2 = f * c + d * s;
        d = d * c - f * s;
        f = f2;
      }
      f.normalize();
      r.normalize();
      d.normalize();
    }
    // <<< win-43
    if (rig.mode == CameraMode.threeD) focus = Realism.focusFollow(comp, t, pos, poi, f) ?? focus; // V2-D: dof follow
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

  // win-40 >>> one-node camera: forward from X (pitch, + = look down) and Y (yaw, + = turn right) in degrees.
  static Vector3 oneNodeForward(double xDeg, double yDeg) {
    final x = xDeg * _deg, y = yDeg * _deg;
    return Vector3(math.sin(y) * math.cos(x), math.sin(x), math.cos(y) * math.cos(x))..normalize();
  }
  // <<< win-40

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
    // V2-D >>> camera_shake
    final sh = Realism.shake2D(rig, t);
    if (sh != null) {
      sx += sh.$1;
      sy += sh.$2;
      rot += sh.$3;
    }
    // <<< V2-D
    return Matrix4.translationValues(cx, cy, 0)
      ..multiply(Matrix4.rotationZ(-rot * _deg))
      ..multiply(Matrix4.diagonal3Values(z, z, 1))
      ..multiply(Matrix4.translationValues(-(pan[0] + sx), -(pan[1] + sy), 0));
  }

  /// Smooth deterministic pseudo-noise in about -1..1.
  static double shakeNoise(double x, double seed) =>
      math.sin(x * 6.13 + seed) * 0.5 + math.sin(x * 13.71 + seed * 2.3) * 0.3 + math.sin(x * 27.1 + seed * 4.1) * 0.2;
}

// win-40 >>> WORKING 3D VIEWS (After Effects: Front / Left / Top / Back / Right /
// Bottom orthographic views and Custom View 1-3 perspective orbit views).

/// A view of a composition's 3D space that is not the active camera.
class ViewCam {
  final Camera3DState cam;
  final Matrix4 proj;
  final bool ortho;
  final String kind;
  ViewCam(this.kind, this.cam, this.proj, this.ortho);

  static const kinds = ['active', 'front', 'left', 'top', 'back', 'right', 'bottom', 'custom1', 'custom2', 'custom3'];
  static const labels = {
    'active': 'Active Camera', 'front': 'Front', 'left': 'Left', 'top': 'Top', 'back': 'Back', 'right': 'Right', 'bottom': 'Bottom',
    'custom1': 'Custom View 1', 'custom2': 'Custom View 2', 'custom3': 'Custom View 3',
  };

  /// Default orbit of the custom views: [yaw°, pitch°, distance × scene size].
  static const customDefaults = {
    'custom1': [-35.0, 22.0, 1.7],
    'custom2': [40.0, 12.0, 1.9],
    'custom3': [0.0, 62.0, 1.8],
  };

  /// World-space points the working views frame: the comp frame, every 3D
  /// layer's corners and the camera (position + point of interest).
  static List<Vector3> scenePoints(Composition comp, double t) {
    final pts = <Vector3>[
      Vector3(0, 0, 0), Vector3(comp.width, 0, 0), Vector3(0, comp.height, 0), Vector3(comp.width, comp.height, 0),
    ];
    final cache = <String, Matrix4>{};
    for (final l in comp.layers) {
      if (!l.is3D || !l.isActiveAt(t)) continue;
      final m = Evaluator.worldMatrix(comp, l, t, cache);
      for (final c in [[0.0, 0.0], [l.width, 0.0], [0.0, l.height], [l.width, l.height]]) {
        pts.add(m.transform3(Vector3(c[0], c[1], 0)));
      }
    }
    if (comp.camera.mode == CameraMode.threeD) {
      final cam = Evaluator.camera3D(comp, t);
      pts.add(cam.position);
      pts.add(cam.position + cam.forward * cam.zoom);
    }
    return pts;
  }

  /// Builds the [kind] view for a viewport of [vw] × [vh] (comp px).
  /// [orbit] overrides a custom view's [yaw, pitch, distance factor].
  static ViewCam? build(Composition comp, double t, String kind, {List<double>? orbit}) {
    if (kind == 'active') return null;
    final w = comp.width, h = comp.height;
    final pts = scenePoints(comp, t);
    var mn = Vector3.copy(pts.first), mx = Vector3.copy(pts.first);
    for (final p in pts) {
      mn = Vector3(math.min(mn.x, p.x), math.min(mn.y, p.y), math.min(mn.z, p.z));
      mx = Vector3(math.max(mx.x, p.x), math.max(mx.y, p.y), math.max(mx.z, p.z));
    }
    final center = (mn + mx) * 0.5;
    final extent = math.max(1.0, (mx - mn).length);
    if (kind.startsWith('custom')) {
      final o = orbit ?? customDefaults[kind] ?? customDefaults['custom1']!;
      final yaw = o[0] * _deg, pitch = o[1] * _deg;
      final dist = extent * (o.length > 2 ? o[2] : 1.7);
      final dir = Vector3(math.sin(yaw) * math.cos(pitch), -math.sin(pitch), math.cos(yaw) * math.cos(pitch)); // camera → scene
      final pos = center - dir * dist;
      final f = dir.normalized();
      var r = Vector3(0, 1, 0).cross(f);
      if (r.length < 1e-6) r = Vector3(1, 0, 0);
      r.normalize();
      final d = f.cross(r)..normalize();
      final zoom = defaultZoomFor(w);
      final cam = Camera3DState(position: pos, right: r, down: d, forward: f, zoom: zoom, cx: w / 2, cy: h / 2, focus: dist, aperture: 0);
      return ViewCam(kind, cam, Evaluator.projection(cam), false);
    }
    late Vector3 f;
    switch (kind) {
      case 'front':
        f = Vector3(0, 0, 1);
      case 'back':
        f = Vector3(0, 0, -1);
      case 'left':
        f = Vector3(1, 0, 0);
      case 'right':
        f = Vector3(-1, 0, 0);
      case 'top':
        f = Vector3(0, 1, 0);
      case 'bottom':
        f = Vector3(0, -1, 0);
      default:
        throw ArgumentError('Unknown view "$kind" (use ${kinds.join(', ')})');
    }
    var r = Vector3(0, 1, 0).cross(f);
    if (r.length < 1e-6) r = Vector3(1, 0, 0);
    r.normalize();
    final d = f.cross(r)..normalize();
    // Fit every point into 86 % of the viewport.
    double r0 = double.infinity, r1 = -double.infinity, d0 = double.infinity, d1 = -double.infinity;
    for (final p in pts) {
      final pr = (p - center).dot(r), pd = (p - center).dot(d);
      r0 = math.min(r0, pr);
      r1 = math.max(r1, pr);
      d0 = math.min(d0, pd);
      d1 = math.max(d1, pd);
    }
    final s = 0.86 * math.min(w / math.max(1.0, r1 - r0), h / math.max(1.0, d1 - d0));
    final mid = center + r * ((r0 + r1) / 2) + d * ((d0 + d1) / 2);
    final pos = mid - f * (extent * 50);
    final cam = Camera3DState(position: pos, right: r, down: d, forward: f, zoom: s, cx: w / 2, cy: h / 2, focus: extent * 50, aperture: 0);
    final m = Matrix4.zero();
    void row(int i, Vector3 v, double k, double c) {
      m.setEntry(i, 0, v.x * k);
      m.setEntry(i, 1, v.y * k);
      m.setEntry(i, 2, v.z * k);
      m.setEntry(i, 3, -(v * k).dot(mid) + c);
    }
    row(0, r, s, w / 2);
    row(1, d, s, h / 2);
    row(2, f, 1e-4, 1); // tiny depth row keeps the matrix invertible (hit-testing)
    m.setEntry(3, 3, 1);
    return ViewCam(kind, cam, m, true);
  }

  /// Comp → this view's screen (comp px of the viewport).
  Offset2 toScreen(Vector3 p) {
    final v = proj.transform(Vector4(p.x, p.y, p.z, 1));
    final w = v.w.abs() < 1e-9 ? 1e-9 : v.w;
    return Offset2(v.x / w, v.y / w, ortho || cam.depthOf(p) > kNearPlane);
  }
}

/// A projected point and whether it is in front of the view.
class Offset2 {
  final double x, y;
  final bool visible;
  const Offset2(this.x, this.y, this.visible);
}
// <<< win-40
