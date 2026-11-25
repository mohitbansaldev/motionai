// MCP (Agent P): the tools Claude calls. Every project change goes through
// the EditorController (undoable, visible live in the editor).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
import '../services/captions.dart';
import '../services/project_storage.dart';
import '../state/editor_controller.dart';
import 'mcp_protocol.dart';
import 'mcp_server.dart';
import 'remote_export.dart';
import 'remote_jobs.dart';

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
  Future<McpToolResult> callTool(String name, Map<String, dynamic> args) async {
    if (!kMcpToolNames.contains(name)) throw McpUnknownTool(name);
    try {
      if (kMcpEditTools.contains(name)) {
        final b = jobs.blocking;
        if (b != null) {
          throw _Fail('A ${b.kind} job (${b.id}) is running${b.message.isEmpty ? '' : ': ${b.message}'}. '
              'Wait for it (${b.kind == 'export' ? 'export_status' : 'job_status'}) or cancel_job first.');
        }
      }
      final r = await _call(name, args);
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

  Future<McpToolResult> _call(String name, Map<String, dynamic> a) async {
    switch (name) {
      case 'get_state':
        return McpToolResult.json(await state());
      case 'get_command_spec':
        return McpToolResult.text('NOTE (MCP): you are connected through tools. Pass the "commands" array to run_commands '
            'and talk to the user normally; the "reply"/JSON output format below is for the in-app assistant only.\n\n$commandSpec');
      case 'run_commands':
        return _runCommands(a);
      case 'get_layer':
        final c = _editor();
        final l = c.comp.layerById(_need(a, 'layer'));
        if (l == null) throw _Fail('No layer "${a['layer']}" in ${c.comp.name}. Layer ids are in get_state.');
        return McpToolResult.json(l.toJson());
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
        final t = (_num(a, 'time') ?? c.time).clamp(0.0, c.comp.duration).toDouble();
        final w = (_num(a, 'width') ?? 960).round().clamp(160, 1920);
        final png = await host.renderPng(c, t, w);
        final h = (w * c.comp.height / c.comp.width).round();
        return McpToolResult.image(png, caption: 'Frame at ${_r(t)} s of "${c.comp.name}" (${w}x$h; composition ${c.comp.width.round()}x${c.comp.height.round()}).');
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
        return _export(a);
      case 'export_status':
        final id = _str(a, 'job');
        final j = id == null ? jobs.latest('export') : jobs.byId(id);
        if (j == null) throw _Fail(id == null ? 'No export has been started.' : 'No job "$id".');
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
        return _director(a);
      case 'captions_generate':
        return _captions(a);
      case 'list_templates':
        return McpToolResult.json({'templates': [for (final t in await _templates(_str(a, 'category'))) _template(t)]});
      case 'apply_template':
        return _applyTemplate(a);
      case 'library_search':
        return _librarySearch(a);
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
    if (uri == kResourceProject) {
      final c = host.editor;
      if (c == null) return ('application/json', jsonEncode({'error': 'No project is open'}));
      return ('application/json', jsonEncode(c.project.toJson()));
    }
    throw McpUnknownResource(uri);
  }

  // ------------------------------------------------------------ state

  Future<Map<String, dynamic>> state() async {
    final out = <String, dynamic>{'app': 'MotionAI', 'screen': host.screen};
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

  Future<McpToolResult> _export(Map<String, dynamic> a) async {
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
    return McpToolResult.json({'ok': true, 'job': job.id, 'message': 'Export started. Poll export_status until state is done.'});
  }

  // ------------------------------------------------------------ Director

  Future<McpToolResult> _director(Map<String, dynamic> a) async {
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

  McpToolResult _captions(Map<String, dynamic> a) {
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
    return McpToolResult.json({'ok': true, 'job': job.id, 'layer': source.id, 'message': 'Transcribing. Poll job_status.'});
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
    final raw = a['slots'] is Map ? Map<String, dynamic>.from(a['slots'] as Map) : <String, dynamic>{};
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

  Future<McpToolResult> _librarySearch(Map<String, dynamic> a) async {
    final lib = await AssetLibrary.shared();
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
