import 'dart:io';

/// win-30: per-app GPU preference on Windows (Settings → Display → Graphics).
/// Stored by Windows under HKCU\Software\Microsoft\DirectX\UserGpuPreferences
/// as "<exe path>" = "GpuPreference=N;" (0 = let Windows decide,
/// 1 = power saving / iGPU, 2 = high performance / dGPU). Takes effect on
/// the next start of the app.
class WinGpu {
  static const _key = r'HKCU\Software\Microsoft\DirectX\UserGpuPreferences';

  static String get _exe => Platform.resolvedExecutable;

  /// 0, 1, 2, or null when unset / not Windows.
  static Future<int?> preference() async {
    if (!Platform.isWindows) return null;
    try {
      final r = await Process.run('reg', ['query', _key, '/v', _exe]);
      if (r.exitCode != 0) return null;
      final m = RegExp(r'GpuPreference=(\d)').firstMatch('${r.stdout}');
      return m == null ? null : int.parse(m.group(1)!);
    } catch (_) {
      return null;
    }
  }

  /// Sets the preference (2 = high performance). True when saved.
  static Future<bool> setPreference(int value) async {
    if (!Platform.isWindows) return false;
    try {
      final r = await Process.run('reg', ['add', _key, '/v', _exe, '/t', 'REG_SZ', '/d', 'GpuPreference=$value;', '/f']);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static String label(int? v) => switch (v) {
        2 => 'High performance GPU',
        1 => 'Power-saving GPU',
        _ => 'GPU chosen by Windows',
      };
}
