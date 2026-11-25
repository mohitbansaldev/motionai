// V2-F: pure-Dart clean-up of generated assets (Google Flow / Gemini):
// green / blue screen → alpha PNG, and the small "✦" sparkle mark in the
// bottom-right corner → inpainted. No Flutter imports: runs in an isolate
// on Windows and Android, and in tests on synthetic images.
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../core/engine/chroma.dart';
import '../platform/windows_ai/image_io.dart';
import '../platform/windows_ai/inpaint.dart';

/// A flat chroma screen found around the picture.
class ScreenInfo {
  final String name; // green | blue
  final List<int> rgb; // median screen colour
  final double coverage; // share of border samples that are screen
  const ScreenInfo(this.name, this.rgb, this.coverage);
  String get hex => ChromaMath.hex(rgb);
}

/// A detected watermark sparkle: its bounding box and the pixels to fill.
class MarkInfo {
  final int x0, y0, x1, y1; // inclusive box of the bright blob
  final List<int> pixels; // blob pixel indices (y * w + x)
  const MarkInfo(this.x0, this.y0, this.x1, this.y1, this.pixels);
  int get size => math.max(x1 - x0 + 1, y1 - y0 + 1);
}

/// What one clean pass did (JSON-friendly, isolate-safe).
class CleanOutcome {
  int width = 0, height = 0;
  bool alpha = false; // the output (or the untouched input) has transparency
  bool keyed = false;
  bool markFound = false, markRemoved = false;
  String keyColor = '';
  double coverage = 0;
  String output = ''; // written file ('' = nothing changed)
  String error = '';

  List<String> get fixes => [if (keyed) 'green_screen', if (markRemoved) 'mark'];

  Map<String, dynamic> toJson() => {
        'size': [width, height],
        if (alpha) 'transparent': true,
        if (keyed) 'keyed': keyColor,
        if (markFound) 'mark': markRemoved ? 'removed' : 'found (pass remove_mark:true to remove)',
        if (error.isNotEmpty) 'error': error,
      };
}

/// Inputs of one clean pass (plain fields so it can cross isolates).
class CleanJob {
  final String source;
  final String outBase; // output path without extension (.png / .jpg added)
  final String greenScreen; // auto | true | false
  final bool removeMark;
  final bool analyseOnly;
  const CleanJob(this.source, this.outBase, {this.greenScreen = 'auto', this.removeMark = false, this.analyseOnly = false});
}

class ImageClean {
  static int _luma(Uint8List d, int o) => (d[o] * 54 + d[o + 1] * 183 + d[o + 2] * 19) >> 8;

  static bool _isGreen(int r, int g, int b) => g > r * 1.15 + 8 && g > b * 1.1 + 8 && g - math.max(r, b) > 25;
  static bool _isBlue(int r, int g, int b) => b > r * 1.15 + 8 && b > g * 1.05 + 8 && b - math.max(r, g) > 25;

  /// True when some pixel is noticeably transparent.
  static bool hasRealAlpha(Rgba im) {
    final d = im.data;
    for (int o = 3; o < d.length; o += 4) {
      if (d[o] < 250) return true;
    }
    return false;
  }

  /// A flat green / blue screen around the subject: the outer border band
  /// must be dominated by one chroma colour. [strict] (auto mode) also asks
  /// for ≥ 3 sides of screen and an even (untextured) screen, so photos of
  /// grass or the sea are left alone. Null for cut-outs that already have
  /// transparency at the border.
  static ScreenInfo? detectScreen(Rgba im, {bool strict = true}) {
    final w = im.width, h = im.height, d = im.data;
    if (w < 8 || h < 8) return null;
    final band = math.max(2, (math.min(w, h) * 0.035).round());
    final per = math.max(1, (2 * (w + h) * band / 5000).floor());
    final step = math.max(1, math.sqrt(per).floor());
    final greens = <int>[], blues = <int>[];
    final sideTotal = List<int>.filled(4, 0), sideG = List<int>.filled(4, 0), sideB = List<int>.filled(4, 0);
    var total = 0, clear = 0;
    void sample(int x, int y, int side) {
      final o = (y * w + x) * 4;
      total++;
      sideTotal[side]++;
      if (d[o + 3] < 128) {
        clear++;
        return;
      }
      final r = d[o], g = d[o + 1], b = d[o + 2];
      if (_isGreen(r, g, b)) {
        greens.add(o);
        sideG[side]++;
      } else if (_isBlue(r, g, b)) {
        blues.add(o);
        sideB[side]++;
      }
    }

    for (int y = 0; y < h; y += step) {
      for (int x = 0; x < w; x += step) {
        final side = y < band ? 0 : (y >= h - band ? 2 : (x < band ? 3 : (x >= w - band ? 1 : -1)));
        if (side >= 0) sample(x, y, side);
      }
    }
    if (total == 0 || clear > total * 0.3) return null;
    final isGreen = greens.length >= blues.length;
    final best = isGreen ? greens : blues;
    final coverage = best.length / total;
    if (coverage < (strict ? 0.6 : 0.25)) return null;
    int median(List<int> v) {
      v.sort();
      return v[v.length ~/ 2];
    }

    final rgb = [for (int c = 0; c < 3; c++) median([for (final o in best) d[o + c]])];
    if (strict) {
      // Chroma screens are far more saturated than skies, sea or foliage.
      final sat = isGreen ? rgb[1] - math.max(rgb[0], rgb[2]) : rgb[2] - math.max(rgb[0], rgb[1]);
      if (sat < 80) return null;
      var sides = 0;
      for (int s = 0; s < 4; s++) {
        final n = isGreen ? sideG[s] : sideB[s];
        if (sideTotal[s] > 0 && n >= sideTotal[s] * 0.5) sides++;
      }
      if (sides < 3) return null;
      // Even screen: luma spread (inter-quartile) of the screen samples.
      final lum = [for (final o in best) _luma(d, o)]..sort();
      final iqr = lum[(lum.length * 3) ~/ 4] - lum[lum.length ~/ 4];
      if (iqr > 40) return null;
    }
    return ScreenInfo(isGreen ? 'green' : 'blue', rgb, coverage);
  }

  /// Keys [s] out of [im] with the chroma_key maths (tolerance, softness,
  /// spill suppression, a light choke): straight-alpha RGBA.
  static Rgba keyScreen(Rgba im, ScreenInfo s, {double tolerance = 40, double softness = 16, double spill = 70, double? chokePx}) {
    final settings = ChromaSettings(r: s.rgb[0].toDouble(), g: s.rgb[1].toDouble(), b: s.rgb[2].toDouble(), tolerance: tolerance, softness: softness, spill: spill);
    final choke = chokePx ?? math.max(0.6, math.min(im.width, im.height) / 1400);
    final out = ChromaMath.key(im.data, im.width, im.height, settings, chokePx: choke);
    for (int o = 0; o < out.length; o += 4) {
      if (out[o + 3] == 0) {
        out[o] = 0;
        out[o + 1] = 0;
        out[o + 2] = 0;
      }
    }
    return Rgba(im.width, im.height, out);
  }

  /// The small white 4-point sparkle Gemini / Flow put in the bottom-right
  /// corner (≈ 2–3 % of the width, ≈ 3–4 % in from the edges). Conservative:
  /// only an isolated, bright, roughly square blob shaped like a star (arms
  /// along the axes, empty corners) near the corner is reported.
  static MarkInfo? detectMark(Rgba im) {
    final w = im.width, h = im.height, d = im.data;
    final ref = math.max(w, h);
    if (w < 64 || h < 64) return null;
    final win = math.min(math.min(w, h), (ref * 0.13).round());
    final wx0 = w - win, wy0 = h - win;
    // Background level of the corner (median luma of opaque pixels).
    final lumHist = List<int>.filled(256, 0);
    var cnt = 0;
    for (int y = wy0; y < h; y += 2) {
      for (int x = wx0; x < w; x += 2) {
        final o = (y * w + x) * 4;
        if (d[o + 3] < 128) continue;
        lumHist[_luma(d, o)]++;
        cnt++;
      }
    }
    var bg = 0;
    if (cnt > 0) {
      var acc = 0;
      while (bg < 255 && acc + lumHist[bg] < cnt / 2) {
        acc += lumHist[bg];
        bg++;
      }
    }
    final thr = math.max(175, bg + 45);
    bool bright(int x, int y) {
      final o = (y * w + x) * 4;
      if (d[o + 3] < 128) return false;
      final r = d[o], g = d[o + 1], b = d[o + 2];
      return _luma(d, o) >= thr && math.max(r, math.max(g, b)) - math.min(r, math.min(g, b)) < 90;
    }

    final seen = Uint8List(win * win);
    MarkInfo? best;
    var bestDist = double.infinity;
    final minSize = math.max(5, (ref * 0.006).round()), maxSize = math.max(minSize + 2, (ref * 0.06).round());
    for (int y = wy0; y < h; y++) {
      for (int x = wx0; x < w; x++) {
        final li = (y - wy0) * win + (x - wx0);
        if (seen[li] != 0 || !bright(x, y)) continue;
        // Flood fill one bright component (4-connected).
        final pix = <int>[];
        final q = Queue<int>()..add(y * w + x);
        seen[li] = 1;
        var x0 = x, x1 = x, y0 = y, y1 = y;
        while (q.isNotEmpty) {
          final i = q.removeFirst();
          pix.add(i);
          final px = i % w, py = i ~/ w;
          if (px < x0) x0 = px;
          if (px > x1) x1 = px;
          if (py < y0) y0 = py;
          if (py > y1) y1 = py;
          if (pix.length > maxSize * maxSize) break;
          for (final (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)]) {
            if (nx < wx0 || ny < wy0 || nx >= w || ny >= h) continue;
            final nl = (ny - wy0) * win + (nx - wx0);
            if (seen[nl] != 0 || !bright(nx, ny)) continue;
            seen[nl] = 1;
            q.add(ny * w + nx);
          }
        }
        final bw = x1 - x0 + 1, bh = y1 - y0 + 1;
        final size = math.max(bw, bh);
        if (size < minSize || size > maxSize) continue;
        final aspect = bw / bh;
        if (aspect < 0.6 || aspect > 1.67) continue;
        final fill = pix.length / (bw * bh);
        if (fill < 0.12 || fill > 0.72) continue;
        final cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
        final dr = w - 1 - cx, db = h - 1 - cy;
        if (dr < ref * 0.005 || db < ref * 0.005 || dr > ref * 0.09 || db > ref * 0.09) continue;
        if (!_starShaped(pix, w, x0, y0, bw, bh)) continue;
        if (!_isolated(bright, w, h, x0, y0, x1, y1, size)) continue;
        final dist = (dr - ref * 0.035).abs() + (db - ref * 0.035).abs();
        if (dist < bestDist) {
          bestDist = dist;
          best = MarkInfo(x0, y0, x1, y1, pix);
        }
      }
    }
    return best;
  }

  /// Arms along the axes, empty corners (a sparkle, not a disc or a square).
  static bool _starShaped(List<int> pix, int w, int x0, int y0, int bw, int bh) {
    final inBlob = <int>{...pix};
    var corner = 0, cornerN = 0, cross = 0, crossN = 0;
    final qx = math.max(1, (bw * 0.25).floor()), qy = math.max(1, (bh * 0.25).floor());
    final mx = x0 + bw ~/ 2, my = y0 + bh ~/ 2;
    for (int y = y0; y < y0 + bh; y++) {
      for (int x = x0; x < x0 + bw; x++) {
        final inCorner = (x < x0 + qx || x >= x0 + bw - qx) && (y < y0 + qy || y >= y0 + bh - qy);
        final on = inBlob.contains(y * w + x);
        if (inCorner) {
          cornerN++;
          if (on) corner++;
        }
        if ((x - mx).abs() <= bw ~/ 20 || (y - my).abs() <= bh ~/ 20) {
          crossN++;
          if (on) cross++;
        }
      }
    }
    return cornerN > 0 && crossN > 0 && corner <= cornerN * 0.2 && cross >= crossN * 0.5;
  }

  /// Few bright pixels in a ring around the blob (not part of a bright area).
  static bool _isolated(bool Function(int, int) bright, int w, int h, int x0, int y0, int x1, int y1, int size) {
    final m = math.max(2, (size * 0.6).round());
    var n = 0, b = 0;
    for (int y = math.max(0, y0 - m); y <= math.min(h - 1, y1 + m); y++) {
      for (int x = math.max(0, x0 - m); x <= math.min(w - 1, x1 + m); x++) {
        if (x >= x0 && x <= x1 && y >= y0 && y <= y1) continue;
        n++;
        if (bright(x, y)) b++;
      }
    }
    return n > 0 && b <= n * 0.08;
  }

  /// Inpaints the mark (blob + its soft glow) from the surrounding pixels.
  /// Only a small patch around the mark changes.
  static Rgba removeMark(Rgba im, MarkInfo m) {
    final w = im.width, h = im.height, d = im.data;
    final pad = math.max(4, m.size);
    final cx0 = math.max(0, m.x0 - pad), cy0 = math.max(0, m.y0 - pad);
    final cx1 = math.min(w - 1, m.x1 + pad), cy1 = math.min(h - 1, m.y1 + pad);
    final cw = cx1 - cx0 + 1, ch = cy1 - cy0 + 1;
    final crop = Uint8List(cw * ch * 4);
    for (int y = 0; y < ch; y++) {
      final so = ((cy0 + y) * w + cx0) * 4;
      crop.setRange(y * cw * 4, (y + 1) * cw * 4, d, so);
    }
    // Ring level → glow threshold; blob dilated by a few pixels.
    final ring = <int>[];
    for (int y = 0; y < ch; y++) {
      for (int x = 0; x < cw; x++) {
        final gx = cx0 + x, gy = cy0 + y;
        if (gx >= m.x0 - pad ~/ 2 && gx <= m.x1 + pad ~/ 2 && gy >= m.y0 - pad ~/ 2 && gy <= m.y1 + pad ~/ 2) continue;
        ring.add(_luma(crop, (y * cw + x) * 4));
      }
    }
    ring.sort();
    final ringLum = ring.isEmpty ? 0 : ring[ring.length ~/ 2];
    final hole = Uint8List(cw * ch);
    final r = math.max(2, (m.size * 0.15).round());
    for (final i in m.pixels) {
      final px = i % w - cx0, py = i ~/ w - cy0;
      for (int dy = -r; dy <= r; dy++) {
        for (int dx = -r; dx <= r; dx++) {
          final x = px + dx, y = py + dy;
          if (x < 0 || y < 0 || x >= cw || y >= ch) continue;
          hole[y * cw + x] = 1;
        }
      }
    }
    final gm = math.max(2, (m.size * 0.35).round());
    for (int y = math.max(0, m.y0 - cy0 - gm); y <= math.min(ch - 1, m.y1 - cy0 + gm); y++) {
      for (int x = math.max(0, m.x0 - cx0 - gm); x <= math.min(cw - 1, m.x1 - cx0 + gm); x++) {
        if (_luma(crop, (y * cw + x) * 4) > ringLum + 18) hole[y * cw + x] = 1;
      }
    }
    final filled = Inpaint.fill(Rgba(cw, ch, crop), hole);
    final out = Uint8List.fromList(d);
    for (int y = 0; y < ch; y++) {
      for (int x = 0; x < cw; x++) {
        if (hole[y * cw + x] == 0) continue;
        final o = ((cy0 + y) * w + cx0 + x) * 4, c = (y * cw + x) * 4;
        out[o] = filled.data[c];
        out[o + 1] = filled.data[c + 1];
        out[o + 2] = filled.data[c + 2];
      }
    }
    return Rgba(w, h, out);
  }

  /// Cheap size of an image file (header only).
  static (int, int) sizeOf(Uint8List bytes) {
    final dec = img.findDecoderForData(bytes);
    final info = dec?.startDecode(bytes);
    return info == null ? (0, 0) : (info.width, info.height);
  }

  /// Decodes [job.source], removes the mark / keys the screen as asked and
  /// writes `<outBase>.png` (transparent) or `<outBase>.jpg` when anything
  /// changed. Never touches the source. Safe to run in an isolate.
  static CleanOutcome processFile(CleanJob job) {
    final o = CleanOutcome();
    try {
      final bytes = File(job.source).readAsBytesSync();
      var im = ImageIo.toRgba(ImageIo.limit(ImageIo.decodeUpright(bytes), ImageIo.maxNormalizedSide));
      o.width = im.width;
      o.height = im.height;
      o.alpha = hasRealAlpha(im);
      final mark = detectMark(im);
      o.markFound = mark != null;
      if (mark != null && job.removeMark && !job.analyseOnly) {
        im = removeMark(im, mark);
        o.markRemoved = true;
      }
      if (job.greenScreen != 'false' && !o.alpha) {
        final s = detectScreen(im, strict: job.greenScreen != 'true');
        if (s != null) {
          o.coverage = s.coverage;
          o.keyColor = s.hex;
          if (!job.analyseOnly) {
            im = keyScreen(im, s);
            o.keyed = true;
            o.alpha = true;
          }
        }
      }
      if (o.keyed || o.markRemoved) {
        final src = job.source.toLowerCase();
        final png = o.alpha || src.endsWith('.png') || src.endsWith('.webp');
        final out = png ? '${job.outBase}.png' : '${job.outBase}.jpg';
        ImageIo.write(out, im, quality: 94);
        o.output = out;
      }
    } catch (e) {
      o.error = '$e';
    }
    return o;
  }
}
