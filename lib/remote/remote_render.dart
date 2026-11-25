// MCP (Agent P): renders a frame of the open composition for Claude,
// offscreen (an overlay entry outside the window), exactly like export:
// precached images, exact decoded video frames, full quality.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;

import '../core/engine/precomp.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../services/media_bridge.dart';
import '../ui/preview/composition_canvas.dart';

class RemoteRenderer {
  final GlobalKey<NavigatorState> navigator;
  RemoteRenderer(this.navigator);

  Future<void> _lock = Future.value();

  /// PNG of [comp] of [p] at [time], [width] pixels wide. Calls are serialised.
  Future<Uint8List> render(Project p, Composition comp, double time, int width) {
    final run = _lock.then((_) => _render(p, comp, time, width));
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<Uint8List> _render(Project p, Composition comp, double time, int width) async {
    final nav = navigator.currentState;
    final overlay = nav?.overlay;
    final ctx = navigator.currentContext;
    if (overlay == null || ctx == null) throw StateError('MotionAI is not ready to render yet.');
    final w = width.clamp(16, 4096);
    final h = math.max(16, (w * comp.height / comp.width).round());
    const ratio = 2.0; // logical px → image px
    final lw = w / ratio, lh = h / ratio;

    // Images at the same decode size the export uses.
    final layers = [...comp.layers, for (final cc in p.comps.values) ...cc.layers];
    for (final l in layers) {
      if (l.type != LayerType.image) continue;
      final a = p.media[l.mediaId];
      if (a == null || !File(a.path).existsSync()) continue;
      if (!ctx.mounted) break;
      await precacheImage(ResizeImage(FileImage(File(a.path)), width: math.min(l.width.round(), 2560)), ctx);
    }

    // Exact video frames (the live players are not used).
    final frames = <String, ui.Image>{};
    Future<void> grab(Layer l, double t) async {
      final a = p.media[l.mediaId];
      if (l.type != LayerType.video || a == null) return;
      final f = await MediaBridge.readerFrame('mcp_${l.id}', a.path, l.sourceTimeAt(t).clamp(0.0, a.duration), maxSize: math.min(1920, math.max(w, h)));
      if (f == null) return;
      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(f.$3, f.$1, f.$2, ui.PixelFormat.rgba8888, done.complete);
      frames[l.id] = await done.future;
    }

    final key = GlobalKey();
    OverlayEntry? entry;
    try {
      for (final l in comp.layers) {
        if (l.isActiveAt(time)) {
          try {
            await grab(l, time);
          } catch (_) {}
        }
      }
      if (comp.id == p.main.id) {
        for (final n in Precomp.nestedMedia(p, time)) {
          try {
            await grab(n.layer, n.compTime);
          } catch (_) {}
        }
      }
      entry = OverlayEntry(
        builder: (_) => Positioned(
          left: -(lw + 4000),
          top: 0,
          width: lw,
          height: lh,
          child: IgnorePointer(
            child: RepaintBoundary(
              key: key,
              child: FittedBox(
                fit: BoxFit.fill,
                child: CompositionCanvas(project: p, comp: comp, time: time, videoFrames: frames),
              ),
            ),
          ),
        ),
      );
      overlay.insert(entry);
      // Two frames: layout/paint, then async-decoded images settle.
      for (var i = 0; i < 2; i++) {
        WidgetsBinding.instance.scheduleForcedFrame();
        await WidgetsBinding.instance.endOfFrame.timeout(const Duration(seconds: 15),
            onTimeout: () => throw TimeoutException('MotionAI did not draw a frame. Is its window minimised? Restore it and try again.'));
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      final ro = key.currentContext?.findRenderObject();
      if (ro is! RenderRepaintBoundary) throw StateError('Render target missing');
      final image = await ro.toImage(pixelRatio: ratio);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (png == null) throw StateError('PNG encoding failed');
      return png.buffer.asUint8List();
    } finally {
      entry?.remove();
      // Free the video frames once the removed entry is gone from the tree.
      final old = frames.values.toList();
      WidgetsBinding.instance.scheduleForcedFrame();
      unawaited(WidgetsBinding.instance.endOfFrame.timeout(const Duration(seconds: 5), onTimeout: () {}).then((_) {
        for (final f in old) {
          f.dispose();
        }
      }));
    }
  }
}
