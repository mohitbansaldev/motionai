import 'package:flutter/material.dart';

import '../core/model/project.dart';
import '../services/project_storage.dart';
import 'editor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _storage = ProjectStorage();
  late Future<List<Project>> _projects = _storage.listProjects();

  void _reload() => setState(() => _projects = _storage.listProjects());

  Future<void> _open(Project p) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditorScreen(project: p, storage: _storage)));
    _reload();
  }

  Future<void> _newProject() async {
    final result = await showModalBottomSheet<(String, double, double, double)>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => const _NewProjectSheet(),
    );
    if (result == null) return;
    final (name, w, h, fps) = result;
    final p = Project(
      id: Ids.next('proj'),
      name: name,
      main: Composition(id: 'main', name: 'Main', width: w, height: h, fps: fps, duration: 10),
    );
    await _storage.save(p);
    await _open(p);
  }

  Future<void> _delete(Project p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete project?'),
        content: Text('"${p.name}" will be removed from this device. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await _storage.delete(p);
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MotionAI')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newProject,
        icon: const Icon(Icons.add),
        label: const Text('New project'),
      ),
      body: FutureBuilder<List<Project>>(
        future: _projects,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final list = snap.data!;
          if (list.isEmpty) {
            return const Center(
              child: Text('No projects yet.\nTap "New project" to start.',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final p = list[i];
              final m = p.main;
              return ListTile(
                leading: const Icon(Icons.movie_creation_outlined),
                title: Text(p.name),
                subtitle: Text('${m.width.round()}×${m.height.round()} · ${m.fps.round()} fps · '
                    '${m.layers.length} layers · ${_ago(p.modified)}'),
                onTap: () => _open(p),
                onLongPress: () => _delete(p),
              );
            },
          );
        },
      ),
    );
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}

class _NewProjectSheet extends StatefulWidget {
  const _NewProjectSheet();
  @override
  State<_NewProjectSheet> createState() => _NewProjectSheetState();
}

class _NewProjectSheetState extends State<_NewProjectSheet> {
  final _name = TextEditingController(text: 'Untitled');
  int _preset = 0;
  double _fps = 30;

  static const _presets = [
    ('YouTube 16:9', 1920.0, 1080.0),
    ('Shorts / Reels 9:16', 1080.0, 1920.0),
    ('Square 1:1', 1080.0, 1080.0),
    ('Portrait 4:5', 1080.0, 1350.0),
    ('4K 16:9', 3840.0, 2160.0),
  ];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('New project', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (int i = 0; i < _presets.length; i++)
            ChoiceChip(label: Text(_presets[i].$1), selected: _preset == i, onSelected: (_) => setState(() => _preset = i)),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 6, children: [
          for (final f in [24.0, 25.0, 30.0, 60.0])
            ChoiceChip(label: Text('${f.round()} fps'), selected: _fps == f, onSelected: (_) => setState(() => _fps = f)),
        ]),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () {
              final p = _presets[_preset];
              final name = _name.text.trim().isEmpty ? 'Untitled' : _name.text.trim();
              Navigator.pop(context, (name, p.$2, p.$3, _fps));
            },
            child: const Text('Create'),
          ),
        ),
      ]),
    );
  }
}
