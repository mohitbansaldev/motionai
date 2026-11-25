import 'package:flutter/material.dart';

import '../../core/model/layer.dart';
import '../../core/model/project.dart';
import '../../services/media_bridge.dart';
import '../../services/media_importer.dart';
import '../../state/editor_controller.dart';
import '../common.dart';
import '../doc_kit_sheet.dart';
import '../audio/sound_sheet.dart'; // Sound (Agent K)
import '../library/library_sheet.dart'; // Library & templates (Agent G)
import '../library/template_gallery.dart'; // Library & templates (Agent G)
import '../../core/geo/geo_styles.dart'; // win-40
import '../../core/model/camera.dart'; // win-40

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
        c.select(c.comp.layers.first.id);
        if (mounted) {
          showSnack(context, 'Added ${assets.length} ${kind == MediaType.image ? 'photo' : kind == MediaType.video ? 'video' : 'audio file'}${assets.length == 1 ? '' : 's'}');
        }
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
      (Icons.article_outlined, 'Doc Kit', () => DocKitSheet.open(context, c)),
      (Icons.category_outlined, 'Shapes', () => DocKitSheet.open(context, c, shapes: true)),
      (Icons.public, 'World Map', () => DocKitSheet.open(context, c, component: 'map')),
      (Icons.travel_explore, 'Geo Map (live)', () => _geoMap(context)), // win-40
      (Icons.videocam_outlined, '3D Camera', () => _camera(context)), // win-40
      (Icons.newspaper, 'Article', () => DocKitSheet.open(context, c, component: 'article')),
      (Icons.bolt, 'Title Intro', () => DocKitSheet.open(context, c, component: 'title_slam')),
      (Icons.badge_outlined, 'Name Tag', () => DocKitSheet.open(context, c, component: 'name_tag')),
      (Icons.text_fields, 'Text', () => _add({'op': 'add_layer', 'type': 'text', 'text': 'Your Title', 'start': c.time})),
      (Icons.square_outlined, 'Solid', () => _add({'op': 'add_layer', 'type': 'solid', 'color': '#1E2A44', 'start': c.time})),
      (Icons.control_camera, 'Null', () => _add({'op': 'add_layer', 'type': 'null', 'name': 'Controller', 'start': c.time})),
      (Icons.layers_outlined, 'Parallax', () => _parallax(context)),
      (Icons.view_in_ar_outlined, '3D Photo (AI)', () => _photo3d()),
      (Icons.graphic_eq, 'Sound FX & Beats', () => SoundSheet.open(context, c)), // Sound (Agent K)
      // Library & templates (Agent G)
      (Icons.collections_bookmark_outlined, 'Library', () => LibrarySheet.open(context, c)),
      (Icons.dashboard_customize_outlined, 'Templates', () => TemplateGallery.open(context, c)),
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

  // win-40 >>> live geo map + AE camera dialogs
  Future<void> _geoMap(BuildContext context) async {
    String style = 'dark_political', projection = 'equirectangular';
    final focus = TextEditingController(text: 'India');
    final highlight = TextEditingController(text: 'India');
    double extrude = 18;
    bool fly = true, pitch = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Geo Map (live)'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              DropdownButtonFormField<String>(
                initialValue: style,
                decoration: const InputDecoration(labelText: 'Style', isDense: true),
                items: [for (final st in GeoStyles.all) DropdownMenuItem(value: st.id, child: Text(st.label))],
                onChanged: (v) => set(() => style = v ?? style),
              ),
              DropdownButtonFormField<String>(
                initialValue: projection,
                decoration: const InputDecoration(labelText: 'Projection', isDense: true),
                items: const [
                  DropdownMenuItem(value: 'equirectangular', child: Text('Flat (equirectangular)')),
                  DropdownMenuItem(value: 'natural_earth', child: Text('Natural Earth')),
                  DropdownMenuItem(value: 'mercator', child: Text('Mercator')),
                  DropdownMenuItem(value: 'globe', child: Text('Globe (3D sphere)')),
                ],
                onChanged: (v) => set(() => projection = v ?? projection),
              ),
              TextField(controller: focus, decoration: const InputDecoration(labelText: 'Fly to (country)', isDense: true)),
              TextField(controller: highlight, decoration: const InputDecoration(labelText: 'Highlight (comma separated)', isDense: true)),
              const SizedBox(height: 8),
              Text('3D slab thickness: ${extrude.round()} px', style: const TextStyle(fontSize: 12)),
              Slider(value: extrude, min: 0, max: 60, onChanged: (v) => set(() => extrude = v)),
              CheckboxListTile(dense: true, value: fly, title: const Text('Fly in from the whole world'), onChanged: (v) => set(() => fly = v ?? fly)),
              CheckboxListTile(dense: true, value: pitch, title: const Text('Pitched 3D map (3D camera)'), onChanged: (v) => set(() => pitch = v ?? pitch)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final hs = [for (final h in highlight.text.split(',')) if (h.trim().isNotEmpty) {'code': h.trim(), 'extrude': extrude}];
    final to = focus.text.trim();
    final cmd = <String, dynamic>{
      'op': 'add_geo',
      'style': style,
      'projection': projection,
      'highlight': hs,
      'start': c.time,
      'is3d': pitch,
      'reveal': {'start': c.time + (fly ? 2.2 : 0.3), 'duration': 1.5},
      if (to.isNotEmpty && !fly) 'focus': to,
      if (to.isNotEmpty && fly) 'fly': {'from': [20, 20], 'from_zoom': 1, 'to': to, 'start': c.time, 'duration': 2.5},
    };
    _add(cmd);
    if (pitch) {
      final id = c.selectedLayerId;
      if (id != null) {
        c.tryRun({'op': 'set_property', 'target': id, 'prop': 'rotation', 'value': [38, 0, 0]});
        c.tryRun({'op': 'set_property', 'target': id, 'prop': 'scale', 'value': [150, 150, 100]});
        c.tryRun({'op': 'set_camera', 'type': 'two_node', 'lens_mm': 35, 'aperture': 60, 'focus_lock': true});
      }
    }
  }

  Future<void> _camera(BuildContext context) async {
    final rig = c.comp.camera;
    String type = rig.type;
    double lens = lensForZoom(c.comp.width, rig.props[CamProps.zoom]!.valueAt(c.time)[0]).roundToDouble();
    bool lock = rig.focusLock;
    double blur = rig.props[CamProps.blurLevel]?.valueAt(c.time)[0] ?? 100;
    double aperture = rig.props[CamProps.aperture]!.valueAt(c.time)[0];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('3D Camera'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'one_node', label: Text('One-node')), ButtonSegment(value: 'two_node', label: Text('Two-node'))],
              selected: {type},
              onSelectionChanged: (v) => set(() => type = v.first),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 6, children: [
              for (final mm in kLensPresetsMm)
                ChoiceChip(label: Text('${mm}mm'), selected: lens.round() == mm, onSelected: (_) => set(() => lens = mm.toDouble())),
            ]),
            CheckboxListTile(dense: true, value: lock, title: const Text('Link focus to point of interest'), onChanged: (v) => set(() => lock = v ?? lock)),
            Text('Aperture (depth of field): ${aperture.round()}', style: const TextStyle(fontSize: 12)),
            Slider(value: aperture.clamp(0.0, 200.0), min: 0, max: 200, onChanged: (v) => set(() => aperture = v)),
            Text('Blur level: ${blur.round()} %', style: const TextStyle(fontSize: 12)),
            Slider(value: blur.clamp(0.0, 300.0), min: 0, max: 300, onChanged: (v) => set(() => blur = v)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    _add({'op': 'set_camera', 'type': type, 'lens_mm': lens, 'focus_lock': lock, 'blur_level': blur, 'aperture': aperture});
  }
  // <<< win-40

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
