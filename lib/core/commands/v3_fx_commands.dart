import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart' show Vector3;

import '../../director/sfx.dart';
import '../engine/evaluator.dart';
import '../engine/precomp.dart';
import '../model/anim_prop.dart';
import '../model/camera.dart';
import '../model/easing.dart';
import '../model/effects_catalog.dart';
import '../model/layer.dart';
import '../model/project.dart';
import '../presets/doc_transitions.dart' show v3DuckAudio;
import 'edit_commands.dart';

/// V3-D: mood & character FX ops (documentary patterns P-D 39–53).
///
///   mood_flood {at?, duration?: 0.9, hold?: 2.5, color?: "#E0283A", dark?: "#5A0A10", from?: corner, keep?: [ids], sfx?: "braam" | false, id?}
///   tint_wipe {at?, color?: "#D0101A", amount?: 70, from?: left|right|top|bottom, duration?: 0.6, hold?: 2, id?}
///   grade_swap {to: hope|warm|cold|dread|archive|normal, at?, duration?: 0 (snap), until?, amount?, id?}
///   spotlight_subject {keep: [ids], layers? | shot?, others?: {mono: 100, dim: 15, blur: 0}, tint?: {color, amount}, start?, duration?: 3, attack?: 0.25, release?: 0.5}
///   pulse {layer, effect? | prop?, param?, from, to, period?: 1, start?, duration?: 3, sync?: [ids], sfx?: kind}
///   cut_to_black {at?, hold?: 1.5, silence?: true, sfx?: "impact" | false, id?}
///   lightning {at: s | [s...], bolt?: true, x?: 0.62, color?: "#DDE6FF", sfx?: "thunder" | false, id?}
///   montage {media: [ids], start?, every?: 0.35, looks?: [...], zoom?: 8, sound?: true, id?}
///   swap_layer {layer, with: layer id | media id, at?, transition?: pop|cut|fade|flash, duration?: 0.2, sfx?}
///   set_dof {keys: [{t, focus: px | layer id}], aperture?} (hook from RealismCommands.setDof)
///
/// All run inside the dispatcher: atomic, one undo step.
class V3FxCommands {
  static const ops = [
    'mood_flood', 'tint_wipe', 'grade_swap', 'spotlight_subject', 'pulse', 'cut_to_black', 'lightning', 'montage', 'swap_layer',
  ];

  static const montageLooks = ['threshold', 'duotone_green', 'red_paint', 'magenta', 'grunge', 'crop'];
  static const grades = ['hope', 'warm', 'cold', 'dread', 'archive', 'normal'];
  static const corners = ['top_left', 'top_right', 'bottom_left', 'bottom_right', 'left', 'right', 'top', 'bottom', 'center'];

  // Eases (After Effects graph style).
  static const _soft = Easing.bezierCurve(0.45, 0, 0.55, 1);
  static const _sine = Easing.bezierCurve(0.37, 0, 0.63, 1);
  static const _out = Easing.bezierCurve(0.33, 1, 0.68, 1);
  static const _in = Easing.bezierCurve(0.32, 0, 0.67, 0);
  static const _expoOut = Easing.bezierCurve(0.16, 1, 0.3, 1);

  static void run(Project p, Map<String, dynamic> c, double now, CommandResult r, void Function(Map<String, dynamic>) exec) {
    final comp = p.editComp;
    switch (c['op']) {
      case 'mood_flood':
        moodFlood(p, comp, c, now, r, exec);
      case 'tint_wipe':
        tintWipe(comp, c, now, r);
      case 'grade_swap':
        gradeSwap(comp, c, now, r);
      case 'spotlight_subject':
        spotlight(p, comp, c, now, r);
      case 'pulse':
        pulse(comp, c, now, r, exec);
      case 'cut_to_black':
        cutToBlack(comp, c, now, r, exec);
      case 'lightning':
        lightning(comp, c, now, r, exec);
      case 'montage':
        montage(p, comp, c, now, r, exec);
      case 'swap_layer':
        swapLayer(p, comp, c, now, r, exec);
    }
  }

  // ------------------------------------------------------------- helpers

  static double? _num(Map<String, dynamic> c, String k) {
    final v = c[k];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    throw CommandError('"$k" must be a number');
  }

  static List<double> _rgb(dynamic v, List<double> d, String what) {
    if (v == null) return d;
    if (v is List && v.length >= 3 && v.every((e) => e is num)) return [for (final e in v.take(3)) (e as num).toDouble()];
    if (v is String) {
      final s = v.trim().replaceFirst('#', '').replaceFirst('0x', '');
      final n = int.tryParse(s, radix: 16);
      if (n != null && (s.length == 6 || s.length == 8)) return [((n >> 16) & 0xFF).toDouble(), ((n >> 8) & 0xFF).toDouble(), (n & 0xFF).toDouble()];
    }
    throw CommandError('$what must be a colour "#RRGGBB" (got "$v")');
  }

  static Layer _layer(Composition comp, dynamic id, String what) {
    if (id is! String) throw CommandError('Missing "$what" layer id');
    final l = comp.layerById(id);
    if (l == null) throw CommandError('No layer "$id". Layers: ${comp.layers.map((l) => '${l.id} (${l.name})').join(', ')}');
    return l;
  }

  static List<String> _ids(dynamic v) => v is List ? [for (final e in v) '$e'] : (v is String ? [v] : const []);

  /// [base], or [base]_2, _3… — the first id not used in [comp].
  static String _uniqueId(Composition comp, String base) {
    if (comp.layerById(base) == null) return base;
    for (int i = 2;; i++) {
      final id = '${base}_$i';
      if (comp.layerById(id) == null) return id;
    }
  }

  static Effect _fx(Layer l, String type, String id, [Map<String, List<double>> values = const {}]) {
    l.effects.removeWhere((e) => e.id == id);
    final e = EffectsCatalog.create(type, id);
    values.forEach((k, v) => e.params[k]!.staticValue = List.of(v));
    l.effects.add(e);
    return e;
  }

  /// A full-frame adjustment layer at the top of [comp].
  static Layer _adjust(Composition comp, String id, String name, double start, double end, {bool fullMask = true}) {
    final l = Layer(
      id: id, name: name, type: LayerType.solid, start: start, duration: math.max(comp.frameDuration, end - start),
      width: comp.width, height: comp.height, color: 0x00000000,
    )..adjustment = true;
    l.prop(Props.position).staticValue = [comp.width / 2, comp.height / 2, 0];
    // A mask covering the frame makes the adjustment mix over the untouched
    // picture, so reveal-shaped effects (ink, wipes) show it only where they reach.
    if (fullMask) {
      l.masks.add(Mask(id: '${id}_frame', shape: 'rect', props: {
        'center': AnimProp([comp.width / 2, comp.height / 2]),
        'size': AnimProp([comp.width * 1.02, comp.height * 1.02]),
        'feather': AnimProp([0]),
      }));
    }
    comp.layers.insert(0, l);
    return l;
  }

  static (double, double) _corner(String c) => switch (c) {
        'top_left' => (0.0, 0.0),
        'top_right' => (100.0, 0.0),
        'bottom_right' => (100.0, 100.0),
        'left' => (0.0, 50.0),
        'right' => (100.0, 50.0),
        'top' => (50.0, 0.0),
        'bottom' => (50.0, 100.0),
        'center' => (50.0, 50.0),
        _ => (0.0, 100.0), // bottom_left
      };

  static String _choice(Map<String, dynamic> c, String k, String d, List<String> options) {
    final v = c[k] == null ? d : '${c[k]}'.toLowerCase();
    if (!options.contains(v)) throw CommandError('"$k" must be one of ${options.join(', ')} (got "$v")');
    return v;
  }

  /// [l] plus every layer parented (directly or not) to it.
  static List<Layer> _withChildren(Composition comp, Layer l) {
    final out = <Layer>[l];
    var grew = true;
    while (grew) {
      grew = false;
      for (final x in comp.layers) {
        if (x.parentId != null && !out.contains(x) && out.any((o) => o.id == x.parentId)) {
          out.add(x);
          grew = true;
        }
      }
    }
    return out;
  }

  static void _sfx(Map<String, dynamic> c, String key, String def, double time, void Function(Map<String, dynamic>) exec, CommandResult r) {
    final v = c[key];
    if (v == false || v == 'none') return;
    final kind = v is String ? v : def;
    if (!Sfx.all.contains(kind)) throw CommandError('"$key": "$kind" is not a sound. Sounds: ${Sfx.all.join(', ')}');
    exec({'op': 'add_sfx', 'kind': kind, 'time': math.max(0.0, time)});
  }

  // ---------------------------------------------------------- mood_flood

  /// 39. An organic ink edge spreads from a corner and floods the picture
  /// red monochrome; `keep` layers stay in colour above it; ends hard.
  static void moodFlood(Project p, Composition comp, Map<String, dynamic> c, double now, CommandResult r, void Function(Map<String, dynamic>) exec) {
    final at = _num(c, 'at') ?? _num(c, 'start') ?? now;
    final spread = (_num(c, 'duration') ?? 0.9).clamp(0.1, 5.0).toDouble();
    final hold = (_num(c, 'hold') ?? 2.5).clamp(0.0, 60.0).toDouble();
    final light = _rgb(c['color'], const [224, 40, 58], 'color');
    final dark = _rgb(c['dark'], [light[0] * 0.4, light[1] * 0.25, light[2] * 0.28], 'dark');
    final from = _choice(c, 'from', 'bottom_left', corners);
    final end = at + spread + hold;
    final id = c['id'] is String ? '${c['id']}' : _uniqueId(comp, 'mood_flood');
    if (comp.layerById(id) != null) throw CommandError('A layer "$id" already exists');
    final keep = [for (final k in _ids(c['keep'])) _layer(comp, k, 'keep')];
    final l = _adjust(comp, id, 'Mood flood', at, end);
    _fx(l, 'duotone', '${id}_duo', {'dark': dark, 'light': light, 'amount': [100]});
    _fx(l, 'color', '${id}_contrast', {'contrast': [18]});
    _fx(l, 'vignette', '${id}_vig', {'amount': [55], 'size': [55]});
    final (cx, cy) = _corner(from);
    final ink = _fx(l, 'reveal', '${id}_ink', {'kind': [1], 'softness': [40], 'cx': [cx], 'cy': [cy]});
    ink.params['progress']!
      ..setKeyframe(at, [0], easing: _soft)
      ..setKeyframe(at + spread, [100], easing: _soft);
    // Kept layers: in-colour copies above the flood for its span only.
    var copies = 0;
    for (final k in keep) {
      final group = _withChildren(comp, k)..sort((x, y) => comp.indexOf(x.id).compareTo(comp.indexOf(y.id)));
      final map = {for (final g in group) g.id: '${id}_keep_${g.id}'};
      final made = <Layer>[];
      for (final g in group) {
        final s = math.max(g.start, at), e = math.min(g.end, end);
        if (e <= s + comp.frameDuration * 0.5) continue;
        final cp = g.copy(newId: map[g.id]!)..name = '${g.name} (kept in colour)';
        cp.sourceIn = g.sourceTimeAt(s);
        cp.start = s;
        cp.duration = e - s;
        if (cp.parentId != null && map.containsKey(cp.parentId)) cp.parentId = map[cp.parentId];
        made.add(cp);
      }
      // Same relative order as the originals, all above the flood.
      comp.layers.insertAll(0, made);
      copies += made.length;
      r.createdIds.addAll(made.map((m) => m.id));
    }
    r.createdIds.add(id);
    _sfx(c, 'sfx', 'braam', at, exec, r);
    r.log.add('Mood flood "$id" from $from at ${at.toStringAsFixed(2)} s for ${(end - at).toStringAsFixed(2)} s'
        '${keep.isEmpty ? '' : ' ($copies layer(s) kept in colour)'}');
  }

  // ----------------------------------------------------------- tint_wipe

  /// A straight colour-tint wipe across the frame (adjustment layer).
  static void tintWipe(Composition comp, Map<String, dynamic> c, double now, CommandResult r) {
    final at = _num(c, 'at') ?? _num(c, 'start') ?? now;
    final d = (_num(c, 'duration') ?? 0.6).clamp(0.05, 5.0).toDouble();
    final hold = (_num(c, 'hold') ?? 2.0).clamp(0.0, 60.0).toDouble();
    final col = _rgb(c['color'], const [208, 16, 26], 'color');
    final amount = (_num(c, 'amount') ?? 70).clamp(0.0, 100.0).toDouble();
    // "direction" = travel direction; "from" = the side it enters from.
    var from = c['from'] is String ? '${c['from']}' : null;
    from ??= switch ('${c['direction'] ?? 'right'}') { 'left' => 'right', 'up' => 'bottom', 'down' => 'top', _ => 'left' };
    final side = const ['left', 'right', 'top', 'bottom'].indexOf(from);
    if (side < 0) throw CommandError('tint_wipe "from" must be left, right, top or bottom');
    final id = c['id'] is String ? '${c['id']}' : _uniqueId(comp, 'tint_wipe');
    if (comp.layerById(id) != null) throw CommandError('A layer "$id" already exists');
    final l = _adjust(comp, id, 'Tint wipe', at, at + d + hold);
    _fx(l, 'tint', '${id}_tint', {'color': col, 'amount': [amount]});
    _fx(l, 'slant_wipe', '${id}_wipe', {'angle': [0], 'side': [side.toDouble()], 'softness': [12]}).params['progress']!
      ..setKeyframe(at, [0], easing: _soft)
      ..setKeyframe(at + d, [100], easing: _soft);
    r.createdIds.add(id);
    r.log.add('Tint wipe "$id" from the $from at ${at.toStringAsFixed(2)} s');
  }

  // ---------------------------------------------------------- grade_swap

  /// Snaps (or fades) the whole picture to a mood grade; ends an earlier
  /// grade_swap still running.
  static void gradeSwap(Composition comp, Map<String, dynamic> c, double now, CommandResult r) {
    final to = _choice(c, 'to', 'hope', grades);
    final at = _num(c, 'at') ?? _num(c, 'start') ?? now;
    final fade = (_num(c, 'duration') ?? 0).clamp(0.0, 10.0).toDouble();
    final until = _num(c, 'until') ?? comp.duration;
    final amount = (_num(c, 'amount') ?? 100).clamp(0.0, 100.0).toDouble();
    var ended = 0;
    for (final l in comp.layers) {
      if (!l.adjustment || !l.id.startsWith('grade_')) continue;
      if (l.start < at - 1e-6 && l.end > at + 1e-6) {
        l.duration = math.max(comp.frameDuration, at + fade - l.start);
        ended++;
      }
    }
    if (to == 'normal') {
      r.log.add(ended == 0 ? 'grade_swap normal: no grade was running at ${at.toStringAsFixed(2)} s' : 'Grade back to normal at ${at.toStringAsFixed(2)} s');
      return;
    }
    if (until <= at + comp.frameDuration) throw CommandError('grade_swap "until" must be after "at"');
    final id = c['id'] is String ? '${c['id']}' : _uniqueId(comp, 'grade_$to');
    if (comp.layerById(id) != null) throw CommandError('A layer "$id" already exists');
    final l = _adjust(comp, id, 'Grade: $to', at, until, fullMask: false);
    final mix = amount;
    switch (to) {
      case 'hope':
        _fx(l, 'grade', '${id}_grade', {'lift': [0, 2, -1], 'gain': [106, 112, 94], 'saturation': [38], 'contrast': [10], 'amount': [mix]});
        _fx(l, 'color', '${id}_lift', {'brightness': [4]});
      case 'warm':
        _fx(l, 'grade', '${id}_grade', {'lift': [3, 1, -3], 'gain': [114, 102, 84], 'saturation': [15], 'contrast': [8], 'amount': [mix]});
      case 'cold':
        _fx(l, 'grade', '${id}_grade', {'lift': [-2, 0, 6], 'gain': [82, 95, 116], 'saturation': [-35], 'contrast': [10], 'amount': [mix]});
        _fx(l, 'vignette', '${id}_vig', {'amount': [60], 'size': [60]});
      case 'dread':
        _fx(l, 'duotone', '${id}_duo', {'dark': [90, 10, 16], 'light': [224, 40, 58], 'amount': [mix]});
        _fx(l, 'color', '${id}_contrast', {'contrast': [15]});
        _fx(l, 'vignette', '${id}_vig', {'amount': [55], 'size': [55]});
      case 'archive':
        _fx(l, 'grade', '${id}_grade', {'lift': [5, 3, 0], 'gain': [112, 96, 74], 'saturation': [-100], 'contrast': [-8], 'amount': [mix]});
        _fx(l, 'grain', '${id}_grain', {'amount': [30]});
    }
    if (fade > 0) {
      l.prop(Props.opacity)
        ..setKeyframe(at, [0], easing: _soft)
        ..setKeyframe(at + fade, [100], easing: _soft);
    }
    r.createdIds.add(id);
    r.log.add('Grade "$to" from ${at.toStringAsFixed(2)} s${fade > 0 ? ' (fade ${fade.toStringAsFixed(2)} s)' : ' (snap)'}${ended > 0 ? ', previous grade ended' : ''}');
  }

  // ---------------------------------------------------- spotlight_subject

  /// 50. Selective colour: everyone but the kept subject(s) goes mono and
  /// dim; optional red pain tint on the kept ones; eased in and released.
  static void spotlight(Project p, Composition comp, Map<String, dynamic> c, double now, CommandResult r) {
    var target = comp;
    var offset = 0.0; // comp time → target time
    final shot = c['shot'];
    if (shot is String) {
      final host = p.main.layerById(shot);
      final child = host == null ? p.compById(shot) : Precomp.childOf(p, host);
      if (child == null) throw CommandError('spotlight_subject: no shot "$shot"');
      target = child;
      if (host != null) offset = (Precomp.childTime(host, child, 0) ?? 0);
      if (host != null && (host.speed - 1).abs() > 1e-6) r.log.add('spotlight_subject: shot plays at speed ${host.speed}: times are shot times');
    }
    final keepIds = _ids(c['keep']);
    if (keepIds.isEmpty) throw CommandError('spotlight_subject needs "keep": [layer ids] (the subject)');
    final keep = [for (final k in keepIds) _layer(target, k, 'keep')];
    final keepSet = {for (final k in keep) ..._withChildren(target, k).map((l) => l.id)};
    final start = (_num(c, 'start') ?? _num(c, 'at') ?? now) + offset;
    final dur = (_num(c, 'duration') ?? 3).clamp(0.1, 600.0).toDouble();
    final attack = (_num(c, 'attack') ?? 0.25).clamp(0.02, 5.0).toDouble();
    final release = (_num(c, 'release') ?? 0.5).clamp(0.02, 5.0).toDouble();
    final end = start + dur;
    final others = c['others'] is Map ? Map<String, dynamic>.from(c['others'] as Map) : const <String, dynamic>{};
    final mono = (_num(others, 'mono') ?? 100).clamp(0.0, 100.0).toDouble();
    final dim = (_num(others, 'dim') ?? 15).clamp(0.0, 100.0).toDouble();
    final blur = (_num(others, 'blur') ?? 0).clamp(0.0, 100.0).toDouble();
    final List<Layer> pool;
    if (c['layers'] is List) {
      pool = [for (final id in _ids(c['layers'])) _layer(target, id, 'layers')];
    } else {
      pool = [
        for (final l in target.layers)
          if (l.type != LayerType.audio && l.type != LayerType.nullObject && !l.adjustment && l.end > start && l.start < end) l,
      ];
    }
    void envelope(AnimProp ap, double v) {
      ap.keyframes.removeWhere((k) => k.time >= start - kTimeEpsilon && k.time <= end + release + kTimeEpsilon);
      ap.setKeyframe(start, [0], easing: _out);
      ap.setKeyframe(start + attack, [v], easing: _soft);
      ap.setKeyframe(end, [v], easing: _in);
      ap.setKeyframe(end + release, [0], easing: _in);
    }

    var n = 0;
    for (final l in pool) {
      if (keepSet.contains(l.id)) continue;
      if (mono > 0) envelope(_fx(l, 'mono', '${l.id}_spot_mono').params['amount']!..staticValue = [0], mono);
      if (dim > 0) envelope(_fx(l, 'color', '${l.id}_spot_dim').params['brightness']!, -dim * 1.6);
      if (blur > 0) envelope(_fx(l, 'blur', '${l.id}_spot_blur').params['amount']!..staticValue = [0], blur);
      n++;
    }
    final tint = c['tint'];
    if (tint is Map) {
      final t = Map<String, dynamic>.from(tint);
      final col = _rgb(t['color'], const [208, 16, 26], 'tint.color');
      final amt = (_num(t, 'amount') ?? 70).clamp(0.0, 100.0).toDouble();
      for (final k in keep) {
        envelope(_fx(k, 'tint', '${k.id}_spot_tint', {'color': col}).params['amount']!, amt);
      }
    }
    r.log.add('Spotlight on ${keep.map((k) => k.id).join(', ')}: $n other layer(s) mono ${mono.round()}% / dim ${dim.round()}% '
        'from ${(start - offset).toStringAsFixed(2)} s for ${dur.toStringAsFixed(2)} s${shot is String ? ' (in shot "$shot")' : ''}');
  }

  // --------------------------------------------------------------- pulse

  /// 51. Generic oscillator: a layer property or effect param swings between
  /// [from] and [to] every [period] (sine-eased), on the layer and `sync` layers.
  static void pulse(Composition comp, Map<String, dynamic> c, double now, CommandResult r, void Function(Map<String, dynamic>) exec) {
    final main = _layer(comp, c['layer'], 'layer');
    final targets = [main, for (final id in _ids(c['sync'])) _layer(comp, id, 'sync')];
    final period = (_num(c, 'period') ?? 1.0).clamp(0.05, 60.0).toDouble();
    final start = _num(c, 'start') ?? _num(c, 'at') ?? now;
    final dur = (_num(c, 'duration') ?? 3.0).clamp(period / 2, 600.0).toDouble();
    final prop = c['prop'] is String ? '${c['prop']}' : null;
    final effect = c['effect'] is String ? '${c['effect']}' : (prop == null ? 'tint' : null);
    final half = period / 2;
    final steps = math.max(1, (dur / half).floor());
    var touched = 0;
    for (final l in targets) {
      AnimProp ap;
      List<double> Function(double v) value;
      if (effect != null) {
        Effect? e = l.effectById(effect);
        if (e == null) {
          for (final x in l.effects) {
            if (x.type == effect) e = x;
          }
        }
        if (e == null) {
          if (EffectsCatalog.byType(effect) == null) throw CommandError('pulse: unknown effect "$effect"');
          e = _fx(l, effect, '${l.id}_pulse_$effect', effect == 'tint' ? {'color': _rgb(c['color'], const [208, 16, 26], 'color')} : const {});
        }
        final key = c['param'] is String ? '${c['param']}' : (e.params.containsKey('amount') ? 'amount' : e.params.keys.first);
        final found = e.params[key];
        if (found == null) throw CommandError('pulse: effect "${e.type}" has no param "$key" (params: ${e.params.keys.join(', ')})');
        ap = found;
        value = (v) => List.filled(found.dims, v);
      } else {
        final pr = l.props[prop!];
        if (pr == null) throw CommandError('pulse: layer "${l.id}" has no property "$prop"');
        ap = pr;
        final rest = pr.valueAt(start);
        if (prop == Props.scale) {
          value = (v) => [v, v, rest.length > 2 ? rest[2] : 100];
        } else {
          value = (v) => List.filled(pr.dims, v);
        }
      }
      final defFrom = effect == 'tint' ? 0.0 : (effect == null && prop == Props.opacity ? 100.0 : 0.0);
      final defTo = effect == 'tint' ? 70.0 : (effect == null && prop == Props.opacity ? 25.0 : 100.0);
      final from = _num(c, 'from') ?? defFrom, to = _num(c, 'to') ?? defTo;
      ap.keyframes.removeWhere((k) => k.time >= start - kTimeEpsilon && k.time <= start + steps * half + kTimeEpsilon);
      for (int i = 0; i <= steps; i++) {
        ap.setKeyframe(start + i * half, value(i.isEven ? from : to), easing: _sine);
      }
      if (steps.isOdd) ap.setKeyframe(start + (steps + 1) * half, value(from), easing: _sine); // end at rest
      touched++;
    }
    final kind = c['sfx'];
    if (kind is String && kind != 'none') {
      if (!Sfx.all.contains(kind)) throw CommandError('pulse sfx "$kind" is not a sound');
      final every = math.max(period, kind == 'heartbeat' ? Sfx.length(kind) : period);
      for (var t = start; t < start + dur - 0.05; t += every) {
        exec({'op': 'add_sfx', 'kind': kind, 'time': t});
      }
    }
    r.log.add('Pulse on $touched layer(s) every ${period.toStringAsFixed(2)} s for ${dur.toStringAsFixed(2)} s');
  }

  // -------------------------------------------------------- cut_to_black

  /// 41. Hard cut to black (+ silence), then hard cut out.
  static void cutToBlack(Composition comp, Map<String, dynamic> c, double now, CommandResult r, void Function(Map<String, dynamic>) exec) {
    final at = _num(c, 'at') ?? now;
    final hold = (_num(c, 'hold') ?? 1.5).clamp(comp.frameDuration, 60.0).toDouble();
    final id = c['id'] is String ? '${c['id']}' : _uniqueId(comp, 'black');
    if (comp.layerById(id) != null) throw CommandError('A layer "$id" already exists');
    final l = Layer(id: id, name: 'Cut to black', type: LayerType.solid, start: at, duration: hold, width: comp.width, height: comp.height, color: 0xFF000000);
    l.prop(Props.position).staticValue = [comp.width / 2, comp.height / 2, 0];
    comp.layers.insert(0, l);
    r.createdIds.add(id);
    var ducked = 0;
    if (c['silence'] != false) ducked = v3DuckAudio(comp, at, at + hold, comp.frameDuration);
    _sfx(c, 'sfx', 'impact', at, exec, r);
    if (comp.duration < at + hold) comp.duration = at + hold;
    r.log.add('Cut to black at ${at.toStringAsFixed(2)} s for ${hold.toStringAsFixed(2)} s${ducked > 0 ? ' ($ducked track(s) silent)' : ''}');
  }

  // ----------------------------------------------------------- lightning

  /// 41. Lightning strikes: sky flash + bolt at each time, thunder.
  static void lightning(Composition comp, Map<String, dynamic> c, double now, CommandResult r, void Function(Map<String, dynamic>) exec) {
    final ats = c['at'] is List
        ? [for (final v in c['at'] as List) if (v is num) v.toDouble()]
        : [_num(c, 'at') ?? now];
    if (ats.isEmpty) throw CommandError('lightning "at" must be a time or a list of times');
    ats.sort();
    final fr = comp.frameDuration;
    final xv = _num(c, 'x') ?? 0.62;
    final x = (xv > 1 ? xv / comp.width : xv).clamp(0.0, 1.0) * 100;
    final col = _rgb(c['color'], const [221, 230, 255], 'color');
    final bolt = c['bolt'] != false;
    final id = c['id'] is String ? '${c['id']}' : _uniqueId(comp, 'lightning');
    if (comp.layerById(id) != null) throw CommandError('A layer "$id" already exists');
    final start = math.max(0.0, ats.first - 0.1), end = ats.last + 0.5;
    final l = Layer(id: id, name: 'Lightning', type: LayerType.solid, start: start, duration: end - start, width: comp.width, height: comp.height, color: 0x00000000);
    l.prop(Props.position).staticValue = [comp.width / 2, comp.height / 2, 0];
    comp.layers.insert(0, l);
    final e = _fx(l, 'lightning', '${id}_fx', {'x': [x], 'color': col});
    final flash = e.params['flash']!, b = e.params['bolt']!, variant = e.params['variant']!;
    for (int i = 0; i < ats.length; i++) {
      final t = ats[i];
      flash.setKeyframe(t - fr, [0], easing: Easing.easeIn);
      flash.setKeyframe(t, [100], easing: _expoOut);
      flash.setKeyframe(t + 0.16, [0], easing: _expoOut);
      variant.setKeyframe(t - fr, [i.toDouble()], easing: Easing.hold);
      if (bolt) {
        b.setKeyframe(t - fr, [0], easing: Easing.hold);
        b.setKeyframe(t, [100], easing: Easing.hold);
        b.setKeyframe(t + 0.06, [70], easing: _out);
        b.setKeyframe(t + 0.12, [0], easing: _out);
      }
    }
    r.createdIds.add(id);
    _sfx(c, 'sfx', 'thunder', ats.first, exec, r);
    r.log.add('Lightning "$id": ${ats.length} strike(s) at ${ats.map((t) => t.toStringAsFixed(2)).join(', ')} s');
  }

  // -------------------------------------------------------------- montage

  /// 52. Smash recap: one picture every [every] s, each with a look and a
  /// fast push, a flash frame on every cut.
  static void montage(Project p, Composition comp, Map<String, dynamic> c, double now, CommandResult r, void Function(Map<String, dynamic>) exec) {
    final ids = _ids(c['media']);
    if (ids.isEmpty) throw CommandError('montage needs "media": [photo/video ids]');
    final media = [
      for (final m in ids)
        p.media[m] ?? (throw CommandError('montage: no media "$m". Media: ${p.media.keys.join(', ')}')),
    ];
    for (final m in media) {
      if (m.type == MediaType.audio) throw CommandError('montage: "${m.id}" is audio');
    }
    final start = _num(c, 'start') ?? now;
    final every = (_num(c, 'every') ?? 0.35).clamp(comp.frameDuration * 2, 10.0).toDouble();
    final looks = c['looks'] is List ? _ids(c['looks']) : montageLooks;
    for (final lk in looks) {
      if (!montageLooks.contains(lk) && lk != 'none') throw CommandError('montage look "$lk": use ${montageLooks.join(', ')} or none');
    }
    final zoom = (_num(c, 'zoom') ?? 8).clamp(0.0, 100.0).toDouble();
    var base = c['id'] is String ? '${c['id']}' : 'montage';
    if (c['id'] is! String) {
      for (int k = 2; comp.layerById('${base}_0') != null; k++) {
        base = 'montage_$k';
      }
    }
    final fr = comp.frameDuration;
    for (int i = 0; i < media.length; i++) {
      final m = media[i];
      final id = '${base}_$i';
      if (comp.layerById(id) != null) throw CommandError('A layer "$id" already exists');
      final t = start + i * every;
      exec({
        'op': 'add_layer', 'type': m.type == MediaType.video ? 'video' : 'image', 'media': m.id, 'id': id, 'name': 'Montage ${i + 1}',
        'start': t, 'duration': every, 'fit': 'cover', 'position': [comp.width / 2, comp.height / 2, 0],
      });
      final l = comp.requireLayer(id);
      final look = looks.isEmpty ? 'none' : looks[i % looks.length];
      final sc = l.prop(Props.scale).staticValue;
      var k0 = 1.0;
      switch (look) {
        case 'threshold':
          _fx(l, 'threshold', '${id}_thr', {'level': [48], 'softness': [12]});
          _fx(l, 'grain', '${id}_grain', {'amount': [35]});
        case 'duotone_green':
          _fx(l, 'duotone', '${id}_duo', {'dark': [3, 20, 10], 'light': [76, 255, 122], 'amount': [100]});
          _fx(l, 'color', '${id}_c', {'contrast': [25]});
        case 'red_paint':
          _fx(l, 'mono', '${id}_mono', {'amount': [100]});
          _fx(l, 'color', '${id}_c', {'contrast': [30]});
          _fx(l, 'red_paint', '${id}_paint', {'amount': [80]});
        case 'magenta':
          _fx(l, 'duotone', '${id}_duo', {'dark': [26, 4, 32], 'light': [255, 61, 184], 'amount': [100]});
        case 'grunge':
          _fx(l, 'mono', '${id}_mono', {'amount': [100]});
          _fx(l, 'color', '${id}_c', {'contrast': [35]});
          _fx(l, 'grunge', '${id}_grunge', {'amount': [70]});
        case 'crop':
          k0 = 1.6;
          final ox = (((i * 7919) % 100) / 100 - 0.5) * comp.width * 0.25, oy = (((i * 104729) % 100) / 100 - 0.5) * comp.height * 0.25;
          l.prop(Props.position).staticValue = [comp.width / 2 + ox, comp.height / 2 + oy, 0];
      }
      final k1 = k0 * (1 + zoom / 100);
      l.prop(Props.scale)
        ..setKeyframe(t, [sc[0] * k0, sc[1] * k0, sc[2]], easing: const Easing.bezierCurve(0.2, 0.6, 0.4, 1))
        ..setKeyframe(t + every, [sc[0] * k1, sc[1] * k1, sc[2]]);
      _fx(l, 'flash', '${id}_flash').params['amount']!
        ..setKeyframe(t, [70], easing: _expoOut)
        ..setKeyframe(t + math.min(every * 0.5, fr * 3), [0]);
      _fx(l, 'vignette', '${id}_vig', {'amount': [55], 'size': [60]});
      r.createdIds.add(id);
    }
    final end = start + media.length * every;
    if (comp.duration < end) comp.duration = end;
    if (c['sound'] != false) {
      exec({'op': 'add_sfx', 'kind': 'hit', 'time': start});
      for (int i = 2; i < media.length; i += 2) {
        exec({'op': 'add_sfx', 'kind': 'swoosh_short', 'time': start + i * every});
      }
    }
    r.log.add('Montage "$base": ${media.length} pictures every ${every.toStringAsFixed(2)} s (${start.toStringAsFixed(2)}–${end.toStringAsFixed(2)} s)');
  }

  // ----------------------------------------------------------- swap_layer

  /// 43. Swaps a layer for another layer / photo in place at [at].
  static void swapLayer(Project p, Composition comp, Map<String, dynamic> c, double now, CommandResult r, void Function(Map<String, dynamic>) exec) {
    final old = _layer(comp, c['layer'], 'layer');
    final at = _num(c, 'at') ?? now;
    if (at <= old.start + comp.frameDuration * 0.5 || at >= old.end - comp.frameDuration * 0.5) {
      throw CommandError('swap_layer "at" ${at.toStringAsFixed(2)} s must be inside "${old.id}" (${old.start.toStringAsFixed(2)}–${old.end.toStringAsFixed(2)} s)');
    }
    final w = c['with'];
    if (w is! String) throw CommandError('swap_layer needs "with": a layer id or a media id');
    final tr = _choice(c, 'transition', 'pop', const ['pop', 'cut', 'fade', 'flash']);
    final d = (_num(c, 'duration') ?? (tr == 'fade' ? 0.3 : 0.2)).clamp(comp.frameDuration * 2, 5.0).toDouble();
    final end = old.end;
    Layer neo;
    final existing = comp.layerById(w);
    if (existing != null) {
      if (existing.id == old.id) throw CommandError('swap_layer: "with" must be another layer');
      neo = existing;
      if (neo.start < at) {
        final e = neo.end;
        neo.sourceIn += (at - neo.start) * neo.speed;
        neo.start = at;
        neo.duration = math.max(comp.frameDuration, e - at);
      } else if (neo.start > at) {
        neo.moveTo(at);
      }
    } else {
      final m = p.media[w];
      if (m == null) throw CommandError('swap_layer: "$w" is neither a layer nor a media id');
      if (m.type == MediaType.audio) throw CommandError('swap_layer: "$w" is audio');
      final id = c['id'] is String ? '${c['id']}' : _uniqueId(comp, '${old.id}_swap');
      neo = old.copy(newId: id)..name = '${m.name} (swap)';
      neo.type = m.type == MediaType.video ? LayerType.video : LayerType.image;
      neo.mediaId = m.id;
      neo.text = null;
      neo.shape = null;
      // Same on-screen height as the old layer.
      final k = old.height / math.max(1.0, m.height);
      neo.width = m.width;
      neo.height = m.height;
      neo.prop(Props.anchor).staticValue = [neo.width / 2, neo.height / 2, 0];
      neo.prop(Props.anchor).keyframes.clear();
      final sp = neo.prop(Props.scale);
      sp.staticValue = [sp.staticValue[0] * k, sp.staticValue[1] * k, sp.staticValue[2]];
      for (final kf in sp.keyframes) {
        kf.value = [kf.value[0] * k, kf.value[1] * k, kf.value[2]];
      }
      neo.sourceIn = 0;
      neo.start = at;
      neo.duration = end - at;
      comp.layers.insert(comp.indexOf(old.id), neo);
      r.createdIds.add(id);
    }
    switch (tr) {
      case 'pop':
        final sp = neo.prop(Props.scale);
        final rest = sp.valueAt(at + d);
        sp.keyframes.removeWhere((k) => k.time >= at - kTimeEpsilon && k.time <= at + d + kTimeEpsilon);
        sp.setKeyframe(at, [0, 0, rest[2]], easing: _out);
        sp.setKeyframe(at + d * 0.6, [rest[0] * 1.1, rest[1] * 1.1, rest[2]], easing: _soft);
        sp.setKeyframe(at + d, rest, easing: _soft);
        old.duration = at - old.start;
      case 'fade':
        final op = neo.prop(Props.opacity);
        final rest = op.valueAt(at + d)[0];
        op.setKeyframe(at, [0], easing: _soft);
        op.setKeyframe(at + d, [rest], easing: _soft);
        old.duration = math.min(end, at + d) - old.start;
      case 'flash':
        _fx(neo, 'flash', '${neo.id}_swap_flash').params['amount']!
          ..setKeyframe(at, [100], easing: _expoOut)
          ..setKeyframe(at + d, [0]);
        old.duration = at - old.start;
      default:
        old.duration = at - old.start;
    }
    final defSfx = tr == 'pop' ? 'pop' : (tr == 'flash' ? 'hit' : null);
    if (c['sfx'] is String || (defSfx != null && c['sfx'] != false)) _sfx(c, 'sfx', defSfx ?? 'pop', at, exec, r);
    r.log.add('Swapped "${old.id}" → "${neo.id}" at ${at.toStringAsFixed(2)} s ($tr)');
  }

  // ------------------------------------------------------ set_dof keys

  /// `set_dof {keys: [{t, focus: px | layer id}], aperture?}` — keyframed
  /// rack focus (eased). Layer focus = the layer's distance at that time.
  static String dofKeys(Composition comp, Map<String, dynamic> c) {
    final list = c['keys'];
    if (list is! List || list.isEmpty) throw CommandError('set_dof "keys" must be [{t, focus}, ...]');
    final rig = comp.camera;
    final fp = rig.prop(CamProps.focus);
    final parsed = <(double, double)>[];
    for (final k in list) {
      if (k is! Map) throw CommandError('set_dof keys: each key is {t, focus}');
      final t = k['t'] ?? k['time'];
      if (t is! num) throw CommandError('set_dof keys: "t" must be a number');
      final f = k['focus'];
      double dist;
      if (f is num) {
        dist = f.toDouble();
      } else if (f is String) {
        final l = _layer(comp, f, 'focus');
        if (!l.is3D) throw CommandError('set_dof focus layer "${l.id}" is not 3D (run make_3d first)');
        final cam = Evaluator.camera3D(comp, t.toDouble());
        final wm = Evaluator.worldMatrix(comp, l, t.toDouble());
        dist = math.max(1.0, cam.depthOf(wm.transform3(Vector3(l.width / 2, l.height / 2, 0))));
      } else {
        throw CommandError('set_dof keys: "focus" must be px or a layer id');
      }
      parsed.add((t.toDouble(), dist));
    }
    parsed.sort((x, y) => x.$1.compareTo(y.$1));
    comp.dofFocus = null;
    fp.keyframes.removeWhere((k) => k.time >= parsed.first.$1 - kTimeEpsilon && k.time <= parsed.last.$1 + kTimeEpsilon);
    for (final (t, d) in parsed) {
      fp.setKeyframe(t, [d], easing: Easing.easyEase);
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
    final note = rig.mode != CameraMode.threeD ? ' (needs the 3D camera: run make_3d / camera_shot)' : '';
    return 'Rack focus: ${parsed.length} focus keys ${parsed.first.$1.toStringAsFixed(2)}–${parsed.last.$1.toStringAsFixed(2)} s$note';
  }
}
