// MCP (Agent P): "Allow Claude to control MotionAI" — settings, the
// localhost server's life cycle, the control file for the stdio bridge,
// the action log, and the RemoteHost the tools drive (navigation,
// rendering, export) in the running app.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/model/project.dart';
import '../platform/win_window.dart';
import '../services/media_bridge.dart';
import '../services/media_importer.dart';
import '../services/project_storage.dart';
import '../services/updater.dart';
import '../state/editor_controller.dart';
import '../ui/editor_screen.dart';
import '../ui/export_screen.dart';
import '../ui/library/library_common.dart';
import 'contact_sheet.dart';
import 'mcp_protocol.dart';
import 'mcp_server.dart';
import 'remote_export.dart';
import 'remote_render.dart';
import 'remote_tools.dart';

class RemoteLogEntry {
  final DateTime time = DateTime.now();
  final String tool, summary;
  final bool ok;
  RemoteLogEntry(this.tool, this.summary, this.ok);
}

class RemoteControl extends ChangeNotifier implements RemoteHost, RemoteFrameHost {
  RemoteControl._();
  static final RemoteControl instance = RemoteControl._();

  /// The app's navigator (MaterialApp.navigatorKey).
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  static const _store = FlutterSecureStorage();
  final ProjectStorage _storage = ProjectStorage();
  late final RemoteTools tools = RemoteTools(this)..onAction = _onAction;
  late final McpDispatcher _dispatcher = McpDispatcher(tools, onRequest: _onRequest);
  late final McpHttpServer _server = McpHttpServer(_dispatcher, token: () => token);
  late final RemoteRenderer _renderer = RemoteRenderer(navigatorKey);

  bool loaded = false;
  bool enabled = false;
  int port = kMcpDefaultPort;
  String token = '';

  /// Why the server is not running although enabled (e.g. port busy).
  String? error;
  DateTime? lastSeen;
  final List<RemoteLogEntry> log = [];

  /// Bumped when Claude creates/renames projects (the home list reloads).
  final ValueNotifier<int> projectsRevision = ValueNotifier(0);

  EditorController? _editor;
  Completer<EditorController>? _waiting;
  Timer? _tick;

  static bool get supported => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool get running => _server.running;
  String? get client => _dispatcher.clientName;
  bool get connected => running && lastSeen != null && DateTime.now().difference(lastSeen!) < const Duration(seconds: 90);
  String get url => 'http://127.0.0.1:$port/mcp';

  /// motionai-mcp.exe next to motionai.exe (bundled by CI).
  String get bridgeExe => bridgeExePath(Platform.resolvedExecutable);
  bool get bridgeExists => File(bridgeExe).existsSync();

  // ------------------------------------------------------------ settings

  Future<void> init() async {
    if (!supported || loaded) return;
    try {
      final all = await _store.readAll();
      enabled = all['mcp_enabled'] == 'true';
      port = int.tryParse(all['mcp_port'] ?? '') ?? kMcpDefaultPort;
      token = all['mcp_token'] ?? '';
    } catch (_) {}
    loaded = true;
    if (token.isEmpty) await regenerateToken(restart: false);
    if (enabled) {
      await _start();
    } else {
      await _writeControlFile();
    }
    _tick ??= Timer.periodic(const Duration(seconds: 20), (_) => notifyListeners()); // badge expiry
    notifyListeners();
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    await _store.write(key: 'mcp_enabled', value: '$v');
    if (v) {
      await _start();
    } else {
      await _server.stop();
      error = null;
      lastSeen = null;
      await _writeControlFile();
    }
    notifyListeners();
  }

  Future<void> setPort(int p) async {
    if (p < 1024 || p > 65535 || p == port) return;
    port = p;
    await _store.write(key: 'mcp_port', value: '$p');
    if (enabled) await _start();
    notifyListeners();
  }

  /// A new token: every connected client must use the new one.
  Future<void> regenerateToken({bool restart = true}) async {
    token = newMcpToken();
    try {
      await _store.write(key: 'mcp_token', value: token);
    } catch (_) {}
    if (restart && enabled) await _writeControlFile();
    notifyListeners();
  }

  Future<void> _start() async {
    try {
      await _server.start(port);
      error = null;
    } on SocketException catch (e) {
      error = 'Port $port is in use (${e.osError?.message ?? e.message}). Pick another port.';
    } catch (e) {
      error = '$e';
    }
    await _writeControlFile();
    notifyListeners();
  }

  /// %APPDATA%\MotionAI\mcp.json (+ %USERPROFILE%\.motionai\mcp.json for
  /// bridges inside the Store build of Claude): tells the bridge the port and token.
  Future<void> _writeControlFile() async {
    final info = McpControlInfo(
      enabled: enabled && running,
      port: port,
      token: token,
      pid: pid,
      exe: Platform.resolvedExecutable,
      written: DateTime.now().toIso8601String(),
    );
    final text = const JsonEncoder.withIndent('  ').convert({...info.toJson(), 'build': Updater.current});
    for (final path in mcpControlFilePaths(Platform.environment, windows: Platform.isWindows)) {
      try {
        final f = File(path);
        await f.parent.create(recursive: true);
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(text, flush: true);
        await tmp.rename(f.path);
      } catch (_) {
        // Not fatal: HTTP clients can still connect with the URL + token.
      }
    }
  }

  // ------------------------------------------------------------ Claude configs

  String get desktopSnippet => claudeDesktopConfigSnippet(bridgeExe);
  String get httpSnippet => httpConfigSnippet(port, token);
  String get claudeCodeCommand => claudeCodeStdioCommand(bridgeExe);
  String get claudeCodeHttp => claudeCodeHttpCommand(port, token);

  /// Every Claude Desktop config file on this PC (V2-A): each Microsoft
  /// Store (MSIX) package `%LOCALAPPDATA%\Packages\Claude_*` (its virtualised
  /// `LocalCache\Roaming\Claude`) and the classic `%APPDATA%\Claude`.
  static List<String> claudeDesktopConfigPathsHere() {
    final env = Platform.environment;
    final names = <String>[];
    final local = env['LOCALAPPDATA'];
    if (local != null) {
      try {
        for (final d in Directory('$local\\Packages').listSync(followLinks: false)) {
          if (d is Directory) names.add(d.path.split(RegExp(r'[\\/]')).last);
        }
      } catch (_) {}
    }
    return claudeDesktopConfigPaths(env, names);
  }

  /// Adds MotionAI to every Claude Desktop config (merging: other servers and
  /// settings stay; the old file is backed up once as .bak). Returns each
  /// path with its status: added | updated | unchanged | error: ….
  Future<List<(String, String)>> addToClaudeDesktop() async {
    final out = <(String, String)>[];
    for (final path in claudeDesktopConfigPathsHere()) {
      final f = File(path);
      try {
        final old = await f.exists() ? await f.readAsString() : null;
        final (text, status) = claudeDesktopConfigUpdate(old, bridgeExe);
        if (status == 'invalid') {
          out.add((path, 'error: not valid JSON, left alone (fix it or paste the config by hand)'));
          continue;
        }
        if (text != null) {
          await f.parent.create(recursive: true);
          final bak = File('$path.bak');
          if (old != null && !await bak.exists()) await bak.writeAsString(old, flush: true);
          await f.writeAsString(text, flush: true);
        }
        out.add((path, status));
      } catch (e) {
        out.add((path, 'error: $e'));
      }
    }
    if (out.isEmpty) throw const FileSystemException('Could not find where Claude Desktop keeps its settings (no APPDATA).');
    if (out.every((r) => r.$2.startsWith('error'))) {
      throw FileSystemException('Could not write the Claude Desktop config:\n${out.map((r) => '${r.$1}: ${r.$2}').join('\n')}');
    }
    return out;
  }

  // ------------------------------------------------------------ activity

  void _onRequest(String method, Map<String, dynamic> params) {
    final was = connected;
    lastSeen = DateTime.now();
    if (!was || method == 'initialize') notifyListeners();
  }

  void _onAction(String tool, String summary, bool ok) {
    log.insert(0, RemoteLogEntry(tool, summary, ok));
    if (log.length > 200) log.removeLast();
    notifyListeners();
  }

  // ------------------------------------------------------------ editor hookup

  /// EditorScreen registers its controller while it is open.
  void attach(EditorController c) {
    _editor = c;
    final w = _waiting;
    _waiting = null;
    if (w != null && !w.isCompleted) w.complete(c);
    scheduleMicrotask(notifyListeners); // called from initState: not during build
  }

  void detach(EditorController c) {
    if (_editor == c) _editor = null;
    scheduleMicrotask(() {
      projectsRevision.value++;
      notifyListeners();
    }); // called from dispose: the tree is locked
  }

  // ------------------------------------------------------------ RemoteHost

  @override
  EditorController? get editor => _editor;

  @override
  ProjectStorage get storage => _storage;

  @override
  String get screen {
    if (_editor == null) return 'home';
    final export = tools.jobs.latest('export');
    if (export != null && export.running) return 'export';
    final director = tools.jobs.latest('director');
    if (director != null && director.running) return 'editor (Director running)';
    return 'editor';
  }

  NavigatorState get _nav => navigatorKey.currentState ?? (throw StateError('MotionAI is still starting.'));

  @override
  Future<EditorController> showProject(Project p) async {
    final nav = _nav;
    nav.popUntil((r) => r.isFirst);
    await WidgetsBinding.instance.endOfFrame;
    final wait = _waiting = Completer<EditorController>();
    nav.push(MaterialPageRoute(builder: (_) => EditorScreen(project: p, storage: _storage)));
    WinWindow.setTitle(p.name);
    return wait.future.timeout(const Duration(seconds: 20), onTimeout: () => throw TimeoutException('The editor did not open.'));
  }

  @override
  Future<void> closeProject() async {
    _nav.popUntil((r) => r.isFirst);
    await WidgetsBinding.instance.endOfFrame;
  }

  @override
  Future<Uint8List> renderPng(EditorController c, double time, int width) async {
    try {
      return await _renderer.render(c.project, c.comp, time, width);
    } finally {
      final export = tools.jobs.latest('export');
      if (export == null || !export.running) unawaited(MediaBridge.readerReleaseAll().catchError((_) {}));
    }
  }

  @override
  Future<List<RawFrame>> renderFrames(EditorController c, List<double> times, int width, {Composition? comp}) async {
    try {
      return await _renderer.renderMany(c.project, comp ?? c.comp, times, width);
    } finally {
      final export = tools.jobs.latest('export');
      if (export == null || !export.running) unawaited(MediaBridge.readerReleaseAll().catchError((_) {}));
    }
  }

  @override
  Future<void> showExport(EditorController c, RemoteExport r) async {
    _nav.push(MaterialPageRoute(builder: (_) => ExportScreen(project: c.project, remote: r)));
    await WidgetsBinding.instance.endOfFrame;
  }

  @override
  Future<List<MediaAsset>> importPaths(EditorController c, List<String> paths, List<String> errors) async {
    final imp = MediaImporter(c.storage);
    final out = await imp.importPaths(paths);
    errors.addAll(imp.errors);
    return out;
  }

  @override
  Future<Map<String, dynamic>> resolveLibrary(EditorController c, Map<String, dynamic> values) => LibUi.resolveLibrary(c, values);

  @override
  void projectsChanged() {
    projectsRevision.value++;
    final c = _editor;
    if (c != null) WinWindow.setTitle(c.project.name);
    notifyListeners();
  }
}
