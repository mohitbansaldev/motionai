import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' hide Layer;
import 'package:flutter/widgets.dart';

import '../../../core/model/layer.dart';
import '../../../core/presets/realism.dart';
import 'offscreen.dart';

/// V2-D realism effects for [LayerView]: grade, haze, contact_shadow,
/// gate_weave, and the snapshot effects (bloom, halation,
/// chromatic_aberration, lens_distortion, light_wrap). Returns null for any
/// other effect type.
Widget? realismEffect(Effect e, Widget child, Layer l, double time, {required bool draft, required bool playing}) {
  double p(String k, [int i = 0]) {
    final ap = e.params[k];
    if (ap == null) return 0;
    final v = ap.valueAt(time);
    return i < v.length ? v[i] : v[0];
  }

  List<double> v3(String k) => [p(k, 0), p(k, 1), p(k, 2)];
  final cheap = draft && playing;
  switch (e.type) {
    case 'grade':
      return ColorFiltered(
        colorFilter: ui.ColorFilter.matrix(Realism.gradeMatrix(
            lift: v3('lift'), gain: v3('gain'), saturation: p('saturation'), contrast: p('contrast'), amount: p('amount'))),
        child: child,
      );
    case 'haze':
      if (p('amount') <= 0.05) return child;
      return ColorFiltered(colorFilter: ui.ColorFilter.matrix(Realism.hazeMatrix(v3('color'), p('amount'))), child: child);
    case 'contact_shadow':
      return _contactShadow(e, child, l, time, v3('color'), p('opacity'), p('cast'));
    case 'gate_weave':
      return _gateWeave(child, l, time, p('amount'), p('flicker'));
    case 'bloom':
    case 'halation':
    case 'chromatic_aberration':
    case 'lens_distortion':
    case 'light_wrap':
      final params = switch (e.type) {
        'bloom' || 'halation' => [p('threshold'), p('amount'), p('radius')],
        'light_wrap' => [p('amount'), p('width')],
        _ => [p('amount')],
      };
      if (e.type == 'lens_distortion' ? params[0].abs() < 0.05 : params[e.type == 'bloom' || e.type == 'halation' ? 1 : 0] <= 0.05) {
        return child;
      }
      return FxSnapshot(
        kind: e.type,
        params: params,
        color: v3('color'),
        maxSide: cheap ? 960 : (draft ? 1600 : 3000),
        draft: draft,
        child: child,
      );
    default:
      return null;
  }
}

// ------------------------------------------------------------ contact shadow

Widget _contactShadow(Effect e, Widget child, Layer l, double time, List<double> rgb, double opacity, double cast) {
  final op = (opacity / 100).clamp(0.0, 1.0);
  if (op <= 0.001) return child;
  final g = ShadowGeometry.forEffect(l, e, time);
  final col = Color.fromARGB(255, rgb[0].round().clamp(0, 255), rgb[1].round().clamp(0, 255), rgb[2].round().clamp(0, 255));
  final c = (cast / 100).clamp(0.0, 1.0);
  final w = l.width, h = l.height;
  return Stack(clipBehavior: Clip.none, children: [
    if (c > 0.001)
      Positioned(
        left: 0,
        top: 0,
        width: w,
        height: h,
        child: IgnorePointer(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: g.blur * 0.8 + 1.5, sigmaY: g.blur * 0.8 + 1.5, tileMode: TileMode.decal),
            child: Transform(
              transform: Matrix4(g.a, g.b, 0, 0, g.c, g.d, 0, 0, 0, 0, 1, 0, g.tx, g.ty, 0, 1),
              child: Opacity(
                opacity: (op * c * 0.85).clamp(0.0, 1.0),
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  // Darkest at the feet, gone toward the head.
                  shaderCallback: (_) => ui.Gradient.linear(
                      Offset(0, g.ground), Offset(0, g.ground * 0.12), const [Color(0xFFFFFFFF), Color(0x00FFFFFF)]),
                  child: ColorFiltered(colorFilter: ui.ColorFilter.mode(col, BlendMode.srcIn), child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    Positioned(
      left: 0,
      top: 0,
      width: w,
      height: h,
      child: IgnorePointer(child: CustomPaint(painter: GroundShadowPainter(g, col, op))),
    ),
    child,
  ]);
}

/// Soft elliptical ground shadow plus a tight dark contact core.
class GroundShadowPainter extends CustomPainter {
  final ShadowGeometry g;
  final Color color;
  final double opacity;
  GroundShadowPainter(this.g, this.color, this.opacity);

  @override
  void paint(Canvas canvas, Size size) {
    final soft = Paint()
      ..color = color.withValues(alpha: (opacity * 0.75).clamp(0.0, 1.0))
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(0.5, g.blur));
    canvas.drawOval(Rect.fromCenter(center: Offset(g.cx, g.cy), width: g.rx * 2, height: g.ry * 2), soft);
    final core = Paint()
      ..color = color.withValues(alpha: opacity.clamp(0.0, 1.0))
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, math.max(0.5, g.blur * 0.3));
    canvas.drawOval(
        Rect.fromCenter(center: Offset(g.cx, g.ground - g.ry * 0.15), width: g.rx * 1.15, height: g.ry * 0.8), core);
  }

  @override
  bool shouldRepaint(covariant GroundShadowPainter old) =>
      old.g.cx != g.cx || old.g.cy != g.cy || old.g.rx != g.rx || old.g.ry != g.ry || old.g.blur != g.blur ||
      old.color != color || old.opacity != opacity;
}

// ---------------------------------------------------------------- gate weave

Widget _gateWeave(Widget child, Layer l, double time, double amount, double flicker) {
  final a = (amount / 100).clamp(0.0, 1.0), fl = (flicker / 100).clamp(0.0, 1.0);
  if (a <= 0.001 && fl <= 0.001) return child;
  final tq = (time * 24).floor() / 24; // film moves once per frame
  final dx = Realism.noise(tq * 1.3, 3) * a * l.width * 0.0025;
  final dy = Realism.noise(tq * 1.1, 9) * a * l.height * 0.004;
  final s = 1 + a * 0.01; // hide the moving edge
  final cx = l.width / 2, cy = l.height / 2;
  Widget out = child;
  if (a > 0.001) {
    out = Transform(
      transform: Matrix4.translationValues(cx + dx, cy + dy, 0)
        ..multiply(Matrix4.diagonal3Values(s, s, 1))
        ..multiply(Matrix4.translationValues(-cx, -cy, 0)),
      child: out,
    );
  }
  if (fl > 0.001) {
    final b = (Realism.noise(tq * 9.0, 21) * 0.7 + Realism.noise(tq * 23.0, 5) * 0.3) * fl * 0.06;
    final k = 1 + b;
    out = ColorFiltered(
      colorFilter: ui.ColorFilter.matrix([k, 0, 0, 0, 0, 0, k, 0, 0, 0, 0, 0, k, 0, 0, 0, 0, 0, 1, 0]),
      child: out,
    );
  }
  return out;
}

// ----------------------------------------------------------- snapshot effects

/// Renders its child to an image and draws it through a lens/light effect:
/// bloom / halation [threshold, amount, radius], chromatic_aberration
/// [amount], lens_distortion [amount], light_wrap [amount, width] + [color].
class FxSnapshot extends SingleChildRenderObjectWidget {
  final String kind;
  final List<double> params;
  final List<double> color;
  final double maxSide;
  final bool draft;

  const FxSnapshot({
    super.key,
    required this.kind,
    required this.params,
    this.color = const [255, 255, 255],
    this.maxSide = 2048,
    this.draft = false,
    super.child,
  });

  @override
  RenderFxSnapshot createRenderObject(BuildContext context) => RenderFxSnapshot(kind, params, color, maxSide, draft);

  @override
  void updateRenderObject(BuildContext context, RenderFxSnapshot renderObject) =>
      renderObject.set(kind, params, color, maxSide, draft);
}

class RenderFxSnapshot extends RenderProxyBox {
  String _kind;
  List<double> _p;
  List<double> _color;
  double _maxSide;
  bool _draft;

  RenderFxSnapshot(this._kind, this._p, this._color, this._maxSide, this._draft);

  final LayerHandle<OffsetLayer> _holder = LayerHandle<OffsetLayer>(OffsetLayer());
  ui.Image? _image;
  ui.Vertices? _vertices;

  static bool _same(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void set(String kind, List<double> p, List<double> color, double maxSide, bool draft) {
    if (kind == _kind && _same(p, _p) && _same(color, _color) && maxSide == _maxSide && draft == _draft) return;
    _kind = kind;
    _p = p;
    _color = color;
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
    super.dispose();
  }

  double _v(int i, [double d = 0]) => i < _p.length ? _p[i] : d;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    // Live video textures cannot be snapshotted: show them unaffected (export
    // renders decoded frames, which go through the effect).
    if (texturesIn(child).isNotEmpty) {
      context.paintChild(child, offset);
      return;
    }
    final ratio = snapshotRatio(size, _maxSide);
    final img = paintChildToImage(_holder.layer!, child, size, ratio);
    if (img == null) {
      context.paintChild(child, offset);
      return;
    }
    _image?.dispose();
    _image = img;
    final canvas = context.canvas;
    final src = Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble());
    final dst = offset & size;
    final base = Paint()..filterQuality = _draft ? FilterQuality.low : FilterQuality.medium;
    switch (_kind) {
      case 'bloom':
      case 'halation':
        canvas.drawImageRect(img, src, dst, base);
        final m = glowMatrix(_v(0, 70), _v(1, 40), halation: _kind == 'halation');
        final sigma = math.max(0.5, _v(2, 30) * 0.5);
        canvas.drawImageRect(
          img,
          src,
          dst,
          Paint()
            ..filterQuality = FilterQuality.low
            ..blendMode = BlendMode.plus
            ..imageFilter = ui.ImageFilter.compose(
              outer: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.decal),
              inner: ui.ColorFilter.matrix(m),
            ),
        );
        break;
      case 'chromatic_aberration':
        final e = (_v(0) / 100).clamp(0.0, 1.0) * 0.012;
        final c = dst.center;
        Rect scaled(double s) => Rect.fromCenter(center: c, width: dst.width * s, height: dst.height * s);
        // win-44: each channel at full alpha, added together. (The old "1/3 alpha
        // then ×3" trick turned black grey on adjustment layers / looks.)
        canvas.saveLayer(scaled(1 + e).inflate(2), Paint());
        for (int ch = 0; ch < 3; ch++) {
          canvas.drawImageRect(
            img,
            src,
            scaled(ch == 0 ? 1 + e : (ch == 2 ? 1 - e : 1)),
            Paint()
              ..filterQuality = base.filterQuality
              ..blendMode = BlendMode.plus
              ..colorFilter = ui.ColorFilter.matrix(channelMatrixFull(ch)),
          );
        }
        canvas.restore();
        break;
      case 'lens_distortion':
        _paintLens(canvas, img, offset, ratio);
        break;
      case 'light_wrap':
        final a = (_v(0, 40) / 100).clamp(0.0, 1.0);
        final width = math.max(0.5, _v(1, 12) * 0.5);
        final col = Color.fromARGB(
            255, _color[0].round().clamp(0, 255), _color[1].round().clamp(0, 255), _color[2].round().clamp(0, 255));
        // Isolated, so the wrap only lands on this layer's own pixels.
        canvas.saveLayer(dst, Paint());
        canvas.drawImageRect(img, src, dst, base);
        canvas.saveLayer(dst, Paint()
          ..blendMode = BlendMode.srcATop
          ..color = Color.fromRGBO(0, 0, 0, a));
        canvas.drawImageRect(img, src, dst, Paint()..colorFilter = ui.ColorFilter.mode(col, BlendMode.srcIn));
        canvas.drawImageRect(
          img,
          src,
          dst,
          Paint()
            ..blendMode = BlendMode.dstOut
            ..imageFilter = ui.ImageFilter.blur(sigmaX: width, sigmaY: width, tileMode: TileMode.decal),
        );
        canvas.restore();
        canvas.restore();
        break;
      default:
        canvas.drawImageRect(img, src, dst, base);
    }
  }

  void _paintLens(Canvas canvas, ui.Image img, Offset offset, double ratio) {
    final cols = _draft ? 20 : 40, rows = _draft ? 12 : 24;
    final w = size.width, h = size.height, amount = _v(0);
    final nv = (cols + 1) * (rows + 1);
    final pos = Float32List(nv * 2), tex = Float32List(nv * 2);
    for (int r = 0; r <= rows; r++) {
      for (int c = 0; c <= cols; c++) {
        final i = (r * (cols + 1) + c) * 2;
        final x = c / cols * w, y = r / rows * h;
        final (px, py) = Realism.lensWarp(x, y, w, h, amount);
        pos[i] = offset.dx + px;
        pos[i + 1] = offset.dy + py;
        tex[i] = x * ratio;
        tex[i + 1] = y * ratio;
      }
    }
    final idx = Uint16List(cols * rows * 6);
    var k = 0;
    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        final i0 = r * (cols + 1) + c, i1 = i0 + 1, i2 = i0 + cols + 1, i3 = i2 + 1;
        idx[k++] = i0;
        idx[k++] = i1;
        idx[k++] = i2;
        idx[k++] = i1;
        idx[k++] = i3;
        idx[k++] = i2;
      }
    }
    final v = ui.Vertices.raw(ui.VertexMode.triangles, pos, textureCoordinates: tex, indices: idx);
    final paint = Paint()
      ..shader = ui.ImageShader(img, TileMode.clamp, TileMode.clamp, Matrix4.identity().storage,
          filterQuality: _draft ? FilterQuality.low : FilterQuality.medium);
    canvas.drawVertices(v, BlendMode.srcOver, paint);
    _vertices?.dispose();
    _vertices = v;
  }
}


/// win-44: one colour channel with the full alpha (chromatic aberration).
List<double> channelMatrixFull(int ch) => [
      for (int row = 0; row < 3; row++) ...[
        for (int col = 0; col < 3; col++) (row == ch && col == ch) ? 1.0 : 0.0,
        0,
        0,
      ],
      0, 0, 0, 1, 0,
    ];

/// One colour channel with a third of the alpha (three passes add up to the
/// full alpha; the layer then multiplies colour by 3).
List<double> channelMatrix(int ch) => [
      for (int row = 0; row < 3; row++) ...[
        for (int col = 0; col < 3; col++) (row == ch && col == ch) ? 1.0 : 0.0,
        0,
        0,
      ],
      0, 0, 0, 1 / 3, 0,
    ];

/// Highlights above [threshold] % scaled by [amount] % (colour kept for
/// bloom; warm red-orange from luminance for halation).
List<double> glowMatrix(double threshold, double amount, {bool halation = false}) {
  final th = (threshold / 100).clamp(0.0, 0.98);
  final s = 1 / (1 - th);
  final a = (amount / 100).clamp(0.0, 1.0) * (halation ? 1.2 : 1.0);
  final off = -th * s * 255;
  if (!halation) {
    return [
      s * a, 0, 0, 0, off * a, //
      0, s * a, 0, 0, off * a, //
      0, 0, s * a, 0, off * a, //
      0, 0, 0, 1, 0,
    ];
  }
  const tint = [1.0, 0.32, 0.12];
  return [
    for (final t in tint) ...[0.2126 * s * a * t, 0.7152 * s * a * t, 0.0722 * s * a * t, 0, off * a * t],
    0, 0, 0, 1, 0,
  ];
}

// ------------------------------------------------------ padded snapshots

class _PadContext extends PaintingContext {
  // ignore: use_super_parameters
  _PadContext(ContainerLayer layer, Rect bounds) : super(layer, bounds);
  void finish() => stopRecordingIfNeeded();
}

/// Like [paintChildToImage] with a margin of [pad] layer px on every side
/// (for effects that paint outside the layer box).
ui.Image? paintChildToImagePadded(OffsetLayer holder, RenderBox child, Size size, double pixelRatio, double pad) {
  if (!child.hasSize || size.isEmpty || !size.isFinite) return null;
  final r = Rect.fromLTWH(-pad, -pad, size.width + 2 * pad, size.height + 2 * pad);
  if (r.width * pixelRatio < 1 || r.height * pixelRatio < 1) return null;
  holder.removeAllChildren();
  final ctx = _PadContext(holder, r);
  ctx.paintChild(child, Offset.zero);
  ctx.finish();
  return holder.toImageSync(r, pixelRatio: pixelRatio);
}
