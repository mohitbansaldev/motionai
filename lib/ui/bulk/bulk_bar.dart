// BULK (Agent N): selection count chip + bulk action strip (PC) / phone bar.
import 'package:flutter/material.dart';

import '../../state/editor_controller.dart';
import '../theme.dart';
import 'bulk_actions.dart';
import 'bulk_menu.dart';

/// Selection chip: "3 selected ✕".
class SelectionChip extends StatelessWidget {
  final EditorController c;
  const SelectionChip({super.key, required this.c});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(10, 3, 4, 3),
        decoration: BoxDecoration(color: MA.accent.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.select_all, size: 15, color: MA.accent2),
          const SizedBox(width: 6),
          Text('${c.selectionCount} selected', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          InkWell(
            onTap: c.clearSelection,
            borderRadius: BorderRadius.circular(12),
            child: const Padding(padding: EdgeInsets.all(3), child: Icon(Icons.close, size: 15, color: MA.textDim)),
          ),
        ]),
      );
}

/// PC: a strip above the timeline while two or more layers are selected.
class BulkBar extends StatelessWidget {
  final EditorController c;
  const BulkBar({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (!c.hasMultiSelection) return const SizedBox.shrink();
        final a = BulkActions(c);
        final layers = a.layers;
        void act(String? Function() f) => bulkReport(context, f());
        Widget b(IconData icon, String tip, VoidCallback onTap, {Color? color}) => IconButton(
              tooltip: tip,
              iconSize: 19,
              visualDensity: VisualDensity.compact,
              icon: Icon(icon, color: color),
              onPressed: onTap,
            );
        const gap = SizedBox(width: 6, height: 20, child: VerticalDivider(width: 6, color: MA.stroke));
        final any2d = layers.any((l) => !l.is3D);
        return Container(
          height: 40,
          margin: const EdgeInsets.fromLTRB(10, 0, 10, 4),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: MA.surface2, borderRadius: BorderRadius.circular(10), border: Border.all(color: MA.stroke)),
          child: Row(children: [
            SelectionChip(c: c),
            const SizedBox(width: 6),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  b(Icons.align_horizontal_left, 'Align left', () => act(() => a.align('left'))),
                  b(Icons.align_horizontal_center, 'Align centre', () => act(() => a.align('center'))),
                  b(Icons.align_horizontal_right, 'Align right', () => act(() => a.align('right'))),
                  b(Icons.align_vertical_top, 'Align top', () => act(() => a.align('top'))),
                  b(Icons.align_vertical_center, 'Align middle', () => act(() => a.align('middle'))),
                  b(Icons.align_vertical_bottom, 'Align bottom', () => act(() => a.align('bottom'))),
                  b(Icons.horizontal_distribute, 'Distribute horizontally', () => act(() => a.distribute('horizontal'))),
                  b(Icons.vertical_distribute, 'Distribute vertically', () => act(() => a.distribute('vertical'))),
                  gap,
                  b(Icons.start, 'Start at playhead', () => act(() => a.alignTime('start'))),
                  b(Icons.stacked_line_chart, 'Stagger…', () => BulkMenu.stagger(context, c)),
                  b(Icons.view_timeline_outlined, 'One after another', () => act(() => a.alignTime('sequence'))),
                  b(Icons.content_cut, 'Split at playhead (S)', () => BulkMenu.run(context, c, 'split')),
                  gap,
                  b(Icons.view_in_ar_outlined, any2d ? 'Make 3D (Shift+3)' : 'Make 2D (Shift+3)', () => act(a.toggle3D),
                      color: any2d ? null : MA.accent2),
                  if (BulkActions.hasDepthMake3d) b(Icons.layers, 'Make 3D (keep look, depth bands)', () => act(a.make3dScene)),
                  b(Icons.workspaces_outline, 'Group into null (Ctrl+G)', () => BulkMenu.run(context, c, 'group')),
                  b(Icons.layers_outlined, 'Precompose (Ctrl+Shift+C)', () => BulkMenu.run(context, c, 'precomp')),
                  b(Icons.account_tree_outlined, 'Parent to…', () => BulkMenu.parent(context, c)),
                  gap,
                  b(layers.any((l) => l.visible) ? Icons.visibility_off_outlined : Icons.visibility_outlined, 'Hide / show',
                      () => BulkMenu.run(context, c, 'vis')),
                  b(layers.every((l) => l.locked) ? Icons.lock_open : Icons.lock_outline, 'Lock / unlock', () => BulkMenu.run(context, c, 'lock')),
                  b(Icons.copy, 'Duplicate (Ctrl+D)', () => BulkMenu.run(context, c, 'dup')),
                  b(Icons.bookmark_add_outlined, 'Save as template', () => BulkMenu.run(context, c, 'template')),
                  b(Icons.delete_outline, 'Delete (Del)', () => BulkMenu.run(context, c, 'delete'), color: Colors.redAccent),
                ]),
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.more_horiz, size: 18),
              label: const Text('More'),
              onPressed: () => BulkSheet.open(context, c),
            ),
          ]),
        );
      },
    );
  }
}

/// Phone: shown in multi-select mode (long-press a layer) or with 2+ selected.
class BulkPhoneBar extends StatelessWidget {
  final EditorController c;
  const BulkPhoneBar({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (!c.multiSelectMode && !c.hasMultiSelection) return const SizedBox.shrink();
        return Container(
          height: 44,
          margin: const EdgeInsets.fromLTRB(10, 0, 10, 4),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(color: MA.surface2, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            SelectionChip(c: c),
            const Spacer(),
            TextButton(onPressed: c.selectAll, child: const Text('All')),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.bolt, size: 18),
              label: const Text('Actions'),
              onPressed: c.selectionCount == 0 ? null : () => BulkSheet.open(context, c),
            ),
            TextButton(
              onPressed: () {
                if (c.selectionCount > 1) {
                  c.select(c.selectedLayerId);
                }
                c.setMultiSelectMode(false);
              },
              child: const Text('Done'),
            ),
          ]),
        );
      },
    );
  }
}
