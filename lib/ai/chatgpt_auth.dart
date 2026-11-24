import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'ai_client.dart';

/// "Continue with ChatGPT" — OpenAI's open-source Sign in with ChatGPT flow.
/// The user signs in in the browser and approves plan usage; requests then
/// count against their ChatGPT Plus/Pro plan instead of an API key.
///
/// Flow (developers.openai.com/siwc/token-sharing-open-source):
///  - dynamic client registration via client_id=dynamic_agent_client
///  - OIDC + PKCE, loopback redirect http://127.0.0.1:<port>/auth/callback
///  - scopes: openid profile email offline_access resource.invoke chatgpt.tokens.use.direct
///  - access token (1 h) is refreshed with the rotating refresh token
class ChatGptAuth {
  static const _store = FlutterSecureStorage();
  static const _authorize = 'https://auth.openai.com/api/accounts/authorize';
  static const _token = 'https://auth.openai.com/api/accounts/oauth/token';
  static const _resource = 'https://api.openai.com/v1';
  static const _scope = 'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct';
  static const _appName = 'MotionAI';
  static const _ports = [1455, 1456, 1457, 1458];

  static Future<String?> _get(String k) => _store.read(key: 'cg_$k');
  static Future<void> _set(String k, String? v) =>
      v == null ? _store.delete(key: 'cg_$k') : _store.write(key: 'cg_$k', value: v);

  static Future<bool> get isSignedIn async => (await _get('refresh')) != null;
  static Future<String?> get email => _get('email');
  static Future<String?> get model => _get('model');
  static Future<void> setModel(String m) => _set('model', m);

  static String _rand([int n = 32]) {
    final r = Random.secure();
    return base64Url.encode(List<int>.generate(n, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  static Future<String> _hostId() async {
    var id = await _get('host');
    if (id == null) {
      id = 'motionai-android-${_rand(12)}';
      await _set('host', id);
    }
    return id;
  }

  /// Opens the browser for sign-in and waits for the loopback callback.
  static Future<void> signIn() async {
    HttpServer? server;
    for (final p in _ports) {
      try {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, p);
        break;
      } catch (_) {}
    }
    if (server == null) throw AiException('Could not start the sign-in listener.');
    final redirect = 'http://127.0.0.1:${server.port}/auth/callback';
    final verifier = _rand(48);
    final challenge = base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    final state = _rand(), nonce = _rand();
    final savedClient = await _get('client');
    final params = {
      'client_id': savedClient ?? 'dynamic_agent_client',
      if (savedClient == null) 'agent_name_hint': _appName,
      'ext_agent_host_id': await _hostId(),
      if (await _get('email') != null) 'login_hint': (await _get('email'))!,
      'response_type': 'code',
      'redirect_uri': redirect,
      'scope': _scope,
      'resource': _resource,
      'state': state,
      'nonce': nonce,
      'code_challenge_method': 'S256',
      'code_challenge': challenge,
    };
    final url = Uri.parse(_authorize).replace(queryParameters: params);

    final callback = Completer<Map<String, String>>();
    final sub = server.listen((req) async {
      if (req.uri.path != '/auth/callback') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final q = req.uri.queryParameters;
      req.response.headers.contentType = ContentType.html;
      req.response.write('<html><body style="font-family:sans-serif;background:#0b0c10;color:#fff;'
          'display:flex;align-items:center;justify-content:center;height:100vh;text-align:center">'
          '<div><h2>${q['error'] == null ? 'Connected to MotionAI' : 'Sign-in cancelled'}</h2>'
          '<p>You can return to the app now.</p></div></body></html>');
      await req.response.close();
      if (!callback.isCompleted) callback.complete(q);
    });

    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw AiException('Could not open the browser.');
      }
      final q = await callback.future.timeout(const Duration(minutes: 5),
          onTimeout: () => throw AiException('Sign-in timed out.'));
      if (q['state'] != state) throw AiException('Sign-in failed a security check (state). Try again.');
      if (q['error'] != null) throw AiException('Sign-in was cancelled.');
      final clientId = q['client_id'] ?? savedClient;
      final code = q['code'];
      if (clientId == null || code == null) throw AiException('Sign-in did not return a code.');

      final res = await http.post(Uri.parse(_token), body: {
        'grant_type': 'authorization_code',
        'client_id': clientId,
        'code': code,
        'code_verifier': verifier,
        'redirect_uri': redirect,
        'resource': _resource,
      });
      final j = _json(res, 'Token exchange');
      final idClaims = _claims(j['id_token'] as String?);
      if (idClaims['nonce'] != null && idClaims['nonce'] != nonce) {
        throw AiException('Sign-in failed a security check (nonce). Try again.');
      }
      final scopes = '${j['scope'] ?? ''}';
      if (!scopes.contains('chatgpt.tokens.use.direct')) {
        throw AiException('ChatGPT plan usage was not approved. Sign in again and allow MotionAI to use your plan '
            '(needs ChatGPT Plus or Pro).');
      }
      await _set('client', clientId);
      await _saveTokens(j);
      if (idClaims['email'] != null) await _set('email', '${idClaims['email']}');
    } finally {
      await sub.cancel();
      await server.close(force: true);
    }
  }

  static Future<void> signOut() async {
    for (final k in ['access', 'refresh', 'expiry', 'email']) {
      await _set(k, null);
    }
  }

  static Future<void> _saveTokens(Map<String, dynamic> j) async {
    await _set('access', j['access_token'] as String?);
    if (j['refresh_token'] != null) await _set('refresh', j['refresh_token'] as String);
    final exp = DateTime.now().add(Duration(seconds: (j['expires_in'] as num? ?? 3600).toInt() - 60));
    await _set('expiry', exp.toIso8601String());
  }

  /// A valid access token, refreshing it when needed.
  static Future<String> accessToken() async {
    final access = await _get('access');
    final exp = DateTime.tryParse(await _get('expiry') ?? '');
    if (access != null && exp != null && DateTime.now().isBefore(exp)) return access;
    final refresh = await _get('refresh');
    final client = await _get('client');
    if (refresh == null || client == null) throw AiException('Connect your ChatGPT account in AI settings.');
    final res = await http.post(Uri.parse(_token), body: {
      'grant_type': 'refresh_token',
      'client_id': client,
      'refresh_token': refresh,
      'resource': _resource,
    });
    if (res.statusCode != 200) {
      await signOut();
      throw AiException('Your ChatGPT session expired. Connect again in AI settings.');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    await _saveTokens(j);
    return j['access_token'] as String;
  }

  /// Models available to the signed-in account.
  static Future<List<String>> models() async {
    final res = await http.get(Uri.parse('$_resource/models'),
        headers: {'Authorization': 'Bearer ${await accessToken()}'});
    final j = _json(res, 'Model list');
    return [for (final m in (j['data'] as List? ?? [])) '${(m as Map)['id']}'];
  }

  static Map<String, dynamic> _json(http.Response res, String what) {
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {}
    if (res.statusCode != 200 || j == null) {
      final err = j?['error'];
      throw AiException('$what failed (${res.statusCode}): ${err is Map ? err['message'] : err ?? res.body}');
    }
    return j;
  }

  static Map<String, dynamic> _claims(String? jwt) {
    if (jwt == null) return {};
    final parts = jwt.split('.');
    if (parts.length < 2) return {};
    try {
      return jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
}
