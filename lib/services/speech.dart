import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import '../ai/ai_client.dart';
import '../ai/ai_settings.dart';
import '../core/model/layer.dart';
import 'media_bridge.dart';

/// Speech-to-text. Runs Whisper on the phone by default (free, offline after
/// a one-time model download); uses the OpenAI API only if the user picked it.
class Speech {
  static final _controller = WhisperController();

  static WhisperModel _model(String name) => switch (name) {
        'tiny' => WhisperModel.tiny,
        'small' => WhisperModel.small,
        _ => WhisperModel.base,
      };

  static String modelLabel(String name) => switch (name) {
        'tiny' => 'Fast (75 MB)',
        'small' => 'Accurate (466 MB)',
        _ => 'Balanced (142 MB)',
      };

  /// Words with times in SOURCE seconds of [path] (a video or audio file).
  static Future<List<WordTiming>> words(
    String path, {
    String? language, // 'hi', 'en' or null for auto
    bool roman = false,
    double sourceIn = 0,
    double duration = 0,
    void Function(String status)? onStatus,
  }) async {
    final s = await AiSettings.load();
    if (s.speechEngine == 'openai' && s.openaiKey.trim().isNotEmpty) {
      return _openai(s, path, language: language, roman: roman, onStatus: onStatus);
    }
    onStatus?.call('Preparing audio…');
    final dir = await getTemporaryDirectory();
    final wav = '${dir.path}/stt_${DateTime.now().millisecondsSinceEpoch}.wav';
    await MediaBridge.wav16k(path, wav, sourceIn: sourceIn, duration: duration);
    try {
      final model = _model(s.whisperModel);
      final modelFile = File(await _controller.getPath(model));
      if (!modelFile.existsSync()) {
        onStatus?.call('Downloading the speech model once (${modelLabel(s.whisperModel)})…');
        await _controller.downloadModel(model);
      }
      onStatus?.call('Listening on your phone…');
      final res = await _controller.transcribe(
        model: model,
        audioPath: wav,
        lang: language ?? 'auto',
        withSegments: true,
        splitOnWord: true,
        initialPrompt: roman
            ? 'Hinglish, written in Roman script: aaj hum baat karenge ki ye kaise hua.'
            : (language == 'hi' ? 'नमस्ते दोस्तों, आज हम बात करेंगे।' : null),
        onProgress: (p) => onStatus?.call('Listening on your phone… $p%'),
      );
      final segs = res?.transcription.segments ?? const [];
      final out = <WordTiming>[];
      for (final seg in segs) {
        final text = seg.text.trim();
        if (text.isEmpty || text.startsWith('[') || text.startsWith('(')) continue;
        final a = seg.fromTs.inMilliseconds / 1000, b = seg.toTs.inMilliseconds / 1000;
        final parts = text.split(RegExp(r'\s+'));
        // A segment may still hold several words: spread its time evenly.
        for (int i = 0; i < parts.length; i++) {
          final s0 = a + (b - a) * i / parts.length;
          final s1 = a + (b - a) * (i + 1) / parts.length;
          out.add(WordTiming(parts[i], sourceIn + s0, sourceIn + s1));
        }
      }
      if (out.isEmpty) throw AiException('No speech was found. Check that the clip has a voice track.');
      return out;
    } finally {
      File(wav).delete().ignore();
    }
  }

  static Future<List<WordTiming>> _openai(AiSettings s, String path,
      {String? language, bool roman = false, void Function(String)? onStatus}) async {
    var audio = path;
    if (!RegExp(r'\.(m4a|mp3|wav|aac|ogg|flac|opus)$', caseSensitive: false).hasMatch(path)) {
      onStatus?.call('Extracting audio…');
      final dir = await getTemporaryDirectory();
      audio = '${dir.path}/stt_${DateTime.now().millisecondsSinceEpoch}.m4a';
      if (!await MediaBridge.extractAudio(path, audio)) throw AiException('This file has no readable audio.');
    }
    if (await File(audio).length() > 25 * 1024 * 1024) {
      throw AiException('Audio is over 25 MB for the OpenAI API. Switch speech-to-text to "On this phone" in AI settings.');
    }
    onStatus?.call('Transcribing with OpenAI…');
    final res = await AiClient.transcribe(
      s: s,
      audioPath: audio,
      language: roman ? null : language,
      prompt: roman ? 'Hinglish conversation written in Roman script, like: "aaj hum baat karenge"' : null,
    );
    return [
      for (final w in (res['words'] as List? ?? []))
        WordTiming(
          '${(w as Map)['word']}'.trim(),
          (w['start'] as num).toDouble(),
          (w['end'] as num).toDouble(),
        ),
    ];
  }

  /// Groups words into sentences/lines: (start, end, text).
  static List<(double, double, String)> lines(List<WordTiming> words, {int maxWords = 18}) {
    final out = <(double, double, String)>[];
    var cur = <WordTiming>[];
    void flush() {
      if (cur.isEmpty) return;
      out.add((cur.first.start, cur.last.end, cur.map((w) => w.word).join(' ')));
      cur = [];
    }

    for (final w in words) {
      if (cur.isNotEmpty && (w.start - cur.last.end > 0.8 || cur.length >= maxWords)) flush();
      cur.add(w);
      if (RegExp(r'[.!?।]$').hasMatch(w.word) && cur.length >= 3) flush();
    }
    flush();
    return out;
  }
}
