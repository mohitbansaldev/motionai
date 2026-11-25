/// Options for automatic captions (speech → caption layers).
class CaptionOptions {
  String? language; // 'hi', 'en' or null (auto)
  bool roman; // Hinglish in Latin script

  /// Most words per caption; 0 = the style's own limit.
  int maxWords;

  /// Caption style id (see `CaptionStyles`); older names (karaoke, word_pop,
  /// plain) still work.
  String style;

  /// Highlight numbers, money, years and names automatically.
  bool emphasis;

  /// Ask the AI (one request for the whole transcript) for extra words to emphasise.
  bool aiEmphasis;

  /// Normalised words to emphasise (e.g. from the AI pass or the user).
  Set<String> emphasisWords;

  /// Move captions off other on-screen text (name tags, lower thirds).
  bool safeArea;

  /// Seconds added to every word time (fix audio/caption drift).
  double offset;

  CaptionOptions({
    this.language = 'hi',
    this.roman = false,
    this.maxWords = 0,
    this.style = 'karaoke',
    this.emphasis = true,
    this.aiEmphasis = false,
    Set<String>? emphasisWords,
    this.safeArea = true,
    this.offset = 0,
  }) : emphasisWords = emphasisWords ?? {};
}
