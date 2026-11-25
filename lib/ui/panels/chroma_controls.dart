// CHROMA (Agent M): "Green screen" controls for video / image layers in the
// layer panel: one-tap key with auto-detected screen colour, eyedropper,
// matte view and the main sliders.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/engine/chroma.dart';
import '../../core/model/layer.dart';
import '../../services/media_bridge.dart';
import '../../state/editor_controller.dart';
import '../common.dart';
import '../preview/fx/chroma_key.dart';
import 'prop_row.dart';

/// Straight RGBA pixels of the layer's picture at the playhead (≤ [maxSize]).
Future<(int, int, Uint8List)?> chromaLayerPixels(EditorController c, Layer l, {int maxSize = 640}) async {
  final a = c.project.media[l.mediaId];
  if (a == null) return null;
  if (l.type == LayerType.video) {
    final t = l.sourceTimeAt(c.time).clamp(0.0, a.duration < 0 ? 0.0 : a.duration).toDouble();
    return MediaBridge.frameAt(a.path, t, maxSize: maxSize);
  }
  final bytes = await File(a.path).readAsBytes();
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final probe = await ui.ImageDescriptor.encoded(buffer);
  final big = probe.width >= probe.height ? probe.width : probe.height;
  final scale = big > maxSize ? maxSize / big : 1.0;
  final codec = await probe.instantiateCodec(
      targetWidth: (probe.width * scale).round().clamp(1, 100000), targetHeight: (probe.height * scale).round().clamp(1, 100000));
  final img = (await codec.getNextFrame()).image;
  codec.dispose();
  probe.dispose();
  buffer.dispose();
  final bd = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  final w = img.width, h = img.height;
  img.dispose();
  if (bd == null) return null;
  return (w, h, bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes));
}

class ChromaControls extends StatelessWidget {
  final EditorController c;
  final Layer layer;
  const ChromaControls({super.key, required this.c, required this.layer});

  Layer get l => layer;

  Effect? get _effect {
    for (final e in l.effects) {
      if (e.type == 'chroma_key') return e;
    }
    return null;
  }

  Future<void> _addKey(BuildContext context) async {
    String color = 'green';
    String msg = 'Green screen keyed (standard green). Use the eyedropper if edges remain.';
    try {
      final px = await chromaLayerPixels(c, l, maxSize: 480);
      if (px != null) {
        final k = await ChromaKeyer.detect(px.$3, px.$1, px.$2);
        if (k != null) {
          color = ChromaMath.hex(k);
          msg = 'Green screen keyed · screen colour $color';
        } else {
          msg = 'No green/blue screen found at the frame edges — using standard green. Pick the colour with the eyedropper.';
        }
      }
    } catch (_) {}
    final err = c.tryRun({'op': 'add_effect', 'layer': l.id, 'effect': 'chroma_key', 'params': {'color': color}});
    if (context.mounted) showSnack(context, err ?? msg);
  }

  Future<void> _autoColor(BuildContext context, Effect e) async {
    final px = await chromaLayerPixels(c, l, maxSize: 480).catchError((_) => null);
    final k = px == null ? null : await ChromaKeyer.detect(px.$3, px.$1, px.$2);
    if (!context.mounted) return;
    if (k == null) {
      showSnack(context, 'No green/blue screen found at the frame edges.');
      return;
    }
    _setColor(context, e, k);
  }

  void _setColor(BuildContext context, Effect e, List<int> rgb) {
    final err = c.tryRun({'op': 'set_effect_param', 'layer': l.id, 'effect': e.id, 'param': 'color', 'value': ChromaMath.hex(rgb)});
    if (err != null && context.mounted) showSnack(context, err);
  }

  Future<void> _eyedropper(BuildContext context, Effect e) async {
    final px = await chromaLayerPixels(c, l, maxSize: 1024).catchError((_) => null);
    if (!context.mounted) return;
    if (px == null) {
      showSnack(context, 'Could not read a frame of this clip.');
      return;
    }
    final picked = await showDialog<List<int>>(context: context, builder: (_) => _EyedropperDialog(px.$1, px.$2, px.$3));
    if (picked != null && context.mounted) _setColor(context, e, picked);
  }

  @override
  Widget build(BuildContext context) {
    final e = _effect;
    if (e == null) {
      return OutlinedButton.icon(
        icon: const Icon(Icons.auto_fix_high, size: 16),
        label: const Text('Green screen'),
        onPressed: () => _addKey(context),
      );
    }
    final v = e.params['color']?.valueAt(c.time) ?? const [0.0, 177.0, 64.0];
    final key = Color.fromARGB(255, v[0].round().clamp(0, 255), v[1].round().clamp(0, 255), v[2].round().clamp(0, 255));
    final matte = (e.params['view']?.valueAt(c.time).first ?? 0).round() == 1;
    PropRow row(String p, String label, double min, double max) =>
        PropRow(c: c, ref: PropRef(l.id, p, effectId: e.id), label: label, min: min, max: max, decimals: 0);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(border: Border.all(color: Colors.white12), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 18, height: 18, decoration: BoxDecoration(color: key, borderRadius: BorderRadius.circular(4))),
          const SizedBox(width: 8),
          Expanded(
            child: Text(e.enabled ? 'Green screen on' : 'Green screen (off)', style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          IconButton(
            tooltip: 'Pick the screen colour from the frame',
            icon: const Icon(Icons.colorize, size: 18),
            onPressed: () => _eyedropper(context, e),
          ),
          IconButton(
            tooltip: 'Detect the screen colour automatically',
            icon: const Icon(Icons.auto_awesome, size: 18),
            onPressed: () => _autoColor(context, e),
          ),
          IconButton(
            tooltip: 'Remove green screen',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => c.tryRun({'op': 'remove_effect', 'layer': l.id, 'effect': e.id}),
          ),
        ]),
        Row(children: [
          const Expanded(child: Text('View matte (white = kept)', style: TextStyle(fontSize: 12.5, color: Colors.white70))),
          Switch(
            value: matte,
            onChanged: (on) =>
                c.tryRun({'op': 'set_effect_param', 'layer': l.id, 'effect': e.id, 'param': 'view', 'value': on ? 'matte' : 'final'}),
          ),
        ]),
        row('tolerance', 'Tolerance', 0, 100),
        row('softness', 'Softness', 0, 100),
        row('spill', 'Spill', 0, 100),
        row('choke', 'Choke', -50, 50),
        if (l.type == LayerType.video)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text('Preview plays the keyed clip at draft size; export is full quality.',
                style: TextStyle(fontSize: 11.5, color: Colors.white38)),
          ),
      ]),
    );
  }
}

/// Shows the frame; tap to pick the screen colour (5×5 average).
class _EyedropperDialog extends StatefulWidget {
  final int w, h;
  final Uint8List rgba;
  const _EyedropperDialog(this.w, this.h, this.rgba);

  @override
  State<_EyedropperDialog> createState() => _EyedropperDialogState();
}

class _EyedropperDialogState extends State<_EyedropperDialog> {
  ui.Image? _img;
  List<int>? _hover;

  @override
  void initState() {
    super.initState();
    ui.decodeImageFromPixels(widget.rgba, widget.w, widget.h, ui.PixelFormat.rgba8888, (img) {
      if (mounted) {
        setState(() => _img = img);
      } else {
        img.dispose();
      }
    });
  }

  @override
  void dispose() {
    _img?.dispose();
    super.dispose();
  }

  List<int> _sample(Offset local, Size box) {
    final x = (local.dx / box.width * widget.w).floor().clamp(0, widget.w - 1);
    final y = (local.dy / box.height * widget.h).floor().clamp(0, widget.h - 1);
    var r = 0, g = 0, b = 0, n = 0;
    for (int dy = -2; dy <= 2; dy++) {
      for (int dx = -2; dx <= 2; dx++) {
        final sx = (x + dx).clamp(0, widget.w - 1), sy = (y + dy).clamp(0, widget.h - 1);
        final o = (sy * widget.w + sx) * 4;
        r += widget.rgba[o];
        g += widget.rgba[o + 1];
        b += widget.rgba[o + 2];
        n++;
      }
    }
    return [r ~/ n, g ~/ n, b ~/ n];
  }

  @override
  Widget build(BuildContext context) {
    final h = _hover;
    return AlertDialog(
      title: const Text('Tap the green screen'),
      content: SizedBox(
        width: 560,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AspectRatio(
            aspectRatio: widget.w / widget.h,
            child: LayoutBuilder(
              builder: (context, cons) => MouseRegion(
                cursor: SystemMouseCursors.precise,
                onHover: (ev) => setState(() => _hover = _sample(ev.localPosition, cons.biggest)),
                child: GestureDetector(
                  onTapUp: (d) => Navigator.pop(context, _sample(d.localPosition, cons.biggest)),
                  child: _img == null ? const ColoredBox(color: Colors.black26) : RawImage(image: _img, fit: BoxFit.fill),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: h == null ? Colors.transparent : Color.fromARGB(255, h[0], h[1], h[2]),
                border: Border.all(color: Colors.white24),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 8),
            Text(h == null ? 'Pick a spot of the screen near the subject' : ChromaMath.hex(h),
                style: const TextStyle(color: Colors.white70)),
          ]),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}
