// V2-E (Depth from photo): depth maps for 2.5D photo animation.
//
// The Windows app runs Depth Anything V2 Small (ONNX, see
// lib/platform/windows_ai/depth.dart); this file holds its pure-Dart pre- and
// post-processing and the "fake depth" fallback used on Android or when the
// model is not available, so photo_to_3d always works.
import 'dart:math' as math;
import 'dart:typed_data';

import 'depth_math.dart';

/// Relative depth of a photo: one value per pixel, 0 = far … 1 = near.
class DepthMap {
  final int width, height;
  final Float32List values;

  DepthMap(this.width, this.height, this.values) : assert(values.length == width * height);

  double at(int x, int y) => values[y * width + x];

  /// Grayscale RGBA picture of the map (near = white).
  Uint8List toRgba() {
    final n = width * height;
    final out = Uint8List(n * 4);
    for (var i = 0; i < n; i++) {
      final v = (values[i].clamp(0.0, 1.0) * 255).round();
      out[i * 4] = v;
      out[i * 4 + 1] = v;
      out[i * 4 + 2] = v;
      out[i * 4 + 3] = 255;
    }
    return out;
  }
}

class DepthPrep {
  /// Depth Anything V2 is trained at 518 px with 14 px ViT patches.
  static const target = 518;
  static const patch = 14;

  /// Longest model side (keeps the ViT token count, and CPU time, bounded).
  static const maxLong = 1036;
  static const mean = [0.485, 0.456, 0.406];
  static const std = [0.229, 0.224, 0.225];

  /// Model input size for a [w]×[h] photo: the short side near [target],
  /// the aspect kept, both sides multiples of [patch].
  static (int, int) inputSize(int w, int h, {int target = target, int maxLong = maxLong}) {
    final short = math.min(w, h), long = math.max(w, h);
    var k = target / math.max(1, short);
    if (long * k > maxLong) k = maxLong / long;
    int m(double v) => math.max(patch, (v / patch).round() * patch);
    return (m(w * k), m(h * k));
  }

  /// 1×3×[th]×[tw] float32 NCHW tensor: RGB / 255, then ImageNet mean/std.
  static Float32List inputTensor(Uint8List rgba, int w, int h, int tw, int th) {
    final t = DepthMath.resizePlanar(rgba, w, h, tw, th);
    final plane = tw * th;
    for (var c = 0; c < 3; c++) {
      final m = mean[c], s = std[c];
      for (var i = 0; i < plane; i++) {
        final j = c * plane + i;
        t[j] = (t[j] / 255 - m) / s;
      }
    }
    return t;
  }

  /// Spreads [v] so its [lo]–[hi] percentiles map to 0..1 (clamped). A flat
  /// map becomes all 0.5.
  static Float32List normalize(Float32List v, {double lo = 0.02, double hi = 0.98}) {
    var mn = double.infinity, mx = -double.infinity;
    for (final x in v) {
      if (!x.isFinite) continue;
      if (x < mn) mn = x;
      if (x > mx) mx = x;
    }
    final out = Float32List(v.length);
    if (!mn.isFinite || mx - mn < 1e-9) {
      out.fillRange(0, out.length, 0.5);
      return out;
    }
    final range = mx - mn;
    for (var i = 0; i < v.length; i++) {
      out[i] = v[i].isFinite ? (v[i] - mn) / range : 0;
    }
    final q = DepthMath.quantiles(out, [lo, hi]);
    final a = q[0], b = math.max(q[1], q[0] + 1e-3);
    for (var i = 0; i < out.length; i++) {
      out[i] = ((out[i] - a) / (b - a)).clamp(0.0, 1.0);
    }
    return out;
  }

  /// Smoothing radius for a [w]×[h] map.
  static int smoothRadius(int w, int h) => math.max(2, math.max(w, h) ~/ 160);

  /// Depth at the photo's size from the model's relative inverse depth
  /// [out] ([s]×[t], larger = nearer): robust 0..1 normalisation, bilinear
  /// upsampling, then an edge-aware (guided) smoothing that snaps depth
  /// edges to the photo's edges.
  static DepthMap fromPrediction(Float32List out, int s, int t, Uint8List rgba, int w, int h) {
    if (out.length < s * t) throw ArgumentError('depth output has ${out.length} values, expected ${s * t}');
    final norm = normalize(Float32List.sublistView(out, 0, s * t));
    return _finish(DepthMath.resample(norm, s, t, w, h), rgba, w, h);
  }

  static DepthMap _finish(Float32List d, Uint8List rgba, int w, int h) {
    final g = DepthMath.luma(rgba, w, h);
    final sm = DepthMath.guided(g, d, w, h, smoothRadius(w, h), 2e-3);
    for (var i = 0; i < sm.length; i++) {
      sm[i] = sm[i].clamp(0.0, 1.0);
    }
    return DepthMap(w, h, sm);
  }

  /// "Fake depth" without a model: bottom of the frame is near, the top far
  /// (ground plane), sky-like regions (bright, bluish, smooth, high up) are
  /// pushed far, detailed and saturated regions come forward (atmospheric
  /// haze), then it is blurred and snapped to the photo's edges.
  static DepthMap fake(Uint8List rgba, int w, int h) {
    final k = math.min(1.0, 256 / math.max(w, h));
    final sw = math.max(2, (w * k).round()), sh = math.max(2, (h * k).round());
    final p = DepthMath.resizePlanar(rgba, w, h, sw, sh);
    final n = sw * sh;
    final lum = Float32List(n), sat = Float32List(n), blue = Float32List(n);
    for (var i = 0; i < n; i++) {
      final r = p[i] / 255, g = p[n + i] / 255, b = p[2 * n + i] / 255;
      lum[i] = 0.299 * r + 0.587 * g + 0.114 * b;
      final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
      sat[i] = mx <= 1e-6 ? 0 : (mx - mn) / mx;
      blue[i] = (b - r).clamp(-1.0, 1.0);
    }
    // Local contrast (detail): std of luma in a small window.
    final r1 = math.max(1, math.max(sw, sh) ~/ 64);
    final m1 = DepthMath.boxMean(lum, sw, sh, r1);
    final sq = Float32List(n);
    for (var i = 0; i < n; i++) {
      sq[i] = lum[i] * lum[i];
    }
    final m2 = DepthMath.boxMean(sq, sw, sh, r1);
    final detail = Float32List(n);
    var dMax = 1e-6;
    for (var i = 0; i < n; i++) {
      final v = math.sqrt(math.max(0.0, m2[i] - m1[i] * m1[i]));
      detail[i] = v;
      if (v > dMax) dMax = v;
    }
    final d = Float32List(n);
    for (var y = 0; y < sh; y++) {
      final v = y / (sh - 1);
      final ground = math.pow(v, 1.2).toDouble();
      for (var x = 0; x < sw; x++) {
        final i = y * sw + x;
        final det = math.min(1.0, detail[i] / (dMax * 0.6));
        final skyness = ((lum[i] - 0.45) * 2.5).clamp(0.0, 1.0) *
            (1 - det) *
            (0.5 + 0.5 * ((blue[i] + 0.1) * 4).clamp(0.0, 1.0)) *
            (1 - v).clamp(0.0, 1.0);
        d[i] = 0.62 * ground + 0.22 * det + 0.12 * sat[i] - 0.35 * skyness;
      }
    }
    final rb = math.max(1, math.max(sw, sh) ~/ 24);
    final blurred = DepthMath.boxMean(DepthMath.boxMean(d, sw, sh, rb), sw, sh, rb);
    final norm = normalize(blurred, lo: 0.01, hi: 0.99);
    return _finish(DepthMath.resample(norm, sw, sh, w, h), rgba, w, h);
  }
}
