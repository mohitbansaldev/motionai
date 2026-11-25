import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _FindWindowExN = IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>);
typedef _FindWindowExD = int Function(int, int, Pointer<Utf16>, Pointer<Utf16>);
typedef _GetPidN = Uint32 Function(IntPtr, Pointer<Uint32>);
typedef _GetPidD = int Function(int, Pointer<Uint32>);
typedef _SetTextN = Int32 Function(IntPtr, Pointer<Utf16>);
typedef _SetTextD = int Function(int, Pointer<Utf16>);
typedef _CurPidN = Uint32 Function();
typedef _CurPidD = int Function();

/// The Windows app window (title). No-op on other platforms.
class WinWindow {
  static int _hwnd = 0;

  static int _find() {
    if (_hwnd != 0) return _hwnd;
    final user32 = DynamicLibrary.open('user32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final findEx = user32.lookupFunction<_FindWindowExN, _FindWindowExD>('FindWindowExW');
    final getPid = user32.lookupFunction<_GetPidN, _GetPidD>('GetWindowThreadProcessId');
    final me = kernel32.lookupFunction<_CurPidN, _CurPidD>('GetCurrentProcessId')();
    return using((arena) {
      final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16(allocator: arena);
      final pid = arena<Uint32>();
      var h = 0;
      for (var guard = 0; guard < 64; guard++) {
        h = findEx(0, h, cls, nullptr);
        if (h == 0) break;
        getPid(h, pid);
        if (pid.value == me) return _hwnd = h;
      }
      return 0;
    });
  }

  /// "MotionAI" or "<project> — MotionAI".
  static void setTitle(String? project) {
    if (!Platform.isWindows) return;
    try {
      final h = _find();
      if (h == 0) return;
      final setText = DynamicLibrary.open('user32.dll').lookupFunction<_SetTextN, _SetTextD>('SetWindowTextW');
      using((arena) => setText(h, (project == null || project.isEmpty ? 'MotionAI' : '$project — MotionAI').toNativeUtf16(allocator: arena)));
    } catch (_) {
      // Cosmetic only.
    }
  }
}
