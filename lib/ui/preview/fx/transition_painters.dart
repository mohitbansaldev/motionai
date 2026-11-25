import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../../core/engine/fx_math.dart';

// V2-C: renderers for the documentary transition effects `burn_edge` and
// `page_curl` (see lib/core/presets/doc_transitions.dart). Pure widgets +
// canvas drawing, so the editor preview and the offscreen export draw the
// same thing (the burn mask is only computed at a lower resolution in draft).

/// The layer burns away from (cx, cy) and a few other spots: charred,
/// glowing edges and rising embers. [progress] 0..1.
class BurnEdgeFx extends StatelessWidget {
  final double progress, cx, cy, embers;
  final Color color;
  final int seed;
  final Size size;
  final bool draft;
  final Widget child;

  const BurnEdgeFx({
    super.key,
    required this.progress,
    required this.cx,
    required this.cy,
    required this.color,
    required this.embers,
    required this.seed,
    required this.size,
    required this.draft,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    if (p <= 0.001 || size.isEmpty) return child;
    if (p >= 0.999) return SizedBox(width: size.width, height: size.height);
    final m = BurnMask.images(p, cx, cy, seed, color, size, draft: draft);
    final scale = Float64List.fromList([size.width / m.w, 0, 0, 0, 0, size.height / m.h, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
    return Stack(children: [
      ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (_) => ui.ImageShader(m.keep, TileMode.clamp, TileMode.clamp, scale, filterQuality: FilterQuality.medium),
        child: child,
      ),
      Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(painter: _BurnOverlayPainter(m.edge, p, cx, cy, seed, color, embers.clamp(0.0, 1.0))),
        ),
      ),
    ]);
  }
}

/// Burn front geometry + cached mask images.
class BurnMask {
  static final LinkedHashMap<String, ({ui.Image keep, ui.Image edge, int w, int h})> _cache = LinkedHashMap();

  /// Burn seeds in a [w]×[h] box: (x, y, start progress, farthest corner distance).
  static List<(double, double, double, double)> seeds(double cx, double cy, int seed, double w, double h) {
    final out = <(double, double, double, double)>[];
    for (int i = 0; i < 4; i++) {
      final x = i == 0 ? cx * w : (0.1 + 0.8 * hash01(seed, i * 5 + 1)) * w;
      final y = i == 0 ? cy * h : (0.1 + 0.8 * hash01(seed, i * 5 + 2)) * h;
      final st = i == 0 ? 0.0 : 0.15 + 0.4 * hash01(seed, i * 5 + 3);
      var far = 0.0;
      for (final (px, py) in [(0.0, 0.0), (w, 0.0), (0.0, h), (w, h)]) {
        far = math.max(far, math.sqrt((px - x) * (px - x) + (py - y) * (py - y)));
      }
      out.add((x, y, st, far));
    }
    return out;
  }

  static double radius((double, double, double, double) s, double p) {
    final (_, _, st, far) = s;
    final q = ((p - st) / (1 - st)).clamp(0.0, 1.0);
    return q * far * 1.35;
  }

  /// Union of wobbly burn holes at progress [p].
  static Path path(List<(double, double, double, double)> seeds, double p, int seed) {
    final path = Path();
    for (int i = 0; i < seeds.length; i++) {
      final s = seeds[i];
      final r = radius(s, p);
      if (r <= 0.5) continue;
      final ph1 = hash01(seed + i, 11) * 6.28, ph2 = hash01(seed + i, 12) * 6.28, ph3 = hash01(seed + i, 13) * 6.28;
      const n = 72;
      for (int k = 0; k <= n; k++) {
        final th = k / n * math.pi * 2;
        final rr = r * (1 + 0.10 * math.sin(3 * th + ph1) + 0.06 * math.sin(7 * th + ph2) + 0.035 * math.sin(15 * th + ph3 + p * 4));
        final x = s.$1 + math.cos(th) * rr, y = s.$2 + math.sin(th) * rr;
        k == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      path.close();
    }
    return path;
  }

  static ({ui.Image keep, ui.Image edge, int w, int h}) images(double p, double cx, double cy, int seed, Color glow, Size size,
      {bool draft = false}) {
    final res = draft ? 240.0 : 640.0;
    final k = res / math.max(1.0, math.max(size.width, size.height));
    final iw = math.max(4, (size.width * k).round()), ih = math.max(4, (size.height * k).round());
    final pq = (p * 300).round() / 300;
    final key = '$seed|$pq|${(cx * 100).round()}|${(cy * 100).round()}|${glow.toARGB32()}|$iw|$ih';
    var hit = _cache.remove(key);
    hit ??= _draw(pq, cx, cy, seed, glow, iw, ih);
    _cache[key] = hit;
    while (_cache.length > 12) {
      final first = _cache.remove(_cache.keys.first);
      first?.keep.dispose();
      first?.edge.dispose();
    }
    return hit;
  }

  static ({ui.Image keep, ui.Image edge, int w, int h}) _draw(double p, double cx, double cy, int seed, Color glow, int w, int h) {
    final sd = seeds(cx, cy, seed, w.toDouble(), h.toDouble());
    final u = math.max(w, h) / 400; // blur unit
    final rect = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
    // Keep mask: opaque except the holes.
    final r1 = ui.PictureRecorder();
    final c1 = Canvas(r1);
    c1.drawRect(rect, Paint()..color = const Color(0xFFFFFFFF));
    c1.drawPath(path(sd, p, seed), Paint()
      ..blendMode = BlendMode.clear
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 0.8 * u));
    // Edge: scorch → char → glowing rim, holes cleared, a halo over the rim.
    final r2 = ui.PictureRecorder();
    final c2 = Canvas(r2);
    c2.saveLayer(rect, Paint());
    c2.drawPath(path(sd, p + 0.07, seed), Paint()
      ..color = const Color(0x803A1A06)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 5 * u));
    c2.drawPath(path(sd, p + 0.03, seed), Paint()
      ..color = const Color(0xE00E0602)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 1.6 * u));
    c2.drawPath(path(sd, p + 0.011, seed), Paint()
      ..color = glow
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 1.4 * u));
    c2.drawPath(path(sd, p, seed), Paint()
      ..blendMode = BlendMode.clear
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 0.8 * u));
    c2.restore();
    c2.drawPath(path(sd, p, seed), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5 * u
      ..color = glow.withValues(alpha: 0.85)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 * u));
    final pic1 = r1.endRecording(), pic2 = r2.endRecording();
    final keep = pic1.toImageSync(w, h), edge = pic2.toImageSync(w, h);
    pic1.dispose();
    pic2.dispose();
    return (keep: keep, edge: edge, w: w, h: h);
  }
}

class _BurnOverlayPainter extends CustomPainter {
  final ui.Image edge;
  final double p, cx, cy, embers;
  final int seed;
  final Color color;
  _BurnOverlayPainter(this.edge, this.p, this.cx, this.cy, this.seed, this.color, this.embers);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      edge,
      Rect.fromLTWH(0, 0, edge.width.toDouble(), edge.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
    if (embers <= 0) return;
    // Embers born on the burn front, rising and fading.
    final sd = BurnMask.seeds(cx, cy, seed, size.width, size.height);
    final unit = math.max(1.0, size.longestSide / 1280);
    final n = (embers * 26).round();
    final paint = Paint()..maskFilter = MaskFilter.blur(BlurStyle.normal, 1.2 * unit);
    const hot = Color(0xFFFFF2C4);
    for (int i = 0; i < sd.length; i++) {
      final s = sd[i];
      final st = s.$3;
      for (int k = 0; k < n; k++) {
        final pb = st + hash01(seed + 31 * i, k) * (1 - st) * 0.92;
        final q = (p - pb) / 0.16;
        if (q <= 0 || q >= 1) continue;
        final a = hash01(seed + 37 * i, k) * math.pi * 2;
        final r = BurnMask.radius(s, pb);
        final x = s.$1 + math.cos(a) * r + math.sin(k * 1.7 + q * 5) * size.width * 0.01;
        final y = s.$2 + math.sin(a) * r - q * size.height * 0.12;
        final rad = (1.0 + 2.4 * hash01(seed + 41 * i, k)) * (1 - q * 0.7) * unit;
        paint.color = Color.lerp(hot, color, q)!.withValues(alpha: math.pow(1 - q, 0.7).toDouble());
        canvas.drawCircle(Offset(x, y), rad, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BurnOverlayPainter o) => o.edge != edge || o.p != p || o.embers != embers || o.color != color;
}

// ---------------------------------------------------------------- page curl

/// The page peels from the corner opposite to [angle] (the direction the
/// fold travels, degrees; 180 = to the left) and folds back over itself,
/// showing the back of the page; what it uncovers is transparent.
class PageCurlFx extends StatelessWidget {
  final double progress, angle, shadow;
  final Color back;
  final Size size;
  final Widget child;

  const PageCurlFx({
    super.key,
    required this.progress,
    required this.angle,
    required this.shadow,
    required this.back,
    required this.size,
    required this.child,
  });

  /// (corner the peel starts from, unit direction, distance to the far corner).
  static (Offset, Offset, double) geometry(Size size, double angle) {
    final th = angle * math.pi / 180;
    final d = Offset(math.cos(th), math.sin(th));
    final corners = [Offset.zero, Offset(size.width, 0), Offset(size.width, size.height), Offset(0, size.height)];
    var p0 = corners.first;
    for (final c in corners) {
      if (c.dx * d.dx + c.dy * d.dy < p0.dx * d.dx + p0.dy * d.dy) p0 = c;
    }
    var far = 0.0;
    for (final c in corners) {
      far = math.max(far, (c - p0).dx * d.dx + (c - p0).dy * d.dy);
    }
    return (p0, d, far);
  }

  /// The page rectangle clipped to one side of the fold line.
  static List<Offset> half(Size size, Offset p0, Offset d, double s, {required bool far}) {
    double f(Offset x) => ((x - p0).dx * d.dx + (x - p0).dy * d.dy - s) * (far ? 1 : -1);
    final poly = [Offset.zero, Offset(size.width, 0), Offset(size.width, size.height), Offset(0, size.height)];
    final out = <Offset>[];
    for (int i = 0; i < poly.length; i++) {
      final a = poly[i], b = poly[(i + 1) % poly.length];
      final fa = f(a), fb = f(b);
      if (fa >= 0) out.add(a);
      if ((fa >= 0) != (fb >= 0)) {
        final t = fa / (fa - fb);
        out.add(Offset.lerp(a, b, t)!);
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    if (p <= 0.001 || size.isEmpty) return child;
    if (p >= 0.999) return SizedBox(width: size.width, height: size.height);
    final (p0, d, far) = geometry(size, angle);
    final s = p * far;
    final c = s + p0.dx * d.dx + p0.dy * d.dy;
    final a = 1 - 2 * d.dx * d.dx, b = -2 * d.dx * d.dy, e = 1 - 2 * d.dy * d.dy;
    final mirror = Matrix4(a, b, 0, 0, b, e, 0, 0, 0, 0, 1, 0, 2 * c * d.dx, 2 * c * d.dy, 0, 1);
    final front = half(size, p0, d, s, far: true);
    final flap = half(size, p0, d, s, far: false);
    return Stack(clipBehavior: Clip.none, children: [
      ClipPath(clipper: _PolyClipper(front), child: child),
      Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _CurlShadowPainter(flap, p0, d, s, shadow.clamp(0.0, 1.0))))),
      Transform(
        transform: mirror,
        child: ClipPath(
          clipper: _PolyClipper(flap),
          child: Stack(children: [
            child,
            Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _FlapPainter(p0, d, s, back, size)))),
          ]),
        ),
      ),
    ]);
  }
}

class _PolyClipper extends CustomClipper<Path> {
  final List<Offset> pts;
  _PolyClipper(this.pts);
  @override
  Path getClip(Size size) {
    final p = Path();
    if (pts.length < 3) return p;
    p.addPolygon(pts, true);
    return p;
  }

  @override
  bool shouldReclip(covariant _PolyClipper o) => true;
}

/// Back of the page (paper colour over a faint mirrored print) with the
/// curl shading: dark crease, highlight, falling off.
class _FlapPainter extends CustomPainter {
  final Offset p0, d;
  final double s;
  final Color back;
  final Size page;
  _FlapPainter(this.p0, this.d, this.s, this.back, this.page);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRect(r, Paint()..color = back.withValues(alpha: 0.88));
    final fold = p0 + d * s;
    final len = math.max(4.0, math.min(s, page.longestSide * 0.45));
    canvas.drawRect(
      r,
      Paint()
        ..shader = ui.Gradient.linear(fold, fold - d * len, const [
          Color(0x66000000),
          Color(0x40FFFFFF),
          Color(0x00000000),
          Color(0x30000000),
        ], const [0, 0.1, 0.5, 1]),
    );
  }

  @override
  bool shouldRepaint(covariant _FlapPainter o) => o.s != s || o.back != back || o.d != d;
}

/// Soft shadow of the lifted page on what it uncovers.
class _CurlShadowPainter extends CustomPainter {
  final List<Offset> area;
  final Offset p0, d;
  final double s, amount;
  _CurlShadowPainter(this.area, this.p0, this.d, this.s, this.amount);

  @override
  void paint(Canvas canvas, Size size) {
    if (amount <= 0 || area.length < 3) return;
    final fold = p0 + d * s;
    final len = size.longestSide * 0.05 + s * 0.12;
    canvas.save();
    canvas.clipPath(Path()..addPolygon(area, true));
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(fold, fold - d * len, [Color.fromRGBO(0, 0, 0, 0.55 * amount), const Color(0x00000000)]),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CurlShadowPainter o) => o.s != s || o.amount != amount || o.d != d;
}
