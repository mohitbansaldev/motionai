import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'ai_settings.dart';
import 'chatgpt_auth.dart';

class AiException implements Exception {
  final String message;
  AiException(this.message);
  @override
  String toString() => message;
}

class AiMessage {
  final String role; // user | assistant
  final String text;
  final List<Uint8List> images; // PNG or JPEG bytes
  AiMessage(this.role, this.text, {this.images = const []});
}

/// Minimal chat client for OpenAI and Anthropic, using the user's own key.
class AiClient {
  static const _timeout = Duration(seconds: 180);

  static Future<String> complete({
    required AiSettings s,
    required String system,
    required List<AiMessage> messages,
    bool jsonMode = true,
  }) async {
    if (!s.isConfigured) {
      throw AiException(s.provider == AiProvider.chatgpt
          ? 'Connect your ChatGPT account in AI settings first.'
          : 'Add your API key in AI settings first.');
    }
    return switch (s.provider) {
      AiProvider.chatgpt => _chatgpt(s, system, messages),
      AiProvider.openai => _openai(s, system, messages, jsonMode),
      AiProvider.anthropic => _anthropic(s, system, messages),
    };
  }

  /// Responses API with the ChatGPT-plan OAuth token (streamed, not stored).
  /// Tries the saved model first, then every model the account lists, and
  /// remembers the first one the plan accepts.
  static Future<String> _chatgpt(AiSettings s, String system, List<AiMessage> msgs) async {
    final tried = <String>[];
    final candidates = <String>[if (s.chatgptModel.isNotEmpty) s.chatgptModel];
    List<String>? listed;
    String? lastError;
    for (int i = 0; i < 12; i++) {
      if (i >= candidates.length) {
        if (listed != null) break;
        listed = await ChatGptAuth.models();
        // Prefer general GPT models, newest-looking names first.
        final ranked = [...listed]..sort((a, b) => _rank(b).compareTo(_rank(a)));
        candidates.addAll(ranked.where((m) => !candidates.contains(m)));
        if (i >= candidates.length) break;
      }
      final model = candidates[i];
      tried.add(model);
      try {
        final out = await _chatgptOnce(model, system, msgs);
        if (s.chatgptModel != model) {
          s.chatgptModel = model;
          await ChatGptAuth.setModel(model);
        }
        return out;
      } on _ModelRejected catch (e) {
        lastError = e.message;
        continue;
      }
    }
    throw AiException('None of your ChatGPT plan models accepted the request '
        '(tried: ${tried.join(', ')}). Last error: $lastError');
  }

  static int _rank(String m) {
    var r = 0;
    if (m.startsWith('gpt-')) r += 100;
    if (m.contains('codex')) r += 20;
    if (RegExp(r'(audio|realtime|tts|transcribe|image|embedding|search|moderation)').hasMatch(m)) r -= 500;
    final v = RegExp(r'gpt-(\d+(?:\.\d+)?)').firstMatch(m);
    if (v != null) r += (double.parse(v.group(1)!) * 10).round();
    if (m.contains('mini')) r -= 5;
    if (m.contains('nano')) r -= 8;
    return r;
  }

  static Future<String> _chatgptOnce(String model, String system, List<AiMessage> msgs) async {
    final token = await ChatGptAuth.accessToken();
    final body = {
      'model': model,
      'instructions': system,
      'store': false,
      'stream': true,
      'input': [
        for (final m in msgs)
          {
            'role': m.role,
            'content': [
              {'type': m.role == 'assistant' ? 'output_text' : 'input_text', 'text': m.text},
              if (m.role == 'user')
                for (final img in m.images)
                  {'type': 'input_image', 'image_url': 'data:${_mime(img)};base64,${base64Encode(img)}', 'detail': 'low'},
            ],
          },
      ],
    };
    final req = http.Request('POST', Uri.parse('https://api.openai.com/v1/responses'))
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'text/event-stream'
      ..body = jsonEncode(body);
    final streamed = await req.send().timeout(_timeout);
    if (streamed.statusCode != 200) {
      final res = await http.Response.fromStream(streamed);
      final text = utf8.decode(res.bodyBytes);
      if ((res.statusCode == 400 || res.statusCode == 403 || res.statusCode == 404) &&
          RegExp(r'model', caseSensitive: false).hasMatch(text)) {
        throw _ModelRejected('$model: ${_errorText(text)}');
      }
      _decode(res);
    }
    final out = StringBuffer();
    String? failure;
    await for (final line in streamed.stream.transform(utf8.decoder).transform(const LineSplitter()).timeout(_timeout)) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      Map<String, dynamic> ev;
      try {
        ev = jsonDecode(data) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      switch (ev['type']) {
        case 'response.output_text.delta':
          out.write(ev['delta'] ?? '');
        case 'response.failed':
        case 'error':
          final r = ev['response'];
          final err = (r is Map ? r['error'] : null) ?? ev['error'] ?? ev;
          failure = err is Map ? '${err['message'] ?? err}' : '$err';
      }
    }
    if (failure != null) {
      if (RegExp(r'model', caseSensitive: false).hasMatch(failure) && out.isEmpty) {
        throw _ModelRejected('$model: $failure');
      }
      throw AiException('ChatGPT request failed: $failure');
    }
    return out.toString();
  }

  static String _errorText(String body) {
    try {
      final j = jsonDecode(body);
      final e = j is Map ? j['error'] : null;
      if (e is Map) return '${e['message'] ?? e}';
      if (e != null) return '$e';
    } catch (_) {}
    return body.length > 200 ? body.substring(0, 200) : body;
  }

  static Map<String, dynamic> _decode(http.Response res) {
    final text = utf8.decode(res.bodyBytes);
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {}
    if (res.statusCode != 200) {
      final err = j?['error'];
      final msg = err is Map ? (err['message'] ?? err.toString()) : text;
      throw AiException('AI request failed (${res.statusCode}): $msg');
    }
    if (j == null) throw AiException('AI returned an unreadable response.');
    return j;
  }

  /// OpenAI speech-to-text with word timestamps (used for captions).
  static Future<Map<String, dynamic>> transcribe({
    required AiSettings s,
    required String audioPath,
    String? language,
    String? prompt,
  }) async {
    if (s.openaiKey.trim().isEmpty) {
      throw AiException('Captions use OpenAI speech-to-text. Add an OpenAI API key in AI settings.');
    }
    final req = http.MultipartRequest('POST', Uri.parse('https://api.openai.com/v1/audio/transcriptions'))
      ..headers['Authorization'] = 'Bearer ${s.openaiKey.trim()}'
      ..fields['model'] = 'whisper-1'
      ..fields['response_format'] = 'verbose_json'
      ..fields['timestamp_granularities[]'] = 'word'
      ..files.add(await http.MultipartFile.fromPath('file', audioPath));
    if (language != null) req.fields['language'] = language;
    if (prompt != null) req.fields['prompt'] = prompt;
    final streamed = await req.send().timeout(const Duration(minutes: 5));
    final res = await http.Response.fromStream(streamed);
    return _decode(res);
  }
}

class _ModelRejected implements Exception {
  final String message;
  _ModelRejected(this.message);
}
