/// Script-aware text rules for captions: visual width estimates, which words
/// must stay together (numbers + units, currency + amount, names, Hindi /
/// Hinglish postpositions) and sentence ends. Pure Dart.
class TextRules {
  static final _deva = RegExp(r'[ऀ-ॿ]');

  /// True when [s] contains Devanagari letters.
  static bool isDevanagari(String s) => _deva.hasMatch(s);

  /// True when most letters of [words] are Devanagari.
  static bool mostlyDevanagari(Iterable<String> words) {
    var d = 0, l = 0;
    for (final w in words) {
      for (final r in w.runes) {
        if (r >= 0x0900 && r <= 0x097F) {
          d++;
        } else if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
          l++;
        }
      }
    }
    return d > l;
  }

  /// Devanagari vowel signs, virama, nukta and other combining marks take no
  /// width of their own (they sit on the previous letter).
  static bool isCombining(int r) =>
      (r >= 0x0900 && r <= 0x0903) ||
      (r >= 0x093A && r <= 0x094F && r != 0x093D) ||
      (r >= 0x0951 && r <= 0x0957) ||
      (r >= 0x0962 && r <= 0x0963) ||
      (r >= 0x0300 && r <= 0x036F) ||
      r == 0x200C ||
      r == 0x200D ||
      (r >= 0xFE00 && r <= 0xFE0F);

  /// Approximate width of [s] in "average characters" (1.0 ≈ one lowercase
  /// Latin letter of a bold sans font). Combining marks are free, Devanagari
  /// letters and capitals are a bit wider, spaces and punctuation narrower.
  static double visualLength(String s) {
    var n = 0.0;
    int? prev;
    for (final r in s.runes) {
      if (isCombining(r)) {
        prev = r;
        continue;
      }
      // A consonant after a virama forms a conjunct: mostly overlaps.
      if (prev == 0x094D && r >= 0x0915 && r <= 0x0939) {
        n += 0.45;
      } else if (r >= 0x0900 && r <= 0x097F) {
        n += 1.15;
      } else if (r >= 0x41 && r <= 0x5A) {
        n += 1.2;
      } else if (r == 0x20) {
        n += 0.5;
      } else if ('.,:;!?\'’"|-'.codeUnits.contains(r)) {
        n += 0.45;
      } else if (r == 0x4D || r == 0x57 || r == 0x6D || r == 0x77) {
        n += 1.3;
      } else {
        n += 1.0;
      }
      prev = r;
    }
    return n;
  }

  /// Width of words joined with spaces.
  static double lineLength(Iterable<String> words) {
    var n = 0.0, k = 0;
    for (final w in words) {
      n += visualLength(w);
      k++;
    }
    return n + (k > 1 ? (k - 1) * 0.5 : 0);
  }

  /// Strips surrounding punctuation and lowercases (for matching words).
  static String normalize(String w) => w
      .toLowerCase()
      .replaceAll(RegExp(r'^[^\p{L}\p{M}\p{N}₹$€£]+|[^\p{L}\p{M}\p{N}%]+$', unicode: true), '');

  static final _sentenceEnd = RegExp(r'[.!?।॥…]["”’)]*$');
  static final _clauseEnd = RegExp(r'[,;:—–]["”’)]*$');

  static bool endsSentence(String w) => _sentenceEnd.hasMatch(w);
  static bool endsClause(String w) => _clauseEnd.hasMatch(w);

  // ------------------------------------------------------------- numbers

  static final _digits = RegExp(r'[0-9०-९]');
  static final _currencySymbol = RegExp(r'^[₹$€£]$|^(rs\.?|inr|usd)$', caseSensitive: false);
  static final _money = RegExp(r'[₹$€£]|^(rs\.?|inr|usd)\s?[0-9]', caseSensitive: false);

  /// Words that follow a number and belong to it.
  static const units = {
    'crore', 'crores', 'cr', 'lakh', 'lakhs', 'lac', 'million', 'millions', 'billion', 'billions', 'trillion',
    'thousand', 'hundred', 'k', 'percent', 'per', '%', 'rupees', 'rupee', 'rupaye', 'rupaiye', 'rupay', 'dollars',
    'dollar', 'saal', 'sal', 'years', 'year', 'km', 'kg', 'mb', 'gb', 'bn', 'mn', 'hazaar', 'hazar', 'hajar', 'sau',
    'करोड़', 'करोड', 'लाख', 'हज़ार', 'हजार', 'सौ', 'प्रतिशत', 'रुपये', 'रुपए', 'रुपया', 'डॉलर', 'साल', 'वर्ष', 'अरब', 'खरब',
  };

  /// Big-number words: count as money/number emphasis on their own.
  static const bigNumberWords = {
    'crore', 'crores', 'lakh', 'lakhs', 'million', 'billion', 'trillion', 'करोड़', 'करोड', 'लाख', 'अरब', 'खरब',
  };

  /// Currency names that follow an amount.
  static const currencyWords = {
    'rupees', 'rupee', 'rupaye', 'rupaiye', 'rupay', 'dollars', 'dollar', 'रुपये', 'रुपए', 'रुपया', 'डॉलर',
  };

  static bool hasDigit(String w) => _digits.hasMatch(w);
  static bool isCurrencySymbol(String w) => _currencySymbol.hasMatch(w.trim());
  static bool isMoney(String w) => _money.hasMatch(w.trim());
  static bool isUnit(String w) => units.contains(normalize(w)) || w.trim() == '%';

  /// 4-digit year 1000–2099 (Latin or Devanagari digits), optionally "1990s".
  static bool isYear(String w) {
    final n = _latinDigits(normalize(w)).replaceAll(RegExp(r"s$|'s$"), '');
    if (!RegExp(r'^\d{4}$').hasMatch(n)) return false;
    final v = int.parse(n);
    return v >= 1000 && v <= 2099;
  }

  static String _latinDigits(String s) => String.fromCharCodes(s.runes.map((r) => r >= 0x0966 && r <= 0x096F ? r - 0x0966 + 0x30 : r));

  // --------------------------------------------------------------- names

  static final _title = RegExp(r"^[\p{Lu}][\p{Ll}'’.\-]+[,.!?;:]?$", unicode: true);
  static final _acronym = RegExp(r'^[A-Z][A-Z0-9&]{1,6}[,.!?;:]?$');

  /// Capitalised words that are not names.
  static const notNames = {
    'i', "i'm", 'im', "i've", "i'll", 'the', 'a', 'an', 'and', 'but', 'so', 'or', 'if', 'it', "it's", 'this', 'that',
    'these', 'those', 'he', 'she', 'we', 'they', 'you', 'my', 'our', 'his', 'her', 'their', 'what', 'when', 'where',
    'why', 'how', 'who', 'yes', 'no', 'ok', 'okay', 'in', 'on', 'at', 'of', 'to', 'for', 'from', 'with', 'by', 'then',
    'now', 'there', 'here', 'is', 'was', 'are', 'were', 'do', 'did', 'not', 'aur', 'ye', 'yeh', 'woh', 'wo', 'kya',
    'lekin', 'par', 'toh', 'phir', 'aaj', 'ab', 'jab', 'tab', 'main', 'hum', 'aap', 'tum', 'ek', 'us',
  };

  static bool isTitleCase(String w) => _title.hasMatch(w.trim()) && !notNames.contains(normalize(w));
  static bool isAcronym(String w) => _acronym.hasMatch(w.trim()) && !notNames.contains(normalize(w));

  // ------------------------------------------------------- postpositions

  /// Hindi / Hinglish particles that must not start a line (they belong to
  /// the word before: "Bharat ka", "देश में", "kiya tha").
  static const trailing = {
    'का', 'की', 'के', 'को', 'ने', 'से', 'में', 'मे', 'पर', 'तक', 'है', 'हैं', 'था', 'थी', 'थे', 'भी', 'ही', 'वाला', 'वाली',
    'वाले', 'गया', 'गई', 'गए', 'दिया', 'दी', 'लिया', 'रहा', 'रही', 'रहे', 'हो', 'जी',
    'ka', 'ki', 'ke', 'ko', 'ne', 'se', 'mein', 'mei', 'me', 'pe', 'tak', 'hai', 'hain', 'hei', 'tha', 'thi', 'bhi',
    'hi', 'wala', 'wali', 'wale', 'gaya', 'gayi', 'gaye', 'diya', 'liya', 'raha', 'rahi', 'rahe', 'ji',
  };

  static bool isTrailingParticle(String w) => trailing.contains(normalize(w));

  /// Whether a line/caption break between [a] and [b] would split something
  /// that belongs together.
  static bool glued(String a, String b) {
    if (endsSentence(a) || endsClause(a)) return false;
    // ₹ 500, Rs 20 lakh
    if (isCurrencySymbol(a) && hasDigit(b)) return true;
    // 500 crore, 20 %, 3.5 million, 1,000 rupees
    if (hasDigit(a) && (isUnit(b) || hasDigit(b))) return true;
    // "20 lakh crore", "5 trillion dollar"
    if (isUnit(a) && (bigNumberWords.contains(normalize(b)) || currencyWords.contains(normalize(b)))) return true;
    // Names: Elon Musk, Reserve Bank, RBI Governor
    if ((isTitleCase(a) || isAcronym(a)) && (isTitleCase(b) || isAcronym(b))) return true;
    // "Bharat ka", "देश में"
    if (isTrailingParticle(b)) return true;
    return false;
  }

  /// A break between [a] and [b] that must be avoided even when a glued
  /// run is too long for one line: a particle starting the line, a currency
  /// sign or a number left at the end of a line.
  static bool unbreakable(String a, String b) {
    if (endsSentence(a) || endsClause(a)) return false;
    if (isTrailingParticle(b)) return true;
    if (isCurrencySymbol(a) && hasDigit(b)) return true;
    if (hasDigit(a) && (isUnit(b) || hasDigit(b))) return true;
    return false;
  }
}
