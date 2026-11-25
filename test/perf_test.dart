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
import 'package:motionai/core/model/project.dart';
import 'package:motionai/services/project_storage.dart';
import 'package:motionai/state/editor_controller.dart';
import 'package:motionai/ui/preview/composition_view.dart';

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
      c.attachTicker(tester);
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Column(children: [
            const SizedBox(height: 40, child: Text('chrome')),
            Expanded(child: CompositionView(controller: c)),
          ]),
        ),
      ));
      expect(tester.takeException(), isNull);
      if (play) c.play();

      Set<PictureLayer> pictures() => tester.layers.whereType<PictureLayer>().toSet();
      var prev = pictures();
      final times = <double>[];
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
        }
        prev = now;
      }
      expect(tester.takeException(), isNull);
      expect(c.time, greaterThan(0.5));
      if (play) c.pause();
      await tester.pump();
      final s = _Stats(times);
      // ignore: avoid_print
      print('PERF preview ${viaMake3D ? 'make_3d+push_through ' : ''}${play ? 'playing' : 'scrubbing (paused)'}${aperture > 0 ? ' with depth of field' : ''}: '
          'build+layout+paint $s; re-recorded pictures/frame=${(repainted / frames).toStringAsFixed(1)} '
          '(pictures in tree: ${prev.length})');
      expect(s.mean, lessThan(400), reason: 'one preview frame (debug build) must not take ages');
    }

    testWidgets('editor preview while playing', (tester) => previewBench(tester, play: true));
    testWidgets('editor preview while playing a make_3d + push_through shot', (tester) => previewBench(tester, play: true, viaMake3D: true));
    testWidgets('editor preview while scrubbing with depth of field', (tester) => previewBench(tester, play: false, aperture: 30));
  });
}
