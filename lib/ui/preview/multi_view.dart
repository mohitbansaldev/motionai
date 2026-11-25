// win-40 >>> AFTER EFFECTS VIEW LAYOUTS: 1 / 2 / 4 / 1+3 view panes.
//
// Pane 0 can be the interactive Active Camera view (CompositionView); the
// others are working 3D views (orthographic Front / Left / Top / Back / Right /
// Bottom or perspective Custom View 1-3) that show only 3D layers, a ground
// grid, the comp frame and the 3D camera (body, frustum, point of interest).
// Drag a custom view to orbit it, scroll to dolly.

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

import '../../core/engine/evaluator.dart';
import '../../core/model/camera.dart';
import '../../core/model/project.dart';
import '../../state/editor_controller.dart';
import 'composition_canvas.dart';
import 'composition_view.dart';

class CompositionViews extends StatelessWidget {
  final EditorController controller;
  const CompositionViews({super.key, required this.controller});

  /// All panes together (MCP editor_screenshot captures this when the layout has several views).
  static final GlobalKey viewsKey = GlobalKey(debugLabel: 'editorViews');

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final comp = controller.comp;
        final layout = comp.viewLayout;
        final views = comp.views;
        Widget pane(int i) {
          final kind = i < views.length ? views[i] : 'active';
          // Only one live Active Camera view (its preview key must be unique).
          final Widget body = kind != 'active'
              ? WorkingView(controller: controller, kind: kind)
              : (views.indexOf('active') == i
                  ? CompositionView(controller: controller)
                  : const Center(child: Text('Active Camera is shown in another pane', style: TextStyle(color: Colors.white54, fontSize: 11))));
          return _Pane(controller: controller, index: i, kind: kind, child: body);
        }

        Widget content;
        switch (layout) {
          case '2':
            content = Row(children: [Expanded(child: pane(0)), const SizedBox(width: 2), Expanded(child: pane(1))]);
          case '4':
            content = Column(children: [
              Expanded(child: Row(children: [Expanded(child: pane(0)), const SizedBox(width: 2), Expanded(child: pane(1))])),
              const SizedBox(height: 2),
              Expanded(child: Row(children: [Expanded(child: pane(2)), const SizedBox(width: 2), Expanded(child: pane(3))])),
            ]);
          case '1+3':
            content = Row(children: [
              Expanded(flex: 3, child: pane(0)),
              const SizedBox(width: 2),
              Expanded(child: Column(children: [Expanded(child: pane(1)), const SizedBox(height: 2), Expanded(child: pane(2)), const SizedBox(height: 2), Expanded(child: pane(3))])),
            ]);
          default:
            content = views.isEmpty || views.first == 'active' ? CompositionView(controller: controller) : pane(0);
        }
        return Stack(fit: StackFit.expand, children: [
          layout == '1' ? content : RepaintBoundary(key: viewsKey, child: content),
          Positioned(top: 6, right: 6, child: _LayoutSwitch(controller: controller)),
        ]);
      },
    );
  }
}

class _LayoutSwitch extends StatelessWidget {
  final EditorController controller;
  const _LayoutSwitch({required this.controller});

  @override
  Widget build(BuildContext context) {
    final cur = controller.comp.viewLayout;
    return Material(
      color: const Color(0xCC15181D),
      borderRadius: BorderRadius.circular(6),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final l in Composition.viewLayouts)
          InkWell(
            onTap: () => controller.tryRun({'op': 'set_view_layout', 'layout': l}, record: false),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(l == '1' ? '1 view' : (l == '1+3' ? '1+3' : '$l views'),
                  style: TextStyle(fontSize: 11, color: l == cur ? const Color(0xFF4FC3F7) : Colors.white70, fontWeight: l == cur ? FontWeight.w700 : FontWeight.w400)),
            ),
          ),
      ]),
    );
  }
}

class _Pane extends StatelessWidget {
  final EditorController controller;
  final int index;
  final String kind;
  final Widget child;
  const _Pane({required this.controller, required this.index, required this.kind, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      ClipRect(child: child),
      Positioned(
        left: 6,
        bottom: 6,
        child: PopupMenuButton<String>(
          tooltip: '3D view',
          initialValue: kind,
          onSelected: (k) {
            final v = List.of(controller.comp.views);
            while (v.length < 4) {
              v.add('active');
            }
            v[index] = k;
            controller.tryRun({'op': 'set_view_layout', 'views': v}, record: false);
          },
          itemBuilder: (_) => [for (final k in ViewCam.kinds) PopupMenuItem(value: k, child: Text(ViewCam.labels[k] ?? k))],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(4)),
            child: Text('${ViewCam.labels[kind] ?? kind} ▾', style: const TextStyle(fontSize: 11, color: Colors.white)),
          ),
        ),
      ),
    ]);
  }
}

/// One working 3D view of the open composition.
class WorkingView extends StatefulWidget {
  final EditorController controller;
  final String kind;
  const WorkingView({super.key, required this.controller, required this.kind});

  @override
  State<WorkingView> createState() => _WorkingViewState();
}

class _WorkingViewState extends State<WorkingView> {
  EditorController get c => widget.controller;

  List<double> _orbit() => c.comp.customViews[widget.kind] ?? List.of(ViewCam.customDefaults[widget.kind] ?? ViewCam.customDefaults['custom1']!);

  void _setOrbit(List<double> o) =>
      c.tryRun({'op': 'set_view_layout', 'custom': {widget.kind: o}}, record: false);

  @override
  Widget build(BuildContext context) {
    final custom = widget.kind.startsWith('custom');
    return LayoutBuilder(builder: (context, box) {
      final comp = c.comp;
      final scale = math.min(box.maxWidth / comp.width, box.maxHeight / comp.height);
      Widget view = AnimatedBuilder(
        animation: Listenable.merge([c, c.timeNotifier]),
        builder: (context, _) {
          final t = c.time;
          ViewCam? vc;
          String? error;
          try {
            vc = ViewCam.build(comp, t, widget.kind, orbit: custom ? _orbit() : null);
          } catch (e) {
            error = '$e';
          }
          if (vc == null) return Center(child: Text(error ?? '', style: const TextStyle(color: Colors.white54, fontSize: 11)));
          final items = Evaluator.evaluate(comp, t, velocity: false, view: vc);
          return FittedBox(
            fit: BoxFit.contain,
            child: Stack(children: [
              SizedBox(width: comp.width, height: comp.height, child: CustomPaint(painter: _GridPainter(vc, comp))),
              CompositionCanvas(
                comp: comp,
                project: c.project,
                time: t,
                videos: c.videos,
                items: items,
                draft: true,
                playing: c.playing,
                nested: true, // transparent: the working view keeps its grey backdrop
                previewScale: scale * (MediaQuery.maybeDevicePixelRatioOf(context) ?? 1),
              ),
              SizedBox(width: comp.width, height: comp.height, child: IgnorePointer(child: CustomPaint(painter: _GizmoPainter(vc, comp, t, c.selectedLayerId)))),
            ]),
          );
        },
      );
      view = ColoredBox(color: const Color(0xFF2A2D33), child: Center(child: view));
      if (!custom) return view;
      return Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) {
            final o = _orbit();
            o[2] = (o[2] * (e.scrollDelta.dy > 0 ? 1.08 : 0.92)).clamp(0.4, 8.0).toDouble();
            _setOrbit(o);
          }
        },
        child: GestureDetector(
          onPanUpdate: (d) {
            final o = _orbit();
            o[0] = o[0] + d.delta.dx * 0.4;
            o[1] = (o[1] + d.delta.dy * 0.3).clamp(-85.0, 85.0).toDouble();
            _setOrbit(o);
          },
          child: view,
        ),
      );
    });
  }
}

/// Ground grid (y = comp bottom plane) and the comp frame at z = 0.
class _GridPainter extends CustomPainter {
  final ViewCam vc;
  final Composition comp;
  _GridPainter(this.vc, this.comp);

  @override
  void paint(Canvas canvas, Size size) {
    final w = comp.width, h = comp.height;
    final grid = Paint()
      ..color = const Color(0x22FFFFFF)
      ..strokeWidth = 1;
    final step = w / 8;
    void line(Vector3 a, Vector3 b, Paint p) {
      final pa = vc.toScreen(a), pb = vc.toScreen(b);
      if (!pa.visible || !pb.visible) return;
      canvas.drawLine(Offset(pa.x, pa.y), Offset(pb.x, pb.y), p);
    }

    for (int i = -8; i <= 16; i++) {
      line(Vector3(i * step, h, -w * 1.5), Vector3(i * step, h, w * 2), grid);
    }
    for (int j = -12; j <= 16; j++) {
      line(Vector3(-w, h, j * step), Vector3(w * 2, h, j * step), grid);
    }
    final frame = Paint()
      ..color = const Color(0x88FFFFFF)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final c = [Vector3(0, 0, 0), Vector3(w, 0, 0), Vector3(w, h, 0), Vector3(0, h, 0)];
    for (int i = 0; i < 4; i++) {
      line(c[i], c[(i + 1) % 4], frame);
    }
    // Axes from the comp centre: X red, Y green, Z blue.
    final o = Vector3(w / 2, h / 2, 0);
    final len = w * 0.08;
    line(o, o + Vector3(len, 0, 0), Paint()..color = const Color(0xFFFF5252)..strokeWidth = 2);
    line(o, o + Vector3(0, -len, 0), Paint()..color = const Color(0xFF69F0AE)..strokeWidth = 2);
    line(o, o + Vector3(0, 0, len), Paint()..color = const Color(0xFF448AFF)..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => true;
}

/// The active 3D camera: body, frustum to its frame at the focus distance,
/// point of interest, plus the selected layer's outline.
class _GizmoPainter extends CustomPainter {
  final ViewCam vc;
  final Composition comp;
  final double t;
  final String? selected;
  _GizmoPainter(this.vc, this.comp, this.t, this.selected);

  @override
  void paint(Canvas canvas, Size size) {
    if (comp.camera.mode != CameraMode.threeD) return;
    final cam = Evaluator.camera3D(comp, t);
    final paint = Paint()
      ..color = const Color(0xFFFFC107)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    Offset? s(Vector3 p) {
      final q = vc.toScreen(p);
      return q.visible ? Offset(q.x, q.y) : null;
    }

    final pos = s(cam.position);
    // Frame of the camera at its zoom distance (the comp-size picture plane).
    final hw = comp.width / 2, hh = comp.height / 2;
    final at = cam.position + cam.forward * cam.zoom;
    final corners = [
      at - cam.right * hw - cam.down * hh,
      at + cam.right * hw - cam.down * hh,
      at + cam.right * hw + cam.down * hh,
      at - cam.right * hw + cam.down * hh,
    ].map(s).toList();
    if (pos != null) {
      for (final cn in corners) {
        if (cn != null) canvas.drawLine(pos, cn, paint..color = const Color(0x99FFC107));
      }
      canvas.drawRect(Rect.fromCenter(center: pos, width: 26, height: 18), Paint()..color = const Color(0xFFFFC107));
    }
    for (int i = 0; i < 4; i++) {
      final a = corners[i], b = corners[(i + 1) % 4];
      if (a != null && b != null) canvas.drawLine(a, b, paint..color = const Color(0xFFFFC107));
    }
    // Point of interest (two-node) / aim point (one-node), and the focus plane distance.
    final poi = s(cam.position + cam.forward * cam.zoom);
    if (pos != null && poi != null) {
      canvas.drawLine(pos, poi, Paint()..color = const Color(0xFFFFFFFF)..strokeWidth = 1);
      canvas.drawCircle(poi, 7, Paint()..color = const Color(0xFFFFFFFF)..style = PaintingStyle.stroke..strokeWidth = 2);
    }
    final focus = s(cam.position + cam.forward * cam.focus);
    if (cam.aperture > 0 && focus != null) {
      canvas.drawCircle(focus, 5, Paint()..color = const Color(0xFF4FC3F7));
    }
    // Selected 3D layer outline.
    final l = selected == null ? null : comp.layerById(selected!);
    if (l != null && l.is3D) {
      final m = Evaluator.worldMatrix(comp, l, t, {});
      final pts = [
        for (final cc in [[0.0, 0.0], [l.width, 0.0], [l.width, l.height], [0.0, l.height]]) s(m.transform3(Vector3(cc[0], cc[1], 0))),
      ];
      final sel = Paint()
        ..color = const Color(0xFF4FC3F7)
        ..strokeWidth = 2;
      for (int i = 0; i < 4; i++) {
        final a = pts[i], b = pts[(i + 1) % 4];
        if (a != null && b != null) canvas.drawLine(a, b, sel);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GizmoPainter old) => true;
}
// <<< win-40
