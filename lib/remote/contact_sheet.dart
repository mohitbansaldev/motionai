// V2-A (Bridge): preview_shot's contact sheet and animated GIF, built in
// pure Dart (package:image) from rendered frames, so it is unit-tested
// without a GPU and runs in a background isolate.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// One rendered frame: [rgba] is width × height × 4 bytes (alpha may be
/// premultiplied; the sheet treats every pixel as opaque).
class RawFrame {
  final int width, height;
  final Uint8List rgba;
  RawFrame(this.width, this.height, this.rgba) {
    if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
      throw ArgumentError('RawFrame: ${rgba.length} bytes for ${width}x$height');
    }
  }

  /// Decodes a PNG (or any format package:image reads).
  static RawFrame fromPng(Uint8List bytes) {
    final im = img.decodeImage(bytes);
    if (im == null) throw const FormatException('Rendered frame is not a readable image');
    final rgba = im.convert(format: img.Format.uint8, numChannels: 4).getBytes(order: img.ChannelOrder.rgba);
    return RawFrame(im.width, im.height, rgba);
  }

  img.Image toImage() {
    final copy = Uint8List.fromList(rgba.sublist(0, width * height * 4));
    return img.Image.fromBytes(width: width, height: height, bytes: copy.buffer, numChannels: 4, order: img.ChannelOrder.rgba);
  }
}

/// A frame and the composition time it shows.
class SheetTile {
  final double time;
  final RawFrame frame;
  SheetTile(this.time, this.frame);
}

class ContactSheet {
  static const int gap = 6;

  /// Columns for [n] tiles: 1-3 in a row, 4 = 2×2, 5-6 = 3×2, 9 = 3×3, else 4 wide.
  static int columnsFor(int n) {
    if (n <= 3) return math.max(1, n);
    if (n == 4) return 2;
    if (n <= 6 || n == 9) return 3;
    return 4;
  }

  /// "1.25 s"
  static String label(double t) => '${t.toStringAsFixed(2)} s';

  /// The tile [f] scaled to [w] × [h], opaque.
  static img.Image _tile(RawFrame f, int w, int h) {
    var im = f.toImage();
    if (im.width != w || im.height != h) {
      im = img.copyResize(im, width: w, height: h, interpolation: img.Interpolation.average);
    }
    final out = img.Image(width: w, height: h);
    img.compositeImage(out, im, blend: img.BlendMode.direct);
    return out;
  }

  /// Grid PNG of [tiles], each [tileWidth] wide (height from the first
  /// frame's aspect), labelled "#n  t s" in its top-left corner.
  static Uint8List png(List<SheetTile> tiles, {int tileWidth = 480, int? columns}) {
    if (tiles.isEmpty) throw ArgumentError('No frames');
    final first = tiles.first.frame;
    final tw = tileWidth.clamp(16, 4096);
    final th = math.max(16, (tw * first.height / first.width).round());
    final cols = (columns ?? columnsFor(tiles.length)).clamp(1, tiles.length);
    final rows = (tiles.length / cols).ceil();
    final sheet = img.Image(width: cols * tw + (cols + 1) * gap, height: rows * th + (rows + 1) * gap);
    img.fill(sheet, color: img.ColorRgb8(18, 18, 22));
    final font = tw >= 360 ? img.arial24 : img.arial14;
    final lh = tw >= 360 ? 30 : 19;
    for (var i = 0; i < tiles.length; i++) {
      final x = gap + (i % cols) * (tw + gap), y = gap + (i ~/ cols) * (th + gap);
      img.compositeImage(sheet, _tile(tiles[i].frame, tw, th), dstX: x, dstY: y, blend: img.BlendMode.direct);
      final text = '#${i + 1}  ${label(tiles[i].time)}';
      final lw = text.length * (tw >= 360 ? 13 : 8) + 12;
      img.fillRect(sheet, x1: x, y1: y, x2: x + math.min(lw, tw - 1), y2: y + lh, color: img.ColorRgba8(0, 0, 0, 175));
      img.drawString(sheet, text, font: font, x: x + 6, y: y + 3, color: img.ColorRgb8(255, 255, 255));
    }
    return img.encodePng(sheet, level: 4);
  }

  /// win-30: one frame as a PNG (render_frame on another comp).
  static Uint8List encodeFrame(RawFrame f) => img.encodePng(f.toImage(), level: 4);

  /// GIF frame delay in 1/100 s: real time between samples, but the whole
  /// loop at most 2 s and at least 4 cs per frame.
  static int gifDelay(double span, int frames) {
    if (frames <= 1) return 100;
    final real = (span / (frames - 1) * 100).round();
    final cap = math.max(4, 200 ~/ frames);
    return real.clamp(4, cap);
  }

  /// Animated GIF of [tiles] at [width] px (≤ 480), looping.
  static Uint8List gif(List<SheetTile> tiles, {int width = 360, required int delay}) {
    if (tiles.isEmpty) throw ArgumentError('No frames');
    final first = tiles.first.frame;
    final w = width.clamp(16, 480);
    final h = math.max(16, (w * first.height / first.width).round());
    final enc = img.GifEncoder(delay: delay, repeat: 0, numColors: 256, samplingFactor: 20);
    for (final t in tiles) {
      final f = _tile(t.frame, w, h);
      img.drawString(f, label(t.time), font: img.arial14, x: 5, y: 4, color: img.ColorRgb8(255, 255, 255));
      enc.addFrame(f, duration: delay);
    }
    final out = enc.finish();
    if (out == null) throw StateError('GIF encoding failed');
    return out;
  }
}
