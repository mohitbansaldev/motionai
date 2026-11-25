// Correctness of the live-preview caches (Agent O): content fingerprints,
// cached 3D layer images and the allocation-free layer matrix.
import 'dart:math' as math;

import 'package:flutter/rendering.dart' hide Layer;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/ui/preview/composition_canvas.dart';
import 'package:motionai/ui/preview/fx/layer_cache.dart';

import 'perf_test.dart' show bench3D;

void _run(Project p, Map<String, dynamic> c) => EditCommands.runAtomic(p, c);

void main() {
  group('preview caches stay correct', () {
    test('localMatrix equals T(p)·Rx·Ry·Rz·S·T(−anchor)', () {
      final rnd = math.Random(7);
      for (int i = 0; i < 200; i++) {
        final is3D = i.isEven;
        double r() => rnd.nextDouble() * 400 - 200;
        final l = Layer(id: 'x', name: 'x', type: LayerType.solid, start: 0, duration: 5, width: 300, height: 200, is3D: is3D);
        l.prop(Props.position).staticValue = [r(), r(), r()];
        l.prop(Props.anchor).staticValue = [r(), r(), r()];
        l.prop(Props.scale).staticValue = [r(), r(), r()];
        l.prop(Props.rotation).staticValue = [i % 3 == 0 ? 0 : r(), i % 5 == 0 ? 0 : r(), i % 7 == 0 ? 0 : r()];
        final p = l.prop(Props.position).staticValue, a = l.prop(Props.anchor).staticValue;
        final sc = l.prop(Props.scale).staticValue, ro = l.prop(Props.rotation).staticValue;
        const deg = math.pi / 180;
        final ref = Matrix4.translationValues(p[0], p[1], is3D ? p[2] : 0);
        if (is3D) {
          if (ro[0] != 0) ref.multiply(Matrix4.rotationX(ro[0] * deg));
          if (ro[1] != 0) ref.multiply(Matrix4.rotationY(ro[1] * deg));
        }
        if (ro[2] != 0) ref.multiply(Matrix4.rotationZ(ro[2] * deg));
        ref.multiply(Matrix4.diagonal3Values(sc[0] / 100, sc[1] / 100, is3D ? sc[2] / 100 : 1));
        ref.multiply(Matrix4.translationValues(-a[0], -a[1], is3D ? -a[2] : 0));
        final m = Evaluator.localMatrix(l, 0);
        for (int k = 0; k < 16; k++) {
          expect(m.storage[k], closeTo(ref.storage[k], 1e-6), reason: 'entry $k of case $i');
        }
      }
    });

    test('content fingerprint: static vs animated vs time-driven', () {
      final p = bench3D();
      final text = p.main.requireLayer('l1'), solid = p.main.requireLayer('l0'), glow = p.main.requireLayer('l3');
      int? sig(Layer l, double t) => LayerSig.content(p, l, t, draft: true, playing: true);
      expect(sig(text, 1), sig(text, 7), reason: 'static text');
      expect(sig(solid, 1), sig(solid, 7), reason: 'transform keyframes are not content');
      expect(sig(glow, 1), sig(glow, 7));
      _run(p, {'op': 'set_keyframe', 'target': 'l3', 'effect': p.main.requireLayer('l3').effects.first.id, 'prop': 'amount', 'time': 0, 'value': [0]});
      _run(p, {'op': 'set_keyframe', 'target': 'l3', 'effect': p.main.requireLayer('l3').effects.first.id, 'prop': 'amount', 'time': 4, 'value': [90]});
      expect(sig(glow, 1), isNot(sig(glow, 2)), reason: 'animated effect param');
      expect(sig(glow, 5), sig(glow, 7), reason: 'held after the last keyframe');
      _run(p, {'op': 'add_effect', 'layer': 'l0', 'effect': 'grain'});
      expect(sig(solid, 1), isNot(sig(solid, 1.5)), reason: 'grain changes every frame');
      _run(p, {'op': 'update_layer', 'layer': 'l1', 'animator': 'typewriter'});
      expect(sig(text, 0.2), isNot(sig(text, 0.4)), reason: 'intro running');
      expect(sig(text, 3), sig(text, 4), reason: 'intro finished');
      final before = sig(text, 3);
      _run(p, {'op': 'update_layer', 'layer': 'l1', 'text': 'Changed'});
      expect(sig(text, 3), isNot(before), reason: 'edits change the fingerprint');
    });

    testWidgets('cached 3D layers look the same and edits show up', (tester) async {
      tester.view.physicalSize = const Size(400, 200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = Project(
        id: 'c',
        name: 'c',
        main: Composition(id: 'm', name: 'm', width: 400, height: 200, fps: 30, duration: 5, background: 0xFF000000),
      );
      _run(p, {'op': 'add_layer', 'type': 'shape', 'id': 's', 'kind': 'rect', 'is3d': true, 'width': 200, 'height': 120,
          'position': [200, 100, 0], 'fill': '#FF0000'});
      _run(p, {'op': 'add_effect', 'layer': 's', 'effect': 'color', 'params': {'brightness': 0}});
      _run(p, {'op': 'set_property', 'target': 's', 'prop': 'rotation', 'value': [0, 25, 0]});
      _run(p, {'op': 'set_camera_mode', 'mode': '3d'});
      final key = GlobalKey();
      Future<List<int>> shot(double? scale) async {
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(
                key: key, child: CompositionCanvas(project: p, time: 1, draft: true, playing: true, previewScale: scale)),
          ),
        ));
        await tester.pump();
        await tester.pump();
        expect(tester.takeException(), isNull);
        late List<int> out;
        await tester.runAsync(() async {
          final ro = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final img = await ro.toImage();
          final bd = (await img.toByteData())!;
          out = [
            for (final xy in const [[200, 100], [150, 100], [250, 100], [10, 10], [395, 195]])
              for (int ch = 0; ch < 3; ch++) bd.getUint8((xy[1] * img.width + xy[0]) * 4 + ch),
          ];
          img.dispose();
        });
        return out;
      }

      final direct = await shot(null);
      final before = RenderLayerRaster.snapshots;
      final cached = await shot(1);
      expect(RenderLayerRaster.snapshots, greaterThan(before), reason: 'the static 3D shape was cached');
      for (int i = 0; i < direct.length; i++) {
        expect((cached[i] - direct[i]).abs(), lessThan(40), reason: 'channel $i');
      }
      expect(cached[0], greaterThan(200), reason: 'red centre');
      _run(p, {'op': 'update_layer', 'layer': 's', 'fill': '#00FF00'});
      final edited = await shot(1);
      expect(edited[0], lessThan(60), reason: 'edit shows up (no red)');
      expect(edited[1], greaterThan(200), reason: 'edit shows up (green)');
    });
  });
}
