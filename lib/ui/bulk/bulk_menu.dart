// BULK (Agent N): multi-layer right-click menu, the bulk action sheet and dialogs.
import 'package:flutter/material.dart';

import '../../captions/styles.dart';
import '../../core/model/layer.dart';
import '../../core/presets/motion_presets.dart';
import '../../state/editor_controller.dart';
import '../common.dart';
import '../library/save_template_dialog.dart';
import '../theme.dart';
import 'bulk_actions.dart';

/// Shows [err] (if any) as a snack bar.
void bulkReport(BuildContext context, String? err) {
  if (err != null && context.mounted) showSnack(context, err);
}

class BulkMenu {
  /// Right-click menu when several layers are selected.
  static Future<void> show(BuildContext context, EditorController c, Offset global) async {
    final a = BulkActions(c);
    final n = c.selectionCount;
    final layers = a.layers;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final pos = RelativeRect.fromRect(global & const Size(1, 1), Offset.zero & overlay.size);
    PopupMenuItem<String> item(String v, IconData icon, String label, [String? keys, Color? color]) => PopupMenuItem(
          value: v,
          height: 34,
          child: Row(children: [
            Icon(icon, size: 18, color: color ?? MA.textDim),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: TextStyle(fontSize: 13, color: color))),
            if (keys != null) Text(keys, style: const TextStyle(fontSize: 11.5, color: MA.textDim)),
          ]),
        );
    final any2d = layers.any((l) => l.type != LayerType.audio && !l.is3D);
    final anyVisible = layers.any((l) => l.visible);
    final allLocked = layers.every((l) => l.locked);
    final v = await showMenu<String>(
      context: context,
      position: pos,
      color: MA.surface2,
      items: [
        PopupMenuItem(enabled: false, height: 30, child: Text('$n layers selected', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5))),
        item('split', Icons.content_cut, 'Split at playhead', 'S'),
        item('dup', Icons.copy, 'Duplicate', 'Ctrl+D'),
        item('copy', Icons.content_copy, 'Copy', 'Ctrl+C'),
        item('cut', Icons.content_cut_outlined, 'Cut', 'Ctrl+X'),
        item('paste', Icons.content_paste, 'Paste', 'Ctrl+V'),
        const PopupMenuDivider(),
        item('group', Icons.workspaces_outline, 'Group into a null parent', 'Ctrl+G'),
        item('precomp', Icons.layers_outlined, 'Precompose…', 'Ctrl+Shift+C'),
        item('3d', Icons.view_in_ar_outlined, any2d ? 'Make 3D' : 'Make 2D', 'Shift+3'),
        item('vis', anyVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined, anyVisible ? 'Hide' : 'Show'),
        item('lock', allLocked ? Icons.lock_open : Icons.lock_outline, allLocked ? 'Unlock' : 'Lock'),
        item('up', Icons.arrow_upward, 'Bring forward'),
        item('down', Icons.arrow_downward, 'Send backward'),
        item('more', Icons.tune_rounded, 'Align, time, effects, styles…'),
        item('template', Icons.bookmark_add_outlined, 'Save as template…'),
        item('library', Icons.collections_bookmark_outlined, 'Add media to library'),
        const PopupMenuDivider(),
        item('delete', Icons.delete_outline, 'Delete', 'Del', Colors.redAccent),
      ],
    );
    if (v == null || !context.mounted) return;
    await run(context, c, v);
  }

  /// Runs a named bulk action (shared by the menu, the bar and shortcuts).
  static Future<void> run(BuildContext context, EditorController c, String action) async {
    final a = BulkActions(c);
    String? err;
    switch (action) {
      case 'split':
        err = a.splitAtPlayhead();
      case 'dup':
        err = a.duplicate();
      case 'copy':
        err = await a.copyLayers();
        if (err == null && context.mounted) showSnack(context, 'Copied ${a.ids.length} layer${a.ids.length == 1 ? '' : 's'}');
      case 'cut':
        err = await a.cutLayers();
      case 'paste':
        err = await a.pasteLayers();
      case 'group':
        err = a.group();
      case 'precomp':
        err = a.precompose();
      case '3d':
        err = a.toggle3D();
      case 'vis':
        err = a.toggleVisible();
      case 'lock':
        err = a.toggleLocked();
      case 'up':
        err = a.reorder(true);
      case 'down':
        err = a.reorder(false);
      case 'more':
        await BulkSheet.open(context, c);
      case 'template':
        await SaveTemplateDialog.open(context, c, layers: a.ids.toSet());
      case 'library':
        final msg = await a.addMediaToLibrary();
        if (context.mounted) showSnack(context, msg);
      case 'delete':
        err = a.delete();
    }
    if (context.mounted) bulkReport(context, err);
  }

  // ------------------------------------------------------------- dialogs

  /// Stagger: ask for the step (seconds or frames).
  static Future<void> stagger(BuildContext context, EditorController c) async {
    final ctl = TextEditingController(text: '0.2');
    var frames = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Stagger start times'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Top layer first, each next layer starts later by:', style: TextStyle(fontSize: 12.5, color: MA.textDim)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextField(controller: ctl, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true))),
              const SizedBox(width: 8),
              SegmentedButton<bool>(
                segments: const [ButtonSegment(value: false, label: Text('sec')), ButtonSegment(value: true, label: Text('frames'))],
                selected: {frames},
                onSelectionChanged: (s) => setD(() {
                  frames = s.first;
                  ctl.text = frames ? '6' : '0.2';
                }),
              ),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Stagger')),
          ],
        ),
      ),
    );
    final v = double.tryParse(ctl.text.trim());
    if (ok != true || v == null || !context.mounted) return;
    bulkReport(context, BulkActions(c).alignTime('stagger', step: frames ? null : v, frames: frames ? v : null));
  }

  /// Picks a layer (for parent / track matte). Returns '' for "none".
  static Future<String?> pickLayer(BuildContext context, EditorController c, String title, {bool Function(Layer)? where}) {
    final sel = c.selectedLayerIds.toSet();
    final options = [for (final l in c.comp.layers) if (!sel.contains(l.id) && (where?.call(l) ?? true)) l];
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(title: Text(title), children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, ''), child: const Text('None')),
        for (final l in options)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, l.id),
            child: Row(children: [
              Icon(layerIcon(l.type), size: 16, color: layerColor(l.type)),
              const SizedBox(width: 8),
              Expanded(child: Text(l.name, overflow: TextOverflow.ellipsis)),
            ]),
          ),
      ]),
    );
  }

  static Future<void> parent(BuildContext context, EditorController c) async {
    final id = await pickLayer(context, c, 'Parent the selection to');
    if (id == null || !context.mounted) return;
    bulkReport(context, BulkActions(c).parentTo(id.isEmpty ? null : id));
  }

  static Future<void> matte(BuildContext context, EditorController c, {bool inverse = false}) async {
    final id = await pickLayer(context, c, 'Track matte (show only inside)',
        where: (l) => l.type != LayerType.audio && l.type != LayerType.nullObject);
    if (id == null || !context.mounted) return;
    bulkReport(context, BulkActions(c).setMatte(id.isEmpty ? null : id, mode: inverse ? 'inverse' : 'alpha'));
  }

  static const blendModes = ['normal', 'multiply', 'screen', 'overlay', 'add', 'darken', 'lighten'];

  static Future<void> captionStyle(BuildContext context, EditorController c) async {
    final id = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(title: const Text('Caption style'), children: [
        for (final s in CaptionStyles.all) SimpleDialogOption(onPressed: () => Navigator.pop(ctx, s.id), child: Text(s.label)),
      ]),
    );
    if (id == null || !context.mounted) return;
    bulkReport(context, BulkActions(c).applyCaptionStyle(id));
  }
}

/// Every bulk action, grouped (phone bottom sheet; "More" on PC).
class BulkSheet extends StatelessWidget {
  final EditorController c;
  const BulkSheet({super.key, required this.c});

  static Future<void> open(BuildContext context, EditorController c) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (ctx) => SizedBox(height: MediaQuery.sizeOf(ctx).height * 0.72, child: BulkSheet(c: c)),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final a = BulkActions(c);
        final layers = a.layers;
        Widget btn(IconData icon, String label, VoidCallback onTap) => ActionChip(
              avatar: Icon(icon, size: 16),
              label: Text(label, style: const TextStyle(fontSize: 12)),
              onPressed: onTap,
            );
        void act(String? Function() f) => bulkReport(context, f());
        Future<void> named(String action) => BulkMenu.run(context, c, action);
        final hasText = layers.any((l) => l.type == LayerType.text);
        final hasMedia = layers.any((l) => l.type == LayerType.image || l.type == LayerType.video);
        return ListView(padding: const EdgeInsets.fromLTRB(14, 8, 14, 24), children: [
          Row(children: [
            Expanded(
              child: Text('${layers.length} layer${layers.length == 1 ? '' : 's'} selected',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
            TextButton(onPressed: c.selectAll, child: const Text('Select all')),
            TextButton(onPressed: c.clearSelection, child: const Text('Clear')),
          ]),
          if (layers.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('Tap layers to select them', style: TextStyle(color: MA.textDim)))
          else ...[
            const SectionTitle('Layers'),
            Wrap(spacing: 6, runSpacing: 6, children: [
              btn(Icons.copy, 'Duplicate', () => named('dup')),
              btn(Icons.content_cut, 'Split at playhead', () => named('split')),
              btn(Icons.first_page, 'Trim start to playhead', () => act(() => a.trimToPlayhead(inPoint: true))),
              btn(Icons.last_page, 'Trim end to playhead', () => act(() => a.trimToPlayhead(inPoint: false))),
              btn(Icons.visibility_outlined, layers.any((l) => l.visible) ? 'Hide' : 'Show', () => named('vis')),
              btn(Icons.lock_outline, layers.every((l) => l.locked) ? 'Unlock' : 'Lock', () => named('lock')),
              btn(Icons.arrow_upward, 'Bring forward', () => named('up')),
              btn(Icons.arrow_downward, 'Send backward', () => named('down')),
              btn(Icons.content_copy, 'Copy', () => named('copy')),
              btn(Icons.content_paste, 'Paste', () => named('paste')),
              btn(Icons.delete_outline, 'Delete', () => named('delete')),
            ]),
            const SectionTitle('Align (to the selection; one layer: to the frame)'),
            Wrap(spacing: 6, runSpacing: 6, children: [
              btn(Icons.align_horizontal_left, 'Left', () => act(() => a.align('left'))),
              btn(Icons.align_horizontal_center, 'Centre', () => act(() => a.align('center'))),
              btn(Icons.align_horizontal_right, 'Right', () => act(() => a.align('right'))),
              btn(Icons.align_vertical_top, 'Top', () => act(() => a.align('top'))),
              btn(Icons.align_vertical_center, 'Middle', () => act(() => a.align('middle'))),
              btn(Icons.align_vertical_bottom, 'Bottom', () => act(() => a.align('bottom'))),
              btn(Icons.center_focus_strong_outlined, 'Centre in frame', () {
                act(() => a.align('center', to: 'comp'));
                act(() => a.align('middle', to: 'comp'));
              }),
              btn(Icons.horizontal_distribute, 'Distribute horizontally', () => act(() => a.distribute('horizontal'))),
              btn(Icons.vertical_distribute, 'Distribute vertically', () => act(() => a.distribute('vertical'))),
            ]),
            const SectionTitle('Time'),
            Wrap(spacing: 6, runSpacing: 6, children: [
              btn(Icons.start, 'Start at playhead', () => act(() => a.alignTime('start'))),
              btn(Icons.keyboard_tab, 'End at playhead', () => act(() => a.alignTime('end'))),
              btn(Icons.stacked_line_chart, 'Stagger…', () => BulkMenu.stagger(context, c)),
              btn(Icons.view_timeline_outlined, 'One after another', () => act(() => a.alignTime('sequence'))),
            ]),
            const SectionTitle('3D, parent, matte'),
            Wrap(spacing: 6, runSpacing: 6, children: [
              btn(Icons.view_in_ar_outlined, 'Make 3D', () => act(() => a.set3D(true))),
              btn(Icons.crop_square, 'Make 2D', () => act(() => a.set3D(false))),
              if (BulkActions.hasDepthMake3d) btn(Icons.layers, 'Make 3D (keep look)', () => act(a.make3dScene)),
              btn(Icons.workspaces_outline, 'Group into null', () => named('group')),
              btn(Icons.account_tree_outlined, 'Parent to…', () => BulkMenu.parent(context, c)),
              btn(Icons.link_off, 'Unparent', () => act(() => a.parentTo(null))),
              btn(Icons.layers_outlined, 'Precompose', () => named('precomp')),
              btn(Icons.filter_b_and_w_outlined, 'Track matte…', () => BulkMenu.matte(context, c)),
            ]),
            const SectionTitle('Animate in (all)'),
            _chips([for (final t in MotionPresets.transitions) (MotionPresets.transitionLabel(t), () => act(() => a.animate(t, isIn: true)))]),
            const SectionTitle('Animate out (all)'),
            _chips([for (final t in MotionPresets.transitions) (MotionPresets.transitionLabel(t), () => act(() => a.animate(t, isIn: false)))]),
            Wrap(spacing: 6, runSpacing: 6, children: [
              btn(Icons.content_copy, 'Copy animation (primary)', () => act(a.copyAnimation)),
              btn(Icons.content_paste, 'Paste animation', () => act(a.pasteAnimation)),
              btn(Icons.content_copy, 'Copy effects (primary)', () => act(a.copyEffects)),
              btn(Icons.content_paste, 'Paste effects', () => act(a.pasteEffects)),
            ]),
            if (hasMedia) ...[
              const SectionTitle('Look (photos & videos)'),
              _chips([for (final s in MotionPresets.styles) (MotionPresets.styleLabel(s), () => act(() => a.applyStyle(s)))]),
            ],
            if (hasText || a.captionLayers.isNotEmpty) ...[
              const SectionTitle('Text'),
              Wrap(spacing: 6, runSpacing: 6, children: [
                if (a.captionLayers.isNotEmpty) btn(Icons.closed_caption_outlined, 'Caption style…', () => BulkMenu.captionStyle(context, c)),
              ]),
            ],
            const SectionTitle('Blend mode'),
            _chips([for (final m in BulkMenu.blendModes) (m, () => act(() => a.setBlend(m)))]),
            const SectionTitle('Library'),
            Wrap(spacing: 6, runSpacing: 6, children: [
              btn(Icons.bookmark_add_outlined, 'Save as template…', () => named('template')),
              btn(Icons.collections_bookmark_outlined, 'Add media to library', () => named('library')),
            ]),
          ],
        ]);
      },
    );
  }

  Widget _chips(List<(String, VoidCallback)> items) => Wrap(spacing: 6, runSpacing: 6, children: [
        for (final (label, onTap) in items) ActionChip(label: Text(label, style: const TextStyle(fontSize: 12)), onPressed: onTap),
      ]);
}
