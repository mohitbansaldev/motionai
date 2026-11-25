import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../../core/engine/text_clusters.dart';
import '../../../core/engine/text_v3.dart';
import '../../../core/model/layer.dart';

/// V3-C: documentary text rendering — filled letters with a coloured edge
/// (`stroke`), italic / tracking, and the animators `typewriter_soft`,
/// `letter_drop`, `word_fade_grey`, typewriter `lead_color`.
class V3TextFx {
  V3TextFx._();

  /// Animators the V3 painter draws itself (no extra fade/slide intro).
  static const selfAnimated = {'typewriter_soft', 'letter_drop', 'word_fade_grey', 'typewriter', 'word_pop', 'fade_up', 'none'};

  /// True when the layer is drawn by [V3TextPainter] (marks, extrusion and the
  /// per-letter random/scramble animators keep their own painters).
  static bool handles(TextData t) {
    if (t.marks.isNotEmpty || t.extrude > 0) return false;
    if (TextV3.animators.contains(t.animator)) return true;
    if (t.animator == 'typewriter' && t.leadColor != 0 && t.leadChars > 0) return true;
    if (t.animator == 'random_pop' || t.animator == 'scramble' || t.animator == 'karaoke') return false;
    return t.stroke > 0;
  }

  /// Italic and letter spacing on the layer's base style.
  static TextStyle style(TextStyle s, TextData t) {
    if (!t.italic && t.letterSpacing == 0) return s;
    return s.copyWith(fontStyle: t.italic ? FontStyle.italic : null, letterSpacing: t.letterSpacing == 0 ? null : t.letterSpacing);
  }

  /// Cache fingerprint of the V3 text keys at [time] (LayerSig).
  static int sig(Layer l, TextData d, double time) {
    var h = Object.hash(d.stroke, d.strokeColor, d.italic, d.letterSpacing, d.leadColor, d.leadChars, d.dimColor,
        Object.hashAll(d.wordTimes));
    if (handles(d) && d.animator != 'none') {
      final local = time - l.start;
      final settle = TextV3.settleTime(
          d.animator, TextClusters.count(d.text), TextV3.wordRanges(d.text).length, d.animDuration, d.leadChars, d.wordTimes);
      if (local < settle) h = Object.hash(h, local);
    }
    return h;
  }

  static Widget build(Layer l, TextData t, TextStyle style, TextAlign align, String shown, double local, {bool draft = false}) =>
      CustomPaint(
        size: Size(l.width, l.height),
        painter: V3TextPainter(
          text: shown,
          style: style,
          align: align,
          animator: t.animator,
          local: local,
          duration: t.animDuration,
          stroke: t.stroke,
          strokeColor: Color(t.strokeColor),
          outline: t.outline,
          leadColor: t.leadColor == 0 ? null : Color(t.leadColor),
          leadChars: t.leadChars,
          wordTimes: t.wordTimes,
          dimColor: Color(t.dimColor == 0 ? TextV3.dimGrey : t.dimColor),
          boxColor: t.boxColor == 0 ? null : Color(t.boxColor),
          draft: draft,
        ),
      );
}

/// One animated piece (letter cluster or word) of the text.
class _Unit {
  final String text;
  final Rect box;
  _Unit(this.text, this.box);
}

class V3TextPainter extends CustomPainter {
  final String text;
  final TextStyle style;
  final TextAlign align;
  final String animator;
  final double local;
  final double duration;
  final double stroke;
  final Color strokeColor;
  final double outline;
  final Color? leadColor;
  final int leadChars;
  final List<double> wordTimes;
  final Color dimColor;
  final Color? boxColor;
  final bool draft;

  V3TextPainter({
    required this.text,
    required this.style,
    required this.align,
    required this.animator,
    required this.local,
    required this.duration,
    this.stroke = 0,
    this.strokeColor = const Color(0xFFFFFFFF),
    this.outline = 0,
    this.leadColor,
    this.leadChars = 0,
    this.wordTimes = const [],
    this.dimColor = const Color(TextV3.dimGrey),
    this.boxColor,
    this.draft = false,
  });

  static final LinkedHashMap<String, TextPainter> _cache = LinkedHashMap();

  Color get _color => style.color ?? const Color(0xFFFFFFFF);

  String get _styleKey =>
      '${style.fontSize}|${style.fontWeight}|${style.fontFamily}|${style.fontFamilyFallback?.join(',')}|${style.fontStyle}|'
      '${style.letterSpacing}|${style.height}|${style.shadows?.length ?? 0}|$stroke|${strokeColor.toARGB32()}|$outline';

  /// Base style without colour (children carry colour / foreground).
  TextStyle _bare({List<Shadow>? shadows}) => TextStyle(
        fontSize: style.fontSize,
        fontWeight: style.fontWeight,
        fontStyle: style.fontStyle,
        fontFamily: style.fontFamily,
        fontFamilyFallback: style.fontFamilyFallback,
        height: style.height,
        letterSpacing: style.letterSpacing,
        shadows: shadows,
      );

  List<Shadow>? _shadows(double a) {
    final s = style.shadows;
    if (s == null || s.isEmpty || a <= 0.001) return a <= 0.001 ? const [] : null;
    if (a >= 0.999) return s;
    return [for (final sh in s) Shadow(color: sh.color.withValues(alpha: sh.color.a * a), blurRadius: sh.blurRadius, offset: sh.offset)];
  }

  /// Leaf style for a run of text in colour [c] (alpha = visibility).
  /// [edge]: the coloured edge pass (drawn first, carries the shadow).
  TextStyle _leaf(Color c, {required bool edge}) {
    final a = c.a;
    if (edge) {
      return TextStyle(
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 2
          ..strokeJoin = StrokeJoin.round
          ..color = strokeColor.withValues(alpha: strokeColor.a * a),
        shadows: _shadows(a),
      );
    }
    if (outline > 0) {
      return TextStyle(
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = outline
          ..color = c,
        shadows: stroke > 0 ? const [] : _shadows(a),
      );
    }
    return TextStyle(color: c, shadows: stroke > 0 ? const [] : _shadows(a));
  }

  TextPainter _paragraph(List<(String, Color)> runs, double maxWidth, {required bool edge}) => TextPainter(
        text: TextSpan(style: _bare(), children: [for (final (s, c) in runs) TextSpan(text: s, style: _leaf(c, edge: edge))]),
        textAlign: align,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxWidth);

  TextPainter _cached(String key, TextPainter Function() make) {
    final hit = _cache.remove(key);
    if (hit != null) return _cache[key] = hit;
    final tp = make();
    _cache[key] = tp;
    while (_cache.length > 400) {
      _cache.remove(_cache.keys.first)?.dispose();
    }
    return tp;
  }

  /// The whole text laid out once in its final colour (positions + static look).
  TextPainter _static(double maxWidth, {required bool edge}) => _cached(
      '${edge ? 'E' : 'F'}|$_styleKey|${_color.toARGB32()}|${align.index}|${maxWidth.round()}|$text',
      () => _paragraph([(text, _color)], maxWidth, edge: edge));

  TextPainter _unitPainter(String s, Color c, {required bool edge}) =>
      _cached('u${edge ? 'E' : 'F'}|$_styleKey|${c.toARGB32()}|$s', () => _paragraph([(s, c)], double.infinity, edge: edge));

  @override
  void paint(Canvas canvas, Size size) {
    if (text.isEmpty) return;
    final base = _static(size.width, edge: false);
    final dx = switch (align) {
      TextAlign.left => 0.0,
      TextAlign.right => size.width - base.width,
      _ => (size.width - base.width) / 2,
    };
    final origin = Offset(dx, (size.height - base.height) / 2);
    final fs = style.fontSize ?? 48;
    final bc = boxColor;
    if (bc != null) {
      final r = origin & base.size;
      final box = Rect.fromLTRB(r.left - fs * 0.35, r.top - fs * 0.12, r.right + fs * 0.35, r.bottom + fs * 0.12);
      canvas.drawRRect(RRect.fromRectAndRadius(box, Radius.circular(fs * 0.2)), Paint()..color = bc);
    }

    switch (animator) {
      case 'typewriter':
        final n = TextClusters.count(text);
        final (shown, from) = TextV3.lead(n, local, duration, leadColor == null ? 0 : leadChars);
        if (shown >= n && from >= n) break;
        final a = TextClusters.prefixEnd(text, from), b = TextClusters.prefixEnd(text, shown);
        const clear = Color(0x00000000);
        _runs(canvas, origin, size.width, [
          (text.substring(0, a), _color),
          (text.substring(a, b), leadColor ?? _color),
          (text.substring(b), clear),
        ]);
        return;
      case 'word_fade_grey':
        final ranges = TextV3.wordRanges(text);
        if (local >= TextV3.wordsDone(ranges.length, duration, wordTimes)) break;
        final runs = <(String, Color)>[];
        var at = 0;
        for (int i = 0; i < ranges.length; i++) {
          final (s, e) = ranges[i];
          if (s > at) runs.add((text.substring(at, s), _color));
          final q = TextV3.wordLevel(i, ranges.length, local, duration, wordTimes);
          runs.add((text.substring(s, e), Color.lerp(dimColor, _color, q) ?? _color));
          at = e;
        }
        if (at < text.length) runs.add((text.substring(at), _color));
        _runs(canvas, origin, size.width, runs);
        return;
      case 'typewriter_soft':
      case 'letter_drop':
        final settle = TextV3.settleTime(animator, TextClusters.count(text), 0, duration, 0, const []);
        if (local >= settle) break;
        _perUnit(canvas, origin, base, _clusters(base), fs, words: false);
        return;
      case 'word_pop':
      case 'fade_up':
        if (local >= duration) break;
        _perUnit(canvas, origin, base, _words(base), fs, words: true);
        return;
    }
    if (stroke > 0) _static(size.width, edge: true).paint(canvas, origin);
    base.paint(canvas, origin);
  }

  void _runs(Canvas canvas, Offset origin, double width, List<(String, Color)> runs) {
    final parts = [for (final r in runs) if (r.$1.isNotEmpty) r];
    if (stroke > 0) {
      final e = _paragraph(parts, width, edge: true);
      e.paint(canvas, origin);
      e.dispose();
    }
    final f = _paragraph(parts, width, edge: false);
    f.paint(canvas, origin);
    f.dispose();
  }

  Rect? _boxOf(TextPainter base, int a, int b) {
    Rect? box;
    for (final tb in base.getBoxesForSelection(TextSelection(baseOffset: a, extentOffset: b))) {
      final r = tb.toRect();
      box = box == null ? r : box.expandToInclude(r);
    }
    return box;
  }

  List<_Unit> _clusters(TextPainter base) => [
        for (final (a, b) in TextClusters.ranges(text))
          if (text.substring(a, b).trim().isNotEmpty)
            if (_boxOf(base, a, b) case final box? when !box.isEmpty) _Unit(text.substring(a, b), box),
      ];

  List<_Unit> _words(TextPainter base) => [
        for (final (a, b) in TextV3.wordRanges(text))
          if (_boxOf(base, a, b) case final box? when !box.isEmpty) _Unit(text.substring(a, b), box),
      ];

  /// (opacity, scale, y offset px, blur px) of unit [i] of [n].
  (double, double, double, double) _state(int i, int n, double fs, bool words) {
    switch (animator) {
      case 'typewriter_soft':
        final (a, blur) = TextV3.soft(i, n, local, duration);
        return (a, 1, 0, blur);
      case 'letter_drop':
        final (a, y) = TextV3.drop(i, n, local, duration);
        return (a, 1, y * fs, 0);
      default: // word_pop / fade_up (same timing as the plain word animators)
        final delay = n <= 1 ? 0.0 : i * (duration * 0.6) / (n - 1);
        final span = math.max(0.05, duration * 0.4);
        final q = ((local - delay) / span).clamp(0.0, 1.0).toDouble();
        if (animator == 'word_pop') return (q, math.max(0.0, TextV3.backOut(q, 1.70158)), 0, 0);
        return (q, 1, (1 - TextV3.easeOutCubic(q)) * fs * 0.5, 0);
    }
  }

  void _perUnit(Canvas canvas, Offset origin, TextPainter base, List<_Unit> units, double fs, {required bool words}) {
    final n = units.length;
    final states = [for (int i = 0; i < n; i++) _state(i, n, fs, words)];
    for (final edge in [if (stroke > 0) true, false]) {
      for (int i = 0; i < n; i++) {
        final (a, sc, dy, blur) = states[i];
        if (a <= 0.002 || sc <= 0.001) continue;
        final u = units[i];
        final tp = _unitPainter(u.text, _color, edge: edge);
        final box = u.box.shift(origin);
        final pos = Offset(box.left + (box.width - tp.width) / 2, box.top + (box.height - tp.height) / 2 + dy);
        final layered = a < 0.998 || blur > 0.05;
        final moved = sc != 1.0;
        canvas.save();
        if (moved) {
          final c = box.center.translate(0, dy);
          canvas.translate(c.dx, c.dy);
          canvas.scale(sc);
          canvas.translate(-c.dx, -c.dy);
        }
        if (layered) {
          final pad = blur * 3 + stroke * 2 + fs * 0.3;
          final bounds = (pos & tp.size).inflate(pad);
          final paint = Paint()..color = Color.fromRGBO(0, 0, 0, a);
          if (blur > 0.05 && !draft) paint.imageFilter = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur, tileMode: TileMode.decal);
          canvas.saveLayer(bounds, paint);
          tp.paint(canvas, pos);
          canvas.restore();
        } else {
          tp.paint(canvas, pos);
        }
        canvas.restore();
      }
    }
  }

  bool _timeMatters(V3TextPainter o) {
    if (o.local == local) return false;
    final settle = TextV3.settleTime(
        animator, TextClusters.count(text), TextV3.wordRanges(text).length, duration, leadColor == null ? 0 : leadChars, wordTimes);
    return !(o.local >= settle && local >= settle);
  }

  @override
  bool shouldRepaint(covariant V3TextPainter o) =>
      o.text != text ||
      _timeMatters(o) ||
      o.style != style ||
      o.align != align ||
      o.animator != animator ||
      o.duration != duration ||
      o.stroke != stroke ||
      o.strokeColor != strokeColor ||
      o.outline != outline ||
      o.leadColor != leadColor ||
      o.leadChars != leadChars ||
      o.dimColor != dimColor ||
      o.boxColor != boxColor ||
      !_sameList(o.wordTimes, wordTimes);

  static bool _sameList(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
