import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../core/model/layer.dart';
import '../core/model/project.dart';

/// One VideoPlayerController per video layer, kept in sync with the
/// editor clock. Split layers of the same file get their own controllers
/// because they show different source times.
class VideoPool extends ChangeNotifier {
  final Map<String, _Entry> _entries = {};

  VideoPlayerController? controllerFor(String layerId) {
    final e = _entries[layerId];
    return (e != null && e.ready) ? e.controller : null;
  }

  void _ensure(Layer layer, MediaAsset asset) {
    final existing = _entries[layer.id];
    if (existing != null && existing.path == asset.path) return;
    existing?.controller.dispose();
    final c = VideoPlayerController.file(File(asset.path), videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
    final e = _Entry(c, asset.path);
    _entries[layer.id] = e;
    c.initialize().then((_) {
      e.ready = true;
      notifyListeners();
    }).catchError((Object err) {
      debugPrint('Video init failed for ${layer.name}: $err');
    });
  }

  /// Call whenever the time changes or the project is edited. [rate] is the
  /// shuttle speed (J/K/L); reverse shuttle (rate < 0) scrubs paused players.
  void sync(Project project, double t, {required bool playing, double rate = 1}) {
    if (rate <= 0) playing = false;
    final comp = project.main;
    final alive = <String>{};
    for (final l in comp.layers) {
      if ((l.type != LayerType.video && l.type != LayerType.audio) || l.mediaId == null) continue;
      final asset = project.media[l.mediaId];
      if (asset == null) continue;
      alive.add(l.id);
      _ensure(l, asset);
      final e = _entries[l.id]!;
      if (!e.ready) continue;
      final active = l.isActiveAt(t);
      final target = l.sourceTimeAt(t).clamp(0.0, asset.duration);
      final vol = (l.prop(Props.volume).scalarAt(t) / 100).clamp(0.0, 1.0);
      if ((e.controller.value.volume - vol).abs() > 0.01) e.controller.setVolume(vol);
      if (playing && active) {
        final pos = e.controller.value.position.inMicroseconds / 1e6;
        final speed = l.speed * rate;
        if (!e.controller.value.isPlaying) {
          e.seekTo(target);
          e.controller.setPlaybackSpeed(speed);
          e.speed = speed;
          e.controller.play();
        } else if (e.speed != speed) {
          e.controller.setPlaybackSpeed(speed);
          e.speed = speed;
          e.seekTo(target);
        } else if ((pos - target).abs() > 0.25 * rate) {
          e.seekTo(target); // drift correction
        }
      } else {
        if (e.controller.value.isPlaying) e.controller.pause();
        if (active) e.scrubTo(target);
      }
    }
    final dead = _entries.keys.where((k) => !alive.contains(k)).toList();
    for (final k in dead) {
      _entries.remove(k)!.controller.dispose();
    }
  }

  void pauseAll() {
    for (final e in _entries.values) {
      if (e.ready && e.controller.value.isPlaying) e.controller.pause();
    }
  }

  @override
  void dispose() {
    for (final e in _entries.values) {
      e.controller.dispose();
    }
    _entries.clear();
    super.dispose();
  }
}

class _Entry {
  final VideoPlayerController controller;
  final String path;
  bool ready = false;
  double speed = 1;
  bool _seeking = false;
  double? _pending;
  double _last = -1;

  _Entry(this.controller, this.path);

  void seekTo(double seconds) {
    _last = seconds;
    controller.seekTo(Duration(microseconds: (seconds * 1e6).round()));
  }

  /// Throttled seeking while scrubbing: never more than one seek in flight.
  void scrubTo(double seconds) {
    if ((seconds - _last).abs() < 1 / 120) return;
    if (_seeking) {
      _pending = seconds;
      return;
    }
    _seeking = true;
    _last = seconds;
    controller.seekTo(Duration(microseconds: (seconds * 1e6).round())).whenComplete(() {
      _seeking = false;
      final p = _pending;
      _pending = null;
      if (p != null) scrubTo(p);
    });
  }
}
