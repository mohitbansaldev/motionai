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
      );

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
      );
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

  Project({
    required this.id,
    required this.name,
    required this.main,
    DateTime? modified,
    Map<String, MediaAsset>? media,
  })  : modified = modified ?? DateTime.now(),
        media = media ?? {};

  Map<String, dynamic> toJson() => {
        'schema': schemaVersion,
        'id': id,
        'name': name,
        'modified': modified.toIso8601String(),
        'media': media.values.map((m) => m.toJson()).toList(),
        'main': main.toJson(),
        if (recipes.isNotEmpty) 'recipes': recipes, // SCENE (Agent D)
        if (shots.isNotEmpty) 'shots': shots, // SCENE (Agent D)
      };

  static Project fromJson(Map<String, dynamic> j) {
    final media = <String, MediaAsset>{};
    for (final m in (j['media'] as List? ?? [])) {
      final a = MediaAsset.fromJson(m as Map<String, dynamic>);
      media[a.id] = a;
    }
    return Project(
      id: j['id'] as String,
      name: j['name'] as String? ?? 'Untitled',
      modified: DateTime.tryParse(j['modified'] as String? ?? '') ?? DateTime.now(),
      media: media,
      main: Composition.fromJson(j['main'] as Map<String, dynamic>),
    )
      // SCENE (Agent D): recipes + shots (absent in older projects).
      ..recipes.addAll(j['recipes'] is Map ? Map<String, dynamic>.from(j['recipes'] as Map) : const {})
      ..shots.addAll(j['shots'] is Map ? Map<String, dynamic>.from(j['shots'] as Map) : const {});
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
