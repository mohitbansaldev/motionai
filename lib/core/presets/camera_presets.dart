import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../engine/evaluator.dart';
import '../model/camera.dart';
import '../model/easing.dart';
import '../model/layer.dart';
import '../model/project.dart';

/// Ready-made camera moves. Each move starts from the camera's current
/// state at [start], so moves can be chained one after another.
class CameraPresets {
  static const threeD = ['push_in', 'pull_out', 'orbit', 'dolly_zoom', 'drone_reveal', 'truck', 'pedestal'];
  static const twoD = ['pan_2d', 'zoom_in_2d', 'zoom_out_2d', 'rotate_2d', 'shake'];

  static String label(String preset) => const {
        'push_in': 'Push In',
        'pull_out': 'Pull Out',
        'orbit': 'Orbit',
        'dolly_zoom': 'Dolly Zoom',
        'drone_reveal': 'Drone Reveal',
        'truck': 'Truck',
        'pedestal': 'Pedestal',
        'pan_2d': 'Pan',
        'zoom_in_2d': 'Zoom In',
        'zoom_out_2d': 'Zoom Out',
        'rotate_2d': 'Rotate',
        'shake': 'Shake',
      }[preset] ??
      preset;

  /// Default "amount" for each preset (pixels, degrees or percent).
  static double defaultAmount(String preset) => const {
        'push_in': 400.0,
        'pull_out': 400.0,
        'orbit': 30.0,
        'dolly_zoom': 600.0,
        'drone_reveal': 500.0,
        'truck': 300.0,
        'pedestal': 250.0,
        'pan_2d': 300.0,
        'zoom_in_2d': 30.0,
        'zoom_out_2d': 30.0,
        'rotate_2d': 8.0,
        'shake': 12.0,
      }[preset] ??
      100.0;

  static void apply(
    Composition comp,
    String preset, {
    required double start,
    required double duration,
    double? amount,
    Easing ease = Easing.easyEase,
    String direction = 'left',
  }) {
    final rig = comp.camera;
    final a = amount ?? defaultAmount(preset);
    final end = start + math.max(duration, comp.frameDuration);

    if (twoD.contains(preset)) {
      rig.mode = CameraMode.twoD;
      _apply2D(comp, preset, start, end, a, ease, direction);
      return;
    }
    if (!threeD.contains(preset)) {
      throw ArgumentError('Unknown camera preset "$preset". Available: ${[...threeD, ...twoD].join(', ')}');
    }
    rig.mode = CameraMode.threeD;
    final posP = rig.prop(CamProps.position);
    final poiP = rig.prop(CamProps.poi);
    final zoomP = rig.prop(CamProps.zoom);
    final p0 = _v(posP.valueAt(start));
    final q0 = _v(poiP.valueAt(start));
    final z0 = zoomP.scalarAt(start);
    final cam = Evaluator.camera3D(comp, start);
    final fwd = cam.forward;

    void key(double t, Vector3 p, Vector3 q, Easing e) {
      posP.setKeyframe(t, [p.x, p.y, p.z], easing: e);
      poiP.setKeyframe(t, [q.x, q.y, q.z], easing: e);
    }

    switch (preset) {
      case 'push_in':
      case 'pull_out':
        final d = preset == 'push_in' ? a : -a;
        key(start, p0, q0, ease);
        key(end, p0 + fwd * d, q0 + fwd * d, Easing.easyEase);
        break;
      case 'truck':
        final sign = direction == 'right' ? 1.0 : -1.0;
        key(start, p0, q0, ease);
        key(end, p0 + cam.right * (a * sign), q0 + cam.right * (a * sign), Easing.easyEase);
        break;
      case 'pedestal':
        final sign = direction == 'down' ? 1.0 : -1.0;
        key(start, p0, q0, ease);
        key(end, p0 + cam.down * (a * sign), q0 + cam.down * (a * sign), Easing.easyEase);
        break;
      case 'orbit':
        const n = 8;
        final rel = p0 - q0;
        final sign = direction == 'right' ? -1.0 : 1.0;
        for (int i = 0; i <= n; i++) {
          final th = sign * a * ease.transform(i / n) * math.pi / 180;
          final c = math.cos(th), s = math.sin(th);
          final p = Vector3(q0.x + rel.x * c - rel.z * s, p0.y, q0.z + rel.x * s + rel.z * c);
          final t = start + (end - start) * i / n;
          posP.setKeyframe(t, [p.x, p.y, p.z], easing: Easing.linear);
          poiP.setKeyframe(t, [q0.x, q0.y, q0.z], easing: Easing.linear);
        }
        break;
      case 'dolly_zoom':
        final dist0 = (q0 - p0).length;
        final p1 = p0 - fwd * a;
        final dist1 = (q0 - p1).length;
        key(start, p0, q0, ease);
        key(end, p1, q0, Easing.easyEase);
        zoomP.setKeyframe(start, [z0], easing: ease);
        zoomP.setKeyframe(end, [z0 * dist1 / math.max(dist0, 1.0)], easing: Easing.easyEase);
        break;
      case 'drone_reveal':
        final high = p0 + Vector3(0, -a, -a * 1.2);
        key(start, high, q0, ease);
        key(end, p0, q0, Easing.easyEase);
        break;
    }
  }

  static void _apply2D(Composition comp, String preset, double start, double end, double a, Easing ease, String dir) {
    final rig = comp.camera;
    switch (preset) {
      case 'pan_2d':
        final pan = rig.prop(CamProps.pan);
        final p0 = pan.valueAt(start);
        final d = switch (dir) {
          'right' => [a, 0.0],
          'up' => [0.0, -a],
          'down' => [0.0, a],
          _ => [-a, 0.0],
        };
        pan.setKeyframe(start, p0, easing: ease);
        pan.setKeyframe(end, [p0[0] + d[0], p0[1] + d[1]]);
        break;
      case 'zoom_in_2d':
      case 'zoom_out_2d':
        final z = rig.prop(CamProps.zoom2d);
        final z0 = z.scalarAt(start);
        final z1 = preset == 'zoom_in_2d' ? z0 * (1 + a / 100) : z0 / (1 + a / 100);
        z.setKeyframe(start, [z0], easing: ease);
        z.setKeyframe(end, [z1]);
        break;
      case 'rotate_2d':
        final r = rig.prop(CamProps.rotation2d);
        final r0 = r.scalarAt(start);
        r.setKeyframe(start, [r0], easing: ease);
        r.setKeyframe(end, [r0 + (dir == 'right' ? a : -a)]);
        break;
      case 'shake':
        final s = rig.prop(CamProps.shake);
        final ramp = math.min(0.2, (end - start) / 4);
        s.setKeyframe(start, [0], easing: Easing.linear);
        s.setKeyframe(start + ramp, [a], easing: Easing.linear);
        s.setKeyframe(end - ramp, [a], easing: Easing.linear);
        s.setKeyframe(end, [0], easing: Easing.linear);
        break;
    }
  }

  /// Turns flat layers into a 3D parallax scene. [layerIdsBackToFront]
  /// lists layers from the farthest (background) to the nearest. Each one
  /// is pushed back in Z and scaled up so the first frame looks unchanged,
  /// then the camera pushes in so near layers move faster than far ones.
  static void parallaxRig(
    Composition comp,
    List<String> layerIdsBackToFront, {
    double depthStep = 500,
    double push = 350,
    required double start,
    required double duration,
    Easing ease = Easing.easyEase,
  }) {
    if (layerIdsBackToFront.isEmpty) throw ArgumentError('parallax needs at least one layer');
    // Reset the camera to a clean 3D state at the start time.
    comp.camera.mode = CameraMode.threeD;
    final cam = Evaluator.camera3D(comp, start);
    final dist = (cam.position - _v(comp.camera.prop(CamProps.poi).valueAt(start))).length;
    final zoom = cam.zoom;
    final cx = comp.width / 2, cy = comp.height / 2;
    final n = layerIdsBackToFront.length;

    for (int i = 0; i < n; i++) {
      final layer = comp.requireLayer(layerIdsBackToFront[i]);
      final z = (n - 1 - i) * depthStep;
      final factor = (dist + z) / zoom;
      layer.is3D = true;
      final pos = layer.prop(Props.position);
      final scale = layer.prop(Props.scale);
      List<double> movePos(List<double> v) => [cx + (v[0] - cx) * factor, cy + (v[1] - cy) * factor, z];
      List<double> scaleUp(List<double> v) => [v[0] * factor, v[1] * factor, v[2]];
      pos.staticValue = movePos(pos.staticValue);
      for (final k in pos.keyframes) {
        k.value = movePos(k.value);
      }
      scale.staticValue = scaleUp(scale.staticValue);
      for (final k in scale.keyframes) {
        k.value = scaleUp(k.value);
      }
    }
    apply(comp, 'push_in', start: start, duration: duration, amount: push, ease: ease);
  }

  static Vector3 _v(List<double> l) => Vector3(l[0], l[1], l.length > 2 ? l[2] : 0);
}
