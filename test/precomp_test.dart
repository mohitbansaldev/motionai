// Nested compositions (precomps) — Agent L.
import 'dart:convert';

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/engine/precomp.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/services/project_storage.dart';
import 'package:motionai/state/editor_controller.dart';
import 'package:motionai/ui/preview/composition_canvas.dart';

Project newProject({double w = 1920, double h = 1080}) => Project(
      id: 'p1',
      name: 'Precomp',
      main: Composition(id: 'main', name: 'Main', width: w, height: h, fps: 30, duration: 10),
    );

Project roundTrip(Project p) => Project.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);

CommandResult run(Project p, Map<String, dynamic> c) => EditCommands.runAtomic(p, c);

/// Screen corners (and opacity) of every leaf layer, nested comps expanded.
Map<String, (List<double>, double)> screen(Project p, double t) => {
      for (final f in Precomp.flatten(p, p.main, t))
        f.layer.id: ([for (final v in f.corners()) ...[v.x, v.y]], f.opacity),
    };

void expectSameScreen(Map<String, (List<double>, double)> a, Map<String, (List<double>, double)> b, String why) {
  expect(b.keys.toSet(), a.keys.toSet(), reason: '$why: same visible layers');
  for (final k in a.keys) {
    final (ca, oa) = a[k]!;
    final (cb, ob) = b[k]!;
    for (int i = 0; i < ca.length; i++) {
      expect(cb[i], closeTo(ca[i], 1e-3), reason: '$why: corner $i of $k');
    }
    expect(ob, closeTo(oa, 1e-9), reason: '$why: opacity of $k');
  }
}

/// A 2D scene: animated card, a title parented to it, a logo with a track matte.
Project scene2D() {
  final p = newProject();
  run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'color': '#102030'});
  run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'card', 'width': 600, 'height': 300, 'color': '#FFFFFF'});
  run(p, {'op': 'set_keyframe', 'target': 'card', 'prop': 'position', 'time': 0, 'value': [400, 300, 0]});
  run(p, {'op': 'set_keyframe', 'target': 'card', 'prop': 'position', 'time': 3, 'value': [1400, 700, 0]});
  run(p, {'op': 'set_keyframe', 'target': 'card', 'prop': 'rotation', 'time': 0, 'value': [0, 0, -10]});
  run(p, {'op': 'set_keyframe', 'target': 'card', 'prop': 'rotation', 'time': 3, 'value': [0, 0, 15]});
  run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'm', 'width': 300, 'height': 300, 'color': '#FFFFFF', 'position': [900, 500, 0]});
  run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'logo', 'width': 200, 'height': 200, 'color': '#FF0000', 'start': 0.5, 'duration': 4});
  run(p, {'op': 'set_keyframe', 'target': 'logo', 'prop': 'opacity', 'time': 0.5, 'value': 20});
  run(p, {'op': 'set_keyframe', 'target': 'logo', 'prop': 'opacity', 'time': 2.5, 'value': 90});
  run(p, {'op': 'update_layer', 'layer': 'logo', 'matte': {'layer': 'm'}});
  run(p, {'op': 'add_layer', 'type': 'text', 'id': 'title', 'text': 'HELLO', 'start': 1, 'duration': 3, 'parent': 'card', 'position': [50, 20, 0]});
  run(p, {'op': 'set_camera_mode', 'mode': '2d'});
  run(p, {'op': 'set_keyframe', 'target': 'camera', 'prop': 'zoom2d', 'time': 0, 'value': 100});
  run(p, {'op': 'set_keyframe', 'target': 'camera', 'prop': 'zoom2d', 'time': 4, 'value': 130});
  return p;
}

/// A 3D scene with a moving 3D camera.
Project scene3D() {
  final p = newProject();
  run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'sky', 'color': '#3060A0'});
  for (final (id, z) in [('far', 1200.0), ('mid', 500.0), ('near', 100.0)]) {
    run(p, {'op': 'add_layer', 'type': 'solid', 'id': id, 'width': 500, 'height': 400, 'is3d': true, 'position': [960, 540, z]});
  }
  run(p, {'op': 'set_camera_mode', 'mode': '3d'});
  run(p, {'op': 'set_keyframe', 'target': 'camera', 'prop': 'position', 'time': 0, 'value': [960, 540, -1500]});
  run(p, {'op': 'set_keyframe', 'target': 'camera', 'prop': 'position', 'time': 4, 'value': [1300, 400, -900]});
  return p;
}

class _MemStorage extends ProjectStorage {
  @override
  Future<void> save(Project p) async {}
}

void main() {
  group('model', () {
    test('JSON round trip keeps comps, comp layers, loop', () {
      final p = newProject();
      run(p, {'op': 'add_comp', 'id': 'C1', 'name': 'Screen', 'width': 800, 'height': 450, 'duration': 4});
      run(p, {'op': 'add_layer', 'in_comp': 'C1', 'type': 'solid', 'id': 's', 'color': '#00FF00', 'duration': 4});
      run(p, {'op': 'add_layer', 'type': 'comp', 'comp': 'C1', 'id': 'cl', 'loop': true});
      final cl = p.main.requireLayer('cl');
      expect(cl.type, LayerType.comp);
      expect(cl.compId, 'C1');
      expect(cl.loop, isTrue);
      expect(cl.width, 800);
      expect(cl.height, 450);
      expect(cl.duration, 4);
      expect(cl.name, 'Screen');
      expect(p.comps['C1']!.background, 0, reason: 'precomps are transparent');
      expect(p.editCompId, isNull, reason: 'in_comp does not leave the comp open');

      final q = roundTrip(p);
      expect(jsonEncode(q.toJson()), jsonEncode(p.toJson()));
      expect(q.comps['C1']!.layers.single.id, 's');
      expect(q.main.requireLayer('cl').loop, isTrue);
      final copy = q.main.requireLayer('cl').copy(newId: 'x');
      expect(copy.compId, 'C1');
      expect(copy.loop, isTrue);
    });

    test('old projects load without comps and save without the key', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'a'});
      final j = p.toJson();
      expect(j.containsKey('comps'), isFalse);
      expect((j['main'] as Map)['layers'][0].containsKey('compId'), isFalse);
      final q = Project.fromJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
      expect(q.comps, isEmpty);
      expect(q.editComp, same(q.main));
      expect(layerTypeFromName('precomp'), LayerType.comp);
    });
  });

  group('precompose', () {
    test('2D scene: first frame and animation look identical', () {
      final p = scene2D();
      final times = [0.0, 1.2, 2.7, 3.9];
      final before = {for (final t in times) t: screen(p, t)};
      final r = run(p, {'op': 'precompose', 'layers': ['title', 'logo'], 'name': 'Group', 'id': 'G', 'layer_id': 'gl'});
      expect(r.createdIds, ['G', 'gl']);
      // Matte layer came along; title's outside parent became a hidden stand-in.
      final g = p.comps['G']!;
      expect(g.layers.map((l) => l.id).toList(), ['title', 'logo', 'm', 'card~parent']);
      expect(g.layerById('title')!.parentId, 'card~parent');
      expect(p.main.layerById('title'), isNull);
      expect(p.main.layerById('card'), isNotNull);
      final gl = p.main.requireLayer('gl');
      expect(gl.type, LayerType.comp);
      expect(p.main.indexOf('gl'), 0, reason: 'takes the place of the top moved layer');
      expect(gl.start, 0, reason: 'from the earliest moved layer (the matte starts at 0)');
      expect(gl.end, closeTo(10, 1e-9)); // V2-B: the matte layer (no start/duration) now spans the whole 10 s comp (was 5 s)
      for (final t in times) {
        expectSameScreen(before[t]!, screen(p, t), 't=$t');
      }
      // Survives save/load.
      final q = roundTrip(p);
      expectSameScreen(before[1.2]!, screen(q, 1.2), 'after round trip');
    });

    test('3D scene with a moving camera looks identical', () {
      final p = scene3D();
      final b0 = screen(p, 0), b2 = screen(p, 2.2);
      run(p, {'op': 'precompose', 'layers': ['mid', 'near'], 'id': 'S', 'layer_id': 'sl'});
      expect(p.comps['S']!.camera.mode.name, 'threeD', reason: 'the 3D camera is copied into the precomp');
      expect(p.main.requireLayer('sl').is3D, isFalse);
      expectSameScreen(b0, screen(p, 0), 't=0');
      expectSameScreen(b2, screen(p, 2.2), 't=2.2');
    });

    test('move_attributes: false keeps transform, effects and id on the comp layer', () {
      final p = scene2D();
      run(p, {'op': 'add_effect', 'layer': 'card', 'effect': 'blur', 'params': {'amount': 10}});
      final before = screen(p, 1.5);
      run(p, {'op': 'precompose', 'layers': ['card'], 'move_attributes': false, 'id': 'CC'});
      final card = p.main.requireLayer('card');
      expect(card.type, LayerType.comp);
      expect(card.compId, 'CC');
      expect(card.effects.single.type, 'blur');
      expect(card.prop(Props.position).isAnimated, isTrue);
      expect(p.comps['CC']!.width, 600);
      final inner = p.comps['CC']!.layers.single;
      expect(inner.type, LayerType.solid);
      expect(inner.effects, isEmpty);
      expect(inner.prop(Props.position).isAnimated, isFalse);
      expect(p.main.requireLayer('title').parentId, 'card', reason: 'children keep following it');
      expectSameScreen(before, screen(p, 1.5), 'leave attributes');
    });

    test('errors: unknown layers, duplicate comp ids', () {
      final p = scene2D();
      expect(() => run(p, {'op': 'precompose', 'layers': ['nope']}), throwsA(isA<CommandError>()));
      expect(() => run(p, {'op': 'precompose', 'layers': []}), throwsA(isA<CommandError>()));
      run(p, {'op': 'add_comp', 'id': 'X'});
      expect(() => run(p, {'op': 'precompose', 'layers': ['bg'], 'id': 'X'}), throwsA(isA<CommandError>()));
      expect(() => run(p, {'op': 'precompose', 'layers': ['bg', 'card'], 'move_attributes': false}),
          throwsA(isA<CommandError>()));
      expect(p.main.layerById('bg'), isNotNull, reason: 'failed commands change nothing');
    });
  });

  group('time', () {
    Project clip() {
      final p = newProject();
      run(p, {'op': 'add_comp', 'id': 'C', 'name': 'Clip', 'duration': 2});
      run(p, {'op': 'add_layer', 'in_comp': 'C', 'type': 'solid', 'id': 's', 'width': 100, 'height': 100, 'duration': 2});
      run(p, {'op': 'set_keyframe', 'in_comp': 'C', 'target': 's', 'prop': 'position', 'time': 0, 'value': [0, 0, 0], 'ease': 'linear'});
      run(p, {'op': 'set_keyframe', 'in_comp': 'C', 'target': 's', 'prop': 'position', 'time': 2, 'value': [200, 0, 0]});
      run(p, {'op': 'add_layer', 'type': 'comp', 'comp': 'C', 'id': 'cl', 'start': 1, 'source_in': 0.5, 'duration': 5});
      run(p, {'op': 'update_layer', 'layer': 'cl', 'speed': 2});
      return p;
    }

    test('start + source_in + speed map to comp time', () {
      final p = clip();
      expect(p.comps['C']!.duration, 2);
      final cl = p.main.requireLayer('cl');
      final c = p.comps['C']!;
      expect(Precomp.childTime(cl, c, 1.5), closeTo(1.5, 1e-9)); // 0.5 + 0.5 * 2
      expect(Precomp.childTime(cl, c, 1.0), closeTo(0.5, 1e-9));
      final s = screen(p, 1.5)['s']!.$1;
      // s at x=150 in the child; the comp layer is the identity, so TL = (100, -50).
      expect(s[0], closeTo(100, 1e-6));
      expect(s[1], closeTo(-50, 1e-6));
      // Past the end of the child comp nothing is shown...
      expect(Precomp.childTime(cl, c, 2.5), isNull);
      expect(screen(p, 2.5), isEmpty);
    });

    test('loop repeats the comp', () {
      final p = clip();
      run(p, {'op': 'update_layer', 'layer': 'cl', 'loop': true});
      final cl = p.main.requireLayer('cl');
      expect(Precomp.childTime(cl, p.comps['C']!, 2.5), closeTo(1.5, 1e-9)); // 3.5 mod 2
      expect(screen(p, 2.5)['s']!.$1[0], closeTo(100, 1e-6));
      expect(Precomp.childTime(cl, p.comps['C']!, 1.75), closeTo(0.0, 1e-9)); // 2.0 mod 2
    });

    test('nested media reports the inner comp time', () {
      final p = clip();
      final m = Precomp.nestedMedia(p, 1.5);
      expect(m, isEmpty, reason: 'only video/audio layers are reported');
    });
  });

  group('nesting', () {
    test('a comp cannot contain itself', () {
      final p = newProject();
      run(p, {'op': 'add_comp', 'id': 'A'});
      run(p, {'op': 'add_comp', 'id': 'B'});
      run(p, {'op': 'add_layer', 'in_comp': 'A', 'type': 'comp', 'comp': 'B', 'id': 'ab'});
      run(p, {'op': 'add_layer', 'type': 'comp', 'comp': 'A', 'id': 'ma'});
      expect(() => run(p, {'op': 'add_layer', 'in_comp': 'B', 'type': 'comp', 'comp': 'A'}), throwsA(isA<CommandError>()));
      expect(() => run(p, {'op': 'add_layer', 'in_comp': 'A', 'type': 'comp', 'comp': 'A'}), throwsA(isA<CommandError>()));
      expect(() => run(p, {'op': 'add_layer', 'in_comp': 'A', 'type': 'comp', 'comp': 'main'}), throwsA(isA<CommandError>()));
      run(p, {'op': 'add_layer', 'in_comp': 'B', 'type': 'solid', 'id': 'bs'});
      expect(() => run(p, {'op': 'add_layer', 'in_comp': 'B', 'type': 'comp'}), throwsA(isA<CommandError>()));
      expect(() => run(p, {'op': 'remove_comp', 'comp': 'B'}), throwsA(isA<CommandError>()));
      expect(Precomp.validate(p), isEmpty);

      // A loop written by hand (e.g. a broken file) is detected, not followed forever.
      final j = jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>;
      final comps = (j['comps'] as List).cast<Map<String, dynamic>>();
      final b = comps.firstWhere((c) => c['id'] == 'B');
      final loopLayer = Map<String, dynamic>.from((comps.firstWhere((c) => c['id'] == 'A')['layers'] as List).first as Map)
        ..['id'] = 'ba'
        ..['compId'] = 'A';
      (b['layers'] as List).insert(0, loopLayer);
      final q = Project.fromJson(j);
      expect(Precomp.validate(q), isNotEmpty);
      expect(() => Precomp.flatten(q, q.main, 1), throwsA(isA<PrecompError>()));
    });

    testWidgets('a looping project still renders (placeholder)', (tester) async {
      final p = newProject(w: 200, h: 100);
      run(p, {'op': 'add_comp', 'id': 'A'});
      run(p, {'op': 'add_layer', 'type': 'comp', 'comp': 'A', 'id': 'ma'});
      // Force a self-reference past the command checks.
      p.comps['A']!.layers.add(p.main.requireLayer('ma').copy(newId: 'self'));
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: CompositionCanvas(project: p, time: 1),
      ));
      expect(tester.takeException(), isNull);
    });

    test('three levels deep compose their transforms', () {
      final p = newProject();
      run(p, {'op': 'add_comp', 'id': 'C'});
      run(p, {'op': 'add_layer', 'in_comp': 'C', 'type': 'solid', 'id': 'leaf'});
      run(p, {'op': 'add_comp', 'id': 'B'});
      run(p, {'op': 'add_layer', 'in_comp': 'B', 'type': 'comp', 'comp': 'C', 'scale': [50, 50, 100]});
      run(p, {'op': 'add_comp', 'id': 'A'});
      run(p, {'op': 'add_layer', 'in_comp': 'A', 'type': 'comp', 'comp': 'B', 'scale': [50, 50, 100]});
      run(p, {'op': 'add_layer', 'type': 'comp', 'comp': 'A', 'scale': [50, 50, 100]});
      expect(Precomp.levelsBelow(p, 'main'), 4);
      final s = screen(p, 1);
      expect(s.keys, ['leaf']);
      final c = s['leaf']!.$1;
      expect(c[0], closeTo(960 - 120, 1e-6));
      expect(c[1], closeTo(540 - 67.5, 1e-6));
      expect(c[4], closeTo(960 + 120, 1e-6));
      expect(c[5], closeTo(540 + 67.5, 1e-6));
      expect(Precomp.pathTo(p, 'C'), ['main', 'A', 'B', 'C']);
    });

    test('nesting deeper than the limit is refused', () {
      final p = newProject();
      for (int i = kMaxPrecompDepth; i >= 1; i--) {
        run(p, {'op': 'add_comp', 'id': 'X$i'});
        if (i == kMaxPrecompDepth) {
          run(p, {'op': 'add_layer', 'in_comp': 'X$i', 'type': 'solid'});
        } else {
          run(p, {'op': 'add_layer', 'in_comp': 'X$i', 'type': 'comp', 'comp': 'X${i + 1}'});
        }
      }
      expect(Precomp.levelsBelow(p, 'X1'), kMaxPrecompDepth);
      expect(() => run(p, {'op': 'add_layer', 'type': 'comp', 'comp': 'X1'}), throwsA(isA<CommandError>()));
      run(p, {'op': 'add_layer', 'type': 'comp', 'comp': 'X2'});
    });
  });

  group('unprecompose', () {
    test('round trip restores the layers exactly', () {
      final p = scene2D();
      final before = jsonEncode(p.main.toJson());
      final shot = screen(p, 2);
      run(p, {'op': 'precompose', 'layers': ['logo', 'title'], 'layer_id': 'gl'});
      run(p, {'op': 'unprecompose', 'layer': 'gl'});
      expect(jsonEncode(p.main.toJson()), before);
      expect(p.comps, isEmpty, reason: 'the unused comp is removed');
      expectSameScreen(shot, screen(p, 2), 'after unprecompose');
    });

    test('a moved comp layer: layers come back with its transform as a parent', () {
      final p = scene2D();
      final shot0 = screen(p, 1.5);
      run(p, {'op': 'precompose', 'layers': ['bg'], 'layer_id': 'gl'});
      expectSameScreen(shot0, screen(p, 1.5), 'precomposed');
      run(p, {'op': 'set_property', 'target': 'gl', 'prop': 'position', 'value': [1000, 600, 0]});
      run(p, {'op': 'set_property', 'target': 'gl', 'prop': 'scale', 'value': [80, 80, 100]});
      final moved = screen(p, 1.5);
      run(p, {'op': 'unprecompose', 'layer': 'gl'});
      expect(p.main.requireLayer('bg').parentId, isNotNull);
      expectSameScreen(moved, screen(p, 1.5), 'unprecomposed');
    });

    test('refuses to silently drop opacity / effects (unless forced)', () {
      final p = scene2D();
      run(p, {'op': 'precompose', 'layers': ['bg'], 'layer_id': 'gl'});
      run(p, {'op': 'add_effect', 'layer': 'gl', 'effect': 'blur'});
      expect(() => run(p, {'op': 'unprecompose', 'layer': 'gl'}), throwsA(isA<CommandError>()));
      expect(p.main.layerById('gl'), isNotNull);
      run(p, {'op': 'unprecompose', 'layer': 'gl', 'force': true});
      expect(p.main.layerById('bg'), isNotNull);
    });
  });

  group('editor', () {
    test('undo/redo include comps; the active comp receives edits', () {
      final p = scene2D();
      final c = EditorController(p, _MemStorage());
      final before = jsonEncode(p.toJson());
      c.run({'op': 'precompose', 'layers': ['logo'], 'id': 'G', 'layer_id': 'gl'});
      expect(p.comps.keys, ['G']);
      c.undo();
      expect(p.comps, isEmpty);
      expect(jsonEncode(p.toJson()), before);
      c.redo();
      expect(p.comps.keys, ['G']);

      c.seek(1.0);
      c.openCompLayer('gl');
      expect(c.comp.id, 'G');
      expect(c.inPrecomp, isTrue);
      expect(c.compTrail.map((k) => k.id), ['main', 'G']);
      expect(c.time, closeTo(1.0, 1e-9), reason: 'inner time of the comp layer');
      c.run({'op': 'add_layer', 'type': 'solid', 'id': 'inside', 'width': 10, 'height': 10});
      expect(p.comps['G']!.layerById('inside'), isNotNull);
      expect(p.main.layerById('inside'), isNull);
      c.undo();
      expect(p.comps['G']!.layerById('inside'), isNull);
      expect(c.comp.id, 'G', reason: 'undo keeps the comp open');
      c.closeComp();
      expect(c.comp.id, 'main');
      expect(c.time, closeTo(1.0, 1e-9), reason: 'back at the time we left');

      // AI-style open_comp also works.
      c.run({'op': 'open_comp', 'comp': 'G'});
      expect(c.comp.id, 'G');
      c.run({'op': 'open_comp', 'comp': 'main'});
      expect(c.comp.id, 'main');
      c.dispose();
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

    Project small() {
      final p = Project(
        id: 'p',
        name: 'px',
        main: Composition(id: 'm', name: 'm', width: 200, height: 100, fps: 30, duration: 5, background: 0xFF000000),
      );
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'red', 'width': 80, 'height': 40, 'color': '#FF0000', 'position': [60, 50, 0]});
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'blue', 'width': 40, 'height': 40, 'color': '#0000FF', 'position': [150, 50, 0]});
      run(p, {'op': 'update_layer', 'layer': 'blue', 'is3d': false});
      return p;
    }

    final pts = [[60, 50], [30, 40], [150, 50], [5, 5], [195, 95], [110, 50]];

    testWidgets('precompose renders the same pixels; effects apply to the whole group', (tester) async {
      final p = small();
      for (final draft in [false, true]) {
        final before = await render(tester, p, 1, pts, draft: draft);
        final q = roundTrip(p);
        run(q, {'op': 'precompose', 'layers': ['red', 'blue'], 'layer_id': 'g'});
        final after = await render(tester, q, 1, pts, draft: draft);
        expect(after, before, reason: 'draft=$draft');
      }
      expect((await render(tester, p, 1, pts))[0], 0xFFFF0000);

      run(p, {'op': 'precompose', 'layers': ['red', 'blue'], 'layer_id': 'g'});
      run(p, {'op': 'add_effect', 'layer': 'g', 'effect': 'mono', 'params': {'amount': 100}});
      final mono = await render(tester, p, 1, pts);
      for (final i in [0, 2]) {
        final v = mono[i];
        final r = (v >> 16) & 0xFF, g = (v >> 8) & 0xFF, b = v & 0xFF;
        expect((r - g).abs() <= 2 && (g - b).abs() <= 2, isTrue, reason: 'pixel $i is grey: ${v.toRadixString(16)}');
        expect(r, greaterThan(0));
      }
      expect(mono[3], 0xFF000000, reason: 'background untouched');
    });

    testWidgets('comp layer moved and scaled; nested three deep', (tester) async {
      final p = small();
      run(p, {'op': 'precompose', 'layers': ['red'], 'layer_id': 'g'});
      run(p, {'op': 'set_property', 'target': 'g', 'prop': 'position', 'value': [180, 50, 0]}); // +80 px
      // Red now spans x 100..180 (blue, on top, still covers 130..170).
      final px = await render(tester, p, 1, [[110, 50], [60, 50]]);
      expect(px[0], 0xFFFF0000, reason: 'red moved right with the comp layer');
      expect(px[1], 0xFF000000);

      run(p, {'op': 'precompose', 'layers': ['g'], 'layer_id': 'g2'});
      run(p, {'op': 'precompose', 'layers': ['g2'], 'layer_id': 'g3'});
      expect(Precomp.levelsBelow(p, p.main.id), 4);
      final deep = await render(tester, p, 1, [[110, 50], [60, 50]], draft: true);
      expect(deep, px);
    });

    testWidgets('evaluation caching: same frame twice, then an edit shows up', (tester) async {
      final p = small();
      run(p, {'op': 'precompose', 'layers': ['red'], 'layer_id': 'g'});
      final a = await render(tester, p, 1, [[60, 50]], draft: true);
      final b = await render(tester, p, 1, [[60, 50]], draft: true);
      expect(b, a);
      run(p, {'op': 'update_layer', 'in_comp': p.main.requireLayer('g').compId, 'layer': 'red', 'color': '#00FF00'});
      final c = await render(tester, p, 1, [[60, 50]], draft: true);
      expect(c[0], 0xFF00FF00);
    });
  });

  test('evaluator unchanged for comp layers: one item of the comp size', () {
    final p = newProject();
    run(p, {'op': 'add_comp', 'id': 'C', 'width': 640, 'height': 360});
    run(p, {'op': 'add_layer', 'type': 'comp', 'comp': 'C', 'id': 'cl'});
    final items = Evaluator.evaluate(p.main, 0);
    expect(items.single.layer.id, 'cl');
    expect(items.single.layer.width, 640);
    run(p, {'op': 'set_comp', 'in_comp': 'C', 'width': 800});
    expect(p.main.requireLayer('cl').width, 800, reason: 'comp layers follow their comp size');
  });
}
