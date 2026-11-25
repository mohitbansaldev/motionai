// V2-E (Depth from photo): depth pre/post-processing, layer splitting,
// placement maths of photo_to_3d and the fake-depth fallback. Everything
// here is pure Dart; the real ONNX depth model needs a Windows run (see the
// report: verify photo_to_3d with model "depth" live).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motionai/core/commands/depth_commands.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/depth/depth_map.dart';
import 'package:motionai/core/depth/depth_math.dart';
import 'package:motionai/core/depth/depth_place.dart';
import 'package:motionai/core/depth/layer_split.dart';
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/model/camera.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/scene3d.dart';
import 'package:motionai/platform/windows_ai/depth.dart';
import 'package:motionai/platform/windows_ai/image_io.dart';
import 'package:motionai/platform/windows_ai/inpaint.dart';
import 'package:motionai/platform/windows_ai/model_store.dart';

/// Deterministic textured RGBA test picture.
Uint8List _picture(int w, int h) {
  final d = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      d[i] = (x * 37 + y * 11) & 0xFF;
      d[i + 1] = (x * 13 + y * 29 + 40) & 0xFF;
      d[i + 2] = (x * 7 ^ y * 17) & 0xFF;
      d[i + 3] = 255;
    }
  }
  return d;
}

/// Depth: a left→right ramp (far…mid) with a near block.
DepthMap _depth(int w, int h, {int bx0 = 20, int by0 = 10, int bx1 = 44, int by1 = 32}) {
  final v = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final inBlock = x >= bx0 && x < bx1 && y >= by0 && y < by1;
      v[y * w + x] = inBlock ? 0.95 : 0.5 * x / (w - 1);
    }
  }
  return DepthMap(w, h, v);
}

Uint8List _realInpaint(Uint8List rgba, int w, int h, Uint8List hole) => Inpaint.fill(Rgba(w, h, rgba), hole).data;

Project _project() {
  final p = Project(id: 'p', name: 'Depth', main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: 10));
  p.media['photo'] = MediaAsset(id: 'photo', type: MediaType.image, path: '/photo.jpg', name: 'fort', width: 1920, height: 1080);
  p.media['clip'] = MediaAsset(id: 'clip', type: MediaType.video, path: '/clip.mp4', name: 'clip', width: 1920, height: 1080, duration: 4);
  return p;
}

void main() {
  group('preprocessing', () {
    test('input size: short side near 518, multiples of 14, long side capped', () {
      expect(DepthPrep.inputSize(1920, 1080), (924, 518));
      expect(DepthPrep.inputSize(518, 518), (518, 518));
      for (final (w, h) in const [(4000, 1000), (1080, 1920), (333, 777), (50, 30)]) {
        final (tw, th) = DepthPrep.inputSize(w, h);
        expect(tw % 14, 0);
        expect(th % 14, 0);
        expect(math.max(tw, th), lessThanOrEqualTo(DepthPrep.maxLong));
        expect((tw / th - w / h).abs() / (w / h), lessThan(0.1), reason: 'aspect kept for ${w}x$h');
      }
    });

    test('tensor is NCHW float32 with ImageNet mean/std', () {
      final rgba = Uint8List(28 * 28 * 4);
      for (var i = 0; i < 28 * 28; i++) {
        rgba[i * 4] = 255;
        rgba[i * 4 + 3] = 255;
      }
      final t = DepthPrep.inputTensor(rgba, 28, 28, 14, 7);
      expect(t.length, 3 * 14 * 7);
      const plane = 14 * 7;
      expect(t[0], closeTo((1 - 0.485) / 0.229, 1e-5));
      expect(t[plane - 1], closeTo((1 - 0.485) / 0.229, 1e-5));
      expect(t[plane], closeTo((0 - 0.456) / 0.224, 1e-5));
      expect(t[2 * plane + 5], closeTo((0 - 0.406) / 0.225, 1e-5));
    });

    test('prediction → 0..1 depth at photo size, order kept, flat map safe', () {
      final out = Float32List(28 * 14);
      for (var y = 0; y < 14; y++) {
        for (var x = 0; x < 28; x++) {
          out[y * 28 + x] = 3.0 + y * 0.7; // inverse depth grows downwards (nearer)
        }
      }
      final img = _picture(56, 28);
      final d = DepthPrep.fromPrediction(out, 28, 14, img, 56, 28);
      expect(d.width, 56);
      expect(d.height, 28);
      double row(int y) => [for (var x = 0; x < 56; x++) d.at(x, y)].reduce((a, b) => a + b) / 56;
      expect(row(0), lessThan(row(27)));
      expect(d.values.every((v) => v >= 0 && v <= 1), isTrue);
      final flat = DepthPrep.normalize(Float32List.fromList(List.filled(20, 7.0)));
      expect(flat.every((v) => v == 0.5), isTrue);
    });
  });

  group('maths', () {
    test('mirror, dilate (mask growth) and majority', () {
      expect([for (var i = -3; i < 8; i++) DepthMath.mirror(i, 5)], [2, 1, 0, 0, 1, 2, 3, 4, 4, 3, 2]);
      final m = Uint8List(11 * 11)..[5 * 11 + 5] = 1;
      final g = DepthMath.dilate(m, 11, 11, 2);
      expect(g.where((v) => v == 1).length, 25);
      expect(g[3 * 11 + 3], 1);
      expect(g[2 * 11 + 5], 0);
      final corner = DepthMath.dilate(Uint8List(11 * 11)..[0] = 1, 11, 11, 2);
      expect(corner.where((v) => v == 1).length, 9);
      expect(DepthMath.majority(m, 11, 11, 1).every((v) => v == 0), isTrue, reason: 'a speck is removed');
    });

    test('quantile thresholds split evenly and stay increasing', () {
      final ramp = Float32List.fromList([for (var i = 0; i < 1000; i++) i / 999]);
      final ts = DepthSplit.thresholds(ramp, 4);
      expect(ts.length, 3);
      expect(ts[0], closeTo(0.25, 0.01));
      expect(ts[1], closeTo(0.5, 0.01));
      expect(ts[2], closeTo(0.75, 0.01));
      final flat = DepthSplit.thresholds(Float32List.fromList(List.filled(100, 0.5)), 5);
      for (var i = 1; i < flat.length; i++) {
        expect(flat[i], greaterThan(flat[i - 1]));
      }
    });

    test('matte feathering: solid core, linear fade over r px, guide only lowers it', () {
      const w = 50, h = 50, r = 4;
      final core = Uint8List(w * h);
      for (var y = 15; y < 35; y++) {
        for (var x = 15; x < 35; x++) {
          core[y * w + x] = 1;
        }
      }
      final a = DepthSplit.feather(core, w, h, r);
      expect(a[25 * w + 20], 1);
      var prev = 1.0;
      for (var d = 1; d <= r; d++) {
        final v = a[25 * w + 15 - d];
        expect(v, greaterThan(0));
        expect(v, lessThan(prev));
        expect(v, closeTo(2 * (r - d + 1) / (2 * r + 1), 1e-5));
        prev = v;
      }
      expect(a[25 * w + 15 - r - 1], 0);
      final guide = Float32List(w * h);
      for (var i = 0; i < w * h; i++) {
        guide[i] = (i % w) < 13 ? 0.1 : 0.9; // a photo edge 2 px outside the core
      }
      final ga = DepthSplit.feather(core, w, h, r, guide: guide);
      for (var i = 0; i < w * h; i++) {
        if (core[i] != 0) expect(ga[i], 1);
        expect(ga[i], lessThanOrEqualTo(a[i] + 1e-6));
      }
      double outside(Float32List m) => [for (var y = 20; y < 30; y++) m[y * w + 11] + m[y * w + 12]].reduce((x, y) => x + y);
      expect(outside(ga), lessThan(outside(a)), reason: 'the matte is pulled back at the photo edge');
    });

    test('depth factors: far behind, near in front, strictly decreasing', () {
      final f = DepthPlace.factors([0.1, 0.4, 0.7, 0.95]);
      expect(f.first, greaterThan(1.5));
      expect(f.last, lessThan(0.8));
      for (var i = 1; i < f.length; i++) {
        expect(f[i], lessThan(f[i - 1]));
      }
      final deeper = DepthPlace.factors([0.1, 0.95], intensity: 1);
      expect(deeper.first, greaterThan(f.first));
      expect(deeper.last, lessThan(f.last));
    });
  });

  group('layer split', () {
    test('stack composites back to the photo exactly (with and without margin)', () {
      const w = 64, h = 42;
      final img = _picture(w, h);
      for (final pad in [0, 5]) {
        final layers = DepthSplit.split(img, w, h, _depth(w, h), layers: 3, pad: pad, inpaint: _realInpaint);
        expect(layers.length, 3);
        expect(layers.first.x, -pad);
        expect(layers.first.width, w + 2 * pad);
        expect(layers.first.rgba.length, (w + 2 * pad) * (h + 2 * pad) * 4);
        for (var i = 3; i < layers.first.rgba.length; i += 4) {
          expect(layers.first.rgba[i], 255, reason: 'far layer is opaque');
        }
        for (var k = 1; k < layers.length; k++) {
          expect(layers[k].depth, greaterThan(layers[k - 1].depth));
        }
        expect(layers.last.width, lessThan(w), reason: 'near layer is cropped to its matte');
        final comp = DepthSplit.composite(layers, w, h);
        var worst = 0;
        for (var i = 0; i < w * h; i++) {
          for (var c = 0; c < 3; c++) {
            worst = math.max(worst, (comp[i * 4 + c] - img[i * 4 + c]).abs());
          }
        }
        expect(worst, lessThanOrEqualTo(1), reason: 'pad $pad');
      }
    });

    test('inpaint hole = nearer region grown by a few px; filled behind it', () {
      const w = 64, h = 42;
      final img = _picture(w, h);
      final holes = <Uint8List>[];
      Uint8List spy(Uint8List rgba, int w, int h, Uint8List hole) {
        holes.add(Uint8List.fromList(hole));
        return _realInpaint(rgba, w, h, hole);
      }

      final layers = DepthSplit.split(img, w, h, _depth(w, h), layers: 2, inpaint: spy);
      expect(holes.length, 1);
      final hole = holes.single;
      final g = DepthSplit.growRadius(w, h);
      expect(hole[21 * w + 30], 1, reason: 'inside the near block');
      expect(hole[21 * w + 20 - g], 1, reason: 'grown $g px');
      expect(hole[21 * w + 20 - g - 2], 0);
      final blockPx = 24 * 22;
      expect(hole.where((v) => v == 1).length, greaterThan(blockPx));
      final far = layers.first.rgba;
      final i = (21 * w + 30) * 4;
      expect([far[i], far[i + 1], far[i + 2]], isNot([img[i], img[i + 1], img[i + 2]]), reason: 'filled, not the near object');
    });
  });

  group('fallback depth', () {
    test('fake depth: sky far, textured ground near', () {
      const w = 64, h = 48;
      final d = Uint8List(w * h * 4);
      final rnd = math.Random(3);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          if (y < h / 2) {
            d[i] = 120;
            d[i + 1] = 170;
            d[i + 2] = 235;
          } else {
            d[i] = 60 + rnd.nextInt(90);
            d[i + 1] = 70 + rnd.nextInt(90);
            d[i + 2] = 20 + rnd.nextInt(40);
          }
          d[i + 3] = 255;
        }
      }
      final m = DepthPrep.fake(d, w, h);
      double mean(int y0, int y1) {
        var s = 0.0;
        for (var y = y0; y < y1; y++) {
          for (var x = 0; x < w; x++) {
            s += m.at(x, y);
          }
        }
        return s / ((y1 - y0) * w);
      }

      expect(mean(0, 16), lessThan(mean(32, 48)));
      expect(m.values.every((v) => v >= 0 && v <= 1), isTrue);
    });

    test('no model or a broken model → fake depth; "depth" requires the model', () {
      final src = Rgba(32, 24, _picture(32, 24));
      final (a, used, note) = Depth.depthOf(src);
      expect(used, 'fake');
      expect(note, isNull);
      expect(a.width, 32);
      final (_, used2, note2) = Depth.depthOf(src, ortLibrary: '/nonexistent/libonnxruntime.so', modelPath: '/nonexistent/m.onnx');
      expect(used2, 'fake');
      expect(note2, contains('depth model failed'));
      expect(() => Depth.depthOf(src, requireModel: true), throwsA(anything));
    });

    test('file pipelines write PNG layers and a depth map', () {
      final dir = Directory.systemTemp.createTempSync('v2depth');
      addTearDown(() => dir.deleteSync(recursive: true));
      final photo = '${dir.path}/photo.png';
      ImageIo.writePng(photo, Rgba(64, 40, _picture(64, 40)));
      final res = Depth.photoTo3dFile(path: photo, outPrefix: '${dir.path}/d', mediaWidth: 128, layers: 4, pad: 0.08);
      expect(res['model'], 'fake');
      final layers = (res['layers'] as List).cast<Map>();
      expect(layers.length, inInclusiveRange(2, 4));
      expect(layers.first['x'], -10.0, reason: '5 px margin × 2 (photo is 128 px wide in the project)');
      expect(layers.first['k'], 2.0);
      for (final l in layers) {
        expect(File('${l['path']}').existsSync(), isTrue);
      }
      final dm = Depth.depthMapFile(path: photo, outPath: '${dir.path}/map.png');
      expect(dm['w'], 64);
      final back = ImageIo.toRgba(ImageIo.readUpright('${dir.path}/map.png'));
      expect(back.data[0], back.data[1], reason: 'grayscale');
    });
  });

  group('photo_to_3d', () {
    late Project p;
    DepthRequest? req;
    setUp(() {
      p = _project();
      req = null;
      DepthCommands.launcher = (r) {
        req = r;
        return 'depth_1';
      };
      EditCommands.runAtomic(p, {'op': 'add_layer', 'type': 'image', 'media': 'photo', 'id': 'P', 'start': 0, 'duration': 6, 'fit': 'cover'});
    });
    tearDown(() => DepthCommands.launcher = null);

    test('validates and starts a background job', () {
      final r = EditCommands.runAtomic(p, {'op': 'photo_to_3d', 'media': 'photo'});
      expect(r.log.single, contains('depth_1'));
      expect(req!.kind, 'photo_to_3d');
      expect(req!.layers, 4);
      expect(req!.pad, DepthCommands.padFraction, reason: 'the photo fills the frame');
      expect(req!.command['layer'], 'P');
      expect(req!.command['start'], 0);
      expect(p.main.layers.length, 1, reason: 'nothing changes until the job is done');

      EditCommands.runAtomic(p, {'op': 'update_layer', 'layer': 'P', 'scale': [50, 50, 100]});
      EditCommands.runAtomic(p, {'op': 'photo_to_3d', 'layer': 'P'});
      expect(req!.pad, 0, reason: 'a smaller photo gets no margin');

      EditCommands.runAtomic(p, {'op': 'depth_map', 'media': 'photo'});
      expect(req!.kind, 'depth_map');

      expect(() => EditCommands.runAtomic(p, {'op': 'photo_to_3d', 'media': 'clip'}), throwsA(isA<CommandError>()));
      expect(() => EditCommands.runAtomic(p, {'op': 'photo_to_3d', 'media': 'photo', 'layers': 9}), throwsA(isA<CommandError>()));
      expect(() => EditCommands.runAtomic(p, {'op': 'photo_to_3d', 'media': 'photo', 'camera': 'spin'}), throwsA(isA<CommandError>()));
      expect(() => EditCommands.runAtomic(p, {'op': 'photo_to_3d', 'media': 'photo', 'model': 'big'}), throwsA(isA<CommandError>()));
      DepthCommands.launcher = null;
      expect(() => EditCommands.runAtomic(p, {'op': 'photo_to_3d', 'media': 'photo'}),
          throwsA(isA<CommandError>().having((e) => e.message, 'message', contains('MotionAI app'))));
    });

    Map<String, dynamic> prepared() {
      p.media['d0'] = MediaAsset(id: 'd0', type: MediaType.image, path: '/d0.png', name: 'far', width: 2228, height: 1388);
      p.media['d1'] = MediaAsset(id: 'd1', type: MediaType.image, path: '/d1.png', name: 'mid', width: 800, height: 500);
      p.media['d2'] = MediaAsset(id: 'd2', type: MediaType.image, path: '/d2.png', name: 'near', width: 480, height: 270);
      return {
        'model': 'fake',
        'layers': [
          {'media': 'd0', 'x': -154, 'y': -154, 'k': 1, 'depth': 0.1},
          {'media': 'd1', 'x': 400, 'y': 300, 'k': 1, 'depth': 0.5},
          {'media': 'd2', 'x': 960, 'y': 540, 'k': 2, 'depth': 0.9}, // half-resolution layer
        ],
      };
    }

    const offsets = {
      'd0': (-154.0, -154.0, 1.0),
      'd1': (400.0, 300.0, 1.0),
      'd2': (960.0, 540.0, 2.0),
    };

    void expectFirstFrameIdentical(Map<String, RenderItem> orig, {Set<String> skip = const {}}) {
      final items = {for (final it in Evaluator.evaluate(p.main, 0)) it.layer.mediaId: it};
      final o = orig['photo']!;
      for (final e in offsets.entries) {
        if (skip.contains(e.key)) continue;
        final it = items[e.key]!;
        final (x, y, k) = e.value;
        for (final (u, v) in [(0.0, 0.0), (100.0, 37.0), (it.layer.width, it.layer.height)]) {
          final got = it.project(u, v), want = o.project(x + k * u, y + k * v);
          expect(got.x, closeTo(want.x, 1e-3), reason: '${e.key} ($u,$v)');
          expect(got.y, closeTo(want.y, 1e-3), reason: '${e.key} ($u,$v)');
        }
      }
    }

    test('places the layers exactly over the photo, at depth, one step', () {
      p.main.layerById('P')!.effects
        ..add(Effect(id: 'v', type: 'vignette', params: {}))
        ..add(Effect(id: 'c', type: 'color', params: {}));
      final orig = {for (final it in Evaluator.evaluate(p.main, 0)) it.layer.mediaId!: it};
      EditCommands.runAtomic(p, {'op': 'photo_to_3d', 'media': 'photo', 'camera': 'none'});
      final r = EditCommands.runAtomic(p, {...req!.command, 'prepared': prepared()});
      final comp = p.main;
      expect(r.createdIds.length, 3);
      expect(comp.camera.mode, CameraMode.threeD);
      expect(comp.layerById('P')!.visible, isFalse);
      expect([for (final l in comp.layers) l.mediaId], ['d2', 'd1', 'd0', 'photo'], reason: 'near on top');
      final z0 = Scene3D.homeZoom(comp);
      final f = [for (final m in ['d0', 'd1', 'd2']) (comp.layers.firstWhere((l) => l.mediaId == m).prop(Props.position).staticValue[2] + z0) / z0];
      expect(f, DepthPlace.factors([0.1, 0.5, 0.9]).map((x) => closeTo(x, 1e-9)).toList());
      final far = comp.layers.firstWhere((l) => l.mediaId == 'd0'), near = comp.layers.firstWhere((l) => l.mediaId == 'd2');
      expect(far.effects.map((e) => e.type), ['vignette', 'color']);
      expect(near.effects.map((e) => e.type), ['color'], reason: 'frame-wide looks are not stacked');
      expect(near.start, 0);
      expect(near.duration, 6);
      expectFirstFrameIdentical(orig);
    });

    test('default camera move keeps the first frame and moves the camera', () {
      final orig = {for (final it in Evaluator.evaluate(p.main, 0)) it.layer.mediaId!: it};
      EditCommands.runAtomic(p, {'op': 'photo_to_3d', 'media': 'photo'});
      EditCommands.runAtomic(p, {...req!.command, 'prepared': prepared()});
      final cam = p.main.camera.prop(CamProps.position);
      expect(cam.isAnimated, isTrue);
      expect((cam.valueAt(6)[0] - cam.valueAt(0)[0]).abs() + (cam.valueAt(6)[2] - cam.valueAt(0)[2]).abs(), greaterThan(1));
      expectFirstFrameIdentical(orig, skip: {'d0'}); // the far plate may grow to hide edges
    });

    test('a photo without a layer gets a full-frame one', () {
      p.main.layers.clear();
      EditCommands.runAtomic(p, {'op': 'photo_to_3d', 'media': 'photo', 'start': 1, 'duration': 4, 'camera': {'move': 'drift', 'intensity': 0.3}});
      expect(req!.pad, DepthCommands.padFraction);
      final r = EditCommands.runAtomic(p, {...req!.command, 'prepared': prepared()});
      expect(p.main.layers.length, 3, reason: 'the helper layer is not kept');
      expect(r.createdIds.length, 3);
      expect(p.main.layers.every((l) => l.is3D && l.start == 1), isTrue);
    });
  });

  group('model store without a pinned hash', () {
    final data = Uint8List.fromList(List.generate(200000, (i) => (i * 7) & 0xFF));
    var hits = 0;
    late Directory dir;
    setUp(() {
      hits = 0;
      dir = Directory.systemTemp.createTempSync('v2depth_models');
      ModelStore.modelsDir = () async => dir;
      ModelStore.httpClient = () => MockClient.streaming((req, body) async {
            hits++;
            return http.StreamedResponse(Stream.value(data), 200, contentLength: data.length);
          });
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('checks the size, records the sha256 and reuses the file', () async {
      final spec = ModelSpec(fileName: 'd.onnx', urls: const ['https://models.example/d.onnx'], bytes: data.length + 1000, hashKind: HashKind.sha256, hash: '', label: 'depth');
      final path = await ModelStore.ensure(spec);
      expect(File(path).lengthSync(), data.length);
      expect(File('$path.sha256').readAsStringSync(), startsWith(sha256.convert(data).toString()));
      await ModelStore.ensure(spec);
      expect(hits, 1);
    });

    test('rejects a download of the wrong size', () async {
      final spec = ModelSpec(fileName: 'e.onnx', urls: const ['https://models.example/e.onnx'], bytes: data.length * 3, hashKind: HashKind.sha256, hash: '', label: 'depth');
      await expectLater(ModelStore.ensure(spec), throwsA(isA<HttpException>()));
    });

    test('depth model spec points at Depth Anything V2 Small', () {
      expect(Depth.model.urls.first, contains('depth-anything-v2-small'));
      expect(Depth.model.urls.every((u) => u.startsWith('https://huggingface.co/')), isTrue);
    });
  });
}
