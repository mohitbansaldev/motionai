import 'dart:convert';

import '../../director/pattern_engine.dart';
import '../../director/patterns.dart';
import '../model/project.dart';
import 'edit_commands.dart';

/// V3-E: story-grammar ops (lib/director/patterns.dart, pattern_engine.dart).
///
///   suggest_patterns {lines: [{text, start?, end?}] | "one line per row", style?: "nr_doc", tone?: auto|snow|desert|neutral,
///                     presenter?: true, asl?, presenter_min_gap?, presenter_max_gap?, cta_every?, handle?}
///     — info op: the pattern plan as JSON in the log (nothing changes).
///   apply_patterns {plan, assets?: {presenter, broll: [ids], beats: {"<i>": {slot: value}}}, tone?, sfx?: true, prefix?}
///     — builds every beat (plate, transition in, pattern, overlays, sound) with capability fallback.
///   list_patterns {category?} — the registry as JSON in the log.
class PatternCommands {
  static const ops = ['suggest_patterns', 'apply_patterns', 'list_patterns'];

  static void run(Project p, Map<String, dynamic> c, double now, CommandResult r, void Function(Map<String, dynamic>) exec) {
    switch (c['op']) {
      case 'suggest_patterns':
        r.log.add(jsonEncode(suggest(c)));
        return;
      case 'list_patterns':
        final cat = c['category'] is String ? '${c['category']}' : null;
        r.log.add(jsonEncode({
          'patterns': [for (final x in PatternLibrary.all) if (cat == null || x.category == cat) x.toJson()],
        }));
        return;
      case 'apply_patterns':
        PatternRuntime.apply(p, c, r, exec);
        return;
    }
    throw CommandError('Unknown pattern op ${c['op']}');
  }

  /// The plan for a suggest_patterns command / MCP tool call.
  static Map<String, dynamic> suggest(Map<String, dynamic> c) {
    final raw = c['lines'];
    final lines = <Map<String, dynamic>>[];
    if (raw is String) {
      for (final l in raw.split(RegExp(r'\r?\n'))) {
        if (l.trim().isNotEmpty) lines.add({'text': l.trim()});
      }
    } else if (raw is List) {
      for (final l in raw) {
        if (l is String) {
          lines.add({'text': l});
        } else if (l is Map) {
          lines.add(Map<String, dynamic>.from(l));
        }
      }
    } else {
      throw CommandError('suggest_patterns needs "lines": [{"text": "...", "start": s, "end": s}, ...] (or one string with a line per row)');
    }
    final context = <String, dynamic>{
      for (final e in c.entries)
        if (e.key != 'op' && e.key != 'lines') e.key: e.value,
    };
    return PatternEngine.suggest(lines, context: context);
  }
}
