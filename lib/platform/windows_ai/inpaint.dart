// Object erase for Windows (Agent E): pure-Dart port of the phone's Kotlin
// multi-scale diffusion inpaint (MediaBridge.kt `inpaint` / `fillLevel`).
import 'dart:typed_data';

import 'image_io.dart';

class Inpaint {
  /// Mask pixels whose green channel is above this are erased (as on Android).
  static const maskThreshold = 100;

  /// Hole map (1 = fill) from an RGBA mask: white strokes on black.
  static Uint8List holeFromMask(Rgba mask) {
    final n = mask.width * mask.height;
    final hole = Uint8List(n);
    for (var i = 0; i < n; i++) {
      hole[i] = mask.data[i * 4 + 1] > maskThreshold ? 1 : 0;
    }
    return hole;
  }

  /// Fills the pixels of [src] marked in [hole] from their surroundings.
  /// Returns a new opaque bitmap; known pixels are unchanged.
  static Rgba fill(Rgba src, Uint8List hole) {
    final w = src.width, h = src.height, n = w * h;
    if (hole.length != n) throw ArgumentError('mask size does not match the image');
    final r = Float32List(n), g = Float32List(n), b = Float32List(n);
    final px = src.data;
    for (var i = 0; i < n; i++) {
      r[i] = px[i * 4].toDouble();
      g[i] = px[i * 4 + 1].toDouble();
      b[i] = px[i * 4 + 2].toDouble();
    }
    fillLevel(r, g, b, hole, w, h);
    final out = Uint8List.fromList(px);
    for (var i = 0; i < n; i++) {
      if (hole[i] == 0) continue;
      out[i * 4] = _u8(r[i]);
      out[i * 4 + 1] = _u8(g[i]);
      out[i * 4 + 2] = _u8(b[i]);
      out[i * 4 + 3] = 255;
    }
    return Rgba(w, h, out);
  }

  static int _u8(double v) => v <= 0 ? 0 : (v >= 255 ? 255 : v.toInt());

  /// Recursive coarse-to-fine fill: solve at half size, upsample as a start,
  /// then diffuse inside the hole (known pixels stay fixed).
  static void fillLevel(Float32List r, Float32List g, Float32List b, Uint8List hole, int w, int h) {
    // Bounding box of the hole: all the work happens inside it.
    var x0 = w, y0 = h, x1 = -1, y1 = -1;
    for (var y = 0; y < h; y++) {
      final row = y * w;
      for (var x = 0; x < w; x++) {
        if (hole[row + x] == 0) continue;
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
    if (x1 < 0) return; // nothing to fill

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
      fillLevel(r2, g2, b2, hole2, w2, h2);
      for (var y = y0; y <= y1; y++) {
        final yy = (y ~/ 2 < h2 - 1 ? y ~/ 2 : h2 - 1) * w2;
        for (var x = x0; x <= x1; x++) {
          final i = y * w + x;
          if (hole[i] == 0) continue;
          final j = yy + (x ~/ 2 < w2 - 1 ? x ~/ 2 : w2 - 1);
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
    // Diffuse inside the hole (known pixels stay fixed).
    final iters = w * h > 600000 ? 6 : 14;
    final ya = y0 < 1 ? 1 : y0, yb = y1 > h - 2 ? h - 2 : y1;
    final xa = x0 < 1 ? 1 : x0, xb = x1 > w - 2 ? w - 2 : x1;
    for (var it = 0; it < iters; it++) {
      for (var y = ya; y <= yb; y++) {
        for (var x = xa; x <= xb; x++) {
          final i = y * w + x;
          if (hole[i] == 0) continue;
          r[i] = (r[i - 1] + r[i + 1] + r[i - w] + r[i + w]) * 0.25;
          g[i] = (g[i - 1] + g[i + 1] + g[i - w] + g[i + w]) * 0.25;
          b[i] = (b[i - 1] + b[i + 1] + b[i - w] + b[i + w]) * 0.25;
        }
      }
    }
  }

  /// File version used by WinAi.inpaint: [maskPath] is resized to the
  /// image when needed; output is JPEG (or PNG for a .png [outPath]).
  static (int, int) file(String imagePath, String maskPath, String outPath) {
    final src = ImageIo.toRgba(ImageIo.readUpright(imagePath));
    var maskImg = ImageIo.readUpright(maskPath);
    if (maskImg.width != src.width || maskImg.height != src.height) {
      maskImg = ImageIo.resize(maskImg, src.width, src.height);
    }
    final out = fill(src, holeFromMask(ImageIo.toRgba(maskImg)));
    ImageIo.write(outPath, out, quality: 94);
    return (out.width, out.height);
  }
}
