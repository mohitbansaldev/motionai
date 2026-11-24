import 'package:flutter/material.dart';

import '../ai/agent.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../services/project_storage.dart';
import '../state/editor_controller.dart';
import 'command_console.dart';
import 'common.dart';
import 'panels/add_panel.dart';
import 'panels/ai_panel.dart';
import 'panels/camera_panel.dart';
import 'panels/effects_panel.dart';
import 'panels/layer_panel.dart';
import 'preview/composition_view.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Text(widget.project.name, overflow: TextOverflow.ellipsis),
        actions: [
          AnimatedBuilder(
            animation: c,
            builder: (_, _) => Row(children: [
              IconButton(icon: const Icon(Icons.undo), onPressed: c.canUndo ? c.undo : null),
              IconButton(icon: const Icon(Icons.redo), onPressed: c.canRedo ? c.redo : null),
            ]),
          ),
          IconButton(
            tooltip: 'Edit commands (AI agent interface)',
            icon: const Icon(Icons.terminal),
            onPressed: () => CommandConsole.open(context, c),
          ),
          IconButton(
            tooltip: 'Export',
            icon: const Icon(Icons.ios_share),
            onPressed: () => showSnack(context, 'Export arrives with the native render engine (milestone 2).'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(flex: 5, child: ColoredBox(color: Colors.black, child: CompositionView(controller: c))),
          _TransportBar(c: c),
          SizedBox(height: 180, child: TimelineView(controller: c, onLayerMenu: _layerMenu)),
          TabBar(
            controller: _tabs,
            labelPadding: EdgeInsets.zero,
            tabs: const [
              Tab(height: 38, text: 'Add'),
              Tab(height: 38, text: 'Layer'),
              Tab(height: 38, text: 'Camera'),
              Tab(height: 38, text: 'Effects'),
              Tab(height: 38, text: 'AI ✨'),
            ],
          ),
          Expanded(
            flex: 4,
            child: TabBarView(
              controller: _tabs,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                AddPanel(c: c),
                LayerPanel(c: c),
                CameraPanel(c: c),
                EffectsPanel(c: c),
                AiPanel(c: c, agent: _agent),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _TransportBar extends StatelessWidget {
  final EditorController c;
  const _TransportBar({required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      color: const Color(0xFF1A1D22),
      child: AnimatedBuilder(
        animation: Listenable.merge([c, c.timeNotifier]),
        builder: (context, _) => Row(children: [
          const SizedBox(width: 8),
          Text(
            '${formatTime(c.time, c.comp.fps)} / ${formatTime(c.comp.duration, c.comp.fps)}',
            style: const TextStyle(fontSize: 12.5, fontFeatures: [FontFeature.tabularFigures()]),
          ),
          const Spacer(),
          IconButton(icon: const Icon(Icons.skip_previous), onPressed: () => c.seek(0)),
          IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => c.stepFrames(-1)),
          IconButton(
            iconSize: 30,
            icon: Icon(c.playing ? Icons.pause_circle_filled : Icons.play_circle_fill),
            onPressed: c.togglePlay,
          ),
          IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => c.stepFrames(1)),
          IconButton(
            icon: Icon(Icons.repeat, color: c.loop ? Colors.amber : Colors.white38),
            onPressed: () => c.setLoop(!c.loop),
          ),
          const SizedBox(width: 4),
        ]),
      ),
    );
  }
}
