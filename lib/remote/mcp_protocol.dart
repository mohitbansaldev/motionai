// MCP (Agent P): Model Context Protocol pieces shared by the in-app control
// server and the stdio bridge (tool/motionai_mcp.dart).
//
// PURE DART: no Flutter imports here (the bridge is compiled with
// `dart compile exe`). JSON-RPC helpers, protocol version negotiation, the
// tool/resource catalogue, the control-file location and the Claude config
// snippets.

import 'dart:convert';

/// Newest MCP revision we speak, and the older ones we accept.
const String kMcpProtocolVersion = '2025-06-18';
const List<String> kMcpSupportedVersions = ['2025-06-18', '2025-03-26', '2024-11-05'];

/// Default localhost port of the in-app server.
const int kMcpDefaultPort = 7820;

/// Server name used in Claude configs.
const String kMcpServerName = 'motionai';

/// Version answered by the server (bumped when the tools change).
const String kMcpServerVersion = '1.0.0';

/// The version to answer for a client's requested one: the same if we
/// support it, otherwise our newest (the client then decides).
String negotiateProtocolVersion(Object? requested) =>
    requested is String && kMcpSupportedVersions.contains(requested) ? requested : kMcpProtocolVersion;

// ---------------------------------------------------------------- JSON-RPC

class JsonRpc {
  static const parseError = -32700;
  static const invalidRequest = -32600;
  static const methodNotFound = -32601;
  static const invalidParams = -32602;
  static const internalError = -32603;

  static Map<String, dynamic> result(Object? id, Object? result) => {'jsonrpc': '2.0', 'id': id, 'result': result};

  static Map<String, dynamic> error(Object? id, int code, String message, [Object? data]) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message, if (data != null) 'data': data},
      };

  /// A request or notification has a string "method"; a notification has no "id".
  static bool isNotification(Object? m) => m is Map && m['method'] is String && !m.containsKey('id');
  static bool isRequest(Object? m) => m is Map && m['method'] is String && m.containsKey('id');
  static bool isResponse(Object? m) => m is Map && !m.containsKey('method') && (m.containsKey('result') || m.containsKey('error'));
}

/// What `initialize` answers (the server and the bridge give the same).
Map<String, dynamic> initializeResult(Object? requestedVersion) => {
      'protocolVersion': negotiateProtocolVersion(requestedVersion),
      'capabilities': {
        'tools': {'listChanged': false},
        'resources': {'subscribe': false, 'listChanged': false},
      },
      'serverInfo': {'name': kMcpServerName, 'title': 'MotionAI', 'version': kMcpServerVersion},
      'instructions': kMcpInstructions,
    };

const String kMcpInstructions = '''
MotionAI is a motion-graphics video editor (After Effects / Alight Motion style) running on the user's PC. These tools drive the running app live: every edit appears on the user's screen and can be undone with undo (or Ctrl+Z).
Typical flow: get_state → (list_projects + open_project, or new_project) → get_command_spec once → run_commands → render_frame to look at the result → fix → save_project / export_video.
- All edits are JSON edit commands (see get_command_spec / resource motionai://spec). One run_commands call = one atomic batch = one undo step; if any command fails nothing changes and you get the error.
- Times are seconds, positions are composition pixels ((0,0) = top-left). Layer ids come from get_state.
- import_media takes file paths on the user's PC. Long jobs (export_video, director_run, captions_generate) return a job id: poll export_status / job_status.
- Reply to the user in their language (often Hindi/Hinglish).''';

// ---------------------------------------------------------------- tools

Map<String, dynamic> _obj(Map<String, dynamic> props, {List<String> required = const []}) => {
      'type': 'object',
      'properties': props,
      if (required.isNotEmpty) 'required': required,
      'additionalProperties': false,
    };

Map<String, dynamic> _s(String d) => {'type': 'string', 'description': d};
Map<String, dynamic> _n(String d) => {'type': 'number', 'description': d};
Map<String, dynamic> _b(String d) => {'type': 'boolean', 'description': d};
Map<String, dynamic> _e(List<String> v, String d) => {'type': 'string', 'enum': v, 'description': d};

Map<String, dynamic> _tool(String name, String title, String description, Map<String, dynamic> schema,
        {bool readOnly = false, bool destructive = false, bool idempotent = false}) =>
    {
      'name': name,
      'title': title,
      'description': description,
      'inputSchema': schema,
      'annotations': {
        'title': title,
        'readOnlyHint': readOnly,
        if (!readOnly) 'destructiveHint': destructive,
        'idempotentHint': readOnly || idempotent,
        'openWorldHint': false,
      },
    };

/// Caption style ids (kept in step with CaptionStyles.all; checked by tests).
const List<String> kCaptionStyleIds = [
  'karaoke', 'word_pop', 'keyword', 'boxed', 'neon', 'punchy', 'typewriter', 'minimal', 'hinglish', 'devanagari', 'decode',
];

/// Starter project templates for new_project (kept in step with Templates.all).
const List<String> kStarterTemplateIds = ['doc_intro', 'shorts_hook', 'quote', 'title_3d'];

/// Project formats for new_project.
const Map<String, List<double>> kProjectFormats = {
  'youtube': [1920, 1080],
  'shorts': [1080, 1920],
  'square': [1080, 1080],
  'portrait': [1080, 1350],
  '4k': [3840, 2160],
};

/// Every tool the server offers, as MCP tool definitions.
final List<Map<String, dynamic>> kMcpTools = [
  _tool('get_state', 'Get editor state',
      'Snapshot of MotionAI right now: the screen shown, the open project (id, name, composition size/fps/duration, playhead, '
          'selection, undo/redo availability, precomps, media list with ids, and every layer top-to-bottom with id, type, '
          'start/end, position/scale/opacity (static values or keyframes), effects and masks), and running jobs. '
          'If no project is open it lists the saved projects instead. Call this first and after edits to get layer ids.',
      _obj({}),
      readOnly: true),
  _tool('get_command_spec', 'Get edit-command reference',
      'Returns the full reference of MotionAI edit commands (layers, keyframes, effects, masks, camera moves, components, '
          'text animators, captions, sound, precomps, 3D scenes and maps) that run_commands accepts. Read it once before editing. '
          'Ignore its "answer with one JSON object" output-format section: with these tools you pass the commands array to run_commands.',
      _obj({}),
      readOnly: true),
  _tool('run_commands', 'Run edit commands',
      'Applies a list of edit commands to the open project as ONE atomic batch and ONE undo step, live in the editor. '
          'Each command is an object with "op" (e.g. add_layer, update_layer, set_keyframe, add_effect, camera_move, add_component) '
          'plus its fields, exactly as in get_command_spec. Give new layers an "id" so later commands in the same batch can refer '
          'to them. If any command fails, nothing changes and the error says which one; fix it and send the whole batch again. '
          'Returns the ids of created layers and a log.',
      _obj({
        'commands': {
          'type': 'array',
          'description': 'Edit commands, e.g. [{"op":"add_layer","type":"text","id":"title","text":"Hello","font_size":120}]',
          'items': {'type': 'object'},
        },
      }, required: ['commands'])),
  _tool('get_layer', 'Get one layer in full',
      'The complete JSON of one layer of the open composition (all properties with keyframes and eases, effects with params, '
          'masks, text style, shape settings). Use when get_state\'s summary is not detailed enough.',
      _obj({'layer': _s('Layer id')}, required: ['layer']),
      readOnly: true),
  _tool('undo', 'Undo', 'Undoes the last edit step(s) in the open project, like Ctrl+Z.',
      _obj({'steps': {'type': 'integer', 'minimum': 1, 'maximum': 50, 'description': 'How many steps (default 1)'}})),
  _tool('redo', 'Redo', 'Redoes undone edit step(s), like Ctrl+Y.',
      _obj({'steps': {'type': 'integer', 'minimum': 1, 'maximum': 50, 'description': 'How many steps (default 1)'}})),
  _tool('list_projects', 'List projects', 'All saved MotionAI projects, newest first: id, name, size, duration, layer count, last modified.',
      _obj({}),
      readOnly: true),
  _tool('open_project', 'Open project',
      'Opens a saved project in the editor (the current one is saved first). Not possible while an export or Director job runs.',
      _obj({'id': _s('Project id from list_projects')}, required: ['id'])),
  _tool('new_project', 'New project',
      'Creates a new project, saves it and opens it in the editor. Pick a format (youtube 1920x1080, shorts 1080x1920, square, '
          'portrait 4:5, 4k) or exact width/height. Optional starter template: ${kStarterTemplateIds.join(', ')}.',
      _obj({
        'name': _s('Project name (default "Project N")'),
        'format': _e(kProjectFormats.keys.toList(), 'Frame format (default youtube)'),
        'width': _n('Composition width in pixels (overrides format)'),
        'height': _n('Composition height in pixels (overrides format)'),
        'fps': _n('Frames per second (default 30)'),
        'duration': _n('Length in seconds (default 10; grows when layers are added past the end only if you set_comp)'),
        'template': _e(kStarterTemplateIds, 'Start from a ready-made animated template'),
      })),
  _tool('save_project', 'Save project', 'Saves the open project to disk now (it also autosaves after every edit).', _obj({}), idempotent: true),
  _tool('rename_project', 'Rename project', 'Renames the open project.', _obj({'name': _s('New name')}, required: ['name']), idempotent: true),
  _tool('close_project', 'Close project', 'Saves and closes the open project, back to the home screen.', _obj({}), idempotent: true),
  _tool('import_media', 'Import media files',
      'Imports photos, videos or audio from paths on the user\'s PC (e.g. "C:\\\\Users\\\\me\\\\Videos\\\\clip.mp4") into the open '
          'project. Files are copied into MotionAI\'s storage. Returns the new media ids (use them in add_layer "media"). '
          'With add_to_timeline the files are also placed one after another from "start" (default: playhead) as layers.',
      _obj({
        'paths': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Absolute file paths'},
        'add_to_timeline': _b('Also add each file as a layer (default false)'),
        'start': _n('Timeline start for add_to_timeline, seconds (default playhead)'),
      }, required: ['paths'])),
  _tool('list_media', 'List media',
      'Media in the open project: id, type (video/image/audio), name, pixel size, duration, file path, AI description.',
      _obj({}),
      readOnly: true),
  _tool('render_frame', 'Render a frame',
      'Renders the open composition at a time exactly as export would (all effects, 3D camera, text animation) and returns a PNG '
          'image, so you can see your edit. Use it to check layout, legibility and timing after run_commands.',
      _obj({
        'time': _n('Seconds (default: playhead)'),
        'width': {'type': 'integer', 'minimum': 160, 'maximum': 1920, 'description': 'Image width in pixels (default 960)'},
      }),
      readOnly: true),
  _tool('seek', 'Move playhead', 'Moves the editor playhead to a time (seconds). New layers and set_property use the playhead.',
      _obj({'time': _n('Seconds')}, required: ['time']),
      idempotent: true),
  _tool('play', 'Play', 'Starts playback in the editor preview (for the user to watch).', _obj({}), idempotent: true),
  _tool('pause', 'Pause', 'Pauses playback.', _obj({}), idempotent: true),
  _tool('select', 'Select layer',
      'Selects a layer in the editor (shows its properties to the user), or the camera, or nothing.',
      _obj({
        'layers': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Layer ids (empty = deselect). The first one becomes the active layer.'},
        'camera': _b('Select the camera instead'),
      }),
      idempotent: true),
  _tool('open_comp', 'Open composition',
      'Opens a nested composition (precomp) for editing, or "main" to go back. run_commands, get_state and render_frame work on the open composition.',
      _obj({'comp': _s('Composition id from get_state "comps", or "main"')}, required: ['comp']),
      idempotent: true),
  _tool('export_video', 'Export video',
      'Saves the project and starts exporting the main composition to MP4 (shows the export screen to the user). Returns at once; '
          'poll export_status. Windows: default folder is Videos\\\\MotionAI. Edits are blocked while exporting.',
      _obj({
        'resolution': {'type': 'integer', 'enum': [720, 1080, 1440, 2160], 'description': 'Short side in pixels (default 1080)'},
        'fps': _n('Frame rate (default: project fps)'),
        'folder': _s('Output folder (Windows; default the last used export folder)'),
        'file_name': _s('File name, e.g. "final.mp4" (default "<project>_<time>.mp4")'),
        'high_quality': _b('Higher bitrate (default true)'),
      })),
  _tool('export_status', 'Export status',
      'Progress of the latest (or a given) export: phase setup/rendering/finishing/done/failed, frame N of M, output file path, error.',
      _obj({'job': _s('Job id (default: latest export)')}),
      readOnly: true),
  _tool('director_run', 'Run the Director (AI auto-edit)',
      'Runs MotionAI\'s Director headlessly: from a brief (and optional script) and the project\'s media it writes/plans a '
          'documentary storyboard, builds the whole timeline (B-roll moves, components, captions, sound effects, music duck) as '
          'one undo step, and optionally reviews rendered frames. Uses MotionAI\'s OWN AI connection (ChatGPT plan or API key '
          'set in the app); if that is not set up it fails, and you can build the edit yourself with run_commands. '
          'Returns a job id; poll job_status (takes minutes).',
      _obj({
        'brief': _s('Topic / instructions in the user\'s words'),
        'script': _s('Narration script (empty = the AI writes it from the brief)'),
        'narration': _e(['aroll', 'voiceover', 'phone_voice', 'silent'],
            'Voice source: aroll = talking-head video, voiceover = audio file, phone_voice = text-to-speech of the script, silent = text only'),
        'aroll_media': _s('Video media id of the presenter (narration aroll)'),
        'voice_media': _s('Audio media id of the voice-over (narration voiceover)'),
        'music_media': _s('Audio media id of background music'),
        'language': _e(['hi', 'en', 'auto'], 'Spoken language (default from AI settings)'),
        'roman': _b('Hinglish captions in Roman script'),
        'minutes': {'type': 'integer', 'minimum': 1, 'maximum': 30, 'description': 'Length when the AI writes the script (default 3)'},
        'captions': _b('Add captions (default true)'),
        'sfx': _b('Add sound effects (default true)'),
        'depth': _b('AI cut-outs for depth shots (default true)'),
        'review': _b('Render frames and fix problems (default true)'),
        'look': _s('Look: auto, cinematic_doc, shorts_punch, retro_film, noir, warm_travel, clean_minimal'),
      }, required: ['brief'])),
  _tool('job_status', 'Job status',
      'Status of a background job (director_run, captions_generate, export_video): running/done/failed/cancelled, progress message, result. '
          'Without "job" lists all recent jobs.',
      _obj({'job': _s('Job id')}),
      readOnly: true),
  _tool('cancel_job', 'Cancel job', 'Asks a running job (export or Director) to stop.', _obj({'job': _s('Job id')}, required: ['job'])),
  _tool('captions_generate', 'Auto captions',
      'Transcribes speech of a video/audio layer (Whisper, on the PC) and adds animated caption layers with per-word timing '
          '(one undo step). Returns a job id; poll job_status. Styles: ${kCaptionStyleIds.join(', ')}.',
      _obj({
        'layer': _s('Video or audio layer id (default: the selected one, else the first video/audio layer)'),
        'style': _e(kCaptionStyleIds, 'Caption style (default karaoke)'),
        'language': _e(['hi', 'en', 'auto'], 'Spoken language (default hi)'),
        'roman': _b('Write Hindi in Roman script (Hinglish)'),
        'max_words': {'type': 'integer', 'minimum': 0, 'maximum': 12, 'description': 'Most words per caption (0 = style default)'},
        'emphasis': _b('Highlight numbers, money, years, names (default true)'),
        'ai_emphasis': _b('Ask MotionAI\'s AI for more key words (needs the app AI set up)'),
      })),
  _tool('list_templates', 'List scene templates',
      'Insertable scene templates (intros, showcases, transitions, captions, lower thirds, endings, maps, 3D, and the user\'s saved '
          'templates): id, name, category, duration and fillable slots (key, kind text/media/medias/color, default).',
      _obj({'category': _s('Only this category')}),
      readOnly: true),
  _tool('apply_template', 'Insert scene template',
      'Inserts a scene template into the open composition at "start" (default playhead) as one undo step. "slots" fills its '
          'slots by key: text, "#RRGGBB" colours, media ids (project ids or "lib:<id>" library ids) or lists of media ids.',
      _obj({
        'id': _s('Template id from list_templates'),
        'slots': {'type': 'object', 'description': 'Slot key → value'},
        'start': _n('Seconds (default playhead)'),
      }, required: ['id'])),
  _tool('library_search', 'Search asset library',
      'Searches the user\'s asset library (photos, cut-outs, videos, music shared by all projects) by words in name, tags, '
          'description, kind, era, region, mood. Returns ids like "lib:<id>".',
      _obj({
        'query': _s('Search words (empty = newest)'),
        'type': _e(['image', 'video', 'audio'], 'Only this media type'),
        'transparent': _b('Only cut-outs with transparency'),
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100, 'description': 'Default 30'},
      }),
      readOnly: true),
  _tool('library_insert', 'Insert library asset',
      'Imports a library asset into the open project (returns its project media id) and, by default, adds it as a layer at "start".',
      _obj({
        'id': _s('Library id ("lib:<id>") from library_search'),
        'add_to_timeline': _b('Also add a layer (default true)'),
        'start': _n('Seconds (default playhead)'),
        'duration': _n('Layer duration (default 5 s for photos, the clip length for video/audio)'),
      }, required: ['id'])),
  _tool('list_effects', 'List effects', 'Every effect for add_effect: id, label, category and params (key, default, min, max, options).',
      _obj({}),
      readOnly: true),
  _tool('list_components', 'List components',
      'Every motion-graphics component for add_component (source cards, lower thirds, maps, pins, counters, 3D scenes, …): type and label. '
          'Their fields are described in get_command_spec.',
      _obj({}),
      readOnly: true),
];

Set<String> get kMcpToolNames => {for (final t in kMcpTools) t['name'] as String};

/// Tools that change the project (blocked while an export/Director job runs).
const Set<String> kMcpEditTools = {
  'run_commands', 'undo', 'redo', 'open_project', 'new_project', 'close_project', 'import_media', 'open_comp',
  'director_run', 'captions_generate', 'apply_template', 'library_insert', 'export_video',
};

// ---------------------------------------------------------------- resources

const String kResourceSpec = 'motionai://spec';
const String kResourceProject = 'motionai://project';

final List<Map<String, dynamic>> kMcpResources = [
  {
    'uri': kResourceSpec,
    'name': 'command-spec',
    'title': 'MotionAI edit-command reference',
    'description': 'Every edit command run_commands accepts.',
    'mimeType': 'text/plain',
  },
  {
    'uri': kResourceProject,
    'name': 'project',
    'title': 'Open project (full JSON)',
    'description': 'The complete JSON of the project open in the editor (all comps, layers, keyframes, media).',
    'mimeType': 'application/json',
  },
];

// ---------------------------------------------------------------- tool results

/// A tools/call result.
class McpToolResult {
  final List<Map<String, dynamic>> content;
  final bool isError;
  final Map<String, dynamic>? structured;
  const McpToolResult(this.content, {this.isError = false, this.structured});

  factory McpToolResult.text(String text, {bool isError = false}) => McpToolResult([
        {'type': 'text', 'text': text},
      ], isError: isError);

  factory McpToolResult.json(Object? data) {
    final text = const JsonEncoder.withIndent(' ').convert(data);
    return McpToolResult([
      {'type': 'text', 'text': text},
    ], structured: data is Map<String, dynamic> ? data : null);
  }

  factory McpToolResult.error(String message) => McpToolResult.text(message, isError: true);

  factory McpToolResult.image(List<int> png, {String? caption}) => McpToolResult([
        {'type': 'image', 'data': base64Encode(png), 'mimeType': 'image/png'},
        if (caption != null) {'type': 'text', 'text': caption},
      ]);

  Map<String, dynamic> toJson() => {
        'content': content,
        'isError': isError,
        if (structured != null) 'structuredContent': structured,
      };
}

/// A tool name that does not exist (answered as JSON-RPC invalid params).
class McpUnknownTool implements Exception {
  final String name;
  McpUnknownTool(this.name);
  @override
  String toString() => 'Unknown tool: $name';
}

/// A resource uri that does not exist.
class McpUnknownResource implements Exception {
  final String uri;
  McpUnknownResource(this.uri);
  @override
  String toString() => 'Resource not found: $uri';
}

// ---------------------------------------------------------------- control file

/// Where the app tells the bridge its port and token:
/// Windows %APPDATA%\MotionAI\mcp.json, elsewhere ~/.config/MotionAI/mcp.json.
String mcpControlFilePath(Map<String, String> env, {required bool windows}) {
  if (windows) {
    final appData = env['APPDATA'] ?? '${env['USERPROFILE'] ?? 'C:'}\\AppData\\Roaming';
    return '$appData\\MotionAI\\mcp.json';
  }
  final base = env['XDG_CONFIG_HOME'] ?? '${env['HOME'] ?? '.'}/.config';
  return '$base/MotionAI/mcp.json';
}

/// Contents of the control file.
class McpControlInfo {
  final bool enabled;
  final int port;
  final String token;
  final int pid;
  final String exe;
  final String written;
  const McpControlInfo({required this.enabled, this.port = kMcpDefaultPort, this.token = '', this.pid = 0, this.exe = '', this.written = ''});

  String get url => 'http://127.0.0.1:$port/mcp';

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        if (enabled) 'port': port,
        if (enabled) 'url': url,
        if (enabled) 'token': token,
        'pid': pid,
        'exe': exe,
        'written': written,
      };

  static McpControlInfo? parse(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map) return null;
      return McpControlInfo(
        enabled: j['enabled'] == true,
        port: (j['port'] as num?)?.toInt() ?? kMcpDefaultPort,
        token: '${j['token'] ?? ''}',
        pid: (j['pid'] as num?)?.toInt() ?? 0,
        exe: '${j['exe'] ?? ''}',
        written: '${j['written'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------- Claude configs

/// The bridge exe next to motionai.exe.
String bridgeExePath(String appExePath) {
  final i = appExePath.lastIndexOf(RegExp(r'[\\/]'));
  final dir = i < 0 ? '.' : appExePath.substring(0, i);
  final sep = appExePath.contains('\\') ? '\\' : '/';
  return '$dir${sep}motionai-mcp${sep == '\\' ? '.exe' : ''}';
}

/// Claude Desktop `claude_desktop_config.json` with only MotionAI in it.
String claudeDesktopConfigSnippet(String bridgeExe) => const JsonEncoder.withIndent('  ').convert({
      'mcpServers': {
        kMcpServerName: {'command': bridgeExe, 'args': <String>[]},
      },
    });

/// Adds/updates MotionAI in an existing Claude Desktop config, keeping
/// every other setting and server. Returns null if [existing] is not a
/// JSON object (then the user should paste the snippet by hand).
String? mergeClaudeDesktopConfig(String? existing, String bridgeExe) {
  Map<String, dynamic> root = {};
  if (existing != null && existing.trim().isNotEmpty) {
    try {
      final j = jsonDecode(existing);
      if (j is! Map) return null;
      root = Map<String, dynamic>.from(j);
    } catch (_) {
      return null;
    }
  }
  final servers = root['mcpServers'];
  final map = servers is Map ? Map<String, dynamic>.from(servers) : <String, dynamic>{};
  map[kMcpServerName] = {'command': bridgeExe, 'args': <String>[]};
  root['mcpServers'] = map;
  return const JsonEncoder.withIndent('  ').convert(root);
}

/// Claude Code command for the stdio bridge.
String claudeCodeStdioCommand(String bridgeExe) => 'claude mcp add --scope user $kMcpServerName -- "$bridgeExe"';

/// Claude Code command for the direct HTTP connection (token header).
String claudeCodeHttpCommand(int port, String token) =>
    'claude mcp add --scope user --transport http $kMcpServerName http://127.0.0.1:$port/mcp --header "Authorization: Bearer $token"';

/// Generic remote-HTTP MCP client config (clients that take a url + headers).
String httpConfigSnippet(int port, String token) => const JsonEncoder.withIndent('  ').convert({
      'mcpServers': {
        kMcpServerName: {
          'type': 'http',
          'url': 'http://127.0.0.1:$port/mcp',
          'headers': {'Authorization': 'Bearer $token'},
        },
      },
    });

// ---------------------------------------------------------------- bridge framing

/// stdio transport helpers: one JSON-RPC message per line (UTF-8, no
/// embedded newlines), nothing else on stdout.
class BridgeFraming {
  /// Parses one input line. Returns (message, null) or (null, error
  /// response to write). Blank lines give (null, null).
  static (Object?, Map<String, dynamic>?) decode(String line) {
    final t = line.trim();
    if (t.isEmpty) return (null, null);
    Object? m;
    try {
      m = jsonDecode(t);
    } catch (e) {
      return (null, JsonRpc.error(null, JsonRpc.parseError, 'Parse error: not valid JSON'));
    }
    if (m is Map || m is List) return (m, null);
    return (null, JsonRpc.error(null, JsonRpc.invalidRequest, 'Invalid request'));
  }

  /// One message as one line (jsonEncode never emits raw newlines).
  static String encode(Object? message) => jsonEncode(message);

  /// Methods the bridge can answer without the app (so Claude starting up
  /// does not launch MotionAI).
  static const offline = {'initialize', 'ping', 'tools/list', 'resources/list', 'resources/templates/list', 'prompts/list'};

  /// Offline answer for [m] (a request), or null if the app is needed.
  static Map<String, dynamic>? localAnswer(Map m) {
    final id = m['id'];
    final params = m['params'] is Map ? m['params'] as Map : const {};
    switch (m['method']) {
      case 'initialize':
        return JsonRpc.result(id, initializeResult(params['protocolVersion']));
      case 'ping':
        return JsonRpc.result(id, {});
      case 'tools/list':
        return JsonRpc.result(id, {'tools': kMcpTools});
      case 'resources/list':
        return JsonRpc.result(id, {'resources': kMcpResources});
      case 'resources/templates/list':
        return JsonRpc.result(id, {'resourceTemplates': []});
      case 'prompts/list':
        return JsonRpc.result(id, {'prompts': []});
    }
    return null;
  }

  /// What to answer when the app can't be reached: tool calls get a tool
  /// error (so Claude reads the reason), other requests a JSON-RPC error.
  static Map<String, dynamic> unavailable(Map m, String reason) {
    if (m['method'] == 'tools/call') return JsonRpc.result(m['id'], McpToolResult.error(reason).toJson());
    return JsonRpc.error(m['id'], JsonRpc.internalError, reason);
  }
}
