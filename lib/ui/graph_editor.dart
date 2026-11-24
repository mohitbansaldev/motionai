import 'package:flutter/material.dart' hide Easing;

import '../core/model/easing.dart';

/// Bezier easing editor (like After Effects' speed/value graph handles).
/// Returns the chosen [Easing] or null.
class GraphEditorSheet extends StatefulWidget {
  final Easing initial;
  const GraphEditorSheet({super.key, required this.initial});

  static Future<Easing?> open(BuildContext context, Easing initial) => showModalBottomSheet<Easing>(
        context: context,
        isScrollControlled: true,
        builder: (_) => GraphEditorSheet(initial: initial),
      );

  @override
  State<GraphEditorSheet> createState() => _GraphEditorSheetState();
}

class _GraphEditorSheetState extends State<GraphEditorSheet> {
  late double x1, y1, x2, y2;
  int? _drag;

  static const _presets = [
    ('Linear', 0.0, 0.0, 1.0, 1.0),
    ('Easy Ease', 0.33, 0.0, 0.67, 1.0),
    ('Ease In', 0.42, 0.0, 1.0, 1.0),
    ('Ease Out', 0.0, 0.0, 0.58, 1.0),
    ('Fast-Slow', 0.1, 0.9, 0.2, 1.0),
    ('Slow-Fast', 0.8, 0.0, 0.9, 0.1),
    ('Anticipate', 0.6, -0.35, 0.7, 1.0),
    ('Overshoot', 0.3, 0.0, 0.4, 1.4),
  ];

  @override
  void initState() {
    super.initState();
    final e = widget.initial;
    switch (e.type) {
      case EaseType.bezier:
        _set(e.x1, e.y1, e.x2, e.y2);
      case EaseType.easeIn:
        _set(0.42, 0, 1, 1);
      case EaseType.easeOut:
        _set(0, 0, 0.58, 1);
      case EaseType.linear:
        _set(0, 0, 1, 1);
      default:
        _set(0.33, 0, 0.67, 1);
    }
  }

  void _set(double a, double b, double c, double d) {
    x1 = a;
    y1 = b;
    x2 = c;
    y2 = d;
  }

  // Graph area maps x 0..1 and y -0.5..1.5 to the box.
  Offset _toPx(double x, double y, Size s) => Offset(x * s.width, (1.5 - y) / 2 * s.height);
  (double, double) _fromPx(Offset p, Size s) =>
      ((p.dx / s.width).clamp(0.0, 1.0), (1.5 - p.dy / s.height * 2).clamp(-0.5, 1.5));

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Easing curve', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const Text('Drag the two handles. Steeper = faster.', style: TextStyle(fontSize: 12, color: Colors.white60)),
        const SizedBox(height: 12),
        AspectRatio(
          aspectRatio: 1.4,
          child: LayoutBuilder(builder: (context, box) {
            final size = Size(box.maxWidth, box.maxHeight);
            return GestureDetector(
              onPanStart: (d) {
                final a = _toPx(x1, y1, size), b = _toPx(x2, y2, size);
                _drag = (d.localPosition - a).distance < (d.localPosition - b).distance ? 1 : 2;
              },
              onPanUpdate: (d) {
                final (x, y) = _fromPx(d.localPosition, size);
                setState(() {
                  if (_drag == 1) {
                    x1 = x;
                    y1 = y;
                  } else {
                    x2 = x;
                    y2 = y;
                  }
                });
              },
              onPanEnd: (_) => _drag = null,
              child: CustomPaint(size: size, painter: _CurvePainter(x1, y1, x2, y2, _toPx)),
            );
          }),
        ),
        const SizedBox(height: 8),
        Text('cubic-bezier(${x1.toStringAsFixed(2)}, ${y1.toStringAsFixed(2)}, ${x2.toStringAsFixed(2)}, ${y2.toStringAsFixed(2)})',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white70)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final p in _presets)
            ActionChip(
              label: Text(p.$1, style: const TextStyle(fontSize: 12)),
              onPressed: () => setState(() => _set(p.$2, p.$3, p.$4, p.$5)),
            ),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.pop(context, Easing.bezierCurve(x1, y1, x2, y2)),
            child: const Text('Apply'),
          ),
        ),
      ]),
    );
  }
}

class _CurvePainter extends CustomPainter {
  final double x1, y1, x2, y2;
  final Offset Function(double, double, Size) toPx;
  _CurvePainter(this.x1, this.y1, this.x2, this.y2, this.toPx);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
        Paint()..color = const Color(0xFF1A1D22));
    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    for (final y in [0.0, 1.0]) {
      canvas.drawLine(toPx(0, y, size), toPx(1, y, size), grid);
    }
    final p0 = toPx(0, 0, size), p3 = toPx(1, 1, size);
    final a = toPx(x1, y1, size), b = toPx(x2, y2, size);
    final handle = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1.5;
    canvas.drawLine(p0, a, handle);
    canvas.drawLine(p3, b, handle);
    final e = Easing.bezierCurve(x1, y1, x2, y2);
    final path = Path()..moveTo(p0.dx, p0.dy);
    for (int i = 1; i <= 60; i++) {
      final t = i / 60;
      final q = toPx(t, e.transform(t), size);
      path.lineTo(q.dx, q.dy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = const Color(0xFFFFD54F));
    for (final h in [a, b]) {
      canvas.drawCircle(h, 9, Paint()..color = const Color(0xFF4FC3F7));
    }
  }

  @override
  bool shouldRepaint(covariant _CurvePainter old) => true;
}
