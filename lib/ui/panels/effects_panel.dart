import 'package:flutter/material.dart';

import '../../core/model/effects_catalog.dart';
import '../../state/editor_controller.dart';
import 'prop_row.dart';

/// Effect stack of the selected layer. Every parameter is keyframeable.
class EffectsPanel extends StatelessWidget {
  final EditorController c;
  const EffectsPanel({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([c, c.timeNotifier]),
      builder: (context, _) {
        final l = c.selectedLayer;
        if (l == null) {
          return const Center(child: Text('Select a layer to add effects', style: TextStyle(color: Colors.white54)));
        }
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          children: [
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final def in EffectsCatalog.all)
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: Text(def.label),
                  onPressed: () => c.tryRun({'op': 'add_effect', 'layer': l.id, 'effect': def.type}),
                ),
            ]),
            const SizedBox(height: 8),
            if (l.effects.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No effects on this layer yet.', style: TextStyle(color: Colors.white54)),
              ),
            for (final e in l.effects)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
                  child: Column(children: [
                    Row(children: [
                      Expanded(
                        child: Text(EffectsCatalog.byType(e.type)?.label ?? e.type,
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => c.tryRun({'op': 'remove_effect', 'layer': l.id, 'effect': e.id}),
                      ),
                    ]),
                    for (final p in EffectsCatalog.byType(e.type)?.params ?? const <ParamDef>[])
                      if (p.defaultValue.length == 1)
                        PropRow(
                          c: c,
                          ref: PropRef(l.id, p.key, effectId: e.id),
                          label: p.label,
                          min: p.min,
                          max: p.max,
                        )
                      else
                        for (int i = 0; i < p.defaultValue.length; i++)
                          PropRow(
                            c: c,
                            ref: PropRef(l.id, p.key, effectId: e.id),
                            component: i,
                            label: '${p.label.split(' ').first} ${'RGB'[i]}',
                            min: p.min,
                            max: p.max,
                            decimals: 0,
                          ),
                  ]),
                ),
              ),
          ],
        );
      },
    );
  }
}
