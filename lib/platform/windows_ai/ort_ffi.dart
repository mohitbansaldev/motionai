// ONNX Runtime C API through dart:ffi (Windows AI layer, Agent E).
//
// Binds just enough of `OrtApi` to run a model with one float input and read
// its first float output. The library is the official onnxruntime.dll that CI
// bundles next to motionai.exe (from the `onnxruntime` PyPI wheel / NuGet).
// Function indices are positions in `struct OrtApi`, which is append-only
// across releases; they were checked against ORT 1.22 by running u2netp
// through the same indices (CreateEnv … Run … GetTensorMutableData).
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

class OrtIndex {
  static const getErrorMessage = 2;
  static const createEnv = 3;
  static const createSession = 7;
  static const run = 9;
  static const createSessionOptions = 10;
  static const setSessionGraphOptimizationLevel = 23;
  static const setIntraOpNumThreads = 24;
  static const sessionGetInputCount = 30;
  static const sessionGetOutputCount = 31;
  static const sessionGetInputName = 36;
  static const sessionGetOutputName = 37;
  static const createTensorWithDataAsOrtValue = 49;
  static const getTensorMutableData = 51;
  static const getDimensionsCount = 61;
  static const getDimensions = 62;
  static const getTensorTypeAndShape = 65;
  static const createCpuMemoryInfo = 69;
  static const allocatorFree = 76;
  static const getAllocatorWithDefaultOptions = 78;
  static const releaseEnv = 92;
  static const releaseStatus = 93;
  static const releaseMemoryInfo = 94;
  static const releaseSession = 95;
  static const releaseValue = 96;
  static const releaseTensorTypeAndShapeInfo = 99;
  static const releaseSessionOptions = 100;
}

/// API version requested from OrtGetApiBase (ORT 1.16+ serves 16).
const int ortApiVersion = 16;

final class _OrtApiBase extends Struct {
  external Pointer<NativeFunction<Pointer<Pointer<Void>> Function(Uint32)>> getApi;
  external Pointer<NativeFunction<Pointer<Utf8> Function()>> getVersionString;
}

typedef _St = Pointer<Void>; // OrtStatus*, null = OK
typedef _PP = Pointer<Pointer<Void>>;

typedef _GetErrN = Pointer<Utf8> Function(Pointer<Void>);
typedef _ReleaseN = Void Function(Pointer<Void>);
typedef _ReleaseD = void Function(Pointer<Void>);
typedef _CreateEnvN = _St Function(Int32, Pointer<Utf8>, _PP);
typedef _CreateEnvD = _St Function(int, Pointer<Utf8>, _PP);
typedef _OutOnlyN = _St Function(_PP);
typedef _OutOnlyD = _St Function(_PP);
typedef _ObjIntN = _St Function(Pointer<Void>, Int32);
typedef _ObjIntD = _St Function(Pointer<Void>, int);
typedef _CreateSessionN = _St Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, _PP);
typedef _CreateSessionD = _St Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, _PP);
typedef _CountN = _St Function(Pointer<Void>, Pointer<IntPtr>);
typedef _CountD = _St Function(Pointer<Void>, Pointer<IntPtr>);
typedef _GetNameN = _St Function(Pointer<Void>, IntPtr, Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _GetNameD = _St Function(Pointer<Void>, int, Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _AllocFreeN = _St Function(Pointer<Void>, Pointer<Void>);
typedef _AllocFreeD = _St Function(Pointer<Void>, Pointer<Void>);
typedef _CpuMemN = _St Function(Int32, Int32, _PP);
typedef _CpuMemD = _St Function(int, int, _PP);
typedef _CreateTensorN = _St Function(Pointer<Void>, Pointer<Void>, IntPtr, Pointer<Int64>, IntPtr, Int32, _PP);
typedef _CreateTensorD = _St Function(Pointer<Void>, Pointer<Void>, int, Pointer<Int64>, int, int, _PP);
typedef _RunN = _St Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Utf8>>, _PP, IntPtr, Pointer<Pointer<Utf8>>, IntPtr, _PP);
typedef _RunD = _St Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Utf8>>, _PP, int, Pointer<Pointer<Utf8>>, int, _PP);
typedef _ObjOutN = _St Function(Pointer<Void>, _PP);
typedef _ObjOutD = _St Function(Pointer<Void>, _PP);
typedef _DimsN = _St Function(Pointer<Void>, Pointer<Int64>, IntPtr);
typedef _DimsD = _St Function(Pointer<Void>, Pointer<Int64>, int);

class OrtException implements Exception {
  final String message;
  OrtException(this.message);
  @override
  String toString() => 'ONNX Runtime: $message';
}

/// One loaded model session. Not thread-safe: create and use it in a single
/// isolate, then [dispose].
class OrtSession {
  final Pointer<Pointer<Void>> _api;
  final String version;
  late final _ReleaseD _releaseStatus, _releaseEnv, _releaseSession, _releaseOptions, _releaseMem, _releaseValue, _releaseShape;
  Pointer<Void> _env = nullptr, _session = nullptr, _mem = nullptr;
  late final String inputName, outputName;
  late final int inputCount, outputCount;

  OrtSession._(this._api, this.version);

  // dart:ffi needs the function types spelled out at each call site.
  Pointer<Void> _p(int index) => _api[index];

  void _check(_St status) {
    if (status == nullptr) return;
    final msg = _p(OrtIndex.getErrorMessage).cast<NativeFunction<_GetErrN>>().asFunction<_GetErrN>()(status).toDartString();
    _releaseStatus(status);
    throw OrtException(msg);
  }

  /// Opens the ONNX Runtime library at [libraryPath] and loads [modelPath].
  static OrtSession open(String libraryPath, String modelPath, {int threads = 4}) {
    final lib = DynamicLibrary.open(libraryPath);
    final base = lib.lookupFunction<Pointer<_OrtApiBase> Function(), Pointer<_OrtApiBase> Function()>('OrtGetApiBase')();
    final version = base.ref.getVersionString.asFunction<Pointer<Utf8> Function()>()().toDartString();
    final api = base.ref.getApi.asFunction<Pointer<Pointer<Void>> Function(int)>()(ortApiVersion);
    if (api == nullptr) throw OrtException('version $version is too old (needs API $ortApiVersion)');
    final s = OrtSession._(api, version);
    s._init(modelPath, threads);
    return s;
  }

  void _init(String modelPath, int threads) {
    _releaseStatus = _p(OrtIndex.releaseStatus).cast<NativeFunction<_ReleaseN>>().asFunction<_ReleaseD>();
    _releaseEnv = _p(OrtIndex.releaseEnv).cast<NativeFunction<_ReleaseN>>().asFunction<_ReleaseD>();
    _releaseSession = _p(OrtIndex.releaseSession).cast<NativeFunction<_ReleaseN>>().asFunction<_ReleaseD>();
    _releaseOptions = _p(OrtIndex.releaseSessionOptions).cast<NativeFunction<_ReleaseN>>().asFunction<_ReleaseD>();
    _releaseMem = _p(OrtIndex.releaseMemoryInfo).cast<NativeFunction<_ReleaseN>>().asFunction<_ReleaseD>();
    _releaseValue = _p(OrtIndex.releaseValue).cast<NativeFunction<_ReleaseN>>().asFunction<_ReleaseD>();
    _releaseShape = _p(OrtIndex.releaseTensorTypeAndShapeInfo).cast<NativeFunction<_ReleaseN>>().asFunction<_ReleaseD>();

    using((arena) {
      final out = arena<Pointer<Void>>();
      _check(_p(OrtIndex.createEnv).cast<NativeFunction<_CreateEnvN>>().asFunction<_CreateEnvD>()(3 /* ORT_LOGGING_LEVEL_ERROR */, 'motionai'.toNativeUtf8(allocator: arena), out));
      _env = out.value;

      _check(_p(OrtIndex.createSessionOptions).cast<NativeFunction<_OutOnlyN>>().asFunction<_OutOnlyD>()(out));
      final opts = out.value;
      try {
        _check(_p(OrtIndex.setIntraOpNumThreads).cast<NativeFunction<_ObjIntN>>().asFunction<_ObjIntD>()(opts, threads));
        _check(_p(OrtIndex.setSessionGraphOptimizationLevel).cast<NativeFunction<_ObjIntN>>().asFunction<_ObjIntD>()(opts, 99 /* ORT_ENABLE_ALL */));
        // ORTCHAR_T is wchar_t (UTF-16) on Windows and char (UTF-8) elsewhere.
        final Pointer<Void> path =
            Platform.isWindows ? modelPath.toNativeUtf16(allocator: arena).cast() : modelPath.toNativeUtf8(allocator: arena).cast();
        _check(_p(OrtIndex.createSession).cast<NativeFunction<_CreateSessionN>>().asFunction<_CreateSessionD>()(_env, path, opts, out));
        _session = out.value;
      } finally {
        _releaseOptions(opts);
      }

      _check(_p(OrtIndex.createCpuMemoryInfo).cast<NativeFunction<_CpuMemN>>().asFunction<_CpuMemD>()(1 /* OrtArenaAllocator */, 0 /* OrtMemTypeDefault */, out));
      _mem = out.value;

      final count = arena<IntPtr>();
      _check(_p(OrtIndex.sessionGetInputCount).cast<NativeFunction<_CountN>>().asFunction<_CountD>()(_session, count));
      inputCount = count.value;
      _check(_p(OrtIndex.sessionGetOutputCount).cast<NativeFunction<_CountN>>().asFunction<_CountD>()(_session, count));
      outputCount = count.value;
      if (inputCount < 1 || outputCount < 1) throw OrtException('model has no inputs or outputs');

      _check(_p(OrtIndex.getAllocatorWithDefaultOptions).cast<NativeFunction<_OutOnlyN>>().asFunction<_OutOnlyD>()(out));
      final allocator = out.value;
      final free = _p(OrtIndex.allocatorFree).cast<NativeFunction<_AllocFreeN>>().asFunction<_AllocFreeD>();
      final name = arena<Pointer<Utf8>>();
      _check(_p(OrtIndex.sessionGetInputName).cast<NativeFunction<_GetNameN>>().asFunction<_GetNameD>()(_session, 0, allocator, name));
      inputName = name.value.toDartString();
      _check(free(allocator, name.value.cast()));
      _check(_p(OrtIndex.sessionGetOutputName).cast<NativeFunction<_GetNameN>>().asFunction<_GetNameD>()(_session, 0, allocator, name));
      outputName = name.value.toDartString();
      _check(free(allocator, name.value.cast()));
    });
  }

  /// Runs the model on a float32 tensor of [shape]; returns the first
  /// output's values and dimensions.
  (Float32List, List<int>) run(Float32List input, List<int> shape) {
    final expected = shape.fold<int>(1, (a, b) => a * b);
    if (expected != input.length) throw ArgumentError('tensor has ${input.length} values, shape $shape needs $expected');
    return using((arena) {
      final data = arena<Float>(input.length);
      data.asTypedList(input.length).setAll(0, input);
      final dims = arena<Int64>(shape.length);
      for (var i = 0; i < shape.length; i++) {
        dims[i] = shape[i];
      }
      final out = arena<Pointer<Void>>();
      _check(_p(OrtIndex.createTensorWithDataAsOrtValue).cast<NativeFunction<_CreateTensorN>>().asFunction<_CreateTensorD>()(
          _mem, data.cast(), input.length * 4, dims, shape.length, 1 /* ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT */, out));
      final inValue = out.value;
      final inNames = arena<Pointer<Utf8>>()..value = inputName.toNativeUtf8(allocator: arena);
      final outNames = arena<Pointer<Utf8>>()..value = outputName.toNativeUtf8(allocator: arena);
      final inputs = arena<Pointer<Void>>()..value = inValue;
      final outputs = arena<Pointer<Void>>()..value = nullptr;
      try {
        _check(_p(OrtIndex.run).cast<NativeFunction<_RunN>>().asFunction<_RunD>()(_session, nullptr, inNames, inputs, 1, outNames, 1, outputs));
      } finally {
        _releaseValue(inValue);
      }
      final outValue = outputs.value;
      try {
        _check(_p(OrtIndex.getTensorTypeAndShape).cast<NativeFunction<_ObjOutN>>().asFunction<_ObjOutD>()(outValue, out));
        final shapeInfo = out.value;
        final List<int> outDims;
        try {
          final count = arena<IntPtr>();
          _check(_p(OrtIndex.getDimensionsCount).cast<NativeFunction<_CountN>>().asFunction<_CountD>()(shapeInfo, count));
          final d = arena<Int64>(count.value == 0 ? 1 : count.value);
          _check(_p(OrtIndex.getDimensions).cast<NativeFunction<_DimsN>>().asFunction<_DimsD>()(shapeInfo, d, count.value));
          outDims = [for (var i = 0; i < count.value; i++) d[i]];
        } finally {
          _releaseShape(shapeInfo);
        }
        _check(_p(OrtIndex.getTensorMutableData).cast<NativeFunction<_ObjOutN>>().asFunction<_ObjOutD>()(outValue, out));
        final n = outDims.fold<int>(1, (a, b) => a * (b <= 0 ? 1 : b));
        return (Float32List.fromList(out.value.cast<Float>().asTypedList(n)), outDims);
      } finally {
        _releaseValue(outValue);
      }
    });
  }

  void dispose() {
    if (_mem != nullptr) _releaseMem(_mem);
    if (_session != nullptr) _releaseSession(_session);
    if (_env != nullptr) _releaseEnv(_env);
    _mem = _session = _env = nullptr;
  }
}
