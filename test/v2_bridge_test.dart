// V2-A (Bridge): preview_shot contact sheets, check_scene, batch, progress
// notifications (dispatcher + SSE), export wait, Claude Desktop config paths.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/model/camera.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/remote/contact_sheet.dart';
import 'package:motionai/remote/mcp_protocol.dart';
import 'package:motionai/remote/mcp_server.dart';
import 'package:motionai/remote/remote_export.dart';
import 'package:motionai/remote/remote_jobs.dart';
import 'package:motionai/remote/remote_tools.dart';
import 'package:motionai/remote/scene_check.dart';
import 'package:motionai/services/project_storage.dart';
import 'package:motionai/state/editor_controller.dart';

class _MemStorage extends ProjectStorage {
  final List<Project> projects = [];
  @override
  Future<void> save(Project p) async {
    if (!projects.contains(p)) projects.add(p);
  }

  @override
  Future<List<Project>> listProjects() async => List.of(projects);

  @override
  Future<String> mediaDir() async => Directory.systemTemp.path;
}

/// A solid-colour PNG of [w]×[h] whose red channel encodes [t].
Uint8List _png(int w, int h, double t) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8((t * 20).round().clamp(0, 255), 80, 120));
  return img.encodePng(im);
}

class _Host implements RemoteHost {
  final _MemStorage mem = _MemStorage();
  EditorController? open;
  RemoteExport? exported;
  final List<double> pngTimes = [];

  @override
  EditorController? get editor => open;
  @override
  ProjectStorage get storage => mem;
  @override
  String get screen => open == null ? 'home' : 'editor';
  @override
  Future<EditorController> showProject(Project p) async => open = EditorController(p, mem);
  @override
  Future<void> closeProject() async => open = null;
  @override
  Future<Uint8List> renderPng(EditorController c, double time, int width) async {
    pngTimes.add(time);
    return _png(width, (width * c.comp.height / c.comp.width).round(), time);
  }

  @override
  Future<void> showExport(EditorController c, RemoteExport r) async {
    exported = r;
    var f = 0;
    r.job.probe = () => {'phase': 'rendering', 'frame': f = (f + 1).clamp(0, 10), 'frames': 10};
  }

  @override
  Future<List<MediaAsset>> importPaths(EditorController c, List<String> paths, List<String> errors) async => [];
  @override
  Future<Map<String, dynamic>> resolveLibrary(EditorController c, Map<String, dynamic> values) async => Map.of(values);
  @override
  void projectsChanged() {}
}

/// Also renders several raw frames in one go.
class _FastHost extends _Host implements RemoteFrameHost {
  List<double>? batchTimes;
  @override
  Future<List<RawFrame>> renderFrames(EditorController c, List<double> times, int width, {Composition? comp}) async {
    batchTimes = times;
    final h = (width * (comp ?? c.comp).height / (comp ?? c.comp).width).round();
    return [for (final t in times) RawFrame(width, h, Uint8List(width * h * 4)..fillRange(0, width * h * 4, (t * 10).round() & 255))];
  }
}

Project _project({double duration = 10}) => Project(
      id: 'p1',
      name: 'Test',
      main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: duration),
    );

Map<String, dynamic> _call(Object id, String tool, [Map<String, dynamic> args = const {}, Object? token]) => {
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/call',
      'params': {'name': tool, 'arguments': args, if (token != null) '_meta': {'progressToken': token}},
    };

Map _result(Object? r) => (r as Map)['result'] as Map;
List _content(Object? r) => _result(r)['content'] as List;
bool _isError(Object? r) => _result(r)['isError'] == true;
dynamic _json(Object? r) => jsonDecode(((_content(r).first as Map)['text']) as String);

Layer _solid(String id, {double start = 0, double duration = 10, bool is3D = false}) => Layer(
      id: id,
      name: id,
      type: LayerType.solid,
      start: start,
      duration: duration,
      width: 1920,
      height: 1080,
      is3D: is3D,
    )..prop(Props.position).staticValue = [960, 540, 0];

Layer _text(String id, String text, {double x = 960, double y = 540}) => Layer(
      id: id,
      name: id,
      type: LayerType.text,
      start: 0,
      duration: 10,
      width: 1536,
      height: 220,
      text: TextData(text: text, fontSize: 120),
    )..prop(Props.position).staticValue = [x, y, 0];

List<String> _kinds(List<SceneIssue> l) => [for (final i in l) i.kind];

void _apply(Project p, List<SceneIssue> issues) =>
    EditCommands.runAtomic(p, {'op': 'batch', 'commands': SceneCheck.fixAll(issues)});

class _RealHttp extends HttpOverrides {}

class _ProgressBackend implements McpBackend {
  @override
  Future<McpToolResult> callTool(String name, Map<String, dynamic> args, {McpProgress? progress}) async {
    progress?.report(1, total: 3, message: 'one');
    progress?.report(1, total: 3, message: 'dropped: not increasing');
    progress?.report(2, total: 3, message: 'two');
    return McpToolResult.text('done $name');
  }

  @override
  Future<(String, String)> readResource(String uri) async => throw McpUnknownResource(uri);
}

void main() {
  group('catalogue', () {
    test('new tools are listed, described and in the instructions', () {
      for (final n in ['preview_shot', 'check_scene', 'batch']) {
        expect(kMcpToolNames, contains(n));
        expect(kMcpInstructions, contains(n));
      }
      expect(kMcpTools.length, 38);
      expect(kMcpEditTools.contains('batch'), isFalse, reason: 'inner calls are checked one by one');
      for (final t in kMcpTools) {
        expect((t['description'] as String).length, lessThan(800), reason: '${t['name']}');
      }
      final export = kMcpTools.firstWhere((t) => t['name'] == 'export_video');
      expect(((export['inputSchema'] as Map)['properties'] as Map).keys, containsAll(['wait', 'timeout']));
    });

    test('sample times stay inside the range, last one before the end frame', () {
      final t = RemoteTools.sampleTimes(0, 6, 6, 1 / 30);
      expect(t.length, 6);
      expect(t.first, 0);
      expect(t.last, closeTo(6 - 1 / 60, 1e-9));
      expect(RemoteTools.sampleTimes(2, 2, 6, 1 / 30), [2]);
      expect(RemoteTools.sampleTimes(1, 5, 1, 1 / 30), [1]);
    });
  });

  group('contact sheet', () {
    test('grid size, columns and labels', () {
      expect([for (final n in [1, 2, 3, 4, 5, 6, 7, 8, 9, 12]) ContactSheet.columnsFor(n)], [1, 2, 3, 2, 3, 3, 4, 4, 3, 4]);
      final tiles = [for (var i = 0; i < 6; i++) SheetTile(i * 1.0, RawFrame.fromPng(_png(320, 180, i.toDouble())))];
      final png = ContactSheet.png(tiles, tileWidth: 480);
      final im = img.decodePng(png)!;
      const g = ContactSheet.gap;
      expect(im.width, 3 * 480 + 4 * g);
      expect(im.height, 2 * 270 + 3 * g);
      // Tile 6's centre shows frame 6's colour (scaled up from 320 px).
      final px = im.getPixel(g + 2 * (480 + g) + 240, g + (270 + g) + 200);
      expect(px.r, 100);
      expect(px.g, 80);
      expect(ContactSheet.label(1.234), '1.23 s');
    });

    test('animated GIF: frames and delay', () {
      expect(ContactSheet.gifDelay(4, 12), 16, reason: 'capped to a 2 s loop');
      expect(ContactSheet.gifDelay(0.5, 6), 10, reason: 'real time when short');
      expect(ContactSheet.gifDelay(0, 6), 4);
      final tiles = [for (var i = 0; i < 4; i++) SheetTile(i * 0.5, RawFrame.fromPng(_png(200, 112, i * 4.0)))];
      final gif = ContactSheet.gif(tiles, width: 240, delay: 12);
      expect(ascii.decode(gif.sublist(0, 4)), 'GIF8');
      final anim = img.decodeGif(gif)!;
      expect(anim.numFrames, 4);
      expect(anim.width, 240);
    });

    test('bad raw frames are rejected', () {
      expect(() => RawFrame(10, 10, Uint8List(10)), throwsArgumentError);
      expect(() => RawFrame.fromPng(Uint8List.fromList([1, 2, 3])), throwsFormatException);
    });
  });

  group('tools', () {
    late _FastHost host;
    late RemoteTools tools;
    late McpDispatcher d;

    setUp(() async {
      host = _FastHost();
      final p = _project();
      host.mem.projects.add(p);
      await host.showProject(p);
      tools = RemoteTools(host);
      d = McpDispatcher(tools);
    });

    test('preview_shot: one PNG contact sheet + the times (one batched render)', () async {
      final r = await d.handle(_call(1, 'preview_shot', {'from': 0, 'to': 6, 'count': 4, 'width': 320}));
      expect(_isError(r), isFalse, reason: '${_content(r)}');
      final c = _content(r);
      expect((c.first as Map)['mimeType'], 'image/png');
      final im = img.decodePng(base64Decode((c.first as Map)['data'] as String))!;
      expect(im.width, 2 * 320 + 3 * ContactSheet.gap);
      expect((c[1] as Map)['text'], contains('#4 5.98 s'));
      expect(host.batchTimes!.length, 4);
      expect(host.pngTimes, isEmpty, reason: 'RemoteFrameHost renders all frames at once');
    });

    test('preview_shot gif, and the PNG fallback for simple hosts', () async {
      final g = await d.handle(_call(1, 'preview_shot', {'from': 1, 'to': 2, 'format': 'gif', 'count': 5}));
      expect((_content(g).first as Map)['mimeType'], 'image/gif');

      final slow = _Host();
      await slow.showProject(_project());
      final d2 = McpDispatcher(RemoteTools(slow));
      final r = await d2.handle(_call(2, 'preview_shot', {'count': 3}));
      expect(_isError(r), isFalse, reason: '${_content(r)}');
      expect(slow.pngTimes.length, 3);
      final bad = await d2.handle(_call(3, 'preview_shot', {'comp': 'nope'}));
      expect(_isError(bad), isTrue);
    });

    test('batch runs calls in order, keeps images, stops at the first error', () async {
      final r = await d.handle(_call(1, 'batch', {
        'calls': [
          {'name': 'run_commands', 'arguments': {'commands': [{'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'start': 0, 'duration': 10}]}},
          {'name': 'render_frame', 'arguments': {'time': 1}},
          {'name': 'get_layer', 'arguments': {'layer': 'missing'}},
          {'name': 'seek', 'arguments': {'time': 3}},
        ],
      }));
      expect(_isError(r), isTrue);
      final c = _content(r);
      expect(c.any((x) => (x as Map)['type'] == 'image'), isTrue);
      expect((c.first as Map)['text'], '[#1 run_commands] ok');
      expect((c.last as Map)['text'], contains('1 not run'));
      expect(host.open!.comp.layerById('bg'), isNotNull);
      expect(host.open!.time, 0, reason: 'seek was not run');

      final r2 = await d.handle(_call(2, 'batch', {
        'continue_on_error': true,
        'calls': [
          {'name': 'nope_tool'},
          {'name': 'batch', 'arguments': {'calls': []}},
          {'name': 'seek', 'arguments': {'time': 3}},
        ],
      }));
      final s = _result(r2)['structuredContent'] as Map;
      expect(s['failed'], 2);
      expect(host.open!.time, closeTo(3, 0.04));
      expect(_isError(await d.handle(_call(3, 'batch', {'calls': []}))), isTrue);
    });

    test('check_scene tool returns issues and fix_all', () async {
      final c = host.open!;
      c.run({'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'start': 0, 'duration': 4});
      final j = _json(await d.handle(_call(1, 'check_scene'))) as Map;
      expect(j['ok'], isFalse);
      expect([for (final i in j['issues'] as List) (i as Map)['kind']], contains('black_gap'));
      final fixes = j['fix_all'] as List;
      final r = await d.handle(_call(2, 'run_commands', {'commands': fixes}));
      expect(_isError(r), isFalse, reason: '${_content(r)}');
      final j2 = _json(await d.handle(_call(3, 'check_scene'))) as Map;
      expect(j2['ok'], isTrue, reason: '${j2['issues']}');
    });

    test('export_video wait:true returns the file and sends progress', () async {
      final sent = <Map<String, dynamic>>[];
      Timer(const Duration(milliseconds: 400), () => host.exported!.finished('done', r'C:\Videos\final.mp4', null));
      final r = await d.handle(_call(1, 'export_video', {'wait': true}, 'tok-1'), notify: sent.add);
      expect(_isError(r), isFalse);
      final j = _json(r) as Map;
      expect(j['state'], 'done');
      expect((j['result'] as Map)['file'], r'C:\Videos\final.mp4');
      expect(sent, isNotEmpty);
      final ps = [for (final n in sent) ((n['params'] as Map)['progress'] as num)];
      for (var i = 1; i < ps.length; i++) {
        expect(ps[i], greaterThan(ps[i - 1]));
      }
      expect(sent.every((n) => n['method'] == 'notifications/progress' && (n['params'] as Map)['progressToken'] == 'tok-1'), isTrue);
      expect(((sent.last['params'] as Map)['progress'] as num), (sent.last['params'] as Map)['total']);
    });

    test('wait gives up after the timeout and says how to follow up', () async {
      final r = await d.handle(_call(1, 'export_video', {'wait': true, 'timeout': 1}));
      final j = _json(r) as Map;
      expect(j['state'], 'running');
      expect(j['note'], contains('export_status'));
      host.exported!.finished('failed', null, 'disk full');
      final st = _json(await d.handle(_call(2, 'export_status'))) as Map;
      expect(st['state'], 'failed');
    });
  });

  group('progress', () {
    test('McpProgress only increases; the dispatcher passes it only with a token and a transport', () async {
      final sent = <Map<String, dynamic>>[];
      final p = McpProgress('t', sent.add);
      expect(p.report(1), isTrue);
      expect(p.report(1), isFalse);
      expect(p.report(0.5), isFalse);
      expect(p.report(2, total: 4, message: 'half'), isTrue);
      expect(sent.length, 2);
      expect(((sent.last['params'] as Map)['total']), 4);
      expect(McpProgress.tokenOf({'_meta': {'progressToken': 7}}), 7);
      expect(McpProgress.tokenOf({'_meta': {'progressToken': {}}}), isNull);

      final d = McpDispatcher(_ProgressBackend());
      final got = <Map<String, dynamic>>[];
      await d.handle(_call(1, 'get_state', const {}, 'x'), notify: got.add);
      expect(got.length, 2);
      got.clear();
      await d.handle(_call(2, 'get_state'), notify: got.add);
      expect(got, isEmpty, reason: 'no progressToken');
    });

    test('job progress: frames for exports, status changes for others', () {
      final jobs = RemoteJobs();
      final e = jobs.start('export');
      e.probe = () => {'phase': 'rendering', 'frame': 5, 'frames': 50};
      expect(e.progress().$1, 5);
      expect(e.progress().$2, 51);
      e.done({'file': 'x'});
      expect(e.progress().$1, 51);
      final dj = jobs.start('director');
      final u0 = dj.progress().$1;
      dj.message = 'Planning';
      dj.message = 'Planning';
      dj.message = 'Building';
      expect(dj.progress().$1, u0 + 2);
      expect(dj.progress().$2, isNull);
    });

    test('SSE parser handles split chunks, CRLF and comments', () {
      final s = SseParser();
      expect(s.add('event: message\r\ndata: {"a"'), isEmpty);
      expect(s.add(':1}\r\n\r\n: keep-alive\n\ndata: x\ndata: y\n'), ['{"a":1}']);
      expect(s.close(), ['x\ny']);
      expect(SseParser().add(SseParser.event({'k': 'v'})), ['{"k":"v"}']);
    });

    test('HTTP: a tools/call with a progressToken streams progress then the result', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = McpHttpServer(McpDispatcher(_ProgressBackend()), token: () => 'tk');
        final port = await server.start(0);
        final client = HttpClient();
        Future<(String?, String)> post(Object body, {bool sse = true}) async {
          final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/mcp'));
          req.headers.set('Authorization', 'Bearer tk');
          req.headers.set('Accept', sse ? 'application/json, text/event-stream' : 'application/json');
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(body));
          final res = await req.close();
          return (res.headers.contentType?.mimeType, await res.transform(utf8.decoder).join());
        }

        try {
          final (type, body) = await post(_call(1, 'get_state', const {}, 'p1'));
          expect(type, 'text/event-stream');
          final events = [for (final e in (SseParser()..add(body)).close()) e];
          final all = [...SseParser().add(body)];
          expect(events, isEmpty, reason: 'close() of a fresh parser');
          expect(all.length, 3);
          expect((jsonDecode(all[0]) as Map)['method'], 'notifications/progress');
          expect(((jsonDecode(all[2]) as Map)['result'] as Map)['content'], isNotEmpty);

          final (type2, body2) = await post(_call(2, 'get_state', const {}, 'p2'), sse: false);
          expect(type2, 'application/json');
          expect((jsonDecode(body2) as Map)['id'], 2);
          final (type3, _) = await post(_call(3, 'get_state'));
          expect(type3, 'application/json', reason: 'no token: plain JSON');
        } finally {
          client.close(force: true);
          await server.stop();
        }
      }, _RealHttp());
    });
  });

  group('Claude Desktop config', () {
    test('every install: Microsoft Store packages and the classic folder', () {
      final env = {
        'LOCALAPPDATA': r'C:\Users\Mohit\AppData\Local',
        'APPDATA': r'C:\Users\Mohit\AppData\Roaming',
      };
      final paths = claudeDesktopConfigPaths(env, ['Microsoft.WindowsCalculator_8wekyb3d8bbwe', 'Claude_pzs8sxrjxfjjc', 'ClaudeHelper', 'Claude_zz1']);
      expect(paths, [
        r'C:\Users\Mohit\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude_desktop_config.json',
        r'C:\Users\Mohit\AppData\Local\Packages\Claude_zz1\LocalCache\Roaming\Claude\claude_desktop_config.json',
        r'C:\Users\Mohit\AppData\Roaming\Claude\claude_desktop_config.json',
      ]);
      expect(claudeDesktopConfigPaths(env, const []), [r'C:\Users\Mohit\AppData\Roaming\Claude\claude_desktop_config.json']);
      final noVars = claudeDesktopConfigPaths({'USERPROFILE': r'C:\Users\M'}, ['Claude_abc']);
      expect(noVars.first, r'C:\Users\M\AppData\Local\Packages\Claude_abc\LocalCache\Roaming\Claude\claude_desktop_config.json');
      expect(noVars.last, r'C:\Users\M\AppData\Roaming\Claude\claude_desktop_config.json');
    });

    test('update statuses keep other servers', () {
      const exe = r'C:\MotionAI\motionai-mcp.exe';
      final (a, s1) = claudeDesktopConfigUpdate(null, exe);
      expect(s1, 'added');
      expect(((jsonDecode(a!) as Map)['mcpServers'] as Map)['motionai'], isNotNull);
      final other = jsonEncode({
        'mcpServers': {'files': {'command': 'npx'}},
        'theme': 'dark',
      });
      final (b, s2) = claudeDesktopConfigUpdate('\uFEFF$other', exe);
      expect(s2, 'added');
      final m = jsonDecode(b!) as Map;
      expect((m['mcpServers'] as Map).keys, containsAll(['files', 'motionai']));
      expect(m['theme'], 'dark');
      expect(claudeDesktopConfigUpdate(b, exe).$2, 'unchanged');
      expect(claudeDesktopConfigUpdate(b, exe).$1, isNull);
      expect(claudeDesktopConfigUpdate(b, r'D:\new\motionai-mcp.exe').$2, 'updated');
      expect(claudeDesktopConfigUpdate('{oops', exe), (null, 'invalid'));
    });

    test('control files: two on Windows, newest wins', () {
      final paths = mcpControlFilePaths({'APPDATA': r'C:\U\AppData\Roaming', 'USERPROFILE': r'C:\U'}, windows: true);
      expect(paths, [r'C:\U\AppData\Roaming\MotionAI\mcp.json', r'C:\U\.motionai\mcp.json']);
      expect(mcpControlFilePaths({'HOME': '/h'}, windows: false), ['/h/.config/MotionAI/mcp.json']);
      const old = McpControlInfo(enabled: true, port: 1, written: '2026-11-25T10:00:00');
      const fresh = McpControlInfo(enabled: true, port: 2, written: '2026-11-25T11:00:00');
      expect(newestControl([old, null, fresh])!.port, 2);
      expect(newestControl([fresh, old])!.port, 2);
      expect(newestControl(const []), isNull);
    });
  });

  group('check_scene', () {
    test('black gap (layers ending early with nothing after) and its fix', () {
      final p = _project();
      p.main.layers.add(_solid('bg', duration: 5));
      final issues = SceneCheck.run(p, p.main);
      final gap = issues.firstWhere((i) => i.kind == 'black_gap');
      expect(gap.severity, 'error');
      expect(gap.layers, ['bg']);
      expect(gap.time, closeTo(5, 1e-9));
      expect(gap.fix.single, {'op': 'trim_layer', 'layer': 'bg', 'out': 10.0});
      _apply(p, issues);
      expect(SceneCheck.run(p, p.main), isEmpty);
    });

    test('a layer ending while its set continues; one starting at the playhead', () {
      final p = _project();
      p.main.layers.addAll([_solid('top', duration: 10), _solid('under', duration: 4)]);
      final i1 = SceneCheck.run(p, p.main);
      expect(_kinds(i1), ['ends_early']);
      expect(i1.single.layers, ['under']);
      _apply(p, i1);
      expect(p.main.layerById('under')!.end, closeTo(10, 1e-9));

      final q = _project();
      q.main.layers.addAll([_solid('a'), _solid('late', start: 3, duration: 7)]);
      expect(SceneCheck.run(q, q.main), isEmpty, reason: 'without a playhead it may be intended');
      final i2 = SceneCheck.run(q, q.main, playhead: 3);
      expect(_kinds(i2), ['starts_late']);
      _apply(q, i2);
      final l = q.main.layerById('late')!;
      expect(l.start, 0);
      expect(l.end, closeTo(10, 1e-9));
    });

    test('3D camera move uncovering empty edges → scale fix', () {
      final p = _project(duration: 4);
      final comp = p.main;
      comp.layers.add(_solid('bg3d', duration: 4, is3D: true));
      final z = defaultZoomFor(1920);
      comp.camera.mode = CameraMode.threeD;
      comp.camera.prop(CamProps.zoom).staticValue = [z];
      comp.camera.prop(CamProps.position).setKeyframe(0, [960, 540, -z]);
      comp.camera.prop(CamProps.position).setKeyframe(4, [1560, 540, -z]);
      comp.camera.prop(CamProps.poi).setKeyframe(0, [960, 540, 0]);
      comp.camera.prop(CamProps.poi).setKeyframe(4, [1560, 540, 0]);
      final issues = SceneCheck.run(p, comp);
      final e = issues.firstWhere((i) => i.kind == 'empty_edges', orElse: () => throw 'no empty_edges in ${_kinds(issues)}');
      expect(e.layers, ['bg3d']);
      expect(e.message, contains('right'));
      final v = e.fix.single['value'] as List;
      expect(v[0], greaterThan(150));
      _apply(p, issues);
      expect(_kinds(SceneCheck.run(p, comp)), isNot(contains('empty_edges')));
    });

    test('floating cut-out → moved down onto the ground', () {
      final p = _project();
      p.media['m1'] = MediaAsset(id: 'm1', type: MediaType.image, path: '/x/man_cutout.png', name: 'man', width: 400, height: 400);
      p.main.layers.add(Layer(id: 'man', name: 'Man', type: LayerType.image, start: 0, duration: 10, width: 400, height: 400, is3D: true, mediaId: 'm1')
        ..prop(Props.position).staticValue = [960, 540, 0]);
      final issues = SceneCheck.run(p, p.main, fileExists: (_) => true);
      final f = issues.firstWhere((i) => i.kind == 'floating', orElse: () => throw 'no floating in ${_kinds(issues)}');
      expect(f.layers, ['man']);
      _apply(p, [f]);
      expect(p.main.layerById('man')!.prop(Props.position).staticValue[1], greaterThan(800));
      expect(_kinds(SceneCheck.run(p, p.main, fileExists: (_) => true)), isNot(contains('floating')));
    });

    test('text off-frame and overlapping text', () {
      final p = _project();
      p.main.layers.addAll([_solid('bg'), _text('t1', 'HELLO WORLD', x: 100)]);
      final i1 = SceneCheck.run(p, p.main);
      expect(_kinds(i1), contains('text_off_frame'));
      _apply(p, i1);
      expect(_kinds(SceneCheck.run(p, p.main)), isNot(anyOf(contains('text_off_frame'), contains('text_unsafe'))));

      final q = _project();
      q.main.layers.addAll([_text('top', 'SECOND LINE'), _text('below', 'FIRST LINE'), _solid('bg')]);
      final i2 = SceneCheck.run(q, q.main);
      final o = i2.firstWhere((i) => i.kind == 'text_overlap');
      expect(o.layers, containsAll(['top', 'below']));
      _apply(q, [o]);
      expect(_kinds(SceneCheck.run(q, q.main)), isNot(contains('text_overlap')));
      expect(SceneCheck.textRect(q.main.layerById('top')!, 0)[2], lessThan(1536));
    });

    test('known-broken effects and missing media', () {
      final p = _project();
      p.media['v1'] = MediaAsset(id: 'v1', type: MediaType.video, path: '/gone/clip.mp4', name: 'clip', width: 1920, height: 1080, duration: 10);
      final bg = _solid('bg', is3D: true)..effects.add(Effect(id: 'fx1', type: 'blur'));
      final cap = _text('cap', 'राजस्थान');
      cap.text!.animator = 'scramble';
      final vid = Layer(id: 'vid', name: 'clip', type: LayerType.video, start: 0, duration: 10, width: 1920, height: 1080, mediaId: 'v1');
      final lost = Layer(id: 'lost', name: 'x', type: LayerType.image, start: 0, duration: 10, width: 10, height: 10, mediaId: 'nope');
      p.main.layers.addAll([cap, vid, lost, bg]);
      final issues = SceneCheck.run(p, p.main, fileExists: (path) => !path.startsWith('/gone'));
      final broken = issues.where((i) => i.kind == 'broken_effect').toList();
      expect(broken.length, 2);
      expect(broken.expand((i) => i.fix).map((c) => c['op']), containsAll(['remove_effect', 'update_layer']));
      final missing = issues.where((i) => i.kind == 'missing_media').toList();
      expect([for (final m in missing) m.layers.single], containsAll(['vid', 'lost']));
      expect(issues.first.severity, 'error', reason: 'errors first');
      final j = issues.first.toJson();
      expect(j['layer'], isNotNull);
    });
  });
}
