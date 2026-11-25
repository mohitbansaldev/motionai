import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../../core/engine/fx_math.dart';

/// Soft god rays streaming across the layer ([angle] = travel direction in degrees).
class LightRaysPainter extends CustomPainter {
  final double angle, amount, time;
  final Color color;
  final int seed;
  LightRaysPainter({required this.angle, required this.amount, required this.time, required this.color, required this.seed});

  static final Paint _ray = Paint()..blendMode = BlendMode.plus;
  static final Paint _glow = Paint()..blendMode = BlendMode.plus;

  @override
  void paint(Canvas canvas, Size size) {
    final a = (amount / 100).clamp(0.0, 1.0);
    if (a <= 0 || size.isEmpty) return;
    final th = angle * math.pi / 180;
    final dx = math.cos(th), dy = math.sin(th);
    final diag = math.sqrt(size.width * size.width + size.height * size.height);
    final c = size.center(Offset.zero);
    final src = c - Offset(dx, dy) * diag * 0.62;
    final len = diag * 1.4;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    _ray.shader = ui.Gradient.linear(src, src + Offset(dx, dy) * len,
        [color.withValues(alpha: 0.9), color.withValues(alpha: 0.35), color.withValues(alpha: 0)], const [0, 0.45, 1]);
    const rays = 9;
    for (int i = 0; i < rays; i++) {
      final off = (hash01(seed, i * 3) - 0.5) * 0.75;
      final half = 0.012 + 0.035 * hash01(seed, i * 3 + 1);
      final flick = 0.55 + 0.45 * math.sin(time * (0.35 + 0.5 * hash01(seed, i * 3 + 2)) + i * 1.7);
      final al = (a * (0.10 + 0.22 * hash01(seed, i + 50)) * flick).clamp(0.0, 1.0);
      final a0 = th + off - half, a1 = th + off + half;
      final path = Path()
        ..moveTo(src.dx, src.dy)
        ..lineTo(src.dx + math.cos(a0) * len, src.dy + math.sin(a0) * len)
        ..lineTo(src.dx + math.cos(a1) * len, src.dy + math.sin(a1) * len)
        ..close();
      _ray.color = Color.fromRGBO(255, 255, 255, al);
      canvas.drawPath(path, _ray);
    }
    final gr = diag * 0.45;
    _glow.shader = ui.Gradient.radial(src, gr, [color.withValues(alpha: 0.55 * a), color.withValues(alpha: 0)]);
    canvas.drawCircle(src, gr, _glow);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant LightRaysPainter o) =>
      o.time != time || o.angle != angle || o.amount != amount || o.color != color;
}

/// Glossy bevelled glass border with a diagonal highlight.
class GlassFramePainter extends CustomPainter {
  final double thickness, gloss;
  GlassFramePainter(this.thickness, this.gloss);

  static double radiusFor(double thickness) => thickness * 1.2 + 10;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final t = thickness.clamp(0.0, size.shortestSide / 3);
    final g = (gloss / 100).clamp(0.0, 1.0);
    final r = radiusFor(t);
    final outer = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(r));
    final inner = RRect.fromRectAndRadius((Offset.zero & size).deflate(t), Radius.circular(math.max(2.0, r - t)));
    if (t > 0) {
      final ring = Path()
        ..fillType = PathFillType.evenOdd
        ..addRRect(outer)
        ..addRRect(inner);
      canvas.drawPath(
        ring,
        Paint()
          ..shader = ui.Gradient.linear(Offset.zero, Offset(size.width, size.height), const [
            Color(0xB3FFFFFF),
            Color(0x4DB8D0E8),
            Color(0x26FFFFFF),
            Color(0x66FFFFFF),
          ], const [0, 0.35, 0.7, 1]),
      );
      // Bevel: light outer rim, dark inner rim + soft inner shadow.
      canvas.drawRRect(
          outer.deflate(0.75),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = const Color(0xCCFFFFFF));
      canvas.drawRRect(
          inner,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = const Color(0x80000000));
      canvas.save();
      canvas.clipRRect(inner);
      canvas.drawRRect(
          inner.inflate(t * 0.15),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = t * 0.5
            ..color = const Color(0x40000000)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(1.0, t * 0.25)));
      canvas.restore();
    }
    if (g > 0) {
      canvas.save();
      canvas.clipRRect(outer);
      final w = size.width, h = size.height;
      final band = Path()
        ..moveTo(w * 0.02, 0)
        ..lineTo(w * 0.42, 0)
        ..lineTo(w * 0.18, h)
        ..lineTo(-w * 0.22, h)
        ..close();
      canvas.drawPath(
        band,
        Paint()
          ..shader = ui.Gradient.linear(Offset(0, 0), Offset(w * 0.4, h * 0.6),
              [Color.fromRGBO(255, 255, 255, 0.38 * g), Color.fromRGBO(255, 255, 255, 0.04 * g)]),
      );
      final thin = Path()
        ..moveTo(w * 0.48, 0)
        ..lineTo(w * 0.53, 0)
        ..lineTo(w * 0.29, h)
        ..lineTo(w * 0.24, h)
        ..close();
      canvas.drawPath(thin, Paint()..color = Color.fromRGBO(255, 255, 255, 0.16 * g));
      canvas.drawLine(Offset(r, t * 0.35 + 1), Offset(w - r, t * 0.35 + 1),
          Paint()
            ..strokeWidth = math.max(1.0, t * 0.12)
            ..color = Color.fromRGBO(255, 255, 255, 0.55 * g));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant GlassFramePainter o) => o.thickness != thickness || o.gloss != gloss;
}

/// Jagged torn-paper edge along one side (0 top, 1 bottom, 2 left, 3 right).
class TornEdgeClipper extends CustomClipper<Path> {
  final int side;
  final double depth; // px
  final int seed;
  final double inset; // 0..1 how far the line sits inside the depth band
  TornEdgeClipper(this.side, this.depth, this.seed, {this.inset = 1});

  @override
  Path getClip(Size size) {
    final w = size.width, h = size.height;
    final horizontal = side <= 1;
    final len = horizontal ? w : h;
    final steps = math.max(8, (len / math.max(6.0, depth * 0.45)).round().clamp(8, 400));
    final pts = <Offset>[];
    for (int i = 0; i <= steps; i++) {
      final u = i / steps * len;
      final big = noise1(i * 0.18, seed) * 0.5 + 0.5;
      final small = hash01(seed + 17, i);
      final d = depth * inset * (0.25 + 0.45 * big + 0.3 * small);
      switch (side) {
        case 0:
          pts.add(Offset(u, d));
          break;
        case 1:
          pts.add(Offset(u, h - d));
          break;
        case 2:
          pts.add(Offset(d, u));
          break;
        default:
          pts.add(Offset(w - d, u));
      }
    }
    final p = Path();
    switch (side) {
      case 0:
        p.moveTo(0, h);
        p.lineTo(0, pts.first.dy);
        for (final o in pts) {
          p.lineTo(o.dx, o.dy);
        }
        p.lineTo(w, h);
        break;
      case 1:
        p.moveTo(0, 0);
        p.lineTo(w, 0);
        for (final o in pts.reversed) {
          p.lineTo(o.dx, o.dy);
        }
        break;
      case 2:
        p.moveTo(w, 0);
        for (final o in pts) {
          p.lineTo(o.dx, o.dy);
        }
        p.lineTo(w, h);
        break;
      default:
        p.moveTo(0, 0);
        for (final o in pts) {
          p.lineTo(o.dx, o.dy);
        }
        p.lineTo(0, h);
    }
    return p..close();
  }

  @override
  bool shouldReclip(covariant TornEdgeClipper o) => o.side != side || o.depth != depth || o.seed != seed || o.inset != inset;
}

/// Procedural reveal masks (iris / ink / smoke / wipe) for the `reveal` effect.
class RevealMask {
  static const kinds = ['iris', 'ink', 'smoke', 'wipe'];

  static final LinkedHashMap<String, ui.Image> _cache = LinkedHashMap();

  /// Shader whose alpha is the mask, in layer pixels of a [size] box.
  /// [progress] and [softness] 0..1, centre ([cx], [cy]) 0..1 of the box.
  static ui.Shader shader(int kind, double progress, double softness, double cx, double cy, int seed, Size size, {bool draft = false}) {
    final p = progress.clamp(0.0, 1.0);
    final w = size.width, h = size.height;
    final c = Offset(cx * w, cy * h);
    switch (kind) {
      case 0: // iris
        final far = [Offset.zero, Offset(w, 0), Offset(0, h), Offset(w, h)].map((o) => (o - c).distance).reduce(math.max);
        final soft = (softness * 0.35).clamp(0.0, 0.9);
        final r = math.max(0.5, far * p / (1 - soft));
        return ui.Gradient.radial(c, r, const [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
            [0, (1 - soft).clamp(0.0, 0.999), 1]);
      case 3: // wipe left → right
        final soft = math.max(1.0, w * softness * 0.3);
        final x = -soft + (w + soft * 2) * p;
        return ui.Gradient.linear(Offset(x - soft, 0), Offset(x, 0), const [Color(0xFFFFFFFF), Color(0x00FFFFFF)]);
      default:
        final res = draft ? 160.0 : 384.0;
        final k = res / math.max(1.0, math.max(w, h));
        final iw = math.max(4, (w * k).round()), ih = math.max(4, (h * k).round());
        final pq = (p * 400).round() / 400; // quantise so still frames reuse the image
        final key = '$kind|$seed|$pq|${(softness * 100).round()}|${(cx * 100).round()}|${(cy * 100).round()}|$iw|$ih';
        var img = _cache.remove(key);
        img ??= _draw(kind, pq, softness, cx, cy, seed, iw, ih);
        _cache[key] = img;
        while (_cache.length > 24) {
          final first = _cache.keys.first;
          _cache.remove(first)?.dispose();
        }
        return ui.ImageShader(img, TileMode.clamp, TileMode.clamp,
            Float64List.fromList([w / iw, 0, 0, 0, 0, h / ih, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]),
            filterQuality: FilterQuality.low);
    }
  }

  static ui.Image _draw(int kind, double p, double softness, double cx, double cy, int seed, int w, int h) {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final c = Offset(cx * w, cy * h);
    final far = [Offset.zero, Offset(w.toDouble(), 0), Offset(0, h.toDouble()), Offset(w.toDouble(), h.toDouble())]
        .map((o) => (o - c).distance)
        .reduce(math.max);
    final blur = 0.5 + softness * math.max(w, h) * 0.04;
    final paint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
    if (kind == 1) {
      // Ink bleed: a wobbly blob grows from the centre, droplets join it.
      final e = 1 - (1 - p) * (1 - p);
      final base = far * 1.25 * e;
      final ph1 = hash01(seed, 1) * 6.28, ph2 = hash01(seed, 2) * 6.28, ph3 = hash01(seed, 3) * 6.28;
      final path = Path();
      const n = 96;
      for (int i = 0; i <= n; i++) {
        final th = i / n * math.pi * 2;
        final r = base * (1 + 0.16 * math.sin(3 * th + ph1) + 0.09 * math.sin(5 * th + ph2) + 0.05 * math.sin(11 * th + ph3 + p * 3));
        final o = c + Offset(math.cos(th) * r, math.sin(th) * r);
        i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(path..close(), paint);
      for (int i = 0; i < 14; i++) {
        final appear = hash01(seed + 5, i) * 0.6;
        if (p < appear) continue;
        final g = ((p - appear) / 0.4).clamp(0.0, 1.0);
        final a = hash01(seed + 6, i) * math.pi * 2;
        final d = base * (0.85 + 0.45 * hash01(seed + 7, i));
        final rr = far * (0.04 + 0.08 * hash01(seed + 8, i)) * g;
        canvas.drawCircle(c + Offset(math.cos(a) * d, math.sin(a) * d), rr, paint);
      }
    } else {
      // Smoke dissolve: soft puffs fade in (nearest the centre first).
      const n = 110;
      for (int i = 0; i < n; i++) {
        final x = hash01(seed + 11, i) * w, y = hash01(seed + 12, i) * h;
        final dist = (Offset(x, y) - c).distance / math.max(1.0, far);
        final th = 0.75 * (0.55 * hash01(seed + 13, i) + 0.45 * dist);
        final a = ((p - th) / 0.22).clamp(0.0, 1.0);
        if (a <= 0) continue;
        final r = math.max(w, h) * (0.09 + 0.08 * hash01(seed + 14, i)) * (0.6 + 0.6 * a);
        canvas.drawCircle(
            Offset(x, y),
            r,
            Paint()
              ..color = Color.fromRGBO(255, 255, 255, a)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.45 + blur * 0.5));
      }
      final fill = ((p - 0.8) / 0.2).clamp(0.0, 1.0);
      if (fill > 0) canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Color.fromRGBO(255, 255, 255, fill));
    }
    final pic = rec.endRecording();
    final img = pic.toImageSync(w, h);
    pic.dispose();
    return img;
  }
}
