// Pure-Dart image decode/encode helpers for the Windows AI layer (Agent E).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// An 8-bit RGBA bitmap (row-major, 4 bytes per pixel).
class Rgba {
  final int width, height;
  final Uint8List data;
  Rgba(this.width, this.height, this.data) : assert(data.length == width * height * 4);
  factory Rgba.blank(int w, int h) => Rgba(w, h, Uint8List(w * h * 4));
}

class ImageIo {
  /// Longest side written by [normalize] (same as the phone).
  static const maxNormalizedSide = 4096;

  /// Decodes jpg/png/webp/bmp/gif/tiff/… (first frame) with EXIF rotation
  /// applied; throws [FormatException] for formats it can't read.
  static img.Image decodeUpright(Uint8List bytes) {
    final im = img.decodeImage(bytes);
    if (im == null) throw const FormatException('This image format can\'t be read');
    return img.bakeOrientation(im);
  }

  static img.Image readUpright(String path) => decodeUpright(File(path).readAsBytesSync());

  /// Scales [im] down so its longest side is at most [maxSide].
  static img.Image limit(img.Image im, int maxSide) {
    final long = math.max(im.width, im.height);
    if (long <= maxSide) return im;
    final k = maxSide / long;
    return img.copyResize(im,
        width: math.max(1, (im.width * k).round()),
        height: math.max(1, (im.height * k).round()),
        interpolation: img.Interpolation.average);
  }

  static img.Image resize(img.Image im, int w, int h) =>
      img.copyResize(im, width: w, height: h, interpolation: img.Interpolation.linear);

  /// 8-bit RGBA copy of any decoded image (palette, 16-bit, gray, …).
  static Rgba toRgba(img.Image im) {
    final c = (im.format == img.Format.uint8 && im.numChannels == 4 && !im.hasPalette)
        ? im
        : im.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
    return Rgba(c.width, c.height, Uint8List.fromList(c.getBytes(order: img.ChannelOrder.rgba)));
  }

  static img.Image fromRgba(Rgba p) =>
      img.Image.fromBytes(width: p.width, height: p.height, bytes: p.data.buffer, numChannels: 4, order: img.ChannelOrder.rgba);

  static bool isPng(String path) => path.toLowerCase().endsWith('.png');

  /// Blends transparent pixels over [bg] (JPEG has no alpha).
  static Rgba flatten(Rgba p, {int bg = 255}) {
    final d = Uint8List.fromList(p.data);
    for (var i = 0; i < d.length; i += 4) {
      final a = d[i + 3];
      if (a == 255) continue;
      for (var c = 0; c < 3; c++) {
        d[i + c] = (d[i + c] * a + bg * (255 - a) + 127) ~/ 255;
      }
      d[i + 3] = 255;
    }
    return Rgba(p.width, p.height, d);
  }

  /// Encodes as PNG when [path] ends in .png, otherwise JPEG.
  static Uint8List encodeFor(String path, Rgba p, {int quality = 92}) =>
      isPng(path) ? img.encodePng(fromRgba(p), level: 4) : img.encodeJpg(fromRgba(flatten(p)), quality: quality);

  static void writePng(String path, Rgba p) => File(path).writeAsBytesSync(img.encodePng(fromRgba(p), level: 4));

  static void write(String path, Rgba p, {int quality = 92}) => File(path).writeAsBytesSync(encodeFor(path, p, quality: quality));

  /// Upright, size-limited copy of [bytes] encoded for [outPath]'s format.
  /// Returns (encoded, width, height).
  static (Uint8List, int, int) normalizeBytes(Uint8List bytes, String outPath) {
    final im = limit(decodeUpright(bytes), maxNormalizedSide);
    final p = toRgba(im);
    return (encodeFor(outPath, p), p.width, p.height);
  }

  /// File version of [normalizeBytes].
  static (int, int) normalizeFile(String inPath, String outPath) {
    final (data, w, h) = normalizeBytes(File(inPath).readAsBytesSync(), outPath);
    File(outPath).writeAsBytesSync(data);
    return (w, h);
  }
}
