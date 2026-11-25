// win-30: keeps MotionAI light — caps Flutter's decoded-image cache and, when
// the process grows past a limit, drops caches that rebuild on demand.
import 'dart:async';
import 'dart:io' show Platform, ProcessInfo;

import 'package:flutter/painting.dart';

import 'app_log.dart';

class MemoryGuard {
  MemoryGuard._();

  /// Decoded images Flutter may keep (bytes). Photos are decoded at about
  /// the size they are shown, so this holds a busy scene.
  static const imageCacheBytes = 256 << 20;

  /// Above this resident size (MB) caches are trimmed.
  static int trimAtMb = 2048;

  static Timer? _timer;
  static int trims = 0;

  static void install() {
    final cache = PaintingBinding.instance.imageCache;
    cache.maximumSizeBytes = imageCacheBytes;
    cache.maximumSize = 600;
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
    _timer ??= Timer.periodic(const Duration(seconds: 6), (_) => check());
  }

  /// Trims when over the limit; returns true when it did.
  static bool check() {
    final mb = ProcessInfo.currentRss ~/ (1 << 20);
    if (mb < trimAtMb) return false;
    trim('RAM $mb MB > $trimAtMb MB');
    return true;
  }

  static void trim(String why) {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    trims++;
    AppLog.warning('memory', 'Trimmed image caches ($why)');
  }
}
