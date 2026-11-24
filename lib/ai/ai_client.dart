import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'ai_settings.dart';

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
    if (!s.isConfigured) throw AiException('Add your API key in AI settings first.');
    return s.provider == AiProvider.openai
        ? _openai(s, system, messages, jsonMode)
        : _anthropic(s, system, messages);
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
