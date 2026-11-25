// Photo subject cut-out for Windows (Agent E): salient-object segmentation
// with U²-Net-p (rembg's "u2netp", 4.4 MB ONNX) run through ONNX Runtime,
// plus pure-Dart pre/post-processing (tensor, mask refine, plates).
import 'dart:math' as math;
import 'dart:typed_data';

import 'image_io.dart';
import 'model_store.dart';
import 'ort_ffi.dart';

class Segment {
  /// rembg's u2netp model (Apache-2.0, from xuebinqin/U-2-Net), 320×320 input.
  static const model = ModelSpec(
    fileName: 'u2netp.onnx',
    urls: [
      'https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2netp.onnx',
    ],
    bytes: 4574861,
    hashKind: HashKind.sha256,
    hash: '309c8469258dda742793dce0ebea8e6dd393174f89934733ecc8b14c76f4ddd8',
    label: 'cut-out model',
  );

  static const inputSize = 320;
  static const maxSide = 2048; // same limit as the phone
  static const mean = [0.485, 0.456, 0.406];
  static const std = [0.229, 0.224, 0.225];

  // ------------------------------------------------------------ resampling

  /// [src] resized to [tw]×[th] as planar RGB floats 0..255 (plane c at
  /// c*tw*th). Area average when shrinking, bilinear when growing.
  static Float32List resizePlanar(Rgba src, int tw, int th) {
    final w = src.width, h = src.height, px = src.data;
    final out = Float32List(3 * tw * th);
    final plane = tw * th;
    final sx = w / tw, sy = h / th;
    for (var y = 0; y < th; y++) {
      for (var x = 0; x < tw; x++) {
        final o = y * tw + x;
        if (sx >= 1 && sy >= 1) {
          final xa = (x * sx).floor(), xb = math.max(xa + 1, ((x + 1) * sx).ceil().clamp(0, w).toInt());
          final ya = (y * sy).floor(), yb = math.max(ya + 1, ((y + 1) * sy).ceil().clamp(0, h).toInt());
          var r = 0, g = 0, b = 0;
          for (var yy = ya; yy < yb; yy++) {
            var i = (yy * w + xa) * 4;
            for (var xx = xa; xx < xb; xx++, i += 4) {
              r += px[i];
              g += px[i + 1];
              b += px[i + 2];
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
            final a = px[(y0 * w + x0) * 4 + c] + (px[(y0 * w + x1) * 4 + c] - px[(y0 * w + x0) * 4 + c]) * kx;
            final d = px[(y1 * w + x0) * 4 + c] + (px[(y1 * w + x1) * 4 + c] - px[(y1 * w + x0) * 4 + c]) * kx;
            out[c * plane + o] = a + (d - a) * ky;
          }
        }
      }
    }
    return out;
  }

  /// Bilinear sample of a single-channel [s]×[t] float map at w×h.
  static Float32List upsample(Float32List m, int s, int t, int w, int h) {
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

  // ----------------------------------------------------------- model I/O

  /// Model input: 1×3×[s]×[s] float32 in NCHW order, pixels divided by the
  /// image's maximum value, then ImageNet mean/std per channel (as rembg).
  static Float32List inputTensor(Rgba src, {int s = inputSize}) {
    final t = resizePlanar(src, s, s);
    var maxV = 1e-6;
    for (final v in t) {
      if (v > maxV) maxV = v;
    }
    final plane = s * s;
    for (var c = 0; c < 3; c++) {
      for (var i = 0; i < plane; i++) {
        final j = c * plane + i;
        t[j] = (t[j] / maxV - mean[c]) / std[c];
      }
    }
    return t;
  }

  /// First channel of the model output, min-max normalised to 0..1.
  static Float32List normalizePrediction(Float32List out, int s) {
    final n = s * s;
    var lo = double.infinity, hi = -double.infinity;
    for (var i = 0; i < n; i++) {
      final v = out[i];
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    final range = hi - lo;
    final p = Float32List(n);
    if (range.abs() < 1e-12) return p; // flat map: no subject
    for (var i = 0; i < n; i++) {
      p[i] = (out[i] - lo) / range;
    }
    return p;
  }

  // -------------------------------------------------------- mask refine

  /// Luma 0..1 of [src].
  static Float32List luma(Rgba src) {
    final n = src.width * src.height, px = src.data;
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = (0.299 * px[i * 4] + 0.587 * px[i * 4 + 1] + 0.114 * px[i * 4 + 2]) / 255;
    }
    return out;
  }

  /// Mean of [v] over a (2r+1)² window (clamped at the borders).
  static Float32List boxMean(Float32List v, int w, int h, int r) {
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

  /// Guided-filter coefficients (He et al.): q = a·I + b follows the edges of
  /// guide [g] while keeping the values of [p]. Returns (a, b).
  static (Float32List, Float32List) guidedCoefficients(Float32List g, Float32List p, int w, int h, int r, double eps) {
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
    return (boxMean(a, w, h, r), boxMean(b, w, h, r));
  }

  /// Contrast curve from soft saliency (0..1) to alpha: clean background,
  /// solid subject, soft edges.
  static int alphaOf(double v) {
    final e = (v - 0.12) / 0.76;
    return e <= 0 ? 0 : (e >= 1 ? 255 : (e * 255).round());
  }

  /// Alpha mask (0..255) at the photo's size from the normalised [pred]
  /// (s×s). With [refine] the edges are snapped to the photo with a guided
  /// filter computed at up to 1024 px.
  static Uint8List alphaMask(Float32List pred, int s, Rgba src, {bool refine = true}) {
    final w = src.width, h = src.height, n = w * h;
    final out = Uint8List(n);
    if (!refine || w < 8 || h < 8) {
      final m = upsample(pred, s, s, w, h);
      for (var i = 0; i < n; i++) {
        out[i] = alphaOf(m[i]);
      }
      return out;
    }
    final k = math.min(1.0, 1024 / math.max(w, h));
    final gw = math.max(1, (w * k).round()), gh = math.max(1, (h * k).round());
    final small = resizePlanar(src, gw, gh);
    final gn = gw * gh;
    final g = Float32List(gn);
    for (var i = 0; i < gn; i++) {
      g[i] = (0.299 * small[i] + 0.587 * small[gn + i] + 0.114 * small[2 * gn + i]) / 255;
    }
    final p = upsample(pred, s, s, gw, gh);
    final r = math.max(2, math.max(gw, gh) ~/ 110);
    final (a, b) = guidedCoefficients(g, p, gw, gh, r, 1e-3);
    final full = luma(src);
    final ua = upsample(a, gw, gh, w, h), ub = upsample(b, gw, gh, w, h);
    for (var i = 0; i < n; i++) {
      out[i] = alphaOf(ua[i] * full[i] + ub[i]);
    }
    return out;
  }

  // ----------------------------------------------------------- outputs

  /// Subject with [alpha] as transparency (existing alpha is kept).
  static Rgba foreground(Rgba src, Uint8List alpha) {
    final d = Uint8List.fromList(src.data);
    for (var i = 0; i < alpha.length; i++) {
      d[i * 4 + 3] = (d[i * 4 + 3] * alpha[i] + 127) ~/ 255;
    }
    return Rgba(src.width, src.height, d);
  }

  /// Background plate as on the phone: the subject (mask > 20, grown by
  /// max(2, side/120) px) replaced by a heavy blur of the photo, so parallax
  /// never reveals a sharp copy of the subject.
  static Rgba backgroundPlate(Rgba src, Uint8List alpha) {
    final w = src.width, h = src.height, n = w * h;
    final sw = math.max(1, w ~/ 24), sh = math.max(1, h ~/ 24);
    final small = resizePlanar(src, sw, sh);
    final sp = sw * sh;
    final planes = [for (var c = 0; c < 3; c++) upsample(Float32List.sublistView(small, c * sp, (c + 1) * sp), sw, sh, w, h)];
    final r = math.max(2, math.max(w, h) ~/ 120);
    final step = math.max(1, r ~/ 2);
    final grown = Uint8List(n);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (alpha[y * w + x] <= 20) continue;
        for (var dy = -r; dy <= r; dy += step) {
          final yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (var dx = -r; dx <= r; dx += step) {
            final xx = x + dx;
            if (xx >= 0 && xx < w) grown[yy * w + xx] = 1;
          }
        }
      }
    }
    final d = Uint8List.fromList(src.data);
    for (var i = 0; i < n; i++) {
      if (grown[i] == 0) continue;
      for (var c = 0; c < 3; c++) {
        final v = planes[c][i];
        d[i * 4 + c] = v <= 0 ? 0 : (v >= 255 ? 255 : v.round());
      }
      d[i * 4 + 3] = 255;
    }
    return Rgba(w, h, d);
  }

  /// Share of pixels that belong to the subject.
  static double coverage(Uint8List alpha) {
    if (alpha.isEmpty) return 0;
    var c = 0;
    for (final a in alpha) {
      if (a > 20) c++;
    }
    return c / alpha.length;
  }

  static (Float32List, List<int>) _predict(String ortLibrary, String modelPath, Float32List input, int threads) {
    final session = OrtSession.open(ortLibrary, modelPath, threads: threads);
    try {
      return session.run(input, const [1, 3, inputSize, inputSize]);
    } finally {
      session.dispose();
    }
  }

  /// Whole cut-out (call inside an isolate): returns (width, height).
  static (int, int) cutoutFile(String ortLibrary, String modelPath, String path, String fgPath, String bgPath, int threads) {
    final src = ImageIo.toRgba(ImageIo.limit(ImageIo.readUpright(path), maxSide));
    final (out, dims) = _predict(ortLibrary, modelPath, inputTensor(src), threads);
    final s = dims.length >= 2 && dims.last > 0 ? dims.last : inputSize;
    if (out.length < s * s) throw StateError('Unexpected cut-out model output $dims');
    final alpha = alphaMask(normalizePrediction(out, s), s, src);
    if (coverage(alpha) < 0.005) throw StateError('No subject found in this photo');
    ImageIo.writePng(fgPath, foreground(src, alpha));
    ImageIo.write(bgPath, backgroundPlate(src, alpha));
    return (src.width, src.height);
  }
}
