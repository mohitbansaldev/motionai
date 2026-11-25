// CHROMA (Agent M): green screen keyer tests (CPU maths, auto colour,
// effect params/commands, rendering through CompositionCanvas).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as imglib;
import 'package:motionai/ai/command_spec.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/engine/chroma.dart';
import 'package:motionai/core/model/effects_catalog.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/ui/preview/composition_canvas.dart';
import 'package:motionai/ui/preview/fx/chroma_key.dart';

const key = ChromaSettings(); // default chroma green (0,177,64)

/// One row of pixels [colors] (opaque) → straight RGBA.
Uint8List row(List<List<int>> colors) {
  final out = Uint8List(colors.length * 4);
  for (int i = 0; i < colors.length; i++) {
    out.setAll(i * 4, [colors[i][0], colors[i][1], colors[i][2], 255]);
  }
  return out;
}

int alphaAt(Uint8List rgba, int i) => rgba[i * 4 + 3];

Project project({double w = 200, double h = 100, int bg = 0xFFFF0000}) => Project(
      id: 'p',
      name: 'chroma',
      main: Composition(id: 'main', name: 'Main', width: w, height: h, fps: 30, duration: 5, background: bg),
    );

void run(Project p, Map<String, dynamic> c) => EditCommands.runAtomic(p, c);

Project roundTrip(Project p) => Project.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);

void main() {
  group('CPU keyer', () {
    test('screen greens key out, subject colours stay', () {
      final keyed = [
        [0, 177, 64], // the key
        [0, 255, 0], // pure green
        [0, 90, 32], // shadow on the screen
        [60, 200, 100], // lighter / uneven screen
      ];
      final kept = [
        [224, 172, 140], // light skin
        [141, 85, 36], // dark skin
        [255, 255, 255], // white shirt
        [0, 0, 0], // black
        [30, 25, 20], // dark hair
        [128, 128, 128], // grey
        [200, 30, 30], // red
        [30, 60, 200], // blue
        [230, 220, 40], // yellow
      ];
      final out = ChromaMath.key(row([...keyed, ...kept]), keyed.length + kept.length, 1, key);
      for (int i = 0; i < keyed.length; i++) {
        expect(alphaAt(out, i), lessThanOrEqualTo(3), reason: 'keyed ${keyed[i]}');
      }
      for (int i = 0; i < kept.length; i++) {
        expect(alphaAt(out, keyed.length + i), 255, reason: 'kept ${kept[i]}');
      }
      expect(ChromaMath.alphaOf(0, 177, 64, key), 0);
      expect(ChromaMath.alphaOf(224, 172, 140, key), 1);
    });

    test('soft edge between screen and subject', () {
      // Blend green → skin in 21 steps: alpha rises monotonically 0 → 1
      // with in-between values (feathered edge).
      final colors = <List<int>>[];
      for (int i = 0; i <= 20; i++) {
        final t = i / 20;
        colors.add([
          (0 + (224 - 0) * t).round(),
          (177 + (172 - 177) * t).round(),
          (64 + (140 - 64) * t).round(),
        ]);
      }
      final out = ChromaMath.key(row(colors), colors.length, 1, key);
      final a = [for (int i = 0; i < colors.length; i++) alphaAt(out, i)];
      expect(a.first, 0);
      expect(a.last, 255);
      for (int i = 1; i < a.length; i++) {
        expect(a[i], greaterThanOrEqualTo(a[i - 1]), reason: '$a');
      }
      expect(a.where((v) => v > 5 && v < 250), isNotEmpty, reason: '$a');
      // More softness → a wider ramp.
      final soft = ChromaMath.key(row(colors), colors.length, 1, const ChromaSettings(softness: 80));
      final partialSoft = [for (int i = 0; i < colors.length; i++) alphaAt(soft, i)].where((v) => v > 5 && v < 250).length;
      expect(partialSoft, greaterThan(a.where((v) => v > 5 && v < 250).length));
    });

    test('tolerance widens the keyed range', () {
      const pale = [110, 190, 130]; // pale green: kept at low tolerance
      expect(ChromaMath.alphaOf(110, 190, 130, const ChromaSettings(tolerance: 10)), greaterThan(0.5));
      expect(ChromaMath.alphaOf(pale[0].toDouble(), 190, 130, const ChromaSettings(tolerance: 90)), lessThan(0.05));
    });

    test('spill suppression neutralises green fringes, keeps skin', () {
      const fringe = [112, 174, 102]; // half green, half skin (hair edge)
      final noSpill = ChromaMath.key(row([fringe]), 1, 1, const ChromaSettings(spill: 0));
      final spill = ChromaMath.key(row([fringe]), 1, 1, const ChromaSettings(spill: 100));
      int greenExcess(Uint8List p) => p[1] - (p[0] > p[2] ? p[0] : p[2]);
      expect(greenExcess(noSpill), greaterThan(50));
      expect(greenExcess(spill), lessThan(greenExcess(noSpill) ~/ 3));
      // Luma is kept (±3).
      double luma(Uint8List p) => 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2];
      expect((luma(spill) - luma(noSpill)).abs(), lessThan(3));
      // Skin and white are untouched.
      expect(ChromaMath.despill(224, 172, 140, const ChromaSettings(spill: 100)), (224, 172, 140));
      expect(ChromaMath.despill(255, 255, 255, const ChromaSettings(spill: 100)), (255, 255, 255));
    });

    test('choke shrinks and grows the matte', () {
      // 20 px: 10 green then 10 skin.
      final colors = [for (int i = 0; i < 20; i++) i < 10 ? [0, 177, 64] : [224, 172, 140]];
      final base = ChromaMath.key(row(colors), 20, 1, key);
      final shrink = ChromaMath.key(row(colors), 20, 1, key, chokePx: 3);
      final grow = ChromaMath.key(row(colors), 20, 1, key, chokePx: -3);
      expect(alphaAt(base, 10), 255);
      expect(alphaAt(base, 9), 0);
      expect(alphaAt(shrink, 11), 0, reason: 'edge eaten by 3 px');
      expect(alphaAt(shrink, 15), 255);
      expect(alphaAt(grow, 8), 255, reason: 'edge grown by 3 px');
      expect(alphaAt(grow, 2), 0);
    });

    test('matte view and contrast', () {
      final colors = [
        [0, 177, 64],
        [224, 172, 140],
        [112, 174, 102],
      ];
      final m = ChromaMath.key(row(colors), 3, 1, const ChromaSettings(matte: true, softness: 80));
      expect(m.sublist(0, 4), [0, 0, 0, 255]);
      expect(m.sublist(4, 8), [255, 255, 255, 255]);
      expect(m[8], m[9]);
      expect(m[11], 255);
      // Contrast pushes partial alpha towards 0 / 1.
      final soft = ChromaMath.key(row(colors), 3, 1, const ChromaSettings(softness: 80));
      final hard = ChromaMath.key(row(colors), 3, 1, const ChromaSettings(softness: 80, contrast: 100));
      final a0 = alphaAt(soft, 2), a1 = alphaAt(hard, 2);
      expect((a1 - 127.5).abs(), greaterThanOrEqualTo((a0 - 127.5).abs()));
    });

    test('blue screen key', () {
      const blue = ChromaSettings(r: 0, g: 71, b: 187);
      expect(ChromaMath.alphaOf(0, 71, 187, blue), 0);
      expect(ChromaMath.alphaOf(20, 90, 230, blue), lessThan(0.05));
      expect(ChromaMath.alphaOf(224, 172, 140, blue), 1);
      expect(ChromaMath.alphaOf(0, 177, 64, blue), 1, reason: 'green is not keyed by a blue key');
    });

    test('a grey key colour keys nothing; source alpha is kept', () {
      const grey = ChromaSettings(r: 128, g: 128, b: 128);
      final out = ChromaMath.key(row([
        [0, 177, 64]
      ]), 1, 1, grey);
      expect(out[3], 255);
      final px = Uint8List.fromList([224, 172, 140, 100]);
      expect(ChromaMath.key(px, 1, 1, key)[3], 100);
    });
  });

  group('auto key colour', () {
    Uint8List frame(int w, int h, List<int> screen, {int seed = 1}) {
      final out = Uint8List(w * h * 4);
      var s = seed;
      int noise() {
        s = (s * 1103515245 + 12345) & 0x7FFFFFFF;
        return (s >> 16) % 13 - 6;
      }

      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final o = (y * w + x) * 4;
          // Presenter: a skin/dark block in the middle, down to the bottom edge.
          final person = x > w * 0.35 && x < w * 0.65 && y > h * 0.15;
          final c = person ? (y < h * 0.45 ? [224, 172, 140] : [40, 40, 60]) : screen;
          out[o] = (c[0] + noise()).clamp(0, 255);
          out[o + 1] = (c[1] + noise()).clamp(0, 255);
          out[o + 2] = (c[2] + noise()).clamp(0, 255);
          out[o + 3] = 255;
        }
      }
      return out;
    }

    test('detects a green screen from the frame borders', () {
      final k = ChromaMath.detectKeyColor(frame(320, 180, [20, 185, 75]), 320, 180)!;
      expect((k[0] - 20).abs(), lessThanOrEqualTo(4));
      expect((k[1] - 185).abs(), lessThanOrEqualTo(4));
      expect((k[2] - 75).abs(), lessThanOrEqualTo(4));
    });

    test('detects a blue screen', () {
      final k = ChromaMath.detectKeyColor(frame(320, 180, [10, 70, 190]), 320, 180)!;
      expect(k[2], greaterThan(170));
      expect(k[1], lessThan(90));
    });

    test('no screen → null', () {
      expect(ChromaMath.detectKeyColor(frame(320, 180, [120, 110, 100]), 320, 180), isNull);
      expect(ChromaMath.detectKeyColor(Uint8List(0), 0, 0), isNull);
    });

    test('detected colour keys its own screen', () {
      final f = frame(160, 90, [20, 185, 75]);
      final k = ChromaMath.detectKeyColor(f, 160, 90)!;
      final s = ChromaSettings(r: k[0].toDouble(), g: k[1].toDouble(), b: k[2].toDouble());
      final out = ChromaMath.key(f, 160, 90, s);
      expect(alphaAt(out, 5 * 160 + 5), 0); // screen corner
      expect(alphaAt(out, 30 * 160 + 80), 255); // face
      expect(ChromaMath.hex(k), startsWith('#'));
      expect(ChromaMath.hex([0, 177, 64]), '#00B140');
    });

    test('isolate detection matches', () async {
      final f = frame(640, 360, [20, 185, 75]);
      expect(await ChromaKeyer.detect(f, 640, 360), ChromaMath.detectKeyColor(f, 640, 360));
    });
  });

  group('effect + commands', () {
    test('catalog entry', () {
      final def = EffectsCatalog.byType('chroma_key')!;
      expect(def.category, 'keying');
      expect(EffectsCatalog.categories, contains('keying'));
      expect(EffectsCatalog.categoryLabel('keying'), contains('Keying'));
      expect([for (final p in def.params) p.key], ['color', 'tolerance', 'softness', 'spill', 'choke', 'contrast', 'view']);
      expect(EffectsCatalog.paramDef('chroma_key', 'color')!.defaultValue, [0, 177, 64]);
      expect(EffectsCatalog.paramDef('chroma_key', 'view')!.options, ['final', 'matte']);
      expect(EffectsCatalog.paramDef('chroma_key', 'choke')!.min, -50);
      final e = EffectsCatalog.create('chroma_key', 'k');
      expect(ChromaSettings.fromEffect(e, 0), const ChromaSettings());
    });

    test('add_effect with "#RRGGBB", names and options; round-trip', () {
      final p = project();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 's'});
      run(p, {
        'op': 'add_effect',
        'layer': 's',
        'effect': 'chroma_key',
        'id': 'ck',
        'params': {'color': '#10C050', 'tolerance': 60, 'softness': 30, 'spill': 80, 'choke': -12, 'contrast': 25, 'view': 'matte'},
      });
      final q = roundTrip(p);
      final e = q.main.requireLayer('s').effects.single;
      expect(e.type, 'chroma_key');
      final s = ChromaSettings.fromEffect(e, 0);
      expect(s, const ChromaSettings(r: 16, g: 192, b: 80, tolerance: 60, softness: 30, spill: 80, choke: -12, contrast: 25, matte: true));
      expect(chromaEffectOf(q.main.requireLayer('s')), isNotNull);

      run(p, {'op': 'set_effect_param', 'layer': 's', 'effect': 'ck', 'param': 'view', 'value': 'final'});
      run(p, {'op': 'set_effect_param', 'layer': 's', 'effect': 'ck', 'param': 'color', 'value': 'blue'});
      final s2 = ChromaSettings.fromEffect(p.main.requireLayer('s').effects.single, 0);
      expect(s2.matte, isFalse);
      expect([s2.r, s2.g, s2.b], kChromaNamedColors['blue']);

      run(p, {'op': 'add_effect', 'layer': 's', 'effect': 'chroma_key', 'params': {'color': 'green'}});
      expect(p.main.requireLayer('s').effects.last.params['color']!.staticValue, [0, 177, 64]);
    });

    test('bad values are rejected', () {
      final p = project();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 's'});
      expect(() => run(p, {'op': 'add_effect', 'layer': 's', 'effect': 'chroma_key', 'params': {'view': 'xray'}}),
          throwsA(isA<CommandError>()));
      expect(() => run(p, {'op': 'add_effect', 'layer': 's', 'effect': 'chroma_key', 'params': {'color': 'purple-ish'}}),
          throwsA(isA<CommandError>()));
      expect(() => run(p, {'op': 'add_effect', 'layer': 's', 'effect': 'chroma_key', 'params': {'feather': 3}}),
          throwsA(isA<CommandError>()));
    });

    test('settings are clamped and animatable', () {
      final p = project();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 's'});
      run(p, {'op': 'add_effect', 'layer': 's', 'effect': 'chroma_key', 'id': 'ck', 'params': {'tolerance': 30}});
      run(p, {'op': 'set_effect_param', 'layer': 's', 'effect': 'ck', 'param': 'tolerance', 'value': 30, 'time': 0});
      run(p, {'op': 'set_effect_param', 'layer': 's', 'effect': 'ck', 'param': 'tolerance', 'value': 70, 'time': 2});
      final e = p.main.requireLayer('s').effects.single;
      expect(ChromaSettings.fromEffect(e, 1).tolerance, closeTo(50, 15));
      e.params['choke']!.staticValue = [500];
      expect(ChromaSettings.fromEffect(e, 0).choke, 50);
    });

    test('documented for the AI', () {
      expect(commandSpec, contains('chroma_key'));
      expect(commandSpec, contains('"green" | "blue"'));
      expect(commandSpec, contains('view: "final" | "matte"'));
    });
  });

  group('render', () {
    tearDown(() => ChromaKeyer.forceCpu = false);

    /// Pumps with real time in between until keying work is done.
    Future<void> settle(WidgetTester tester) async {
      for (int i = 0; i < 40; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
        await tester.pump();
        if (!ChromaKeyer.busy && i > 3) break;
      }
    }

    Future<ui.Image> frameImage(WidgetTester tester, int w, int h) async {
      // Left half green screen, right half white.
      final px = Uint8List(w * h * 4);
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final o = (y * w + x) * 4;
          px.setAll(o, x < w / 2 ? [0, 177, 64, 255] : [255, 255, 255, 255]);
        }
      }
      late ui.Image img;
      await tester.runAsync(() async {
        final c = Completer<ui.Image>();
        ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, c.complete);
        img = await c.future;
      });
      return img;
    }

    Future<List<int>> pixels(WidgetTester tester, GlobalKey key, List<List<int>> at) async {
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

    Future<void> pumpCanvas(WidgetTester tester, GlobalKey key, Project p, Map<String, ui.Image>? frames, {bool draft = false}) async {
      tester.view.physicalSize = Size(p.main.width, p.main.height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(key: key, child: CompositionCanvas(project: p, time: 1, videoFrames: frames, draft: draft)),
        ),
      ));
      expect(tester.takeException(), isNull);
    }

    Project videoProject({String view = 'final'}) {
      final p = project();
      p.media['v'] = MediaAsset(id: 'v', type: MediaType.video, path: '/green.mp4', name: 'presenter', width: 200, height: 100, duration: 5);
      run(p, {'op': 'add_layer', 'type': 'video', 'media': 'v', 'id': 'vid'});
      run(p, {'op': 'add_effect', 'layer': 'vid', 'effect': 'chroma_key', 'params': {'color': 'green', 'view': view}});
      return p;
    }

    for (final cpu in [true, false]) {
      testWidgets('export frame of a green-screen video is keyed (${cpu ? 'CPU fallback' : 'shader or fallback'})', (tester) async {
        ChromaKeyer.forceCpu = cpu;
        final p = videoProject();
        final frame = await frameImage(tester, 200, 100);
        final key = GlobalKey();
        await pumpCanvas(tester, key, p, {'vid': frame});
        await settle(tester);
        await pumpCanvas(tester, key, p, {'vid': frame});
        final px = await pixels(tester, key, [
          [20, 50],
          [180, 50],
        ]);
        expect(px[0], 0xFFFF0000, reason: 'green screen removed → red background shows (got ${px[0].toRadixString(16)})');
        expect(px[1], 0xFFFFFFFF, reason: 'subject kept');
        expect(tester.takeException(), isNull);
        frame.dispose();
      });
    }

    testWidgets('matte view renders black/white', (tester) async {
      ChromaKeyer.forceCpu = true;
      final p = videoProject(view: 'matte');
      final frame = await frameImage(tester, 200, 100);
      final key = GlobalKey();
      await pumpCanvas(tester, key, p, {'vid': frame});
      await settle(tester);
      await pumpCanvas(tester, key, p, {'vid': frame});
      final px = await pixels(tester, key, [
        [20, 50],
        [180, 50],
      ]);
      expect(px, [0xFF000000, 0xFFFFFFFF]);
      frame.dispose();
    });

    testWidgets('live preview without a decoder never shows the raw texture', (tester) async {
      // No platform media plugin in tests: the keyed video layer stays empty
      // (no player, no un-keyed green) and nothing throws.
      final p = videoProject();
      final key = GlobalKey();
      await pumpCanvas(tester, key, p, null, draft: true);
      await settle(tester);
      final px = await pixels(tester, key, [
        [20, 50],
        [180, 50],
      ]);
      expect(px, [0xFFFF0000, 0xFFFF0000]);
      expect(tester.takeException(), isNull);
    }, skip: Platform.isWindows); // on Windows the real ffmpeg decoder runs inside the fake-async test zone

    testWidgets('image layer with chroma_key (CPU fallback)', (tester) async {
      ChromaKeyer.forceCpu = true;
      late String path;
      await tester.runAsync(() async {
        final im = imglib.Image(width: 200, height: 100);
        for (final px in im) {
          if (px.x < 100) {
            px.setRgba(0, 177, 64, 255);
          } else {
            px.setRgba(255, 255, 255, 255);
          }
        }
        final dir = await Directory.systemTemp.createTemp('chroma');
        path = '${dir.path}/green.png';
        await File(path).writeAsBytes(imglib.encodePng(im));
      });
      final p = project();
      p.media['img'] = MediaAsset(id: 'img', type: MediaType.image, path: path, name: 'green', width: 200, height: 100);
      run(p, {'op': 'add_layer', 'type': 'image', 'media': 'img', 'id': 'im'});
      run(p, {'op': 'add_effect', 'layer': 'im', 'effect': 'chroma_key'});
      final key = GlobalKey();
      for (int i = 0; i < 3; i++) {
        await pumpCanvas(tester, key, p, null);
        await settle(tester);
      }
      final px = await pixels(tester, key, [
        [20, 50],
        [180, 50],
      ]);
      expect(px[0], 0xFFFF0000);
      expect(px[1], 0xFFFFFFFF);
    });

    testWidgets('text layer with chroma_key renders (snapshot path)', (tester) async {
      final p = project();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 's', 'color': '#00B140', 'width': 200, 'height': 100});
      run(p, {'op': 'add_effect', 'layer': 's', 'effect': 'chroma_key'});
      final key = GlobalKey();
      await pumpCanvas(tester, key, p, null);
      await settle(tester);
      await pumpCanvas(tester, key, p, null);
      final px = await pixels(tester, key, [
        [100, 50],
      ]);
      // Keyed on the GPU when the shader is available, else drawn as is.
      expect(px.single == 0xFFFF0000 || px.single == 0xFF00B140, isTrue, reason: px.single.toRadixString(16));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('GPU shader matches the CPU keyer', (tester) async {
    // Futures made in another test's fake-async zone never complete here, so
    // poll instead of awaiting the shader load.
    ChromaKeyer.ensureLoaded();
    for (int i = 0; i < 60 && !ChromaKeyer.gpuReady && !ChromaKeyer.gpuFailed; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    if (!ChromaKeyer.gpuReady) {
      // ignore: avoid_print
      print('chroma_key shader not available in flutter test: CPU keyer only');
      return;
    }
    // ignore: avoid_print
    print('chroma_key shader loaded in flutter test: comparing GPU with CPU');
    await tester.runAsync(() async {
      // Blend green → skin (soft edge) + green → white fringes, 4 rows.
      final colors = <List<int>>[];
      for (int i = 0; i <= 20; i++) {
        final t = i / 20;
        colors.add([(224 * t).round(), (177 - 5 * t).round(), (64 + 76 * t).round()]);
      }
      colors.addAll([
        [0, 255, 0],
        [112, 174, 102],
        [128, 216, 160],
        [255, 255, 255],
      ]);
      final w = colors.length, h = 4;
      final px = Uint8List(w * h * 4);
      // Each row shifted, so a flipped/mirrored result would not match.
      for (int y = 0; y < h; y++) {
        px.setAll(y * w * 4, row([for (int i = 0; i < w; i++) colors[(i + y * 7) % w]]));
      }
      final c = Completer<ui.Image>();
      ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, c.complete);
      final src = await c.future;
      for (final s in const [ChromaSettings(), ChromaSettings(softness: 80, spill: 100), ChromaSettings(tolerance: 30, contrast: 40)]) {
        final shader = ChromaKeyer.newShader()!;
        final keyed = ChromaKeyer.gpuKey(shader, src, s, 0)!;
        final bd = (await keyed.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
        final gpu = bd.buffer.asUint8List();
        final cpu = ChromaMath.key(px, w, h, s);
        for (int i = 0; i < w * h; i++) {
          final o = i * 4;
          final at = 'pixel ${i % w},${i ~/ w} (${px[o]},${px[o + 1]},${px[o + 2]}) $s';
          expect((gpu[o + 3] - cpu[o + 3]).abs(), lessThanOrEqualTo(6), reason: 'alpha $at gpu ${gpu[o + 3]} cpu ${cpu[o + 3]}');
          if (cpu[o + 3] > 60) {
            for (int ch = 0; ch < 3; ch++) {
              expect((gpu[o + ch] - cpu[o + ch]).abs(), lessThanOrEqualTo(8), reason: 'rgb $at');
            }
          }
        }
        keyed.dispose();
        shader.dispose();
      }
      src.dispose();
    });
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('shader source exists and is declared', () {
    expect(File('shaders/chroma_key.frag').existsSync(), isTrue);
    expect(File('pubspec.yaml').readAsStringSync(), contains('shaders/chroma_key.frag'));
  });
}
