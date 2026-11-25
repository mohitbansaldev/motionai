// BULK (Agent N): the Edit and Effects panels when several layers are selected.
import 'package:flutter/material.dart';

import '../../core/model/effects_catalog.dart';
import '../../core/model/layer.dart';
import '../../core/presets/motion_presets.dart';
import '../../state/editor_controller.dart';
import '../common.dart';
import '../fonts/font_picker.dart';
import '../theme.dart';
import 'bulk_actions.dart';
import 'bulk_menu.dart';

/// "N layers selected": the bulk-editable sections (transform, opacity, 3D,
/// effects, text style, animation, layer options). Mixed values show "—".
class BulkPanel extends StatelessWidget {
  final EditorController c;
  const BulkPanel({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([c, c.timeNotifier]),
      builder: (context, _) {
        final a = BulkActions(c);
        final layers = a.layers;
        void act(String? Function() f) => bulkReport(context, f());
        final visual = [for (final l in layers) if (l.type != LayerType.audio) l];
        final sound = [for (final l in layers) if (l.type == LayerType.audio || l.type == LayerType.video) l];
        final texts = [for (final l in layers) if (l.type == LayerType.text) l];
        final types = <LayerType, int>{};
        for (final l in layers) {
          types[l.type] = (types[l.type] ?? 0) + 1;
        }
        final all3d = visual.isNotEmpty && visual.every((l) => l.is3D);
        final none3d = visual.every((l) => !l.is3D);
        final w = c.comp.width, h = c.comp.height;
        BulkValueRow row(String label, String prop, List<Layer> ls, double min, double max, {int? component, int decimals = 1}) =>
            BulkValueRow(c: c, layers: ls, prop: prop, component: component, label: label, min: min, max: max, decimals: decimals);
        return ListView(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), children: [
          Row(children: [
            const Icon(Icons.select_all, size: 18, color: MA.accent2),
            const SizedBox(width: 8),
            Expanded(child: Text('${layers.length} layers selected', style: const TextStyle(fontWeight: FontWeight.w700))),
            TextButton(onPressed: () => BulkSheet.open(context, c), child: const Text('All actions')),
          ]),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final e in types.entries)
              Chip(
                visualDensity: VisualDensity.compact,
                avatar: Icon(layerIcon(e.key), size: 14, color: layerColor(e.key)),
                label: Text('${e.value} ${e.key.name}', style: const TextStyle(fontSize: 11.5)),
              ),
          ]),
          if (visual.isNotEmpty) ...[
            Row(children: [
              const Expanded(child: SectionTitle('3D')),
              Text(all3d ? 'all 3D' : (none3d ? 'all 2D' : 'mixed'), style: const TextStyle(fontSize: 12, color: MA.textDim)),
              Checkbox(
                tristate: true,
                value: all3d ? true : (none3d ? false : null),
                onChanged: (_) => act(() => a.set3D(!all3d)),
              ),
            ]),
            if (BulkActions.hasDepthMake3d)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.layers, size: 16),
                  label: const Text('Make 3D (keep look, depth bands)'),
                  onPressed: () => act(a.make3dScene),
                ),
              ),
            const SectionTitle('Transform (all selected)'),
            row('Position X', Props.position, visual, -w, w * 2, component: 0, decimals: 0),
            row('Position Y', Props.position, visual, -h, h * 2, component: 1, decimals: 0),
            if (visual.any((l) => l.is3D)) row('Position Z', Props.position, [for (final l in visual) if (l.is3D) l], -4000, 12000, component: 2, decimals: 0),
            row('Scale', Props.scale, visual, 0, 400, component: 0),
            row('Rotation', Props.rotation, visual, -360, 360, component: 2),
            row('Opacity', Props.opacity, visual, 0, 100, decimals: 0),
            Wrap(spacing: 6, runSpacing: 6, children: [
              OutlinedButton(onPressed: () => act(() => a.transform(scale: 1.1)), child: const Text('Scale +10%')),
              OutlinedButton(onPressed: () => act(() => a.transform(scale: 1 / 1.1)), child: const Text('Scale −10%')),
              OutlinedButton(onPressed: () => act(() => a.transform(rotate: -15)), child: const Text('Rotate −15°')),
              OutlinedButton(onPressed: () => act(() => a.transform(rotate: 15)), child: const Text('Rotate +15°')),
            ]),
          ],
          if (sound.isNotEmpty) ...[
            const SectionTitle('Audio'),
            row('Volume', Props.volume, sound, 0, 200, decimals: 0),
          ],
          if (layers.any((l) => l.type == LayerType.video || l.type == LayerType.audio || l.type == LayerType.comp)) ...[
            const SectionTitle('Speed'),
            Wrap(spacing: 6, children: [
              for (final s in [0.25, 0.5, 1.0, 1.5, 2.0, 4.0]) ActionChip(label: Text('${s}x'), onPressed: () => act(() => a.setSpeed(s))),
            ]),
          ],
          if (texts.isNotEmpty) ...[
            SectionTitle('Text style (${texts.length} text layer${texts.length == 1 ? '' : 's'})'),
            Wrap(spacing: 6, runSpacing: 6, children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.font_download_outlined, size: 16),
                label: Text(_common(texts.map((l) => l.text?.fontFamily ?? 'Default')) ?? 'Font: —'),
                onPressed: () async {
                  final f = await FontPicker.open(context, texts.first.text?.fontFamily, sample: texts.first.text?.text);
                  if (f != null && context.mounted) act(() => a.setText({'font': f}));
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: const Text('Text style preset'),
                onPressed: () async {
                  final id = await TextStylePicker.open(context);
                  if (id != null && context.mounted) act(() => a.setText({'text_style': id}));
                },
              ),
              if (a.captionLayers.isNotEmpty)
                OutlinedButton.icon(
                  icon: const Icon(Icons.closed_caption_outlined, size: 16),
                  label: const Text('Caption style'),
                  onPressed: () => BulkMenu.captionStyle(context, c),
                ),
            ]),
            _TextSizeRow(c: c, texts: texts),
            SwatchRow(
              selected: _commonInt(texts.map((l) => l.text!.color)) ?? 0,
              onPick: (v) => act(() => a.setText({'text_color': colorHex(v)})),
            ),
            const SectionTitle('Text animation'),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final an in TextAnimators.all)
                ChoiceChip(
                  label: Text(TextAnimators.label(an), style: const TextStyle(fontSize: 12)),
                  selected: texts.every((l) => l.text!.animator == an),
                  onSelected: (_) => act(() => a.setText({'animator': an})),
                ),
            ]),
          ],
          if (visual.isNotEmpty) ...[
            const SectionTitle('Animate in (all)'),
            _chips([for (final t in MotionPresets.transitions) (MotionPresets.transitionLabel(t), () => act(() => a.animate(t, isIn: true)))]),
            const SectionTitle('Animate out (all)'),
            _chips([for (final t in MotionPresets.transitions) (MotionPresets.transitionLabel(t), () => act(() => a.animate(t, isIn: false)))]),
            Wrap(spacing: 6, runSpacing: 6, children: [
              OutlinedButton(onPressed: () => act(a.copyAnimation), child: const Text('Copy animation (primary)')),
              OutlinedButton(onPressed: () => act(a.pasteAnimation), child: const Text('Paste animation')),
            ]),
          ],
          const SectionTitle('Layer'),
          Row(children: [
            const SizedBox(width: 84, child: Text('Blend', style: TextStyle(fontSize: 12.5, color: Colors.white70))),
            DropdownButton<String>(
              value: _common(layers.map((l) => l.blendMode)),
              hint: const Text('—'),
              items: [for (final m in BulkMenu.blendModes) DropdownMenuItem(value: m, child: Text(m))],
              onChanged: (m) {
                if (m != null) act(() => a.setBlend(m));
              },
            ),
          ]),
          Row(children: [
            const SizedBox(width: 84, child: Text('Parent', style: TextStyle(fontSize: 12.5, color: Colors.white70))),
            Expanded(
              child: Text(_parentLabel(c, layers), overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
            ),
            TextButton(onPressed: () => BulkMenu.parent(context, c), child: const Text('Set…')),
          ]),
          Row(children: [
            const SizedBox(width: 84, child: Text('Track matte', style: TextStyle(fontSize: 12.5, color: Colors.white70))),
            Expanded(child: Text(_common(layers.map((l) => l.matte?.layerId ?? 'None')) ?? '—', style: const TextStyle(fontSize: 12.5))),
            TextButton(onPressed: () => BulkMenu.matte(context, c), child: const Text('Set…')),
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(icon: const Icon(Icons.content_cut, size: 16), label: const Text('Split'), onPressed: () => BulkMenu.run(context, c, 'split')),
            OutlinedButton.icon(icon: const Icon(Icons.copy, size: 16), label: const Text('Duplicate'), onPressed: () => BulkMenu.run(context, c, 'dup')),
            OutlinedButton.icon(icon: const Icon(Icons.workspaces_outline, size: 16), label: const Text('Group'), onPressed: () => BulkMenu.run(context, c, 'group')),
            OutlinedButton.icon(icon: const Icon(Icons.layers_outlined, size: 16), label: const Text('Precompose'), onPressed: () => BulkMenu.run(context, c, 'precomp')),
            OutlinedButton.icon(icon: const Icon(Icons.delete_outline, size: 16), label: const Text('Delete'), onPressed: () => BulkMenu.run(context, c, 'delete')),
          ]),
          const SizedBox(height: 24),
        ]);
      },
    );
  }

  static String _parentLabel(EditorController c, List<Layer> layers) {
    final p = _common(layers.map((l) => l.parentId ?? ''));
    if (p == null) return '—';
    if (p.isEmpty) return 'None';
    return c.comp.layerById(p)?.name ?? p;
  }

  static Widget _chips(List<(String, VoidCallback)> items) => Wrap(spacing: 6, runSpacing: 6, children: [
        for (final (label, onTap) in items) ActionChip(label: Text(label, style: const TextStyle(fontSize: 12)), onPressed: onTap),
      ]);
}

/// The value shared by every element, or null when they differ.
String? _common(Iterable<String> v) {
  final s = v.toSet();
  return s.length == 1 ? s.first : null;
}

int? _commonInt(Iterable<int> v) {
  final s = v.toSet();
  return s.length == 1 ? s.first : null;
}

/// One property for many layers. Shows the shared value or "—". The slider
/// sets the value on all ("=") or moves all by the same amount ("±").
class BulkValueRow extends StatefulWidget {
  final EditorController c;
  final List<Layer> layers;
  final String prop;
  final int? component;
  final String label;
  final double min, max;
  final int decimals;
  const BulkValueRow({
    super.key,
    required this.c,
    required this.layers,
    required this.prop,
    required this.label,
    required this.min,
    required this.max,
    this.component,
    this.decimals = 1,
  });

  @override
  State<BulkValueRow> createState() => _BulkValueRowState();
}

class _BulkValueRowState extends State<BulkValueRow> {
  bool _relative = false;
  double _dragApplied = 0;
  double? _dragValue;
  final _ctl = TextEditingController();

  EditorController get c => widget.c;

  @override
  void initState() {
    super.initState();
    // Position and rotation are usually moved together; opacity/scale/volume set.
    _relative = widget.prop == Props.position || widget.prop == Props.rotation;
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  List<double> get _values => [
        for (final l in widget.layers)
          if (l.props[widget.prop] != null) l.props[widget.prop]!.valueAt(c.time)[widget.component ?? 0],
      ];

  double? get _shared {
    final v = _values;
    if (v.isEmpty) return null;
    final f = v.first;
    return v.every((x) => (x - f).abs() < 1e-6) ? f : null;
  }

  BulkActions get _a => BulkActions(c);
  List<String> get _ids => [for (final l in widget.layers) l.id];

  String? _apply(double v, {required bool relative, bool record = true}) {
    final a = _a;
    final ids = _ids;
    final key = widget.component == null ? widget.prop : '${widget.prop}.${'xyz'[widget.component!]}';
    final isScale = widget.prop == Props.scale;
    if (relative) {
      return c.tryRun({
        'op': 'for_layers',
        'layers': ids,
        'command': {'op': 'offset_property', 'layer': r'$layer', 'prop': isScale ? Props.scale : key, 'by': isScale ? [v, v, 0] : v},
      }, record: record);
    }
    if (a.isEmpty) return null;
    return c.tryRun({
      'op': 'for_layers',
      'layers': ids,
      'command': {'op': 'set_property', 'layer': r'$layer', 'prop': isScale ? Props.scale : key, 'value': isScale ? [v, v] : v},
    }, record: record);
  }

  @override
  Widget build(BuildContext context) {
    final shared = _shared;
    final range = widget.max - widget.min;
    final sliderMin = _relative ? -range / 2 : widget.min;
    final sliderMax = _relative ? range / 2 : widget.max;
    final sliderValue = _dragValue ?? (_relative ? 0.0 : (shared ?? (_values.isEmpty ? widget.min : _values.first)));
    return Row(children: [
      SizedBox(width: 84, child: Text(widget.label, style: const TextStyle(fontSize: 12.5, color: Colors.white70))),
      Expanded(
        child: Slider(
          value: sliderValue.clamp(sliderMin, sliderMax).toDouble(),
          min: sliderMin,
          max: sliderMax,
          onChangeStart: (v) {
            c.beginGesture();
            _dragApplied = 0;
            setState(() => _dragValue = v);
          },
          onChanged: (v) {
            setState(() => _dragValue = v);
            if (_relative) {
              _apply(v - _dragApplied, relative: true, record: false);
              _dragApplied = v;
            } else {
              _apply(v, relative: false, record: false);
            }
          },
          onChangeEnd: (_) {
            c.endGesture();
            setState(() => _dragValue = null);
          },
        ),
      ),
      SizedBox(
        width: 62,
        child: TextField(
          controller: _ctl,
          textAlign: TextAlign.right,
          style: const TextStyle(fontSize: 12.5),
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: InputDecoration(
            isDense: true,
            hintText: _relative ? '±' : (shared == null ? '—' : shared.toStringAsFixed(widget.decimals)),
            border: InputBorder.none,
          ),
          onSubmitted: (s) {
            final v = double.tryParse(s.trim());
            if (v == null) return;
            bulkReport(context, _apply(v, relative: _relative));
            _ctl.clear();
          },
        ),
      ),
      Tooltip(
        message: _relative ? 'Moves all by the same amount (click: set all to one value)' : 'Sets all to one value (click: move all by an amount)',
        child: InkWell(
          onTap: () => setState(() => _relative = !_relative),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 26,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(_relative ? '±' : '=', style: const TextStyle(fontWeight: FontWeight.w800, color: MA.accent2)),
          ),
        ),
      ),
    ]);
  }
}

class _TextSizeRow extends StatelessWidget {
  final EditorController c;
  final List<Layer> texts;
  const _TextSizeRow({required this.c, required this.texts});

  @override
  Widget build(BuildContext context) {
    final sizes = texts.map((l) => l.text!.fontSize).toSet();
    final shared = sizes.length == 1 ? sizes.first : null;
    return Row(children: [
      const SizedBox(width: 84, child: Text('Size', style: TextStyle(fontSize: 12.5, color: Colors.white70))),
      Expanded(
        child: Slider(
          value: (shared ?? texts.first.text!.fontSize).clamp(8.0, 400.0).toDouble(),
          min: 8,
          max: 400,
          onChangeStart: (_) => c.beginGesture(),
          onChanged: (v) => BulkActions(c).setText({'font_size': v}, record: false),
          onChangeEnd: (_) => c.endGesture(),
        ),
      ),
      SizedBox(width: 40, child: Text(shared == null ? '—' : shared.round().toString(), textAlign: TextAlign.right)),
    ]);
  }
}

/// Effects tab with several layers selected: add an effect to all, remove
/// an effect type from all, copy / paste effect stacks.
class BulkEffectsPanel extends StatelessWidget {
  final EditorController c;
  const BulkEffectsPanel({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final a = BulkActions(c);
        void act(String? Function() f) => bulkReport(context, f());
        final used = <String, int>{};
        for (final l in a.layers) {
          for (final t in {for (final e in l.effects) e.type}) {
            used[t] = (used[t] ?? 0) + 1;
          }
        }
        final hasMedia = a.layers.any((l) => l.type == LayerType.image || l.type == LayerType.video);
        return ListView(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), children: [
          Text('Effects on ${a.layers.length} selected layers', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            OutlinedButton.icon(icon: const Icon(Icons.content_copy, size: 16), label: const Text('Copy (primary)'), onPressed: () => act(a.copyEffects)),
            OutlinedButton.icon(icon: const Icon(Icons.content_paste, size: 16), label: const Text('Paste to all'), onPressed: () => act(a.pasteEffects)),
            OutlinedButton(onPressed: () => act(() => a.pasteEffects(replace: true)), child: const Text('Replace all with copied')),
          ]),
          if (hasMedia) ...[
            const SectionTitle('Looks (selected photos & videos)'),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final st in MotionPresets.styles)
                ActionChip(
                  avatar: const Icon(Icons.palette_outlined, size: 16),
                  label: Text(MotionPresets.styleLabel(st)),
                  onPressed: () => act(() => a.applyStyle(st)),
                ),
            ]),
          ],
          if (used.isNotEmpty) ...[
            const SectionTitle('On the selection (tap to remove from all)'),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final e in used.entries)
                InputChip(
                  label: Text('${EffectsCatalog.byType(e.key)?.label ?? e.key} · ${e.value}'),
                  onDeleted: () => act(() => a.removeEffectType(e.key)),
                ),
            ]),
          ],
          const SectionTitle('Add to all selected'),
          for (final cat in EffectsCatalog.categories) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 6, 2, 4),
              child: Text(EffectsCatalog.categoryLabel(cat), style: const TextStyle(fontSize: 11.5, color: Colors.white38)),
            ),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final def in EffectsCatalog.all.where((d) => d.category == cat))
                ActionChip(avatar: const Icon(Icons.add, size: 16), label: Text(def.label), onPressed: () => act(() => a.addEffect(def.type))),
            ]),
          ],
          const SizedBox(height: 8),
          const Text('Select one layer to edit effect settings.', style: TextStyle(color: Colors.white38, fontSize: 12)),
        ]);
      },
    );
  }
}
