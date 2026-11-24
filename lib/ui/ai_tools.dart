import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../ai/ai_client.dart';
import '../ai/ai_settings.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../services/media_bridge.dart';
import '../state/editor_controller.dart';
import 'common.dart';
import 'theme.dart';

/// AI image tools for the selected layer: remove background, erase object,
/// clean plate for static video shots.
class AiTools {
  static Future<String> _dir(EditorController c) => c.storage.mediaDir();

  static MediaAsset _asset(String path, String name, int w, int h) =>
      MediaAsset(id: Ids.next('img'), type: MediaType.image, path: path, name: name, width: w.toDouble(), height: h.toDouble());

  /// Remove background: keep subject, keep background, or split into two layers.
  static Future<void> removeBackground(BuildContext context, EditorController c, Layer l) async {
    final media = c.project.media[l.mediaId];
    if (media == null || l.type != LayerType.image) return;
    final mode = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Remove background', style: TextStyle(fontWeight: FontWeight.w800))),
          ListTile(leading: const Icon(Icons.person_outline), title: const Text('Keep the subject'), onTap: () => Navigator.pop(ctx, 'subject')),
          ListTile(leading: const Icon(Icons.landscape_outlined), title: const Text('Keep only the background'), subtitle: const Text('Subject area is filled in'), onTap: () => Navigator.pop(ctx, 'background')),
          ListTile(leading: const Icon(Icons.layers_outlined), title: const Text('Split into two layers'), subtitle: const Text('Subject on top of the background — great for depth & text behind'), onTap: () => Navigator.pop(ctx, 'split')),
        ]),
      ),
    );
    if (mode == null || !context.mounted) return;
    final done = _busy(context, 'Cutting out with on-device AI…');
    try {
      final dir = await _dir(c);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final fgPath = '$dir/cut_${stamp}_fg.png', bgPath = '$dir/cut_${stamp}_bg.jpg';
      final (w, h) = await MediaBridge.cutout(media.path, fgPath, bgPath);
      final fg = _asset(fgPath, '${media.name} (subject)', w, h);
      final bg = _asset(bgPath, '${media.name} (background)', w, h);
      c.project.media[fg.id] = fg;
      c.project.media[bg.id] = bg;
      c.mediaChanged();
      final cmds = <Map<String, dynamic>>[];
      if (mode == 'subject') cmds.add({'op': 'replace_media', 'layer': l.id, 'media': fg.id});
      if (mode == 'background') cmds.add({'op': 'replace_media', 'layer': l.id, 'media': bg.id});
      if (mode == 'split') {
        final topId = '${l.id}_subject';
        cmds.addAll([
          {'op': 'duplicate_layer', 'layer': l.id, 'new_id': topId},
          {'op': 'replace_media', 'layer': topId, 'media': fg.id},
          {'op': 'update_layer', 'layer': topId, 'name': '${l.name} subject'},
          {'op': 'replace_media', 'layer': l.id, 'media': bg.id},
        ]);
      }
      final err = c.tryRun({'op': 'batch', 'commands': cmds});
      done();
      if (context.mounted) showSnack(context, err ?? 'Background removed');
    } catch (e) {
      done();
      if (context.mounted) showSnack(context, 'Cut-out failed: $e');
    }
  }

  /// Erase an object from a photo layer (brush over it).
  static Future<void> eraseObject(BuildContext context, EditorController c, Layer l) async {
    final media = c.project.media[l.mediaId];
    if (media == null || l.type != LayerType.image) return;
    final out = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => EraseScreen(imagePath: media.path, workDir: c.storage.mediaDir)),
    );
    if (out == null || !context.mounted) return;
    final img = await _size(out);
    final a = _asset(out, '${media.name} (erased)', img.$1, img.$2);
    c.project.media[a.id] = a;
    c.mediaChanged();
    final err = c.tryRun({'op': 'replace_media', 'layer': l.id, 'media': a.id});
    if (context.mounted) showSnack(context, err ?? 'Object erased. Undo brings it back.');
  }

  /// Static video shot: grab the frame at the playhead, erase, and lay the
  /// cleaned frame over the video for the length of the clip.
  static Future<void> cleanPlate(BuildContext context, EditorController c, Layer l) async {
    final media = c.project.media[l.mediaId];
    if (media == null || l.type != LayerType.video) return;
    final t = l.isActiveAt(c.time) ? c.time : l.start;
    final frame = await MediaBridge.frameAt(media.path, l.sourceTimeAt(t).clamp(0.0, media.duration), maxSize: 2048);
    if (frame == null) {
      if (context.mounted) showSnack(context, 'Could not read a frame from this video.');
      return;
    }
    final dir = await _dir(c);
    final framePath = '$dir/plate_${DateTime.now().millisecondsSinceEpoch}.png';
    await _writePng(framePath, frame.$3, frame.$1, frame.$2);
    if (!context.mounted) return;
    final out = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => EraseScreen(imagePath: framePath, workDir: c.storage.mediaDir)),
    );
    if (out == null || !context.mounted) return;
    final a = _asset(out, '${media.name} (clean plate)', frame.$1, frame.$2);
    c.project.media[a.id] = a;
    c.mediaChanged();
    final id = '${l.id}_plate';
    final cmds = <Map<String, dynamic>>[
      {'op': 'duplicate_layer', 'layer': l.id, 'new_id': id},
      {'op': 'replace_media', 'layer': id, 'media': a.id},
      {'op': 'update_layer', 'layer': id, 'name': '${l.name} clean plate'},
      {'op': 'update_layer', 'layer': l.id, 'visible': false},
    ];
    final err = c.tryRun({'op': 'batch', 'commands': cmds});
    if (context.mounted) {
      showSnack(context, err ?? 'Clean plate added above the clip (the original clip is hidden; its sound still plays).');
    }
  }

  static Future<(int, int)> _size(String path) async {
    final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
    final f = await codec.getNextFrame();
    final r = (f.image.width, f.image.height);
    f.image.dispose();
    return r;
  }

  static Future<void> _writePng(String path, List<int> rgba, int w, int h) async {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba is Uint8List ? rgba : Uint8List.fromList(rgba), w, h, ui.PixelFormat.rgba8888, done.complete);
    final img = await done.future;
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    await File(path).writeAsBytes(data!.buffer.asUint8List());
  }

  static VoidCallback _busy(BuildContext context, String msg) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(children: [
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 16),
          Expanded(child: Text(msg)),
        ]),
      ),
    );
    var closed = false;
    return () {
      if (!closed && context.mounted) {
        closed = true;
        Navigator.of(context, rootNavigator: true).pop();
      }
    };
  }
}

/// Brush over what to remove; returns the path of the cleaned image.
class EraseScreen extends StatefulWidget {
  final String imagePath;
  final Future<String> Function() workDir;
  const EraseScreen({super.key, required this.imagePath, required this.workDir});

  @override
  State<EraseScreen> createState() => _EraseScreenState();
}

class _EraseScreenState extends State<EraseScreen> {
  ui.Image? _img;
  final List<List<Offset>> _strokes = []; // image pixel coordinates
  final List<double> _widths = [];
  double _brush = 40;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    () async {
      final codec = await ui.instantiateImageCodec(await File(widget.imagePath).readAsBytes());
      final f = await codec.getNextFrame();
      if (mounted) setState(() => _img = f.image);
    }();
  }

  @override
  void dispose() {
    _img?.dispose();
    super.dispose();
  }

  /// Renders the mask at image size: [forOpenAI] → transparent where erased
  /// (opaque elsewhere); otherwise white strokes on black.
  Future<String> _mask({required bool forOpenAI}) async {
    final img = _img!;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    final size = Size(img.width.toDouble(), img.height.toDouble());
    canvas.drawRect(Offset.zero & size, Paint()..color = forOpenAI ? Colors.black : Colors.black);
    final paint = Paint()
      ..color = forOpenAI ? Colors.transparent : Colors.white
      ..blendMode = forOpenAI ? BlendMode.clear : BlendMode.srcOver
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (int i = 0; i < _strokes.length; i++) {
      paint.strokeWidth = _widths[i];
      final s = _strokes[i];
      if (s.length == 1) {
        canvas.drawCircle(s.first, _widths[i] / 2, paint..style = PaintingStyle.fill);
        paint.style = PaintingStyle.stroke;
      } else {
        final path = Path()..moveTo(s.first.dx, s.first.dy);
        for (final p in s.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path, paint);
      }
    }
    final mask = await rec.endRecording().toImage(img.width, img.height);
    final data = await mask.toByteData(format: ui.ImageByteFormat.png);
    mask.dispose();
    final path = '${await widget.workDir()}/mask_${DateTime.now().microsecondsSinceEpoch}.png';
    await File(path).writeAsBytes(data!.buffer.asUint8List());
    return path;
  }

  Future<void> _run({required bool hd}) async {
    if (_strokes.isEmpty) {
      setState(() => _error = 'Brush over what you want to remove first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final dir = await widget.workDir();
      final out = '$dir/erased_${DateTime.now().millisecondsSinceEpoch}';
      String result;
      if (hd) {
        // OpenAI needs PNG input of the same size as the mask.
        final img = _img!;
        final pngData = await img.toByteData(format: ui.ImageByteFormat.png);
        final srcPng = '$out.src.png';
        await File(srcPng).writeAsBytes(pngData!.buffer.asUint8List());
        final mask = await _mask(forOpenAI: true);
        final bytes = await AiClient.editImage(s: await AiSettings.load(), imagePng: srcPng, maskPng: mask);
        result = '$out.png';
        await File(result).writeAsBytes(bytes);
      } else {
        final mask = await _mask(forOpenAI: false);
        result = await MediaBridge.inpaint(widget.imagePath, mask, '$out.jpg');
      }
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final img = _img;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Erase object'),
        actions: [
          IconButton(
            tooltip: 'Undo stroke',
            icon: const Icon(Icons.undo),
            onPressed: _strokes.isEmpty ? null : () => setState(() {
              _strokes.removeLast();
              _widths.removeLast();
            }),
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: img == null
              ? const Center(child: CircularProgressIndicator())
              : LayoutBuilder(builder: (context, box) {
                  final s = (box.maxWidth / img.width).clamp(0.0, box.maxHeight / img.height);
                  final dw = img.width * s, dh = img.height * s;
                  Offset toImg(Offset p) => p / s;
                  return Center(
                    child: SizedBox(
                      width: dw,
                      height: dh,
                      child: GestureDetector(
                        onPanStart: (d) => setState(() {
                          _strokes.add([toImg(d.localPosition)]);
                          _widths.add(_brush / s);
                        }),
                        onPanUpdate: (d) => setState(() => _strokes.last.add(toImg(d.localPosition))),
                        child: CustomPaint(painter: _ErasePainter(img, _strokes, _widths, s)),
                      ),
                    ),
                  );
                }),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          color: MA.surface,
          child: SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                const Text('Brush'),
                Expanded(child: Slider(value: _brush, min: 8, max: 120, onChanged: (v) => setState(() => _brush = v))),
              ]),
              if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12.5)),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => _run(hd: false),
                    icon: const Icon(Icons.phone_android),
                    label: const Text('Erase on phone'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : () => _run(hd: true),
                    icon: _busy
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.auto_fix_high),
                    label: const Text('Erase HD (OpenAI)'),
                  ),
                ),
              ]),
              const SizedBox(height: 4),
              const Text('On phone: free, best for small objects. HD: uses your OpenAI API key.',
                  style: TextStyle(fontSize: 11.5, color: MA.textDim)),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _ErasePainter extends CustomPainter {
  final ui.Image img;
  final List<List<Offset>> strokes;
  final List<double> widths;
  final double scale;
  _ErasePainter(this.img, this.strokes, this.widths, this.scale);

  @override
  void paint(Canvas canvas, Size size) {
    paintImage(canvas: canvas, rect: Offset.zero & size, image: img, fit: BoxFit.fill);
    final paint = Paint()
      ..color = const Color(0x88FF3B6B)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (int i = 0; i < strokes.length; i++) {
      paint.strokeWidth = widths[i] * scale;
      final s = strokes[i];
      final path = Path()..moveTo(s.first.dx * scale, s.first.dy * scale);
      for (final p in s) {
        path.lineTo(p.dx * scale + 0.01, p.dy * scale);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ErasePainter old) => true;
}
