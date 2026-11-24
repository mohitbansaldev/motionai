import 'package:flutter/material.dart' hide Easing;

import '../../core/model/anim_prop.dart';
import '../../core/model/easing.dart';
import '../../state/editor_controller.dart';

/// Addresses one animatable property through the edit-command system.
/// [effectId] is set for effect parameters.
class PropRef {
  final String target; // layer id or "camera"
  final String prop;
  final String? effectId;
  final String? maskId;
  const PropRef(this.target, this.prop, {this.effectId, this.maskId});

  Map<String, dynamic> base() => {
        'target': target,
        'prop': prop,
        if (effectId != null) 'effect': effectId,
        if (maskId != null) 'mask': maskId,
      };
}

/// A labelled slider for one component of an animatable property, with a
/// keyframe diamond (tap = add/remove keyframe, long-press = easing).
class PropRow extends StatelessWidget {
  final EditorController c;
  final PropRef ref;
  final int? component; // null = uniform (all components get the value)
  final String label;
  final double min;
  final double max;
  final int decimals;

  const PropRow({
    super.key,
    required this.c,
    required this.ref,
    required this.label,
    required this.min,
    required this.max,
    this.component,
    this.decimals = 1,
  });

  AnimProp? _resolve() {
    if (ref.maskId != null) {
      return c.comp.layerById(ref.target)?.maskById(ref.maskId!)?.props[ref.prop];
    }
    if (ref.effectId != null) {
      final l = c.comp.layerById(ref.target);
      return l?.effectById(ref.effectId!)?.params[ref.prop];
    }
    return c.propOf(ref.target, ref.prop);
  }

  String get _propPath => component == null ? ref.prop : '${ref.prop}.${'xyz'[component!]}';

  void _set(double v, {bool record = false}) {
    if (component != null && (ref.effectId != null || ref.maskId != null)) {
      // Effects don't support .x paths; write the whole vector.
      final p = _resolve()!;
      final cur = p.valueAt(c.time);
      cur[component!] = v;
      c.tryRun({'op': 'set_property', ...ref.base(), 'value': cur}, record: record);
      return;
    }
    c.tryRun({'op': 'set_property', ...ref.base(), 'prop': _propPath, 'value': v}, record: record);
  }

  @override
  Widget build(BuildContext context) {
    final p = _resolve();
    if (p == null) return const SizedBox.shrink();
    final value = p.valueAt(c.time)[component ?? 0];
    final onKey = p.keyframeAt(c.time) != null;
    final animated = p.isAnimated;
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(label, style: const TextStyle(fontSize: 12.5, color: Colors.white70), overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(trackHeight: 2.5, overlayShape: SliderComponentShape.noOverlay),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChangeStart: (_) => c.beginGesture(),
                onChanged: (v) => _set(v),
                onChangeEnd: (_) => c.endGesture(),
              ),
            ),
          ),
          GestureDetector(
            onTap: () => _editNumber(context, value),
            child: SizedBox(
              width: 58,
              child: Text(
                value.toStringAsFixed(decimals),
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 12.5, color: animated ? const Color(0xFFFFD54F) : Colors.white, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: onKey ? 'Remove keyframe (long-press: easing)' : 'Add keyframe',
            icon: Icon(
              onKey ? Icons.diamond : Icons.diamond_outlined,
              size: 18,
              color: onKey ? const Color(0xFFFFD54F) : (animated ? Colors.white70 : Colors.white38),
            ),
            onPressed: () => _toggleKey(p),
            onLongPress: onKey ? () => _pickEase(context) : null,
          ),
        ],
      ),
    );
  }

  void _toggleKey(AnimProp p) {
    if (p.keyframeAt(c.time) != null) {
      c.tryRun({'op': 'remove_keyframe', ...ref.base(), 'time': c.time});
    } else {
      c.tryRun({'op': 'set_keyframe', ...ref.base(), 'time': c.time, 'value': p.valueAt(c.time)});
    }
  }

  Future<void> _pickEase(BuildContext context) async {
    final picked = await showModalBottomSheet<Easing>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Keyframe easing', style: TextStyle(fontWeight: FontWeight.bold))),
            for (final e in const [
              Easing.linear,
              Easing.easyEase,
              Easing.easeIn,
              Easing.easeOut,
              Easing.hold,
              Easing.bounce,
              Easing.elastic,
              Easing.back,
            ])
              ListTile(title: Text(e.label), onTap: () => Navigator.pop(ctx, e)),
          ],
        ),
      ),
    );
    if (picked != null) {
      c.tryRun({'op': 'set_ease', ...ref.base(), 'time': c.time, 'ease': picked.toJson()});
    }
  }

  Future<void> _editNumber(BuildContext context, double current) async {
    final ctl = TextEditingController(text: current.toStringAsFixed(decimals));
    final v = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          onSubmitted: (s) => Navigator.pop(ctx, double.tryParse(s)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, double.tryParse(ctl.text)), child: const Text('OK')),
        ],
      ),
    );
    if (v != null) _set(v, record: true);
  }
}
