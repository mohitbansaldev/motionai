// CHROMA (Agent M): green / blue screen (chroma key) renderer.
//
// How keying reaches the screen:
//  - Image layers: the photo is decoded (same cache entry as the normal
//    Image widget) and keyed directly.
//  - Video layers, export: the exact decoded frame (MediaBridge.readerFrame)
//    is keyed directly.
//  - Video layers, live preview: a platform video texture cannot be read
//    back, so the keyed layer shows frames from the platform decoder instead
//    of the player texture (the player keeps running for sound):
//      paused / scrubbing → exact frame (MediaBridge.frameAt) at ≤ 1280 px;
//      playing           → sequential decoder (MediaBridge.readerFrame)
//                           at ≤ 640 px, the newest decoded frame is shown
//                           (can trail the sound by a frame or two).
//    The un-keyed green picture is never shown: until the first keyed frame
//    arrives the layer is empty.
//  - Keying runs on the GPU (shaders/chroma_key.frag through a Paint, into
//    an offscreen picture → works on Skia and Impeller). When the shader
//    cannot load, the pure-Dart keyer (lib/core/engine/chroma.dart) runs in
//    an isolate and the result appears a moment later; export waits for it
//    with [ChromaKeyer.settle].
//  - Other layer types (text, shapes, comps): [ChromaSnapshot] keys a
//    snapshot of the layer on the GPU (skipped when the shader is missing).
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' hide Layer;
import 'package:flutter/widgets.dart';

import '../../../core/engine/chroma.dart';
import '../../../core/model/layer.dart';
import '../../../core/model/project.dart';
import '../../../services/media_bridge.dart';
import 'offscreen.dart';

/// Shader program cache, CPU fallback jobs and the export barrier.
class ChromaKeyer {
  static const asset = 'shaders/chroma_key.frag';

  static ui.FragmentProgram? _program;
  static Future<void>? _loading;
  static bool _failed = false;

  /// Tests: force the CPU keyer even when the shader is available.
  @visibleForTesting
  static bool forceCpu = false;

  static final Set<Future<void>> _pending = {};

  /// True when the GPU shader is ready to use.
  static bool get gpuReady => _program != null && !forceCpu;

  /// True once loading the shader failed (CPU keyer is used).
  static bool get gpuFailed => _failed || forceCpu;

  /// Outstanding async work (shader load, CPU keying).
  static bool get busy => _pending.isNotEmpty;

  /// Starts loading the shader (once). [onReady] runs when it finished
  /// (loaded or failed).
  static void ensureLoaded([VoidCallback? onReady]) {
    if (_program != null || _failed) return;
    _loading ??= _track(() async {
      try {
        _program = await ui.FragmentProgram.fromAsset(asset);
      } catch (e) {
        _failed = true;
        debugPrint('chroma_key shader unavailable, using the CPU keyer: $e');
      }
    }());
    if (onReady != null) _loading!.then((_) => onReady());
  }

  /// Loads the shader and waits for it (export start).
  static Future<void> load() async {
    ensureLoaded();
    await _loading;
  }

  static Future<void> _track(Future<void> f) {
    _pending.add(f);
    f.whenComplete(() => _pending.remove(f));
    return f;
  }

  /// Waits until no keying work is outstanding (call before capturing an
  /// export frame, then wait one more frame so the result is painted).
  static Future<void> settle() async {
    var guard = 0;
    while (_pending.isNotEmpty && guard++ < 50) {
      await Future.wait(_pending.toList()).catchError((_) => const <void>[]);
    }
  }

  /// GPU keying of [src] into a new image of the same size, or null when the
  /// shader is not ready. [shader] is reused between calls (the uniforms are
  /// copied when drawn).
  static ui.Image? gpuKey(ui.FragmentShader shader, ui.Image src, ChromaSettings s, double chokePx) {
    final w = src.width, h = src.height;
    shader
      ..setFloat(0, w.toDouble())
      ..setFloat(1, h.toDouble())
      ..setFloat(2, s.r / 255)
      ..setFloat(3, s.g / 255)
      ..setFloat(4, s.b / 255)
      ..setFloat(5, s.t0)
      ..setFloat(6, s.width)
      ..setFloat(7, s.spillAmount)
      ..setFloat(8, chokePx)
      ..setFloat(9, s.gain)
      ..setFloat(10, s.matte ? 1 : 0)
      ..setImageSampler(0, src);
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..shader = shader);
    final pic = rec.endRecording();
    final out = pic.toImageSync(w, h);
    pic.dispose();
    return out;
  }

  static ui.FragmentShader? newShader() => gpuReady ? _program!.fragmentShader() : null;

  /// CPU keying of [src] (async: read back → isolate → upload).
  static Future<ui.Image?> cpuKey(ui.Image src, ChromaSettings s, double chokePx) {
    final c = Completer<ui.Image?>();
    _track(() async {
      try {
        final w = src.width, h = src.height;
        final bd = await src.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
        src.dispose();
        if (bd == null) {
          c.complete(null);
          return;
        }
        final bytes = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
        final out = w * h > 160000 ? await _keyInIsolate(bytes, w, h, s, chokePx) : ChromaMath.key(bytes, w, h, s, chokePx: chokePx);
        final img = Completer<ui.Image>();
        ui.decodeImageFromPixels(out, w, h, ui.PixelFormat.rgba8888, img.complete);
        c.complete(await img.future);
      } catch (e) {
        debugPrint('chroma_key CPU keyer failed: $e');
        if (!c.isCompleted) c.complete(null);
      }
    }());
    return c.future;
  }

  /// Auto key colour from straight RGBA pixels (border sampling), in an
  /// isolate for big frames. Null when no green/blue screen is found.
  static Future<List<int>?> detect(Uint8List rgba, int w, int h) =>
      w * h > 160000 ? Isolate.run(() => ChromaMath.detectKeyColor(rgba, w, h)) : Future.value(ChromaMath.detectKeyColor(rgba, w, h));

  // Only plain values are captured (a ui.Image in the closure context
  // could not be sent to the isolate).
  static Future<Uint8List> _keyInIsolate(Uint8List bytes, int w, int h, ChromaSettings s, double chokePx) =>
      Isolate.run(() => ChromaMath.key(bytes, w, h, s, chokePx: chokePx));
}

/// Draws [source] keyed with [settings], stretched to its box.
/// [chokeScale] = source pixels per layer pixel (choke is in layer pixels).
class ChromaKeyedImage extends LeafRenderObjectWidget {
  final ui.Image? source;
  final ChromaSettings settings;
  final double chokeScale;
  final FilterQuality filterQuality;

  const ChromaKeyedImage({
    super.key,
    required this.source,
    required this.settings,
    this.chokeScale = 1,
    this.filterQuality = FilterQuality.medium,
  });

  @override
  RenderChromaKeyedImage createRenderObject(BuildContext context) =>
      RenderChromaKeyedImage()..update(source, settings, chokeScale, filterQuality);

  @override
  void updateRenderObject(BuildContext context, RenderChromaKeyedImage renderObject) =>
      renderObject.update(source, settings, chokeScale, filterQuality);
}

class RenderChromaKeyedImage extends RenderBox {
  ui.Image? _src;
  int _srcVersion = 0;
  ChromaSettings _settings = const ChromaSettings();
  double _chokeScale = 1;
  FilterQuality _fq = FilterQuality.medium;

  ui.FragmentShader? _shader;
  ui.Image? _keyed;
  Object? _keyedSig; // (srcVersion, settings, chokeScale) of [_keyed]
  Object? _jobSig; // CPU job in flight
  bool _disposed = false;

  void update(ui.Image? src, ChromaSettings s, double chokeScale, FilterQuality fq) {
    final same = (src == null && _src == null) || (src != null && _src != null && src.isCloneOf(_src!));
    if (!same) {
      _src?.dispose();
      _src = src?.clone();
      _srcVersion++;
    }
    if (!same || s != _settings || chokeScale != _chokeScale || fq != _fq) {
      _settings = s;
      _chokeScale = chokeScale;
      _fq = fq;
      markNeedsPaint();
    }
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest.isFinite ? constraints.biggest : constraints.smallest;

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void dispose() {
    _disposed = true;
    _src?.dispose();
    _src = null;
    _keyed?.dispose();
    _keyed = null;
    _shader?.dispose();
    _shader = null;
    super.dispose();
  }

  Object get _sig => (_srcVersion, _settings, _chokeScale);

  void _setKeyed(ui.Image? img, Object sig) {
    _keyed?.dispose();
    _keyed = img;
    _keyedSig = sig;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final src = _src;
    if (src == null) return;
    final sig = _sig;
    if (_keyedSig != sig) {
      final chokePx = _settings.choke / 10 * _chokeScale;
      if (ChromaKeyer.gpuReady) {
        _shader ??= ChromaKeyer.newShader();
        _setKeyed(ChromaKeyer.gpuKey(_shader!, src, _settings, chokePx), sig);
      } else if (ChromaKeyer.gpuFailed) {
        if (_jobSig != sig) {
          _jobSig = sig;
          ChromaKeyer.cpuKey(src.clone(), _settings, chokePx).then((img) {
            if (_disposed || _jobSig != sig) {
              img?.dispose();
              return;
            }
            _jobSig = null;
            _setKeyed(img, sig);
            markNeedsPaint();
          });
        }
      } else {
        ChromaKeyer.ensureLoaded(() {
          if (!_disposed && attached) markNeedsPaint();
        });
      }
    }
    // Never show the un-keyed picture: draw the newest keyed result (it may
    // be one update behind while the CPU keyer works), or nothing.
    final k = _keyed;
    if (k == null) return;
    context.canvas.drawImageRect(
      k,
      Rect.fromLTWH(0, 0, k.width.toDouble(), k.height.toDouble()),
      offset & size,
      Paint()..filterQuality = _fq,
    );
  }
}

/// Content of an image or video layer with a `chroma_key` effect.
class ChromaSource extends StatefulWidget {
  final Layer layer;
  final Project project;
  final double time;
  final ChromaSettings settings;

  /// Exact frame for this moment (export); live preview fetches its own.
  final ui.Image? frame;
  final bool draft;
  final bool playing;

  const ChromaSource({
    super.key,
    required this.layer,
    required this.project,
    required this.time,
    required this.settings,
    this.frame,
    this.draft = false,
    this.playing = false,
  });

  /// Longest side of preview frames while paused / while playing.
  static const pausedSize = 1280, playingSize = 640;

  @override
  State<ChromaSource> createState() => _ChromaSourceState();
}

class _ChromaSourceState extends State<ChromaSource> {
  // Image layers.
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ui.Image? _image;

  // Live video frames.
  ui.Image? _frame;
  bool _busy = false;
  (double, int)? _want; // (source time, max size) to fetch next
  (double, int)? _have; // what [_frame] shows / is being fetched

  bool _syncing = false;

  Layer get l => widget.layer;
  MediaAsset? get _asset => widget.project.media[l.mediaId];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ChromaSource old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _unlisten();
    _image?.dispose();
    _frame?.dispose();
    super.dispose();
  }

  void _sync() {
    _syncing = true;
    try {
      if (l.type == LayerType.image) {
        _resolveImage();
      } else if (l.type == LayerType.video && widget.frame == null) {
        _requestFrame();
      }
    } finally {
      _syncing = false;
    }
  }

  // ------------------------------------------------------------- images

  ImageProvider? _provider() {
    final a = _asset;
    if (a == null) return null;
    // Same key as LayerView's Image.file (cacheWidth) and export precache.
    final cw = math.min(l.width.round(), widget.draft ? 1280 : 2560);
    return ResizeImage(FileImage(File(a.path)), width: math.max(1, cw));
  }

  void _resolveImage() {
    final p = _provider();
    if (p == null) return;
    final stream = p.resolve(createLocalImageConfiguration(context));
    if (_stream?.key == stream.key && _stream?.key != null) return;
    _unlisten();
    _stream = stream;
    _listener = ImageStreamListener((info, _) {
      if (!mounted) {
        info.dispose();
        return;
      }
      void swap() {
        _image?.dispose();
        _image = info.image.clone();
      }

      // Cached images arrive synchronously while updating: no setState then.
      if (_syncing) {
        swap();
      } else {
        setState(swap);
      }
      info.dispose();
    }, onError: (e, _) => debugPrint('chroma_key image: $e'));
    stream.addListener(_listener!);
  }

  void _unlisten() {
    final s = _stream, li = _listener;
    if (s != null && li != null) s.removeListener(li);
    _stream = null;
    _listener = null;
  }

  // -------------------------------------------------------- live video

  void _requestFrame() {
    final a = _asset;
    if (a == null) return;
    final t = l.sourceTimeAt(widget.time).clamp(0.0, math.max(0.0, a.duration)).toDouble();
    final size = widget.draft && widget.playing ? ChromaSource.playingSize : ChromaSource.pausedSize;
    // Frames closer than ~1/60 s are the same picture.
    final want = ((t * 60).round() / 60, size);
    if (want == _have || want == _want) return;
    _want = want;
    if (!_busy) _fetchNext();
  }

  Future<void> _fetchNext() async {
    final want = _want, a = _asset;
    if (want == null || a == null || !mounted) return;
    _want = null;
    _busy = true;
    _have = want;
    try {
      final (t, size) = want;
      final playing = size == ChromaSource.playingSize;
      final f = playing
          ? await MediaBridge.readerFrame('chroma:${l.id}', a.path, t, maxSize: size)
          : await MediaBridge.frameAt(a.path, t, maxSize: size);
      if (f != null && mounted) {
        final c = Completer<ui.Image>();
        ui.decodeImageFromPixels(f.$3, f.$1, f.$2, ui.PixelFormat.rgba8888, c.complete);
        final img = await c.future;
        if (mounted) {
          setState(() {
            _frame?.dispose();
            _frame = img;
          });
        } else {
          img.dispose();
        }
      }
    } catch (e) {
      // No platform decoder (tests) or a decode error: keep the last frame.
      if (kDebugMode) debugPrint('chroma_key frame: $e');
    } finally {
      _busy = false;
    }
    if (_want != null && mounted) _fetchNext();
  }

  @override
  Widget build(BuildContext context) {
    final src = l.type == LayerType.image ? _image : (widget.frame ?? _frame);
    return ChromaKeyedImage(
      source: src,
      settings: widget.settings,
      chokeScale: src == null || l.width <= 0 ? 1 : src.width / l.width,
      filterQuality: widget.draft && widget.playing ? FilterQuality.low : FilterQuality.medium,
    );
  }
}

/// Keys a snapshot of [child] on the GPU (text, shapes, comps). Paints the
/// child unchanged when the shader is unavailable or the child holds a live
/// video texture (cannot be read back).
class ChromaSnapshot extends SingleChildRenderObjectWidget {
  final ChromaSettings settings;
  final double maxSide;
  const ChromaSnapshot({super.key, required this.settings, this.maxSide = 2048, super.child});

  @override
  RenderChromaSnapshot createRenderObject(BuildContext context) => RenderChromaSnapshot(settings, maxSide);

  @override
  void updateRenderObject(BuildContext context, RenderChromaSnapshot renderObject) {
    renderObject
      ..settings = settings
      ..maxSide = maxSide;
  }
}

class RenderChromaSnapshot extends RenderProxyBox {
  RenderChromaSnapshot(this._settings, this._maxSide);

  ChromaSettings _settings;
  set settings(ChromaSettings v) {
    if (v == _settings) return;
    _settings = v;
    markNeedsPaint();
  }

  double _maxSide;
  set maxSide(double v) {
    if (v == _maxSide) return;
    _maxSide = v;
    markNeedsPaint();
  }

  final LayerHandle<OffsetLayer> _holder = LayerHandle<OffsetLayer>(OffsetLayer());
  ui.FragmentShader? _shader;
  ui.Image? _snap, _keyed;

  @override
  void dispose() {
    _snap?.dispose();
    _keyed?.dispose();
    _shader?.dispose();
    _holder.layer = null;
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (!ChromaKeyer.gpuReady || texturesIn(child).isNotEmpty) {
      if (!ChromaKeyer.gpuFailed) {
        ChromaKeyer.ensureLoaded(() {
          if (attached) markNeedsPaint();
        });
      }
      context.paintChild(child, offset);
      return;
    }
    final ratio = snapshotRatio(size, _maxSide);
    final img = paintChildToImage(_holder.layer!, child, size, ratio);
    if (img == null) return;
    _snap?.dispose();
    _snap = img;
    _shader ??= ChromaKeyer.newShader();
    final keyed = ChromaKeyer.gpuKey(_shader!, img, _settings, _settings.choke / 10 * ratio);
    _keyed?.dispose();
    _keyed = keyed;
    if (keyed == null) return;
    context.canvas.drawImageRect(keyed, Rect.fromLTWH(0, 0, keyed.width.toDouble(), keyed.height.toDouble()), offset & size,
        Paint()..filterQuality = FilterQuality.medium);
  }
}
