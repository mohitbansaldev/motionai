import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/model/layer.dart';
import '../../core/model/project.dart' show Ids; // BULK (Agent N)
import '../../state/editor_controller.dart';
import '../common.dart';

const double _headerW = 104;
const double _rulerH = 26;
const double _rowH = 36;
const double _handleW = 16;

enum _Drag { none, scrub, scroll, move, trimIn, trimOut, zoom, marquee } // BULK (Agent N): marquee

/// Layer timeline: ruler + playhead, one row per layer (plus a camera row),
/// drag clips to move, drag edges to trim, pinch to zoom, long-press a row
/// for the layer menu. With a mouse: hover highlights, right-click menu,
/// wheel scrolls (Shift = sideways, Ctrl/Alt = zoom at the pointer).
class TimelineView extends StatefulWidget {
  final EditorController controller;
  final void Function(Layer layer) onLayerMenu;

  /// Right-click on a clip/row (desktop). Falls back to [onLayerMenu].
  final void Function(Layer layer, Offset globalPosition)? onLayerContextMenu;
  const TimelineView({super.key, required this.controller, required this.onLayerMenu, this.onLayerContextMenu});

  @override
  State<TimelineView> createState() => TimelineViewState();
}

class _Viewport {
  double pxPerSec = 80;
  double scrollX = 0; // seconds offset * pxPerSec
  double scrollY = 0;
  int hoverRow = -2; // -2 = none
  bool hoverClip = false;
  Rect? marquee; // BULK (Agent N): rubber-band rectangle (local px)
}

/// Public so the desktop editor can zoom from buttons and shortcuts.
class TimelineViewState extends State<TimelineView> {
  final _vp = _Viewport();
  _Drag _drag = _Drag.none;
  Layer? _dragLayer;
  double _dragStartX = 0;
  double _origStart = 0, _origEnd = 0;
  double _zoomBase = 80;
  Size _size = Size.zero;

  // BULK (Agent N) >>> multi-selection drag state
  PointerDeviceKind _pointerKind = PointerDeviceKind.touch;
  final Map<String, (double, double)> _origTimes = {}; // id → (start, end) at drag start
  List<String> _marqueeBase = const [];
  Offset _marqueeFrom = Offset.zero;
  bool get _mouse => _pointerKind == PointerDeviceKind.mouse || _pointerKind == PointerDeviceKind.trackpad;
  bool get _ctrl => HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
  bool get _shift => HardwareKeyboard.instance.isShiftPressed;

  /// Layers whose clip touches the rubber band [r].
  List<String> _inMarquee(Rect r) {
    final out = <String>[];
    for (int i = 0; i < c.comp.layers.length; i++) {
      final l = c.comp.layers[i];
      final top = _rulerH + (i + 1) * _rowH - _vp.scrollY;
      final clip = Rect.fromLTRB(_xAtTime(l.start), top + 4, _xAtTime(l.end), top + _rowH - 4);
      if (clip.overlaps(r)) out.add(l.id);
    }
    return out;
  }

  /// The layers a drag on [l] moves / trims: the whole selection when [l] is part of it.
  List<Layer> _dragSet(Layer l) {
    if (!c.hasMultiSelection || !c.isSelected(l.id)) return [l];
    return [for (final o in c.selectedLayers) if (!o.locked) o];
  }
  // <<< BULK (Agent N)

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

  double get pxPerSec => _vp.pxPerSec;

  /// Zooms by [factor] keeping the time under [focusX] (default: playhead) still.
  void zoomBy(double factor, {double? focusX}) {
    if (_size.width == 0) return;
    final fx = focusX ?? _xAtTime(c.time).clamp(_headerW, _size.width).toDouble();
    final focusT = _timeAtX(fx);
    _vp.pxPerSec = (_vp.pxPerSec * factor).clamp(8.0, 800.0).toDouble();
    _vp.scrollX = focusT * _vp.pxPerSec - (fx - _headerW);
    _clampScroll();
    setState(() {});
  }

  /// Shows the whole composition.
  void zoomToFit() {
    if (_size.width == 0) return;
    final w = math.max(60.0, _size.width - _headerW - 40);
    _vp.pxPerSec = (w / math.max(0.5, c.comp.duration)).clamp(8.0, 800.0).toDouble();
    _vp.scrollX = 0;
    _clampScroll();
    setState(() {});
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (ev) {
      final s = ev as PointerScrollEvent;
      final kb = HardwareKeyboard.instance;
      final dy = s.scrollDelta.dy, dx = s.scrollDelta.dx;
      if (kb.isControlPressed || kb.isAltPressed) {
        zoomBy(math.exp(-dy / 300), focusX: math.max(_headerW, s.localPosition.dx));
        return;
      }
      final contentH = (c.comp.layers.length + 1) * _rowH;
      final overflowY = contentH > _size.height - _rulerH;
      if (kb.isShiftPressed || !overflowY || s.localPosition.dy < _rulerH) {
        _vp.scrollX += dy + dx;
      } else {
        _vp.scrollY += dy;
        _vp.scrollX += dx;
      }
      _clampScroll();
      setState(() {});
    });
  }

  void _onHover(PointerHoverEvent e) {
    final p = e.localPosition;
    final row = _rowAt(p.dy);
    final l = _layerForRow(row);
    final onClip = l != null && p.dx > _headerW && p.dx >= _xAtTime(l.start) && p.dx <= _xAtTime(l.end);
    if (row != _vp.hoverRow || onClip != _vp.hoverClip) {
      setState(() {
        _vp.hoverRow = row;
        _vp.hoverClip = onClip;
      });
    }
    final cursor = _cursorAt(p);
    if (cursor != _cursor) setState(() => _cursor = cursor);
  }

  MouseCursor _cursor = SystemMouseCursors.basic;

  MouseCursor _cursorAt(Offset p) {
    if (p.dx <= _headerW) return SystemMouseCursors.click;
    final row = _rowAt(p.dy);
    if (row == -1) return SystemMouseCursors.resizeColumn;
    final l = _layerForRow(row);
    if (l == null || l.locked) return SystemMouseCursors.basic;
    final x0 = _xAtTime(l.start), x1 = _xAtTime(l.end);
    if (c.isSelected(l.id) && ((p.dx - x0).abs() < _handleW * 0.6 || (p.dx - x1).abs() < _handleW * 0.6)) {
      return SystemMouseCursors.resizeLeftRight;
    }
    if (p.dx >= x0 && p.dx <= x1) return SystemMouseCursors.grab;
    return SystemMouseCursors.basic;
  }

  void _onSecondaryTap(TapUpDetails d) {
    final row = _rowAt(d.localPosition.dy);
    if (row == 0) {
      c.selectCamera();
      return;
    }
    final l = _layerForRow(row);
    if (l == null) return;
    if (!c.isSelected(l.id)) c.select(l.id); // BULK (Agent N): keep a multi-selection for its menu
    final cb = widget.onLayerContextMenu;
    if (cb != null) {
      cb(l, d.globalPosition);
    } else {
      widget.onLayerMenu(l);
    }
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
    // BULK (Agent N) >>> Ctrl/Cmd+click toggles, Shift+click selects a range, multi-select mode toggles.
    if (l != null && (_ctrl || c.multiSelectMode)) {
      c.toggleSelect(l.id);
      return;
    }
    if (l != null && _shift) {
      c.selectRange(l.id);
      return;
    }
    if (l == null && (_ctrl || _shift || c.multiSelectMode)) return;
    // <<< BULK (Agent N)
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
    // BULK (Agent N): on a touch screen long-press starts multi-select mode (checkboxes).
    if (l != null && !_mouse) {
      HapticFeedback.mediumImpact();
      if (!c.multiSelectMode) {
        c.setMultiSelectMode(true);
        c.selectMany([l.id], add: true);
      } else {
        c.toggleSelect(l.id);
      }
      return;
    }
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
        final selected = c.isSelected(l.id); // BULK (Agent N): any selected clip has trim handles
        if (p.dx < x0 + _handleW && selected) {
          _drag = _Drag.trimIn;
        } else if (p.dx > x1 - _handleW && selected) {
          _drag = _Drag.trimOut;
        } else {
          _drag = _Drag.move;
        }
        // BULK (Agent N) >>> keep a multi-selection; Alt+drag duplicates first and drags the copies.
        if (!c.isSelected(l.id)) c.select(l.id);
        c.beginGesture();
        if (_drag == _Drag.move && HardwareKeyboard.instance.isAltPressed) {
          final copies = {for (final o in _dragSet(l)) o.id: Ids.next('L')};
          final err = c.tryRun({
            'op': 'batch',
            'commands': [for (final e in copies.entries) {'op': 'duplicate_layer', 'layer': e.key, 'new_id': e.value}],
          }, record: false);
          if (err == null) {
            c.selectMany(copies.values, primary: copies[l.id]);
            _dragLayer = c.comp.layerById(copies[l.id]!) ?? l;
          }
        }
        _origTimes
          ..clear()
          ..addAll({for (final o in _dragSet(_dragLayer!)) o.id: (o.start, o.end)});
        // <<< BULK (Agent N)
        return;
      }
    }
    // BULK (Agent N): rubber band with a mouse (or in phone multi-select mode) on empty space.
    if (row >= 0 && p.dx > _headerW && (_mouse || c.multiSelectMode)) {
      _drag = _Drag.marquee;
      _marqueeFrom = p;
      _marqueeBase = _ctrl || _shift || c.multiSelectMode ? c.selectedLayerIds : const [];
      _vp.marquee = Rect.fromPoints(p, p);
      return;
    }
    _drag = _Drag.scroll;
  }

  double _snap(double t, Layer self) {
    final threshold = 8 / _vp.pxPerSec;
    final candidates = <double>[0, c.time];
    for (final o in c.comp.layers) {
      if (o.id == self.id || _origTimes.containsKey(o.id)) continue; // BULK (Agent N): not to clips moving along
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
      case _Drag.marquee: // BULK (Agent N)
        final r = Rect.fromPoints(_marqueeFrom, p);
        setState(() => _vp.marquee = r);
        final hit = _inMarquee(r);
        c.selectMany([..._marqueeBase, ...hit], primary: hit.isEmpty ? null : hit.first);
        break;
      case _Drag.move when _origTimes.length > 1: // BULK (Agent N): move every selected clip together
        final l = _dragLayer!;
        final dt = (p.dx - _dragStartX) / _vp.pxPerSec;
        final minStart = _origTimes.values.map((v) => v.$1).reduce(math.min);
        var ns = _origStart + math.max(dt, -minStart);
        final snappedStart = _snap(ns, l);
        final snappedEnd = _snap(ns + l.duration, l);
        ns = (snappedStart - ns).abs() <= (snappedEnd - (ns + l.duration)).abs() ? snappedStart : snappedEnd - l.duration;
        final shift = math.max(ns - _origStart, -minStart);
        c.tryRun({
          'op': 'batch',
          'commands': [
            for (final e in _origTimes.entries) {'op': 'update_layer', 'layer': e.key, 'start': math.max(0.0, e.value.$1 + shift)},
          ],
        }, record: false);
        break;
      case _Drag.trimIn when _origTimes.length > 1: // BULK (Agent N): trim every selected clip by the same amount
        final dt = _snap(_origStart + (p.dx - _dragStartX) / _vp.pxPerSec, _dragLayer!) - _origStart;
        c.tryRun({
          'op': 'batch',
          'commands': [
            for (final e in _origTimes.entries)
              {'op': 'trim_layer', 'layer': e.key, 'in': (e.value.$1 + dt).clamp(0.0, e.value.$2 - c.comp.frameDuration)},
          ],
        }, record: false);
        break;
      case _Drag.trimOut when _origTimes.length > 1: // BULK (Agent N)
        final dt = _snap(_origEnd + (p.dx - _dragStartX) / _vp.pxPerSec, _dragLayer!) - _origEnd;
        c.tryRun({
          'op': 'batch',
          'commands': [
            for (final e in _origTimes.entries)
              {'op': 'trim_layer', 'layer': e.key, 'out': math.max(e.value.$2 + dt, e.value.$1 + c.comp.frameDuration)},
          ],
        }, record: false);
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
    if (_drag == _Drag.marquee) setState(() => _vp.marquee = null); // BULK (Agent N)
    _origTimes.clear(); // BULK (Agent N)
    _drag = _Drag.none;
    _dragLayer = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      _size = Size(box.maxWidth, box.maxHeight);
      return Listener(
        onPointerSignal: _onPointerSignal,
        onPointerDown: (e) => _pointerKind = e.kind, // BULK (Agent N)
        child: MouseRegion(
          cursor: _cursor,
          onHover: _onHover,
          onExit: (_) => setState(() => _vp.hoverRow = -2),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _onTapUp,
            onSecondaryTapUp: _onSecondaryTap,
            onLongPressStart: _onLongPress,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            child: CustomPaint(
              size: _size,
              painter: _TimelinePainter(c, _vp, Listenable.merge([c, c.timeNotifier])),
            ),
          ),
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
  static final _hover = Paint()..color = const Color(0x0FFFFFFF);

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
      if (r == vp.hoverRow) canvas.drawRect(Rect.fromLTWH(0, top, size.width, _rowH), _hover);
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
      final selected = r == 0 ? c.cameraSelected : c.isSelected(comp.layers[r - 1].id); // BULK (Agent N)
      if (selected) {
        canvas.drawRect(Rect.fromLTWH(0, top, _headerW, _rowH), Paint()..color = const Color(0xFF2B3442));
      }
      final name = r == 0 ? 'Camera · ${comp.camera.mode.name}' : comp.layers[r - 1].name;
      final l = r == 0 ? null : comp.layers[r - 1];
      // BULK (Agent N): checkboxes in phone multi-select mode.
      final box = c.multiSelectMode && l != null;
      if (box) _checkbox(canvas, Offset(6, top + _rowH / 2 - 7), selected);
      _text(canvas, name, Offset(box ? 26 : 8, top + 10), _headerW - (box ? 32 : 14),
          color: (l != null && !l.visible) ? Colors.white30 : Colors.white70, size: 11.5);
    }
    canvas.restore();

    // BULK (Agent N): rubber band.
    final m = vp.marquee;
    if (m != null) {
      canvas.drawRect(m, Paint()..color = const Color(0x334FC3F7));
      canvas.drawRect(
          m,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = const Color(0xFF4FC3F7));
    }

    _rulerAndPlayhead(canvas, size);
  }

  // BULK (Agent N)
  void _checkbox(Canvas canvas, Offset at, bool on) {
    final r = RRect.fromRectAndRadius(at & const Size(14, 14), const Radius.circular(3));
    if (on) {
      canvas.drawRRect(r, Paint()..color = const Color(0xFF8B6CFF));
      final tick = Path()
        ..moveTo(at.dx + 3, at.dy + 7)
        ..lineTo(at.dx + 6, at.dy + 10)
        ..lineTo(at.dx + 11, at.dy + 4);
      canvas.drawPath(
          tick,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = Colors.white);
    } else {
      canvas.drawRRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = Colors.white54);
    }
  }

  void _cameraRow(Canvas canvas, Size size, double top) {
    final keys = c.comp.camera.allKeyframeTimes();
    final y = top + _rowH / 2;
    for (final t in keys) {
      _diamond(canvas, Offset(x(t), y), const Color(0xFFFFD54F));
    }
  }

  void _layerRow(Canvas canvas, Size size, Layer l, double top) {
    final selected = c.isSelected(l.id); // BULK (Agent N)
    final primary = l.id == c.selectedLayerId;
    final x0 = math.max(_headerW, x(l.start));
    final x1 = x(l.end);
    if (x1 <= _headerW || x(l.start) > size.width) return;
    final rect = RRect.fromRectAndRadius(Rect.fromLTRB(x0, top + 4, x1, top + _rowH - 4), const Radius.circular(5));
    final base = layerColor(l.type);
    canvas.drawRRect(rect, Paint()..color = l.visible ? base.withValues(alpha: 0.85) : base.withValues(alpha: 0.3));
    if (!selected && vp.hoverClip && vp.hoverRow == c.comp.indexOf(l.id) + 1) {
      canvas.drawRRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2
            ..color = Colors.white54);
    }
    if (selected) {
      canvas.drawRRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = primary ? Colors.white : const Color(0xFF4FC3F7)); // BULK (Agent N): primary white, others blue
      final hp = Paint()..color = primary ? Colors.white : const Color(0xFF4FC3F7);
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
