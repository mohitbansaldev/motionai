import 'dart:math' as math;

import '../model/anim_prop.dart';
import '../model/camera.dart';
import '../model/easing.dart';
import '../model/effects_catalog.dart';
import '../model/layer.dart';
import '../model/project.dart';
import '../presets/realism.dart';
import '../presets/scene3d.dart';
import 'edit_commands.dart';
import 'v3_fx_commands.dart'; // V3-D

/// V2-D realism commands, called from [EditCommands] through small hooks:
/// `match_colour`, `camera_shake`, `set_dof`, looks for `apply_style`,
/// `adjustment` on add/update_layer, `dof` on set_comp, make_3d extras.
class RealismCommands {
  static const ops = ['match_colour', 'match_color', 'camera_shake', 'set_dof'];

  static void run(Project project, Map<String, dynamic> c, double now, CommandResult r) {
    final comp = project.editComp;
    switch (c['op']) {
      case 'match_colour':
      case 'match_color':
        r.log.add(matchColour(project, comp, c, now));
        break;
      case 'camera_shake':
        r.log.add(cameraShake(comp, c, now));
        break;
      case 'set_dof':
        r.log.add(setDof(comp, c));
        break;
    }
  }

  static double? _num(Map<String, dynamic> c, String k) {
    final v = c[k];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    throw CommandError('"$k" must be a number');
  }

  static Layer _layer(Composition comp, dynamic id, String what) {
    if (id is! String) throw CommandError('Missing "$what" layer id');
    final l = comp.layerById(id);
    if (l == null) throw CommandError('No layer "$id". Layers: ${comp.layers.map((l) => '${l.id} (${l.name})').join(', ')}');
    return l;
  }

  // ------------------------------------------------------------ match_colour

  /// The visual layer right below [cut] that covers its centre on screen.
  static Layer? plateBelow(Composition comp, Layer cut, double t) {
    final b = Scene3D.screenBox(comp, [cut], t);
    final i0 = comp.indexOf(cut.id);
    if (b == null || i0 < 0) return null;
    final cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2;
    Layer? fallback;
    for (int i = i0 + 1; i < comp.layers.length; i++) {
      final l = comp.layers[i];
      if (!Scene3D.isVisual(l) || !l.isActiveAt(t) || l.adjustment) continue;
      if (l.type != LayerType.image && l.type != LayerType.solid) continue;
      final pb = Scene3D.screenBox(comp, [l], t);
      if (pb == null) continue;
      if (cx >= pb[0] && cx <= pb[2] && cy >= pb[1] && cy <= pb[3]) return l;
      fallback ??= l;
    }
    return fallback;
  }

  /// Region of [plate] (fractions of its box) behind [cut] on screen.
  static List<double> regionBehind(Composition comp, Layer cut, Layer plate, double t) {
    final b = Scene3D.screenBox(comp, [cut], t), pb = Scene3D.screenBox(comp, [plate], t);
    if (b == null || pb == null) return const [0, 0, 1, 1];
    final pw = pb[2] - pb[0], ph = pb[3] - pb[1];
    if (pw <= 0 || ph <= 0) return const [0, 0, 1, 1];
    // A little wider than the cut-out: the light around it counts too.
    final mx = (b[2] - b[0]) * 0.25, my = (b[3] - b[1]) * 0.15;
    final x0 = ((b[0] - mx - pb[0]) / pw).clamp(0.0, 1.0), x1 = ((b[2] + mx - pb[0]) / pw).clamp(0.0, 1.0);
    final y0 = ((b[1] - my - pb[1]) / ph).clamp(0.0, 1.0), y1 = ((b[3] + my - pb[1]) / ph).clamp(0.0, 1.0);
    if (x1 - x0 < 0.02 || y1 - y0 < 0.02) return const [0, 0, 1, 1];
    return [x0, y0, x1, y1];
  }

  static String matchColour(Project project, Composition comp, Map<String, dynamic> c, double now) {
    final cut = _layer(comp, c['layer'], 'layer');
    final t = (_num(c, 'time') ?? now).clamp(cut.start, math.max(cut.start, cut.end - 1e-3)).toDouble();
    final to = c['to'] ?? 'below';
    final plate = to == 'below' ? plateBelow(comp, cut, t) : _layer(comp, to, 'to');
    if (plate == null) throw CommandError('match_colour: no image/solid layer below "${cut.id}" — give "to": <plate layer id>');
    if (plate.id == cut.id) throw CommandError('match_colour: "to" must be another layer');
    if (plate.type != LayerType.image && plate.type != LayerType.solid) {
      throw CommandError('match_colour: "to" must be an image or solid layer (videos: use a still frame as the plate)');
    }
    final cs = Realism.statsOfLayer(project, cut);
    if (cs == null) throw CommandError('match_colour: cannot read the pixels of "${cut.id}" (image layers and solids only)');
    final region = regionBehind(comp, cut, plate, t);
    final ps = Realism.statsOfLayer(project, plate, region: region);
    if (ps == null) throw CommandError('match_colour: cannot read the pixels of "${plate.id}"');
    final amount = (_num(c, 'amount') ?? 100).clamp(0.0, 100.0).toDouble();
    final params = Realism.matchParams(cs, ps, amount: amount);
    final id = '${cut.id}_match';
    final old = cut.effectById(id);
    final fx = EffectsCatalog.create('grade', id);
    params.forEach((k, v) => fx.params[k]!.staticValue = v);
    if (old != null) {
      cut.effects[cut.effects.indexOf(old)] = fx;
    } else {
      // Before stylising effects so the match happens on the raw pixels.
      final at = cut.effects.indexWhere((e) => e.type != 'chroma_key' && e.type != 'contact_shadow');
      cut.effects.insert(at < 0 ? cut.effects.length : at, fx);
    }
    // Light wrap takes the plate's light colour.
    final lightColor = [
      for (final v in [ps.r, ps.g, ps.b]) (math.pow(v.clamp(0.0, 1.0), 0.6) * 255).clamp(0.0, 255.0).roundToDouble(),
    ];
    var wrap = cut.effects.where((e) => e.type == 'light_wrap').firstOrNull;
    if (wrap == null && c['light_wrap'] == true) {
      wrap = EffectsCatalog.create('light_wrap', '${cut.id}_wrap');
      cut.effects.add(wrap);
    }
    wrap?.params['color']!.staticValue = lightColor;
    final g = params['gain']!;
    return 'Matched ${cut.name} to ${plate.name}: gain ${g.map((v) => v.round()).join('/')}%, '
        'saturation ${params['saturation']![0].round()}, contrast ${params['contrast']![0].round()}';
  }

  // ------------------------------------------------------------ camera_shake

  static String cameraShake(Composition comp, Map<String, dynamic> c, double now) {
    final style = '${c['style'] ?? 'handheld'}';
    final si = Realism.shakeStyles.indexOf(style);
    if (si < 0) throw CommandError('camera_shake style must be one of ${Realism.shakeStyles.join(', ')}');
    final start = _num(c, 'start') ?? now;
    final dur = math.max(comp.frameDuration * 2, _num(c, 'duration') ?? (style == 'impact' ? 0.8 : 2.0));
    var amount = _num(c, 'amount') ?? 40;
    if (amount < 1 && amount > 0) amount *= 100; // 0..1 also accepted
    final amp = amount.clamp(0.0, 200.0) / 100 * Realism.shakeScale(style) * comp.height;
    final rig = comp.camera;
    final has3D = comp.layers.any((l) => l.is3D);
    var note = '';
    if (rig.mode == CameraMode.off) {
      rig.mode = has3D ? CameraMode.threeD : CameraMode.twoD;
      note = ' (camera switched to ${has3D ? '3D' : '2D'})';
    }
    final p = rig.props.putIfAbsent(Realism.shakeProp, () => AnimProp([0]));
    final end = start + dur;
    p.keyframes.removeWhere((k) => k.time >= start - 1e-3 && k.time <= end + 1e-3);
    for (final (t, v, e) in Realism.shakeEnvelope(style, start, dur, amp)) {
      p.setKeyframe(t, [v], easing: e);
    }
    final sp = rig.props.putIfAbsent(Realism.shakeStyleProp, () => AnimProp([0]));
    sp.keyframes.removeWhere((k) => k.time >= start - 1e-3 && k.time <= end + 1e-3);
    if (sp.keyframes.isEmpty) {
      sp.staticValue = [si.toDouble()];
      sp.setKeyframe(start, [si.toDouble()], easing: Easing.hold);
    } else {
      // Later shakes keep their own style after this one ends.
      final after = sp.valueAt(end + 2e-3);
      sp.setKeyframe(start, [si.toDouble()], easing: Easing.hold);
      sp.setKeyframe(end + 2e-3, after, easing: Easing.hold);
    }
    if (end > comp.duration) comp.duration = end;
    return 'Camera shake ($style) ${start.toStringAsFixed(2)}–${end.toStringAsFixed(2)} s, ${amp.toStringAsFixed(1)} px$note';
  }

  // ----------------------------------------------------------------- set_dof

  static String setDof(Composition comp, Map<String, dynamic> c) {
    if (c['keys'] != null) return V3FxCommands.dofKeys(comp, c); // V3-D: keyframed rack focus
    final rig = comp.camera;
    final focus = c['focus'];
    if (c['enabled'] == false || focus == 'off' || focus == false) {
      comp.dofFocus = null;
      rig.prop(CamProps.aperture)
        ..keyframes.clear()
        ..staticValue = [0];
      return 'Depth of field off';
    }
    if (focus is num) {
      comp.dofFocus = null;
      rig.prop(CamProps.focus)
        ..keyframes.clear()
        ..staticValue = [focus.toDouble()];
    } else if (focus == null || focus == 'target') {
      comp.dofFocus = 'target';
    } else {
      final l = _layer(comp, focus, 'focus');
      if (!l.is3D) throw CommandError('set_dof focus layer "${l.id}" is not 3D (run make_3d first)');
      comp.dofFocus = l.id;
    }
    final ap = rig.prop(CamProps.aperture);
    final a = _num(c, 'aperture');
    if (a != null) {
      ap
        ..keyframes.clear()
        ..staticValue = [a.clamp(0.0, 200.0).toDouble()];
    } else if (!ap.isAnimated && ap.staticValue[0] <= 0) {
      ap.staticValue = [20];
    }
    var note = '';
    if (rig.mode != CameraMode.threeD) note = ' (needs the 3D camera: run make_3d / camera_shot)';
    return 'Depth of field: focus on ${comp.dofFocus ?? '${rig.prop(CamProps.focus).staticValue[0].round()} px'}, '
        'aperture ${ap.valueAt(0)[0].round()}$note';
  }

  /// `set_comp {dof: {focus, aperture} | false}`.
  static void applyComp(Composition comp, Map<String, dynamic> c) {
    final d = c['dof'];
    if (d == null) return;
    if (d == false || d == 'off') {
      setDof(comp, {'focus': 'off'});
    } else if (d == true) {
      setDof(comp, {'focus': 'target'});
    } else if (d is Map) {
      setDof(comp, Map<String, dynamic>.from(d));
    } else if (d is String) {
      setDof(comp, {'focus': d});
    } else {
      throw CommandError('set_comp dof must be {focus: "target" | layer id | px, aperture} or false');
    }
  }

  // ------------------------------------------------------------------ hooks

  /// add_layer / update_layer `adjustment: true|false`.
  static void applyLayer(Layer l, Map<String, dynamic> c) {
    final a = c['adjustment'];
    if (a == null) return;
    if (a == true && l.type != LayerType.solid && l.type != LayerType.nullObject) {
      throw CommandError('adjustment: true works on solid or null layers (add_layer type "solid")');
    }
    l.adjustment = a == true;
    if (l.adjustment && l.is3D) l.is3D = false;
  }

  /// add_effect: a contact_shadow on an image layer measures the feet from
  /// the image's alpha (unless the command gave the footprint).
  static void onEffectAdded(Project project, Layer l, Effect e, Map<String, dynamic> c) {
    if (e.type != 'contact_shadow') return;
    final p = c['params'];
    if (p is Map && (p.containsKey('x0') || p.containsKey('x1') || p.containsKey('bottom'))) return;
    Realism.fillFootprint(project, l, e);
  }

  /// apply_style: documentary looks and film_look go on an adjustment layer.
  /// Returns false when [style] is not one of ours.
  static bool applyStyle(Composition comp, Map<String, dynamic> c, CommandResult r) {
    final style = '${c['style'] ?? ''}';
    if (!Realism.looks.contains(style) && style != Realism.filmLook) return false;
    final id = Realism.applyLook(comp, style);
    r.createdIds.add(id);
    r.log.add('${Realism.lookLabel(style)} look on adjustment layer "$id" (affects every layer below it)');
    return true;
  }

  /// make_3d never moves adjustment layers into depth.
  static List<String>? make3DLayers(Composition comp, List<String>? ids, double start) {
    if (!comp.layers.any((l) => l.adjustment)) return ids;
    if (ids != null && ids.isNotEmpty) {
      final keep = ids.where((id) => comp.layerById(id)?.adjustment != true).toList();
      if (keep.isEmpty) throw CommandError('make_3d: adjustment layers stay flat (they act on everything below them)');
      return keep;
    }
    var w = comp.layers.where((l) => Scene3D.isVisual(l) && !l.adjustment && l.isActiveAt(start)).map((l) => l.id).toList();
    if (w.isEmpty) w = comp.layers.where((l) => Scene3D.isVisual(l) && !l.adjustment).map((l) => l.id).toList();
    return w;
  }

  static void afterMake3D(Project project, Composition comp, List<String> roots, Map<String, dynamic> c, double start, List<String> log) {
    final haze = _num(c, 'haze') ?? 25;
    final shadows = c['contact_shadows'] != false && c['shadows'] != false;
    Realism.afterMake3D(project, comp, roots, start, haze: haze.clamp(0.0, 100.0).toDouble(), shadows: shadows, log: log);
  }
}
