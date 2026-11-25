import 'package:flutter/material.dart';

import '../../core/commands/edit_commands.dart';
import '../../core/model/project.dart';
import '../../core/presets/templates.dart';
import '../../library/asset_library.dart';
import '../../state/editor_controller.dart';
import '../common.dart';
import '../preview/composition_canvas.dart';
import 'library_common.dart';
import 'recipes_panel.dart';
import 'save_template_dialog.dart';
import 'template_thumbs.dart';

/// Templates gallery: built-in scenes by category + "My templates" + recipes.
/// Pick one, fill its slots (text, media from the project or the library,
/// colours) and insert it at the playhead as one undo step.
///
/// Open with `TemplateGallery.open(context, controller)`.
class TemplateGallery extends StatefulWidget {
  final EditorController c;
  final String? initialCategory;
  const TemplateGallery({super.key, required this.c, this.initialCategory});

  static Future<void> open(BuildContext context, EditorController c, {String? category}) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          maxChildSize: 0.95,
          builder: (_, sc) => PrimaryScrollController(controller: sc, child: TemplateGallery(c: c, initialCategory: category)),
        ),
      );

  /// Saved templates from the library.
  static List<SceneTemplate> saved(AssetLibrary? lib) => [
        for (final j in lib?.index.templates ?? const <Map<String, dynamic>>[])
          SceneTemplate.fromJson(j),
      ];

  @override
  State<TemplateGallery> createState() => _TemplateGalleryState();
}

class _TemplateGalleryState extends State<TemplateGallery> {
  AssetLibrary? _lib;
  SceneTemplate? _open;

  EditorController get c => widget.c;

  static bool get _recipes => EditCommands.ops.contains('save_recipe') && EditCommands.ops.contains('apply_recipe');

  @override
  void initState() {
    super.initState();
    AssetLibrary.shared().then((l) {
      if (mounted) setState(() => _lib = l);
    }).catchError((_) {});
  }

  List<String> get _tabs => [
        for (final cat in SceneTemplates.categories)
          if (SceneTemplates.available.any((t) => t.category == cat)) cat,
        SceneTemplates.mine,
        if (_recipes) 'Recipes',
      ];

  List<SceneTemplate> _of(String cat) => cat == SceneTemplates.mine
      ? TemplateGallery.saved(_lib)
      : [for (final t in SceneTemplates.available) if (t.category == cat) t];

  Future<void> _saveSelection() async {
    final ok = await SaveTemplateDialog.open(context, c);
    if (ok == true && mounted) setState(() {});
  }

  Future<void> _delete(SceneTemplate t) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${t.name}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true || _lib == null) return;
    await _lib!.deleteTemplate(t.id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final open = _open;
    if (open != null) {
      return _SlotForm(c: c, t: open, onBack: () => setState(() => _open = null));
    }
    final tabs = _tabs;
    final initial = widget.initialCategory == null ? 0 : tabs.indexOf(widget.initialCategory!).clamp(0, tabs.length - 1).toInt();
    final queue = [for (final cat in tabs) if (cat != 'Recipes') ..._of(cat)];
    final bg = Theme.of(context).colorScheme.surface;
    return Stack(children: [
      // Renders thumbnails underneath the (opaque) gallery.
      Positioned(left: 0, top: 0, child: ThumbStage(source: c.project, queue: queue, onRendered: () {
            if (mounted) setState(() {});
          })),
      Positioned.fill(
        child: ColoredBox(
          color: bg,
          child: DefaultTabController(
            length: tabs.length,
            initialIndex: initial,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
                child: Row(children: [
                  const Text('Templates', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  TextButton.icon(onPressed: _saveSelection, icon: const Icon(Icons.bookmark_add_outlined), label: const Text('Save selection as template')),
                ]),
              ),
              TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [for (final t in tabs) Tab(text: t)]),
              Expanded(
                child: TabBarView(children: [
                  for (final cat in tabs)
                    if (cat == 'Recipes') RecipesPanel(c: c) else _grid(cat),
                ]),
              ),
            ]),
          ),
        ),
      ),
    ]);
  }

  Widget _grid(String cat) {
    final list = _of(cat);
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            cat == SceneTemplates.mine
                ? 'No saved templates yet. Select a layer (or a component group) and tap "Save selection as template".'
                : 'Nothing here on this build.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 240, mainAxisExtent: 200, crossAxisSpacing: 10, mainAxisSpacing: 10),
      itemCount: list.length,
      itemBuilder: (_, i) => _tile(list[i]),
    );
  }

  Widget _tile(SceneTemplate t) {
    final scheme = Theme.of(context).colorScheme;
    final k = TemplateThumbs.key(t, c.project);
    final png = TemplateThumbs.cache[k];
    final failed = TemplateThumbs.failed.contains(k);
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => _open = t),
        onLongPress: t.saved ? () => _delete(t) : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AspectRatio(
            aspectRatio: c.comp.width / (c.comp.height <= 0 ? 1 : c.comp.height),
            child: ColoredBox(
              color: Colors.black,
              child: png != null
                  ? Image.memory(png, fit: BoxFit.contain, gaplessPlayback: true)
                  : Center(child: failed ? const Icon(Icons.auto_awesome_mosaic_outlined) : const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
            child: Text(t.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ),
        ]),
      ),
    );
  }
}

/// Slot form + live preview for one template.
class _SlotForm extends StatefulWidget {
  final EditorController c;
  final SceneTemplate t;
  final VoidCallback onBack;
  const _SlotForm({required this.c, required this.t, required this.onBack});

  @override
  State<_SlotForm> createState() => _SlotFormState();
}

class _SlotFormState extends State<_SlotForm> {
  final Map<String, TextEditingController> _ctl = {};
  final Map<String, List<String>> _media = {};
  Project? _preview;
  double _time = 0;
  String? _error;
  bool _busy = false;

  SceneTemplate get t => widget.t;

  @override
  void initState() {
    super.initState();
    for (final s in t.slots) {
      if (s.isMedia) {
        final v = s.initial;
        _media[s.key] = v is List ? [for (final x in v) '$x'] : (v is String && v.isNotEmpty ? [v] : []);
      } else {
        _ctl[s.key] = TextEditingController(text: s.initial == null ? '' : '${s.initial}')..addListener(_refresh);
      }
    }
    _time = t.previewTime;
    _preview = TemplateThumbs.scratch(t, widget.c.project, values: _values());
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _values() => {
        for (final s in t.slots)
          if (s.isMedia)
            s.key: s.kind == 'medias' ? _media[s.key] ?? const <String>[] : ((_media[s.key] ?? const []).isEmpty ? null : _media[s.key]!.first)
          else
            s.key: _ctl[s.key]!.text,
      };

  void _refresh() {
    final p = TemplateThumbs.scratch(t, widget.c.project, values: _values());
    if (mounted) setState(() => _preview = p);
  }

  Future<void> _pick(TemplateSlot s) async {
    final r = await MediaPickerDialog.open(context, widget.c, media: s.media, multi: s.kind == 'medias', max: s.max, initial: _media[s.key] ?? const []);
    if (r == null) return;
    _media[s.key] = r;
    _refresh();
  }

  Future<void> _insert() async {
    final c = widget.c;
    setState(() {
      _busy = true;
      _error = null;
    });
    c.beginGesture(); // library imports + every layer = one undo step
    try {
      final values = await LibUi.resolveLibrary(c, _values());
      values.removeWhere((k, v) => v == null);
      final r = SceneTemplates.insert(c.project, t, start: c.time, values: values);
      c.endGesture();
      if (r.createdIds.isNotEmpty) c.select(r.createdIds.first);
      if (mounted) {
        Navigator.pop(context);
        showSnack(context, '${t.name} inserted at ${formatTime(c.time, c.comp.fps)}. Undo removes it in one step.');
      }
      return;
    } on CommandError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    c.endGesture();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final p = _preview;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: ListView(primary: true, children: [
        Row(children: [
          IconButton(icon: const Icon(Icons.arrow_back), onPressed: widget.onBack),
          Expanded(child: Text(t.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
        ]),
        if (t.subtitle.isNotEmpty) Text(t.subtitle, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5)),
        const SizedBox(height: 10),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: AspectRatio(
              aspectRatio: c.comp.width / (c.comp.height <= 0 ? 1 : c.comp.height),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: ColoredBox(
                  color: Colors.black,
                  child: p == null
                      ? const Center(child: Text('Preview not available', style: TextStyle(color: Colors.white54)))
                      : FittedBox(fit: BoxFit.contain, child: CompositionCanvas(project: p, time: _time.clamp(0.0, p.main.duration).toDouble())),
                ),
              ),
            ),
          ),
        ),
        if (p != null)
          Slider(
            value: _time.clamp(0.0, p.main.duration).toDouble(),
            max: p.main.duration <= 0 ? 1 : p.main.duration,
            onChanged: (v) => setState(() => _time = v),
          ),
        for (final s in t.slots) Padding(padding: const EdgeInsets.only(bottom: 10), child: _field(s)),
        if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
        FilledButton.icon(
          onPressed: _busy ? null : _insert,
          icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.add),
          label: Text('Insert at ${formatTime(c.time, c.comp.fps)}'),
        ),
      ]),
    );
  }

  Widget _field(TemplateSlot s) {
    if (s.isMedia) {
      final sel = _media[s.key] ?? const <String>[];
      return InputDecorator(
        decoration: InputDecoration(labelText: s.label, isDense: true),
        child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final id in sel)
            InputChip(
              label: Text(LibUi.nameOf(widget.c, id), overflow: TextOverflow.ellipsis),
              avatar: Icon(id.startsWith('lib:') ? Icons.collections_bookmark_outlined : Icons.perm_media_outlined, size: 16),
              onDeleted: () {
                _media[s.key] = [...sel]..remove(id);
                _refresh();
              },
            ),
          TextButton.icon(onPressed: () => _pick(s), icon: const Icon(Icons.add_photo_alternate_outlined, size: 18), label: Text(sel.isEmpty ? 'Pick…' : 'Change…')),
        ]),
      );
    }
    final ctl = _ctl[s.key]!;
    if (s.kind == 'color') {
      final parsed = int.tryParse(ctl.text.replaceFirst('#', ''), radix: 16);
      final argb = parsed == null ? 0xFFFFFFFF : (ctl.text.replaceFirst('#', '').length <= 6 ? 0xFF000000 | parsed : parsed);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: TextField(controller: ctl, decoration: InputDecoration(labelText: s.label, isDense: true, hintText: '#RRGGBB'))),
          const SizedBox(width: 8),
          Container(width: 28, height: 28, decoration: BoxDecoration(color: Color(argb), shape: BoxShape.circle, border: Border.all(color: Colors.white24))),
        ]),
        const SizedBox(height: 6),
        SwatchRow(selected: argb, onPick: (v) => ctl.text = colorHex(v)),
      ]);
    }
    return TextField(controller: ctl, decoration: InputDecoration(labelText: s.label, isDense: true, helperText: s.hint.isEmpty ? null : s.hint));
  }
}
