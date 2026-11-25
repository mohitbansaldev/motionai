import 'dart:convert';

import 'caption_cue.dart';
import 'text_rules.dart';

/// Why a word is emphasised. Higher = stronger.
enum EmphasisKind { none, name, number, year, money, ai }

/// Finds the words worth highlighting in a caption: numbers, money (₹ / $ /
/// crore / lakh), years, names in Title Case, and words picked by the AI.
class Emphasis {
  /// Kind of emphasis for word [i] of [words] (the whole transcript or one
  /// caption). [aiWords] are normalised words (see [TextRules.normalize]).
  static EmphasisKind kindOf(List<String> words, int i, {Set<String> aiWords = const {}}) {
    final w = words[i];
    final norm = TextRules.normalize(w);
    if (norm.isEmpty) return EmphasisKind.none;
    if (aiWords.contains(norm)) return EmphasisKind.ai;
    if (TextRules.isMoney(w)) return EmphasisKind.money;
    final prev = i > 0 ? words[i - 1] : null;
    final next = i + 1 < words.length ? words[i + 1] : null;
    if (TextRules.hasDigit(w)) {
      if (prev != null && TextRules.isCurrencySymbol(prev)) return EmphasisKind.money;
      if (next != null && _moneyUnit(next)) return EmphasisKind.money;
      if (TextRules.isYear(w)) return EmphasisKind.year;
      return EmphasisKind.number;
    }
    if (TextRules.isCurrencySymbol(w) && next != null && TextRules.hasDigit(next)) return EmphasisKind.money;
    // The unit of an amount ("500 crore") is part of the highlight.
    if (prev != null && TextRules.hasDigit(prev) && TextRules.isUnit(w)) {
      return _moneyUnit(w) ? EmphasisKind.money : EmphasisKind.number;
    }
    if (TextRules.bigNumberWords.contains(norm)) return EmphasisKind.money;
    // Names: Title Case words that do not start a sentence, and acronyms.
    if (!_allCaps(words)) {
      final sentenceStart = i == 0 || TextRules.endsSentence(prev!);
      if (TextRules.isAcronym(w)) return EmphasisKind.name;
      if (TextRules.isTitleCase(w) && (!sentenceStart || (next != null && TextRules.isTitleCase(next)))) {
        return EmphasisKind.name;
      }
    }
    return EmphasisKind.none;
  }

  static bool _moneyUnit(String w) {
    final n = TextRules.normalize(w);
    return TextRules.bigNumberWords.contains(n) || TextRules.currencyWords.contains(n);
  }

  static bool _allCaps(List<String> words) {
    var upper = 0, letters = 0;
    for (final w in words) {
      for (final r in w.runes) {
        if (r >= 0x41 && r <= 0x5A) {
          upper++;
          letters++;
        } else if (r >= 0x61 && r <= 0x7A) {
          letters++;
        }
      }
    }
    return letters >= 6 && upper > letters * 0.8;
  }

  /// Emphasised word indices for each caption. Glued runs ("₹500 crore",
  /// "Elon Musk") are highlighted together. At most [maxPerCue] separate
  /// highlights per caption, strongest first.
  static void apply(List<CaptionCue> cues, {Set<String> aiWords = const {}, int maxPerCue = 2}) {
    for (final c in cues) {
      c.emphasis = detect([for (final w in c.words) w.word], aiWords: aiWords, maxRuns: maxPerCue);
    }
  }

  /// Indices of emphasised words in one caption.
  static Set<int> detect(List<String> words, {Set<String> aiWords = const {}, int maxRuns = 2}) {
    final kinds = [for (int i = 0; i < words.length; i++) kindOf(words, i, aiWords: aiWords)];
    // Runs of consecutive emphasised, glued words.
    final runs = <(int, int, EmphasisKind)>[];
    for (int i = 0; i < words.length; i++) {
      if (kinds[i] == EmphasisKind.none) continue;
      final last = runs.isEmpty ? null : runs.last;
      if (last != null && last.$2 == i && TextRules.glued(words[i - 1], words[i])) {
        runs[runs.length - 1] = (last.$1, i + 1, kinds[i].index > last.$3.index ? kinds[i] : last.$3);
      } else {
        runs.add((i, i + 1, kinds[i]));
      }
    }
    final ranked = [...runs]..sort((a, b) {
        final k = b.$3.index.compareTo(a.$3.index);
        return k != 0 ? k : a.$1.compareTo(b.$1);
      });
    final out = <int>{};
    for (final r in ranked.take(maxRuns)) {
      for (int i = r.$1; i < r.$2; i++) {
        out.add(i);
      }
    }
    return out;
  }
}

/// Optional AI pass: one request for the whole transcript returns the words
/// to emphasise. Pure prompt/parse helpers here; the request itself is made
/// by the caller with `AiClient.complete` (see `CaptionMaker`).
class EmphasisAi {
  static const system = 'You edit captions for a viral Hindi/Hinglish/English documentary YouTube channel. '
      'From the transcript, pick the few punchiest words to highlight on screen: key numbers, money, years, '
      'names, places, shocking or decisive words. At most one or two per sentence; never filler words. '
      'Return JSON {"emphasis": ["word", ...]} using the words exactly as written in the transcript.';

  static String userMessage(List<String> words) => jsonEncode({'transcript': words.join(' ')});

  /// Normalised words from the model reply (tolerates prose around the JSON,
  /// a bare list, or phrases — which are split into words).
  static Set<String> parse(String raw) {
    final out = <String>{};
    dynamic decoded;
    try {
      final a = raw.indexOf('{'), b = raw.lastIndexOf('}');
      if (a >= 0 && b > a) {
        decoded = jsonDecode(raw.substring(a, b + 1));
      } else {
        final la = raw.indexOf('['), lb = raw.lastIndexOf(']');
        if (la >= 0 && lb > la) decoded = jsonDecode(raw.substring(la, lb + 1));
      }
    } catch (_) {
      return out;
    }
    List? list;
    if (decoded is Map) {
      final v = decoded['emphasis'] ?? decoded['words'] ?? decoded['keywords'];
      if (v is List) list = v;
    } else if (decoded is List) {
      list = decoded;
    }
    for (final e in list ?? const []) {
      for (final part in '$e'.split(RegExp(r'\s+'))) {
        final n = TextRules.normalize(part);
        if (n.isNotEmpty && !TextRules.notNames.contains(n)) out.add(n);
      }
    }
    return out;
  }
}
