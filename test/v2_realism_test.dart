import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:motionai/ai/command_spec.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/model/camera.dart';
import 'package:motionai/core/model/effects_catalog.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/realism.dart';
import 'package:motionai/ui/preview/composition_canvas.dart';
import 'package:motionai/ui/preview/fx/layer_cache.dart';
import 'package:motionai/ui/preview/fx/realism_painters.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3, Vector4;

Project project() =>
    Project(id: 'p', name: 'Realism', main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: 10));

CommandResult run(Project p, Map<String, dynamic> c) => EditCommands.runAtomic(p, c);

Map<String, dynamic> rect(String id, double w, double h, double x, double y, {String fill = '#888888', String? name}) => {
      'op': 'add_layer', 'type': 'shape', 'id': id, 'kind': 'rect', 'width': w, 'height': h, 'position': [x, y, 0],
      'fill': fill, 'start': 0, 'duration': 10, 'name': ?name,
    };

late Directory tmp;

/// Writes a PNG and registers it as media [id].
void png(Project p, String id, int w, int h, List<int> Function(int x, int y) px) {
  final im = img.Image(width: w, height: h, numChannels: 4);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final c = px(x, y);
      im.setPixelRgba(x, y, c[0], c[1], c[2], c[3]);
    }
  }
  final path = '${tmp.path}/$id.png';
  File(path).writeAsBytesSync(img.encodePng(im));
  p.media[id] = MediaAsset(id: id, type: MediaType.image, path: path, name: id, width: w.toDouble(), height: h.toDouble());
}

/// A grey person cut-out: body x 10..30, y 5..73, feet x 12..28, y 74..78.
List<int> person(int x, int y) {
  final body = x >= 10 && x <= 30 && y >= 5 && y <= 73;
  final feet = x >= 12 && x <= 28 && y >= 74 && y <= 78;
  return body || feet ? [200, 200, 200, 255] : [0, 0, 0, 0];
}

/// Warm, darker plate.
List<int> plate(int x, int y) => [120 + (x % 7), 80 + (y % 5), 50, 255];

Project scene() {
  final p = project();
  png(p, 'plate', 64, 36, plate);
  png(p, 'cut', 40, 80, person);
  run(p, {'op': 'add_layer', 'type': 'image', 'media': 'plate', 'id': 'bg', 'fit': 'cover', 'start': 0, 'duration': 10});
  run(p, {'op': 'add_layer', 'type': 'image', 'media': 'cut', 'id': 'man', 'start': 0, 'duration': 10});
  return p;
}

double luma(List<double> c) => 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];

void main() {
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('v2d'));
  tearDownAll(() {
    PixelCache.clear();
    tmp.deleteSync(recursive: true);
  });

  group('bug: blur on a 3D layer', () {
    Project blurred() {
      final p = project();
      run(p, {'op': 'add_layer', 'type': 'shape', 'id': 's', 'kind': 'path', 'points': [[200, 200], [900, 300], [500, 800]], 'closed': true, 'fill': '#FFAA00', 'start': 0, 'duration': 10});
      run(p, {'op': 'update_layer', 'layer': 's', 'is3d': true});
      run(p, {'op': 'set_property', 'target': 's', 'prop': 'position', 'value': [960, 540, 2666]});
      run(p, {'op': 'set_property', 'target': 's', 'prop': 'scale', 'value': [200, 200, 100]});
      run(p, {'op': 'add_effect', 'layer': 's', 'effect': 'blur', 'params': {'amount': 6}});
      return p;
    }

    test('layer matrix has w = 1 at the centre: compositor blur sigma stays as asked', () {
      final p = blurred();
      final l = p.main.requireLayer('s');
      final it = Evaluator.evaluate(p.main, 1).single;
      final raw = Evaluator.projection(Evaluator.camera3D(p.main, 1)).multiplied(Evaluator.worldMatrix(p.main, l, 1));
      // Before the fix: the basis is scale × depth (≈ 5333) → σ 3 became ≈ 16 000 px.
      expect(Realism.naiveScale(raw), greaterThan(1000));
      // After: the true on-screen scale (≈ 1: scale 200% at twice the distance).
      final a = it.project(0, 0), b = it.project(l.width, 0);
      final onScreen = (b - a).length / l.width;
      expect(Realism.naiveScale(it.matrix), closeTo(onScreen, onScreen * 1e-6));
      expect(Realism.effectiveSigma(it.matrix, 3), lessThan(4));
      // Same picture: every point projects exactly where it did.
      for (final q in [[0.0, 0.0], [l.width, 0.0], [l.width, l.height], [17.0, 33.0]]) {
        final want = projectPoint(raw, q[0], q[1]), got = it.project(q[0], q[1]);
        expect(got.x, closeTo(want.x, 1e-6));
        expect(got.y, closeTo(want.y, 1e-6));
      }
    });

    test('normalised under a moving, rotated camera too', () {
      final p = blurred();
      run(p, {'op': 'set_camera_mode', 'mode': '3d'});
      run(p, {'op': 'camera_move', 'preset': 'orbit', 'start': 0, 'duration': 4, 'amount': 30});
      for (final t in [0.0, 1.3, 2.7, 4.0]) {
        final it = Evaluator.evaluate(p.main, t).single;
        final l = it.layer;
        final c = it.matrix.transform(Vector4(l.width / 2, l.height / 2, 0, 1));
        expect(c.w, closeTo(1, 1e-9), reason: 'w at the layer centre, t=$t');
        expect(Realism.effectiveSigma(it.matrix, 3), lessThan(12));
      }
    });

    test('cached 3D images keep room for blur / glow / shadow spill', () {
      final p = blurred();
      final l = p.main.requireLayer('s');
      expect(Realism.spill(l, 0), closeTo(9, 1e-9)); // 3σ of σ = 3
      run(p, {'op': 'add_effect', 'layer': 's', 'effect': 'glow', 'params': {'radius': 20}});
      expect(Realism.spill(l, 0), 60);
      final none = Layer(id: 'n', name: 'n', type: LayerType.solid, start: 0, duration: 1, width: 100, height: 100);
      expect(Realism.spill(none, 0), 0);
    });

    test('realism effects are cached like other parameter-only effects', () {
      for (final t in Realism.paramFx) {
        expect(LayerSig.paramDriven, contains(t));
        expect(EffectsCatalog.byType(t), isNotNull, reason: t);
      }
      expect(LayerSig.paramDriven.contains('gate_weave'), isFalse, reason: 'gate weave moves every frame');
    });
  });

  group('contact shadow', () {
    test('footprint from alpha', () {
      final im = List<int>.filled(40 * 80 * 4, 0);
      for (int y = 0; y < 80; y++) {
        for (int x = 0; x < 40; x++) {
          final c = person(x, y);
          for (int k = 0; k < 4; k++) {
            im[(y * 40 + x) * 4 + k] = c[k];
          }
        }
      }
      final fp = Realism.footprint(Uint8List.fromList(im), 40, 80)!;
      expect(fp[0], closeTo(12 / 40, 1e-9));
      expect(fp[1], closeTo(29 / 40, 1e-9));
      expect(fp[2], closeTo(79 / 80, 1e-9));
      expect(Realism.footprint(Uint8List.fromList(List<int>.filled(16 * 16 * 4, 0)), 16, 16), isNull);
    });

    test('ground ellipse under the feet, cast shadow pinned at the feet and away from the light', () {
      final g = ShadowGeometry.of(w: 400, h: 800, x0: 0.3, x1: 0.7, bottom: 0.95, angle: 90, length: 50);
      expect(g.cx, closeTo(200, 1e-6), reason: 'overhead light: centred');
      expect(g.cy, lessThan(760));
      expect(g.cy + g.ry, greaterThan(760));
      expect(g.ry, lessThan(g.rx * 0.2), reason: 'flat on the ground');
      // Light from the left (180°): the shadow falls to the right.
      final r = ShadowGeometry.of(w: 400, h: 800, x0: 0.3, x1: 0.7, bottom: 0.95, angle: 180, length: 80);
      expect(r.cx, greaterThan(200));
      final (fx, fy) = r.castPoint(200, 760);
      expect(fx, closeTo(200, 1e-6));
      expect(fy, closeTo(760, 1e-6));
      final (hx, hy) = r.castPoint(200, 40);
      expect(hx, greaterThan(200), reason: 'head leans away from the light');
      expect(hy, lessThan(760));
      expect(hy, greaterThan(40), reason: 'squashed onto the ground');
      expect(r.spill, greaterThan(0));
      // Softer → blurrier; longer → wider.
      expect(ShadowGeometry.of(w: 400, h: 800, softness: 90).blur, greaterThan(ShadowGeometry.of(w: 400, h: 800, softness: 10).blur));
      expect(ShadowGeometry.of(w: 400, h: 800, length: 90).rx, greaterThan(ShadowGeometry.of(w: 400, h: 800, length: 10).rx));
    });

    test('add_effect contact_shadow measures the feet of an image cut-out', () {
      final p = scene();
      run(p, {'op': 'add_effect', 'layer': 'man', 'effect': 'contact_shadow', 'id': 'cs'});
      final e = p.main.requireLayer('man').effectById('cs')!;
      expect(e.params['x0']!.staticValue[0], closeTo(30, 0.11));
      expect(e.params['x1']!.staticValue[0], closeTo(72.5, 0.11));
      expect(e.params['bottom']!.staticValue[0], closeTo(98.8, 0.11));
      expect(e.params['opacity']!.staticValue[0], 55);
    });
  });

  group('make_3d realism', () {
    test('haze grows with depth; contact shadows on cut-outs standing on the ground', () {
      expect(Realism.hazeForDepth(1, 25), 0);
      expect(Realism.hazeForDepth(0.7, 25), 0);
      expect(Realism.hazeForDepth(2, 25), greaterThan(15));
      expect(Realism.hazeForDepth(4, 25), closeTo(50, 1e-9));
      expect(Realism.hazeForDepth(4, 25), greaterThan(Realism.hazeForDepth(2, 25)));
      expect(Realism.hazeForDepth(4, 0), 0);

      final p = scene();
      run(p, {'op': 'batch', 'commands': [rect('hill', 300, 120, 400, 300, name: 'hill')]});
      final r = run(p, {'op': 'make_3d', 'start': 0, 'bands': {'bg': 'sky', 'hill': 'far', 'man': 'mid'}});
      final bg = p.main.requireLayer('bg'), hill = p.main.requireLayer('hill'), man = p.main.requireLayer('man');
      final hb = bg.effectById('bg_haze')!, hh = hill.effectById('hill_haze')!;
      expect(hb.params['amount']!.staticValue[0], greaterThan(hh.params['amount']!.staticValue[0]));
      // Sky colour taken from the (warm) plate.
      final sky = hb.params['color']!.staticValue;
      expect(sky[0], greaterThan(sky[2]));
      expect(man.effectById('man_haze'), isNull, reason: 'mid band: no haze');
      final cs = man.effects.firstWhere((e) => e.type == 'contact_shadow');
      expect(cs.params['bottom']!.staticValue[0], closeTo(98.8, 0.11));
      expect(r.log.any((s) => s.contains('Contact shadow')), isTrue);
      expect(bg.effects.any((e) => e.type == 'contact_shadow'), isFalse, reason: 'plates get no shadow');

      final q = scene();
      run(q, {'op': 'make_3d', 'start': 0, 'haze': 0, 'contact_shadows': false, 'bands': {'bg': 'sky', 'man': 'mid'}});
      expect(q.main.layers.every((l) => l.effects.isEmpty), isTrue);
    });
  });

  group('colour match', () {
    test('grade matrix: identity by default, maths of gain / lift / saturation', () {
      final id = Realism.gradeMatrix();
      for (int i = 0; i < 20; i++) {
        expect(id[i], closeTo(const [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0][i], 1e-12));
      }
      final warm = Realism.gradeMatrix(gain: [120, 100, 80]);
      final c = Realism.applyMatrix(warm, [0.5, 0.5, 0.5]);
      expect(c[0], closeTo(0.6, 1e-9));
      expect(c[2], closeTo(0.4, 1e-9));
      final grey = Realism.applyMatrix(Realism.gradeMatrix(saturation: -100), [0.8, 0.2, 0.1]);
      expect(grey[0], closeTo(grey[1], 1e-9));
      final lifted = Realism.applyMatrix(Realism.gradeMatrix(lift: [10, 10, 10]), [0, 0, 0]);
      expect(lifted[0], closeTo(0.1, 1e-9));
      final half = Realism.applyMatrix(Realism.gradeMatrix(gain: [200, 200, 200], amount: 50), [0.2, 0.2, 0.2]);
      expect(half[0], closeTo(0.3, 1e-9));
    });

    test('stats → params move the cut-out toward the plate', () {
      final cut = ImageStats.ofColor(0xFFC8C8C8); // light neutral grey
      final pl = ImageStats.ofColor(0xFF785032); // darker, warm
      final m = Realism.matchParams(cut, pl);
      final g = m['gain']!;
      expect(g[0], greaterThan(g[2]), reason: 'warm white balance');
      expect((g[0] + g[1] + g[2]) / 3, lessThan(100), reason: 'darker');
      final before = [cut.r, cut.g, cut.b];
      final after = Realism.applyMatrix(
          Realism.gradeMatrix(lift: m['lift']!, gain: g, saturation: m['saturation']![0], contrast: m['contrast']![0]), before);
      expect((luma(after) - pl.luma).abs(), lessThan((luma(before) - pl.luma).abs()));
      expect(after[0] - after[2], greaterThan(0.02));
      // Same stats → (almost) nothing to do.
      final same = Realism.matchParams(pl, pl);
      for (final v in same['gain']!) {
        expect(v, closeTo(100, 0.5));
      }
      expect(same['saturation']![0], closeTo(0, 0.5));
    });

    test('image stats are alpha-weighted and region-limited', () {
      final data = List<int>.filled(4 * 2 * 4, 0);
      void put(int x, int y, List<int> c) {
        for (int k = 0; k < 4; k++) {
          data[(y * 4 + x) * 4 + k] = c[k];
        }
      }

      for (int x = 0; x < 4; x++) {
        put(x, 0, x < 2 ? [255, 0, 0, 255] : [0, 0, 255, 255]);
        put(x, 1, [0, 255, 0, 0]); // invisible
      }
      final s = ImageStats.of(Uint8List.fromList(data), 4, 2)!;
      expect(s.r, closeTo(0.5, 1e-9));
      expect(s.g, closeTo(0, 1e-9));
      expect(s.coverage, closeTo(0.5, 1e-9));
      final left = ImageStats.of(Uint8List.fromList(data), 4, 2, region: const [0, 0, 0.5, 1])!;
      expect(left.r, closeTo(1, 1e-9));
      expect(left.b, closeTo(0, 1e-9));
    });

    test('match_colour adds a grade from the plate behind (to: "below")', () {
      final p = scene();
      final r = run(p, {'op': 'match_colour', 'layer': 'man'});
      final e = p.main.requireLayer('man').effectById('man_match')!;
      expect(e.type, 'grade');
      final g = e.params['gain']!.staticValue;
      expect(g[0], greaterThan(g[2]));
      expect(r.log.single, contains('Matched'));
      // Again: replaced, not stacked; light wrap gets the plate colour.
      run(p, {'op': 'match_color', 'layer': 'man', 'to': 'bg', 'amount': 60, 'light_wrap': true});
      final man = p.main.requireLayer('man');
      expect(man.effects.where((e) => e.type == 'grade').length, 1);
      expect(man.effectById('man_match')!.params['amount']!.staticValue, [60.0]);
      final wrap = man.effects.firstWhere((e) => e.type == 'light_wrap');
      final wc = wrap.params['color']!.staticValue;
      expect(wc[0], greaterThan(wc[2]));
      expect(() => run(p, {'op': 'match_colour', 'layer': 'man', 'to': 'man'}), throwsA(isA<CommandError>()));
    });
  });

  group('camera', () {
    test('shake noise is deterministic, smooth and bounded', () {
      for (final style in Realism.shakeStyles) {
        double maxStep = 0, maxAbs = 0;
        var prev = Realism.shakeAt(style, 0);
        for (int i = 1; i <= 2400; i++) {
          final t = i / 480;
          final s = Realism.shakeAt(style, t);
          expect(s, Realism.shakeAt(style, t), reason: 'deterministic');
          maxStep = math.max(maxStep, math.max((s.$1 - prev.$1).abs(), (s.$2 - prev.$2).abs()));
          maxAbs = math.max(maxAbs, math.max(s.$1.abs(), s.$2.abs()));
          prev = s;
        }
        expect(maxAbs, lessThan(2.5), reason: style);
        expect(maxAbs, greaterThan(0.2), reason: style);
        expect(maxStep, lessThan(0.2), reason: '$style: no jumps between 1/480 s samples');
      }
      expect(Realism.noise(3.3, 1), Realism.noise(3.3, 1));
      expect(Realism.noise(3.3, 1), isNot(Realism.noise(3.3, 2)));
    });

    test('camera_shake: eased envelope on a 3D camera, nothing outside it', () {
      final p = project();
      run(p, {'op': 'batch', 'commands': [rect('a', 400, 300, 960, 540)]});
      run(p, {'op': 'make_3d', 'start': 0, 'haze': 0});
      Vector3 pos(double t) => Evaluator.camera3D(p.main, t).position;
      final base = [for (final t in [0.5, 1.5, 2.5, 4.5]) pos(t)];
      run(p, {'op': 'camera_shake', 'start': 1, 'duration': 2, 'amount': 60, 'style': 'handheld'});
      final rig = p.main.camera;
      expect(rig.props[Realism.shakeProp]!.valueAt(0.9)[0], 0);
      expect(rig.props[Realism.shakeProp]!.valueAt(2)[0], closeTo(0.6 * 0.025 * 1080, 1e-9));
      expect(rig.props[Realism.shakeProp]!.valueAt(3.1)[0], 0);
      expect(pos(0.5).distanceTo(base[0]), lessThan(1e-9));
      expect(pos(4.5).distanceTo(base[3]), lessThan(1e-9));
      expect(pos(1.5).distanceTo(base[1]), greaterThan(1e-3), reason: 'shaking inside the window');
      // Smooth: no jumps between frames at 120 fps.
      var maxStep = 0.0;
      for (int i = 0; i < 480; i++) {
        maxStep = math.max(maxStep, pos(1 + i / 240).distanceTo(pos(1 + (i + 1) / 240)));
      }
      expect(maxStep, lessThan(3));
      // Survives save / load, as one undo step (atomic).
      final back = Project.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(Evaluator.camera3D(back.main, 2).position.distanceTo(pos(2)), lessThan(1e-9));
      expect(() => run(p, {'op': 'camera_shake', 'style': 'wobble'}), throwsA(isA<CommandError>()));
    });

    test('camera_shake on a flat comp uses the 2D camera', () {
      final p = project();
      run(p, {'op': 'batch', 'commands': [rect('a', 400, 300, 960, 540)]});
      final r = run(p, {'op': 'camera_shake', 'start': 0, 'duration': 0.8, 'amount': 80, 'style': 'impact'});
      expect(p.main.camera.mode, CameraMode.twoD);
      expect(r.log.single, contains('2D'));
      final m0 = Evaluator.camera2D(p.main, 0.9).storage[12];
      final m1 = Evaluator.camera2D(p.main, 0.1).storage[12];
      expect((m1 - m0).abs(), greaterThan(0.01));
    });

    test('depth of field follows the camera target (and a chosen layer)', () {
      final p = project();
      run(p, {
        'op': 'batch',
        'commands': [rect('sky', 1920, 1080, 960, 540, name: 'Sky'), rect('house', 300, 260, 1400, 700), rect('tree', 200, 400, 400, 700)],
      });
      run(p, {'op': 'make_3d', 'start': 0, 'haze': 0, 'bands': {'sky': 'sky', 'house': 'far', 'tree': 'near'}});
      run(p, {'op': 'set_dof', 'focus': 'target', 'aperture': 30});
      expect(p.main.dofFocus, 'target');
      run(p, {'op': 'camera_shot', 'move': 'fly_to', 'target': 'house', 'start': 0, 'duration': 3});
      RenderItem item(String id, double t) => Evaluator.evaluate(p.main, t).firstWhere((i) => i.layer.id == id);
      final cam = Evaluator.camera3D(p.main, 3);
      expect(cam.focus, closeTo(item('house', 3).depth, item('house', 3).depth * 0.05));
      expect(item('house', 3).dofBlur, lessThan(item('sky', 3).dofBlur)); // (the near tree is behind the camera by now)
      expect(item('house', 3).dofBlur, lessThan(1));
      // Smooth while scrubbing: focus changes a little per frame, never jumps.
      var maxJump = 0.0;
      for (int f = 0; f < 90; f++) {
        maxJump = math.max(maxJump, (Evaluator.camera3D(p.main, f / 30).focus - Evaluator.camera3D(p.main, (f + 1) / 30).focus).abs());
      }
      expect(maxJump, lessThan(Evaluator.camera3D(p.main, 0).focus * 0.1));
      // Focus on a layer.
      run(p, {'op': 'set_comp', 'dof': {'focus': 'tree'}});
      expect(item('tree', 0.3).dofBlur, lessThan(0.05));
      expect(item('sky', 0.3).dofBlur, greaterThan(1));
      final back = Project.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.main.dofFocus, 'tree');
      run(p, {'op': 'set_comp', 'dof': false});
      expect(p.main.dofFocus, isNull);
      expect(item('sky', 0.3).dofBlur, 0);
    });

    test('lens warp keeps corners and centre, barrel pushes edges out', () {
      for (final c in [[0.0, 0.0], [1920.0, 0.0], [1920.0, 1080.0], [0.0, 1080.0], [960.0, 540.0]]) {
        final (x, y) = Realism.lensWarp(c[0], c[1], 1920, 1080, 60);
        expect(x, closeTo(c[0], 1e-9));
        expect(y, closeTo(c[1], 1e-9));
      }
      final (bx, _) = Realism.lensWarp(1700, 540, 1920, 1080, 60);
      expect(bx, greaterThan(1700));
      final (px, _) = Realism.lensWarp(1700, 540, 1920, 1080, -60);
      expect(px, lessThan(1700));
    });
  });

  group('adjustment layers and looks', () {
    test('adjustment flag: commands, JSON, make_3d keeps it flat, evaluator keeps its stack slot', () {
      final p = project();
      run(p, {'op': 'batch', 'commands': [rect('a', 400, 300, 960, 540), rect('b', 400, 300, 600, 540)]});
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'adj', 'adjustment': true, 'color': '#00000000', 'start': 0, 'duration': 10});
      run(p, {'op': 'add_effect', 'layer': 'adj', 'effect': 'grade', 'params': {'saturation': -100}});
      run(p, {'op': 'reorder_layer', 'layer': 'adj', 'index': 1}); // between b (top) and a
      final adj = p.main.requireLayer('adj');
      expect(adj.adjustment, isTrue);
      final back = Project.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.main.requireLayer('adj').adjustment, isTrue);
      expect(adj.copy().adjustment, isTrue);
      run(p, {'op': 'make_3d', 'start': 0, 'haze': 0});
      expect(adj.is3D, isFalse);
      expect(p.main.requireLayer('a').is3D, isTrue);
      final order = Evaluator.evaluate(p.main, 1).map((i) => i.layer.id).toList();
      expect(order, ['a', 'adj', 'b'], reason: 'paint order: a below the adjustment, b above it');
      expect(() => run(p, {'op': 'update_layer', 'layer': 'a', 'adjustment': true}), throwsA(isA<CommandError>()));
      expect(() => run(p, {'op': 'make_3d', 'layers': ['adj']}), throwsA(isA<CommandError>()));
      // A null layer can be an adjustment layer too.
      run(p, {'op': 'add_layer', 'type': 'null', 'id': 'n', 'adjustment': true, 'start': 0, 'duration': 10});
      expect(Evaluator.evaluate(p.main, 1).any((i) => i.layer.id == 'n'), isTrue);
      run(p, {'op': 'update_layer', 'layer': 'n', 'adjustment': false});
      expect(Evaluator.evaluate(p.main, 1).any((i) => i.layer.id == 'n'), isFalse);
    });

    test('doc looks and film_look go on adjustment layers at the top', () {
      final p = project();
      run(p, {'op': 'batch', 'commands': [rect('a', 400, 300, 960, 540)]});
      for (final s in [...Realism.looks, Realism.filmLook]) {
        final effects = Realism.lookEffects(s);
        expect(effects.first.$1, isNotEmpty);
        for (final (type, params) in effects) {
          final def = EffectsCatalog.byType(type)!;
          for (final k in params.keys) {
            expect(def.params.any((d) => d.key == k), isTrue, reason: '$s: $type.$k');
          }
        }
      }
      run(p, {'op': 'apply_style', 'style': 'doc_teal_orange'});
      run(p, {'op': 'apply_style', 'style': 'film_look'});
      run(p, {'op': 'apply_style', 'style': 'doc_cold_night'}); // replaces the grade, stays under the film look
      expect(p.main.layers.map((l) => l.id).toList(), ['film_look', 'look', 'a']);
      final look = p.main.requireLayer('look');
      expect(look.adjustment, isTrue);
      expect(look.name, contains('Cold night'));
      expect(look.width, 1920);
      expect(look.duration, greaterThanOrEqualTo(p.main.duration));
      expect(p.main.requireLayer('film_look').effects.map((e) => e.type), containsAll(['grain', 'gate_weave', 'halation', 'vignette']));
      // Old styles still work per layer.
      expect(() => run(p, {'op': 'apply_style', 'style': 'nope'}), throwsA(isA<CommandError>()));
    });

    test('helpers: channel matrices add up, glow keeps only highlights', () {
      final sum = List<double>.filled(20, 0);
      for (int c = 0; c < 3; c++) {
        final m = channelMatrix(c);
        expect(m.length, 20);
        for (int i = 0; i < 20; i++) {
          sum[i] += m[i];
        }
      }
      for (int i = 0; i < 20; i++) {
        expect(sum[i], closeTo(const [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0][i], 1e-12));
      }
      final g = glowMatrix(70, 100);
      expect(Realism.applyMatrix(g, [0.5, 0.5, 0.5])[0], 0);
      expect(Realism.applyMatrix(g, [1, 1, 1])[0], closeTo(1, 1e-9));
      expect(glowMatrix(70, 100, halation: true).length, 20);
    });

    testWidgets('canvas: adjustment effects wrap only the layers below; realism effects render', (tester) async {
      final p = scene();
      run(p, {'op': 'batch', 'commands': [rect('top', 300, 200, 300, 200)]});
      run(p, {'op': 'make_3d', 'start': 0, 'bands': {'bg': 'sky', 'man': 'mid'}});
      run(p, {'op': 'add_effect', 'layer': 'man', 'effect': 'blur', 'params': {'amount': 6}});
      run(p, {'op': 'add_effect', 'layer': 'man', 'effect': 'light_wrap'});
      run(p, {'op': 'set_effect_param', 'layer': 'man', 'effect': 'man_cshadow', 'param': 'cast', 'value': 60});
      for (final fx in ['bloom', 'chromatic_aberration', 'lens_distortion', 'glow']) {
        run(p, {'op': 'add_effect', 'layer': 'top', 'effect': fx});
      }
      run(p, {'op': 'apply_style', 'style': 'doc_golden_hour'});
      run(p, {'op': 'apply_style', 'style': 'film_look'});
      run(p, {'op': 'reorder_layer', 'layer': 'top', 'index': 0});
      run(p, {'op': 'set_dof', 'focus': 'man', 'aperture': 25});
      run(p, {'op': 'camera_shake', 'start': 0, 'duration': 2, 'style': 'walk'});
      for (final draft in [false, true]) {
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: FittedBox(
              child: CompositionCanvas(project: p, time: 1, draft: draft, previewScale: draft ? 0.5 : null),
            ),
          ),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull);
        final top = find.byKey(const ValueKey('top'));
        final man = find.byKey(const ValueKey('man'));
        expect(top, findsOneWidget);
        expect(man, findsOneWidget);
        // The grade of the look is above `man` (below the adjustment layer) but not above `top`.
        Finder graded(Finder f) => find.ancestor(of: f, matching: find.byKey(const ValueKey('look#adjust')));
        expect(graded(man), findsOneWidget);
        expect(graded(top), findsNothing);
        expect(find.byType(FxSnapshot), findsWidgets);
      }
    });

    test('documented for the AI', () {
      for (final w in [
        'match_colour', 'camera_shake', 'set_dof', 'adjustment: true', 'contact_shadow', 'light_wrap', 'haze', 'bloom',
        'chromatic_aberration', 'lens_distortion', 'film_look', ...Realism.looks,
      ]) {
        expect(commandSpec, contains(w), reason: w);
      }
      for (final op in ['match_colour', 'camera_shake', 'set_dof']) {
        expect(EditCommands.ops, contains(op));
      }
    });
  });
}
