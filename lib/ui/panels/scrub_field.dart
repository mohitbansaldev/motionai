// win-43: After Effects style property rows: drag a number left/right to
// scrub it (Shift = ×10, Ctrl = ×0.1), click it to type an exact value,
// no slider limits. One row shows every component of a property
// (Position X Y Z), with keyframe navigation (◀ ◆ ▶) like AE's stopwatch.

import 'package:flutter/material.dart' hide Easing;
import 'package:flutter/services.dart';

import '../../core/model/anim_prop.dart';
import '../../state/editor_controller.dart';
import 'prop_row.dart';

const kAxisColors = [Color(0xFFFF6B6B), Color(0xFF7CE38B), Color(0xFF6EA8FF)];
const kScrubBlue = Color(0xFF6CB6FF);
const kKeyGold = Color(0xFFFFD54F);

/// One draggable number.
class ScrubNumber extends StatefulWidget {
  final double value;
  final int decimals;
  final double step; // value change per pixel dragged
  final double? min, max;
  final String suffix;
  final Color color;
  final double width;
  final VoidCallback? onStart;
  final ValueChanged<double> onChanged;
  final VoidCallback? onEnd;
  final ValueChanged<double> onSubmit; // typed value (one undo step)

  const ScrubNumber({
    super.key,
    required this.value,
    required this.onChanged,
    required this.onSubmit,
    this.onStart,
    this.onEnd,
    this.decimals = 1,
    this.step = 1,
    this.min,
    this.max,
    this.suffix = '',
    this.color = kScrubBlue,
    this.width = 62,
  });

  @override
  State<ScrubNumber> createState() => _ScrubNumberState();
}

class _ScrubNumberState extends State<ScrubNumber> {
  bool _editing = false;
  bool _hover = false;
  double _drag = 0;
  double _start = 0;
  late final TextEditingController _ctl = TextEditingController();
  late final FocusNode _focus = FocusNode()..addListener(_onFocus);

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (!_focus.hasFocus && _editing) _commit();
  }

  double _clamp(double v) {
    var x = v;
    if (widget.min != null && x < widget.min!) x = widget.min!;
    if (widget.max != null && x > widget.max!) x = widget.max!;
    return x;
  }

  String _fmt(double v) => v.toStringAsFixed(widget.decimals);

  void _commit() {
    final raw = _ctl.text.trim();
    setState(() => _editing = false);
    final v = _evalExpr(raw, widget.value);
    if (v != null && v.isFinite) widget.onSubmit(_clamp(v));
  }

  /// "120", "+=30" / "-=30" (relative), "*2", "/2", or a plain sum like "100+20".
  static double? _evalExpr(String s, double current) {
    if (s.isEmpty) return null;
    final t = s.replaceAll(' ', '');
    if (t.startsWith('+=')) return (double.tryParse(t.substring(2)) ?? 0) + current;
    if (t.startsWith('-=')) return current - (double.tryParse(t.substring(2)) ?? 0);
    if (t.startsWith('*')) return current * (double.tryParse(t.substring(1)) ?? 1);
    if (t.startsWith('/')) {
      final d = double.tryParse(t.substring(1)) ?? 1;
      return d == 0 ? null : current / d;
    }
    final direct = double.tryParse(t);
    if (direct != null) return direct;
    final m = RegExp(r'^(-?[\d.]+)([+\-*/])(-?[\d.]+)$').firstMatch(t);
    if (m == null) return null;
    final a = double.tryParse(m.group(1)!), b = double.tryParse(m.group(3)!);
    if (a == null || b == null) return null;
    switch (m.group(2)) {
      case '+':
        return a + b;
      case '-':
        return a - b;
      case '*':
        return a * b;
      default:
        return b == 0 ? null : a / b;
    }
  }

  double get _mult {
    final kb = HardwareKeyboard.instance;
    if (kb.isShiftPressed) return 10;
    if (kb.isControlPressed || kb.isMetaPressed) return 0.1;
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    if (_editing) {
      return SizedBox(
        width: widget.width,
        height: 24,
        child: TextField(
          controller: _ctl,
          focusNode: _focus,
          autofocus: true,
          style: const TextStyle(fontSize: 12.5, color: Colors.white),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 5),
            filled: true,
            fillColor: Color(0xFF0B0C10),
            border: OutlineInputBorder(borderSide: BorderSide(color: kScrubBlue)),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: kScrubBlue)),
          ),
          onSubmitted: (_) => _commit(),
          onTapOutside: (_) => _focus.unfocus(),
        ),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _ctl.text = _fmt(widget.value);
          _ctl.selection = TextSelection(baseOffset: 0, extentOffset: _ctl.text.length);
          setState(() => _editing = true);
        },
        onHorizontalDragStart: (_) {
          _drag = 0;
          _start = widget.value;
          widget.onStart?.call();
        },
        onHorizontalDragUpdate: (d) {
          _drag += d.delta.dx * _mult;
          widget.onChanged(_clamp(_start + _drag * widget.step));
        },
        onHorizontalDragEnd: (_) => widget.onEnd?.call(),
        onHorizontalDragCancel: () => widget.onEnd?.call(),
        child: Container(
          width: widget.width,
          height: 24,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: _hover ? const Color(0x1A6CB6FF) : Colors.transparent,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            '${_fmt(widget.value)}${widget.suffix}',
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontSize: 12.5,
              color: widget.color,
              decoration: TextDecoration.underline,
              decorationStyle: TextDecorationStyle.dotted,
              decorationColor: widget.color.withValues(alpha: 0.5),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

/// A property row: label, every component as a scrub field, keyframe nav.
/// [components] = which components to show (default all of the value);
/// [linked] scales all components together (uniform scale).
class VecPropRow extends StatelessWidget {
  final EditorController c;
  final PropRef ref;
  final String label;
  final List<int>? components;
  final List<String>? names; // per-component prefix ("X", "Y", "Z")
  final int decimals;
  final double step;
  final double? min, max;
  final String suffix;
  final bool linked;
  final bool axisColors;

  const VecPropRow({
    super.key,
    required this.c,
    required this.ref,
    required this.label,
    this.components,
    this.names,
    this.decimals = 1,
    this.step = 1,
    this.min,
    this.max,
    this.suffix = '',
    this.linked = false,
    this.axisColors = true,
  });

  AnimProp? _resolve() {
    if (ref.maskId != null) return c.comp.layerById(ref.target)?.maskById(ref.maskId!)?.props[ref.prop];
    if (ref.effectId != null) return c.comp.layerById(ref.target)?.effectById(ref.effectId!)?.params[ref.prop];
    return c.propOf(ref.target, ref.prop);
  }

  void _setAll(List<double> v, {bool record = false}) =>
      c.tryRun({'op': 'set_property', ...ref.base(), 'value': v}, record: record);

  void _setOne(AnimProp p, int i, double v, {bool record = false}) {
    final cur = List<double>.of(p.valueAt(c.time));
    if (linked) {
      final old = cur[i];
      final k = old.abs() < 1e-9 ? null : v / old;
      for (int j = 0; j < cur.length; j++) {
        cur[j] = k == null ? v : cur[j] * k;
      }
    } else {
      cur[i] = v;
    }
    _setAll(cur, record: record);
  }

  @override
  Widget build(BuildContext context) {
    final p = _resolve();
    if (p == null) return const SizedBox.shrink();
    final value = p.valueAt(c.time);
    final comps = components ?? [for (int i = 0; i < value.length; i++) i];
    final onKey = p.keyframeAt(c.time) != null;
    final animated = p.isAnimated;
    final times = [for (final k in p.keyframes) k.time]..sort();
    final prev = times.where((t) => t < c.time - 1e-6).lastOrNull;
    final next = times.where((t) => t > c.time + 1e-6).firstOrNull;
    final fieldW = comps.length >= 3 ? 58.0 : 66.0;
    return SizedBox(
      height: 30,
      child: Row(children: [
        // AE stopwatch: on = animated.
        InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => _toggleKey(p),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Icon(animated ? Icons.timer : Icons.timer_outlined, size: 15, color: animated ? kKeyGold : Colors.white38),
          ),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: Text(label, style: const TextStyle(fontSize: 12.5, color: Color(0xFFD5D8DE)), overflow: TextOverflow.ellipsis),
        ),
        for (final i in comps) ...[
          if (names != null && comps.length > 1)
            Text(names![comps.indexOf(i)], style: TextStyle(fontSize: 10.5, color: axisColors ? kAxisColors[i % 3] : Colors.white38, fontWeight: FontWeight.w700)),
          if (i < value.length)
            ScrubNumber(
              width: fieldW,
              value: value[i],
              decimals: decimals,
              step: step,
              min: min,
              max: max,
              suffix: suffix,
              color: animated ? kKeyGold : kScrubBlue,
              onStart: c.beginGesture,
              onChanged: (v) => _setOne(p, i, v),
              onEnd: c.endGesture,
              onSubmit: (v) => _setOne(p, i, v, record: true),
            ),
        ],
        // ◀ ◆ ▶ keyframe navigation
        if (animated)
          _navBtn(Icons.chevron_left, prev == null ? null : () => c.seek(prev, snap: false))
        else
          const SizedBox(width: 18),
        InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => _toggleKey(p),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Icon(onKey ? Icons.diamond : Icons.diamond_outlined, size: 14, color: onKey ? kKeyGold : (animated ? Colors.white60 : Colors.white30)),
          ),
        ),
        if (animated) _navBtn(Icons.chevron_right, next == null ? null : () => c.seek(next, snap: false)) else const SizedBox(width: 18),
      ]),
    );
  }

  Widget _navBtn(IconData icon, VoidCallback? onTap) => InkWell(
        onTap: onTap,
        child: SizedBox(width: 18, height: 24, child: Icon(icon, size: 16, color: onTap == null ? Colors.white12 : Colors.white70)),
      );

  void _toggleKey(AnimProp p) {
    if (p.keyframeAt(c.time) != null) {
      c.tryRun({'op': 'remove_keyframe', ...ref.base(), 'time': c.time});
    } else {
      c.tryRun({'op': 'set_keyframe', ...ref.base(), 'time': c.time, 'value': p.valueAt(c.time)});
    }
  }
}

/// A collapsible AE-style property group ("Transform", "Camera Options").
class PropGroup extends StatefulWidget {
  final String title;
  final List<Widget> children;
  final bool initiallyOpen;
  final Widget? trailing;
  const PropGroup({super.key, required this.title, required this.children, this.initiallyOpen = true, this.trailing});

  @override
  State<PropGroup> createState() => _PropGroupState();
}

class _PropGroupState extends State<PropGroup> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF16181E),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF23262E)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 7, 8, 7),
            child: Row(children: [
              AnimatedRotation(
                turns: _open ? 0.25 : 0,
                duration: const Duration(milliseconds: 120),
                child: const Icon(Icons.chevron_right, size: 18, color: Colors.white54),
              ),
              const SizedBox(width: 2),
              Expanded(child: Text(widget.title, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.white, letterSpacing: 0.2))),
              if (widget.trailing != null) widget.trailing!,
            ]),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 4, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: widget.children),
          ),
      ]),
    );
  }
}
