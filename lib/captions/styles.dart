/// Data-driven caption looks (karaoke, word pop, MrBeast punch, neon…).
///
/// Every style is plain data. [CaptionBuilder] turns a style + captions into
/// ordinary edit commands (text layers, effects, keyframes), so styles need
/// nothing new from the renderer.
library;

/// How words appear over time.
enum CaptionTiming {
  /// The whole caption appears at once (with the style's animator).
  cue,

  /// Renderer karaoke: the spoken word is highlighted from per-word timings.
  karaoke,

  /// Word pop / fade spread so each word lands about when it is spoken.
  spread,

  /// Typewriter that finishes when the last word is spoken.
  typeOn,

  /// Per-letter animator (random_pop / scramble) over a short intro.
  glyph,
}

/// How emphasised words are shown.
enum EmphasisLook {
  none,

  /// The word turns [CaptionStyle.emphasisColor] when it is spoken.
  color,

  /// The caption punches in (scale pulse) when the word is spoken.
  pulse,

  /// Both.
  colorPulse,
}

/// Font families by script, first available wins (see [CaptionFonts]).
class CaptionFontSet {
  final List<String> latin;
  final List<String> devanagari;
  const CaptionFontSet(this.latin, [this.devanagari = CaptionFonts.devanagariDefault]);
}

/// Picks a font family from a fallback list. The font catalog (fonts
/// branch) can set [available] to the families bundled with the app; when
/// it is null the first family is used (Flutter falls back to the system
/// font for missing families, so a missing font never breaks rendering).
class CaptionFonts {
  static Set<String>? available;
  static const devanagariDefault = ['Noto Sans Devanagari', 'Mukta', 'Hind', 'Poppins'];

  static String? pick(List<String> families) {
    if (families.isEmpty) return null;
    final a = available;
    if (a == null) return families.first;
    for (final f in families) {
      if (a.contains(f)) return f;
    }
    return null;
  }
}

class CaptionStyle {
  final String id;
  final String label;
  final String description;
  final CaptionFontSet fonts;
  final int weight;

  /// Font size as a fraction of the frame's short side, horizontal and vertical (9:16) frames.
  final double sizeH, sizeV;

  /// Extra size for Devanagari text (its letters look smaller).
  final double devanagariScale;

  /// bottom | center | lower (just above the bottom edge).
  final String position;
  final String color;
  final String highlightColor;
  final String emphasisColor;
  final EmphasisLook emphasis;

  /// Scale (%) of the emphasis pulse.
  final double pulseScale;

  /// Background box per line, e.g. '#E6000000'; null = none.
  final String? box;
  final bool softShadow;

  /// Outline stroke around filled text (px at 1080p short side; 0 = none) and colour.
  final double stroke;
  final String strokeColor;

  /// Hollow outline text width (TextData.outline; 0 = filled).
  final double hollow;

  /// Glow effect amount 0–100 (0 = none) and radius.
  final double glow, glowRadius;

  /// Drop shadow effect (hard offset shadow for punchy styles).
  final bool dropShadow;

  /// TextData animator and how word timing drives it.
  final String animator;
  final CaptionTiming timing;
  final double animDuration;

  /// Scale bounce when each caption appears.
  final bool bounce;
  final bool uppercase;
  final int maxWords;
  final int maxLines;

  /// Most characters per line, also limited by the frame width.
  final double maxLineChars;

  /// Roman (Hinglish) or Devanagari script preference: 'any' | 'roman' | 'devanagari'.
  final String script;

  const CaptionStyle({
    required this.id,
    required this.label,
    this.description = '',
    this.fonts = const CaptionFontSet(['Montserrat', 'Poppins']),
    this.weight = 800,
    this.sizeH = 0.062,
    this.sizeV = 0.075,
    this.devanagariScale = 1.1,
    this.position = 'bottom',
    this.color = '#FFFFFF',
    this.highlightColor = '#FFD54F',
    this.emphasisColor = '#FFD54F',
    this.emphasis = EmphasisLook.color,
    this.pulseScale = 108,
    this.box,
    this.softShadow = true,
    this.stroke = 0,
    this.strokeColor = '#000000',
    this.hollow = 0,
    this.glow = 0,
    this.glowRadius = 18,
    this.dropShadow = false,
    this.animator = 'none',
    this.timing = CaptionTiming.cue,
    this.animDuration = 0.3,
    this.bounce = false,
    this.uppercase = false,
    this.maxWords = 4,
    this.maxLines = 2,
    this.maxLineChars = 26,
    this.script = 'any',
  });

  /// Renderer paths that need one layer per line to control line breaks
  /// (word animators lay words out in a Wrap) or to draw one box per line.
  bool get layerPerLine => box != null || const ['karaoke', 'word_pop', 'fade_up'].contains(animator);

  /// Colour marks are drawn by the marked-text painter, which skips word
  /// animators, per-letter animators and the background box.
  bool get colorMarks =>
      (emphasis == EmphasisLook.color || emphasis == EmphasisLook.colorPulse) &&
      box == null &&
      hollow <= 0 &&
      const ['none', 'fade_up', 'slide_up'].contains(animator);

  bool get pulses => emphasis == EmphasisLook.pulse || emphasis == EmphasisLook.colorPulse || (emphasis == EmphasisLook.color && !colorMarks);
}

class CaptionStyles {
  static const karaoke = CaptionStyle(
    id: 'karaoke',
    label: 'Karaoke',
    description: 'White words, the spoken word turns yellow',
    fonts: CaptionFontSet(['Montserrat', 'Poppins', 'Inter']),
    weight: 800,
    animator: 'karaoke',
    timing: CaptionTiming.karaoke,
    emphasis: EmphasisLook.pulse,
    maxWords: 4,
  );

  static const wordPop = CaptionStyle(
    id: 'word_pop',
    label: 'Word pop',
    description: 'Each word pops in as it is said',
    fonts: CaptionFontSet(['Poppins', 'Montserrat']),
    weight: 800,
    animator: 'word_pop',
    timing: CaptionTiming.spread,
    emphasis: EmphasisLook.pulse,
    maxWords: 4,
  );

  static const keyword = CaptionStyle(
    id: 'keyword',
    label: 'Yellow keyword',
    description: 'Bold white, key words light up yellow',
    fonts: CaptionFontSet(['Montserrat', 'Poppins']),
    weight: 900,
    sizeH: 0.066,
    sizeV: 0.08,
    emphasisColor: '#FFD400',
    emphasis: EmphasisLook.colorPulse,
    animator: 'fade_up',
    timing: CaptionTiming.cue,
    stroke: 4,
    maxWords: 5,
  );

  static const boxed = CaptionStyle(
    id: 'boxed',
    label: 'Boxed',
    description: 'Black box behind each line',
    fonts: CaptionFontSet(['Inter', 'Roboto', 'Poppins']),
    weight: 700,
    sizeH: 0.052,
    sizeV: 0.062,
    box: '#E6000000',
    softShadow: false,
    animator: 'slide_up',
    animDuration: 0.25,
    emphasis: EmphasisLook.pulse,
    pulseScale: 104,
    maxWords: 7,
    maxLineChars: 32,
  );

  static const neon = CaptionStyle(
    id: 'neon',
    label: 'Neon',
    description: 'Glowing outline letters',
    fonts: CaptionFontSet(['Bebas Neue', 'Oswald', 'Anton']),
    weight: 700,
    sizeH: 0.08,
    sizeV: 0.095,
    color: '#00E5FF',
    emphasisColor: '#FF2BD6',
    emphasis: EmphasisLook.pulse,
    hollow: 3,
    glow: 85,
    glowRadius: 16,
    softShadow: false,
    uppercase: true,
    animator: 'random_pop',
    timing: CaptionTiming.glyph,
    animDuration: 0.45,
    maxWords: 3,
    maxLines: 2,
    maxLineChars: 18,
  );

  static const punchy = CaptionStyle(
    id: 'punchy',
    label: 'MrBeast punch',
    description: 'Huge 1–3 words with a bounce',
    fonts: CaptionFontSet(['Anton', 'Bebas Neue', 'Montserrat']),
    weight: 900,
    sizeH: 0.11,
    sizeV: 0.13,
    position: 'center',
    emphasisColor: '#4CFF3F',
    emphasis: EmphasisLook.colorPulse,
    pulseScale: 112,
    stroke: 9,
    dropShadow: true,
    softShadow: false,
    uppercase: true,
    bounce: true,
    animator: 'none',
    maxWords: 3,
    maxLines: 1,
    maxLineChars: 14,
  );

  static const typewriter = CaptionStyle(
    id: 'typewriter',
    label: 'Typewriter',
    description: 'Types on with the voice',
    fonts: CaptionFontSet(['Courier Prime', 'Roboto Mono', 'monospace']),
    weight: 700,
    sizeH: 0.05,
    sizeV: 0.06,
    animator: 'typewriter',
    timing: CaptionTiming.typeOn,
    emphasis: EmphasisLook.none,
    maxWords: 6,
    maxLineChars: 30,
  );

  static const minimal = CaptionStyle(
    id: 'minimal',
    label: 'Minimal',
    description: 'Small clean subtitle at the bottom',
    fonts: CaptionFontSet(['Inter', 'Roboto']),
    weight: 600,
    sizeH: 0.04,
    sizeV: 0.05,
    position: 'lower',
    emphasisColor: '#FFE082',
    emphasis: EmphasisLook.color,
    animator: 'fade_up',
    animDuration: 0.2,
    maxWords: 8,
    maxLineChars: 42,
  );

  static const hinglish = CaptionStyle(
    id: 'hinglish',
    label: 'Hinglish',
    description: 'Roman-script Hindi, bold with yellow key words',
    fonts: CaptionFontSet(['Poppins', 'Montserrat']),
    weight: 800,
    sizeH: 0.062,
    sizeV: 0.076,
    emphasisColor: '#FFC400',
    emphasis: EmphasisLook.colorPulse,
    animator: 'fade_up',
    stroke: 3,
    maxWords: 5,
    script: 'roman',
  );

  static const devanagari = CaptionStyle(
    id: 'devanagari',
    label: 'देवनागरी',
    description: 'Hindi in Devanagari with word highlight',
    fonts: CaptionFontSet(['Noto Sans Devanagari', 'Mukta', 'Hind'], ['Noto Sans Devanagari', 'Mukta', 'Hind']),
    weight: 700,
    sizeH: 0.064,
    sizeV: 0.078,
    devanagariScale: 1.0,
    highlightColor: '#FFC400',
    animator: 'karaoke',
    timing: CaptionTiming.karaoke,
    emphasis: EmphasisLook.pulse,
    maxWords: 4,
    script: 'devanagari',
  );

  static const decode = CaptionStyle(
    id: 'decode',
    label: 'Decode',
    description: 'Letters scramble, then settle',
    fonts: CaptionFontSet(['Roboto Mono', 'Courier Prime', 'monospace']),
    weight: 800,
    sizeH: 0.056,
    sizeV: 0.068,
    color: '#B9FF66',
    emphasis: EmphasisLook.pulse,
    animator: 'scramble',
    timing: CaptionTiming.glyph,
    animDuration: 0.5,
    uppercase: true,
    maxWords: 4,
    maxLineChars: 22,
  );

  static const all = [karaoke, wordPop, keyword, boxed, neon, punchy, typewriter, minimal, hinglish, devanagari, decode];

  /// Older style names stay valid.
  static const aliases = {'plain': 'boxed', 'mrbeast': 'punchy', 'yellow': 'keyword', 'hindi': 'devanagari', 'roman': 'hinglish'};

  static CaptionStyle byId(String? id) {
    final key = aliases[id] ?? id;
    for (final s in all) {
      if (s.id == key) return s;
    }
    return karaoke;
  }

  static List<String> get ids => [for (final s in all) s.id];
}
