// V2-E (Depth from photo): monocular depth with Depth Anything V2 Small
// (ONNX, run through ONNX Runtime like the cut-out model) and the file
// pipelines behind photo_to_3d / depth_map. Pre/post-processing and the
// layer splitting are pure Dart (lib/core/depth); without the model (Android,
// no download, any failure) the heuristic "fake depth" is used so the
// feature always works.
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/depth/depth_map.dart';
import '../../core/depth/layer_split.dart';
import 'image_io.dart';
import 'inpaint.dart';
import 'model_store.dart';
import 'ort_ffi.dart';

class Depth {
  /// Depth Anything V2 Small, dynamically quantized (uint8 weights, float32
  /// input/output) from Xenova/onnx-community (Apache-2.0), ≈27.3 MB.
  /// Input `pixel_values` 1×3×H×W (H, W multiples of 14), output
  /// `predicted_depth` 1×H×W relative inverse depth.
  ///
  /// TODO(V2-E): the build container could not reach huggingface.co, so the
  /// exact size and SHA-256 are not pinned yet: [hash] is empty, which makes
  /// ModelStore check the size (±15 %) and record the SHA-256 it got next to
  /// the model (depth_anything_v2_small_q8.onnx.sha256). Pin it here after
  /// the first verified download.
  static const model = ModelSpec(
    fileName: 'depth_anything_v2_small_q8.onnx',
    urls: [
      'https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/f7421df0cc30f121782ab050d42f0a423291dcde/onnx/model_quantized.onnx',
      'https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/main/onnx/model_quantized.onnx',
    ],
    bytes: 27300000,
    hashKind: HashKind.sha256,
    hash: '',
    label: 'depth model',
  );

  /// Photos are processed at most this large (the layers are scaled back up
  /// to the photo's size when placed).
  static const maxSide = 2048;

  static (Float32List, List<int>) _predict(OrtSession s, Float32List input, int tw, int th) => s.run(input, [1, 3, th, tw]);

  /// Depth of [src] with the ONNX model (call inside an isolate).
  static DepthMap estimate(String ortLibrary, String modelPath, Rgba src, int threads) {
    final session = OrtSession.open(ortLibrary, modelPath, threads: threads);
    try {
      var (tw, th) = DepthPrep.inputSize(src.width, src.height);
      Float32List out;
      List<int> dims;
      try {
        (out, dims) = _predict(session, DepthPrep.inputTensor(src.data, src.width, src.height, tw, th), tw, th);
      } on OrtException {
        // A model exported with a fixed input size: the square training size.
        tw = th = DepthPrep.target;
        (out, dims) = _predict(session, DepthPrep.inputTensor(src.data, src.width, src.height, tw, th), tw, th);
      }
      final ow = dims.length >= 2 && dims.last > 0 ? dims.last : tw;
      final oh = dims.length >= 2 && dims[dims.length - 2] > 0 ? dims[dims.length - 2] : th;
      return DepthPrep.fromPrediction(out, ow, oh, src.data, src.width, src.height);
    } finally {
      session.dispose();
    }
  }

  /// Model depth when [modelPath] is given and works, else fake depth.
  /// Returns (map, "depth" | "fake", note).
  static (DepthMap, String, String?) depthOf(Rgba src, {String? ortLibrary, String? modelPath, int threads = 2, bool requireModel = false}) {
    if (ortLibrary != null && modelPath != null) {
      try {
        return (estimate(ortLibrary, modelPath, src, threads), 'depth', null);
      } catch (e) {
        if (requireModel) rethrow;
        return (DepthPrep.fake(src.data, src.width, src.height), 'fake', 'depth model failed ($e); used the built-in estimate');
      }
    }
    if (requireModel) throw StateError('The depth model is not available on this device');
    return (DepthPrep.fake(src.data, src.width, src.height), 'fake', null);
  }

  static Uint8List _inpaint(Uint8List rgba, int w, int h, Uint8List hole) => Inpaint.fill(Rgba(w, h, rgba), hole).data;

  /// photo_to_3d files (call inside an isolate): PNG layers
  /// `<outPrefix>_<i>.png`, far first. [mediaWidth] is the photo's width
  /// in the project (layer offsets are returned in those pixels).
  /// Returns {model, note?, width, height, layers: [{path, w, h, x, y, k, depth}]}.
  static Map<String, dynamic> photoTo3dFile({
    required String path,
    required String outPrefix,
    required double mediaWidth,
    int layers = DepthSplit.defaultLayers,
    double pad = 0,
    String? ortLibrary,
    String? modelPath,
    int threads = 2,
    bool requireModel = false,
  }) {
    final src = ImageIo.toRgba(ImageIo.limit(ImageIo.readUpright(path), maxSide));
    final (depth, used, note) = depthOf(src, ortLibrary: ortLibrary, modelPath: modelPath, threads: threads, requireModel: requireModel);
    final p = (pad * math.max(src.width, src.height)).round();
    final parts = DepthSplit.split(src.data, src.width, src.height, depth, layers: layers, pad: p, inpaint: _inpaint);
    final k = mediaWidth > 0 ? mediaWidth / src.width : 1.0;
    final out = <Map<String, dynamic>>[];
    for (final l in parts) {
      final file = '${outPrefix}_${l.index}.png';
      ImageIo.writePng(file, Rgba(l.width, l.height, l.rgba));
      out.add({'path': file, 'w': l.width, 'h': l.height, 'x': l.x * k, 'y': l.y * k, 'k': k, 'depth': l.depth});
    }
    return {'model': used, 'note': note, 'width': src.width, 'height': src.height, 'layers': out};
  }

  /// depth_map file (call inside an isolate): grayscale PNG (near = white).
  /// Returns {model, note?, path, w, h}.
  static Map<String, dynamic> depthMapFile({
    required String path,
    required String outPath,
    String? ortLibrary,
    String? modelPath,
    int threads = 2,
    bool requireModel = false,
  }) {
    final src = ImageIo.toRgba(ImageIo.limit(ImageIo.readUpright(path), maxSide));
    final (depth, used, note) = depthOf(src, ortLibrary: ortLibrary, modelPath: modelPath, threads: threads, requireModel: requireModel);
    ImageIo.writePng(outPath, Rgba(depth.width, depth.height, depth.toRgba()));
    return {'model': used, 'note': note, 'path': outPath, 'w': depth.width, 'h': depth.height};
  }
}
