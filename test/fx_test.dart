import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/engine/fx_math.dart';
import 'package:motionai/core/model/effects_catalog.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/motion_presets.dart';
import 'package:motionai/ui/preview/composition_canvas.dart';

Project newProject() => Project(
      id: 'p1',
      name: 'FX',
      main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: 10),
    );

Project roundTrip(Project p) => Project.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);

void run(Project p, Map<String, dynamic> c) => EditCommands.runAtomic(p, c);

void main() {
  group('serialisation', () {
    test('matte, path, extrude and motionBlur round-trip', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'm', 'width': 400, 'height': 400});
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'HELLO', 'animator': 'scramble'});
      run(p, {
        'op': 'update_layer',
        'layer': 't',
        'matte': {'layer': 'm', 'mode': 'inverse'},
        'path': {'points': [[0, 0], [500, 200], [900, 0]], 'smooth': true, 'orient': true},
        'extrude': {'depth': 18, 'color': '#404040'},
      });
      run(p, {'op': 'set_comp', 'motion_blur': true});
      final q = roundTrip(p);
      final t = q.main.requireLayer('t');
      expect(t.matte, const LayerMatte('m', mode: 'inverse'));
      expect(t.path!.points.length, 3);
      expect(t.path!.points[1], [500.0, 200.0]);
      expect(t.path!.orient, isTrue);
      expect(t.path!.smooth, isTrue);
      expect(t.props.containsKey(Props.pathProgress), isTrue);
      expect(t.text!.extrude, 18);
      expect(t.text!.extrudeColor, 0xFF404040);
      expect(t.text!.animator, 'scramble');
      expect(q.main.motionBlur, isTrue);
      // copy keeps it too
      final c = t.copy(newId: 'c');
      expect(c.matte, t.matte);
      expect(c.path!.points, t.path!.points);
    });

    test('old projects without the new fields still load', () {
      final old = {
        'id': 'L1',
        'name': 'Old',
        'type': 'text',
        'start': 0,
        'duration': 3,
        'width': 100,
        'height': 50,
        'text': {'text': 'Hi'},
      };
      final l = Layer.fromJson(old);
      expect(l.matte, isNull);
      expect(l.path, isNull);
      expect(l.text!.extrude, 0);
      expect(l.props.containsKey(Props.pathProgress), isFalse);
      final j = l.toJson();
      expect(j.containsKey('matte'), isFalse);
      expect(j.containsKey('path'), isFalse);
      expect((j['text'] as Map).containsKey('extrude'), isFalse);
      final comp = Composition.fromJson({'id': 'c', 'width': 100, 'height': 100});
      expect(comp.motionBlur, isFalse);
      expect(comp.toJson().containsKey('motionBlur'), isFalse);
    });

    test('removing matte and path', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'm', 'width': 100, 'height': 100});
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'a', 'width': 100, 'height': 100, 'matte': 'm'});
      final a = p.main.requireLayer('a');
      expect(a.matte!.layerId, 'm');
      expect(a.matte!.inverse, isFalse);
      run(p, {'op': 'update_layer', 'layer': 'a', 'path': {'from': [100, 100], 'to': [300, 100]}});
      expect(a.path, isNotNull);
      run(p, {'op': 'update_layer', 'layer': 'a', 'matte': 'none', 'path': 'none'});
      expect(a.matte, isNull);
      expect(a.path, isNull);
      // Layer stays where it was on the path (progress 0 = start point).
      expect(a.prop(Props.position).staticValue.sublist(0, 2), [100.0, 100.0]);
    });

    test('bad matte commands are rejected', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'a', 'width': 100, 'height': 100});
      expect(() => run(p, {'op': 'update_layer', 'layer': 'a', 'matte': 'a'}), throwsA(isA<CommandError>()));
      expect(() => run(p, {'op': 'update_layer', 'layer': 'a', 'matte': 'nope'}), throwsA(isA<CommandError>()));
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'b', 'width': 100, 'height': 100});
      expect(() => run(p, {'op': 'update_layer', 'layer': 'a', 'matte': {'layer': 'b', 'mode': 'luma'}}),
          throwsA(isA<CommandError>()));
      expect(p.main.requireLayer('a').matte, isNull);
    });
  });

  group('motion path', () {
    test('line: arc-length sampling and angle', () {
      final m = MotionPath(points: [[0, 0], [100, 0], [100, 100]], smooth: false);
      expect(m.length, closeTo(200, 1e-9));
      final a = m.sample(0.25);
      expect(a.x, closeTo(50, 1e-9));
      expect(a.y, closeTo(0, 1e-9));
      expect(a.angle, closeTo(0, 1e-9));
      final b = m.sample(0.75);
      expect(b.x, closeTo(100, 1e-9));
      expect(b.y, closeTo(50, 1e-9));
      expect(b.angle, closeTo(90, 1e-9));
      expect(m.sample(-1).x, 0);
      expect(m.sample(2).y, 100);
    });

    test('smooth path passes through its points', () {
      final m = MotionPath(points: [[0, 0], [200, 100], [400, 0]]);
      expect(m.sample(0).x, closeTo(0, 1e-9));
      expect(m.sample(1).x, closeTo(400, 1e-9));
      // Symmetric curve: halfway along is the middle point.
      final mid = m.sample(0.5);
      expect(mid.x, closeTo(200, 0.5));
      expect(mid.y, closeTo(100, 0.5));
      expect(m.length, greaterThan(400));
    });

    test('arc preset and its params', () {
      final arc = MotionPath.arc([0, 500], [1000, 500], 200);
      final ap = arc.arcParams!;
      expect(ap.a, [0.0, 500.0]);
      expect(ap.b, [1000.0, 500.0]);
      expect(ap.bend, closeTo(200, 1e-9));
      // Positive bend bows upward (screen y down) for a left→right path.
      expect(arc.sample(0.5).y, lessThan(500));
      expect(MotionPath.arc([0, 0], [10, 0], 0).points.length, 2);
    });

    test('evaluator follows the path at path_progress (+ position offset, orient)', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 's', 'width': 100, 'height': 100});
      run(p, {'op': 'update_layer', 'layer': 's', 'path': {'points': [[100, 100], [100, 500]], 'orient': true}});
      final l = p.main.requireLayer('s');
      // Offset was reset so the layer sits on the path.
      expect(l.prop(Props.position).staticValue.sublist(0, 2), [0.0, 0.0]);
      run(p, {'op': 'set_keyframe', 'target': 's', 'prop': 'path_progress', 'time': 0, 'value': 0, 'ease': 'linear'});
      run(p, {'op': 'set_keyframe', 'target': 's', 'prop': 'path_progress', 'time': 2, 'value': 100});
      final it = Evaluator.evaluate(p.main, 1).single;
      final c = it.project(50, 50);
      expect(c.x, closeTo(100, 1e-6));
      expect(c.y, closeTo(300, 1e-6));
      // Auto-orient: moving down = rotated 90°, so the layer's +x axis points down.
      final right = it.project(100, 50);
      expect(right.x, closeTo(100, 1e-6));
      expect(right.y, closeTo(350, 1e-6));
      // Position acts as an offset.
      run(p, {'op': 'set_property', 'target': 's', 'prop': 'position', 'value': [10, 0, 0]});
      final c2 = Evaluator.evaluate(p.main, 1).single.project(50, 50);
      expect(c2.x, closeTo(110, 1e-6));
    });
  });

  group('particles', () {
    test('deterministic and time-driven for every kind', () {
      for (int kind = 0; kind < kParticleKinds.length; kind++) {
        final n = ParticleSim.countFor(kind, 60);
        expect(n, greaterThan(0));
        final a = Float64List(n * kParticleStride), b = Float64List(n * kParticleStride), c = Float64List(n * kParticleStride);
        ParticleSim.simulate(kind: kind, count: n, t: 1.25, w: 1920, h: 1080, out: a, seed: 9, speed: 1.3, direction: 20);
        ParticleSim.simulate(kind: kind, count: n, t: 1.25, w: 1920, h: 1080, out: b, seed: 9, speed: 1.3, direction: 20);
        ParticleSim.simulate(kind: kind, count: n, t: 2.5, w: 1920, h: 1080, out: c, seed: 9, speed: 1.3, direction: 20);
        expect(a, b, reason: kParticleKinds[kind]);
        expect(a.every((v) => v.isFinite), isTrue, reason: kParticleKinds[kind]);
        var moved = false;
        for (int i = 0; i < n && !moved; i++) {
          final o = i * kParticleStride;
          if ((a[o] - c[o]).abs() > 1e-6 || (a[o + 1] - c[o + 1]).abs() > 1e-6 || (a[o + 4] - c[o + 4]).abs() > 1e-6) {
            moved = true;
          }
        }
        expect(moved, isTrue, reason: '${kParticleKinds[kind]} should animate');
      }
    });

    test('amount scales the count; zero draws nothing', () {
      expect(ParticleSim.countFor(PKind.snow, 0), 0);
      expect(ParticleSim.countFor(PKind.snow, 100), greaterThan(ParticleSim.countFor(PKind.snow, 20)));
    });

    test('effect params accept names and hex colours', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 's'});
      run(p, {
        'op': 'add_effect',
        'layer': 's',
        'effect': 'particles',
        'id': 'fx1',
        'params': {'kind': 'snow', 'color': '#FFC107', 'amount': 80},
      });
      final e = p.main.requireLayer('s').effectById('fx1')!;
      expect(e.params['kind']!.staticValue, [4.0]);
      expect(e.params['color']!.staticValue, [255.0, 193.0, 7.0]);
      expect(e.params['amount']!.staticValue, [80.0]);
      run(p, {'op': 'set_effect_param', 'layer': 's', 'effect': 'fx1', 'param': 'kind', 'value': 'birds'});
      expect(e.params['kind']!.staticValue, [9.0]);
      expect(() => run(p, {'op': 'set_effect_param', 'layer': 's', 'effect': 'fx1', 'param': 'kind', 'value': 'lava'}),
          throwsA(isA<CommandError>()));
      run(p, {'op': 'add_effect', 'layer': 's', 'effect': 'torn_edge', 'id': 'te', 'params': {'side': 'left'}});
      expect(p.main.requireLayer('s').effectById('te')!.params['side']!.staticValue, [2.0]);
      run(p, {'op': 'add_effect', 'layer': 's', 'effect': 'reveal', 'id': 'rv', 'params': {'kind': 'ink', 'progress': 30}});
      expect(p.main.requireLayer('s').effectById('rv')!.params['kind']!.staticValue, [1.0]);
    });
  });

  group('text fx', () {
    test('scramble settles left to right and keeps spaces', () {
      const text = 'TOP SECRET 1996';
      final start = TextFx.scrambleText(text, 0.01, 1.0, seed: 3);
      expect(start.length, text.length);
      expect(start, isNot(text));
      expect(start[3], ' ');
      expect(start[10], ' ');
      // Digits scramble to digits.
      for (int i = 11; i < 15; i++) {
        expect('0123456789'.contains(start[i]), isTrue);
      }
      expect(TextFx.scrambleText(text, 1.0, 1.0, seed: 3), text);
      expect(TextFx.scrambleText(text, 0.6, 1.0, seed: 3), TextFx.scrambleText(text, 0.6, 1.0, seed: 3));
      final mid = TextFx.scrambleText(text, 0.6, 1.0, seed: 3);
      // First letters already settled, last not yet.
      expect(mid.substring(0, 3), 'TOP');
      expect(TextFx.scrambleSettle(0, 15, 1.0), lessThan(TextFx.scrambleSettle(14, 15, 1.0)));
    });

    test('random pop order is a stable permutation', () {
      final o = TextFx.popOrder(12, 5);
      expect(o.toSet().length, 12);
      expect(o, TextFx.popOrder(12, 5));
      expect(o, isNot(List.generate(12, (i) => i)));
      for (int i = 0; i < 12; i++) {
        expect(TextFx.randomPopProgress(i, 12, 0.8, 0.8, 5), 1.0);
        expect(TextFx.randomPopProgress(i, 12, -0.1, 0.8, 5), 0.0);
      }
    });

    test('animators and extrude via commands', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'VIRAL', 'animator': 'random_pop', 'extrude': 14});
      final t = p.main.requireLayer('t').text!;
      expect(t.animator, 'random_pop');
      expect(t.extrude, 14);
      run(p, {'op': 'update_layer', 'layer': 't', 'extrude': 'none'});
      expect(t.extrude, 0);
      expect(TextAnimators.all, containsAll(['random_pop', 'scramble']));
    });
  });

  group('matte + velocity in the evaluator', () {
    test('matte layer is hidden and attached to the matted item', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'width': 1920, 'height': 1080});
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'beam', 'width': 300, 'height': 300});
      run(p, {'op': 'update_layer', 'layer': 'bg', 'matte': {'layer': 'beam'}});
      final items = Evaluator.evaluate(p.main, 1);
      expect(items.map((i) => i.layer.id), ['bg']);
      expect(items.single.matte!.layer.id, 'beam');
      expect(items.single.matteInverse, isFalse);
      // Matte layer not active → alpha matte shows nothing; inverse shows all.
      run(p, {'op': 'trim_layer', 'layer': 'beam', 'out': 0.5});
      expect(Evaluator.evaluate(p.main, 1), isEmpty);
      run(p, {'op': 'update_layer', 'layer': 'bg', 'matte': {'layer': 'beam', 'mode': 'inverse'}});
      final inv = Evaluator.evaluate(p.main, 1);
      expect(inv.single.layer.id, 'bg');
      expect(inv.single.matte, isNull);
      // Deleting the matte layer leaves the layer drawn normally.
      run(p, {'op': 'remove_layer', 'layer': 'beam'});
      expect(Evaluator.evaluate(p.main, 1).single.layer.id, 'bg');
    });

    test('screen velocity for motion blur', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 's', 'width': 100, 'height': 100});
      run(p, {'op': 'set_keyframe', 'target': 's', 'prop': 'position', 'time': 0, 'value': [0, 500, 0], 'ease': 'linear'});
      run(p, {'op': 'set_keyframe', 'target': 's', 'prop': 'position', 'time': 2, 'value': [600, 500, 0]});
      var it = Evaluator.evaluate(p.main, 1).single;
      expect(it.vx, 0); // off by default
      run(p, {'op': 'set_comp', 'motion_blur': true});
      it = Evaluator.evaluate(p.main, 1).single;
      expect(it.vx, closeTo(10, 1e-6)); // 300 px/s at 30 fps
      expect(it.vy, closeTo(0, 1e-6));
      expect(it.speed, closeTo(10, 1e-6));
      run(p, {'op': 'set_comp', 'motion_blur': false});
      run(p, {'op': 'add_effect', 'layer': 's', 'effect': 'motion_blur'});
      expect(Evaluator.evaluate(p.main, 1).single.vx, closeTo(10, 1e-6));
    });

    test('3D camera move gives velocity too', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 's', 'width': 400, 'height': 400, 'is3d': true});
      run(p, {'op': 'set_comp', 'motion_blur': true});
      run(p, {'op': 'set_camera_mode', 'mode': '3d'});
      final cam = p.main.camera.prop('position').valueAt(0);
      final poi = p.main.camera.prop('poi').valueAt(0);
      run(p, {'op': 'set_keyframe', 'target': 'camera', 'prop': 'position', 'time': 0, 'value': cam, 'ease': 'linear'});
      run(p, {'op': 'set_keyframe', 'target': 'camera', 'prop': 'position', 'time': 1, 'value': [cam[0] + 900, cam[1], cam[2]]});
      run(p, {'op': 'set_keyframe', 'target': 'camera', 'prop': 'poi', 'time': 0, 'value': poi, 'ease': 'linear'});
      run(p, {'op': 'set_keyframe', 'target': 'camera', 'prop': 'poi', 'time': 1, 'value': [poi[0] + 900, poi[1], poi[2]]});
      final it = Evaluator.evaluate(p.main, 0.5).single;
      expect(it.vx, lessThan(-5)); // camera moves right → layer slides left
    });
  });

  group('catalog + transitions', () {
    test('every contract effect exists with defaults', () {
      const names = [
        'silhouette', 'mono', 'duotone', 'edge_blur', 'curve', 'glass_frame', 'torn_edge', 'particles',
        'light_rays', 'sway', 'reveal', 'motion_blur',
      ];
      for (final n in names) {
        final e = EffectsCatalog.create(n, 'x');
        expect(e.params, isNotEmpty, reason: n);
      }
      expect(EffectsCatalog.paramDef('particles', 'kind')!.options, kParticleKinds);
      expect(EffectsCatalog.paramDef('reveal', 'kind')!.options, ['iris', 'ink', 'smoke', 'wipe']);
      for (final d in EffectsCatalog.all) {
        expect(EffectsCatalog.categories, contains(d.category), reason: d.type);
      }
    });

    test('new transitions add keyframed effects', () {
      for (final t in ['iris', 'ink', 'smoke', 'spin', 'flash', 'glitch_flash']) {
        expect(MotionPresets.transitions, contains(t));
        final p = newProject();
        run(p, {'op': 'add_layer', 'type': 'text', 'id': 'a', 'text': 'Hi', 'start': 1, 'duration': 4});
        run(p, {'op': 'animate_in', 'layer': 'a', 'preset': t, 'duration': 0.6});
        run(p, {'op': 'animate_out', 'layer': 'a', 'preset': t, 'duration': 0.6});
        final l = p.main.requireLayer('a');
        if (t == 'iris' || t == 'ink' || t == 'smoke') {
          final rin = l.effectById('a_in_reveal')!;
          expect(rin.params['progress']!.valueAt(1), [0.0]);
          expect(rin.params['progress']!.valueAt(1.6), [100.0]);
          final rout = l.effectById('a_out_reveal')!;
          expect(rout.params['progress']!.valueAt(5), [0.0]);
        }
        if (t == 'flash' || t == 'glitch_flash') {
          final f = l.effectById('a_in_flash')!;
          expect(f.params['amount']!.valueAt(1), [100.0]);
          expect(f.params['amount']!.valueAt(1.6), [0.0]);
        }
        if (t == 'glitch_flash') {
          final g = l.effectById('a_in_glitch')!.params['amount']!;
          expect(g.keyframes.length, greaterThan(3));
          expect(g.valueAt(1.6), [0.0]);
        }
        // Survives a save/load.
        roundTrip(p);
      }
    });

    test('colour matrices', () {
      final m = FxColor.duotone([10, 20, 30], [250, 200, 100], 1);
      // black → dark, white → light (offsets are 0..255)
      expect(m[4], closeTo(10, 1e-9));
      expect(m[0] * 255 + m[1] * 255 + m[2] * 255 + m[4], closeTo(250, 1e-6));
      final mono = FxColor.mono(1);
      expect(mono[0], closeTo(mono[5], 1e-12));
      expect(FxColor.mono(0), [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0]);
    });

    test('curve warp keeps the board edges and bulges the centre', () {
      final out = [0.0, 0.0];
      Warp.curve(0, 0, 1000, 500, 60, out);
      expect(out[0], closeTo(0, 1e-6));
      Warp.curve(1000, 250, 1000, 500, 60, out);
      expect(out[0], closeTo(1000, 1e-6));
      Warp.curve(500, 0, 1000, 500, 60, out);
      final centreTop = out[1];
      Warp.curve(0, 0, 1000, 500, 60, out);
      final edgeTop = out[1];
      expect(centreTop, lessThan(edgeTop)); // centre taller than edges
      Warp.curve(300, 100, 1000, 500, 0, out);
      expect(out, [300.0, 100.0]);
      expect(Warp.sway(10, 500, 100, 500, 50, 1, 0.7, 1), 0); // bottom pinned
    });
  });

  group('render smoke test', () {
    testWidgets('every new effect, matte and text fx paints without errors', (tester) async {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'width': 1920, 'height': 1080, 'color': '#203040'});
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'beam', 'width': 600, 'height': 600, 'color': '#FFFFFF'});
      run(p, {'op': 'update_layer', 'layer': 'bg', 'matte': {'layer': 'beam', 'mode': 'alpha'}});
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 'pop', 'text': 'VIRAL 3D', 'animator': 'random_pop', 'extrude': 10});
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 'scr', 'text': 'SECRET 1996', 'animator': 'scramble', 'outline': 3});
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'fx', 'width': 800, 'height': 450, 'color': '#808080'});
      for (final e in [
        {'effect': 'silhouette'},
        {'effect': 'mono'},
        {'effect': 'duotone'},
        {'effect': 'edge_blur'},
        {'effect': 'curve', 'params': {'bend': 50}},
        {'effect': 'sway'},
        {'effect': 'glass_frame'},
        {'effect': 'torn_edge'},
        for (final k in kParticleKinds) {'effect': 'particles', 'params': {'kind': k}},
        {'effect': 'light_rays'},
        {'effect': 'reveal', 'params': {'kind': 'ink', 'progress': 40}},
        {'effect': 'reveal', 'params': {'kind': 'smoke', 'progress': 60}},
        {'effect': 'reveal', 'params': {'kind': 'iris', 'progress': 70}},
        {'effect': 'reveal', 'params': {'kind': 'wipe', 'progress': 80}},
        {'effect': 'flash', 'params': {'amount': 30}},
        {'effect': 'glitch', 'params': {'amount': 100}},
        {'effect': 'motion_blur'},
      ]) {
        run(p, {'op': 'add_effect', 'layer': 'fx', ...e});
      }
      run(p, {'op': 'set_keyframe', 'target': 'fx', 'prop': 'position', 'time': 0, 'value': [0, 500, 0], 'ease': 'linear'});
      run(p, {'op': 'set_keyframe', 'target': 'fx', 'prop': 'position', 'time': 2, 'value': [1500, 500, 0]});
      run(p, {'op': 'update_layer', 'layer': 'pop', 'path': {'from': [200, 800], 'to': [1600, 800], 'bend': 200}});
      for (final draft in [false, true]) {
        for (final t in [0.3, 1.0]) {
          await tester.pumpWidget(Directionality(
            textDirection: TextDirection.ltr,
            child: FittedBox(child: CompositionCanvas(project: p, time: t, draft: draft)),
          ));
          expect(tester.takeException(), isNull);
        }
      }
    });
  });

  group('render pixels', () {
    Future<List<int>> render(WidgetTester tester, Project p, double t, List<List<int>> at, {bool draft = false}) async {
      final key = GlobalKey();
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(key: key, child: CompositionCanvas(project: p, time: t, draft: draft)),
        ),
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

    Project small() => Project(
          id: 'p',
          name: 'px',
          main: Composition(id: 'm', name: 'm', width: 200, height: 100, fps: 30, duration: 5, background: 0xFF000000),
        );

    testWidgets('alpha and inverse track matte', (tester) async {
      final p = small();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'red', 'width': 200, 'height': 100, 'color': '#FF0000'});
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'hole', 'width': 40, 'height': 40, 'color': '#FFFFFF', 'position': [100, 50, 0]});
      run(p, {'op': 'update_layer', 'layer': 'red', 'matte': {'layer': 'hole'}});
      for (final draft in [false, true]) {
        final px = await render(tester, p, 1, [[100, 50], [10, 10], [190, 90]], draft: draft);
        expect(px[0], 0xFFFF0000, reason: 'inside the matte shows the layer');
        expect(px[1], 0xFF000000, reason: 'outside shows the background');
        expect(px[2], 0xFF000000);
      }
      run(p, {'op': 'update_layer', 'layer': 'red', 'matte': {'layer': 'hole', 'mode': 'inverse'}});
      final inv = await render(tester, p, 1, [[100, 50], [10, 10]]);
      expect(inv[0], 0xFF000000);
      expect(inv[1], 0xFFFF0000);
    });

    testWidgets('curve mesh warp draws the layer bent', (tester) async {
      final p = small();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'g', 'width': 160, 'height': 80, 'color': '#00FF00', 'position': [100, 50, 0]});
      run(p, {'op': 'add_effect', 'layer': 'g', 'effect': 'curve', 'params': {'bend': 100}});
      final px = await render(tester, p, 1, [[100, 50], [100, 12], [21, 12], [21, 50], [100, 5]]);
      expect(px[0], 0xFF00FF00, reason: 'centre is drawn');
      expect(px[1], 0xFF00FF00, reason: 'convex centre keeps its full height');
      expect(px[2], 0xFF000000, reason: 'edges recede (shorter)');
      expect(px[3], 0xFF00FF00, reason: 'width is kept');
      expect(px[4], 0xFF000000);
    });

    testWidgets('reveal iris hides the outside', (tester) async {
      final p = small();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'w', 'width': 200, 'height': 100, 'color': '#FFFFFF'});
      run(p, {'op': 'add_effect', 'layer': 'w', 'effect': 'reveal', 'params': {'kind': 'iris', 'progress': 20, 'softness': 0}});
      final px = await render(tester, p, 1, [[100, 50], [5, 5]]);
      expect(px[0], 0xFFFFFFFF);
      expect(px[1], 0xFF000000);
    });

    testWidgets('mono and duotone', (tester) async {
      final p = small();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'r', 'width': 200, 'height': 100, 'color': '#FF0000'});
      run(p, {'op': 'add_effect', 'layer': 'r', 'effect': 'duotone', 'params': {'dark': '#000000', 'light': '#00FF00'}});
      final px = await render(tester, p, 1, [[100, 50]]);
      // red luminance 0.2126 → 21% green
      expect((px[0] >> 16) & 0xFF, 0);
      expect((px[0] >> 8) & 0xFF, closeTo(54, 3));
    });
    testWidgets('particles draw sprites; motion blur smears a fast layer', (tester) async {
      final p = small();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'sky', 'width': 200, 'height': 100, 'color': '#000000'});
      run(p, {'op': 'add_effect', 'layer': 'sky', 'effect': 'particles', 'params': {'kind': 'snow', 'amount': 100}});
      final pts = [for (int y = 2; y < 100; y += 4) for (int x = 2; x < 200; x += 4) [x, y]];
      final px = await render(tester, p, 1.5, pts);
      final lit = px.where((v) => (v & 0xFFFFFF) != 0).length;
      expect(lit, greaterThan(5), reason: 'snow flakes visible');

      final q = small();
      run(q, {'op': 'add_layer', 'type': 'solid', 'id': 'box', 'width': 40, 'height': 40, 'color': '#FFFFFF'});
      run(q, {'op': 'set_keyframe', 'target': 'box', 'prop': 'position', 'time': 0, 'value': [0, 50, 0], 'ease': 'linear'});
      run(q, {'op': 'set_keyframe', 'target': 'box', 'prop': 'position', 'time': 1, 'value': [1800, 50, 0]});
      // At t=1/18 s the box is centred at x=100 (box spans 80..120), moving 60 px/frame.
      const t = 1 / 18;
      final sharp = await render(tester, q, t, [[74, 50], [100, 50]]);
      expect(sharp[0] & 0xFFFFFF, 0);
      run(q, {'op': 'set_comp', 'motion_blur': true});
      final blurred = await render(tester, q, t, [[74, 50], [100, 50], [100, 25]]);
      expect((blurred[0] >> 16) & 0xFF, greaterThan(20), reason: 'smeared beyond the edge along x');
      expect(blurred[2] & 0xFFFFFF, lessThan(0x101010), reason: 'no vertical smear for horizontal motion');
    });
  });
}
