import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/agent.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../services/project_storage.dart';
import '../state/editor_controller.dart';
import 'captions_sheet.dart';
import 'command_console.dart';
import 'export_screen.dart';
import 'common.dart';
import 'panels/add_panel.dart';
import 'panels/ai_panel.dart';
import 'panels/camera_panel.dart';
import 'panels/effects_panel.dart';
import 'panels/layer_panel.dart';
import 'preview/composition_view.dart';
import 'theme.dart';
import 'timeline/timeline_view.dart';

class EditorScreen extends StatefulWidget {
  final Project project;
  final ProjectStorage storage;
  const EditorScreen({super.key, required this.project, required this.storage});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> with TickerProviderStateMixin {
  late final EditorController c = EditorController(widget.project, widget.storage);
  late final TabController _tabs = TabController(length: 5, vsync: this);
  late final EditAgent _agent = EditAgent(c);
  String? _lastSelection;
  bool _lastCamera = false;

  @override
  void initState() {
    super.initState();
    c.attachTicker(this);
    c.addListener(_onSelectionChange);
    c.seek(0);
  }

  void _onSelectionChange() {
    if (c.selectedLayerId != _lastSelection && c.selectedLayerId != null && _tabs.index == 0) {
      _tabs.animateTo(1);
    }
    if (c.cameraSelected && !_lastCamera) _tabs.animateTo(2);
    _lastSelection = c.selectedLayerId;
    _lastCamera = c.cameraSelected;
  }

  @override
  void dispose() {
    c.removeListener(_onSelectionChange);
    c.pause();
    c.dispose();
    _tabs.dispose();
    super.dispose();
  }

  void _layerMenu(Layer l) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          ListTile(title: Text(l.name, style: const TextStyle(fontWeight: FontWeight.bold))),
          ListTile(
            leading: const Icon(Icons.arrow_upward),
            title: const Text('Move layer up'),
            onTap: () {
              Navigator.pop(ctx);
              c.tryRun({'op': 'reorder_layer', 'layer': l.id, 'index': (c.comp.indexOf(l.id) - 1).clamp(0, 9999)});
            },
          ),
          ListTile(
            leading: const Icon(Icons.arrow_downward),
            title: const Text('Move layer down'),
            onTap: () {
              Navigator.pop(ctx);
              c.tryRun({'op': 'reorder_layer', 'layer': l.id, 'index': c.comp.indexOf(l.id) + 1});
            },
          ),
          ListTile(
            leading: const Icon(Icons.content_cut),
            title: const Text('Split at playhead'),
            onTap: () {
              Navigator.pop(ctx);
              final e = c.tryRun({'op': 'split_layer', 'layer': l.id, 'time': c.time});
              if (e != null) showSnack(context, e);
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('Duplicate'),
            onTap: () {
              Navigator.pop(ctx);
              c.tryRun({'op': 'duplicate_layer', 'layer': l.id});
            },
          ),
          ListTile(
            leading: Icon(l.locked ? Icons.lock_open : Icons.lock_outline),
            title: Text(l.locked ? 'Unlock' : 'Lock'),
            onTap: () {
              Navigator.pop(ctx);
              c.tryRun({'op': 'update_layer', 'layer': l.id, 'locked': !l.locked});
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
            title: const Text('Delete'),
            onTap: () {
              Navigator.pop(ctx);
              c.tryRun({'op': 'remove_layer', 'layer': l.id});
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _rename() async {
    final ctl = TextEditingController(text: c.project.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Project name'),
        content: TextField(controller: ctl, autofocus: true, onSubmitted: (s) => Navigator.pop(ctx, s)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      setState(() => c.project.name = name.trim());
      c.save();
    }
  }

  Future<void> _export() async {
    c.pause();
    await c.save();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ExportScreen(project: c.project)));
  }

  PreferredSizeWidget _appBar() => AppBar(
        titleSpacing: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios_new, size: 20), onPressed: () => Navigator.pop(context)),
        title: GestureDetector(
          onTap: _rename,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(c.project.name, overflow: TextOverflow.ellipsis),
            Text('${c.comp.width.round()}×${c.comp.height.round()} · ${c.comp.fps.round()} fps',
                style: const TextStyle(fontSize: 11, color: MA.textDim, fontWeight: FontWeight.w400)),
          ]),
        ),
        actions: [
          AnimatedBuilder(
            animation: c,
            builder: (_, _) => Row(children: [
              IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo_rounded), onPressed: c.canUndo ? c.undo : null),
              IconButton(tooltip: 'Redo', icon: const Icon(Icons.redo_rounded), onPressed: c.canRedo ? c.redo : null),
            ]),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              if (v == 'console') CommandConsole.open(context, c);
              if (v == 'captions') CaptionsSheet.open(context, c);
              if (v == 'rename') _rename();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename project')),
              PopupMenuItem(value: 'captions', child: Text('Auto captions')),
              PopupMenuItem(value: 'console', child: Text('Edit commands (developer)')),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10, left: 4),
            child: GradientButton(label: 'Export', icon: Icons.ios_share_rounded, onTap: _export),
          ),
        ],
      );

  Widget _preview() => Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Container(
            color: const Color(0xFF050608),
            child: Stack(children: [
              Positioned.fill(child: CompositionView(controller: c)),
              AnimatedBuilder(
                animation: c,
                builder: (_, _) => c.comp.layers.isEmpty
                    ? Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: MA.card(color: MA.surface.withValues(alpha: 0.9)),
                          child: const Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.add_photo_alternate_outlined, color: MA.accent),
                            SizedBox(width: 10),
                            Text('Add photos, videos or text from the Add tab\nor ask the AI to build a scene',
                                style: TextStyle(fontSize: 12.5, color: MA.textDim)),
                          ]),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ]),
          ),
        ),
      );

  Widget _dock() => Container(
        margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
        padding: const EdgeInsets.all(4),
        decoration: MA.card(color: MA.surface, radius: 14),
        child: TabBar(
          controller: _tabs,
          dividerColor: Colors.transparent,
          indicatorSize: TabBarIndicatorSize.tab,
          indicator: BoxDecoration(color: MA.surface3, borderRadius: BorderRadius.circular(10)),
          labelColor: MA.text,
          unselectedLabelColor: MA.textDim,
          labelPadding: EdgeInsets.zero,
          labelStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          unselectedLabelStyle: const TextStyle(fontSize: 11),
          onTap: (_) => HapticFeedback.selectionClick(),
          tabs: const [
            Tab(height: 48, icon: Icon(Icons.add_circle_outline, size: 20), text: 'Add'),
            Tab(height: 48, icon: Icon(Icons.tune_rounded, size: 20), text: 'Edit'),
            Tab(height: 48, icon: Icon(Icons.videocam_outlined, size: 20), text: 'Camera'),
            Tab(height: 48, icon: Icon(Icons.auto_fix_high_outlined, size: 20), text: 'Effects'),
            Tab(height: 48, icon: Icon(Icons.auto_awesome, size: 20, color: MA.gold), text: 'AI'),
          ],
        ),
      );

  Widget _panels() => Container(
        margin: const EdgeInsets.fromLTRB(10, 6, 10, 8),
        decoration: MA.card(color: MA.surface, radius: 14),
        clipBehavior: Clip.antiAlias,
        child: TabBarView(
          controller: _tabs,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            AddPanel(c: c),
            LayerPanel(c: c),
            CameraPanel(c: c),
            EffectsPanel(c: c),
            AiPanel(c: c, agent: _agent, onCaptions: () => CaptionsSheet.open(context, c)),
          ],
        ),
      );

  Widget _timeline(double height) => Container(
        height: height,
        margin: const EdgeInsets.symmetric(horizontal: 10),
        decoration: MA.card(color: MA.surface, radius: 14),
        clipBehavior: Clip.antiAlias,
        child: TimelineView(controller: c, onLayerMenu: _layerMenu),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _appBar(),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(builder: (context, box) {
          final landscape = box.maxWidth > box.maxHeight * 1.1;
          if (landscape) {
            return Row(children: [
              Expanded(
                child: Column(children: [
                  Expanded(child: _preview()),
                  _TransportBar(c: c),
                  _timeline(math.min(190, box.maxHeight * 0.36)),
                  const SizedBox(height: 8),
                ]),
              ),
              SizedBox(
                width: math.min(400, box.maxWidth * 0.42),
                child: Column(children: [
                  _dock(),
                  Expanded(child: _panels()),
                ]),
              ),
            ]);
          }
          return Column(children: [
            Expanded(flex: 5, child: _preview()),
            _TransportBar(c: c),
            _timeline(170),
            _dock(),
            Expanded(flex: 5, child: _panels()),
          ]);
        }),
      ),
    );
  }
}

class _TransportBar extends StatelessWidget {
  final EditorController c;
  const _TransportBar({required this.c});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: AnimatedBuilder(
        animation: Listenable.merge([c, c.timeNotifier]),
        builder: (context, _) => Row(children: [
          const SizedBox(width: 16),
          Text.rich(
            TextSpan(children: [
              TextSpan(text: formatTime(c.time, c.comp.fps), style: const TextStyle(color: MA.text)),
              TextSpan(text: '  /  ${formatTime(c.comp.duration, c.comp.fps)}', style: const TextStyle(color: MA.textDim)),
            ]),
            style: const TextStyle(fontSize: 12.5, fontFeatures: [FontFeature.tabularFigures()]),
          ),
          const Spacer(),
          IconButton(icon: const Icon(Icons.skip_previous_rounded), onPressed: () => c.seek(0)),
          IconButton(icon: const Icon(Icons.chevron_left_rounded), onPressed: () => c.stepFrames(-1)),
          GestureDetector(
            onTap: () {
              HapticFeedback.lightImpact();
              c.togglePlay();
            },
            child: Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(gradient: MA.gradient, shape: BoxShape.circle),
              child: Icon(c.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 28),
            ),
          ),
          IconButton(icon: const Icon(Icons.chevron_right_rounded), onPressed: () => c.stepFrames(1)),
          IconButton(
            icon: Icon(Icons.repeat_rounded, color: c.loop ? MA.accent2 : MA.textDim),
            onPressed: () => c.setLoop(!c.loop),
          ),
          const SizedBox(width: 8),
        ]),
      ),
    );
  }
}
