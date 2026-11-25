// BULK (Agent N): multi-selection on the preview — Ctrl/Shift+click, rubber
// band, moving / scaling / rotating the whole selection, and its overlay.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/commands/bulk_commands.dart';
import '../../core/engine/evaluator.dart';
import '../../state/editor_controller.dart';
import 'bulk_actions.dart';

/// Gesture state used by `CompositionView` (calls marked `BULK (Agent N)`).
class BulkPreview {
  final EditorController c;
  BulkPreview(this.c);

  PointerDeviceKind kind = PointerDeviceKind.touch;
  bool _active = false; // a multi-layer drag / pinch is running
  Rect? marquee; // comp px
  Offset _marqueeFrom = Offset.zero;
  List<String> _marqueeBase = const [];
  double _lastScale = 1, _lastRot = 0;
  int _pointers = 1;
  List<double>? _center;
  Offset? _last;

  bool get _mouse => kind == PointerDeviceKind.mouse || kind == PointerDeviceKind.trackpad;
  static bool get _ctrl => HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
  static bool get _shift => HardwareKeyboard.instance.isShiftPressed;

  bool get active => _active || marquee != null;

  /// Tap with Ctrl/Cmd or Shift (or in phone multi-select mode): toggles /
  /// adds [hitId]. Returns true when handled.
  bool onTap(String? hitId) {
    if (!_ctrl && !_shift && !c.multiSelectMode) return false;
    if (hitId == null) return true; // keep the selection
    if (_shift && !_ctrl) {
      if (!c.isSelected(hitId)) c.selectMany([hitId], add: true);
    } else {
      c.toggleSelect(hitId);
    }
    return true;
  }

  /// Gesture start at [comp] (comp px) over [hitId]. Returns true when the
  /// gesture is a multi-layer transform or a rubber band (handled here).
  bool onStart(Offset comp, String? hitId, int pointers, List<RenderItem> items) {
    if (hitId == null && pointers == 1 && (_mouse || c.multiSelectMode)) {
      marquee = Rect.fromPoints(comp, comp);
      _marqueeFrom = comp;
      _marqueeBase = _ctrl || _shift || c.multiSelectMode ? c.selectedLayerIds : const [];
      return true;
    }
    final onSelection = hitId != null ? c.isSelected(hitId) : pointers >= 2;
    if (!c.hasMultiSelection || !onSelection) return false;
    _active = true;
    _last = null;
    _lastScale = 1;
    _lastRot = 0;
    _pointers = pointers;
    final layers = [for (final l in c.selectedLayers) if (!l.locked) l];
    if (layers.isEmpty) {
      _active = false;
      return true;
    }
    final b = BulkCommands.unionBounds(c.comp, layers, c.time);
    _center = [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2];
    c.beginGesture();
    return true;
  }

  void onUpdate(Offset comp, ScaleUpdateDetails d, List<RenderItem> items) {
    if (marquee != null) {
      final r = Rect.fromPoints(_marqueeFrom, comp);
      marquee = r;
      final hit = [
        for (final i in items.reversed)
          if (!i.layer.locked && _box(i).overlaps(r)) i.layer.id,
      ];
      c.selectMany([..._marqueeBase, ...hit], primary: hit.isEmpty ? null : hit.first);
      return;
    }
    if (!_active) return;
    final last = _last ?? comp;
    _last = comp;
    final a = BulkActions(c);
    final delta = comp - last;
    if (delta != Offset.zero) a.nudge(delta.dx, delta.dy, record: false);
    if (d.pointerCount != _pointers) {
      // A finger was added/lifted: scale and rotation restart from here.
      _pointers = d.pointerCount;
      _lastScale = d.scale;
      _lastRot = d.rotation;
    } else if (d.pointerCount >= 2) {
      final k = d.scale / _lastScale;
      final rot = (d.rotation - _lastRot) * 180 / math.pi;
      _lastScale = d.scale;
      _lastRot = d.rotation;
      final cen = _center;
      if (cen != null) {
        cen[0] += delta.dx;
        cen[1] += delta.dy;
      }
      if ((k - 1).abs() > 1e-6 || rot.abs() > 1e-6) a.transform(scale: k, rotate: rot, center: cen, record: false);
    }
  }

  void onEnd() {
    if (_active) c.endGesture();
    _active = false;
    marquee = null;
    _center = null;
    _last = null;
  }

  /// Alt+wheel scales the selection around its centre; Alt+Shift+wheel rotates.
  void onSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || c.selectionCount == 0 || !HardwareKeyboard.instance.isAltPressed) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
      final s = ev as PointerScrollEvent;
      final a = BulkActions(c);
      final dy = s.scrollDelta.dy;
      if (_shift) {
        a.transform(rotate: dy > 0 ? 5 : -5);
      } else {
        a.transform(scale: math.exp(-dy / 600));
      }
    });
  }

  static Rect _box(RenderItem i) {
    final pts = i.corners();
    double x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    for (final p in pts) {
      x0 = math.min(x0, p.x);
      y0 = math.min(y0, p.y);
      x1 = math.max(x1, p.x);
      y1 = math.max(y1, p.y);
    }
    return Rect.fromLTRB(x0, y0, x1, y1);
  }
}

/// Outlines every selected layer (the primary in light blue with handles,
/// the others thinner), the selection's bounding box, and the rubber band.
class BulkSelectionPainter extends CustomPainter {
  final List<RenderItem> items;
  final String? primary;
  final double px; // one screen pixel in comp units
  final Rect? marquee;
  BulkSelectionPainter(this.items, this.primary, this.px, this.marquee);

  @override
  void paint(Canvas canvas, Size size) {
    const blue = Color(0xFF4FC3F7);
    Rect? union;
    for (final item in items) {
      final pts = item.corners();
      final path = Path()..moveTo(pts[0].x, pts[0].y);
      for (final p in pts.skip(1)) {
        path.lineTo(p.x, p.y);
      }
      path.close();
      final isPrimary = item.layer.id == primary;
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (isPrimary ? 1.8 : 1.2) * px
          ..color = isPrimary ? blue : blue.withValues(alpha: 0.75),
      );
      if (isPrimary) {
        final handle = Paint()..color = blue;
        for (final p in pts) {
          canvas.drawRect(Rect.fromCenter(center: Offset(p.x, p.y), width: 8 * px, height: 8 * px), handle);
        }
      }
      final b = BulkPreview._box(item);
      union = union == null ? b : union.expandToInclude(b);
    }
    if (union != null && items.length > 1) {
      _dashed(canvas, union.inflate(6 * px), Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 * px
        ..color = Colors.white70);
      final c = union.center;
      final p = Paint()
        ..color = Colors.white
        ..strokeWidth = 1.2 * px;
      canvas.drawLine(c.translate(-8 * px, 0), c.translate(8 * px, 0), p);
      canvas.drawLine(c.translate(0, -8 * px), c.translate(0, 8 * px), p);
    }
    final m = marquee;
    if (m != null) {
      canvas.drawRect(m, Paint()..color = blue.withValues(alpha: 0.15));
      canvas.drawRect(
          m,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1 * px
            ..color = blue);
    }
  }

  void _dashed(Canvas canvas, Rect r, Paint paint) {
    final dash = 8 * px, gap = 6 * px;
    void line(Offset a, Offset b) {
      final len = (b - a).distance;
      final dir = (b - a) / len;
      for (double s = 0; s < len; s += dash + gap) {
        canvas.drawLine(a + dir * s, a + dir * math.min(len, s + dash), paint);
      }
    }

    line(r.topLeft, r.topRight);
    line(r.topRight, r.bottomRight);
    line(r.bottomRight, r.bottomLeft);
    line(r.bottomLeft, r.topLeft);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
