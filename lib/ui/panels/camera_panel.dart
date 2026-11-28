import 'package:flutter/material.dart';

import '../../core/model/camera.dart';
import '../../core/presets/camera_presets.dart';
import '../../core/presets/scene3d.dart';
import '../../state/editor_controller.dart';
import '../common.dart';
import 'prop_row.dart';
import 'scrub_field.dart'; // win-43
import 'package:vector_math/vector_math_64.dart' show Vector3; // win-43
import '../../core/engine/evaluator.dart'; // win-43
import '../../core/model/layer.dart'; // win-43

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
      animation: Listenable.merge([c, c.panelTime]), // PERF: quiet while playing
      builder: (context, _) {
        final comp = c.comp;
        final mode = comp.camera.mode;
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
            // win-43 >>> After Effects style camera controls (scrub fields, no limits, every axis)
            if (mode == CameraMode.threeD) ..._threeD(comp.width),
            if (mode == CameraMode.twoD)
              PropGroup(title: '2D Camera', children: [
                VecPropRow(c: c, ref: const PropRef('camera', CamProps.pan), label: 'Pan', names: const ['X', 'Y']),
                VecPropRow(c: c, ref: const PropRef('camera', CamProps.zoom2d), label: 'Zoom', suffix: '%', step: 0.5, min: 1),
                VecPropRow(c: c, ref: const PropRef('camera', CamProps.rotation2d), label: 'Rotation', suffix: '°', step: 0.25),
                VecPropRow(c: c, ref: const PropRef('camera', CamProps.shake), label: 'Shake', step: 0.25, min: 0),
                VecPropRow(c: c, ref: const PropRef('camera', CamProps.shakeSpeed), label: 'Shake speed', step: 0.05, min: 0, decimals: 2),
              ]),
            // <<< win-43
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

  // win-43 >>> 3D camera groups
  List<Widget> _threeD(double w) {
    final rig = c.comp.camera;
    final oneNode = rig.type == 'one_node';
    final zoom = rig.prop(CamProps.zoom).valueAt(c.time)[0];
    final lens = lensForZoom(w, zoom);
    final fov = fovForZoom(w, zoom);
    const cam = 'camera';
    return [
      PropGroup(
        title: 'Camera',
        trailing: SegmentedButton<String>(
          style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'two_node', label: Text('Two-node', style: TextStyle(fontSize: 11))),
            ButtonSegment(value: 'one_node', label: Text('One-node', style: TextStyle(fontSize: 11))),
          ],
          selected: {rig.type},
          onSelectionChanged: (v) => c.tryRun({'op': 'set_camera', 'type': v.first}),
        ),
        children: [
          VecPropRow(c: c, ref: const PropRef(cam, CamProps.position), label: 'Position', names: const ['X', 'Y', 'Z']),
          if (!oneNode) VecPropRow(c: c, ref: const PropRef(cam, CamProps.poi), label: 'Point of Interest', names: const ['X', 'Y', 'Z']),
          VecPropRow(c: c, ref: const PropRef(cam, CamProps.orientation), label: 'Orientation', names: const ['X', 'Y', 'Z'], suffix: '°', step: 0.25),
          VecPropRow(c: c, ref: const PropRef(cam, CamProps.rotation), label: 'X Rotation', components: const [0], suffix: '°', step: 0.25),
          VecPropRow(c: c, ref: const PropRef(cam, CamProps.rotation), label: 'Y Rotation', components: const [1], suffix: '°', step: 0.25),
          VecPropRow(c: c, ref: const PropRef(cam, CamProps.rotation), label: 'Z Rotation', components: const [2], suffix: '°', step: 0.25),
          if (c.selectedLayer != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(spacing: 6, children: [
                if (!oneNode) _chip(Icons.center_focus_strong_outlined, 'Look at selected', _lookAtSelected),
                _chip(Icons.filter_center_focus, 'Focus on selected', _focusOnSelected),
              ]),
            ),
        ],
      ),
      PropGroup(title: 'Lens', children: [
        VecPropRow(c: c, ref: const PropRef(cam, CamProps.zoom), label: 'Zoom', step: 2, min: 1, decimals: 0),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
          child: Row(children: [
            const SizedBox(width: 21),
            const Expanded(child: Text('Focal length', style: TextStyle(fontSize: 12.5, color: Color(0xFFD5D8DE)))),
            ScrubNumber(
              value: lens,
              suffix: ' mm',
              decimals: 1,
              step: 0.2,
              min: 5,
              max: 1000,
              width: 76,
              onStart: c.beginGesture,
              onChanged: (v) => c.tryRun({'op': 'set_property', 'target': cam, 'prop': CamProps.zoom, 'value': [zoomForLens(w, v)]}, record: false),
              onEnd: c.endGesture,
              onSubmit: (v) => c.tryRun({'op': 'set_property', 'target': cam, 'prop': CamProps.zoom, 'value': [zoomForLens(w, v)]}),
            ),
            const SizedBox(width: 50),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
          child: Row(children: [
            const SizedBox(width: 21),
            const Expanded(child: Text('Angle of view', style: TextStyle(fontSize: 12.5, color: Color(0xFFD5D8DE)))),
            ScrubNumber(
              value: fov,
              suffix: '°',
              decimals: 1,
              step: 0.1,
              min: 1,
              max: 170,
              width: 76,
              onStart: c.beginGesture,
              onChanged: (v) => c.tryRun({'op': 'set_property', 'target': cam, 'prop': CamProps.zoom, 'value': [zoomForFov(w, v)]}, record: false),
              onEnd: c.endGesture,
              onSubmit: (v) => c.tryRun({'op': 'set_property', 'target': cam, 'prop': CamProps.zoom, 'value': [zoomForFov(w, v)]}),
            ),
            const SizedBox(width: 50),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 4),
          child: Wrap(spacing: 4, runSpacing: 4, children: [
            for (final mm in kLensPresetsMm)
              ChoiceChip(
                visualDensity: VisualDensity.compact,
                label: Text('${mm}mm', style: const TextStyle(fontSize: 11)),
                selected: (lens - mm).abs() < 0.5,
                onSelected: (_) => c.tryRun({'op': 'set_camera', 'lens_mm': mm}),
              ),
          ]),
        ),
      ]),
      PropGroup(title: 'Depth of Field', children: [
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 4),
          title: const Text('Lock focus to point of interest', style: TextStyle(fontSize: 12.5)),
          value: rig.focusLock,
          onChanged: (v) => c.tryRun({'op': 'set_camera', 'focus_lock': v}),
        ),
        VecPropRow(c: c, ref: const PropRef(cam, CamProps.focus), label: 'Focus Distance', step: 2, min: 1, decimals: 0),
        VecPropRow(c: c, ref: const PropRef(cam, CamProps.aperture), label: 'Aperture', step: 0.5, min: 0),
        VecPropRow(c: c, ref: const PropRef(cam, CamProps.blurLevel), label: 'Blur Level', suffix: '%', step: 1, min: 0, decimals: 0),
      ]),
      PropGroup(title: 'Viewer tools', initiallyOpen: false, children: const [
        Padding(
          padding: EdgeInsets.all(6),
          child: Text(
            'In the viewer: W move · E rotate · R scale · C camera tools (orbit / pan / dolly; press C again to cycle) · '
            'X toggles world / local axes. Drag the coloured arrows, rings and boxes; the mouse wheel dollies with a camera tool.',
            style: TextStyle(fontSize: 11.5, color: Colors.white60),
          ),
        ),
      ]),
    ];
  }

  Widget _chip(IconData icon, String label, VoidCallback onTap) =>
      ActionChip(visualDensity: VisualDensity.compact, avatar: Icon(icon, size: 15), label: Text(label, style: const TextStyle(fontSize: 11.5)), onPressed: onTap);

  List<double>? _selectedWorld() {
    final l = c.selectedLayer;
    if (l == null) return null;
    final m = Evaluator.worldMatrix(c.comp, l, c.time, {});
    final a = l.prop(Props.anchor).valueAt(c.time);
    final p = m.transform3(Vector3(a[0], a[1], a.length > 2 ? a[2] : 0));
    return [p.x, p.y, p.z];
  }

  void _lookAtSelected() {
    final p = _selectedWorld();
    if (p != null) c.tryRun({'op': 'set_property', 'target': 'camera', 'prop': CamProps.poi, 'value': p});
  }

  void _focusOnSelected() {
    final p = _selectedWorld();
    if (p == null) return;
    final cam = Evaluator.camera3D(c.comp, c.time);
    final d = cam.depthOf(Vector3(p[0], p[1], p[2]));
    if (d > 1) c.tryRun({'op': 'set_property', 'target': 'camera', 'prop': CamProps.focus, 'value': [d]});
  }
  // <<< win-43

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
