// V3-A: satellite map base.
//
// The bundled texture is NASA's Blue Marble (public domain), equirectangular
// (lon −180..180, lat 90..−90, the same projection as the map kit's
// 3600 × 1800 map px), graded dark with a teal ocean. It is decoded once at
// startup (main.dart) so exports and MCP renders have it from frame 1.
// Without it (missing / undecodable asset) the effect draws nothing and the
// map shows the dark vector style underneath.

import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';

class MapTexture {
  static const asset = 'assets/maps/blue_marble_dark.jpg';

  /// The decoded texture (null until loaded, or when it failed).
  static final ValueNotifier<ui.Image?> image = ValueNotifier<ui.Image?>(null);
  static Future<void>? _loading;

  /// Loads the texture once (safe to call many times).
  static Future<void> load() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      final data = await rootBundle.load(asset);
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      // Phones: half resolution (2048 × 1024) keeps GPU memory small.
      final mobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: mobile ? 2048 : null);
      final frame = await codec.getNextFrame();
      image.value = frame.image;
    } catch (_) {
      // Fallback: the dark vector map under the texture layer stays visible.
    }
  }
}

/// Draws the satellite texture over the layer box (a 3600 × 1800 map-px
/// solid in the map group), at [amount] % opacity.
class MapTextureFx extends StatelessWidget {
  final double amount;
  final bool draft;
  final Widget child;
  const MapTextureFx({super.key, required this.amount, required this.child, this.draft = false});

  @override
  Widget build(BuildContext context) {
    if (MapTexture.image.value == null) MapTexture.load();
    return ValueListenableBuilder<ui.Image?>(
      valueListenable: MapTexture.image,
      builder: (context, img, _) {
        final a = (amount / 100).clamp(0.0, 1.0);
        if (img == null || a <= 0) return child;
        Widget tex = RawImage(
          image: img,
          fit: BoxFit.fill,
          filterQuality: draft ? FilterQuality.low : FilterQuality.medium,
        );
        if (a < 0.999) tex = Opacity(opacity: a, child: tex);
        return Stack(children: [child, Positioned.fill(child: IgnorePointer(child: tex))]);
      },
    );
  }
}
