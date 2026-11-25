import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'image_ops.dart';
import 'onnx_ffi.dart';
import 'win_tools.dart';

/// Photo subject cut-out on Windows: an on-device salient-object model
/// (rembg's "silueta", a compact U²-Net, 43 MB) run with ONNX Runtime via
/// dart:ffi. The model is downloaded once to the app data folder.
class WinCutout {
  static const modelName = 'silueta.onnx';
  static const modelUrl = 'https://github.com/danielgatis/rembg/releases/download/v0.0.0/silueta.onnx';
  static const inputSize = 320;

  static Future<String> ensureModel({void Function(double)? onProgress}) async {
    final dir = await WinTools.dataDir('models');
    final f = File('${dir.path}\\$modelName');
    await WinTools.download(modelUrl, f, onProgress: onProgress, minBytes: 1 << 20);
    return f.path;
  }

  static Future<(int, int)> cutout(String path, String fgPath, String bgPath) async {
    final dll = WinTools.onnxRuntimeDll;
    if (!File(dll).existsSync()) throw StateError('onnxruntime.dll is missing next to the app. Reinstall MotionAI.');
    final model = await ensureModel();
    final threads = math.max(1, Platform.numberOfProcessors ~/ 2);
    return Isolate.run(() => _work(dll, model, path, fgPath, bgPath, threads));
  }

  static (int, int) _work(String dll, String model, String path, String fgPath, String bgPath, int threads) {
    final src = ImageOps.loadUpright(path);
    final input = ImageOps.saliencyInput(src, inputSize);
    final m = OrtModel.load(dll, model, threads: threads);
    try {
      final (out, dims) = m.run(input, [1, 3, inputSize, inputSize]);
      final s = dims.isNotEmpty && dims.last > 0 ? dims.last : inputSize;
      final mask = ImageOps.maskFromSaliency(out.sublist(0, s * s), s, src.width, src.height);
      return ImageOps.writeCutout(src, mask, fgPath, bgPath);
    } finally {
      m.dispose();
    }
  }
}
