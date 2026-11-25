// V2-E (Depth from photo): `photo_to_3d` and `depth_map`.
//
// Both need the photo's pixels and (on Windows) a depth model, so they run
// as a background job started through [DepthCommands.launcher] (installed
// by the app: lib/ui/depth_tools.dart). The command itself only validates
// and starts the job; when the job is done the app runs the same command
// again with "prepared" (the generated layer media), which places the
// layers — one undo step.
import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart' show Vector2;

import '../depth/depth_place.dart';
import '../depth/layer_split.dart';
import '../engine/evaluator.dart';
import '../model/camera.dart';
import '../model/layer.dart';
import '../model/project.dart';
import '../presets/scene3d.dart';
import 'edit_commands.dart';

/// What a depth job must build.
class DepthRequest {
  final String kind; // photo_to_3d | depth_map
  final Project project;
  final MediaAsset media;
  final int layers;
  final String model; // auto | depth | fake

  /// Mirrored margin around the photo, as a share of its longest side
  /// (0 when the photo doesn't fill the frame).
  final double pad;

  /// The command to run again with "prepared" when the layers exist.
  final Map<String, dynamic> command;

  DepthRequest({
    required this.kind,
    required this.project,
    required this.media,
    required this.layers,
    required this.model,
    required this.pad,
    required this.command,
  });
}

/// Starts a depth job and returns its id (for job_status).
typedef DepthLauncher = String Function(DepthRequest request);

class DepthCommands {
  static const ops = ['photo_to_3d', 'depth_map'];
  static const models = ['auto', 'depth', 'fake'];

  /// Margin added around a photo that fills the frame (share of its long side).
  static const padFraction = 0.08;

  /// Set by the app; null in pure-Dart contexts (tests may set a fake).
  static DepthLauncher? launcher;

  static double? _optNum(Map<String, dynamic> c, String k) {
    final v = c[k];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    final d = double.tryParse('$v');
    if (d == null) throw CommandError('"$k" must be a number');
    return d;
  }

  static void run(Project project, Map<String, dynamic> c, double now, CommandResult r, void Function(Map<String, dynamic>) exec) {
    final op = '${c['op']}';
    final comp = project.editComp;
    final layerArg = c['layer'] == null ? null : '${c['layer']}';
    Layer? given;
    if (layerArg != null) {
      given = comp.layerById(layerArg);
      if (given == null) throw CommandError('$op: no layer "$layerArg" in ${comp.name}');
    }
    final mid = c['media'] == null ? given?.mediaId : '${c['media']}';
    final media = mid == null ? null : project.media[mid];
    if (media == null) {
      throw CommandError('$op needs "media" = an imported photo id (or "layer" = a photo layer). '
          'Photos: ${project.media.values.where((m) => m.type == MediaType.image).map((m) => m.id).join(', ')}');
    }
    if (media.type != MediaType.image) throw CommandError('$op: media "${media.id}" is ${media.type.name}, not a photo');
    if (given != null && given.mediaId != media.id) throw CommandError('$op: layer "${given.id}" does not show media "${media.id}"');

    final model = '${c['model'] ?? 'auto'}';
    if (!models.contains(model)) throw CommandError('$op: model must be ${models.join(', ')}');
    final n = (_optNum(c, 'layers') ?? DepthSplit.defaultLayers).round();
    if (n < 3 || n > DepthSplit.maxLayers) throw CommandError('photo_to_3d: layers must be 3-${DepthSplit.maxLayers}');
    final cam = cameraSpec(c['camera']);

    final prepared = c['prepared'];
    if (op == 'photo_to_3d' && prepared is Map) {
      _apply(project, c, Map<String, dynamic>.from(prepared), media, given, cam, now, r, exec);
      return;
    }
    if (op == 'depth_map' && prepared is Map) {
      r.log.add('depth_map: media ${prepared['media']}');
      return;
    }

    final base = given ?? findLayer(comp, media.id, now);
    final pad = op == 'depth_map' ? 0.0 : (base == null || coversFrame(comp, base, _startFor(c, base, now)) ? padFraction : 0.0);
    final start = launcher;
    if (start == null) throw CommandError('$op runs in the MotionAI app (it needs the photo file and the depth model)');
    final cmd = Map<String, dynamic>.from(c)..remove('prepared');
    if (base != null) cmd['layer'] = base.id;
    if (op == 'photo_to_3d') cmd['start'] = base == null ? (_optNum(c, 'start') ?? now) : _startFor(c, base, now); // the playhead may move meanwhile
    cmd['media'] = media.id;
    cmd['layers'] = n;
    final job = start(DepthRequest(kind: op, project: project, media: media, layers: n, model: model, pad: pad, command: cmd));
    r.log.add(op == 'photo_to_3d'
        ? 'photo_to_3d: building $n depth layers of ${media.name} in the background (job $job). Poll job_status {"job":"$job"}; '
            'the 3D layers and camera move appear as one undo step when it is done.'
        : 'depth_map: computing the depth map of ${media.name} in the background (job $job). Poll job_status {"job":"$job"}; '
            'the result is a new grayscale photo media (near = white).');
  }

  /// The photo layer showing [mediaId]: the top one active at [now], else the top one.
  static Layer? findLayer(Composition comp, String mediaId, double now) {
    Layer? first;
    for (final l in comp.layers) {
      if (l.type != LayerType.image || l.mediaId != mediaId) continue;
      if (l.isActiveAt(now)) return l;
      first ??= l;
    }
    return first;
  }

  static double _startFor(Map<String, dynamic> c, Layer base, double now) =>
      _optNum(c, 'start') ?? (base.isActiveAt(now) ? now : base.start);

  /// Whether [l] fills the whole frame at [t] (then a margin can be added
  /// around it without changing the picture).
  static bool coversFrame(Composition comp, Layer l, double t) {
    for (final it in Evaluator.evaluate(comp, t, velocity: false)) {
      if (it.layer.id != l.id) continue;
      final q = it.corners();
      final w = comp.width, h = comp.height;
      return [
        Vector2(0.5, 0.5),
        Vector2(w - 0.5, 0.5),
        Vector2(w - 0.5, h - 0.5),
        Vector2(0.5, h - 0.5),
      ].every((p) => pointInQuad(p, q));
    }
    return false;
  }

  /// Camera move of photo_to_3d: a camera_shot move name, an object
  /// {move, intensity?, direction?, ease?, duration?}, or "none"/false.
  static Map<String, dynamic>? cameraSpec(dynamic v) {
    if (v == false || v == 'none' || v == 'off') return null;
    final Map<String, dynamic> m;
    if (v == null || v == true) {
      m = {'move': 'drift'};
    } else if (v is String) {
      m = {'move': v};
    } else if (v is Map) {
      m = Map<String, dynamic>.from(v);
      m['move'] ??= 'drift';
    } else {
      throw CommandError('photo_to_3d: camera must be a move name (${Scene3D.moves.join(', ')}), {"move": …} or "none"');
    }
    final move = '${m['move']}';
    if (move == 'none') return null;
    if (!Scene3D.moves.contains(move)) throw CommandError('photo_to_3d: unknown camera move "$move". Use ${Scene3D.moves.join(', ')} or "none"');
    return m;
  }

  static void _apply(Project project, Map<String, dynamic> c, Map<String, dynamic> prep, MediaAsset media, Layer? given,
      Map<String, dynamic>? cam, double now, CommandResult r, void Function(Map<String, dynamic>) exec) {
    final comp = project.editComp;
    final raw = prep['layers'];
    if (raw is! List || raw.length < 2) throw CommandError('photo_to_3d: "prepared.layers" must list the generated layers');
    final parts = <({MediaAsset m, double x, double y, double k, double depth})>[];
    for (final e in raw) {
      if (e is! Map) throw CommandError('photo_to_3d: bad prepared layer $e');
      final m = project.media['${e['media']}'];
      if (m == null || m.type != MediaType.image) throw CommandError('photo_to_3d: no generated photo "${e['media']}"');
      double numOf(String k, double d) => e[k] is num ? (e[k] as num).toDouble() : d;
      parts.add((m: m, x: numOf('x', 0), y: numOf('y', 0), k: numOf('k', 1), depth: numOf('depth', 0.5)));
    }

    // The layer to replace (a new full-frame one when the photo isn't used yet).
    var found = given ?? findLayer(comp, media.id, now);
    var created = false;
    if (found == null) {
      final id = Ids.next('L');
      exec({
        'op': 'add_layer',
        'type': 'image',
        'media': media.id,
        'id': id,
        'fit': 'cover',
        'start': _optNum(c, 'start') ?? now,
        if (c['duration'] != null) 'duration': c['duration'],
      });
      found = comp.layerById(id)!;
      created = true;
    }
    final base = found;
    if (base.parentId != null) throw CommandError('photo_to_3d: layer "${base.id}" has a parent; unparent it first (update_layer parent null)');
    final start = _startFor(c, base, now);
    final dur = math.max(comp.frameDuration * 2, _optNum(c, 'duration') ?? (base.end - start));
    var inten = _optNum(c, 'intensity') ?? 0.5;
    if (inten > 1) inten /= 100;

    if (comp.camera.mode != CameraMode.threeD) r.log.add('photo_to_3d: camera switched to 3D');
    Scene3D.homeCamera(comp, start);
    final z0 = Scene3D.homeZoom(comp), cx = comp.width / 2, cy = comp.height / 2;
    final f = DepthPlace.factors([for (final p in parts) p.depth], intensity: inten);
    final names = DepthPlace.labels(parts.length);
    final at = comp.layers.indexOf(base);
    final ids = <String>[];
    for (var j = 0; j < parts.length; j++) {
      final p = parts[j];
      final l = DepthPlace.overlay(base,
          id: Ids.next('L'),
          mediaId: p.m.id,
          width: p.m.width,
          height: p.m.height,
          x: p.x,
          y: p.y,
          k: p.k,
          keepAllEffects: j == 0)
        ..name = '${base.name} · ${names[j]}'
        ..visible = true;
      DepthPlace.pushTo(l, f[j], cx, cy, z0);
      comp.layers.insert(at, l); // nearer layers end up on top
      ids.add(l.id);
    }
    r.createdIds.addAll(ids.reversed);
    if (created) {
      comp.layers.remove(base);
      r.createdIds.remove(base.id);
      r.log.removeWhere((s) => s.contains('(${base.id})'));
    } else {
      base.visible = false;
      r.log.add('photo_to_3d: the flat photo layer ${base.id} is hidden (kept below the 3D layers)');
    }
    r.log.add('photo_to_3d: ${parts.length} depth layers (${names.join(', ')}) at '
        '${[for (final x in f) '${x.toStringAsFixed(2)}×'].join(', ')} the camera distance${prep['model'] == null ? '' : ', depth from ${prep['model']}'}');

    if (cam != null) {
      // Only the opaque far layer may grow to hide edges; nearer layers keep
      // their exact size so the stack stays aligned.
      final keep = {for (final id in ids.skip(1)) id: comp.layerById(id)!.prop(Props.scale).copy()};
      final cstart = _optNum(cam, 'start') ?? start;
      final cdur = _optNum(cam, 'duration') ?? dur;
      var ci = _optNum(cam, 'intensity') ?? inten;
      if (ci > 1) ci /= 100;
      Scene3D.cameraShot(
        comp,
        move: '${cam['move']}',
        start: cstart,
        duration: cdur,
        intensity: ci.clamp(0.0, 1.0).toDouble(),
        direction: '${cam['direction'] ?? 'right'}',
        log: r.log,
      );
      for (final e in keep.entries) {
        comp.layerById(e.key)!.props[Props.scale] = e.value;
      }
      if (comp.duration < cstart + cdur) comp.duration = cstart + cdur;
    }
  }
}
