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

class _ModelUnsupported implements Exception {
  final String message;
  _ModelUnsupported(this.message);
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
  /// If a model isn't available on the user's plan, the next one from the
  /// account's model list is tried and the working one is remembered.
  static Future<String> _chatgpt(AiSettings s, String system, List<AiMessage> msgs) async {
    final candidates = <String>[];
    if (s.chatgptModel.isNotEmpty) candidates.add(s.chatgptModel);
    List<String> listed = const [];
    try {
      listed = await ChatGptAuth.models();
    } catch (_) {}
    for (final m in listed) {
      if (!candidates.contains(m) && !_nonChat.hasMatch(m)) candidates.add(m);
    }
    if (candidates.isEmpty) throw AiException('Your ChatGPT account returned no available models.');
    AiException? last;
    for (final model in candidates.take(6)) {
      try {
        final text = await _chatgptOnce(model, system, msgs);
        if (s.chatgptModel != model) {
          s.chatgptModel = model;
          await ChatGptAuth.setModel(model);
        }
        return text;
      } on _ModelUnsupported catch (e) {
        last = AiException('Model $model: ${e.message}');
      }
    }
    throw last ?? AiException('No model on your ChatGPT plan accepted the request.');
  }

  static final _nonChat = RegExp(r'(embedding|tts|whisper|transcribe|dall-e|image|audio|realtime|moderation|search)', caseSensitive: false);

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
          RegExp(r'model|not supported|unsupported', caseSensitive: false).hasMatch(text)) {
        String msg = text;
        try {
          final e = (jsonDecode(text) as Map)['error'];
          msg = e is Map ? '${e['message']}' : '$e';
        } catch (_) {}
        throw _ModelUnsupported(msg);
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
      if (RegExp(r'model.*(not supported|unsupported|not available)', caseSensitive: false).hasMatch(failure)) {
        throw _ModelUnsupported(failure);
      }
      throw AiException('ChatGPT request failed: $failure');
    }
    return out.toString();
  }

  static String _mime(Uint8List b) =>
      (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8) ? 'image/jpeg' : 'image/png';

  static Future<String> _openai(AiSettings s, String system, List<AiMessage> msgs, bool jsonMode) async {
    final body = {
      'model': s.openaiModel,
      if (jsonMode) 'response_format': {'type': 'json_object'},
      'messages': [
        {'role': 'system', 'content': system},
        for (final m in msgs)
          {
            'role': m.role,
            'content': m.images.isEmpty
                ? m.text
                : [
                    {'type': 'text', 'text': m.text},
                    for (final img in m.images)
                      {
                        'type': 'image_url',
                        'image_url': {'url': 'data:${_mime(img)};base64,${base64Encode(img)}', 'detail': 'low'},
                      },
                  ],
          },
      ],
    };
    final res = await http
        .post(
          Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: {'Authorization': 'Bearer ${s.openaiKey.trim()}', 'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(_timeout);
    final j = _decode(res);
    final content = (((j['choices'] as List).first as Map)['message'] as Map)['content'];
    return content is String ? content : jsonEncode(content);
  }

  static Future<String> _anthropic(AiSettings s, String system, List<AiMessage> msgs) async {
    final body = {
      'model': s.anthropicModel,
      'max_tokens': 8000,
      'system': system,
      'messages': [
        for (final m in msgs)
          {
            'role': m.role,
            'content': [
              for (final img in m.images)
                {
                  'type': 'image',
                  'source': {'type': 'base64', 'media_type': _mime(img), 'data': base64Encode(img)},
                },
              {'type': 'text', 'text': m.text},
            ],
          },
      ],
    };
    final res = await http
        .post(
          Uri.parse('https://api.anthropic.com/v1/messages'),
          headers: {
            'x-api-key': s.anthropicKey.trim(),
            'anthropic-version': '2023-06-01',
            'content-type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(_timeout);
    final j = _decode(res);
    return (j['content'] as List)
        .whereType<Map>()
        .where((b) => b['type'] == 'text')
        .map((b) => b['text'] as String)
        .join();
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
