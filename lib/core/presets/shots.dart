import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../engine/evaluator.dart';
import '../model/anim_prop.dart';
import '../model/effects_catalog.dart';
import '../model/layer.dart';
import '../model/project.dart';
import 'motion_presets.dart';
import 'scene3d.dart';

/// Shots & sequences (V2-B): smart sizing and placement of cut-outs by role,
/// the built-in shot styles, looks, and the geometry helpers `add_shot`
/// (lib/core/commands/shot_commands.dart) uses.
///
/// A shot is composed flat at the home camera (screen space, fractions of
/// the frame) and then put in depth with [Scene3D.make3D]. Grounded roles
/// (far / mid / near) stand on ONE horizontal floor plane: the mid band's
/// ground line is `floor` (fraction of the frame height, default 0.88) and
/// the other bands' ground lines follow from the perspective, so the feet of
/// every cut-out stay on the same floor while the camera moves.
class ShotRoles {
  /// Back to front (also the stacking order inside a shot).
  static const roles = ['sky', 'far', 'mid', 'ground', 'near', 'front'];

  /// Roles that stand on the floor plane.
  static const grounded = {'far', 'mid', 'near'};

  static const double defaultFloor = 0.88;

  /// Front objects never get taller than this (fraction of the frame height).
  static const double maxFront = 0.45;

  /// Depth band (see [Scene3D.bands]) of a role.
  static String band(String role) => role == 'ground' ? 'near' : role;

  static int order(String role) => math.max(0, roles.indexOf(role));

  /// Default on-screen height (fraction of the frame height) at the home
  /// camera, aspect-aware: tall/narrow things (people, towers, plants) are
  /// taller than wide ones (houses, carts, heaps).
  static double targetHeight(String role, double aspect) {
    final tall = aspect < 0.8, wide = aspect > 1.4;
    switch (role) {
      case 'far':
        return tall ? 0.30 : (wide ? 0.24 : 0.27);
      case 'mid':
        return tall ? 0.62 : (wide ? 0.46 : 0.52);
      case 'near':
        return tall ? 0.80 : (wide ? 0.55 : 0.68);
      case 'front':
        return tall ? 0.45 : (wide ? 0.34 : 0.40);
    }
    return 0.5;
  }

  /// Widest a role gets by default (fraction of the frame width).
  static double maxWidth(String role) => switch (role) {
        'far' => 0.5,
        'mid' => 0.7,
        'near' => 0.9,
        'front' => 0.6,
        _ => 1.3,
      };

  /// On-screen size (px) of a cut-out of [mw]×[mh] px in a [fw]×[fh] frame.
  /// [height] (0..1 of the frame height) overrides the role default.
  static ({double w, double h}) size(String role, double mw, double mh, double fw, double fh, {double? height}) {
    final aspect = math.max(1e-3, mw) / math.max(1e-3, mh);
    if (height != null) {
      final h = height.clamp(0.01, 4.0) * fh;
      return (w: h * aspect, h: h);
    }
    if (role == 'sky') {
      final w = fw * 1.2;
      return (w: w, h: w / aspect);
    }
    if (role == 'ground') {
      var w = fw * 1.25, h = w / aspect;
      if (h > fh * 0.4) {
        h = fh * 0.4;
        w = h * aspect;
      }
      return (w: w, h: h);
    }
    var h = targetHeight(role, aspect) * fh;
    if (role == 'front') h = math.min(h, maxFront * fh);
    final maxW = maxWidth(role) * fw;
    if (h * aspect > maxW) h = maxW / aspect;
    return (w: h * aspect, h: h);
  }

  /// Screen y (fraction of the frame height) where a role's bottom stands
  /// so it is on the floor plane whose mid-band ground line is [floor].
  static double groundLine(String role, double floor) {
    switch (role) {
      case 'ground':
        return 1.02;
      case 'sky':
        return 0.6;
    }
    final k = Scene3D.bandFactor(band(role));
    final y = 0.5 + (floor - 0.5) / k;
    return role == 'mid' ? floor : math.min(1.03, y);
  }

  /// Default horizontal centre (fraction of the frame width) of the [k]-th
  /// cut-out of [role]: spread so far layers are not right behind mid ones.
  static double defaultX(String role, int k) {
    const far = [0.12, 0.88, 0.3, 0.7, 0.45, 0.6];
    const mid = [0.55, 0.32, 0.76, 0.16, 0.9];
    const near = [0.24, 0.76, 0.5];
    const front = [0.84, 0.16, 0.5];
    List<double> l;
    switch (role) {
      case 'far':
        l = far;
        break;
      case 'mid':
        l = mid;
        break;
      case 'near':
        l = near;
        break;
      case 'front':
        l = front;
        break;
      default:
        return 0.5;
    }
    return l[k % l.length];
  }

  /// Role from the picture's shape when none is given.
  static String guess(double mw, double mh) => mw / math.max(1, mh) > 2.4 ? 'ground' : 'mid';
}

/// One built-in shot style (`style:` on add_shot): camera + atmosphere + look.
class ShotStyle {
  final String id, label, description;

  /// Camera moves; start/duration are fractions of the shot (`u0`, `u1`),
  /// `target: "hero"` = the most important cut-out.
  final List<Map<String, dynamic>> camera;
  final Map<String, dynamic> atmosphere;
  final String look;
  const ShotStyle(this.id, this.label, this.description, {required this.camera, this.atmosphere = const {}, this.look = 'cinematic_doc'});
}

class ShotStyles {
  static const all = <ShotStyle>[
    ShotStyle('opening_reveal', 'Opening reveal', 'Slides out from behind the foreground, settles on the scene with a slow drift (story openers)',
        camera: [
          {'move': 'reveal', 'target': 'hero', 'u0': 0.0, 'u1': 0.6, 'intensity': 0.6, 'ease': 'ease_in'},
          {'move': 'drift', 'u0': 0.6, 'u1': 1.0, 'intensity': 0.3, 'ease': 'ease_out'},
        ],
        atmosphere: {'haze': 35, 'dust': 30},
        look: 'cinematic_doc'),
    ShotStyle('character_focus', 'Character focus', 'Gentle drift, then flies to the hero cut-out (introduce a person)',
        camera: [
          {'move': 'drift', 'u0': 0.0, 'u1': 0.35, 'intensity': 0.3, 'ease': 'ease_in'},
          {'move': 'fly_to', 'target': 'hero', 'u0': 0.35, 'u1': 1.0, 'intensity': 0.5, 'ease': 'ease_out'},
        ],
        atmosphere: {'dust': 25},
        look: 'cinematic_doc'),
    ShotStyle('crowd_pass', 'Crowd pass', 'Sideways pass-by through the layers (markets, crowds, streets)',
        camera: [
          {'move': 'pass_by', 'target': 'hero', 'u0': 0.0, 'u1': 1.0, 'intensity': 0.55, 'direction': 'right', 'ease': 'easy_ease'},
        ],
        atmosphere: {'dust': 30, 'haze': 20},
        look: 'warm_travel'),
    ShotStyle('slow_push_detail', 'Slow push on a detail', 'One long slow push into the hero detail (objects, documents, faces)',
        camera: [
          {'move': 'fly_to', 'target': 'hero', 'u0': 0.0, 'u1': 1.0, 'intensity': 0.75, 'ease': 'easy_ease'},
        ],
        atmosphere: {'dust': 20, 'light_rays': 30},
        look: 'cinematic_doc'),
    ShotStyle('crash_pull_back', 'Crash pull back', 'Starts tight on the hero and crashes back to the wide (shock reveals)',
        camera: [
          {'move': 'pull_back', 'target': 'hero', 'u0': 0.0, 'u1': 0.55, 'intensity': 0.8, 'ease': 'ease_out'},
          {'move': 'drift', 'u0': 0.55, 'u1': 1.0, 'intensity': 0.2, 'ease': 'easy_ease'},
        ],
        atmosphere: {'smoke': 25, 'dust': 30},
        look: 'noir'),
  ];

  static List<String> get ids => [for (final s in all) s.id];

  static ShotStyle? byId(String id) {
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Default camera without a style: a reveal into a fly-to on the hero
  /// (ease in → ease out so the move never stops halfway), or a slow drift.
  static List<Map<String, dynamic>> defaultCamera({required bool hasHero, required double duration}) {
    if (!hasHero || duration < 3) {
      return [
        {'move': 'drift', 'u0': 0.0, 'u1': 1.0, 'intensity': 0.4, 'ease': 'easy_ease'},
      ];
    }
    return [
      {'move': 'reveal', 'target': 'hero', 'u0': 0.0, 'u1': 0.45, 'intensity': 0.5, 'ease': 'ease_in'},
      {'move': 'fly_to', 'target': 'hero', 'u0': 0.45, 'u1': 1.0, 'intensity': 0.35, 'ease': 'ease_out'},
    ];
  }
}

/// Grades for a whole shot: the same looks as `apply_style`, applied once to
/// the shot's comp layer (not to every cut-out, so the vignette, grain and
/// letterbox are drawn once over the whole picture).
class ShotLooks {
  static List<String> get ids => MotionPresets.styles;

  static List<({String type, Map<String, List<double>> params})> effects(String style) {
    if (!MotionPresets.styles.contains(style)) {
      throw ArgumentError('Unknown look "$style". Available: ${MotionPresets.styles.join(', ')}, none');
    }
    ({String type, Map<String, List<double>> params}) fx(String t, Map<String, List<double>> p) => (type: t, params: p);
    ({String type, Map<String, List<double>> params}) color(double b, double c, double s) =>
        fx('color', {'brightness': [b], 'contrast': [c], 'saturation': [s]});
    ({String type, Map<String, List<double>> params}) tint(double r, double g, double b, double a) =>
        fx('tint', {'color': [r, g, b], 'amount': [a]});
    ({String type, Map<String, List<double>> params}) one(String t, double v) => fx(t, {'amount': [v]});
    return switch (style) {
      'cinematic_doc' => [color(0, 18, -25), tint(70, 130, 160, 12), one('vignette', 65), one('grain', 18), one('letterbox', 11)],
      'shorts_punch' => [color(6, 25, 25), one('vignette', 25)],
      'retro_film' => [color(4, -10, -30), tint(255, 180, 90, 30), one('vignette', 55), one('grain', 45), one('light_leak', 40)],
      'noir' => [color(-5, 35, -100), one('vignette', 75), one('grain', 30), one('letterbox', 11)],
      'warm_travel' => [color(8, 10, 12), tint(255, 170, 80, 20), one('vignette', 30), one('light_leak', 25)],
      _ => [color(5, 5, -5)],
    };
  }

  /// Puts the look on [l] (ids `<layer>_style_<type>`, replacing an earlier look).
  static void apply(Layer l, String style) {
    final list = effects(style);
    l.effects.removeWhere((e) => e.id.startsWith('${l.id}_style_'));
    for (final e in list) {
      final fx = EffectsCatalog.create(e.type, '${l.id}_style_${e.type}');
      e.params.forEach((k, v) => fx.params[k]!.staticValue = List.of(v));
      l.effects.add(fx);
    }
  }
}

/// Floor, contact shadows, "keep far layers visible" and edge checks.
class ShotGeometry {
  static void _map(AnimProp p, List<double> Function(List<double>) f) {
    p.staticValue = f(p.staticValue);
    for (final k in p.keyframes) {
      k.value = f(k.value);
    }
  }

  /// World y of the floor plane whose mid-band ground line is [floor].
  static double floorY(Composition comp, double floor) => comp.height * floor;

  /// World-space bottom (largest y) of [l] at [t].
  static double bottomOf(Composition comp, Layer l, double t) {
    final b = Scene3D.worldBox(comp, l, t);
    return b == null ? 0 : b.center.y + b.h / 2;
  }

  /// Moves a root 3D layer up/down so its bottom stands on the floor.
  static void snapToFloor(Composition comp, Layer l, double floorWorldY) {
    final dy = floorWorldY - bottomOf(comp, l, 0);
    if (dy.abs() < 1e-6) return;
    _map(l.prop(Props.position), (v) => [v[0], v[1] + dy, v[2]]);
  }

  /// A soft dark ellipse at the feet of [l] (same depth, just behind it),
  /// so a cut-out reads as standing on the ground. Inserted below [l].
  static Layer addContactShadow(Composition comp, Layer l, String id, {double opacity = 55}) {
    final b = Scene3D.worldBox(comp, l, 0)!;
    final bottom = b.center.y + b.h / 2;
    const lw = 400.0, lh = 100.0;
    final sw = b.w * 0.85, sh = math.max(b.h * 0.07, b.w * 0.05);
    final s = Layer(
      id: id,
      name: '${l.name} shadow',
      type: LayerType.solid,
      start: l.start,
      duration: l.duration,
      width: lw,
      height: lh,
      is3D: true,
      color: 0xFF000000,
    );
    s.prop(Props.position).staticValue = [b.center.x, bottom - sh * 0.15, b.center.z + 3];
    s.prop(Props.scale).staticValue = [sw / lw * 100, sh / lh * 100, 100];
    s.prop(Props.opacity).staticValue = [opacity];
    s.masks.add(Mask(id: '${id}_soft', shape: 'ellipse', props: {
      'center': AnimProp([lw / 2, lh / 2]),
      'size': AnimProp([lw, lh]),
      'feather': AnimProp([lh / 2]),
    }));
    final idx = comp.indexOf(l.id);
    comp.layers.insert(idx < 0 ? comp.layers.length : idx + 1, s);
    return s;
  }

  /// Sample times over [0, dur).
  static List<double> samples(double dur, [int n = 16]) => [for (int i = 0; i <= n; i++) math.min(dur * i / n, dur - 1e-3)];

  /// A horizontal floor plane at [floorWorldY] from just in front of the
  /// camera's closest point to beyond the far band, fading out with
  /// distance (or a floor texture from [media]). It stays in front of the
  /// camera for the whole shot (a 3D layer touching the lens is culled) and
  /// is painted behind every cut-out. Returns null when no such plane fits
  /// (the camera flies through the set).
  static Layer? buildFloor(Composition comp, String id, double floorWorldY, double dur,
      {MediaAsset? media, int color = 0xFF231B13, double alpha = 0.5, List<String>? log}) {
    final z0 = Scene3D.homeZoom(comp);
    final w = comp.width;
    var dn = 0.55 * z0;
    final df = 3.85 * z0;
    final minW = 1.15 * w * df / z0;
    var wg = 1.5 * w * df / z0;
    final times = samples(dur, 24);
    final cams = [for (final t in times) Evaluator.camera3D(comp, t)];
    const margin = kNearPlane + 60;
    var ok = false;
    for (int it = 0; it < 24; it++) {
      final zn = dn - z0;
      var worstCentre = double.infinity, worstSide = double.infinity;
      Camera3DState? camC;
      for (final cam in cams) {
        final c = (Vector3(w / 2, floorWorldY, zn) - cam.position).dot(cam.forward);
        if (c < worstCentre) {
          worstCentre = c;
          camC = cam;
        }
        for (final sx in [-1.0, 1.0]) {
          worstSide = math.min(worstSide, (Vector3(w / 2 + sx * wg / 2, floorWorldY, zn) - cam.position).dot(cam.forward));
        }
      }
      if (worstCentre >= margin && worstSide >= margin) {
        ok = true;
        break;
      }
      if (worstCentre < margin) {
        dn += (margin - worstCentre) / math.max(0.3, camC!.forward.z) + 10;
      } else if (wg > minW + 1) {
        wg = math.max(minW, wg * 0.8);
      } else {
        dn += (margin - worstSide) / 0.3 + 10;
      }
      if (dn > 1.6 * z0) break;
    }
    if (!ok) {
      log?.add('Floor plane skipped: the camera flies too close to the ground line (contact shadows kept)');
      return null;
    }
    final hg = df - dn;
    final zc = (dn + df) / 2 - z0;
    final Layer f;
    if (media != null) {
      f = Layer(
        id: id,
        name: 'Floor',
        type: media.type == MediaType.video ? LayerType.video : LayerType.image,
        start: 0,
        duration: comp.duration,
        width: media.width,
        height: media.height,
        is3D: true,
        mediaId: media.id,
      );
      f.prop(Props.scale).staticValue = [wg / math.max(1, media.width) * 100, hg / math.max(1, media.height) * 100, 100];
    } else {
      final a = (alpha.clamp(0.0, 1.0) * 255).round();
      final rgb = color & 0xFFFFFF;
      final end = rgb == 0 ? 0x00010101 : rgb; // fill2 0 would mean "no gradient"
      f = Layer(
        id: id,
        name: 'Floor',
        type: LayerType.shape,
        start: 0,
        duration: comp.duration,
        width: wg,
        height: hg,
        is3D: true,
        // Top of the shape = the near edge (rotation x 90°: layer y → depth).
        shape: ShapeData(kind: 'rect', fill: (a << 24) | rgb, fill2: end),
      );
    }
    f.prop(Props.position).staticValue = [w / 2, floorWorldY, zc];
    f.prop(Props.rotation).staticValue = [90, 0, 0];
    // Just above the plate (the bottom layer), below every cut-out.
    comp.layers.insert(math.max(0, comp.layers.length - 1), f);
    return f;
  }

  /// Keeps far layers from disappearing behind mid layers during the move:
  /// a far layer whose top sinks below the top of a mid layer in front of
  /// it (more than in the first frame, which is the composition) is grown
  /// about its bottom (up to ×1.6, so it stays on the ground), then lifted
  /// if that is not enough. Returns how many layers changed.
  static int keepFarVisible(Composition comp, List<Layer> far, List<Layer> mid, double dur, {List<String>? log}) {
    if (far.isEmpty || mid.isEmpty) return 0;
    final margin = comp.height * 0.03;
    final times = samples(dur);
    var changed = 0;
    for (final f in far) {
      var touched = false;
      double? base; // how far it already sits below the mid tops at the first frame (the composition)
      for (int pass = 0; pass < 4; pass++) {
        // Per sample: how much higher the top must go (screen px) and the
        // layer's screen height there. Growing about the bottom raises the
        // top by height × (k − 1) at every time, so one k fixes all samples.
        final needs = <({double t, double need, double h})>[];
        for (final t in times) {
          final fb = Scene3D.screenBox(comp, [f], t);
          if (fb == null || fb[3] <= fb[1]) continue;
          double? midTop;
          for (final m in mid) {
            final mb = Scene3D.screenBox(comp, [m], t);
            if (mb == null) continue;
            final overlap = math.min(fb[2], mb[2]) - math.max(fb[0], mb[0]);
            if (overlap <= (fb[2] - fb[0]) * 0.15) continue;
            if (mb[3] < fb[1]) continue; // the mid layer is above it on screen
            midTop = midTop == null ? mb[1] : math.min(midTop, mb[1]);
          }
          if (midTop == null) continue;
          final v = fb[1] - (midTop - margin);
          if (pass == 0 && t == times.first) base = math.max(0.0, v);
          final need = v - (base ?? 0.0);
          if (need > 0.5) needs.add((t: t, need: need + 1, h: fb[3] - fb[1]));
        }
        if (needs.isEmpty) break;
        touched = true;
        var kNeed = 1.0;
        for (final n in needs) {
          kNeed = math.max(kNeed, (n.h + n.need) / math.max(1.0, n.h));
        }
        final k = math.min(1.6, kNeed);
        final bottom = bottomOf(comp, f, 0);
        final a = f.prop(Props.anchor).staticValue;
        _map(f.prop(Props.scale), (v) => [v[0] * k, v[1] * k, v[2]]);
        final sy = f.prop(Props.scale).valueAt(0)[1].abs() / 100;
        final newY = bottom - (f.height - a[1]) * sy;
        _map(f.prop(Props.position), (v) => [v[0], newY, v[2]]);
        if (kNeed > k) {
          // Still not enough: lift it (world px) by the largest remainder.
          var lift = 0.0;
          for (final n in needs) {
            final rest = n.need - n.h * (k - 1);
            if (rest <= 0) continue;
            final cam = Evaluator.camera3D(comp, n.t);
            final b = Scene3D.worldBox(comp, f, n.t);
            final d = b == null ? Scene3D.homeZoom(comp) : math.max(Scene3D.minClearance, cam.depthOf(b.center));
            lift = math.max(lift, rest * d / cam.zoom);
          }
          _map(f.prop(Props.position), (v) => [v[0], v[1] - lift, v[2]]);
        }
      }
      if (touched) {
        changed++;
        log?.add('${f.name}: kept above the mid layers during the move');
      }
    }
    return changed;
  }

  /// Grows [plate] (about its anchor) so it covers the frame at every
  /// sampled time of the shot: no empty edges.
  static void ensureCover(Composition comp, Layer plate, double dur, {List<String>? log}) {
    var need = 1.0;
    for (final t in samples(dur, 24)) {
      if (!plate.isActiveAt(t)) continue;
      need = math.max(need, Scene3D.coverScale(comp, plate, t));
    }
    if (need > 1.0005) {
      final s = math.min(need * 1.01, 3.0);
      _map(plate.prop(Props.scale), (v) => [v[0] * s, v[1] * s, v[2]]);
      log?.add('Plate scaled ×${s.toStringAsFixed(2)} so the camera shows no empty edges');
    }
  }

  /// True when the frame corners are inside [l] on screen at [t].
  static bool covers(Composition comp, Layer l, double t) {
    for (final it in Evaluator.evaluate(comp, t, velocity: false)) {
      if (it.layer.id != l.id) continue;
      final q = it.corners();
      final w = comp.width, h = comp.height;
      return [
        [1.0, 1.0],
        [w - 1, 1.0],
        [w - 1, h - 1],
        [1.0, h - 1],
      ].every((p) => pointInQuad(Vector2(p[0], p[1]), q));
    }
    return false;
  }
}
