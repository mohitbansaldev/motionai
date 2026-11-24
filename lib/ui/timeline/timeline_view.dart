import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/model/layer.dart';
import '../../state/editor_controller.dart';
import '../common.dart';

const double _headerW = 104;
const double _rulerH = 26;
const double _rowH = 36;
const double _handleW = 16;

enum _Drag { none, scrub, scroll, move, trimIn, trimOut, zoom }

/// Layer timeline: ruler + playhead, one row per layer (plus a camera row),
/// drag clips to move, drag edges to trim, pinch to zoom, long-press a row
/// for the layer menu.
class TimelineView extends StatefulWidget {
  final EditorController controller;
  final void Function(Layer layer) onLayerMenu;
  const TimelineView({super.key, required this.controller, required this.onLayerMenu});

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _Viewport {
  double pxPerSec = 80;
  double scrollX = 0; // seconds offset * pxPerSec
  double scrollY = 0;
}

class _TimelineViewState extends State<TimelineView> {
  final _vp = _Viewport();
  _Drag _drag = _Drag.none;
  Layer? _dragLayer;
  double _dragStartX = 0;
  double _origStart = 0, _origEnd = 0;
  double _zoomBase = 80;
  Size _size = Size.zero;

  EditorController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.timeNotifier.addListener(_follow);
  }

  @override
  void dispose() {
    c.timeNotifier.removeListener(_follow);
    super.dispose();
  }

  /// Keeps the playhead in view during playback.
  void _follow() {
    if (!c.playing || _size.width == 0) return;
    final x = c.time * _vp.pxPerSec - _vp.scrollX;
    final w = _size.width - _headerW;
    if (x > w * 0.85 || x < 0) _vp.scrollX = math.max(0.0, c.time * _vp.pxPerSec - w * 0.15);
  }

  double _timeAtX(double x) => (x - _headerW + _vp.scrollX) / _vp.pxPerSec;
  double _xAtTime(double t) => _headerW + t * _vp.pxPerSec - _vp.scrollX;

  /// Row -1 = ruler, 0 = camera, 1.. = layers (comp order, top first).
  int _rowAt(double y) {
    if (y < _rulerH) return -1;
    return ((y - _rulerH + _vp.scrollY) / _rowH).floor();
  }

  Layer? _layerForRow(int row) {
    final i = row - 1;
    if (i < 0 || i >= c.comp.layers.length) return null;
    return c.comp.layers[i];
  }

  void _clampScroll() {
    final contentW = c.comp.duration * _vp.pxPerSec + 120;
    final viewW = math.max(1.0, _size.width - _headerW);
    _vp.scrollX = _vp.scrollX.clamp(0.0, math.max(0.0, contentW - viewW));
    final contentH = (c.comp.layers.length + 1) * _rowH;
    final viewH = math.max(1.0, _size.height - _rulerH);
    _vp.scrollY = _vp.scrollY.clamp(0.0, math.max(0.0, contentH - viewH));
  }

  void _onTapUp(TapUpDetails d) {
    final p = d.localPosition;
    final row = _rowAt(p.dy);
    if (row == -1) {
      if (p.dx > _headerW) c.seek(_timeAtX(p.dx));
      return;
    }
    if (row == 0) {
      c.selectCamera();
      _seekToNearbyKey(c.comp.camera.allKeyframeTimes(), p.dx);
      return;
    }
    final l = _layerForRow(row);
    c.select(l?.id);
    if (l != null) _seekToNearbyKey(l.allKeyframeTimes(), p.dx);
  }

  void _seekToNearbyKey(List<double> times, double x) {
    if (x < _headerW) return;
    for (final t in times) {
      if ((_xAtTime(t) - x).abs() < 10) {
        c.seek(t);
        return;
      }
    }
  }

  void _onLongPress(LongPressStartDetails d) {
    final l = _layerForRow(_rowAt(d.localPosition.dy));
    if (l != null) {
      c.select(l.id);
      widget.onLayerMenu(l);
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    final p = d.localFocalPoint;
    _dragStartX = p.dx;
    if (d.pointerCount >= 2) {
      _drag = _Drag.zoom;
      _zoomBase = _vp.pxPerSec;
      return;
    }
    final row = _rowAt(p.dy);
    if (row == -1 && p.dx > _headerW) {
      _drag = _Drag.scrub;
      c.seek(_timeAtX(p.dx));
      return;
    }
    final l = p.dx > _headerW ? _layerForRow(row) : null;
    if (l != null && !l.locked) {
      final x0 = _xAtTime(l.start), x1 = _xAtTime(l.end);
      if (p.dx >= x0 - _handleW && p.dx <= x1 + _handleW) {
        _dragLayer = l;
        _origStart = l.start;
        _origEnd = l.end;
        if (p.dx < x0 + _handleW && l.id == c.selectedLayerId) {
          _drag = _Drag.trimIn;
        } else if (p.dx > x1 - _handleW && l.id == c.selectedLayerId) {
          _drag = _Drag.trimOut;
        } else {
          _drag = _Drag.move;
        }
        c.select(l.id);
        c.beginGesture();
        return;
      }
    }
    _drag = _Drag.scroll;
  }

  double _snap(double t, Layer self) {
    final threshold = 8 / _vp.pxPerSec;
    final candidates = <double>[0, c.time];
    for (final o in c.comp.layers) {
      if (o.id == self.id) continue;
      candidates
        ..add(o.start)
        ..add(o.end);
    }
    for (final cnd in candidates) {
      if ((cnd - t).abs() < threshold) return cnd;
    }
    return c.comp.snapToFrame(t);
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final p = d.localFocalPoint;
    switch (_drag) {
      case _Drag.zoom:
        final focusT = _timeAtX(p.dx);
        _vp.pxPerSec = (_zoomBase * d.scale).clamp(8.0, 800.0);
        _vp.scrollX = focusT * _vp.pxPerSec - (p.dx - _headerW);
        _clampScroll();
        setState(() {});
        break;
      case _Drag.scrub:
        c.seek(_timeAtX(p.dx));
        break;
      case _Drag.scroll:
        _vp.scrollX -= d.focalPointDelta.dx;
        _vp.scrollY -= d.focalPointDelta.dy;
        _clampScroll();
        setState(() {});
        break;
      case _Drag.move:
        final l = _dragLayer!;
        final dt = (p.dx - _dragStartX) / _vp.pxPerSec;
        var ns = math.max(0.0, _origStart + dt);
        final snappedStart = _snap(ns, l);
        final snappedEnd = _snap(ns + l.duration, l);
        ns = (snappedStart - ns).abs() <= (snappedEnd - (ns + l.duration)).abs()
            ? snappedStart
            : snappedEnd - l.duration;
        c.tryRun({'op': 'update_layer', 'layer': l.id, 'start': math.max(0.0, ns)}, record: false);
        break;
      case _Drag.trimIn:
        final l = _dragLayer!;
        final t = _snap(_origStart + (p.dx - _dragStartX) / _vp.pxPerSec, l);
        c.tryRun({'op': 'trim_layer', 'layer': l.id, 'in': t.clamp(0.0, _origEnd - c.comp.frameDuration)},
            record: false);
        break;
      case _Drag.trimOut:
        final l = _dragLayer!;
        final t = _snap(_origEnd + (p.dx - _dragStartX) / _vp.pxPerSec, l);
        c.tryRun({'op': 'trim_layer', 'layer': l.id, 'out': math.max(t, l.start + c.comp.frameDuration)},
            record: false);
        break;
      case _Drag.none:
        break;
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_drag == _Drag.move || _drag == _Drag.trimIn || _drag == _Drag.trimOut) c.endGesture();
    _drag = _Drag.none;
    _dragLayer = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      _size = Size(box.maxWidth, box.maxHeight);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: _onTapUp,
        onLongPressStart: _onLongPress,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
        child: CustomPaint(
          size: _size,
          painter: _TimelinePainter(c, _vp, Listenable.merge([c, c.timeNotifier])),
        ),
      );
    });
  }
}

class _TimelinePainter extends CustomPainter {
  final EditorController c;
  final _Viewport vp;
  _TimelinePainter(this.c, this.vp, Listenable repaint) : super(repaint: repaint);

  static final _bg = Paint()..color = const Color(0xFF14161A);
  static final _rowAlt = Paint()..color = const Color(0xFF181B20);
  static final _header = Paint()..color = const Color(0xFF1E2127);
  static final _ruler = Paint()..color = const Color(0xFF22252C);

  double x(double t) => _headerW + t * vp.pxPerSec - vp.scrollX;

  @override
  void paint(Canvas canvas, Size size) {
    final comp = c.comp;
    canvas.drawRect(Offset.zero & size, _bg);

    // Rows (clipped below the ruler).
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, _rulerH, size.width, size.height - _rulerH));
    final rows = comp.layers.length + 1;
    for (int r = 0; r < rows; r++) {
      final top = _rulerH + r * _rowH - vp.scrollY;
      if (top > size.height || top + _rowH < _rulerH) continue;
      if (r.isOdd) canvas.drawRect(Rect.fromLTWH(0, top, size.width, _rowH), _rowAlt);
      if (r == 0) {
        _cameraRow(canvas, size, top);
      } else {
        _layerRow(canvas, size, comp.layers[r - 1], top);
      }
    }
    // Beyond composition end.
    final endX = x(comp.duration);
    if (endX < size.width) {
      canvas.drawRect(Rect.fromLTWH(endX, _rulerH, size.width - endX, size.height),
          Paint()..color = Colors.black.withValues(alpha: 0.35));
    }
    canvas.restore();

    // Header column background drawn over clips' left overflow.
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, _rulerH, _headerW, size.height - _rulerH));
    canvas.drawRect(Rect.fromLTWH(0, _rulerH, _headerW, size.height), _header);
    for (int r = 0; r < rows; r++) {
      final top = _rulerH + r * _rowH - vp.scrollY;
      if (top > size.height || top + _rowH < _rulerH) continue;
      final selected = r == 0 ? c.cameraSelected : comp.layers[r - 1].id == c.selectedLayerId;
      if (selected) {
        canvas.drawRect(Rect.fromLTWH(0, top, _headerW, _rowH), Paint()..color = const Color(0xFF2B3442));
      }
      final name = r == 0 ? 'Camera · ${comp.camera.mode.name}' : comp.layers[r - 1].name;
      final l = r == 0 ? null : comp.layers[r - 1];
      _text(canvas, name, Offset(8, top + 10), _headerW - 14,
          color: (l != null && !l.visible) ? Colors.white30 : Colors.white70, size: 11.5);
    }
    canvas.restore();

    _rulerAndPlayhead(canvas, size);
  }

  void _cameraRow(Canvas canvas, Size size, double top) {
    final keys = c.comp.camera.allKeyframeTimes();
    final y = top + _rowH / 2;
    for (final t in keys) {
      _diamond(canvas, Offset(x(t), y), const Color(0xFFFFD54F));
    }
  }

  void _layerRow(Canvas canvas, Size size, Layer l, double top) {
    final selected = l.id == c.selectedLayerId;
    final x0 = math.max(_headerW, x(l.start));
    final x1 = x(l.end);
    if (x1 <= _headerW || x(l.start) > size.width) return;
    final rect = RRect.fromRectAndRadius(Rect.fromLTRB(x0, top + 4, x1, top + _rowH - 4), const Radius.circular(5));
    final base = layerColor(l.type);
    canvas.drawRRect(rect, Paint()..color = l.visible ? base.withValues(alpha: 0.85) : base.withValues(alpha: 0.3));
    if (selected) {
      canvas.drawRRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white);
      final hp = Paint()..color = Colors.white;
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(x(l.start), top + 4, 6, _rowH - 8), const Radius.circular(3)), hp);
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(x1 - 6, top + 4, 6, _rowH - 8), const Radius.circular(3)), hp);
    }
    canvas.save();
    canvas.clipRRect(rect);
    final label = '${l.is3D ? '3D · ' : ''}${l.name}${l.speed != 1 ? '  ${l.speed}x' : ''}';
    _text(canvas, label, Offset(x0 + 8, top + 10), math.max(0.0, x1 - x0 - 12), color: Colors.white, size: 11);
    canvas.restore();
    final y = top + _rowH - 8;
    for (final t in l.allKeyframeTimes()) {
      final kx = x(t);
      if (kx >= _headerW) _diamond(canvas, Offset(kx, y), selected ? const Color(0xFFFFD54F) : Colors.white70, 4);
    }
  }

  void _rulerAndPlayhead(Canvas canvas, Size size) {
    final comp = c.comp;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, _rulerH), _ruler);
    // Choose a tick step that leaves room for labels.
    const steps = [0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0];
    final step = steps.firstWhere((s) => s * vp.pxPerSec >= 70, orElse: () => 120.0);
    final t0 = math.max(0.0, ((vp.scrollX / vp.pxPerSec) / step).floor() * step);
    final tick = Paint()
      ..color = Colors.white30
      ..strokeWidth = 1;
    for (double t = t0; x(t) < size.width; t += step) {
      final tx = x(t);
      if (tx < _headerW) continue;
      canvas.drawLine(Offset(tx, _rulerH - 9), Offset(tx, _rulerH), tick);
      _text(canvas, formatTime(t, comp.fps).substring(t >= 60 ? 0 : 3), Offset(tx + 3, 4), 60,
          color: Colors.white54, size: 9.5);
      final minor = step / 4;
      for (int i = 1; i < 4; i++) {
        final mx = x(t + minor * i);
        canvas.drawLine(Offset(mx, _rulerH - 4), Offset(mx, _rulerH), tick);
      }
    }
    canvas.drawRect(Rect.fromLTWH(0, 0, _headerW, _rulerH), _header);
    _text(canvas, formatTime(c.time, comp.fps), const Offset(8, 6), _headerW - 10, color: Colors.amber, size: 11);

    final px = x(c.time);
    if (px >= _headerW) {
      final p = Paint()
        ..color = const Color(0xFFFF5252)
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(px, 0), Offset(px, size.height), p);
      final tri = Path()
        ..moveTo(px - 6, 0)
        ..lineTo(px + 6, 0)
        ..lineTo(px, 9)
        ..close();
      canvas.drawPath(tri, p);
    }
  }

  void _diamond(Canvas canvas, Offset p, Color color, [double r = 5]) {
    final path = Path()
      ..moveTo(p.dx, p.dy - r)
      ..lineTo(p.dx + r, p.dy)
      ..lineTo(p.dx, p.dy + r)
      ..lineTo(p.dx - r, p.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _text(Canvas canvas, String s, Offset at, double maxW, {required Color color, double size = 11}) {
    if (maxW < 8) return;
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxW);
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter old) => true;
}
