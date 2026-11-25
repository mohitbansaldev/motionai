import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../core/commands/edit_commands.dart';
import '../core/engine/precomp.dart'; // PRECOMP (Agent L)
import '../core/model/anim_prop.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../services/project_storage.dart';
import 'video_pool.dart';

/// Owns the open project, the playhead, selection, undo/redo and playback.
///
/// Structural changes call [notifyListeners]; the playhead lives in
/// [timeNotifier] so playback doesn't rebuild the whole editor.
class EditorController extends ChangeNotifier {
  final Project project;
  final ProjectStorage storage;
  final VideoPool videos = VideoPool();
  final ValueNotifier<double> timeNotifier = ValueNotifier(0);

  String? selectedLayerId;
  bool cameraSelected = false;
  bool loop = true;

  final List<String> _undo = [];
  final List<String> _redo = [];
  static const int _maxUndo = 100;
  String? _gestureSnapshot;
  Timer? _saveTimer;

  Ticker? _ticker;
  bool _playing = false;
  double _playStartTime = 0;

  /// Playback speed: 1 = normal; J/K/L shuttle uses -4..4.
  double rate = 1;

  EditorController(this.project, this.storage);

  /// The composition open in the editor: main, or a precomp opened from it.
  Composition get comp => project.editComp; // PRECOMP (Agent L)
  double get time => timeNotifier.value;
  bool get playing => _playing;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get undoDepth => _undo.length;

  Layer? get selectedLayer => selectedLayerId == null ? null : comp.layerById(selectedLayerId!);

  // PRECOMP (Agent L) >>>
  // --------------------------------------------------------- nested comps

  final List<double> _compReturnTimes = [];

  /// Breadcrumbs: main first, the open comp last.
  List<Composition> get compTrail {
    final ids = Precomp.pathTo(project, comp.id) ?? [project.main.id];
    return [for (final id in ids) project.compById(id)].whereType<Composition>().toList();
  }

  bool get inPrecomp => comp.id != project.main.id;

  /// Opens comp [id] ("main" or null = back to main) for editing.
  void openComp(String? id, {double? atTime}) {
    final target = id == null ? project.main : project.compById(id);
    if (target == null || target.id == comp.id) return;
    if (_playing) pause();
    final trail = Precomp.pathTo(project, target.id) ?? [project.main.id, target.id];
    final goingUp = compTrail.any((c) => c.id == target.id);
    double t;
    if (goingUp) {
      // Back up the breadcrumbs: restore the time we left that comp at.
      final levels = compTrail.length - trail.length;
      double? back;
      for (int i = 0; i < levels && _compReturnTimes.isNotEmpty; i++) {
        back = _compReturnTimes.removeLast();
      }
      t = back ?? 0;
    } else {
      _compReturnTimes.add(time);
      t = atTime ?? 0;
    }
    project.editCompId = target.id == project.main.id ? null : target.id;
    if (project.editCompId == null) _compReturnTimes.clear();
    selectedLayerId = null;
    cameraSelected = false;
    timeNotifier.value = t.clamp(0.0, comp.duration).toDouble();
    videos.sync(project, time, playing: false);
    notifyListeners();
  }

  /// Opens the comp shown by comp layer [layerId] at the matching inner time.
  void openCompLayer(String layerId) {
    final l = comp.layerById(layerId);
    if (l == null) return;
    final child = Precomp.childOf(project, l);
    if (child == null) return;
    openComp(child.id, atTime: Precomp.childTime(l, child, time) ?? 0);
  }

  /// One level up the breadcrumbs.
  void closeComp() {
    final trail = compTrail;
    if (trail.length >= 2) openComp(trail[trail.length - 2].id);
  }
  // <<< PRECOMP (Agent L)

  // ------------------------------------------------------------- selection

  void select(String? layerId) {
    selectedLayerId = layerId;
    cameraSelected = false;
    notifyListeners();
  }

  void selectCamera() {
    selectedLayerId = null;
    cameraSelected = true;
    notifyListeners();
  }

  // ------------------------------------------------------------- time

  void seek(double t, {bool snap = true}) {
    var v = t.clamp(0.0, comp.duration);
    if (snap) v = comp.snapToFrame(v);
    if (_playing) {
      _playStartTime = v;
      _ticker?.stop();
      _ticker?.start();
    }
    timeNotifier.value = v;
    videos.sync(project, v, playing: _playing, rate: rate);
  }

  void stepFrames(int n) => seek(time + n * comp.frameDuration);

  void attachTicker(TickerProvider vsync) {
    _ticker?.dispose();
    _ticker = vsync.createTicker(_onTick);
  }

  void _onTick(Duration elapsed) {
    var t = _playStartTime + elapsed.inMicroseconds / 1e6 * rate;
    if (rate < 0 && t <= 0) {
      timeNotifier.value = 0;
      pause();
      return;
    }
    if (t >= comp.duration) {
      if (loop) {
        _playStartTime = 0;
        _ticker!.stop();
        _ticker!.start();
        t = 0;
        videos.pauseAll();
      } else {
        t = comp.duration;
        pause();
      }
    }
    timeNotifier.value = t;
    videos.sync(project, t, playing: _playing, rate: rate);
  }

  /// J/K/L shuttle: [direction] 1 = forward (L), -1 = backward (J). Pressing
  /// again in the same direction doubles the speed (up to 4x); K = [pause].
  void shuttle(int direction) {
    final same = _playing && rate.sign == direction.sign;
    final double next = same ? math.min(4.0, rate.abs() * 2) * direction : direction.toDouble();
    if (_playing) {
      _playStartTime = time;
      _ticker?.stop();
      rate = next;
      _ticker?.start();
      videos.sync(project, time, playing: true, rate: rate);
      notifyListeners();
    } else {
      rate = next;
      play();
    }
  }

  void play() {
    if (_playing || _ticker == null) return;
    if (rate > 0 && time >= comp.duration - comp.frameDuration) timeNotifier.value = 0;
    _playing = true;
    _playStartTime = time;
    _ticker!.start();
    videos.sync(project, time, playing: true, rate: rate);
    notifyListeners();
  }

  void pause() {
    if (!_playing) return;
    _playing = false;
    rate = 1;
    _ticker?.stop();
    videos.pauseAll();
    seek(time);
    notifyListeners();
  }

  void togglePlay() {
    if (_playing) {
      pause();
    } else {
      rate = 1;
      play();
    }
  }

  void setLoop(bool v) {
    loop = v;
    notifyListeners();
  }

  // ------------------------------------------------------------- editing

  /// Runs an edit command. With [record] false the change is not added to
  /// undo history (used during slider drags between begin/endGesture).
  CommandResult run(Map<String, dynamic> cmd, {bool record = true}) {
    final before = record && _gestureSnapshot == null ? ProjectSnapshot.take(project) : null;
    final result = EditCommands.runAtomic(project, cmd, now: time);
    if (before != null) _pushUndo(before);
    _afterEdit();
    return result;
  }

  /// Like [run] but returns an error message instead of throwing.
  String? tryRun(Map<String, dynamic> cmd, {bool record = true}) {
    try {
      run(cmd, record: record);
      return null;
    } on CommandError catch (e) {
      return e.message;
    }
  }

  void beginGesture() {
    _gestureSnapshot ??= ProjectSnapshot.take(project);
  }

  void endGesture() {
    final s = _gestureSnapshot;
    _gestureSnapshot = null;
    if (s != null && s != ProjectSnapshot.take(project)) _pushUndo(s);
    _afterEdit();
  }

  void _pushUndo(String snapshot) {
    _undo.add(snapshot);
    if (_undo.length > _maxUndo) _undo.removeAt(0);
    _redo.clear();
  }

  void undo() {
    if (_undo.isEmpty) return;
    _redo.add(ProjectSnapshot.take(project));
    ProjectSnapshot.restore(project, _undo.removeLast());
    _afterEdit();
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(ProjectSnapshot.take(project));
    ProjectSnapshot.restore(project, _redo.removeLast());
    _afterEdit();
  }

  void _afterEdit() {
    Precomp.touch(); // PRECOMP (Agent L): drop cached precomp renders
    if (project.editCompId != null && project.comps[project.editCompId] == null) project.editCompId = null; // PRECOMP (Agent L)
    if (selectedLayerId != null && comp.layerById(selectedLayerId!) == null) selectedLayerId = null;
    if (time > comp.duration) timeNotifier.value = comp.duration;
    videos.sync(project, time, playing: _playing);
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), save);
  }

  /// Call after mutating [project.media] directly (imports).
  void mediaChanged() => _afterEdit();

  Future<void> save() => storage.save(project);

  // ------------------------------------------------------------- helpers

  AnimProp? propOf(String target, String key) =>
      target == 'camera' ? comp.camera.props[key] : comp.layerById(target)?.props[key];

  /// Toggles a keyframe at the playhead (the stopwatch/diamond button).
  void toggleKeyframe(String target, String key) {
    final p = propOf(target, key);
    if (p == null) return;
    if (p.keyframeAt(time) != null) {
      tryRun({'op': 'remove_keyframe', 'target': target, 'prop': key, 'time': time});
    } else {
      tryRun({'op': 'set_keyframe', 'target': target, 'prop': key, 'time': time, 'value': p.valueAt(time)});
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    storage.save(project);
    _ticker?.dispose();
    videos.dispose();
    timeNotifier.dispose();
    super.dispose();
  }
}
