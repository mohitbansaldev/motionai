import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/commands/shot_commands.dart';
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/scene3d.dart';
import 'package:motionai/core/presets/shots.dart';
import 'package:motionai/core/presets/templates.dart';
import 'package:motionai/core/presets/transition_registry.dart';

const double kW = 1920, kH = 1080;

Project project({double duration = 30}) {
  final p = Project(id: 'p', name: 'Tulips', main: Composition(id: 'main', name: 'Main', width: kW, height: kH, fps: 30, duration: duration));
  void m(String id, double w, double h) => p.media[id] = MediaAsset(id: id, type: MediaType.image, path: '/$id.png', name: id, width: w, height: h);
  m('plate', 1920, 1080);
  m('person', 600, 1200);
  m('house', 900, 700);
  m('castle', 800, 900);
  m('heap', 1600, 800);
  m('plant', 500, 1100);
  m('dirt', 1024, 1024);
  return p;
}

CommandResult run(Project p, Map<String, dynamic> c, {double now = 0}) => EditCommands.runAtomic(p, c, now: now);

List<Map<String, dynamic>> tulipLayers() => [
      {'media': 'castle', 'role': 'far', 'id': 'castle'},
      {'media': 'house', 'role': 'mid', 'id': 'house'},
      {'media': 'person', 'role': 'mid', 'id': 'man', 'hero': true},
      {'media': 'heap', 'role': 'front', 'id': 'gold'},
    ];

Map<String, dynamic> shot({String? id, double? start, double duration = 6, String? style, dynamic camera}) => {
      'op': 'add_shot', 'id': ?id, 'start': ?start, 'duration': duration, 'style': ?style, 'camera': ?camera,
      'plate': 'plate', 'layers': tulipLayers(),
    };

List<double> box(Composition comp, String id, double t) => Scene3D.screenBox(comp, [comp.requireLayer(id)], t)!;

List<double> times(double dur, [int n = 24]) => [for (int i = 0; i <= n; i++) (dur * i / n).clamp(0.0, dur - 1e-3).toDouble()];

void main() {
  group('default layer timing', () {
    test('no start and no duration: 0 → the whole comp (not the playhead)', () {
      final p = project();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 's'}, now: 4);
      final l = p.main.requireLayer('s');
      expect(l.start, 0);
      expect(l.duration, closeTo(30, 1e-9));
      run(p, {'op': 'add_layer', 'type': 'image', 'media': 'person', 'id': 'i'}, now: 7);
      expect(p.main.requireLayer('i').start, 0);
      expect(p.main.requireLayer('i').end, closeTo(30, 1e-9));
    });

    test('only a start keeps the 5 s still; explicit values win', () {
      final p = project();
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'Hi', 'start': 2});
      expect(p.main.requireLayer('t').duration, closeTo(5, 1e-9));
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 'u', 'text': 'Hi', 'duration': 3});
      expect(p.main.requireLayer('u').start, 0);
      expect(p.main.requireLayer('u').duration, closeTo(3, 1e-9));
    });

    test('inside a precomp the layer spans the precomp', () {
      final p = project();
      run(p, {'op': 'add_comp', 'id': 'C', 'duration': 7});
      run(p, {'op': 'add_layer', 'in_comp': 'C', 'type': 'solid', 'id': 's'});
      expect(p.comps['C']!.requireLayer('s').duration, closeTo(7, 1e-9));
    });

    test('components: start 0; set components span the comp, pop-ups 5 s', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'tv_frame', 'id': 'tv'}, now: 3);
      expect(p.main.requireLayer('tv_g').start, 0);
      expect(p.main.requireLayer('tv_g').duration, closeTo(30, 1e-9));
      run(p, {'op': 'add_component', 'type': 'lower_third', 'id': 'lt', 'source': 'BBC', 'text': 'Hello'}, now: 3);
      expect(p.main.requireLayer('lt_g').start, 0);
      expect(p.main.requireLayer('lt_g').duration, closeTo(5, 1e-9));
      run(p, {'op': 'add_component', 'type': 'lower_third', 'id': 'lt2', 'start': 9, 'source': 'BBC', 'text': 'Hello'});
      expect(p.main.requireLayer('lt2_g').start, 9);
    });

    test('project templates no longer go black before their end', () {
      final t = Templates.all.first;
      final p = Project(id: 'q', name: 'T', main: Composition(id: 'main', name: 'Main', width: t.width, height: t.height, duration: t.duration));
      run(p, {'op': 'batch', 'commands': t.commands(t.width, t.height)});
      expect(p.main.requireLayer('bg').end, closeTo(t.duration, 1e-9));
    });
  });

  group('smart scale helpers', () {
    test('sizes by role are aspect-aware', () {
      final man = ShotRoles.size('mid', 600, 1200, kW, kH);
      expect(man.h / kH, inInclusiveRange(0.55, 0.70));
      final plant = ShotRoles.size('front', 500, 1100, kW, kH);
      expect(plant.h / kH, lessThanOrEqualTo(ShotRoles.maxFront + 1e-9));
      final heap = ShotRoles.size('front', 1600, 800, kW, kH);
      expect(heap.h / kH, lessThanOrEqualTo(0.45));
      expect(heap.w / kW, lessThanOrEqualTo(0.6 + 1e-9));
      final house = ShotRoles.size('mid', 3000, 700, kW, kH);
      expect(house.w / kW, lessThanOrEqualTo(0.7 + 1e-9));
      final far = ShotRoles.size('far', 800, 900, kW, kH);
      expect(far.h / kH, inInclusiveRange(0.2, 0.32));
      expect(ShotRoles.size('mid', 600, 1200, kW, kH, height: 0.3).h, closeTo(0.3 * kH, 1e-9));
    });

    test('ground lines follow the perspective of one floor', () {
      expect(ShotRoles.groundLine('mid', 0.88), 0.88);
      expect(ShotRoles.groundLine('far', 0.88), closeTo(0.69, 1e-9));
      expect(ShotRoles.groundLine('near', 0.88), lessThanOrEqualTo(1.03));
      expect(ShotRoles.groundLine('front', 0.88), lessThanOrEqualTo(1.03));
    });
  });

  group('add_shot', () {
    test('one precomp + ONE comp layer in main; everything spans the shot', () {
      final p = project();
      final r = run(p, shot(id: 'tulip1'));
      expect(r.createdIds.first, 'tulip1');
      expect(p.comps['tulip1'], isNotNull);
      expect(p.main.layers.where((l) => l.type == LayerType.comp).length, 1);
      final cl = p.main.requireLayer('tulip1');
      expect(cl.compId, 'tulip1');
      expect(cl.start, 0);
      expect(cl.duration, closeTo(6, 1e-9));
      final comp = p.comps['tulip1']!;
      expect(comp.duration, closeTo(6, 1e-9));
      for (final l in comp.layers) {
        if (l.type == LayerType.text) continue;
        expect(l.start, 0, reason: l.id);
        expect(l.end, greaterThanOrEqualTo(6 - 1e-9), reason: '${l.id} must not end mid-shot');
      }
      expect(comp.layerById('castle_shadow'), isNotNull);
      expect(comp.layerById('man_shadow'), isNotNull);
      expect(comp.layerById('gold_shadow'), isNull, reason: 'front objects are not grounded');
      expect(comp.layerById('tulip1_floor'), isNotNull);
      expect(p.seqShots['tulip1']['hero'], 'man');
    });

    test('sizes by role and bottoms on the ground line (static camera)', () {
      final p = project();
      run(p, shot(id: 's', camera: 'none'));
      final comp = p.comps['s']!;
      final man = box(comp, 'man', 0), gold = box(comp, 'gold', 0), castle = box(comp, 'castle', 0);
      expect((man[3] - man[1]) / kH, inInclusiveRange(0.55, 0.70));
      expect((gold[3] - gold[1]) / kH, lessThanOrEqualTo(0.45 + 1e-3));
      expect((castle[3] - castle[1]) / kH, inInclusiveRange(0.2, 0.32));
      expect(man[3], closeTo(0.88 * kH, 12));
      expect(castle[3], closeTo(0.69 * kH, 12));
      expect(gold[3], closeTo(1.03 * kH, 3));
      // In the world, every grounded cut-out stands on the same floor plane.
      final floorY = ShotGeometry.floorY(comp, 0.88);
      for (final id in ['castle', 'house', 'man']) {
        expect(ShotGeometry.bottomOf(comp, comp.requireLayer(id), 0), closeTo(floorY, 0.5), reason: id);
        expect(comp.requireLayer(id).is3D, isTrue);
      }
    });

    test('camera move: no empty edges, never touches a layer, floor always drawn', () {
      final p = project();
      run(p, shot(id: 's'));
      final comp = p.comps['s']!;
      final plate = comp.requireLayer('s_plate');
      expect(comp.camera.allKeyframeTimes(), isNotEmpty);
      for (final t in times(6)) {
        expect(ShotGeometry.covers(comp, plate, t), isTrue, reason: 'empty edge at $t');
        expect(Scene3D.nearestLayerDistance(comp, t), greaterThanOrEqualTo(kNearPlane), reason: 'too close at $t');
        final ids = Evaluator.evaluate(comp, t).map((i) => i.layer.id).toSet();
        expect(ids, contains('s_floor'), reason: 'floor culled at $t');
        expect(ids, containsAll(['man', 'house', 'castle']), reason: 'cut-out missing at $t');
      }
      // The floor is painted behind every cut-out.
      final order = Evaluator.evaluate(comp, 3).map((i) => i.layer.id).toList();
      for (final id in ['castle', 'house', 'man', 'gold']) {
        if (order.contains(id)) expect(order.indexOf('s_floor'), lessThan(order.indexOf(id)), reason: id);
      }
    });

    test('far layers stay visible over the mid band during the move', () {
      final p = project();
      run(p, {
        'op': 'add_shot', 'id': 's', 'plate': 'plate', 'duration': 5,
        'layers': [
          {'media': 'castle', 'role': 'far', 'id': 'castle', 'x': 0.5},
          {'media': 'person', 'role': 'mid', 'id': 'man', 'x': 0.5},
        ],
        'camera': [
          {'move': 'fly_to', 'target': 'man', 'start': 0, 'duration': 5, 'intensity': 0.9},
        ],
      });
      final comp = p.comps['s']!;
      final margin = kH * 0.03;
      final b0 = box(comp, 'castle', 0), m0 = box(comp, 'man', 0);
      final base = (b0[1] - (m0[1] - margin)).clamp(0.0, double.infinity);
      for (final t in times(5, 16)) {
        final c = box(comp, 'castle', t), m = box(comp, 'man', t);
        final overlap = (c[2] < m[2] ? c[2] : m[2]) - (c[0] > m[0] ? c[0] : m[0]);
        if (overlap <= (c[2] - c[0]) * 0.15) continue;
        expect(c[1] - (m[1] - margin), lessThanOrEqualTo(base + 2), reason: 'castle sinks behind the man at $t');
      }
      final off = project();
      run(off, {
        'op': 'add_shot', 'id': 's', 'plate': 'plate', 'duration': 5, 'keep_far_visible': false,
        'layers': [
          {'media': 'castle', 'role': 'far', 'id': 'castle', 'x': 0.5},
          {'media': 'person', 'role': 'mid', 'id': 'man', 'x': 0.5},
        ],
        'camera': [
          {'move': 'fly_to', 'target': 'man', 'start': 0, 'duration': 5, 'intensity': 0.9},
        ],
      });
      final sOn = p.comps['s']!.requireLayer('castle').prop(Props.scale).staticValue[1];
      final sOff = off.comps['s']!.requireLayer('castle').prop(Props.scale).staticValue[1];
      expect(sOn, greaterThan(sOff), reason: 'the far castle was grown to stay visible');
    });

    test('default start is the end of the last shot; main grows to fit', () {
      final p = project(duration: 10);
      run(p, shot(id: 'a'));
      run(p, shot(id: 'b', duration: 5));
      expect(p.main.requireLayer('b').start, closeTo(6, 1e-9));
      expect(p.main.duration, greaterThanOrEqualTo(11 - 1e-9));
      expect(ShotCommands.lastShotEnd(p), closeTo(11, 1e-9));
    });

    test('title, caption, atmosphere, look and a floor texture', () {
      final p = project();
      run(p, {
        ...shot(id: 's'),
        'title': {'text': 'TULIP MANIA', 'subtitle': 'Amsterdam, 1637'},
        'caption': 'Holland, 1637',
        'atmosphere': {'dust': 40, 'haze': 30},
        'look': 'retro_film',
        'ground': 'dirt',
      });
      final comp = p.comps['s']!;
      expect(comp.requireLayer('s_title').text!.text, 'TULIP MANIA');
      expect(comp.requireLayer('s_subtitle').text!.text, 'Amsterdam, 1637');
      expect(comp.requireLayer('s_caption').text!.text, 'Holland, 1637');
      expect(comp.requireLayer('s_atmo_dust').effects.single.type, 'particles');
      expect(comp.layerById('s_atmo_haze'), isNotNull);
      expect(comp.requireLayer('s_floor').mediaId, 'dirt');
      expect(p.main.requireLayer('s').effects.map((e) => e.id), contains('s_style_tint'));
    });

    test('bad input: nothing changes (one atomic step) and undo restores exactly', () {
      final p = project();
      final before = ProjectSnapshot.take(p);
      expect(() => run(p, {...shot(id: 's'), 'layers': [{'media': 'nope'}]}), throwsA(isA<CommandError>()));
      expect(ProjectSnapshot.take(p), before);
      expect(() => run(p, {...shot(id: 's'), 'style': 'wobbly'}), throwsA(isA<CommandError>()));
      expect(ProjectSnapshot.take(p), before);
      run(p, shot(id: 's'));
      expect(p.seqShots, contains('s'));
      ProjectSnapshot.restore(p, before);
      expect(ProjectSnapshot.take(p), before);
      expect(p.comps, isEmpty);
      expect(p.seqShots, isEmpty);
    });

    test('shots survive save/load and show in the summary', () {
      final p = project();
      run(p, shot(id: 's', style: 'character_focus'));
      final back = Project.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.seqShots.keys, ['s']);
      final sum = ShotCommands.summary(back);
      expect(sum.single['id'], 's');
      expect(sum.single['style'], 'character_focus');
      expect(sum.single['hero'], 'man');
    });

    test('every built-in style builds with its camera, atmosphere and look', () {
      for (final st in ShotStyles.all) {
        final p = project();
        run(p, shot(id: 's', style: st.id));
        final cam = p.seqShots['s']['camera'] as List;
        expect(cam.length, st.camera.length, reason: st.id);
        final comp = p.comps['s']!;
        for (final k in st.atmosphere.keys) {
          expect(comp.layerById('s_atmo_$k'), isNotNull, reason: '${st.id} $k');
        }
        expect(p.main.requireLayer('s').effects.any((e) => e.id.startsWith('s_style_')), isTrue, reason: st.id);
        for (final t in times(6, 12)) {
          expect(ShotGeometry.covers(comp, comp.requireLayer('s_plate'), t), isTrue, reason: '${st.id} at $t');
        }
      }
    });
  });

  group('sequence', () {
    test('back to back with an overlap for each transition', () {
      final p = project();
      run(p, {
        'op': 'sequence',
        'shots': [
          {...shot(id: 'a', duration: 5)}..remove('op'),
          {...shot(id: 'b', duration: 6)}..remove('op'),
          {...shot(id: 'c', duration: 4)}..remove('op'),
        ],
        'transitions': [
          {'between': [0, 1], 'type': 'flash', 'duration': 0.5},
          {'between': [1, 2], 'type': 'cut'},
        ],
      });
      final a = p.main.requireLayer('a'), b = p.main.requireLayer('b'), c = p.main.requireLayer('c');
      expect(a.start, closeTo(0, 1e-9));
      expect(b.start, closeTo(4.5, 1e-9));
      expect(c.start, closeTo(10.5, 1e-9));
      expect(c.end, closeTo(14.5, 1e-9));
      expect(b.effects.map((e) => e.id), contains('b_in_flash'));
      expect(c.effects.where((e) => e.id.contains('_in_')), isEmpty);
      expect(p.main.indexOf('c'), lessThan(p.main.indexOf('b')), reason: 'later shots on top');
    });

    test('registered transitions are called; unknown ones are an error', () {
      final calls = <String>[];
      TransitionRegistry.addRegistrar((register) {
        register('test_slide', (Composition comp, Layer out, Layer inc, Map<String, dynamic> params) {
          calls.add('${out.id}>${inc.id}:${params['duration']}:${params['overlap']}');
        });
      });
      expect(TransitionRegistry.has('test_slide'), isTrue);
      final p = project();
      run(p, {
        'op': 'sequence', 'transition': 'test_slide', 'transition_duration': 0.8,
        'shots': [
          {'id': 'a', 'plate': 'plate', 'duration': 4},
          {'id': 'b', 'plate': 'plate', 'duration': 4},
        ],
      });
      expect(calls, ['a>b:0.8:0.8']);
      expect(p.main.requireLayer('b').start, closeTo(3.2, 1e-9));
      TransitionRegistry.unregister('test_slide');

      final q = project();
      final before = ProjectSnapshot.take(q);
      expect(
        () => run(q, {'op': 'sequence', 'transition': 'teleport_9000', 'shots': [{'plate': 'plate'}, {'plate': 'plate'}]}),
        throwsA(isA<CommandError>()),
      );
      expect(ProjectSnapshot.take(q), before);
    });

    test('fallback presets on the incoming shot', () {
      expect(ShotCommands.fallbackPreset('ink'), 'ink');
      expect(ShotCommands.fallbackPreset('dissolve'), 'fade');
      expect(ShotCommands.fallbackPreset('nope'), isNull);
      final p = project();
      run(p, {'op': 'sequence', 'transition': 'ink', 'shots': [{'id': 'a', 'plate': 'plate'}, {'id': 'b', 'plate': 'plate'}]});
      expect(p.main.requireLayer('b').effects.map((e) => e.id), contains('b_in_reveal'));
    });
  });

  group('update_shot / remove_shot', () {
    test('update keeps the id, rebuilds and can ripple', () {
      final p = project();
      run(p, shot(id: 'a'));
      run(p, shot(id: 'b'));
      run(p, {'op': 'update_shot', 'shot': 'a', 'duration': 8, 'ripple': true, 'style': 'crowd_pass'});
      expect(p.comps['a']!.duration, closeTo(8, 1e-9));
      expect(p.main.requireLayer('a').duration, closeTo(8, 1e-9));
      expect(p.main.requireLayer('b').start, closeTo(8, 1e-9));
      expect((p.seqShots['a']['camera'] as List).first['move'], 'pass_by');
      expect(p.main.layers.where((l) => l.type == LayerType.comp).length, 2);
    });

    test('remove deletes precomp + comp layer and closes the gap', () {
      final p = project();
      run(p, shot(id: 'a'));
      run(p, shot(id: 'b', duration: 4));
      run(p, {'op': 'remove_shot', 'shot': 'a', 'ripple': true});
      expect(p.comps.containsKey('a'), isFalse);
      expect(p.main.layerById('a'), isNull);
      expect(p.seqShots.containsKey('a'), isFalse);
      expect(p.main.requireLayer('b').start, closeTo(0, 1e-9));
      expect(() => run(p, {'op': 'remove_shot', 'shot': 'a'}), throwsA(isA<CommandError>()));
    });
  });
}
