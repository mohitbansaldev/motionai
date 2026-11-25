// win-30: parallax check, camera-facing 3D layers, Flow upload route.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart' show Vector2;
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/model/camera.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/realism.dart';
import 'package:motionai/remote/mcp_server.dart';
import 'package:motionai/remote/scene_check.dart';

Project _project() => Project(
      id: 'p1',
      name: 'Test',
      main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: 4),
    );

Layer _card(String id, double z) => Layer(
      id: id,
      name: id,
      type: LayerType.solid,
      start: 0,
      duration: 4,
      width: 400,
      height: 400,
      is3D: true,
    )..prop(Props.position).staticValue = [960, 540, z];

void _truck(Composition comp) {
  final z = defaultZoomFor(1920);
  comp.camera.mode = CameraMode.threeD;
  comp.camera.prop(CamProps.zoom).staticValue = [z];
  comp.camera.prop(CamProps.position).setKeyframe(0, [760, 540, -z]);
  comp.camera.prop(CamProps.position).setKeyframe(4, [1160, 540, -z]);
  comp.camera.prop(CamProps.poi).setKeyframe(0, [760, 540, 0]);
  comp.camera.prop(CamProps.poi).setKeyframe(4, [1160, 540, 0]);
}

List<String> _kinds(List<SceneIssue> l) => [for (final i in l) i.kind];

void main() {
  group('parallax check', () {
    test('layers at the same depth while the camera trucks → flat_parallax', () {
      final p = _project();
      p.main.layers.addAll([_card('a', 0), _card('b', 10)]);
      _truck(p.main);
      expect(_kinds(SceneCheck.run(p, p.main)), contains('flat_parallax'));
    });

    test('layers far apart in depth → no flat_parallax', () {
      final p = _project();
      p.main.layers.addAll([_card('near', -1200), _card('far', 4000)]);
      _truck(p.main);
      expect(_kinds(SceneCheck.run(p, p.main)), isNot(contains('flat_parallax')));
    });

    test('a still camera is never flagged', () {
      final p = _project();
      p.main.layers.addAll([_card('a', 0), _card('b', 0)]);
      p.main.camera.mode = CameraMode.threeD;
      expect(_kinds(SceneCheck.run(p, p.main)), isNot(contains('flat_parallax')));
    });
  });

  test('camera-facing 3D layers: exact matrix for the engine, sub-pixel perspective for the preview', () {
    final p = _project();
    p.main.layers.add(_card('a', 0));
    final z = defaultZoomFor(1920);
    p.main.camera.mode = CameraMode.threeD;
    p.main.camera.prop(CamProps.zoom).staticValue = [z];
    p.main.camera.prop(CamProps.position).staticValue = [960, 540, -z];
    p.main.camera.prop(CamProps.poi).staticValue = [960, 540, 0];
    final it = Evaluator.evaluate(p.main, 1).single;
    expect(it.matrix.storage[3], 0, reason: 'engine/export matrix stays exact');
    final safe = Realism.previewSafe(it.matrix);
    expect(safe.storage[3], isNot(0));
    expect(identical(Realism.previewSafe(safe), safe), isTrue, reason: 'already has perspective: unchanged');
    final q = it.corners();
    expect(q[0].x, closeTo(760, 1e-6));
    expect(q[0].y, closeTo(340, 1e-6));
  });

  group('Flow upload route', () {
    late McpHttpServer server;
    late int port;
    final saved = <String, int>{};

    setUp(() async {
      server = McpHttpServer(McpDispatcher(_NoBackend()), token: () => 'secret')
        ..onUpload = (folder, name, bytes) async {
          saved['$folder/$name'] = bytes.length;
          return 'C:/x/$folder/$name';
        };
      port = await server.start(0);
    });
    tearDown(() => server.stop());

    Future<HttpClientResponse> post(String q, List<int> body, {String? origin, String? token = 'secret'}) async {
      final c = HttpClient();
      final r = await c.postUrl(Uri.parse('http://127.0.0.1:$port/api/upload$q'));
      if (origin != null) r.headers.set('origin', origin);
      if (token != null) r.headers.set('authorization', 'Bearer $token');
      r.add(body);
      return r.close();
    }

    test('Flow origin + token saves the image', () async {
      final res = await post('?folder=P360&name=s06_bg.png', List.filled(500, 1), origin: 'https://labs.google');
      expect(res.statusCode, 200);
      expect(res.headers.value('access-control-allow-origin'), 'https://labs.google');
      final j = jsonDecode(await utf8.decodeStream(res)) as Map;
      expect(j['ok'], isTrue);
      expect(saved['P360/s06_bg.png'], 500);
    });

    test('foreign origin, missing token and bad names are refused', () async {
      expect((await post('?name=a.png', List.filled(500, 1), origin: 'https://evil.example')).statusCode, 403);
      expect((await post('?name=a.png', List.filled(500, 1), origin: 'https://labs.google', token: null)).statusCode, 401);
      expect((await post('?name=a.exe', List.filled(500, 1), origin: 'https://labs.google')).statusCode, 400);
      expect((await post('?name=../../evil.png', List.filled(500, 1))).statusCode, 200);
      expect(saved.keys, contains('inbox/evil.png'));
    });

    test('CORS preflight allows the Flow page (private network)', () async {
      final c = HttpClient();
      final r = await c.openUrl('OPTIONS', Uri.parse('http://127.0.0.1:$port/api/upload'));
      r.headers.set('origin', 'https://flow.google.com');
      final res = await r.close();
      expect(res.statusCode, 204);
      expect(res.headers.value('access-control-allow-private-network'), 'true');
      expect(res.headers.value('access-control-allow-headers'), contains('authorization'));
    });

    test('other routes still refuse a foreign origin', () async {
      final c = HttpClient();
      final r = await c.postUrl(Uri.parse('http://127.0.0.1:$port/mcp'));
      r.headers.set('origin', 'https://labs.google');
      r.headers.set('authorization', 'Bearer secret');
      r.write('{}');
      expect((await r.close()).statusCode, 403);
    });
  });
}

class _NoBackend implements McpBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  group('layers reaching behind the camera', () {
    test('a big background seen at an angle is cropped to its part in view, not culled', () {
      final p = _project();
      final z = defaultZoomFor(1920);
      final bg = Layer(id: 'bg', name: 'bg', type: LayerType.solid, start: 0, duration: 4, width: 20000, height: 8000, is3D: true)
        ..prop(Props.position).staticValue = [960, 540, 0];
      p.main.layers.add(bg);
      p.main.camera.mode = CameraMode.threeD;
      p.main.camera.prop(CamProps.zoom).staticValue = [z];
      p.main.camera.prop(CamProps.position).staticValue = [960, 540, -z];
      p.main.camera.prop(CamProps.poi).staticValue = [960 + 3000, 540, 0]; // yawed ~60°: the far left edge is behind the lens
      final items = Evaluator.evaluate(p.main, 1);
      expect(items, hasLength(1), reason: 'was culled whole (black frame)');
      final it = items.single;
      final c = it.crop!;
      expect(c[2] - c[0], lessThan(20000));
      expect(it.depth, greaterThan(kNearPlane));
      final q = it.corners();
      for (final sc in [
        [1.0, 1.0],
        [1919.0, 1.0],
        [1919.0, 1079.0],
        [1.0, 1079.0],
      ]) {
        expect(pointInQuad(Vector2(sc[0], sc[1]), q), isTrue, reason: 'screen corner $sc uncovered');
      }
      // The drawn box maps (0,0) of the crop to its corner.
      final dm = it.drawMatrix;
      final a = projectPoint(dm, 0, 0), b = it.project(c[0], c[1]);
      expect((a - b).length, lessThan(1e-3));
    });

    test('a layer fully behind the camera is still culled; a normal layer has no crop', () {
      final p = _project();
      final z = defaultZoomFor(1920);
      p.main.layers.addAll([_card('behind', -z - 2000), _card('front', 0)]);
      p.main.camera.mode = CameraMode.threeD;
      p.main.camera.prop(CamProps.zoom).staticValue = [z];
      p.main.camera.prop(CamProps.position).staticValue = [960, 540, -z];
      p.main.camera.prop(CamProps.poi).staticValue = [960, 540, 0];
      final items = Evaluator.evaluate(p.main, 1);
      expect([for (final i in items) i.layer.id], ['front']);
      expect(items.single.crop, isNull);
    });
  });

  group('stacked parallel layers', () {
    test('pages on a tilted calendar stay in front of the back plate', () {
      final p = _project();
      final z = defaultZoomFor(1920);
      final g = Layer(id: 'g', name: 'g', type: LayerType.nullObject, start: 0, duration: 4, width: 10, height: 10, is3D: true)
        ..prop(Props.position).staticValue = [960, 540, 0]
        ..prop(Props.rotation).staticValue = [50, 0, -20];
      Layer plate(String id, double w, double h, double y, double zz) => Layer(
            id: id, name: id, type: LayerType.solid, start: 0, duration: 4, width: w, height: h, is3D: true)
        ..parentId = 'g'
        ..prop(Props.anchor).staticValue = [w / 2, h / 2, 0]
        ..prop(Props.position).staticValue = [0, y, zz];
      // layers[0] is the top layer: page on top of the back.
      p.main.layers.addAll([g, plate('page', 360, 280, 60, 0), plate('back', 400, 450, 0, 3)]);
      p.main.camera.mode = CameraMode.threeD;
      p.main.camera.prop(CamProps.zoom).staticValue = [z];
      p.main.camera.prop(CamProps.position).staticValue = [960, 540, -z];
      p.main.camera.prop(CamProps.poi).staticValue = [960, 540, 0];
      final ids = [for (final i in Evaluator.evaluate(p.main, 1)) i.layer.id];
      expect(ids.indexOf('page'), greaterThan(ids.indexOf('back')), reason: 'back plate painted over the page');
    });

    test('layers far apart in depth still sort by depth', () {
      final p = _project();
      p.main.layers.addAll([_card('far', 3000), _card('near', -500)]);
      final z = defaultZoomFor(1920);
      p.main.camera.mode = CameraMode.threeD;
      p.main.camera.prop(CamProps.zoom).staticValue = [z];
      p.main.camera.prop(CamProps.position).staticValue = [960, 540, -z];
      p.main.camera.prop(CamProps.poi).staticValue = [960, 540, 0];
      expect([for (final i in Evaluator.evaluate(p.main, 1)) i.layer.id], ['far', 'near']);
    });
  });
}
