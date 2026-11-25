import 'dart:math' as math;

/// V3-C: timing maths for the documentary text animators (pure Dart, used by
/// the renderer in lib/ui/preview/fx/text_fx_v3.dart and by tests).
///
/// All times are seconds since the text layer started ([local]); [duration]
/// is the layer's `anim_duration`. Every curve is eased (no linear jerks) and
/// every letter/word reaches exactly its resting state by the end.
class TextV3 {
  TextV3._();

  /// Animators drawn by the V3 painter.
  static const animators = {'typewriter_soft', 'letter_drop', 'word_fade_grey'};

  /// Per-letter fade time of `typewriter_soft` (opacity 0→1 + blur 8→0).
  static const softFade = 0.12;

  /// Blur radius (px) a `typewriter_soft` letter starts with.
  static const softBlur = 8.0;

  /// Default `letter_drop` stagger and per-letter drop time.
  static const dropStagger = 0.08;
  static const dropTime = 0.38;

  /// `word_fade_grey`: grey → final colour time per word.
  static const wordFade = 0.2;

  /// Default grey of words not spoken yet.
  static const dimGrey = 0xFF8A8A8A;

  static double _clamp01(double v) => v.isNaN ? 0 : v.clamp(0.0, 1.0).toDouble();

  static double easeOutCubic(double t) {
    final u = 1 - _clamp01(t);
    return 1 - u * u * u;
  }

  static double easeInOut(double t) {
    final x = _clamp01(t);
    return x * x * (3 - 2 * x);
  }

  /// Back ease-out with a small overshoot ([s] 1.0 ≈ 6 %).
  static double backOut(double t, [double s = 1.2]) {
    final u = _clamp01(t) - 1;
    return 1 + u * u * ((s + 1) * u + s);
  }

  /// Start time of letter [i] of [n] when the letters are spread over [span] s.
  static double spread(int i, int n, double span) => n <= 1 ? 0 : math.max(0.0, span) * i / (n - 1);

  /// typewriter_soft: (opacity 0..1, blur px) of letter [i] of [n].
  static (double, double) soft(int i, int n, double local, double duration) {
    final fade = math.min(softFade, math.max(0.02, duration * 0.5));
    final t0 = spread(i, n, duration - fade);
    final q = easeOutCubic((local - t0) / fade);
    return (q, softBlur * (1 - q));
  }

  /// letter_drop: stagger for [n] letters inside [duration] (max 0.08 s).
  static double dropStaggerFor(int n, double duration) =>
      n <= 1 ? 0 : math.min(dropStagger, math.max(0.0, duration - dropTime) / (n - 1));

  /// letter_drop: (opacity 0..1, y offset in font sizes, negative = above)
  /// of letter [i] of [n]. Drops from 1.1 font sizes above with a small
  /// bounce below the line, then settles.
  static (double, double) drop(int i, int n, double local, double duration) {
    final t0 = i * dropStaggerFor(n, duration);
    final q = _clamp01((local - t0) / dropTime);
    if (q <= 0) return (0, -1.1);
    final y = -1.1 * (1 - backOut(q, 1.6));
    return (easeOutCubic(q / 0.35), q >= 1 ? 0 : y);
  }

  /// word_fade_grey: 0 (grey) → 1 (final colour) for word [i] of [n].
  /// [wordTimes] (s after the layer start) wins over an even spread of the
  /// words across [duration].
  static double wordLevel(int i, int n, double local, double duration, List<double> wordTimes) {
    final t0 = i < wordTimes.length ? wordTimes[i] : spread(i, n, math.max(0.0, duration - wordFade));
    return easeInOut((local - t0) / wordFade);
  }

  /// When every word of a word_fade_grey layer has reached its colour.
  static double wordsDone(int n, double duration, List<double> wordTimes) {
    var last = n <= 0 ? 0.0 : spread(n - 1, n, math.max(0.0, duration - wordFade));
    for (final t in wordTimes) {
      last = math.max(last, t);
    }
    return last + wordFade;
  }

  /// typewriter (hard reveal) with a lead colour: letters shown and how many
  /// of the newest are in the lead colour. Letter k appears at k/n·duration
  /// (same pace as the plain typewriter) and stays lead-coloured while the
  /// next [leadChars] letters are typed (also after the last one).
  static (int shown, int leadFrom) lead(int n, double local, double duration, int leadChars) {
    if (n <= 0) return (0, 0);
    final p = duration <= 0 ? 1.0 : _clamp01(local / duration);
    final shown = (n * p).round().clamp(0, n);
    if (leadChars <= 0) return (shown, shown);
    final per = duration <= 0 ? 0.0 : duration / n;
    // letters typed within the last leadChars·per seconds keep the lead colour
    var from = shown;
    for (int k = shown - 1; k >= 0; k--) {
      final appear = duration <= 0 ? 0.0 : (k + 0.5) / n * duration;
      if (local - appear < leadChars * per) {
        from = k;
      } else {
        break;
      }
    }
    return (shown, from);
  }

  /// Time after which the animator no longer changes the picture.
  static double settleTime(String animator, int letters, int words, double duration, int leadChars, List<double> wordTimes) {
    switch (animator) {
      case 'typewriter_soft':
        return duration + 0.02;
      case 'letter_drop':
        return (letters - 1).clamp(0, 1 << 20) * dropStaggerFor(letters, duration) + dropTime + 0.02;
      case 'word_fade_grey':
        return wordsDone(words, duration, wordTimes) + 0.02;
      case 'typewriter':
        final per = letters <= 0 ? 0.0 : duration / letters;
        return duration + leadChars * per + 0.05;
      default:
        return duration + 0.06;
    }
  }

  /// Word ranges ([start, end) code-unit offsets) of [text]: runs of non-space.
  static List<(int, int)> wordRanges(String text) => [for (final m in RegExp(r'\S+').allMatches(text)) (m.start, m.end)];
}
