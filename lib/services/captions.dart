import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';

import '../ai/ai_client.dart';
import '../ai/ai_settings.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import 'media_bridge.dart';

class CaptionOptions {
  String? language; // 'hi', 'en' or null (auto)
  bool roman; // Hinglish in Latin script
  int maxWords;
  String style; // karaoke | word_pop | plain
  CaptionOptions({this.language = 'hi', this.roman = false, this.maxWords = 4, this.style = 'karaoke'});
}

/// Speech-to-text captions: audio → OpenAI Whisper (word timestamps) →
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

    // 1. Audio file
    String audioPath = media.path;
    if (media.type == MediaType.video) {
      onStatus?.call('Extracting audio…');
      final dir = await getTemporaryDirectory();
      audioPath = '${dir.path}/captions_${source.id}.m4a';
      final ok = await MediaBridge.extractAudio(media.path, audioPath);
      if (!ok) throw AiException('This video has no audio track that can be read.');
    }
    final size = await File(audioPath).length();
    if (size > 25 * 1024 * 1024) {
      throw AiException('The audio is ${(size / 1048576).toStringAsFixed(0)} MB; speech-to-text accepts up to 25 MB. '
          'Split the clip into shorter parts first.');
    }

    // 2. Transcribe
    onStatus?.call('Transcribing speech…');
    final res = await AiClient.transcribe(
      s: s,
      audioPath: audioPath,
      language: o.roman ? null : o.language,
      prompt: o.roman ? 'Hinglish conversation written in Roman script, like: "aaj hum baat karenge"' : null,
    );
    var words = <WordTiming>[];
    for (final w in (res['words'] as List? ?? [])) {
      final m = w as Map<String, dynamic>;
      words.add(WordTiming(
        (m['word'] as String).trim(),
        (m['start'] as num).toDouble(),
        (m['end'] as num).toDouble(),
      ));
    }
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

    // 5. Group into captions.
    final groups = <List<WordTiming>>[];
    var cur = <WordTiming>[];
    for (final w in words) {
      final gap = cur.isEmpty ? 0.0 : w.start - cur.last.end;
      final endsSentence = cur.isNotEmpty && RegExp(r'[.!?।,]$').hasMatch(cur.last.word);
      if (cur.isNotEmpty && (cur.length >= o.maxWords || gap > 0.6 || endsSentence)) {
        groups.add(cur);
        cur = [];
      }
      cur.add(w);
    }
    if (cur.isNotEmpty) groups.add(cur);

    // 6. Commands
    final comp = project.main;
    final short = math.min(comp.width, comp.height);
    final fontSize = (short * 0.065).roundToDouble();
    final y = comp.height > comp.width ? comp.height * 0.72 : comp.height * 0.84;
    final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final cmds = <Map<String, dynamic>>[];
    for (int i = 0; i < groups.length; i++) {
      final g = groups[i];
      final start = g.first.start;
      var end = g.last.end;
      if (i + 1 < groups.length && groups[i + 1].first.start - end < 0.35) end = groups[i + 1].first.start;
      end = math.max(end, start + 0.3);
      cmds.add({
        'op': 'add_layer',
        'type': 'text',
        'id': 'cap_${stamp}_$i',
        'name': 'Caption ${i + 1}',
        'text': g.map((w) => w.word).join(' '),
        'start': start,
        'duration': end - start,
        'width': comp.width * 0.9,
        'height': fontSize * 3.2,
        'position': [comp.width / 2, y, 0],
        'font_size': fontSize,
        'font_weight': 800,
        'shadow': true,
        'box_color': o.style == 'plain' ? '#99000000' : 'none',
        'animator': o.style == 'plain' ? 'none' : o.style,
        'anim_duration': 0.3,
        'words': [for (final w in g) {'w': w.word, 's': w.start, 'e': w.end}],
      });
    }
    return cmds;
  }
}
