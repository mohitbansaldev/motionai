import 'package:flutter/material.dart';

import '../../core/model/effects_catalog.dart';
import '../../core/model/layer.dart';
import '../../core/presets/motion_presets.dart';
import '../common.dart';
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
        final looks = [
          const SectionTitle('Looks (all photos & videos)'),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final st in MotionPresets.styles)
              ActionChip(
                avatar: const Icon(Icons.palette_outlined, size: 16),
                label: Text(MotionPresets.styleLabel(st)),
                onPressed: () {
                  final e = c.tryRun({'op': 'apply_style', 'style': st});
                  if (e != null) showSnack(context, e);
                },
              ),
          ]),
          Row(children: [
            const Expanded(
              child: Text('Motion blur (fast moves & camera)', style: TextStyle(fontSize: 12.5, color: Colors.white70)),
            ),
            Switch(
              value: c.comp.motionBlur,
              onChanged: (v) => c.tryRun({'op': 'set_comp', 'motion_blur': v}),
            ),
          ]),
          const SectionTitle('Effects on selected layer'),
        ];
        if (l == null) {
          return ListView(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), children: [
            ...looks,
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Select a layer to add effects', style: TextStyle(color: Colors.white54)),
            ),
          ]);
        }
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          children: [
            ...looks,
            for (final cat in EffectsCatalog.categories) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 6, 2, 4),
                child: Text(EffectsCatalog.categoryLabel(cat), style: const TextStyle(fontSize: 11.5, color: Colors.white38)),
              ),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final def in EffectsCatalog.all.where((d) => d.category == cat))
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 16),
                    label: Text(def.label),
                    onPressed: () {
                      final err = c.tryRun({'op': 'add_effect', 'layer': l.id, 'effect': def.type});
                      if (err != null) showSnack(context, err);
                    },
                  ),
              ]),
            ],
            const SizedBox(height: 8),
            if (l.effects.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No effects on this layer yet.', style: TextStyle(color: Colors.white54)),
              ),
            for (final e in l.effects) _EffectCard(c: c, layer: l, effect: e),
          ],
        );
      },
    );
  }
}

class _EffectCard extends StatelessWidget {
  final EditorController c;
  final Layer layer;
  final Effect effect;
  const _EffectCard({required this.c, required this.layer, required this.effect});

  @override
  Widget build(BuildContext context) {
    final l = layer, e = effect;
    final def = EffectsCatalog.byType(e.type);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(def?.label ?? e.type, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => c.tryRun({'op': 'remove_effect', 'layer': l.id, 'effect': e.id}),
            ),
          ]),
          if (e.type == 'motion_blur' && !c.comp.motionBlur)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text('Blurs along the layer\'s on-screen movement (needs position or camera animation).',
                  style: TextStyle(fontSize: 11.5, color: Colors.white38)),
            ),
          for (final p in def?.params ?? const <ParamDef>[]) ..._param(context, p),
        ]),
      ),
    );
  }

  List<Widget> _param(BuildContext context, ParamDef p) {
    final l = layer, e = effect;
    final ref = PropRef(l.id, p.key, effectId: e.id);
    final ap = e.params[p.key];
    if (ap == null) return const [];
    void set(List<double> v) => c.tryRun({'op': 'set_property', ...ref.base(), 'value': v});
    if (p.options.isNotEmpty) {
      final cur = ap.valueAt(c.time)[0].round();
      return [
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 84, child: Text(p.label, style: const TextStyle(fontSize: 12.5, color: Colors.white70))),
            Expanded(
              child: Wrap(spacing: 4, runSpacing: 4, children: [
                for (int i = 0; i < p.options.length; i++)
                  ChoiceChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(p.options[i], style: const TextStyle(fontSize: 11.5)),
                    selected: cur == i,
                    onSelected: (_) => set([i.toDouble()]),
                  ),
              ]),
            ),
          ]),
        ),
      ];
    }
    if (p.color || p.defaultValue.length == 3) {
      final v = ap.valueAt(c.time);
      final argb = 0xFF000000 | (v[0].round().clamp(0, 255) << 16) | (v[1].round().clamp(0, 255) << 8) | v[2].round().clamp(0, 255);
      return [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 84, child: Text(p.label.replaceAll(' (R,G,B)', ''), style: const TextStyle(fontSize: 12.5, color: Colors.white70))),
            Expanded(
              child: SwatchRow(
                selected: argb,
                onPick: (col) => set([((col >> 16) & 0xFF).toDouble(), ((col >> 8) & 0xFF).toDouble(), (col & 0xFF).toDouble()]),
              ),
            ),
          ]),
        ),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Custom RGB / keyframes', style: TextStyle(fontSize: 12, color: Colors.white54)),
            children: [
              for (int i = 0; i < 3; i++)
                PropRow(c: c, ref: ref, component: i, label: 'RGB'[i], min: p.min, max: p.max, decimals: 0),
            ],
          ),
        ),
      ];
    }
    if (p.defaultValue.length == 1) {
      return [PropRow(c: c, ref: ref, label: p.label, min: p.min, max: p.max)];
    }
    return [
      for (int i = 0; i < p.defaultValue.length; i++)
        PropRow(c: c, ref: ref, component: i, label: '${p.label.split(' ').first} ${'XYZ'[i]}', min: p.min, max: p.max, decimals: 0),
    ];
  }
}
