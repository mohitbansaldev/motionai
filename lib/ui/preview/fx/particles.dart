import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../../core/engine/fx_math.dart';

/// White sprites for every particle kind, drawn once into one atlas image so
/// a whole particle system is a single [Canvas.drawRawAtlas] call.
class ParticleAtlas {
  static ui.Image? _image;

  /// Sprite rects in the atlas, indexed by [Sprite] ids.
  static final List<Rect> rects = [
    const Rect.fromLTWH(0, 0, 64, 64), // soft
    const Rect.fromLTWH(64, 0, 64, 64), // disc (bokeh)
    const Rect.fromLTWH(128, 0, 64, 64), // star
    const Rect.fromLTWH(192, 0, 64, 64), // leaf
    const Rect.fromLTWH(256, 0, 64, 64), // rect (confetti)
    const Rect.fromLTWH(0, 64, 256, 32), // streak
    const Rect.fromLTWH(320, 0, 64, 64), // bird wings up
    const Rect.fromLTWH(384, 0, 64, 64), // bird wings down
    const Rect.fromLTWH(256, 64, 192, 96), // cloud
    const Rect.fromLTWH(448, 0, 64, 64), // rain drop
  ];

  static ui.Image get image => _image ??= _build();

  static ui.Image _build() {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    const white = Color(0xFFFFFFFF);
    Offset ctr(int s) => rects[s].center;

    // soft dot
    c.drawCircle(
      ctr(Sprite.soft),
      31,
      Paint()
        ..shader = ui.Gradient.radial(ctr(Sprite.soft), 31, const [Color(0xFFFFFFFF), Color(0x88FFFFFF), Color(0x00FFFFFF)], const [0, 0.35, 1]),
    );
    // bokeh disc with a slightly brighter rim
    c.drawCircle(
      ctr(Sprite.disc),
      30,
      Paint()
        ..shader = ui.Gradient.radial(ctr(Sprite.disc), 30,
            const [Color(0xAAFFFFFF), Color(0xC0FFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)], const [0, 0.78, 0.92, 1]),
    );
    // four-point sparkle
    final sc = ctr(Sprite.star);
    final star = Path()
      ..moveTo(sc.dx, sc.dy - 30)
      ..quadraticBezierTo(sc.dx + 3, sc.dy - 3, sc.dx + 30, sc.dy)
      ..quadraticBezierTo(sc.dx + 3, sc.dy + 3, sc.dx, sc.dy + 30)
      ..quadraticBezierTo(sc.dx - 3, sc.dy + 3, sc.dx - 30, sc.dy)
      ..quadraticBezierTo(sc.dx - 3, sc.dy - 3, sc.dx, sc.dy - 30)
      ..close();
    c.drawPath(star, Paint()..color = white);
    c.drawCircle(sc, 9, Paint()..shader = ui.Gradient.radial(sc, 9, const [Color(0xFFFFFFFF), Color(0x00FFFFFF)]));
    // leaf
    final lc = ctr(Sprite.leaf);
    final leaf = Path()
      ..moveTo(lc.dx - 28, lc.dy)
      ..quadraticBezierTo(lc.dx, lc.dy - 22, lc.dx + 28, lc.dy)
      ..quadraticBezierTo(lc.dx, lc.dy + 22, lc.dx - 28, lc.dy)
      ..close();
    c.drawPath(leaf, Paint()..color = white);
    c.drawLine(Offset(lc.dx - 26, lc.dy), Offset(lc.dx + 24, lc.dy),
        Paint()
          ..color = const Color(0x66000000)
          ..strokeWidth = 2
          ..blendMode = BlendMode.dstOut);
    // confetti rectangle
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: ctr(Sprite.rect), width: 44, height: 26), const Radius.circular(3)),
        Paint()..color = white);
    // light streak: bright head on the right, long fading tail
    final st = rects[Sprite.streak];
    c.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(st.left + 4, st.center.dy - 5, st.width - 8, 10), const Radius.circular(5)),
      Paint()
        ..shader = ui.Gradient.linear(Offset(st.left, 0), Offset(st.right, 0),
            const [Color(0x00FFFFFF), Color(0x66FFFFFF), Color(0xFFFFFFFF)], const [0, 0.7, 1])
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    c.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(st.left + st.width * 0.55, st.center.dy - 1.5, st.width * 0.43, 3), const Radius.circular(2)),
      Paint()
        ..shader = ui.Gradient.linear(Offset(st.left + st.width * 0.55, 0), Offset(st.right, 0),
            const [Color(0x00FFFFFF), Color(0xFFFFFFFF)]),
    );
    // birds
    final wing = Paint()
      ..color = white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final bu = ctr(Sprite.birdUp);
    c.drawPath(
        Path()
          ..moveTo(bu.dx - 26, bu.dy - 12)
          ..quadraticBezierTo(bu.dx - 12, bu.dy - 10, bu.dx, bu.dy + 4)
          ..quadraticBezierTo(bu.dx + 12, bu.dy - 10, bu.dx + 26, bu.dy - 12),
        wing);
    final bd = ctr(Sprite.birdDown);
    c.drawPath(
        Path()
          ..moveTo(bd.dx - 24, bd.dy + 10)
          ..quadraticBezierTo(bd.dx - 12, bd.dy - 6, bd.dx, bd.dy)
          ..quadraticBezierTo(bd.dx + 12, bd.dy - 6, bd.dx + 24, bd.dy + 10),
        wing);
    // cloud: overlapping soft puffs
    final cl = rects[Sprite.cloud];
    final puff = Paint();
    for (final p in const [
      [0.30, 0.62, 0.22],
      [0.50, 0.50, 0.30],
      [0.70, 0.60, 0.24],
      [0.42, 0.68, 0.22],
      [0.60, 0.70, 0.22],
      [0.20, 0.70, 0.15],
      [0.82, 0.70, 0.14],
    ]) {
      final o = Offset(cl.left + cl.width * p[0], cl.top + cl.height * p[1]);
      final r = cl.width * p[2] * 0.75;
      puff.shader = ui.Gradient.radial(o, r, const [Color(0xEEFFFFFF), Color(0x99FFFFFF), Color(0x00FFFFFF)], const [0, 0.55, 1]);
      c.drawCircle(o, r, puff);
    }
    // rain drop: thin vertical streak, bright at the bottom
    final dr = rects[Sprite.drop];
    c.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(dr.center.dx - 1.5, dr.top + 2, 3, dr.height - 4), const Radius.circular(1.5)),
      Paint()
        ..shader = ui.Gradient.linear(Offset(0, dr.top), Offset(0, dr.bottom), const [Color(0x00FFFFFF), Color(0xFFFFFFFF)]),
    );
    final pic = rec.endRecording();
    final img = pic.toImageSync(512, 160);
    pic.dispose();
    return img;
  }
}

/// The `particles` effect: deterministic from time (export == preview).
class ParticlesPainter extends CustomPainter {
  final int kind;
  final double amount, speed, direction, time;
  final int color;
  final int seed;

  ParticlesPainter({
    required this.kind,
    required this.amount,
    required this.speed,
    required this.direction,
    required this.time,
    required this.color,
    required this.seed,
  });

  // Reused buffers (grown on demand) so painting allocates almost nothing.
  static Float64List _sim = Float64List(0);
  static Float32List _rst = Float32List(0);
  static Float32List _rects = Float32List(0);
  static Int32List _colors = Int32List(0);
  static final Paint _paint = Paint()..filterQuality = FilterQuality.low;

  static void _grow(int n) {
    if (_colors.length >= n) return;
    final cap = math.max(n, 64);
    _sim = Float64List(cap * kParticleStride);
    _rst = Float32List(cap * 4);
    _rects = Float32List(cap * 4);
    _colors = Int32List(cap);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final n = ParticleSim.countFor(kind, amount);
    if (n <= 0 || size.isEmpty) return;
    _grow(n);
    final count = ParticleSim.simulate(
      kind: kind,
      count: n,
      t: time,
      w: size.width,
      h: size.height,
      out: _sim,
      speed: speed,
      direction: direction,
      color: color,
      seed: seed,
    );
    final rects = ParticleAtlas.rects;
    for (int i = 0; i < count; i++) {
      final o = i * kParticleStride;
      final sprite = _sim[o + 5].toInt().clamp(0, rects.length - 1);
      final r = rects[sprite];
      final scale = _sim[o + 2] / math.max(r.width, r.height);
      final rot = _sim[o + 3];
      final scos = math.cos(rot) * scale, ssin = math.sin(rot) * scale;
      final ax = r.width / 2, ay = r.height / 2;
      final j = i * 4;
      _rst[j] = scos;
      _rst[j + 1] = ssin;
      _rst[j + 2] = _sim[o] - scos * ax + ssin * ay;
      _rst[j + 3] = _sim[o + 1] - ssin * ax - scos * ay;
      _rects[j] = r.left;
      _rects[j + 1] = r.top;
      _rects[j + 2] = r.right;
      _rects[j + 3] = r.bottom;
      final a = (_sim[o + 4] * ((_sim[o + 6].toInt() >> 24) & 0xFF)).round().clamp(0, 255);
      _colors[i] = (a << 24) | (_sim[o + 6].toInt() & 0x00FFFFFF);
    }
    final light = kind == PKind.stars || kind == PKind.bokeh || kind == PKind.streaks || kind == PKind.dust || kind == PKind.ice; // V3-D: ice glints
    _paint.blendMode = light ? BlendMode.plus : BlendMode.srcOver;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawRawAtlas(
      ParticleAtlas.image,
      Float32List.sublistView(_rst, 0, count * 4),
      Float32List.sublistView(_rects, 0, count * 4),
      Int32List.sublistView(_colors, 0, count),
      BlendMode.modulate,
      null,
      _paint,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ParticlesPainter o) =>
      o.time != time || o.kind != kind || o.amount != amount || o.speed != speed || o.direction != direction || o.color != color || o.seed != seed;
}
