import 'dart:convert';
import 'dart:math' as math;

import '../ai/ai_client.dart';
import '../ai/ai_settings.dart';
import '../captions/builder.dart';
import '../captions/emphasis.dart';
import '../captions/options.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import 'speech.dart';

export '../captions/options.dart' show CaptionOptions;

/// Speech-to-text captions: audio → Whisper (on the phone, or OpenAI) →
/// caption text layers with per-word highlight.
class CaptionMaker {
  static Future<List<Map<String, dynamic>>> buildCommands(
    Project project,
    Layer source,
    CaptionOptions o, {
    void Function(String)? onStatus,
  }) async {
    final s = await AiSettings.load();
    final media = project.media[source.mediaId];
    if (media == null) throw AiException('This layer has no media.');

    // 1-2. Speech → words (on the phone by default).
    var words = await Speech.words(
      media.path,
      language: o.roman ? null : o.language,
      roman: o.roman,
      sourceIn: source.sourceIn,
      duration: source.duration * source.speed,
      onStatus: onStatus,
    );
    if (words.isEmpty) throw AiException('No speech was found in this clip.');

    // 3. Romanize if needed (Devanagari → Hinglish)
    if (o.roman && words.any((w) => RegExp(r'[ऀ-ॿ]').hasMatch(w.word))) {
      onStatus?.call('Converting to Roman script…');
      try {
        final raw = await AiClient.complete(
          s: s,
          system: 'Transliterate Hindi words to casual Roman-script Hinglish. '
              'Return JSON {"words": [...]} with exactly the same number of items, in order.',
          messages: [AiMessage('user', jsonEncode({'words': words.map((w) => w.word).toList()}))],
        );
        final start = raw.indexOf('{'), end = raw.lastIndexOf('}');
        final out = (jsonDecode(raw.substring(start, end + 1))['words'] as List).map((e) => '$e').toList();
        if (out.length == words.length) {
          for (int i = 0; i < words.length; i++) {
            words[i].word = out[i];
          }
        }
      } catch (_) {
        // Keep the original script if transliteration fails.
      }
    }

    // 4. Source time → composition time, keep words inside the layer.
    words = [
      for (final w in words)
        if (w.start >= source.sourceIn && w.start < source.sourceIn + source.duration * source.speed)
          WordTiming(
            w.word,
            source.start + (w.start - source.sourceIn) / source.speed,
            source.start + (math.min(w.end, source.sourceIn + source.duration * source.speed) - source.sourceIn) / source.speed,
          ),
    ];
    if (words.isEmpty) throw AiException('No speech falls inside the trimmed part of this clip.');

    // 5. Optional AI pass for words to emphasise (one request).
    if (o.aiEmphasis) {
      onStatus?.call('Finding key words…');
      o.emphasisWords.addAll(await aiEmphasis(words));
    }

    return fromWords(project, words, o);
  }

  /// Caption text layers (with per-word timing) from composition-time words.
  /// Grouping, styles, emphasis and safe areas live in `lib/captions/`.
  static List<Map<String, dynamic>> fromWords(Project project, List<WordTiming> words, CaptionOptions o) =>
      CaptionBuilder.fromWords(project, words, o);

  /// One AI request for the whole transcript: normalised words to emphasise.
  /// Returns an empty set when AI is not set up or the request fails.
  static Future<Set<String>> aiEmphasis(List<WordTiming> words) async {
    try {
      final s = await AiSettings.load();
      if (!s.isConfigured || words.isEmpty) return {};
      final raw = await AiClient.complete(
        s: s,
        system: EmphasisAi.system,
        messages: [AiMessage('user', EmphasisAi.userMessage([for (final w in words) w.word]))],
      );
      return EmphasisAi.parse(raw);
    } catch (_) {
      return {};
    }
  }
}
