// Integration QA: the doc-kit components (C) rendered by the motion-FX engine
// (B), end to end through EditCommands → Evaluator → CompositionCanvas.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/rendering.dart' show RenderRepaintBoundary, TextureLayer;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/components.dart';
import 'package:motionai/core/presets/world_map.dart';
import 'package:motionai/director/story_builder.dart';
import 'package:motionai/ui/preview/composition_canvas.dart';
import 'package:motionai/ui/preview/fx/offscreen.dart';

const double kW = 960, kH = 540;

Project project({double w = kW, double h = kH}) {
  final p = Project(
    id: 'qa',
    name: 'QA',
    main: Composition(id: 'main', name: 'Main', width: w, height: h, fps: 30, duration: 10, background: 0xFF000000),
  );
  // Video media renders as a placeholder box without a player (no file IO in tests).
  p.media['clip'] = MediaAsset(id: 'clip', type: MediaType.video, path: '/v.mp4', name: 'footage', width: 1920, height: 1080, duration: 12);
  p.media['img'] = MediaAsset(id: 'img', type: MediaType.image, path: '/a.jpg', name: 'portrait', width: 1200, height: 800);
  p.media['cut'] = MediaAsset(id: 'cut', type: MediaType.image, path: '/c.png', name: 'person (subject)', width: 600, height: 1200);
  p.media['shot'] = MediaAsset(id: 'shot', type: MediaType.image, path: '/s.png', name: 'article', width: 1080, height: 4200);
  p.media['music'] = MediaAsset(id: 'music', type: MediaType.audio, path: '/m.mp3', name: 'music', width: 0, height: 0, duration: 30);
  return p;
}

void run(Project p, Map<String, dynamic> c) => EditCommands.runAtomic(p, c);

/// Extra params a component needs to build without image files on disk.
Map<String, dynamic> renderArgs(String t) => switch (t) {
      'photo_card' => {'media': 'clip'},
      'map' => {'countries': ['India'], 'focus': 'India'},
      'map_pin' => {'map': 'mp', 'lat': 28.6, 'lon': 77.2, 'label': 'Delhi'},
      'map_route' => {'map': 'mp', 'from': [28.6, 77.2], 'to': [48.8, 2.3]},
      _ => const <String, dynamic>{},
    };

/// Renders the composition at [t] and returns RGBA bytes (comp size, 1 px = 1 comp px).
Future<Uint8List> render(WidgetTester tester, Project p, double t, {bool draft = false, bool playing = false}) async {
  final comp = p.main;
  tester.view.physicalSize = Size(comp.width, comp.height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: RepaintBoundary(key: key, child: CompositionCanvas(project: p, time: t, draft: draft, playing: playing)),
    ),
  ));
  expect(tester.takeException(), isNull);
  late Uint8List bytes;
  await tester.runAsync(() async {
    final ro = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await ro.toImage();
    expect(img.width, comp.width.round());
    expect(img.height, comp.height.round());
    bytes = (await img.toByteData())!.buffer.asUint8List();
    img.dispose();
  });
  return bytes;
}

class Px {
  final Uint8List b;
  final int w;
  Px(this.b, this.w);
  int r(int x, int y) => b[(y * w + x) * 4];
  int g(int x, int y) => b[(y * w + x) * 4 + 1];
  int bl(int x, int y) => b[(y * w + x) * 4 + 2];
  int get h => b.length ~/ 4 ~/ w;

  /// Pixels in [x0,x1)×[y0,y1) matching [test].
  int count(bool Function(int r, int g, int b) test, {int x0 = 0, int y0 = 0, int? x1, int? y1}) {
    var n = 0;
    for (int y = y0; y < (y1 ?? h); y++) {
      for (int x = x0; x < (x1 ?? w); x++) {
        if (test(r(x, y), g(x, y), bl(x, y))) n++;
      }
    }
    return n;
  }

  /// Centre of the pixels that are not (almost) black.
  Offset centroid() {
    double sx = 0, sy = 0;
    var n = 0;
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        if (math.max(r(x, y), math.max(g(x, y), bl(x, y))) > 40) {
          sx += x;
          sy += y;
          n++;
        }
      }
    }
    return n == 0 ? Offset.infinite : Offset(sx / n, sy / n);
  }

  double meanLuma() {
    double s = 0;
    final n = b.length ~/ 4;
    for (int i = 0; i < n; i++) {
      s += 0.2126 * b[i * 4] + 0.7152 * b[i * 4 + 1] + 0.0722 * b[i * 4 + 2];
    }
    return s / n;
  }
}

bool lit(int r, int g, int b) => r > 6 || g > 6 || b > 6;

void main() {
  setUpAll(() => WorldMap.load(File('assets/world_countries.json').readAsStringSync()));

  group('every component renders', () {
    for (final t in Components.types) {
      testWidgets(t, (tester) async {
        final p = project();
        if (t == 'map_pin' || t == 'map_route') {
          run(p, {'op': 'add_component', 'type': 'map', 'id': 'mp', 'start': 0, 'duration': 4});
        }
        run(p, {'op': 'add_component', 'type': t, 'id': 'k', 'start': 0, 'duration': 4, ...renderArgs(t)});
        var best = 0;
        for (final time in [0.4, 1.5, 3.0]) {
          final px = Px(await render(tester, p, time), kW.toInt());
          best = math.max(best, px.count(lit));
        }
        await render(tester, p, 1.5, draft: true);
        await render(tester, p, 1.6, draft: true, playing: true);
        expect(best, greaterThan(50), reason: '$t draws something');
      });
    }
  });

  testWidgets('icon_stream: icons travel along the path (Layer.path on a null sub-group)', (tester) async {
    final p = project();
    run(p, {
      'op': 'add_component', 'type': 'icon_stream', 'id': 'is', 'start': 0, 'duration': 4, 'count': 1,
      'from': [100, 450], 'to': [860, 120], 'bend': 0.2, 'travel': 2.4,
      'icons': [{'text': 'A', 'color': '#FF2020'}],
    });
    final icon = p.main.requireLayer('is_i0_icon');
    expect(icon.type, LayerType.nullObject);
    Offset expected(double t) {
      final s = icon.path!.sample(icon.prop(Props.pathProgress).valueAt(t)[0] / 100);
      return Offset(s.x, s.y);
    }

    final a = Px(await render(tester, p, 0.6), kW.toInt()).centroid();
    final b = Px(await render(tester, p, 1.8), kW.toInt()).centroid();
    expect((a - expected(0.6)).distance, lessThan(12), reason: 'icon at 25% of the path: $a vs ${expected(0.6)}');
    expect((b - expected(1.8)).distance, lessThan(12), reason: 'icon at 75% of the path: $b vs ${expected(1.8)}');
    expect((b - a).distance, greaterThan(200), reason: 'the icon moved');
  });

  testWidgets('scanner: targets show only inside the beam; the beam matte is hidden', (tester) async {
    final p = project();
    run(p, {
      'op': 'add_component', 'type': 'scanner', 'id': 'sc', 'start': 0, 'duration': 4,
      'targets': [{'label': 'A', 'x': 240, 'y': 180}, {'label': 'B', 'x': 720, 'y': 180}],
    });
    expect(p.main.requireLayer('sc_t0').matte, const LayerMatte('sc_beam_matte'));
    expect(p.main.requireLayer('sc_t1').matte, const LayerMatte('sc_beam_matte'));
    // Beam on target A (arrives 0.8 s, dwells 1 s).
    var px = Px(await render(tester, p, 1.2), kW.toInt());
    expect(px.g(240, 180), greaterThan(30), reason: 'target A visible inside the beam');
    expect(px.g(720, 180), lessThan(10), reason: 'target B hidden outside the beam');
    // Halfway along the beam: red beam, not the white matte layer.
    expect(px.r(360, 322), greaterThan(50));
    expect(px.g(360, 322), lessThan(110), reason: 'matte layer itself is not drawn');
    // Beam on target B (arrives 2.4 s).
    px = Px(await render(tester, p, 2.8), kW.toInt());
    expect(px.g(720, 180), greaterThan(30), reason: 'target B visible inside the beam');
    expect(px.g(240, 180), lessThan(10), reason: 'target A hidden again');
  });

  testWidgets('article: the page scrolls and nothing spills outside the window', (tester) async {
    final p = project();
    run(p, {'op': 'add_component', 'type': 'article', 'id': 'ar', 'start': 0, 'duration': 4, 'backdrop': 'none', 'tilt': 0, 'drift': 0});
    expect(p.main.requireLayer('ar_a0_img').prop(Props.position).isAnimated, isTrue);
    bool dark(int r, int g, int b) => r < 60 && g < 60 && b < 60;
    bool grey(int r, int g, int b) => r > 110 && r < 210 && (r - g).abs() < 20 && (r - b).abs() < 20;
    // Window: comp y 54..486, content x 259..701 (inside the white page).
    final before = Px(await render(tester, p, 0.6), kW.toInt());
    expect(before.count(dark, x0: 300, x1: 640, y0: 70, y1: 470), greaterThan(500), reason: 'headline lines near the top');
    expect(before.count(grey, x0: 300, x1: 640, y0: 470, y1: 484), greaterThan(50), reason: 'body text inside the window');
    // A body line sits at y≈530 in content space: below the window/paper it must be masked.
    expect(before.count(grey, x0: 300, x1: 640, y0: 522, y1: 538), 0, reason: 'placeholder lines are clipped to the window');
    final after = Px(await render(tester, p, 3.8), kW.toInt());
    expect(after.count(dark, x0: 300, x1: 640, y0: 70, y1: 470), lessThan(5), reason: 'scrolled down: the headline left the window');
    expect(after.count(grey, x0: 300, x1: 640, y0: 70, y1: 470), greaterThan(500), reason: 'body text still visible');
  });

  testWidgets('title_slam: the flash frames are bright, between them it is not', (tester) async {
    final p = project();
    run(p, {'op': 'add_component', 'type': 'title_slam', 'id': 'ts', 'start': 0, 'duration': 5, 'hit': 'none'});
    expect(Px(await render(tester, p, 0), kW.toInt()).meanLuma(), greaterThan(235), reason: 'white flash at 0');
    expect(Px(await render(tester, p, 1.5), kW.toInt()).meanLuma(), lessThan(150), reason: 'title on the dark backdrop');
    expect(Px(await render(tester, p, 2.6), kW.toInt()).meanLuma(), greaterThan(235), reason: 'white flash on the drop');
  });

  group('text fx combinations', () {
    bool green(int r, int g, int b) => g > 150 && r < 110 && b < 110;
    bool red(int r, int g, int b) => r > 150 && g < 90 && b < 90;
    bool blue(int r, int g, int b) => b > 150 && r < 90 && g < 90;

    testWidgets('extrude + marks, extrude + counter, random_pop + highlight', (tester) async {
      Project small() => project(w: 400, h: 200);
      final base = {'op': 'add_layer', 'type': 'text', 'id': 't', 'width': 380, 'height': 120, 'position': [200, 90], 'font_size': 56, 'text_color': '#FFFFFF', 'shadow': false};

      var p = small();
      run(p, {...base, 'text': 'GOLD RUSH', 'extrude': {'depth': 10, 'color': '#00FF00'},
          'marks': [{'phrase': 'GOLD', 'style': 'underline', 'delay': 0, 'duration': 0.2, 'color': '#FF0000'}]});
      var px = Px(await render(tester, p, 1), 400);
      expect(px.count(green), greaterThan(40), reason: 'extruded edge drawn with marks');
      expect(px.count(red), greaterThan(20), reason: 'underline mark drawn with extrude');

      p = small();
      run(p, {...base, 'text': '', 'extrude': {'depth': 10, 'color': '#00FF00'}, 'counter': {'from': 0, 'to': 500, 'duration': 0.3}});
      px = Px(await render(tester, p, 1), 400);
      expect(px.count(green), greaterThan(40), reason: 'extruded edge on a counter');

      p = small();
      run(p, {...base, 'text': 'SECRET FILES', 'animator': 'random_pop', 'anim_duration': 0.3,
          'marks': [{'phrase': 'SECRET', 'style': 'highlight', 'delay': 0, 'duration': 0.2, 'color': '#0000FF'}]});
      px = Px(await render(tester, p, 1), 400);
      expect(px.count(blue), greaterThan(30), reason: 'highlight drawn with a per-letter animator');
      expect(px.count((r, g, b) => r > 200 && g > 200 && b > 200), greaterThan(100), reason: 'letters popped in');
    });
  });

  testWidgets('a shape edited in place repaints', (tester) async {
    final p = project(w: 200, h: 100);
    run(p, {'op': 'add_layer', 'type': 'shape', 'id': 's', 'kind': 'rect', 'width': 100, 'height': 50, 'position': [100, 50], 'fill': '#FF0000'});
    var px = Px(await render(tester, p, 1), 200);
    expect(px.r(100, 50), greaterThan(200));
    run(p, {'op': 'update_layer', 'layer': 's', 'fill': '#0000FF'});
    px = Px(await render(tester, p, 1), 200);
    expect(px.bl(100, 50), greaterThan(200), reason: 'new fill shown');
    expect(px.r(100, 50), lessThan(30));
  });

  testWidgets('curve and sway over a live video texture composite in strips (no blank snapshot)', (tester) async {
    for (final mode in WarpMode.values) {
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 300,
            height: 150,
            child: MeshWarp(mode: mode, a: 60, b: 1, time: 0.7, child: const SizedBox(width: 300, height: 150, child: Texture(textureId: 7))),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      expect(tester.layers.whereType<TextureLayer>().length, greaterThan(4), reason: '$mode');
    }
    // Ordinary content still goes through the mesh (one snapshot, no texture layers).
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: MeshWarp(mode: WarpMode.curve, a: 60, child: const SizedBox(width: 300, height: 150, child: ColoredBox(color: Color(0xFF00FF00)))),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(tester.layers.whereType<TextureLayer>(), isEmpty);
  });

  testWidgets('a video layer works as a track matte and under curve in the preview', (tester) async {
    final p = project(w: 200, h: 100);
    p.media['v'] = MediaAsset(id: 'v', type: MediaType.video, path: '/v.mp4', name: 'v', width: 80, height: 40, duration: 5);
    run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'red', 'width': 200, 'height': 100, 'color': '#FF0000'});
    run(p, {'op': 'add_layer', 'type': 'video', 'media': 'v', 'id': 'vid', 'fit': 'none', 'position': [100, 50]});
    run(p, {'op': 'update_layer', 'layer': 'red', 'matte': {'layer': 'vid'}});
    final px = Px(await render(tester, p, 1), 200);
    expect(px.r(100, 50), greaterThan(200), reason: 'inside the video box');
    expect(px.r(10, 10), lessThan(10), reason: 'outside the video box');
    run(p, {'op': 'update_layer', 'layer': 'red', 'matte': 'none'});
    run(p, {'op': 'add_effect', 'layer': 'vid', 'effect': 'curve', 'params': {'bend': 60}});
    await render(tester, p, 1, draft: true);
  });

  testWidgets('preview with 40 layers incl. particles, mattes, text fx and warps', (tester) async {
    final p = project();
    const kinds = ['confetti', 'leaves', 'stars', 'rain', 'snow', 'smoke', 'dust', 'bokeh', 'streaks', 'birds'];
    for (int i = 0; i < 10; i++) {
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'pa$i', 'color': '#00000000', 'width': kW, 'height': kH, 'position': [kW / 2, kH / 2]});
      run(p, {'op': 'add_effect', 'layer': 'pa$i', 'effect': 'particles', 'id': 'pfx$i', 'params': {'kind': kinds[i], 'amount': 60}});
    }
    for (int i = 0; i < 10; i++) {
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 'tx$i', 'text': 'TITLE $i', 'font_size': 40, 'width': 300, 'height': 60, 'position': [100 + i * 70, 80 + i * 30],
          'animator': i.isEven ? 'random_pop' : 'scramble', if (i % 3 == 0) 'extrude': 6});
    }
    for (int i = 0; i < 10; i++) {
      run(p, {'op': 'add_layer', 'type': 'shape', 'id': 'sh$i', 'kind': i.isEven ? 'ellipse' : 'star', 'width': 80, 'height': 80, 'position': [60 + i * 90, 400], 'fill': '#FFC107'});
      run(p, {'op': 'set_keyframe', 'target': 'sh$i', 'prop': 'position', 'time': 0, 'value': [60 + i * 90, 400], 'ease': 'linear'});
      run(p, {'op': 'set_keyframe', 'target': 'sh$i', 'prop': 'position', 'time': 2, 'value': [60 + i * 90, 300]});
    }
    for (int i = 0; i < 10; i++) {
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'so$i', 'color': '#3366CC', 'width': 120, 'height': 80, 'position': [80 + i * 85, 480]});
      run(p, {'op': 'add_effect', 'layer': 'so$i', 'effect': i.isEven ? 'curve' : 'glow'});
      if (i > 0) run(p, {'op': 'update_layer', 'layer': 'so$i', 'matte': {'layer': 'so0'}});
    }
    run(p, {'op': 'set_comp', 'motion_blur': true});
    expect(p.main.layers.length, 40);
    for (int f = 0; f < 12; f++) {
      await render(tester, p, f / 6, draft: true, playing: f.isOdd);
    }
    await render(tester, p, 1.0);
  });

  group('Director StoryBuilder builds every new visual', () {
    Map<String, dynamic> directorArgs(String t) => switch (t) {
          'photo_card' => {'media': 'img', 'caption': 'Him'},
          'badge' => {'label': 'AGENCY', 'media': 'img'},
          'map' => {'countries': ['India', 'France'], 'focus': 'India'},
          'title_slam' => {'title': 'GOLD RUSH', 'subtitle': 'STORY'},
          'article' => {'media': 'shot', 'marks': [{'box': [0.1, 0.3, 0.6, 0.32], 'style': 'highlight'}, {'phrase': 'not found'}]},
          'icon_stream' => {'icons': ['img', '₹', 'missing']},
          'scanner' => {'logo': 'img', 'targets': [{'media': 'cut', 'label': 'A'}, {'label': 'B'}]},
          'silhouette_crowd' => {'media': ['cut', 'missing'], 'labels': ['A', 'B'], 'highlight': 1},
          'glass_screen' => {'media': ['clip', 'img']},
          'poster' => {'title': 'WANTED', 'media': 'img'},
          'number_tiles' => {'text': '200', 'word': 'YEARS'},
          'date_title' => {'text': '1835', 'subtitle': 'Paris'},
          'plaque' => {'name': 'ABE', 'dates': '1809 – 1865'},
          'name_tag' => {'name': 'John', 'role': 'Miner', 'over_aroll': true},
          'foreground_wipe' => {'media': 'cut'},
          _ => const <String, dynamic>{},
        };

    test('each component as its own beat', () {
      for (final t in Components.types) {
        if (t == 'map_pin' || t == 'map_route') continue; // need a map beat first (below)
        final p = project();
        final cmds = StoryBuilder.build(p, [Beat(0, 3, 'line', {'component': t, ...directorArgs(t)})], BuildOptions(tag: 'x'));
        EditCommands.runAtomic(p, {'op': 'batch', 'commands': cmds});
        expect(p.main.layers.any((l) => l.id.startsWith('dx_0')), isTrue, reason: t);
      }
    });

    test('map + map_pin + map_route on it', () {
      final p = project();
      final cmds = StoryBuilder.build(p, [
        Beat(0, 6, 'India', {'component': 'map', 'countries': ['India']}),
        Beat(1, 3, 'Delhi', {'component': 'map_pin', 'map': 'dm_0', 'lat': 28.6, 'lon': 77.2, 'label': 'Delhi'}),
        Beat(3, 5, 'To Paris', {'component': 'map_route', 'map': 'dm_0', 'from': [28.6, 77.2], 'to': [48.8, 2.3]}),
      ], BuildOptions(tag: 'm'));
      EditCommands.runAtomic(p, {'op': 'batch', 'commands': cmds});
      expect(p.main.layerById('dm_1_g')!.parentId, 'dm_0_g');
    });

    test('every move and transition on photo/video beats; 3D moves gated on the scene ops', () {
      final p = project();
      final beats = <Beat>[];
      var t = 0.0;
      for (final m in StoryBuilder.moves) {
        beats.add(Beat(t, t + 2, 'move $m', {'media': 'img', 'move': m}));
        t += 2;
      }
      for (final tr in StoryBuilder.transitions) {
        beats.add(Beat(t, t + 2, 'transition $tr', {'media': beats.length.isEven ? 'img' : 'clip', 'transition': tr, 'move': 'drift'}));
        t += 2;
      }
      final cmds = StoryBuilder.build(p, beats, BuildOptions(tag: 'mv', musicMedia: 'music', cutouts: {'img': ('cut', 'img')}));
      final ops = cmds.map((c) => c['op']).toSet();
      if (StoryBuilder.has3d) {
        expect(ops, containsAll(['make_3d', 'camera_shot']));
      } else {
        expect(ops.contains('make_3d') || ops.contains('camera_shot'), isFalse, reason: 'no scene ops on this build');
      }
      EditCommands.runAtomic(p, {'op': 'batch', 'commands': cmds});
      expect(p.main.layers.where((l) => l.id.endsWith('_wipe_wipe')), isNotEmpty);
    });

    test('a whole storyboard of new visuals in one batch', () {
      final p = project();
      final beats = <Beat>[];
      var t = 0.0;
      for (final c in Components.types.where((c) => c != 'map_pin' && c != 'map_route')) {
        beats.add(Beat(t, t + 2.5, c, {'component': c, ...directorArgs(c)}));
        t += 2.5;
      }
      final cmds = StoryBuilder.build(p, beats, BuildOptions(tag: 'all', musicMedia: 'music'));
      EditCommands.runAtomic(p, {'op': 'batch', 'commands': cmds});
      expect(p.main.duration, greaterThanOrEqualTo(t - 0.01));
    });
  });
}
