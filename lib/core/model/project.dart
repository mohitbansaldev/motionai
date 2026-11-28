import 'camera.dart';
import 'layer.dart';

enum MediaType { video, image, audio }

/// An imported media file. Width/height/duration are probed on import.
class MediaAsset {
  String id;
  MediaType type;
  String path;
  String name;
  double width;
  double height;
  double duration; // seconds (0 for images)
  String description; // AI-written description of what's in it (Director mode)

  MediaAsset({
    required this.id,
    required this.type,
    required this.path,
    required this.name,
    required this.width,
    required this.height,
    this.duration = 0,
    this.description = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'path': path,
        'name': name,
        'width': width,
        'height': height,
        'duration': duration,
        if (description.isNotEmpty) 'desc': description,
      };

  static MediaAsset fromJson(Map<String, dynamic> j) => MediaAsset(
        id: j['id'] as String,
        type: MediaType.values.firstWhere((t) => t.name == j['type']),
        path: j['path'] as String,
        name: j['name'] as String? ?? '',
        width: (j['width'] as num).toDouble(),
        height: (j['height'] as num).toDouble(),
        duration: (j['duration'] as num? ?? 0).toDouble(),
        description: j['desc'] as String? ?? '',
      );
}

/// A composition. `layers[0]` is the TOP layer (After Effects order).
class Composition {
  String id;
  String name;
  double width;
  double height;
  double fps;
  double duration;
  int background; // ARGB
  final List<Layer> layers;
  CameraRig camera;

  /// Motion blur on fast-moving layers and camera moves (see Evaluator).
  bool motionBlur;

  // V2-D >>>
  /// Depth of field focus follows: "target" (the 3D camera's point of
  /// interest) or a layer id; null = the camera's own focus distance.
  String? dofFocus;
  // <<< V2-D

  // win-43 >>> atmosphere: depth fog / aerial perspective for 3D layers.
  /// [start depth px, end depth px, max %] (null = off) and its colour.
  List<double>? fog;
  int fogColor = 0xFF8FA0B4;
  // <<< win-43

  // win-40 >>> viewer: After Effects view layout ("1", "2", "4", "1+3") and the
  // 3D view of each pane (see ViewCam.kinds); custom view orbits [yaw, pitch, dist].
  String viewLayout = '1';
  List<String> views = ['active', 'top', 'front', 'right'];
  Map<String, List<double>> customViews = {};
  static const viewLayouts = ['1', '2', '4', '1+3'];
  // <<< win-40

  Composition({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    this.fps = 30,
    this.duration = 30,
    this.background = 0xFF000000,
    List<Layer>? layers,
    CameraRig? camera,
    this.motionBlur = false,
  })  : layers = layers ?? [],
        camera = camera ?? CameraRig.defaults(width, height) {
    this.camera.ensureDefaults(width, height);
  }

  double get frameDuration => 1 / fps;

  double snapToFrame(double t) => (t * fps).roundToDouble() / fps;

  Layer? layerById(String id) {
    for (final l in layers) {
      if (l.id == id) return l;
    }
    return null;
  }

  Layer requireLayer(String id) {
    final l = layerById(id);
    if (l == null) throw ArgumentError('No layer with id "$id"');
    return l;
  }

  int indexOf(String id) => layers.indexWhere((l) => l.id == id);

  /// End time of the last layer (useful to auto-extend comp duration).
  double get contentEnd => layers.fold(0.0, (m, l) => l.end > m ? l.end : m);

  Composition copy() => Composition(
        id: id,
        name: name,
        width: width,
        height: height,
        fps: fps,
        duration: duration,
        background: background,
        layers: layers.map((l) => l.copy()).toList(),
        camera: camera.copy(),
        motionBlur: motionBlur,
      )
        ..dofFocus = dofFocus // V2-D
        ..fog = fog == null ? null : List.of(fog!) // win-43
        ..fogColor = fogColor // win-43
        ..viewLayout = viewLayout // win-40
        ..views = List.of(views) // win-40
        ..customViews = customViews.map((k, v) => MapEntry(k, List.of(v))); // win-40

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'width': width,
        'height': height,
        'fps': fps,
        'duration': duration,
        'background': background,
        'layers': layers.map((l) => l.toJson()).toList(),
        'camera': camera.toJson(),
        if (motionBlur) 'motionBlur': true,
        if (dofFocus != null) 'dofFocus': dofFocus, // V2-D
        if (fog != null) 'fog': fog, // win-43
        if (fog != null) 'fogColor': fogColor, // win-43
        if (viewLayout != '1') 'viewLayout': viewLayout, // win-40
        if (viewLayout != '1' || views.join() != 'activetopfrontright') 'views': views, // win-40
        if (customViews.isNotEmpty) 'customViews': customViews, // win-40
      };

  static Composition fromJson(Map<String, dynamic> j) => Composition(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Main',
        width: (j['width'] as num).toDouble(),
        height: (j['height'] as num).toDouble(),
        fps: (j['fps'] as num? ?? 30).toDouble(),
        duration: (j['duration'] as num? ?? 30).toDouble(),
        background: j['background'] as int? ?? 0xFF000000,
        layers: (j['layers'] as List? ?? []).map((e) => Layer.fromJson(e as Map<String, dynamic>)).toList(),
        camera: j['camera'] == null ? null : CameraRig.fromJson(j['camera'] as Map<String, dynamic>),
        motionBlur: j['motionBlur'] as bool? ?? false,
      )
        ..dofFocus = j['dofFocus'] as String? // V2-D
        ..fog = j['fog'] is List && (j['fog'] as List).length >= 3 ? [for (final x in (j['fog'] as List).take(3)) (x as num).toDouble()] : null // win-43
        ..fogColor = j['fogColor'] as int? ?? 0xFF8FA0B4 // win-43
        ..viewLayout = viewLayouts.contains(j['viewLayout']) ? j['viewLayout'] as String : '1' // win-40
        ..views = j['views'] is List ? [for (final v in j['views'] as List) '$v'] : ['active', 'top', 'front', 'right'] // win-40
        ..customViews = j['customViews'] is Map
            ? (j['customViews'] as Map).map((k, v) => MapEntry('$k', [for (final x in v as List) (x as num).toDouble()]))
            : <String, List<double>>{}; // win-40
}

class Project {
  static const int schemaVersion = 1;

  String id;
  String name;
  DateTime modified;
  final Map<String, MediaAsset> media;
  Composition main;

  // SCENE (Agent D): saved recipes (look/move/frame of a layer) and shots
  // (camera + 3D arrangement), by name. JSON-only data, see presets/scene3d.dart.
  final Map<String, dynamic> recipes = {};
  final Map<String, dynamic> shots = {};
  // end SCENE
  // V2-B >>> shots built by add_shot / sequence: shot id → {spec, start, duration} (see commands/shot_commands.dart).
  // The shot's precomp and its comp layer in main share the shot id.
  final Map<String, dynamic> seqShots = {};
  // <<< V2-B
  // PRECOMP (Agent L) >>>
  /// Nested compositions (precomps), by id. Used by `LayerType.comp` layers.
  final Map<String, Composition> comps;

  /// The composition being edited (editor state, not saved): null = [main].
  /// Edit commands work on [editComp]; export always renders [main].
  String? editCompId;

  /// The composition edit commands apply to.
  Composition get editComp => (editCompId == null ? null : compById(editCompId!)) ?? main;

  /// [main] (by its id or "main") or a nested comp.
  Composition? compById(String id) => id == main.id || id == 'main' ? main : comps[id];
  // <<< PRECOMP (Agent L)

  Project({
    required this.id,
    required this.name,
    required this.main,
    DateTime? modified,
    Map<String, MediaAsset>? media,
    Map<String, Composition>? comps, // PRECOMP (Agent L)
  })  : modified = modified ?? DateTime.now(),
        media = media ?? {},
        comps = comps ?? {}; // PRECOMP (Agent L)

  Map<String, dynamic> toJson() => {
        'schema': schemaVersion,
        'id': id,
        'name': name,
        'modified': modified.toIso8601String(),
        'media': media.values.map((m) => m.toJson()).toList(),
        'main': main.toJson(),
        if (recipes.isNotEmpty) 'recipes': recipes, // SCENE (Agent D)
        if (shots.isNotEmpty) 'shots': shots, // SCENE (Agent D)
        if (seqShots.isNotEmpty) 'seq_shots': seqShots, // V2-B
        if (comps.isNotEmpty) 'comps': comps.values.map((c) => c.toJson()).toList(), // PRECOMP (Agent L)
      };

  static Project fromJson(Map<String, dynamic> j) {
    final media = <String, MediaAsset>{};
    for (final m in (j['media'] as List? ?? [])) {
      final a = MediaAsset.fromJson(m as Map<String, dynamic>);
      media[a.id] = a;
    }
    // PRECOMP (Agent L): nested comps (absent in older projects).
    final comps = <String, Composition>{};
    for (final c in (j['comps'] as List? ?? [])) {
      final comp = Composition.fromJson(Map<String, dynamic>.from(c as Map));
      comps[comp.id] = comp;
    }
    return Project(
      comps: comps, // PRECOMP (Agent L)
      id: j['id'] as String,
      name: j['name'] as String? ?? 'Untitled',
      modified: DateTime.tryParse(j['modified'] as String? ?? '') ?? DateTime.now(),
      media: media,
      main: Composition.fromJson(j['main'] as Map<String, dynamic>),
    )
      // SCENE (Agent D): recipes + shots (absent in older projects).
      ..recipes.addAll(j['recipes'] is Map ? Map<String, dynamic>.from(j['recipes'] as Map) : const {})
      ..shots.addAll(j['shots'] is Map ? Map<String, dynamic>.from(j['shots'] as Map) : const {})
      ..seqShots.addAll(j['seq_shots'] is Map ? Map<String, dynamic>.from(j['seq_shots'] as Map) : const {}); // V2-B
  }
}

/// Simple unique id generator (no external package needed).
class Ids {
  static int _counter = 0;
  static String next(String prefix) {
    _counter = (_counter + 1) % 0xFFFFFF;
    final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return '${prefix}_$t${_counter.toRadixString(36)}';
  }
}
