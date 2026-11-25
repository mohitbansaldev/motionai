import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Minimal ONNX Runtime C API binding (dart:ffi) for one float input → one
/// float output models. The DLL (onnxruntime.dll, ORT 1.20+) is bundled next
/// to the Windows exe by CI. Indices are positions in `struct OrtApi`
/// (append-only across versions); verified against ORT 1.20 headers.
class OrtIndex {
  static const getErrorMessage = 2;
  static const createEnv = 3;
  static const createSession = 7;
  static const run = 9;
  static const createSessionOptions = 10;
  static const setSessionGraphOptimizationLevel = 23;
  static const setIntraOpNumThreads = 24;
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

const int _ortApiVersion = 20;

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
typedef _ObjIntN = _St Function(Pointer<Void>, Int32);
typedef _ObjIntD = _St Function(Pointer<Void>, int);
typedef _CreateSessionN = _St Function(Pointer<Void>, Pointer<Utf16>, Pointer<Void>, _PP);
typedef _GetNameN = _St Function(Pointer<Void>, IntPtr, Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _GetNameD = _St Function(Pointer<Void>, int, Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _AllocFreeN = _St Function(Pointer<Void>, Pointer<Void>);
typedef _CpuMemN = _St Function(Int32, Int32, _PP);
typedef _CpuMemD = _St Function(int, int, _PP);
typedef _CreateTensorN = _St Function(Pointer<Void>, Pointer<Void>, IntPtr, Pointer<Int64>, IntPtr, Int32, _PP);
typedef _CreateTensorD = _St Function(Pointer<Void>, Pointer<Void>, int, Pointer<Int64>, int, int, _PP);
typedef _RunN = _St Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Utf8>>, _PP, IntPtr, Pointer<Pointer<Utf8>>, IntPtr, _PP);
typedef _RunD = _St Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Utf8>>, _PP, int, Pointer<Pointer<Utf8>>, int, _PP);
typedef _ObjOutN = _St Function(Pointer<Void>, _PP);
typedef _DimCountN = _St Function(Pointer<Void>, Pointer<IntPtr>);
typedef _DimsN = _St Function(Pointer<Void>, Pointer<Int64>, IntPtr);
typedef _DimsD = _St Function(Pointer<Void>, Pointer<Int64>, int);

/// One loaded model. Not thread-safe; use it from a single isolate.
class OrtModel {
  final Pointer<Pointer<Void>> _api;
  late final _GetErrN _getErr;
  late final _ReleaseD _releaseStatus, _releaseEnv, _releaseSession, _releaseOptions, _releaseMem, _releaseValue, _releaseShape;
  Pointer<Void> _env = nullptr, _session = nullptr, _mem = nullptr;
  late final String inputName, outputName;

  OrtModel._(this._api);

  void _check(_St status) {
    if (status == nullptr) return;
    final f = _api[OrtIndex.getErrorMessage].cast<NativeFunction<_GetErrN>>().asFunction<Pointer<Utf8> Function(Pointer<Void>)>();
    final msg = f(status).toDartString();
    _releaseStatus(status);
    throw OrtException(msg);
  }

  /// Loads [dllPath] and the ONNX model at [modelPath].
  static OrtModel load(String dllPath, String modelPath, {int threads = 4}) {
    final lib = DynamicLibrary.open(dllPath);
    final base = lib.lookupFunction<Pointer<_OrtApiBase> Function(), Pointer<_OrtApiBase> Function()>('OrtGetApiBase')();
    final getApi = base.ref.getApi.asFunction<Pointer<Pointer<Void>> Function(int)>();
    final api = getApi(_ortApiVersion);
    if (api == nullptr) throw OrtException('ONNX Runtime is too old (needs API $_ortApiVersion)');
    final m = OrtModel._(api);
    m._init(modelPath, threads);
    return m;
  }

  void _init(String modelPath, int threads) {
    _releaseStatus = _api[OrtIndex.releaseStatus].cast<NativeFunction<_ReleaseN>>().asFunction<_ReleaseD>();
    _releaseEnv = _api[OrtIndex.releaseEnv].cast<NativeFunction<_ReleaseN>>().asFunction<_ReleaseD>();
    _releaseSession = _api[OrtIndex.releaseSession].cast<NativeFunction<_ReleaseN>>().asFunction<_ReleaseD>();
    _releaseOptions = _api[OrtIndex.releaseSessionOptions].cast<NativeFunction<_ReleaseN>>().asFunction<_ReleaseD>();
    _releaseMem = _api[OrtIndex.releaseMemoryInfo].cast<NativeFunction<_ReleaseN>>().asFunction<_ReleaseD>();
    _releaseValue = _api[OrtIndex.releaseValue].cast<NativeFunction<_ReleaseN>>().asFunction<_ReleaseD>();
    _releaseShape = _api[OrtIndex.releaseTensorTypeAndShapeInfo].cast<NativeFunction<_ReleaseN>>().asFunction<_ReleaseD>();

    using((arena) {
      final out = arena<Pointer<Void>>();
      final createEnv = _api[OrtIndex.createEnv].cast<NativeFunction<_CreateEnvN>>().asFunction<_CreateEnvD>();
      _check(createEnv(3 /* ORT_LOGGING_LEVEL_ERROR */, 'motionai'.toNativeUtf8(allocator: arena), out));
      _env = out.value;

      final createOpts = _api[OrtIndex.createSessionOptions].cast<NativeFunction<_OutOnlyN>>().asFunction<_St Function(_PP)>();
      _check(createOpts(out));
      final opts = out.value;
      try {
        _check(_api[OrtIndex.setIntraOpNumThreads].cast<NativeFunction<_ObjIntN>>().asFunction<_ObjIntD>()(opts, threads));
        _check(_api[OrtIndex.setSessionGraphOptimizationLevel].cast<NativeFunction<_ObjIntN>>().asFunction<_ObjIntD>()(opts, 99));
        final createSession = _api[OrtIndex.createSession].cast<NativeFunction<_CreateSessionN>>()
            .asFunction<_St Function(Pointer<Void>, Pointer<Utf16>, Pointer<Void>, _PP)>();
        // ORTCHAR_T is wchar_t (UTF-16) on Windows.
        _check(createSession(_env, modelPath.toNativeUtf16(allocator: arena), opts, out));
        _session = out.value;
      } finally {
        _releaseOptions(opts);
      }

      _check(_api[OrtIndex.createCpuMemoryInfo].cast<NativeFunction<_CpuMemN>>().asFunction<_CpuMemD>()(1 /* OrtArenaAllocator */, 0, out));
      _mem = out.value;

      _check(_api[OrtIndex.getAllocatorWithDefaultOptions].cast<NativeFunction<_OutOnlyN>>().asFunction<_St Function(_PP)>()(out));
      final allocator = out.value;
      final free = _api[OrtIndex.allocatorFree].cast<NativeFunction<_AllocFreeN>>().asFunction<_St Function(Pointer<Void>, Pointer<Void>)>();
      final name = arena<Pointer<Utf8>>();
      _check(_api[OrtIndex.sessionGetInputName].cast<NativeFunction<_GetNameN>>().asFunction<_GetNameD>()(_session, 0, allocator, name));
      inputName = name.value.toDartString();
      _check(free(allocator, name.value.cast()));
      _check(_api[OrtIndex.sessionGetOutputName].cast<NativeFunction<_GetNameN>>().asFunction<_GetNameD>()(_session, 0, allocator, name));
      outputName = name.value.toDartString();
      _check(free(allocator, name.value.cast()));
    });
  }

  /// Runs the model on a float tensor of [shape]; returns (output, dims).
  (Float32List, List<int>) run(Float32List input, List<int> shape) {
    return using((arena) {
      final data = arena<Float>(input.length);
      data.asTypedList(input.length).setAll(0, input);
      final dims = arena<Int64>(shape.length);
      for (var i = 0; i < shape.length; i++) {
        dims[i] = shape[i];
      }
      final out = arena<Pointer<Void>>();
      final createTensor = _api[OrtIndex.createTensorWithDataAsOrtValue].cast<NativeFunction<_CreateTensorN>>().asFunction<_CreateTensorD>();
      _check(createTensor(_mem, data.cast(), input.length * 4, dims, shape.length, 1 /* FLOAT */, out));
      final inValue = out.value;
      final inNames = arena<Pointer<Utf8>>()..value = inputName.toNativeUtf8(allocator: arena);
      final outNames = arena<Pointer<Utf8>>()..value = outputName.toNativeUtf8(allocator: arena);
      final inputs = arena<Pointer<Void>>()..value = inValue;
      final outputs = arena<Pointer<Void>>()..value = nullptr;
      try {
        final run = _api[OrtIndex.run].cast<NativeFunction<_RunN>>().asFunction<_RunD>();
        _check(run(_session, nullptr, inNames, inputs, 1, outNames, 1, outputs));
      } finally {
        _releaseValue(inValue);
      }
      final outValue = outputs.value;
      try {
        final objOut = _api[OrtIndex.getTensorTypeAndShape].cast<NativeFunction<_ObjOutN>>().asFunction<_St Function(Pointer<Void>, _PP)>();
        _check(objOut(outValue, out));
        final shapeInfo = out.value;
        final count = arena<IntPtr>();
        final List<int> outDims;
        try {
          _check(_api[OrtIndex.getDimensionsCount].cast<NativeFunction<_DimCountN>>()
              .asFunction<_St Function(Pointer<Void>, Pointer<IntPtr>)>()(shapeInfo, count));
          final d = arena<Int64>(count.value);
          _check(_api[OrtIndex.getDimensions].cast<NativeFunction<_DimsN>>().asFunction<_DimsD>()(shapeInfo, d, count.value));
          outDims = [for (var i = 0; i < count.value; i++) d[i]];
        } finally {
          _releaseShape(shapeInfo);
        }
        final getData = _api[OrtIndex.getTensorMutableData].cast<NativeFunction<_ObjOutN>>().asFunction<_St Function(Pointer<Void>, _PP)>();
        _check(getData(outValue, out));
        final n = outDims.fold<int>(1, (a, b) => a * (b <= 0 ? 1 : b));
        final result = Float32List.fromList(out.value.cast<Float>().asTypedList(n));
        return (result, outDims);
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

  static bool get available => Platform.isWindows;
}

class OrtException implements Exception {
  final String message;
  OrtException(this.message);
  @override
  String toString() => 'ONNX Runtime: $message';
}
