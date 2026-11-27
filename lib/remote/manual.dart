// win-42: the complete MotionAI control manual for Claude, served over MCP
// (tool get_manual, resource motionai://manual) so every new chat can learn
// the whole app. The text is docs/MOTIONAI_MANUAL.md, embedded by
// tool/gen_manual.py as lib/remote/manual_text.dart (test/manual_test.dart
// fails when the two differ or a tool is undocumented).
//
// PURE DART: no Flutter imports (the stdio bridge serves it too, even while
// the app is closed).

import 'manual_text.dart';

export 'manual_text.dart' show kManual;

/// One heading of the manual: `## ` (level 2) or `### ` (level 3), and the
/// character range its section covers (up to the next heading of the same or
/// a higher level).
class ManualHeading {
  final int level;
  final String title;
  final int start;
  int end;
  ManualHeading(this.level, this.title, this.start, this.end);
}

class Manual {
  static final List<ManualHeading> headings = scan(kManual);

  /// Headings of [text], ignoring lines inside ``` code fences.
  static List<ManualHeading> scan(String text) {
    final out = <ManualHeading>[];
    var inCode = false;
    var offset = 0;
    for (final line in text.split('\n')) {
      if (line.startsWith('```')) inCode = !inCode;
      if (!inCode) {
        if (line.startsWith('## ')) {
          out.add(ManualHeading(2, line.substring(3).trim(), offset, text.length));
        } else if (line.startsWith('### ')) {
          out.add(ManualHeading(3, line.substring(4).trim(), offset, text.length));
        }
      }
      offset += line.length + 1;
    }
    for (var i = 0; i < out.length; i++) {
      for (var j = i + 1; j < out.length; j++) {
        if (out[j].level <= out[i].level) {
          out[i].end = out[j].start;
          break;
        }
      }
    }
    return out;
  }

  /// The table of contents (every chapter and sub-section title).
  static String toc() {
    final b = StringBuffer('MotionAI control manual (${kManual.length} characters). '
        'Read a part with get_manual {"section": "<number or words>"}, e.g. "0" (rules), "2" (connecting), '
        '"16" (quirks), "7.3", "camera", "maps"; "all" = everything; "spec" = the raw command reference.\n\n');
    for (final h in headings) {
      b.writeln(h.level == 2 ? h.title : '    ${h.title}');
    }
    return b.toString();
  }

  /// The text for [query]:
  /// - null / empty / "all": the whole manual;
  /// - "toc" / "contents": the table of contents;
  /// - a number such as "7", "7.3", "A", "A.1": that chapter / section;
  /// - words: the first chapter, else the first sub-section, whose title contains them.
  /// Null when nothing matches. ("spec" is answered by the caller: it is the app's command reference.)
  static String? section(String? query) {
    final q = (query ?? '').trim().toLowerCase();
    if (q.isEmpty || q == 'all' || q == 'full') return kManual;
    if (q == 'toc' || q == 'contents' || q == 'index') return toc();
    ManualHeading? hit;
    if (RegExp(r'^([0-9]+|[a-z])(\.[0-9]+)?$').hasMatch(q)) {
      for (final h in headings) {
        final t = h.title.toLowerCase();
        if (t.startsWith('$q.') || t.startsWith('$q ') || t == q || t.startsWith('appendix $q')) {
          hit = h;
          break;
        }
      }
    }
    if (hit == null) {
      for (final level in const [2, 3]) {
        for (final h in headings) {
          if (h.level == level && h.title.toLowerCase().contains(q)) {
            hit = h;
            break;
          }
        }
        if (hit != null) break;
      }
    }
    if (hit == null) return null;
    return kManual.substring(hit.start, hit.end).trimRight();
  }
}
