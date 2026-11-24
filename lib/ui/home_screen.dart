import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/commands/edit_commands.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../core/presets/templates.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/project_storage.dart';
import '../services/updater.dart';
import 'editor_screen.dart';
import 'theme.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _Format {
  final String label, sub;
  final double w, h;
  final IconData icon;
  const _Format(this.label, this.sub, this.w, this.h, this.icon);
}

class _HomeScreenState extends State<HomeScreen> {
  final _storage = ProjectStorage();
  late Future<List<Project>> _projects = _storage.listProjects();

  static const _formats = [
    _Format('YouTube', '16:9 · 1080p', 1920, 1080, Icons.smart_display_outlined),
    _Format('Shorts / Reels', '9:16 · 1080p', 1080, 1920, Icons.stay_current_portrait),
    _Format('Square', '1:1', 1080, 1080, Icons.crop_square),
    _Format('Portrait', '4:5', 1080, 1350, Icons.crop_portrait),
    _Format('4K', '16:9 · 2160p', 3840, 2160, Icons.four_k_outlined),
  ];

  void _reload() => setState(() => _projects = _storage.listProjects());

  @override
  void initState() {
    super.initState();
    // Quiet automatic check on launch.
    Future.delayed(const Duration(seconds: 2), () => _checkUpdate(manual: false));
  }

  Future<void> _checkUpdate({required bool manual}) async {
    try {
      final u = await Updater.check();
      if (!mounted) return;
      if (u == null) {
        if (manual) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('You have the latest version (build ${Updater.current}).')));
        return;
      }
      await showModalBottomSheet(
        context: context,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.system_update, color: MA.accent2),
                const SizedBox(width: 10),
                Text('Update available · build ${u.build}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 6),
              Text('You have build ${Updater.current}. Your projects stay as they are.', style: const TextStyle(color: MA.textDim)),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: GradientButton(
                  label: 'Download update',
                  icon: Icons.download_rounded,
                  onTap: () {
                    Navigator.pop(ctx);
                    launchUrl(Uri.parse(u.url), mode: LaunchMode.externalApplication);
                  },
                ),
              ),
              if (u.olderUrl != null)
                TextButton(
                  onPressed: () => launchUrl(Uri.parse(u.olderUrl!), mode: LaunchMode.externalApplication),
                  child: const Text('Older phone? Download this version instead'),
                ),
              const Text('After downloading, tap the file to install over the current app.',
                  style: TextStyle(fontSize: 12, color: MA.textDim)),
            ]),
          ),
        ),
      );
    } catch (e) {
      if (manual && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _open(Project p) async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (_, __, ___) => EditorScreen(project: p, storage: _storage),
      transitionsBuilder: (_, a, __, child) => FadeTransition(
        opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
        child: ScaleTransition(scale: Tween(begin: 0.98, end: 1.0).animate(a), child: child),
      ),
    ));
    _reload();
  }

  Future<int> _count() async => (await _projects).length;

  Future<void> _create(_Format f) async {
    final p = Project(
      id: Ids.next('proj'),
      name: 'Project ${await _count() + 1}',
      main: Composition(id: 'main', name: 'Main', width: f.w, height: f.h, fps: 30, duration: 10),
    );
    await _storage.save(p);
    await _open(p);
  }

  Future<void> _fromTemplate(ProjectTemplate t) async {
    final p = Project(
      id: Ids.next('proj'),
      name: t.name,
      main: Composition(id: 'main', name: 'Main', width: t.width, height: t.height, fps: 30, duration: t.duration),
    );
    try {
      EditCommands.runAtomic(p, {'op': 'batch', 'commands': t.commands(t.width, t.height)});
    } on CommandError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Template error: ${e.message}')));
      return;
    }
    await _storage.save(p);
    await _open(p);
  }

  Future<void> _menu(Project p) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700))),
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Rename'), onTap: () => Navigator.pop(ctx, 'rename')),
          ListTile(leading: const Icon(Icons.copy_outlined), title: const Text('Duplicate'), onTap: () => Navigator.pop(ctx, 'dup')),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
            title: const Text('Delete'),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
        ]),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'rename':
        final name = await _ask('Rename project', p.name);
        if (name != null && name.trim().isNotEmpty) {
          p.name = name.trim();
          await _storage.save(p);
          _reload();
        }
      case 'dup':
        final copy = Project.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>)
          ..id = Ids.next('proj')
          ..name = '${p.name} copy';
        await _storage.save(copy);
        _reload();
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete project?'),
            content: Text('"${p.name}" will be removed from this phone. This cannot be undone.'),
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
  }

  Future<String?> _ask(String title, String initial) {
    final ctl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctl, autofocus: true, onSubmitted: (s) => Navigator.pop(ctx, s)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width > 700;
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<List<Project>>(
          future: _projects,
          builder: (context, snap) {
            final list = snap.data ?? const <Project>[];
            return CustomScrollView(slivers: [
              SliverToBoxAdapter(child: _header()),
              _sectionTitle('Start a new project'),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 118,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    scrollDirection: Axis.horizontal,
                    itemCount: _formats.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (_, i) => _formatCard(_formats[i], i == 0),
                  ),
                ),
              ),
              _sectionTitle('Templates'),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 150,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    scrollDirection: Axis.horizontal,
                    itemCount: Templates.all.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (_, i) => _templateCard(Templates.all[i], i),
                  ),
                ),
              ),
              _sectionTitle(list.isEmpty ? 'Your projects' : 'Your projects · ${list.length}'),
              if (!snap.hasData)
                const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())))
              else if (list.isEmpty)
                SliverToBoxAdapter(child: _empty())
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: wide ? 4 : 2,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 14,
                      childAspectRatio: 0.92,
                    ),
                    delegate: SliverChildBuilderDelegate((_, i) => _projectCard(list[i]), childCount: list.length),
                  ),
                ),
            ]);
          },
        ),
      ),
    );
  }

  Widget _header() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ShaderMask(
                shaderCallback: (r) => MA.gradient.createShader(r),
                child: const Text('MotionAI',
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: -0.5)),
              ),
              const SizedBox(height: 2),
              Text('Cinematic motion, 3D camera & AI editing · build ${Updater.current}',
                  style: const TextStyle(color: MA.textDim, fontSize: 13.5)),
            ]),
          ),
          IconButton(
            tooltip: 'Check for updates',
            onPressed: () => _checkUpdate(manual: true),
            icon: const Icon(Icons.system_update_alt_rounded, color: MA.textDim),
          ),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(gradient: MA.gradient, borderRadius: BorderRadius.circular(14)),
            child: const Icon(Icons.movie_filter_rounded, color: Colors.white),
          ),
        ]),
      );

  Widget _sectionTitle(String t) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 10),
          child: Text(t, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: MA.text)),
        ),
      );

  Widget _formatCard(_Format f, bool primary) {
    final ratio = f.w / f.h;
    return GestureDetector(
      onTap: () => _create(f),
      child: Container(
        width: 128,
        padding: const EdgeInsets.all(12),
        decoration: primary
            ? BoxDecoration(gradient: MA.gradient, borderRadius: BorderRadius.circular(16))
            : MA.card(color: MA.surface2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: ratio >= 1 ? 30 : 30 * ratio,
              height: ratio >= 1 ? 30 / ratio : 30,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 1.6),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const Spacer(),
            Icon(Icons.add_rounded, color: Colors.white.withValues(alpha: 0.9)),
          ]),
          const Spacer(),
          Text(f.label, style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
          Text(f.sub, style: TextStyle(fontSize: 11.5, color: Colors.white.withValues(alpha: primary ? 0.85 : 0.55))),
        ]),
      ),
    );
  }

  static const _templateGradients = [
    [Color(0xFF1B2A4A), Color(0xFF0B0F1A)],
    [Color(0xFF5B2BD6), Color(0xFFE0367A)],
    [Color(0xFF6B4423), Color(0xFF2A1E14)],
    [Color(0xFF0F3D4A), Color(0xFF06080D)],
  ];

  Widget _templateCard(ProjectTemplate t, int i) {
    final g = _templateGradients[i % _templateGradients.length];
    return GestureDetector(
      onTap: () => _fromTemplate(t),
      child: Container(
        width: 200,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: g, begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(8)),
            child: Text('${t.width > t.height ? '16:9' : t.width == t.height ? '1:1' : '9:16'} · ${t.duration.round()}s',
                style: const TextStyle(fontSize: 10.5, color: Colors.white70)),
          ),
          const Spacer(),
          Text(t.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 2),
          Text(t.subtitle, style: const TextStyle(fontSize: 12, color: Colors.white70), maxLines: 2),
        ]),
      ),
    );
  }

  Widget _projectCard(Project p) {
    final m = p.main;
    final hue = (p.id.hashCode % 360).abs().toDouble();
    final c1 = HSLColor.fromAHSL(1, hue, 0.45, 0.28).toColor();
    final c2 = HSLColor.fromAHSL(1, (hue + 40) % 360, 0.5, 0.14).toColor();
    final title = m.layers.where((l) => l.type == LayerType.text).map((l) => l.text?.text ?? '').firstOrNull;
    return GestureDetector(
      onTap: () => _open(p),
      onLongPress: () => _menu(p),
      child: Container(
        decoration: MA.card(color: MA.surface),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(gradient: LinearGradient(colors: [c1, c2], begin: Alignment.topLeft, end: Alignment.bottomRight)),
              child: Center(
                child: AspectRatio(
                  aspectRatio: m.width / m.height,
                  child: Container(
                    margin: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.white24),
                    ),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(4),
                    child: Text(
                      title ?? '${m.layers.length} layers',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text('${m.width.round()}×${m.height.round()} · ${_ago(p.modified)}',
                      style: const TextStyle(fontSize: 11, color: MA.textDim)),
                ]),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.more_vert, size: 18, color: MA.textDim),
                onPressed: () => _menu(p),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _empty() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 40),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: MA.card(),
          child: const Column(children: [
            Icon(Icons.auto_awesome_motion_outlined, size: 42, color: MA.accent),
            SizedBox(height: 10),
            Text('No projects yet', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            SizedBox(height: 4),
            Text('Pick a format or a template above to start.', style: TextStyle(color: MA.textDim)),
          ]),
        ),
      );

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}
