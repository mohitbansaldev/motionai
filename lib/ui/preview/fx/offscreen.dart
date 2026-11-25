import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../../core/engine/fx_math.dart';

/// A painting context that records into a private layer tree, so a child can
/// be rendered to an image synchronously (for mesh warps and track mattes).
class _OffscreenContext extends PaintingContext {
  // ignore: use_super_parameters
  _OffscreenContext(ContainerLayer layer, Rect bounds) : super(layer, bounds);
  void finish() => stopRecordingIfNeeded();
}

/// Paints [child] (already laid out) into [holder] and snapshots it at
/// [pixelRatio] (image pixels per logical pixel). Works for every content
/// type (images, text, shapes, nested effects) and is synchronous, so the
/// exported frame always matches what is on screen.
ui.Image? paintChildToImage(OffsetLayer holder, RenderBox child, Size size, double pixelRatio) {
  if (!child.hasSize || size.isEmpty || !size.isFinite) return null;
  if (size.width * pixelRatio < 1 || size.height * pixelRatio < 1) return null;
  holder.removeAllChildren();
  final ctx = _OffscreenContext(holder, Offset.zero & size);
  ctx.paintChild(child, Offset.zero);
  ctx.finish();
  return holder.toImageSync(Offset.zero & size, pixelRatio: pixelRatio);
}

/// Platform textures in a render subtree. Live video players draw through a
/// [TextureBox], whose pixels an offscreen snapshot may miss (→ blank).
List<TextureBox> texturesIn(RenderObject root) {
  final out = <TextureBox>[];
  void visit(RenderObject r) {
    if (r is TextureBox) {
      out.add(r);
    } else {
      r.visitChildren(visit);
    }
  }

  visit(root);
  return out;
}

/// Picks a snapshot resolution: at most [maxSide] image pixels on the long
/// side, never more than 1.5× the layer's own pixels.
double snapshotRatio(Size size, double maxSide) {
  final side = math.max(size.width, size.height);
  if (side <= 0) return 1;
  return (maxSide / side).clamp(0.02, 1.5).toDouble();
}

enum WarpMode { curve, sway }

/// True mesh warp of its child: the child is rendered to an image and drawn
/// through a deformed triangle grid ([Canvas.drawVertices]).
///
/// - [WarpMode.curve]: bulge/curve like a curved screen or board ([a] = bend −100..100).
/// - [WarpMode.sway]: wind sway with the bottom pinned ([a] = amount, [b] = speed).
class MeshWarp extends SingleChildRenderObjectWidget {
  final WarpMode mode;
  final double a, b, time;
  final int seed;
  final double maxSide; // snapshot resolution cap (px)
  final bool draft;

  const MeshWarp({
    super.key,
    required this.mode,
    required this.a,
    this.b = 1,
    this.time = 0,
    this.seed = 0,
    this.maxSide = 2048,
    this.draft = false,
    super.child,
  });

  @override
  RenderMeshWarp createRenderObject(BuildContext context) =>
      RenderMeshWarp(mode, a, b, time, seed, maxSide, draft);

  @override
  void updateRenderObject(BuildContext context, RenderMeshWarp renderObject) {
    final r = renderObject;
    r.set(mode, a, b, time, seed, maxSide, draft);
  }
}

class RenderMeshWarp extends RenderProxyBox {
  WarpMode _mode;
  double _a, _b, _time, _maxSide;
  int _seed;
  bool _draft;

  RenderMeshWarp(this._mode, this._a, this._b, this._time, this._seed, this._maxSide, this._draft);

  final LayerHandle<OffsetLayer> _holder = LayerHandle<OffsetLayer>(OffsetLayer());
  ui.Image? _image;
  ui.Vertices? _vertices;

  // Strip fallback for live video (see [_paintStrips]); layers reused per strip.
  final List<LayerHandle<TransformLayer>> _stripT = [];
  final List<LayerHandle<ClipRectLayer>> _stripC = [];
  final Paint _paint = Paint()..filterQuality = FilterQuality.medium;

  // Mesh buffers, rebuilt only when the grid or size changes.
  int _cols = 0, _rows = 0;
  Size _meshSize = Size.zero;
  double _meshRatio = 0;
  Float32List _pos = Float32List(0);
  Float32List _tex = Float32List(0);
  Uint16List _idx = Uint16List(0);
  final List<double> _tmp = [0.0, 0.0];

  void set(WarpMode mode, double a, double b, double time, int seed, double maxSide, bool draft) {
    if (mode == _mode && a == _a && b == _b && time == _time && seed == _seed && maxSide == _maxSide && draft == _draft) {
      return;
    }
    _mode = mode;
    _a = a;
    _b = b;
    _time = time;
    _seed = seed;
    _maxSide = maxSide;
    _draft = draft;
    markNeedsPaint();
  }

  @override
  void dispose() {
    _image?.dispose();
    _image = null;
    _vertices?.dispose();
    _vertices = null;
    _holder.layer = null;
    _clearStrips();
    super.dispose();
  }

  void _clearStrips() {
    for (final h in _stripT) {
      h.layer = null;
    }
    for (final h in _stripC) {
      h.layer = null;
    }
    _stripT.clear();
    _stripC.clear();
  }

  /// Live video (a platform texture) cannot be snapshotted reliably, so the
  /// warp is approximated by compositing the video texture several times,
  /// each copy clipped to one strip and transformed like the mesh there
  /// (columns for curve, rows for sway). No pixels are read back. Only the
  /// texture is drawn: effects inside the warp are skipped in the live
  /// preview (export renders decoded frames through the real mesh).
  void _paintStrips(PaintingContext context, Offset offset, RenderBox child, List<TextureBox> textures) {
    final w = size.width, h = size.height;
    final curve = _mode == WarpMode.curve;
    final n = curve ? (_draft ? 16 : 32) : (_draft ? 10 : 20);
    while (_stripT.length < n) {
      _stripT.add(LayerHandle<TransformLayer>());
      _stripC.add(LayerHandle<ClipRectLayer>());
    }
    final cy = h / 2;
    for (int i = 0; i < n; i++) {
      final Matrix4 m;
      final Rect clip;
      if (curve) {
        final x0 = i / n * w, x1 = (i + 1) / n * w;
        Warp.curve(x0, 0, w, h, _a, _tmp);
        final dx0 = _tmp[0];
        Warp.curve(x1, 0, w, h, _a, _tmp);
        final dx1 = _tmp[0];
        Warp.curve((x0 + x1) / 2, 0, w, h, _a, _tmp);
        final sy = cy > 0 ? (cy - _tmp[1]) / cy : 1.0;
        final sx = (dx1 - dx0) / math.max(1e-6, x1 - x0);
        m = Matrix4.translationValues(dx0, cy, 0)
          ..multiply(Matrix4.diagonal3Values(sx, sy, 1))
          ..multiply(Matrix4.translationValues(-x0, -cy, 0));
        clip = Rect.fromLTRB(x0 - 0.75, 0, x1 + 0.75, h); // slight overlap hides seams
      } else {
        final y0 = i / n * h, y1 = (i + 1) / n * h;
        final dx = Warp.sway(w / 2, (y0 + y1) / 2, w, h, _a, _b, _time, _seed);
        m = Matrix4.translationValues(dx, 0, 0);
        clip = Rect.fromLTRB(0, y0 - 0.75, w, y1 + 0.75);
      }
      final ch = _stripC[i];
      _stripT[i].layer = context.pushTransform(true, offset, m, (ctx, o) {
        ch.layer = ctx.pushClipRect(true, o, clip, (c2, o2) {
          for (final tex in textures) {
            c2.pushTransform(true, o2, tex.getTransformTo(child), (c3, o3) {
              c3.addLayer(TextureLayer(rect: o3 & tex.size, textureId: tex.textureId, freeze: tex.freeze, filterQuality: tex.filterQuality));
            });
          }
        }, oldLayer: ch.layer);
      }, oldLayer: _stripT[i].layer);
    }
  }

  void _ensureMesh(int cols, int rows, Size size, double ratio) {
    if (cols == _cols && rows == _rows && size == _meshSize && ratio == _meshRatio) return;
    _cols = cols;
    _rows = rows;
    _meshSize = size;
    _meshRatio = ratio;
    final nv = (cols + 1) * (rows + 1);
    _pos = Float32List(nv * 2);
    _tex = Float32List(nv * 2);
    for (int r = 0; r <= rows; r++) {
      for (int c = 0; c <= cols; c++) {
        final i = (r * (cols + 1) + c) * 2;
        _tex[i] = c / cols * size.width * ratio;
        _tex[i + 1] = r / rows * size.height * ratio;
      }
    }
    _idx = Uint16List(cols * rows * 6);
    var k = 0;
    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        final i0 = r * (cols + 1) + c, i1 = i0 + 1, i2 = i0 + cols + 1, i3 = i2 + 1;
        _idx[k++] = i0;
        _idx[k++] = i1;
        _idx[k++] = i2;
        _idx[k++] = i1;
        _idx[k++] = i3;
        _idx[k++] = i2;
      }
    }
  }

  bool get _identity => _mode == WarpMode.curve ? _a.abs() < 0.05 : _a <= 0.01;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (_identity) {
      context.paintChild(child, offset);
      return;
    }
    final textures = texturesIn(child);
    if (textures.isNotEmpty) {
      // Live video: a snapshot could come out blank, so warp by compositing.
      _paintStrips(context, offset, child, textures);
      return;
    }
    final ratio = snapshotRatio(size, _maxSide);
    final img = paintChildToImage(_holder.layer!, child, size, ratio);
    if (img == null) return;
    _image?.dispose();
    _image = img;

    final cols = _mode == WarpMode.curve ? (_draft ? 24 : 48) : (_draft ? 4 : 8);
    final rows = _mode == WarpMode.curve ? (_draft ? 6 : 12) : (_draft ? 12 : 24);
    _ensureMesh(cols, rows, size, ratio);
    final w = size.width, h = size.height;
    for (int r = 0; r <= rows; r++) {
      for (int c = 0; c <= cols; c++) {
        final i = (r * (cols + 1) + c) * 2;
        final x = c / cols * w, y = r / rows * h;
        double px, py;
        if (_mode == WarpMode.curve) {
          Warp.curve(x, y, w, h, _a, _tmp);
          px = _tmp[0];
          py = _tmp[1];
        } else {
          px = x + Warp.sway(x, y, w, h, _a, _b, _time, _seed);
          py = y;
        }
        _pos[i] = offset.dx + px;
        _pos[i + 1] = offset.dy + py;
      }
    }
    final vertices = ui.Vertices.raw(ui.VertexMode.triangles, _pos, textureCoordinates: _tex, indices: _idx);
    _paint.shader = ui.ImageShader(img, TileMode.clamp, TileMode.clamp, Matrix4.identity().storage,
        filterQuality: _draft ? FilterQuality.low : FilterQuality.medium);
    context.canvas.drawVertices(vertices, BlendMode.srcOver, _paint);
    _vertices?.dispose();
    _vertices = vertices;
  }
}

/// Track matte compositor: draws [content] only where [matte] has pixels
/// (or only where it has none when [inverse]). The matte itself is not shown.
class MatteComposite extends MultiChildRenderObjectWidget {
  final bool inverse;
  final double resolution; // matte image pixels per comp pixel

  MatteComposite({super.key, required Widget matte, required Widget content, this.inverse = false, this.resolution = 1})
      : super(children: [matte, content]);

  @override
  RenderMatteComposite createRenderObject(BuildContext context) => RenderMatteComposite(inverse, resolution);

  @override
  void updateRenderObject(BuildContext context, RenderMatteComposite renderObject) {
    final r = renderObject;
    r
      ..inverse = inverse
      ..resolution = resolution;
  }
}

class _MatteData extends ContainerBoxParentData<RenderBox> {}

class RenderMatteComposite extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _MatteData>, RenderBoxContainerDefaultsMixin<RenderBox, _MatteData> {
  RenderMatteComposite(this._inverse, this._resolution);

  bool _inverse;
  double _resolution;
  bool get inverse => _inverse;
  set inverse(bool v) {
    if (v == _inverse) return;
    _inverse = v;
    markNeedsPaint();
  }

  double get resolution => _resolution;
  set resolution(double v) {
    if (v == _resolution) return;
    _resolution = v;
    markNeedsPaint();
  }

  final LayerHandle<OffsetLayer> _holder = LayerHandle<OffsetLayer>(OffsetLayer());
  ui.Image? _image;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _MatteData) child.parentData = _MatteData();
  }

  @override
  bool get alwaysNeedsCompositing => true;

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
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final content = lastChild;
    if (content == null) return false;
    return content.hitTest(result, position: position);
  }

  @override
  void dispose() {
    _image?.dispose();
    _image = null;
    _holder.layer = null;
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final matte = firstChild;
    final content = matte == null ? null : childAfter(matte);
    if (matte == null || content == null) return;
    final ratio = _resolution.clamp(0.05, 2.0).toDouble();
    final img = paintChildToImage(_holder.layer!, matte, size, ratio);
    if (img == null) {
      layer = null;
      if (_inverse) context.paintChild(content, offset);
      return;
    }
    _image?.dispose();
    _image = img;
    final shader = ui.ImageShader(img, TileMode.clamp, TileMode.clamp,
        Matrix4.diagonal3Values(1 / ratio, 1 / ratio, 1).storage, filterQuality: FilterQuality.low);
    final l = (layer is ShaderMaskLayer ? layer as ShaderMaskLayer : null) ?? ShaderMaskLayer();
    l
      ..shader = shader
      ..maskRect = offset & size
      ..blendMode = _inverse ? BlendMode.dstOut : BlendMode.dstIn;
    layer = l;
    context.pushLayer(l, (ctx, o) => ctx.paintChild(content, o), offset);
  }
}
