import 'dart:math' as math;
import 'dart:typed_data';

import 'text_clusters.dart'; // V2-F: Devanagari-safe letters

/// Pure, deterministic maths behind the motion FX (no Flutter imports), so
/// export frames match the preview exactly and everything is unit-testable.

/// Stable hash → 0..1 (same result on every run and device).
double hash01(int a, int b) {
  var h = (a * 374761393 + b * 668265263) & 0xFFFFFFFF;
  h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF;
  h = h ^ (h >> 16);
  return (h & 0xFFFFFF) / 0x1000000;
}

/// Stable 32-bit hash of a string (String.hashCode is not stable across runs).
int stableHash(String s) {
  var h = 0x811C9DC5;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
  }
  return h & 0x7FFFFFFF;
}

/// Smooth 1D value noise in about -1..1.
double noise1(double x, int seed) {
  final i = x.floor();
  final f = x - i;
  final u = f * f * (3 - 2 * f);
  final a = hash01(i, seed) * 2 - 1, b = hash01(i + 1, seed) * 2 - 1;
  return a + (b - a) * u;
}

// ------------------------------------------------------------------ particles

/// Sprite ids in the particle atlas (see lib/ui/preview/fx/particles.dart).
class Sprite {
  static const soft = 0, disc = 1, star = 2, leaf = 3, rect = 4, streak = 5, birdUp = 6, birdDown = 7, cloud = 8, drop = 9;
  static const count = 10;
}

/// Values per particle in the [ParticleSim.simulate] output buffer:
/// x, y (px), size (px, longest side), rotation (rad), alpha (0..1), sprite id, ARGB colour.
const int kParticleStride = 7;

/// Particle kind indices, same order as `kParticleKinds` in effects_catalog.
class PKind {
  static const confetti = 0, leaves = 1, stars = 2, rain = 3, snow = 4, smoke = 5, dust = 6, bokeh = 7, streaks = 8, birds = 9, clouds = 10;
  static const debris = 11, snowSpray = 12, ice = 13; // V3-D
}

class ParticleSim {
  static const _confetti = [0xFFFF3B30, 0xFFFFCC00, 0xFF34C759, 0xFF0A84FF, 0xFFBF5AF2, 0xFFFF2D55, 0xFFFFFFFF, 0xFFFF9500];
  static const _leaves = [0xFF6B8E23, 0xFF9ACD32, 0xFFD2691E, 0xFFCD853F, 0xFF8B4513, 0xFFB8860B, 0xFF556B2F];

  /// Particles at 100% amount, per kind.
  static const _base = [160, 60, 150, 380, 240, 34, 200, 36, 12, 14, 7, 70, 260, 90]; // V3-D: + debris, snow_spray, ice

  static int countFor(int kind, double amount) {
    final k = kind.clamp(0, _base.length - 1);
    if (amount <= 0) return 0;
    return math.max(1, (_base[k] * (amount / 100).clamp(0.0, 2.0)).round());
  }

  static double _wrap(double v, double lo, double span) => lo + ((v - lo) % span + span) % span;

  /// Fills [out] with [count] particles of [kind] at time [t] (seconds) for a
  /// [w]×[h] box. Pure function of its inputs. Returns how many were written.
  static int simulate({
    required int kind,
    required int count,
    required double t,
    required double w,
    required double h,
    required Float64List out,
    double speed = 1,
    double direction = 0,
    int color = 0xFFFFFFFF,
    int seed = 0,
  }) {
    final n = math.min(count, out.length ~/ kParticleStride);
    final ms = math.max(1.0, math.min(w, h));
    final dir = direction * math.pi / 180;
    final cd = math.cos(dir), sd = math.sin(dir);
    final rgb = color & 0x00FFFFFF;
    final isWhite = rgb == 0xFFFFFF;
    for (int i = 0; i < n; i++) {
      double r(int k) => hash01(seed * 131 + i * 7919 + kind * 104729, k);
      double x, y, size, rot = 0, alpha = 1;
      int sprite = Sprite.soft, col = color;
      // Natural velocity (px/s) before the direction rotation.
      double vx = 0, vy = 0;
      final mx = ms * 0.15, my = ms * 0.15; // wrap margins
      switch (kind) {
        case PKind.confetti:
        case PKind.leaves:
          final leaf = kind == PKind.leaves;
          vy = h * (leaf ? 0.07 + 0.07 * r(2) : 0.16 + 0.12 * r(2));
          vx = h * (r(9) - 0.5) * 0.04;
          size = ms * (leaf ? 0.03 + 0.025 * r(7) : 0.012 + 0.012 * r(7));
          sprite = leaf ? Sprite.leaf : Sprite.rect;
          col = leaf ? _leaves[(r(8) * _leaves.length).floor()] : _confetti[(r(8) * _confetti.length).floor()];
          if (!isWhite) col = (r(10) < 0.5) ? color : col;
          final swayA = ms * (leaf ? 0.06 : 0.025) * (0.4 + r(3)), swayF = 0.6 + 1.6 * r(4);
          final tt = t * speed;
          x = _wrap(w * r(0) + (vx * cd - vy * sd) * tt + math.sin(tt * swayF + r(5) * 6.28) * swayA, -mx, w + 2 * mx);
          y = _wrap(h * r(1) + (vx * sd + vy * cd) * tt, -my, h + 2 * my);
          rot = r(5) * 6.28 + (leaf ? math.sin(tt * swayF) * 1.2 : tt * (2 + 5 * r(6)));
          break;
        case PKind.rain:
          vy = h * (1.3 + 0.8 * r(2));
          size = ms * (0.035 + 0.04 * r(7));
          sprite = Sprite.drop;
          alpha = 0.3 + 0.4 * r(3);
          final tt = t * speed;
          x = _wrap(w * r(0) - vy * sd * tt, -mx, w + 2 * mx);
          y = _wrap(h * r(1) + vy * cd * tt, -my, h + 2 * my);
          rot = dir; // drop sprite points down
          break;
        case PKind.snow:
          vy = h * (0.05 + 0.08 * r(2));
          size = ms * (0.004 + 0.01 * r(7));
          alpha = 0.55 + 0.45 * r(3);
          final tt = t * speed;
          final sway = math.sin(tt * (0.5 + r(4)) + r(5) * 6.28) * ms * 0.02;
          x = _wrap(w * r(0) - vy * sd * tt + sway, -mx, w + 2 * mx);
          y = _wrap(h * r(1) + vy * cd * tt, -my, h + 2 * my);
          break;
        case PKind.stars:
          sprite = r(6) < 0.35 ? Sprite.star : Sprite.soft;
          size = ms * (sprite == Sprite.star ? 0.012 + 0.02 * r(7) : 0.003 + 0.006 * r(7));
          alpha = 0.3 + 0.7 * (0.5 + 0.5 * math.sin(t * speed * (1 + 3 * r(3)) + r(4) * 6.28));
          x = _wrap(w * r(0) + cd * ms * 0.004 * t * speed, -mx, w + 2 * mx);
          y = _wrap(h * r(1) + sd * ms * 0.004 * t * speed, -my, h + 2 * my);
          rot = r(5) * 0.6;
          break;
        case PKind.dust:
          vx = ms * (0.01 + 0.02 * r(2));
          vy = -ms * (0.008 + 0.02 * r(3));
          size = ms * (0.002 + 0.005 * r(7));
          alpha = (0.25 + 0.65 * (0.5 + 0.5 * math.sin(t * 2 + r(4) * 6.28))) * (0.4 + 0.6 * r(5));
          final tt = t * speed;
          x = _wrap(w * r(0) + (vx * cd - vy * sd) * tt + math.sin(tt * 0.7 + r(6) * 6) * ms * 0.01, -mx, w + 2 * mx);
          y = _wrap(h * r(1) + (vx * sd + vy * cd) * tt, -my, h + 2 * my);
          break;
        case PKind.bokeh:
          vx = ms * 0.006 * (r(2) - 0.3);
          vy = -ms * (0.004 + 0.01 * r(3));
          sprite = Sprite.disc;
          size = ms * (0.04 + 0.1 * r(7));
          alpha = (0.12 + 0.3 * r(5)) * (0.6 + 0.4 * math.sin(t * speed * (0.4 + 0.6 * r(4)) + r(6) * 6.28));
          final tt = t * speed;
          x = _wrap(w * r(0) + (vx * cd - vy * sd) * tt, -mx, w + 2 * mx);
          y = _wrap(h * r(1) + (vx * sd + vy * cd) * tt, -my, h + 2 * my);
          break;
        case PKind.smoke:
          final life = 7.0 / math.max(0.05, speed);
          final age = (t / life + r(0)) % 1.0;
          final rise = h * (0.35 + 0.25 * r(2));
          final drift = ms * 0.15 * (r(3) - 0.5);
          final ox = drift * age, oy = -rise * age;
          x = w * (0.05 + 0.9 * r(1)) + ox * cd - oy * sd;
          y = h * (0.75 + 0.35 * r(4)) + ox * sd + oy * cd;
          size = ms * (0.25 + 0.25 * r(7)) * (0.55 + 0.9 * age);
          alpha = 0.32 * math.sin(math.pi * age);
          rot = r(5) * 6.28 + age * (r(6) - 0.5);
          break;
        case PKind.streaks:
          final life = (1.4 + 1.4 * r(2)) / math.max(0.05, speed);
          final cyc = t / life + r(0);
          final age = cyc % 1.0;
          final gen = cyc.floor();
          double g(int k) => hash01(i * 31 + gen * 977 + seed, k);
          // Natural travel: up-right at -28°, rotated by direction.
          final a = -28 * math.pi / 180 + dir;
          final ca = math.cos(a), sa = math.sin(a);
          final travel = (w + h) * (0.9 + 0.4 * g(1));
          // Start somewhere so the streak crosses the box.
          final sx = w * (g(2) * 1.2 - 0.3) - ca * travel * 0.45;
          final sy = h * (g(3) * 1.2 - 0.1) - sa * travel * 0.45;
          x = sx + ca * travel * age;
          y = sy + sa * travel * age;
          rot = a;
          sprite = Sprite.streak;
          size = ms * (0.25 + 0.35 * g(4));
          alpha = math.pow(math.sin(math.pi * age), 0.7).toDouble() * (0.6 + 0.4 * g(5));
          break;
        case PKind.birds:
          final v = ms * (0.06 + 0.05 * r(2));
          final tt = t * speed;
          final flap = (tt * (3 + 1.5 * r(3)) + r(4)).floor().isEven;
          sprite = flap ? Sprite.birdUp : Sprite.birdDown;
          size = ms * (0.025 + 0.025 * r(7));
          final bob = math.sin(tt * 1.3 + r(5) * 6.28) * ms * 0.015;
          x = _wrap(w * r(0) + v * cd * tt - bob * sd, -mx, w + 2 * mx);
          y = _wrap(h * (0.08 + 0.5 * r(1)) + v * sd * tt + bob * cd, -my, h + 2 * my);
          if (isWhite) col = 0xFF1E1E1E;
          rot = dir;
          break;
        // V3-D >>> debris (grit tumbling down-wind), snow_spray (wind-blown powder), ice (glinting crystals)
        case PKind.debris:
          vy = h * (0.35 + 0.35 * r(2));
          vx = w * (0.08 + 0.12 * r(9));
          size = ms * (0.004 + 0.012 * r(7) * r(7));
          sprite = r(6) < 0.7 ? Sprite.rect : Sprite.soft;
          alpha = 0.55 + 0.45 * r(3);
          if (isWhite) col = [0xFF3A332C, 0xFF5A5046, 0xFF7A6E60, 0xFF26211C][math.min(3, (r(8) * 4).floor())];
          final tt = t * speed;
          x = _wrap(w * r(0) + (vx * cd - vy * sd) * tt, -mx, w + 2 * mx);
          y = _wrap(h * r(1) + (vx * sd + vy * cd) * tt, -my, h + 2 * my);
          rot = r(5) * 6.28 + tt * (3 + 9 * r(4));
          break;
        case PKind.snowSpray:
          vx = w * (0.45 + 0.5 * r(2));
          vy = h * (0.03 + 0.06 * r(3));
          size = ms * (0.002 + 0.006 * r(7));
          alpha = (0.35 + 0.55 * r(5)) * (0.6 + 0.4 * math.sin(t * speed * (2 + 3 * r(4)) + r(6) * 6.28));
          final tt = t * speed;
          final gust = math.sin(tt * (0.9 + r(4)) + r(5) * 6.28) * ms * 0.03;
          x = _wrap(w * r(0) + (vx * cd - vy * sd) * tt, -mx, w + 2 * mx);
          y = _wrap(h * r(1) + (vx * sd + vy * cd) * tt + gust, -my, h + 2 * my);
          break;
        case PKind.ice:
          vy = h * (0.02 + 0.04 * r(2));
          sprite = r(6) < 0.5 ? Sprite.star : Sprite.soft;
          size = ms * (sprite == Sprite.star ? 0.01 + 0.018 * r(7) : 0.003 + 0.005 * r(7));
          alpha = 0.25 + 0.75 * math.pow(0.5 + 0.5 * math.sin(t * speed * (1.5 + 3 * r(3)) + r(4) * 6.28), 3).toDouble();
          if (isWhite) col = 0xFFD6F0FF;
          final tt = t * speed;
          x = _wrap(w * r(0) - vy * sd * tt + math.sin(tt * 0.6 + r(5) * 6) * ms * 0.01, -mx, w + 2 * mx);
          y = _wrap(h * r(1) + vy * cd * tt, -my, h + 2 * my);
          rot = r(5) * 6.28 + tt * (r(9) - 0.5);
          break;
        // <<< V3-D
        default: // clouds
          final v = ms * (0.008 + 0.012 * r(2));
          final tt = t * speed;
          sprite = Sprite.cloud;
          size = ms * (0.35 + 0.35 * r(7));
          alpha = 0.55 + 0.35 * r(3);
          final m2 = size * 0.6;
          x = _wrap(w * r(0) + v * cd * tt, -m2, w + 2 * m2);
          y = _wrap(h * (0.05 + 0.55 * r(1)) + v * sd * tt, -m2, h + 2 * m2);
          break;
      }
      final o = i * kParticleStride;
      out[o] = x;
      out[o + 1] = y;
      out[o + 2] = size;
      out[o + 3] = rot;
      out[o + 4] = alpha.clamp(0.0, 1.0);
      out[o + 5] = sprite.toDouble();
      out[o + 6] = col.toDouble();
    }
    return n;
  }
}

// ----------------------------------------------------------------------- text

const _upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const _lower = 'abcdefghijklmnopqrstuvwxyz';
const _digits = '0123456789';
const _symbols = r'#$%&*@?!<>/\+=';

class TextFx {
  /// When letter [i] of [n] has settled in a scramble of [duration] s.
  static double scrambleSettle(int i, int n, double duration) =>
      n <= 0 ? 0 : duration * (0.25 + 0.75 * (i + 1) / n);

  // V2-F >>> scramble works on whole letters (grapheme / conjunct clusters)
  static const _devaLetters = [
    'क', 'ख', 'ग', 'घ', 'च', 'छ', 'ज', 'झ', 'ट', 'ठ', 'ड', 'ढ', 'त', 'थ', 'द', 'ध', 'न', 'प', 'फ', 'ब', 'भ', 'म', 'य', 'र', 'ल', 'व', 'श', 'ष',
    'स', 'ह', 'अ', 'इ', 'उ', 'ए', 'ओ',
  ];
  static const _devaDigits = ['०', '१', '२', '३', '४', '५', '६', '७', '८', '९'];

  /// The letter shown for cluster [i] of [n] (original [cluster], one
  /// user-perceived letter, see TextClusters) at [local] seconds into a
  /// scramble: random letters of the same script/class until it settles
  /// (left → right), then exactly the original cluster. Spaces never
  /// scramble; Devanagari scrambles through Devanagari letters.
  static String scrambleCluster(String cluster, int i, int n, double local, double duration, int seed) {
    if (local >= scrambleSettle(i, n, duration)) return cluster;
    final cls = TextClusters.classOf(cluster);
    if (cls == ClusterClass.space) return cluster;
    final step = (math.max(0.0, local) * 24).floor();
    final h = hash01(seed + i * 97, step);
    String pick(String set) => set[(h * set.length).floor().clamp(0, set.length - 1)];
    String pickL(List<String> set) => set[(h * set.length).floor().clamp(0, set.length - 1)];
    return switch (cls) {
      ClusterClass.digit => pick(_digits),
      ClusterClass.lower => pick(_lower),
      ClusterClass.upper => pick(_upper),
      ClusterClass.devanagari => pickL(_devaLetters),
      ClusterClass.devanagariDigit => pickL(_devaDigits),
      _ => pick('$_upper$_symbols'),
    };
  }

  /// Code-point version of [scrambleCluster] (single-code-point letters only).
  static int scrambleRune(int rune, int i, int n, double local, double duration, int seed) =>
      scrambleCluster(String.fromCharCode(rune), i, n, local, duration, seed).runes.first;

  /// The whole scrambled string at [local] seconds (letter = cluster).
  static String scrambleText(String text, double local, double duration, {int seed = 0}) {
    final letters = TextClusters.split(text);
    final n = letters.length;
    return [for (int i = 0; i < n; i++) scrambleCluster(letters[i], i, n, local, duration, seed)].join();
  }

  /// True once every letter of a [duration] s scramble / random pop has settled.
  static bool lettersSettled(double local, double duration) => duration <= 0 || local >= duration;
  // <<< V2-F

  static final Map<int, List<int>> _orders = {};

  /// Random (but stable) pop order: order[i] = rank of letter i.
  static List<int> popOrder(int n, int seed) {
    final key = n * 1000003 + seed;
    final cached = _orders[key];
    if (cached != null) return cached;
    final idx = List<int>.generate(n, (i) => i);
    for (int i = n - 1; i > 0; i--) {
      final j = (hash01(seed, i) * (i + 1)).floor().clamp(0, i);
      final tmp = idx[i];
      idx[i] = idx[j];
      idx[j] = tmp;
    }
    final rank = List<int>.filled(n, 0);
    for (int k = 0; k < n; k++) {
      rank[idx[k]] = k;
    }
    if (_orders.length > 64) _orders.clear();
    return _orders[key] = rank;
  }

  /// Linear 0..1 pop progress of letter [i] of [n] (apply an overshoot ease).
  static double randomPopProgress(int i, int n, double local, double duration, int seed) {
    if (n <= 0) return 1;
    final rank = popOrder(n, seed)[i];
    final span = math.max(0.05, duration * 0.35);
    final start = n <= 1 ? 0.0 : rank / (n - 1) * (duration - span);
    return ((local - start) / span).clamp(0.0, 1.0);
  }
}

// -------------------------------------------------------------- colour matrices

const _lr = 0.2126, _lg = 0.7152, _lb = 0.0722;

List<double> _mix(List<double> m, double a) {
  final id = <double>[1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];
  return [for (int i = 0; i < 20; i++) id[i] + (m[i] - id[i]) * a];
}

class FxColor {
  /// Black & white, blended by [amount] 0..1.
  static List<double> mono(double amount) => _mix([
        _lr, _lg, _lb, 0, 0,
        _lr, _lg, _lb, 0, 0,
        _lr, _lg, _lb, 0, 0,
        0, 0, 0, 1, 0,
      ], amount.clamp(0.0, 1.0));

  /// Maps luminance from [dark] to [light] (RGB 0..255), blended by [amount].
  static List<double> duotone(List<double> dark, List<double> light, double amount) {
    final row = <double>[];
    for (int c = 0; c < 3; c++) {
      final d = dark[c], l = light[c];
      final k = (l - d) / 255;
      row.addAll([k * _lr, k * _lg, k * _lb, 0, d]);
    }
    return _mix([...row, 0, 0, 0, 1, 0], amount.clamp(0.0, 1.0));
  }

  /// Pushes every pixel toward [rgb] by [amount] 0..1 (alpha kept).
  static List<double> flash(List<double> rgb, double amount) {
    final a = amount.clamp(0.0, 1.0);
    return [
      1 - a, 0, 0, 0, rgb[0] * a,
      0, 1 - a, 0, 0, rgb[1] * a,
      0, 0, 1 - a, 0, rgb[2] * a,
      0, 0, 0, 1, 0,
    ];
  }
}

// ------------------------------------------------------------------- warping

class Warp {
  /// Curved-screen mesh: maps a layer point (x, y) in a [w]×[h] box to its
  /// warped position for [bend] -100..100 (positive bulges toward the viewer,
  /// negative curves away like a curved TV). Writes into [out] (x, y).
  static void curve(double x, double y, double w, double h, double bend, List<double> out) {
    final b = (bend / 100).clamp(-1.0, 1.0);
    if (b.abs() < 1e-4 || w <= 0) {
      out[0] = x;
      out[1] = y;
      return;
    }
    final theta = b.abs() * 1.1; // half-angle of the cylinder section
    final f = w * 1.6; // focal distance
    final hw = w / 2, cx = hw, cy = h / 2;
    final rad = hw / theta;
    double proj(double u, List<double> res) {
      final phi = u * theta;
      final px = rad * math.sin(phi);
      // Convex: edges recede (z > 0). Concave: edges come forward.
      final z = rad * (1 - math.cos(phi)) * (b > 0 ? 1 : -1);
      final s = f / (f + z);
      res[0] = px * s;
      return s;
    }

    final tmp = [0.0];
    proj(1, tmp);
    final norm = hw / math.max(1e-6, tmp[0]); // keep the edges at the box sides (width unchanged)
    final u = ((x - cx) / hw).clamp(-1.5, 1.5);
    final s = proj(u, tmp);
    out[0] = cx + tmp[0] * norm;
    // Height follows the perspective scale; the centre keeps its height.
    out[1] = cy + (y - cy) * s;
  }

  /// Wind sway: horizontal displacement for a point at height [y] in a box of
  /// height [h] (bottom pinned), at time [t].
  static double sway(double x, double y, double w, double h, double amount, double speed, double t, int seed) {
    if (h <= 0 || amount <= 0) return 0;
    final k = (1 - (y / h)).clamp(0.0, 1.0);
    final a = amount / 100 * h * 0.12;
    final tt = t * speed;
    final phase = x / math.max(1.0, w) * 0.8;
    final wave = math.sin(tt * 1.7 + phase + seed % 7) * 0.7 + math.sin(tt * 3.1 + phase * 2 + seed % 5) * 0.3;
    final gust = 0.6 + 0.4 * noise1(tt * 0.4, seed);
    return a * k * k * wave * gust;
  }
}
