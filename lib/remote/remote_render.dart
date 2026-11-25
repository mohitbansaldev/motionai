// MCP (Agent P): renders a frame of the open composition for Claude,
// offscreen (an overlay entry outside the window), exactly like export:
// precached images, exact decoded video frames, full quality. Several
// frames reuse one offscreen canvas (V2-A: preview_shot).

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
import 'contact_sheet.dart';

class RemoteRenderer {
  final GlobalKey<NavigatorState> navigator;
  RemoteRenderer(this.navigator);

  Future<void> _lock = Future.value();

  /// PNG of [comp] of [p] at [time], [width] pixels wide. Calls are serialised.
  Future<Uint8List> render(Project p, Composition comp, double time, int width) async =>
      (await _serial(() => _renderMany(p, comp, [time], width, png: true))).first.$3;

  /// Raw RGBA frames of [comp] at every time in [times] (V2-A): one offscreen
  /// canvas is reused for all of them and images are precached once, so a
  /// contact sheet costs little more than one frame each.
  Future<List<RawFrame>> renderMany(Project p, Composition comp, List<double> times, int width) async => [
        for (final f in await _serial(() => _renderMany(p, comp, times, width, png: false))) RawFrame(f.$1, f.$2, f.$3),
      ];

  Future<T> _serial<T>(Future<T> Function() job) {
    final run = _lock.then((_) => job());
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<List<(int, int, Uint8List)>> _renderMany(Project p, Composition comp, List<double> times, int width, {required bool png}) async {
    if (times.isEmpty) return const [];
    final nav = navigator.currentState;
    final overlay = nav?.overlay;
    final ctx = navigator.currentContext;
    if (overlay == null || ctx == null) throw StateError('MotionAI is not ready to render yet.');
    final w = width.clamp(16, 4096);
    final h = math.max(16, (w * comp.height / comp.width).round());
    const ratio = 2.0; // logical px → image px
    final lw = w / ratio, lh = h / ratio;

    // Images at the same decode size the export uses (once for all frames).
    final layers = [...comp.layers, for (final cc in p.comps.values) ...cc.layers];
    final seen = <String>{};
    for (final l in layers) {
      if (l.type != LayerType.image) continue;
      final a = p.media[l.mediaId];
      if (a == null) continue;
      final cw = math.min(l.width.round(), 2560);
      if (!seen.add('${a.path}|$cw') || !File(a.path).existsSync()) continue;
      if (!ctx.mounted) break;
      await precacheImage(ResizeImage(FileImage(File(a.path)), width: cw), ctx);
    }

    // Exact video frames (the live players are not used).
    Future<void> grab(Map<String, ui.Image> frames, Layer l, double t) async {
      final a = p.media[l.mediaId];
      if (l.type != LayerType.video || a == null) return;
      final f = await MediaBridge.readerFrame('mcp_${l.id}', a.path, l.sourceTimeAt(t).clamp(0.0, a.duration), maxSize: math.min(1920, math.max(w, h)));
      if (f == null) return;
      final done = Completer<ui.Image>();
      ui.decodeImageFromPixels(f.$3, f.$1, f.$2, ui.PixelFormat.rgba8888, done.complete);
      frames[l.id] = await done.future;
    }

    Future<Map<String, ui.Image>> framesAt(double t) async {
      final frames = <String, ui.Image>{};
      for (final l in comp.layers) {
        if (l.isActiveAt(t)) {
          try {
            await grab(frames, l, t);
          } catch (_) {}
        }
      }
      if (comp.id == p.main.id) {
        for (final n in Precomp.nestedMedia(p, t)) {
          try {
            await grab(frames, n.layer, n.compTime);
          } catch (_) {}
        }
      }
      return frames;
    }

    Future<void> pump(int n, {bool settle = false}) async {
      for (var i = 0; i < n; i++) {
        WidgetsBinding.instance.scheduleForcedFrame();
        await WidgetsBinding.instance.endOfFrame.timeout(const Duration(seconds: 15),
            onTimeout: () => throw TimeoutException('MotionAI did not draw a frame. Is its window minimised? Restore it and try again.'));
        if (settle) await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }

    final key = GlobalKey();
    final state = ValueNotifier<(double, Map<String, ui.Image>)>((times.first, await framesAt(times.first)));
    final used = <ui.Image>[...state.value.$2.values];
    final out = <(int, int, Uint8List)>[];
    OverlayEntry? entry;
    try {
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
                child: ValueListenableBuilder<(double, Map<String, ui.Image>)>(
                  valueListenable: state,
                  builder: (_, v, _) => CompositionCanvas(project: p, comp: comp, time: v.$1, videoFrames: v.$2),
                ),
              ),
            ),
          ),
        ),
      );
      overlay.insert(entry);
      for (var i = 0; i < times.length; i++) {
        if (i > 0) {
          final f = await framesAt(times[i]);
          used.addAll(f.values);
          state.value = (times[i], f);
        }
        // First frame: layout/paint, then async-decoded images settle. Later
        // frames reuse the same tree and the decoded images.
        await pump(2, settle: i == 0);
        final ro = key.currentContext?.findRenderObject();
        if (ro is! RenderRepaintBoundary) throw StateError('Render target missing');
        final image = await ro.toImage(pixelRatio: ratio);
        try {
          final bytes = await image.toByteData(format: png ? ui.ImageByteFormat.png : ui.ImageByteFormat.rawRgba);
          if (bytes == null) throw StateError('Frame encoding failed');
          out.add((image.width, image.height, bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes)));
        } finally {
          image.dispose();
        }
      }
      return out;
    } finally {
      entry?.remove();
      // Free the video frames once the removed entry is gone from the tree.
      WidgetsBinding.instance.scheduleForcedFrame();
      unawaited(WidgetsBinding.instance.endOfFrame.timeout(const Duration(seconds: 5), onTimeout: () {}).then((_) {
        for (final f in used) {
          f.dispose();
        }
        state.dispose();
      }));
    }
  }
}
