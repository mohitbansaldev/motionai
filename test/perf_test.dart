// Performance benchmark (Agent O): a 48-layer, all-3D project with a moving
// 3D camera, played through the real editor preview (CompositionView).
//
// Prints per-frame numbers (look for "PERF" in the CI log) and asserts only
// very generous upper bounds so CI never flakes. Widget tests run in debug
// (JIT, asserts on), so absolute times are several times slower than a
// release build; compare before/after on the same runner.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/services/project_storage.dart';
import 'package:motionai/state/editor_controller.dart';
import 'package:motionai/ui/preview/composition_canvas.dart';
import 'package:motionai/ui/preview/composition_view.dart';
import 'package:motionai/ui/preview/fx/layer_cache.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4;

class _NoSave extends ProjectStorage {
  @override
  Future<void> save(Project p) async {}
}

void _run(Project p, Map<String, dynamic> c) => EditCommands.runAtomic(p, c);

/// 48 layers, every one 3D, spread in depth; a 3D camera dollies and pans
/// through them over 10 s. Mix of solids, text (with shadows), shapes and a
/// few effects and masks, like a typical documentary scene.
///
/// [viaMake3D]: the layers are built flat and converted with `make_3d`, then
/// the camera does a `camera_shot` push_through (turns comp motion blur on),
/// which is how most users make "all layers 3D".
Project bench3D({bool motionBlur = false, double aperture = 0, bool viaMake3D = false}) {
  final p = Project(
    id: 'perf',
    name: 'Perf',
    main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: 10, background: 0xFF101014),
  );
  final rnd = math.Random(42);
  for (int i = 0; i < 48; i++) {
    final x = 200.0 + (i % 8) * 220 + rnd.nextDouble() * 40;
    final y = 150.0 + (i ~/ 8) * 150 + rnd.nextDouble() * 40;
    final z = viaMake3D ? 0.0 : (i % 6) * 350.0;
    final d3 = !viaMake3D;
    final id = 'l$i';
    switch (i % 4) {
      case 0:
        _run(p, {'op': 'add_layer', 'type': 'solid', 'id': id, 'is3d': d3, 'color': '#3366CC', 'width': 420, 'height': 260, 'position': [x, y, z]});
      case 1:
        _run(p, {'op': 'add_layer', 'type': 'text', 'id': id, 'is3d': d3, 'text': 'Chapter $i: The Story', 'font_size': 64,
            'width': 700, 'height': 120, 'position': [x, y, z]});
      case 2:
        _run(p, {'op': 'add_layer', 'type': 'shape', 'id': id, 'is3d': d3, 'kind': i % 8 == 2 ? 'star' : 'ellipse',
            'width': 260, 'height': 260, 'position': [x, y, z], 'fill': '#FFC107', 'stroke': '#FFFFFF', 'stroke_width': 6});
      default:
        _run(p, {'op': 'add_layer', 'type': 'solid', 'id': id, 'is3d': d3, 'color': '#AA3344', 'width': 640, 'height': 360, 'position': [x, y, z]});
    }
    // A few effects and masks (static parameters).
    if (i % 6 == 3) _run(p, {'op': 'add_effect', 'layer': id, 'effect': 'glow'});
    if (i % 6 == 5) _run(p, {'op': 'add_effect', 'layer': id, 'effect': 'shadow'});
    if (i % 8 == 7) _run(p, {'op': 'add_effect', 'layer': id, 'effect': 'vignette'});
    if (i % 9 == 4) _run(p, {'op': 'add_effect', 'layer': id, 'effect': 'color', 'params': {'saturation': 30}});
    if (i % 10 == 0) _run(p, {'op': 'add_mask', 'layer': id, 'shape': 'ellipse'});
    // Some layers turn slowly (animated transform, static content).
    if (i % 5 == 0) {
      _run(p, {'op': 'set_keyframe', 'target': id, 'prop': 'rotation', 'time': 0, 'value': [0, 0, 0]});
      _run(p, {'op': 'set_keyframe', 'target': id, 'prop': 'rotation', 'time': 10, 'value': [0, 40, 0]});
    }
  }
  if (viaMake3D) {
    _run(p, {'op': 'make_3d', 'start': 0});
    _run(p, {'op': 'camera_shot', 'move': 'push_through', 'start': 0, 'duration': 10});
    return p;
  }
  _run(p, {'op': 'set_camera_mode', 'mode': '3d'});
  _run(p, {'op': 'set_keyframe', 'target': 'camera', 'prop': 'position', 'time': 0, 'value': [960, 540, -2667], 'ease': 'linear'});
  _run(p, {'op': 'set_keyframe', 'target': 'camera', 'prop': 'position', 'time': 10, 'value': [1300, 420, -900]});
  _run(p, {'op': 'set_keyframe', 'target': 'camera', 'prop': 'poi', 'time': 0, 'value': [960, 540, 0], 'ease': 'linear'});
  _run(p, {'op': 'set_keyframe', 'target': 'camera', 'prop': 'poi', 'time': 10, 'value': [1100, 520, 600]});
  if (aperture > 0) _run(p, {'op': 'set_property', 'target': 'camera', 'prop': 'aperture', 'value': [aperture]});
  if (motionBlur) _run(p, {'op': 'set_comp', 'motion_blur': true});
  return p;
}

class _Stats {
  final List<double> ms;
  _Stats(this.ms);
  double get mean => ms.isEmpty ? 0 : ms.reduce((a, b) => a + b) / ms.length;
  double pct(double q) {
    if (ms.isEmpty) return 0;
    final s = [...ms]..sort();
    return s[((s.length - 1) * q).round()];
  }

  @override
  String toString() =>
      'mean=${mean.toStringAsFixed(3)}ms p50=${pct(0.5).toStringAsFixed(3)}ms p95=${pct(0.95).toStringAsFixed(3)}ms max=${pct(1).toStringAsFixed(3)}ms (n=${ms.length})';
}

double _ms(Stopwatch sw) => sw.elapsedMicroseconds / 1000.0;

void main() {
  group('PERF 48 layers, all 3D, moving camera', () {
    test('Evaluator.evaluate per frame', () {
      for (final (mb, m3) in [(false, false), (true, false), (false, true)]) {
        final p = bench3D(motionBlur: mb, viaMake3D: m3);
        expect(p.main.layers.length, 48);
        var items = 0;
        for (int f = 0; f < 120; f++) {
          items += Evaluator.evaluate(p.main, f / 60).length; // warm up the JIT
        }
        final times = <double>[];
        for (int f = 0; f < 600; f++) {
          final sw = Stopwatch()..start();
          items += Evaluator.evaluate(p.main, f / 60).length;
          times.add(_ms(sw));
        }
        expect(items, greaterThan(0));
        final s = _Stats(times);
        // ignore: avoid_print
        print('PERF evaluate ${m3 ? 'make_3d+push_through (motionBlur=${p.main.motionBlur})' : 'motionBlur=$mb'}: $s');
        expect(s.mean, lessThan(25), reason: 'evaluate() of 48 3D layers should take well under a frame');
      }
    });

    Future<void> previewBench(WidgetTester tester, {required bool play, double aperture = 0, bool viaMake3D = false}) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = bench3D(aperture: aperture, viaMake3D: viaMake3D);
      expect(p.main.layers.where((l) => l.is3D).length, greaterThan(40), reason: 'all layers 3D');
      final c = EditorController(p, _NoSave());
      final previewKey = GlobalKey();
      c.attachTicker(tester);
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Column(children: [
            const SizedBox(height: 40, child: Text('chrome')),
            Expanded(child: RepaintBoundary(key: previewKey, child: CompositionView(controller: c))),
          ]),
        ),
      ));
      expect(tester.takeException(), isNull);
      if (play) c.play();

      Set<PictureLayer> pictures() => tester.layers.whereType<PictureLayer>().toSet();
      var prev = pictures();
      final times = <double>[], raster = <double>[];
      var repainted = 0, frames = 0;
      const warm = 20, n = 180;
      for (int f = 0; f < warm + n; f++) {
        final sw = Stopwatch()..start();
        if (play) {
          await tester.pump(const Duration(microseconds: 16667));
        } else {
          c.seek((f + 1) / 30, snap: false); // scrubbing while paused
          await tester.pump();
        }
        final ms = _ms(sw);
        final now = pictures();
        if (f >= warm) {
          times.add(ms);
          repainted += now.difference(prev).length;
          frames++;
          // Raster-cost proxy: rasterise the whole preview in software. The
          // test renderer has no GPU, so this is where glyphs, paths, blurs
          // and big textures under perspective show up.
          if ((f - warm) % 15 == 0) {
            await tester.runAsync(() async {
              final ro = previewKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
              final sw2 = Stopwatch()..start();
              final img = await ro.toImage();
              raster.add(_ms(sw2));
              img.dispose();
            });
          }
        }
        prev = now;
      }
      expect(tester.takeException(), isNull);
      expect(c.time, greaterThan(0.5));
      if (play) c.pause();
      await tester.pump();
      final s = _Stats(times);
      final kinds = <String, int>{};
      for (final l in tester.layers) {
        kinds['${l.runtimeType}'] = (kinds['${l.runtimeType}'] ?? 0) + 1;
      }
      // ignore: avoid_print
      print('PERF raster ${play ? 'playing' : 'scrubbing'}${viaMake3D ? ' make_3d' : ''}: whole preview rasterised in software ${_Stats(raster)}; layers: $kinds');
      // ignore: avoid_print
      print('PERF preview ${viaMake3D ? 'make_3d+push_through ' : ''}${play ? 'playing' : 'scrubbing (paused)'}${aperture > 0 ? ' with depth of field' : ''}: '
          'build+layout+paint $s; re-recorded pictures/frame=${(repainted / frames).toStringAsFixed(1)} '
          '(pictures in tree: ${prev.length})');
      // ignore: avoid_print
      print('PERF layer image snapshots so far: ${RenderLayerRaster.snapshots}');
      expect(s.mean, lessThan(400), reason: 'one preview frame (debug build) must not take ages');
    }

    testWidgets('editor preview while playing', (tester) => previewBench(tester, play: true));
    testWidgets('editor preview while playing a make_3d + push_through shot', (tester) => previewBench(tester, play: true, viaMake3D: true));
    testWidgets('editor preview while scrubbing with depth of field', (tester) => previewBench(tester, play: false, aperture: 30));
  });

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
