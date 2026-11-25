import 'dart:io' show Platform;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Live preview resolution (Agent O, performance). Export is always full.
enum PreviewRes { auto, full, half, quarter }

/// Preview quality setting and frame-time monitor, shared by the editor.
///
/// Auto = full resolution, dropping to half while playing when frames take
/// longer than [slowFrameMs]. The resolution scales the cached layer images
/// and the decode size of photos in the preview.
class PreviewQuality extends ChangeNotifier {
  PreviewQuality._();
  static final PreviewQuality instance = PreviewQuality._();

  static const double slowFrameMs = 20;

  PreviewRes _mode = PreviewRes.auto;
  PreviewRes get mode => _mode;
  set mode(PreviewRes m) {
    if (m == _mode) return;
    _mode = m;
    notifyListeners();
  }

  bool _showFps = false;
  bool get showFps => _showFps;
  void toggleFps() {
    _showFps = !_showFps;
    _listen();
    notifyListeners();
  }

  bool _playing = false;
  bool _slow = false; // Auto dropped to half for this playback

  /// Resolution factor for the preview right now.
  double factor({required bool playing}) {
    if (playing != _playing) {
      _playing = playing;
      if (!playing) _slow = false;
      _listen();
    }
    return switch (_mode) {
      PreviewRes.full => 1.0,
      PreviewRes.half => 0.5,
      PreviewRes.quarter => 0.25,
      PreviewRes.auto => playing && _slow ? 0.5 : 1.0,
    };
  }

  /// What Auto currently uses (for the label).
  bool get autoReduced => _mode == PreviewRes.auto && _playing && _slow;

  // ---------------------------------------------------------- frame timing
  bool _listening = false;
  final List<double> _recent = []; // max(build, raster) ms of recent frames
  final List<int> _stamps = []; // vsync start (µs) of recent frames
  double fps = 0, buildMs = 0, rasterMs = 0;
  int _lastNotify = 0;

  void _listen() {
    final want = _showFps || (_mode == PreviewRes.auto && _playing);
    if (want == _listening) return;
    _listening = want;
    if (want) {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
    } else {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _recent.clear();
      _stamps.clear();
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    double b = 0, r = 0;
    for (final t in timings) {
      final bm = t.buildDuration.inMicroseconds / 1000, rm = t.rasterDuration.inMicroseconds / 1000;
      b += bm;
      r += rm;
      _recent.add(bm > rm ? bm : rm);
      _stamps.add(t.timestampInMicroseconds(FramePhase.vsyncStart));
    }
    while (_recent.length > 30) {
      _recent.removeAt(0);
    }
    while (_stamps.length > 60) {
      _stamps.removeAt(0);
    }
    if (timings.isNotEmpty) {
      buildMs = buildMs * 0.7 + b / timings.length * 0.3;
      rasterMs = rasterMs * 0.7 + r / timings.length * 0.3;
    }
    if (_stamps.length >= 2) {
      final span = (_stamps.last - _stamps.first) / 1e6;
      if (span > 0) fps = (_stamps.length - 1) / span;
    }
    var changed = false;
    if (_mode == PreviewRes.auto && _playing && !_slow && _recent.length >= 10) {
      final avg = _recent.reduce((a, c) => a + c) / _recent.length;
      if (avg > slowFrameMs) {
        _slow = true;
        changed = true;
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (changed || (_showFps && now - _lastNotify > 250)) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  static String label(PreviewRes r) => switch (r) {
        PreviewRes.auto => 'Auto',
        PreviewRes.full => 'Full',
        PreviewRes.half => 'Half',
        PreviewRes.quarter => 'Quarter',
      };
}

/// Small preview overlay: quality picker and (Ctrl+Shift+F) FPS meter.
class PreviewHud extends StatelessWidget {
  const PreviewHud({super.key});

  static bool get _desktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  Widget build(BuildContext context) {
    final q = PreviewQuality.instance;
    return ListenableBuilder(
      listenable: q,
      builder: (context, _) {
        const style = TextStyle(color: Colors.white, fontSize: 11, fontFeatures: [FontFeature.tabularFigures()]);
        final res = '${PreviewQuality.label(q.mode)}${q.autoReduced ? ' · half' : ''}';
        return Material(type: MaterialType.transparency, child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (q.showFps)
            Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: const Color(0xAA000000), borderRadius: BorderRadius.circular(8)),
              child: Text(
                '${q.fps.toStringAsFixed(0)} fps · build ${q.buildMs.toStringAsFixed(1)} · raster ${q.rasterMs.toStringAsFixed(1)} ms',
                style: style.copyWith(color: q.fps > 0 && q.fps < 45 ? const Color(0xFFFFB74D) : Colors.white),
              ),
            ),
          PopupMenuButton<PreviewRes>(
            tooltip: 'Preview quality${_desktop ? ' (FPS meter: Ctrl+Shift+F)' : ''}',
            initialValue: q.mode,
            onSelected: (m) => q.mode = m,
            itemBuilder: (_) => [
              for (final m in PreviewRes.values)
                PopupMenuItem(
                  value: m,
                  child: Text(switch (m) {
                    PreviewRes.auto => 'Auto (half while playing if slow)',
                    PreviewRes.full => 'Full resolution',
                    PreviewRes.half => 'Half resolution',
                    PreviewRes.quarter => 'Quarter resolution',
                  }),
                ),
              if (!_desktop)
                PopupMenuItem(
                  onTap: q.toggleFps,
                  child: Text(q.showFps ? 'Hide FPS meter' : 'Show FPS meter'),
                ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: const Color(0x88000000), borderRadius: BorderRadius.circular(8)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.high_quality_outlined, size: 14, color: Colors.white70),
                const SizedBox(width: 4),
                Text(res, style: style.copyWith(color: Colors.white70)),
              ]),
            ),
          ),
        ]));
      },
    );
  }
}
