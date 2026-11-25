import 'package:flutter/material.dart';

import '../../core/model/camera.dart';
import '../../core/presets/camera_presets.dart';
import '../../core/presets/scene3d.dart';
import '../../state/editor_controller.dart';
import '../common.dart';
import 'prop_row.dart';

/// Camera mode, one-tap camera moves and keyframeable camera properties.
class CameraPanel extends StatefulWidget {
  final EditorController c;
  const CameraPanel({super.key, required this.c});

  @override
  State<CameraPanel> createState() => _CameraPanelState();
}

class _CameraPanelState extends State<CameraPanel> {
  double _duration = 3;
  String _direction = 'left';

  EditorController get c => widget.c;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([c, c.timeNotifier]),
      builder: (context, _) {
        final comp = c.comp;
        final mode = comp.camera.mode;
        final w = comp.width, h = comp.height;
        PropRow row(String prop, String label, double min, double max, {int? comp, int decimals = 0}) =>
            PropRow(c: c, ref: PropRef('camera', prop), component: comp, label: label, min: min, max: max, decimals: decimals);
        final presets = mode == CameraMode.twoD
            ? CameraPresets.twoD
            : mode == CameraMode.threeD
                ? CameraPresets.threeD
                : [...CameraPresets.threeD, ...CameraPresets.twoD];
        return ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          children: [
            SegmentedButton<CameraMode>(
              segments: const [
                ButtonSegment(value: CameraMode.off, label: Text('Off')),
                ButtonSegment(value: CameraMode.twoD, label: Text('2D Camera')),
                ButtonSegment(value: CameraMode.threeD, label: Text('3D Camera')),
              ],
              selected: {mode},
              onSelectionChanged: (s) => c.tryRun({'op': 'set_camera_mode', 'mode': s.first == CameraMode.twoD ? '2d' : s.first == CameraMode.threeD ? '3d' : 'off'}),
            ),
            const SectionTitle('Camera moves (start at playhead)'),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final p in presets)
                ActionChip(
                  avatar: const Icon(Icons.videocam_outlined, size: 16),
                  label: Text(CameraPresets.label(p)),
                  onPressed: () {
                    final e = c.tryRun({
                      'op': 'camera_move',
                      'preset': p,
                      'start': c.time,
                      'duration': _duration,
                      'direction': _direction,
                    });
                    if (e != null) showSnack(context, e);
                  },
                ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              const Text('Length', style: TextStyle(fontSize: 12.5, color: Colors.white70)),
              const SizedBox(width: 8),
              for (final d in [1.0, 2.0, 3.0, 5.0, 8.0])
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: ChoiceChip(
                    label: Text('${d.toInt()}s'),
                    selected: _duration == d,
                    onSelected: (_) => setState(() => _duration = d),
                  ),
                ),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              const Text('Direction', style: TextStyle(fontSize: 12.5, color: Colors.white70)),
              const SizedBox(width: 8),
              for (final d in ['left', 'right', 'up', 'down'])
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: ChoiceChip(
                    label: Text(d),
                    selected: _direction == d,
                    onSelected: (_) => setState(() => _direction = d),
                  ),
                ),
            ]),
            _ScenePanel(c: c, duration: _duration, direction: _direction),
            if (mode == CameraMode.threeD) ...[
              const SectionTitle('3D camera'),
              row(CamProps.position, 'Pos X', -w, w * 2, comp: 0),
              row(CamProps.position, 'Pos Y', -h * 2, h * 3, comp: 1),
              row(CamProps.position, 'Pos Z', -8000, 4000, comp: 2),
              row(CamProps.poi, 'Target X', -w, w * 2, comp: 0),
              row(CamProps.poi, 'Target Y', -h, h * 2, comp: 1),
              row(CamProps.poi, 'Target Z', -4000, 8000, comp: 2),
              row(CamProps.zoom, 'Zoom', 100, 10000),
              row(CamProps.roll, 'Roll', -180, 180, decimals: 1),
              const SectionTitle('Depth of field'),
              row(CamProps.aperture, 'Aperture', 0, 100),
              row(CamProps.focus, 'Focus dist', 100, 12000),
            ],
            if (mode == CameraMode.twoD) ...[
              const SectionTitle('2D camera'),
              row(CamProps.pan, 'Pan X', -w, w * 2, comp: 0),
              row(CamProps.pan, 'Pan Y', -h, h * 2, comp: 1),
              row(CamProps.zoom2d, 'Zoom %', 10, 800),
              row(CamProps.rotation2d, 'Rotation', -180, 180, decimals: 1),
              row(CamProps.shake, 'Shake', 0, 100),
              row(CamProps.shakeSpeed, 'Shake speed', 0.1, 10, decimals: 1),
            ],
            if (mode == CameraMode.off)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Text(
                  'Pick a camera move above, or switch on the 2D / 3D camera to animate it by hand. '
                  '3D layers always render with perspective, even with the camera off.',
                  style: TextStyle(color: Colors.white54, fontSize: 12.5),
                ),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.restart_alt, size: 16),
              label: const Text('Reset camera'),
              onPressed: _reset,
            ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }

  void _reset() {
    final d = CameraRig.defaults(c.comp.width, c.comp.height);
    c.tryRun({
      'op': 'batch',
      'commands': [
        for (final e in d.props.entries) ...[
          {'op': 'clear_keyframes', 'target': 'camera', 'prop': e.key},
          {'op': 'set_property', 'target': 'camera', 'prop': e.key, 'value': e.value.staticValue},
        ],
      ],
    });
  }
}


/// "Compose flat, play deep": Make 3D with a depth band per layer, the seven
/// aimed camera moves (at the selected layer or a tapped point), saved shots
/// and recipes.
class _ScenePanel extends StatefulWidget {
  final EditorController c;
  final double duration;
  final String direction;
  const _ScenePanel({required this.c, required this.duration, required this.direction});

  @override
  State<_ScenePanel> createState() => _ScenePanelState();
}

class _ScenePanelState extends State<_ScenePanel> {
  final Map<String, String> _bands = {}; // layer id → band ('auto' = guess)
  Offset? _point; // tapped aim point, 0..1 of the frame
  double _intensity = 0.5;

  EditorController get c => widget.c;

  void _run(Map<String, dynamic> cmd, String ok) {
    final e = c.tryRun(cmd);
    if (!mounted) return;
    showSnack(context, e ?? ok);
    setState(() {});
  }

  Future<String?> _askName(String title, String hint) {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctl, autofocus: true, decoration: InputDecoration(labelText: hint)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
  }

  void _make3d(List<String> ids) {
    final bands = <String, String>{};
    for (final id in ids) {
      final b = _bands[id];
      if (b != null && b != 'auto') bands[id] = b;
    }
    _run({'op': 'make_3d', 'layers': ids, 'bands': bands, 'start': c.time}, 'Scene is 3D now: the first frame looks the same, try a camera move.');
  }

  void _shot(String move) {
    final comp = c.comp;
    final sel = c.selectedLayerId;
    final pt = _point;
    _run({
      'op': 'camera_shot',
      'move': move,
      if (pt != null) 'point': [pt.dx * comp.width, pt.dy * comp.height] else if (sel != null) 'target': sel,
      'start': c.time,
      'duration': widget.duration,
      'intensity': _intensity,
      'direction': widget.direction == 'left' ? 'left' : 'right',
    }, '${Scene3D.moveLabel(move)} added.');
  }

  Future<void> _saveShot() async {
    final name = await _askName('Save shot', 'Shot name (e.g. Hut approach)');
    if (name == null || name.isEmpty) return;
    _run({'op': 'save_shot', 'name': name}, 'Shot "$name" saved.');
  }

  Future<void> _saveRecipe() async {
    final sel = c.selectedLayerId;
    if (sel == null) {
      showSnack(context, 'Select the layer whose move, transition, look and frame you want to keep.');
      return;
    }
    final name = await _askName('Save recipe', 'Recipe name (e.g. Dreamy push-in)');
    if (name == null || name.isEmpty) return;
    _run({'op': 'save_recipe', 'name': name, 'layer': sel}, 'Recipe "$name" saved.');
  }

  @override
  Widget build(BuildContext context) {
    final comp = c.comp;
    final t = c.time;
    final layers = comp.layers.where((l) => Scene3D.isVisual(l) && l.isActiveAt(t)).take(16).toList();
    final sel = c.selectedLayer;
    final muted = TextStyle(fontSize: 12.5, color: Colors.white.withValues(alpha: 0.6));
    final aim = _point != null
        ? 'the tapped point'
        : sel != null
            ? sel.name
            : 'the centre of the frame';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('3D scene: compose flat, play deep'),
      Text('Give each layer a depth band (or leave Auto), then Make 3D. The first frame stays exactly the same.', style: muted),
      const SizedBox(height: 6),
      if (layers.isEmpty) Text('No layers at the playhead.', style: muted),
      for (final l in layers)
        Row(children: [
          Expanded(child: Text(l.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
          if (l.is3D) Padding(padding: const EdgeInsets.only(right: 6), child: Text(Scene3D.bandLabel(Scene3D.bandOf(comp, l, t)), style: muted)),
          DropdownButton<String>(
            value: _bands[l.id] ?? 'auto',
            isDense: true,
            items: [
              const DropdownMenuItem(value: 'auto', child: Text('Auto')),
              for (final b in Scene3D.bands) DropdownMenuItem(value: b, child: Text(Scene3D.bandLabel(b))),
            ],
            onChanged: (v) => setState(() => _bands[l.id] = v ?? 'auto'),
          ),
        ]),
      const SizedBox(height: 6),
      FilledButton.icon(
        icon: const Icon(Icons.view_in_ar, size: 18),
        label: const Text('Make 3D'),
        onPressed: layers.isEmpty ? null : () => _make3d([for (final l in layers) l.id]),
      ),
      const SectionTitle('Aimed camera moves (start at playhead)'),
      Text('Aim at: $aim. Select a layer, or tap the frame below to aim at a point.', style: muted),
      const SizedBox(height: 6),
      AspectRatio(
        aspectRatio: comp.width / comp.height,
        child: LayoutBuilder(builder: (context, box) {
          final pt = _point;
          return GestureDetector(
            onTapDown: (d) => setState(() => _point = Offset(
                  (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0),
                  (d.localPosition.dy / box.maxHeight).clamp(0.0, 1.0),
                )),
            child: Container(
              decoration: BoxDecoration(border: Border.all(color: Colors.white24), color: Colors.black26),
              child: Stack(children: [
                if (pt == null) Center(child: Text('tap to aim', style: muted)),
                if (pt != null)
                  Positioned(
                    left: pt.dx * box.maxWidth - 7,
                    top: pt.dy * box.maxHeight - 7,
                    child: const Icon(Icons.center_focus_strong, size: 14, color: Colors.amber),
                  ),
              ]),
            ),
          );
        }),
      ),
      if (_point != null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.close, size: 16),
            label: const Text('Aim at the selected layer instead'),
            onPressed: () => setState(() => _point = null),
          ),
        ),
      Row(children: [
        Text('Intensity', style: muted),
        Expanded(
          child: Slider(value: _intensity, min: 0, max: 1, divisions: 10, label: _intensity.toStringAsFixed(1), onChanged: (v) => setState(() => _intensity = v)),
        ),
      ]),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final m in Scene3D.moves)
          ActionChip(
            avatar: const Icon(Icons.flight_takeoff, size: 16),
            label: Text(Scene3D.moveLabel(m)),
            onPressed: () => _shot(m),
          ),
      ]),
      const SectionTitle('Shots & recipes'),
      Wrap(spacing: 6, runSpacing: 6, children: [
        OutlinedButton.icon(icon: const Icon(Icons.bookmark_add_outlined, size: 16), label: const Text('Save shot'), onPressed: _saveShot),
        OutlinedButton.icon(icon: const Icon(Icons.save_outlined, size: 16), label: const Text('Save recipe'), onPressed: _saveRecipe),
      ]),
      const SizedBox(height: 6),
      if (c.project.shots.isNotEmpty) Text('Load a shot at the playhead:', style: muted),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final n in c.project.shots.keys)
          ActionChip(
            avatar: const Icon(Icons.bookmark_outline, size: 16),
            label: Text(n),
            onPressed: () => _run({'op': 'load_shot', 'name': n, 'start': c.time}, 'Shot "$n" loaded.'),
          ),
      ]),
      if (c.project.recipes.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(sel == null ? 'Select a layer to apply a recipe.' : 'Apply a recipe to ${sel.name}:', style: muted),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final n in c.project.recipes.keys)
            InputChip(
              avatar: const Icon(Icons.restaurant_menu, size: 16),
              label: Text(n),
              onPressed: sel == null ? null : () => _run({'op': 'apply_recipe', 'name': n, 'layer': sel.id, 'start': c.time}, 'Applied "$n".'),
              onDeleted: () => _run({'op': 'delete_recipe', 'name': n}, 'Recipe "$n" deleted.'),
            ),
        ]),
      ],
      const SizedBox(height: 8),
    ]);
  }
}
