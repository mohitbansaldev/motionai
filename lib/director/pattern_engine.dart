// V3-E: the "when to use" engine. suggest() turns narration lines into a
// pattern plan that follows the documentary grammar (shot rhythm, presenter
// returns, reveal timing, evidence → reenactment, grades, transitions, SFX);
// PatternRuntime runs a plan's builders with capability fallback.

import 'dart:convert';
import 'dart:math' as math;

import '../core/commands/edit_commands.dart';
import '../core/model/effects_catalog.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../core/presets/camera_presets.dart';
import '../core/presets/components.dart';
import '../core/presets/doc_transitions.dart';
import '../core/presets/motion_presets.dart';
import '../fonts/font_catalog.dart';
import '../fonts/text_styles.dart';
import 'cue_classifier.dart';
import 'patterns.dart';
import 'sfx.dart';

/// What this build can run: ops, components, transitions, effects, text
/// animators/styles, sounds, camera and animate presets. Defaults read the
/// live registries, so a pattern uses a V3 component as soon as its branch
/// is merged and falls back before that. Tests pass their own sets.
class PatternCaps {
  final Set<String> ops, components, transitions, effects, animators, textStyles, sfx, cameraPresets, motionPresets;

  PatternCaps({
    Iterable<String>? ops,
    Iterable<String>? components,
    Iterable<String>? transitions,
    Iterable<String>? effects,
    Iterable<String>? animators,
    Iterable<String>? textStyles,
    Iterable<String>? sfx,
    Iterable<String>? cameraPresets,
    Iterable<String>? motionPresets,
  })  : ops = {...(ops ?? EditCommands.ops)},
        components = {...(components ?? Components.types)},
        transitions = {...(transitions ?? DocTransitions.types)},
        effects = {...(effects ?? [for (final e in EffectsCatalog.all) e.type])},
        animators = {...(animators ?? TextAnimators.all)},
        textStyles = {...(textStyles ?? TextStylePresets.ids)},
        sfx = {...(sfx ?? Sfx.all)},
        cameraPresets = {...(cameraPresets ?? [...CameraPresets.threeD, ...CameraPresets.twoD])},
        motionPresets = {...(motionPresets ?? MotionPresets.transitions)};

  /// The concrete command for [c] on this build, or null when something it
  /// needs is missing. "@call" becomes the op or add_component; "@transition"
  /// becomes the transition op (or an op of that name).
  Map<String, dynamic>? resolve(Map<String, dynamic> c) {
    final op = '${c['op']}';
    switch (op) {
      case '@call':
        final name = '${c['name']}';
        final rest = Map<String, dynamic>.from(c)
          ..remove('op')
          ..remove('name');
        if (ops.contains(name)) return {'op': name, ...rest};
        if (components.contains(name) && ops.contains('add_component')) return {'op': 'add_component', 'type': name, ...rest};
        return null;
      case '@transition':
        final type = '${c['type']}';
        final rest = Map<String, dynamic>.from(c)..remove('op');
        if (transitions.contains(type) && ops.contains('transition')) return {'op': 'transition', ...rest};
        if (ops.contains(type)) {
          final ls = rest.remove('layers');
          rest.remove('type');
          return {'op': type, if (ls is List && ls.length >= 2) 'from': ls[0], if (ls is List && ls.length >= 2) 'to': ls[1], ...rest};
        }
        return null;
      case '@scale_keys':
        return c;
      case 'add_component':
        return components.contains('${c['type']}') && ops.contains(op) ? c : null;
      case 'transition':
        return transitions.contains('${c['type']}') && ops.contains(op) ? c : null;
      case 'add_effect':
        return effects.contains('${c['effect']}') ? c : null;
      case 'animate_in':
      case 'animate_out':
        return motionPresets.contains('${c['preset']}') ? c : null;
      case 'add_sfx':
        return sfx.contains('${c['kind']}') && ops.contains(op) ? c : null;
      case 'camera_move':
        return cameraPresets.contains('${c['preset']}') ? c : null;
    }
    if (!ops.contains(op)) return null;
    if (op == 'add_layer' || op == 'update_layer') {
      if (c['animator'] != null && !animators.contains('${c['animator']}')) return null;
      if (c['text_style'] != null && !textStyles.contains('${c['text_style']}')) return null;
      if (c['font'] != null && FontCatalog.lookup('${c['font']}') == null) return null;
    }
    return c;
  }

  /// Every command of an alternative resolved, or null.
  List<Map<String, dynamic>>? resolveAll(List<Map<String, dynamic>> alt) {
    final out = <Map<String, dynamic>>[];
    for (final c in alt) {
      final r = resolve(c);
      if (r == null) return null;
      out.add(r);
    }
    return out;
  }

  /// Short name of what an alternative is built on.
  static String label(List<Map<String, dynamic>> alt) {
    for (final c in alt) {
      switch ('${c['op']}') {
        case '@call':
          return '${c['name']}';
        case '@transition':
        case 'transition':
          return 'transition:${c['type']}';
        case 'add_component':
          return 'component:${c['type']}';
        case 'animate_in':
          return 'animate_in:${c['preset']}';
        case 'camera_move':
          return 'camera_move:${c['preset']}';
        case 'add_shot':
        case 'mood_flood':
        case 'grade_swap':
        case 'cut_to_black':
        case 'lightning':
        case 'spotlight_subject':
        case 'pulse':
        case 'swap_layer':
        case 'set_dof':
          return '${c['op']}';
      }
    }
    for (final c in alt) {
      if (c['op'] == 'add_layer' && c['text_style'] != null) return 'text_style:${c['text_style']}';
      if (c['op'] == 'add_layer' && c['animator'] != null && c['type'] == 'text' && alt.length == 1) return 'text:${c['animator']}';
    }
    return 'layers';
  }
}

/// Runs pattern builders: per step the first alternative that exists on
/// this build and runs without error (a failed one is rolled back).
class PatternRuntime {
  /// Synth SFX kind for a spec sound name.
  static String? sfxKind(String name, Set<String> have) {
    const map = {
      'radio_crackle': ['radio_crackle', 'glitch'],
      'ice_crash': ['ice_crash', 'impact', 'hit'],
      'thunder': ['thunder', 'impact'],
      'marker_squeak': ['marker_squeak', 'paper'],
      'page_flip': ['page_flip', 'paper'],
      'clock_tick': ['clock_tick', 'tick'],
      'silence': ['whoosh_silence'],
    };
    for (final k in map[name] ?? [name]) {
      if (have.contains(k)) return k;
    }
    return null;
  }

  /// The alternative each step of [p] would use now (name check only).
  static List<Map<String, dynamic>> preview(DocPattern p, PatternCtx ctx, {PatternCaps? caps}) {
    final cap = caps ?? PatternCaps();
    final out = <Map<String, dynamic>>[];
    for (final s in p.build(ctx)) {
      var used = '';
      var index = -1;
      for (int i = 0; i < s.alts.length; i++) {
        if (cap.resolveAll(s.alts[i]) != null) {
          used = PatternCaps.label(s.alts[i]);
          index = i;
          break;
        }
      }
      out.add({'step': s.label, 'uses': used.isEmpty ? 'none' : used, 'fallback': index > 0, 'primary': s.alts.isEmpty ? '' : PatternCaps.label(s.alts.first)});
    }
    return out;
  }

  /// Runs the steps; returns the label used per step ("skipped" when none).
  static List<String> runSteps(Project p, List<PStep> steps, CommandResult r, void Function(Map<String, dynamic>) exec,
      {PatternCaps? caps, String where = ''}) {
    final cap = caps ?? PatternCaps();
    final used = <String>[];
    for (final s in steps) {
      String? done;
      String? lastError;
      for (final alt in s.alts) {
        final cmds = cap.resolveAll(alt);
        if (cmds == null) continue;
        final snap = ProjectSnapshot.take(p);
        final nCreated = r.createdIds.length, nLog = r.log.length;
        try {
          for (final c in cmds) {
            if (c['op'] == '@scale_keys') {
              for (final k in _scaleKeys(p, c)) {
                exec(k);
              }
            } else {
              exec(c);
            }
          }
          done = PatternCaps.label(alt);
          break;
        } catch (e) {
          // CommandError, or a component rejecting a field it reads with another type
          ProjectSnapshot.restore(p, snap);
          r.createdIds.removeRange(nCreated, r.createdIds.length);
          r.log.removeRange(nLog, r.log.length);
          lastError = e is CommandError ? e.message : '$e';
        }
      }
      if (done == null) {
        used.add('skipped');
        if (!s.optional) r.log.add('$where${s.label}: no alternative worked${lastError == null ? '' : ' ($lastError)'}');
      } else {
        used.add(done);
      }
    }
    return used;
  }

  static List<Map<String, dynamic>> _scaleKeys(Project p, Map<String, dynamic> c) {
    final l = p.editComp.layerById('${c['layer']}');
    if (l == null) return const [];
    final t0 = (c['start'] as num).toDouble(), t1 = (c['end'] as num).toDouble();
    final v = l.prop(Props.scale).valueAt(t0);
    final a = (c['from'] as num).toDouble(), b = (c['to'] as num).toDouble();
    return [
      {'op': 'set_keyframe', 'target': l.id, 'prop': 'scale', 'time': t0, 'value': [v[0] * a, v[1] * a, v[2]], 'ease': c['ease'] ?? 'easy_ease'},
      {'op': 'set_keyframe', 'target': l.id, 'prop': 'scale', 'time': t1, 'value': [v[0] * b, v[1] * b, v[2]], 'ease': 'linear'},
    ];
  }

  // ------------------------------------------------------------ apply_patterns

  static const _tones = {
    'snow': ['#16242C', '#05090C'],
    'desert': ['#3A2A18', '#0E0904'],
    'neutral': ['#1C1F26', '#07080B'],
  };

  /// apply_patterns {plan, assets?, tone?, sfx?, prefix?}: builds every beat
  /// of a plan (from suggest_patterns or hand-written) on the timeline.
  static void apply(Project p, Map<String, dynamic> c, CommandResult r, void Function(Map<String, dynamic>) exec, {PatternCaps? caps}) {
    final cap = caps ?? PatternCaps();
    final planRaw = c['plan'];
    final List beats;
    Map<String, dynamic> plan = const {};
    if (planRaw is Map) {
      plan = Map<String, dynamic>.from(planRaw);
      beats = plan['beats'] is List ? plan['beats'] as List : const [];
    } else if (planRaw is List) {
      beats = planRaw;
    } else if (planRaw is String) {
      final d = jsonDecode(planRaw);
      plan = d is Map ? Map<String, dynamic>.from(d) : const {};
      beats = d is List ? d : (plan['beats'] as List? ?? const []);
    } else {
      throw CommandError('apply_patterns needs "plan": the object suggest_patterns returned (or {"beats":[{"pattern","start","end","slots"}]})');
    }
    if (beats.isEmpty) throw CommandError('apply_patterns: the plan has no beats');
    final assets = c['assets'] is Map ? Map<String, dynamic>.from(c['assets'] as Map) : <String, dynamic>{};
    final tone = '${c['tone'] ?? plan['tone'] ?? 'neutral'}';
    final prefix = c['prefix'] is String ? '${c['prefix']}' : Ids.next('pt');
    final sfxOn = c['sfx'] != false;
    final broll = [
      for (final id in (assets['broll'] is List ? assets['broll'] as List : const []))
        if (p.media['$id'] != null && p.media['$id']!.type != MediaType.audio) p.media['$id']!,
    ];
    var brollIdx = 0;
    final beatAssets = assets['beats'] is Map ? Map<String, dynamic>.from(assets['beats'] as Map) : const <String, dynamic>{};
    String? prevPlate;
    var t = 0.0;
    final summary = <Map<String, dynamic>>[];
    for (int i = 0; i < beats.length; i++) {
      final b = beats[i];
      if (b is! Map) continue;
      final beat = Map<String, dynamic>.from(b);
      final id = '${beat['pattern'] ?? ''}';
      final asked = PatternLibrary.byId(id);
      if (asked == null) throw CommandError('beats[$i]: unknown pattern "$id". Patterns: ${PatternLibrary.ids.join(', ')}');
      // A transition pattern as a beat = a plain shot entered with that transition.
      final pat = asked.isTransition ? PatternLibrary.byId('human_detail_insert')! : asked;
      if (asked.isTransition) beat['transition_in'] = asked.id;
      final start = beat['start'] is num ? (beat['start'] as num).toDouble() : t;
      var end = beat['end'] is num ? (beat['end'] as num).toDouble() : start + pat.hold;
      if (end <= start + 0.2) end = start + math.max(0.5, pat.hold);
      t = end;
      final slots = <String, dynamic>{
        if (beat['slots'] is Map) ...Map<String, dynamic>.from(beat['slots'] as Map),
        if (beatAssets['$i'] is Map) ...Map<String, dynamic>.from(beatAssets['$i'] as Map),
      };
      final pfx = '$prefix$i';
      final used = <String>[];

      // ---- plate
      String? plate;
      if (beat['plate'] != false) {
        plate = '${pfx}_plate';
        final presenter = pat.role == 'presenter' || beat['role'] == 'presenter';
        MediaAsset? m;
        if (presenter) {
          m = _media(p, slots['media']) ?? _media(p, assets['presenter']);
        } else if (!pat.fullscreen) {
          m = _media(p, slots['plate']) ?? _media(p, slots['media']);
          if (m == null && broll.isNotEmpty && pat.category != 'shot') m = broll[brollIdx++ % broll.length];
          if (m == null && broll.isNotEmpty && pat.category == 'shot' && slots['cutouts'] == null) m = broll[brollIdx++ % broll.length];
        }
        final ctx0 = PatternCtx(p, start: start, end: end, pfx: pfx, tone: tone);
        if (m != null) {
          final sc = math.max(ctx0.w / math.max(1, m.width), ctx0.h / math.max(1, m.height)) * 100;
          final srcIn = presenter && m.type == MediaType.video && m.duration >= end ? start : 0.0;
          exec({
            'op': 'add_layer', 'type': m.type == MediaType.video ? 'video' : 'image', 'media': m.id, 'id': plate, 'name': presenter ? 'Presenter' : m.name,
            'start': start, 'duration': end - start, 'fit': 'none', 'scale': [sc, sc, 100], if (srcIn > 0) 'source_in': srcIn,
          });
          final grade = '${beat['grade'] ?? (presenter ? 'warm' : (tone == 'snow' ? 'cold' : 'none'))}';
          used.addAll(runSteps(p, [_gradeStep(ctx0, plate, grade)], r, exec, caps: cap));
          if (!presenter && pat.category != 'shot') {
            used.addAll(runSteps(p, [PStep('push', [[{'op': '@scale_keys', 'layer': plate, 'from': 1.0, 'to': 1.06, 'start': start, 'end': end, 'ease': 'easy_ease'}]], optional: true)], r, exec, caps: cap));
          }
        } else {
          final cols = presenter ? const ['#3A2A1E', '#120C08'] : (_tones[tone] ?? _tones['neutral']!);
          exec({
            'op': 'add_layer', 'type': 'shape', 'kind': 'rect', 'id': plate, 'name': presenter ? 'Presenter (placeholder)' : 'Backdrop', 'width': ctx0.w, 'height': ctx0.h,
            'position': [ctx0.w / 2, ctx0.h / 2, 0], 'fill': cols[0], 'fill2': cols[1], 'start': start, 'duration': end - start,
          });
        }
        if (beat['particles'] is String && cap.effects.contains('particles')) {
          used.addAll(runSteps(p, [
            PStep('particles', [
              [
                {'op': 'add_layer', 'type': 'solid', 'id': '${pfx}_atmos', 'name': 'Atmosphere', 'color': '#00000000', 'start': start, 'duration': end - start},
                {'op': 'add_effect', 'layer': '${pfx}_atmos', 'effect': 'particles', 'id': '${pfx}_atmos_fx', 'params': {'kind': '${beat['particles']}', 'amount': 40, 'speed': 1.0}},
              ],
            ], optional: true),
          ], r, exec, caps: cap));
        }
      }

      // ---- transition in (between the previous plate and this one)
      final tin = '${beat['transition_in'] ?? 'cut'}';
      if (tin != 'cut' && tin != 'none' && plate != null && prevPlate != null) {
        final tctx = PatternCtx(p, start: start, end: end, slots: slots, pfx: '${pfx}t', plate: plate, prevPlate: prevPlate, tone: tone);
        final tp = PatternLibrary.byId(tin);
        final steps = tp != null && (tp.isTransition || tp.id == 'sun_glare_entry')
            ? tp.build(tctx)
            : tctx.transition(tin, const {}, const [('flash_cut', {})]);
        used.addAll(runSteps(p, steps, r, exec, caps: cap, where: 'beats[$i] transition $tin: '));
      }

      // ---- the pattern itself
      final reveal = beat['reveal_at'] is num ? (beat['reveal_at'] as num).toDouble() : null;
      final ctx = PatternCtx(p, start: start, end: end, slots: slots, pfx: pfx, plate: plate, tone: tone, reveal: reveal);
      used.addAll(runSteps(p, pat.build(ctx), r, exec, caps: cap, where: 'beats[$i] $id: '));

      // ---- overlays
      final ovs = beat['overlays'] is List ? beat['overlays'] as List : const [];
      for (int k = 0; k < ovs.length; k++) {
        final o = ovs[k];
        if (o is! Map) continue;
        final op = PatternLibrary.byId('${o['pattern']}');
        if (op == null) continue;
        final os = o['at'] is num ? (o['at'] as num).toDouble().clamp(start, end - 0.3).toDouble() : start;
        final oe = o['end'] is num ? (o['end'] as num).toDouble().clamp(os + 0.3, end).toDouble() : math.min(end, os + op.hold);
        final octx = PatternCtx(p, start: os, end: math.max(os + 0.3, oe), slots: o['slots'] is Map ? Map<String, dynamic>.from(o['slots'] as Map) : const {},
            pfx: '${pfx}o$k', plate: plate, tone: tone, reveal: o['reveal_at'] is num ? (o['reveal_at'] as num).toDouble() : os + 0.2);
        used.addAll(runSteps(p, op.build(octx), r, exec, caps: cap, where: 'beats[$i] overlay ${op.id}: '));
        if (sfxOn) _sounds(p, op.sfx.map((s) => {'kind': s, 'at': octx.rv}).toList(), os, r, exec, cap, '${pfx}o$k');
      }

      // ---- sound
      if (sfxOn) {
        final list = beat['sfx'] is List
            ? [for (final s in beat['sfx'] as List) if (s is Map) Map<String, dynamic>.from(s)]
            : [for (final s in asked.isTransition ? const <String>[] : asked.sfx) {'kind': s, 'at': ctx.rv}];
        _sounds(p, list, start, r, exec, cap, pfx);
      }

      summary.add({'i': i, 'pattern': id, 'start': _r(start), 'end': _r(end), 'used': used.where((u) => u != 'layers').toSet().toList()});
      if (plate != null) prevPlate = plate;
    }
    r.log.add(jsonEncode({'apply_patterns': summary}));
  }

  static void _sounds(Project p, List<Map<String, dynamic>> list, double minStart, CommandResult r, void Function(Map<String, dynamic>) exec, PatternCaps cap, String pfx) {
    for (int k = 0; k < list.length; k++) {
      final kind = sfxKind('${list[k]['kind']}', cap.sfx);
      if (kind == null) continue;
      final at = list[k]['at'] is num ? (list[k]['at'] as num).toDouble() : minStart;
      final time = math.max(at, minStart + Sfx.peak(kind));
      runSteps(p, [
        PStep('sfx', [
          [{'op': 'add_sfx', 'kind': kind, 'time': time, 'id': '${pfx}_sfx$k'}],
        ], optional: true),
      ], r, exec, caps: cap);
    }
  }

  static PStep _gradeStep(PatternCtx c, String plate, String grade) {
    switch (grade) {
      case 'cold':
        return PStep('grade', [
          [
            c.fx(plate, 'tint', {'color': '#6FA8C8', 'amount': 22}, fxId: '${plate}_cold'),
            c.fx(plate, 'color', {'saturation': -30}, fxId: '${plate}_desat'),
            c.fx(plate, 'vignette', {'amount': 65}, fxId: '${plate}_vig'),
          ],
        ], optional: true);
      case 'warm':
        return PStep('grade', [
          [c.fx(plate, 'tint', {'color': '#FFB070', 'amount': 14}, fxId: '${plate}_warm')],
        ], optional: true);
      case 'archive':
        return PStep('grade', [
          [
            c.fx(plate, 'mono', {'amount': 100}, fxId: '${plate}_mono'),
            c.fx(plate, 'tint', {'color': '#C8A070', 'amount': 25}, fxId: '${plate}_sepia'),
            c.fx(plate, 'grain', {'amount': 30}, fxId: '${plate}_grain'),
          ],
        ], optional: true);
    }
    return const PStep('grade', [], optional: true);
  }

  static MediaAsset? _media(Project p, dynamic v) {
    final id = v is List ? (v.isEmpty ? null : '${v.first}') : v?.toString();
    final m = id == null ? null : p.media[id];
    return m == null || m.type == MediaType.audio ? null : m;
  }

  static double _r(double v) => double.parse(v.toStringAsFixed(2));
}

/// suggest(): narration → pattern plan.
class PatternEngine {
  static const _defaultBroll = ['reenactment_shot', 'human_detail_insert', 'push_between_subjects', 'crane_down_reveal', 'rack_focus_encounter'];
  static const _platforms = ['whatsapp', 'instagram', 'telegram', 'youtube', 'facebook', 'twitter'];

  /// Plans [lines] ({text, start?, end?}). context: style ("nr_doc"),
  /// tone / story_tone (auto | snow | desert | neutral …), presenter (true),
  /// asl (3.4), presenter_min_gap (12), presenter_max_gap (25),
  /// presenter_share ([0.25, 0.30]), cta_every (40), handle ("Mohitflix"),
  /// transition (force a default transition pattern).
  static Map<String, dynamic> suggest(List<Map<String, dynamic>> lines, {Map<String, dynamic> context = const {}, PatternCaps? caps}) {
    double opt(String k, double d) => context[k] is num ? (context[k] as num).toDouble() : d;
    final asl = opt('asl', 3.4).clamp(1.5, 8.0).toDouble();
    final minGap = opt('presenter_min_gap', 12), maxGap = opt('presenter_max_gap', 25);
    final share = context['presenter_share'] is List && (context['presenter_share'] as List).length == 2
        ? [for (final v in context['presenter_share'] as List) (v as num).toDouble()]
        : const [0.25, 0.30];
    final ctaEvery = opt('cta_every', 40);
    final presenterOn = context['presenter'] != false;
    final handle = '${context['handle'] ?? 'Mohitflix'}';

    // 1. lines with times + cues
    final ls = <(String, double, double, List<Cue>)>[];
    var t = opt('start', 0);
    for (final l in lines) {
      final text = '${l['text'] ?? ''}'.trim();
      if (text.isEmpty) continue;
      final s = l['start'] is num ? (l['start'] as num).toDouble() : t;
      final e = l['end'] is num ? math.max(s + 0.3, (l['end'] as num).toDouble()) : s + CueClassifier.estimateDuration(text);
      ls.add((text, s, e, CueClassifier.classify(text, start: s, end: e)));
      t = e;
    }
    final toneIn = '${context['story_tone'] ?? context['tone'] ?? 'auto'}';
    final tone = toneIn == 'auto' ? CueClassifier.toneOf([for (final l in ls) l.$1]) : toneIn;
    if (ls.isEmpty) return {'style': '${context['style'] ?? 'nr_doc'}', 'tone': tone, 'beats': <Map<String, dynamic>>[], 'stats': {}};
    final t0 = ls.first.$2;

    // 2. segments of ~ASL
    final segs = <_Seg>[];
    for (int li = 0; li < ls.length; li++) {
      final (text, s, e, cues) = ls[li];
      final d = e - s;
      final n = d >= asl * 1.6 ? (d / asl).round().clamp(1, 8) : 1;
      for (int k = 0; k < n; k++) {
        final a = s + d * k / n, b = s + d * (k + 1) / n;
        segs.add(_Seg(li, text, a, b, [
          for (final c in cues)
            if ((c.at ?? s) >= a - 1e-6 && ((c.at ?? s) < b - 1e-6 || k == n - 1)) c,
        ]));
      }
    }

    // 3. choose a pattern per segment
    final beats = <Map<String, dynamic>>[];
    var lastPEnd = t0;
    var pTime = 0.0;
    var lastCta = t0 - ctaEvery / 2;
    var platform = 0;
    var evidencePending = false;
    double? stintStart;
    var stintTarget = 0.0;
    var stintCta = false;
    var ctaPlaced = false;
    final recent = <String>[];
    for (int k = 0; k < segs.length; k++) {
      final sg = segs[k];
      final prev = beats.isEmpty ? null : beats.last;
      final prevId = prev == null ? '' : '${prev['pattern']}';
      final scored = _score(sg.cues, sg.text);
      final best = scored.isEmpty ? null : scored.first;
      final since = sg.start - lastPEnd;
      final elapsed = math.max(1.0, sg.start - t0);
      final pShare = pTime / elapsed;
      final afterCrash = const {'crash_to_black', 'cut_to_black', 'mood_flood'}.contains(prevId);
      final nextClimax = k + 1 < segs.length && segs[k + 1].cues.any((c) => (c.type == 'crash' || c.type == 'dread') && c.weight >= 1);
      final wantsP = sg.cues.where((c) => c.type == 'presenter' || c.type == 'question' || c.type == 'cta').fold<double>(0, (a, c) => a + c.weight);
      final strong = best != null && best.$2 >= 0.9;
      final climaxHere = sg.cues.any((c) => (c.type == 'crash' || c.type == 'dread') && c.weight >= 1);
      final inStint = prevId == 'presenter' && stintStart != null;
      bool presenter;
      if (!presenterOn || afterCrash || climaxHere) {
        presenter = false;
      } else if (inStint && sg.start - stintStart < stintTarget - 0.5) {
        presenter = true; // keep the stint going (one ~7 s stint per ~40 s carries the CTA)
      } else if (inStint && wantsP >= 1.0 && pShare < share[1] && sg.start - stintStart < 10) {
        presenter = true; // the presenter keeps talking to the viewer
      } else if (inStint) {
        presenter = false;
      } else if (since >= maxGap) {
        presenter = true;
      } else if (evidencePending) {
        presenter = false; // evidence is ALWAYS followed by its reenactment
      } else if (since >= minGap && pShare < share[1] && (wantsP >= 0.8 || !strong || nextClimax)) {
        presenter = true;
      } else if (wantsP >= 1.0 && since >= minGap * 0.5 && pShare < share[0]) {
        presenter = true;
      } else {
        presenter = false;
      }

      Map<String, dynamic> beat;
      if (presenter) {
        if (!inStint) {
          stintStart = sg.start;
          stintCta = sg.start - lastCta >= ctaEvery;
          stintTarget = stintCta ? 7.0 : math.max(2.5, math.min(5.0, sg.end - sg.start));
          ctaPlaced = false;
        }
        if (prevId == 'presenter') {
          // one beat per stint: extend it
          final pb = prev!;
          pb['end'] = _r(sg.end);
          final pl = pb['lines'] as List;
          if (!pl.contains(sg.line)) {
            pl.add(sg.line);
            pb['text'] = '${pb['text']} ${sg.text}'.trim();
          }
          beat = pb;
        } else {
          beat = {'pattern': 'presenter', 'role': 'presenter', 'start': _r(sg.start), 'end': _r(sg.end), 'lines': [sg.line], 'text': sg.text, 'grade': 'warm', 'overlays': <Map<String, dynamic>>[]};
          beats.add(beat);
        }
        final ovs = beat['overlays'] as List<Map<String, dynamic>>;
        final nums = [for (final c in sg.cues) if (c.type == 'number' || c.type == 'people_count') c];
        if (nums.isNotEmpty) {
          ovs.add({'pattern': 'presenter_stats', 'at': _r(_reveal(sg, nums.first)), 'end': _r(sg.end), 'slots': {'lines': [for (final n in nums.take(3)) _numText(n)]}});
        }
        final list = sg.cues.where((c) => c.type == 'list').toList();
        if (list.isNotEmpty && list.first.value is List) {
          ovs.add({'pattern': 'icon_sticker', 'at': _r(sg.start + 0.1), 'end': _r(sg.end), 'slots': {'items': list.first.value}});
        }
        if (stintCta && !ctaPlaced && sg.end - stintStart >= 5) {
          final at = math.min(stintStart + 2.5, sg.end - 3.0);
          ovs.add({'pattern': platform % 3 == 2 ? 'social_bug' : 'social_cta', 'at': _r(math.max(stintStart + 2.0, at)), 'slots': {'platform': _platforms[platform % _platforms.length], 'handle': handle}});
          platform++;
          ctaPlaced = true;
          lastCta = sg.start;
        }
        pTime += sg.end - sg.start;
        lastPEnd = sg.end;
      } else {
        String id;
        final overlays = <Map<String, dynamic>>[];
        if (evidencePending) {
          id = 'reenactment_shot';
          if (best != null && const {'overlay', 'mood'}.contains(PatternLibrary.byId(best.$1)!.role) && best.$2 >= 0.6) {
            overlays.add({'pattern': best.$1, 'at': _r(sg.start), 'end': _r(sg.end), 'slots': _slots(PatternLibrary.byId(best.$1)!, sg.cues, sg.text)});
          }
        } else {
          final pick = scored.firstWhere((s) => s.$1 != prevId && !(recent.take(2).contains(s.$1) && s.$2 < 1.2) && s.$2 >= 0.35, orElse: () => ('', 0.0));
          id = pick.$1.isNotEmpty ? pick.$1 : _defaultBroll.firstWhere((x) => x != prevId && !recent.take(2).contains(x), orElse: () => _defaultBroll.firstWhere((x) => x != prevId));
        }
        final pat = PatternLibrary.byId(id)!;
        evidencePending = pat.isEvidence;
        // secondary overlays: date/time stamps, source tags, pain pulse, lightning
        bool hasOv(String o) => overlays.any((x) => x['pattern'] == o);
        if (id != 'clock_stamp' && !hasOv('clock_stamp') && sg.cues.any((c) => (c.type == 'date' || c.type == 'time' || c.type == 'day_count') && c.weight >= 0.8)) {
          final cl = PatternLibrary.byId('clock_stamp')!;
          final c0 = sg.cues.firstWhere((c) => c.type == 'date' || c.type == 'time' || c.type == 'day_count');
          overlays.add({'pattern': 'clock_stamp', 'at': _r(sg.start), 'end': _r(sg.end), 'reveal_at': _r(_reveal(sg, c0)), 'slots': _slots(cl, sg.cues, sg.text)});
        }
        if (id != 'lightning' && sg.cues.any((c) => c.type == 'lightning')) {
          overlays.add({'pattern': 'lightning', 'at': _r(sg.start), 'end': _r(sg.end), 'reveal_at': _r(_reveal(sg, sg.cues.firstWhere((c) => c.type == 'lightning')))});
        }
        if (id != 'pulse' && id != 'spotlight_subject' && sg.cues.any((c) => c.type == 'pain' && c.weight >= 1) && overlays.length < 2) {
          overlays.add({'pattern': 'pulse', 'at': _r(sg.start), 'end': _r(sg.end)});
        }
        final cue = _keyCue(pat, sg.cues);
        final rv = cue == null ? sg.start + (sg.end - sg.start) * 0.65 : _reveal(sg, cue);
        final archive = pat.id == 'photo_wall' || pat.id == 'montage' || sg.cues.any((c) => c.type == 'archive' && c.weight >= 0.6) && pat.category == 'shot';
        final grade = archive ? 'archive' : (pat.fullscreen ? 'none' : (tone == 'snow' ? 'cold' : 'none'));
        beat = {
          'pattern': id, 'role': pat.role == 'presenter' ? 'presenter' : 'broll', 'start': _r(sg.start), 'end': _r(sg.end), 'lines': [sg.line], 'text': sg.text,
          'reveal_at': _r(rv), 'grade': grade, 'slots': _slots(pat, sg.cues, sg.text),
          if (pat.category == 'shot' && tone == 'snow') 'particles': 'snow',
          if (overlays.isNotEmpty) 'overlays': overlays,
          if (cue != null) 'reason': '${cue.type}: ${cue.match}',
        };
        beats.add(beat);
        stintStart = null;
      }
      recent.insert(0, '${beat['pattern']}');
      if (recent.length > 4) recent.removeLast();
    }

    // 4. transitions, sound, element rhythm
    final counts = _Counts();
    String last = '';
    for (int i = 0; i < beats.length; i++) {
      final b = beats[i];
      final prev = i == 0 ? null : beats[i - 1];
      final tr = i == 0 ? 'cut' : _transition(prev!, b, tone, context['transition'] is String ? '${context['transition']}' : null, counts, last);
      b['transition_in'] = tr;
      if (tr != 'cut') last = tr;
      final pat = PatternLibrary.byId('${b['pattern']}')!;
      final rv = b['reveal_at'] is num ? (b['reveal_at'] as num).toDouble() : (b['start'] as num).toDouble() + 0.3;
      final sfx = <Map<String, dynamic>>[for (final s in pat.sfx.take(2)) {'kind': s, 'at': _r(rv)}];
      b['sfx'] = sfx;
      b['hold'] = _r((b['end'] as num).toDouble() - (b['start'] as num).toDouble());
      _events(b, pat);
      if ((b['hold'] as double) > 6) {
        b['long_hold'] = true;
        if (tone == 'snow' && b['role'] != 'presenter') b['particles'] = 'snow';
      }
    }

    // 5. stats
    final total = (beats.last['end'] as num).toDouble() - t0;
    final pres = beats.where((b) => b['pattern'] == 'presenter').toList();
    final pDur = pres.fold<double>(0, (a, b) => a + (b['end'] as num).toDouble() - (b['start'] as num).toDouble());
    var maxGapSeen = 0.0;
    var lastEnd = t0;
    for (final b in pres) {
      maxGapSeen = math.max(maxGapSeen, (b['start'] as num).toDouble() - lastEnd);
      lastEnd = (b['end'] as num).toDouble();
    }
    if (pres.isNotEmpty) maxGapSeen = math.max(maxGapSeen, (beats.last['end'] as num).toDouble() - lastEnd);
    var repeats = 0;
    for (int i = 1; i < beats.length; i++) {
      if (beats[i]['pattern'] == beats[i - 1]['pattern']) repeats++;
    }
    var maxElementGap = 0.0;
    for (final b in beats) {
      final ev = [for (final e in b['events'] as List) (e['t'] as num).toDouble()];
      for (int i = 1; i < ev.length; i++) {
        maxElementGap = math.max(maxElementGap, ev[i] - ev[i - 1]);
      }
    }
    final caps0 = caps ?? PatternCaps();
    final resolved = <String, String>{};
    for (final id in {for (final b in beats) '${b['pattern']}', for (final b in beats) for (final o in (b['overlays'] as List? ?? const [])) '${o['pattern']}'}) {
      resolved[id] = _uses(id, caps0);
    }
    return {
      'style': '${context['style'] ?? 'nr_doc'}',
      'tone': tone,
      'beats': beats,
      'resolved': resolved,
      'stats': {
        'duration': _r(total),
        'beats': beats.length,
        'asl': _r(total / beats.length),
        'presenter_share': _r(total <= 0 ? 0 : pDur / total),
        'presenter_returns': pres.length,
        'max_presenter_gap': _r(maxGapSeen),
        'cta': beats.fold<int>(0, (a, b) => a + (b['overlays'] as List? ?? const []).where((o) => '${o['pattern']}'.startsWith('social_')).length),
        'same_pattern_repeats': repeats,
        'max_element_gap': _r(maxElementGap),
      },
    };
  }

  /// What a pattern's main step uses on this build ("unit_chart", or the fallback).
  static String _uses(String id, PatternCaps caps) {
    final p = PatternLibrary.byId(id);
    if (p == null) return '';
    final ctx = PatternCtx(_scratch, start: 0, end: math.max(1.0, p.hold), pfx: 'x', plate: 'plate', prevPlate: 'prev');
    final pv = PatternRuntime.preview(p, ctx, caps: caps);
    final main = pv.firstWhere((s) => s['primary'] != 'layers', orElse: () => pv.isEmpty ? const {'uses': 'none'} : pv.first);
    return '${main['uses']}${main['fallback'] == true ? ' (fallback for ${main['primary']})' : ''}';
  }

  static final Project _scratch = Project(id: 'scratch', name: 'scratch', main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: 10));

  /// (pattern id, score) best first, for the cues of one segment.
  static List<(String, double)> _score(List<Cue> cues, String text) {
    final toks = CueClassifier.tokens(text);
    final out = <(String, double)>[];
    for (final p in PatternLibrary.all) {
      if (p.isTransition || p.role == 'presenter' || p.precede.contains('presenter')) continue;
      var s = 0.0;
      final seen = <String>{};
      for (final c in cues) {
        final w = p.cues[c.type];
        if (w == null || !seen.add(c.type)) continue;
        s += w * c.weight;
      }
      if (s <= 0) continue;
      if (p.keywords.isNotEmpty && CueClassifier.findPhrases(toks, [for (final k in p.keywords) [for (final w in k.split(' ')) w.endsWith('*') ? '${CueClassifier.key(w.substring(0, w.length - 1))}*' : CueClassifier.key(w)]]).isNotEmpty) {
        s += 0.3;
      }
      // specific patterns beat generic ones
      if (p.id == 'map_labels_typed' && cues.where((c) => c.type == 'place' && c.weight >= 1).length < 2) s *= 0.5;
      if (p.id == 'route_duration_label' && !cues.any((c) => c.type == 'duration' || c.type == 'time')) s *= 0.4;
      if (p.id == 'giant_ghost_country' || p.id == 'map_zoom_punch') s *= 0.8;
      out.add((p.id, s));
    }
    out.sort((a, b) => b.$2.compareTo(a.$2));
    return out;
  }

  static Cue? _keyCue(DocPattern p, List<Cue> cues) {
    Cue? best;
    var w = 0.0;
    for (final c in cues) {
      final pw = (p.cues[c.type] ?? 0) * c.weight;
      if (pw > w) {
        w = pw;
        best = c;
      }
    }
    return best;
  }

  /// Reveal 0.2 s after the keyword (inside the segment).
  static double _reveal(_Seg sg, Cue c) => ((c.at ?? sg.start) + 0.2).clamp(sg.start + 0.1, math.max(sg.start + 0.1, sg.end - 0.3)).toDouble();

  static String _numText(Cue c) {
    final v = c.value;
    if (v is Map && v['text'] != null) return '${v['text']}'.toUpperCase();
    if (v is Map && v['label'] != null && v['value'] is num) {
      final n = (v['value'] as num).toDouble();
      return '${n == n.roundToDouble() ? n.round() : n} ${v['label']}'.toUpperCase();
    }
    return c.match.toUpperCase();
  }

  static String _transition(Map<String, dynamic> a, Map<String, dynamic> b, String tone, String? force, _Counts n, String last) {
    final pa = PatternLibrary.byId('${a['pattern']}')!, pb = PatternLibrary.byId('${b['pattern']}')!;
    String pick(List<String> opts) => opts.firstWhere((o) => o != last, orElse: () => opts.first);
    if (pa.id == 'mood_flood' || pa.id == 'crash_to_black' || pa.id == 'cut_to_black' || pb.id == 'cut_to_black' || pb.id == 'crash_to_black') return 'cut';
    final text = '${b['text']}';
    final bc = CueClassifier.classify(text);
    if (pa.isEvidence && pb.category == 'shot') return pick(const ['zoom_blur', 'flash_cut']);
    if (pa.category == 'shot' && pb.category == 'evidence' && pb.fullscreen) return pick(const ['zoom_out_to_source', 'zoom_blur']);
    if (bc.any((c) => c.type == 'witness' && c.weight >= 1) && pb.role != 'presenter') return 'eye_reflection';
    if (bc.any((c) => c.type == 'turning_point')) return pick(const ['ink_bleed_duotone', 'zoom_blur']);
    if (pb.id == 'photo_wall' || pb.id == 'montage') return pick(const ['slide_film', 'zoom_blur']);
    if (pb.id == 'sun_glare_entry' || bc.any((c) => c.type == 'sunrise' && c.weight >= 1) && pb.role != 'presenter') return 'sun_glare_entry';
    if (pa.category == 'maps' && pb.category == 'shot') return 'map_drop';
    final toneT = force ?? (tone == 'snow' || tone == 'desert' ? 'powder_burst' : null);
    if (pa.role == 'presenter' || pb.role == 'presenter') {
      final k = n.presenter++;
      if (k % 5 == 0 || k % 5 == 2 || k % 5 == 4) return 'cut'; // ~60% hard cuts
      if (pb.role == 'presenter' && bc.any((c) => c.type == 'emphasis' || c.type == 'question')) return 'presenter_punch_in';
      return pick([if (toneT != null) toneT, 'light_leak_wipe', 'flash_cut', 'debris_burst']);
    }
    final m = n.broll++;
    if (m % 3 != 2) return 'cut';
    return pick([if (toneT != null) toneT, if (tone == 'snow') 'debris_burst', 'zoom_blur', 'light_leak_wipe']);
  }

  /// "New element every 1–2.5 s": the beat's reveal times, plus camera
  /// beats filling any longer gap.
  static void _events(Map<String, dynamic> b, DocPattern p) {
    final s = (b['start'] as num).toDouble(), e = (b['end'] as num).toDouble();
    final ts = <(double, String)>[(s, b['transition_in'] == 'cut' ? 'cut' : 'transition')];
    if (b['reveal_at'] is num) ts.add(((b['reveal_at'] as num).toDouble(), 'reveal'));
    for (final o in (b['overlays'] as List? ?? const [])) {
      if (o['at'] is num) ts.add(((o['at'] as num).toDouble() + 0.2, '${o['pattern']}'));
    }
    ts.sort((a, b) => a.$1.compareTo(b.$1));
    final out = <(double, String)>[];
    var last = s;
    for (final x in ts) {
      while (x.$1 - last > 2.5) {
        last += 2.0;
        out.add((last, 'camera_beat'));
      }
      out.add(x);
      last = math.max(last, x.$1);
    }
    while (e - last > 2.5) {
      last += 2.0;
      out.add((last, 'camera_beat'));
    }
    b['events'] = [for (final x in out) {'t': _r(x.$1), 'what': x.$2}];
  }

  /// Slot values for [p] from the cues of its line.
  static Map<String, dynamic> _slots(DocPattern p, List<Cue> cues, String text) {
    final s = <String, dynamic>{'line': text};
    Iterable<Cue> of(String t) => cues.where((c) => c.type == t);
    final places = <String>[];
    String? city;
    for (final c in of('place')) {
      final v = c.value;
      if (v is! Map) continue;
      if (v['city'] == true) {
        city ??= '${v['name']}';
        if (!places.contains('${v['country']}')) places.add('${v['country']}');
      } else if (!places.contains('${v['name']}')) {
        places.add('${v['name']}');
      }
    }
    if (places.isNotEmpty) {
      s['places'] = places;
      s['place'] = places.first;
    }
    if (city != null) s['city'] = city;
    final route = of('route').where((c) => c.value is Map).toList();
    final nums = of('number').toList();
    final people = of('people_count').toList();
    String up(String x) => x.toUpperCase();
    switch (p.id) {
      case 'route_arrow_follow':
      case 'route_duration_label':
        if (route.isNotEmpty) {
          final v = route.first.value as Map;
          if (v['from'] != null) s['from'] = '${v['from']}';
          if (v['to'] != null) s['to'] = '${v['to']}';
        } else if (places.length >= 2) {
          s['from'] = places[0];
          s['to'] = places[1];
        }
        final d = of('duration').where((c) => c.value is Map && (c.value as Map)['value'] != null).toList();
        if (d.isNotEmpty) s['label'] = up(d.first.match);
      case 'map_tilt_3d':
        final tr = of('terrain').toList();
        if (tr.isNotEmpty) s['terrain'] = up(tr.first.match);
      case 'search_sweep':
        final tr = of('terrain').toList();
        s['place'] = up(places.isNotEmpty ? places.first : (tr.isNotEmpty ? tr.first.match : 'SEARCH'));
        s['label'] = 'SEARCH';
      case 'sketch_map':
        final dirs = [for (final c in of('direction')) up(c.match)];
        if (dirs.isNotEmpty) s['items'] = dirs;
      case 'doc_highlight_circle':
      case 'article_focus':
      case 'quote_hole':
        final q = of('quote').where((c) => c.value is String).toList();
        s['quote'] = q.isNotEmpty ? q.first.value : text;
        final n = [...nums, ...of('date')];
        if (n.isNotEmpty) s['circle'] = n.first.match;
        final src = of('article').followedBy(of('second_source')).toList();
        if (src.isNotEmpty) s['source'] = 'Source – ${src.first.match}';
      case 'book_reveal_open':
        final q = of('quote').where((c) => c.value is String).toList();
        s['quote'] = q.isNotEmpty ? q.first.value : text;
      case 'note_card':
        final c = of('concept').toList();
        if (c.isNotEmpty) s['text'] = up(c.first.match);
      case 'handwrite_card':
      case 'speech_bubble_comic':
      case 'speech_bubble_puff':
      case 'kinetic_text':
        final q = of('dialogue').followedBy(of('quote')).where((c) => c.value is String).toList();
        s['text'] = q.isNotEmpty ? '${q.first.value}' : text;
      case 'grunge_photo_title':
      case 'emblem_badge':
        final o = of('organisation').toList();
        if (o.isNotEmpty) {
          s['title'] = up(o.first.match);
          s['label'] = up(o.first.match);
        }
      case 'unit_chart':
        final c = people.isNotEmpty ? people.first : (nums.isNotEmpty ? nums.first : null);
        if (c != null && c.value is Map) {
          final v = c.value as Map;
          s['total'] = v['value'];
          s['label'] = _numText(c);
          final rest = [...people.skip(1), ...nums.where((n) => n.offset != c.offset)];
          if (rest.isNotEmpty) s['groups'] = [for (final r in rest.take(3)) if (r.value is Map) '${((r.value as Map)['value'] as num).round()}:${up(r.match.replaceFirst(RegExp(r'^[\d,.\s]+'), ''))}'];
        }
      case 'people_grid_tally':
        final sv = of('survivors').where((c) => c.value is Map).toList();
        final all = [...people, ...nums];
        if (sv.isNotEmpty) s['alive'] = (sv.first.value as Map)['value'];
        if (all.length >= 2) {
          final vs = [for (final c in all) if (c.value is Map) ((c.value as Map)['value'] as num).toDouble()]..sort();
          s['total'] = vs.last;
          s['alive'] = vs.first;
        }
        if (s['alive'] != null) s['label'] = '${(s['alive'] as num).round()} SURVIVORS';
      case 'stat_figure':
        final v = of('stat_change').where((c) => c.value is Map).toList();
        if (v.isNotEmpty) {
          final m = v.first.value as Map;
          if (m['from'] != null) s['from'] = m['from'];
          s['to'] = m['to'];
        }
        if (nums.isNotEmpty && nums.first.value is Map) s['unit'] = (nums.first.value as Map)['unit'];
      case 'comparison_split':
        final v = of('comparison').where((c) => c.value is List).toList();
        if (v.isNotEmpty) {
          final l = v.first.value as List;
          s['a_value'] = '${l[0]}';
          if (l.length > 1) s['b_value'] = '${l[1]}';
        }
      case 'gauge_hud':
      case 'fog_tracking':
        final g = [...of('gauge'), ...nums].where((c) => c.value is Map && (c.value as Map)['value'] != null).toList();
        if (g.isNotEmpty) {
          final v = ((g.first.value as Map)['value'] as num).toDouble();
          s['from'] = v;
          s['to'] = (v * 0.65).roundToDouble();
          s['unit'] = '${(g.first.value as Map)['unit'] ?? 'FT'}'.isEmpty ? 'FT' : (g.first.value as Map)['unit'];
        }
      case 'clock_stamp':
        final lines = <String>[
          for (final c in of('day_count')) '${c.value ?? up(c.match)}',
          for (final c in of('date')) if (c.value is String && (c.value as String).isNotEmpty) '${c.value}',
          for (final c in of('time')) '${c.value ?? up(c.match)}',
        ];
        if (lines.isNotEmpty) s['lines'] = lines.toSet().take(3).toList();
      case 'stat_behind_silhouettes':
      case 'stat_title':
        if (nums.isNotEmpty) {
          s['text'] = _numText(nums.first);
          s['line1'] = _numText(nums.first);
        } else if (people.isNotEmpty) {
          s['text'] = _numText(people.first);
          s['line1'] = _numText(people.first);
        }
      case 'calendar_flip':
        final d = of('duration').where((c) => c.value is Map && (c.value as Map)['value'] != null).toList();
        if (d.isNotEmpty) {
          final v = d.first.value as Map;
          final days = ((v['value'] as num) * switch ('${v['unit']}') { 'weeks' => 7, 'months' => 30, 'years' => 365, _ => 1 }).round();
          s['from'] = 1;
          s['to'] = days;
        }
      case 'clock_overlay':
        final d = of('duration').where((c) => c.value is Map && (c.value as Map)['value'] != null).toList();
        if (d.isNotEmpty) s['text'] = up(d.first.match);
      case 'signal_rings':
      case 'inset_circle':
      case 'ui_toggle':
        final o = of('radio').followedBy(of('object')).followedBy(of('device')).toList();
        if (o.isNotEmpty) s['label'] = up(o.first.match);
      case 'audio_wave_flag':
        if (places.isNotEmpty) s['country'] = places.first;
        final o = of('broadcast').toList();
        if (o.isNotEmpty) s['label'] = up(o.first.match);
      case 'list_card':
      case 'icon_sticker':
        final l = of('list').where((c) => c.value is List).toList();
        if (l.isNotEmpty) s['items'] = l.first.value;
      case 'surface_labels':
        final pr = of('person').toList();
        if (pr.isNotEmpty) s['role'] = up(pr.first.match);
      case 'geo_label':
        final c = of('crash').toList();
        s['text'] = c.isNotEmpty ? 'CRASH SITE' : up(places.isNotEmpty ? places.first : 'HERE');
      case 'spotlight_subject':
        if (of('pain').isNotEmpty) s['pain'] = true;
    }
    return s;
  }

  static double _r(double v) => double.parse(v.toStringAsFixed(2));

  // ------------------------------------------------------------ Director hook

  /// Per-line pattern hints for the Director's AI planner (opt-in capability).
  static List<Map<String, dynamic>> hints(List<(double, double, String)> lines, {int? first}) {
    final out = <Map<String, dynamic>>[];
    for (int i = 0; i < lines.length; i++) {
      final (s, e, text) = lines[i];
      final cues = CueClassifier.classify(text, start: s, end: e);
      final sc = _score(cues, text);
      if (sc.isEmpty || sc.first.$2 < 0.6) continue;
      out.add({
        'i': (first ?? 0) + i,
        'patterns': [for (final x in sc.take(2)) x.$1],
        'cues': [...{for (final c in cues.where((c) => c.weight >= 0.7)) c.type}],
      });
    }
    return out;
  }

  /// One prompt line telling the planner how to use the hints.
  static const promptSection = '''
STORY PATTERNS (pattern_hints): each hinted line names the documentary pattern that fits its cue (map for places, route for "X se Y tak", article highlight for sources — ALWAYS followed by a reenactment, clock stamp for dates/times, unit chart for totals, mood flood for death/despair, presenter on "aap/dosto/you"). Prefer the matching visual from the list above; presenter every 12-25 s (25-30% of the time), never right after the crash, always before a climax.''';
}

class _Counts {
  int presenter = 0, broll = 0;
}

class _Seg {
  final int line;
  final String text;
  final double start, end;
  final List<Cue> cues;
  _Seg(this.line, this.text, this.start, this.end, this.cues);
}
