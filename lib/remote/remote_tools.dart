// MCP (Agent P): the tools Claude calls. Every project change goes through
// the EditorController (undoable, visible live in the editor).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../ai/agent.dart';
import '../ai/ai_client.dart';
import '../ai/ai_settings.dart';
import '../ai/command_spec.dart';
import '../core/commands/edit_commands.dart';
import '../core/model/effects_catalog.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../core/presets/components.dart';
import '../core/presets/templates.dart';
import '../director/capabilities.dart';
import '../director/director.dart';
import '../director/planner.dart';
import '../library/asset_library.dart';
import '../library/library_ops.dart'; // V2-lead
import '../core/commands/pattern_commands.dart'; // V3-E
import '../services/app_log.dart'; // win-30
import '../services/captions.dart';
import '../services/project_storage.dart';
import '../state/editor_controller.dart';
import 'contact_sheet.dart';
import 'manual.dart'; // win-42
import 'mcp_protocol.dart';
import 'mcp_server.dart';
import 'remote_export.dart';
import 'remote_jobs.dart';
import 'scene_check.dart';

/// What the tools need from the running app (navigation, rendering). The
/// real one is RemoteControl; tests use an in-memory fake.
abstract class RemoteHost {
  /// The editor's controller, or null on the home screen.
  EditorController? get editor;
  ProjectStorage get storage;

  /// home | editor | export | director | … (what the user sees).
  String get screen;

  /// Opens [p] in the editor (closing any open one) and returns its controller.
  Future<EditorController> showProject(Project p);

  /// Back to the home screen.
  Future<void> closeProject();

  /// PNG of the open composition of [c] at [time], [width] pixels wide.
  Future<Uint8List> renderPng(EditorController c, double time, int width);

  /// Opens the export screen running [r].
  Future<void> showExport(EditorController c, RemoteExport r);

  /// Imports files (copied into app storage, probed). Failures go to [errors].
  Future<List<MediaAsset>> importPaths(EditorController c, List<String> paths, List<String> errors);

  /// Resolves "lib:<id>" values to project media ids (template slots).
  Future<Map<String, dynamic>> resolveLibrary(EditorController c, Map<String, dynamic> values);

  /// The project list changed / the open project was renamed.
  void projectsChanged();
}

/// V2-A: hosts that can render several frames in one go (one offscreen
/// canvas, images decoded once) and any composition. Optional: without it
/// preview_shot renders PNGs one by one through [RemoteHost.renderPng].
abstract class RemoteFrameHost {
  Future<List<RawFrame>> renderFrames(EditorController c, List<double> times, int width, {Composition? comp});
}

/// win-30: hosts that can capture the live editor preview (the same widget
/// tree the user sees, not the export renderer).
abstract class RemoteEditorView {
  /// PNG of the editor's composition preview, [width] px wide, or null when
  /// the editor is not on screen.
  Future<Uint8List?> editorScreenshot({int width = 960});
}

/// win-30: hosts that give Claude a files area: the user's Documents
/// folder, limited to folders whose name starts with "MotionAI"
/// (MotionAI_Files, MotionAI_Flow, …).
abstract class RemoteFiles {
  Future<String> documentsPath();
}

/// Resolves a files-tool [path] ("MotionAI_Files/scripts/a.txt") under
/// [docs]; null when it leaves the allowed folders.
String? resolveFilesPath(String docs, String path) {
  final parts = path.replaceAll('\\', '/').split('/').where((p) => p.isNotEmpty && p != '.').toList();
  if (parts.isEmpty) return null;
  if (parts.any((p) => p == '..' || p.contains(':'))) return null;
  if (!parts.first.toLowerCase().startsWith('motionai')) return null;
  return [docs, ...parts].join(Platform.pathSeparator);
}

/// win-43: hosts with the Flow panel (Google Flow inside MotionAI).
abstract class RemoteFlowPanel {
  Future<Map<String, dynamic>> flowOpen({String? url, bool show = true});
  Future<Map<String, dynamic>> flowPull(Map<String, dynamic> args, {void Function(String status)? status});
  Future<Object?> flowEval(String code, {Duration timeout});
  Future<bool> flowClose();
}

class _Fail implements Exception {
  final String message;
  _Fail(this.message);
}

class RemoteTools implements McpBackend {
  final RemoteHost host;
  final RemoteJobs jobs;

  /// Every call, for the on-screen log: (tool, short summary, ok).
  void Function(String tool, String summary, bool ok)? onAction;

  RemoteTools(this.host, {RemoteJobs? jobs}) : jobs = jobs ?? RemoteJobs();

  EditorController _editor() {
    final c = host.editor;
    if (c == null) throw _Fail('No project is open. Use list_projects + open_project, or new_project.');
    return c;
  }

  // ------------------------------------------------------------ args

  static String? _str(Map<String, dynamic> a, String k) {
    final v = a[k];
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty ? null : s;
  }

  static String _need(Map<String, dynamic> a, String k) => _str(a, k) ?? (throw _Fail('Missing "$k".'));

  static double? _num(Map<String, dynamic> a, String k) {
    final v = a[k];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }

  static bool? _bool(Map<String, dynamic> a, String k) {
    final v = a[k];
    if (v is bool) return v;
    if (v is String) return v == 'true' ? true : (v == 'false' ? false : null);
    return null;
  }

  static List<String> _strings(Map<String, dynamic> a, String k) {
    final v = a[k];
    if (v is List) return [for (final e in v) if ('$e'.trim().isNotEmpty) '$e'.trim()];
    if (v is String && v.trim().isNotEmpty) return [v.trim()];
    return const [];
  }

  static String _r(double v) => v.toStringAsFixed(2);

  // ------------------------------------------------------------ dispatch

  @override
  Future<McpToolResult> callTool(String name, Map<String, dynamic> args, {McpProgress? progress}) async {
    if (!kMcpToolNames.contains(name)) throw McpUnknownTool(name);
    try {
      if (kMcpEditTools.contains(name)) {
        final b = jobs.blocking;
        if (b != null) {
          throw _Fail('A ${b.kind} job (${b.id}) is running${b.message.isEmpty ? '' : ': ${b.message}'}. '
              'Wait for it (${b.kind == 'export' ? 'export_status' : 'job_status'}) or cancel_job first.');
        }
      }
      final r = await _call(name, args, progress);
      onAction?.call(name, r.isError ? _firstText(r) : _summary(name, args), !r.isError);
      return r;
    } on McpUnknownTool {
      rethrow;
    } on _Fail catch (e) {
      onAction?.call(name, e.message, false);
      return McpToolResult.error(e.message);
    } on CommandError catch (e) {
      onAction?.call(name, e.message, false);
      return McpToolResult.error('Rejected, nothing was changed: ${e.message}');
    } catch (e) {
      onAction?.call(name, '$e', false);
      rethrow;
    }
  }

  static String _firstText(McpToolResult r) {
    for (final c in r.content) {
      if (c['type'] == 'text') {
        final t = '${c['text']}';
        return t.length > 160 ? '${t.substring(0, 160)}…' : t;
      }
    }
    return '';
  }

  static String _summary(String name, Map<String, dynamic> a) {
    switch (name) {
      case 'run_commands':
        final cmds = a['commands'];
        if (cmds is List) {
          final ops = [for (final c in cmds) if (c is Map) '${c['op']}'];
          final shown = ops.take(4).join(', ');
          return '${ops.length} command${ops.length == 1 ? '' : 's'}: $shown${ops.length > 4 ? '…' : ''}';
        }
        return 'commands';
      case 'seek':
        return 'to ${a['time']} s';
      case 'render_frame':
        return 'at ${a['time'] ?? 'playhead'}';
      case 'preview_shot':
      case 'check_scene':
        return '${a['from'] ?? 0}–${a['to'] ?? 'end'} s';
      case 'batch':
        final calls = a['calls'];
        if (calls is List) {
          final names = [for (final c in calls) if (c is Map) '${c['name']}'];
          return '${names.length} calls: ${names.take(4).join(', ')}${names.length > 4 ? '…' : ''}';
        }
        return '';
      case 'open_project':
        return '${a['id']}';
      case 'new_project':
        return '${a['name'] ?? a['format'] ?? ''}';
      case 'import_media':
        return '${_strings(a, 'paths').length} file(s)';
      case 'director_run':
        final b = '${a['brief'] ?? ''}';
        return b.length > 60 ? '${b.substring(0, 60)}…' : b;
      case 'apply_template':
      case 'library_insert':
        return '${a['id']}';
    }
    return '';
  }

  Future<McpToolResult> _call(String name, Map<String, dynamic> a, McpProgress? progress) async {
    switch (name) {
      case 'preview_shot':
        return _previewShot(a);
      case 'check_scene':
        return _checkScene(a);
      case 'batch':
        return _batch(a, progress);
      case 'get_state':
        return McpToolResult.json(await state());
      case 'get_manual': // win-42: the complete control manual
        final q = a['section'] is String ? a['section'] as String : null;
        if (q != null && q.trim().toLowerCase() == 'spec') return McpToolResult.text(commandSpec);
        final text = Manual.section(q);
        if (text == null) throw _Fail('No manual section "$q".\n\n${Manual.toc()}');
        return McpToolResult.text(text);
      case 'get_command_spec':
        return McpToolResult.text('NOTE (MCP): you are connected through tools. Pass the "commands" array to run_commands '
            'and talk to the user normally; the "reply"/JSON output format below is for the in-app assistant only. '
            'Save round trips with batch (e.g. run_commands + check_scene + preview_shot in one call); look at shots with '
            'preview_shot (one contact sheet) rather than many render_frame calls.\n\n$commandSpec');
      case 'run_commands':
        return _runCommands(a);
      case 'get_layer':
        final c = _editor();
        final comp = _compArg(c, a); // win-30: any comp, the user's view stays
        final l = comp.layerById(_need(a, 'layer'));
        if (l == null) throw _Fail('No layer "${a['layer']}" in ${comp.name}. Layer ids are in get_state (or get_layers with comp).');
        return McpToolResult.json(l.toJson());
      case 'get_layers': // win-30: every layer of any comp, top to bottom, without opening it
        final c = _editor();
        final comp = _compArg(c, a);
        final full = _bool(a, 'full') == true;
        return McpToolResult.json({
          'comp': comp.id,
          'name': comp.name,
          'duration': _r(comp.duration),
          'layers': [
            for (final l in comp.layers)
              full
                  ? l.toJson()
                  : {
                      'id': l.id,
                      'name': l.name,
                      'type': l.type.name,
                      'start': _r(l.start),
                      'end': _r(l.end),
                      'is3d': l.is3D,
                      if (l.parentId != null) 'parent': l.parentId,
                      if (!l.visible) 'visible': false,
                    },
          ],
        });
      case 'get_logs': // win-30: app errors / events for debugging
        final limit = (_num(a, 'limit') ?? 50).round().clamp(1, AppLog.capacity);
        final level = _str(a, 'level');
        final entries = AppLog.recent(limit: limit, level: level);
        if (_bool(a, 'clear') == true) AppLog.clear();
        return McpToolResult.json({'count': entries.length, 'entries': [for (final e in entries) e.toJson()]});
      case 'list_files': // win-30: Documents/MotionAI* folders
      case 'read_file':
      case 'write_file':
        return _files(name, a);
      case 'editor_screenshot': // win-30: the real editor preview, exactly what the user sees
        final Object h = host;
        if (h is! RemoteEditorView) throw _Fail('This app version cannot capture the editor preview.');
        final png = await h.editorScreenshot(width: (_num(a, 'width') ?? 960).round().clamp(160, 1920));
        if (png == null) throw _Fail('The editor preview is not on screen (screen: ${host.screen}).');
        return McpToolResult.image(png, caption: 'Editor preview as the user sees it (${host.screen}).');
      case 'undo':
      case 'redo':
        final c = _editor();
        final steps = (_num(a, 'steps') ?? 1).round().clamp(1, 50);
        var done = 0;
        for (var i = 0; i < steps; i++) {
          if (name == 'undo' ? !c.canUndo : !c.canRedo) break;
          name == 'undo' ? c.undo() : c.redo();
          done++;
        }
        return McpToolResult.json({'ok': done > 0, name == 'undo' ? 'undone' : 'redone': done, 'can_undo': c.canUndo, 'can_redo': c.canRedo});
      case 'list_projects':
        return McpToolResult.json({'projects': await _projects()});
      case 'open_project':
        return _openProject(_need(a, 'id'));
      case 'new_project':
        return _newProject(a);
      case 'save_project':
        final c = _editor();
        await c.save();
        return McpToolResult.json({'ok': true, 'saved': c.project.name});
      case 'rename_project':
        final c = _editor();
        c.project.name = _need(a, 'name');
        await c.save();
        host.projectsChanged();
        return McpToolResult.json({'ok': true, 'name': c.project.name});
      case 'close_project':
        final c = host.editor;
        if (c == null) return McpToolResult.json({'ok': true, 'message': 'No project was open.'});
        await c.save();
        await host.closeProject();
        return McpToolResult.json({'ok': true});
      case 'import_media':
        return _import(a);
      case 'list_media':
        final c = _editor();
        return McpToolResult.json({'media': [for (final m in c.project.media.values) _media(m)]});
      case 'render_frame':
        final c = _editor();
        final comp = _compArg(c, a); // win-30: any comp without switching the user's view
        final t = (_num(a, 'time') ?? (comp == c.comp ? c.time : 0)).clamp(0.0, comp.duration).toDouble();
        final w = (_num(a, 'width') ?? 960).round().clamp(160, 1920);
        final Object fh = host;
        final Uint8List png;
        final fmt = (_str(a, 'format') ?? 'png').toLowerCase();
        final jpeg = fmt == 'jpeg' || fmt == 'jpg';
        if ((comp != c.comp || jpeg) && fh is RemoteFrameHost) {
          final f = (await fh.renderFrames(c, [t], w, comp: comp)).first;
          png = ContactSheet.encodeFrame(f, jpeg: jpeg);
        } else {
          if (comp != c.comp) throw _Fail('open_comp "${comp.id}" first, then render_frame.');
          png = await host.renderPng(c, t, w);
        }
        final h = (w * comp.height / comp.width).round();
        final isJpeg = png.length > 2 && png[0] == 0xFF && png[1] == 0xD8;
        return McpToolResult.image(png,
            mimeType: isJpeg ? 'image/jpeg' : 'image/png',
            caption: 'Frame at ${_r(t)} s of "${comp.name}" (${w}x$h; composition ${comp.width.round()}x${comp.height.round()}).');
      case 'seek':
        final c = _editor();
        final t = _num(a, 'time') ?? (throw _Fail('Missing "time" (seconds).'));
        c.seek(t);
        return McpToolResult.json({'ok': true, 'playhead': _r(c.time)});
      case 'play':
        final c = _editor();
        c.play();
        return McpToolResult.json({'ok': true, 'playing': c.playing});
      case 'pause':
        final c = _editor();
        c.pause();
        return McpToolResult.json({'ok': true, 'playhead': _r(c.time)});
      case 'select':
        return _select(a);
      case 'open_comp':
        final c = _editor();
        final id = _need(a, 'comp');
        if (id == 'main') {
          c.openComp(null);
        } else {
          if (c.project.compById(id) == null) throw _Fail('No composition "$id". Ids are in get_state "comps".');
          c.openComp(id);
        }
        return McpToolResult.json({'ok': true, 'comp': c.comp.id});
      case 'export_video':
        return _export(a, progress);
      case 'export_status':
        final id = _str(a, 'job');
        final j = id == null ? jobs.latest('export') : jobs.byId(id);
        if (j == null) throw _Fail(id == null ? 'No export has been started.' : 'No job "$id".');
        // win-30: long-poll — one call waits for the end instead of many polls.
        final waitS = (_num(a, 'wait_s') ?? 0).clamp(0.0, 120.0).toDouble();
        if (waitS > 0) {
          final until = DateTime.now().add(Duration(milliseconds: (waitS * 1000).round()));
          while (j.running && DateTime.now().isBefore(until)) {
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        }
        return McpToolResult.json(j.toJson());
      case 'job_status':
        final id = _str(a, 'job');
        if (id == null) return McpToolResult.json({'jobs': [for (final j in jobs.all.reversed) j.toJson()]});
        final j = jobs.byId(id) ?? (throw _Fail('No job "$id".'));
        return McpToolResult.json(j.toJson());
      case 'cancel_job':
        final j = jobs.byId(_need(a, 'job')) ?? (throw _Fail('No job "${a['job']}".'));
        if (!j.running) return McpToolResult.json({'ok': false, 'message': 'Job already ${j.state}.'});
        if (j.onCancel == null) throw _Fail('This job cannot be cancelled.');
        j.onCancel!();
        j.message = 'Stopping…';
        return McpToolResult.json({'ok': true, 'message': 'Asked ${j.id} to stop.'});
      case 'director_run':
        return _director(a, progress);
      case 'captions_generate':
        return _captions(a, progress);
      case 'list_templates':
        return McpToolResult.json({'templates': [for (final t in await _templates(_str(a, 'category'))) _template(t)]});
      case 'apply_template':
        return _applyTemplate(a);
      case 'library_search':
        return _librarySearch(a);
      // V2-lead >>>
      case 'library_import_folder':
      case 'library_clean':
      case 'library_suggest':
        return _libraryOps(name, a);
      // <<< V2-lead
      // win-43 >>> Flow panel
      case 'flow_panel_open':
      case 'flow_pull':
      case 'flow_panel_eval':
      case 'flow_panel_close':
        return _flowPanel(name, a, progress);
      // <<< win-43
      case 'library_insert':
        return _libraryInsert(a);
      case 'list_effects':
        return McpToolResult.json({
          'effects': [
            for (final e in EffectsCatalog.all)
              {
                'id': e.type,
                'label': e.label,
                'category': e.category,
                'params': [
                  for (final p in e.params)
                    {
                      'key': p.key,
                      'label': p.label,
                      'default': p.defaultValue.length == 1 ? p.defaultValue.first : p.defaultValue,
                      'min': p.min,
                      'max': p.max,
                      if (p.options.isNotEmpty) 'options': p.options,
                      if (p.color) 'color': true,
                    },
                ],
              },
          ],
        });
      // V3-E >>>
      case 'suggest_patterns':
        try {
          return McpToolResult.json(PatternCommands.suggest(a));
        } on CommandError catch (e) {
          throw _Fail(e.message);
        }
      // <<< V3-E
      case 'list_components':
        return McpToolResult.json({
          'components': [for (final t in Components.types) {'type': t, 'label': Components.label(t)}],
          'usage': '{"op":"add_component","component":"<type>", ...fields} — see get_command_spec for each component\'s fields.',
        });
    }
    throw McpUnknownTool(name);
  }

  // ------------------------------------------------------------ resources

  @override
  Future<(String, String)> readResource(String uri) async {
    if (uri == kResourceSpec) return ('text/plain', commandSpec);
    if (uri == kResourceManual) return ('text/markdown', kManual); // win-42
    if (uri == kResourceProject) {
      final c = host.editor;
      if (c == null) return ('application/json', jsonEncode({'error': 'No project is open'}));
      return ('application/json', jsonEncode(c.project.toJson()));
    }
    throw McpUnknownResource(uri);
  }

  // ------------------------------------------------------------ state

  Future<Map<String, dynamic>> state() async {
    final out = <String, dynamic>{
      'app': 'MotionAI',
      // win-42: every new chat should read the manual before editing.
      'manual': 'New chat? Read get_manual {"section":"toc"} first (rules, tools, commands, quirks, recipes).',
      'screen': host.screen,
      // win-30: memory and recent errors at a glance.
      'perf': {
        'ram_mb': (ProcessInfo.currentRss / 1048576).round(),
        'peak_ram_mb': (ProcessInfo.maxRss / 1048576).round(),
        'errors_logged': AppLog.recent(limit: AppLog.capacity, level: 'error').length,
      },
    };
    final running = [for (final j in jobs.all) if (j.running) j.toJson()];
    if (running.isNotEmpty) out['jobs'] = running;
    final c = host.editor;
    if (c == null) {
      out['project'] = null;
      out['projects'] = (await _projects()).take(30).toList();
      out['hint'] = 'No project is open: open_project {id} or new_project.';
      return out;
    }
    out['project'] = {'id': c.project.id, 'name': c.project.name};
    out.addAll(EditAgent.projectSummary(c));
    out['selection'] = {'layers': c.selectedLayerIds, 'primary': c.selectedLayerId, 'camera': c.cameraSelected};
    out['playing'] = c.playing;
    out['can_undo'] = c.canUndo;
    out['can_redo'] = c.canRedo;
    return out;
  }

  Future<List<Map<String, dynamic>>> _projects() async {
    final list = await host.storage.listProjects();
    return [
      for (final p in list)
        {
          'id': p.id,
          'name': p.name,
          'size': [p.main.width.round(), p.main.height.round()],
          'duration': _r(p.main.duration),
          'layers': p.main.layers.length,
          'modified': p.modified.toIso8601String(),
          if (host.editor?.project.id == p.id) 'open': true,
        },
    ];
  }

  static Map<String, dynamic> _media(MediaAsset m) => {
        'id': m.id,
        'type': m.type.name,
        'name': m.name,
        'size': [m.width.round(), m.height.round()],
        if (m.duration > 0) 'duration': _r(m.duration),
        'path': m.path,
        if (m.description.isNotEmpty) 'description': m.description,
      };

  // ------------------------------------------------------------ editing

  McpToolResult _runCommands(Map<String, dynamic> a) {
    final c = _editor();
    var raw = a['commands'];
    if (raw is String) {
      try {
        raw = jsonDecode(raw);
      } catch (_) {
        throw _Fail('"commands" must be an array of command objects.');
      }
    }
    if (raw is Map) raw = [raw];
    if (raw is! List || raw.isEmpty) throw _Fail('"commands" must be a non-empty array of command objects, e.g. [{"op":"add_layer",...}].');
    final cmds = <Map<String, dynamic>>[];
    for (final (i, x) in raw.indexed) {
      if (x is! Map || x['op'] is! String) throw _Fail('Command #${i + 1} must be an object with an "op".');
      cmds.add(Map<String, dynamic>.from(x));
    }
    final r = c.run({'op': 'batch', 'commands': cmds});
    return McpToolResult.json({
      'ok': true,
      'applied': cmds.length,
      'created': r.createdIds,
      if (r.log.isNotEmpty) 'log': r.log.take(40).toList(),
      'comp': c.comp.id,
      'layers': c.comp.layers.length,
      'duration': _r(c.comp.duration),
      'note': 'One undo step. Use render_frame to look at the result.',
    });
  }

  McpToolResult _select(Map<String, dynamic> a) {
    final c = _editor();
    if (_bool(a, 'camera') == true) {
      c.selectCamera();
      return McpToolResult.json({'ok': true, 'selected': 'camera'});
    }
    final ids = _strings(a, 'layers');
    final filter = a['filter'];
    if (ids.isEmpty && filter is! Map) {
      c.clearSelection();
      return McpToolResult.json({'ok': true, 'selected': const <String>[]});
    }
    c.run({
      'op': 'select',
      if (filter is Map) 'filter': Map<String, dynamic>.from(filter) else 'layers': ids,
      'mode': _str(a, 'mode') ?? 'replace',
    });
    return McpToolResult.json({'ok': true, 'selected': c.selectedLayerIds, 'primary': c.selectedLayerId});
  }

  // ------------------------------------------------------------ projects

  Future<McpToolResult> _openProject(String id) async {
    final open = host.editor;
    if (open != null && open.project.id == id) return McpToolResult.json({'ok': true, 'message': 'Already open.', ...await state()});
    final list = await host.storage.listProjects();
    final p = list.where((x) => x.id == id).firstOrNull ?? list.where((x) => x.name == id).firstOrNull;
    if (p == null) throw _Fail('No project "$id". Ids are in list_projects.');
    if (open != null) await open.save();
    await host.showProject(p);
    return McpToolResult.json({'ok': true, ...await state()});
  }

  Future<McpToolResult> _newProject(Map<String, dynamic> a) async {
    final tid = _str(a, 'template');
    final tpl = tid == null ? null : Templates.all.where((t) => t.id == tid).firstOrNull;
    if (tid != null && tpl == null) throw _Fail('No starter template "$tid" (${kStarterTemplateIds.join(', ')}).');
    final fmt = _str(a, 'format')?.toLowerCase() ?? 'youtube';
    final size = kProjectFormats[fmt] ?? (throw _Fail('Unknown format "$fmt" (${kProjectFormats.keys.join(', ')}).'));
    final w = (_num(a, 'width') ?? tpl?.width ?? size[0]).clamp(16, 8192).toDouble();
    final h = (_num(a, 'height') ?? tpl?.height ?? size[1]).clamp(16, 8192).toDouble();
    final fps = (_num(a, 'fps') ?? 30).clamp(1, 120).toDouble();
    final dur = (_num(a, 'duration') ?? tpl?.duration ?? 10).clamp(0.5, 7200).toDouble();
    final count = (await host.storage.listProjects()).length;
    final p = Project(
      id: Ids.next('proj'),
      name: _str(a, 'name') ?? tpl?.name ?? 'Project ${count + 1}',
      main: Composition(id: 'main', name: 'Main', width: w, height: h, fps: fps, duration: dur),
    );
    if (tpl != null) EditCommands.runAtomic(p, {'op': 'batch', 'commands': tpl.commands(w, h)});
    final open = host.editor;
    if (open != null) await open.save();
    await host.storage.save(p);
    host.projectsChanged();
    await host.showProject(p);
    return McpToolResult.json({'ok': true, ...await state()});
  }

  Future<McpToolResult> _import(Map<String, dynamic> a) async {
    final c = _editor();
    final paths = _strings(a, 'paths');
    if (paths.isEmpty) throw _Fail('Give "paths": a list of files on this PC.');
    final errors = <String>[];
    final ok = <String>[];
    for (final p in paths) {
      if (await File(p).exists()) {
        ok.add(p);
      } else {
        errors.add('$p: file not found');
      }
    }
    final assets = ok.isEmpty ? <MediaAsset>[] : await host.importPaths(c, ok, errors);
    for (final m in assets) {
      c.project.media[m.id] = m;
    }
    if (assets.isNotEmpty) c.mediaChanged();
    List<String> created = const [];
    if (assets.isNotEmpty && _bool(a, 'add_to_timeline') == true) {
      var t = _num(a, 'start') ?? c.time;
      final cmds = <Map<String, dynamic>>[];
      for (final m in assets) {
        cmds.add({
          'op': 'add_layer',
          'type': m.type.name,
          'media': m.id,
          'start': t,
          if (m.type == MediaType.audio) 'index': c.comp.layers.length + cmds.length,
        });
        t += m.type == MediaType.image ? 5 : m.duration;
      }
      created = c.run({'op': 'batch', 'commands': cmds}).createdIds;
    }
    if (assets.isEmpty) throw _Fail('Nothing imported. ${errors.join('; ')}');
    return McpToolResult.json({
      'ok': true,
      'media': [for (final m in assets) _media(m)],
      if (created.isNotEmpty) 'layers': created,
      if (errors.isNotEmpty) 'errors': errors,
    });
  }

  // ------------------------------------------------------------ export

  Future<McpToolResult> _export(Map<String, dynamic> a, McpProgress? progress) async {
    final c = _editor();
    final res = (_num(a, 'resolution') ?? 1080).round();
    if (![720, 1080, 1440, 2160].contains(res)) throw _Fail('resolution must be 720, 1080, 1440 or 2160.');
    final folder = _str(a, 'folder');
    if (folder != null && !Directory(folder).isAbsolute) throw _Fail('"folder" must be an absolute path.');
    c.pause();
    await c.save();
    final job = jobs.start('export');
    final r = RemoteExport(
      job: job,
      shortSide: res,
      fps: _num(a, 'fps'),
      folder: folder,
      fileName: _str(a, 'file_name'),
      high: _bool(a, 'high_quality') ?? true,
    );
    job.message = 'Starting export…';
    try {
      await host.showExport(c, r);
    } catch (e) {
      job.fail(e);
      rethrow;
    }
    if (_bool(a, 'wait') == true) return _waitJob(job, a, progress);
    return McpToolResult.json({'ok': true, 'job': job.id, 'message': 'Export started. Poll export_status until state is done (or use wait:true).'});
  }

  /// Blocks until [job] ends or the timeout passes, sending progress
  /// notifications when the client asked for them. Without a progress token
  /// the default wait is short (clients time out requests after ~60 s).
  Future<McpToolResult> _waitJob(RemoteJob job, Map<String, dynamic> a, McpProgress? progress) async {
    final limit = (_num(a, 'timeout') ?? (progress != null ? 540 : 50)).clamp(1, 540).toDouble();
    final sw = Stopwatch()..start();
    var tick = 0;
    while (job.running && sw.elapsedMilliseconds < limit * 1000) {
      if (progress != null) {
        final (p, total, msg) = job.progress();
        progress.report(p, total: total, message: msg);
        // Keep-alive: the elapsed seconds while the job reports nothing new.
        if (++tick % 20 == 0 && total == null) progress.report(p + tick / 1e6, message: msg);
      }
      await Future<void>.delayed(Duration(milliseconds: tick < 8 ? 100 : 250));
    }
    if (progress != null) {
      final (p, total, msg) = job.progress();
      progress.report(job.running ? p : math.max(p, total ?? p), total: total, message: msg);
    }
    final j = job.toJson();
    switch (job.state) {
      case 'done':
        return McpToolResult.json({'ok': true, ...j});
      case 'running':
        return McpToolResult.json({
          'ok': true,
          ...j,
          'note': 'Still running after ${limit.round()} s. Call ${job.kind == 'export' ? 'export_status' : 'job_status'} '
              '{"job":"${job.id}"} later (or call it with wait:true and a progress token).',
        });
      default:
        return McpToolResult(McpToolResult.json(j).content, isError: true, structured: j);
    }
  }

  // ------------------------------------------------------------ V2-A: preview_shot / check_scene / batch

  Composition _compArg(EditorController c, Map<String, dynamic> a) {
    final id = _str(a, 'comp');
    if (id == null) return c.comp;
    return c.project.compById(id) ?? (throw _Fail('No composition "$id". Ids are in get_state "comps" (or "main").'));
  }

  /// Even samples over [from, to], the last one just before [to] (a shot's
  /// end frame belongs to the next shot).
  static List<double> sampleTimes(double from, double to, int count, double frame) {
    if (count <= 1 || to - from < frame) return [from];
    final last = math.max(from, to - frame * 0.5);
    return [for (var i = 0; i < count; i++) from + (last - from) * i / (count - 1)];
  }

  Future<McpToolResult> _previewShot(Map<String, dynamic> a) async {
    final c = _editor();
    final comp = _compArg(c, a);
    final fmt = (_str(a, 'format') ?? 'png').toLowerCase();
    final gif = fmt == 'gif', jpeg = fmt == 'jpeg' || fmt == 'jpg';
    final from = (_num(a, 'from') ?? 0).clamp(0.0, comp.duration).toDouble();
    final to = (_num(a, 'to') ?? comp.duration).clamp(from, comp.duration).toDouble();
    final count = (_num(a, 'count') ?? (gif ? 12 : 6)).round().clamp(1, gif ? 20 : 12);
    final width = (_num(a, 'width') ?? (gif ? 360 : 480)).round().clamp(160, gif ? 480 : 960);
    final times = sampleTimes(from, to, count, comp.frameDuration);
    final Object fast = host;
    List<RawFrame> frames;
    if (fast is RemoteFrameHost) {
      frames = await fast.renderFrames(c, times, width, comp: comp);
    } else {
      if (comp != c.comp) throw _Fail('open_comp "${comp.id}" first, then preview_shot.');
      frames = [];
      for (final t in times) {
        try {
          frames.add(RawFrame.fromPng(await host.renderPng(c, t, width)));
        } on FormatException catch (e) {
          throw _Fail('Could not read the rendered frame: ${e.message}');
        }
      }
    }
    if (frames.length != times.length) throw _Fail('Rendered ${frames.length} of ${times.length} frames.');
    final tiles = [for (var i = 0; i < times.length; i++) SheetTile(times[i], frames[i])];
    final list = [for (var i = 0; i < times.length; i++) '#${i + 1} ${_r(times[i])} s'].join(', ');
    if (gif) {
      final delay = ContactSheet.gifDelay(to - from, tiles.length);
      final bytes = await _gifInIsolate(tiles, width, delay);
      return McpToolResult.image(bytes,
          mimeType: 'image/gif',
          caption: 'Animated GIF of "${comp.name}" ${_r(from)}–${_r(to)} s: ${tiles.length} frames, ${delay * 10} ms each '
              '(${(delay * tiles.length / 100).toStringAsFixed(1)} s loop). Times: $list. If you only see one frame, use the PNG contact sheet.');
    }
    final cols = ContactSheet.columnsFor(tiles.length);
    final bytes = await _pngInIsolate(tiles, width, cols, jpeg);
    return McpToolResult.image(bytes,
        mimeType: jpeg ? 'image/jpeg' : 'image/png',
        caption: 'Contact sheet of "${comp.name}" ${_r(from)}–${_r(to)} s: ${tiles.length} frames in $cols columns '
            '(left→right, top→bottom), tiles ${width}px wide. Times: $list.');
  }

  // Static: the isolate closure must capture only the frames, never the editor.
  static Future<Uint8List> _pngInIsolate(List<SheetTile> tiles, int width, int cols, [bool jpeg = false]) =>
      Isolate.run(() => ContactSheet.png(tiles, tileWidth: width, columns: cols, jpeg: jpeg));
  static Future<Uint8List> _gifInIsolate(List<SheetTile> tiles, int width, int delay) =>
      Isolate.run(() => ContactSheet.gif(tiles, width: width, delay: delay));

  Future<McpToolResult> _files(String name, Map<String, dynamic> a) async {
    final Object h = host;
    if (h is! RemoteFiles) throw _Fail('This app version has no files area.');
    final docs = await h.documentsPath();
    final sep = Platform.pathSeparator;
    final rel = _str(a, 'path') ?? '';
    if (name == 'list_files' && rel.isEmpty) {
      final out = <Map<String, dynamic>>[];
      final d = Directory(docs);
      if (await d.exists()) {
        await for (final e in d.list()) {
          final n = e.path.split(sep).last;
          if (e is Directory && n.toLowerCase().startsWith('motionai')) out.add({'name': n, 'type': 'dir'});
        }
      }
      return McpToolResult.json({'root': docs, 'entries': out, 'note': 'Paths start with a MotionAI* folder, e.g. "MotionAI_Files/notes.txt".'});
    }
    final full = resolveFilesPath(docs, rel);
    if (full == null) throw _Fail('path must be inside a Documents folder named MotionAI… (e.g. "MotionAI_Files/x.txt"), without "..".');
    switch (name) {
      case 'list_files':
        final d = Directory(full);
        if (!await d.exists()) throw _Fail('No folder "$rel".');
        final out = <Map<String, dynamic>>[];
        await for (final e in d.list()) {
          final st = await e.stat();
          out.add({'name': e.path.split(sep).last, 'type': e is Directory ? 'dir' : 'file', if (e is File) 'size': st.size});
          if (out.length >= 2000) break;
        }
        return McpToolResult.json({'path': full, 'entries': out});
      case 'read_file':
        final f = File(full);
        if (!await f.exists()) throw _Fail('No file "$rel".');
        final max = (_num(a, 'max_bytes') ?? 2000000).round().clamp(1, 20000000);
        final len = await f.length();
        final bytes = await f.openRead(0, math.min(len, max)).fold<List<int>>(<int>[], (acc, b) => acc..addAll(b));
        final asB64 = (_str(a, 'encoding') ?? 'text') == 'base64';
        return McpToolResult.json({
          'path': full,
          'size': len,
          'truncated': len > max,
          if (asB64) 'base64': base64Encode(bytes) else 'text': utf8.decode(bytes, allowMalformed: true),
        });
      default: // write_file
        final text = a['text'], b64 = a['base64'];
        if (text is! String && b64 is! String) throw _Fail('Give "text" or "base64".');
        final f = File(full);
        await f.parent.create(recursive: true);
        final bytes = text is String ? utf8.encode(text) : base64Decode(b64 as String);
        await f.writeAsBytes(bytes, mode: a['append'] == true ? FileMode.append : FileMode.write, flush: true);
        return McpToolResult.json({'ok': true, 'path': full, 'bytes': bytes.length, 'note': 'Use this absolute path with import_media.'});
    }
  }

  McpToolResult _checkScene(Map<String, dynamic> a) {
    final c = _editor();
    final comp = _compArg(c, a);
    final from = _num(a, 'from'), to = _num(a, 'to');
    final issues = SceneCheck.run(c.project, comp, from: from, to: to, playhead: c.time);
    final counts = <String, int>{};
    for (final i in issues) {
      counts[i.severity] = (counts[i.severity] ?? 0) + 1;
    }
    final fixes = SceneCheck.fixAll(issues);
    return McpToolResult.json({
      'comp': comp.id,
      'range': [_r((from ?? 0).clamp(0.0, comp.duration).toDouble()), _r((to ?? comp.duration).clamp(0.0, comp.duration).toDouble())],
      'ok': issues.isEmpty,
      'counts': counts,
      'issues': [for (final i in issues.take(60)) i.toJson()],
      if (issues.length > 60) 'more': issues.length - 60,
      if (fixes.isNotEmpty) 'fix_all': fixes,
      if (fixes.isNotEmpty) 'how_to_fix': 'run_commands {"commands": <fix_all>} (one undo step), then check_scene again. Review heuristic ones (floating, overlap) with preview_shot.',
    });
  }

  Future<McpToolResult> _batch(Map<String, dynamic> a, McpProgress? progress) async {
    var raw = a['calls'];
    if (raw is String) {
      try {
        raw = jsonDecode(raw);
      } catch (_) {
        throw _Fail('"calls" must be an array of {"name","arguments"} objects.');
      }
    }
    if (raw is! List || raw.isEmpty) throw _Fail('"calls" must be a non-empty array of {"name":"tool","arguments":{...}}.');
    if (raw.length > 50) throw _Fail('At most 50 calls per batch.');
    final keepGoing = _bool(a, 'continue_on_error') ?? false;
    final content = <Map<String, dynamic>>[];
    final results = <Map<String, dynamic>>[];
    var failed = 0;
    for (final (i, x) in raw.indexed) {
      final n = i + 1;
      String name = '';
      McpToolResult r;
      if (x is! Map) {
        r = McpToolResult.error('Call #$n must be an object {"name","arguments"}.');
      } else {
        name = '${x['name'] ?? x['tool'] ?? ''}';
        final args = x['arguments'] ?? x['args'] ?? const <String, dynamic>{};
        if (name == 'batch') {
          r = McpToolResult.error('batch cannot contain batch.');
        } else if (args is! Map) {
          r = McpToolResult.error('"arguments" of call #$n must be an object.');
        } else {
          try {
            r = await callTool(name, Map<String, dynamic>.from(args));
          } on McpUnknownTool {
            r = McpToolResult.error('Unknown tool "$name".');
          } catch (e) {
            r = McpToolResult.error('$name failed: $e');
          }
        }
      }
      content.add({'type': 'text', 'text': '[#$n $name] ${r.isError ? 'ERROR' : 'ok'}'});
      content.addAll(r.content);
      results.add({'call': n, 'name': name, 'ok': !r.isError});
      progress?.report(n, total: raw.length, message: name);
      if (r.isError) {
        failed++;
        if (!keepGoing) break;
      }
    }
    final skipped = raw.length - results.length;
    content.add({
      'type': 'text',
      'text': 'batch: ${results.length - failed} ok, $failed failed${skipped > 0 ? ', $skipped not run (stopped at the first error)' : ''}.',
    });
    return McpToolResult(content,
        isError: failed > 0, structured: {'results': results, 'failed': failed, if (skipped > 0) 'skipped': skipped});
  }

  // ------------------------------------------------------------ Director

  Future<McpToolResult> _director(Map<String, dynamic> a, McpProgress? progress) async {
    final c = _editor();
    final s = await AiSettings.load();
    if (!s.isConfigured) {
      throw _Fail('The Director uses MotionAI\'s own AI connection, which is not set up (AI tab → settings: ChatGPT plan or an API key). '
          'Ask the user to set it up, or build the edit yourself with run_commands.');
    }
    final p = c.project;
    List<MediaAsset> media(MediaType t) =>
        p.media.values.where((m) => m.type == t && !m.name.startsWith('SFX ') && !m.name.startsWith('Voice ')).toList();
    final o = DirectorInput()
      ..language = s.captionLanguage
      ..roman = s.captionsRoman;
    final videos = media(MediaType.video), audio = media(MediaType.audio);
    if (videos.isNotEmpty) {
      o.arollMedia = videos.first.id;
    } else if (audio.isNotEmpty) {
      o
        ..narration = Narration.voiceover
        ..voiceMedia = audio.first.id;
    } else {
      o.narration = Narration.phoneVoice;
    }
    o
      ..brief = _need(a, 'brief')
      ..script = _str(a, 'script') ?? '';
    final n = _str(a, 'narration');
    if (n != null) {
      o.narration = switch (n) {
        'aroll' => Narration.aroll,
        'voiceover' => Narration.voiceover,
        'phone_voice' || 'phoneVoice' => Narration.phoneVoice,
        'silent' => Narration.silent,
        _ => throw _Fail('narration must be aroll, voiceover, phone_voice or silent.'),
      };
    }
    String? mediaArg(String k, MediaType t) {
      final id = _str(a, k);
      if (id == null) return null;
      final m = p.media[id];
      if (m == null || m.type != t) throw _Fail('"$k": no ${t.name} media "$id" in the project (see list_media).');
      return id;
    }

    o.arollMedia = mediaArg('aroll_media', MediaType.video) ?? o.arollMedia;
    o.voiceMedia = mediaArg('voice_media', MediaType.audio) ?? o.voiceMedia;
    o.musicMedia = mediaArg('music_media', MediaType.audio) ?? o.musicMedia;
    if (o.narration == Narration.aroll && o.arollMedia == null) throw _Fail('narration aroll needs a video in the project (import_media first).');
    if (o.narration == Narration.voiceover && o.voiceMedia == null) throw _Fail('narration voiceover needs an audio file (import_media first).');
    if ((o.narration == Narration.phoneVoice || o.narration == Narration.silent) && o.script.isEmpty && o.brief.isEmpty) {
      throw _Fail('Give a brief or a script.');
    }
    final lang = _str(a, 'language');
    if (lang != null) o.language = lang;
    o.roman = _bool(a, 'roman') ?? o.roman;
    o.minutes = (_num(a, 'minutes') ?? o.minutes).round().clamp(1, 30);
    o.captions = _bool(a, 'captions') ?? o.captions;
    o.sfx = _bool(a, 'sfx') ?? o.sfx;
    o.depth = _bool(a, 'depth') ?? o.depth;
    o.review = _bool(a, 'review') ?? o.review;
    o.look = _str(a, 'look') ?? o.look;

    final job = jobs.start('director');
    final cancel = CancelToken();
    job.onCancel = cancel.cancel;
    job.message = 'Starting…';
    unawaited(_runDirector(c, o, job, cancel));
    if (_bool(a, 'wait') == true) return _waitJob(job, a, progress);
    return McpToolResult.json({
      'ok': true,
      'job': job.id,
      'message': 'Director started (the user sees the edit being built). Poll job_status every ~20 s; it takes minutes.',
    });
  }

  Future<void> _runDirector(EditorController c, DirectorInput o, RemoteJob job, CancelToken cancel) async {
    final p = c.project;
    final snapshot = ProjectSnapshot.take(p);
    c.beginGesture();
    final d = Director(c, (msg) => job.message = msg);
    try {
      job.message = 'Looking at your media';
      await d.understandMedia();
      cancel.check();
      job.message = 'Listening to the voice';
      final narration = await d.narrate(o);
      cancel.check();
      job.message = 'Planning every shot';
      final sb = await d.planStoryboard(o, narration, cancel: cancel);
      final look = o.look == 'auto' ? sb.look : o.look;
      cancel.check();
      job.message = 'Cut-outs & sound effects';
      final opts = await d.prepare(sb.beats, o, narration, look);
      opts
        ..tag = sb.tag
        ..chapters = sb.chapters
        ..caps = Capabilities();
      cancel.check();
      job.message = 'Building ${sb.chapters.length} chapters';
      final dropped = d.build(sb.beats, opts);
      for (final ch in sb.chapters) {
        ch.status = 'built';
      }
      sb.stage = 'built';
      await d.saveStoryboard(sb);
      var notes = '';
      if (o.review) {
        job.message = 'Watching & fixing';
        try {
          notes = await d.reviewChapters(sb, (times) async => [for (final t in times) (t, await host.renderPng(c, t, 960))], cancel: cancel);
        } on DirectorCancelled {
          notes = 'Review stopped.';
        } catch (e) {
          notes = 'Review skipped: $e';
        }
      }
      c.endGesture();
      final kept = sb.beats.where((b) => b.keep).length;
      job.done({
        'duration': _r(c.comp.duration),
        'chapters': sb.chapters.length,
        'shots': kept,
        if (dropped > 0) 'skipped': dropped,
        if (notes.isNotEmpty) 'notes': notes,
        'undo': 'One undo removes the whole build.',
      }, message: 'Built ${_r(c.comp.duration)} s in ${sb.chapters.length} chapters with $kept shots.');
    } catch (e) {
      _directorFailed(c, p, snapshot, e, job);
    }
  }

  static void _directorFailed(EditorController c, Project p, String snapshot, Object e, RemoteJob job) {
    ProjectSnapshot.restore(p, snapshot);
    c.endGesture();
    c.mediaChanged();
    if (e is DirectorCancelled) {
      job.cancelled('Stopped; the project is back as it was.');
    } else {
      job.fail(e is AiException ? e.message : e);
    }
  }

  // ------------------------------------------------------------ captions

  Future<McpToolResult> _captions(Map<String, dynamic> a, McpProgress? progress) async {
    final c = _editor();
    bool src(Layer l) => (l.type == LayerType.video || l.type == LayerType.audio) && c.project.media[l.mediaId] != null;
    final id = _str(a, 'layer');
    Layer? l;
    if (id != null) {
      l = c.comp.layerById(id);
      if (l == null || !src(l)) throw _Fail('"$id" is not a video/audio layer with media.');
    } else {
      final sel = c.selectedLayer;
      l = sel != null && src(sel) ? sel : c.comp.layers.where(src).firstOrNull;
      if (l == null) throw _Fail('No video or audio layer to caption (import_media with add_to_timeline first).');
    }
    final style = _str(a, 'style') ?? 'karaoke';
    final lang = _str(a, 'language') ?? 'hi';
    final o = CaptionOptions(
      style: style,
      language: lang == 'auto' ? null : lang,
      roman: _bool(a, 'roman') ?? false,
      maxWords: (_num(a, 'max_words') ?? 0).round().clamp(0, 12),
      emphasis: _bool(a, 'emphasis') ?? true,
      aiEmphasis: _bool(a, 'ai_emphasis') ?? false,
    );
    final job = jobs.start('captions');
    job.message = 'Starting speech-to-text…';
    final source = l;
    unawaited(() async {
      try {
        final cmds = await CaptionMaker.buildCommands(c.project, source, o, onStatus: (m) => job.message = m);
        if (host.editor != c) throw _Fail('The project was closed before the captions were ready.');
        final r = c.run({'op': 'batch', 'commands': cmds});
        final n = cmds.where((m) => m['op'] == 'add_layer').length;
        job.done({'caption_layers': n, 'created': r.createdIds.take(200).toList()}, message: 'Added $n caption layers (one undo step).');
      } on _Fail catch (e) {
        job.fail(e.message);
      } on CommandError catch (e) {
        job.fail(e.message);
      } catch (e) {
        job.fail(e is AiException ? e.message : e);
      }
    }());
    if (_bool(a, 'wait') == true) return _waitJob(job, a, progress);
    return McpToolResult.json({'ok': true, 'job': job.id, 'layer': source.id, 'message': 'Transcribing. Poll job_status (or use wait:true).'});
  }

  // ------------------------------------------------------------ templates

  Future<List<SceneTemplate>> _templates(String? category) async {
    final out = <SceneTemplate>[...SceneTemplates.available];
    try {
      final lib = await AssetLibrary.shared();
      for (final j in lib.index.templates) {
        out.add(SceneTemplate.fromJson(j));
      }
    } catch (_) {
      // No library (tests, first run): built-ins only.
    }
    return category == null ? out : [for (final t in out) if (t.category.toLowerCase() == category.toLowerCase()) t];
  }

  static Map<String, dynamic> _template(SceneTemplate t) => {
        'id': t.id,
        'name': t.name,
        'category': t.category,
        if (t.subtitle.isNotEmpty) 'subtitle': t.subtitle,
        'duration': t.duration,
        if (t.slots.isNotEmpty)
          'slots': [
            for (final s in t.slots)
              {
                'key': s.key,
                'label': s.label,
                'kind': s.kind,
                if (s.isMedia) 'media': s.media,
                if (s.initial != null) 'default': s.initial,
                if (s.hint.isNotEmpty) 'hint': s.hint,
              },
          ],
      };

  Future<McpToolResult> _applyTemplate(Map<String, dynamic> a) async {
    final c = _editor();
    final id = _need(a, 'id');
    final t = (await _templates(null)).where((x) => x.id == id).firstOrNull ?? (throw _Fail('No template "$id" (see list_templates).'));
    // win-30: "values" is a common name for the slots (it was ignored silently).
    final slotsArg = a['slots'] ?? a['values'];
    final raw = slotsArg is Map ? Map<String, dynamic>.from(slotsArg) : <String, dynamic>{};
    final start = _num(a, 'start') ?? c.time;
    c.beginGesture(); // library imports + every layer = one undo step
    try {
      final values = await host.resolveLibrary(c, raw);
      values.removeWhere((k, v) => v == null);
      final r = SceneTemplates.insert(c.project, t, start: start, values: values);
      c.endGesture();
      if (r.createdIds.isNotEmpty) c.select(r.createdIds.first);
      return McpToolResult.json({'ok': true, 'template': t.name, 'start': _r(start), 'created': r.createdIds});
    } catch (e) {
      c.endGesture();
      if (e is CommandError) rethrow;
      throw _Fail('Could not insert "${t.name}": $e');
    }
  }

  // ------------------------------------------------------------ library

  // V2-lead >>> library ops (V2-F)
  Future<McpToolResult> _libraryOps(String name, Map<String, dynamic> a) async {
    final lib = await AssetLibrary.shared();
    try {
      final r = switch (name) {
        'library_import_folder' => await LibraryOps.importFolder(lib, a),
        'library_clean' => await LibraryOps.clean(lib, a),
        _ => LibraryOps.suggest(lib, a),
      };
      return McpToolResult.json(r);
    } on ArgumentError catch (e) {
      throw _Fail('${e.message}');
    }
  }
  // <<< V2-lead

  // win-43 >>> Flow panel
  Future<McpToolResult> _flowPanel(String name, Map<String, dynamic> a, McpProgress? progress) async {
    final h = host;
    if (h is! RemoteFlowPanel) throw _Fail('The Flow panel needs the MotionAI Windows app (build 43 or newer).');
    final f = h;
    try {
      switch (name) {
        case 'flow_panel_open':
          return McpToolResult.json(await f.flowOpen(url: _str(a, 'url'), show: _bool(a, 'show') ?? true));
        case 'flow_pull':
          final job = jobs.start('flow_pull');
          var step = 0;
          try {
            final r = await f.flowPull(a, status: (s) {
              job.message = s;
              progress?.report(++step, message: s);
            });
            job.done(null, message: 'Saved ${r['saved']} images');
            return McpToolResult.json(r);
          } catch (e) {
            job.fail(e);
            rethrow;
          }
        case 'flow_panel_eval':
          final secs = _num(a, 'timeout') ?? 45;
          final v = await f.flowEval(_need(a, 'code'), timeout: Duration(milliseconds: (secs.clamp(1, 300) * 1000).round()));
          return McpToolResult.json({'result': v});
        default:
          return McpToolResult.json({'closed': await f.flowClose()});
      }
    } on StateError catch (e) {
      throw _Fail(e.message);
    } on TimeoutException {
      throw _Fail('The Flow page did not answer in time.');
    }
  }
  // <<< win-43

  Future<McpToolResult> _librarySearch(Map<String, dynamic> a) async {
    final lib = await AssetLibrary.shared();
    // V2-lead: role/tags/kit (and fuzzy matching) go through LibraryOps.search.
    if (a['role'] != null || a['roles'] != null || a['tags'] != null || a['kit'] != null) {
      try {
        return McpToolResult.json(LibraryOps.search(lib, a));
      } on ArgumentError catch (e) {
        throw _Fail('${e.message}');
      }
    }
    final type = switch (_str(a, 'type')) { 'image' => MediaType.image, 'video' => MediaType.video, 'audio' => MediaType.audio, _ => null };
    final limit = (_num(a, 'limit') ?? 30).round().clamp(1, 100);
    final found = lib.search(_str(a, 'query') ?? '', type: type, transparent: _bool(a, 'transparent') == true ? true : null);
    return McpToolResult.json({
      'total': found.length,
      'assets': [
        for (final x in found.take(limit))
          {
            'id': 'lib:${x.id}',
            'type': x.type.name,
            'name': x.name,
            if (x.kind.isNotEmpty) 'kind': x.kind,
            if (x.tags.isNotEmpty) 'tags': x.tags,
            if (x.description.isNotEmpty) 'description': x.description,
            if (x.transparent) 'transparent': true,
            'size': [x.width.round(), x.height.round()],
            if (x.duration > 0) 'duration': _r(x.duration),
          },
      ],
    });
  }

  Future<McpToolResult> _libraryInsert(Map<String, dynamic> a) async {
    final c = _editor();
    final id = _need(a, 'id');
    final lib = await AssetLibrary.shared();
    if (lib.byId(id) == null) throw _Fail('No library asset "$id" (see library_search).');
    final m = await lib.importInto(c.project, id, mediaDir: await c.storage.mediaDir());
    c.mediaChanged();
    List<String> created = const [];
    if (_bool(a, 'add_to_timeline') ?? true) {
      final dur = _num(a, 'duration');
      created = c.run({
        'op': 'add_layer',
        'type': m.type.name,
        'media': m.id,
        'start': _num(a, 'start') ?? c.time,
        if (dur != null) 'duration': dur,
        if (m.type == MediaType.audio) 'index': c.comp.layers.length,
      }).createdIds;
      if (created.isNotEmpty) c.select(created.first);
    }
    return McpToolResult.json({'ok': true, 'media': _media(m), if (created.isNotEmpty) 'layers': created});
  }
}
