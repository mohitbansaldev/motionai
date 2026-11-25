import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Pure-Dart image work used on Windows (the phone does these in Kotlin):
/// photo normalisation, object erase (inpaint) and cut-out compositing.
/// Heavy calls run in a background isolate.
class ImageOps {
  // ----------------------------------------------------------- normalise

  /// Decodes any photo the `image` package reads, applies EXIF rotation,
  /// limits it to 4096 px and writes a JPEG (PNG when it has transparency).
  /// Returns (path, width, height).
  static Future<(String, int, int)> normalizeImage(String path, String outBase) =>
      Isolate.run(() => _normalize(path, outBase));

  static (String, int, int) _normalize(String path, String outBase) {
    final bytes = File(path).readAsBytesSync();
    var im = img.decodeImage(bytes);
    if (im == null) throw const FormatException('This image format can\'t be read');
    im = img.bakeOrientation(im);
    final long = math.max(im.width, im.height);
    if (long > 4096) {
      im = im.width >= im.height
          ? img.copyResize(im, width: 4096, interpolation: img.Interpolation.average)
          : img.copyResize(im, height: 4096, interpolation: img.Interpolation.average);
    }
    final png = im.hasAlpha && path.toLowerCase().endsWith('.png');
    final out = '$outBase${png ? '.png' : '.jpg'}';
    File(out).writeAsBytesSync(png ? img.encodePng(im) : img.encodeJpg(im, quality: 92));
    return (out, im.width, im.height);
  }

  // -------------------------------------------------------------- erase

  /// Fills the white area of [maskPath] with surrounding pixels using a
  /// coarse-to-fine diffusion (port of the phone's Kotlin inpaint).
  static Future<String> inpaint(String path, String maskPath, String outPath) =>
      Isolate.run(() => _inpaintFile(path, maskPath, outPath));

  static String _inpaintFile(String path, String maskPath, String outPath) {
    final src = img.decodeImage(File(path).readAsBytesSync());
    if (src == null) throw const FormatException('Cannot read image');
    var mask = img.decodeImage(File(maskPath).readAsBytesSync());
    if (mask == null) throw const FormatException('Cannot read mask');
    final w = src.width, h = src.height;
    if (mask.width != w || mask.height != h) {
      mask = img.copyResize(mask, width: w, height: h, interpolation: img.Interpolation.linear);
    }
    final rgba = rgbaBytes(src);
    final m = rgbaBytes(mask);
    final n = w * h;
    final hole = Uint8List(n);
    final r = Float32List(n), g = Float32List(n), b = Float32List(n);
    for (var i = 0; i < n; i++) {
      hole[i] = m[i * 4 + 1] > 100 ? 1 : 0;
      r[i] = rgba[i * 4].toDouble();
      g[i] = rgba[i * 4 + 1].toDouble();
      b[i] = rgba[i * 4 + 2].toDouble();
    }
    inpaintPlanes(r, g, b, hole, w, h);
    for (var i = 0; i < n; i++) {
      if (hole[i] == 0) continue;
      rgba[i * 4] = _u8(r[i]);
      rgba[i * 4 + 1] = _u8(g[i]);
      rgba[i * 4 + 2] = _u8(b[i]);
      rgba[i * 4 + 3] = 255;
    }
    final out = img.Image.fromBytes(width: w, height: h, bytes: rgba.buffer, numChannels: 4, order: img.ChannelOrder.rgba);
    File(outPath).writeAsBytesSync(img.encodeJpg(out, quality: 94));
    return outPath;
  }

  static int _u8(double v) => v <= 0 ? 0 : (v >= 255 ? 255 : v.round());

  /// Recursive coarse-to-fine fill: solve at half size, upsample as a start,
  /// then diffuse inside the hole (known pixels stay fixed).
  static void inpaintPlanes(Float32List r, Float32List g, Float32List b, Uint8List hole, int w, int h) {
    if (w > 24 && h > 24) {
      final w2 = w ~/ 2, h2 = h ~/ 2;
      final r2 = Float32List(w2 * h2), g2 = Float32List(w2 * h2), b2 = Float32List(w2 * h2);
      final hole2 = Uint8List(w2 * h2);
      for (var y = 0; y < h2; y++) {
        for (var x = 0; x < w2; x++) {
          var sr = 0.0, sg = 0.0, sb = 0.0;
          var cnt = 0;
          var anyHole = false;
          for (var dy = 0; dy < 2; dy++) {
            for (var dx = 0; dx < 2; dx++) {
              final i = (y * 2 + dy) * w + (x * 2 + dx);
              if (hole[i] != 0) {
                anyHole = true;
              } else {
                sr += r[i];
                sg += g[i];
                sb += b[i];
                cnt++;
              }
            }
          }
          final j = y * w2 + x;
          if (cnt > 0) {
            r2[j] = sr / cnt;
            g2[j] = sg / cnt;
            b2[j] = sb / cnt;
          }
          hole2[j] = (cnt == 0 || (anyHole && cnt < 2)) ? 1 : 0;
        }
      }
      inpaintPlanes(r2, g2, b2, hole2, w2, h2);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = y * w + x;
          if (hole[i] == 0) continue;
          final j = math.min(y ~/ 2, h2 - 1) * w2 + math.min(x ~/ 2, w2 - 1);
          r[i] = r2[j];
          g[i] = g2[j];
          b[i] = b2[j];
        }
      }
    } else {
      // Coarsest level: start holes from the mean of known pixels.
      var sr = 0.0, sg = 0.0, sb = 0.0;
      var cnt = 0;
      for (var i = 0; i < hole.length; i++) {
        if (hole[i] == 0) {
          sr += r[i];
          sg += g[i];
          sb += b[i];
          cnt++;
        }
      }
      if (cnt > 0) {
        for (var i = 0; i < hole.length; i++) {
          if (hole[i] != 0) {
            r[i] = sr / cnt;
            g[i] = sg / cnt;
            b[i] = sb / cnt;
          }
        }
      }
    }
    final iters = w * h > 600000 ? 6 : 14;
    for (var it = 0; it < iters; it++) {
      for (var y = 1; y < h - 1; y++) {
        for (var x = 1; x < w - 1; x++) {
          final i = y * w + x;
          if (hole[i] == 0) continue;
          r[i] = (r[i - 1] + r[i + 1] + r[i - w] + r[i + w]) * 0.25;
          g[i] = (g[i - 1] + g[i + 1] + g[i - w] + g[i + w]) * 0.25;
          b[i] = (b[i - 1] + b[i + 1] + b[i - w] + b[i + w]) * 0.25;
        }
      }
    }
  }

  // ------------------------------------------------------------- helpers

  /// 8-bit RGBA bytes of any decoded image.
  static Uint8List rgbaBytes(img.Image im) {
    final c = (im.format == img.Format.uint8 && im.numChannels == 4 && !im.hasPalette)
        ? im
        : im.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
    return Uint8List.fromList(c.getBytes(order: img.ChannelOrder.rgba));
  }

  /// Loads a photo for cut-out: upright, at most [maxSide] px.
  static img.Image loadUpright(String path, {int maxSide = 2048}) {
    var im = img.decodeImage(File(path).readAsBytesSync());
    if (im == null) throw const FormatException('Cannot read image');
    im = img.bakeOrientation(im);
    if (math.max(im.width, im.height) > maxSide) {
      im = im.width >= im.height
          ? img.copyResize(im, width: maxSide, interpolation: img.Interpolation.average)
          : img.copyResize(im, height: maxSide, interpolation: img.Interpolation.average);
    }
    return im;
  }

  /// u2net-style input tensor (1×3×s×s, ImageNet mean/std) for [im].
  static Float32List saliencyInput(img.Image im, int s) {
    final small = img.copyResize(im, width: s, height: s, interpolation: img.Interpolation.cubic);
    final px = rgbaBytes(small);
    var maxV = 1e-6;
    for (var i = 0; i < s * s; i++) {
      maxV = math.max(maxV, math.max(px[i * 4].toDouble(), math.max(px[i * 4 + 1].toDouble(), px[i * 4 + 2].toDouble())));
    }
    const mean = [0.485, 0.456, 0.406], std = [0.229, 0.224, 0.225];
    final t = Float32List(3 * s * s);
    for (var i = 0; i < s * s; i++) {
      for (var c = 0; c < 3; c++) {
        t[c * s * s + i] = (px[i * 4 + c] / maxV - mean[c]) / std[c];
      }
    }
    return t;
  }

  /// Min-max normalised saliency map (s×s floats) → 0..255 mask at w×h.
  static Uint8List maskFromSaliency(Float32List pred, int s, int w, int h) {
    var lo = double.infinity, hi = -double.infinity;
    for (final v in pred) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    final range = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;
    final out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      final fy = ((y + 0.5) * s / h - 0.5).clamp(0.0, s - 1.0);
      final y0 = fy.floor(), y1 = math.min(y0 + 1, s - 1);
      final ky = fy - y0;
      for (var x = 0; x < w; x++) {
        final fx = ((x + 0.5) * s / w - 0.5).clamp(0.0, s - 1.0);
        final x0 = fx.floor(), x1 = math.min(x0 + 1, s - 1);
        final kx = fx - x0;
        final a = pred[y0 * s + x0] + (pred[y0 * s + x1] - pred[y0 * s + x0]) * kx;
        final c = pred[y1 * s + x0] + (pred[y1 * s + x1] - pred[y1 * s + x0]) * kx;
        final v = ((a + (c - a) * ky) - lo) / range;
        // Gentle contrast curve: crisp edges, soft hair.
        final e = ((v - 0.12) / 0.76).clamp(0.0, 1.0);
        out[y * w + x] = (e * 255).round();
      }
    }
    return out;
  }

  /// Writes the transparent subject PNG and the background plate (subject
  /// area replaced by a heavy blur, so parallax shows no sharp duplicate).
  static (int, int) writeCutout(img.Image src, Uint8List mask, String fgPath, String bgPath) {
    final w = src.width, h = src.height, n = w * h;
    final px = rgbaBytes(src);
    var covered = 0;
    final fg = Uint8List.fromList(px);
    for (var i = 0; i < n; i++) {
      fg[i * 4 + 3] = mask[i];
      if (mask[i] > 20) covered++;
    }
    if (covered < n * 0.005) throw StateError('No subject found in this photo');
    final fgImg = img.Image.fromBytes(width: w, height: h, bytes: fg.buffer, numChannels: 4, order: img.ChannelOrder.rgba);
    File(fgPath).writeAsBytesSync(img.encodePng(fgImg, level: 4));

    final small = img.copyResize(src, width: math.max(1, w ~/ 24), height: math.max(1, h ~/ 24), interpolation: img.Interpolation.average);
    final blurred = rgbaBytes(img.copyResize(small, width: w, height: h, interpolation: img.Interpolation.linear));
    final r = math.max(2, math.max(w, h) ~/ 120);
    final step = math.max(1, r ~/ 2);
    final grown = Uint8List(n);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (mask[y * w + x] <= 20) continue;
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
    final bg = Uint8List.fromList(px);
    for (var i = 0; i < n; i++) {
      if (grown[i] == 0) continue;
      bg[i * 4] = blurred[i * 4];
      bg[i * 4 + 1] = blurred[i * 4 + 1];
      bg[i * 4 + 2] = blurred[i * 4 + 2];
      bg[i * 4 + 3] = 255;
    }
    final bgImg = img.Image.fromBytes(width: w, height: h, bytes: bg.buffer, numChannels: 4, order: img.ChannelOrder.rgba);
    File(bgPath).writeAsBytesSync(img.encodeJpg(bgImg, quality: 92));
    return (w, h);
  }
}
