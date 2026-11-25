import 'package:flutter/material.dart';

import '../../core/commands/edit_commands.dart';
import '../../core/model/layer.dart';
import '../../core/presets/templates.dart';
import '../../library/asset_library.dart';
import '../../state/editor_controller.dart';
import '../common.dart';

/// "Save as template": the chosen layers (plus their children, parents and
/// matte layers) become a template; texts and media become slots. Media is
/// copied into the library so the template works in every project.
///
/// Open with `SaveTemplateDialog.open(context, controller)`; returns true when saved.
class SaveTemplateDialog extends StatefulWidget {
  final EditorController c;
  final Set<String>? layers;
  const SaveTemplateDialog({super.key, required this.c, this.layers});

  static Future<bool?> open(BuildContext context, EditorController c, {Set<String>? layers}) =>
      showDialog<bool>(context: context, builder: (_) => SaveTemplateDialog(c: c, layers: layers));

  /// Saves [t] to the library: project media slots → library assets.
  static Future<SceneTemplate> store(AssetLibrary lib, EditorController c, SceneTemplate t) async {
    final slots = <TemplateSlot>[];
    for (final s in t.slots) {
      final v = s.initial;
      final m = s.isMedia && v is String ? c.project.media[v] : null;
      if (m == null) {
        slots.add(s);
        continue;
      }
      final a = await lib.addMedia(m, origin: c.project.name);
      slots.add(s.withInitial('lib:${a.id}'));
    }
    final out = t.withSlots(slots);
    await lib.saveTemplate(out.toJson());
    return out;
  }

  @override
  State<SaveTemplateDialog> createState() => _SaveTemplateDialogState();
}

class _SaveTemplateDialogState extends State<SaveTemplateDialog> {
  late final Set<String> _picked;
  final _name = TextEditingController(text: 'My template');
  String _category = SceneTemplates.mine;
  bool _busy = false;
  String? _error;

  EditorController get c => widget.c;

  @override
  void initState() {
    super.initState();
    _picked = {...?widget.layers, if (widget.layers == null && c.selectedLayerId != null) c.selectedLayerId!};
    final sel = c.selectedLayer;
    if (sel != null) _name.text = sel.name;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _picked.isEmpty) {
      setState(() => _error = 'Pick at least one layer and give it a name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final t = SceneTemplates.fromLayers(c.project, _picked, name: name, category: _category);
      await SaveTemplateDialog.store(await AssetLibrary.shared(), c, t);
      if (!mounted) return;
      Navigator.pop(context, true);
      showSnack(context, 'Saved "$name" — find it in Templates → ${SceneTemplates.mine}.');
    } on CommandError catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final layers = c.comp.layers;
    final all = SceneTemplates.closure(c.comp, _picked);
    final extra = all.length - _picked.where((id) => c.comp.layerById(id) != null).length;
    return AlertDialog(
      title: const Text('Save as template'),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Template name', isDense: true)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _category,
            decoration: const InputDecoration(labelText: 'Category', isDense: true),
            items: [for (final cat in [SceneTemplates.mine, ...SceneTemplates.categories]) DropdownMenuItem(value: cat, child: Text(cat))],
            onChanged: (v) => setState(() => _category = v ?? SceneTemplates.mine),
          ),
          const SizedBox(height: 8),
          Text(
            'Texts and photos/videos become fillable slots. ${extra > 0 ? '+$extra linked layers (children, parents, mattes) are included.' : ''}',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          const SizedBox(height: 4),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final l in layers)
                if (l.parentId == null || !all.contains(l.parentId))
                  CheckboxListTile(
                    dense: true,
                    value: all.contains(l.id),
                    secondary: Icon(layerIcon(l.type), size: 18),
                    title: Text(l.name, overflow: TextOverflow.ellipsis),
                    subtitle: _children(l) == 0 ? null : Text('+ ${_children(l)} parts'),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _picked.add(l.id);
                      } else {
                        _picked.removeAll(SceneTemplates.closure(c.comp, [l.id]));
                      }
                    }),
                  ),
            ]),
          ),
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Save')),
      ],
    );
  }

  int _children(Layer l) => SceneTemplates.closure(c.comp, [l.id]).length - 1;
}
