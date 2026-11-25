import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/engine/precomp.dart';
import '../../core/model/layer.dart';
import '../../core/model/project.dart';
import '../../state/video_pool.dart';
import 'composition_canvas.dart';

/// The chain of comp ids being drawn (outermost first), for loop detection.
class PrecompScope extends InheritedWidget {
  final List<String> stack;
  const PrecompScope({super.key, required this.stack, required super.child});

  static List<String> stackOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PrecompScope>()?.stack ?? const [];

  @override
  bool updateShouldNotify(PrecompScope old) =>
      old.stack.length != stack.length || !Iterable.generate(stack.length).every((i) => old.stack[i] == stack[i]);
}

/// Content of a comp layer: its child comp drawn as one sub-canvas at the
/// mapped child time (with the child's own camera). The layer's effects,
/// masks, matte and 3D transform are applied around it by LayerView.
///
/// While the child time and the project are unchanged (a held / frozen
/// precomp, or the same frame repainted) the same widget is returned, so
/// Flutter skips rebuilding and the RepaintBoundary reuses its pixels.
class PrecompView extends StatefulWidget {
  final Layer layer;
  final Project project;
  final double time; // parent comp time
  final VideoPool? videos;
  final Map<String, ui.Image>? videoFrames;
  final bool draft;
  final bool playing;

  const PrecompView({
    super.key,
    required this.layer,
    required this.project,
    required this.time,
    this.videos,
    this.videoFrames,
    this.draft = false,
    this.playing = false,
  });

  @override
  State<PrecompView> createState() => _PrecompViewState();
}

class _PrecompViewState extends State<PrecompView> {
  Object? _sig;
  Widget? _built;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final l = w.layer;
    final child = Precomp.childOf(w.project, l);
    if (child == null) return _placeholder('Missing comp "${l.compId}"');
    final stack = PrecompScope.stackOf(context);
    if (stack.contains(child.id)) return _placeholder('Comp loop: "${child.name}" contains itself');
    if (stack.length >= kMaxPrecompDepth) return _placeholder('Comps nested too deep');
    final ct = Precomp.childTime(l, child, w.time);
    if (ct == null) return const SizedBox.shrink();

    final sig = Object.hash(identityHashCode(child), Precomp.revision, ct, w.draft, w.playing,
        identityHashCode(w.videoFrames), identityHashCode(w.project), l.width, l.height, stack.length);
    final cached = _built;
    // Live video players repaint on their own; don't hold on to a stale tree for them.
    final live = w.videoFrames == null && child.layers.any((x) => x.type == LayerType.video);
    if (cached != null && sig == _sig && !live) return cached;

    Widget canvas = CompositionCanvas(
      project: w.project,
      comp: child,
      nested: true,
      time: ct,
      items: Precomp.evaluateCached(child, ct),
      videos: w.videos,
      videoFrames: w.videoFrames,
      draft: w.draft,
      playing: w.playing,
    );
    if (child.width != l.width || child.height != l.height) {
      canvas = FittedBox(fit: BoxFit.fill, child: canvas);
    }
    final built = RepaintBoundary(child: SizedBox(width: l.width, height: l.height, child: canvas));
    _sig = sig;
    _built = built;
    return built;
  }

  Widget _placeholder(String msg) => ColoredBox(
        color: const Color(0x66B71C1C),
        child: Center(
          child: Text(msg,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: (widget.layer.height * 0.05).clamp(8.0, 64.0))),
        ),
      );
}
