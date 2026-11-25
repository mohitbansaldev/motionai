import 'dart:convert';

/// Lenient JSON for AI answers: strips code fences and prose around the
/// object, removes trailing commas, and when the answer was cut off (long
/// storyboards hit the output limit) keeps every complete item and closes
/// the open brackets. Pure Dart, unit-tested.
class JsonRepair {
  /// Decodes the first JSON object in [raw], repairing it when needed.
  /// Throws [FormatException] when nothing usable is found.
  static Map<String, dynamic> decode(String raw) {
    final r = tryDecode(raw);
    if (r == null) throw const FormatException('No JSON object in the answer');
    return r;
  }

  static Map<String, dynamic>? tryDecode(String raw) {
    var s = raw.replaceAll(RegExp(r'```(?:json|JSON)?'), '');
    final a = s.indexOf('{');
    if (a < 0) return null;
    s = s.substring(a);
    // 1. As is (up to the last closing brace).
    final b = s.lastIndexOf('}');
    if (b > 0) {
      final whole = _try(s.substring(0, b + 1));
      if (whole != null) return whole;
      final noCommas = _try(_dropTrailingCommas(s.substring(0, b + 1)));
      if (noCommas != null) return noCommas;
    }
    // 2. Cut off: try ever shorter prefixes that end on a complete value.
    final cuts = _cutPoints(s);
    var tries = 0;
    for (int i = cuts.length - 1; i >= 0 && tries < 600; i--, tries++) {
      final closed = _close(s.substring(0, cuts[i]));
      if (closed == null) continue;
      final r = _try(closed) ?? _try(_dropTrailingCommas(closed));
      if (r != null) return r;
    }
    return null;
  }

  static Map<String, dynamic>? _try(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map<String, dynamic> ? v : (v is Map ? Map<String, dynamic>.from(v) : null);
    } catch (_) {
      return null;
    }
  }

  /// Removes commas directly before a closing bracket (outside strings).
  static String _dropTrailingCommas(String s) {
    final out = StringBuffer();
    var inStr = false, esc = false;
    for (int i = 0; i < s.length; i++) {
      final ch = s[i];
      if (inStr) {
        out.write(ch);
        if (esc) {
          esc = false;
        } else if (ch == '\\') {
          esc = true;
        } else if (ch == '"') {
          inStr = false;
        }
        continue;
      }
      if (ch == '"') {
        inStr = true;
        out.write(ch);
        continue;
      }
      if (ch == ',') {
        var j = i + 1;
        while (j < s.length && ' \n\r\t'.contains(s[j])) {
          j++;
        }
        if (j < s.length && (s[j] == '}' || s[j] == ']')) continue;
      }
      out.write(ch);
    }
    return out.toString();
  }

  /// Prefix lengths that end right after a complete value: after a closing
  /// bracket, or just before a comma (all outside strings).
  static List<int> _cutPoints(String s) {
    final out = <int>[];
    var inStr = false, esc = false;
    for (int i = 0; i < s.length; i++) {
      final ch = s[i];
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (ch == '\\') {
          esc = true;
        } else if (ch == '"') {
          inStr = false;
        }
        continue;
      }
      if (ch == '"') {
        inStr = true;
      } else if (ch == '}' || ch == ']') {
        out.add(i + 1);
      } else if (ch == ',') {
        out.add(i);
      }
    }
    return out;
  }

  /// Closes the brackets left open by [prefix]; null when it ends inside a
  /// string or right after a key.
  static String? _close(String prefix) {
    final stack = <String>[];
    var inStr = false, esc = false;
    for (int i = 0; i < prefix.length; i++) {
      final ch = prefix[i];
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (ch == '\\') {
          esc = true;
        } else if (ch == '"') {
          inStr = false;
        }
        continue;
      }
      if (ch == '"') {
        inStr = true;
      } else if (ch == '{') {
        stack.add('}');
      } else if (ch == '[') {
        stack.add(']');
      } else if (ch == '}' || ch == ']') {
        if (stack.isEmpty || stack.last != ch) return null;
        stack.removeLast();
      }
    }
    if (inStr) return null;
    final t = prefix.trimRight();
    if (t.endsWith(':') || t.endsWith(',')) return null;
    final b = StringBuffer(t);
    for (final c in stack.reversed) {
      b.write(c);
    }
    return b.toString();
  }
}
