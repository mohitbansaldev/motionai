import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' hide Layer;
import 'package:flutter/rendering.dart' as rendering show Layer;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../core/model/anim_prop.dart';
import '../../../core/model/layer.dart';
import '../../../core/model/project.dart';
import '../../../core/presets/realism.dart'; // V2-D
import '../shape_painter.dart';
import 'offscreen.dart';
import 'realism_painters.dart'; // V2-D

/// Live-preview caching for layers (Agent O, performance).
///
/// - [LayerSig] fingerprints what a layer's *content* (pixels in layer space:
///   media, text, shape, effects, masks) looks like at one moment. While it is
///   unchanged the preview reuses the same content widget, so nothing below
///   it rebuilds, relayouts or repaints; only the 3D transform changes.
/// - [LayerRaster] is a repaint boundary that, when enabled, draws its child
///   once into an image at about its on-screen size and then composites only
///   that image (one textured quad under the perspective transform instead of
///   text glyphs / paths / blurs re-rasterised every frame).
///
/// Export never uses either (draft only).
class LayerSig {
  /// Effects whose look depends on time itself, not only on their params.
  static const timeDriven = {'grain', 'dust', 'light_leak', 'flicker', 'sway', 'particles', 'light_rays', 'glitch'};

  /// Effects whose look depends only on their params (and the layer).
  static const paramDriven = {
    'blur', 'color', 'tint', 'vignette', 'glow', 'gradient', 'letterbox', 'outline', 'shadow', 'shatter', 'paper',
    'grunge', 'silhouette', 'mono', 'duotone', 'edge_blur', 'motion_blur', 'curve', 'glass_frame', 'torn_edge',
    'reveal', 'flash',
    ...Realism.paramFx, // V2-D
  };

  static int _prop(AnimProp p, double t) => Object.hashAll(p.isAnimated ? p.valueAt(t) : p.staticValue);

  static double _markProgress(TextMark m, double t) =>
      m.duration <= 0 ? (t >= m.start ? 1 : 0) : ((t - m.start) / m.duration).clamp(0.0, 1.0).toDouble();

  static int _text(Layer l, TextData d, double t) {
    var h = Object.hash(d.text, d.fontSize, d.color, d.fontWeight, d.align, d.fontFamily, d.animator, d.animDuration,
        d.highlightColor, d.boxColor, d.shadow, d.outline, d.extrude, d.extrudeColor);
    final local = t - l.start;
    if (d.animator == 'karaoke') {
      h = Object.hash(h, t, l.start, l.duration);
    } else if (d.animator != 'none' && local < d.animDuration + 0.06) {
      h = Object.hash(h, local); // intro still running
    }
    for (final w in d.words) {
      h = Object.hash(h, w.word, w.start, w.end);
    }
    for (final m in d.marks) {
      h = Object.hash(h, m.phrase, m.style, m.color, m.start, m.duration, _markProgress(m, t));
    }
    final c = d.counter;
    if (c != null) h = Object.hash(h, c.valueAt(t));
    return h;
  }

  /// Fingerprint of [l]'s content at [t], or null when it cannot be cached
  /// (live video, nested comps: they update on their own).
  static int? content(Project project, Layer l, double t,
      {required bool draft, required bool playing, bool asMatte = false, int decodeWidth = 0}) {
    if (l.type == LayerType.video || l.type == LayerType.comp) return null;
    final mid = l.mediaId;
    var h = Object.hash(l.type, l.id, l.width, l.height, l.color, mid, mid == null ? null : project.media[mid]?.path, draft,
        playing, asMatte, decodeWidth);
    final sh = l.shape;
    if (sh != null) h = Object.hash(h, identityHashCode(sh), ShapePainter.signature(sh));
    final trim = l.props[Props.trim];
    if (trim != null && l.type == LayerType.shape) h = Object.hash(h, _prop(trim, t));
    if (l.type == LayerType.text) h = Object.hash(h, _text(l, l.text ?? TextData(), t));
    for (final e in l.effects) {
      h = Object.hash(h, e.id, e.type, e.enabled);
      if (!e.enabled) continue;
      for (final p in e.params.entries) {
        h = Object.hash(h, p.key, _prop(p.value, t));
      }
      if (!paramDriven.contains(e.type)) h = Object.hash(h, t); // time-driven or unknown: changes every frame
    }
    for (final m in l.masks) {
      h = Object.hash(h, m.id, m.shape, m.invert);
      for (final p in m.props.entries) {
        h = Object.hash(h, p.key, _prop(p.value, t));
      }
    }
    return h;
  }

  /// True when caching [l] as an image is worth it: anything but a bare
  /// image / solid (those already draw as one quad).
  static bool worthRaster(Layer l) => switch (l.type) {
        LayerType.video || LayerType.comp || LayerType.audio || LayerType.nullObject => false,
        LayerType.image || LayerType.solid => l.masks.isNotEmpty || l.effects.any((e) => e.enabled && e.type != 'motion_blur'),
        LayerType.text || LayerType.shape => true,
      };

  /// Largest on-screen magnification of a layer: composition px per layer
  /// px along its longest projected edge (handles perspective foreshortening).
  static double screenScale(Matrix4 m, double w, double h) {
    final s = m.storage;
    Offset pr(double x, double y) {
      final px = s[0] * x + s[4] * y + s[12];
      final py = s[1] * x + s[5] * y + s[13];
      var pw = s[3] * x + s[7] * y + s[15];
      if (pw.abs() < 1e-9) pw = 1e-9;
      return Offset(px / pw, py / pw);
    }

    final a = pr(0, 0), b = pr(w, 0), c = pr(w, h), d = pr(0, h);
    final sx = math.max((b - a).distance, (c - d).distance) / math.max(1.0, w);
    final sy = math.max((d - a).distance, (c - b).distance) / math.max(1.0, h);
    final v = math.max(sx, sy);
    return v.isFinite ? v : 1.0;
  }

  /// Power-of-two bucket for a wanted value with hysteresis: stays on
  /// [current] while [want] fits in it and is more than 40% of it.
  static double bucket(double want, double current, {double min = 1 / 64, double max = 2}) {
    final w = want.isFinite ? want.clamp(min, max).toDouble() : 1.0;
    if (current > 0 && w <= current && w > current * 0.4) return current;
    final b = math.pow(2, (math.log(w) / math.ln2).ceil()).toDouble();
    return b.clamp(min, max).toDouble();
  }

  /// Decode width for an image layer in the live preview: about its on-screen
  /// width in physical pixels, in power-of-two steps (128..[cap]).
  static int decodeWidth(double wantPx, int current, {int cap = 1280}) {
    if (cap <= 128) return math.max(1, cap);
    final w = wantPx.isFinite ? wantPx.clamp(128.0, cap.toDouble()).toDouble() : cap.toDouble();
    if (current > 0 && w <= current && w > current * 0.4) return current;
    final b = math.pow(2, (math.log(w) / math.ln2).ceil()).toInt();
    return math.min(cap, math.max(128, b));
  }
}

/// Caches its child as an image while [enabled] (see [LayerSig]). Always a
/// repaint boundary, exactly like [RepaintBoundary] when disabled.
class LayerRaster extends SingleChildRenderObjectWidget {
  final bool enabled;

  /// Wanted image pixels per layer pixel (on-screen size); bucketed.
  final double ratio;

  /// Playing: cheaper sampling of the cached image.
  final bool fast;

  /// Depth-of-field blur sigma in layer pixels (in steps of 20%). Baked into
  /// the cached image, so scrubbing re-blurs a small image now and then
  /// instead of blurring the layer every frame; a blur layer otherwise.
  final double blur;

  /// V2-D: margin (layer px) cached around the box for effects that paint
  /// outside it (blur tails, glow, shadows), see `Realism.spill`.
  final double pad;

  const LayerRaster(
      {super.key, required this.enabled, this.ratio = 1, this.fast = false, this.blur = 0, this.pad = 0, super.child});

  @override
  RenderLayerRaster createRenderObject(BuildContext context) => RenderLayerRaster(enabled, ratio, fast)
    ..blur = blur
    ..pad = pad;

  @override
  void updateRenderObject(BuildContext context, RenderLayerRaster renderObject) {
    renderObject
      ..enabled = enabled
      ..ratio = ratio
      ..fast = fast
      ..blur = blur
      ..pad = pad; // V2-D
  }
}

class RenderLayerRaster extends RenderProxyBox {
  RenderLayerRaster(this._enabled, double ratio, this._fast) : _bucket = LayerSig.bucket(ratio, 0);

  /// Snapshots taken so far (tests / benchmark).
  static int snapshots = 0;

  /// Most snapshots taken in one frame; more wait for the next frame, so
  /// starting playback with dozens of layers does not stall one frame.
  static int maxSnapshotsPerFrame = 12;

  /// Longest side of a cached image (px).
  static const double maxSide = 2048;

  /// Frames in which a snapshot was taken (advanced after each such frame).
  static int _epoch = 0;
  static bool _resetArmed = false;
  static int _budgetUsed = 0;
  static final Stopwatch _clock = Stopwatch()..start();

  bool _enabled;
  double _bucket;
  bool _fast;

  bool _contentDirty = true;
  bool _redrawOnly = false;
  bool _retryScheduled = false;
  int _lastSnapEpoch = -10;
  int _streak = 0;
  int _cooldownUntilMs = -1; // real time (ms of [_clock])
  bool _never = false; // live texture: always direct

  // Inner repaint boundaries (RenderOpacity, ImageFiltered…) repaint without
  // telling us: after each frame, compare the layers of the snapshot with
  // what they hold now, and take a new snapshot if one was repainted.
  final List<ContainerLayer> _watchLayers = [];
  final List<rendering.Layer?> _watchFirst = [];
  bool _watchArmed = false;

  ui.Image? _image;
  double _imageRatio = 0;
  final LayerHandle<OffsetLayer> _holder = LayerHandle<OffsetLayer>(OffsetLayer());
  final Paint _paint = Paint();

  @override
  bool get isRepaintBoundary => true;

  /// What this boundary does right now (tests / benchmark).
  String get debugStatus => !_enabled
      ? 'off'
      : _never
          ? 'never'
          : _clock.elapsedMilliseconds < _cooldownUntilMs
              ? 'cooldown'
              : _image != null
                  ? 'image'
                  : 'direct';

  bool get enabled => _enabled;
  set enabled(bool v) {
    if (v == _enabled) return;
    _enabled = v;
    if (!v) _dropImage();
    _cooldownUntilMs = -1;
    markNeedsPaint();
  }

  set ratio(double want) {
    final b = LayerSig.bucket(want, _bucket);
    if (b == _bucket) return;
    _bucket = b;
    if (_enabled) markNeedsPaint();
  }

  // V2-D >>> snapshot margin
  double _pad = 0; // wanted (layer px, steps of 8)
  double _imagePad = 0; // margin of [_image]
  set pad(double v) {
    final q = v > 0.5 ? (v / 8).ceil() * 8.0 : 0.0;
    if (q == _pad) return;
    _pad = q;
    if (_enabled) markNeedsPaint();
  }
  // <<< V2-D

  double _blurQ = 0; // quantised sigma (layer px), 0 = sharp
  ui.Image? _blurred;
  ui.Image? _blurredFrom;
  double _blurredQ = 0;
  double _blurredDs = 1, _blurredPad = 0; // geometry of [_blurred]
  bool _redrawScheduled = false;

  static const double _blurStep = 1.3;

  /// Quantised blur: 0 below 0.3 px, else 1.3^k; stays on [current] while
  /// [s] is within ±65% of a step of it (no flicker between two steps).
  static double quantizeBlur(double s, [double current = 0]) {
    if (!(s > 0.3)) return 0;
    if (current > 0 && (math.log(s / current)).abs() < 0.65 * math.log(_blurStep)) return current;
    final k = (math.log(s) / math.log(_blurStep)).round();
    return math.pow(_blurStep, k).toDouble();
  }

  set blur(double v) {
    final q = quantizeBlur(v, _blurQ);
    if (q == _blurQ) return;
    _blurQ = q;
    if (_enabled && _image != null) {
      _redrawOnly = true;
      markNeedsPaint();
      _redrawOnly = false;
    } else {
      markNeedsPaint();
    }
  }

  void _dropBlurred() {
    _blurred?.dispose();
    _blurred = null;
    _blurredFrom = null;
    _blurredQ = 0;
  }

  set fast(bool v) {
    if (v == _fast) return;
    _fast = v;
    if (_enabled && _image != null) {
      _redrawOnly = true;
      markNeedsPaint();
      _redrawOnly = false;
    }
  }

  /// Every repaint request from the child (or a layout change) means the
  /// cached image is stale.
  @override
  void markNeedsPaint() {
    if (!_redrawOnly) _contentDirty = true;
    super.markNeedsPaint();
  }

  void _dropImage() {
    _image?.dispose();
    _image = null;
    _imageRatio = 0;
    _dropBlurred();
    _watchLayers.clear();
    _watchFirst.clear();
  }

  void _recordWatch(bool innerBoundaries) {
    _watchLayers.clear();
    _watchFirst.clear();
    if (!innerBoundaries) return;
    void visit(rendering.Layer l) {
      if (l is! ContainerLayer) return;
      _watchLayers.add(l);
      _watchFirst.add(l.firstChild);
      for (var c = l.firstChild; c != null; c = c.nextSibling) {
        visit(c);
      }
    }

    for (var c = _holder.layer!.firstChild; c != null; c = c.nextSibling) {
      visit(c);
    }
    _armWatch();
  }

  void _armWatch() {
    if (_watchArmed) return;
    _watchArmed = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _watchArmed = false;
      if (!attached || _image == null || _watchLayers.isEmpty) return;
      for (int i = 0; i < _watchLayers.length; i++) {
        if (!identical(_watchLayers[i].firstChild, _watchFirst[i])) {
          _watchLayers.clear();
          _watchFirst.clear();
          markNeedsPaint();
          return;
        }
      }
      _armWatch();
    });
  }

  @override
  String toStringShort() => 'RenderLayerRaster($debugStatus)';

  @override
  void dispose() {
    _dropImage();
    _holder.layer = null;
    super.dispose();
  }

  static bool _hasInnerBoundary(RenderObject root) {
    var found = false;
    void visit(RenderObject r) {
      if (found) return;
      if (r.isRepaintBoundary) {
        found = true;
        return;
      }
      r.visitChildren(visit);
    }

    root.visitChildren(visit);
    return found || root.isRepaintBoundary;
  }

  double get _ratio {
    final side = math.max(size.width, size.height) + 2 * _pad; // V2-D: + margin
    if (side <= 0) return _bucket;
    return math.min(_bucket, maxSide / side);
  }

  bool _takeBudget() {
    if (!_resetArmed) {
      _resetArmed = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _resetArmed = false;
        _budgetUsed = 0;
        _epoch++;
      });
    }
    if (_budgetUsed >= maxSnapshotsPerFrame) return false;
    _budgetUsed++;
    return true;
  }

  /// Most depth-blur steps re-rendered per frame.
  static int maxReblursPerFrame = 4;
  static int _reblurs = 0;
  static bool _reblurResetArmed = false;

  static bool _takeReblur() {
    if (!_reblurResetArmed) {
      _reblurResetArmed = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _reblurResetArmed = false;
        _reblurs = 0;
      });
    }
    if (_reblurs >= maxReblursPerFrame) return false;
    _reblurs++;
    return true;
  }

  /// Draw again next frame without a new snapshot (deferred re-blur).
  void _redrawNextFrame() {
    if (_redrawScheduled) return;
    _redrawScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _redrawScheduled = false;
      if (!attached || !_enabled || _image == null) return;
      _redrawOnly = true;
      markNeedsPaint();
      _redrawOnly = false;
    });
  }

  void _retryNextFrame() {
    if (_retryScheduled) return;
    _retryScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _retryScheduled = false;
      if (attached && _enabled) markNeedsPaint();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _paintDirect(PaintingContext context, Offset offset, RenderBox child) {
    _contentDirty = false;
    if (_blurQ > 0) {
      final f = ImageFilterLayer(imageFilter: ui.ImageFilter.blur(sigmaX: _blurQ, sigmaY: _blurQ, tileMode: TileMode.decal));
      context.pushLayer(f, (ctx, o) => ctx.paintChild(child, o), offset);
      return;
    }
    context.paintChild(child, offset);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (!_enabled || _never || size.isEmpty || _clock.elapsedMilliseconds < _cooldownUntilMs) {
      if (_image != null) _dropImage();
      _paintDirect(context, offset, child);
      return;
    }
    final ratio = _ratio;
    if (_contentDirty || _image == null || _imageRatio != ratio) {
      if (!_takeBudget()) {
        _dropImage();
        _paintDirect(context, offset, child);
        _retryNextFrame();
        return;
      }
      // Live textures cannot be snapshotted: draw those directly.
      if (texturesIn(child).isNotEmpty) {
        _never = true;
        _paintDirect(context, offset, child);
        return;
      }
      // Content repainting frame after frame is not worth caching.
      _streak = _lastSnapEpoch >= _epoch - 1 ? _streak + 1 : 0;
      _lastSnapEpoch = _epoch;
      if (_streak >= 3) {
        _streak = 0;
        _cooldownUntilMs = _clock.elapsedMilliseconds + 1500;
        _dropImage();
        _paintDirect(context, offset, child);
        return;
      }
      // V2-D: with a margin when effects paint outside the box.
      final img = _pad > 0 ? paintChildToImagePadded(_holder.layer!, child, size, ratio, _pad) : paintChildToImage(_holder.layer!, child, size, ratio);
      if (img == null) {
        _dropImage();
        _paintDirect(context, offset, child);
        return;
      }
      _image?.dispose();
      _image = img;
      _imageRatio = ratio;
      _imagePad = _pad; // V2-D
      snapshots++;
      _recordWatch(_hasInnerBoundary(child));
    }
    _contentDirty = false;
    final img = _image!;
    _paint.filterQuality = _fast ? FilterQuality.low : FilterQuality.medium;
    if (_blurQ > 0) {
      // Blurred copy with a 3σ margin (the blur spills past the layer edge),
      // stored smaller the stronger the blur (it has no fine detail left).
      final k = img.width / (size.width + 2 * _imagePad); // image px per layer px (V2-D: margin)
      final sigma = _blurQ * k; // in image px
      final ds = (2.0 / sigma).clamp(0.08, 1.0).toDouble();
      final pad = 3 * sigma; // image px
      final stale = _blurred != null && (!identical(_blurredFrom, img) || _blurredQ != _blurQ);
      // While scrubbing, at most [maxReblursPerFrame] layers re-blur per
      // frame; the others keep their previous blur step one more frame.
      if (stale && identical(_blurredFrom, img) && !_takeReblur()) {
        _redrawNextFrame();
      } else if (_blurred == null || stale) {
        _blurred?.dispose();
        final bw = math.max(1, ((img.width + 2 * pad) * ds).ceil()), bh = math.max(1, ((img.height + 2 * pad) * ds).ceil());
        final rec = ui.PictureRecorder();
        Canvas(rec).drawImageRect(
          img,
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          Rect.fromLTWH(pad * ds, pad * ds, img.width * ds, img.height * ds),
          Paint()
            ..filterQuality = FilterQuality.low
            ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma * ds, sigmaY: sigma * ds, tileMode: TileMode.decal),
        );
        final pic = rec.endRecording();
        _blurred = pic.toImageSync(bw, bh);
        pic.dispose();
        _blurredFrom = img;
        _blurredQ = _blurQ;
        _blurredDs = ds;
        _blurredPad = pad;
      }
      final b = _blurred!;
      final m = _blurredPad / k + _imagePad; // layer px (V2-D: + snapshot margin)
      context.canvas.drawImageRect(
        b,
        Rect.fromLTWH(0, 0, b.width.toDouble(), b.height.toDouble()),
        Rect.fromLTWH(offset.dx - m, offset.dy - m, b.width / _blurredDs / k, b.height / _blurredDs / k),
        _paint,
      );
      return;
    }
    if (_blurred != null) _dropBlurred();
    context.canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      (offset & size).inflate(_imagePad), // V2-D: snapshot margin
      _paint,
    );
  }
}
