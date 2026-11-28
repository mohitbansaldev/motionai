import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/agent.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../platform/win_window.dart';
import '../services/media_importer.dart';
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
import 'preview/multi_view.dart'; // win-40
import 'preview/preview_quality.dart'; // PERF (Agent O)
import 'theme.dart';
import 'preview/gizmo3d.dart' show ViewTools; // win-43
import 'timeline/timeline_view.dart';
import 'library/library_sheet.dart';
import 'library/save_template_dialog.dart';
import 'library/template_gallery.dart';
import 'director_screen.dart';
import 'audio/sound_sheet.dart';
import 'bulk/bulk_actions.dart'; // BULK (Agent N)
import 'bulk/bulk_bar.dart'; // BULK (Agent N)
import 'bulk/bulk_menu.dart'; // BULK (Agent N)
import '../remote/remote_control.dart'; // MCP (Agent P)

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
  final _timelineKey = GlobalKey<TimelineViewState>();
  double _timelineH = 250;
  bool _leftOpen = true; // win-43: desktop left drawer (Add / media)
  bool _dropHover = false;
  bool _importing = false;
  Timer? _nudgeTimer;

  static bool get _desktopOs => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    c.attachTicker(this);
    c.addListener(_onSelectionChange);
    c.seek(0);
    HardwareKeyboard.instance.addHandler(_onKey);
    WinWindow.setTitle(c.project.name);
    RemoteControl.instance.attach(c); // MCP (Agent P): Claude can drive this editor
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
    RemoteControl.instance.detach(c); // MCP (Agent P)
    HardwareKeyboard.instance.removeHandler(_onKey);
    _nudgeTimer?.cancel();
    if (_nudgeTimer != null) c.endGesture();
    WinWindow.setTitle(null);
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


  // ------------------------------------------------------------ desktop

  /// Right-click menu for a layer (timeline clip or the selected layer in
  /// the preview). Same actions as the phone's long-press sheet.
  Future<void> _layerContextMenu(Layer l, Offset global) async {
    // BULK (Agent N): several layers selected → the multi-layer menu.
    if (c.hasMultiSelection && c.isSelected(l.id)) return BulkMenu.show(context, c, global);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final pos = RelativeRect.fromRect(global & const Size(1, 1), Offset.zero & overlay.size);
    PopupMenuItem<String> item(String v, IconData icon, String label, [String? keys, Color? color]) => PopupMenuItem(
          value: v,
          height: 36,
          child: Row(children: [
            Icon(icon, size: 18, color: color ?? MA.textDim),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: TextStyle(fontSize: 13, color: color))),
            if (keys != null) Text(keys, style: const TextStyle(fontSize: 11.5, color: MA.textDim)),
          ]),
        );
    final v = await showMenu<String>(
      context: context,
      position: pos,
      color: MA.surface2,
      items: [
        PopupMenuItem(enabled: false, height: 30, child: Text(l.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5))),
        item('split', Icons.content_cut, 'Split at playhead', 'S'),
        item('dup', Icons.copy, 'Duplicate', 'Ctrl+D'),
        item('up', Icons.arrow_upward, 'Bring forward'),
        item('down', Icons.arrow_downward, 'Send backward'),
        item('vis', l.visible ? Icons.visibility_off_outlined : Icons.visibility_outlined, l.visible ? 'Hide' : 'Show'),
        item('lock', l.locked ? Icons.lock_open : Icons.lock_outline, l.locked ? 'Unlock' : 'Lock'),
        item('rename', Icons.edit_outlined, 'Rename layer'),
        item('template', Icons.bookmark_add_outlined, 'Save as template…'),
        const PopupMenuDivider(),
        item('delete', Icons.delete_outline, 'Delete', 'Del', Colors.redAccent),
      ],
    );
    if (v == null || !mounted) return;
    String? err;
    switch (v) {
      case 'split':
        err = c.tryRun({'op': 'split_layer', 'layer': l.id, 'time': c.time});
      case 'dup':
        err = c.tryRun({'op': 'duplicate_layer', 'layer': l.id});
      case 'up':
        err = c.tryRun({'op': 'reorder_layer', 'layer': l.id, 'index': (c.comp.indexOf(l.id) - 1).clamp(0, 9999)});
      case 'down':
        err = c.tryRun({'op': 'reorder_layer', 'layer': l.id, 'index': c.comp.indexOf(l.id) + 1});
      case 'vis':
        err = c.tryRun({'op': 'update_layer', 'layer': l.id, 'visible': !l.visible});
      case 'lock':
        err = c.tryRun({'op': 'update_layer', 'layer': l.id, 'locked': !l.locked});
      case 'rename':
        final ctl = TextEditingController(text: l.name);
        final name = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Layer name'),
            content: TextField(controller: ctl, autofocus: true, onSubmitted: (s) => Navigator.pop(ctx, s)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Save')),
            ],
          ),
        );
        if (name != null && name.trim().isNotEmpty) err = c.tryRun({'op': 'update_layer', 'layer': l.id, 'name': name.trim()});
      case 'template':
        await SaveTemplateDialog.open(context, c, layers: {l.id});
      case 'delete':
        err = c.tryRun({'op': 'remove_layer', 'layer': l.id});
    }
    if (err != null && mounted) showSnack(context, err);
  }

  bool _typing() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText || ctx.findAncestorStateOfType<EditableTextState>() != null;
  }

  /// Keyboard shortcuts (desktop and phones with a keyboard).
  bool _onKey(KeyEvent e) {
    if (e is KeyUpEvent || !mounted) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? false) || _typing()) return false;
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    final shift = kb.isShiftPressed;
    final k = e.logicalKey;
    final repeat = e is KeyRepeatEvent;
    final sel = c.selectedLayer;

    if (ctrl) {
      if (repeat && k != LogicalKeyboardKey.keyZ && k != LogicalKeyboardKey.keyY) return false;
      // PERF (Agent O) >>> Ctrl+Shift+F: preview FPS meter
      if (shift && k == LogicalKeyboardKey.keyF) {
        PreviewQuality.instance.toggleFps();
        return true;
      }
      // <<< PERF (Agent O)
      if (_bulkCtrlKey(k, shift)) return true; // BULK (Agent N): Ctrl+A/C/X/V/G, Ctrl+Shift+C, Ctrl+D on a multi-selection
      if (k == LogicalKeyboardKey.keyZ) {
        if (shift) {
          c.redo();
        } else {
          c.undo();
        }
      } else if (k == LogicalKeyboardKey.keyY) {
        c.redo();
      } else if (k == LogicalKeyboardKey.keyD) {
        if (sel != null) c.tryRun({'op': 'duplicate_layer', 'layer': sel.id});
      } else if (k == LogicalKeyboardKey.keyS) {
        c.save().then((_) {
          if (mounted) showSnack(context, 'Saved');
        });
      } else if (k == LogicalKeyboardKey.keyE) {
        _export();
      } else if (k == LogicalKeyboardKey.keyI) {
        _importDialog();
      } else if (k == LogicalKeyboardKey.digit0 || k == LogicalKeyboardKey.numpad0) {
        _timelineKey.currentState?.zoomToFit();
      } else {
        return false;
      }
      return true;
    }

    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      final step = shift ? 10.0 : 1.0;
      final dx = k == LogicalKeyboardKey.arrowLeft ? -step : (k == LogicalKeyboardKey.arrowRight ? step : 0.0);
      final dy = k == LogicalKeyboardKey.arrowUp ? -step : (k == LogicalKeyboardKey.arrowDown ? step : 0.0);
      if (c.hasMultiSelection && !c.playing) {
        _bulkNudge(dx, dy); // BULK (Agent N): nudge every selected layer
      } else if (sel != null && !sel.locked && !c.playing) {
        _nudge(sel, dx, dy);
      } else if (dx != 0) {
        c.seek(c.time + (shift ? dx.sign : dx.sign * c.comp.frameDuration));
      } else {
        return false;
      }
      return true;
    }
    if (repeat) {
      if (k == LogicalKeyboardKey.comma) c.stepFrames(-1);
      if (k == LogicalKeyboardKey.period) c.stepFrames(1);
      return k == LogicalKeyboardKey.comma || k == LogicalKeyboardKey.period;
    }
    if (_bulkKey(e, shift)) return true; // BULK (Agent N): Shift+3, S, Delete, Esc on a multi-selection
    if (k == LogicalKeyboardKey.space) {
      c.togglePlay();
    } else if (k == LogicalKeyboardKey.keyK) {
      c.pause();
    } else if (k == LogicalKeyboardKey.keyJ) {
      c.shuttle(-1);
    } else if (k == LogicalKeyboardKey.keyL) {
      c.shuttle(1);
    } else if (k == LogicalKeyboardKey.keyS) {
      if (sel == null) {
        showSnack(context, 'Select a layer to split');
      } else {
        final err = c.tryRun({'op': 'split_layer', 'layer': sel.id, 'time': c.time});
        if (err != null) showSnack(context, err);
      }
    } else if (k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) {
      if (sel == null) return false;
      c.tryRun({'op': 'remove_layer', 'layer': sel.id});
    } else if (k == LogicalKeyboardKey.equal || k == LogicalKeyboardKey.add || k == LogicalKeyboardKey.numpadAdd) {
      _timelineKey.currentState?.zoomBy(1.4);
    } else if (k == LogicalKeyboardKey.minus || k == LogicalKeyboardKey.numpadSubtract) {
      _timelineKey.currentState?.zoomBy(1 / 1.4);
    } else if (k == LogicalKeyboardKey.backslash) {
      _timelineKey.currentState?.zoomToFit();
    } else if (k == LogicalKeyboardKey.home) {
      c.seek(0);
    } else if (k == LogicalKeyboardKey.end) {
      c.seek(c.comp.duration);
    } else if (k == LogicalKeyboardKey.comma) {
      c.stepFrames(-1);
    } else if (k == LogicalKeyboardKey.period) {
      c.stepFrames(1);
    } else if (k == LogicalKeyboardKey.escape) {
      if (sel == null && !c.cameraSelected && !c.multiSelectMode) return false;
      c.clearSelection(); // BULK (Agent N): clears the whole selection
    } else if (k == LogicalKeyboardKey.keyW) { // win-43 >>> viewer tools
      ViewTools.instance.tool = 'move';
    } else if (k == LogicalKeyboardKey.keyE) {
      ViewTools.instance.tool = 'rotate';
    } else if (k == LogicalKeyboardKey.keyR) {
      ViewTools.instance.tool = 'scale';
    } else if (k == LogicalKeyboardKey.keyC) {
      ViewTools.instance.cycleCamera();
    } else if (k == LogicalKeyboardKey.keyX) {
      ViewTools.instance.local = !ViewTools.instance.local; // <<< win-43
    } else if (k == LogicalKeyboardKey.f1 || k == LogicalKeyboardKey.slash) {
      _showShortcuts();
    } else {
      return false;
    }
    return true;
  }

  // BULK (Agent N) >>> multi-selection shortcuts
  bool _bulkCtrlKey(LogicalKeyboardKey k, bool shift) {
    if (k == LogicalKeyboardKey.keyA) {
      c.selectAll();
      return true;
    }
    if (k == LogicalKeyboardKey.keyC && shift) {
      if (c.selectionCount == 0) return false;
      BulkMenu.run(context, c, 'precomp');
      return true;
    }
    if (k == LogicalKeyboardKey.keyC) {
      if (c.selectionCount == 0) return false;
      BulkMenu.run(context, c, 'copy');
      return true;
    }
    if (k == LogicalKeyboardKey.keyX) {
      if (c.selectionCount == 0) return false;
      BulkMenu.run(context, c, 'cut');
      return true;
    }
    if (k == LogicalKeyboardKey.keyV) {
      BulkActions(c).pasteLayers(atOriginalTime: shift).then((err) {
        if (mounted) bulkReport(context, err);
      });
      return true;
    }
    if (k == LogicalKeyboardKey.keyG) {
      if (c.selectionCount == 0) return false;
      BulkMenu.run(context, c, 'group');
      return true;
    }
    if (k == LogicalKeyboardKey.keyD && c.hasMultiSelection) {
      BulkMenu.run(context, c, 'dup');
      return true;
    }
    return false;
  }

  bool _bulkKey(KeyEvent e, bool shift) {
    final k = e.logicalKey;
    final kb = HardwareKeyboard.instance;
    if (kb.isAltPressed) return false;
    if (shift && (e.physicalKey == PhysicalKeyboardKey.digit3 || k == LogicalKeyboardKey.digit3 || k == LogicalKeyboardKey.numberSign)) {
      if (c.selectionCount == 0) return false;
      bulkReport(context, BulkActions(c).toggle3D());
      return true;
    }
    if (!c.hasMultiSelection) return false;
    if (k == LogicalKeyboardKey.keyS) {
      BulkMenu.run(context, c, 'split');
      return true;
    }
    if (k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) {
      BulkMenu.run(context, c, 'delete');
      return true;
    }
    return false;
  }

  /// Nudges every selected layer; key-repeats merge into one undo step.
  void _bulkNudge(double dx, double dy) {
    if (_nudgeTimer == null) c.beginGesture();
    _nudgeTimer?.cancel();
    BulkActions(c).nudge(dx, dy, record: false);
    _nudgeTimer = Timer(const Duration(milliseconds: 600), () {
      _nudgeTimer = null;
      c.endGesture();
    });
  }
  // <<< BULK (Agent N)

  /// Moves the selected layer by (dx, dy) comp pixels; key-repeats merge
  /// into one undo step.
  void _nudge(Layer l, double dx, double dy) {
    if (_nudgeTimer == null) c.beginGesture();
    _nudgeTimer?.cancel();
    final p = l.prop(Props.position).valueAt(c.time);
    c.tryRun({
      'op': 'set_property',
      'layer': l.id,
      'prop': Props.position,
      'value': [p[0] + dx, p[1] + dy, if (p.length > 2) p[2]],
    }, record: false);
    _nudgeTimer = Timer(const Duration(milliseconds: 600), () {
      _nudgeTimer = null;
      c.endGesture();
    });
  }

  void _showShortcuts() {
    const rows = [
      ('Space', 'Play / pause'),
      ('J  K  L', 'Shuttle back / stop / forward (press again = faster)'),
      ('← →', 'Previous / next frame (Shift = 1 s); with a layer selected: nudge'),
      ('↑ ↓ ← →', 'Nudge selected layer 1 px (Shift = 10 px)'),
      (',  .', 'Previous / next frame'),
      ('Home / End', 'Go to start / end'),
      ('S', 'Split selected layer at the playhead'),
      ('W / E / R', 'Viewer: move / rotate / scale gizmo'), // win-43
      ('C', 'Viewer: camera tools (orbit → pan → dolly)'),
      ('X', 'Gizmo axes: world / local'),
      ('Ctrl+D', 'Duplicate layer'),
      ('Delete', 'Delete layer'),
      ('Ctrl+Z / Ctrl+Y', 'Undo / redo'),
      ('+ / −', 'Timeline zoom in / out'),
      ('\\ or Ctrl+0', 'Fit the whole video in the timeline'),
      ('Ctrl + wheel', 'Zoom the timeline at the mouse'),
      ('Shift + wheel', 'Scroll the timeline sideways'),
      ('Right-click', 'Layer menu'),
      ('Ctrl+I', 'Import photos, videos or audio'),
      ('Ctrl+S / Ctrl+E', 'Save / export'),
      ('Esc', 'Deselect'),
      // BULK (Agent N): multi-selection
      ('Ctrl/Cmd + click', 'Add / remove a layer from the selection (timeline and preview)'),
      ('Shift + click', 'Select a range of layers (timeline); add to the selection (preview)'),
      ('Drag on empty area', 'Rubber-band select (timeline and preview; Ctrl/Shift adds)'),
      ('Ctrl+A', 'Select all layers of the open comp'),
      ('Ctrl+C / X / V', 'Copy / cut / paste layers (paste at the playhead; works across comps and projects)'),
      ('Ctrl+Shift+V', 'Paste layers at their original time'),
      ('Ctrl+G', 'Group the selection into a null parent'),
      ('Ctrl+Shift+C', 'Precompose the selection'),
      ('Shift+3', 'Make the selection 3D / 2D'),
      ('Drag a selected clip', 'Moves every selected clip in time (Alt+drag duplicates)'),
      ('Drag in the preview', 'Moves every selected layer (pinch: scale/rotate around the selection centre)'),
      ('Alt + wheel', 'Scale the selection in the preview (Alt+Shift+wheel rotates)'),
      ('Right-click', 'With several layers selected: the multi-layer menu'),
    ];
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Keyboard & mouse'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final (k, d) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 130, child: Text(k, style: const TextStyle(fontWeight: FontWeight.w700, color: MA.accent2))),
                    Expanded(child: Text(d, style: const TextStyle(color: MA.textDim))),
                  ]),
                ),
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  Future<void> _importDialog() async {
    final kind = await showDialog<MediaType>(
      context: context,
      builder: (ctx) => SimpleDialog(title: const Text('Import'), children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, MediaType.video), child: const Text('Videos')),
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, MediaType.image), child: const Text('Photos')),
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, MediaType.audio), child: const Text('Music / voice-over')),
      ]),
    );
    if (kind == null) return;
    final importer = MediaImporter(c.storage);
    final picked = await importer.pick(kind: kind);
    await _addAssets(picked, importer.errors);
  }

  /// Files dropped from Explorer: import and place them at the playhead.
  Future<void> _onDrop(DropDoneDetails d) async {
    setState(() => _dropHover = false);
    final paths = [for (final f in d.files) if (f.path.isNotEmpty) f.path];
    if (paths.isEmpty) return;
    setState(() => _importing = true);
    try {
      final importer = MediaImporter(c.storage);
      final assets = await importer.importPaths(paths);
      await _addAssets(assets, importer.errors);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _addAssets(List<MediaAsset> assets, List<String> errors) async {
    if (!mounted) return;
    if (errors.isNotEmpty) showSnack(context, 'Could not import ${errors.join('; ')}');
    if (assets.isEmpty) return;
    for (final a in assets) {
      c.project.media[a.id] = a;
    }
    c.mediaChanged();
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
    if (!mounted) return;
    if (err != null) {
      showSnack(context, err);
    } else {
      c.select(c.comp.layers.first.id);
      showSnack(context, 'Added ${assets.length} file${assets.length == 1 ? '' : 's'}');
    }
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
      WinWindow.setTitle(c.project.name);
      c.save();
    }
  }

  Future<void> _export() async {
    c.pause();
    await c.save();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ExportScreen(project: c.project)));
  }

  // win-43 >>> top bar: brand mark, project + format pill, Claude link status, undo/redo, menu, Export
  PreferredSizeWidget _appBar() => AppBar(
        titleSpacing: 0,
        toolbarHeight: 52,
        shape: const Border(bottom: BorderSide(color: MA.stroke)),
        leading: IconButton(tooltip: 'Projects', icon: const Icon(Icons.arrow_back_ios_new, size: 17), onPressed: () => Navigator.pop(context)),
        title: Row(children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(gradient: MA.gradient, borderRadius: BorderRadius.circular(7)),
            child: const Icon(Icons.movie_filter_rounded, size: 16, color: MA.onAccent),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _rename,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Text(c.project.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _pill('${c.comp.width.round()}×${c.comp.height.round()} · ${c.comp.fps.round()} fps'),
        ]),
        actions: [
          if (RemoteControl.supported)
            ListenableBuilder(
              listenable: RemoteControl.instance,
              builder: (_, _) {
                final rc = RemoteControl.instance;
                final live = rc.connected;
                return Tooltip(
                  message: live ? 'Claude is connected${rc.client == null ? '' : ' (${rc.client})'}' : (rc.running ? 'Claude control is on — waiting for Claude' : 'Claude control is off'),
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(color: MA.surface2, borderRadius: BorderRadius.circular(20), border: Border.all(color: MA.stroke)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: live ? MA.success : (rc.running ? MA.warning : MA.textFaint))),
                      const SizedBox(width: 6),
                      Text(live ? 'Claude live' : 'Claude', style: const TextStyle(fontSize: 11.5, color: MA.textDim, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                );
              },
            ),
          AnimatedBuilder(
            animation: c,
            builder: (_, _) => Row(children: [
              IconButton(tooltip: 'Undo (Ctrl+Z)', icon: const Icon(Icons.undo_rounded, size: 19), onPressed: c.canUndo ? c.undo : null),
              IconButton(tooltip: 'Redo (Ctrl+Y)', icon: const Icon(Icons.redo_rounded, size: 19), onPressed: c.canRedo ? c.redo : null),
            ]),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_horiz_rounded),
            onSelected: _menu,
            itemBuilder: (_) => [
              if (_desktopOs) const PopupMenuItem(value: 'import', child: Text('Import files…  (Ctrl+I)')),
              const PopupMenuItem(value: 'director', child: Text('Director (AI makes the video)')),
              const PopupMenuItem(value: 'templates', child: Text('Templates')),
              const PopupMenuItem(value: 'library', child: Text('Asset library')),
              const PopupMenuItem(value: 'sound', child: Text('Sound FX, beats & mix')),
              const PopupMenuItem(value: 'rename', child: Text('Rename project')),
              const PopupMenuItem(value: 'captions', child: Text('Auto captions')),
              const PopupMenuItem(value: 'console', child: Text('Edit commands (developer)')),
              if (_desktopOs) const PopupMenuItem(value: 'keys', child: Text('Keyboard shortcuts  (F1)')),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12, left: 6),
            child: GradientButton(label: 'Export', icon: Icons.ios_share_rounded, onTap: _export),
          ),
        ],
      );

  void _menu(String v) {
    if (v == 'console') CommandConsole.open(context, c);
    if (v == 'captions') CaptionsSheet.open(context, c);
    if (v == 'rename') _rename();
    if (v == 'keys') _showShortcuts();
    if (v == 'import') _importDialog();
    if (v == 'library') LibrarySheet.open(context, c);
    if (v == 'templates') TemplateGallery.open(context, c);
    if (v == 'director') DirectorScreen.open(context, c);
    if (v == 'sound') SoundSheet.open(context, c);
  }

  Widget _pill(String s) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: MA.surface2, borderRadius: BorderRadius.circular(6), border: Border.all(color: MA.stroke)),
        child: Text(s, style: const TextStyle(fontSize: 11, color: MA.textDim, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
      );

  /// Desktop tool rail (left edge).
  Widget _rail() {
    Widget item(IconData icon, String tip, VoidCallback onTap, {bool on = false, Color? color}) => Tooltip(
          message: tip,
          preferBelow: false,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Container(
              width: 40,
              height: 40,
              margin: const EdgeInsets.symmetric(vertical: 3),
              decoration: BoxDecoration(
                color: on ? MA.accent.withValues(alpha: 0.16) : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: on ? MA.accent.withValues(alpha: 0.5) : Colors.transparent),
              ),
              child: Icon(icon, size: 20, color: on ? MA.accentHi : (color ?? MA.textDim)),
            ),
          ),
        );
    return Container(
      width: 54,
      decoration: const BoxDecoration(color: MA.surface, border: Border(right: BorderSide(color: MA.stroke))),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(children: [
        item(Icons.add_box_outlined, 'Add media, text, shapes', () => setState(() => _leftOpen = !_leftOpen), on: _leftOpen),
        item(Icons.photo_library_outlined, 'Asset library', () => LibrarySheet.open(context, c)),
        item(Icons.dashboard_customize_outlined, 'Templates', () => TemplateGallery.open(context, c)),
        item(Icons.movie_creation_outlined, 'Director (AI makes the video)', () => DirectorScreen.open(context, c)),
        item(Icons.graphic_eq_rounded, 'Sound FX, beats & mix', () => SoundSheet.open(context, c)),
        item(Icons.closed_caption_outlined, 'Auto captions', () => CaptionsSheet.open(context, c)),
        const Spacer(),
        item(Icons.keyboard_alt_outlined, 'Keyboard shortcuts (F1)', _showShortcuts),
        item(Icons.terminal_rounded, 'Edit commands', () => CommandConsole.open(context, c)),
      ]),
    );
  }

  /// Desktop status bar (bottom edge).
  Widget _statusBar() => AnimatedBuilder(
        animation: Listenable.merge([c, c.timeNotifier]),
        builder: (_, _) {
          final t = c.time;
          final fps = c.comp.fps <= 0 ? 30.0 : c.comp.fps;
          final frames = (t * fps).round();
          String tc(double secs) {
            final f = (secs * fps).round();
            final s = f ~/ fps.round();
            return '${(s ~/ 3600).toString().padLeft(2, '0')}:${(s ~/ 60 % 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}:${(f % fps.round()).toString().padLeft(2, '0')}';
          }

          final sel = c.selectedLayer;
          const st = TextStyle(fontSize: 11, color: MA.textDim, fontFeatures: [FontFeature.tabularFigures()]);
          return Container(
            height: 26,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(color: MA.surface, border: Border(top: BorderSide(color: MA.stroke))),
            child: Row(children: [
              Text(tc(t), style: st.copyWith(color: MA.accentHi, fontWeight: FontWeight.w700)),
              const SizedBox(width: 6),
              Text('/ ${tc(c.comp.duration)}', style: st),
              const SizedBox(width: 14),
              Text('frame $frames', style: st),
              const SizedBox(width: 14),
              Text('${c.comp.layers.length} layers', style: st),
              if (sel != null) ...[
                const SizedBox(width: 14),
                Flexible(child: Text('● ${sel.name}', overflow: TextOverflow.ellipsis, style: st.copyWith(color: MA.text))),
              ],
              if (c.cameraSelected) ...[const SizedBox(width: 14), Text('● Camera', style: st.copyWith(color: MA.text))],
              const Spacer(),
              Text('Camera: ${c.comp.camera.mode.name == 'threeD' ? '3D' : c.comp.camera.mode.name == 'twoD' ? '2D' : 'off'}', style: st),
              const SizedBox(width: 14),
              ListenableBuilder(
                listenable: ViewTools.instance,
                builder: (_, _) => Text('Tool: ${ViewTools.labels[ViewTools.instance.tool] ?? ViewTools.instance.tool}', style: st),
              ),
            ]),
          );
        },
      );
  // <<< win-43

  Widget _preview() => Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF040506), // win-43
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: MA.stroke),
            ),
            child: Stack(fit: StackFit.expand, children: [
              Positioned.fill(
                child: GestureDetector(
                  onSecondaryTapUp: (d) {
                    final l = c.selectedLayer;
                    if (l != null) _layerContextMenu(l, d.globalPosition); // BULK (Agent N): multi menu inside
                  },
                  child: CompositionViews(controller: c), // win-40: 1 / 2 / 4 / 1+3 view layouts
                ),
              ),
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
        margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
        padding: const EdgeInsets.all(4),
        decoration: MA.panel(radius: 12), // win-43
        child: TabBar(
          controller: _tabs,
          dividerColor: Colors.transparent,
          indicatorSize: TabBarIndicatorSize.tab,
          indicator: BoxDecoration(
            color: MA.surface3,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: MA.accent.withValues(alpha: 0.45)),
          ), // win-43
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
        decoration: MA.panel(radius: 12), // win-43
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
        decoration: MA.panel(radius: 12), // win-43
        clipBehavior: Clip.antiAlias,
        child: TimelineView(key: _timelineKey, controller: c, onLayerMenu: _layerMenu, onLayerContextMenu: _layerContextMenu),
      );

  /// PC layout: big preview in the middle, panels on the right, a
  /// full-width resizable timeline at the bottom.
  Widget _desktop(BoxConstraints box) {
    final side = (box.maxWidth * 0.27).clamp(330.0, 440.0).toDouble();
    final maxTl = math.max(160.0, box.maxHeight - 300);
    final tl = _timelineH.clamp(150.0, maxTl).toDouble();
    final left = (box.maxWidth * 0.2).clamp(260.0, 340.0).toDouble(); // win-43
    final showLeft = _leftOpen && box.maxWidth >= 1250;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _rail(), // win-43
      Expanded(child: Column(children: [
      Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (showLeft) // win-43: Add / media drawer
            Container(
              width: left,
              margin: const EdgeInsets.fromLTRB(10, 8, 0, 0),
              decoration: MA.panel(radius: 12),
              clipBehavior: Clip.antiAlias,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 6, 4),
                  child: Row(children: [
                    const Expanded(child: Text('ADD', style: TextStyle(fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w800, color: MA.textDim))),
                    IconButton(tooltip: 'Hide', icon: const Icon(Icons.chevron_left_rounded, size: 18), onPressed: () => setState(() => _leftOpen = false)),
                  ]),
                ),
                Expanded(child: AddPanel(c: c)),
              ]),
            ),
          Expanded(
            child: Column(children: [
              Expanded(child: _preview()),
              _DesktopTransport(c: c, timeline: _timelineKey, onHelp: _showShortcuts),
            ]),
          ),
          SizedBox(
            width: side,
            child: Column(children: [
              _dock(),
              Expanded(child: _panels()),
            ]),
          ),
        ]),
      ),
      MouseRegion(
        cursor: SystemMouseCursors.resizeRow,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (d) => setState(() => _timelineH = (tl - d.delta.dy).clamp(150.0, maxTl).toDouble()),
          child: SizedBox(
            height: 10,
            child: Center(
              child: Container(width: 48, height: 3, decoration: BoxDecoration(color: MA.stroke, borderRadius: BorderRadius.circular(2))),
            ),
          ),
        ),
      ),
      BulkBar(c: c), // BULK (Agent N): bulk action strip above the timeline
      _timeline(tl),
      const SizedBox(height: 8),
      _statusBar(), // win-43
    ])),
    ]);
  }

  Widget _dropLayer(Widget child) {
    if (!_desktopOs) return child;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dropHover = true),
      onDragExited: (_) => setState(() => _dropHover = false),
      onDragDone: _onDrop,
      child: Stack(children: [
        Positioned.fill(child: child),
        if (_dropHover || _importing)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: MA.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: MA.accent2, width: 2),
                ),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    decoration: MA.card(color: MA.surface2),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      _importing
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.file_download_outlined, color: MA.accent2),
                      const SizedBox(width: 10),
                      Text(_importing ? 'Importing…' : 'Drop photos, videos or audio to add them at the playhead'),
                    ]),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _appBar(),
      body: SafeArea(
        top: false,
        child: _dropLayer(LayoutBuilder(builder: (context, box) {
          final desktop = _desktopOs ? box.maxWidth >= 900 && box.maxHeight >= 520 : box.maxWidth >= 1280 && box.maxHeight >= 700;
          if (desktop) return _desktop(box);
          final landscape = box.maxWidth > box.maxHeight * 1.1;
          if (landscape) {
            return Row(children: [
              Expanded(
                child: Column(children: [
                  Expanded(child: _preview()),
                  _TransportBar(c: c),
                  BulkPhoneBar(c: c), // BULK (Agent N)
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
            BulkPhoneBar(c: c), // BULK (Agent N)
            _timeline(170),
            _dock(),
            Expanded(flex: 5, child: _panels()),
          ]);
        })),
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

/// Transport bar for the PC layout: time, shuttle, loop and timeline zoom.
class _DesktopTransport extends StatelessWidget {
  final EditorController c;
  final GlobalKey<TimelineViewState> timeline;
  final VoidCallback onHelp;
  const _DesktopTransport({required this.c, required this.timeline, required this.onHelp});

  Widget _btn(IconData icon, String tip, VoidCallback onTap, {Color? color, double size = 22}) => IconButton(
        tooltip: tip,
        iconSize: size,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, color: color),
        onPressed: onTap,
      );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      child: AnimatedBuilder(
        animation: Listenable.merge([c, c.timeNotifier]),
        builder: (context, _) => Row(children: [
          const SizedBox(width: 16),
          SizedBox(
            width: 170,
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: formatTime(c.time, c.comp.fps), style: const TextStyle(color: MA.text, fontWeight: FontWeight.w700)),
                TextSpan(text: '  /  ${formatTime(c.comp.duration, c.comp.fps)}', style: const TextStyle(color: MA.textDim)),
              ]),
              style: const TextStyle(fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          const Spacer(),
          _btn(Icons.first_page_rounded, 'Start (Home)', () => c.seek(0)),
          _btn(Icons.fast_rewind_rounded, 'Shuttle back (J)', () => c.shuttle(-1)),
          _btn(Icons.chevron_left_rounded, 'Previous frame (←)', () => c.stepFrames(-1)),
          const SizedBox(width: 4),
          Tooltip(
            message: 'Play / pause (Space)',
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: Ink(
                width: 42,
                height: 42,
                decoration: const BoxDecoration(gradient: MA.gradient, shape: BoxShape.circle),
                child: InkWell(
                  onTap: c.togglePlay,
                  child: Icon(c.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 26),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          _btn(Icons.chevron_right_rounded, 'Next frame (→)', () => c.stepFrames(1)),
          _btn(Icons.fast_forward_rounded, 'Shuttle forward (L)', () => c.shuttle(1)),
          _btn(Icons.last_page_rounded, 'End (End)', () => c.seek(c.comp.duration)),
          _btn(Icons.repeat_rounded, 'Loop', () => c.setLoop(!c.loop), color: c.loop ? MA.accent2 : MA.textDim),
          SizedBox(
            width: 44,
            child: c.playing && c.rate != 1
                ? Text('${c.rate > 0 ? '' : '−'}${c.rate.abs().round()}×', style: const TextStyle(color: MA.gold, fontWeight: FontWeight.w700))
                : null,
          ),
          const Spacer(),
          _btn(Icons.zoom_out_rounded, 'Zoom out (−)', () => timeline.currentState?.zoomBy(1 / 1.4), size: 20),
          _btn(Icons.fit_screen_outlined, 'Fit (\\)', () => timeline.currentState?.zoomToFit(), size: 20),
          _btn(Icons.zoom_in_rounded, 'Zoom in (+)', () => timeline.currentState?.zoomBy(1.4), size: 20),
          _btn(Icons.keyboard_outlined, 'Shortcuts (F1)', onHelp, size: 20, color: MA.textDim),
          const SizedBox(width: 8),
        ]),
      ),
    );
  }
}
