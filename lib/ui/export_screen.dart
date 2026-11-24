import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:path_provider/path_provider.dart';

import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../services/media_bridge.dart';
import 'common.dart';
import 'preview/composition_canvas.dart';

/// Renders the composition frame by frame and encodes an MP4 on the phone.
class ExportScreen extends StatefulWidget {
  final Project project;
  const ExportScreen({super.key, required this.project});

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

enum _Phase { setup, rendering, finishing, done, failed }

class _ExportScreenState extends State<ExportScreen> {
  final _boundary = GlobalKey();
  int _shortSide = 1080;
  bool _high = true;
  _Phase _phase = _Phase.setup;
  int _frame = 0;
  int _frames = 1;
  double _time = 0;
  Map<String, ui.Image> _videoFrames = {};
  bool _cancel = false;
  String? _result; // gallery uri or path
  String? _error;
  final _sw = Stopwatch();

  Project get p => widget.project;
  Composition get comp => p.main;

  /// Output size: multiple of 8, aspect of the composition.
  (int, int) _outSize() {
    final short = math.min(comp.width, comp.height);
    final scale = _shortSide / short;
    int even8(double v) => math.max(8, (v / 8).round() * 8);
    return (even8(comp.width * scale), even8(comp.height * scale));
  }

  Future<void> _precacheImages() async {
    for (final l in comp.layers) {
      if (l.type != LayerType.image) continue;
      final a = p.media[l.mediaId];
      if (a == null) continue;
      final provider = ResizeImage(FileImage(File(a.path)), width: math.min(l.width.round(), 2560));
      await precacheImage(provider, context);
    }
  }

  Future<ui.Image> _decode((int, int, Uint8List) f) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(f.$3, f.$1, f.$2, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  Future<void> _run() async {
    final (w, h) = _outSize();
    final fps = comp.fps;
    final duration = comp.duration;
    _frames = math.max(1, (duration * fps).floor());
    final dir = await getTemporaryDirectory();
    final tmp = '${dir.path}/export_video.mp4';
    final finalPath = '${dir.path}/MotionAI_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final bitrate = (w * h * fps * (_high ? 0.2 : 0.1)).round();

    setState(() {
      _phase = _Phase.rendering;
      _frame = 0;
      _cancel = false;
    });
    _sw
      ..reset()
      ..start();
    try {
      if (!mounted) return;
      await _precacheImages();
      await MediaBridge.encoderStart(outPath: tmp, width: w, height: h, fps: fps, bitrate: bitrate);
      for (int i = 0; i < _frames; i++) {
        if (_cancel) throw _Cancelled();
        final t = i / fps;
        // Exact video frames for active video layers.
        final frames = <String, ui.Image>{};
        for (final l in comp.layers) {
          if (l.type != LayerType.video || !l.isActiveAt(t)) continue;
          final a = p.media[l.mediaId];
          if (a == null) continue;
          final f = await MediaBridge.readerFrame(l.id, a.path, l.sourceTimeAt(t).clamp(0.0, a.duration),
              maxSize: math.min(2560, math.max(w, h)));
          if (f != null) frames[l.id] = await _decode(f);
        }
        final old = _videoFrames;
        setState(() {
          _time = t;
          _videoFrames = frames;
          _frame = i;
        });
        await WidgetsBinding.instance.endOfFrame;
        for (final img in old.values) {
          img.dispose();
        }
        final boundary = _boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 4);
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final iw = image.width, ih = image.height;
        image.dispose();
        if (iw != w || ih != h) throw StateError('Rendered ${iw}x$ih, expected ${w}x$h');
        await MediaBridge.encoderFrame(data!.buffer.asUint8List(), w, h);
      }
      setState(() => _phase = _Phase.finishing);
      final audio = <Map<String, dynamic>>[
        for (final l in comp.layers)
          if ((l.type == LayerType.video || l.type == LayerType.audio) && l.visible && p.media[l.mediaId] != null)
            {
              'path': p.media[l.mediaId]!.path,
              'start': l.start,
              'sourceIn': l.sourceIn,
              'duration': math.min(l.duration, duration - l.start),
              'speed': l.speed,
              'volume': l.prop(Props.volume).valueAt(l.start + l.duration / 2)[0] / 100,
              if (l.prop(Props.volume).isAnimated) 'envelope': _envelope(l, duration),
            },
      ];
      await MediaBridge.encoderFinish(finalPath: finalPath, duration: duration, audio: audio);
      await MediaBridge.readerReleaseAll();
      final name = '${p.name.replaceAll(RegExp(r'[^\w\- ]'), '')}_${DateTime.now().millisecondsSinceEpoch}.mp4';
      _result = await MediaBridge.saveToGallery(finalPath, name);
      File(finalPath).delete().ignore();
      setState(() => _phase = _Phase.done);
    } on _Cancelled {
      await MediaBridge.encoderCancel();
      await MediaBridge.readerReleaseAll();
      if (mounted) setState(() => _phase = _Phase.setup);
    } catch (e) {
      await MediaBridge.encoderCancel().catchError((_) {});
      await MediaBridge.readerReleaseAll().catchError((_) {});
      if (mounted) {
        setState(() {
          _phase = _Phase.failed;
          _error = '$e';
        });
      }
    } finally {
      _sw.stop();
      for (final img in _videoFrames.values) {
        img.dispose();
      }
      _videoFrames = {};
    }
  }

  /// Volume keyframes → (time, gain) points for the audio mixer.
  static List<List<double>> _envelope(Layer l, double duration) {
    final v = l.prop(Props.volume);
    final end = math.min(l.start + l.duration, duration);
    final pts = <List<double>>[];
    for (var t = l.start; t < end; t += 0.1) {
      pts.add([t, v.scalarAt(t) / 100]);
    }
    pts.add([end, v.scalarAt(end) / 100]);
    return pts;
  }

  @override
  Widget build(BuildContext context) {
    final (w, h) = _outSize();
    final logicalW = w / 4, logicalH = h / 4;
    final busy = _phase == _Phase.rendering || _phase == _Phase.finishing;
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Export video')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // The render target. Shown scaled to fit; captured at full size.
            Expanded(
              child: Center(
                child: FittedBox(
                  child: RepaintBoundary(
                    key: _boundary,
                    child: SizedBox(
                      width: logicalW,
                      height: logicalH,
                      child: FittedBox(
                        fit: BoxFit.fill,
                        child: CompositionCanvas(project: p, time: _time, videoFrames: _videoFrames),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_phase == _Phase.setup) ..._setup(w, h),
            if (busy) ..._progress(),
            if (_phase == _Phase.done) ..._done(),
            if (_phase == _Phase.failed) ...[
              Text('Export failed: $_error', style: const TextStyle(color: Colors.redAccent)),
              const SizedBox(height: 8),
              FilledButton(onPressed: () => setState(() => _phase = _Phase.setup), child: const Text('Back')),
            ],
          ]),
        ),
      ),
    );
  }

  List<Widget> _setup(int w, int h) => [
        const Text('Resolution', style: TextStyle(color: Colors.white70)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, children: [
          for (final r in [720, 1080, 2160])
            ChoiceChip(
              label: Text(r == 2160 ? '4K' : '${r}p'),
              selected: _shortSide == r,
              onSelected: (_) => setState(() => _shortSide = r),
            ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          const Expanded(child: Text('High quality (bigger file)', style: TextStyle(color: Colors.white70))),
          Switch(value: _high, onChanged: (v) => setState(() => _high = v)),
        ]),
        Text('$w × $h · ${comp.fps.round()} fps · ${formatTime(comp.duration, comp.fps)}',
            style: const TextStyle(color: Colors.white54, fontSize: 12.5)),
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: _run, icon: const Icon(Icons.movie_creation), label: const Text('Export MP4')),
      ];

  List<Widget> _progress() {
    final frac = _phase == _Phase.finishing ? 1.0 : (_frame + 1) / _frames;
    final elapsed = _sw.elapsedMilliseconds / 1000;
    final eta = frac > 0.02 ? elapsed / frac - elapsed : null;
    return [
      LinearProgressIndicator(value: _phase == _Phase.finishing ? null : frac),
      const SizedBox(height: 8),
      Text(
        _phase == _Phase.finishing
            ? 'Mixing audio and saving…'
            : 'Frame ${_frame + 1} / $_frames${eta == null ? '' : ' · about ${eta.round()} s left'}',
        style: const TextStyle(color: Colors.white70),
      ),
      const SizedBox(height: 4),
      const Text('Keep the app open while exporting.', style: TextStyle(color: Colors.white38, fontSize: 12)),
      if (_phase == _Phase.rendering)
        TextButton(onPressed: () => _cancel = true, child: const Text('Cancel')),
    ];
  }

  List<Widget> _done() => [
        const Row(children: [
          Icon(Icons.check_circle, color: Colors.greenAccent),
          SizedBox(width: 8),
          Expanded(child: Text('Saved to your Gallery (Movies/MotionAI)')),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          if (_result != null && _result!.startsWith('content://'))
            Expanded(
              child: FilledButton.icon(
                onPressed: () => MediaBridge.share(_result!),
                icon: const Icon(Icons.share),
                label: const Text('Share'),
              ),
            ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Back to editor')),
          ),
        ]),
      ];
}

class _Cancelled implements Exception {}
