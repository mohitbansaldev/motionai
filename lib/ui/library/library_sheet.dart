import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../ai/ai_client.dart';
import '../../core/model/project.dart';
import '../../library/asset_library.dart';
import '../../library/library_ops.dart'; // V2-F
import '../../library/library_tagger.dart';
import '../../services/media_importer.dart';
import '../../state/editor_controller.dart';
import '../common.dart';
import 'library_common.dart';

/// Asset library shared by all projects: search, filter by kind/kit, add
/// from this project or from files, AI auto-tag, kits, insert at the playhead.
///
/// Open with `LibrarySheet.open(context, controller)`.
class LibrarySheet extends StatefulWidget {
  final EditorController c;
  const LibrarySheet({super.key, required this.c});

  static Future<void> open(BuildContext context, EditorController c) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          maxChildSize: 0.95,
          builder: (_, sc) => PrimaryScrollController(controller: sc, child: LibrarySheet(c: c)),
        ),
      );

  @override
  State<LibrarySheet> createState() => _LibrarySheetState();
}

class _LibrarySheetState extends State<LibrarySheet> {
  AssetLibrary? _lib;
  String? _error;
  String _query = '';
  final Set<String> _kinds = {};
  String? _kit;
  final Set<String> _sel = {};
  bool _busy = false;
  String _status = '';

  EditorController get c => widget.c;

  @override
  void initState() {
    super.initState();
    AssetLibrary.shared().then((l) {
      if (mounted) setState(() => _lib = l);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = 'Could not open the library: $e');
    });
  }

  Future<void> _work(String label, Future<void> Function(AssetLibrary lib) job) async {
    final lib = _lib;
    if (lib == null || _busy) return;
    setState(() {
      _busy = true;
      _status = label;
    });
    try {
      await job(lib);
    } on AiException catch (e) {
      if (mounted) showSnack(context, e.message);
    } catch (e) {
      if (mounted) showSnack(context, '$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
        });
      }
    }
  }

  // ------------------------------------------------------------ adding

  Future<void> _addFromProject() async {
    final media = c.project.media.values.where((m) => !m.name.startsWith('SFX ')).toList();
    if (media.isEmpty) {
      showSnack(context, 'This project has no media yet.');
      return;
    }
    final picked = <String>{};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Add project media to the library'),
          content: SizedBox(
            width: 420,
            child: ListView(shrinkWrap: true, children: [
              for (final m in media)
                CheckboxListTile(
                  dense: true,
                  value: picked.contains(m.id),
                  secondary: LibUi.mediaThumb(m, size: 40),
                  title: Text(m.name, overflow: TextOverflow.ellipsis),
                  subtitle: m.description.isEmpty ? null : Text(m.description, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onChanged: (v) => setD(() => v == true ? picked.add(m.id) : picked.remove(m.id)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => setD(() => picked.addAll(media.map((m) => m.id))), child: const Text('All')),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true || picked.isEmpty) return;
    await _work('Copying into the library…', (lib) async {
      final added = <LibraryAsset>[];
      for (final id in picked) {
        final m = c.project.media[id];
        if (m != null) added.add(await lib.addMedia(m, origin: c.project.name));
      }
      if (mounted) showSnack(context, 'Added ${added.length} to the library. Tap "AI tag" to label them.');
    });
  }

  Future<void> _addFromFiles(MediaType kind) async {
    await _work('Importing…', (lib) async {
      final importer = MediaImporter(c.storage);
      final assets = await importer.pick(kind: kind);
      for (final a in assets) {
        await lib.addMedia(a, origin: 'files');
      }
      if (importer.errors.isNotEmpty && mounted) showSnack(context, importer.errors.join('; '));
      if (assets.isNotEmpty && mounted) showSnack(context, 'Added ${assets.length} to the library.');
    });
  }

  // V2-F >>> folder import (Google Flow kits) + green screen / mark clean-up
  Future<({bool green, bool mark})?> _cleanOptions(String title, {bool mark = false}) {
    var green = true, removeMark = mark;
    return showDialog<({bool green, bool mark})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            CheckboxListTile(
              value: green,
              title: const Text('Remove flat green / blue screens'),
              subtitle: const Text('Keeps the original; makes a transparent PNG cut-out'),
              onChanged: (v) => setD(() => green = v ?? true),
            ),
            CheckboxListTile(
              value: removeMark,
              title: const Text('Remove the corner sparkle mark'),
              subtitle: const Text('Only when a small white star is found bottom-right'),
              onChanged: (v) => setD(() => removeMark = v ?? false),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, (green: green, mark: removeMark)), child: const Text('Go')),
          ],
        ),
      ),
    );
  }

  Future<void> _addFolder() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Asset folder (e.g. a Google Flow kit)');
    if (dir == null || !mounted) return;
    final opt = await _cleanOptions('Import "${LibraryOps.kitName(dir)}"');
    if (opt == null) return;
    await _work('Importing folder…', (lib) async {
      final r = await LibraryOps.importFolder(lib, {'path': dir, 'green_screen': opt.green ? 'auto' : 'false', 'remove_mark': opt.mark},
          status: (s) {
        if (mounted) setState(() => _status = s);
      });
      final kit = r['kit'];
      if (kit is Map) _kit = '${kit['id']}';
      if (mounted) {
        showSnack(context,
            'Imported ${r['imported']} (${r['duplicates']} already there, ${r['green_screen_keyed']} keyed, ${r['marks_removed']} marks removed) into kit "${kit is Map ? kit['name'] : '-'}".');
      }
    });
  }

  Future<void> _clean(List<String> ids) async {
    final opt = await _cleanOptions('Clean ${ids.length} asset(s)', mark: true);
    if (opt == null) return;
    await _work('Cleaning…', (lib) async {
      final r = await LibraryOps.clean(lib, {'ids': ids, 'green_screen': opt.green ? 'true' : 'false', 'remove_mark': opt.mark}, status: (s) {
        if (mounted) setState(() => _status = s);
      });
      if (mounted) showSnack(context, 'Cleaned ${r['changed']} of ${ids.length}.');
    });
  }
  // <<< V2-F

  Future<void> _tag({bool selected = false}) async {
    await _work('AI is looking at your assets…', (lib) async {
      final list = selected ? [for (final id in _sel) if (lib.byId(id) != null) lib.byId(id)!] : null;
      final n = await LibraryTagger.tag(lib, assets: list, status: (s) {
        if (mounted) setState(() => _status = s);
      });
      if (mounted) showSnack(context, n == 0 ? 'Nothing to tag.' : 'Tagged $n assets.');
    });
  }

  // ------------------------------------------------------------ using

  Future<void> _insert(List<String> ids) async {
    await _work('Adding to the timeline…', (lib) async {
      final dir = await c.storage.mediaDir();
      c.beginGesture(); // one undo step for the import + layers
      try {
        var t = c.time;
        final cmds = <Map<String, dynamic>>[];
        for (final id in ids) {
          final m = await lib.importInto(c.project, id, mediaDir: dir);
          cmds.add({
            'op': 'add_layer', 'type': m.type.name, 'media': m.id, 'start': t,
            if (m.type == MediaType.audio) 'index': c.comp.layers.length + cmds.length,
          });
          t += m.type == MediaType.video || m.type == MediaType.audio ? m.duration : 5;
        }
        final err = c.tryRun({'op': 'batch', 'commands': cmds});
        if (err != null) throw Exception(err);
      } finally {
        c.endGesture();
      }
      if (mounted) {
        Navigator.pop(context);
        showSnack(context, 'Added ${ids.length} from the library.');
      }
    });
  }

  Future<void> _newKit() async {
    final name = await _askText('New kit', 'Kit name (e.g. Village kit)');
    if (name == null || name.isEmpty) return;
    await _work('Saving kit…', (lib) async {
      final k = await lib.createKit(name, _sel);
      setState(() => _kit = k.id);
    });
  }

  Future<void> _editTags(LibraryAsset a) async {
    final lib = _lib!;
    final desc = TextEditingController(text: a.description);
    final tags = TextEditingController(text: a.tags.join(', '));
    final era = TextEditingController(text: a.era);
    final region = TextEditingController(text: a.region);
    final mood = TextEditingController(text: a.mood);
    var kind = a.kind;
    var alpha = a.transparent;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(a.name, overflow: TextOverflow.ellipsis),
          content: SizedBox(
            width: 420,
            child: ListView(shrinkWrap: true, children: [
              Center(child: LibUi.assetThumb(lib, a, size: 160)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: kind.isEmpty ? null : kind,
                decoration: const InputDecoration(labelText: 'Kind', isDense: true),
                items: [for (final k in libraryKinds) DropdownMenuItem(value: k, child: Text(LibUi.kindLabels[k] ?? k))],
                onChanged: (v) => setD(() => kind = v ?? ''),
              ),
              TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description', isDense: true), maxLines: 2),
              TextField(controller: tags, decoration: const InputDecoration(labelText: 'Tags (comma separated)', isDense: true)),
              Row(children: [
                Expanded(child: TextField(controller: era, decoration: const InputDecoration(labelText: 'Era', isDense: true))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: region, decoration: const InputDecoration(labelText: 'Region', isDense: true))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: mood, decoration: const InputDecoration(labelText: 'Mood', isDense: true))),
              ]),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Transparent background (cut-out)'),
                value: alpha,
                onChanged: (v) => setD(() => alpha = v),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    a
      ..kind = kind
      ..description = desc.text.trim()
      ..tags = tags.text.split(',').map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toList()
      ..era = era.text.trim()
      ..region = region.text.trim()
      ..mood = mood.text.trim()
      ..transparent = alpha;
    await lib.save();
    if (mounted) setState(() {});
  }

  Future<String?> _askText(String title, String hint) {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctl, autofocus: true, decoration: InputDecoration(hintText: hint), onSubmitted: (v) => Navigator.pop(ctx, v.trim())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('OK')),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final lib = _lib;
    final scheme = Theme.of(context).colorScheme;
    final items = lib == null ? const <LibraryAsset>[] : lib.search(_query, kinds: _kinds, kit: _kit);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Text('Asset library', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(width: 8),
          if (lib != null) Text('${lib.assets.length} assets · ${lib.kits.length} kits', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
          const Spacer(),
          PopupMenuButton<String>(
            tooltip: 'Add to library',
            icon: const Icon(Icons.add_photo_alternate_outlined),
            enabled: lib != null && !_busy,
            onSelected: (v) => switch (v) {
              'project' => _addFromProject(),
              'folder' => _addFolder(), // V2-F
              'images' => _addFromFiles(MediaType.image),
              'videos' => _addFromFiles(MediaType.video),
              _ => _addFromFiles(MediaType.audio),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'project', child: Text('From this project…')),
              PopupMenuItem(value: 'folder', child: Text('Folder / Google Flow kit…')), // V2-F
              PopupMenuItem(value: 'images', child: Text('Images / cut-outs from files…')),
              PopupMenuItem(value: 'videos', child: Text('Videos from files…')),
              PopupMenuItem(value: 'audio', child: Text('Sounds / music from files…')),
            ],
          ),
          IconButton(
            tooltip: 'AI tag untagged assets',
            icon: const Icon(Icons.auto_awesome),
            onPressed: lib == null || _busy ? null : () => _tag(),
          ),
        ]),
        if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        TextField(
          decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: 'Search: hut, grass, 1900s, Rajasthan, logo…'),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 36,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            if (lib != null && lib.kits.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: DropdownButton<String?>(
                  value: _kit,
                  hint: const Text('All kits'),
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('All assets')),
                    for (final k in lib.kits) DropdownMenuItem<String?>(value: k.id, child: Text('${k.name} (${k.assetIds.length})')),
                  ],
                  onChanged: (v) => setState(() => _kit = v),
                ),
              ),
            for (final k in libraryKinds)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: FilterChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(LibUi.kindLabels[k] ?? k, style: const TextStyle(fontSize: 11.5)),
                  selected: _kinds.contains(k),
                  onSelected: (v) => setState(() => v ? _kinds.add(k) : _kinds.remove(k)),
                ),
              ),
          ]),
        ),
        if (_busy)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
              Expanded(child: Text(_status, style: const TextStyle(fontSize: 12))),
            ]),
          ),
        if (_sel.isNotEmpty)
          Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('${_sel.length} selected'),
            FilledButton.tonal(onPressed: _busy ? null : () => _insert(_sel.toList()), child: const Text('Insert at playhead')),
            OutlinedButton(onPressed: _busy ? null : _newKit, child: const Text('New kit')),
            if (lib != null && lib.kits.isNotEmpty)
              PopupMenuButton<String>(
                tooltip: 'Add to kit',
                onSelected: (k) => _work('Saving kit…', (lib) => lib.addToKit(k, _sel)),
                itemBuilder: (_) => [for (final k in lib.kits) PopupMenuItem(value: k.id, child: Text(k.name))],
                child: const Padding(padding: EdgeInsets.all(8), child: Text('Add to kit ▾')),
              ),
            OutlinedButton(onPressed: _busy ? null : () => _tag(selected: true), child: const Text('AI tag')),
            OutlinedButton(onPressed: _busy ? null : () => _clean(_sel.toList()), child: const Text('Clean')), // V2-F
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _work('Deleting…', (lib) async {
                        for (final id in _sel.toList()) {
                          await lib.remove(id);
                        }
                        _sel.clear();
                      }),
              child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
            ),
            if (_kit != null)
              TextButton(
                onPressed: () => _work('Deleting kit…', (lib) async {
                  await lib.removeKit(_kit!);
                  _kit = null;
                }),
                child: const Text('Delete this kit'),
              ),
            IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_sel.clear)),
          ]),
        const SizedBox(height: 6),
        Expanded(
          child: lib == null
              ? Center(child: _error == null ? const CircularProgressIndicator() : const SizedBox.shrink())
              : items.isEmpty
                  ? Center(
                      child: Text(
                        lib.assets.isEmpty
                            ? 'The library is empty. Add cut-outs, skies, houses, logos… from this project or from files — they are available in every project.'
                            : 'Nothing matches.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : GridView.builder(
                      primary: true,
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 130, mainAxisExtent: 158, crossAxisSpacing: 8, mainAxisSpacing: 8),
                      itemCount: items.length,
                      itemBuilder: (_, i) => _assetTile(lib, items[i]),
                    ),
        ),
      ]),
    );
  }

  Widget _assetTile(AssetLibrary lib, LibraryAsset a) {
    final on = _sel.contains(a.id);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: on ? scheme.primaryContainer : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => on ? _sel.remove(a.id) : _sel.add(a.id)),
        onDoubleTap: _busy ? null : () => _insert([a.id]),
        onLongPress: () => _editTags(a),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Stack(children: [
              Center(child: LibUi.assetThumb(lib, a, size: 104)),
              if (a.transparent)
                const Positioned(left: 4, top: 4, child: Tooltip(message: 'Cut-out (transparent)', child: Icon(Icons.content_cut, size: 14, color: Colors.white70))),
              Positioned(
                right: 0,
                top: 0,
                child: InkWell(onTap: () => _editTags(a), child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.edit_note, size: 18))),
              ),
            ]),
            const SizedBox(height: 4),
            Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
            Text(
              a.tagged ? [LibUi.kindLabels[a.kind] ?? a.kind, if (a.era.isNotEmpty) a.era, if (a.region.isNotEmpty) a.region].join(' · ') : 'not tagged',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
            ),
          ]),
        ),
      ),
    );
  }
}
