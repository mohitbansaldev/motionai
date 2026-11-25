import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' hide Layer;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../core/model/anim_prop.dart';
import '../../../core/model/layer.dart';
import '../../../core/model/project.dart';
import '../shape_painter.dart';
import 'offscreen.dart';

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

  const LayerRaster({super.key, required this.enabled, this.ratio = 1, this.fast = false, super.child});

  @override
  RenderLayerRaster createRenderObject(BuildContext context) => RenderLayerRaster(enabled, ratio, fast);

  @override
  void updateRenderObject(BuildContext context, RenderLayerRaster renderObject) {
    renderObject
      ..enabled = enabled
      ..ratio = ratio
      ..fast = fast;
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
  bool _never = false; // live texture / inner repaint boundary: always direct

  ui.Image? _image;
  double _imageRatio = 0;
  final LayerHandle<OffsetLayer> _holder = LayerHandle<OffsetLayer>(OffsetLayer());
  final Paint _paint = Paint();

  @override
  bool get isRepaintBoundary => true;

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
  }

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
    final side = math.max(size.width, size.height);
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
      // Live textures cannot be snapshotted; inner repaint boundaries would
      // repaint without telling us (stale image) — draw those directly.
      if (texturesIn(child).isNotEmpty || _hasInnerBoundary(child)) {
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
      final img = paintChildToImage(_holder.layer!, child, size, ratio);
      if (img == null) {
        _dropImage();
        _paintDirect(context, offset, child);
        return;
      }
      _image?.dispose();
      _image = img;
      _imageRatio = ratio;
      snapshots++;
    }
    _contentDirty = false;
    final img = _image!;
    _paint.filterQuality = _fast ? FilterQuality.low : FilterQuality.medium;
    context.canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      offset & size,
      _paint,
    );
  }
}
