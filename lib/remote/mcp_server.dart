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
  /// [McpToolResult.error] for failures the model should read.
  Future<McpToolResult> callTool(String name, Map<String, dynamic> args);

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
  /// (notifications and responses).
  Future<Object?> handle(Object? message) async {
    if (message is List) {
      if (message.isEmpty) return JsonRpc.error(null, JsonRpc.invalidRequest, 'Empty batch');
      final out = <Object?>[];
      for (final m in message) {
        final r = await _one(m);
        if (r != null) out.add(r);
      }
      return out.isEmpty ? null : out;
    }
    return _one(message);
  }

  Future<Map<String, dynamic>?> _one(Object? m) async {
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
          McpToolResult r;
          try {
            r = await backend.callTool(name, args == null ? <String, dynamic>{} : Map<String, dynamic>.from(args as Map));
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
