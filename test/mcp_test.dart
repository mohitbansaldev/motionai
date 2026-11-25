// MCP (Agent P): Claude control — JSON-RPC handling, the HTTP server's
// security checks, bridge framing and the Claude config snippets.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/captions/styles.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/templates.dart';
import 'package:motionai/remote/mcp_protocol.dart';
import 'package:motionai/remote/mcp_server.dart';
import 'package:motionai/remote/remote_export.dart';
import 'package:motionai/remote/remote_jobs.dart';
import 'package:motionai/remote/remote_tools.dart';
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

class _FakeHost implements RemoteHost {
  final _MemStorage mem = _MemStorage();
  EditorController? open;
  RemoteExport? exported;
  int changed = 0;

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
  Future<Uint8List> renderPng(EditorController c, double time, int width) async => Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
  @override
  Future<void> showExport(EditorController c, RemoteExport r) async => exported = r;
  @override
  Future<List<MediaAsset>> importPaths(EditorController c, List<String> paths, List<String> errors) async => [
        for (final p in paths) MediaAsset(id: Ids.next('img'), type: MediaType.image, path: p, name: p.split('/').last, width: 640, height: 480),
      ];
  @override
  Future<Map<String, dynamic>> resolveLibrary(EditorController c, Map<String, dynamic> values) async => Map.of(values);
  @override
  void projectsChanged() => changed++;
}

Project _project() => Project(
      id: 'p1',
      name: 'Test',
      main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: 10),
    );

Map<String, dynamic> _req(Object id, String method, [Map<String, dynamic>? params]) =>
    {'jsonrpc': '2.0', 'id': id, 'method': method, if (params != null) 'params': params};

Map<String, dynamic> _call(Object id, String tool, [Map<String, dynamic> args = const {}]) =>
    _req(id, 'tools/call', {'name': tool, 'arguments': args});

/// Text of a tools/call response, decoded as JSON when possible.
dynamic _payload(Object? response) {
  final r = (response as Map)['result'] as Map;
  final text = ((r['content'] as List).first as Map)['text'] as String;
  try {
    return jsonDecode(text);
  } catch (_) {
    return text;
  }
}

bool _isError(Object? response) => ((response as Map)['result'] as Map)['isError'] == true;

class _RealHttp extends HttpOverrides {}

void main() {
  late _FakeHost host;
  late RemoteTools tools;
  late McpDispatcher d;

  setUp(() async {
    host = _FakeHost();
    final p = _project();
    host.mem.projects.add(p);
    await host.showProject(p);
    tools = RemoteTools(host);
    d = McpDispatcher(tools);
  });

  group('JSON-RPC', () {
    test('initialize negotiates the protocol version', () async {
      final r = await d.handle(_req(1, 'initialize', {
        'protocolVersion': '2025-03-26',
        'capabilities': {},
        'clientInfo': {'name': 'claude-ai', 'version': '0.1'},
      })) as Map;
      expect(r['id'], 1);
      final res = r['result'] as Map;
      expect(res['protocolVersion'], '2025-03-26');
      expect((res['serverInfo'] as Map)['name'], 'motionai');
      expect((res['capabilities'] as Map).containsKey('tools'), isTrue);
      expect(d.clientName, 'claude-ai 0.1');

      final r2 = await d.handle(_req(2, 'initialize', {'protocolVersion': '1999-01-01'})) as Map;
      expect((r2['result'] as Map)['protocolVersion'], kMcpProtocolVersion);
      expect(negotiateProtocolVersion(null), kMcpProtocolVersion);
    });

    test('notifications and responses get no answer; ping does', () async {
      expect(await d.handle({'jsonrpc': '2.0', 'method': 'notifications/initialized'}), isNull);
      expect(await d.handle({'jsonrpc': '2.0', 'id': 5, 'result': {}}), isNull);
      final r = await d.handle(_req('a', 'ping')) as Map;
      expect(r['id'], 'a');
      expect(r['result'], isEmpty);
    });

    test('errors are JSON-RPC errors', () async {
      final unknown = await d.handle(_req(1, 'nope/method')) as Map;
      expect((unknown['error'] as Map)['code'], JsonRpc.methodNotFound);
      final bad = await d.handle({'id': 2, 'method': 'ping'}) as Map; // no "jsonrpc"
      expect((bad['error'] as Map)['code'], JsonRpc.invalidRequest);
      final notObj = await d.handle(42) as Map;
      expect((notObj['error'] as Map)['code'], JsonRpc.invalidRequest);
      final tool = await d.handle(_call(3, 'format_hard_drive')) as Map;
      expect((tool['error'] as Map)['code'], JsonRpc.invalidParams);
      final params = await d.handle({'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call', 'params': [1]}) as Map;
      expect((params['error'] as Map)['code'], JsonRpc.invalidParams);
      final res = await d.handle(_req(5, 'resources/read', {'uri': 'motionai://nothing'})) as Map;
      expect((res['error'] as Map)['code'], -32002);
    });

    test('batches answer every request', () async {
      final r = await d.handle([_req(1, 'ping'), {'jsonrpc': '2.0', 'method': 'notifications/x'}, _req(2, 'tools/list')]) as List;
      expect(r.length, 2);
      expect((r[1] as Map)['id'], 2);
    });

    test('tools/list: every tool has a name, description and object schema', () async {
      final r = await d.handle(_req(1, 'tools/list')) as Map;
      final list = (r['result'] as Map)['tools'] as List;
      final names = {for (final t in list) (t as Map)['name']};
      for (final n in ['get_state', 'get_command_spec', 'run_commands', 'undo', 'redo', 'list_projects', 'open_project', 'new_project',
        'save_project', 'rename_project', 'import_media', 'list_media', 'render_frame', 'seek', 'play', 'pause', 'select',
        'export_video', 'export_status', 'director_run', 'captions_generate', 'apply_template', 'library_search', 'library_insert',
        'list_templates', 'list_effects', 'list_components']) {
        expect(names, contains(n));
      }
      for (final t in list) {
        final m = t as Map;
        expect((m['description'] as String).length, greaterThan(20), reason: '${m['name']}');
        expect((m['inputSchema'] as Map)['type'], 'object');
      }
      expect(kMcpToolNames.containsAll(kMcpEditTools), isTrue);
    });

    test('catalogue ids match the app', () {
      expect(kCaptionStyleIds, [for (final s in CaptionStyles.all) s.id]);
      expect(kStarterTemplateIds, [for (final t in Templates.all) t.id]);
    });
  });

  group('tools', () {
    test('run_commands edits through the controller: undoable, atomic', () async {
      final c = host.open!;
      final r = await d.handle(_call(1, 'run_commands', {
        'commands': [
          {'op': 'add_layer', 'type': 'text', 'id': 'title', 'text': 'Hello', 'font_size': 120},
          {'op': 'add_effect', 'layer': 'title', 'effect': 'glow'},
        ],
      }));
      expect(_isError(r), isFalse);
      expect((_payload(r) as Map)['created'], contains('title'));
      expect(c.comp.layerById('title'), isNotNull);
      expect(c.canUndo, isTrue);

      // A failing batch changes nothing.
      final before = jsonEncode(c.project.toJson());
      final bad = await d.handle(_call(2, 'run_commands', {
        'commands': [
          {'op': 'update_layer', 'layer': 'title', 'text': 'Changed'},
          {'op': 'remove_layer', 'layer': 'does_not_exist'},
        ],
      }));
      expect(_isError(bad), isTrue);
      expect(_payload(bad), contains('nothing was changed'));
      expect(jsonEncode(c.project.toJson()), before);

      final bad2 = await d.handle(_call(3, 'run_commands', {'commands': [42]}));
      expect(_isError(bad2), isTrue);

      final u = await d.handle(_call(4, 'undo'));
      expect((_payload(u) as Map)['undone'], 1);
      expect(c.comp.layerById('title'), isNull);
      await d.handle(_call(5, 'redo'));
      expect(c.comp.layerById('title'), isNotNull);
    });

    test('commands given as a JSON string still work', () async {
      final r = await d.handle(_call(1, 'run_commands', {'commands': '[{"op":"add_layer","type":"solid","id":"bg","color":"#112233"}]'}));
      expect(_isError(r), isFalse);
      expect(host.open!.comp.layerById('bg'), isNotNull);
    });

    test('get_state, get_layer, seek, select', () async {
      await d.handle(_call(1, 'run_commands', {
        'commands': [
          {'op': 'add_layer', 'type': 'solid', 'id': 'a', 'color': '#FF0000'},
          {'op': 'add_layer', 'type': 'solid', 'id': 'b', 'color': '#00FF00'},
        ],
      }));
      final s = _payload(await d.handle(_call(2, 'get_state'))) as Map;
      expect((s['project'] as Map)['id'], 'p1');
      expect([for (final l in s['layers_top_to_bottom'] as List) (l as Map)['id']], ['b', 'a']);
      expect(s['can_undo'], isTrue);

      final l = _payload(await d.handle(_call(3, 'get_layer', {'layer': 'a'}))) as Map;
      expect(l['id'], 'a');
      expect(_isError(await d.handle(_call(4, 'get_layer', {'layer': 'zz'}))), isTrue);

      await d.handle(_call(5, 'seek', {'time': 2.5}));
      expect(host.open!.time, closeTo(2.5, 0.04));

      final sel = _payload(await d.handle(_call(6, 'select', {'layers': ['a', 'b']}))) as Map;
      expect(sel['selected'], containsAll(['a', 'b']));
      expect(host.open!.selectedLayerIds, containsAll(['a', 'b']));
      await d.handle(_call(7, 'select', {'layers': []}));
      expect(host.open!.selectedLayerIds, isEmpty);
    });

    test('render_frame returns PNG image content', () async {
      final r = await d.handle(_call(1, 'render_frame', {'time': 1, 'width': 640})) as Map;
      final content = (r['result'] as Map)['content'] as List;
      expect((content.first as Map)['type'], 'image');
      expect((content.first as Map)['mimeType'], 'image/png');
      expect(base64Decode((content.first as Map)['data'] as String).take(4), [0x89, 0x50, 0x4E, 0x47]);
    });

    test('projects: list, new, open, close; edits need an open project', () async {
      final list = _payload(await d.handle(_call(1, 'list_projects'))) as Map;
      expect((list['projects'] as List).length, 1);

      final n = _payload(await d.handle(_call(2, 'new_project', {'name': 'Shorts', 'format': 'shorts'}))) as Map;
      expect((n['project'] as Map)['name'], 'Shorts');
      expect(host.open!.comp.width, 1080);
      expect(host.open!.comp.height, 1920);
      expect(host.mem.projects.length, 2);
      expect(host.changed, 1);

      final t = _payload(await d.handle(_call(3, 'new_project', {'template': 'quote'}))) as Map;
      expect((t['layers_top_to_bottom'] as List), isNotEmpty);

      await d.handle(_call(4, 'open_project', {'id': 'p1'}));
      expect(host.open!.project.id, 'p1');
      expect(_isError(await d.handle(_call(5, 'open_project', {'id': 'missing'}))), isTrue);

      await d.handle(_call(6, 'close_project'));
      expect(host.open, isNull);
      final r = await d.handle(_call(7, 'run_commands', {'commands': [{'op': 'add_layer', 'type': 'solid'}]}));
      expect(_isError(r), isTrue);
      expect(_payload(r), contains('No project is open'));
      final s = _payload(await d.handle(_call(8, 'get_state'))) as Map;
      expect(s['project'], isNull);
      expect((s['projects'] as List).length, 3);
    });

    test('import_media adds media (and layers)', () async {
      final f = File('${Directory.systemTemp.path}/mcp_test_photo.png')..writeAsBytesSync([1, 2, 3]);
      addTearDown(() => f.deleteSync());
      final r = _payload(await d.handle(_call(1, 'import_media', {'paths': [f.path, '/no/such/file.jpg'], 'add_to_timeline': true}))) as Map;
      expect((r['media'] as List).length, 1);
      expect((r['errors'] as List).single, contains('not found'));
      expect((r['layers'] as List).length, 1);
      expect(host.open!.project.media.length, 1);
    });

    test('export starts a job that blocks edits until it ends', () async {
      final r = _payload(await d.handle(_call(1, 'export_video', {'resolution': 720, 'file_name': 'final'}))) as Map;
      final job = r['job'] as String;
      expect(host.exported!.shortSide, 720);
      expect(host.exported!.fileName, 'final.mp4');
      final blocked = await d.handle(_call(2, 'run_commands', {'commands': [{'op': 'add_layer', 'type': 'solid'}]}));
      expect(_isError(blocked), isTrue);
      expect(_payload(blocked), contains('export'));
      host.exported!.finished('done', 'C:\\Videos\\final.mp4', null);
      final st = _payload(await d.handle(_call(3, 'export_status'))) as Map;
      expect(st['job'], job);
      expect(st['state'], 'done');
      expect(_isError(await d.handle(_call(4, 'run_commands', {'commands': [{'op': 'add_layer', 'type': 'solid'}]}))), isFalse);
      expect(_isError(await d.handle(_call(5, 'export_video', {'resolution': 999}))), isTrue);
    });

    test('catalogues: effects, components, templates', () async {
      final e = _payload(await d.handle(_call(1, 'list_effects'))) as Map;
      expect([for (final x in e['effects'] as List) (x as Map)['id']], contains('blur'));
      final c = _payload(await d.handle(_call(2, 'list_components'))) as Map;
      expect([for (final x in c['components'] as List) (x as Map)['type']], contains('lower_third'));
      final t = _payload(await d.handle(_call(3, 'list_templates'))) as Map;
      final all = [for (final x in t['templates'] as List) x as Map];
      expect(all, isNotEmpty);
      final plain = all.firstWhere((x) => ((x['slots'] as List?) ?? const []).every((s) => !'${(s as Map)['kind']}'.startsWith('media')),
          orElse: () => all.first);
      final r = await d.handle(_call(4, 'apply_template', {'id': plain['id'], 'start': 1}));
      expect(_isError(r), isFalse, reason: '${_payload(r)}');
      expect(host.open!.comp.layers, isNotEmpty);
      expect(host.open!.canUndo, isTrue);
    });

    test('resources: spec and project JSON', () async {
      final r = await d.handle(_req(1, 'resources/read', {'uri': kResourceProject})) as Map;
      final c = ((r['result'] as Map)['contents'] as List).first as Map;
      expect(c['mimeType'], 'application/json');
      expect((jsonDecode(c['text'] as String) as Map)['id'], 'p1');
      final s = await d.handle(_req(2, 'resources/read', {'uri': kResourceSpec})) as Map;
      expect((((s['result'] as Map)['contents'] as List).first as Map)['text'], contains('add_layer'));
      final list = await d.handle(_req(3, 'resources/list')) as Map;
      expect(((list['result'] as Map)['resources'] as List).length, 2);
    });

    test('actions are logged', () async {
      final log = <String>[];
      tools.onAction = (t, s, ok) => log.add('$t:$ok');
      await d.handle(_call(1, 'seek', {'time': 1}));
      await d.handle(_call(2, 'get_layer', {'layer': 'missing'}));
      expect(log, ['seek:true', 'get_layer:false']);
    });
  });

  group('jobs', () {
    test('states and blocking kinds', () {
      final j = RemoteJobs();
      final cap = j.start('captions');
      expect(j.blocking, isNull, reason: 'captions do not block edits');
      final dir = j.start('director');
      expect(j.blocking, dir);
      dir.fail('boom');
      expect(j.blocking, isNull);
      expect(dir.toJson()['state'], 'failed');
      cap.done({'n': 3});
      cap.fail('ignored after done');
      expect(cap.state, 'done');
      expect(j.latest('captions'), cap);
    });

    test('export file names are cleaned', () {
      expect(RemoteExport.cleanFileName('C:\\x\\My: video'), 'My_ video.mp4');
      expect(RemoteExport.cleanFileName('clip.MP4'), 'clip.MP4');
      expect(RemoteExport.cleanFileName('  '), isNull);
      expect(RemoteExport.cleanFileName(null), isNull);
    });
  });

  group('HTTP server', () {
    test('token, origin and routes', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = McpHttpServer(d, token: () => 'secret-token');
        final port = await server.start(0);
        final client = HttpClient();
        Future<(int, String)> send(String method, String path, {Object? body, String? token, String? origin}) async {
          final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
          if (token != null) req.headers.set('Authorization', 'Bearer $token');
          if (origin != null) req.headers.set('Origin', origin);
          if (body != null) {
            req.headers.contentType = ContentType.json;
            req.write(jsonEncode(body));
          }
          final res = await req.close();
          return (res.statusCode, await res.transform(utf8.decoder).join());
        }

        try {
          expect((await send('GET', '/health')).$1, 200);
          expect((await send('POST', '/mcp', body: _req(1, 'ping'))).$1, 401);
          expect((await send('POST', '/mcp', body: _req(1, 'ping'), token: 'wrong')).$1, 401);
          expect((await send('POST', '/mcp', body: _req(1, 'ping'), token: 'secret-token', origin: 'https://evil.example')).$1, 403);

          final init = await send('POST', '/mcp', body: _req(1, 'initialize', {'protocolVersion': kMcpProtocolVersion}), token: 'secret-token');
          expect(init.$1, 200);
          expect(((jsonDecode(init.$2) as Map)['result'] as Map)['protocolVersion'], kMcpProtocolVersion);

          final note = await send('POST', '/mcp', body: {'jsonrpc': '2.0', 'method': 'notifications/initialized'}, token: 'secret-token');
          expect(note.$1, 202);
          expect(note.$2, isEmpty);

          final parse = await client.postUrl(Uri.parse('http://127.0.0.1:$port/mcp'));
          parse.headers.set('Authorization', 'Bearer secret-token');
          parse.write('{not json');
          final pres = await parse.close();
          expect(pres.statusCode, 400);
          final perr = jsonDecode(await pres.transform(utf8.decoder).join()) as Map;
          expect((perr['error'] as Map)['code'], JsonRpc.parseError);

          final call = await send('POST', '/mcp', body: _call(2, 'run_commands', {'commands': [{'op': 'add_layer', 'type': 'solid', 'id': 'web'}]}), token: 'secret-token');
          expect(call.$1, 200);
          expect(host.open!.comp.layerById('web'), isNotNull);

          expect((await send('GET', '/mcp', token: 'secret-token')).$1, 405);
          final rest = await send('POST', '/api/tools/seek', body: {'time': 3}, token: 'secret-token');
          expect(rest.$1, 200);
          expect((await send('GET', '/api/tools', token: 'secret-token')).$1, 200);
          expect((await send('GET', '/nowhere', token: 'secret-token')).$1, 404);
        } finally {
          client.close(force: true);
          await server.stop();
        }
      }, _RealHttp());
    });

    test('host / origin / token helpers', () {
      expect(isLoopbackHost('127.0.0.1:7820'), isTrue);
      expect(isLoopbackHost('localhost'), isTrue);
      expect(isLoopbackHost('[::1]:7820'), isTrue);
      expect(isLoopbackHost('evil.example:7820'), isFalse);
      expect(isLoopbackHost('127.0.0.1.evil.example'), isFalse);
      expect(isLoopbackHost(null), isFalse);
      expect(isAllowedOrigin(null), isTrue);
      expect(isAllowedOrigin('http://localhost:3000'), isTrue);
      expect(isAllowedOrigin('https://claude.ai'), isFalse);
      expect(constantTimeEquals('abc', 'abc'), isTrue);
      expect(constantTimeEquals('abc', 'abd'), isFalse);
      expect(constantTimeEquals('abc', 'abcd'), isFalse);
      final t1 = newMcpToken(), t2 = newMcpToken();
      expect(t1.length, greaterThanOrEqualTo(40));
      expect(t1, isNot(t2));
    });
  });

  group('bridge framing', () {
    test('decode / encode lines', () {
      final (m, e) = BridgeFraming.decode('{"jsonrpc":"2.0","id":1,"method":"ping"}\r');
      expect(e, isNull);
      expect((m as Map)['method'], 'ping');
      expect(BridgeFraming.decode('   '), (null, null));
      final (_, err) = BridgeFraming.decode('{oops');
      expect((err!['error'] as Map)['code'], JsonRpc.parseError);
      final (_, err2) = BridgeFraming.decode('"just a string"');
      expect((err2!['error'] as Map)['code'], JsonRpc.invalidRequest);
      final line = BridgeFraming.encode({'text': 'two\nlines', 'ok': true});
      expect(line.contains('\n'), isFalse);
      expect((jsonDecode(line) as Map)['text'], 'two\nlines');
    });

    test('offline answers and unavailable app', () {
      final init = BridgeFraming.localAnswer(_req(1, 'initialize', {'protocolVersion': '2024-11-05'}))!;
      expect((init['result'] as Map)['protocolVersion'], '2024-11-05');
      final tl = BridgeFraming.localAnswer(_req(2, 'tools/list'))!;
      expect(((tl['result'] as Map)['tools'] as List).length, kMcpTools.length);
      expect(BridgeFraming.localAnswer(_call(3, 'get_state')), isNull);
      final u = BridgeFraming.unavailable(_call(4, 'get_state'), 'MotionAI is closed');
      expect(_isError(u), isTrue);
      expect(_payload(u), 'MotionAI is closed');
      final u2 = BridgeFraming.unavailable(_req(5, 'resources/read'), 'closed');
      expect((u2['error'] as Map)['code'], JsonRpc.internalError);
      expect(JsonRpc.isNotification({'jsonrpc': '2.0', 'method': 'x'}), isTrue);
      expect(JsonRpc.isRequest(_req(1, 'x')), isTrue);
    });
  });

  group('config', () {
    const exe = r'C:\Users\Mohit\AppData\Local\Programs\MotionAI\motionai.exe';

    test('bridge path and control file', () {
      expect(bridgeExePath(exe), r'C:\Users\Mohit\AppData\Local\Programs\MotionAI\motionai-mcp.exe');
      expect(bridgeExePath('/opt/motionai/motionai'), '/opt/motionai/motionai-mcp');
      expect(mcpControlFilePath({'APPDATA': r'C:\Users\M\AppData\Roaming'}, windows: true), r'C:\Users\M\AppData\Roaming\MotionAI\mcp.json');
      expect(mcpControlFilePath({'HOME': '/home/m'}, windows: false), '/home/m/.config/MotionAI/mcp.json');
      final info = McpControlInfo(enabled: true, port: 7821, token: 'tok', pid: 9, exe: exe, written: 'now');
      final back = McpControlInfo.parse(jsonEncode(info.toJson()))!;
      expect(back.enabled, isTrue);
      expect(back.port, 7821);
      expect(back.token, 'tok');
      expect(back.url, 'http://127.0.0.1:7821/mcp');
      final off = McpControlInfo.parse(jsonEncode(const McpControlInfo(enabled: false, token: 'hidden').toJson()))!;
      expect(off.enabled, isFalse);
      expect(off.token, isEmpty, reason: 'no token on disk while control is off');
      expect(McpControlInfo.parse('garbage'), isNull);
    });

    test('Claude Desktop snippet and merge', () {
      final bridge = bridgeExePath(exe);
      final snip = jsonDecode(claudeDesktopConfigSnippet(bridge)) as Map;
      expect(((snip['mcpServers'] as Map)['motionai'] as Map)['command'], bridge);
      expect(claudeDesktopConfigSnippet(bridge), contains(r'C:\\Users\\Mohit'), reason: 'backslashes are JSON-escaped');

      final existing = jsonEncode({
        'globalShortcut': 'Ctrl+Space',
        'mcpServers': {
          'files': {'command': 'npx', 'args': ['-y', 'fs']},
          'motionai': {'command': 'old.exe'},
        },
      });
      final merged = jsonDecode(mergeClaudeDesktopConfig(existing, bridge)!) as Map;
      expect(merged['globalShortcut'], 'Ctrl+Space');
      final servers = merged['mcpServers'] as Map;
      expect(servers.keys, containsAll(['files', 'motionai']));
      expect((servers['motionai'] as Map)['command'], bridge);
      expect(jsonDecode(mergeClaudeDesktopConfig(null, bridge)!), isA<Map>());
      expect(jsonDecode(mergeClaudeDesktopConfig('', bridge)!), isA<Map>());
      expect(mergeClaudeDesktopConfig('{broken', bridge), isNull);
      expect(mergeClaudeDesktopConfig('[1,2]', bridge), isNull);
    });

    test('Claude Code and HTTP snippets', () {
      final bridge = bridgeExePath(exe);
      expect(claudeCodeStdioCommand(bridge), 'claude mcp add --scope user motionai -- "$bridge"');
      expect(claudeCodeHttpCommand(7820, 'T'), contains('--transport http motionai http://127.0.0.1:7820/mcp --header "Authorization: Bearer T"'));
      final h = jsonDecode(httpConfigSnippet(7820, 'T')) as Map;
      final m = (h['mcpServers'] as Map)['motionai'] as Map;
      expect(m['url'], 'http://127.0.0.1:7820/mcp');
      expect((m['headers'] as Map)['Authorization'], 'Bearer T');
    });
  });
}
