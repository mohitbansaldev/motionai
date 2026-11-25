import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/model/project.dart';
import '../../director/director.dart';
import '../../library/asset_library.dart';
import '../../library/library_tagger.dart';
import '../../state/editor_controller.dart';

/// Small helpers shared by the library sheet, the template gallery and the
/// save-as-template dialog.
class LibUi {
  static const kindLabels = {
    'building': 'Buildings', 'plant': 'Plants', 'grass_strip': 'Grass strips', 'sky': 'Skies', 'ground': 'Ground',
    'prop': 'Props', 'person': 'People', 'animal': 'Animals', 'vehicle': 'Vehicles', 'icon': 'Icons', 'texture': 'Textures',
    'interior': 'Interiors', 'map': 'Maps', 'document': 'Documents', 'logo': 'Logos',
    'plate': 'Plates', 'overlay': 'Overlays', 'set_piece': 'Set pieces', // V2-F
  };

  static final Map<String, Uint8List?> _videoThumbs = {};

  /// Square-ish preview of a library asset (images from disk, videos via a frame).
  static Widget assetThumb(AssetLibrary lib, LibraryAsset a, {double size = 96}) {
    final path = lib.pathOf(a);
    Widget child;
    if (a.type == MediaType.image) {
      child = Image.file(File(path), cacheWidth: (size * 2).round(), fit: BoxFit.contain, errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined));
    } else if (a.type == MediaType.video) {
      child = FutureBuilder<Uint8List?>(
        future: _videoThumbs.containsKey(a.id) ? Future.value(_videoThumbs[a.id]) : Director.thumbnail(LibraryTagger.asMedia(lib, a), size: 256).then((b) => _videoThumbs[a.id] = b),
        builder: (_, s) => s.data == null ? const Icon(Icons.movie_outlined) : Image.memory(s.data!, fit: BoxFit.cover),
      );
    } else {
      child = const Icon(Icons.music_note_outlined);
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        // Checkerboard-ish dark backdrop so cut-outs read as cut-outs.
        color: a.transparent ? const Color(0xFF3A3F4B) : const Color(0xFF15171C),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: child,
    );
  }

  static Widget mediaThumb(MediaAsset m, {double size = 64}) {
    Widget child;
    if (m.type == MediaType.image) {
      child = Image.file(File(m.path), cacheWidth: (size * 2).round(), fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(Icons.image_outlined));
    } else {
      child = Icon(m.type == MediaType.video ? Icons.movie_outlined : Icons.music_note_outlined);
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), color: const Color(0xFF15171C)),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: child,
    );
  }

  static bool typeMatches(MediaType t, String want) => switch (want) {
        'image' => t == MediaType.image,
        'video' => t == MediaType.video,
        'audio' => t == MediaType.audio,
        _ => t != MediaType.audio,
      };

  /// Imports every `lib:<id>` value in [values] into the project and returns
  /// the values with project media ids.
  static Future<Map<String, dynamic>> resolveLibrary(EditorController c, Map<String, dynamic> values) async {
    final out = <String, dynamic>{};
    AssetLibrary? lib;
    String? dir;
    Future<String> one(String v) async {
      if (!v.startsWith('lib:')) return v;
      lib ??= await AssetLibrary.shared();
      dir ??= await c.storage.mediaDir();
      return (await lib!.importInto(c.project, v, mediaDir: dir!)).id;
    }

    for (final e in values.entries) {
      final v = e.value;
      if (v is String) {
        out[e.key] = await one(v);
      } else if (v is List) {
        out[e.key] = [for (final x in v) await one('$x')];
      } else {
        out[e.key] = v;
      }
    }
    return out;
  }

  static String nameOf(EditorController c, String id) {
    if (id.startsWith('lib:')) return AssetLibrary.loaded?.byId(id)?.name ?? id;
    return c.project.media[id]?.name ?? id;
  }
}

/// Picks media for a template slot: from the project or from the library.
/// Returns project ids and/or `lib:<id>` ids.
class MediaPickerDialog extends StatefulWidget {
  final EditorController c;
  final String media; // image | video | audio | any
  final bool multi;
  final int max;
  final List<String> initial;
  const MediaPickerDialog({super.key, required this.c, this.media = 'any', this.multi = false, this.max = 6, this.initial = const []});

  static Future<List<String>?> open(BuildContext context, EditorController c, {String media = 'any', bool multi = false, int max = 6, List<String> initial = const []}) =>
      showDialog<List<String>>(context: context, builder: (_) => MediaPickerDialog(c: c, media: media, multi: multi, max: max, initial: initial));

  @override
  State<MediaPickerDialog> createState() => _MediaPickerDialogState();
}

class _MediaPickerDialogState extends State<MediaPickerDialog> {
  late final List<String> _sel = [...widget.initial];
  AssetLibrary? _lib;
  String _query = '';
  String? _kind;

  @override
  void initState() {
    super.initState();
    AssetLibrary.shared().then((l) {
      if (mounted) setState(() => _lib = l);
    }).catchError((_) {});
  }

  void _toggle(String id) {
    setState(() {
      if (_sel.contains(id)) {
        _sel.remove(id);
      } else {
        if (!widget.multi) _sel.clear();
        if (_sel.length < widget.max) _sel.add(id);
      }
    });
    if (!widget.multi && _sel.isNotEmpty) Navigator.pop(context, _sel);
  }

  Widget _tile(String id, Widget thumb, String name, {bool alpha = false}) {
    final on = _sel.contains(id);
    return InkWell(
      onTap: () => _toggle(id),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 104,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: on ? Theme.of(context).colorScheme.primary : Colors.transparent, width: 2),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Stack(children: [
            thumb,
            if (alpha) const Positioned(right: 2, top: 2, child: Icon(Icons.layers_clear_outlined, size: 14, color: Colors.white70)),
          ]),
          const SizedBox(height: 3),
          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final project = [for (final m in widget.c.project.media.values) if (LibUi.typeMatches(m.type, widget.media)) m];
    final lib = _lib;
    final libItems = lib == null
        ? const <LibraryAsset>[]
        : [for (final a in lib.search(_query, kinds: _kind == null ? null : [_kind!])) if (LibUi.typeMatches(a.type, widget.media)) a];
    return DefaultTabController(
      length: 2,
      child: AlertDialog(
        title: Text(widget.multi ? 'Pick media (up to ${widget.max})' : 'Pick media'),
        contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        content: SizedBox(
          width: 560,
          height: 460,
          child: Column(children: [
            const TabBar(tabs: [Tab(text: 'This project'), Tab(text: 'Library')]),
            Expanded(
              child: TabBarView(children: [
                project.isEmpty
                    ? const Center(child: Text('No matching media in this project yet.'))
                    : SingleChildScrollView(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final m in project) _tile(m.id, LibUi.mediaThumb(m, size: 92), m.name),
                        ]),
                      ),
                Column(children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TextField(
                      decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: 'Search the library (hut, sky, logo, 1900s…)'),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                  SizedBox(
                    height: 40,
                    child: ListView(scrollDirection: Axis.horizontal, children: [
                      for (final k in libraryKinds)
                        Padding(
                          padding: const EdgeInsets.only(right: 4, top: 4),
                          child: FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: Text(LibUi.kindLabels[k] ?? k, style: const TextStyle(fontSize: 11)),
                            selected: _kind == k,
                            onSelected: (v) => setState(() => _kind = v ? k : null),
                          ),
                        ),
                    ]),
                  ),
                  Expanded(
                    child: lib == null
                        ? const Center(child: CircularProgressIndicator())
                        : libItems.isEmpty
                            ? const Center(child: Text('Nothing in the library matches.'))
                            : SingleChildScrollView(
                                child: Wrap(spacing: 6, runSpacing: 6, children: [
                                  for (final a in libItems) _tile('lib:${a.id}', LibUi.assetThumb(lib, a, size: 92), a.name, alpha: a.transparent),
                                ]),
                              ),
                  ),
                ]),
              ]),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          if (widget.multi) TextButton(onPressed: () => Navigator.pop(context, <String>[]), child: const Text('Clear')),
          if (widget.multi) FilledButton(onPressed: () => Navigator.pop(context, _sel), child: Text('Use ${_sel.length}')),
        ],
      ),
    );
  }
}
