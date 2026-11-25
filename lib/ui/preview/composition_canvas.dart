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
    this.previewScale, // PERF (Agent O)
  });

  /// Live editor preview only: screen pixels per composition pixel (view
  /// scale × device pixel ratio × preview quality). Enables image caching of
  /// static 3D layers and on-screen-size photo decoding (see [LayerView]).
  final double? previewScale; // PERF (Agent O)

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
    final children = <Widget>[
      if (!nested) Positioned.fill(child: ColoredBox(color: Color(comp.background))), // PRECOMP (Agent L): precomps are transparent
    ];
    for (int i = 0; i < list.length; i++) {
      final item = list[i];
      // V2-D >>> adjustment layer: its effects act on everything painted so far
      if (item.layer.adjustment) {
        if (children.isNotEmpty) {
          final below = Stack(clipBehavior: Clip.none, children: List.of(children));
          children
            ..clear()
            ..add(Positioned.fill(
                key: ValueKey('${item.layer.id}#adjust'),
                child: _layerView(item, null).buildAdjustment(below, comp.width, comp.height)));
        }
        continue;
      }
      // <<< V2-D
      final matte = item.matte;
      if (matte == null) {
        children.add(_view(item, ValueKey(item.layer.id)));
        continue;
      }
      // Track matte: the layer shows only inside/outside the matte layer's
      // pixels. Neighbours in paint order that use the same matte share one
      // compositor, so the matte is rendered once (e.g. scanner targets).
      final group = [item];
      while (i + 1 < list.length) {
        final next = list[i + 1];
        if (next.matte?.layer.id != matte.layer.id || next.matteInverse != item.matteInverse) break;
        group.add(next);
        i++;
      }
      children.add(Positioned.fill(
        key: ValueKey('${item.layer.id}#matte'),
        child: MatteComposite(
          inverse: item.matteInverse,
          resolution: draft ? 0.5 : 1.0,
          matte: Stack(clipBehavior: Clip.none, children: [_view(matte, null, asMatte: true)]),
          content: Stack(clipBehavior: Clip.none, children: [for (final g in group) _view(g, ValueKey(g.layer.id))]),
        ),
      ));
    }
    if (overlay != null) children.add(Positioned.fill(child: IgnorePointer(child: overlay!)));
    final stack = PrecompScope.stackOf(context); // PRECOMP (Agent L)
    final Widget canvas = PrecompScope(stack: [...stack, comp.id], child: SizedBox(
      width: comp.width,
      height: comp.height,
      child: ClipRect(
        child: Stack(clipBehavior: Clip.hardEdge, children: children),
      ),
    )); // PRECOMP (Agent L): PrecompScope
    // PERF (Agent O): the live preview repaints every frame; keep that from
    // repainting the editor around it (draft only: export is unchanged).
    return draft ? RepaintBoundary(child: canvas) : canvas;
  }

  Widget _view(RenderItem item, Key? key, {bool asMatte = false}) => _layerView(item, key, asMatte: asMatte); // V2-D

  LayerView _layerView(RenderItem item, Key? key, {bool asMatte = false}) => LayerView(
        key: key,
        item: item,
        project: project,
        videos: videos,
        time: time,
        videoFrames: videoFrames,
        draft: draft,
        playing: playing,
        asMatte: asMatte,
        previewScale: previewScale, // PERF (Agent O)
      );
}
