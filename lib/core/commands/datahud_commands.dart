import 'dart:math' as math;

import '../model/layer.dart';
import 'edit_commands.dart' show CommandError;

/// V3-C: extra text keys on add_layer / update_layer (called from
/// EditCommands._applyText):
///
/// - `stroke`: edge width px behind FILLED letters (or `{width, color}`),
///   `stroke_color` "#RRGGBB" (default white) — sticker-style outlined text
/// - `italic`: true/false, `letter_spacing`: px
/// - `lead_color` + `lead_chars` (3): typewriter's newest letters coloured
/// - `word_times`: [s, ...] after the layer start, one per word
///   (word_fade_grey), `dim_color`: colour of not-yet-spoken words
class DataHudText {
  DataHudText._();

  static void apply(TextData t, Map<String, dynamic> c, int Function(dynamic) color) {
    final st = c['stroke'];
    if (st is Map) {
      final m = Map<String, dynamic>.from(st);
      if (m['width'] is num) t.stroke = math.max(0.0, (m['width'] as num).toDouble());
      if (m['color'] != null) t.strokeColor = color(m['color']);
    } else if (st == 'none' || st == false) {
      t.stroke = 0;
    } else if (st != null) {
      if (st is! num) throw CommandError('"stroke" must be a width in px, {width, color} or "none"');
      t.stroke = st.toDouble().clamp(0.0, 200.0).toDouble();
    }
    if (c['stroke_color'] != null) t.strokeColor = color(c['stroke_color']);
    if (c['italic'] != null) t.italic = c['italic'] == true;
    if (c['letter_spacing'] != null) {
      final v = c['letter_spacing'];
      if (v is! num) throw CommandError('"letter_spacing" must be a number (px)');
      t.letterSpacing = v.toDouble().clamp(-50.0, 400.0).toDouble();
    }
    if (c['lead_color'] != null) {
      t.leadColor = c['lead_color'] == 'none' ? 0 : color(c['lead_color']);
      if (t.leadColor != 0 && t.leadChars <= 0 && c['lead_chars'] == null) t.leadChars = 3;
    }
    if (c['lead_chars'] != null) {
      final v = c['lead_chars'];
      if (v is! num) throw CommandError('"lead_chars" must be a whole number');
      t.leadChars = v.round().clamp(0, 50);
    }
    if (c['dim_color'] != null) t.dimColor = c['dim_color'] == 'none' ? 0 : color(c['dim_color']);
    final wt = c['word_times'];
    if (wt != null) {
      if (wt is! List || wt.any((e) => e is! num)) {
        throw CommandError('"word_times" must be a list of seconds after the layer start, one per word');
      }
      t.wordTimes = [for (final e in wt) math.max(0.0, (e as num).toDouble())];
    }
  }
}

/// V3-C: layer blend modes (`update_layer {blend}`), rendered by
/// BlendComposite in lib/ui/preview/fx/datahud_fx.dart.
class DataHudBlend {
  DataHudBlend._();

  static const names = [
    'normal', 'screen', 'add', 'lighten', 'multiply', 'overlay', 'darken', 'soft_light', 'hard_light', 'color_dodge', 'difference',
  ];

  static String parse(dynamic v) {
    final s = '$v'.trim().toLowerCase().replaceAll(' ', '_').replaceAll('-', '_');
    final k = const {'plus': 'add', 'linear_dodge': 'add', 'none': 'normal'}[s] ?? s;
    if (!names.contains(k)) throw CommandError('Unknown blend "$v". Use ${names.join(', ')}');
    return k;
  }
}
