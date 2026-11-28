import 'dart:async'; // win-43
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerScrollEvent; // win-43
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' show Vector2;

import '../../core/engine/evaluator.dart';
import '../../core/model/camera.dart'; // win-43
import '../../core/model/layer.dart';
import '../../state/editor_controller.dart';
import '../precomp_bar.dart'; // PRECOMP (Agent L)
import '../bulk/bulk_preview.dart'; // BULK (Agent N)
import 'composition_canvas.dart';
import 'preview_quality.dart'; // PERF (Agent O)
import 'gizmo3d.dart'; // win-43

/// Live preview of the composition. Tap a layer to select it, drag to move
/// it, pinch with two fingers to scale and rotate it.
class CompositionView extends StatefulWidget {
  final EditorController controller;
  const CompositionView({super.key, required this.controller});

  /// win-30: the preview's repaint boundary (MCP editor_screenshot captures it).
  static final GlobalKey previewKey = GlobalKey(debugLabel: 'editorPreview');

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

  // win-43 >>> gizmos + camera tools
  GizmoGeom? _geom;
  GizmoView? _gview;
  GizmoHandle? _hot;
  GizmoDrag? _gdrag;
  CameraNav? _nav;
  int _wheelTick = 0;
  // <<< win-43

  // PRECOMP (Agent L): double-tap a comp layer to open it.
  String? _lastTapId;
  DateTime _lastTapAt = DateTime(0);

  @override
  Widget build(BuildContext context) {
    // PRECOMP (Agent L): rebuild when another comp is opened; breadcrumbs on top.
    return ListenableBuilder(listenable: c, builder: (context, _) => Stack(fit: StackFit.passthrough, children: [
      _view(),
      if (c.inPrecomp) Positioned(left: 8, top: 8, child: PrecompBreadcrumbs(c: c)),
      const Positioned(right: 8, bottom: 8, child: PreviewHud()), // PERF (Agent O): quality + FPS meter
    ]));
  }

  Widget _view() {
    return LayoutBuilder(builder: (context, box) {
      final comp = c.comp;
      _viewScale = math.min(box.maxWidth / comp.width, box.maxHeight / comp.height);
      return Center(
        child: RepaintBoundary( // win-30: captured by MCP editor_screenshot
          key: CompositionView.previewKey,
          child: SizedBox(
          width: comp.width * _viewScale,
          height: comp.height * _viewScale,
          child: Listener( // BULK (Agent N): pointer kind (rubber band with a mouse), Alt+wheel scale/rotate
            onPointerDown: (e) => _bulk.kind = e.kind,
            onPointerSignal: (e) { // win-43: wheel dollies with a camera tool
              if (ViewTools.instance.isCameraTool && e is PointerScrollEvent) {
                _wheel(e.scrollDelta.dy);
                return;
              }
              _bulk.onSignal(e);
            },
            onPointerHover: (e) => _hover(_toComp(e.localPosition)), // win-43
            child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _onTap,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: (_) => _onScaleEnd(),
            child: AnimatedBuilder(
              animation: Listenable.merge([c, c.timeNotifier, c.videos, PreviewQuality.instance, ViewTools.instance]), // PERF (Agent O): + quality; win-43: + tools
              builder: (context, _) {
                final t = c.time;
                _items = Evaluator.evaluate(comp, t, velocity: !c.playing); // PERF (Agent O): motion blur is not drawn while playing
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
                    // PERF (Agent O): on-screen pixels per comp pixel → cached 3D layers, photo decode size
                    previewScale: _viewScale * (MediaQuery.maybeDevicePixelRatioOf(context) ?? 1) * PreviewQuality.instance.factor(playing: c.playing),
                    overlay: !c.playing ? _bulkOverlay(selected) : null, // BULK (Agent N): all selected layers
                  ),
                );
              },
            ),
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
      // win-43 >>> transform gizmo on top of the selection outline
      _geom = null;
      final tg = gizmoTargetFor(c, working: false);
      if (tg != null) {
        _gview = activeViewFor(c.comp, c.time, tg);
        _geom = GizmoGeom.build(tg, _gview!, toolFor(tg, ViewTools.instance.tool), 92 / _viewScale);
      }
      final outline = selected == null ? null : CustomPaint(painter: _SelectionPainter(selected, 1 / _viewScale));
      final geom = _geom;
      if (geom == null) return outline;
      return Stack(children: [
        if (outline != null) Positioned.fill(child: outline),
        Positioned.fill(child: CustomPaint(painter: GizmoPainter(geom, _gdrag?.h ?? _hot, 1 / _viewScale))),
      ]);
      // <<< win-43
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

  // win-43 >>> gizmo + camera tool helpers
  void _hover(Offset p) {
    final g = _geom;
    final h = g?.hit(p, 9 / _viewScale);
    if (h != _hot) setState(() => _hot = h);
  }

  void _ensure3DCamera() {
    if (c.comp.camera.mode == CameraMode.off) c.tryRun({'op': 'set_camera_mode', 'mode': '3d'});
  }

  void _wheel(double dy) {
    _ensure3DCamera();
    final nav = CameraNav(c.comp, c.time, 'dolly', Offset.zero);
    final cmds = nav.update(Offset.zero, wheel: dy * 0.6);
    // One undo step per burst of wheel ticks.
    final tick = ++_wheelTick;
    if (tick == 1 || _wheelTimer == null) c.beginGesture();
    c.tryRun({'op': 'batch', 'commands': cmds}, record: false);
    _wheelTimer?.cancel();
    _wheelTimer = Timer(const Duration(milliseconds: 350), () {
      _wheelTimer = null;
      _wheelTick = 0;
      c.endGesture();
    });
  }

  Timer? _wheelTimer;

  @override
  void dispose() {
    if (_wheelTimer != null) {
      _wheelTimer!.cancel();
      c.endGesture();
    }
    super.dispose();
  }

  bool _startTool(ScaleStartDetails d, Offset compPos) {
    final tools = ViewTools.instance;
    if (d.pointerCount != 1 || c.playing) return false;
    if (tools.isCameraTool) {
      _ensure3DCamera();
      c.beginGesture();
      _nav = CameraNav(c.comp, c.time, tools.tool, d.localFocalPoint / _viewScale);
      return true;
    }
    final g = _geom, v = _gview;
    final h = g?.hit(compPos, 10 / _viewScale);
    if (g == null || v == null || h == null) return false;
    c.beginGesture();
    _gdrag = GizmoDrag(c.comp, c.time, g, h, compPos)..setView(v);
    return true;
  }
  // <<< win-43

  void _onScaleStart(ScaleStartDetails d) {
    final layer = c.selectedLayer;
    final compPos = _toComp(d.localFocalPoint);
    if (_startTool(d, compPos)) { // win-43: gizmo handle or camera tool
      _gestureOnLayer = false;
      setState(() {});
      return;
    }
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
    // win-43 >>> gizmo / camera tool drags
    final nav = _nav, gd = _gdrag;
    if (nav != null || gd != null) {
      final p = _toComp(d.localFocalPoint);
      final cmds = nav != null ? nav.update(p) : gd!.update(p);
      if (cmds.isNotEmpty) c.tryRun({'op': 'batch', 'commands': cmds}, record: false);
      return;
    }
    // <<< win-43
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
    if (_nav != null || _gdrag != null) { // win-43
      _nav = null;
      _gdrag = null;
      c.endGesture();
      setState(() {});
      return;
    }
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
