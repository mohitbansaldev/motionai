import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../../core/engine/fx_math.dart';
import 'offscreen.dart';

/// V3-C: layer blend modes. `update_layer {blend}` names → canvas blend modes.
class LayerBlend {
  LayerBlend._();

  static const modes = <String, BlendMode>{
    'multiply': BlendMode.multiply,
    'screen': BlendMode.screen,
    'overlay': BlendMode.overlay,
    'add': BlendMode.plus,
    'darken': BlendMode.darken,
    'lighten': BlendMode.lighten,
    'color_dodge': BlendMode.colorDodge,
    'soft_light': BlendMode.softLight,
    'hard_light': BlendMode.hardLight,
    'difference': BlendMode.difference,
  };

  static BlendMode? of(String name) => modes[name];
}

/// Draws [top] over [below] with a real blend mode (screen / add / multiply /
/// lighten …): both are rendered to images (comp size × [resolution]) and
/// composited on one canvas, so the blend sees every pixel under the layer.
/// Falls back to a plain stack when a live video texture is involved (its
/// pixels cannot be snapshotted); export uses decoded frames, so it blends.
class BlendComposite extends MultiChildRenderObjectWidget {
  final BlendMode mode;
  final double resolution;

  BlendComposite({super.key, required this.mode, required Widget below, required Widget top, this.resolution = 1})
      : super(children: [below, top]);

  @override
  RenderBlendComposite createRenderObject(BuildContext context) => RenderBlendComposite(mode, resolution);

  @override
  void updateRenderObject(BuildContext context, RenderBlendComposite renderObject) {
    renderObject
      ..mode = mode
      ..resolution = resolution;
  }
}

class _BlendData extends ContainerBoxParentData<RenderBox> {}

class RenderBlendComposite extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _BlendData>, RenderBoxContainerDefaultsMixin<RenderBox, _BlendData> {
  RenderBlendComposite(this._mode, this._resolution);

  BlendMode _mode;
  set mode(BlendMode v) {
    if (v == _mode) return;
    _mode = v;
    markNeedsPaint();
  }

  double _resolution;
  set resolution(double v) {
    if (v == _resolution) return;
    _resolution = v;
    markNeedsPaint();
  }

  final LayerHandle<OffsetLayer> _holderBelow = LayerHandle<OffsetLayer>(OffsetLayer());
  final LayerHandle<OffsetLayer> _holderTop = LayerHandle<OffsetLayer>(OffsetLayer());
  ui.Image? _below, _top;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _BlendData) child.parentData = _BlendData();
  }

  @override
  void performLayout() {
    final s = constraints.biggest.isFinite ? constraints.biggest : constraints.smallest;
    size = s;
    var child = firstChild;
    while (child != null) {
      child.layout(BoxConstraints.tight(s));
      child = childAfter(child);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => defaultHitTestChildren(result, position: position);

  @override
  void dispose() {
    _below?.dispose();
    _top?.dispose();
    _below = null;
    _top = null;
    _holderBelow.layer = null;
    _holderTop.layer = null;
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final below = firstChild;
    final top = below == null ? null : childAfter(below);
    if (below == null || top == null) {
      defaultPaint(context, offset);
      return;
    }
    if (texturesIn(below).isNotEmpty || texturesIn(top).isNotEmpty) {
      defaultPaint(context, offset);
      return;
    }
    final ratio = _resolution.clamp(0.05, 2.0).toDouble();
    final b = paintChildToImage(_holderBelow.layer!, below, size, ratio);
    final t = paintChildToImage(_holderTop.layer!, top, size, ratio);
    if (b == null || t == null) {
      b?.dispose();
      t?.dispose();
      defaultPaint(context, offset);
      return;
    }
    _below?.dispose();
    _top?.dispose();
    _below = b;
    _top = t;
    final dst = offset & size;
    final canvas = context.canvas;
    final q = ratio >= 0.99 ? FilterQuality.none : FilterQuality.low;
    canvas.drawImageRect(b, Rect.fromLTWH(0, 0, b.width.toDouble(), b.height.toDouble()), dst, Paint()..filterQuality = q);
    canvas.drawImageRect(t, Rect.fromLTWH(0, 0, t.width.toDouble(), t.height.toDouble()), dst,
        Paint()
          ..filterQuality = q
          ..blendMode = _mode);
  }
}

/// V3-C `disintegrate` effect: the layer breaks into square blocks that drop
/// out in a random order sweeping left → right (block edge pieces drift up
/// and away). [progress] 0..1.
class DisintegrateFx {
  DisintegrateFx._();

  static final LinkedHashMap<String, ui.Image> _masks = LinkedHashMap();

  /// Threshold (0..1) at which block (x, y) of a [cols]-wide grid vanishes.
  static double threshold(int x, int y, int cols, int seed) =>
      0.08 + 0.62 * hash01(x * 131 + y * 977, seed) + 0.3 * (cols <= 1 ? 0 : x / (cols - 1)) * 0.9;

  /// Alpha of a block at [p]: 1 before its threshold, fading over [band].
  static double alpha(double thr, double p, {double band = 0.06}) => ((thr - p) / band).clamp(0.0, 1.0).toDouble();

  static ui.Image _mask(int cols, int rows, int seed, double p, {required bool edge}) {
    final q = (p * 90).round();
    final key = '$cols|$rows|$seed|$q|$edge';
    final hit = _masks.remove(key);
    if (hit != null) return _masks[key] = hit;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    final paint = Paint();
    final pq = q / 90;
    for (int y = 0; y < rows; y++) {
      for (int x = 0; x < cols; x++) {
        final thr = threshold(x, y, cols, seed);
        double a;
        if (edge) {
          // the pieces breaking away right now
          final d = pq - thr;
          a = d < 0 || d > 0.22 ? 0 : (1 - d / 0.22) * 0.85;
        } else {
          a = alpha(thr, pq);
        }
        if (a <= 0.004) continue;
        paint.color = Color.fromRGBO(255, 255, 255, a);
        c.drawRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1), paint);
      }
    }
    final img = rec.endRecording().toImageSync(cols, rows);
    _masks[key] = img;
    while (_masks.length > 96) {
      _masks.remove(_masks.keys.first)?.dispose();
    }
    return img;
  }

  static ui.Shader _shader(ui.Image img, Rect bounds, int cols, int rows) {
    final m = Float64List.fromList([
      bounds.width / cols, 0, 0, 0, //
      0, bounds.height / rows, 0, 0, //
      0, 0, 1, 0, //
      bounds.left, bounds.top, 0, 1,
    ]);
    return ui.ImageShader(img, TileMode.clamp, TileMode.clamp, m, filterQuality: FilterQuality.none);
  }

  static Widget wrap({
    required Widget child,
    required double progress,
    required double block,
    required double drift,
    required int seed,
    required Size size,
  }) {
    if (progress <= 0.001) return child;
    if (progress >= 0.999) return Opacity(opacity: 0, child: child);
    final b = block.clamp(2.0, 200.0);
    final cols = (size.width / b).ceil().clamp(1, 160);
    final rows = (size.height / b).ceil().clamp(1, 160);
    final keep = _mask(cols, rows, seed, progress, edge: false);
    final flying = _mask(cols, rows, seed, progress, edge: true);
    final d = (drift / 100).clamp(0.0, 1.0) * math.max(size.width, size.height) * 0.08;
    return Stack(clipBehavior: Clip.none, children: [
      ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (r) => _shader(keep, r, cols, rows),
        child: child,
      ),
      Transform.translate(
        offset: Offset(d * (0.6 + progress), -d * (0.4 + progress * 1.2)),
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (r) => _shader(flying, r, cols, rows),
          child: child,
        ),
      ),
    ]);
  }
}
