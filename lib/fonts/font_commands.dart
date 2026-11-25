import '../core/commands/edit_commands.dart' show CommandError;
import '../core/model/effects_catalog.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart' show Ids;
import 'font_catalog.dart';
import 'text_styles.dart';

/// Text command keys for fonts, called once from EditCommands._applyText:
/// - `font`: a bundled family (or alias like "serif"), validated against
///   [FontCatalog] → stored as TextData.fontFamily (canonical name).
/// - `text_style`: a [TextStylePresets] id; its keys are merged under the
///   command's own keys (explicit keys win) and its effects are added to the
///   layer when the layer has no effect of that type yet.
/// `font_family` keeps its old lenient meaning (any name, incl. system fonts).
class FontCommands {
  FontCommands._();

  /// Returns the command with `text_style` expanded and `font` turned into a
  /// canonical `font_family`. Throws [CommandError] for unknown names.
  static Map<String, dynamic> expand(Layer l, Map<String, dynamic> c) {
    if (c['font'] == null && c['text_style'] == null) return c;
    final out = <String, dynamic>{};
    final presetId = c['text_style'];
    if (presetId != null) {
      final p = TextStylePresets.byId('$presetId');
      if (p == null) {
        throw CommandError('Unknown text_style "$presetId". Available: ${TextStylePresets.ids.join(', ')}');
      }
      // A preset is a whole look: clear the edge/box/outline of a previous one.
      out.addAll({'outline': 0, 'extrude': 'none', 'box_color': 'none'});
      p.keys.forEach((k, v) => out[k == 'font' ? 'font_family' : k] = v);
      // Preset font is a catalog family; explicit font_family / font override it below.
      _addEffects(l, p);
    }
    out.addAll(c);
    out.remove('text_style');
    final f = c['font'];
    if (f != null) {
      out['font_family'] = canonical('$f');
      out.remove('font');
    }
    // Snap the weight to one the font really has (no faux bold on Anton etc.).
    final info = FontCatalog.lookup(out['font_family']?.toString());
    if (info != null && (c['font'] != null || presetId != null)) {
      final w = out['font_weight'] is num ? (out['font_weight'] as num).toInt() : (l.text?.fontWeight ?? 700);
      out['font_weight'] = info.clampWeight(w);
    }
    return out;
  }

  /// The pubspec family name for [name] or a [CommandError] listing fonts.
  static String canonical(String name) {
    final info = FontCatalog.lookup(name);
    if (info == null) {
      final near = FontCatalog.suggestions(name);
      throw CommandError('Unknown font "$name".${near.isEmpty ? '' : ' Did you mean: ${near.join(', ')}?'} '
          'Available: ${FontCatalog.families.join(', ')}');
    }
    return info.family;
  }

  static void _addEffects(Layer l, TextStylePreset p) {
    for (final e in p.effects) {
      final type = e['effect'] as String;
      if (l.effects.any((x) => x.type == type)) continue;
      if (EffectsCatalog.byType(type) == null) continue;
      final fx = EffectsCatalog.create(type, Ids.next('fx'));
      final params = e['params'];
      if (params is Map) {
        params.forEach((k, v) {
          final ap = fx.params['$k'];
          if (ap != null && v is num) ap.staticValue = [v.toDouble()];
        });
      }
      l.effects.add(fx);
    }
  }
}
