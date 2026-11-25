/// Ready-made text looks for documentary videos, as plain command data so
/// the AI, the font picker and components can all apply them.
///
/// Apply with `add_layer`/`update_layer` `{"text_style": "<id>"}`; any key
/// given explicitly in the same command wins over the preset value.
library;

import 'text_styles_v3.dart'; // V3-C

class TextStylePreset {
  final String id;
  final String label;
  final String description;

  /// Text command keys (same names as add_layer/update_layer: font,
  /// font_weight, text_color, outline, extrude, shadow, box_color, animator...).
  final Map<String, dynamic> keys;

  /// Effects added to the layer if it has none of that type yet:
  /// {'effect': type, 'params': {...}}.
  final List<Map<String, dynamic>> effects;

  /// Sample text for previews.
  final String sample;

  const TextStylePreset(this.id, this.label, this.description, this.keys,
      {this.effects = const [], this.sample = 'Title'});

  String get font => keys['font'] as String;
}

class TextStylePresets {
  TextStylePresets._();

  static const List<TextStylePreset> all = [
    TextStylePreset('doc_title', 'Doc title', 'Tall white Anton with a thick grey 3D edge (viral intro / big words)', {
      'font': 'Anton',
      'font_weight': 400,
      'text_color': '#FFFFFF',
      'extrude': {'depth': 14, 'color': '#5C5C5C'},
      'shadow': true,
    }, sample: 'VIRAL 3D'),
    TextStylePreset('gold_word', 'Gold word', 'Huge gold Anton word with a warm glow ("Poor Farmer")', {
      'font': 'Anton',
      'font_weight': 400,
      'text_color': '#F2C14E',
      'shadow': true,
    }, effects: [
      {'effect': 'glow', 'params': {'amount': 45, 'radius': 24}},
    ], sample: 'POOR FARMER'),
    TextStylePreset('date_serif', 'Date serif', 'Big black-weight Playfair serif for dates and years', {
      'font': 'Playfair Display',
      'font_weight': 900,
      'text_color': '#F4E7CF',
      'shadow': true,
    }, sample: '1831'),
    TextStylePreset('script_name', 'Script name', 'Elegant Great Vibes script for a name under a date', {
      'font': 'Great Vibes',
      'font_weight': 400,
      'text_color': '#FFFFFF',
      'shadow': true,
    }, sample: 'Louis Vuitton'),
    TextStylePreset('neon_outline', 'Neon outline', 'Bebas Neue outline-only letters with a strong glow', {
      'font': 'Bebas Neue',
      'font_weight': 400,
      'text_color': '#3DF5FF',
      'outline': 4,
      'shadow': false,
    }, effects: [
      {'effect': 'glow', 'params': {'amount': 85, 'radius': 28}},
    ], sample: 'NEON'),
    TextStylePreset('typewriter', 'Typewriter', 'Special Elite typed on letter by letter (case files, letters)', {
      'font': 'Special Elite',
      'font_weight': 400,
      'text_color': '#EDE6D6',
      'animator': 'typewriter',
      'shadow': true,
    }, sample: 'CLASSIFIED'),
    TextStylePreset('headline_red', 'Breaking headline', 'Bold Oswald on a red box (news headline / label)', {
      'font': 'Oswald',
      'font_weight': 700,
      'text_color': '#FFFFFF',
      'box_color': '#D32F2F',
      'shadow': false,
    }, sample: 'BREAKING'),
    TextStylePreset('roman_caps', 'Roman caps', 'Cinzel gold capitals for history, empires and plaques', {
      'font': 'Cinzel',
      'font_weight': 700,
      'text_color': '#E8C66A',
      'shadow': true,
    }, sample: 'EMPIRE'),
    TextStylePreset('marker_note', 'Marker note', 'Yellow Permanent Marker scribble for callouts', {
      'font': 'Permanent Marker',
      'font_weight': 400,
      'text_color': '#FFE14D',
      'shadow': true,
    }, sample: 'Look here!'),
    TextStylePreset('caption_bold', 'Bold caption', 'White Poppins Black on a dark box (Hinglish captions)', {
      'font': 'Poppins',
      'font_weight': 900,
      'text_color': '#FFFFFF',
      'box_color': '#B3000000',
      'shadow': false,
    }, sample: 'Sach kya hai?'),
    TextStylePreset('hindi_bold', 'Hindi bold', 'Heavy Rozha One Hindi headline in warm yellow', {
      'font': 'Rozha One',
      'font_weight': 400,
      'text_color': '#FFD54F',
      'shadow': true,
    }, sample: 'भारत का इतिहास'),
    TextStylePreset('hindi_title', 'Hindi title', 'Tall condensed Teko for Hindi/English titles with a 3D edge', {
      'font': 'Teko',
      'font_weight': 700,
      'text_color': '#FFFFFF',
      'extrude': {'depth': 10, 'color': '#5C5C5C'},
      'shadow': true,
    }, sample: 'रहस्य'),
    TextStylePreset('hindi_handwritten', 'Hindi handwritten', 'Kalam handwriting for Hindi notes and names', {
      'font': 'Kalam',
      'font_weight': 700,
      'text_color': '#FFFFFF',
      'shadow': true,
    }, sample: 'मोहित'),
    ...DataHudStyles.all, // V3-C
  ];

  static List<String> get ids => [for (final p in all) p.id];

  static TextStylePreset? byId(String? id) {
    if (id == null) return null;
    final k = id.trim().toLowerCase().replaceAll(RegExp(r'[\s\-]+'), '_');
    for (final p in all) {
      if (p.id == k) return p;
    }
    return null;
  }
}
