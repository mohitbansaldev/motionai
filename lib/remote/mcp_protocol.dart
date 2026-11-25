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
const String kMcpServerVersion = '2.0.0';

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
MotionAI is a motion-graphics video editor (After Effects / Alight Motion style) running on the user's PC. These tools drive the running app live: every edit appears on the user's screen and is undoable (undo tool or Ctrl+Z).
Flow: get_state → (list_projects + open_project, or new_project) → get_command_spec once → run_commands → look → fix → save_project / export_video.
Workflow hint: use batch + preview_shot + check_scene. batch runs several tool calls in one request (e.g. run_commands then preview_shot then check_scene). preview_shot shows a whole time range as ONE labelled contact sheet (instead of many render_frame calls); check_scene lists problems (black gaps, layers ending early, empty edges in 3D moves, floating cut-outs, text overlap/off-frame, broken effects, missing media) with ready fix commands. Build shots with add_shot / sequence if get_command_spec lists them.
- All edits are JSON edit commands (get_command_spec / resource motionai://spec). One run_commands call = one atomic batch = one undo step; if any command fails nothing changes.
- Times are seconds, positions are composition pixels ((0,0) = top-left). Layer ids come from get_state. Give new layers an explicit "start" and "duration" (otherwise they start at the playhead).
- Long jobs (export_video, director_run, captions_generate): pass wait:true to get the final result in one call (progress notifications are sent when you give a progressToken), or poll export_status / job_status.
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
      'Snapshot of the app: screen, open project (id, name, comp size/fps/duration, playhead, selection, undo/redo), precomps, '
          'media ids, every layer top-to-bottom (id, type, start/end, transform values or keyframes, effects, masks) and running jobs. '
          'With no project open it lists saved projects. Call first, and after edits to get layer ids.',
      _obj({}),
      readOnly: true),
  _tool('get_command_spec', 'Get edit-command reference',
      'Full reference of the JSON edit commands run_commands accepts (layers, keyframes, effects, masks, camera, components, text '
          'animators, captions, sound, precomps, 3D scenes, maps, shots). Read once before editing; ignore its "answer with one JSON '
          'object" section: pass the commands array to run_commands.',
      _obj({}),
      readOnly: true),
  _tool('run_commands', 'Run edit commands',
      'Applies edit commands to the open composition as ONE atomic batch = ONE undo step, live in the editor. Each command is '
          '{"op": ..., fields} as in get_command_spec. Give new layers an "id" (and "start"/"duration") so later commands can use them. '
          'If any command fails nothing changes and the error names it. Returns created ids and a log.',
      _obj({
        'commands': {
          'type': 'array',
          'description': 'Edit commands, e.g. [{"op":"add_layer","type":"text","id":"title","text":"Hello","start":0,"duration":4}]',
          'items': {'type': 'object'},
        },
      }, required: ['commands'])),
  _tool('get_layer', 'Get one layer in full',
      'Complete JSON of one layer (keyframes with eases, effect params, masks, text style, shape) of the open composition '
          'or of "comp" (the user\'s view does not change).',
      _obj({'layer': _s('Layer id'), 'comp': _s('Composition id (default: the open one; "main" = main)')}, required: ['layer']),
      readOnly: true),
  _tool('get_layers', 'List layers of any comp',
      'Every layer of "comp" (default: the open one) top to bottom: id, name, type, start, end, is3d, parent; full:true '
          'returns complete layer JSON. Does not change what the user is looking at (no open_comp needed).',
      _obj({'comp': _s('Composition id ("main" = main)'), 'full': _b('Complete layer JSON (default false)')}),
      readOnly: true),
  _tool('editor_screenshot', 'Screenshot of the editor preview',
      'PNG of the live editor preview exactly as the user sees it (same draw path as the editor, unlike render_frame / '
          'preview_shot which use the export renderer). Use it to confirm that what you built shows correctly for the user.',
      _obj({'width': {'type': 'integer', 'minimum': 160, 'maximum': 1920, 'description': 'Image width (default 960)'}}),
      readOnly: true),
  _tool('undo', 'Undo', 'Undoes the last edit step(s) of the open project (Ctrl+Z).',
      _obj({'steps': {'type': 'integer', 'minimum': 1, 'maximum': 50, 'description': 'How many steps (default 1)'}})),
  _tool('redo', 'Redo', 'Redoes undone edit step(s) (Ctrl+Y).',
      _obj({'steps': {'type': 'integer', 'minimum': 1, 'maximum': 50, 'description': 'How many steps (default 1)'}})),
  _tool('list_projects', 'List projects', 'Saved projects, newest first: id, name, size, duration, layer count, modified.', _obj({}),
      readOnly: true),
  _tool('open_project', 'Open project', 'Opens a saved project in the editor (saves the current one first). Blocked during export/Director.',
      _obj({'id': _s('Project id (or exact name) from list_projects')}, required: ['id'])),
  _tool('new_project', 'New project',
      'Creates, saves and opens a new project. Format youtube 1920x1080 (default), shorts 1080x1920, square, portrait 4:5, 4k, or '
          'exact width/height. Optional starter template: ${kStarterTemplateIds.join(', ')}.',
      _obj({
        'name': _s('Project name (default "Project N")'),
        'format': _e(kProjectFormats.keys.toList(), 'Frame format (default youtube)'),
        'width': _n('Width in pixels (overrides format)'),
        'height': _n('Height in pixels (overrides format)'),
        'fps': _n('Frames per second (default 30)'),
        'duration': _n('Length in seconds (default 10; change later with set_comp)'),
        'template': _e(kStarterTemplateIds, 'Start from a ready-made animated template'),
      })),
  _tool('save_project', 'Save project', 'Saves the open project now (it also autosaves after edits).', _obj({}), idempotent: true),
  _tool('rename_project', 'Rename project', 'Renames the open project.', _obj({'name': _s('New name')}, required: ['name']), idempotent: true),
  _tool('close_project', 'Close project', 'Saves and closes the open project (back to the home screen).', _obj({}), idempotent: true),
  _tool('import_media', 'Import media files',
      'Copies photos/videos/audio from absolute paths on the user\'s PC into the open project and returns media ids (for add_layer '
          '"media"). add_to_timeline also places them one after another from "start" (default playhead).',
      _obj({
        'paths': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Absolute file paths'},
        'add_to_timeline': _b('Also add each file as a layer (default false)'),
        'start': _n('Timeline start for add_to_timeline, seconds (default playhead)'),
      }, required: ['paths'])),
  _tool('list_media', 'List media', 'Media of the open project: id, type, name, pixel size, duration, file path, AI description.', _obj({}),
      readOnly: true),
  _tool('render_frame', 'Render a frame',
      'One PNG of the open composition at a time, rendered like the export (effects, 3D camera, text animation). '
          'To look at a move or a shot prefer preview_shot (many times in one image).',
      _obj({
        'time': _n('Seconds (default: playhead)'),
        'width': {'type': 'integer', 'minimum': 160, 'maximum': 1920, 'description': 'Image width in pixels (default 960)'},
        'comp': _s('Composition id (default: the open one; "main" = main). The user\'s view does not change.'),
      }),
      readOnly: true),
  _tool('preview_shot', 'Preview a shot (contact sheet)',
      'Renders "count" frames evenly spread over from..to and returns ONE PNG contact sheet (grid, each tile labelled #n and its '
          'time) plus the list of times. Use it to judge a camera move, an animation or a whole shot in one look. '
          'format "gif" returns a small animated GIF instead (≤ 20 frames, ≤ 2 s, ≤ 480 px; some clients only show its first frame).',
      _obj({
        'from': _n('Start time, seconds (default 0)'),
        'to': _n('End time, seconds (default: composition end)'),
        'count': {'type': 'integer', 'minimum': 1, 'maximum': 12, 'description': 'Frames on the sheet (default 6; GIF: default 12, max 20)'},
        'width': {'type': 'integer', 'minimum': 160, 'maximum': 960, 'description': 'Width of each tile in pixels (default 480; GIF max 480)'},
        'comp': _s('Composition id (default: the open one; "main" = main)'),
        'format': _e(['png', 'gif'], 'png contact sheet (default) or animated gif'),
      }),
      readOnly: true),
  _tool('check_scene', 'Check the scene for problems',
      'Lints the composition over from..to (pure analysis, no rendering) and returns JSON problems, each with layer id(s), time, '
          'severity and a "fix" list of run_commands commands: black gaps, layers ending before their set / starting at the playhead, '
          '3D moves uncovering empty canvas edges, cut-outs floating above the ground, text overlapping or off-frame/outside the safe '
          'area, known-broken effects (blur on a 3D layer, scramble on Devanagari) and missing media files. "fix_all" collects '
          'every fix. Run it after building a shot; review the fixes before applying.',
      _obj({
        'comp': _s('Composition id (default: the open one)'),
        'from': _n('Start of the range, seconds (default 0)'),
        'to': _n('End of the range, seconds (default: composition end)'),
      }),
      readOnly: true),
  _tool('batch', 'Run several tools',
      'Runs several tool calls in ONE request, in order, and returns every result (images included), each headed "[#n tool] ok|ERROR". '
          'Stops at the first error unless continue_on_error. Use it to save round trips, e.g. run_commands → check_scene → '
          'preview_shot. batch cannot contain batch.',
      _obj({
        'calls': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 50,
          'description': 'Tool calls, e.g. [{"name":"run_commands","arguments":{"commands":[...]}},{"name":"preview_shot","arguments":{"from":0,"to":6}}]',
          'items': {
            'type': 'object',
            'properties': {
              'name': {'type': 'string', 'description': 'Tool name'},
              'arguments': {'type': 'object', 'description': 'Its arguments'},
            },
            'required': ['name'],
          },
        },
        'continue_on_error': _b('Run the remaining calls after an error (default false)'),
      }, required: ['calls'])),
  _tool('seek', 'Move playhead', 'Moves the editor playhead (seconds). Commands without "time"/"start" use the playhead.',
      _obj({'time': _n('Seconds')}, required: ['time']),
      idempotent: true),
  _tool('play', 'Play', 'Starts preview playback for the user to watch.', _obj({}), idempotent: true),
  _tool('pause', 'Pause', 'Pauses playback.', _obj({}), idempotent: true),
  _tool('select', 'Select layers',
      'Selects layers in the editor so the user sees what you mean (not an undo step). Commands accept "layers": "selection". '
          'Or select the camera, or nothing (empty list).',
      _obj({
        'layers': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Layer ids (empty list = deselect)'},
        'filter': {'type': 'object', 'description': 'Instead of ids: a layer filter as in get_command_spec, e.g. {"type":"text"}'},
        'mode': _e(['replace', 'add', 'remove'], 'How to combine with the current selection (default replace)'),
        'camera': _b('Select the camera instead'),
      }),
      idempotent: true),
  _tool('open_comp', 'Open composition',
      'Opens a nested composition (precomp) for editing, or "main" to go back. Editing, get_state and rendering use the open composition.',
      _obj({'comp': _s('Composition id from get_state "comps", or "main"')}, required: ['comp']),
      idempotent: true),
  _tool('export_video', 'Export video',
      'Saves and exports the main composition to MP4 (the user sees the export screen). With wait:true the call returns when the '
          'file is ready (progress notifications if you sent a progressToken; without one it waits at most ~50 s, then returns the '
          'status: call export_status). Otherwise returns a job id at once. Edits are blocked while exporting. '
          'Windows default folder: Videos\\MotionAI.',
      _obj({
        'resolution': {'type': 'integer', 'enum': [720, 1080, 1440, 2160], 'description': 'Short side in pixels (default 1080)'},
        'fps': _n('Frame rate (default: project fps)'),
        'folder': _s('Absolute output folder (default: the last used export folder)'),
        'file_name': _s('File name, e.g. "final.mp4" (default "<project>_<time>.mp4")'),
        'high_quality': _b('Higher bitrate (default true)'),
        'wait': _b('Block until the export ends and return the file (default false)'),
        'timeout': _n('Most seconds to wait with wait:true (default 540 with a progressToken, else 50; max 540)'),
      })),
  _tool('export_status', 'Export status',
      'Latest (or given) export: phase setup/rendering/finishing/done/failed, frame N of M, output file, error.',
      _obj({'job': _s('Job id (default: latest export)')}),
      readOnly: true),
  _tool('director_run', 'Run the Director (AI auto-edit)',
      'Runs MotionAI\'s own Director: from a brief (+ optional script) and the project media it plans a documentary storyboard and '
          'builds the whole timeline (B-roll moves, components, captions, SFX, music duck) as one undo step, optionally reviewing '
          'frames. Needs MotionAI\'s OWN AI connection (set in the app); without it, build the edit yourself with run_commands. '
          'Returns a job id (poll job_status, takes minutes) or, with wait:true, the result.',
      _obj({
        'brief': _s('Topic / instructions in the user\'s words'),
        'script': _s('Narration script (empty = the AI writes it from the brief)'),
        'narration': _e(['aroll', 'voiceover', 'phone_voice', 'silent'],
            'Voice: aroll = talking-head video, voiceover = audio file, phone_voice = text-to-speech of the script, silent = text only'),
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
        'wait': _b('Block until done (default false)'),
        'timeout': _n('Most seconds to wait with wait:true (default 540 with a progressToken, else 50; max 540)'),
      }, required: ['brief'])),
  _tool('job_status', 'Job status',
      'A background job (director, captions, export): running/done/failed/cancelled, message, result. Without "job": all recent jobs.',
      _obj({'job': _s('Job id')}),
      readOnly: true),
  _tool('cancel_job', 'Cancel job', 'Asks a running export or Director job to stop.', _obj({'job': _s('Job id')}, required: ['job'])),
  _tool('captions_generate', 'Auto captions',
      'Transcribes a video/audio layer on the PC (Whisper) and adds animated caption layers with per-word timing (one undo step). '
          'Returns a job id (poll job_status) or, with wait:true, the result. Styles: ${kCaptionStyleIds.join(', ')}.',
      _obj({
        'layer': _s('Video or audio layer id (default: the selected one, else the first video/audio layer)'),
        'style': _e(kCaptionStyleIds, 'Caption style (default karaoke)'),
        'language': _e(['hi', 'en', 'auto'], 'Spoken language (default hi)'),
        'roman': _b('Write Hindi in Roman script (Hinglish)'),
        'max_words': {'type': 'integer', 'minimum': 0, 'maximum': 12, 'description': 'Most words per caption (0 = style default)'},
        'emphasis': _b('Highlight numbers, money, years, names (default true)'),
        'ai_emphasis': _b('Ask MotionAI\'s AI for more key words (needs the app AI set up)'),
        'wait': _b('Block until done (default false)'),
        'timeout': _n('Most seconds to wait with wait:true (default 540 with a progressToken, else 50; max 540)'),
      })),
  _tool('list_templates', 'List scene templates',
      'Insertable scene templates (intros, showcases, transitions, captions, lower thirds, endings, maps, 3D, user templates): '
          'id, name, category, duration, slots (key, kind text/media/medias/color, default).',
      _obj({'category': _s('Only this category')}),
      readOnly: true),
  _tool('apply_template', 'Insert scene template',
      'Inserts a scene template at "start" (default playhead) as one undo step. "slots" fills slots by key: text, "#RRGGBB", '
          'media ids (project ids or "lib:<id>") or lists of media ids.',
      _obj({
        'id': _s('Template id from list_templates'),
        'slots': {'type': 'object', 'description': 'Slot key → value'},
        'start': _n('Seconds (default playhead)'),
      }, required: ['id'])),
  _tool('library_search', 'Search asset library',
      'Searches the user\'s shared asset library (photos, cut-outs, videos, music) by name, tags, description, kind, era, region, '
          'mood. Returns ids "lib:<id>".',
      _obj({
        'query': _s('Search words, fuzzy (empty = newest)'),
        'role': _e(['character', 'object', 'plate', 'overlay', 'set_piece'], 'Only this role'),
        'tags': {'type': 'array', 'items': {'type': 'string'}, 'description': 'All of these tags'},
        'kit': _s('Only this kit (name or id)'),
        'type': _e(['image', 'video', 'audio'], 'Only this media type'),
        'transparent': _b('Only cut-outs with transparency'),
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100, 'description': 'Default 30'},
      }),
      readOnly: true),
  // V2-lead >>> library tools backed by lib/library/library_ops.dart (V2-F)
  _tool('library_import_folder', 'Import a folder into the library',
      'Imports every image/video/audio in a folder on this PC (e.g. a Google Flow kit folder with cutouts/, plates/, fx/) into the '
          'shared library as one kit. Roles come from file prefixes (char_ character, prop_ object, plate_ background, fx_ overlay, '
          'cut_ set piece); the PNG cut-out wins over a same-named green-screen JPEG; duplicates are skipped. green_screen auto keys '
          'flat green/blue backgrounds; remove_mark inpaints the small AI sparkle mark. Slow for big folders.',
      _obj({
        'path': _s('Absolute folder path'),
        'recursive': _b('Include subfolders (default true)'),
        'kit': _s('Kit name (default: folder name)'),
        'tags': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Extra tags for every asset'},
        'green_screen': _e(['auto', 'true', 'false'], 'Key green/blue-screen images (default auto)'),
        'remove_mark': _b('Remove the AI sparkle watermark (default false)'),
      }, required: ['path'])),
  _tool('library_clean', 'Clean library images',
      'Green-screen keying and/or AI sparkle-mark removal on library images (originals are kept; restore:true undoes).',
      _obj({
        'ids': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Library ids ("lib:<id>")'},
        'kit': _s('Kit name or id'),
        'all': _b('Every image in the library'),
        'green_screen': _e(['auto', 'true', 'false'], 'Default auto'),
        'remove_mark': _b('Default true'),
        'restore': _b('Go back to the original images'),
      })),
  _tool('library_suggest', 'Suggest assets for a shot',
      'Ranks library assets for a shot brief, per role (character, object, plate, overlay, set_piece). Read-only.',
      _obj({
        'brief': _s('What the shot shows, e.g. "merchant shows a tulip bulb in the exchange hall"'),
        'roles': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Roles wanted (default all)'},
        'kit': _s('Only this kit'),
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 30, 'description': 'Per role, default 5'},
      }, required: ['brief']),
      readOnly: true),
  // <<< V2-lead
  _tool('library_insert', 'Insert library asset',
      'Imports a library asset into the open project (returns its media id) and by default adds it as a layer at "start".',
      _obj({
        'id': _s('Library id ("lib:<id>") from library_search'),
        'add_to_timeline': _b('Also add a layer (default true)'),
        'start': _n('Seconds (default playhead)'),
        'duration': _n('Layer duration (default: photo default, or the clip length)'),
      }, required: ['id'])),
  _tool('list_effects', 'List effects', 'Every effect for add_effect: id, label, category, params (key, default, min, max, options).',
      _obj({}),
      readOnly: true),
  // V3-E >>> story-grammar pattern planner (lib/director/pattern_engine.dart)
  _tool('suggest_patterns', 'Suggest documentary patterns',
      'Plans documentary visual patterns for narration lines (English / Hindi / Hinglish): per beat the pattern id (map, route, article '
          'highlight, clock stamp, unit chart, mood flood, presenter…), times, reveal_at (0.1-0.3 s after the keyword), slots, transition_in, '
          'grade, overlays (social_cta, presenter_stats…) and sfx, following the Nitish-Rajput grammar (ASL ~3.4 s, presenter every 12-25 s, '
          'evidence then reenactment). Read-only: pass the plan to run_commands [{"op":"apply_patterns","plan":…,"assets":{…}}] to build it.',
      _obj({
        'lines': {
          'type': 'array',
          'description': 'Narration lines [{"text":"...","start":0,"end":3.2}] (times optional)',
          'items': {'type': 'object'},
        },
        'style': _e(['nr_doc'], 'Style grammar (default nr_doc)'),
        'tone': _s('Story tone: auto (default), snow, desert, neutral — picks the signature transition'),
        'presenter': _b('A presenter (A-roll) is available (default true)'),
        'asl': _n('Average shot length in seconds (default 3.4)'),
      }, required: ['lines']),
      readOnly: true),
  // <<< V3-E
  _tool('list_components', 'List components',
      'Every component for add_component (source cards, lower thirds, maps, pins, counters, 3D scenes, …): type and label; '
          'fields are in get_command_spec.',
      _obj({}),
      readOnly: true),
];

Set<String> get kMcpToolNames => {for (final t in kMcpTools) t['name'] as String};

/// Tools that change the project (blocked while an export/Director job runs).
const Set<String> kMcpEditTools = {
  'run_commands', 'undo', 'redo', 'open_project', 'new_project', 'close_project', 'import_media', 'open_comp',
  'director_run', 'captions_generate', 'apply_template', 'library_insert', 'export_video',
  'library_import_folder', 'library_clean', // V2-lead
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

  factory McpToolResult.image(List<int> png, {String? caption, String mimeType = 'image/png'}) => McpToolResult([
        {'type': 'image', 'data': base64Encode(png), 'mimeType': mimeType},
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

/// Every control file the app writes and the bridge reads, newest wins.
/// On Windows also `%USERPROFILE%\.motionai\mcp.json`: a bridge started by
/// the Microsoft Store build of Claude Desktop runs inside Claude's MSIX
/// package, where `%APPDATA%` is virtualised (it may see a stale private
/// copy); the user profile root is not virtualised.
List<String> mcpControlFilePaths(Map<String, String> env, {required bool windows}) {
  final out = [mcpControlFilePath(env, windows: windows)];
  if (windows) {
    final home = env['USERPROFILE'];
    if (home != null && home.isNotEmpty) out.add('$home\\.motionai\\mcp.json');
  }
  return out;
}

/// The control info to use among several files: the most recently written
/// one (unparseable dates count as oldest). Null if [infos] is empty.
McpControlInfo? newestControl(Iterable<McpControlInfo?> infos) {
  McpControlInfo? best;
  DateTime? bestAt;
  for (final i in infos) {
    if (i == null) continue;
    final at = DateTime.tryParse(i.written);
    if (best == null || (at != null && (bestAt == null || at.isAfter(bestAt)))) {
      best = i;
      bestAt = at;
    }
  }
  return best;
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
  existing = existing?.replaceFirst('\uFEFF', '');
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

/// Every Claude Desktop config file to write on Windows, given the folder
/// names inside `%LOCALAPPDATA%\Packages`:
/// - each Microsoft Store (MSIX) install `Claude_<publisherId>`: its config is
///   virtualised at `%LOCALAPPDATA%\Packages\Claude_<id>\LocalCache\Roaming\Claude\claude_desktop_config.json`;
/// - the classic installer: `%APPDATA%\Claude\claude_desktop_config.json`.
/// Store packages first (sorted), then the classic path.
List<String> claudeDesktopConfigPaths(Map<String, String> env, Iterable<String> packageNames) {
  final out = <String>[];
  final local = env['LOCALAPPDATA'] ?? (env['USERPROFILE'] == null ? null : '${env['USERPROFILE']}\\AppData\\Local');
  if (local != null) {
    final re = RegExp(r'^Claude_[A-Za-z0-9]+$');
    final names = {for (final n in packageNames) if (re.hasMatch(n)) n}.toList()..sort();
    for (final n in names) {
      out.add('$local\\Packages\\$n\\LocalCache\\Roaming\\Claude\\claude_desktop_config.json');
    }
  }
  final appData = env['APPDATA'] ?? (env['USERPROFILE'] == null ? null : '${env['USERPROFILE']}\\AppData\\Roaming');
  if (appData != null) out.add('$appData\\Claude\\claude_desktop_config.json');
  return out;
}

/// What writing MotionAI into one Claude Desktop config does: the new text
/// (null = leave the file alone) and a status: added | updated | unchanged | invalid.
(String?, String) claudeDesktopConfigUpdate(String? existing, String bridgeExe) {
  final text = existing?.replaceFirst('﻿', '');
  final merged = mergeClaudeDesktopConfig(text, bridgeExe);
  if (merged == null) return (null, 'invalid');
  if (text == null || text.trim().isEmpty) return (merged, 'added');
  final old = jsonDecode(text) as Map;
  final servers = old['mcpServers'];
  final had = servers is Map ? servers[kMcpServerName] : null;
  if (had is Map && had['command'] == bridgeExe && (had['args'] is! List || (had['args'] as List).isEmpty)) return (null, 'unchanged');
  return (merged, had == null ? 'added' : 'updated');
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

// ---------------------------------------------------------------- progress

/// Sends MCP `notifications/progress` for one request that carried
/// `_meta.progressToken`. Progress only ever increases (the spec requires it):
/// reports that do not increase it are dropped.
class McpProgress {
  final Object token;
  final void Function(Map<String, dynamic> notification) _send;
  double _last = double.negativeInfinity;
  int sent = 0;

  McpProgress(this.token, this._send);

  /// The token of a tools/call's params, or null.
  static Object? tokenOf(Map<String, dynamic> params) {
    final meta = params['_meta'];
    final t = meta is Map ? meta['progressToken'] : null;
    return t is String || t is num ? t : null;
  }

  bool report(num progress, {num? total, String? message}) {
    if (!(progress > _last)) return false;
    _last = progress.toDouble();
    sent++;
    _send({
      'jsonrpc': '2.0',
      'method': 'notifications/progress',
      'params': {
        'progressToken': token,
        'progress': progress,
        if (total != null) 'total': total,
        if (message != null && message.isNotEmpty) 'message': message,
      },
    });
    return true;
  }
}

/// Incremental parser for a `text/event-stream` body: feed chunks, get the
/// `data` payload of every complete event.
class SseParser {
  String _pending = '';
  final List<String> _data = [];

  List<String> add(String chunk) {
    _pending += chunk;
    final out = <String>[];
    while (true) {
      final i = _pending.indexOf('\n');
      if (i < 0) break;
      var line = _pending.substring(0, i);
      _pending = _pending.substring(i + 1);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      if (line.isEmpty) {
        if (_data.isNotEmpty) {
          out.add(_data.join('\n'));
          _data.clear();
        }
        continue;
      }
      if (line.startsWith(':')) continue; // comment / keep-alive
      final c = line.indexOf(':');
      final field = c < 0 ? line : line.substring(0, c);
      var value = c < 0 ? '' : line.substring(c + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      if (field == 'data') _data.add(value);
    }
    return out;
  }

  /// End of stream: the last event even without its blank line.
  List<String> close() {
    final out = add('\n\n');
    _pending = '';
    return out;
  }

  /// One SSE event carrying [message] as JSON.
  static String event(Object? message) => 'event: message\ndata: ${jsonEncode(message)}\n\n';
}
