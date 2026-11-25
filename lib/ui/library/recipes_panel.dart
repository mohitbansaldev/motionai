import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/commands/edit_commands.dart';
import '../../library/asset_library.dart';
import '../../state/editor_controller.dart';
import '../common.dart';

/// Recipes (saved move + transition + atmosphere + look + frame): list,
/// save from the selected layer, apply to the selected layer, delete.
/// The data and ops are the scene agent's `save_recipe` / `apply_recipe`
/// (optional `delete_recipe`); this panel only shows when they exist.
class RecipesPanel extends StatefulWidget {
  final EditorController c;
  const RecipesPanel({super.key, required this.c});

  static bool get supported => EditCommands.ops.contains('save_recipe') && EditCommands.ops.contains('apply_recipe');

  /// Recipe names: the ones saved through this panel (library) plus any the
  /// project itself stores under "recipes" (map or list of {name}).
  static List<String> names(EditorController c, AssetLibrary? lib) {
    final out = <String>{...?lib?.recipeNames};
    try {
      final j = jsonDecode(ProjectSnapshot.take(c.project));
      final r = j is Map ? j['recipes'] : null;
      if (r is Map) out.addAll(r.keys.map((k) => '$k'));
      if (r is List) {
        for (final e in r) {
          if (e is Map && e['name'] != null) out.add('${e['name']}');
          if (e is String) out.add(e);
        }
      }
    } catch (_) {}
    return out.toList();
  }

  @override
  State<RecipesPanel> createState() => _RecipesPanelState();
}

class _RecipesPanelState extends State<RecipesPanel> {
  AssetLibrary? _lib;
  EditorController get c => widget.c;

  @override
  void initState() {
    super.initState();
    AssetLibrary.shared().then((l) {
      if (mounted) setState(() => _lib = l);
    }).catchError((_) {});
  }

  void _run(Map<String, dynamic> cmd, String ok) {
    final err = c.tryRun(cmd);
    if (!mounted) return;
    showSnack(context, err ?? ok);
    setState(() {});
  }

  Future<void> _save() async {
    final sel = c.selectedLayerId;
    if (sel == null) {
      showSnack(context, 'Select the layer whose move, transition, look and frame you want to keep.');
      return;
    }
    final ctl = TextEditingController(text: c.selectedLayer?.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save recipe'),
        content: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(labelText: 'Recipe name (e.g. Dreamy push-in)')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final err = c.tryRun({'op': 'save_recipe', 'name': name, 'layer': sel});
    if (err == null) await (_lib ?? await AssetLibrary.shared()).noteRecipe(name);
    if (!mounted) return;
    showSnack(context, err ?? 'Recipe "$name" saved.');
    setState(() {});
  }

  void _apply(String name) {
    final sel = c.selectedLayerId;
    if (sel == null) {
      showSnack(context, 'Select a layer to apply "$name" to.');
      return;
    }
    _run({'op': 'apply_recipe', 'name': name, 'layer': sel, 'start': c.time}, 'Applied "$name".');
  }

  Future<void> _delete(String name) async {
    if (EditCommands.ops.contains('delete_recipe')) c.tryRun({'op': 'delete_recipe', 'name': name});
    await (_lib ?? await AssetLibrary.shared()).forgetRecipe(name);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final names = RecipesPanel.names(c, _lib);
    final sel = c.selectedLayer;
    return ListView(padding: const EdgeInsets.all(12), children: [
      Row(children: [
        Expanded(
          child: Text(sel == null ? 'Select a layer to save or apply a recipe.' : 'Selected: ${sel.name}',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
        FilledButton.tonalIcon(onPressed: _save, icon: const Icon(Icons.save_outlined), label: const Text('Save recipe')),
      ]),
      const SizedBox(height: 8),
      if (names.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('No recipes yet. A recipe keeps a layer\'s camera move, transition, atmosphere, look and frame so you can reuse the combination in one tap.',
              textAlign: TextAlign.center),
        ),
      for (final n in names)
        Card(
          child: ListTile(
            leading: const Icon(Icons.restaurant_menu),
            title: Text(n),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              TextButton(onPressed: () => _apply(n), child: const Text('Apply')),
              IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(n)),
            ]),
          ),
        ),
    ]);
  }
}
