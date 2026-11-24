import 'package:flutter/material.dart';

import '../core/model/layer.dart';

String formatTime(double t, double fps) {
  if (t < 0) t = 0;
  final totalFrames = (t * fps).round();
  final f = totalFrames % fps.round();
  final s = (totalFrames ~/ fps.round()) % 60;
  final m = totalFrames ~/ (fps.round() * 60);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(m)}:${two(s)}:${two(f)}';
}

IconData layerIcon(LayerType t) => switch (t) {
      LayerType.video => Icons.movie_outlined,
      LayerType.image => Icons.image_outlined,
      LayerType.text => Icons.text_fields,
      LayerType.solid => Icons.square_outlined,
      LayerType.nullObject => Icons.control_camera,
    };

Color layerColor(LayerType t) => switch (t) {
      LayerType.video => const Color(0xFF3F7DD8),
      LayerType.image => const Color(0xFF2E9E6F),
      LayerType.text => const Color(0xFFC9813A),
      LayerType.solid => const Color(0xFF8C5BD6),
      LayerType.nullObject => const Color(0xFF7A7F89),
    };

String colorHex(int argb) => '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

const List<int> kSwatches = [
  0xFFFFFFFF, 0xFF000000, 0xFFFF3B30, 0xFFFF9500, 0xFFFFCC00, 0xFF34C759,
  0xFF00C7BE, 0xFF0A84FF, 0xFF5E5CE6, 0xFFBF5AF2, 0xFFFF2D55, 0xFF8E8E93,
];

class SwatchRow extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onPick;
  const SwatchRow({super.key, required this.selected, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final c in kSwatches)
          GestureDetector(
            onTap: () => onPick(c),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: Color(c),
                shape: BoxShape.circle,
                border: Border.all(
                  color: (c & 0xFFFFFF) == (selected & 0xFFFFFF) ? Colors.amber : Colors.white24,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

void showSnack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
}

class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
        child: Text(text.toUpperCase(),
            style: const TextStyle(fontSize: 11, letterSpacing: 1.2, color: Colors.white54, fontWeight: FontWeight.w600)),
      );
}
