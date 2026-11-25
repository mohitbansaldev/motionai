import 'dart:math' as math;
import 'dart:typed_data';

import '../model/layer.dart';

// CHROMA (Agent M): green / blue screen keyer maths (no Flutter imports).
//
// The same formulas run in the GPU fragment shader (shaders/chroma_key.frag)
// and in this pure-Dart CPU keyer (fallback renderer, auto key colour, tests).
//
// Keyer: colours are compared in the CbCr (chroma) plane of BT.601 YCbCr,
// in the frame of the key colour's chroma vector k:
//   u = projection of the pixel chroma on k, relative to |k| (1 = as
//       saturated as the key, 0.5 = half as saturated, e.g. a shadow on the
//       screen; ≤ 0 = the opposite hue: skin, red, …)
//   v = distance from the k axis, relative to |k|
//   d = max(v / u,  0.7 · (1 − u))
// v / u is the tangent of the hue difference, 0.7·(1 − u) rejects pale /
// grey / white pixels. alpha = smoothstep(t0, t0 + w, d), with t0 from
// tolerance and w from softness. Luma is ignored, so screen shadows and
// hot spots key evenly; white, grey, black and skin stay opaque.
// Spill: the chroma component along k (when positive) is removed by the
// spill amount, at the same luma → green fringes turn neutral.
// Choke: morphological min (shrink, choke > 0) / max (grow, choke < 0) of
// the key alpha over 8 neighbours at the choke radius (+4 at half radius).

/// Named key colours accepted by commands (`color: "green" | "blue"`).
const Map<String, List<double>> kChromaNamedColors = {
  'green': [0, 177, 64], // chroma-key green
  'blue': [0, 71, 187], // chroma-key blue
};

/// The chroma_key settings at one moment (all in the effect's units).
class ChromaSettings {
  /// Key colour 0..255.
  final double r, g, b;

  /// 0..100.
  final double tolerance, softness, spill;

  /// −50..50: tenths of a layer pixel (+ shrinks the matte, − grows it).
  final double choke;

  /// 0..100 matte contrast (0 = none).
  final double contrast;

  /// Show the black/white matte instead of the keyed picture.
  final bool matte;

  const ChromaSettings({
    this.r = 0,
    this.g = 177,
    this.b = 64,
    this.tolerance = 50,
    this.softness = 20,
    this.spill = 50,
    this.choke = 0,
    this.contrast = 0,
    this.matte = false,
  });

  /// Settings of a `chroma_key` [e] at time [t].
  factory ChromaSettings.fromEffect(Effect e, double t) {
    double p(String k, double d, [int i = 0]) {
      final v = e.params[k]?.valueAt(t);
      return v == null || v.length <= i ? d : v[i];
    }

    return ChromaSettings(
      r: p('color', 0, 0).clamp(0.0, 255.0),
      g: p('color', 177, 1).clamp(0.0, 255.0),
      b: p('color', 64, 2).clamp(0.0, 255.0),
      tolerance: p('tolerance', 50).clamp(0.0, 100.0),
      softness: p('softness', 20).clamp(0.0, 100.0),
      spill: p('spill', 50).clamp(0.0, 100.0),
      choke: p('choke', 0).clamp(-50.0, 50.0),
      contrast: p('contrast', 0).clamp(0.0, 100.0),
      matte: p('view', 0).round() == 1,
    );
  }

  /// Lower edge of the soft ramp (key distance below this → transparent).
  double get t0 => tolerance / 100 * 0.8;

  /// Width of the soft ramp.
  double get width => 0.02 + softness / 100 * 0.8;

  /// Alpha gain around 0.5 for the matte contrast (≥ 1).
  double get gain => 1 + contrast / 20;

  double get spillAmount => spill / 100;

  @override
  bool operator ==(Object o) =>
      o is ChromaSettings &&
      o.r == r &&
      o.g == g &&
      o.b == b &&
      o.tolerance == tolerance &&
      o.softness == softness &&
      o.spill == spill &&
      o.choke == choke &&
      o.contrast == contrast &&
      o.matte == matte;

  @override
  int get hashCode => Object.hash(r, g, b, tolerance, softness, spill, choke, contrast, matte);

  @override
  String toString() => 'ChromaSettings(rgb $r,$g,$b tol $tolerance soft $softness spill $spill choke $choke contrast $contrast matte $matte)';
}

/// The first enabled `chroma_key` effect of [l], or null.
Effect? chromaEffectOf(Layer l) {
  for (final e in l.effects) {
    if (e.enabled && e.type == 'chroma_key') return e;
  }
  return null;
}

/// Pure-Dart chroma keyer (CPU fallback, auto colour detection, tests).
class ChromaMath {
  static double _cb(double r, double g, double b) => -0.168736 * r - 0.331264 * g + 0.5 * b;
  static double _cr(double r, double g, double b) => 0.5 * r - 0.418688 * g - 0.081312 * b;

  static double _smooth(double e0, double e1, double x) {
    final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  /// Key distance d of a colour (0..1 channels) against key chroma
  /// unit vector (kx, ky) of length [kl].
  static double _dist(double r, double g, double b, double kx, double ky, double kl) {
    final cx = _cb(r, g, b), cy = _cr(r, g, b);
    final u = (cx * kx + cy * ky) / kl;
    final v = (cx * ky - cy * kx).abs() / kl;
    final ang = u > 0.001 ? v / u : 1000.0;
    final mag = (1 - u) * 0.7;
    return math.max(ang, mag);
  }

  /// Key alpha (0 = keyed out, 1 = kept) of one colour, channels 0..255,
  /// before choke / contrast.
  static double alphaOf(double r, double g, double b, ChromaSettings s) {
    final kx0 = _cb(s.r / 255, s.g / 255, s.b / 255), ky0 = _cr(s.r / 255, s.g / 255, s.b / 255);
    final kl = math.sqrt(kx0 * kx0 + ky0 * ky0);
    if (kl < 1e-4) return 1; // a grey key colour keys nothing
    final d = _dist(r / 255, g / 255, b / 255, kx0 / kl, ky0 / kl, kl);
    return _smooth(s.t0, s.t0 + s.width, d);
  }

  /// Keys [rgba] (straight alpha, w×h) and returns a new straight-alpha
  /// RGBA buffer. [chokePx] is the choke radius in pixels of this buffer
  /// (positive shrinks, negative grows).
  static Uint8List key(Uint8List rgba, int w, int h, ChromaSettings s, {double chokePx = 0}) =>
      _key(rgba, w, h, s, chokePx);

  /// Like [key], with premultiplied output (for ui.decodeImageFromPixels,
  /// which takes premultiplied RGBA).
  static Uint8List keyPremultiplied(Uint8List rgba, int w, int h, ChromaSettings s, {double chokePx = 0}) {
    final out = _key(rgba, w, h, s, chokePx);
    for (int o = 0; o < out.length; o += 4) {
      final a = out[o + 3];
      if (a == 255) continue;
      out[o] = (out[o] * a / 255).round();
      out[o + 1] = (out[o + 1] * a / 255).round();
      out[o + 2] = (out[o + 2] * a / 255).round();
    }
    return out;
  }

  static Uint8List _key(Uint8List rgba, int w, int h, ChromaSettings s, double chokePx) {
    final n = w * h;
    final out = Uint8List(n * 4);
    final kx0 = _cb(s.r / 255, s.g / 255, s.b / 255), ky0 = _cr(s.r / 255, s.g / 255, s.b / 255);
    final kl = math.sqrt(kx0 * kx0 + ky0 * ky0);
    if (kl < 1e-4) {
      out.setAll(0, Uint8List.sublistView(rgba, 0, n * 4));
      if (s.matte) _toMatte(out, n, null);
      return out;
    }
    final kx = kx0 / kl, ky = ky0 / kl;
    final t0 = s.t0, t1 = s.t0 + s.width;
    // Key alpha per pixel.
    final ka = Float32List(n);
    for (int i = 0; i < n; i++) {
      final o = i * 4;
      ka[i] = _smooth(t0, t1, _dist(rgba[o] / 255, rgba[o + 1] / 255, rgba[o + 2] / 255, kx, ky, kl));
    }
    // Choke: min/max over 8 neighbours at r and 4 at r/2 (like the shader).
    Float32List a = ka;
    final cr = chokePx.abs();
    if (cr > 0.01) {
      a = Float32List(n);
      final shrink = chokePx > 0;
      final offs = <(int, int)>{};
      for (int k = 0; k < 8; k++) {
        final ang = k * math.pi / 4;
        offs.add(((math.cos(ang) * cr).round(), (math.sin(ang) * cr).round()));
      }
      for (int k = 0; k < 4; k++) {
        final ang = k * math.pi / 2;
        offs.add(((math.cos(ang) * cr * 0.5).round(), (math.sin(ang) * cr * 0.5).round()));
      }
      offs.remove((0, 0));
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          var m = ka[y * w + x];
          for (final (dx, dy) in offs) {
            final sx = (x + dx).clamp(0, w - 1), sy = (y + dy).clamp(0, h - 1);
            final v = ka[sy * w + sx];
            m = shrink ? math.min(m, v) : math.max(m, v);
          }
          a[y * w + x] = m;
        }
      }
    }
    final gain = s.gain, sp = s.spillAmount;
    for (int i = 0; i < n; i++) {
      final o = i * 4;
      var al = a[i];
      if (gain != 1) al = ((al - 0.5) * gain + 0.5).clamp(0.0, 1.0);
      final srcA = rgba[o + 3] / 255;
      final fa = al * srcA;
      if (s.matte) {
        final v = (fa * 255).round();
        out[o] = v;
        out[o + 1] = v;
        out[o + 2] = v;
        out[o + 3] = 255;
        continue;
      }
      var r = rgba[o] / 255, g = rgba[o + 1] / 255, b = rgba[o + 2] / 255;
      if (sp > 0) (r, g, b) = _despill(r, g, b, kx, ky, sp);
      out[o] = (r * 255).round().clamp(0, 255);
      out[o + 1] = (g * 255).round().clamp(0, 255);
      out[o + 2] = (b * 255).round().clamp(0, 255);
      out[o + 3] = (fa * 255).round().clamp(0, 255);
    }
    return out;
  }

  static void _toMatte(Uint8List out, int n, Float32List? a) {
    for (int i = 0; i < n; i++) {
      final o = i * 4;
      final v = a == null ? out[o + 3] : (a[i] * out[o + 3]).round();
      out[o] = v;
      out[o + 1] = v;
      out[o + 2] = v;
      out[o + 3] = 255;
    }
  }

  /// Spill suppression of one colour (0..1 channels): removes [amount] of
  /// the chroma along the key direction (kx, ky), keeping luma.
  static (double, double, double) _despill(double r, double g, double b, double kx, double ky, double amount) {
    var cx = _cb(r, g, b), cy = _cr(r, g, b);
    final along = cx * kx + cy * ky;
    if (along <= 0) return (r, g, b);
    final y = 0.299 * r + 0.587 * g + 0.114 * b;
    cx -= kx * along * amount;
    cy -= ky * along * amount;
    return (
      (y + 1.402 * cy).clamp(0.0, 1.0),
      (y - 0.344136 * cx - 0.714136 * cy).clamp(0.0, 1.0),
      (y + 1.772 * cx).clamp(0.0, 1.0),
    );
  }

  /// Spill-suppressed colour (0..255 channels) for key settings [s].
  static (int, int, int) despill(int r, int g, int b, ChromaSettings s) {
    final kx0 = _cb(s.r / 255, s.g / 255, s.b / 255), ky0 = _cr(s.r / 255, s.g / 255, s.b / 255);
    final kl = math.sqrt(kx0 * kx0 + ky0 * ky0);
    if (kl < 1e-4) return (r, g, b);
    final (rr, gg, bb) = _despill(r / 255, g / 255, b / 255, kx0 / kl, ky0 / kl, s.spillAmount);
    return ((rr * 255).round(), (gg * 255).round(), (bb * 255).round());
  }

  /// Auto key colour: samples the frame's border band (where the screen
  /// usually is), classifies saturated green / blue pixels and returns the
  /// per-channel median of the dominant one, or null when the border is
  /// not a green/blue screen. [rgba] is straight-alpha w×h.
  static List<int>? detectKeyColor(Uint8List rgba, int w, int h) {
    if (w <= 0 || h <= 0 || rgba.length < w * h * 4) return null;
    final bandX = math.max(1, (w * 0.08).round()), bandY = math.max(1, (h * 0.08).round());
    final step = math.max(1, (math.sqrt(w * h / 6000.0)).floor());
    final greens = <int>[], blues = <int>[];
    var total = 0;
    void sample(int x, int y) {
      final o = (y * w + x) * 4;
      if (rgba[o + 3] < 128) return;
      total++;
      final r = rgba[o], g = rgba[o + 1], b = rgba[o + 2];
      if (g > r * 1.15 + 8 && g > b * 1.1 + 8 && g - math.max(r, b) > 25) {
        greens.add(o);
      } else if (b > r * 1.15 + 8 && b > g * 1.05 + 8 && b - math.max(r, g) > 25) {
        blues.add(o);
      }
    }

    for (int y = 0; y < h; y += step) {
      final edgeRow = y < bandY || y >= h - bandY;
      for (int x = 0; x < w; x += step) {
        if (edgeRow || x < bandX || x >= w - bandX) sample(x, y);
      }
    }
    if (total == 0) return null;
    final best = greens.length >= blues.length ? greens : blues;
    if (best.length < math.max(8, total * 0.15)) return null;
    int median(int ch) {
      final v = [for (final o in best) rgba[o + ch]]..sort();
      return v[v.length ~/ 2];
    }

    return [median(0), median(1), median(2)];
  }

  /// "#RRGGBB" of [rgb].
  static String hex(List<int> rgb) =>
      '#${rgb.map((v) => v.clamp(0, 255).toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';
}
