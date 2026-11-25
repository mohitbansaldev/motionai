// V2-E (Depth from photo): pure-Dart image maths shared by the depth
// pre/post-processing and the layer splitter. Works on raw buffers
// (RGBA bytes, single-channel float maps) so it runs everywhere: unit tests,
// background isolates on Windows and Android.
import 'dart:math' as math;
import 'dart:typed_data';

class DepthMath {
  /// [rgba] (w×h, 4 bytes per pixel) resized to [tw]×[th] as planar RGB
  /// floats 0..255 (plane c at c·tw·th). Area average when shrinking,
  /// bilinear when growing.
  static Float32List resizePlanar(Uint8List rgba, int w, int h, int tw, int th) {
    final out = Float32List(3 * tw * th);
    final plane = tw * th;
    final sx = w / tw, sy = h / th;
    for (var y = 0; y < th; y++) {
      for (var x = 0; x < tw; x++) {
        final o = y * tw + x;
        if (sx >= 1 && sy >= 1) {
          final xa = (x * sx).floor(), xb = math.max(xa + 1, math.min(w, ((x + 1) * sx).ceil()));
          final ya = (y * sy).floor(), yb = math.max(ya + 1, math.min(h, ((y + 1) * sy).ceil()));
          var r = 0, g = 0, b = 0;
          for (var yy = ya; yy < yb; yy++) {
            var i = (yy * w + xa) * 4;
            for (var xx = xa; xx < xb; xx++, i += 4) {
              r += rgba[i];
              g += rgba[i + 1];
              b += rgba[i + 2];
            }
          }
          final k = 1 / ((xb - xa) * (yb - ya));
          out[o] = r * k;
          out[plane + o] = g * k;
          out[2 * plane + o] = b * k;
        } else {
          final fx = ((x + 0.5) * sx - 0.5).clamp(0.0, w - 1.0), fy = ((y + 0.5) * sy - 0.5).clamp(0.0, h - 1.0);
          final x0 = fx.floor(), y0 = fy.floor();
          final x1 = math.min(x0 + 1, w - 1), y1 = math.min(y0 + 1, h - 1);
          final kx = fx - x0, ky = fy - y0;
          for (var c = 0; c < 3; c++) {
            final p00 = rgba[(y0 * w + x0) * 4 + c], p01 = rgba[(y0 * w + x1) * 4 + c];
            final p10 = rgba[(y1 * w + x0) * 4 + c], p11 = rgba[(y1 * w + x1) * 4 + c];
            final a = p00 + (p01 - p00) * kx;
            final d = p10 + (p11 - p10) * kx;
            out[c * plane + o] = a + (d - a) * ky;
          }
        }
      }
    }
    return out;
  }

  /// Bilinear resample of a single-channel [s]×[t] map to [w]×[h].
  static Float32List resample(Float32List m, int s, int t, int w, int h) {
    if (s == w && t == h) return Float32List.fromList(m);
    final out = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      final fy = ((y + 0.5) * t / h - 0.5).clamp(0.0, t - 1.0);
      final y0 = fy.floor(), y1 = math.min(y0 + 1, t - 1);
      final ky = fy - y0;
      for (var x = 0; x < w; x++) {
        final fx = ((x + 0.5) * s / w - 0.5).clamp(0.0, s - 1.0);
        final x0 = fx.floor(), x1 = math.min(x0 + 1, s - 1);
        final kx = fx - x0;
        final a = m[y0 * s + x0] + (m[y0 * s + x1] - m[y0 * s + x0]) * kx;
        final c = m[y1 * s + x0] + (m[y1 * s + x1] - m[y1 * s + x0]) * kx;
        out[y * w + x] = a + (c - a) * ky;
      }
    }
    return out;
  }

  /// Luma 0..1 of an RGBA buffer.
  static Float32List luma(Uint8List rgba, int w, int h) {
    final n = w * h;
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = (0.299 * rgba[i * 4] + 0.587 * rgba[i * 4 + 1] + 0.114 * rgba[i * 4 + 2]) / 255;
    }
    return out;
  }

  /// Mean of [v] over a (2r+1)² window (clamped at the borders), O(n).
  static Float32List boxMean(Float32List v, int w, int h, int r) {
    if (r <= 0) return Float32List.fromList(v);
    final iw = w + 1;
    final sat = Float64List(iw * (h + 1));
    for (var y = 0; y < h; y++) {
      var row = 0.0;
      for (var x = 0; x < w; x++) {
        row += v[y * w + x];
        sat[(y + 1) * iw + x + 1] = sat[y * iw + x + 1] + row;
      }
    }
    final out = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      final ya = math.max(0, y - r), yb = math.min(h, y + r + 1);
      for (var x = 0; x < w; x++) {
        final xa = math.max(0, x - r), xb = math.min(w, x + r + 1);
        final s = sat[yb * iw + xb] - sat[ya * iw + xb] - sat[yb * iw + xa] + sat[ya * iw + xa];
        out[y * w + x] = s / ((yb - ya) * (xb - xa));
      }
    }
    return out;
  }

  /// Edge-aware smoothing of [p] guided by [g] (He et al. guided filter):
  /// the result follows the edges of the photo while keeping [p]'s values.
  static Float32List guided(Float32List g, Float32List p, int w, int h, int r, double eps) {
    final n = w * h;
    final gp = Float32List(n), gg = Float32List(n);
    for (var i = 0; i < n; i++) {
      gp[i] = g[i] * p[i];
      gg[i] = g[i] * g[i];
    }
    final mg = boxMean(g, w, h, r), mp = boxMean(p, w, h, r), mgp = boxMean(gp, w, h, r), mgg = boxMean(gg, w, h, r);
    final a = Float32List(n), b = Float32List(n);
    for (var i = 0; i < n; i++) {
      final varG = mgg[i] - mg[i] * mg[i];
      final cov = mgp[i] - mg[i] * mp[i];
      a[i] = cov / (varG + eps);
      b[i] = mp[i] - a[i] * mg[i];
    }
    final ma = boxMean(a, w, h, r), mb = boxMean(b, w, h, r);
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = ma[i] * g[i] + mb[i];
    }
    return out;
  }

  /// Value below which a share [q] (0..1) of [v] lies (1024-bin histogram of
  /// the 0..1 range; values outside are clamped).
  static List<double> quantiles(Float32List v, List<double> qs) {
    const bins = 1024;
    final hist = Int32List(bins);
    for (final x in v) {
      final b = (x.isNaN ? 0.0 : x.clamp(0.0, 1.0)) * (bins - 1);
      hist[b.round()]++;
    }
    final n = v.length;
    final out = <double>[];
    for (final q in qs) {
      final want = q * n;
      var acc = 0;
      var b = 0;
      for (; b < bins; b++) {
        acc += hist[b];
        if (acc >= want) break;
      }
      out.add(math.min(b, bins - 1) / (bins - 1));
    }
    return out;
  }

  /// Square dilation of a 0/1 mask by [r] px (separable running max).
  static Uint8List dilate(Uint8List m, int w, int h, int r) {
    if (r <= 0) return Uint8List.fromList(m);
    final tmp = Uint8List(w * h), out = Uint8List(w * h);
    // At scan position x the output pixel x − r is set when the last set
    // pixel seen (≤ x) lies within [x − 2r, x].
    for (var y = 0; y < h; y++) {
      final row = y * w;
      var last = -1 << 30;
      for (var x = 0; x < w + r; x++) {
        if (x < w && m[row + x] != 0) last = x;
        final ox = x - r;
        if (ox >= 0 && ox < w && x - last <= 2 * r) tmp[row + ox] = 1;
      }
    }
    for (var x = 0; x < w; x++) {
      var last = -1 << 30;
      for (var y = 0; y < h + r; y++) {
        if (y < h && tmp[y * w + x] != 0) last = y;
        final oy = y - r;
        if (oy >= 0 && oy < h && y - last <= 2 * r) out[oy * w + x] = 1;
      }
    }
    return out;
  }

  /// Majority filter: 1 where more than half of the (2r+1)² window is set
  /// (removes specks and fills pin holes).
  static Uint8List majority(Uint8List m, int w, int h, int r) {
    if (r <= 0) return Uint8List.fromList(m);
    final f = Float32List(w * h);
    for (var i = 0; i < f.length; i++) {
      f[i] = m[i].toDouble();
    }
    final b = boxMean(f, w, h, r);
    final out = Uint8List(w * h);
    for (var i = 0; i < out.length; i++) {
      out[i] = b[i] > 0.5 ? 1 : 0;
    }
    return out;
  }

  /// Mirror-pads an RGBA buffer by [p] px on every side.
  static Uint8List padRgba(Uint8List rgba, int w, int h, int p) {
    if (p <= 0) return Uint8List.fromList(rgba);
    final pw = w + 2 * p, ph = h + 2 * p;
    final out = Uint8List(pw * ph * 4);
    for (var y = 0; y < ph; y++) {
      final sy = mirror(y - p, h);
      for (var x = 0; x < pw; x++) {
        final sx = mirror(x - p, w);
        final s = (sy * w + sx) * 4, d = (y * pw + x) * 4;
        out[d] = rgba[s];
        out[d + 1] = rgba[s + 1];
        out[d + 2] = rgba[s + 2];
        out[d + 3] = rgba[s + 3];
      }
    }
    return out;
  }

  /// Mirror-pads a float map by [p] px on every side.
  static Float32List padMap(Float32List m, int w, int h, int p) {
    if (p <= 0) return Float32List.fromList(m);
    final pw = w + 2 * p, ph = h + 2 * p;
    final out = Float32List(pw * ph);
    for (var y = 0; y < ph; y++) {
      final sy = mirror(y - p, h);
      for (var x = 0; x < pw; x++) {
        out[y * pw + x] = m[sy * w + mirror(x - p, w)];
      }
    }
    return out;
  }

  /// Reflects index [i] into 0..n-1 (… 2 1 0 | 0 1 2 … n-1 | n-1 n-2 …).
  static int mirror(int i, int n) {
    if (n <= 1) return 0;
    final period = 2 * n;
    var k = i % period;
    if (k < 0) k += period;
    return k < n ? k : period - 1 - k;
  }
}
