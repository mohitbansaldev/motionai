import 'package:flutter/material.dart';

import '../../core/model/layer.dart';
import '../../core/presets/motion_presets.dart';
import '../../state/editor_controller.dart';
import '../common.dart';
import 'prop_row.dart';

/// Transform, text and layer options for the selected layer.
class LayerPanel extends StatelessWidget {
  final EditorController c;
  const LayerPanel({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([c, c.timeNotifier]),
      builder: (context, _) {
        final l = c.selectedLayer;
        if (l == null) {
          return const Center(
            child: Text('Select a layer in the timeline or preview', style: TextStyle(color: Colors.white54)),
          );
        }
        final comp = c.comp;
        final w = comp.width, h = comp.height;
        PropRow row(String prop, String label, double min, double max, {int? comp, int decimals = 1}) => PropRow(
              c: c,
              ref: PropRef(l.id, prop),
              component: comp,
              label: label,
              min: min,
              max: max,
              decimals: decimals,
            );
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          children: [
            _header(context, l),
            if (l.type == LayerType.text) _TextSection(c: c, layer: l),
            if (l.type == LayerType.solid) ...[
              const SectionTitle('Color'),
              SwatchRow(
                selected: l.color,
                onPick: (v) => c.tryRun({'op': 'update_layer', 'layer': l.id, 'color': colorHex(v)}),
              ),
            ],
            if (l.type == LayerType.video) ...[
              const SectionTitle('Speed'),
              Wrap(spacing: 6, children: [
                for (final s in [0.25, 0.5, 1.0, 1.5, 2.0, 4.0])
                  ChoiceChip(
                    label: Text('${s}x'),
                    selected: l.speed == s,
                    onSelected: (_) => c.tryRun({'op': 'update_layer', 'layer': l.id, 'speed': s}),
                  ),
              ]),
            ],
            if (l.type == LayerType.video || l.type == LayerType.audio) ...[
              const SectionTitle('Audio'),
              row(Props.volume, 'Volume', 0, 100, decimals: 0),
            ],
            if (l.type != LayerType.audio) ...[
              const SectionTitle('Transform'),
              row(Props.position, 'Position X', -w, w * 2, comp: 0),
              row(Props.position, 'Position Y', -h, h * 2, comp: 1),
              if (l.is3D) row(Props.position, 'Position Z', -4000, 12000, comp: 2),
              row(Props.scale, 'Scale', 0, 400),
              if (l.is3D) row(Props.rotation, 'X Rotation', -180, 180, comp: 0),
              if (l.is3D) row(Props.rotation, 'Y Rotation', -180, 180, comp: 1),
              row(Props.rotation, l.is3D ? 'Z Rotation' : 'Rotation', -360, 360, comp: 2),
              row(Props.opacity, 'Opacity', 0, 100, decimals: 0),
              row(Props.anchor, 'Anchor X', 0, l.width, comp: 0, decimals: 0),
              row(Props.anchor, 'Anchor Y', 0, l.height, comp: 1, decimals: 0),
              const SectionTitle('Animate in (at layer start)'),
              _transitionChips(context, l, true),
              const SectionTitle('Animate out (at layer end)'),
              _transitionChips(context, l, false),
              const SectionTitle('Masks'),
              for (final m in l.masks) _maskCard(l, m),
              Wrap(spacing: 8, children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.circle_outlined, size: 16),
                  label: const Text('Ellipse mask'),
                  onPressed: () => c.tryRun({'op': 'add_mask', 'layer': l.id, 'shape': 'ellipse'}),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.crop_square, size: 16),
                  label: const Text('Rectangle mask'),
                  onPressed: () => c.tryRun({'op': 'add_mask', 'layer': l.id, 'shape': 'rect'}),
                ),
              ]),
            ],
            const SectionTitle('Layer'),
            _parentPicker(l),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.content_cut, size: 16),
                label: const Text('Split'),
                onPressed: () {
                  final e = c.tryRun({'op': 'split_layer', 'layer': l.id, 'time': c.time});
                  if (e != null) showSnack(context, e);
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Duplicate'),
                onPressed: () => c.tryRun({'op': 'duplicate_layer', 'layer': l.id}),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Delete'),
                onPressed: () => c.tryRun({'op': 'remove_layer', 'layer': l.id}),
              ),
            ]),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }

  Widget _transitionChips(BuildContext context, Layer l, bool isIn) {
    return Wrap(spacing: 6, runSpacing: 6, children: [
      for (final t in MotionPresets.transitions)
        ActionChip(
          label: Text(MotionPresets.transitionLabel(t), style: const TextStyle(fontSize: 12)),
          onPressed: () {
            final e = c.tryRun({'op': isIn ? 'animate_in' : 'animate_out', 'layer': l.id, 'preset': t});
            if (e != null) showSnack(context, e);
          },
        ),
    ]);
  }

  Widget _maskCard(Layer l, Mask m) {
    PropRow mrow(String prop, String label, double max, {int? comp}) => PropRow(
          c: c,
          ref: PropRef(l.id, prop, maskId: m.id),
          component: comp,
          label: label,
          min: 0,
          max: max,
          decimals: 0,
        );
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 4, 6),
        child: Column(children: [
          Row(children: [
            Expanded(child: Text(m.shape == 'rect' ? 'Rectangle mask' : 'Ellipse mask')),
            const Text('Invert', style: TextStyle(fontSize: 12)),
            Switch(
              value: m.invert,
              onChanged: (v) => c.tryRun({'op': 'update_mask', 'layer': l.id, 'mask': m.id, 'invert': v}),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => c.tryRun({'op': 'remove_mask', 'layer': l.id, 'mask': m.id}),
            ),
          ]),
          mrow('center', 'Center X', l.width, comp: 0),
          mrow('center', 'Center Y', l.height, comp: 1),
          mrow('size', 'Width', l.width * 2, comp: 0),
          mrow('size', 'Height', l.height * 2, comp: 1),
          mrow('feather', 'Feather', 500),
        ]),
      ),
    );
  }

  Widget _header(BuildContext context, Layer l) {
    return Row(children: [
      Icon(layerIcon(l.type), size: 18, color: layerColor(l.type)),
      const SizedBox(width: 8),
      Expanded(
        child: GestureDetector(
          onTap: () => _rename(context, l),
          child: Text(l.name, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
        ),
      ),
      const Text('3D', style: TextStyle(fontSize: 12)),
      Switch(
        value: l.is3D,
        onChanged: (v) => c.tryRun({'op': 'update_layer', 'layer': l.id, 'is3d': v}),
      ),
      IconButton(
        icon: Icon(l.visible ? Icons.visibility : Icons.visibility_off, size: 20),
        onPressed: () => c.tryRun({'op': 'update_layer', 'layer': l.id, 'visible': !l.visible}),
      ),
    ]);
  }

  Widget _parentPicker(Layer l) {
    final others = c.comp.layers.where((o) => o.id != l.id).toList();
    return Row(children: [
      const SizedBox(width: 84, child: Text('Parent', style: TextStyle(fontSize: 12.5, color: Colors.white70))),
      Expanded(
        child: DropdownButton<String?>(
          isExpanded: true,
          value: others.any((o) => o.id == l.parentId) ? l.parentId : null,
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('None')),
            for (final o in others) DropdownMenuItem<String?>(value: o.id, child: Text(o.name, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => c.tryRun({'op': 'update_layer', 'layer': l.id, 'parent': v}),
        ),
      ),
    ]);
  }

  Future<void> _rename(BuildContext context, Layer l) async {
    final ctl = TextEditingController(text: l.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename layer'),
        content: TextField(controller: ctl, autofocus: true, onSubmitted: (s) => Navigator.pop(ctx, s)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('OK')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      c.tryRun({'op': 'update_layer', 'layer': l.id, 'name': name.trim()});
    }
  }
}

class _TextSection extends StatefulWidget {
  final EditorController c;
  final Layer layer;
  const _TextSection({required this.c, required this.layer});

  @override
  State<_TextSection> createState() => _TextSectionState();
}

class _TextSectionState extends State<_TextSection> {
  late final TextEditingController _ctl = TextEditingController(text: widget.layer.text?.text ?? '');
  String? _layerId;

  @override
  void didUpdateWidget(covariant _TextSection old) {
    super.didUpdateWidget(old);
    if (widget.layer.id != _layerId) {
      _layerId = widget.layer.id;
      _ctl.text = widget.layer.text?.text ?? '';
    }
  }

  @override
  void initState() {
    super.initState();
    _layerId = widget.layer.id;
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final l = widget.layer;
    final t = l.text!;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionTitle('Text'),
      TextField(
        controller: _ctl,
        maxLines: null,
        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
        onChanged: (s) => c.tryRun({'op': 'update_layer', 'layer': l.id, 'text': s}),
      ),
      Row(children: [
        const SizedBox(width: 84, child: Text('Size', style: TextStyle(fontSize: 12.5, color: Colors.white70))),
        Expanded(
          child: Slider(
            value: t.fontSize.clamp(8.0, 400.0),
            min: 8,
            max: 400,
            onChangeStart: (_) => c.beginGesture(),
            onChanged: (v) => c.tryRun({'op': 'update_layer', 'layer': l.id, 'font_size': v}, record: false),
            onChangeEnd: (_) => c.endGesture(),
          ),
        ),
        SizedBox(width: 40, child: Text(t.fontSize.round().toString(), textAlign: TextAlign.right)),
      ]),
      Row(children: [
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 400, label: Text('Regular')),
            ButtonSegment(value: 700, label: Text('Bold')),
            ButtonSegment(value: 900, label: Text('Black')),
          ],
          selected: {t.fontWeight >= 900 ? 900 : (t.fontWeight >= 600 ? 700 : 400)},
          onSelectionChanged: (s) => c.tryRun({'op': 'update_layer', 'layer': l.id, 'font_weight': s.first}),
        ),
      ]),
      const SizedBox(height: 8),
      SwatchRow(
        selected: t.color,
        onPick: (v) => c.tryRun({'op': 'update_layer', 'layer': l.id, 'text_color': colorHex(v)}),
      ),
      const SectionTitle('Text animation'),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final a in TextAnimators.all)
          ChoiceChip(
            label: Text(TextAnimators.label(a), style: const TextStyle(fontSize: 12)),
            selected: t.animator == a,
            onSelected: (_) => c.tryRun({'op': 'update_layer', 'layer': l.id, 'animator': a}),
          ),
      ]),
      Row(children: [
        const SizedBox(width: 84, child: Text('Anim length', style: TextStyle(fontSize: 12.5, color: Colors.white70))),
        Expanded(
          child: Slider(
            value: t.animDuration.clamp(0.1, 5.0),
            min: 0.1,
            max: 5,
            onChangeStart: (_) => c.beginGesture(),
            onChanged: (v) => c.tryRun({'op': 'update_layer', 'layer': l.id, 'anim_duration': v}, record: false),
            onChangeEnd: (_) => c.endGesture(),
          ),
        ),
        SizedBox(width: 40, child: Text('${t.animDuration.toStringAsFixed(1)}s', textAlign: TextAlign.right)),
      ]),
      Row(children: [
        const Expanded(child: Text('Background box', style: TextStyle(fontSize: 12.5, color: Colors.white70))),
        Switch(
          value: t.boxColor != 0,
          onChanged: (v) =>
              c.tryRun({'op': 'update_layer', 'layer': l.id, 'box_color': v ? '#AA000000' : 'none'}),
        ),
        const Text('Shadow', style: TextStyle(fontSize: 12.5, color: Colors.white70)),
        Switch(
          value: t.shadow,
          onChanged: (v) => c.tryRun({'op': 'update_layer', 'layer': l.id, 'shadow': v}),
        ),
      ]),
    ]);
  }
}
