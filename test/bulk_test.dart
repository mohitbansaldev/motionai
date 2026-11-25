// Multi-selection and bulk operations — Agent N.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/core/commands/bulk_commands.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/services/project_storage.dart';
import 'package:motionai/state/editor_controller.dart';
import 'package:motionai/ui/bulk/bulk_actions.dart';

class _MemStorage extends ProjectStorage {
  @override
  Future<void> save(Project p) async {}
}

Project newProject() => Project(
      id: 'p1',
      name: 'Bulk',
      main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: 10),
    );

void run(Project p, Map<String, dynamic> c) => EditCommands.runAtomic(p, c);

/// Solids s0..s(n-1), 100×100, at x = 200 + 300·i, y = 300 + 50·i, start i·0.5.
Project solids(int n) {
  final p = newProject();
  for (int i = n - 1; i >= 0; i--) {
    run(p, {
      'op': 'add_layer',
      'type': 'solid',
      'id': 's$i',
      'name': 'Solid $i',
      'width': 100,
      'height': 100,
      'color': '#FF0000',
      'position': [200 + 300.0 * i, 300 + 50.0 * i, 0],
      'start': i * 0.5,
      'duration': 4,
    });
  }
  return p;
}

EditorController ctl(Project p) => EditorController(p, _MemStorage());

List<double> pos(Project p, String id) => p.editComp.layerById(id)!.prop(Props.position).staticValue;

/// Screen corners of every visible layer at [t].
Map<String, List<double>> screen(Composition comp, double t) => {
      for (final i in Evaluator.evaluate(comp, t)) i.layer.id: [for (final v in i.corners()) ...[v.x, v.y]],
    };

void expectSameScreen(Map<String, List<double>> a, Map<String, List<double>> b) {
  expect(b.keys.toSet(), a.keys.toSet());
  for (final k in a.keys) {
    for (int i = 0; i < a[k]!.length; i++) {
      expect(b[k]![i], closeTo(a[k]![i], 1e-6), reason: 'corner value $i of $k');
    }
  }
}

void main() {
  group('selection model', () {
    test('primary stays compatible; toggle, range, all, clear', () {
      final p = solids(5);
      final c = ctl(p);
      c.select('s1');
      expect(c.selectedLayerIds, ['s1']);
      expect(c.selectedLayer?.id, 's1');
      c.toggleSelect('s3');
      expect(c.selectedLayerIds, ['s1', 's3']);
      expect(c.selectedLayerId, 's3', reason: 'the clicked layer becomes primary');
      expect(c.hasMultiSelection, isTrue);
      c.toggleSelect('s3');
      expect(c.selectedLayerIds, ['s1']);
      expect(c.selectedLayerId, 's1');

      // Shift+click: range from the anchor in stacking order.
      c.select('s1');
      c.selectRange('s4');
      expect(c.selectedLayerIds.toSet(), {'s1', 's2', 's3', 's4'});
      expect(c.selectedLayerId, 's4');
      c.selectRange('s0'); // anchor still s1
      expect(c.selectedLayerIds.toSet(), {'s0', 's1'});

      c.selectAll();
      expect(c.selectionCount, 5);
      expect(c.selectedLayers.map((l) => l.id), ['s0', 's1', 's2', 's3', 's4'], reason: 'comp order');
      c.clearSelection();
      expect(c.selectionCount, 0);
      expect(c.selectedLayerId, isNull);

      // Plain select collapses a multi-selection.
      c.selectMany(['s0', 's2']);
      c.select('s4');
      expect(c.selectedLayerIds, ['s4']);
      c.selectCamera();
      expect(c.selectionCount, 0);
      c.dispose();
    });

    test('removed layers leave the selection; undo keeps ids that exist again', () {
      final p = solids(4);
      final c = ctl(p);
      c.selectMany(['s0', 's1', 's2'], primary: 's1');
      c.run({'op': 'remove_layer', 'layer': 's1'});
      expect(c.selectedLayerIds, ['s0', 's2']);
      expect(c.selectedLayerId, 's2', reason: 'primary passes to the newest remaining');
      c.undo();
      expect(c.selectedLayerIds, ['s0', 's2'], reason: 'selection survives undo');
      c.selectMany(['s0', 's3']);
      c.run({'op': 'add_layer', 'type': 'solid', 'id': 'new'});
      c.selectMany(['new', 's0']);
      c.undo();
      expect(c.selectedLayerIds, ['s0'], reason: 'ids that no longer exist are dropped');
      c.dispose();
    });

    test('selection is per open comp', () {
      final p = solids(3);
      final c = ctl(p);
      c.run({'op': 'precompose', 'layers': ['s2'], 'id': 'G', 'layer_id': 'gl'});
      c.selectMany(['s0', 's1']);
      c.openCompLayer('gl');
      expect(c.comp.id, 'G');
      expect(c.selectionCount, 0);
      c.select('s2');
      c.selectAll();
      expect(c.selectedLayerIds, ['s2'], reason: 'Ctrl+A selects in the open comp only');
      c.closeComp();
      expect(c.selectedLayerIds, ['s0', 's1']);
      c.openComp('G');
      expect(c.selectedLayerIds, ['s2']);
      c.dispose();
    });
  });

  group('for_layers & select', () {
    test('expands placeholders per layer', () {
      final p = solids(3);
      final cmds = BulkCommands.expand(p, {
        'op': 'for_layers',
        'layers': ['s2', 's0'],
        'command': {'op': 'duplicate_layer', 'layer': r'$layer', 'new_id': r'$layer_copy', 'meta': [r'$index', r'$layer_start']},
      });
      expect(cmds.map((e) => e.$1), ['s2', 's0']);
      expect(cmds[0].$2, {'op': 'duplicate_layer', 'layer': 's2', 'new_id': 's2_copy', 'meta': [0, 1.0]});
      expect(cmds[1].$2['meta'], [1, 0.0]);
      run(p, {
        'op': 'for_layers',
        'layers': ['s2', 's0'],
        'command': {'op': 'duplicate_layer', 'layer': r'$layer', 'new_id': r'$layer_copy'},
      });
      expect(p.main.layerById('s2_copy'), isNotNull);
      expect(p.main.layerById('s0_copy'), isNotNull);
    });

    test('filters: type, name, is3d, in_range, visible; combined with ids', () {
      final p = solids(4);
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 't1', 'text': 'Hello', 'start': 6, 'duration': 2});
      run(p, {'op': 'update_layer', 'layer': 's1', 'is3d': true});
      run(p, {'op': 'update_layer', 'layer': 's3', 'visible': false});
      List<String> f(Map<String, dynamic> filter, [List<String>? ids]) =>
          BulkCommands.resolveLayers(p, {'op': 'select', 'filter': filter, 'layers': ?ids}, allowEmpty: true);
      expect(f({'type': 'text'}), ['t1']);
      expect(f({'type': ['text', 'solid']}).length, 5);
      expect(f({'name_contains': 'solid 2'}), ['s2']);
      expect(f({'is3d': true}), ['s1']);
      expect(f({'in_range': [5, 7]}), ['t1', 's3'], reason: 's3 ends at 5.5');
      expect(f({'in_range': [0, 0.6]}).toSet(), {'s0', 's1'}, reason: 's1 starts at 0.5');
      expect(f({'visible': false}), ['s3']);
      expect(f({'type': 'solid'}, ['t1', 's2']), ['s2']);
      expect(() => f({'colour': 'red'}), throwsA(isA<CommandError>()));
      expect(() => run(p, {'op': 'for_layers', 'filter': {'type': 'video'}, 'command': {'op': 'remove_layer', 'layer': r'$layer'}}),
          throwsA(isA<CommandError>()));
      // Filtered for_layers.
      run(p, {'op': 'for_layers', 'filter': {'type': 'solid', 'is3d': false}, 'command': {'op': 'update_layer', 'layer': r'$layer', 'is3d': true}});
      expect(p.main.layers.where((l) => l.type == LayerType.solid).every((l) => l.is3D), isTrue);
      expect(p.main.layerById('t1')!.is3D, isFalse);
    });

    test('a failing layer aborts everything unless skip_errors', () {
      final p = solids(3);
      final before = jsonEncode(p.toJson());
      // s0 spans 0..4, s2 spans 1..5: a split at 4.5 only fits s2.
      expect(() => run(p, {'op': 'for_layers', 'layers': ['s2', 's0'], 'command': {'op': 'split_layer', 'layer': r'$layer', 'time': 4.5}}),
          throwsA(isA<CommandError>()));
      expect(jsonEncode(p.toJson()), before);
      run(p, {'op': 'for_layers', 'layers': ['s2', 's0'], 'skip_errors': true, 'command': {'op': 'split_layer', 'layer': r'$layer', 'time': 4.5}});
      expect(p.main.layers.length, 4);
    });

    test('select op and "selection" layers through the editor; select is no undo step', () {
      final p = solids(4);
      final c = ctl(p);
      c.run({'op': 'select', 'filter': {'name_contains': 'solid'}, 'layers': ['s1', 's3']});
      expect(c.selectedLayerIds, ['s1', 's3']);
      expect(c.undoDepth, 0);
      c.run({'op': 'select', 'layers': ['s0'], 'mode': 'add'});
      expect(c.selectedLayerIds, ['s1', 's3', 's0']);
      c.run({'op': 'select', 'layers': ['s1'], 'mode': 'remove'});
      expect(c.selectedLayerIds, ['s3', 's0']);
      c.run({'op': 'for_layers', 'layers': 'selection', 'command': {'op': 'update_layer', 'layer': r'$layer', 'is3d': true}});
      expect(p.main.layers.where((l) => l.is3D).map((l) => l.id).toSet(), {'s0', 's3'});
      expect(c.undoDepth, 1);
      c.dispose();
    });
  });

  group('bulk ops are one undo step', () {
    late Project p;
    late EditorController c;
    late BulkActions a;
    setUp(() {
      p = solids(6);
      c = ctl(p);
      a = BulkActions(c);
    });
    tearDown(() => c.dispose());

    void oneStep(String? Function() op, void Function() check) {
      final before = jsonEncode(p.toJson());
      final depth = c.undoDepth;
      expect(op(), isNull);
      expect(c.undoDepth, depth + 1, reason: 'exactly one undo step');
      check();
      c.undo();
      expect(jsonEncode(p.toJson()), before, reason: 'undo restores everything');
    }

    test('delete, duplicate, hide, lock', () {
      c.selectMany(['s1', 's2', 's4']);
      oneStep(a.delete, () => expect(p.main.layers.map((l) => l.id), ['s0', 's3', 's5']));
      c.selectMany(['s1', 's2', 's4']);
      oneStep(a.duplicate, () {
        expect(p.main.layers.length, 9);
        expect(c.selectionCount, 3);
        expect(c.selectedLayerIds.every((id) => !id.startsWith('s')), isTrue, reason: 'the copies are selected');
      });
      c.selectMany(['s1', 's2', 's4']);
      oneStep(() => a.setVisible(false), () => expect(p.main.layers.where((l) => !l.visible).length, 3));
      c.selectMany(['s1', 's2', 's4']);
      oneStep(a.toggleLocked, () => expect(p.main.layers.where((l) => l.locked).length, 3));
    });

    test('split and trim at the playhead skip layers it does not cross', () {
      c.seek(2.2);
      c.selectMany(['s0', 's2', 's5']); // s5 starts at 2.5
      oneStep(a.splitAtPlayhead, () => expect(p.main.layers.length, 8));
      oneStep(() => a.trimToPlayhead(inPoint: false), () {
        expect(p.main.layerById('s0')!.end, closeTo(2.2, 1e-9));
        expect(p.main.layerById('s5')!.end, closeTo(6.5, 1e-9));
      });
    });

    test('shift in time and nudge move all together', () {
      c.selectMany(['s1', 's3']);
      oneStep(() => a.shiftTime(1.5), () {
        expect(p.main.layerById('s1')!.start, closeTo(2.0, 1e-9));
        expect(p.main.layerById('s3')!.start, closeTo(3.0, 1e-9));
      });
      oneStep(() => a.shiftTime(-10), () {
        expect(p.main.layerById('s1')!.start, closeTo(0, 1e-9), reason: 'clamped so nothing goes before 0');
        expect(p.main.layerById('s3')!.start, closeTo(1.0, 1e-9));
      });
      oneStep(() => a.nudge(10, -5), () {
        expect(pos(p, 's1'), [510, 345, 0]);
        expect(pos(p, 's3'), [1110, 445, 0]);
        expect(pos(p, 's2'), [800, 400, 0]);
      });
    });

    test('align and distribute math', () {
      c.selectMany(['s0', 's1', 's2']); // boxes x: 150..250, 450..550, 750..850
      oneStep(() => a.align('left'), () {
        for (final id in ['s0', 's1', 's2']) {
          expect(BulkCommands.bounds(p.main, p.main.layerById(id)!, 0)[0], closeTo(150, 1e-9));
        }
      });
      oneStep(() => a.align('right'), () => expect(pos(p, 's0')[0], closeTo(800, 1e-9)));
      oneStep(() => a.align('center'), () => expect(pos(p, 's2')[0], closeTo(500, 1e-9)));
      oneStep(() => a.align('top'), () => expect(pos(p, 's2')[1], closeTo(300, 1e-9)));
      oneStep(() => a.align('bottom'), () => expect(pos(p, 's0')[1], closeTo(400, 1e-9)));
      oneStep(() => a.align('middle'), () => expect(pos(p, 's1')[1], closeTo(350, 1e-9)));
      oneStep(() => a.align('center', to: 'comp'), () => expect(pos(p, 's0')[0], closeTo(960, 1e-9)));

      // Distribute: uneven layers become evenly spaced between the outer two.
      run(p, {'op': 'update_layer', 'layer': 's1', 'width': 300, 'height': 100});
      run(p, {'op': 'set_property', 'layer': 's1', 'prop': 'anchor', 'value': [150, 50, 0]});
      run(p, {'op': 'set_property', 'layer': 's1', 'prop': 'position', 'value': [300, 300, 0]});
      c.selectMany(['s0', 's1', 's2', 's3']); // centres 200, 300, 800, 1100
      oneStep(() => a.distribute('horizontal'), () {
        expect(pos(p, 's0')[0], closeTo(200, 1e-9));
        expect(pos(p, 's1')[0], closeTo(500, 1e-9));
        expect(pos(p, 's2')[0], closeTo(800, 1e-9));
        expect(pos(p, 's3')[0], closeTo(1100, 1e-9));
      });
      oneStep(() => a.distribute('horizontal', by: 'gap'), () {
        // span 150..1150 = 1000, widths 100+300+100+100 = 600 → gaps of 400/3
        final g = 400 / 3;
        final b = [for (final id in ['s0', 's1', 's2', 's3']) BulkCommands.bounds(p.main, p.main.layerById(id)!, 0)];
        b.sort((x, y) => x[0].compareTo(y[0]));
        for (int i = 1; i < b.length; i++) {
          expect(b[i][0] - b[i - 1][2], closeTo(g, 1e-6));
        }
      });
      oneStep(() => a.distribute('vertical'), () {
        final ys = [for (final id in ['s0', 's1', 's2', 's3']) pos(p, id)[1]]..sort();
        expect(ys[1] - ys[0], closeTo(ys[2] - ys[1], 1e-9));
        expect(ys[3] - ys[2], closeTo(ys[2] - ys[1], 1e-9));
      });
      c.selectMany(['s0', 's1']);
      expect(a.distribute('horizontal'), isNotNull, reason: 'needs 3 layers');
    });

    test('align in time: start at playhead, stagger by seconds and frames, sequence', () {
      c.seek(1.0);
      c.selectMany(['s3', 's1', 's2']);
      oneStep(() => a.alignTime('start'), () {
        for (final id in ['s1', 's2', 's3']) {
          expect(p.main.layerById(id)!.start, closeTo(1.0, 1e-9));
        }
      });
      oneStep(() => a.alignTime('stagger', step: 0.5, time: 2), () {
        // stacking order: s1, s2, s3 (top first)
        expect(p.main.layerById('s1')!.start, closeTo(2.0, 1e-9));
        expect(p.main.layerById('s2')!.start, closeTo(2.5, 1e-9));
        expect(p.main.layerById('s3')!.start, closeTo(3.0, 1e-9));
      });
      oneStep(() => a.alignTime('stagger', frames: 6), () {
        expect(p.main.layerById('s1')!.start, closeTo(0.5, 1e-9), reason: 'base = first layer start');
        expect(p.main.layerById('s2')!.start, closeTo(0.7, 1e-9));
        expect(p.main.layerById('s3')!.start, closeTo(0.9, 1e-9));
      });
      oneStep(() => a.alignTime('sequence'), () {
        expect(p.main.layerById('s2')!.start, closeTo(p.main.layerById('s1')!.end, 1e-9));
        expect(p.main.layerById('s3')!.start, closeTo(p.main.layerById('s2')!.end, 1e-9));
      });
      // Keyframes move with the layers.
      run(p, {'op': 'set_keyframe', 'target': 's1', 'prop': 'opacity', 'time': 1.0, 'value': 0});
      c.selectMany(['s1']);
      a.alignTime('start', time: 3);
      expect(p.main.layerById('s1')!.prop(Props.opacity).keyframes.first.time, closeTo(3.5, 1e-9));
    });

    test('set property for all: absolute, relative and mixed', () {
      c.selectMany(['s0', 's1', 's2']);
      oneStep(() => a.setProperty(Props.opacity, 40), () {
        expect(p.main.layers.where((l) => l.prop(Props.opacity).staticValue[0] == 40).length, 3);
      });
      oneStep(() => a.setProperty(Props.rotation, 15, component: 2, relative: true), () {
        expect(p.main.layerById('s1')!.prop(Props.rotation).staticValue[2], 15);
      });
      oneStep(() => a.setProperty(Props.scale, 50), () => expect(p.main.layerById('s2')!.prop(Props.scale).staticValue, [50, 50, 100]));
      oneStep(() => a.setProperty(Props.position, 20, component: 0, relative: true), () {
        expect(pos(p, 's0')[0], 220);
        expect(pos(p, 's2')[0], 820);
      });
      // Relative changes move keyframes too.
      run(p, {'op': 'set_keyframe', 'target': 's0', 'prop': 'position', 'time': 0, 'value': [0, 0, 0]});
      run(p, {'op': 'set_keyframe', 'target': 's0', 'prop': 'position', 'time': 2, 'value': [100, 0, 0]});
      oneStep(() => a.setProperty(Props.position, 10, component: 1, relative: true), () {
        final k = p.main.layerById('s0')!.prop(Props.position).keyframes;
        expect(k.map((e) => e.value[1]), [10, 10]);
      });
    });

    test('make 3D for 30 layers is one step; make 2D back', () {
      final q = solids(30);
      final cc = ctl(q);
      final aa = BulkActions(cc);
      cc.selectAll();
      final before = screen(q.main, 1.0);
      expect(aa.set3D(true), isNull);
      expect(cc.undoDepth, 1);
      expect(q.main.layers.every((l) => l.is3D), isTrue);
      expectSameScreen(before, screen(q.main, 1.0));
      expect(aa.toggle3D(), isNull, reason: 'all 3D → all 2D');
      expect(q.main.layers.every((l) => !l.is3D), isTrue);
      expect(cc.undoDepth, 2);
      cc.undo();
      expect(q.main.layers.every((l) => l.is3D), isTrue);
      cc.undo();
      expect(q.main.layers.every((l) => !l.is3D), isTrue);
      if (BulkActions.hasDepthMake3d) {
        expect(aa.make3dScene(), isNull);
        expect(cc.undoDepth, 1);
        expect(q.main.layers.every((l) => l.is3D), isTrue);
      }
      cc.dispose();
    });

    test('effects, transitions, looks for all; copy/paste effects and animation', () {
      c.selectMany(['s0', 's1', 's2']);
      oneStep(() => a.addEffect('blur'), () {
        expect(p.main.layers.where((l) => l.effects.any((e) => e.type == 'blur')).length, 3);
      });
      a.addEffect('glow');
      a.addEffect('mono');
      c.select('s0');
      expect(a.copyEffects(), isNull);
      c.selectMany(['s3', 's4']);
      oneStep(a.pasteEffects, () {
        final types = p.main.layerById('s4')!.effects.map((e) => e.type).toList();
        expect(types, ['blur', 'glow', 'mono']);
        final ids = {for (final l in p.main.layers) for (final e in l.effects) e.id};
        expect(ids.length, 15, reason: 'pasted effects get new ids');
      });
      c.selectMany(['s3', 's4']);
      oneStep(() => a.animate('fade', isIn: true), () {
        for (final id in ['s3', 's4']) {
          expect(p.main.layerById(id)!.prop(Props.opacity).isAnimated, isTrue);
        }
      });
      // Copy the primary's animation; paste is relative to each layer's start.
      run(p, {'op': 'set_keyframe', 'target': 's0', 'prop': 'rotation', 'time': 0, 'value': [0, 0, 0]});
      run(p, {'op': 'set_keyframe', 'target': 's0', 'prop': 'rotation', 'time': 1, 'value': [0, 0, 90]});
      c.select('s0');
      expect(a.copyAnimation(), isNull);
      c.selectMany(['s2', 's5']);
      oneStep(a.pasteAnimation, () {
        final k = p.main.layerById('s5')!.prop(Props.rotation).keyframes;
        expect(k.map((e) => e.time), [closeTo(2.5, 1e-9), closeTo(3.5, 1e-9)]);
        expect(k.last.value[2], 90);
      });
    });

    test('text style for all text layers only', () {
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 't1', 'text': 'One'});
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 't2', 'text': 'Two'});
      c.selectMany(['t1', 't2', 's0']);
      oneStep(() => a.setText({'font_size': 140, 'text_color': '#FFD54F', 'animator': 'random_pop'}), () {
        for (final id in ['t1', 't2']) {
          final t = p.main.layerById(id)!.text!;
          expect(t.fontSize, 140);
          expect(t.animator, 'random_pop');
        }
      });
    });

    test('parent / unparent keep the picture; group into a null keeps visual positions', () {
      run(p, {'op': 'set_property', 'layer': 's5', 'prop': 'rotation', 'value': [0, 0, 30]});
      run(p, {'op': 'set_property', 'layer': 's5', 'prop': 'scale', 'value': [150, 150, 100]});
      run(p, {'op': 'set_keyframe', 'target': 's1', 'prop': 'position', 'time': 0.5, 'value': [500, 350, 0]});
      run(p, {'op': 'set_keyframe', 'target': 's1', 'prop': 'position', 'time': 2.5, 'value': [900, 600, 0]});
      final t0 = screen(p.main, 1.0), t1 = screen(p.main, 2.0);
      c.seek(1.0);
      c.selectMany(['s1', 's2']);
      oneStep(() => a.parentTo('s5'), () {
        expect(p.main.layerById('s1')!.parentId, 's5');
        expectSameScreen(t0, screen(p.main, 1.0));
        expectSameScreen(t1, screen(p.main, 2.0));
      });
      a.parentTo('s5');
      oneStep(() => a.parentTo(null), () {
        expect(p.main.layerById('s2')!.parentId, isNull);
        expectSameScreen(t0, screen(p.main, 1.0));
      });
      c.undo(); // back to unparented

      c.selectMany(['s0', 's1', 's3']);
      oneStep(a.group, () {
        final g = p.main.layers.firstWhere((l) => l.type == LayerType.nullObject);
        expect(c.selectedLayerIds, [g.id]);
        final u = BulkCommands.unionBounds(p.main, [for (final id in ['s0', 's1', 's3']) p.main.layerById(id)!], 1.0);
        expect(g.prop(Props.position).staticValue, [closeTo((u[0] + u[2]) / 2, 1e-6), closeTo((u[1] + u[3]) / 2, 1e-6), 0]);
        expect(u[0], closeTo(150, 1e-9));
        for (final id in ['s0', 's1', 's3']) {
          expect(p.main.layerById(id)!.parentId, g.id);
        }
        expect(p.main.indexOf(g.id), lessThan(p.main.indexOf('s0')));
        expectSameScreen(t0, screen(p.main, 1.0));
        expectSameScreen(t1, screen(p.main, 2.0));
        // Moving the null moves the group.
        run(p, {'op': 'transform_layers', 'layers': [g.id], 'move': [100, 0]});
        expect(screen(p.main, 1.0)['s0']![0], closeTo(t0['s0']![0] + 100, 1e-6));
      });
    });

    test('transform together: scale and rotate around the selection centre', () {
      c.selectMany(['s0', 's2']); // centres (200,300), (800,400); union 150..850 × 250..450 → centre (500,350)
      oneStep(() => a.transform(scale: 2), () {
        expect(pos(p, 's0'), [closeTo(-100, 1e-9), closeTo(250, 1e-9), 0]);
        expect(pos(p, 's2'), [closeTo(1100, 1e-9), closeTo(450, 1e-9), 0]);
        expect(p.main.layerById('s0')!.prop(Props.scale).staticValue, [200, 200, 100]);
      });
      oneStep(() => a.transform(rotate: 90), () {
        expect(pos(p, 's0'), [closeTo(550, 1e-9), closeTo(50, 1e-9), 0]);
        expect(p.main.layerById('s2')!.prop(Props.rotation).staticValue[2], 90);
      });
    });

    test('copy / paste layers: round trip with new ids, parents and mattes follow', () async {
      run(p, {'op': 'update_layer', 'layer': 's1', 'parent': 's0'});
      run(p, {'op': 'update_layer', 'layer': 's2', 'matte': {'layer': 's0'}});
      c.selectMany(['s0', 's1', 's2']);
      expect(await a.copyLayers(), isNull);
      final clip = BulkActions.layerClipboard!;
      expect(clip['op'], 'paste_layers');
      jsonDecode(jsonEncode(clip)); // plain JSON

      c.seek(3.0);
      final depth = c.undoDepth;
      expect(await a.pasteLayers(), isNull);
      expect(c.undoDepth, depth + 1);
      expect(p.main.layers.length, 9);
      final pasted = c.selectedLayers;
      expect(pasted.length, 3);
      expect(pasted.every((l) => !['s0', 's1', 's2'].contains(l.id)), isTrue, reason: 'new ids');
      final byName = {for (final l in pasted) l.name: l};
      expect(byName['Solid 1']!.parentId, byName['Solid 0']!.id, reason: 'parent remapped to the copy');
      expect(byName['Solid 2']!.matte!.layerId, byName['Solid 0']!.id);
      expect(byName['Solid 0']!.start, closeTo(3.0, 1e-9), reason: 'pasted at the playhead');
      expect(byName['Solid 2']!.start, closeTo(4.0, 1e-9), reason: 'relative timing kept');

      // Another project (cross-project paste carries media and comps).
      final q = newProject();
      q.media['m1'] = MediaAsset(id: 'm1', type: MediaType.image, path: '/tmp/x.png', name: 'x', width: 400, height: 300);
      run(q, {'op': 'add_layer', 'type': 'image', 'media': 'm1', 'id': 'img'});
      run(q, {'op': 'add_comp', 'id': 'C1', 'name': 'Inner'});
      run(q, {'op': 'add_layer', 'in_comp': 'C1', 'type': 'solid', 'id': 'inner', 'width': 10, 'height': 10});
      run(q, {'op': 'add_layer', 'type': 'comp', 'comp': 'C1', 'id': 'cl'});
      final cmd = BulkCommands.clipboardFor(q, q.main, ['img', 'cl']);
      final target = solids(1);
      run(target, cmd);
      expect(target.media.containsKey('m1'), isTrue);
      expect(target.comps.containsKey('C1'), isTrue);
      expect(target.main.layers.length, 3);
      // Pasting a comp layer into its own comp is refused.
      target.editCompId = 'C1';
      final compLayer = (cmd['layers'] as List).firstWhere((j) => (j as Map)['type'] == 'comp');
      expect(() => run(target, {...cmd, 'layers': [compLayer]}), throwsA(isA<CommandError>()));
    });

    test('precompose the selection: one step, comp layer selected, picture unchanged', () {
      final before = screen(p.main, 1.0);
      c.selectMany(['s1', 's3', 's4']);
      oneStep(a.precompose, () {
        expect(p.comps.length, 1);
        final comp = p.comps.values.single;
        expect(comp.layers.map((l) => l.id).toSet(), {'s1', 's3', 's4'});
        expect(c.selectionCount, 1);
        expect(c.selectedLayer!.type, LayerType.comp);
        expect(p.main.layers.map((l) => l.id).toSet(), {'s0', 's2', 's5', c.selectedLayerId});
        expect(screen(p.main, 1.0)['s0'], before['s0']);
      });
    });

    test('reorder the selection together', () {
      c.selectMany(['s2', 's4']);
      oneStep(() => a.reorder(true), () => expect(p.main.layers.map((l) => l.id), ['s0', 's2', 's1', 's4', 's3', 's5']));
      c.selectMany(['s0', 's1']);
      oneStep(() => a.reorder(false), () => expect(p.main.layers.map((l) => l.id), ['s2', 's0', 's1', 's3', 's4', 's5']));
    });
  });
}
