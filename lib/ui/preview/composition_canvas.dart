import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/engine/evaluator.dart';
import '../../core/model/project.dart';
import '../../state/video_pool.dart';
import 'layer_view.dart';

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
  });

  @override
  Widget build(BuildContext context) {
    final comp = project.main;
    final list = items ?? Evaluator.evaluate(comp, time);
    return SizedBox(
      width: comp.width,
      height: comp.height,
      child: ClipRect(
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned.fill(child: ColoredBox(color: Color(comp.background))),
            for (final item in list)
              LayerView(
                key: ValueKey(item.layer.id),
                item: item,
                project: project,
                videos: videos,
                time: time,
                videoFrames: videoFrames,
              ),
            if (overlay != null) Positioned.fill(child: IgnorePointer(child: overlay!)),
          ],
        ),
      ),
    );
  }
}
