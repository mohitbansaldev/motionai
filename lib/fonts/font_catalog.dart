/// Bundled typefaces (assets/fonts/**, declared in pubspec `fonts:`) and the
/// rules that pick a family for a piece of text.
///
/// Pure Dart (no Flutter import) so commands, the AI and tests can use it.
/// Every family here is SIL OFL 1.1 or Apache 2.0, downloaded unmodified
/// from github.com/google/fonts; the licence sits next to each font file.
///
/// Variable fonts (`-VariableFont_wght`) rely on Flutter >= 3.41, where
/// `FontWeight` drives the `wght` axis automatically.
library;

enum FontCategory { condensed, serif, script, display, mono, sans, devanagari }

extension FontCategoryLabel on FontCategory {
  String get label => switch (this) {
        FontCategory.condensed => 'Condensed titles',
        FontCategory.serif => 'Serif',
        FontCategory.script => 'Script',
        FontCategory.display => 'Display',
        FontCategory.mono => 'Mono / typewriter',
        FontCategory.sans => 'Sans',
        FontCategory.devanagari => 'Hindi (Devanagari)',
      };
}

class FontInfo {
  /// Family name exactly as declared in pubspec.yaml (used as TextStyle.fontFamily).
  final String family;
  final FontCategory category;

  /// Scripts the font covers: 'latin' and/or 'devanagari'.
  final Set<String> scripts;
  final int minWeight;
  final int maxWeight;

  /// Folder under assets/fonts/ and the font files in it.
  final String dir;
  final List<String> files;

  /// 'OFL-1.1' or 'Apache-2.0'.
  final String license;

  /// What it is good for (shown in the picker and the AI spec).
  final String use;

  /// Family used instead when the text contains Devanagari and this font
  /// has none. Null for fonts that cover Devanagari themselves.
  final String? devanagariMatch;

  const FontInfo(
    this.family,
    this.category, {
    required this.dir,
    required this.files,
    required this.use,
    this.scripts = const {'latin'},
    this.minWeight = 400,
    this.maxWeight = 400,
    this.license = 'OFL-1.1',
    this.devanagariMatch,
  });

  bool get hasDevanagari => scripts.contains('devanagari');
  bool get isVariable => files.any((f) => f.contains('VariableFont'));
  String get licenseFile => license == 'Apache-2.0' ? 'LICENSE.txt' : 'OFL.txt';
  String get licensePath => 'assets/fonts/$dir/$licenseFile';
  List<String> get assetPaths => [for (final f in files) 'assets/fonts/$dir/$f'];

  /// Nearest weight this font really has (static fonts snap, variable clamp).
  int clampWeight(int w) => w.clamp(minWeight, maxWeight);
}

const _both = {'latin', 'devanagari'};

class FontCatalog {
  FontCatalog._();

  /// Default family for Devanagari text when no family (or an unknown one) is set.
  static const String defaultDevanagari = 'Mukta';

  static const List<FontInfo> all = [
    // ---- condensed titles (tall, bold documentary titles)
    FontInfo('Anton', FontCategory.condensed,
        dir: 'anton', files: ['Anton-Regular.ttf'], devanagariMatch: 'Teko',
        use: 'Tall heavy documentary titles, big words, title slams'),
    FontInfo('Bebas Neue', FontCategory.condensed,
        dir: 'bebasneue', files: ['BebasNeue-Regular.ttf'], devanagariMatch: 'Teko',
        use: 'All-caps condensed headlines, neon outline words'),
    FontInfo('Oswald', FontCategory.condensed,
        dir: 'oswald', files: ['Oswald-VariableFont_wght.ttf'], minWeight: 200, maxWeight: 700, devanagariMatch: 'Teko',
        use: 'News-style headlines, lower thirds, labels'),
    FontInfo('Teko', FontCategory.condensed,
        dir: 'teko', files: ['Teko-VariableFont_wght.ttf'], scripts: _both, minWeight: 300, maxWeight: 700,
        use: 'Condensed titles in Hindi and English (covers Devanagari)'),
    FontInfo('Barlow Condensed', FontCategory.condensed,
        dir: 'barlowcondensed',
        files: ['BarlowCondensed-Regular.ttf', 'BarlowCondensed-Bold.ttf', 'BarlowCondensed-Black.ttf'],
        maxWeight: 900, devanagariMatch: 'Teko',
        use: 'Clean condensed captions, stats, year rulers'),
    // ---- serif (dates, plaques, posters)
    FontInfo('Playfair Display', FontCategory.serif,
        dir: 'playfairdisplay', files: ['PlayfairDisplay-VariableFont_wght.ttf'], maxWeight: 900, devanagariMatch: 'Rozha One',
        use: 'Big serif dates and years, elegant titles'),
    FontInfo('DM Serif Display', FontCategory.serif,
        dir: 'dmserifdisplay', files: ['DMSerifDisplay-Regular.ttf'], devanagariMatch: 'Rozha One',
        use: 'High-contrast serif headings, article titles'),
    FontInfo('Cinzel', FontCategory.serif,
        dir: 'cinzel', files: ['Cinzel-VariableFont_wght.ttf'], maxWeight: 900, devanagariMatch: 'Rozha One',
        use: 'Roman capitals: history, empires, plaques, gold titles'),
    // ---- script (names, signatures)
    FontInfo('Great Vibes', FontCategory.script,
        dir: 'greatvibes', files: ['GreatVibes-Regular.ttf'], devanagariMatch: 'Kalam',
        use: 'Elegant script names under a date title, signatures'),
    FontInfo('Dancing Script', FontCategory.script,
        dir: 'dancingscript', files: ['DancingScript-VariableFont_wght.ttf'], maxWeight: 700, devanagariMatch: 'Kalam',
        use: 'Friendly handwritten names and notes'),
    // ---- display
    FontInfo('Permanent Marker', FontCategory.display,
        dir: 'permanentmarker', files: ['PermanentMarker-Regular.ttf'], license: 'Apache-2.0', devanagariMatch: 'Kalam',
        use: 'Marker scribbles, hand-written callouts on photos'),
    // V3-D >>>
    FontInfo('Comic Neue', FontCategory.display,
        dir: 'comicneue', files: ['ComicNeue-Regular.ttf', 'ComicNeue-Bold.ttf'], maxWeight: 700, devanagariMatch: 'Baloo 2',
        use: 'Comic speech bubbles for dialogue, playful captions'),
    // <<< V3-D
    // ---- mono / typewriter
    FontInfo('Special Elite', FontCategory.mono,
        dir: 'specialelite', files: ['SpecialElite-Regular.ttf'], license: 'Apache-2.0', devanagariMatch: 'Noto Sans Devanagari',
        use: 'Old typewriter: case files, letters, classified documents'),
    FontInfo('Roboto Mono', FontCategory.mono,
        dir: 'robotomono', files: ['RobotoMono-VariableFont_wght.ttf'], minWeight: 100, maxWeight: 700,
        devanagariMatch: 'Noto Sans Devanagari',
        use: 'Code, data readouts, scramble/decode text'),
    // ---- sans
    FontInfo('Inter', FontCategory.sans,
        dir: 'inter', files: ['Inter-VariableFont_opsz_wght.ttf'], minWeight: 100, maxWeight: 900, devanagariMatch: 'Mukta',
        use: 'Neutral UI-style text, subtitles, source cards'),
    FontInfo('Montserrat', FontCategory.sans,
        dir: 'montserrat', files: ['Montserrat-VariableFont_wght.ttf'], minWeight: 100, maxWeight: 900, devanagariMatch: 'Mukta',
        use: 'Wide geometric titles, YouTube-style captions'),
    FontInfo('Poppins', FontCategory.sans,
        dir: 'poppins', files: ['Poppins-Regular.ttf', 'Poppins-Bold.ttf', 'Poppins-Black.ttf'], scripts: _both, maxWeight: 900,
        use: 'Bold captions in Hinglish (covers Devanagari)'),
    // ---- Devanagari (all also cover Latin)
    FontInfo('Noto Sans Devanagari', FontCategory.devanagari,
        dir: 'notosansdevanagari', files: ['NotoSansDevanagari-VariableFont_wdth_wght.ttf'], scripts: _both,
        minWeight: 100, maxWeight: 900,
        use: 'Plain, very complete Hindi text (fallback of last resort)'),
    FontInfo('Hind', FontCategory.devanagari,
        dir: 'hind', files: ['Hind-Regular.ttf', 'Hind-Bold.ttf'], scripts: _both, maxWeight: 700,
        use: 'Readable Hindi subtitles and body text'),
    FontInfo('Mukta', FontCategory.devanagari,
        dir: 'mukta', files: ['Mukta-Regular.ttf', 'Mukta-Bold.ttf', 'Mukta-ExtraBold.ttf'], scripts: _both, maxWeight: 800,
        use: 'Clean bold Hindi captions and labels (default Hindi font)'),
    FontInfo('Baloo 2', FontCategory.devanagari,
        dir: 'baloo2', files: ['Baloo2-VariableFont_wght.ttf'], scripts: _both, maxWeight: 800,
        use: 'Rounded friendly Hindi titles, explainer style'),
    FontInfo('Rozha One', FontCategory.devanagari,
        dir: 'rozhaone', files: ['RozhaOne-Regular.ttf'], scripts: _both,
        use: 'Heavy high-contrast Hindi serif headlines (newspaper look)'),
    FontInfo('Yatra One', FontCategory.devanagari,
        dir: 'yatraone', files: ['YatraOne-Regular.ttf'], scripts: _both,
        use: 'Brush-style Hindi display titles, festive/cultural'),
    FontInfo('Kalam', FontCategory.devanagari,
        dir: 'kalam', files: ['Kalam-Regular.ttf', 'Kalam-Bold.ttf'], scripts: _both, maxWeight: 700,
        use: 'Handwritten Hindi notes and names'),
  ];

  /// Generic names (older projects, components) → bundled family.
  static const Map<String, String> aliases = {
    'serif': 'Playfair Display',
    'sans': 'Inter',
    'sans-serif': 'Inter',
    'sansserif': 'Inter',
    'monospace': 'Roboto Mono',
    'mono': 'Roboto Mono',
    'typewriter': 'Special Elite',
    'script': 'Great Vibes',
    'cursive': 'Dancing Script',
    'handwriting': 'Dancing Script',
    'marker': 'Permanent Marker',
    'comic': 'Comic Neue', // V3-D
    'condensed': 'Anton',
    'display': 'Anton',
    'title': 'Anton',
    'hindi': 'Mukta',
    'devanagari': 'Mukta',
  };

  static final Map<String, FontInfo> _byKey = {for (final f in all) _key(f.family): f};

  static String _key(String s) => s.toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');

  static List<String> get families => [for (final f in all) f.family];

  static List<FontInfo> byCategory(FontCategory c) => [for (final f in all) if (f.category == c) f];

  /// The catalog entry for a family name or alias (case/space-insensitive:
  /// "anton", "Bebas_Neue", "playfair-display", "serif"), or null.
  static FontInfo? lookup(String? name) {
    if (name == null) return null;
    final k = _key(name);
    if (k.isEmpty) return null;
    final direct = _byKey[k];
    if (direct != null) return direct;
    final alias = aliases[name.trim().toLowerCase()] ?? aliases[k];
    return alias == null ? null : _byKey[_key(alias)];
  }

  /// True if [text] contains Devanagari letters (Hindi, Marathi, ...).
  static bool hasDevanagari(String text) {
    for (final r in text.runes) {
      if ((r >= 0x0900 && r <= 0x097F) || (r >= 0xA8E0 && r <= 0xA8FF) || (r >= 0x1CD0 && r <= 0x1CFF)) return true;
    }
    return false;
  }

  /// Family to render [text] with when the layer asks for [family].
  ///
  /// - bundled family / alias → its exact pubspec name;
  /// - text has Devanagari and the font has none → its Devanagari match
  ///   (all matches also cover Latin, so Hinglish stays in one family);
  /// - no family and Devanagari text → [defaultDevanagari];
  /// - unknown names are passed through (system fonts keep working).
  static String? resolve(String? family, String text) {
    final info = lookup(family);
    final deva = hasDevanagari(text);
    if (info == null) {
      if (deva && (family == null || family.trim().isEmpty)) return defaultDevanagari;
      return (family == null || family.trim().isEmpty) ? null : family;
    }
    if (deva && !info.hasDevanagari) return devanagariFor(info.family);
    return info.family;
  }

  /// The Devanagari family that best matches [family]'s style.
  static String devanagariFor(String? family) {
    final info = lookup(family);
    if (info == null) return defaultDevanagari;
    if (info.hasDevanagari) return info.family;
    return info.devanagariMatch ?? _categoryMatch[info.category] ?? defaultDevanagari;
  }

  static const Map<FontCategory, String> _categoryMatch = {
    FontCategory.condensed: 'Teko',
    FontCategory.serif: 'Rozha One',
    FontCategory.script: 'Kalam',
    FontCategory.display: 'Baloo 2',
    FontCategory.mono: 'Noto Sans Devanagari',
    FontCategory.sans: 'Mukta',
  };

  /// Per-glyph fallback list for TextStyle.fontFamilyFallback: the matching
  /// Devanagari family, then Noto Sans Devanagari (covers everything).
  static List<String> fallbackFor(String? family) {
    final m = devanagariFor(family);
    return m == 'Noto Sans Devanagari' ? const ['Noto Sans Devanagari'] : [m, 'Noto Sans Devanagari'];
  }

  /// Error-friendly suggestion list for an unknown name.
  static List<String> suggestions(String name, {int max = 5}) {
    final k = _key(name);
    if (k.isEmpty) return families.take(max).toList();
    final hits = [
      for (final f in all)
        if (_key(f.family).contains(k) || k.contains(_key(f.family)) || _key(f.family).startsWith(k.substring(0, 1))) f.family,
    ];
    return hits.take(max).toList();
  }

  /// Case-insensitive search over family, category, use and scripts
  /// ("hindi", "serif", "date", "neon").
  static List<FontInfo> search(String q) {
    final s = q.trim().toLowerCase();
    if (s.isEmpty) return all;
    return [
      for (final f in all)
        if (f.family.toLowerCase().contains(s) ||
            f.category.name.contains(s) ||
            f.category.label.toLowerCase().contains(s) ||
            f.use.toLowerCase().contains(s) ||
            ((s == 'hindi' || s == 'devanagari') && f.hasDevanagari))
          f,
    ];
  }
}
