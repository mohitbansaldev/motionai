// MCP (Agent P): motionai-mcp.exe — the stdio MCP server Claude Desktop
// starts. It forwards JSON-RPC to the running MotionAI app (localhost
// server; port + token from %APPDATA%\MotionAI\mcp.json) and starts
// MotionAI when a tool is used and the app is not running.
//
// stdout carries ONLY newline-delimited JSON-RPC; diagnostics go to stderr.
//
// Build: dart compile exe tool/motionai_mcp.dart -o motionai-mcp.exe
// Options: --app <path to motionai.exe>  --control <path to mcp.json>  --verbose

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:motionai/remote/mcp_protocol.dart';

List<String> _controlPaths = [];
String? _appOverride;
bool _verbose = false;
final HttpClient _http = HttpClient()
  ..connectionTimeout = const Duration(seconds: 3)
  ..idleTimeout = const Duration(seconds: 30);
Future<McpControlInfo>? _starting;

void _log(String s) {
  if (_verbose) stderr.writeln('[motionai-mcp] $s');
}

void _out(Object? message) => stdout.writeln(BridgeFraming.encode(message));

Future<void> main(List<String> args) async {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--app' && i + 1 < args.length) _appOverride = args[++i];
    if (args[i] == '--control' && i + 1 < args.length) _controlPaths = [args[++i]];
    if (args[i] == '--verbose') _verbose = true;
  }
  if (_controlPaths.isEmpty) _controlPaths = mcpControlFilePaths(Platform.environment, windows: Platform.isWindows);
  _log('control files $_controlPaths');

  final pending = <Future<void>>[];
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final (msg, err) = BridgeFraming.decode(line);
    if (err != null) {
      _out(err);
      continue;
    }
    if (msg == null) continue;
    final f = _handle(msg).catchError((Object e) => _log('error: $e'));
    pending.add(f);
    f.whenComplete(() => pending.remove(f));
  }
  // stdin closed (Claude quit): finish what is in flight, then exit.
  await Future.wait(List.of(pending)).timeout(const Duration(seconds: 5), onTimeout: () => []);
  _http.close(force: true);
  exit(0);
}

Future<void> _handle(Object msg) async {
  if (msg is List) {
    // JSON-RPC batch (older clients): answer each, as one array.
    final out = <Object?>[];
    for (final m in msg) {
      final r = await _answer(m);
      if (r != null) out.add(r);
    }
    if (out.isNotEmpty) _out(out);
    return;
  }
  final r = await _answer(msg);
  if (r != null) _out(r);
}

/// The response to one message (null for notifications / responses).
Future<Object?> _answer(Object? m) async {
  if (m is! Map) return JsonRpc.error(null, JsonRpc.invalidRequest, 'Invalid request');
  if (JsonRpc.isResponse(m)) return null;
  if (JsonRpc.isNotification(m)) {
    final info = await _reachable();
    if (info != null) unawaited(_post(info, m).then((_) {}, onError: (_) {}));
    return null;
  }
  final method = m['method'];
  // Answer the handshake here, so starting Claude does not start MotionAI.
  if (method == 'initialize' || method == 'ping') return BridgeFraming.localAnswer(m);
  if (BridgeFraming.offline.contains(method)) {
    final info = await _reachable();
    if (info == null) return BridgeFraming.localAnswer(m);
    try {
      return await _post(info, m);
    } catch (_) {
      return BridgeFraming.localAnswer(m);
    }
  }
  McpControlInfo info;
  try {
    info = await (_starting ??= _ensureApp().whenComplete(() => _starting = null));
  } catch (e) {
    return BridgeFraming.unavailable(m, '$e');
  }
  try {
    return await _post(info, m);
  } catch (e) {
    _log('forward failed: $e');
    // The app may have restarted with a new port/token: once more.
    final again = await _reachable();
    if (again != null) {
      try {
        return await _post(again, m);
      } catch (_) {}
    }
    return BridgeFraming.unavailable(m, 'Lost the connection to MotionAI ($e). Is it still open?');
  }
}

// ---------------------------------------------------------------- app connection

/// The newest of the control files (the app writes two: inside the
/// Microsoft Store build of Claude Desktop %APPDATA% may show a stale copy).
McpControlInfo? _readControl() {
  final all = <McpControlInfo?>[];
  for (final path in _controlPaths) {
    try {
      final f = File(path);
      if (f.existsSync()) all.add(McpControlInfo.parse(f.readAsStringSync()));
    } catch (_) {}
  }
  return newestControl(all);
}

Future<bool> _healthy(McpControlInfo info) async {
  try {
    final req = await _http.getUrl(Uri.parse('http://127.0.0.1:${info.port}/health'));
    final res = await req.close().timeout(const Duration(seconds: 3));
    final body = await res.transform(utf8.decoder).join();
    return res.statusCode == 200 && body.contains('motionai');
  } catch (_) {
    return false;
  }
}

/// The app's server if it is running and enabled (never starts the app).
Future<McpControlInfo?> _reachable() async {
  final info = _readControl();
  if (info == null || !info.enabled || info.token.isEmpty) return null;
  return await _healthy(info) ? info : null;
}

Future<bool> _alive(int pid) async {
  if (pid <= 0) return false;
  try {
    if (Platform.isWindows) {
      final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV']);
      return '${r.stdout}'.toLowerCase().contains('motionai');
    }
    final r = await Process.run('kill', ['-0', '$pid']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

String? _appExe(McpControlInfo? info) {
  final candidates = [
    if (_appOverride != null) _appOverride!,
    if (info != null && info.exe.isNotEmpty) info.exe,
    () {
      final dir = File(Platform.resolvedExecutable).parent.path;
      return '$dir${Platform.pathSeparator}motionai${Platform.isWindows ? '.exe' : ''}';
    }(),
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

const _turnOn = 'In MotionAI open the AI tab → settings (or the robot icon on the home screen) and turn on '
    '"Allow Claude to control MotionAI", then try again.';

/// Connects to MotionAI, starting it if it is not running.
Future<McpControlInfo> _ensureApp() async {
  final ok = await _reachable();
  if (ok != null) return ok;
  final info = _readControl();
  if (info != null && await _alive(info.pid)) {
    if (!info.enabled) throw StateError('MotionAI is open but Claude control is turned off. $_turnOn');
    // Running and enabled but not answering yet (starting up): wait a bit.
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final r = await _reachable();
      if (r != null) return r;
    }
    throw StateError('MotionAI is open but its control server does not answer on port ${info.port}. '
        'Check MotionAI → Claude control (maybe the port is busy).');
  }
  final exe = _appExe(info);
  if (exe == null) throw StateError('MotionAI is not running and motionai.exe was not found. Please open MotionAI.');
  _log('starting $exe');
  final started = DateTime.now();
  // Windows: start it through Explorer, so MotionAI does not run inside
  // Claude Desktop's Microsoft Store package (whose file virtualisation
  // would hide its projects and settings). Directly if that fails.
  var direct = !Platform.isWindows;
  if (!direct) {
    try {
      await Process.start('explorer.exe', [exe], mode: ProcessStartMode.detached);
    } catch (e) {
      _log('explorer start failed: $e');
      direct = true;
    }
  }
  if (direct) await Process.start(exe, const [], mode: ProcessStartMode.detached, workingDirectory: File(exe).parent.path);
  for (var i = 0; i < 120; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!direct && i == 24 && _readControl()?.written == info?.written) {
      _log('no sign of MotionAI after 12 s: starting it directly');
      direct = true;
      await Process.start(exe, const [], mode: ProcessStartMode.detached, workingDirectory: File(exe).parent.path);
    }
    final now = _readControl();
    if (now == null) continue;
    final fresh = DateTime.tryParse(now.written)?.isAfter(started.subtract(const Duration(seconds: 2))) ?? false;
    if (!fresh) continue;
    if (!now.enabled) throw StateError('MotionAI started, but Claude control is turned off. $_turnOn');
    if (await _healthy(now)) return now;
  }
  throw StateError('MotionAI did not start in time. Open it and try again.');
}

/// Forwards one message to POST /mcp; returns the parsed response (null for
/// 202). A `text/event-stream` answer (progress) is relayed as it arrives:
/// notifications go straight to stdout, the response is returned.
Future<Object?> _post(McpControlInfo info, Map m) async {
  final req = await _http.postUrl(Uri.parse(info.url));
  req.headers
    ..set(HttpHeaders.contentTypeHeader, 'application/json')
    ..set(HttpHeaders.acceptHeader, 'application/json, text/event-stream')
    ..set(HttpHeaders.authorizationHeader, 'Bearer ${info.token}')
    ..set('MCP-Protocol-Version', kMcpProtocolVersion);
  req.add(utf8.encode(jsonEncode(m)));
  final res = await req.close().timeout(const Duration(minutes: 10));
  if (res.statusCode == 200 && res.headers.contentType?.mimeType == 'text/event-stream') {
    final sse = SseParser();
    Object? answer;
    void take(String data) {
      try {
        final j = jsonDecode(data);
        if (JsonRpc.isNotification(j)) {
          _out(j);
        } else {
          answer = j;
        }
      } catch (_) {}
    }

    await for (final chunk in res.transform(utf8.decoder).timeout(const Duration(minutes: 10))) {
      sse.add(chunk).forEach(take);
    }
    sse.close().forEach(take);
    return answer;
  }
  final body = await res.transform(utf8.decoder).join();
  if (res.statusCode == 202 || body.trim().isEmpty) return null;
  if (res.statusCode == 401) throw StateError('MotionAI rejected the token (it was changed in Settings).');
  final j = jsonDecode(body);
  return j;
}
