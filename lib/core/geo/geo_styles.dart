// win-40: premium map style presets for geo layers.

class GeoStyle {
  final String id, label;
  final int ocean, ocean2; // radial gradient centre → edge
  final int land, land2; // land fill (top → bottom shade)
  final int border; // country borders
  final int coast; // coast glow colour (0 = none)
  final double coastGlow; // px blur of the coast glow
  final int graticule;
  final int highlight, highlightStroke, glow;
  final int labelColor, labelShadow;
  final int dimmed; // land colour of non-highlighted countries when dimOthers
  final String texture; // none | satellite | paper | grid | dots | scan
  final double textureOpacity;
  final int atmosphere; // globe rim glow
  final double vignette; // 0..1
  final bool landStroke; // outline the whole land mass

  const GeoStyle({
    required this.id,
    required this.label,
    required this.ocean,
    required this.ocean2,
    required this.land,
    required this.land2,
    required this.border,
    this.coast = 0,
    this.coastGlow = 0,
    required this.graticule,
    required this.highlight,
    required this.highlightStroke,
    required this.glow,
    this.labelColor = 0xFFFFFFFF,
    this.labelShadow = 0xCC000000,
    required this.dimmed,
    this.texture = 'none',
    this.textureOpacity = 1,
    this.atmosphere = 0xFF6FB7FF,
    this.vignette = 0.5,
    this.landStroke = false,
  });
}

class GeoStyles {
  static const all = <GeoStyle>[
    GeoStyle(
        id: 'dark_political', label: 'Dark Political', ocean: 0xFF0E1B2A, ocean2: 0xFF060B12, land: 0xFF2A3442, land2: 0xFF1D2531,
        border: 0x99C8D3E0, coast: 0xFF2E6FA8, coastGlow: 10, graticule: 0x1AFFFFFF, highlight: 0xFFD0202A, highlightStroke: 0xFFFFE2D6,
        glow: 0xFFFF3B30, dimmed: 0xFF1A2029),
    GeoStyle(
        id: 'satellite', label: 'Satellite Relief', ocean: 0xFF0B2233, ocean2: 0xFF03101A, land: 0xFF3B4636, land2: 0xFF2A3127,
        border: 0xB3F1E6CF, coast: 0x8037A0C8, coastGlow: 8, graticule: 0x14FFFFFF, highlight: 0xCCD0202A, highlightStroke: 0xFFFFF1E0,
        glow: 0xFFFF4A3A, dimmed: 0xFF20271F, texture: 'satellite', atmosphere: 0xFF7EC8FF),
    GeoStyle(
        id: 'paper_vintage', label: 'Paper Vintage', ocean: 0xFFCDBB95, ocean2: 0xFFA99470, land: 0xFFEADBB8, land2: 0xFFD9C59C,
        border: 0x99694F33, coast: 0x66694F33, coastGlow: 3, graticule: 0x33694F33, highlight: 0xFFB0302A, highlightStroke: 0xFF4A2A18,
        glow: 0xFFB0302A, labelColor: 0xFF2E1C10, labelShadow: 0x33FFF6E0, dimmed: 0xFFD9CBAA, texture: 'paper', vignette: 0.6, landStroke: true,
        atmosphere: 0xFFF2DFB4),
    GeoStyle(
        id: 'blueprint', label: 'Blueprint', ocean: 0xFF0D3B78, ocean2: 0xFF072650, land: 0x330D3B78, land2: 0x220D3B78,
        border: 0xCCBFE2FF, coast: 0xFFBFE2FF, coastGlow: 2, graticule: 0x40BFE2FF, highlight: 0x66FFFFFF, highlightStroke: 0xFFFFFFFF,
        glow: 0xFFBFE2FF, dimmed: 0x220D3B78, texture: 'grid', landStroke: true, atmosphere: 0xFF9FD0FF),
    GeoStyle(
        id: 'neon', label: 'Neon Night', ocean: 0xFF070712, ocean2: 0xFF020206, land: 0xFF101024, land2: 0xFF0A0A18,
        border: 0xCC00E5FF, coast: 0xFF00E5FF, coastGlow: 14, graticule: 0x2200E5FF, highlight: 0xCCFF2BD6, highlightStroke: 0xFFFFB6F2,
        glow: 0xFFFF2BD6, dimmed: 0xFF0B0B1A, atmosphere: 0xFF00E5FF, vignette: 0.65, landStroke: true),
    GeoStyle(
        id: 'clean_light', label: 'Clean Light', ocean: 0xFFE9EEF3, ocean2: 0xFFD6DEE7, land: 0xFFFFFFFF, land2: 0xFFF3F5F7,
        border: 0xFFB9C4D0, coast: 0x00000000, graticule: 0x14000000, highlight: 0xFF2563EB, highlightStroke: 0xFF1E3A8A,
        glow: 0xFF60A5FA, labelColor: 0xFF111827, labelShadow: 0x22FFFFFF, dimmed: 0xFFF1F3F6, vignette: 0.15, atmosphere: 0xFFBFD7FF),
    GeoStyle(
        id: 'newsprint', label: 'Newsprint Ink', ocean: 0xFFE8E4DA, ocean2: 0xFFD8D2C4, land: 0xFF9A968E, land2: 0xFF86827A,
        border: 0xFFE8E4DA, graticule: 0x22000000, highlight: 0xFF111111, highlightStroke: 0xFF000000, glow: 0xFF333333,
        labelColor: 0xFF111111, labelShadow: 0x00000000, dimmed: 0xFFB5B0A6, texture: 'dots', vignette: 0.25),
    GeoStyle(
        id: 'documentary_gold', label: 'Documentary Gold', ocean: 0xFF111316, ocean2: 0xFF050607, land: 0xFF2C2B28, land2: 0xFF1E1D1B,
        border: 0x99E9C46A, coast: 0x66E9C46A, coastGlow: 8, graticule: 0x12E9C46A, highlight: 0xFFE9C46A, highlightStroke: 0xFFFFF3C4,
        glow: 0xFFFFC94A, dimmed: 0xFF19191A, atmosphere: 0xFFFFD27A, vignette: 0.6),
    GeoStyle(
        id: 'night_lights', label: 'Night Lights', ocean: 0xFF02060D, ocean2: 0xFF000103, land: 0xFF0B1220, land2: 0xFF060B14,
        border: 0x553A5A80, coast: 0xFF1E4A7A, coastGlow: 12, graticule: 0x0FFFFFFF, highlight: 0xCCFFB547, highlightStroke: 0xFFFFE0A3,
        glow: 0xFFFFB547, dimmed: 0xFF070C16, texture: 'satellite', textureOpacity: 0.35, atmosphere: 0xFF4C8DFF, vignette: 0.7),
    GeoStyle(
        id: 'hologram', label: 'Hologram HUD', ocean: 0xFF001014, ocean2: 0xFF000507, land: 0x2200FFC8, land2: 0x1100FFC8,
        border: 0xCC00FFC8, coast: 0xFF00FFC8, coastGlow: 10, graticule: 0x3300FFC8, highlight: 0x66FF3B3B, highlightStroke: 0xFFFF6B6B,
        glow: 0xFFFF3B3B, labelColor: 0xFFB8FFF0, dimmed: 0x0A00FFC8, texture: 'scan', atmosphere: 0xFF00FFC8, landStroke: true),
    GeoStyle(
        id: 'clay', label: 'Clay 3D', ocean: 0xFF8FB8C9, ocean2: 0xFF6F9AAD, land: 0xFFEFE6DA, land2: 0xFFD8CDBE,
        border: 0xFFFFFFFF, graticule: 0x00000000, highlight: 0xFFE76F51, highlightStroke: 0xFFFFFFFF, glow: 0x00000000,
        labelColor: 0xFF2B2B2B, labelShadow: 0x33FFFFFF, dimmed: 0xFFE4DCD1, vignette: 0.2, atmosphere: 0xFFDDEEFF),
    GeoStyle(
        id: 'military', label: 'Military Ops', ocean: 0xFF161A14, ocean2: 0xFF0A0C09, land: 0xFF3A4130, land2: 0xFF2C3224,
        border: 0x99B8C79A, coast: 0x55B8C79A, coastGlow: 4, graticule: 0x26B8C79A, highlight: 0xCCB23A2E, highlightStroke: 0xFFF0D9A0,
        glow: 0xFFFF5A3C, labelColor: 0xFFE9E2C6, dimmed: 0xFF262B20, texture: 'grid', vignette: 0.6, atmosphere: 0xFFB8C79A),
    // win-43 >>> cinematic map styles
    GeoStyle(
        id: 'obsidian_gold', label: 'Obsidian Gold', ocean: 0xFF0B0D10, ocean2: 0xFF030405, land: 0xFF1F2022, land2: 0xFF151618,
        border: 0x88E2B65D, coast: 0xAAE2B65D, coastGlow: 12, graticule: 0x0CE2B65D, highlight: 0xFFE2B65D, highlightStroke: 0xFFFFF0C8,
        glow: 0xFFF4D592, labelColor: 0xFFF6EBD2, dimmed: 0xFF141517, atmosphere: 0xFFE2B65D, vignette: 0.72, landStroke: true),
    GeoStyle(
        id: 'terrain', label: 'Terrain Atlas', ocean: 0xFF2D5670, ocean2: 0xFF14324A, land: 0xFF6E7B52, land2: 0xFF4F5A3A,
        border: 0xB3F3EAD5, coast: 0x8CD7EEF7, coastGlow: 5, graticule: 0x14FFFFFF, highlight: 0xCCC8452E, highlightStroke: 0xFFFFF3DF,
        glow: 0xFFFF6A45, labelColor: 0xFFFFFCF2, dimmed: 0xFF55603F, texture: 'satellite', textureOpacity: 0.8, atmosphere: 0xFF9AD1FF, vignette: 0.45),
    GeoStyle(
        id: 'war_room', label: 'War Room', ocean: 0xFF0A0606, ocean2: 0xFF020101, land: 0xFF241A18, land2: 0xFF160F0E,
        border: 0x99FF5A47, coast: 0xCCFF3B2B, coastGlow: 10, graticule: 0x1AFF5A47, highlight: 0xCCFF2A1C, highlightStroke: 0xFFFFD2C8,
        glow: 0xFFFF2A1C, labelColor: 0xFFFFE6DF, dimmed: 0xFF120B0A, texture: 'scan', textureOpacity: 0.6, atmosphere: 0xFFFF4A3A, vignette: 0.75, landStroke: true),
    GeoStyle(
        id: 'cinematic_teal', label: 'Cinematic Teal', ocean: 0xFF06222A, ocean2: 0xFF010B0E, land: 0xFF2E3A36, land2: 0xFF1F2825,
        border: 0x99F2C49B, coast: 0xAA3FC1C9, coastGlow: 12, graticule: 0x0F3FC1C9, highlight: 0xFFF28C38, highlightStroke: 0xFFFFE3C9,
        glow: 0xFFFFA14F, labelColor: 0xFFFFF4EA, dimmed: 0xFF19211F, texture: 'satellite', textureOpacity: 0.45, atmosphere: 0xFF3FC1C9, vignette: 0.65),
    GeoStyle(
        id: 'arctic_white', label: 'Arctic White', ocean: 0xFFBFD3E1, ocean2: 0xFF93AFC4, land: 0xFFF7FAFC, land2: 0xFFE3EBF1,
        border: 0xFF9DB2C3, coast: 0x6693AFC4, coastGlow: 6, graticule: 0x1A2B4A66, highlight: 0xFF1F5FAF, highlightStroke: 0xFF0D2E57,
        glow: 0xFF5C9BEB, labelColor: 0xFF0F2236, labelShadow: 0x22FFFFFF, dimmed: 0xFFE9EFF4, vignette: 0.25, atmosphere: 0xFFFFFFFF),
    GeoStyle(
        id: 'old_atlas', label: 'Old Atlas', ocean: 0xFF9FB2A4, ocean2: 0xFF7D9183, land: 0xFFE6D3AA, land2: 0xFFCDB585,
        border: 0xCC7A4E2B, coast: 0x887A4E2B, coastGlow: 4, graticule: 0x447A4E2B, highlight: 0xFFA3331F, highlightStroke: 0xFF3B1D0E,
        glow: 0xFFA3331F, labelColor: 0xFF2A170A, labelShadow: 0x22FFF4D8, dimmed: 0xFFD8C69E, texture: 'paper', vignette: 0.65, landStroke: true,
        atmosphere: 0xFFEBD9AE),
    // <<< win-43
  ];

  static List<String> get ids => [for (final s in all) s.id];

  static GeoStyle byId(String id) {
    final n = id.toLowerCase().replaceAll('-', '_').replaceAll(' ', '_');
    const alias = {'dark': 'dark_political', 'political': 'dark_political', 'sat': 'satellite', 'relief': 'satellite', 'paper': 'paper_vintage',
      'vintage': 'paper_vintage', 'light': 'clean_light', 'ink': 'newsprint', 'gold': 'documentary_gold', 'night': 'night_lights', 'hud': 'hologram', 'ops': 'military', 'gold_dark': 'obsidian_gold', 'atlas': 'old_atlas', 'war': 'war_room', 'teal': 'cinematic_teal', 'arctic': 'arctic_white'};
    final key = alias[n] ?? n;
    for (final s in all) {
      if (s.id == key) return s;
    }
    throw FormatException('Unknown map style "$id" (use ${ids.join(', ')})');
  }
}
