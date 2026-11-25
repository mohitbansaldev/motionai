import 'package:flutter/material.dart';

import '../core/commands/edit_commands.dart';
import '../core/model/layer.dart';
import '../state/editor_controller.dart';
import 'common.dart';

/// Breadcrumbs of nested comps: "Main › Screen › Inner". Tap one to go back
/// up. Shows nothing while the main comp is open. (PRECOMP, Agent L)
class PrecompBreadcrumbs extends StatelessWidget {
  final EditorController c;
  final bool showWhenMain;
  const PrecompBreadcrumbs({super.key, required this.c, this.showWhenMain = false});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        if (!c.inPrecomp && !showWhenMain) return const SizedBox.shrink();
        final trail = c.compTrail;
        final items = <Widget>[];
        for (int i = 0; i < trail.length; i++) {
          final last = i == trail.length - 1;
          if (i > 0) items.add(const Icon(Icons.chevron_right, size: 16, color: Colors.white54));
          items.add(InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: last ? null : () => c.openComp(trail[i].id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Text(
                i == 0 ? 'Main' : trail[i].name,
                style: TextStyle(
                  fontSize: 12,
                  color: last ? Colors.white : const Color(0xFF4FC3F7),
                  fontWeight: last ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ));
        }
        return Material(
          color: const Color(0xCC15181D),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.layers_outlined, size: 14, color: Colors.white54),
              const SizedBox(width: 2),
              ...items,
              if (c.inPrecomp)
                IconButton(
                  tooltip: 'Back up one comp',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  icon: const Icon(Icons.arrow_upward, color: Colors.white70),
                  onPressed: c.closeComp,
                ),
            ]),
          ),
        );
      },
    );
  }
}

/// Precompose / open / unprecompose / loop buttons for the layer panel.
class PrecompActions extends StatelessWidget {
  final EditorController c;
  final Layer layer;
  const PrecompActions({super.key, required this.c, required this.layer});

  @override
  Widget build(BuildContext context) {
    final l = layer;
    final isComp = l.type == LayerType.comp;
    void run(Map<String, dynamic> cmd) {
      final e = c.tryRun(cmd);
      if (e != null) showSnack(context, e);
    }

    return Wrap(spacing: 8, runSpacing: 8, children: [
      if (isComp) ...[
        FilledButton.tonalIcon(
          icon: const Icon(Icons.open_in_new, size: 16),
          label: const Text('Open comp'),
          onPressed: () => c.openCompLayer(l.id),
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.unfold_more, size: 16),
          label: const Text('Unprecompose'),
          onPressed: () => run({'op': 'unprecompose', 'layer': l.id}),
        ),
        FilterChip(
          label: const Text('Loop'),
          selected: l.loop,
          onSelected: (v) => run({'op': 'update_layer', 'layer': l.id, 'loop': v}),
        ),
      ],
      if (l.type != LayerType.audio)
        OutlinedButton.icon(
          icon: const Icon(Icons.layers_outlined, size: 16),
          label: const Text('Precompose'),
          onPressed: () {
            try {
              final r = c.run({'op': 'precompose', 'layers': [l.id], 'name': '${l.name} comp'});
              if (r.createdIds.isNotEmpty) c.select(r.createdIds.last);
            } on CommandError catch (e) {
              showSnack(context, e.message);
            }
          },
        ),
    ]);
  }
}
