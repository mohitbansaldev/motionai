// MCP (Agent P): JSON-RPC dispatcher + localhost Streamable-HTTP server.
//
// PURE DART (dart:io only), so it is unit-tested without Flutter. The
// actual tools are behind [McpBackend] (lib/remote/remote_tools.dart).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'mcp_protocol.dart';

/// What the dispatcher needs from the app.
abstract class McpBackend {
  /// Runs tool [name]. Throw [McpUnknownTool] for unknown names; return
  /// [McpToolResult.error] for failures the model should read. [progress]
  /// is set when the client asked for progress and the transport can send it.
  Future<McpToolResult> callTool(String name, Map<String, dynamic> args, {McpProgress? progress});

  /// Contents of resource [uri]: (mimeType, text). Throw [McpUnknownResource].
  Future<(String, String)> readResource(String uri);
}

/// Handles MCP JSON-RPC messages (stateless: no session is required).
class McpDispatcher {
  final McpBackend backend;

  /// Called for every request with its method (for the "connected" badge / log).
  void Function(String method, Map<String, dynamic> params)? onRequest;

  /// Client name/version from the last initialize.
  String? clientName;

  McpDispatcher(this.backend, {this.onRequest});

  /// Answers one message (or a JSON-RPC batch list). Null = nothing to send
  /// (notifications and responses). [notify] sends server → client
  /// notifications (progress) before the answer, when the transport can.
  Future<Object?> handle(Object? message, {void Function(Map<String, dynamic> notification)? notify}) async {
    if (message is List) {
      if (message.isEmpty) return JsonRpc.error(null, JsonRpc.invalidRequest, 'Empty batch');
      final out = <Object?>[];
      for (final m in message) {
        final r = await _one(m, notify);
        if (r != null) out.add(r);
      }
      return out.isEmpty ? null : out;
    }
    return _one(message, notify);
  }

  Future<Map<String, dynamic>?> _one(Object? m, void Function(Map<String, dynamic>)? notify) async {
    if (m is! Map) return JsonRpc.error(null, JsonRpc.invalidRequest, 'Invalid request: expected a JSON-RPC object');
    if (JsonRpc.isResponse(m)) return null; // we never send requests; ignore
    if (m['jsonrpc'] != '2.0' || m['method'] is! String) {
      return JsonRpc.error(m['id'], JsonRpc.invalidRequest, 'Invalid request: needs "jsonrpc": "2.0" and a "method"');
    }
    final method = m['method'] as String;
    final rawParams = m['params'];
    if (rawParams != null && rawParams is! Map) {
      return JsonRpc.isNotification(m) ? null : JsonRpc.error(m['id'], JsonRpc.invalidParams, '"params" must be an object');
    }
    final params = rawParams == null ? <String, dynamic>{} : Map<String, dynamic>.from(rawParams as Map);
    if (JsonRpc.isNotification(m)) return null; // notifications/initialized, cancelled, …
    final id = m['id'];
    if (id is! String && id is! num) return JsonRpc.error(null, JsonRpc.invalidRequest, 'Invalid request: "id" must be a string or number');
    onRequest?.call(method, params);
    try {
      switch (method) {
        case 'initialize':
          final info = params['clientInfo'];
          if (info is Map) clientName = '${info['name'] ?? 'client'} ${info['version'] ?? ''}'.trim();
          return JsonRpc.result(id, initializeResult(params['protocolVersion']));
        case 'ping':
          return JsonRpc.result(id, {});
        case 'tools/list':
          return JsonRpc.result(id, {'tools': kMcpTools});
        case 'tools/call':
          final name = params['name'];
          if (name is! String) return JsonRpc.error(id, JsonRpc.invalidParams, 'tools/call needs "name"');
          final args = params['arguments'];
          if (args != null && args is! Map) return JsonRpc.error(id, JsonRpc.invalidParams, '"arguments" must be an object');
          if (!kMcpToolNames.contains(name)) return JsonRpc.error(id, JsonRpc.invalidParams, 'Unknown tool: $name');
          final token = McpProgress.tokenOf(params);
          final progress = token != null && notify != null ? McpProgress(token, notify) : null;
          McpToolResult r;
          try {
            r = await backend.callTool(name, args == null ? <String, dynamic>{} : Map<String, dynamic>.from(args as Map),
                progress: progress);
          } on McpUnknownTool catch (e) {
            return JsonRpc.error(id, JsonRpc.invalidParams, '$e');
          } catch (e) {
            r = McpToolResult.error('$name failed: $e');
          }
          return JsonRpc.result(id, r.toJson());
        case 'resources/list':
          return JsonRpc.result(id, {'resources': kMcpResources});
        case 'resources/templates/list':
          return JsonRpc.result(id, {'resourceTemplates': []});
        case 'resources/read':
          final uri = params['uri'];
          if (uri is! String) return JsonRpc.error(id, JsonRpc.invalidParams, 'resources/read needs "uri"');
          try {
            final (mime, text) = await backend.readResource(uri);
            return JsonRpc.result(id, {
              'contents': [
                {'uri': uri, 'mimeType': mime, 'text': text},
              ],
            });
          } on McpUnknownResource catch (e) {
            return JsonRpc.error(id, -32002, '$e', {'uri': uri});
          }
        case 'prompts/list':
          return JsonRpc.result(id, {'prompts': []});
        case 'logging/setLevel':
          return JsonRpc.result(id, {});
        default:
          return JsonRpc.error(id, JsonRpc.methodNotFound, 'Method not found: $method');
      }
    } catch (e) {
      return JsonRpc.error(id, JsonRpc.internalError, 'Internal error: $e');
    }
  }
}

/// Constant-time string compare (token check).
bool constantTimeEquals(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < math.max(x.length, y.length); i++) {
    diff |= (i < x.length ? x[i] : 0) ^ (i < y.length ? y[i] : 0);
  }
  return diff == 0;
}

/// A new random token (32 bytes, base64url, no padding).
String newMcpToken() {
  final r = math.Random.secure();
  return base64Url.encode([for (var i = 0; i < 32; i++) r.nextInt(256)]).replaceAll('=', '');
}

/// True for Host headers that name this machine's loopback (DNS-rebinding guard).
bool isLoopbackHost(String? host) {
  if (host == null || host.isEmpty) return false;
  var h = host.toLowerCase();
  if (h.startsWith('[')) {
    final end = h.indexOf(']');
    h = end < 0 ? h : h.substring(1, end);
  } else if (h.contains(':')) {
    h = h.substring(0, h.lastIndexOf(':'));
  }
  return h == '127.0.0.1' || h == 'localhost' || h == '::1';
}

/// Origin allowed: none (non-browser clients) or a loopback page.
bool isAllowedOrigin(String? origin) {
  if (origin == null || origin.isEmpty) return true;
  final u = Uri.tryParse(origin);
  if (u == null) return false;
  return (u.scheme == 'http' || u.scheme == 'https') && isLoopbackHost(u.host.contains(':') ? '[${u.host}]' : u.host);
}

/// MCP Streamable HTTP on 127.0.0.1 (POST /mcp, JSON responses) plus a small
/// REST mirror for debugging (GET /api/tools, POST /api/tools/<name>,
/// GET /api/state). Every route except GET /health needs the bearer token.
class McpHttpServer {
  final McpDispatcher dispatcher;
  final String Function() token;
  final int maxBody;
  HttpServer? _server;

  /// win-30: POST /api/upload saves one image sent from a Google Flow page
  /// (no browser download / save prompt). Set by the app; returns the saved
  /// file path. The only route a non-loopback page may call, and only from
  /// [uploadOrigins], with the bearer token.
  Future<String> Function(String folder, String name, List<int> bytes)? onUpload;

  static const uploadOrigins = {'https://labs.google', 'https://flow.google.com'};

  McpHttpServer(this.dispatcher, {required this.token, this.maxBody = 64 << 20});

  int? get port => _server?.port;
  bool get running => _server != null;

  /// Binds loopback only. [port] 0 = any free port (tests).
  Future<int> start(int port) async {
    await stop();
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, port, shared: false);
    s.autoCompress = false;
    s.idleTimeout = const Duration(seconds: 120);
    _server = s;
    s.listen((req) => _handle(req).catchError((Object _) {}), onError: (Object _) {});
    return s.port;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  Future<void> _send(HttpRequest req, int status, {Object? json, String? text, Map<String, String> headers = const {}}) async {
    final res = req.response;
    res.statusCode = status;
    res.headers.set('Cache-Control', 'no-store');
    headers.forEach(res.headers.set);
    if (json != null) {
      res.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
      res.write(jsonEncode(json));
    } else if (text != null) {
      res.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
      res.write(text);
    }
    await res.close();
  }

  Future<String?> _body(HttpRequest req) async {
    final len = req.contentLength;
    if (len > maxBody) return null;
    final chunks = <int>[];
    await for (final c in req) {
      chunks.addAll(c);
      if (chunks.length > maxBody) return null;
    }
    return utf8.decode(chunks, allowMalformed: true);
  }

  bool _authorized(HttpRequest req) {
    final h = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    const prefix = 'bearer ';
    if (h.length <= prefix.length || h.substring(0, prefix.length).toLowerCase() != prefix) return false;
    final t = token();
    return t.isNotEmpty && constantTimeEquals(h.substring(prefix.length).trim(), t);
  }

  Future<void> _handle(HttpRequest req) async {
    // win-30: Flow page → /api/upload (CORS + Private Network Access).
    if (req.uri.path == '/api/upload' && isLoopbackHost(req.headers.value(HttpHeaders.hostHeader))) {
      await _upload(req);
      return;
    }
    // DNS rebinding / browser guard: loopback Host, no foreign Origin.
    if (!isLoopbackHost(req.headers.value(HttpHeaders.hostHeader)) || !isAllowedOrigin(req.headers.value('origin'))) {
      await _send(req, HttpStatus.forbidden, json: JsonRpc.error(null, JsonRpc.invalidRequest, 'Forbidden origin'));
      return;
    }
    final path = req.uri.path;
    if (path == '/health' && req.method == 'GET') {
      await _send(req, 200, json: {'ok': true, 'app': 'motionai', 'mcp': kMcpProtocolVersion});
      return;
    }
    if (!_authorized(req)) {
      await _send(req, HttpStatus.unauthorized,
          json: JsonRpc.error(null, JsonRpc.invalidRequest, 'Unauthorized: send "Authorization: Bearer <token>" (MotionAI → Settings → Claude control)'),
          headers: {'WWW-Authenticate': 'Bearer realm="motionai"'});
      return;
    }

    if (path == '/mcp') {
      switch (req.method) {
        case 'POST':
          final body = await _body(req);
          if (body == null) {
            await _send(req, HttpStatus.requestEntityTooLarge, json: JsonRpc.error(null, JsonRpc.invalidRequest, 'Request too large'));
            return;
          }
          Object? msg;
          try {
            msg = jsonDecode(body);
          } catch (_) {
            await _send(req, HttpStatus.badRequest, json: JsonRpc.error(null, JsonRpc.parseError, 'Parse error: not valid JSON'));
            return;
          }
          if (_wantsStream(req, msg)) {
            await _stream(req, msg);
            return;
          }
          final out = await dispatcher.handle(msg);
          if (out == null) {
            await _send(req, HttpStatus.accepted);
            return;
          }
          final isInit = msg is Map && msg['method'] == 'initialize';
          await _send(req, 200, json: out, headers: {if (isInit) 'Mcp-Session-Id': newMcpToken().substring(0, 22)});
          return;
        case 'GET':
          // No server-initiated stream: every answer comes back on its POST.
          await _send(req, HttpStatus.methodNotAllowed, headers: {'Allow': 'POST, DELETE'});
          return;
        case 'DELETE':
          await _send(req, HttpStatus.noContent);
          return;
      }
      await _send(req, HttpStatus.methodNotAllowed, headers: {'Allow': 'POST, DELETE'});
      return;
    }

    // ---- REST mirror (debugging: curl -H "Authorization: Bearer …")
    if (path == '/api/tools' && req.method == 'GET') {
      await _send(req, 200, json: {'tools': kMcpTools});
      return;
    }
    if (path == '/api/state' && req.method == 'GET') {
      await _restCall(req, 'get_state', {});
      return;
    }
    if (path == '/api/spec' && req.method == 'GET') {
      await _restCall(req, 'get_command_spec', {});
      return;
    }
    if (path.startsWith('/api/tools/') && req.method == 'POST') {
      final name = path.substring('/api/tools/'.length);
      final body = await _body(req);
      Map<String, dynamic> args = {};
      if (body != null && body.trim().isNotEmpty) {
        try {
          final j = jsonDecode(body);
          if (j is Map) args = Map<String, dynamic>.from(j);
        } catch (_) {
          await _send(req, 400, json: {'error': 'Body must be a JSON object of tool arguments'});
          return;
        }
      }
      await _restCall(req, name, args);
      return;
    }
    await _send(req, HttpStatus.notFound, json: {'error': 'Not found. MCP endpoint: POST /mcp'});
  }

  // win-30 >>> image upload from a Google Flow page
  Future<void> _upload(HttpRequest req) async {
    final origin = req.headers.value('origin');
    final okOrigin = origin == null || origin.isEmpty || uploadOrigins.contains(origin) || isAllowedOrigin(origin);
    if (!okOrigin) {
      await _send(req, HttpStatus.forbidden, json: {'error': 'Forbidden origin'});
      return;
    }
    final cors = <String, String>{
      if (origin != null && origin.isNotEmpty) 'Access-Control-Allow-Origin': origin,
      'Vary': 'Origin',
    };
    if (req.method == 'OPTIONS') {
      await _send(req, HttpStatus.noContent, headers: {
        ...cors,
        'Access-Control-Allow-Methods': 'POST',
        'Access-Control-Allow-Headers': 'authorization, content-type',
        'Access-Control-Allow-Private-Network': 'true',
        'Access-Control-Max-Age': '600',
      });
      return;
    }
    if (req.method != 'POST') {
      await _send(req, HttpStatus.methodNotAllowed, headers: {...cors, 'Allow': 'POST, OPTIONS'});
      return;
    }
    if (!_authorized(req)) {
      await _send(req, HttpStatus.unauthorized, json: {'error': 'Unauthorized'}, headers: cors);
      return;
    }
    final hook = onUpload;
    if (hook == null) {
      await _send(req, HttpStatus.serviceUnavailable, json: {'error': 'Upload not available'}, headers: cors);
      return;
    }
    String clean(String? v, String fallback) {
      final n = (v ?? '').split(RegExp(r'[\\/]')).last.trim().replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
      return n.isEmpty || n.startsWith('.') ? fallback : n;
    }
    final folder = clean(req.uri.queryParameters['folder'], 'inbox');
    final name = clean(req.uri.queryParameters['name'], 'image_${DateTime.now().millisecondsSinceEpoch}.png');
    const exts = ['.png', '.jpg', '.jpeg', '.webp'];
    if (!exts.any(name.toLowerCase().endsWith)) {
      await _send(req, HttpStatus.badRequest, json: {'error': 'name must end in ${exts.join(', ')}'}, headers: cors);
      return;
    }
    final len = req.contentLength;
    if (len > maxBody) {
      await _send(req, HttpStatus.requestEntityTooLarge, json: {'error': 'Too large'}, headers: cors);
      return;
    }
    final bytes = <int>[];
    await for (final c in req) {
      bytes.addAll(c);
      if (bytes.length > maxBody) {
        await _send(req, HttpStatus.requestEntityTooLarge, json: {'error': 'Too large'}, headers: cors);
        return;
      }
    }
    if (bytes.length < 64) {
      await _send(req, HttpStatus.badRequest, json: {'error': 'Empty image'}, headers: cors);
      return;
    }
    try {
      final path = await hook(folder, name, bytes);
      await _send(req, 200, json: {'ok': true, 'path': path, 'bytes': bytes.length}, headers: cors);
    } catch (e) {
      await _send(req, HttpStatus.internalServerError, json: {'error': '$e'}, headers: cors);
    }
  }
  // <<< win-30

  /// A tools/call with a progressToken from a client that accepts SSE gets a
  /// `text/event-stream` answer: progress notifications, then the response.
  static bool _wantsStream(HttpRequest req, Object? msg) {
    final accept = req.headers.value(HttpHeaders.acceptHeader) ?? '';
    if (!accept.contains('text/event-stream')) return false;
    if (msg is! Map || msg['method'] != 'tools/call' || !msg.containsKey('id')) return false;
    final params = msg['params'];
    return params is Map && McpProgress.tokenOf(Map<String, dynamic>.from(params)) != null;
  }

  Future<void> _stream(HttpRequest req, Object? msg) async {
    final res = req.response;
    res.statusCode = 200;
    res.headers.set('Cache-Control', 'no-store');
    res.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
    var chain = Future<void>.value();
    void send(Object? m) {
      chain = chain.then((_) async {
        res.write(SseParser.event(m));
        await res.flush();
      }).catchError((Object _) {}); // client went away: keep running the tool
    }

    final out = await dispatcher.handle(msg, notify: send);
    if (out != null) send(out);
    await chain;
    try {
      await res.close();
    } catch (_) {}
  }

  Future<void> _restCall(HttpRequest req, String name, Map<String, dynamic> args) async {
    final out = await dispatcher.handle({
      'jsonrpc': '2.0',
      'id': 'rest',
      'method': 'tools/call',
      'params': {'name': name, 'arguments': args},
    });
    final m = out is Map ? out : const {};
    if (m['error'] != null) {
      await _send(req, 400, json: m['error']);
      return;
    }
    await _send(req, 200, json: m['result']);
  }
}
