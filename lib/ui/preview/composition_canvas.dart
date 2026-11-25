import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/engine/evaluator.dart';
import '../../core/model/project.dart';
import '../../state/video_pool.dart';
import 'fx/offscreen.dart';
import 'layer_view.dart';
import 'precomp_view.dart'; // PRECOMP (Agent L)

/// Draws a whole composition at one moment, at composition pixel size.
/// Used by the live preview and by export (with exact [videoFrames]).
class CompositionCanvas extends StatelessWidget {
  final Project project;
  final double time;
  final VideoPool? videos;
  final Map<String, ui.Image>? videoFrames;
  final List<RenderItem>? items;
  final Widget? overlay;

  const CompositionCanvas({
    super.key,
    required this.project,
    required this.time,
    this.videos,
    this.videoFrames,
    this.items,
    this.overlay,
    this.draft = false,
    this.playing = false,
    this.comp, // PRECOMP (Agent L)
    this.nested = false, // PRECOMP (Agent L)
  });

  // PRECOMP (Agent L) >>>
  /// The composition to draw (default: the project's main comp).
  final Composition? comp;

  /// Drawn inside a comp layer: no background (precomps are transparent).
  final bool nested;
  // <<< PRECOMP (Agent L)

  /// Live editor preview: decode images at screen size, cache each layer's
  /// pixels so camera moves only re-composite, and lighten depth blur.
  /// Export and Director renders keep full quality.
  final bool draft;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final comp = this.comp ?? project.main; // PRECOMP (Agent L)
    final list = items ?? Evaluator.evaluate(comp, time);
    final stack = PrecompScope.stackOf(context); // PRECOMP (Agent L)
    return PrecompScope(stack: [...stack, comp.id], child: SizedBox(
      width: comp.width,
      height: comp.height,
      child: ClipRect(
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            if (!nested) Positioned.fill(child: ColoredBox(color: Color(comp.background))), // PRECOMP (Agent L)
            for (final item in list)
              if (item.matte == null)
                _view(item, ValueKey(item.layer.id))
              else
                // Track matte: the layer shows only inside/outside the matte layer's pixels.
                Positioned.fill(
                  key: ValueKey('${item.layer.id}#matte'),
                  child: MatteComposite(
                    inverse: item.matteInverse,
                    resolution: draft ? 0.5 : 1.0,
                    matte: Stack(clipBehavior: Clip.none, children: [_view(item.matte!, null)]),
                    content: Stack(clipBehavior: Clip.none, children: [_view(item, null)]),
                  ),
                ),
            if (overlay != null) Positioned.fill(child: IgnorePointer(child: overlay!)),
          ],
        ),
      ),
    )); // PRECOMP (Agent L): PrecompScope
  }

  Widget _view(RenderItem item, Key? key) => LayerView(
        key: key,
        item: item,
        project: project,
        videos: videos,
        time: time,
        videoFrames: videoFrames,
        draft: draft,
        playing: playing,
      );
}
