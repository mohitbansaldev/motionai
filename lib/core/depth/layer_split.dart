// V2-E (Depth from photo): one photo + its depth map → N stacked layers
// (far … near) for a 2.5D parallax scene.
//
// Layer k (k ≥ 1) holds everything at or nearer than depth threshold t_k:
// its matte is 1 on the region R_k = {depth ≥ t_k} grown by a few px (G_k)
// and fades out over a feather band that follows the photo's edges. The
// bottom layer is opaque. Behind every nearer layer the pixels are
// inpainted (hole = G_{k+1}), and because the layer above is fully opaque
// exactly there, the stack composites back to the original photo
// pixel-for-pixel, while camera moves reveal filled background instead of
// holes or ghost edges.
import 'dart:math' as math;
import 'dart:typed_data';

import 'depth_map.dart';
import 'depth_math.dart';

/// Fills the pixels of an RGBA image ([w]×[h]) marked 1 in [hole]; returns
/// a new RGBA buffer (known pixels unchanged).
typedef InpaintFn = Uint8List Function(Uint8List rgba, int w, int h, Uint8List hole);

class SplitLayer {
  final Uint8List rgba;
  final int width, height;

  /// Top-left of this layer in the source photo's pixels (negative when the
  /// layer extends into the padding around the photo).
  final int x, y;

  /// Mean depth of the layer's own slice (0 far … 1 near).
  final double depth;

  /// Slice index, 0 = farthest.
  final int index;

  SplitLayer(this.rgba, this.width, this.height, this.x, this.y, this.depth, this.index);
}

class DepthSplit {
  static const minLayers = 2, maxLayers = 6, defaultLayers = 4;

  /// Depth thresholds t_1 < … < t_{n-1} at the quantiles k/n, so every slice
  /// gets about the same share of the picture.
  static List<double> thresholds(Float32List depth, int n) {
    if (n < 2) return const [];
    final ts = DepthMath.quantiles(depth, [for (var k = 1; k < n; k++) k / n]);
    for (var i = 0; i < ts.length; i++) {
      if (i > 0 && ts[i] <= ts[i - 1]) ts[i] = ts[i - 1] + 1e-3;
      if (ts[i] <= 0) ts[i] = 1e-3;
    }
    return ts;
  }

  /// Px the hard region of a nearer layer is grown by (its matte = 1 there).
  static int growRadius(int w, int h) => math.max(2, math.max(w, h) ~/ 300);

  /// Width (px) of the soft matte edge outside the grown region.
  static int featherRadius(int w, int h) => math.max(2, math.max(w, h) ~/ 220);

  /// Matte 0..1: 1 on [core]; outside it a linear fade to 0 over [r] px,
  /// pulled down across the photo's edges when a luma [guide] is given.
  static Float32List feather(Uint8List core, int w, int h, int r, {Float32List? guide}) {
    final n = w * h;
    final f = Float32List(n);
    for (var i = 0; i < n; i++) {
      f[i] = core[i] != 0 ? 1 : 0;
    }
    final b = DepthMath.boxMean(f, w, h, r);
    final ramp = Float32List(n);
    for (var i = 0; i < n; i++) {
      ramp[i] = core[i] != 0 ? 1.0 : (2 * b[i]).clamp(0.0, 1.0);
    }
    if (guide == null) return ramp;
    final g = DepthMath.guided(guide, ramp, w, h, r, 1e-3);
    for (var i = 0; i < n; i++) {
      if (core[i] != 0) continue;
      ramp[i] = math.min(ramp[i], g[i].clamp(0.0, 1.0));
    }
    return ramp;
  }

  /// Hard region {depth ≥ t}, cleaned of specks.
  static Uint8List region(Float32List depth, int w, int h, double t, int clean) {
    final m = Uint8List(w * h);
    for (var i = 0; i < m.length; i++) {
      m[i] = depth[i] >= t ? 1 : 0;
    }
    return DepthMath.majority(m, w, h, clean);
  }

  /// Splits [rgba] (w×h) with [depth] into [layers] layers, far first.
  /// [pad] px of mirrored picture are added around the photo so camera
  /// moves don't reveal empty edges.
  static List<SplitLayer> split(Uint8List rgba, int w, int h, DepthMap depth,
      {int layers = defaultLayers, int pad = 0, required InpaintFn inpaint, void Function(String status)? onStatus}) {
    if (depth.width != w || depth.height != h) throw ArgumentError('depth map is ${depth.width}x${depth.height}, photo is ${w}x$h');
    final n = layers.clamp(minLayers, maxLayers);
    final p = math.max(0, pad);
    final pw = w + 2 * p, ph = h + 2 * p, np = pw * ph;
    final img = DepthMath.padRgba(rgba, w, h, p);
    final d = DepthMath.padMap(depth.values, w, h, p);
    final ts = thresholds(depth.values, n);
    final g = growRadius(w, h), fr = featherRadius(w, h);
    final guide = DepthMath.luma(img, pw, ph);

    // Nested hard regions R_1 ⊇ R_2 ⊇ … and their grown versions G_k.
    final hard = <Uint8List>[Uint8List(np)..fillRange(0, np, 1)];
    final grown = <Uint8List>[hard.first];
    for (var k = 1; k < n; k++) {
      final r = region(d, pw, ph, ts[k - 1], math.max(1, fr ~/ 2));
      final prev = hard[k - 1];
      for (var i = 0; i < np; i++) {
        if (prev[i] == 0) r[i] = 0;
      }
      hard.add(r);
      grown.add(DepthMath.dilate(r, pw, ph, g));
    }

    final out = <SplitLayer>[];
    for (var k = 0; k < n; k++) {
      onStatus?.call('Building layer ${k + 1} of $n…');
      // Colour: the photo, with whatever is nearer (grown) filled in.
      final Uint8List colour;
      if (k + 1 < n) {
        final hole = grown[k + 1];
        var any = false;
        for (var i = 0; i < np && !any; i++) {
          any = hole[i] != 0;
        }
        colour = any ? inpaint(img, pw, ph, hole) : Uint8List.fromList(img);
      } else {
        colour = Uint8List.fromList(img);
      }
      // Mean depth of the layer's own slice.
      var sum = 0.0;
      var cnt = 0;
      final mine = hard[k], nearer = k + 1 < n ? hard[k + 1] : null;
      for (var i = 0; i < np; i++) {
        if (mine[i] == 0 || (nearer != null && nearer[i] != 0)) continue;
        sum += d[i];
        cnt++;
      }
      final lo = k == 0 ? 0.0 : ts[k - 1], hi = k + 1 < n ? ts[k] : 1.0;
      final mean = cnt > 0 ? sum / cnt : (lo + hi) / 2;

      if (k == 0) {
        for (var i = 0; i < np; i++) {
          colour[i * 4 + 3] = 255;
        }
        out.add(SplitLayer(colour, pw, ph, -p, -p, mean, k));
        continue;
      }
      final alpha = feather(grown[k], pw, ph, fr, guide: guide);
      var x0 = pw, y0 = ph, x1 = -1, y1 = -1;
      for (var y = 0; y < ph; y++) {
        for (var x = 0; x < pw; x++) {
          final i = y * pw + x;
          final a = (alpha[i] * 255).round();
          colour[i * 4 + 3] = (colour[i * 4 + 3] * a + 127) ~/ 255;
          if (a == 0) continue;
          if (x < x0) x0 = x;
          if (x > x1) x1 = x;
          if (y < y0) y0 = y;
          if (y > y1) y1 = y;
        }
      }
      if (x1 < 0) continue; // empty slice
      final cw = x1 - x0 + 1, ch = y1 - y0 + 1;
      out.add(SplitLayer(crop(colour, pw, x0, y0, cw, ch), cw, ch, x0 - p, y0 - p, mean, k));
    }
    return out;
  }

  /// [cw]×[ch] window of an RGBA buffer [w] px wide, starting at (x0, y0).
  static Uint8List crop(Uint8List rgba, int w, int x0, int y0, int cw, int ch) {
    final out = Uint8List(cw * ch * 4);
    for (var y = 0; y < ch; y++) {
      final s = ((y0 + y) * w + x0) * 4;
      out.setRange(y * cw * 4, (y + 1) * cw * 4, rgba, s);
    }
    return out;
  }

  /// Composites RGBA layers (far first, straight alpha) placed at their
  /// offsets onto a [w]×[h] canvas covering the photo (for tests/preview).
  static Uint8List composite(List<SplitLayer> layers, int w, int h) {
    final acc = Float64List(w * h * 3);
    for (final l in layers) {
      for (var y = 0; y < h; y++) {
        final ly = y - l.y;
        if (ly < 0 || ly >= l.height) continue;
        for (var x = 0; x < w; x++) {
          final lx = x - l.x;
          if (lx < 0 || lx >= l.width) continue;
          final s = (ly * l.width + lx) * 4;
          final a = l.rgba[s + 3] / 255;
          if (a == 0) continue;
          final o = (y * w + x) * 3;
          for (var c = 0; c < 3; c++) {
            acc[o + c] = acc[o + c] * (1 - a) + l.rgba[s + c] * a;
          }
        }
      }
    }
    final out = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      for (var c = 0; c < 3; c++) {
        out[i * 4 + c] = acc[i * 3 + c].round().clamp(0, 255);
      }
      out[i * 4 + 3] = 255;
    }
    return out;
  }
}
