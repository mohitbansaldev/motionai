import 'dart:math' as math;

import '../core/model/layer.dart';
import '../core/model/project.dart';
import 'builder.dart';
import 'caption_cue.dart';
import 'emphasis.dart';
import 'grouping.dart';
import 'options.dart';
import 'placement.dart';
import 'styles.dart';
import 'text_rules.dart';

/// Reads caption layers back from a composition (for editing, restyling and
/// .srt/.vtt export) and writes edited captions back as one undoable batch.
class CaptionTrack {
  /// Caption layers in [comp] (ids `cap_…`).
  static List<Layer> layers(Composition comp) => [for (final l in comp.layers) if (CaptionBuilder.idPattern.hasMatch(l.id)) l];

  /// Captions in time order. Multi-line captions made of one layer per line
  /// are joined back into one caption.
  static List<CaptionCue> read(Composition comp) {
    final groups = <String, List<(int, Layer)>>{};
    for (final l in layers(comp)) {
      if (l.text == null) continue;
      final m = CaptionBuilder.idPattern.firstMatch(l.id)!;
      final key = '${m.group(1)}_${m.group(2)}';
      (groups[key] ??= []).add((int.tryParse(m.group(3) ?? '') ?? 0, l));
    }
    final out = <CaptionCue>[];
    for (final g in groups.values) {
      g.sort((a, b) => a.$1.compareTo(b.$1));
      final words = <WordTiming>[];
      final lineStarts = <int>[];
      var start = double.infinity, end = -double.infinity;
      for (final (_, l) in g) {
        start = math.min(start, l.start);
        end = math.max(end, l.end);
        final t = l.text!;
        final lines = t.words.isNotEmpty ? [t.words.map((w) => WordTiming(w.word, w.start, w.end)).toList()] : _estimate(t.text, l.start, l.end);
        for (final line in lines) {
          if (line.isEmpty) continue;
          if (words.isNotEmpty) lineStarts.add(words.length);
          words.addAll(line);
        }
        // One layer with "\n" lines and timed words: recover the line starts.
        if (g.length == 1 && t.words.isNotEmpty && t.text.contains('\n')) {
          lineStarts
            ..clear()
            ..addAll(_lineStartsFromText(t.text, t.words.length));
        }
      }
      if (words.isEmpty) continue;
      out.add(CaptionCue(words, lineStarts: lineStarts, start: start, end: end));
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  static List<int> _lineStartsFromText(String text, int wordCount) {
    final out = <int>[];
    var n = 0;
    final lines = text.split('\n');
    for (int i = 0; i < lines.length; i++) {
      if (i > 0 && n > 0 && n < wordCount) out.add(n);
      n += lines[i].split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    }
    return out;
  }

  /// Words spread over [start]..[end] by their length, one list per line.
  static List<List<WordTiming>> _estimate(String text, double start, double end) {
    final lines = [for (final l in text.split('\n')) l.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList()];
    final all = [for (final l in lines) ...l];
    if (all.isEmpty) return [];
    final weights = [for (final w in all) TextRules.visualLength(w) + 1.5];
    final total = weights.fold(0.0, (a, b) => a + b);
    final span = math.max(0.1, end - start);
    var t = start;
    var k = 0;
    final out = <List<WordTiming>>[];
    for (final l in lines) {
      final line = <WordTiming>[];
      for (final w in l) {
        final d = span * weights[k++] / total;
        line.add(WordTiming(w, t, t + d));
        t += d;
      }
      out.add(line);
    }
    return out;
  }

  /// Words for [text] spread over [start]..[end] (used by .srt import and
  /// when a caption's text is edited as a whole).
  static CaptionCue cueFromText(String text, double start, double end) {
    final lines = _estimate(text, start, end).where((l) => l.isNotEmpty).toList();
    final words = <WordTiming>[];
    final starts = <int>[];
    for (final l in lines) {
      if (words.isNotEmpty) starts.add(words.length);
      words.addAll(l);
    }
    return CaptionCue(words, lineStarts: starts, start: start, end: end);
  }

  /// A batch that replaces every caption layer with [cues] drawn in
  /// [style]. Line breaks are recomputed for the style when [relayout].
  static Map<String, dynamic> replaceCommand(
    Project project,
    List<CaptionCue> cues,
    CaptionStyle style, {
    CaptionOptions? options,
    bool relayout = true,
    String? stamp,
  }) {
    final comp = project.main;
    final o = options ?? CaptionOptions(style: style.id);
    final remove = [for (final l in layers(comp)) {'op': 'remove_layer', 'layer': l.id}];
    List<CaptionCue> list;
    if (relayout) {
      // Re-group the words for the new style (word limits and line lengths differ).
      final words = [for (final c in cues) ...c.words.map((w) => WordTiming(w.word, w.start, w.end))];
      list = CaptionBuilder.cues(comp, words, style, options: CaptionOptions(
        style: style.id,
        maxWords: o.maxWords,
        emphasis: o.emphasis,
        emphasisWords: o.emphasisWords,
        offset: 0,
      ));
    } else {
      // Keep the caption boundaries; only the line breaks follow the style.
      final deva = TextRules.mostlyDevanagari([for (final c in cues) ...c.words.map((w) => w.word)]);
      final layout = CaptionLayout.of(comp.width, comp.height, style, devanagari: deva);
      list = [
        for (final c in cues)
          c.copy()
            ..lineStarts = CaptionGrouper.breakLines(
              [for (final w in c.words) w.word],
              maxLines: style.maxLines,
              maxLineChars: layout.maxLineChars,
            ),
      ];
      if (o.emphasis || o.emphasisWords.isNotEmpty) {
        Emphasis.apply(list, aiWords: o.emphasisWords, maxPerCue: style.maxWords <= 3 ? 1 : 2);
      }
    }
    final cmds = CaptionBuilder.build(project, list, style, stamp: stamp, safeArea: o.safeArea);
    return {'op': 'batch', 'commands': [...remove, ...cmds]};
  }
}
