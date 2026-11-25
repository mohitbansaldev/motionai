import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/model/layer.dart';

/// Builds the geometry of a shape layer in layer pixels.
Path buildShapePath(ShapeData s, Size size) {
  final inset = s.stroke != 0 ? s.strokeWidth / 2 : 0.0;
  final r = Rect.fromLTWH(inset, inset, math.max(1, size.width - inset * 2), math.max(1, size.height - inset * 2));
  switch (s.kind) {
    case 'rect':
      return Path()..addRRect(RRect.fromRectAndRadius(r, Radius.circular(s.corner)));
    case 'ellipse':
      return Path()..addOval(r);
    case 'polygon':
    case 'star':
      final n = math.max(3, s.sides);
      final star = s.kind == 'star';
      final cx = r.center.dx, cy = r.center.dy;
      final rx = r.width / 2, ry = r.height / 2;
      final path = Path();
      final count = star ? n * 2 : n;
      for (int i = 0; i < count; i++) {
        final a = -math.pi / 2 + i * 2 * math.pi / count;
        final k = star && i.isOdd ? s.inner : 1.0;
        final p = Offset(cx + math.cos(a) * rx * k, cy + math.sin(a) * ry * k);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      return path..close();
    default:
      final path = Path();
      for (final ring in s.rings) {
        if (ring.length < 4) continue;
        final pts = [for (int i = 0; i + 1 < ring.length; i += 2) Offset(ring[i], ring[i + 1])];
        if (s.smooth && pts.length >= 3) {
          _catmullRom(path, pts, s.closed);
        } else {
          path.moveTo(pts.first.dx, pts.first.dy);
          for (final p in pts.skip(1)) {
            path.lineTo(p.dx, p.dy);
          }
          if (s.closed) path.close();
        }
      }
      return path;
  }
}

void _catmullRom(Path path, List<Offset> p, bool closed) {
  final n = p.length;
  Offset at(int i) => closed ? p[(i + n) % n] : p[i.clamp(0, n - 1)];
  path.moveTo(p[0].dx, p[0].dy);
  final segs = closed ? n : n - 1;
  for (int i = 0; i < segs; i++) {
    final p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2);
    final c1 = p1 + (p2 - p0) / 6;
    final c2 = p2 - (p3 - p1) / 6;
    path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
  }
  if (closed) path.close();
}

/// Keeps the part of [path] between [start] and [end] (0..1 of total length).
Path trimPath(Path path, double start, double end) {
  if (start <= 0.0001 && end >= 0.9999) return path;
  final metrics = path.computeMetrics().toList();
  final total = metrics.fold<double>(0, (a, m) => a + m.length);
  final a = total * start.clamp(0.0, 1.0), b = total * end.clamp(0.0, 1.0);
  final out = Path();
  double offset = 0;
  for (final m in metrics) {
    final s = (a - offset).clamp(0.0, m.length), e = (b - offset).clamp(0.0, m.length);
    if (e > s) out.addPath(m.extractPath(s, e), Offset.zero);
    offset += m.length;
  }
  return out;
}

Path dashPath(Path path, double on, double off) {
  final out = Path();
  for (final m in path.computeMetrics()) {
    double d = 0;
    while (d < m.length) {
      out.addPath(m.extractPath(d, math.min(d + on, m.length)), Offset.zero);
      d += on + off;
    }
  }
  return out;
}

class ShapePainter extends CustomPainter {
  final ShapeData shape;
  final double trimStart, trimEnd;

  /// Cheap fingerprint of the shape's look: edits mutate [shape] in place, so
  /// comparing the object alone would keep a stale picture.
  final int _sig;
  ShapePainter(this.shape, this.trimStart, this.trimEnd) : _sig = signature(shape);

  static int signature(ShapeData s) => Object.hash(
        s.kind, s.closed, s.smooth, s.sides, s.inner, s.corner, s.fill, s.fill2, s.stroke, s.strokeWidth,
        Object.hashAll(s.dash), s.arrowStart, s.arrowEnd,
        identityHashCode(s.rings), s.rings.length, // new points replace the list
      );

  @override
  void paint(Canvas canvas, Size size) {
    final s = shape;
    var path = trimPath(buildShapePath(s, size), trimStart, trimEnd);
    if (s.fill != 0 && s.closed) {
      final paint = Paint()..color = Color(s.fill);
      if (s.fill2 != 0) {
        paint.shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [Color(s.fill), Color(s.fill2)]);
      }
      canvas.drawPath(path, paint);
    }
    if (s.stroke != 0 && s.strokeWidth > 0) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..color = Color(s.stroke)
        ..strokeWidth = s.strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final stroked = s.dash.length >= 2 && s.dash[0] > 0 ? dashPath(path, s.dash[0], math.max(1, s.dash[1])) : path;
      canvas.drawPath(stroked, paint);
      if (s.arrowEnd || s.arrowStart) {
        final metrics = path.computeMetrics().toList();
        if (metrics.isNotEmpty) {
          final fillPaint = Paint()..color = Color(s.stroke);
          if (s.arrowEnd) {
            final m = metrics.last;
            final t = m.getTangentForOffset(m.length);
            if (t != null) _arrow(canvas, t.position, t.vector, s.strokeWidth, fillPaint);
          }
          if (s.arrowStart) {
            final m = metrics.first;
            final t = m.getTangentForOffset(0);
            if (t != null) _arrow(canvas, t.position, -t.vector, s.strokeWidth, fillPaint);
          }
        }
      }
    }
  }

  void _arrow(Canvas c, Offset tip, Offset dir, double w, Paint p) {
    final len = dir.distance;
    if (len == 0) return;
    final d = dir / len;
    final n = Offset(-d.dy, d.dx);
    final size = math.max(10.0, w * 3.2);
    final base = tip - d * size;
    c.drawPath(
      Path()
        ..moveTo(tip.dx + d.dx * w * 0.5, tip.dy + d.dy * w * 0.5)
        ..lineTo(base.dx + n.dx * size * 0.6, base.dy + n.dy * size * 0.6)
        ..lineTo(base.dx - n.dx * size * 0.6, base.dy - n.dy * size * 0.6)
        ..close(),
      p,
    );
  }

  @override
  bool shouldRepaint(covariant ShapePainter old) =>
      old.shape != shape || old._sig != _sig || old.trimStart != trimStart || old.trimEnd != trimEnd;
}

/// Which parts [MarkedTextPainter] draws: everything, or only the marks
/// behind the text (highlighter) / in front of it (circle, underline) when the
/// letters themselves are drawn by another painter (per-letter animators).
enum MarkLayer { all, behind, front }

/// Text with animated annotations (highlighter, circle, underline, colour),
/// optional outline and 3D extruded edge.
class MarkedTextPainter extends CustomPainter {
  final String text;
  final TextStyle style;
  final TextAlign align;
  final List<TextMark> marks;
  final double time;
  final double outline;
  final double extrude; // extruded edge depth px (0 = none)
  final Color extrudeColor;
  final bool draft;
  final MarkLayer layer;
  final int _marksSig;
  MarkedTextPainter({
    required this.text,
    required this.style,
    required this.align,
    required this.marks,
    required this.time,
    this.outline = 0,
    this.extrude = 0,
    this.extrudeColor = const Color(0xFF8A8A8A),
    this.draft = false,
    this.layer = MarkLayer.all,
  }) : _marksSig = Object.hashAll([for (final m in marks) Object.hash(m.phrase, m.style, m.color, m.start, m.duration)]);

  static double _progress(TextMark m, double t) => m.duration <= 0 ? (t >= m.start ? 1 : 0) : ((t - m.start) / m.duration).clamp(0.0, 1.0);
  double _p(TextMark m) => _progress(m, time);

  @override
  void paint(Canvas canvas, Size size) {
    final drawText = layer == MarkLayer.all;
    // Colour marks change the span colour; others are drawn around the text.
    final spans = <TextSpan>[];
    final colorMarks = marks.where((m) => m.style == 'color' && _p(m) > 0).toList();
    if (colorMarks.isEmpty) {
      spans.add(TextSpan(text: text));
    } else {
      var rest = 0;
      final ranges = <(int, int, Color)>[];
      for (final m in colorMarks) {
        final i = text.toLowerCase().indexOf(m.phrase.toLowerCase());
        if (i >= 0) ranges.add((i, i + m.phrase.length, Color(m.color)));
      }
      ranges.sort((a, b) => a.$1.compareTo(b.$1));
      for (final r in ranges) {
        if (r.$1 < rest) continue;
        spans.add(TextSpan(text: text.substring(rest, r.$1)));
        spans.add(TextSpan(text: text.substring(r.$1, r.$2), style: TextStyle(color: r.$3)));
        rest = r.$2;
      }
      spans.add(TextSpan(text: text.substring(rest)));
    }
    // Outline text needs a foreground paint and no plain colour.
    final baseStyle = outline > 0
        ? TextStyle(
            fontSize: style.fontSize,
            fontWeight: style.fontWeight,
            fontFamily: style.fontFamily,
            height: style.height,
            letterSpacing: style.letterSpacing,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = outline
              ..color = style.color ?? Colors.white,
          )
        : style;
    final tp = TextPainter(
      text: TextSpan(style: baseStyle, children: spans),
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width);
    final dx = switch (align) {
      TextAlign.left => 0.0,
      TextAlign.right => size.width - tp.width,
      _ => (size.width - tp.width) / 2,
    };
    final origin = Offset(dx, (size.height - tp.height) / 2);

    List<Rect> boxes(TextMark m) {
      final i = text.toLowerCase().indexOf(m.phrase.toLowerCase());
      if (i < 0) return const [];
      return tp
          .getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + m.phrase.length))
          .map((b) => b.toRect().shift(origin))
          .toList();
    }

    // Highlighter sweeps behind the text, line by line.
    for (final m in marks.where((m) => m.style == 'highlight' && layer != MarkLayer.front)) {
      final p = _p(m);
      if (p <= 0) continue;
      final bs = boxes(m);
      final total = bs.fold<double>(0, (a, b) => a + b.width);
      var budget = total * p;
      final paint = Paint()..color = Color(m.color);
      for (final b in bs) {
        if (budget <= 0) break;
        final w = math.min(b.width, budget);
        canvas.drawRect(Rect.fromLTWH(b.left - 2, b.top + b.height * 0.08, w + 4, b.height * 0.9), paint);
        budget -= b.width;
      }
    }
    if (drawText) {
      if (extrude > 0) {
        // Thick 3D edge: copies of the text in the edge colour, down-right.
        final depth = extrude.clamp(0.0, 400.0);
        final steps = draft ? math.min(depth.ceil(), 14) : depth.ceil();
        const dir = Offset(0.40998, 0.91209); // (0.45, 1) normalised, as GlyphTextPainter
        final step = dir * (depth / math.max(1, steps));
        final edge = TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              fontSize: style.fontSize,
              fontWeight: style.fontWeight,
              fontFamily: style.fontFamily,
              height: style.height,
              letterSpacing: style.letterSpacing,
              color: extrudeColor,
            ),
          ),
          textAlign: align,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: size.width);
        for (int k = steps; k >= 1; k--) {
          edge.paint(canvas, origin + step * k.toDouble());
        }
        edge.dispose();
      }
      tp.paint(canvas, origin);
    }
    // Hand-drawn circle / underline draw on top.
    for (final m in marks.where((m) => (m.style == 'circle' || m.style == 'underline') && layer != MarkLayer.behind)) {
      final p = _p(m);
      if (p <= 0) continue;
      final bs = boxes(m);
      if (bs.isEmpty) continue;
      final u = bs.reduce((a, b) => a.expandToInclude(b));
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..color = Color(m.color)
        ..strokeWidth = math.max(2.0, (style.fontSize ?? 40) * 0.08)
        ..strokeCap = StrokeCap.round;
      Path path;
      if (m.style == 'circle') {
        final r = u.inflate((style.fontSize ?? 40) * 0.25);
        path = Path();
        // Slightly more than a full turn, like a quick pen circle.
        for (int i = 0; i <= 64; i++) {
          final a = -math.pi * 0.6 + i / 64 * math.pi * 2.15;
          final wob = 1 + 0.04 * math.sin(i * 0.7);
          final pt = Offset(r.center.dx + math.cos(a) * r.width / 2 * wob, r.center.dy + math.sin(a) * r.height / 2 * wob);
          i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
        }
      } else {
        final y = u.bottom + 2;
        path = Path()
          ..moveTo(u.left, y)
          ..quadraticBezierTo(u.center.dx, y + 4, u.right, y - 1);
      }
      canvas.drawPath(trimPath(path, 0, p), paint);
    }
    tp.dispose();
  }

  @override
  bool shouldRepaint(covariant MarkedTextPainter old) {
    if (old.text != text ||
        old.style != style ||
        old.align != align ||
        old.outline != outline ||
        old.extrude != extrude ||
        old.extrudeColor != extrudeColor ||
        old.draft != draft ||
        old.layer != layer ||
        old._marksSig != _marksSig) {
      return true;
    }
    // Same text: repaint only while a mark is animating.
    for (final m in marks) {
      if (_progress(m, old.time) != _progress(m, time)) return true;
    }
    return false;
  }
}
