import 'dart:math' as math;

import '../core/model/project.dart';
import 'caption_cue.dart';
import 'emphasis.dart';
import 'grouping.dart';
import 'options.dart';
import 'placement.dart';
import 'styles.dart';
import 'text_rules.dart';

/// Turns timed words / captions + a [CaptionStyle] into edit commands
/// (`add_layer` text layers, `add_effect`, `set_keyframe`). Pure Dart; run
/// the result with `EditCommands.runAtomic` as one batch.
class CaptionBuilder {
  /// Caption layer ids: `cap_<stamp>_<n>` (one layer) or `cap_<stamp>_<n>_l<k>` (one per line).
  static const prefix = 'cap_';
  static final idPattern = RegExp(r'^cap_([A-Za-z0-9]+)_(\d+)(?:_l(\d+))?$');

  /// Words → captions (grouped, line-broken, emphasis detected) for [style] in [comp].
  static List<CaptionCue> cues(Composition comp, List<WordTiming> words, CaptionStyle style, {CaptionOptions? options}) {
    final o = options ?? CaptionOptions(style: style.id);
    final ws = [
      for (final w in words)
        if (w.word.trim().isNotEmpty) WordTiming(w.word.trim(), w.start + o.offset, w.end + o.offset),
    ];
    final deva = TextRules.mostlyDevanagari(ws.map((w) => w.word));
    final layout = CaptionLayout.of(comp.width, comp.height, style, devanagari: deva);
    final maxWords = o.maxWords > 0 ? math.min(o.maxWords, style.maxWords + 4) : style.maxWords;
    final list = CaptionGrouper.group(
      ws,
      GroupingRules(
        maxWords: maxWords,
        maxLines: style.maxLines,
        maxLineChars: layout.maxLineChars,
        breakOnClause: maxWords > 2,
      ),
    );
    retime(list, minDuration: style.bounce ? 0.25 : 0.3);
    if (o.emphasis || o.emphasisWords.isNotEmpty) {
      Emphasis.apply(list, aiWords: o.emphasisWords, maxPerCue: style.maxWords <= 3 ? 1 : 2);
      if (!o.emphasis) {
        // Only the chosen words.
        for (final c in list) {
          c.emphasis = {for (final i in c.emphasis) if (o.emphasisWords.contains(TextRules.normalize(c.words[i].word))) i};
        }
      }
    }
    return list;
  }

  /// Fills short gaps between captions, enforces a minimum length and removes overlaps.
  static void retime(List<CaptionCue> cues, {double minDuration = 0.3, double bridge = 0.35}) {
    cues.sort((a, b) => a.start.compareTo(b.start));
    for (int i = 0; i < cues.length; i++) {
      final c = cues[i];
      final s = c.start;
      var e = math.max(c.end, s + minDuration);
      if (i + 1 < cues.length) {
        final next = cues[i + 1].start;
        if (next - e < bridge) e = next;
        if (e > next) e = next;
      }
      c.start = s;
      c.end = math.max(e, s + 0.1);
    }
  }

  /// One-shot: words → commands.
  static List<Map<String, dynamic>> fromWords(Project project, List<WordTiming> words, CaptionOptions o, {String? stamp}) {
    final style = CaptionStyles.byId(o.style);
    final list = cues(project.main, words, style, options: o);
    return build(project, list, style, stamp: stamp, safeArea: o.safeArea);
  }

  /// Commands that add caption layers for [cues] in [style].
  static List<Map<String, dynamic>> build(
    Project project,
    List<CaptionCue> cues,
    CaptionStyle style, {
    String? stamp,
    bool safeArea = true,
  }) {
    final comp = project.main;
    stamp ??= DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final deva = TextRules.mostlyDevanagari([for (final c in cues) ...c.words.map((w) => w.word)]);
    final layout = CaptionLayout.of(comp.width, comp.height, style, devanagari: deva);
    final family = CaptionFonts.pick(deva ? style.fonts.devanagari : style.fonts.latin);
    final scale = math.min(comp.width, comp.height) / 1080;
    final cmds = <Map<String, dynamic>>[];

    for (int ci = 0; ci < cues.length; ci++) {
      final c = cues[ci];
      if (c.words.isEmpty) continue;
      String shown(String w) => style.uppercase ? w.toUpperCase() : w;
      final ranges = c.lineRanges;
      final lineTexts = [for (final r in ranges) c.words.sublist(r.$1, r.$2).map((w) => shown(w.word)).join(' ')];

      // Placement (+ safe area).
      var block = layout.block(lineTexts);
      if (safeArea) {
        final obs = CaptionSafeArea.obstacles(comp, c.start, c.end, captionPrefix: prefix);
        final dy = CaptionSafeArea.offsetFor(block.rect, obs, top: layout.safeTop, bottom: layout.safeBottom, margin: layout.fontSize * 0.25);
        if (dy != 0) block = block.shift(dy);
      }

      final perLine = style.layerPerLine && ranges.length > 1;
      final parts = perLine
          ? [for (int k = 0; k < ranges.length; k++) (ranges[k].$1, ranges[k].$2, block.lineY(k), 1)]
          : [(0, c.words.length, block.rect.cy, ranges.length)];

      for (int k = 0; k < parts.length; k++) {
        final (from, to, y, nLines) = parts[k];
        final id = perLine ? '$prefix${stamp}_${ci}_l$k' : '$prefix${stamp}_$ci';
        final ws = c.words.sublist(from, to);
        // Word-pop lines appear when their first word is spoken.
        final start = perLine && k > 0 && style.timing == CaptionTiming.spread ? math.min(ws.first.start, c.end - 0.1) : c.start;
        final dur = math.max(0.1, c.end - start);
        final text = perLine ? lineTexts[k] : lineTexts.join('\n');
        final emph = [for (final i in c.emphasis) if (i >= from && i < to) i]..sort();

        final cmd = <String, dynamic>{
          'op': 'add_layer',
          'type': 'text',
          'id': id,
          'name': perLine ? 'Caption ${ci + 1} · ${k + 1}' : 'Caption ${ci + 1}',
          'text': text,
          'start': start,
          'duration': dur,
          'width': layout.boxWidth,
          'height': layout.lineHeight * nLines + layout.fontSize * 0.4,
          'position': [comp.width / 2, y, 0],
          'font_size': layout.fontSize,
          'font_weight': style.weight,
          if (family != null) 'font_family': family,
          'text_color': style.color,
          'highlight_color': style.highlightColor,
          'box_color': style.box ?? 'none',
          'shadow': style.softShadow,
          'outline': style.hollow > 0 ? math.max(1.0, style.hollow * scale) : 0,
          'animator': style.animator,
          'anim_duration': _animDuration(style, ws, start, c.end),
          'words': [for (final w in ws) {'w': w.word, 's': w.start, 'e': w.end}],
        };
        if (style.colorMarks && emph.isNotEmpty) {
          cmd['marks'] = [
            for (final run in _runs(emph))
              {
                'phrase': c.words.sublist(run.$1, run.$2).map((w) => shown(w.word)).join(' ').replaceAll(RegExp(r'[,.!?;:।]+$'), ''),
                'style': 'color',
                'color': style.emphasisColor,
                'delay': math.max(0.0, c.words[run.$1].start - start),
                'duration': 0.04,
              },
          ];
        }
        cmds.add(cmd);

        // Effects.
        if (style.stroke > 0) {
          cmds.add({'op': 'add_effect', 'layer': id, 'id': '${id}_stroke', 'effect': 'outline', 'params': {'width': (style.stroke * scale * 10).roundToDouble() / 10, 'color': _rgb(style.strokeColor)}});
        }
        if (style.dropShadow) {
          cmds.add({'op': 'add_effect', 'layer': id, 'id': '${id}_shadow', 'effect': 'shadow', 'params': {'distance': (8 * scale).roundToDouble(), 'angle': 90, 'blur': (4 * scale).roundToDouble(), 'opacity': 75}});
        }
        if (style.glow > 0) {
          cmds.add({'op': 'add_effect', 'layer': id, 'id': '${id}_glow', 'effect': 'glow', 'params': {'amount': style.glow, 'radius': style.glowRadius}});
        }

        // Motion: bounce in, pulse on emphasised words.
        final kfs = <(double, double, String)>[];
        final end = start + dur;
        var busyUntil = start;
        if (style.bounce && dur > 0.2) {
          final peak = c.emphasis.isNotEmpty ? style.pulseScale + 6 : 112.0;
          kfs.addAll([(start, 55.0, 'ease_out'), (start + 0.09, peak, 'easy_ease'), (start + 0.18, 100.0, 'easy_ease')]);
          busyUntil = start + 0.19;
        }
        if (style.pulses) {
          for (final run in _runs(emph)) {
            final t = math.max(c.words[run.$1].start, start);
            if (t < busyUntil + 0.01 || t + 0.2 > end - 0.02) continue;
            kfs.addAll([(t, 100.0, 'ease_out'), (t + 0.07, style.pulseScale, 'easy_ease'), (t + 0.2, 100.0, 'easy_ease')]);
            busyUntil = t + 0.21;
          }
        }
        for (final kf in kfs) {
          cmds.add({'op': 'set_keyframe', 'target': id, 'prop': 'scale', 'time': _ms(kf.$1), 'value': kf.$2, 'ease': kf.$3});
        }
      }
    }
    return cmds;
  }

  static double _ms(double t) => (t * 1000).roundToDouble() / 1000;

  static double _animDuration(CaptionStyle s, List<WordTiming> ws, double start, double end) {
    final d = switch (s.timing) {
      CaptionTiming.spread => ws.length <= 1 ? 0.3 : (ws.last.start - start) / 0.6,
      CaptionTiming.typeOn => (ws.last.end - start) * 0.95,
      CaptionTiming.glyph => math.min(s.animDuration, (end - start) * 0.6),
      _ => s.animDuration,
    };
    return (d.clamp(0.1, 20.0) * 1000).roundToDouble() / 1000;
  }

  /// Consecutive index runs: [2,3,5] → (2,4), (5,6).
  static List<(int, int)> _runs(List<int> sorted) {
    final out = <(int, int)>[];
    for (final i in sorted) {
      if (out.isNotEmpty && out.last.$2 == i) {
        out[out.length - 1] = (out.last.$1, i + 1);
      } else {
        out.add((i, i + 1));
      }
    }
    return out;
  }

  static List<int> _rgb(String hex) {
    var s = hex.replaceFirst('#', '');
    if (s.length == 8) s = s.substring(2);
    final n = int.tryParse(s, radix: 16) ?? 0;
    return [(n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF];
  }
}
