import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' show Vector2;

import '../../core/engine/evaluator.dart';
import '../../core/model/layer.dart';
import '../../state/editor_controller.dart';
import '../precomp_bar.dart'; // PRECOMP (Agent L)
import '../bulk/bulk_preview.dart'; // BULK (Agent N)
import 'composition_canvas.dart';

/// Live preview of the composition. Tap a layer to select it, drag to move
/// it, pinch with two fingers to scale and rotate it.
class CompositionView extends StatefulWidget {
  final EditorController controller;
  const CompositionView({super.key, required this.controller});

  @override
  State<CompositionView> createState() => _CompositionViewState();
}

class _CompositionViewState extends State<CompositionView> {
  double _viewScale = 1;
  List<RenderItem> _items = const [];

  // Gesture state
  Offset? _lastFocal;
  double _startScale = 100;
  double _startRot = 0;
  bool _gestureOnLayer = false;

  EditorController get c => widget.controller;

  late final BulkPreview _bulk = BulkPreview(c); // BULK (Agent N)

  // PRECOMP (Agent L): double-tap a comp layer to open it.
  String? _lastTapId;
  DateTime _lastTapAt = DateTime(0);

  @override
  Widget build(BuildContext context) {
    // PRECOMP (Agent L): rebuild when another comp is opened; breadcrumbs on top.
    return ListenableBuilder(listenable: c, builder: (context, _) => Stack(fit: StackFit.passthrough, children: [
      _view(),
      if (c.inPrecomp) Positioned(left: 8, top: 8, child: PrecompBreadcrumbs(c: c)),
    ]));
  }

  Widget _view() {
    return LayoutBuilder(builder: (context, box) {
      final comp = c.comp;
      _viewScale = math.min(box.maxWidth / comp.width, box.maxHeight / comp.height);
      return Center(
        child: SizedBox(
          width: comp.width * _viewScale,
          height: comp.height * _viewScale,
          child: Listener( // BULK (Agent N): pointer kind (rubber band with a mouse), Alt+wheel scale/rotate
            onPointerDown: (e) => _bulk.kind = e.kind,
            onPointerSignal: _bulk.onSignal,
            child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _onTap,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: (_) => _onScaleEnd(),
            child: AnimatedBuilder(
              animation: Listenable.merge([c, c.timeNotifier, c.videos]),
              builder: (context, _) {
                final t = c.time;
                _items = Evaluator.evaluate(comp, t);
                final selected = _items.where((i) => i.layer.id == c.selectedLayerId).firstOrNull;
                return FittedBox(
                  fit: BoxFit.contain,
                  child: CompositionCanvas(
                    comp: comp, // PRECOMP (Agent L): the open comp
                    project: c.project,
                    time: t,
                    videos: c.videos,
                    items: _items,
                    draft: true,
                    playing: c.playing,
                    overlay: !c.playing ? _bulkOverlay(selected) : null, // BULK (Agent N): all selected layers
                  ),
                );
              },
            ),
          ),
          ),
        ),
      );
    });
  }

  // BULK (Agent N) >>>
  Widget? _bulkOverlay(RenderItem? selected) {
    if (!c.hasMultiSelection && _bulk.marquee == null) {
      return selected == null ? null : CustomPaint(painter: _SelectionPainter(selected, 1 / _viewScale));
    }
    final items = [for (final i in _items) if (c.isSelected(i.layer.id)) i];
    return CustomPaint(painter: BulkSelectionPainter(items, c.selectedLayerId, 1 / _viewScale, _bulk.marquee));
  }
  // <<< BULK (Agent N)

  Offset _toComp(Offset local) => local / _viewScale;

  RenderItem? _hit(Offset compPos) {
    for (final item in _items.reversed) {
      if (item.layer.locked) continue;
      if (item.containsPoint(compPos.dx, compPos.dy)) return item;
    }
    return null;
  }

  void _onTap(TapUpDetails d) {
    final hit = _hit(_toComp(d.localPosition));
    // PRECOMP (Agent L) >>>
    final now = DateTime.now();
    if (hit != null && hit.layer.type == LayerType.comp && hit.layer.id == _lastTapId &&
        now.difference(_lastTapAt) < const Duration(milliseconds: 400)) {
      _lastTapId = null;
      c.openCompLayer(hit.layer.id);
      return;
    }
    _lastTapId = hit?.layer.id;
    _lastTapAt = now;
    // <<< PRECOMP (Agent L)
    if (_bulk.onTap(hit?.layer.id)) return; // BULK (Agent N): Ctrl/Shift+click, multi-select mode
    c.select(hit?.layer.id);
  }

  void _onScaleStart(ScaleStartDetails d) {
    final layer = c.selectedLayer;
    final compPos = _toComp(d.localFocalPoint);
    final hit = _hit(compPos);
    // BULK (Agent N): rubber band, or move/scale/rotate the whole selection.
    if (_bulk.onStart(compPos, hit?.layer.id, d.pointerCount, _items)) {
      _gestureOnLayer = false;
      setState(() {});
      return;
    }
    // Start dragging only on the selected layer (or select what's under the finger).
    if (layer == null || (hit != null && hit.layer.id != layer.id && d.pointerCount == 1)) {
      if (hit != null) c.select(hit.layer.id);
    }
    final target = c.selectedLayer;
    _gestureOnLayer = target != null && !target.locked;
    if (!_gestureOnLayer) return;
    _lastFocal = d.localFocalPoint;
    _startScale = target!.prop(Props.scale).valueAt(c.time)[0];
    _startRot = target.prop(Props.rotation).valueAt(c.time)[2];
    c.beginGesture();
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_bulk.active) { // BULK (Agent N)
      _bulk.onUpdate(_toComp(d.localFocalPoint), d, _items);
      setState(() {});
      return;
    }
    final layer = c.selectedLayer;
    if (!_gestureOnLayer || layer == null) return;
    final last = _lastFocal ?? d.localFocalPoint;
    var delta = (d.localFocalPoint - last) / _viewScale;
    _lastFocal = d.localFocalPoint;

    if (layer.is3D) {
      // Move in world space at the layer's depth so it tracks the finger.
      final item = _items.where((i) => i.layer.id == layer.id).firstOrNull;
      if (item != null && item.depth > 0) {
        final cam = Evaluator.camera3D(c.comp, c.time);
        delta = delta * (item.depth / cam.zoom);
      }
    }
    final pos = layer.prop(Props.position).valueAt(c.time);
    c.tryRun({
      'op': 'set_property',
      'target': layer.id,
      'prop': 'position',
      'value': [pos[0] + delta.dx, pos[1] + delta.dy, pos[2]],
    }, record: false);

    if (d.pointerCount >= 2) {
      final s = (_startScale * d.scale).clamp(1.0, 5000.0);
      final sc = layer.prop(Props.scale).valueAt(c.time);
      c.tryRun({'op': 'set_property', 'target': layer.id, 'prop': 'scale', 'value': [s, s, sc[2]]}, record: false);
      final r = layer.prop(Props.rotation).valueAt(c.time);
      c.tryRun({
        'op': 'set_property',
        'target': layer.id,
        'prop': 'rotation',
        'value': [r[0], r[1], _startRot + d.rotation * 180 / math.pi],
      }, record: false);
    }
  }

  void _onScaleEnd() {
    if (_bulk.active) { // BULK (Agent N)
      _bulk.onEnd();
      setState(() {});
    }
    if (_gestureOnLayer) c.endGesture();
    _gestureOnLayer = false;
    _lastFocal = null;
  }
}

class _SelectionPainter extends CustomPainter {
  final RenderItem item;
  final double px; // one screen pixel in comp units
  _SelectionPainter(this.item, this.px);

  @override
  void paint(Canvas canvas, Size size) {
    final pts = item.corners();
    final path = Path()..moveTo(pts[0].x, pts[0].y);
    for (final p in pts.skip(1)) {
      path.lineTo(p.x, p.y);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 * px
        ..color = const Color(0xFF4FC3F7),
    );
    final handle = Paint()..color = const Color(0xFF4FC3F7);
    for (final p in pts) {
      canvas.drawRect(Rect.fromCenter(center: Offset(p.x, p.y), width: 8 * px, height: 8 * px), handle);
    }
    // Anchor point crosshair.
    final a = item.layer.prop(Props.anchor).staticValue;
    final ap = item.layer.prop(Props.anchor).isAnimated ? null : item.project(a[0], a[1]);
    if (ap != null) _cross(canvas, ap, px);
  }

  void _cross(Canvas canvas, Vector2 p, double px) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5 * px;
    canvas.drawLine(Offset(p.x - 10 * px, p.y), Offset(p.x + 10 * px, p.y), paint);
    canvas.drawLine(Offset(p.x, p.y - 10 * px), Offset(p.x, p.y + 10 * px), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
