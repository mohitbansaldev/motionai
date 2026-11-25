import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart';

import '../engine/evaluator.dart';
import '../model/camera.dart';
import '../model/easing.dart';
import '../model/effects_catalog.dart';
import '../model/layer.dart';
import '../model/project.dart';
import 'scene3d.dart';

/// V2-D Realism: pure maths and presets that make 2.5D scenes built from
/// flat cut-outs look photographed — contact shadows, colour matching,
/// atmospheric haze, depth of field that follows the camera target, camera
/// shake, lens effects, adjustment layers and documentary grades.
///
/// Rendering lives in lib/ui/preview/fx/realism_painters.dart; this file has
/// no Flutter imports so everything here is unit-testable.
class Realism {
  /// Realism effects whose look depends only on their params (content cache).
  static const paramFx = {
    'contact_shadow', 'grade', 'haze', 'light_wrap', 'bloom', 'halation', 'chromatic_aberration', 'lens_distortion',
  };

  /// Effects drawn from a snapshot of the layer (offscreen image).
  static const snapshotFx = {'light_wrap', 'bloom', 'halation', 'chromatic_aberration', 'lens_distortion'};

  // ------------------------------------------------------- 3D matrix (bug fix)

  /// Divides every entry of a layer→screen [m] by [w] (the homogeneous w of
  /// the layer centre, i.e. its camera depth). The projection is unchanged
  /// (homogeneous coordinates are scale-free) but the upper 2×2 block now
  /// holds the real on-screen scale instead of `scale × depth`.
  ///
  /// Why: Flutter's compositor (Impeller) sizes blur filters inside a
  /// perspective [Transform] from the matrix basis without dividing by w.
  /// With w ≈ depth (thousands of px) a blur of σ = 3 became σ ≈ 16 000 and
  /// the layer was smeared to nothing (V2 bug 1: blur on a 3D layer made it
  /// vanish; glow / drop shadow / depth-of-field blur on 3D layers vanished too).
  static void normalizeW(Matrix4 m, double w) {
    if (!(w > 1e-6) || !w.isFinite) return;
    final s = m.storage, k = 1 / w;
    for (int i = 0; i < 16; i++) {
      s[i] *= k;
    }
    avoidFrontal(m);
  }

  /// A 3D layer facing the camera exactly (no X/Y tilt) gets a perspective
  /// row of (0, 0, z, w). The Windows compositor drops such layers from the
  /// live preview (export draws them). A perspective term far below one
  /// pixel keeps them on the regular perspective path: invisible change.
  static void avoidFrontal(Matrix4 m) {
    final s = m.storage;
    if (s[3] == 0 && s[7] == 0) s[3] = 3e-8; // ≈ the 0.01° Y tilt that was verified on Windows
  }

  /// Scale a compositor reads from [m] when it ignores perspective (max
  /// length of the projected x / y basis, not divided by w).
  static double naiveScale(Matrix4 m) {
    final s = m.storage;
    return math.max(math.sqrt(s[0] * s[0] + s[1] * s[1]), math.sqrt(s[4] * s[4] + s[5] * s[5]));
  }

  /// Blur sigma the compositor actually applies for a layer-space [sigma]
  /// under [m] (see [normalizeW]).
  static double effectiveSigma(Matrix4 m, double sigma) => sigma * naiveScale(m);

  /// Layer pixels an effect paints outside the layer box (blur tails, glow,
  /// shadows): cached 3D layer images are taken with this margin so nothing
  /// is cut off at the box edge.
  static double spill(Layer l, double t) {
    double p(Effect e, String k, double d) {
      final ap = e.params[k];
      return ap == null ? d : ap.valueAt(t)[0];
    }

    var pad = 0.0;
    for (final e in l.effects) {
      if (!e.enabled) continue;
      final v = switch (e.type) {
        'blur' => p(e, 'amount', 0) * 0.5 * 3,
        'glow' => p(e, 'radius', 20) * 3,
        'shadow' => p(e, 'distance', 14) + p(e, 'blur', 12) * 3,
        'outline' => p(e, 'width', 8),
        'bloom' || 'halation' => p(e, 'radius', 30) * 3,
        'contact_shadow' => ShadowGeometry.forEffect(l, e, t).spill,
        _ => 0.0,
      };
      if (v > pad) pad = v;
    }
    return math.min(pad, math.max(l.width, l.height) * 0.6).clamp(0.0, 600.0).toDouble();
  }

  // ------------------------------------------------------------- colour maths

  static const _lr = 0.2126, _lg = 0.7152, _lb = 0.0722;

  /// Colour grade as a Flutter 5×4 colour matrix (0..255 offsets):
  /// saturation → per-channel gain (%) → contrast about mid grey → lift
  /// (% of full range, per channel), mixed with the original by [amount] %.
  static List<double> gradeMatrix({
    List<double> lift = const [0, 0, 0],
    List<double> gain = const [100, 100, 100],
    double saturation = 0,
    double contrast = 0,
    double amount = 100,
  }) {
    final s = (1 + saturation / 100).clamp(0.0, 3.0);
    final k = (1 + contrast / 100).clamp(0.0, 3.0);
    final a = (amount / 100).clamp(0.0, 1.0);
    final lw = [_lr, _lg, _lb];
    final out = List<double>.filled(20, 0);
    for (int i = 0; i < 3; i++) {
      final g = (gain.length > i ? gain[i] : 100) / 100;
      for (int j = 0; j < 3; j++) {
        final sat = lw[j] * (1 - s) + (i == j ? s : 0);
        final full = k * g * sat;
        out[i * 5 + j] = (i == j ? 1 - a : 0) + a * full;
      }
      final l = lift.length > i ? lift[i] : 0;
      out[i * 5 + 4] = a * (128 * (1 - k) + l * 2.55);
    }
    out[18] = 1;
    return out;
  }

  /// Applies a 5×4 colour matrix to an (r, g, b) colour in 0..1.
  static List<double> applyMatrix(List<double> m, List<double> rgb) => [
        for (int i = 0; i < 3; i++)
          (m[i * 5] * rgb[0] + m[i * 5 + 1] * rgb[1] + m[i * 5 + 2] * rgb[2] + m[i * 5 + 4] / 255).clamp(0.0, 1.0),
      ];

  /// Atmospheric haze: blends toward [color] (0..255) by [amount] % — lower
  /// contrast and a tint toward the sky, alpha untouched.
  static List<double> hazeMatrix(List<double> color, double amount) {
    final a = (amount / 100).clamp(0.0, 1.0) * 0.85;
    return [
      1 - a, 0, 0, 0, a * color[0], //
      0, 1 - a, 0, 0, a * color[1], //
      0, 0, 1 - a, 0, a * color[2], //
      0, 0, 0, 1, 0,
    ];
  }

  /// Haze amount (0..100) for a layer at camera depth `k × home distance`
  /// with make_3d `haze` [haze]: nothing up to the mid band, rising with
  /// log depth (far ≈ 0.9 × haze, sky ≈ 2 × haze).
  static double hazeForDepth(double k, double haze) {
    if (!(k > 1.05) || haze <= 0) return 0;
    final f = (math.log(k) / math.log(4)).clamp(0.0, 1.0);
    return (haze * 2 * math.pow(f, 1.1)).clamp(0.0, 100.0).toDouble();
  }

  static const List<double> defaultSky = [196, 210, 224];

  /// Grade params that make a cut-out with stats [cut] sit in a plate with
  /// stats [plate]: exposure (mean luminance), white balance (channel ratios),
  /// saturation, contrast (spread) and black level.
  static Map<String, List<double>> matchParams(ImageStats cut, ImageStats plate, {double amount = 100}) {
    final lc = math.max(cut.luma, 0.02), lp = math.max(plate.luma, 0.02);
    final expo = math.pow(lp / lc, 0.8).clamp(0.55, 1.7).toDouble();
    List<double> norm(ImageStats s) {
      final l = math.max(s.luma, 0.02);
      return [s.r / l, s.g / l, s.b / l];
    }

    final nc = norm(cut), np = norm(plate);
    final wb = [for (int i = 0; i < 3; i++) math.pow((np[i] + 0.02) / (nc[i] + 0.02), 0.7).toDouble()];
    final wl = _lr * wb[0] + _lg * wb[1] + _lb * wb[2];
    for (int i = 0; i < 3; i++) {
      wb[i] = (wb[i] / wl).clamp(0.8, 1.25);
    }
    var sat = 0.0;
    if (cut.sat > 0.02) sat = ((plate.sat / cut.sat - 1) * 80).clamp(-60.0, 40.0);
    var contrast = 0.0;
    final sc = (cut.high - cut.low) * expo, sp = plate.high - plate.low;
    if (sc > 0.05) contrast = ((sp / sc - 1) * 50).clamp(-30.0, 30.0);
    final lift = ((plate.low - cut.low * expo) * 50).clamp(-15.0, 15.0).toDouble();
    double r1(double v) => (v * 10).roundToDouble() / 10;
    return {
      'lift': [r1(lift), r1(lift), r1(lift)],
      'gain': [for (final w in wb) r1(expo * w * 100)],
      'saturation': [r1(sat)],
      'contrast': [r1(contrast)],
      'amount': [amount.clamp(0, 100).toDouble()],
    };
  }

  // ------------------------------------------------------------ lens warping

  /// Lens distortion of a point in a w×h frame: [amount] > 0 = barrel (centre
  /// bulges, edges bend), < 0 = pincushion. Corners stay put, so a full-frame
  /// picture never shows empty corners.
  static (double, double) lensWarp(double x, double y, double w, double h, double amount) {
    final k = -(amount / 100).clamp(-1.0, 1.0) * 0.3;
    if (k == 0) return (x, y);
    final cx = w / 2, cy = h / 2;
    final hd2 = cx * cx + cy * cy;
    final dx = x - cx, dy = y - cy;
    final r2 = hd2 <= 0 ? 0.0 : (dx * dx + dy * dy) / hd2;
    final f = (1 + k * r2) / (1 + k);
    return (cx + dx * f, cy + dy * f);
  }

  // ------------------------------------------------------------- camera shake

  static const shakeStyles = ['handheld', 'walk', 'impact', 'earthquake'];

  /// Amplitude (fraction of comp height) at amount 100, per style.
  static double shakeScale(String style) => switch (style) {
        'walk' => 0.02,
        'impact' => 0.045,
        'earthquake' => 0.04,
        _ => 0.025,
      };

  static int _hash(int i, int seed) {
    var h = (i * 0x27d4eb2d) ^ (seed * 0x165667b1);
    h = (h ^ (h >> 15)) * 0x2c1b3c6d;
    h &= 0x7fffffff;
    h = (h ^ (h >> 12)) * 0x297a2d39;
    h &= 0x7fffffff;
    return h ^ (h >> 15);
  }

  /// Smooth deterministic value noise in −1..1 (C², quintic fade).
  static double noise(double x, int seed) {
    final i = x.floor();
    final f = x - i;
    double v(int k) => (_hash(k, seed) & 0xFFFF) / 0x7FFF - 1.0;
    final u = f * f * f * (f * (f * 6 - 15) + 10);
    return v(i) + (v(i + 1) - v(i)) * u;
  }

  static double _fbm(double x, int seed) => noise(x, seed) * 0.7 + noise(x * 2.17 + 3.1, seed + 11) * 0.3;

  /// Shake at time [t] for amplitude 1: (dx, dy, roll°). dx/dy are screen
  /// px per amplitude px; roll in degrees per 10 px of amplitude.
  static (double, double, double) shakeAt(String style, double t, [int seed = 7]) {
    switch (style) {
      case 'walk':
        final ph = t * 1.8;
        final bob = 0.5 - (math.sin(math.pi * ph)).abs();
        final sway = math.sin(math.pi * ph * 0.5);
        return (sway * 0.6 + _fbm(t * 0.8, seed) * 0.2, bob * 1.1 + _fbm(t * 0.9, seed + 1) * 0.15, sway * 0.35);
      case 'impact':
        return (_fbm(t * 9, seed), _fbm(t * 9, seed + 5), _fbm(t * 7, seed + 9) * 0.6);
      case 'earthquake':
        return (
          noise(t * 6.5, seed) + noise(t * 14, seed + 2) * 0.3,
          noise(t * 6.5, seed + 4) * 0.7 + noise(t * 14, seed + 6) * 0.25,
          noise(t * 5, seed + 8) * 0.5,
        );
      default: // handheld
        return (_fbm(t * 0.9, seed) + noise(t * 2.3, seed + 3) * 0.25, _fbm(t * 0.8, seed + 1) + noise(t * 2.1, seed + 4) * 0.25,
            _fbm(t * 0.6, seed + 2) * 0.3);
    }
  }

  static String _styleAt(CameraRig rig, double t) {
    final p = rig.props[shakeStyleProp];
    final i = p == null ? 0 : p.valueAt(t)[0].round().clamp(0, shakeStyles.length - 1);
    return shakeStyles[i];
  }

  /// Camera props written by `camera_shake` (amplitude envelope in px, style index).
  static const shakeProp = 'shake3d';
  static const shakeStyleProp = 'shake3dStyle';

  /// 2D camera shake to add to (pan x, pan y, rotation°), or null.
  static (double, double, double)? shake2D(CameraRig rig, double t) {
    final p = rig.props[shakeProp];
    if (p == null) return null;
    final a = p.valueAt(t)[0];
    if (a.abs() < 1e-3) return null;
    final (x, y, r) = shakeAt(_styleAt(rig, t), t);
    return (x * a, y * a, r * a / 10);
  }

  /// 3D camera shake: new (position, poi, roll offset) or null. 70% of the
  /// shake turns the camera (moves every depth equally on screen), 30% moves
  /// it (near layers shake more: parallax).
  static (Vector3, Vector3, double)? shake3D(CameraRig rig, double t, Vector3 pos, Vector3 poi, double zoom) {
    final p = rig.props[shakeProp];
    if (p == null) return null;
    final a = p.valueAt(t)[0];
    if (a.abs() < 1e-3) return null;
    final (sx, sy, roll) = shakeAt(_styleAt(rig, t), t);
    var f = poi - pos;
    final dist = f.length;
    if (dist < 1e-6) return null;
    f = f / dist;
    var r = Vector3(0, 1, 0).cross(f);
    if (r.length < 1e-6) r = Vector3(1, 0, 0);
    r.normalize();
    final d = f.cross(r)..normalize();
    final screen = r * (sx * a) + d * (sy * a);
    final turn = screen * (0.7 * dist / math.max(zoom, 1));
    final move = screen * 0.3;
    return (pos + move, poi + move + turn, roll * a / 10);
  }

  /// Envelope keyframes (time, amplitude, ease) for a shake of [amp] px.
  static List<(double, double, Easing)> shakeEnvelope(String style, double start, double dur, double amp) {
    if (style == 'impact') {
      final atk = math.min(0.04, dur * 0.1);
      return [(start, 0, Easing.linear), (start + atk, amp, Easing.easeOut), (start + dur, 0, Easing.linear)];
    }
    final ramp = math.min(0.35, dur * 0.25);
    return [
      (start, 0, Easing.easyEase),
      (start + ramp, amp, Easing.linear),
      (start + dur - ramp, amp, Easing.easyEase),
      (start + dur, 0, Easing.linear),
    ];
  }

  // ---------------------------------------------------------- depth of field

  /// Focus distance for comp [Composition.dofFocus] ("target" = the camera's
  /// point of interest, else a layer id = that layer's centre), or null.
  static double? focusFollow(Composition comp, double t, Vector3 pos, Vector3 poi, Vector3 forward) {
    final mode = comp.dofFocus;
    if (mode == null) return null;
    if (mode == 'target') return math.max(1.0, (poi - pos).dot(forward));
    final l = comp.layerById(mode);
    if (l == null) return null;
    if (!l.is3D) return null;
    final w = Evaluator.worldMatrix(comp, l, t);
    final c = w.transform3(Vector3(l.width / 2, l.height / 2, 0));
    return math.max(1.0, (c - pos).dot(forward));
  }

  // -------------------------------------------------------------- looks

  static const looks = [
    'doc_golden_hour', 'doc_cold_night', 'doc_archive_sepia', 'doc_teal_orange', 'doc_noir_contrast', 'doc_desaturated_war',
  ];
  static const filmLook = 'film_look';

  static String lookLabel(String s) => const {
        'doc_golden_hour': 'Golden hour',
        'doc_cold_night': 'Cold night',
        'doc_archive_sepia': 'Archive sepia',
        'doc_teal_orange': 'Teal & orange',
        'doc_noir_contrast': 'Noir contrast',
        'doc_desaturated_war': 'Desaturated war',
        'film_look': 'Film look',
      }[s] ??
      s;

  /// Effects (type, params) of a look, in order.
  static List<(String, Map<String, List<double>>)> lookEffects(String style) => switch (style) {
        'doc_golden_hour' => [
            ('grade', {'lift': [3, 1, -3], 'gain': [112, 102, 84], 'saturation': [12], 'contrast': [8]}),
            ('bloom', {'threshold': [68], 'amount': [35], 'radius': [30]}),
            ('vignette', {'amount': [45], 'size': [65]}),
          ],
        'doc_cold_night' => [
            ('grade', {'lift': [-2, 0, 6], 'gain': [80, 92, 112], 'saturation': [-25], 'contrast': [12]}),
            ('vignette', {'amount': [60], 'size': [60]}),
            ('grain', {'amount': [12], 'size': [2]}),
          ],
        'doc_archive_sepia' => [
            ('grade', {'lift': [5, 3, 0], 'gain': [112, 96, 74], 'saturation': [-100], 'contrast': [-8]}),
            ('grain', {'amount': [40], 'size': [2]}),
            ('gate_weave', {'amount': [25], 'flicker': [20]}),
            ('vignette', {'amount': [55], 'size': [55]}),
          ],
        'doc_teal_orange' => [
            ('grade', {'lift': [-5, 1, 5], 'gain': [112, 100, 88], 'saturation': [10], 'contrast': [15]}),
            ('vignette', {'amount': [35], 'size': [65]}),
          ],
        'doc_noir_contrast' => [
            ('grade', {'lift': [-3, -3, -3], 'gain': [100, 100, 100], 'saturation': [-100], 'contrast': [40]}),
            ('vignette', {'amount': [70], 'size': [55]}),
            ('grain', {'amount': [25], 'size': [2]}),
            ('letterbox', {'amount': [11]}),
          ],
        'doc_desaturated_war' => [
            ('grade', {'lift': [2, 2, 0], 'gain': [104, 100, 92], 'saturation': [-55], 'contrast': [22]}),
            ('chromatic_aberration', {'amount': [10]}),
            ('grain', {'amount': [30], 'size': [2]}),
            ('vignette', {'amount': [55], 'size': [60]}),
          ],
        'film_look' => [
            ('halation', {'amount': [35], 'radius': [18], 'threshold': [72]}),
            ('grain', {'amount': [22], 'size': [2]}),
            ('gate_weave', {'amount': [30], 'flicker': [25]}),
            ('vignette', {'amount': [40], 'size': [62]}),
          ],
        _ => throw ArgumentError('Unknown look "$style". Available: ${[...looks, filmLook].join(', ')}'),
      };

  /// Puts [style] on an adjustment layer at the top of [comp] covering the
  /// whole comp (replaces an earlier look; the film look is a second layer
  /// above the grade). Returns the adjustment layer id.
  static String applyLook(Composition comp, String style) {
    final effects = lookEffects(style);
    final film = style == filmLook;
    final id = film ? 'film_look' : 'look';
    comp.layers.removeWhere((l) => l.id == id && l.adjustment);
    if (comp.layerById(id) != null) throw ArgumentError('Layer id "$id" is taken by a layer that is not a look');
    final l = Layer(
      id: id,
      name: '${film ? 'Film' : 'Look'}: ${lookLabel(style)}',
      type: LayerType.solid,
      start: 0,
      duration: math.max(comp.duration, comp.frameDuration),
      width: comp.width,
      height: comp.height,
      color: 0x00000000,
    )..adjustment = true;
    l.prop(Props.position).staticValue = [comp.width / 2, comp.height / 2, 0];
    for (final (type, params) in effects) {
      final fx = EffectsCatalog.create(type, '${id}_$type');
      params.forEach((k, v) => fx.params[k]!.staticValue = List.of(v));
      l.effects.add(fx);
    }
    final filmIdx = film ? -1 : comp.indexOf('film_look');
    comp.layers.insert(filmIdx >= 0 ? filmIdx + 1 : 0, l);
    return id;
  }

  // ---------------------------------------------------------- make_3d hooks

  /// After make_3d: haze on far/sky layers, contact shadows under near/mid
  /// cut-outs that stand on the ground.
  static void afterMake3D(Project project, Composition comp, List<String> roots, double t,
      {double haze = 25, bool shadows = true, List<String>? log}) {
    final z0 = Scene3D.homeZoom(comp);
    final kids = <String, List<Layer>>{};
    for (final l in comp.layers) {
      final p = l.parentId;
      if (p != null) (kids[p] ??= []).add(l);
    }
    List<Layer> subtree(Layer r) {
      final out = <Layer>[];
      final seen = <String>{};
      void walk(Layer l, int d) {
        if (d > 32 || !seen.add(l.id)) return;
        out.add(l);
        for (final k in kids[l.id] ?? const <Layer>[]) {
          walk(k, d + 1);
        }
      }

      walk(r, 0);
      return out;
    }

    // Sky colour: the top of the sky plate when it can be read.
    List<double> sky = defaultSky;
    final rootLayers = [for (final id in roots) comp.layerById(id)].whereType<Layer>().toList();
    for (final r in rootLayers) {
      if (Scene3D.bandOf(comp, r, t) != 'sky') continue;
      final s = statsOfLayer(project, r, region: const [0, 0, 1, 0.35]);
      if (s != null) {
        // A touch lighter than the sky itself (haze is scattered light).
        sky = [for (final c in [s.r, s.g, s.b]) (c * 255 * 0.7 + 255 * 0.3).clamp(0.0, 255.0).toDouble()];
        break;
      }
    }
    var hazed = 0, shadowed = 0;
    for (final r in rootLayers) {
      final z = r.prop(Props.position).valueAt(t)[2];
      final k = (z + z0) / z0;
      final band = Scene3D.bandOf(comp, r, t);
      final h = hazeForDepth(k, haze);
      for (final l in subtree(r)) {
        if (!Scene3D.isVisual(l) || l.adjustment) continue;
        l.effects.removeWhere((e) => e.id == '${l.id}_haze');
        if (h >= 1) {
          final fx = EffectsCatalog.create('haze', '${l.id}_haze');
          fx.params['amount']!.staticValue = [(h * 10).roundToDouble() / 10];
          fx.params['color']!.staticValue = [for (final c in sky) c.roundToDouble()];
          l.effects.add(fx);
          hazed++;
        }
      }
      if (shadows && (band == 'mid' || band == 'near') && _standsOnGround(comp, r, t)) {
        if (r.effects.any((e) => e.type == 'contact_shadow')) continue;
        final fx = EffectsCatalog.create('contact_shadow', '${r.id}_cshadow');
        fillFootprint(project, r, fx);
        r.effects.insert(0, fx);
        shadowed++;
      }
    }
    if (hazed > 0) log?.add('Haze on $hazed far layer(s)');
    if (shadowed > 0) log?.add('Contact shadow under $shadowed cut-out(s) (make_3d contact_shadows:false to skip)');
  }

  /// A cut-out (image, not a full plate) whose bottom is in the lower part
  /// of the frame.
  static bool _standsOnGround(Composition comp, Layer l, double t) {
    if (l.type != LayerType.image) return false;
    final b = Scene3D.screenBox(comp, [l], t);
    if (b == null) return false;
    final w = comp.width, h = comp.height;
    final ix = math.min(w, b[2]) - math.max(0.0, b[0]), iy = math.min(h, b[3]) - math.max(0.0, b[1]);
    if (ix <= 0 || iy <= 0) return false;
    if (ix * iy > w * h * 0.6) return false; // a plate, not a cut-out
    return b[3] >= h * 0.55;
  }

  /// Sets a contact_shadow effect's footprint (x0, x1, bottom %) from the
  /// layer's alpha when its image can be read.
  static void fillFootprint(Project project, Layer l, Effect fx) {
    final px = pixelsOf(project, l);
    if (px == null) return;
    final fp = footprint(px.data, px.width, px.height);
    if (fp == null) return;
    double r1(double v) => (v * 1000).roundToDouble() / 10;
    fx.params['x0']!.staticValue = [r1(fp[0])];
    fx.params['x1']!.staticValue = [r1(fp[1])];
    fx.params['bottom']!.staticValue = [r1(fp[2])];
  }

  // -------------------------------------------------------- image statistics

  /// Feet of a cut-out: [x0, x1, bottom] as fractions of the image, from the
  /// lowest rows that have opaque pixels; null when there is no alpha.
  static List<double>? footprint(Uint8List rgba, int w, int h, {int minAlpha = 128}) {
    if (w <= 0 || h <= 0 || rgba.length < w * h * 4) return null;
    int bottom = -1;
    for (int y = h - 1; y >= 0 && bottom < 0; y--) {
      for (int x = 0; x < w; x++) {
        if (rgba[(y * w + x) * 4 + 3] >= minAlpha) {
          bottom = y;
          break;
        }
      }
    }
    if (bottom < 0) return null;
    int top = 0;
    for (int y = 0; y < h; y++) {
      var any = false;
      for (int x = 0; x < w; x++) {
        if (rgba[(y * w + x) * 4 + 3] >= minAlpha) {
          any = true;
          break;
        }
      }
      if (any) {
        top = y;
        break;
      }
    }
    // The footprint band: the lowest 6% of the subject's height.
    final band = math.max(1, ((bottom - top + 1) * 0.06).round());
    int x0 = w, x1 = -1;
    for (int y = math.max(0, bottom - band + 1); y <= bottom; y++) {
      for (int x = 0; x < w; x++) {
        if (rgba[(y * w + x) * 4 + 3] >= minAlpha) {
          if (x < x0) x0 = x;
          if (x > x1) x1 = x;
        }
      }
    }
    if (x1 < x0) return null;
    return [x0 / w, (x1 + 1) / w, (bottom + 1) / h];
  }

  /// Decoded, downscaled RGBA of an image layer's media (cached), or null.
  static Rgba8? pixelsOf(Project project, Layer l) {
    if (l.type != LayerType.image) return null;
    final m = project.media[l.mediaId];
    if (m == null) return null;
    return PixelCache.load(m.path);
  }

  /// Stats of a layer's pixels in [region] [x0, y0, x1, y1] (0..1 of the
  /// layer): image layers from their file, solids from their colour.
  static ImageStats? statsOfLayer(Project project, Layer l, {List<double> region = const [0, 0, 1, 1]}) {
    if (l.type == LayerType.solid) return ImageStats.ofColor(l.color);
    final px = pixelsOf(project, l);
    if (px == null) return null;
    return ImageStats.of(px.data, px.width, px.height, region: region);
  }
}

/// 8-bit RGBA pixels.
class Rgba8 {
  final int width, height;
  final Uint8List data;
  const Rgba8(this.width, this.height, this.data);
}

/// Small decoded copies of image files for colour statistics and alpha
/// footprints (pure Dart; at most [maxSide] px).
class PixelCache {
  static const int maxSide = 192;
  static final Map<String, Rgba8?> _cache = {};

  static Rgba8? load(String path) {
    if (_cache.containsKey(path)) return _cache[path];
    Rgba8? out;
    try {
      final f = File(path);
      if (f.existsSync()) {
        var im = img.decodeImage(f.readAsBytesSync());
        if (im != null) {
          final long = math.max(im.width, im.height);
          if (long > maxSide) {
            final k = maxSide / long;
            im = img.copyResize(im,
                width: math.max(1, (im.width * k).round()),
                height: math.max(1, (im.height * k).round()),
                interpolation: img.Interpolation.average);
          }
          final c = (im.format == img.Format.uint8 && im.numChannels == 4 && !im.hasPalette)
              ? im
              : im.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
          out = Rgba8(c.width, c.height, Uint8List.fromList(c.getBytes(order: img.ChannelOrder.rgba)));
        }
      }
    } catch (_) {
      out = null;
    }
    if (_cache.length > 64) _cache.clear();
    _cache[path] = out;
    return out;
  }

  static void clear() => _cache.clear();
}

/// Colour statistics of the visible pixels of an image (alpha-weighted).
class ImageStats {
  final double r, g, b; // mean colour 0..1
  final double luma; // mean luminance 0..1
  final double sat; // mean chroma (max − min) 0..1
  final double low, high; // 5th / 95th percentile luminance
  final double coverage; // fraction of (mostly) opaque pixels

  const ImageStats(this.r, this.g, this.b, this.luma, this.sat, this.low, this.high, this.coverage);

  factory ImageStats.ofColor(int argb) {
    final r = ((argb >> 16) & 0xFF) / 255, g = ((argb >> 8) & 0xFF) / 255, b = (argb & 0xFF) / 255;
    final l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    return ImageStats(r, g, b, l, math.max(r, math.max(g, b)) - math.min(r, math.min(g, b)), l, l, 1);
  }

  static ImageStats? of(Uint8List rgba, int w, int h, {List<double> region = const [0, 0, 1, 1], int minAlpha = 32}) {
    if (w <= 0 || h <= 0 || rgba.length < w * h * 4) return null;
    final x0 = (region[0].clamp(0.0, 1.0) * w).floor(), y0 = (region[1].clamp(0.0, 1.0) * h).floor();
    final x1 = math.max(x0 + 1, (region[2].clamp(0.0, 1.0) * w).ceil()), y1 = math.max(y0 + 1, (region[3].clamp(0.0, 1.0) * h).ceil());
    double sw = 0, sr = 0, sg = 0, sb = 0, ss = 0;
    final hist = List<double>.filled(64, 0);
    int opaque = 0, n = 0;
    for (int y = y0; y < math.min(h, y1); y++) {
      for (int x = x0; x < math.min(w, x1); x++) {
        final i = (y * w + x) * 4;
        n++;
        final a = rgba[i + 3];
        if (a < minAlpha) continue;
        if (a >= 128) opaque++;
        final wt = a / 255;
        final r = rgba[i] / 255, g = rgba[i + 1] / 255, b = rgba[i + 2] / 255;
        sw += wt;
        sr += r * wt;
        sg += g * wt;
        sb += b * wt;
        ss += (math.max(r, math.max(g, b)) - math.min(r, math.min(g, b))) * wt;
        final l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        hist[(l * 63.999).floor().clamp(0, 63)] += wt;
      }
    }
    if (sw <= 0) return null;
    double pct(double q) {
      var acc = 0.0;
      for (int i = 0; i < 64; i++) {
        acc += hist[i];
        if (acc >= q * sw) return (i + 0.5) / 64;
      }
      return 1;
    }

    final r = sr / sw, g = sg / sw, b = sb / sw;
    return ImageStats(r, g, b, 0.2126 * r + 0.7152 * g + 0.0722 * b, ss / sw, pct(0.05), pct(0.95), n == 0 ? 0 : opaque / n);
  }
}

/// Ground shadow of a standing cut-out, in layer pixels.
class ShadowGeometry {
  /// Ground ellipse centre and radii.
  final double cx, cy, rx, ry;

  /// Gaussian softness (sigma, px).
  final double blur;

  /// Cast shadow affine: x' = a·x + c·y + tx, y' = b·x + d·y + ty.
  final double a, b, c, d, tx, ty;

  /// Feet line (layer px).
  final double ground;

  /// Pixels painted outside the layer box.
  final double spill;

  const ShadowGeometry(this.cx, this.cy, this.rx, this.ry, this.blur, this.a, this.b, this.c, this.d, this.tx, this.ty, this.ground,
      this.spill);

  /// [x0], [x1], [bottom]: footprint as fractions of the layer box.
  /// [softness], [length] 0..100. [angle]: where the light comes from
  /// (degrees, screen plane: 0 = right, 90 = overhead/front, 180 = left).
  factory ShadowGeometry.of({
    required double w,
    required double h,
    double x0 = 0.25,
    double x1 = 0.75,
    double bottom = 1,
    double softness = 50,
    double length = 50,
    double angle = 120,
  }) {
    final lo = math.min(x0, x1), hi = math.max(x0, x1);
    final fw = math.max((hi - lo) * w, w * 0.04);
    final ground = bottom.clamp(0.0, 1.0) * h;
    final len = (length / 100).clamp(0.0, 2.0);
    final away = -math.cos(angle * math.pi / 180); // shadow falls away from the light
    final cx = (lo + hi) / 2 * w + away * fw * 0.18 * len;
    final rx = fw * 0.55 * (1 + 0.35 * len);
    final ry = math.max(2.0, rx * 0.13);
    final cy = ground - ry * 0.25;
    final blur = 1 + (softness / 100).clamp(0.0, 2.0) * ry * 1.2;
    final sy = 0.18 + 0.42 * len;
    final sx = away * (0.25 + 0.9 * len);
    // Feet stay on the ground line; the head lands behind (higher on screen)
    // and sideways away from the light.
    final reach = rx + 3 * blur;
    final spill = [
      cy + ry + 3 * blur - h, // below the feet
      cx + reach - w, // right edge
      reach - cx, // left edge
      sx.abs() * ground * 0.6, // cast shadow leaning sideways
    ].fold(0.0, (m, v) => v > m ? v : m);
    return ShadowGeometry(cx, cy, rx, ry, blur, 1, 0, -sx, sy, sx * ground, ground * (1 - sy), ground, spill);
  }

  factory ShadowGeometry.forEffect(Layer l, Effect e, double t) {
    double p(String k, double d) => e.params[k]?.valueAt(t)[0] ?? d;
    return ShadowGeometry.of(
      w: l.width,
      h: l.height,
      x0: p('x0', 25) / 100,
      x1: p('x1', 75) / 100,
      bottom: p('bottom', 100) / 100,
      softness: p('softness', 50),
      length: p('length', 50),
      angle: p('angle', 120),
    );
  }

  /// Where the cast shadow puts layer point (x, y).
  (double, double) castPoint(double x, double y) => (a * x + c * y + tx, b * x + d * y + ty);
}
