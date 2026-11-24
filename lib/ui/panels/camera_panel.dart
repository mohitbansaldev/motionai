import 'package:flutter/material.dart';

import '../../core/model/camera.dart';
import '../../core/presets/camera_presets.dart';
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
