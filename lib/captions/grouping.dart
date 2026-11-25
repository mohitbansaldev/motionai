import 'dart:math' as math;

import 'caption_cue.dart';
import 'text_rules.dart';

/// Limits for splitting a transcript into captions.
class GroupingRules {
  /// Most words in one caption (glued words — "₹500 crore", "Elon Musk" —
  /// may push a caption up to [maxWords] + 2).
  final int maxWords;
  final int maxLines;

  /// Most visual characters per line (see [TextRules.visualLength]).
  final double maxLineChars;

  /// A silence longer than this always starts a new caption (seconds).
  final double maxGap;

  /// Longest caption on screen (seconds).
  final double maxDuration;

  /// Also break after commas / clause ends once a caption has 2+ words.
  final bool breakOnClause;

  const GroupingRules({
    this.maxWords = 4,
    this.maxLines = 2,
    this.maxLineChars = 28,
    this.maxGap = 0.6,
    this.maxDuration = 3.5,
    this.breakOnClause = true,
  });
}

/// Splits timed words into captions and captions into lines.
class CaptionGrouper {
  /// Groups [words] into captions. Never splits glued words (numbers with
  /// their units, currency with the amount, Title Case names, Hindi /
  /// Hinglish postpositions with the word before) unless they would make a
  /// caption longer than [GroupingRules.maxWords] + 2.
  static List<CaptionCue> group(List<WordTiming> words, GroupingRules r) {
    final maxWords = math.max(1, r.maxWords);
    final hardMax = maxWords + 2;
    final ws = [for (final w in words) if (w.word.trim().isNotEmpty) w];
    if (ws.isEmpty) return [];

    // 1. Chunks of words that belong together.
    final chunks = <List<int>>[];
    var cur = <int>[0];
    for (int i = 1; i < ws.length; i++) {
      final gap = ws[i].start - ws[i - 1].end;
      if (gap <= r.maxGap && cur.length < hardMax && TextRules.glued(ws[i - 1].word, ws[i].word)) {
        cur.add(i);
      } else {
        chunks.add(cur);
        cur = [i];
      }
    }
    chunks.add(cur);

    // 2. Pack chunks into captions.
    final maxChars = r.maxLines * r.maxLineChars;
    final groups = <List<int>>[];
    var g = <int>[];
    for (final c in chunks) {
      if (g.isNotEmpty) {
        final last = ws[g.last];
        final gap = ws[c.first].start - last.end;
        final n = g.length + c.length;
        final chars = TextRules.lineLength([for (final i in [...g, ...c]) ws[i].word]);
        final tooLong = ws[c.last].end - ws[g.first].start > r.maxDuration;
        // A last single word of a sentence may join instead of standing alone.
        final isLast = c.last == ws.length - 1;
        final closes = c.length == 1 &&
            (isLast || TextRules.endsSentence(ws[c.first].word) || ws[c.first + 1].start - ws[c.first].end > r.maxGap);
        final orphanOk = closes && n == maxWords + 1 && maxWords >= 3 && !tooLong;
        final breakHere = gap > r.maxGap ||
            TextRules.endsSentence(last.word) ||
            (r.breakOnClause && g.length >= 2 && TextRules.endsClause(last.word)) ||
            (n > maxWords && !orphanOk) ||
            !_fits(chars, maxChars) ||
            tooLong;
        if (breakHere) {
          groups.add(g);
          g = [];
        }
      }
      g.addAll(c);
      // A chunk longer than the hard limit is split.
      while (g.length > hardMax) {
        groups.add(g.sublist(0, maxWords));
        g = g.sublist(maxWords);
      }
    }
    if (g.isNotEmpty) groups.add(g);

    // 3. Captions with line breaks.
    return [
      for (final grp in groups)
        CaptionCue(
          [for (final i in grp) ws[i]],
          lineStarts: breakLines([for (final i in grp) ws[i].word], maxLines: r.maxLines, maxLineChars: r.maxLineChars),
        ),
    ];
  }

  static bool _fits(double chars, double max) => chars <= max + 0.01;

  /// Where to start new lines (word indices) so each line fits in
  /// [maxLineChars], lines are balanced (the bottom line may be longer), and
  /// glued words stay on one line. Empty = one line.
  static List<int> breakLines(List<String> words, {int maxLines = 2, double maxLineChars = 28}) {
    final n = words.length;
    if (n <= 1 || maxLines <= 1) return [];
    if (TextRules.lineLength(words) <= maxLineChars) return [];
    double len(int a, int b) => TextRules.lineLength(words.sublist(a, b));
    bool canBreak(int k) => !TextRules.glued(words[k - 1], words[k]);

    if (maxLines == 2) {
      // Pass 1: never inside glued words. Pass 2: may split a long name or
      // amount, but never strand a particle / currency sign / number.
      // Otherwise keep one (long) line.
      for (final pass in [0, 1]) {
        int? best;
        var bestCost = double.infinity;
        for (int k = 1; k < n; k++) {
          if (pass == 0 && !canBreak(k)) continue;
          if (pass == 1 && TextRules.unbreakable(words[k - 1], words[k])) continue;
          final a = len(0, k), b = len(k, n);
          // Overflow is expensive, imbalance cheap; a longer top line costs a bit more.
          var cost = math.max(a, b) + (a > b ? (a - b) * 0.15 : 0);
          if (a > maxLineChars) cost += (a - maxLineChars) * 4;
          if (b > maxLineChars) cost += (b - maxLineChars) * 4;
          // A one-word top line is a last resort.
          if (k == 1 && n > 2) cost += 2;
          if (cost < bestCost) {
            bestCost = cost;
            best = k;
          }
        }
        if (best != null) return [best];
      }
      return [];
    }

    // 3+ lines: greedy fill, breaking only where allowed.
    final starts = <int>[];
    var from = 0;
    for (int k = 1; k < n; k++) {
      if (starts.length >= maxLines - 1) break;
      if (len(from, k + 1) > maxLineChars && !TextRules.unbreakable(words[k - 1], words[k]) && (canBreak(k) || len(from, k + 1) > maxLineChars * 1.5)) {
        starts.add(k);
        from = k;
      }
    }
    return starts;
  }
}
