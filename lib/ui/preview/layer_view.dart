import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Easing;
import 'package:video_player/video_player.dart';

import '../../core/engine/evaluator.dart';
import '../../core/model/easing.dart';
import '../../core/model/layer.dart';
import '../../core/model/project.dart';
import '../../state/video_pool.dart';

/// Draws one evaluated layer: content → effects → masks → depth blur → opacity → transform.
///
/// During export, [videoFrames] supplies exact decoded frames for video
/// layers instead of the live players.
class LayerView extends StatelessWidget {
  final RenderItem item;
  final Project project;
  final VideoPool? videos;
  final double time;
  final Map<String, ui.Image>? videoFrames;

  const LayerView({
    super.key,
    required this.item,
    required this.project,
    required this.videos,
    required this.time,
    this.videoFrames,
  });

  @override
  Widget build(BuildContext context) {
    final l = item.layer;
    Widget child = SizedBox(width: l.width, height: l.height, child: _content(l));
    for (final e in l.effects) {
      if (e.enabled) child = _effect(e, child, l);
    }
    for (final m in l.masks) {
      child = _mask(m, child);
    }
    if (item.dofBlur > 0.3) {
      final s = math.min(item.dofBlur, 40.0);
      child = ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: s, sigmaY: s, tileMode: TileMode.decal), child: child);
    }
    if (item.opacity < 0.999) child = Opacity(opacity: item.opacity, child: child);
    return Positioned(left: 0, top: 0, child: Transform(transform: item.matrix, child: child));
  }

  Widget _content(Layer l) {
    switch (l.type) {
      case LayerType.video:
        final frame = videoFrames?[l.id];
        if (frame != null) return RawImage(image: frame, fit: BoxFit.fill, width: l.width, height: l.height);
        final VideoPlayerController? c = videos?.controllerFor(l.id);
        if (c == null) return const ColoredBox(color: Color(0xFF15181D));
        return VideoPlayer(c);
      case LayerType.image:
        final asset = project.media[l.mediaId];
        if (asset == null) return const ColoredBox(color: Color(0xFF3A1010));
        return Image.file(
          File(asset.path),
          width: l.width,
          height: l.height,
          fit: BoxFit.fill,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          cacheWidth: math.min(l.width.round(), 2560),
          errorBuilder: (_, e, _) => ColoredBox(
            color: const Color(0xFF3A1010),
            child: Center(
              child: Text('Image could not be shown\n$e',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: l.height * 0.04)),
            ),
          ),
        );
      case LayerType.text:
        return _text(l, l.text ?? TextData());
      case LayerType.solid:
        return ColoredBox(color: Color(l.color));
      case LayerType.nullObject:
      case LayerType.audio:
        return const SizedBox.shrink();
    }
  }

  // ------------------------------------------------------------------ text

  Widget _text(Layer l, TextData t) {
    final weightIndex = ((t.fontWeight ~/ 100) - 1).clamp(0, FontWeight.values.length - 1);
    final style = TextStyle(
      fontSize: t.fontSize,
      color: Color(t.color),
      fontWeight: FontWeight.values[weightIndex],
      fontFamily: t.fontFamily,
      height: 1.15,
      decoration: TextDecoration.none,
      shadows: t.shadow
          ? [Shadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: t.fontSize * 0.12, offset: Offset(0, t.fontSize * 0.04))]
          : null,
    );
    final align = switch (t.align) { 'left' => TextAlign.left, 'right' => TextAlign.right, _ => TextAlign.center };
    final wrapAlign = switch (t.align) {
      'left' => WrapAlignment.start,
      'right' => WrapAlignment.end,
      _ => WrapAlignment.center,
    };
    final local = time - l.start;
    final p = t.animDuration <= 0 ? 1.0 : (local / t.animDuration).clamp(0.0, 1.0);

    Widget content;
    switch (t.animator) {
      case 'typewriter':
        final n = (t.text.length * p).round();
        content = Text.rich(
          TextSpan(children: [
            TextSpan(text: t.text.substring(0, n)),
            TextSpan(text: t.text.substring(n), style: const TextStyle(color: Colors.transparent, shadows: [])),
          ]),
          textAlign: align,
          style: style,
        );
        break;
      case 'slide_up':
        final e = Easing.easeOut.transform(p);
        content = ClipRect(
          child: Transform.translate(
            offset: Offset(0, (1 - e) * t.fontSize * 1.3),
            child: Opacity(opacity: e, child: Text(t.text, textAlign: align, style: style)),
          ),
        );
        break;
      case 'word_pop':
      case 'fade_up':
      case 'karaoke':
        content = _words(l, t, style, wrapAlign, local);
        break;
      default:
        content = Text(t.text, textAlign: align, style: style);
    }

    if (t.boxColor != 0) {
      content = Container(
        padding: EdgeInsets.symmetric(horizontal: t.fontSize * 0.35, vertical: t.fontSize * 0.12),
        decoration: BoxDecoration(color: Color(t.boxColor), borderRadius: BorderRadius.circular(t.fontSize * 0.2)),
        child: content,
      );
    }
    return Align(
      alignment: switch (t.align) { 'left' => Alignment.centerLeft, 'right' => Alignment.centerRight, _ => Alignment.center },
      child: content,
    );
  }

  Widget _words(Layer l, TextData t, TextStyle style, WrapAlignment wrapAlign, double local) {
    final timed = t.words.isNotEmpty;
    final words = timed ? t.words.map((w) => w.word).toList() : t.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final n = words.length;
    final children = <Widget>[];
    for (int i = 0; i < n; i++) {
      Widget w = Text('${words[i]} ', style: style);
      switch (t.animator) {
        case 'word_pop':
        case 'fade_up':
          final delay = n <= 1 ? 0.0 : i * (t.animDuration * 0.6) / (n - 1);
          final span = math.max(0.05, t.animDuration * 0.4);
          final q = ((local - delay) / span).clamp(0.0, 1.0);
          if (t.animator == 'word_pop') {
            w = Opacity(
              opacity: q,
              child: Transform.scale(scale: math.max(0.0, Easing.back.transform(q)), child: w),
            );
          } else {
            w = Opacity(
              opacity: q,
              child: Transform.translate(offset: Offset(0, (1 - Easing.easeOut.transform(q)) * t.fontSize * 0.5), child: w),
            );
          }
          break;
        case 'karaoke':
          bool active;
          bool spoken;
          if (timed) {
            final wt = t.words[i];
            active = time >= wt.start && time < wt.end;
            spoken = time >= wt.start;
          } else {
            final idx = l.duration <= 0 ? 0 : (local / l.duration * n).floor();
            active = idx == i;
            spoken = i <= idx;
          }
          w = Transform.scale(
            scale: active ? 1.08 : 1.0,
            child: Text(
              '${words[i]} ',
              style: style.copyWith(
                color: active ? Color(t.highlightColor) : (spoken ? Color(t.color) : Color(t.color).withValues(alpha: 0.75)),
              ),
            ),
          );
          break;
      }
      children.add(w);
    }
    return Wrap(alignment: wrapAlign, crossAxisAlignment: WrapCrossAlignment.center, children: children);
  }

  // --------------------------------------------------------------- effects

  Widget _effect(Effect e, Widget child, Layer l) {
    double p(String k, [int i = 0]) {
      final ap = e.params[k];
      return ap == null ? 0 : ap.valueAt(time)[i];
    }

    Widget overlay(Widget o) => Stack(children: [child, Positioned.fill(child: IgnorePointer(child: o))]);

    switch (e.type) {
      case 'blur':
        final a = p('amount') * 0.5;
        if (a <= 0.05) return child;
        return ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: a, sigmaY: a, tileMode: TileMode.decal), child: child);
      case 'color':
        return ColorFiltered(
          colorFilter: ColorFilter.matrix(colorAdjustMatrix(p('brightness'), p('contrast'), p('saturation'))),
          child: child,
        );
      case 'tint':
        return ColorFiltered(
          colorFilter: ColorFilter.matrix(tintMatrix(p('color', 0), p('color', 1), p('color', 2), p('amount') / 100)),
          child: child,
        );
      case 'vignette':
        final amount = (p('amount') / 100).clamp(0.0, 1.0);
        final size = (p('size') / 100).clamp(0.05, 1.0);
        return overlay(DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              radius: 0.75,
              colors: [Colors.transparent, Colors.black.withValues(alpha: amount)],
              stops: [size * 0.95, 1.0],
            ),
          ),
        ));
      case 'glow':
        final amount = (p('amount') / 100).clamp(0.0, 1.0);
        final r = p('radius').clamp(1.0, 100.0);
        if (amount <= 0) return child;
        return Stack(children: [
          child,
          IgnorePointer(
            child: Opacity(
              opacity: amount * 0.85,
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: r, sigmaY: r, tileMode: TileMode.decal),
                child: ColorFiltered(colorFilter: ColorFilter.matrix(colorAdjustMatrix(25, 20, 10)), child: child),
              ),
            ),
          ),
        ]);
      case 'grain':
        final amount = (p('amount') / 100).clamp(0.0, 1.0);
        if (amount <= 0) return child;
        return overlay(CustomPaint(painter: _GrainPainter((time * 24).floor(), amount, p('size').clamp(1.0, 8.0))));
      case 'light_leak':
        final amount = (p('amount') / 100).clamp(0.0, 1.0);
        final sp = p('speed');
        return overlay(Opacity(
          opacity: amount,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(math.sin(time * sp * 0.7) * 0.9, math.cos(time * sp * 0.5) * 0.6 - 0.3),
                radius: 1.1,
                colors: const [Color(0xCCFF8A3D), Color(0x66FF2E63), Color(0x00FF2E63)],
                stops: const [0, 0.45, 1],
              ),
            ),
          ),
        ));
      case 'gradient':
        final bottom = (p('amount') / 100).clamp(0.0, 1.0);
        final top = (p('top') / 100).clamp(0.0, 1.0);
        return overlay(DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: top),
                Colors.transparent,
                Colors.transparent,
                Colors.black.withValues(alpha: bottom),
              ],
              stops: const [0, 0.35, 0.55, 1],
            ),
          ),
        ));
      case 'letterbox':
        final bar = (p('amount') / 100).clamp(0.0, 0.45) * l.height;
        if (bar <= 0) return child;
        return Stack(children: [
          child,
          Positioned(left: 0, right: 0, top: 0, height: bar, child: const ColoredBox(color: Colors.black)),
          Positioned(left: 0, right: 0, bottom: 0, height: bar, child: const ColoredBox(color: Colors.black)),
        ]);
      default:
        return child;
    }
  }

  // ----------------------------------------------------------------- masks

  Widget _mask(Mask m, Widget child) {
    List<double> v(String k, List<double> d) => m.props[k]?.valueAt(time) ?? d;
    final c = v('center', [0, 0]);
    final s = v('size', [100, 100]);
    final f = math.max(0.0, v('feather', [0])[0]);
    final rx = math.max(1.0, s[0] / 2), ry = math.max(1.0, s[1] / 2);

    if (m.shape == 'ellipse') {
      final inner = (1 - f / math.min(rx, ry)).clamp(0.0, 0.999);
      final matrix = Float64List.fromList([rx, 0, 0, 0, 0, ry, 0, 0, 0, 0, 1, 0, c[0], c[1], 0, 1]);
      final colors = m.invert ? const [Color(0x00FFFFFF), Color(0xFFFFFFFF)] : const [Color(0xFFFFFFFF), Color(0x00FFFFFF)];
      return ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (_) => ui.Gradient.radial(Offset.zero, 1, colors, [inner, 1.0], TileMode.clamp, matrix),
        child: child,
      );
    }

    final rect = Rect.fromCenter(center: Offset(c[0], c[1]), width: s[0], height: s[1]);
    if (m.invert) {
      return ClipPath(
        clipper: _InvertRectClipper(rect),
        child: child,
      );
    }
    ui.Gradient ramp(Offset a, Offset b, double len) {
      final e = len <= 0 ? 0.0 : (f / len).clamp(0.0, 0.5);
      return ui.Gradient.linear(
        a,
        b,
        const [Color(0x00FFFFFF), Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
        [0, e, 1 - e, 1],
      );
    }

    final w = rect.width + f, h = rect.height + f;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (_) => ramp(Offset(rect.left - f / 2, 0), Offset(rect.right + f / 2, 0), w),
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (_) => ramp(Offset(0, rect.top - f / 2), Offset(0, rect.bottom + f / 2), h),
        child: child,
      ),
    );
  }
}

class _InvertRectClipper extends CustomClipper<Path> {
  final Rect hole;
  _InvertRectClipper(this.hole);
  @override
  Path getClip(Size size) => Path()
    ..fillType = PathFillType.evenOdd
    ..addRect(Offset.zero & size)
    ..addRect(hole);
  @override
  bool shouldReclip(covariant _InvertRectClipper old) => old.hole != hole;
}

class _GrainPainter extends CustomPainter {
  final int seed;
  final double amount;
  final double dot;
  _GrainPainter(this.seed, this.amount, this.dot);

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = math.Random(seed);
    final count = (size.width * size.height / (dot * dot * 40)).clamp(500, 20000).toInt();
    final light = <Offset>[], dark = <Offset>[];
    for (int i = 0; i < count; i++) {
      final o = Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
      (i.isEven ? light : dark).add(o);
    }
    final pl = Paint()
      ..color = Colors.white.withValues(alpha: 0.35 * amount)
      ..strokeWidth = dot
      ..strokeCap = StrokeCap.square;
    final pd = Paint()
      ..color = Colors.black.withValues(alpha: 0.45 * amount)
      ..strokeWidth = dot
      ..strokeCap = StrokeCap.square;
    canvas.drawPoints(ui.PointMode.points, light, pl);
    canvas.drawPoints(ui.PointMode.points, dark, pd);
  }

  @override
  bool shouldRepaint(covariant _GrainPainter old) => old.seed != seed || old.amount != amount || old.dot != dot;
}

const _lr = 0.2126, _lg = 0.7152, _lb = 0.0722;

/// brightness/contrast/saturation in -100..100 → Flutter 5x4 color matrix.
List<double> colorAdjustMatrix(double brightness, double contrast, double saturation) {
  final s = (saturation + 100) / 100;
  final c = (contrast + 100) / 100;
  final off = 128 * (1 - c) + brightness * 1.28;
  final sr = _lr * (1 - s), sg = _lg * (1 - s), sb = _lb * (1 - s);
  return [
    c * (sr + s), c * sg, c * sb, 0, off,
    c * sr, c * (sg + s), c * sb, 0, off,
    c * sr, c * sg, c * (sb + s), 0, off,
    0, 0, 0, 1, 0,
  ];
}

/// Blends toward luminance × tint color by [amount] (0..1).
List<double> tintMatrix(double r, double g, double b, double amount) {
  final a = amount.clamp(0.0, 1.0);
  final tr = r / 255, tg = g / 255, tb = b / 255;
  return [
    (1 - a) + a * tr * _lr, a * tr * _lg, a * tr * _lb, 0, 0,
    a * tg * _lr, (1 - a) + a * tg * _lg, a * tg * _lb, 0, 0,
    a * tb * _lr, a * tb * _lg, (1 - a) + a * tb * _lb, 0, 0,
    0, 0, 0, 1, 0,
  ];
}
