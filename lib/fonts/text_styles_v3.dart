/// V3-C: documentary data / HUD text looks (see TextStylePresets.all).
library;

import 'text_styles.dart';

class DataHudStyles {
  DataHudStyles._();

  static const List<TextStylePreset> all = [
    TextStylePreset('caption_red_outline', 'Red outline caption',
        'Poppins 800 red letters with a white edge, words pop (rare emotional line, 2 lines at the bottom)', {
      'font': 'Poppins',
      'font_weight': 800,
      'text_color': '#E8254F',
      'stroke': 4,
      'stroke_color': '#FFFFFF',
      'shadow': true,
      'animator': 'word_pop',
    }, sample: 'KOI NAHI BACHA'),
    TextStylePreset('stat_red_outline', 'Red outline stat',
        'Poppins Black crimson stat with a white edge, letters fade in softly from a blur', {
      'font': 'Poppins',
      'font_weight': 900,
      'text_color': '#D3123F',
      'stroke': 4,
      'stroke_color': '#FFFFFF',
      'shadow': true,
      'animator': 'typewriter_soft',
    }, sample: '72 DAYS'),
    TextStylePreset('osd_timestamp', 'VCR timestamp',
        'Italic Share Tech Mono white camcorder date/time typed on (bottom-left OSD)', {
      'font': 'Share Tech Mono',
      'font_weight': 400,
      'text_color': '#FFFFFF',
      'italic': true,
      'letter_spacing': 2,
      'shadow': true,
      'animator': 'typewriter',
    }, sample: 'DEC 22 1972  03:21 PM'),
    TextStylePreset('label_yellow_outline', 'Yellow outline label',
        'Heavy rounded Baloo 2 yellow label with a dark edge (objects, inset circles)', {
      'font': 'Baloo 2',
      'font_weight': 800,
      'text_color': '#FFD21F',
      'stroke': 3,
      'stroke_color': '#1A1A1A',
      'shadow': false,
    }, sample: 'RADIO'),
    TextStylePreset('stat_yellow', 'Yellow drop stat',
        'Huge yellow Poppins Black stat dropping letter by letter with a small bounce (put it behind silhouettes)', {
      'font': 'Poppins',
      'font_weight': 900,
      'text_color': '#FFE000',
      'shadow': true,
      'animator': 'letter_drop',
    }, sample: '60KM'),
  ];
}
