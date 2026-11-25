import 'caption_cue.dart';
import 'caption_track.dart';

/// SubRip (.srt) and WebVTT (.vtt) export / import. Pure functions.
class Subtitles {
  /// "00:01:02,345" (SRT) or "00:01:02.345" (VTT).
  static String timestamp(double seconds, {bool vtt = false}) {
    var ms = (seconds * 1000).round();
    if (ms < 0) ms = 0;
    final h = ms ~/ 3600000;
    final m = (ms ~/ 60000) % 60;
    final s = (ms ~/ 1000) % 60;
    final f = ms % 1000;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(h)}:${two(m)}:${two(s)}${vtt ? '.' : ','}${f.toString().padLeft(3, '0')}';
  }

  static String toSrt(List<CaptionCue> cues) {
    final b = StringBuffer();
    var n = 1;
    for (final c in _sorted(cues)) {
      final text = c.text.trim();
      if (text.isEmpty) continue;
      b
        ..writeln(n++)
        ..writeln('${timestamp(c.start)} --> ${timestamp(c.end)}')
        ..writeln(text)
        ..writeln();
    }
    return b.toString();
  }

  static String toVtt(List<CaptionCue> cues) {
    final b = StringBuffer('WEBVTT\n\n');
    for (final c in _sorted(cues)) {
      final text = c.text.trim();
      if (text.isEmpty) continue;
      b
        ..writeln('${timestamp(c.start, vtt: true)} --> ${timestamp(c.end, vtt: true)}')
        ..writeln(text)
        ..writeln();
    }
    return b.toString();
  }

  static List<CaptionCue> _sorted(List<CaptionCue> cues) => [...cues]..sort((a, b) => a.start.compareTo(b.start));

  static final _time = RegExp(r'(?:(\d+):)?(\d{1,2}):(\d{1,2})[,.](\d{1,3})');
  static final _arrow = RegExp(r'^\s*(\S+)\s*-->\s*(\S+)');

  /// Seconds from "01:02:03,456", "02:03.456" or "1:02:03.4".
  static double? parseTime(String s) {
    final m = _time.firstMatch(s.trim());
    if (m == null) return null;
    final h = int.parse(m.group(1) ?? '0');
    final mi = int.parse(m.group(2)!);
    final se = int.parse(m.group(3)!);
    final frac = m.group(4)!;
    final ms = int.parse(frac.padRight(3, '0'));
    return h * 3600 + mi * 60 + se + ms / 1000;
  }

  /// Captions from .srt or .vtt text. Formatting tags (<i>, {\an8}, <c.x>,
  /// VTT word timestamps) are removed; words get times spread over the cue.
  static List<CaptionCue> parse(String text) {
    final src = text.replaceAll('﻿', '').replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final out = <CaptionCue>[];
    final lines = src.split('\n');
    int i = 0;
    while (i < lines.length) {
      final m = _arrow.firstMatch(lines[i]);
      if (m == null) {
        i++;
        continue;
      }
      final s = parseTime(m.group(1)!), e = parseTime(m.group(2)!);
      i++;
      final body = <String>[];
      while (i < lines.length && lines[i].trim().isNotEmpty && _arrow.firstMatch(lines[i]) == null) {
        body.add(lines[i]);
        i++;
      }
      // A numeric index line right before the next cue belongs to that cue.
      if (body.isNotEmpty && i < lines.length && _arrow.firstMatch(lines[i]) != null && RegExp(r'^\d+$').hasMatch(body.last.trim())) {
        body.removeLast();
      }
      if (s == null || e == null || e <= s) continue;
      final clean = [for (final l in body) _clean(l)].where((l) => l.isNotEmpty).join('\n');
      if (clean.isEmpty) continue;
      out.add(CaptionTrack.cueFromText(clean, s, e));
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  static String _clean(String l) => l
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll(RegExp(r'\{\\[^}]*\}'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
