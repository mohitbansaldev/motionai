import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/engine/evaluator.dart';
import '../../core/model/layer.dart';
import '../../core/model/project.dart';
import '../../state/video_pool.dart';

/// Draws one evaluated layer: content → effects → depth blur → opacity → transform.
class LayerView extends StatelessWidget {
  final RenderItem item;
  final Project project;
  final VideoPool videos;
  final double time;

  const LayerView({super.key, required this.item, required this.project, required this.videos, required this.time});

  @override
  Widget build(BuildContext context) {
    final l = item.layer;
    Widget child = SizedBox(width: l.width, height: l.height, child: _content(l));
    for (final e in l.effects) {
      if (e.enabled) child = _effect(e, child);
    }
    if (item.dofBlur > 0.3) {
      final s = math.min(item.dofBlur, 40.0);
      child = ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: s, sigmaY: s, tileMode: TileMode.decal), child: child);
    }
    if (item.opacity < 0.999) child = Opacity(opacity: item.opacity, child: child);
    return Positioned(
      left: 0,
      top: 0,
      child: Transform(transform: item.matrix, child: child),
    );
  }

  Widget _content(Layer l) {
    switch (l.type) {
      case LayerType.video:
        final VideoPlayerController? c = videos.controllerFor(l.id);
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
        );
      case LayerType.text:
        final t = l.text ?? TextData();
        final weightIndex = ((t.fontWeight ~/ 100) - 1).clamp(0, FontWeight.values.length - 1);
        return Align(
          alignment: switch (t.align) {
            'left' => Alignment.centerLeft,
            'right' => Alignment.centerRight,
            _ => Alignment.center,
          },
          child: Text(
            t.text,
            textAlign: switch (t.align) {
              'left' => TextAlign.left,
              'right' => TextAlign.right,
              _ => TextAlign.center,
            },
            style: TextStyle(
              fontSize: t.fontSize,
              color: Color(t.color),
              fontWeight: FontWeight.values[weightIndex],
              fontFamily: t.fontFamily,
              height: 1.1,
              decoration: TextDecoration.none,
            ),
          ),
        );
      case LayerType.solid:
        return ColoredBox(color: Color(l.color));
      case LayerType.nullObject:
        return const SizedBox.shrink();
    }
  }

  Widget _effect(Effect e, Widget child) {
    double p(String k, [int i = 0]) {
      final ap = e.params[k];
      return ap == null ? 0 : ap.valueAt(time)[i];
    }

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
        return Stack(fit: StackFit.passthrough, children: [
          child,
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 0.75,
                    colors: [Colors.transparent, Colors.black.withValues(alpha: amount)],
                    stops: [size * 0.95, 1.0],
                  ),
                ),
              ),
            ),
          ),
        ]);
      default:
        return child;
    }
  }
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
