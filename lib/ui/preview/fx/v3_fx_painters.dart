import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../../core/engine/fx_math.dart';
import '../../../core/model/layer.dart';
import 'particles.dart' show ParticleAtlas;

// V3-D: renderers for the transition / mood / character FX effects
// (lib/core/model/effects_catalog.dart, V3-D block): burst, radial_blur,
// holes, frost, cracks, threshold, red_paint, lightning, slices, slant_wipe,
// slide_mount, puff. Everything is a pure function of the effect params, the
// layer timing and the time, so preview and export match.

/// The V3-D effect [e] around [child] ([l]'s content box), or null when [e]
/// is not one of them.
Widget? v3dEffect(Effect e, Widget child, Layer l, double time, {required bool draft, required bool playing}) {
  double p(String k, [int i = 0]) {
    final ap = e.params[k];
    if (ap == null) return 0;
    final v = ap.valueAt(time);
    return i < v.length ? v[i] : v[0];
  }

  Color rgb(String k) =>
      Color.fromARGB(255, p(k, 0).round().clamp(0, 255), p(k, 1).round().clamp(0, 255), p(k, 2).round().clamp(0, 255));
  final seed = stableHash(e.id) & 0xFFFF;
  final size = Size(l.width, l.height);
  final cheap = draft && playing;
  Widget over(CustomPainter painter) => Stack(clipBehavior: Clip.none, children: [
        child,
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: painter))),
      ]);

  switch (e.type) {
    case 'burst':
      final local = time - l.start;
      final b = BurstSpec(
        kind: p('kind').round(),
        origin: p('origin').round(),
        density: p('density').clamp(0.0, 100.0),
        color: rgb('color'),
        cut: p('cut'),
        rise: math.max(0.02, p('rise')),
        hold: math.max(0.0, p('hold')),
        clear: math.max(0.02, p('clear')),
        linger: math.max(0.0, p('linger')),
        preRoll: math.max(0.0, p('pre_roll')),
        cover: (p('cover') / 100).clamp(0.0, 1.0),
        seed: seed,
      );
      if (!b.visibleAt(local)) return child;
      return over(BurstPainter(b, local, cheap: cheap));
    case 'radial_blur':
      final a = (p('amount') / 100).clamp(0.0, 1.0);
      if (a <= 0.004) return child;
      return RadialBlurFx(amount: a, cx: p('cx') / 100, cy: p('cy') / 100, size: size, steps: cheap ? 5 : (draft ? 7 : 12), child: child);
    case 'holes':
      return HolesFx(
          progress: p('progress') / 100, count: p('count').round().clamp(5, 120), maxShare: (p('size') / 100).clamp(0.01, 0.4),
          rim: rgb('rim'), seed: seed, size: size, draft: draft, child: child);
    case 'frost':
      final pr = (p('progress') / 100).clamp(0.0, 1.0);
      if (pr <= 0.001) return child;
      return over(FrostPainter(pr, p('corner').round().clamp(0, 4), rgb('color'), seed));
    case 'cracks':
      final pr = (p('progress') / 100).clamp(0.0, 1.0);
      if (pr <= 0.001) return child;
      return over(CracksPainter(pr, p('cx') / 100, p('cy') / 100, rgb('color'), seed));
    case 'threshold':
      final a = (p('amount') / 100).clamp(0.0, 1.0);
      if (a <= 0.001) return child;
      return ColorFiltered(colorFilter: ColorFilter.matrix(V3Color.threshold(p('level') / 100, p('softness') / 100, a)), child: child);
    case 'red_paint':
      final a = (p('amount') / 100).clamp(0.0, 1.0);
      if (a <= 0.001) return child;
      return over(RedPaintPainter(a, rgb('color'), seed));
    case 'lightning':
      final f = (p('flash') / 100).clamp(0.0, 1.0), bo = (p('bolt') / 100).clamp(0.0, 1.0);
      if (f <= 0.001 && bo <= 0.001) return child;
      return over(LightningPainter(f, bo, p('x') / 100, p('variant').round(), rgb('color'), seed));
    case 'slices':
      final pr = (p('progress') / 100).clamp(0.0, 1.0);
      if (pr >= 0.999) return child;
      return SlicesFx(progress: pr, bands: p('bands').round().clamp(2, 12), stagger: (p('stagger') / 100).clamp(0.0, 1.0), size: size, child: child);
    case 'slant_wipe':
      final pr = (p('progress') / 100).clamp(0.0, 1.0);
      if (pr >= 0.999) return child;
      if (pr <= 0.001) return Opacity(opacity: 0, child: child);
      final g = SlantGeometry(size, p('angle'), p('side').round().clamp(0, 3), pr, (p('softness') / 100).clamp(0.0, 1.0));
      final masked = ShaderMask(blendMode: BlendMode.dstIn, shaderCallback: (_) => g.shader(), child: child);
      final edge = (p('edge') / 100).clamp(0.0, 1.0);
      if (edge <= 0.001) return masked;
      return Stack(clipBehavior: Clip.none, children: [
        masked,
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _SlantEdgePainter(g, edge)))),
      ]);
    case 'slide_mount':
      return over(SlideMountPainter(rgb('color'), rgb('print'), (p('window') / 100).clamp(0.3, 0.95), p('number').round().clamp(0, 99)));
    case 'puff':
      final u = l.duration <= 0 ? 1.0 : ((time - l.start) / l.duration).clamp(0.0, 1.0);
      if (u >= 0.999) return child;
      return over(PuffPainter(u, (p('amount') / 100).clamp(0.0, 2.0), rgb('color'), seed));
    default:
      return null;
  }
}

double _smooth(double x) {
  final t = x.clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

double _outCubic(double x) {
  final t = 1 - x.clamp(0.0, 1.0);
  return 1 - t * t * t;
}

/// Colour matrices of the V3-D colour effects.
class V3Color {
  /// High-contrast black & white cut at luminance [level] (0..1) with a
  /// [softness] (0..1) ramp, blended with the original by [amount].
  static List<double> threshold(double level, double softness, double amount) {
    final k = 1 / math.max(0.02, softness * 0.5);
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final off = (0.5 - k * level) * 255;
    final a = amount.clamp(0.0, 1.0);
    final m = <double>[];
    for (int c = 0; c < 3; c++) {
      m.addAll([
        k * lr * a + (c == 0 ? 1 - a : 0),
        k * lg * a + (c == 1 ? 1 - a : 0),
        k * lb * a + (c == 2 ? 1 - a : 0),
        0,
        off * a,
      ]);
    }
    m.addAll([0, 0, 0, 1, 0]);
    return m;
  }
}

// ------------------------------------------------------------------ burst

/// Timing and look of one `burst` (powder / debris) effect. Times are in
/// seconds after the layer start; full cover is centred on [cut].
class BurstSpec {
  final int kind, origin, seed;
  final double density, cut, rise, hold, clear, linger, preRoll, cover;
  final Color color;
  const BurstSpec({
    required this.kind,
    required this.origin,
    required this.density,
    required this.color,
    required this.cut,
    required this.rise,
    required this.hold,
    required this.clear,
    required this.linger,
    required this.preRoll,
    required this.cover,
    required this.seed,
  });

  double get tA => cut - hold / 2 - rise; // dense burst starts
  double get tF => cut - hold / 2; // full cover reached
  double get tE => cut + hold / 2; // cover starts clearing
  double get tC => tE + clear; // cover gone
  double get tL => tC + linger; // last flakes gone

  bool visibleAt(double t) => density > 0 && t >= tA - preRoll - 1e-6 && t <= tL + 1e-6;

  /// Share of the frame the solid veil covers (0..1) and its opacity at [t].
  (double, double) veil(double t) {
    if (t < tA || t > tC) return (0, 0);
    final front = t >= tF ? 1.0 : _outCubic((t - tA) / math.max(1e-6, tF - tA));
    final a = t <= tE ? cover : cover * (1 - _smooth((t - tE) / clear));
    return (front, a);
  }

  bool get shards => kind == 4 || kind == 5; // ice, glass
  bool get leaves => kind == 7;
}

class BurstPainter extends CustomPainter {
  final BurstSpec b;
  final double t;
  final bool cheap;
  BurstPainter(this.b, this.t, {this.cheap = false});

  static final Paint _atlasPaint = Paint()..filterQuality = FilterQuality.low;

  double _h(int i, int k) => hash01(b.seed * 131 + i * 7919, k);

  /// Entry point E (on/just outside the frame), travel direction D, span.
  (Offset, Offset, double) _geom(Size s) {
    final w = s.width, h = s.height;
    final diag = math.sqrt(w * w + h * h);
    switch (b.origin) {
      case 1: // left
        return (Offset(0, h / 2), const Offset(1, 0), w);
      case 2: // center
        return (Offset(w / 2, h / 2), Offset.zero, diag / 2);
      case 3: // top
        return (Offset(w / 2, 0), const Offset(0, 1), h);
      case 4: // bottom
        return (Offset(w / 2, h), const Offset(0, -1), h);
      case 5:
      case 6:
      case 7:
      case 8:
        final c = switch (b.origin) { 5 => Offset.zero, 6 => Offset(w, 0), 7 => Offset(0, h), _ => Offset(w, h) };
        final d = Offset(w / 2, h / 2) - c;
        return (c, d / d.distance, diag);
      default: // right
        return (Offset(w, h / 2), const Offset(-1, 0), w);
    }
  }

  Color _tint(int i, double alpha) {
    final base = b.color;
    final v = 0.82 + 0.18 * _h(i, 40);
    final hasColor = base.toARGB32() & 0xFFFFFF;
    int ch(double c) => (c * 255 * v).round().clamp(0, 255);
    if (b.leaves && hasColor == 0xFFFFFF) {
      const leaves = [0xFF6B8E23, 0xFF9ACD32, 0xFFD2691E, 0xFFB8860B, 0xFF8B4513];
      return Color(leaves[(_h(i, 41) * leaves.length).floor().clamp(0, leaves.length - 1)]).withValues(alpha: alpha.clamp(0.0, 1.0));
    }
    return Color.fromARGB((alpha.clamp(0.0, 1.0) * 255).round(), ch(base.r), ch(base.g), ch(base.b));
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final w = size.width, h = size.height;
    final ms = math.min(w, h);
    final (entry, dir, span) = _geom(size);
    final radial = dir == Offset.zero;
    final perp = Offset(-dir.dy, dir.dx);
    final perpSpan = radial ? 0.0 : (dir.dx.abs() > 0.5 ? h : w) * (dir.dx.abs() > 0.1 && dir.dy.abs() > 0.1 ? 1.4 : 1.0);
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    // 1. The solid veil: a front blasting in from the origin, full cover at
    //    the cut, then dissolving.
    final (front, va) = b.veil(t);
    if (va > 0.002 && front > 0.002) {
      final col = b.color;
      final c1 = col.withValues(alpha: va), c0 = col.withValues(alpha: 0);
      final soft = 0.22;
      final st = (front * (1 + soft)).clamp(0.0, 1.0 + soft);
      final stops = [0.0, (st - soft).clamp(0.0, 1.0), st.clamp(0.0001, 1.0)];
      if (stops[1] >= stops[2]) stops[1] = stops[2] - 0.0001;
      if (stops[1] < 0) stops[1] = 0;
      final ui.Shader sh;
      if (radial) {
        sh = ui.Gradient.radial(entry, span * 1.15, [c1, c1, c0], stops);
      } else {
        sh = ui.Gradient.linear(entry - dir * (span * 0.05), entry + dir * (span * 1.2), [c1, c1, c0], stops);
      }
      canvas.drawRect(Offset.zero & size, Paint()..shader = sh);
    }

    // 2. Puffs (powder) / chunks riding the front, 3. flakes and shards with
    //    drag, 4. sparse lead-in debris. All as atlas sprites (one draw call).
    final dens = b.density / 100;
    final nPuff = b.shards ? (dens * 28).round() : (dens * (cheap ? 45 : 85)).round();
    final nFlake = (dens * (cheap ? 70 : (b.shards ? 120 : 150))).round();
    final nPre = b.preRoll > 0 ? (dens * 26).round() : 0;
    final xs = <double>[], rects = <double>[];
    final cols = <int>[];
    final rects0 = ParticleAtlas.rects;
    void sprite(int sp, double x, double y, double longest, double rot, Color c) {
      if (c.a <= 0.004 || longest < 0.3) return;
      final r = rects0[sp];
      final sc = longest / math.max(r.width, r.height);
      final scos = math.cos(rot) * sc, ssin = math.sin(rot) * sc;
      final ax = r.width / 2, ay = r.height / 2;
      xs.addAll([scos, ssin, x - scos * ax + ssin * ay, y - ssin * ax - scos * ay]);
      rects.addAll([r.left, r.top, r.right, r.bottom]);
      cols.add(c.toARGB32());
    }

    final env = t <= b.tE ? 1.0 : 1 - _smooth((t - b.tE) / (b.clear * 1.5));
    for (int i = 0; i < nPuff; i++) {
      final bi = b.tA + (b.tF - b.tA) * 0.85 * _h(i, 1);
      if (t < bi) continue;
      final age = t - bi;
      final life = math.max(0.05, b.tC + b.clear * 0.5 - bi);
      final q = (age / life).clamp(0.0, 1.0);
      if (q >= 1) continue;
      final Offset p0, v;
      if (radial) {
        final a = _h(i, 2) * math.pi * 2;
        v = Offset(math.cos(a), math.sin(a));
        p0 = entry + v * (ms * 0.05 * _h(i, 3));
      } else {
        v = (dir + perp * ((_h(i, 4) - 0.5) * 0.5));
        p0 = entry + perp * ((_h(i, 2) - 0.5) * perpSpan * 1.15) - dir * (ms * 0.1);
      }
      final dist = span * (0.55 + 0.9 * _h(i, 5)) * _outCubic(q * 1.6);
      final pos = p0 + v * dist;
      final r = ms * (0.12 + 0.22 * _h(i, 6)) * (0.55 + 1.5 * _outCubic(q * 1.3));
      final a = env * (0.45 + 0.45 * _h(i, 7)) * math.min(1.0, age / 0.06) * b.cover;
      sprite(b.shards ? 0 : (_h(i, 8) < 0.5 ? 8 : 0), pos.dx, pos.dy, r * 2, _h(i, 9) * 6.28, _tint(i, a));
    }

    for (int i = 0; i < nFlake + nPre; i++) {
      final pre = i >= nFlake;
      final j = i + 1000;
      final bi = pre ? b.tA - b.preRoll * _h(j, 1) : b.tA + (b.tF - b.tA) * _h(j, 1);
      if (t < bi) continue;
      final age = t - bi;
      final Offset p0, v0;
      final speed = (pre ? 0.25 : 1.6 + 2.2 * _h(j, 3)) * span; // px/s
      if (radial) {
        final a = _h(j, 2) * math.pi * 2;
        final u = Offset(math.cos(a), math.sin(a));
        p0 = entry + u * (ms * 0.04 * _h(j, 4));
        v0 = u * speed;
      } else {
        p0 = entry + perp * ((_h(j, 2) - 0.5) * perpSpan * 1.2) - dir * (ms * 0.02);
        v0 = (dir + perp * ((_h(j, 4) - 0.5) * 0.7)) * speed;
      }
      // Drag: fast at first, settling into a slow drift over the incoming shot.
      const k = 3.2;
      final dragged = (1 - math.exp(-k * age)) / k;
      final fall = ms * 0.05 * age * age;
      final pos = p0 + v0 * dragged + Offset(0, fall);
      final vel = v0 * math.exp(-k * age) + Offset(0, ms * 0.1 * age);
      final sp = vel.distance;
      // Toward the lens: some flakes grow big as they pass the camera.
      final near = _h(j, 6) < 0.25;
      var longest = ms * (b.shards ? 0.008 + 0.022 * _h(j, 5) : 0.003 + 0.008 * _h(j, 5));
      if (near) longest *= 1 + 5 * _smooth(age / 0.5);
      if (pre) longest *= 0.8 + 1.5 * _smooth(age / math.max(0.05, b.preRoll));
      var a = (0.55 + 0.45 * _h(j, 7)) * math.min(1.0, age / 0.04);
      if (t > b.tC) a *= 1 - _smooth((t - b.tC) / math.max(0.02, b.linger));
      if (pre && t > b.tF) a *= 1 - _smooth((t - b.tF) / 0.2);
      if (a <= 0.01) continue;
      final rot = math.atan2(vel.dy, vel.dx);
      // Motion blur: fast flakes become streaks along their velocity.
      final streak = sp / 40; // px travelled in ~1/40 s
      if (b.shards) {
        sprite(_h(j, 8) < 0.5 ? 2 : 4, pos.dx, pos.dy, longest + streak * 0.4, _h(j, 9) * 6.28 + age * (4 + 10 * _h(j, 10)), _tint(j, a));
      } else if (b.leaves) {
        sprite(3, pos.dx, pos.dy, longest * 3 + streak * 0.3, _h(j, 9) * 6.28 + age * 6, _tint(j, a));
      } else if (streak > longest * 2.5) {
        sprite(5, pos.dx, pos.dy, longest + streak, rot, _tint(j, a));
      } else {
        sprite(0, pos.dx, pos.dy, longest * 2.2, 0, _tint(j, a));
      }
    }

    final n = cols.length;
    if (n > 0) {
      _atlasPaint.blendMode = BlendMode.srcOver;
      canvas.drawRawAtlas(ParticleAtlas.image, Float32List.fromList(xs), Float32List.fromList(rects), Int32List.fromList(cols),
          BlendMode.modulate, null, _atlasPaint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant BurstPainter o) => o.t != t || o.b != b || o.cheap != cheap;
}

// ------------------------------------------------------------ radial blur

/// Zoom blur about (cx, cy) (0..1 of the box): an average of scaled copies.
class RadialBlurFx extends StatelessWidget {
  final double amount, cx, cy;
  final Size size;
  final int steps;
  final Widget child;
  const RadialBlurFx({super.key, required this.amount, required this.cx, required this.cy, required this.size, required this.steps, required this.child});

  @override
  Widget build(BuildContext context) {
    final c = Offset(cx * size.width, cy * size.height);
    final maxK = 0.32 * amount;
    final layers = <Widget>[];
    for (int i = 0; i < steps; i++) {
      final k = 1 + maxK * i / math.max(1, steps - 1);
      final m = Matrix4(k, 0, 0, 0, 0, k, 0, 0, 0, 0, 1, 0, c.dx * (1 - k), c.dy * (1 - k), 0, 1);
      final copy = i == 0 ? child : Transform(transform: m, child: child);
      // Running average: copy i drawn at 1/(i+1) over the previous ones.
      layers.add(i == 0 ? copy : Opacity(opacity: 1 / (i + 1), child: copy));
    }
    return ClipRect(child: Stack(clipBehavior: Clip.hardEdge, children: layers));
  }
}

// ------------------------------------------------------------------ holes

/// Burned holes opening in the layer (30–60 by default), brown charred rims.
class HolesFx extends StatelessWidget {
  final double progress, maxShare;
  final int count, seed;
  final Color rim;
  final Size size;
  final bool draft;
  final Widget child;
  const HolesFx({
    super.key,
    required this.progress,
    required this.count,
    required this.maxShare,
    required this.rim,
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
    final m = HoleMask.images(p, count, maxShare, seed, rim, size, draft: draft);
    final scale = Float64List.fromList([size.width / m.w, 0, 0, 0, 0, size.height / m.h, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
    return Stack(children: [
      ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (_) => ui.ImageShader(m.keep, TileMode.clamp, TileMode.clamp, scale, filterQuality: FilterQuality.medium),
        child: child,
      ),
      Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(painter: _ImagePainter(m.edge)),
        ),
      ),
    ]);
  }
}

class _ImagePainter extends CustomPainter {
  final ui.Image img;
  _ImagePainter(this.img);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), Offset.zero & size,
        Paint()..filterQuality = FilterQuality.medium);
  }

  @override
  bool shouldRepaint(covariant _ImagePainter o) => o.img != img;
}

class HoleMask {
  static final LinkedHashMap<String, ({ui.Image keep, ui.Image edge, int w, int h})> _cache = LinkedHashMap();

  /// Hole [i] in a [w]×[h] box at progress [p]: (x, y, radius).
  static (double, double, double) hole(int i, double p, int seed, double maxShare, double w, double h) {
    final x = hash01(seed, i * 5 + 1) * w, y = hash01(seed, i * 5 + 2) * h;
    final st = 0.42 * hash01(seed, i * 5 + 3);
    final share = 0.02 + (math.max(0.021, maxShare) - 0.02) * math.pow(hash01(seed, i * 5 + 4), 1.6).toDouble();
    final rMax = share * w / 2;
    final q = ((p - st) / 0.3).clamp(0.0, 1.0);
    final diag = math.sqrt(w * w + h * h);
    final late = math.pow(math.max(0.0, (p - 0.62) / 0.38), 2).toDouble();
    return (x, y, rMax * _outCubic(q) + late * diag * (0.3 + 0.4 * hash01(seed, i * 5 + 5)));
  }

  static Path path(double p, int count, double maxShare, int seed, double w, double h, double grow, double add) {
    final path = Path();
    for (int i = 0; i < count; i++) {
      final (x, y, r) = hole(i, p, seed, maxShare, w, h);
      if (r <= 0.3) continue;
      final rr = r * grow + add;
      // Slightly wobbly circle (burnt paper, not a punch).
      const n = 28;
      for (int k = 0; k <= n; k++) {
        final th = k / n * math.pi * 2;
        final wob = 1 + 0.08 * math.sin(th * 3 + hash01(seed + i, 7) * 6.28) + 0.05 * math.sin(th * 7 + hash01(seed + i, 8) * 6.28);
        final px = x + math.cos(th) * rr * wob, py = y + math.sin(th) * rr * wob;
        k == 0 ? path.moveTo(px, py) : path.lineTo(px, py);
      }
      path.close();
    }
    return path;
  }

  static ({ui.Image keep, ui.Image edge, int w, int h}) images(double p, int count, double maxShare, int seed, Color rim, Size size,
      {bool draft = false}) {
    final res = draft ? 240.0 : 640.0;
    final k = res / math.max(1.0, math.max(size.width, size.height));
    final iw = math.max(4, (size.width * k).round()), ih = math.max(4, (size.height * k).round());
    final pq = (p * 300).round() / 300;
    final key = '$seed|$pq|$count|${(maxShare * 1000).round()}|${rim.toARGB32()}|$iw|$ih';
    var hit = _cache.remove(key);
    hit ??= _draw(pq, count, maxShare, seed, rim, iw, ih);
    _cache[key] = hit;
    while (_cache.length > 12) {
      final first = _cache.remove(_cache.keys.first);
      first?.keep.dispose();
      first?.edge.dispose();
    }
    return hit;
  }

  static ({ui.Image keep, ui.Image edge, int w, int h}) _draw(double p, int count, double maxShare, int seed, Color rim, int w, int h) {
    final fw = w.toDouble(), fh = h.toDouble();
    final u = math.max(w, h) / 400;
    final rect = Rect.fromLTWH(0, 0, fw, fh);
    final holes = path(p, count, maxShare, seed, fw, fh, 1, 0);
    final r1 = ui.PictureRecorder();
    final c1 = Canvas(r1);
    c1.drawRect(rect, Paint()..color = const Color(0xFFFFFFFF));
    c1.drawPath(holes, Paint()
      ..blendMode = BlendMode.clear
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 0.6 * u));
    final r2 = ui.PictureRecorder();
    final c2 = Canvas(r2);
    c2.saveLayer(rect, Paint());
    c2.drawPath(path(p, count, maxShare, seed, fw, fh, 1.22, 2.5 * u), Paint()
      ..color = const Color(0x8C2A1406)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 * u));
    c2.drawPath(path(p, count, maxShare, seed, fw, fh, 1.08, 1.2 * u), Paint()
      ..color = rim.withValues(alpha: 0.95)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 1.2 * u));
    c2.drawPath(path(p, count, maxShare, seed, fw, fh, 1.02, 0.4 * u), Paint()
      ..color = const Color(0xFFFF9A3A).withValues(alpha: 0.55)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 0.8 * u));
    c2.drawPath(holes, Paint()
      ..blendMode = BlendMode.clear
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 0.6 * u));
    c2.restore();
    final pic1 = r1.endRecording(), pic2 = r2.endRecording();
    final keep = pic1.toImageSync(w, h), edge = pic2.toImageSync(w, h);
    pic1.dispose();
    pic2.dispose();
    return (keep: keep, edge: edge, w: w, h: h);
  }
}

// ------------------------------------------------------------------ frost

/// Ice crystals (fern-like dendrites) growing from a corner, with a frosty haze.
class FrostPainter extends CustomPainter {
  final double p;
  final int corner, seed;
  final Color color;
  FrostPainter(this.p, this.corner, this.color, this.seed);

  /// Segments (x0, y0, x1, y1, distance 0..1 from the root, width share).
  static List<(double, double, double, double, double, double)> segments(int corner, int seed, double w, double h) {
    final out = <(double, double, double, double, double, double)>[];
    final diag = math.sqrt(w * w + h * h);
    final root = switch (corner) { 1 => Offset(w, 0), 2 => Offset(0, h), 3 => Offset(w, h), 4 => Offset(w / 2, h / 2), _ => Offset.zero };
    final aim = math.atan2(h / 2 - root.dy, w / 2 - root.dx);
    final spread = corner == 4 ? math.pi * 2 : math.pi * 0.62;
    final reach = corner == 4 ? diag * 0.62 : diag * 1.08;
    final mains = corner == 4 ? 9 : 7;
    for (int m = 0; m < mains; m++) {
      var a = corner == 4 ? m / mains * math.pi * 2 : aim + (m / (mains - 1) - 0.5) * spread;
      a += (hash01(seed, m * 13) - 0.5) * 0.18;
      var x = root.dx, y = root.dy;
      final len = reach * (0.7 + 0.3 * hash01(seed, m * 13 + 1));
      const steps = 16;
      for (int s = 0; s < steps; s++) {
        final seg = len / steps;
        a += (hash01(seed + m, s * 7 + 2) - 0.5) * 0.22;
        final nx = x + math.cos(a) * seg, ny = y + math.sin(a) * seg;
        final d0 = s / steps * (len / reach);
        out.add((x, y, nx, ny, d0, 1 - s / steps * 0.7));
        // Side needles (dendrites) at ±60°.
        for (final side in const [-1.0, 1.0]) {
          if (hash01(seed + m * 3 + s, side > 0 ? 5 : 6) < 0.25) continue;
          final ba = a + side * (1.0 + 0.2 * hash01(seed + s, m + 9));
          final bl = seg * (1.2 + 1.6 * hash01(seed + m, s + 31)) * (1 - s / steps * 0.6);
          var bx = x, by = y;
          for (int q = 0; q < 3; q++) {
            final ex = bx + math.cos(ba) * bl / 3, ey = by + math.sin(ba) * bl / 3;
            out.add((bx, by, ex, ey, d0 + (q + 1) / 3 * 0.06, 0.45 * (1 - q / 3)));
            bx = ex;
            by = ey;
          }
        }
        x = nx;
        y = ny;
      }
    }
    return out;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final w = size.width, h = size.height;
    final u = math.max(1.0, size.longestSide / 1280);
    final diag = math.sqrt(w * w + h * h);
    final root = switch (corner) { 1 => Offset(w, 0), 2 => Offset(0, h), 3 => Offset(w, h), 4 => Offset(w / 2, h / 2), _ => Offset.zero };
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    // Frosty haze ahead of the crystals.
    final hr = math.max(1.0, diag * 1.1 * p);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(root, hr, [color.withValues(alpha: 0.42 * math.min(1.0, p * 1.4)), color.withValues(alpha: 0.12 * p), color.withValues(alpha: 0)],
            const [0, 0.7, 1]),
    );
    final glow = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 * u);
    final core = Paint()
      ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final reach = p * 1.05;
    for (final (x0, y0, x1, y1, d, wd) in segments(corner, seed, w, h)) {
      if (d > reach) continue;
      final k = ((reach - d) / 0.04).clamp(0.0, 1.0); // the growing tip
      final ex = x0 + (x1 - x0) * k, ey = y0 + (y1 - y0) * k;
      glow.strokeWidth = (5 * wd + 1.5) * u;
      core.strokeWidth = (1.6 * wd + 0.5) * u;
      canvas.drawLine(Offset(x0, y0), Offset(ex, ey), glow);
      canvas.drawLine(Offset(x0, y0), Offset(ex, ey), core);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant FrostPainter o) => o.p != p || o.corner != corner || o.color != color || o.seed != seed;
}

// ----------------------------------------------------------------- cracks

/// Radial cracks spreading from an impact point (shatter lead-in).
class CracksPainter extends CustomPainter {
  final double p, cx, cy;
  final Color color;
  final int seed;
  CracksPainter(this.p, this.cx, this.cy, this.color, this.seed);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final w = size.width, h = size.height;
    final u = math.max(1.0, size.longestSide / 1280);
    final c = Offset(cx * w, cy * h);
    final reach = math.sqrt(w * w + h * h) * 0.8;
    final dark = Paint()
      ..color = const Color(0x8C000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6 * u
      ..strokeCap = StrokeCap.round;
    final light = Paint()
      ..color = color.withValues(alpha: 0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 * u
      ..strokeCap = StrokeCap.round;
    const mains = 11;
    final ends = <List<Offset>>[];
    for (int m = 0; m < mains; m++) {
      var a = m / mains * math.pi * 2 + (hash01(seed, m) - 0.5) * 0.4;
      final pts = <Offset>[c];
      var pt = c;
      const steps = 12;
      final len = reach * (0.55 + 0.45 * hash01(seed, m + 50));
      for (int s = 1; s <= steps; s++) {
        a += (hash01(seed + m, s) - 0.5) * 0.35;
        pt = pt + Offset(math.cos(a), math.sin(a)) * (len / steps);
        pts.add(pt);
      }
      ends.add(pts);
      final shown = (p * 1.25 * steps).clamp(0.0, steps.toDouble());
      final path = Path()..moveTo(c.dx, c.dy);
      for (int s = 1; s <= shown.floor(); s++) {
        path.lineTo(pts[s].dx, pts[s].dy);
      }
      final f = shown - shown.floor();
      if (shown.floor() < steps && f > 0) {
        final q = Offset.lerp(pts[shown.floor()], pts[shown.floor() + 1], f)!;
        path.lineTo(q.dx, q.dy);
      }
      canvas.drawPath(path.shift(Offset(u, u)), dark);
      canvas.drawPath(path, light);
    }
    // Concentric links between neighbouring cracks (appear later).
    for (final ring in const [3, 6, 9]) {
      final q = ((p - ring / 14) / 0.25).clamp(0.0, 1.0);
      if (q <= 0) continue;
      final path = Path();
      for (int m = 0; m < mains; m++) {
        if (hash01(seed + ring, m) < 0.3) continue;
        final a = ends[m][ring], b = ends[(m + 1) % mains][ring];
        final mid = Offset.lerp(a, b, 0.5)! + Offset((hash01(seed, m + ring * 3) - 0.5) * 12 * u, (hash01(seed, m + ring * 5) - 0.5) * 12 * u);
        final e = Offset.lerp(a, mid, q * 2)!;
        path.moveTo(a.dx, a.dy);
        if (q <= 0.5) {
          path.lineTo(e.dx, e.dy);
        } else {
          path.lineTo(mid.dx, mid.dy);
          final e2 = Offset.lerp(mid, b, (q - 0.5) * 2)!;
          path.lineTo(e2.dx, e2.dy);
        }
      }
      canvas.drawPath(path.shift(Offset(u, u)), dark);
      canvas.drawPath(path, light);
    }
    // Bright impact point.
    canvas.drawCircle(c, 10 * u * math.min(1.0, p * 3), Paint()
      ..color = color.withValues(alpha: 0.6)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 * u));
  }

  @override
  bool shouldRepaint(covariant CracksPainter o) => o.p != p || o.cx != cx || o.cy != cy || o.color != color;
}

// -------------------------------------------------------------- red paint

/// Thick red brush strokes and splatter over the picture (recap montage look).
class RedPaintPainter extends CustomPainter {
  final double amount;
  final Color color;
  final int seed;
  RedPaintPainter(this.amount, this.color, this.seed);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final w = size.width, h = size.height;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final mul = Paint()
      ..color = color.withValues(alpha: 0.85 * amount)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..blendMode = BlendMode.multiply;
    final top = Paint()
      ..color = color.withValues(alpha: 0.4 * amount)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (int s = 0; s < 4; s++) {
      final y0 = h * (0.12 + 0.76 * hash01(seed, s * 11 + 1));
      final tilt = (hash01(seed, s * 11 + 2) - 0.5) * h * 0.35;
      final thick = h * (0.06 + 0.08 * hash01(seed, s * 11 + 3));
      for (int pass = 0; pass < 3; pass++) {
        final path = Path();
        const n = 14;
        for (int i = 0; i <= n; i++) {
          final x = -w * 0.05 + w * 1.1 * i / n;
          final y = y0 + tilt * (i / n - 0.5) + math.sin(i * 0.9 + s) * h * 0.02 + (hash01(seed + pass, s * 31 + i) - 0.5) * thick * 0.25;
          i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
        }
        mul.strokeWidth = thick * (1 - pass * 0.25);
        top.strokeWidth = thick * (1 - pass * 0.25);
        canvas.drawPath(path, mul);
        canvas.drawPath(path, top);
      }
    }
    // Splatter.
    final dot = Paint()..color = color.withValues(alpha: 0.85 * amount);
    for (int i = 0; i < 40; i++) {
      final x = hash01(seed, 500 + i) * w, y = hash01(seed, 600 + i) * h;
      final r = h * (0.002 + 0.012 * math.pow(hash01(seed, 700 + i), 3).toDouble());
      canvas.drawCircle(Offset(x, y), r, dot);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant RedPaintPainter o) => o.amount != amount || o.color != color || o.seed != seed;
}

// -------------------------------------------------------------- lightning

/// Sky flash + a jagged bolt with branches and glow.
class LightningPainter extends CustomPainter {
  final double flash, bolt, x;
  final int variant, seed;
  final Color color;
  LightningPainter(this.flash, this.bolt, this.x, this.variant, this.color, this.seed);

  /// Jagged polyline from [a] to [b] (midpoint displacement, deterministic).
  static List<Offset> boltPath(int seed, Offset a, Offset b) {
    var pts = <Offset>[a, b];
    var amp = (b - a).distance * 0.18;
    for (int level = 0; level < 6; level++) {
      final next = <Offset>[pts.first];
      for (int i = 0; i < pts.length - 1; i++) {
        final p0 = pts[i], p1 = pts[i + 1];
        final m = Offset.lerp(p0, p1, 0.5)! + Offset((hash01(seed + level * 97, i) - 0.5) * amp, (hash01(seed + level * 89, i + 7) - 0.5) * amp * 0.3);
        next.addAll([m, p1]);
      }
      pts = next;
      amp *= 0.55;
    }
    return pts;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final w = size.width, h = size.height;
    final u = math.max(1.0, size.longestSide / 1280);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (flash > 0.001) {
      canvas.drawRect(Offset.zero & size, Paint()..color = color.withValues(alpha: 0.55 * flash));
      canvas.drawRect(Offset.zero & size, Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.radial(Offset(x * w, 0), h * 1.1, [color.withValues(alpha: 0.5 * flash), color.withValues(alpha: 0)]));
    }
    if (bolt > 0.001) {
      final s = seed + variant * 7717;
      final top = Offset(x * w, -h * 0.02);
      final bottom = Offset(x * w + (hash01(s, 1) - 0.5) * w * 0.18, h * (0.7 + 0.25 * hash01(s, 2)));
      final main = boltPath(s, top, bottom);
      final paths = <(List<Offset>, double)>[(main, 1.0)];
      for (int b = 0; b < 3; b++) {
        final i = (main.length * (0.2 + 0.5 * hash01(s, 40 + b))).floor().clamp(1, main.length - 2);
        final st = main[i];
        final end = st + Offset((hash01(s, 50 + b) - 0.5) * w * 0.35, h * (0.12 + 0.2 * hash01(s, 60 + b)));
        paths.add((boltPath(s + 300 + b, st, end), 0.5));
      }
      for (final (pts, wt) in paths) {
        final path = Path()..moveTo(pts.first.dx, pts.first.dy);
        for (final q in pts.skip(1)) {
          path.lineTo(q.dx, q.dy);
        }
        canvas.drawPath(path, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 16 * u * wt
          ..color = color.withValues(alpha: 0.35 * bolt)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 12 * u));
        canvas.drawPath(path, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5 * u * wt
          ..color = color.withValues(alpha: 0.75 * bolt)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 * u));
        canvas.drawPath(path, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8 * u * wt
          ..strokeJoin = StrokeJoin.round
          ..color = const Color(0xFFFFFFFF).withValues(alpha: bolt));
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant LightningPainter o) => o.flash != flash || o.bolt != bolt || o.x != x || o.variant != variant || o.color != color;
}

// ----------------------------------------------------------------- slices

/// Horizontal bands sliding in from alternating sides (eased, staggered,
/// motion-blurred while fast).
class SlicesFx extends StatelessWidget {
  final double progress, stagger;
  final int bands;
  final Size size;
  final Widget child;
  const SlicesFx({super.key, required this.progress, required this.bands, required this.stagger, required this.size, required this.child});

  /// Progress 0..1 of band [k].
  static double bandProgress(double p, int k, int n, double stagger) {
    final st = stagger * 0.6 / math.max(1, n - 1);
    final span = math.max(0.05, 1 - st * (n - 1));
    return ((p - st * k) / span).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final bh = size.height / bands;
    final out = <Widget>[];
    for (int k = 0; k < bands; k++) {
      final q = bandProgress(progress, k, bands, stagger);
      if (q <= 0) continue;
      final e = _outCubic(q);
      final dx = (1 - e) * size.width * (k.isEven ? -1 : 1);
      Widget band = Transform.translate(offset: Offset(dx, 0), child: child);
      final speed = 3 * (1 - q) * (1 - q); // derivative of the ease
      final sigma = math.min(36.0, speed * size.width * 0.012);
      if (sigma > 0.6 && q < 1) {
        band = ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: 0.01, tileMode: TileMode.decal), child: band);
      }
      out.add(ClipRect(clipper: _BandClip(k * bh, (k + 1) * bh + 0.5), child: band));
    }
    return SizedBox(width: size.width, height: size.height, child: Stack(clipBehavior: Clip.hardEdge, children: out));
  }
}

class _BandClip extends CustomClipper<Rect> {
  final double top, bottom;
  _BandClip(this.top, this.bottom);
  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, top, size.width, math.min(size.height, bottom));
  @override
  bool shouldReclip(covariant _BandClip o) => o.top != top || o.bottom != bottom;
}

// ------------------------------------------------------------- slant wipe

/// A straight edge tilted by [angle]° sweeping in from [side]
/// (0 left, 1 right, 2 top, 3 bottom); what it has passed is kept.
class SlantGeometry {
  final Size size;
  final double angle, progress, softness;
  final int side;
  SlantGeometry(this.size, this.angle, this.side, this.progress, this.softness);

  Offset get normal {
    final base = switch (side) { 1 => const Offset(-1, 0), 2 => const Offset(0, 1), 3 => const Offset(0, -1), _ => const Offset(1, 0) };
    final a = angle * math.pi / 180;
    return Offset(base.dx * math.cos(a) - base.dy * math.sin(a), base.dx * math.sin(a) + base.dy * math.cos(a));
  }

  /// Edge position (projection on [normal]) at the current progress.
  (double, double, double) get range {
    final n = normal;
    double lo = double.infinity, hi = -double.infinity;
    for (final c in [Offset.zero, Offset(size.width, 0), Offset(0, size.height), Offset(size.width, size.height)]) {
      final d = c.dx * n.dx + c.dy * n.dy;
      lo = math.min(lo, d);
      hi = math.max(hi, d);
    }
    final soft = math.max(0.75, softness * size.longestSide * 0.2);
    final s = lo - 1 + (hi - lo + soft + 2) * progress;
    return (s, soft, lo);
  }

  ui.Shader shader() {
    final n = normal;
    final (s, soft, _) = range;
    return ui.Gradient.linear(n * (s - soft), n * s, const [Color(0xFFFFFFFF), Color(0x00FFFFFF)]);
  }

  /// The edge line clipped to a generous box (for the highlight).
  (Offset, Offset) edgeLine() {
    final n = normal;
    final (s, soft, _) = range;
    final t = Offset(-n.dy, n.dx);
    final p = n * (s - soft / 2);
    final l = size.longestSide * 2;
    return (p - t * l, p + t * l);
  }
}

class _SlantEdgePainter extends CustomPainter {
  final SlantGeometry g;
  final double amount;
  _SlantEdgePainter(this.g, this.amount);
  @override
  void paint(Canvas canvas, Size size) {
    final (a, b) = g.edgeLine();
    final u = math.max(1.0, size.longestSide / 1280);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawLine(a, b, Paint()
      ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.5 * amount)
      ..strokeWidth = 10 * u
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 * u));
    canvas.drawLine(a, b, Paint()
      ..color = const Color(0xFFFFFFFF).withValues(alpha: amount)
      ..strokeWidth = 3 * u);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SlantEdgePainter o) => true;
}

// ------------------------------------------------------------ slide mount

/// A cream 35 mm slide mount with a picture window and magenta printing.
class SlideMountPainter extends CustomPainter {
  final Color color, print;
  final double window;
  final int number;
  SlideMountPainter(this.color, this.print, this.window, this.number);

  /// The window rect in a [size] mount.
  static Rect windowRect(Size size, double window) {
    final ww = size.width * window;
    final wh = math.min(size.height * window, ww * 2 / 3);
    return Rect.fromCenter(center: size.center(Offset.zero), width: ww, height: wh);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final r = Offset.zero & size;
    final win = windowRect(size, window);
    final rad = Radius.circular(size.shortestSide * 0.06);
    final card = Path()
      ..fillType = ui.PathFillType.evenOdd
      ..addRRect(RRect.fromRectAndRadius(r, rad))
      ..addRRect(RRect.fromRectAndRadius(win, Radius.circular(size.shortestSide * 0.015)));
    canvas.drawPath(card.shift(Offset(0, size.shortestSide * 0.02)), Paint()
      ..color = const Color(0x66000000)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.shortestSide * 0.025));
    canvas.drawPath(card, Paint()
      ..shader = ui.Gradient.linear(r.topLeft, r.bottomRight, [
        Color.lerp(color, const Color(0xFFFFFFFF), 0.25)!,
        color,
        Color.lerp(color, const Color(0xFF000000), 0.12)!,
      ], const [0, 0.55, 1]));
    // Bevel around the window.
    canvas.drawRRect(RRect.fromRectAndRadius(win.inflate(size.shortestSide * 0.012), Radius.circular(size.shortestSide * 0.02)), Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.shortestSide * 0.008
      ..color = const Color(0x33000000));
    // Magenta printing: frame number + generic film marks (no brand names).
    final fs = size.shortestSide * 0.045;
    void text(String s, Offset at, {double angle = 0}) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: TextStyle(color: print, fontSize: fs, fontWeight: FontWeight.w700, letterSpacing: fs * 0.2)),
        textDirection: TextDirection.ltr,
      )..layout();
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(angle);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    }

    final mid = (win.top + 0) / 2;
    text('◀ ${number.toString().padLeft(2, '0')}', Offset(win.left + win.width * 0.18, mid));
    text('35 MM · COLOR', Offset(win.center.dx + win.width * 0.12, mid));
    text('PROCESSED', Offset((win.right + size.width) / 2, size.height / 2), angle: math.pi / 2);
    canvas.drawCircle(Offset(win.left + win.width * 0.05, (win.bottom + size.height) / 2), fs * 0.3, Paint()..color = print);
  }

  @override
  bool shouldRepaint(covariant SlideMountPainter o) => o.color != color || o.print != print || o.window != window || o.number != number;
}

// ------------------------------------------------------------------- puff

/// Cartoon cloud puff: outlined white puffs burst out and fade ([u] 0..1).
class PuffPainter extends CustomPainter {
  final double u, amount;
  final Color color;
  final int seed;
  PuffPainter(this.u, this.amount, this.color, this.seed);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || amount <= 0) return;
    final c = size.center(Offset.zero);
    final base = size.shortestSide * 0.32 * amount;
    final e = _outCubic(u);
    final fade = (1 - u * u).clamp(0.0, 1.0);
    final fill = Paint()..color = color.withValues(alpha: fade);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, size.shortestSide * 0.012)
      ..color = const Color(0xFF111111).withValues(alpha: fade);
    const n = 8;
    for (int i = 0; i < n; i++) {
      final a = i / n * math.pi * 2 + hash01(seed, i) * 0.4;
      final d = base * (0.35 + 0.9 * e) * (0.8 + 0.4 * hash01(seed, i + 10));
      final r = base * (0.38 + 0.2 * hash01(seed, i + 20)) * (0.5 + 0.7 * e) * (1 - 0.6 * u);
      final o = c + Offset(math.cos(a) * d, math.sin(a) * d * 0.75);
      canvas.drawCircle(o, r, fill);
      canvas.drawCircle(o, r, line);
    }
    if (u < 0.5) {
      final r = base * (1 - u * 2) * 0.9;
      canvas.drawCircle(c, r, fill);
      canvas.drawCircle(c, r, line);
    }
  }

  @override
  bool shouldRepaint(covariant PuffPainter o) => o.u != u || o.amount != amount || o.color != color;
}
