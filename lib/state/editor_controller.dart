import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../core/commands/bulk_commands.dart'; // BULK (Agent N)
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

  /// Like [timeNotifier] but silent while playing (fires again on pause), so
  /// side panels don't rebuild 60× a second during playback. PERF
  late final Listenable panelTime = _PanelTime(this);

  // BULK (Agent N): `selectedLayerId` is the PRIMARY of [selectedLayerIds].
  String? _primary;
  final List<String> _sel = [];

  /// The primary selected layer (what single-layer panels show).
  String? get selectedLayerId => _primary;
  set selectedLayerId(String? id) => _setSelection(id == null ? const [] : [id], primary: id);
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
    _selByComp[comp.id] = List.of(_sel); // BULK (Agent N): selection is per comp
    _selPrimaryByComp[comp.id] = _primary;
    project.editCompId = target.id == project.main.id ? null : target.id;
    if (project.editCompId == null) _compReturnTimes.clear();
    _restoreCompSelection(); // BULK (Agent N) (was: selectedLayerId = null)
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

  // BULK (Agent N) >>> multi-selection
  final Map<String, List<String>> _selByComp = {};
  final Map<String, String?> _selPrimaryByComp = {};
  String? _rangeAnchor;

  /// Phone multi-select mode (long-press): taps toggle, rows show checkboxes.
  bool multiSelectMode = false;

  /// Selected layer ids in the order they were selected (an ordered set).
  /// The primary ([selectedLayerId]) is one of them.
  List<String> get selectedLayerIds => List.unmodifiable(_sel);
  int get selectionCount => _sel.length;
  bool get hasMultiSelection => _sel.length > 1;
  bool isSelected(String id) => _sel.contains(id);

  /// Selected layers in comp order (top first).
  List<Layer> get selectedLayers => [for (final l in comp.layers) if (_sel.contains(l.id)) l];

  void _setSelection(Iterable<String> ids, {String? primary}) {
    _sel.clear();
    for (final id in ids) {
      if (!_sel.contains(id)) _sel.add(id);
    }
    _primary = primary != null && _sel.contains(primary) ? primary : (_sel.isEmpty ? null : _sel.last);
    if (_sel.length <= 1) _rangeAnchor = _primary;
  }

  /// Replaces the selection ([add] = keep the current one too).
  void selectMany(Iterable<String> ids, {String? primary, bool add = false}) {
    final valid = [for (final id in ids) if (comp.layerById(id) != null) id];
    _setSelection([if (add) ..._sel, ...valid], primary: primary ?? (valid.isEmpty ? _primary : valid.last));
    if (_sel.isNotEmpty) cameraSelected = false;
    notifyListeners();
  }

  /// Ctrl/Cmd+click: adds or removes [id]; the clicked layer becomes primary.
  void toggleSelect(String id) {
    if (comp.layerById(id) == null) return;
    if (_sel.contains(id)) {
      _sel.remove(id);
      if (_primary == id) _primary = _sel.isEmpty ? null : _sel.last;
    } else {
      _sel.add(id);
      _primary = id;
    }
    _rangeAnchor = id;
    cameraSelected = false;
    notifyListeners();
  }

  /// Shift+click in the timeline: every layer between the last clicked
  /// layer (the anchor) and [id], in stacking order.
  void selectRange(String id, {bool add = false}) {
    final to = comp.indexOf(id);
    if (to < 0) return;
    final anchor = _rangeAnchor ?? _primary;
    final from = anchor == null ? -1 : comp.indexOf(anchor);
    if (from < 0) {
      select(id);
      _rangeAnchor = id;
      return;
    }
    final lo = math.min(from, to), hi = math.max(from, to);
    final range = [for (int i = lo; i <= hi; i++) comp.layers[i].id];
    final keep = anchor;
    _setSelection([if (add) ..._sel, ...range], primary: id);
    _rangeAnchor = keep;
    cameraSelected = false;
    notifyListeners();
  }

  /// Ctrl+A: every layer of the open comp.
  void selectAll() => selectMany([for (final l in comp.layers) l.id], primary: _primary);

  /// Esc: nothing selected (also leaves multi-select mode).
  void clearSelection() {
    _setSelection(const []);
    cameraSelected = false;
    multiSelectMode = false;
    notifyListeners();
  }

  void setMultiSelectMode(bool on) {
    multiSelectMode = on;
    notifyListeners();
  }

  /// Drops removed layers; a removed primary passes to the newest remaining.
  void _pruneSelection() {
    _sel.removeWhere((id) => comp.layerById(id) == null);
    if (_primary != null && !_sel.contains(_primary)) _primary = _sel.isEmpty ? null : _sel.last;
    if (_rangeAnchor != null && comp.layerById(_rangeAnchor!) == null) _rangeAnchor = _primary;
  }

  void _restoreCompSelection() {
    final ids = _selByComp[comp.id] ?? const <String>[];
    _setSelection([for (final id in ids) if (comp.layerById(id) != null) id], primary: _selPrimaryByComp[comp.id]);
  }

  /// Applies `select` / `paste_layers` / `group_layers` results.
  void _applyResultSelection(CommandResult r) {
    final ids = r.selection;
    if (ids == null) return;
    final valid = [for (final id in ids) if (comp.layerById(id) != null) id];
    switch (r.selectionMode) {
      case 'add':
        _setSelection([..._sel, ...valid], primary: valid.isEmpty ? _primary : valid.last);
      case 'remove':
        _setSelection([for (final id in _sel) if (!valid.contains(id)) id], primary: _primary);
      default:
        _setSelection(valid);
    }
    if (_sel.isNotEmpty) cameraSelected = false;
  }
  // <<< BULK (Agent N)

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
    BulkCommands.selection = List.of(_sel); // BULK (Agent N): layers: "selection"
    final result = EditCommands.runAtomic(project, cmd, now: time);
    if (before != null && (cmd['op'] != 'select' || ProjectSnapshot.take(project) != before)) _pushUndo(before); // BULK (Agent N): select alone is no undo step
    _applyResultSelection(result); // BULK (Agent N)
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
    _pruneSelection(); // BULK (Agent N): selection survives undo where ids still exist
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


class _PanelTime extends ChangeNotifier {
  final EditorController c;
  bool _wasPlaying = false;
  _PanelTime(this.c) {
    c.timeNotifier.addListener(_tick);
    c.addListener(_state);
  }
  void _tick() {
    if (!c.playing) notifyListeners();
  }

  void _state() {
    if (_wasPlaying && !c.playing) notifyListeners();
    _wasPlaying = c.playing;
  }
}
