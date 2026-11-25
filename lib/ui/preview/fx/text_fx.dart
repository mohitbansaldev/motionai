import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../../core/engine/fx_math.dart';

class _Glyph {
  final int rune;
  final Rect box; // in full-layout coordinates
  _Glyph(this.rune, this.box);
}

class _Layout {
  final TextPainter face;
  final TextPainter? edge;
  final List<_Glyph> glyphs;
  _Layout(this.face, this.edge, this.glyphs);
  void dispose() {
    face.dispose();
    edge?.dispose();
  }
}

/// Text with per-letter animators (`random_pop`, `scramble`) and a 3D
/// extruded edge (`extrude`). Text layouts and single-glyph painters are
/// cached, so animating only re-positions already laid-out glyphs.
class GlyphTextPainter extends CustomPainter {
  final String text;
  final TextStyle style;
  final TextAlign align;
  final String animator; // none | random_pop | scramble
  final double local; // seconds since the layer start
  final double duration; // animator length
  final int seed;
  final double outline;
  final double extrude;
  final Color extrudeColor;
  final bool draft;

  GlyphTextPainter({
    required this.text,
    required this.style,
    required this.align,
    required this.animator,
    required this.local,
    required this.duration,
    required this.seed,
    this.outline = 0,
    this.extrude = 0,
    this.extrudeColor = const Color(0xFF8A8A8A),
    this.draft = false,
  });

  static final LinkedHashMap<String, _Layout> _layouts = LinkedHashMap();
  static final LinkedHashMap<String, TextPainter> _glyphs = LinkedHashMap();

  TextStyle _faceStyle() {
    if (outline <= 0) return style;
    return TextStyle(
      fontSize: style.fontSize,
      fontWeight: style.fontWeight,
      fontFamily: style.fontFamily,
      height: style.height,
      letterSpacing: style.letterSpacing,
      shadows: style.shadows,
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = outline
        ..color = style.color ?? const Color(0xFFFFFFFF),
    );
  }

  TextStyle _edgeStyle() => TextStyle(
        fontSize: style.fontSize,
        fontWeight: style.fontWeight,
        fontFamily: style.fontFamily,
        height: style.height,
        letterSpacing: style.letterSpacing,
        color: extrudeColor,
      );

  String get _styleKey =>
      '${style.fontSize}|${style.fontWeight}|${style.fontFamily}|${style.color?.toARGB32()}|${style.shadows?.length ?? 0}|$outline|${extrude > 0 ? extrudeColor.toARGB32() : 0}';

  bool get _perGlyph => animator == 'random_pop' || animator == 'scramble';

  _Layout _layout(double maxWidth) {
    final key = '$_styleKey|${align.index}|${maxWidth.round()}|$_perGlyph|$text';
    final hit = _layouts.remove(key);
    if (hit != null) return _layouts[key] = hit;
    final face = TextPainter(text: TextSpan(text: text, style: _faceStyle()), textAlign: align, textDirection: TextDirection.ltr)
      ..layout(maxWidth: maxWidth);
    TextPainter? edge;
    if (extrude > 0) {
      edge = TextPainter(text: TextSpan(text: text, style: _edgeStyle()), textAlign: align, textDirection: TextDirection.ltr)
        ..layout(maxWidth: maxWidth);
    }
    final glyphs = <_Glyph>[];
    if (_perGlyph) {
      var offset = 0;
      for (final r in text.runes) {
        final len = r > 0xFFFF ? 2 : 1;
        final boxes = face.getBoxesForSelection(TextSelection(baseOffset: offset, extentOffset: offset + len));
        if (boxes.isNotEmpty) glyphs.add(_Glyph(r, boxes.first.toRect()));
        offset += len;
      }
    }
    final l = _Layout(face, edge, glyphs);
    _layouts[key] = l;
    while (_layouts.length > 48) {
      _layouts.remove(_layouts.keys.first)?.dispose();
    }
    return l;
  }

  TextPainter _glyph(int rune, bool edge) {
    final key = '${edge ? 'e' : 'f'}|$_styleKey|$rune';
    final hit = _glyphs.remove(key);
    if (hit != null) return _glyphs[key] = hit;
    final tp = TextPainter(
      text: TextSpan(text: String.fromCharCode(rune), style: edge ? _edgeStyle() : _faceStyle()),
      textDirection: TextDirection.ltr,
    )..layout();
    _glyphs[key] = tp;
    while (_glyphs.length > 600) {
      _glyphs.remove(_glyphs.keys.first)?.dispose();
    }
    return tp;
  }

  /// Extrusion direction (down-right) and step count.
  (Offset, int) _extrudeSteps() {
    final depth = extrude.clamp(0.0, 400.0);
    final steps = draft ? math.min(depth.ceil(), 14) : depth.ceil();
    final dir = const Offset(0.45, 1) / const Offset(0.45, 1).distance;
    return (dir * (depth / math.max(1, steps)), steps);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (text.isEmpty) return;
    final lay = _layout(size.width);
    final face = lay.face;
    final dx = switch (align) {
      TextAlign.left => 0.0,
      TextAlign.right => size.width - face.width,
      _ => (size.width - face.width) / 2,
    };
    final origin = Offset(dx, (size.height - face.height) / 2);
    final (step, steps) = _extrudeSteps();

    if (!_perGlyph) {
      final edge = lay.edge;
      if (edge != null) {
        for (int k = steps; k >= 1; k--) {
          edge.paint(canvas, origin + step * k.toDouble());
        }
      }
      face.paint(canvas, origin);
      return;
    }

    final n = lay.glyphs.length;
    for (int i = 0; i < n; i++) {
      final g = lay.glyphs[i];
      if (String.fromCharCode(g.rune).trim().isEmpty) continue;
      var rune = g.rune;
      var scale = 1.0;
      if (animator == 'random_pop') {
        final q = TextFx.randomPopProgress(i, n, local, duration, seed);
        if (q <= 0) continue;
        scale = _back(q);
      } else {
        rune = TextFx.scrambleRune(g.rune, i, n, local, duration, seed);
      }
      if (scale <= 0.001) continue;
      final box = g.box.shift(origin);
      final tp = _glyph(rune, false);
      final pos = Offset(box.left + (box.width - tp.width) / 2, box.top + (box.height - tp.height) / 2);
      final scaled = scale != 1.0;
      if (scaled) {
        canvas.save();
        canvas.translate(box.center.dx, box.center.dy);
        canvas.scale(scale);
        canvas.translate(-box.center.dx, -box.center.dy);
      }
      if (extrude > 0) {
        final ep = _glyph(rune, true);
        for (int k = steps; k >= 1; k--) {
          ep.paint(canvas, pos + step * k.toDouble());
        }
      }
      tp.paint(canvas, pos);
      if (scaled) canvas.restore();
    }
  }

  static double _back(double t) {
    const s = 1.70158;
    final u = t - 1;
    return 1 + u * u * ((s + 1) * u + s);
  }

  /// Per-letter animators settle by [duration]; after that (and for plain
  /// extruded text) time no longer changes the picture (PERF, Agent O).
  bool _timeChanged(GlyphTextPainter o) {
    if (o.local == local) return false;
    if (!_perGlyph || o.animator != animator) return _perGlyph;
    final done = duration + 0.05;
    return !(o.local >= done && local >= done);
  }

  @override
  bool shouldRepaint(covariant GlyphTextPainter o) =>
      o.text != text ||
      _timeChanged(o) ||
      o.style != style ||
      o.animator != animator ||
      o.duration != duration ||
      o.outline != outline ||
      o.extrude != extrude ||
      o.extrudeColor != extrudeColor ||
      o.align != align;
}
