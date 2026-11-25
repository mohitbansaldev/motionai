import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/ai/command_spec.dart';
import 'package:motionai/audio/audio_cache.dart';
import 'package:motionai/audio/sfx_library.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/commands/v3_fx_commands.dart';
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/engine/fx_math.dart';
import 'package:motionai/core/model/anim_prop.dart';
import 'package:motionai/core/model/camera.dart';
import 'package:motionai/core/model/easing.dart';
import 'package:motionai/core/model/effects_catalog.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/doc_transitions.dart';
import 'package:motionai/core/presets/fx_animators.dart';
import 'package:motionai/core/presets/motion_presets.dart';
import 'package:motionai/core/presets/transition_registry.dart';
import 'package:motionai/director/sfx.dart';
import 'package:motionai/fonts/font_catalog.dart';
import 'package:motionai/ui/preview/composition_canvas.dart';
import 'package:motionai/ui/preview/fx/v3_fx_painters.dart';

Project newProject({double w = 1920, double h = 1080}) => Project(
      id: 'p',
      name: 'V3D',
      main: Composition(id: 'main', name: 'Main', width: w, height: h, fps: 30, duration: 10),
    );

CommandResult run(Project p, Map<String, dynamic> c) => EditCommands.runAtomic(p, c);

/// Two shots: a (0..5 s) and b (5..10 s).
Project twoShots({double w = 1920, double h = 1080}) {
  final p = newProject(w: w, h: h);
  run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'b', 'color': '#806040', 'start': 5, 'duration': 5});
  run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'a', 'color': '#304060', 'start': 0, 'duration': 5});
  return p;
}

const v3Types = [
  'powder_burst', 'debris_burst', 'frost_shatter', 'zoom_blur', 'eye_reflection', 'holes', 'shatter', 'slice', 'slant_wipe',
  'shrink_to_card', 'emerge', 'zoom_out_of_photo', 'slide_film', 'exposure_in', 'punch_in', 'cut_to_black',
];

double val(AnimProp p, double t, [int i = 0]) => p.valueAt(t)[i];

Effect effectOf(Layer l, String type) => l.effects.firstWhere((e) => e.type == type);

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('v3d');
    SfxLibrary.dir = tmp.path;
    AudioCache.clear();
  });
  tearDown(() {
    SfxLibrary.dir = null;
    AudioCache.clear();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('catalog', () {
    test('every V3 transition is registered, documented and has real sounds', () {
      final docs = File('docs/EDIT_COMMANDS.md').readAsStringSync();
      final names = <String>[];
      DocTransitions.registerAll((name, fn) => names.add(name));
      for (final t in v3Types) {
        final d = DocTransitions.byId(t);
        expect(d, isNotNull, reason: t);
        expect(names, contains(t));
        expect(commandSpec, contains(t), reason: t);
        expect(docs, contains('`$t`'), reason: t);
        for (final s in d!.sounds) {
          expect(Sfx.all, contains(s), reason: '$t sound $s');
        }
      }
      expect(DocTransitions.types.toSet().length, DocTransitions.types.length, reason: 'unique ids');
      TransitionRegistry.addRegistrar(DocTransitions.registerAll);
      expect(TransitionRegistry.has('powder_burst'), isTrue);
    });

    test('ops, effects, animators, sounds and particle kinds are documented', () {
      for (final op in V3FxCommands.ops) {
        expect(EditCommands.ops, contains(op));
        expect(commandSpec, contains(op), reason: op);
      }
      for (final e in ['burst', 'radial_blur', 'holes', 'frost', 'cracks', 'threshold', 'red_paint', 'lightning', 'slices', 'slant_wipe', 'slide_mount', 'puff']) {
        expect(EffectsCatalog.byType(e), isNotNull, reason: e);
        expect(commandSpec, contains(e), reason: e);
      }
      for (final a in FxAnimators.presets) {
        expect(MotionPresets.transitions, contains(a));
        expect(commandSpec, contains(a));
      }
      for (final k in Sfx.v3dKinds) {
        expect(Sfx.all, contains(k));
        expect(commandSpec, contains(k));
      }
      for (final k in ['debris', 'snow_spray', 'ice']) {
        expect(kParticleKinds, contains(k));
      }
      expect(EffectsCatalog.paramDef('particles', 'kind')!.max, kParticleKinds.length - 1);
      expect(commandSpec, contains('Comic Neue'));
    });

    test('Comic Neue is bundled (OFL) and is the comic bubble font', () {
      final f = FontCatalog.lookup('comic')!;
      expect(f.family, 'Comic Neue');
      for (final path in f.assetPaths) {
        expect(File(path).existsSync(), isTrue, reason: path);
      }
      expect(File(f.licensePath).readAsStringSync(), contains('SIL OPEN FONT LICENSE'));
      expect(File('pubspec.yaml').readAsStringSync(), contains('assets/fonts/comicneue/ComicNeue-Bold.ttf'));
    });
  });

  group('sounds', () {
    test('new kinds render with their peak on the loud moment', () {
      for (final k in Sfx.v3dKinds) {
        final (l, r) = Sfx.render(k);
        expect(l.length / Sfx.rate, closeTo(Sfx.length(k), 0.01), reason: k);
        var mx = 0.0, mxAt = 0;
        for (int i = 0; i < l.length; i++) {
          final v = math.max(l[i].abs(), r[i].abs());
          if (v > mx) {
            mx = v;
            mxAt = i;
          }
        }
        expect(mx, inInclusiveRange(0.8, 0.9), reason: k);
        expect(mxAt / Sfx.rate, lessThan(Sfx.length(k)), reason: k);
        expect(Sfx.info(k).$2, isIn(Sfx.categories));
        expect(Sfx.wav(k), Sfx.wav(k), reason: 'deterministic $k');
      }
    });
  });

  group('transitions', () {
    test('powder_burst: full cover centred on the cut, flakes linger over the incoming', () {
      final p = twoShots();
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'powder_burst', 'params': {'direction': 'left', 'linger': 0.4}});
      final a = p.main.layerById('a')!, b = p.main.layerById('b')!;
      expect(a.end, closeTo(5, 1e-6), reason: 'hard cut under the cover');
      expect(b.start, closeTo(5, 1e-6));
      final o = p.main.layerById('tr_b_burst')!;
      expect(p.main.indexOf(o.id), lessThan(p.main.indexOf('a')));
      expect(p.main.indexOf(o.id), lessThan(p.main.indexOf('b')));
      final e = effectOf(o, 'burst');
      double v(String k) => e.params[k]!.staticValue[0];
      expect(o.start + v('cut'), closeTo(5.0, 1e-6));
      expect(v('hold'), closeTo(2.5 / 30, 1e-9));
      expect(v('origin'), kBurstOrigins.indexOf('left'));
      expect(v('linger'), closeTo(0.4, 1e-9));
      expect(o.end, greaterThan(5.29 + 0.4));
      final spec = BurstSpec(
        kind: v('kind').round(), origin: v('origin').round(), density: v('density'), color: const Color(0xFFFFFFFF),
        cut: v('cut'), rise: v('rise'), hold: v('hold'), clear: v('clear'), linger: v('linger'), preRoll: v('pre_roll'),
        cover: v('cover') / 100, seed: 1,
      );
      expect(spec.veil(v('cut')), (1.0, 1.0));
      expect(spec.veil(v('cut') + v('hold') * 0.49).$2, 1.0);
      expect(spec.veil(spec.tA - 0.01).$2, 0);
      expect(spec.veil(spec.tC + 0.01).$2, 0);
      expect(spec.visibleAt(spec.tC + spec.linger * 0.5), isTrue, reason: 'flakes linger');
      expect(spec.visibleAt(spec.tL + 0.05), isFalse);
      // The front grows monotonically before the cut.
      var last = -1.0;
      for (var t = spec.tA; t <= spec.tF; t += 0.02) {
        final (f, _) = spec.veil(t);
        expect(f, greaterThanOrEqualTo(last));
        last = f;
      }
      expect(helperLayers(p).isEmpty, isFalse);
    });

    test('debris_burst: sparse pre-roll before the burst, ice-crash on the cut', () {
      final p = twoShots();
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'debris_burst', 'params': {'kind': 'glass', 'from': 'top_right', 'pre_roll': 1.2}});
      final o = p.main.layerById('tr_b_burst')!;
      final e = effectOf(o, 'burst');
      expect(o.start, lessThanOrEqualTo(5 - 1.2 - 0.3 + 1e-6));
      expect(e.params['kind']!.staticValue[0], kBurstKinds.indexOf('glass'));
      expect(e.params['origin']!.staticValue[0], kBurstOrigins.indexOf('top_right'));
      expect(e.params['pre_roll']!.staticValue[0], closeTo(1.2, 1e-9));
      expect(p.main.layerById('tr_b_sfx_ice_crash'), isNotNull);
    });

    test('zoom_blur crashes the outgoing 2.5x and settles the incoming 1.5x → 1x', () {
      final p = twoShots();
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'zoom_blur', 'params': {'flash': true}});
      final a = p.main.layerById('a')!, b = p.main.layerById('b')!;
      expect(val(a.prop(Props.scale), 5.0), closeTo(250, 1e-6));
      expect(val(b.prop(Props.scale), 5.0), closeTo(150, 1e-6));
      expect(val(b.prop(Props.scale), 5.3), closeTo(100, 1e-6));
      expect(val(effectOf(a, 'radial_blur').params['amount']!, 5.0), closeTo(90, 1e-6));
      expect(val(effectOf(b, 'flash').params['amount']!, 5.0), closeTo(85, 1e-6));
      expect(a.effects.any((x) => x.type == 'motion_blur'), isTrue);
    });

    test('eye_reflection: the outgoing sits in the pupil of the 5x incoming, then pulls back', () {
      final p = twoShots();
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'eye_reflection', 'params': {'point': [900, 500]}});
      final a = p.main.layerById('a')!, b = p.main.layerById('b')!;
      expect(val(b.prop(Props.scale), 5.0), closeTo(500, 1e-6));
      expect(val(b.prop(Props.scale), 5.0 + 0.63 + 0.01), closeTo(100, 1e-6));
      expect(p.main.indexOf('a'), lessThan(p.main.indexOf('b')), reason: 'reflection above the eye');
      expect(val(a.prop(Props.opacity), 5.0), closeTo(70, 1e-6));
      final m = a.masks.single;
      expect(m.shape, 'ellipse');
      expect(m.props['size']!.valueAt(5.0)[0], closeTo(a.height, 1e-6));
      expect(a.prop(Props.position).valueAt(5.0).sublist(0, 2), [900.0, 500.0]);
      // Pupil = 15% of the width at rest: a's screen height at the end of the pull-back.
      final sc = val(a.prop(Props.scale), 5.0 + 0.63);
      expect(a.height * sc / 100, closeTo(1920 * 0.15, 1));
      expect(a.end, greaterThan(5.63));
    });

    test('holes eat the outgoing by the cut', () {
      final p = twoShots();
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'holes'});
      final a = p.main.layerById('a')!;
      final h = effectOf(a, 'holes').params['progress']!;
      expect(val(h, 4.6), closeTo(0, 1e-6));
      expect(val(h, 5.0), closeTo(100, 1e-6));
      expect(a.end, closeTo(5 + 1 / 30, 1e-6));
      // Holes grow with progress and finally cover the frame.
      for (int i = 0; i < 40; i++) {
        final r0 = HoleMask.hole(i, 0.3, 7, 0.1, 1920, 1080).$3, r1 = HoleMask.hole(i, 0.6, 7, 0.1, 1920, 1080).$3;
        expect(r1, greaterThanOrEqualTo(r0));
        expect(HoleMask.hole(i, 0.6, 7, 0.1, 1920, 1080).$3, lessThanOrEqualTo(0.1 * 1920 / 2 + 1e-6));
      }
    });

    test('shatter tone ice: cracks lead in, ice shards break on the cut', () {
      final p = twoShots();
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'shatter', 'params': {'tone': 'ice', 'lead_in': 1.0}});
      final a = p.main.layerById('a')!;
      final cr = effectOf(a, 'cracks').params['progress']!;
      expect(val(cr, 4.0), closeTo(0, 1e-6));
      expect(val(cr, 4.99), greaterThan(90));
      final sh = effectOf(a, 'shatter');
      expect(sh.params['color']!.staticValue, [191.0, 230.0, 255.0]);
      expect(val(sh.params['progress']!, 4.9), closeTo(0, 1e-6));
      expect(a.effects.any((e) => e.type == 'frost'), isTrue);
    });

    test('slice / slant_wipe / emerge / shrink_to_card key their reveals', () {
      final p = twoShots();
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'slice'});
      final s = effectOf(p.main.layerById('b')!, 'slices').params['progress']!;
      expect(val(s, 4.8), 0);
      expect(val(s, 5.2), 100);
      for (var q = 0.0; q <= 1.0; q += 0.1) {
        expect(SlicesFx.bandProgress(q, 3, 4, 0.3), lessThanOrEqualTo(SlicesFx.bandProgress(q, 0, 4, 0.3)));
      }
      expect(SlicesFx.bandProgress(1, 3, 4, 0.3), 1);

      final q = twoShots();
      run(q, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'slant_wipe', 'params': {'direction': 'left'}});
      final sw = effectOf(q.main.layerById('b')!, 'slant_wipe');
      expect(sw.params['side']!.staticValue[0], 0);
      expect(sw.params['angle']!.staticValue[0], 10);

      final e = twoShots();
      run(e, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'emerge', 'params': {'point': [300, 200]}});
      final eb = e.main.layerById('b')!;
      expect(val(eb.prop(Props.scale), 5.0), closeTo(5, 1e-6));
      expect(val(eb.prop(Props.scale), 5.75), closeTo(100, 1e-6));
      expect(eb.prop(Props.position).valueAt(5.0)[0], closeTo(300 + (960 - 300) * 0.05, 1e-6));

      final c = twoShots();
      run(c, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'shrink_to_card'});
      final ca = c.main.layerById('a')!;
      expect(val(ca.prop(Props.scale), 5.0), closeTo(45, 1e-6));
      expect(ca.end, closeTo(5.65 + 1.5, 1e-6));
      expect(ca.effects.any((x) => x.type == 'outline'), isTrue);
      expect(c.main.layerById('b')!.effects.any((x) => x.type == 'duotone'), isTrue);
    });

    test('zoom_out_of_photo starts with the photo of the incoming filling the frame', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'page', 'color': '#EEE8DD'});
      run(p, {'op': 'add_layer', 'type': 'shape', 'id': 'embed', 'kind': 'rect', 'width': 400, 'height': 300, 'position': [500, 300, 0], 'fill': '#000000'});
      run(p, {'op': 'precompose', 'layers': ['page', 'embed'], 'id': 'ART', 'layer_id': 'b'});
      run(p, {'op': 'update_layer', 'layer': 'b', 'start': 5, 'duration': 5});
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'a', 'color': '#304060', 'start': 0, 'duration': 5});
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'zoom_out_of_photo', 'params': {'layer': 'embed'}, 'sound': false});
      final b = p.main.layerById('b')!, a = p.main.layerById('a')!;
      final k = math.max(1920 / 400, 1080 / 300) * 1.02;
      expect(val(b.prop(Props.scale), 5.0), closeTo(100 * k, 0.5));
      expect(val(b.prop(Props.scale), 6.0), closeTo(100, 1e-6));
      // The photo centre is on the frame centre at the cut.
      final bp = b.prop(Props.position).valueAt(5.0);
      expect(bp[0] + (500 - 960) * k, closeTo(960, 2));
      expect(bp[1] + (300 - 540) * k, closeTo(540, 2));
      expect(val(a.prop(Props.opacity), 6.0), closeTo(0, 1e-6));
      expect(() => run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'zoom_out_of_photo', 'params': {'layer': 'nope'}}),
          throwsA(isA<CommandError>()));
    });

    test('slide_film builds two 35 mm mounts and a carousel backdrop', () {
      final p = twoShots();
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'slide_film'});
      final ma = p.main.layerById('tr_b_mount_a')!, mb = p.main.layerById('tr_b_mount_b')!, bg = p.main.layerById('tr_b_carousel')!;
      expect(effectOf(ma, 'slide_mount'), isNotNull);
      expect(p.main.indexOf(bg.id), greaterThan(p.main.indexOf('a')));
      expect(p.main.indexOf(bg.id), greaterThan(p.main.indexOf('b')));
      expect(val(ma.prop(Props.scale), 4.75), closeTo(55, 1e-6));
      expect(val(mb.prop(Props.scale), 5.5), closeTo(100, 1e-6));
      final b = p.main.layerById('b')!;
      expect(val(b.prop(Props.scale), 5.25), closeTo(55, 1e-6));
      expect(val(b.prop(Props.scale), 5.5), closeTo(100, 1e-6));
    });

    test('exposure_in, punch_in and cut_to_black', () {
      final p = twoShots();
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'exposure_in'});
      final b = p.main.layerById('b')!;
      expect(val(effectOf(b, 'flash').params['amount']!, 5.0), closeTo(2 / 2.2 * 100, 1e-6));
      expect(val(effectOf(b, 'flash').params['amount']!, 5.75), closeTo(0, 1e-6));
      expect(p.main.layerById('tr_b_rays'), isNotNull);

      final q = twoShots();
      run(q, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'punch_in'});
      final qb = q.main.layerById('b')!;
      expect(val(qb.prop(Props.scale), 5.0), closeTo(150, 1e-6));
      expect(val(qb.prop(Props.scale), 5.25), closeTo(100, 1e-6));

      final c = twoShots();
      c.media['song'] = MediaAsset(id: 'song', type: MediaType.audio, path: '/nonexistent/song.wav', name: 'music', width: 0, height: 0, duration: 20);
      run(c, {'op': 'add_layer', 'type': 'audio', 'media': 'song', 'id': 'music', 'start': 0});
      run(c, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'cut_to_black'});
      final black = c.main.layerById('tr_b_black')!;
      expect(black.start, closeTo(5, 1e-6));
      expect(black.end, closeTo(6.5, 1e-6));
      final vol = c.main.layerById('music')!.prop(Props.volume);
      expect(val(vol, 4.5), closeTo(100, 1e-6));
      expect(val(vol, 5.5), closeTo(0, 1e-6));
      expect(val(vol, 6.9), closeTo(100, 1e-6));
      expect(c.main.layerById('tr_b_sfx_impact'), isNotNull);
    });

    test('ink_bleed incoming duotone_of_outgoing splits the outgoing and tints it navy', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'ph', 'color': '#A08060', 'start': 0, 'duration': 6});
      run(p, {'op': 'transition', 'from': 'ph', 'type': 'ink_bleed', 'incoming': 'duotone_of_outgoing', 'at': 3, 'sound': false});
      final b = p.main.layerById('ph_duo')!;
      expect(b.start, lessThan(3));
      final duo = effectOf(b, 'duotone');
      expect(duo.params['dark']!.staticValue, [10.0, 22.0, 48.0]);
      expect(duo.params['light']!.staticValue, [108.0, 134.0, 176.0]);
    });

    test('every V3 transition is one undo step', () {
      for (final t in v3Types) {
        final p = twoShots();
        final before = ProjectSnapshot.take(p);
        run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': t});
        expect(ProjectSnapshot.take(p), isNot(before), reason: t);
        ProjectSnapshot.restore(p, before);
        expect(ProjectSnapshot.take(p), before, reason: t);
      }
    });

    test('sequence uses the V3 transitions', () {
      final p = newProject();
      p.media['plate'] = MediaAsset(id: 'plate', type: MediaType.image, path: '/nonexistent/plate.png', name: 'plate', width: 1920, height: 1080);
      run(p, {
        'op': 'sequence',
        'transitions': [
          {'between': [0, 1], 'type': 'powder_burst', 'duration': 0.6},
        ],
        'shots': [
          {'id': 's1', 'plate': 'plate', 'duration': 3},
          {'id': 's2', 'plate': 'plate', 'duration': 3},
        ],
      });
      expect(p.main.layerById('tr_s2_burst'), isNotNull);
    });
  });

  group('mood & character ops', () {
    Project scene() {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'color': '#406080', 'start': 0, 'duration': 10});
      run(p, {'op': 'add_layer', 'type': 'shape', 'id': 'man', 'kind': 'rect', 'width': 300, 'height': 600, 'position': [1300, 600, 0], 'fill': '#C08050', 'start': 0, 'duration': 10});
      run(p, {'op': 'add_layer', 'type': 'shape', 'id': 'crowd', 'kind': 'rect', 'width': 600, 'height': 400, 'position': [500, 700, 0], 'fill': '#80A060', 'start': 0, 'duration': 10});
      return p;
    }

    test('mood_flood: red ink flood from a corner, kept layers in colour above, one undo step', () {
      final p = scene();
      final before = ProjectSnapshot.take(p);
      final r = run(p, {'op': 'mood_flood', 'at': 2, 'keep': ['man'], 'from': 'top_right'});
      final f = p.main.layerById('mood_flood')!;
      expect(f.adjustment, isTrue);
      expect(f.start, 2);
      expect(f.end, closeTo(2 + 0.9 + 2.5, 1e-6));
      final duo = effectOf(f, 'duotone');
      expect(duo.params['light']!.staticValue, [224.0, 40.0, 58.0]);
      final ink = effectOf(f, 'reveal');
      expect(ink.params['kind']!.staticValue[0], 1);
      expect(ink.params['cx']!.staticValue[0], 100);
      expect(ink.params['cy']!.staticValue[0], 0);
      expect(val(ink.params['progress']!, 2), 0);
      expect(val(ink.params['progress']!, 2.9), 100);
      expect(f.masks, isNotEmpty);
      final keep = p.main.layerById('mood_flood_keep_man')!;
      expect(p.main.indexOf(keep.id), lessThan(p.main.indexOf(f.id)));
      expect(keep.start, 2);
      expect(keep.end, closeTo(f.end, 1e-6));
      expect(r.createdIds, containsAll(['mood_flood', 'mood_flood_keep_man']));
      expect(p.main.layers.any((l) => l.type == LayerType.audio), isTrue, reason: 'braam');
      ProjectSnapshot.restore(p, before);
      expect(ProjectSnapshot.take(p), before);
      expect(() => run(p, {'op': 'mood_flood', 'keep': ['ghost']}), throwsA(isA<CommandError>()));
    });

    test('tint_wipe and grade_swap (snap, chain, normal)', () {
      final p = scene();
      run(p, {'op': 'tint_wipe', 'at': 1, 'from': 'right', 'sfx': false});
      final tw = p.main.layerById('tint_wipe')!;
      final wipe = effectOf(tw, 'slant_wipe');
      expect(wipe.params['side']!.staticValue[0], 1);
      expect(val(wipe.params['progress']!, 1.6), 100);
      run(p, {'op': 'grade_swap', 'to': 'hope', 'at': 2});
      final hope = p.main.layerById('grade_hope')!;
      expect(hope.adjustment, isTrue);
      expect(hope.start, 2);
      expect(effectOf(hope, 'grade').params['saturation']!.staticValue[0], greaterThan(20));
      run(p, {'op': 'grade_swap', 'to': 'cold', 'at': 4});
      expect(hope.end, closeTo(4, 1e-6), reason: 'the next grade ends the previous one');
      run(p, {'op': 'grade_swap', 'to': 'normal', 'at': 6});
      expect(p.main.layerById('grade_cold')!.end, closeTo(6, 1e-6));
      expect(() => run(p, {'op': 'grade_swap', 'to': 'purple'}), throwsA(isA<CommandError>()));
    });

    test('spotlight_subject: others mono + dim, subject red-tinted, eased release', () {
      final p = scene();
      run(p, {'op': 'spotlight_subject', 'keep': ['man'], 'start': 1, 'duration': 2, 'tint': {'color': '#D0101A', 'amount': 70}});
      final crowd = p.main.layerById('crowd')!, man = p.main.layerById('man')!;
      final mono = crowd.effectById('crowd_spot_mono')!.params['amount']!;
      expect(val(mono, 0.9), 0);
      expect(val(mono, 2), 100);
      expect(val(mono, 3.6), 0);
      expect(val(crowd.effectById('crowd_spot_dim')!.params['brightness']!, 2), lessThan(-10));
      expect(man.effectById('man_spot_mono'), isNull);
      expect(val(man.effectById('man_spot_tint')!.params['amount']!, 2), 70);
      for (final k in mono.keyframes.take(mono.keyframes.length - 1)) {
        expect(k.easing.type, isNot(EaseType.linear));
      }
    });

    test('pulse oscillates an effect on the layer and its sync layers, heartbeat sfx', () {
      final p = scene();
      run(p, {'op': 'pulse', 'layer': 'man', 'sync': ['crowd'], 'period': 1, 'start': 1, 'duration': 3, 'sfx': 'heartbeat'});
      for (final id in ['man', 'crowd']) {
        final amt = p.main.layerById(id)!.effectById('${id}_pulse_tint')!.params['amount']!;
        expect(val(amt, 1), 0);
        expect(val(amt, 1.5), 70);
        expect(val(amt, 2), 0);
        expect(val(amt, 3.5), 70);
        expect(val(amt, 4), 0);
      }
      expect(p.main.layers.where((l) => l.type == LayerType.audio).length, 2);
      run(p, {'op': 'pulse', 'layer': 'man', 'prop': 'opacity', 'from': 100, 'to': 20, 'period': 0.5, 'start': 5, 'duration': 1});
      expect(val(p.main.layerById('man')!.prop(Props.opacity), 5.25), 20);
    });

    test('cut_to_black op ducks the music to silence and comes back', () {
      final p = scene();
      p.media['song'] = MediaAsset(id: 'song', type: MediaType.audio, path: '/nonexistent/song.wav', name: 'music', width: 0, height: 0, duration: 20);
      run(p, {'op': 'add_layer', 'type': 'audio', 'media': 'song', 'id': 'music', 'start': 0});
      run(p, {'op': 'cut_to_black', 'at': 3, 'hold': 1});
      final black = p.main.layerById('black')!;
      expect(p.main.indexOf('black'), 0);
      expect(black.start, 3);
      expect(black.end, 4);
      final vol = p.main.layerById('music')!.prop(Props.volume);
      expect(val(vol, 2.9), closeTo(100, 1e-6));
      expect(val(vol, 3.5), 0);
      expect(val(vol, 4.5), closeTo(100, 1e-6));
    });

    test('lightning flashes and strikes at each time, with thunder', () {
      final p = scene();
      run(p, {'op': 'lightning', 'at': [2, 2.4], 'x': 0.3});
      final l = p.main.layerById('lightning')!;
      final e = effectOf(l, 'lightning');
      expect(val(e.params['flash']!, 2), 100);
      expect(val(e.params['flash']!, 2.2), lessThan(1));
      expect(val(e.params['bolt']!, 2.02), 100);
      expect(val(e.params['variant']!, 2.45), 1);
      expect(e.params['x']!.staticValue[0], closeTo(30, 1e-9));
      expect(p.main.layers.any((x) => x.type == LayerType.audio), isTrue);
    });

    test('montage: one picture every 0.35 s with looks and a push', () {
      final p = newProject();
      for (int i = 0; i < 4; i++) {
        p.media['m$i'] = MediaAsset(id: 'm$i', type: MediaType.image, path: '/nonexistent/$i.png', name: 'p$i', width: 1600, height: 900);
      }
      run(p, {'op': 'montage', 'media': ['m0', 'm1', 'm2', 'm3'], 'start': 1});
      for (int i = 0; i < 4; i++) {
        final l = p.main.layerById('montage_$i')!;
        expect(l.start, closeTo(1 + i * 0.35, 1e-9));
        expect(l.duration, closeTo(0.35, 1e-9));
        final sc = l.prop(Props.scale);
        expect(val(sc, l.end) / val(sc, l.start), closeTo(1.08, 1e-6));
      }
      expect(p.main.layerById('montage_0')!.effects.any((e) => e.type == 'threshold'), isTrue);
      expect(p.main.layerById('montage_2')!.effects.any((e) => e.type == 'red_paint'), isTrue);
      expect(() => run(p, {'op': 'montage', 'media': ['zz']}), throwsA(isA<CommandError>()));
      expect(() => run(p, {'op': 'montage', 'media': ['m0'], 'looks': ['sparkly']}), throwsA(isA<CommandError>()));
    });

    test('swap_layer swaps in place with a pop (0 → 110 → 100 %)', () {
      final p = scene();
      p.media['img2'] = MediaAsset(id: 'img2', type: MediaType.image, path: '/nonexistent/b.png', name: 'after', width: 800, height: 1600);
      run(p, {'op': 'swap_layer', 'layer': 'man', 'with': 'img2', 'at': 2});
      final old = p.main.layerById('man')!, neo = p.main.layerById('man_swap')!;
      expect(old.end, closeTo(2, 1e-9));
      expect(neo.start, closeTo(2, 1e-9));
      expect(neo.end, closeTo(10, 1e-9));
      expect(neo.type, LayerType.image);
      final rest = 600 / 1600 * 100;
      expect(val(neo.prop(Props.scale), 2), 0);
      expect(val(neo.prop(Props.scale), 2.12), closeTo(rest * 1.1, 1e-6));
      expect(val(neo.prop(Props.scale), 2.3), closeTo(rest, 1e-6));
      expect(neo.prop(Props.position).valueAt(2.3), old.prop(Props.position).valueAt(1));
      expect(() => run(p, {'op': 'swap_layer', 'layer': 'crowd', 'with': 'nothing', 'at': 2}), throwsA(isA<CommandError>()));
    });

    test('set_dof keys = keyframed rack focus', () {
      final p = scene();
      run(p, {'op': 'set_dof', 'keys': [{'t': 1, 'focus': 800}, {'t': 3, 'focus': 1500}], 'aperture': 30});
      final f = p.main.camera.prop(CamProps.focus);
      expect(val(f, 1), 800);
      expect(val(f, 3), 1500);
      expect(val(f, 2), inExclusiveRange(800, 1500));
      expect(p.main.camera.prop(CamProps.aperture).staticValue[0], 30);
      expect(() => run(p, {'op': 'set_dof', 'keys': [{'t': 1, 'focus': 'man'}]}), throwsA(isA<CommandError>()), reason: 'not 3D');
    });

    test('animators punch_in, swing_in, exposure_in', () {
      final p = scene();
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'HELLO', 'start': 1, 'duration': 4});
      run(p, {'op': 'animate_in', 'layer': 't', 'preset': 'punch_in'});
      final t = p.main.layerById('t')!;
      expect(val(t.prop(Props.scale), 1), closeTo(150, 1e-6));
      expect(val(t.prop(Props.scale), 1.25), closeTo(100, 1e-6));
      expect(val(t.effectById('t_in_punch')!.params['amount']!, 1), 40);
      run(p, {'op': 'animate_in', 'layer': 'man', 'preset': 'swing_in', 'rotation': 25, 'background': 'bg'});
      final man = p.main.layerById('man')!;
      expect(man.prop(Props.rotation).valueAt(0)[2], closeTo(25, 1e-6));
      expect(val(man.prop(Props.scale), 0), closeTo(250, 1e-6));
      expect(val(p.main.layerById('bg')!.effectById('bg_in_swingbg')!.params['amount']!, 0), 24);
      run(p, {'op': 'animate_out', 'layer': 'crowd', 'preset': 'exposure_in'});
      final fl = p.main.layerById('crowd')!.effectById('crowd_out_exposure')!.params['amount']!;
      expect(val(fl, 10), greaterThan(80));
      expect(val(fl, 9.0), 0);
    });

    test('speech_bubble: timed messages typed in place, tail to the speaker, puff exit', () {
      final p = scene();
      run(p, {
        'op': 'add_component', 'type': 'speech_bubble', 'id': 'sb', 'start': 1, 'cps': 20, 'exit': 'puff', 'tail_to': [1300, 300],
        'messages': [{'text': 'Hello there', 'at': 0}, {'text': 'Over', 'at': 2}],
      });
      final t0 = p.main.layerById('sb_txt0')!, t1 = p.main.layerById('sb_txt1')!;
      expect(t0.start, closeTo(1.15, 1e-9));
      expect(t0.end, closeTo(3, 1e-9));
      expect(t0.text!.text, 'HELLO THERE');
      expect(t0.text!.animator, 'typewriter');
      expect(t0.text!.animDuration, closeTo(11 / 20, 1e-9));
      expect(t0.text!.fontFamily, 'Comic Neue');
      expect(t1.start, closeTo(3.05, 1e-9));
      final g = p.main.layerById('sb_g')!;
      expect(val(g.prop(Props.scale), 1), 0);
      expect(val(g.prop(Props.scale), 1.13), closeTo(110, 1e-6));
      expect(val(g.prop(Props.scale), 1.2), closeTo(100, 1e-6));
      expect(g.end, closeTo(1 + 2 + 0.15 + 4 / 20 + 1.8, 1e-6));
      expect(p.main.layerById('sb_puff')!.effects.single.type, 'puff');
      expect(p.main.layerById('sb_box')!.shape!.stroke, isNot(0), reason: 'black outline');
      // The bubble sits above the speaker; its tail points down at them without overshooting.
      final tail = p.main.layerById('sb_tail')!, box = p.main.layerById('sb_box')!;
      final tm = Evaluator.worldMatrix(p.main, tail, 1.5);
      final ring = tail.shape!.rings.first;
      var maxY = -1e9;
      for (int i = 0; i + 1 < ring.length; i += 2) {
        maxY = math.max(maxY, projectPoint(tm, ring[i], ring[i + 1]).y);
      }
      final gc = projectPoint(Evaluator.worldMatrix(p.main, g, 1.5), 0, 0);
      expect(gc.y, lessThan(300));
      expect(maxY, greaterThan(gc.y + box.height / 2));
      expect(maxY, lessThanOrEqualTo(301));

      run(p, {'op': 'add_component', 'type': 'speech_bubble', 'id': 'sb2', 'start': 0, 'text': 'Copy that', 'attach': 'man', 'style': 'radio', 'blink': 0.5});
      expect(p.main.layerById('sb2_g')!.parentId, 'man');
      expect(p.main.layerById('sb2_txt')!.text!.fontFamily, 'Roboto Mono');
      expect(p.main.layerById('sb2_box')!.prop(Props.opacity).keyframes, isNotEmpty);
      run(p, {'op': 'add_component', 'type': 'speech_bubble', 'id': 'sb3', 'text': 'Old style', 'style': 'classic'});
      expect(p.main.layerById('sb3_txt'), isNotNull);
      expect(() => run(p, {'op': 'add_component', 'type': 'speech_bubble', 'id': 'sb4', 'style': 'neon'}), throwsA(isA<CommandError>()));
    });
  });

  group('maths', () {
    test('threshold matrix cuts at the level', () {
      final m = V3Color.threshold(0.5, 0.1, 1);
      double out(double g) => (m[0] + m[1] + m[2]) * g + m[4];
      expect(out(200), greaterThan(255));
      expect(out(60), lessThan(0));
      final id = V3Color.threshold(0.5, 0.1, 0);
      expect(id.sublist(0, 5), [1, 0, 0, 0, 0]);
    });

    test('new particle kinds are deterministic and move', () {
      for (final kind in [PKind.debris, PKind.snowSpray, PKind.ice]) {
        final n = ParticleSim.countFor(kind, 60);
        final a = Float64List(n * kParticleStride), b = Float64List(n * kParticleStride);
        ParticleSim.simulate(kind: kind, count: n, t: 1, w: 1920, h: 1080, out: a, seed: 3);
        ParticleSim.simulate(kind: kind, count: n, t: 2, w: 1920, h: 1080, out: b, seed: 3);
        expect(a.every((v) => v.isFinite), isTrue);
        expect(a, isNot(b));
      }
    });
  });

  group('render', () {
    Future<List<int>> pixels(WidgetTester tester, Project p, double t, List<List<int>> at) async {
      final key = GlobalKey();
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: RepaintBoundary(key: key, child: CompositionCanvas(project: p, time: t))),
      ));
      expect(tester.takeException(), isNull);
      final out = <int>[];
      await tester.runAsync(() async {
        final ro = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final img = await ro.toImage();
        final bd = (await img.toByteData())!;
        for (final xy in at) {
          final i = (xy[1] * img.width + xy[0]) * 4;
          out.add((bd.getUint8(i + 3) << 24) | (bd.getUint8(i) << 16) | (bd.getUint8(i + 1) << 8) | bd.getUint8(i + 2));
        }
        img.dispose();
      });
      return out;
    }

    testWidgets('powder_burst covers the frame white at the cut', (tester) async {
      final p = twoShots(w: 200, h: 100);
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'powder_burst', 'sound': false});
      final px = await pixels(tester, p, 5.0, [[100, 50], [10, 10], [190, 90]]);
      for (final v in px) {
        expect((v >> 16) & 0xFF, greaterThan(200));
        expect(v & 0xFF, greaterThan(200));
      }
      final before = await pixels(tester, p, 4.3, [[100, 50]]);
      expect(before[0] & 0xFFFFFF, 0x304060, reason: 'untouched before the burst');
    });

    testWidgets('threshold and slant_wipe effects', (tester) async {
      final p = newProject(w: 200, h: 100);
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'g', 'color': '#A0A0A0', 'start': 0, 'duration': 5});
      run(p, {'op': 'add_effect', 'layer': 'g', 'effect': 'threshold', 'params': {'level': 50, 'softness': 5}});
      expect((await pixels(tester, p, 1, [[100, 50]]))[0], 0xFFFFFFFF);
      final q = newProject(w: 200, h: 100);
      run(q, {'op': 'add_layer', 'type': 'solid', 'id': 'r', 'color': '#FF0000', 'start': 0, 'duration': 5});
      run(q, {'op': 'add_effect', 'layer': 'r', 'effect': 'slant_wipe', 'params': {'progress': 50, 'angle': 0, 'side': 'left'}});
      final px = await pixels(tester, q, 1, [[30, 50], [170, 50]]);
      expect(px[0], 0xFFFF0000);
      expect((px[1] >> 16) & 0xFF, lessThan(40));
    });

    testWidgets('every V3 op and effect paints without errors', (tester) async {
      final p = newProject(w: 640, h: 360);
      for (int i = 0; i < 3; i++) {
        p.media['m$i'] = MediaAsset(id: 'm$i', type: MediaType.image, path: '/nonexistent/$i.png', name: 'p$i', width: 1600, height: 900);
      }
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'color': '#406080', 'start': 0, 'duration': 10});
      run(p, {'op': 'add_layer', 'type': 'shape', 'id': 'man', 'kind': 'rect', 'width': 100, 'height': 200, 'position': [420, 200, 0], 'fill': '#C08050', 'start': 0, 'duration': 10});
      run(p, {'op': 'mood_flood', 'at': 1, 'keep': ['man'], 'sfx': false});
      run(p, {'op': 'tint_wipe', 'at': 4.5, 'duration': 0.5, 'hold': 0.5});
      run(p, {'op': 'grade_swap', 'to': 'hope', 'at': 6});
      run(p, {'op': 'spotlight_subject', 'keep': ['man'], 'start': 5, 'duration': 1, 'tint': {'amount': 60}});
      run(p, {'op': 'pulse', 'layer': 'man', 'start': 6, 'duration': 2});
      run(p, {'op': 'lightning', 'at': [7, 7.2], 'sfx': false});
      run(p, {'op': 'montage', 'media': ['m0', 'm1', 'm2'], 'start': 8, 'sound': false});
      run(p, {'op': 'cut_to_black', 'at': 9.5, 'hold': 0.4, 'sfx': false});
      run(p, {'op': 'add_component', 'type': 'speech_bubble', 'id': 'sb', 'start': 2, 'tail_to': 'man', 'exit': 'puff',
        'messages': [{'text': 'We are trapped', 'at': 0}, {'text': 'Help', 'at': 1}]});
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'fx', 'color': '#808080', 'width': 300, 'height': 200, 'start': 0, 'duration': 10});
      for (final e in [
        {'effect': 'radial_blur', 'params': {'amount': 50}},
        {'effect': 'holes', 'params': {'progress': 50}},
        {'effect': 'frost', 'params': {'progress': 60, 'corner': 'center'}},
        {'effect': 'cracks', 'params': {'progress': 70}},
        {'effect': 'red_paint'},
        {'effect': 'slices', 'params': {'progress': 40}},
        {'effect': 'slide_mount'},
        {'effect': 'burst', 'params': {'kind': 'ice', 'origin': 'center', 'cut': 2, 'pre_roll': 1}},
        for (final k in ['debris', 'snow_spray', 'ice']) {'effect': 'particles', 'params': {'kind': k}},
      ]) {
        run(p, {'op': 'add_effect', 'layer': 'fx', ...e});
      }
      for (final draft in [false, true]) {
        for (final t in [0.5, 1.4, 1.95, 2.3, 3.2, 4.8, 5.1, 6.2, 7.0, 7.05, 8.4, 9.6]) {
          await tester.pumpWidget(Directionality(
            textDirection: TextDirection.ltr,
            child: FittedBox(child: CompositionCanvas(project: p, time: t, draft: draft, playing: draft && t > 5)),
          ));
          expect(tester.takeException(), isNull, reason: '@$t draft=$draft');
        }
      }
    });

    testWidgets('every V3 transition paints with its options', (tester) async {
      final opts = <String, Map<String, dynamic>>{
        'powder_burst': {'kind': 'ash', 'direction': 'center'},
        'debris_burst': {'kind': 'leaves', 'from': 'bottom'},
        'frost_shatter': {'corner': 'bottom_right'},
        'zoom_blur': {'grain': true},
        'shatter': {'tone': 'gold'},
        'slant_wipe': {'direction': 'top'},
        'shrink_to_card': {'bg': 'none'},
      };
      for (final type in v3Types) {
        final p = twoShots(w: 480, h: 270);
        run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': type, 'params': opts[type] ?? const {}, 'sound': false});
        for (final t in [3.9, 4.7, 4.98, 5.02, 5.4, 6.0]) {
          await tester.pumpWidget(Directionality(
            textDirection: TextDirection.ltr,
            child: FittedBox(child: CompositionCanvas(project: p, time: t)),
          ));
          expect(tester.takeException(), isNull, reason: '$type @$t');
        }
      }
    });
  });
}

/// The created helper layers of a transition (tr_*), for quick sanity checks.
List<Layer> helperLayers(Project p) => [for (final l in p.main.layers) if (l.id.startsWith('tr_')) l];
