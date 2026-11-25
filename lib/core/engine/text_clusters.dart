// V2-F: user-perceived letters for per-letter text animators (pure Dart).
//
// Per-letter effects (scramble, random_pop, typewriter, rolling tiles) must
// never split a letter from its combining marks. In Devanagari a "letter" is
// a whole syllable cluster: consonant (+ nukta) (+ virama + consonant …)
// (+ vowel sign) (+ candrabindu / anusvara / visarga), e.g. "स्था", "क्ष",
// "त्रि", "श्री", "फ़", "हॉ", "लैं". Splitting by UTF-16 code unit or by code
// point drops / detaches viramas, matras and nuktas ("राजस्थान" → "ज  न").
//
// [TextClusters.ranges] implements extended grapheme clusters (combining
// marks, ZWJ / ZWNJ, variation selectors, emoji modifiers and ZWJ sequences,
// regional-indicator flags, CR LF, surrogate pairs) plus the Indic conjunct
// rule (Unicode 15.1 GB9c): a virama followed by a consonant of the same
// script joins the clusters.

/// Broad script class of a cluster (scramble picks random letters from it).
enum ClusterClass { space, digit, upper, lower, devanagari, devanagariDigit, other }

class TextClusters {
  /// Start/end UTF-16 offsets of each user-perceived letter of [s].
  static List<(int, int)> ranges(String s) {
    final out = <(int, int)>[];
    final n = s.length;
    var i = 0;
    while (i < n) {
      final start = i;
      var (cp, len) = _at(s, i);
      i += len;
      var prev = cp;
      var riCount = _isRegional(cp) ? 1 : 0;
      // CR LF stays one cluster.
      if (cp == 0x0D && i < n && s.codeUnitAt(i) == 0x0A) {
        out.add((start, i + 1));
        i++;
        continue;
      }
      if (_isControl(cp)) {
        out.add((start, i));
        continue;
      }
      while (i < n) {
        final (next, nlen) = _at(s, i);
        var join = false;
        if (_isExtend(next) || next == 0x200D || _isSpacingMark(next)) {
          join = true;
        } else if (prev == 0x200D && _isPictographic(next)) {
          join = true; // emoji ZWJ sequence
        } else if (_isVirama(prev) && _isConsonant(next) && _sameIndicBlock(prev, next)) {
          join = true; // conjunct: क्ष, स्थ, त्र, श्र
        } else if (prev == 0x200D && _isConsonant(next) && i - start >= 2 && _isVirama(_cpBefore(s, i - 1))) {
          join = true; // virama + ZWJ + consonant (half-form request)
        } else if (riCount == 1 && _isRegional(next)) {
          join = true; // flag = two regional indicators
          riCount = 2;
        }
        if (!join) break;
        i += nlen;
        prev = next;
      }
      out.add((start, i));
    }
    return out;
  }

  /// The user-perceived letters of [s] (joined back they give [s]).
  static List<String> split(String s) => [for (final (a, b) in ranges(s)) s.substring(a, b)];

  /// Number of letters in [s].
  static int count(String s) => ranges(s).length;

  /// UTF-16 offset after the first [letters] letters of [s] (typewriter).
  static int prefixEnd(String s, int letters) {
    if (letters <= 0) return 0;
    final r = ranges(s);
    if (letters >= r.length) return s.length;
    return r[letters - 1].$2;
  }

  /// Script class of one cluster (by its first code point).
  static ClusterClass classOf(String cluster) {
    if (cluster.isEmpty || cluster.trim().isEmpty) return ClusterClass.space;
    final cp = cluster.runes.first;
    if (cp >= 0x30 && cp <= 0x39) return ClusterClass.digit;
    if (cp >= 0x41 && cp <= 0x5A) return ClusterClass.upper;
    if (cp >= 0x61 && cp <= 0x7A) return ClusterClass.lower;
    if (cp >= 0x0966 && cp <= 0x096F) return ClusterClass.devanagariDigit;
    if (_isDevanagariLetter(cp)) return ClusterClass.devanagari;
    return ClusterClass.other;
  }

  /// True for any Devanagari code point (incl. extended blocks).
  static bool isDevanagari(int cp) => (cp >= 0x0900 && cp <= 0x097F) || (cp >= 0xA8E0 && cp <= 0xA8FF) || (cp >= 0x1CD0 && cp <= 0x1CFF);

  static bool _isDevanagariLetter(int cp) =>
      (cp >= 0x0904 && cp <= 0x0939) || cp == 0x093D || cp == 0x0950 || (cp >= 0x0958 && cp <= 0x0961) || (cp >= 0x0971 && cp <= 0x097F);

  // ---------------------------------------------------------------- internals

  static (int, int) _at(String s, int i) {
    final c = s.codeUnitAt(i);
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
      final d = s.codeUnitAt(i + 1);
      if (d >= 0xDC00 && d <= 0xDFFF) return (0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00), 2);
    }
    return (c, 1);
  }

  /// The code point that ends just before UTF-16 offset [end].
  static int _cpBefore(String s, int end) {
    final c = s.codeUnitAt(end - 1);
    if (c >= 0xDC00 && c <= 0xDFFF && end >= 2) {
      final h = s.codeUnitAt(end - 2);
      if (h >= 0xD800 && h <= 0xDBFF) return 0x10000 + ((h - 0xD800) << 10) + (c - 0xDC00);
    }
    return c;
  }

  static bool _isControl(int cp) => cp == 0x0A || cp == 0x0D || (cp < 0x20) || (cp >= 0x7F && cp < 0xA0);

  static bool _isRegional(int cp) => cp >= 0x1F1E6 && cp <= 0x1F1FF;

  static bool _isPictographic(int cp) =>
      (cp >= 0x1F300 && cp <= 0x1FAFF) || (cp >= 0x2600 && cp <= 0x27BF) || (cp >= 0x1F000 && cp <= 0x1F2FF) || cp == 0x2764;

  /// Indic viramas (Devanagari … Malayalam, Sinhala).
  static bool _isVirama(int cp) =>
      cp == 0x094D || cp == 0x09CD || cp == 0x0A4D || cp == 0x0ACD || cp == 0x0B4D || cp == 0x0BCD || cp == 0x0C4D || cp == 0x0CCD || cp == 0x0D4D || cp == 0x0DCA;

  /// Indic consonants (incl. Devanagari nukta forms क़ … य़ and the extended letters).
  static bool _isConsonant(int cp) =>
      (cp >= 0x0915 && cp <= 0x0939) || (cp >= 0x0958 && cp <= 0x095F) || (cp >= 0x0978 && cp <= 0x097F) ||
      (cp >= 0x0995 && cp <= 0x09B9) || (cp >= 0x09DC && cp <= 0x09DF) || // Bengali
      (cp >= 0x0A15 && cp <= 0x0A39) || (cp >= 0x0A59 && cp <= 0x0A5E) || // Gurmukhi
      (cp >= 0x0A95 && cp <= 0x0AB9) || // Gujarati
      (cp >= 0x0B15 && cp <= 0x0B39) || (cp >= 0x0B5C && cp <= 0x0B5F) || // Oriya
      (cp >= 0x0B95 && cp <= 0x0BB9) || // Tamil
      (cp >= 0x0C15 && cp <= 0x0C39) || // Telugu
      (cp >= 0x0C95 && cp <= 0x0CB9) || // Kannada
      (cp >= 0x0D15 && cp <= 0x0D3A) || // Malayalam
      (cp >= 0x0D9A && cp <= 0x0DC6); // Sinhala

  static bool _sameIndicBlock(int a, int b) => (a >> 7) == (b >> 7);

  /// Spacing combining marks (Mc): vowel signs written beside the letter.
  static bool _isSpacingMark(int cp) {
    if (cp >= 0x0900 && cp <= 0x0DFF) {
      final o = cp & 0x7F; // offset inside the 128-code-point Indic block
      // Dependent vowel signs, virama, nukta, signs (ं ः ँ) and the stress
      // marks of every Brahmic block sit at the same offsets.
      return (o >= 0x00 && o <= 0x03) || (o >= 0x3A && o <= 0x4F && o != 0x3D) || (o >= 0x51 && o <= 0x57) || (o >= 0x62 && o <= 0x63);
    }
    return false;
  }

  /// Grapheme_Extend-ish code points (nonspacing / enclosing marks, emoji
  /// modifiers, variation selectors, tags).
  static bool _isExtend(int cp) =>
      (cp >= 0x0300 && cp <= 0x036F) || // combining diacritics
      (cp >= 0x0483 && cp <= 0x0489) ||
      (cp >= 0x0591 && cp <= 0x05BD) || cp == 0x05BF || cp == 0x05C1 || cp == 0x05C2 || cp == 0x05C4 || cp == 0x05C5 || cp == 0x05C7 ||
      (cp >= 0x0610 && cp <= 0x061A) || (cp >= 0x064B && cp <= 0x065F) || cp == 0x0670 || (cp >= 0x06D6 && cp <= 0x06DC) || (cp >= 0x06DF && cp <= 0x06E4) ||
      cp == 0x06E7 || cp == 0x06E8 || (cp >= 0x06EA && cp <= 0x06ED) ||
      (cp >= 0x0E31 && cp <= 0x0E3A && cp != 0x0E32 && cp != 0x0E33) || (cp >= 0x0E47 && cp <= 0x0E4E) || // Thai
      (cp >= 0x1AB0 && cp <= 0x1AFF) || (cp >= 0x1CD0 && cp <= 0x1CE8) || cp == 0x1CED || cp == 0x1CF4 || (cp >= 0x1CF7 && cp <= 0x1CF9) || // Vedic
      (cp >= 0x1DC0 && cp <= 0x1DFF) || cp == 0x200C || (cp >= 0x20D0 && cp <= 0x20FF) ||
      (cp >= 0xA8E0 && cp <= 0xA8F1) || // Devanagari extended (cantillation)
      (cp >= 0xFE00 && cp <= 0xFE0F) || (cp >= 0xFE20 && cp <= 0xFE2F) ||
      (cp >= 0x1F3FB && cp <= 0x1F3FF) || // skin tones
      (cp >= 0xE0020 && cp <= 0xE007F) || (cp >= 0xE0100 && cp <= 0xE01EF);
}
