import 'package:flutter/material.dart';

import '../../core/model/layer.dart';
import '../../core/model/project.dart';
import '../../services/media_bridge.dart';
import '../../services/media_importer.dart';
import '../../state/editor_controller.dart';
import '../common.dart';

/// Add media, text, solids, nulls and the one-tap parallax rig.
class AddPanel extends StatefulWidget {
  final EditorController c;
  const AddPanel({super.key, required this.c});

  @override
  State<AddPanel> createState() => _AddPanelState();
}

class _AddPanelState extends State<AddPanel> {
  bool _busy = false;
  EditorController get c => widget.c;

  Future<void> _importMedia(MediaType kind) async {
    setState(() => _busy = true);
    try {
      final importer = MediaImporter(c.storage);
      final assets = await importer.pick(kind: kind);
      if (importer.errors.isNotEmpty && mounted) {
        showSnack(context, 'Could not import ${importer.errors.join('; ')}');
      }
      if (assets.isEmpty) return;
      for (final a in assets) {
        c.project.media[a.id] = a;
      }
      c.mediaChanged();
      // Place clips one after another starting at the playhead.
      var t = c.time;
      final cmds = <Map<String, dynamic>>[];
      for (final a in assets) {
        cmds.add({
          'op': 'add_layer',
          'type': a.type.name,
          'media': a.id,
          'start': t,
          if (a.type == MediaType.audio) 'index': c.comp.layers.length + cmds.length,
        });
        t += a.type == MediaType.image ? 5 : a.duration;
      }
      final err = c.tryRun({'op': 'batch', 'commands': cmds});
      if (err != null && mounted) showSnack(context, err);
      if (err == null) {
        final r = c.comp.layers.first;
        c.select(r.id);
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Import failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Pick a photo, cut out the subject with on-device AI and build a
  /// parallax shot: blurred-subject background + subject in front.
  Future<void> _photo3d() async {
    setState(() => _busy = true);
    try {
      final importer = MediaImporter(c.storage);
      final picked = await importer.pick(kind: MediaType.image);
      if (picked.isEmpty) {
        if (importer.errors.isNotEmpty && mounted) showSnack(context, 'Could not import ${importer.errors.join('; ')}');
        return;
      }
      final src = picked.first;
      final base = src.path.substring(0, src.path.lastIndexOf('.'));
      final fgPath = '${base}_subject.png', bgPath = '${base}_plate.jpg';
      final (w, h) = await MediaBridge.cutout(src.path, fgPath, bgPath);
      final fg = MediaAsset(id: Ids.next('img'), type: MediaType.image, path: fgPath, name: '${src.name} subject', width: w.toDouble(), height: h.toDouble());
      final bg = MediaAsset(id: Ids.next('img'), type: MediaType.image, path: bgPath, name: '${src.name} background', width: w.toDouble(), height: h.toDouble());
      c.project.media[fg.id] = fg;
      c.project.media[bg.id] = bg;
      c.mediaChanged();
      final stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
      final bgId = 'bg_$stamp', fgId = 'fg_$stamp';
      final err = c.tryRun({
        'op': 'batch',
        'commands': [
          {'op': 'add_layer', 'type': 'image', 'media': bg.id, 'id': bgId, 'start': c.time, 'duration': 5, 'fit': 'cover'},
          {'op': 'add_layer', 'type': 'image', 'media': fg.id, 'id': fgId, 'start': c.time, 'duration': 5, 'fit': 'cover'},
          {'op': 'parallax_rig', 'layers': [bgId, fgId], 'depth': 700, 'push': 450, 'start': c.time, 'duration': 5},
        ],
      });
      if (err != null && mounted) showSnack(context, err);
      if (err == null && mounted) showSnack(context, '3D photo created. Press play.');
    } catch (e) {
      if (mounted) showSnack(context, '3D photo failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _add(Map<String, dynamic> cmd) {
    try {
      final r = c.run(cmd);
      if (r.createdIds.isNotEmpty) c.select(r.createdIds.first);
    } catch (e) {
      showSnack(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tiles = <(IconData, String, VoidCallback)>[
      (Icons.movie_outlined, 'Video', () => _importMedia(MediaType.video)),
      (Icons.image_outlined, 'Image', () => _importMedia(MediaType.image)),
      (Icons.music_note_outlined, 'Music / VO', () => _importMedia(MediaType.audio)),
      (Icons.text_fields, 'Text', () => _add({'op': 'add_layer', 'type': 'text', 'text': 'Your Title'})),
      (Icons.square_outlined, 'Solid', () => _add({'op': 'add_layer', 'type': 'solid', 'color': '#1E2A44'})),
      (Icons.control_camera, 'Null', () => _add({'op': 'add_layer', 'type': 'null', 'name': 'Controller'})),
      (Icons.layers_outlined, 'Parallax', () => _parallax(context)),
      (Icons.view_in_ar_outlined, '3D Photo (AI)', () => _photo3d()),
    ];
    return Stack(children: [
      GridView.count(
        crossAxisCount: 3,
        padding: const EdgeInsets.all(12),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.6,
        children: [
          for (final t in tiles)
            Material(
              color: const Color(0xFF1E2127),
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: _busy ? null : t.$3,
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(t.$1, size: 26),
                  const SizedBox(height: 6),
                  Text(t.$2, style: const TextStyle(fontSize: 12.5)),
                ]),
              ),
            ),
        ],
      ),
      if (_busy) const Center(child: CircularProgressIndicator()),
    ]);
  }

  Future<void> _parallax(BuildContext context) async {
    final candidates = c.comp.layers.where((l) => l.type != LayerType.nullObject && l.type != LayerType.audio).toList();
    if (candidates.isEmpty) {
      showSnack(context, 'Add a background and some foreground layers (PNG cut-outs, text) first.');
      return;
    }
    final picked = <String>{for (final l in candidates) l.id};
    double depth = 500, push = 350, duration = 4;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Parallax rig'),
          content: SizedBox(
            width: 360,
            child: ListView(shrinkWrap: true, children: [
              const Text(
                'Layers are spread in depth: the bottom layer goes farthest back, the top layer stays closest. '
                'The camera then pushes in so near layers move faster.',
                style: TextStyle(fontSize: 12.5, color: Colors.white70),
              ),
              const SizedBox(height: 8),
              for (final l in candidates)
                CheckboxListTile(
                  dense: true,
                  value: picked.contains(l.id),
                  title: Text(l.name, overflow: TextOverflow.ellipsis),
                  secondary: Icon(layerIcon(l.type), size: 18),
                  onChanged: (v) => setD(() => v == true ? picked.add(l.id) : picked.remove(l.id)),
                ),
              Text('Depth between layers: ${depth.round()} px'),
              Slider(value: depth, min: 100, max: 2000, onChanged: (v) => setD(() => depth = v)),
              Text('Camera push: ${push.round()} px'),
              Slider(value: push, min: 0, max: 1500, onChanged: (v) => setD(() => push = v)),
              Text('Duration: ${duration.toStringAsFixed(1)} s'),
              Slider(value: duration, min: 1, max: 15, onChanged: (v) => setD(() => duration = v)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
          ],
        ),
      ),
    );
    if (ok != true || picked.isEmpty) return;
    // Back to front = bottom of the layer stack first.
    final ordered = c.comp.layers.reversed.where((l) => picked.contains(l.id)).map((l) => l.id).toList();
    final err = c.tryRun({
      'op': 'parallax_rig',
      'layers': ordered,
      'depth': depth,
      'push': push,
      'start': c.time,
      'duration': duration,
    });
    if (err != null && context.mounted) showSnack(context, err);
  }
}
