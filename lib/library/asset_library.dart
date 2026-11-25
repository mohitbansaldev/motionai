import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../core/model/project.dart';

/// What a library asset shows (AI auto-tagging picks one).
const libraryKinds = [
  'building', 'plant', 'grass_strip', 'sky', 'ground', 'prop', 'person', 'animal', 'vehicle',
  'icon', 'texture', 'interior', 'map', 'document', 'logo',
];

/// One reusable file in the cross-project asset library.
class LibraryAsset {
  final String id;
  MediaType type;
  String file; // file name inside the library's files/ folder
  String name;
  double width, height, duration;
  String description;
  String kind; // one of [libraryKinds], '' = not tagged yet
  String era, region, mood;
  List<String> tags;
  bool transparent; // PNG/WebP with an alpha channel (cut-out)
  DateTime added;
  String hash;
  String origin; // project it came from

  LibraryAsset({
    required this.id,
    required this.type,
    required this.file,
    required this.name,
    this.width = 0,
    this.height = 0,
    this.duration = 0,
    this.description = '',
    this.kind = '',
    this.era = '',
    this.region = '',
    this.mood = '',
    List<String>? tags,
    this.transparent = false,
    DateTime? added,
    this.hash = '',
    this.origin = '',
  })  : tags = tags ?? [],
        added = added ?? DateTime.now();

  bool get tagged => kind.isNotEmpty;

  /// One line for people and the AI: "[building · 1900s · India · calm · cut-out] old hut ...".
  String get about {
    final parts = [
      if (kind.isNotEmpty) kind,
      if (era.isNotEmpty) era,
      if (region.isNotEmpty) region,
      if (mood.isNotEmpty) mood,
      if (transparent) 'cut-out (transparent background)',
    ];
    final head = parts.isEmpty ? '' : '[${parts.join(' · ')}] ';
    final body = description.isNotEmpty ? description : name;
    final extra = tags.isEmpty ? '' : ' #${tags.join(' #')}';
    return '$head$body$extra'.trim();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'file': file,
        'name': name,
        'width': width,
        'height': height,
        if (duration > 0) 'duration': duration,
        if (description.isNotEmpty) 'desc': description,
        if (kind.isNotEmpty) 'kind': kind,
        if (era.isNotEmpty) 'era': era,
        if (region.isNotEmpty) 'region': region,
        if (mood.isNotEmpty) 'mood': mood,
        if (tags.isNotEmpty) 'tags': tags,
        if (transparent) 'alpha': true,
        'added': added.toIso8601String(),
        if (hash.isNotEmpty) 'hash': hash,
        if (origin.isNotEmpty) 'origin': origin,
      };

  static LibraryAsset fromJson(Map<String, dynamic> j) => LibraryAsset(
        id: '${j['id']}',
        type: MediaType.values.firstWhere((t) => t.name == j['type'], orElse: () => MediaType.image),
        file: '${j['file'] ?? ''}',
        name: '${j['name'] ?? ''}',
        width: (j['width'] as num? ?? 0).toDouble(),
        height: (j['height'] as num? ?? 0).toDouble(),
        duration: (j['duration'] as num? ?? 0).toDouble(),
        description: '${j['desc'] ?? ''}',
        kind: '${j['kind'] ?? ''}',
        era: '${j['era'] ?? ''}',
        region: '${j['region'] ?? ''}',
        mood: '${j['mood'] ?? ''}',
        tags: [for (final t in (j['tags'] as List? ?? const [])) '$t'],
        transparent: j['alpha'] == true,
        added: DateTime.tryParse('${j['added'] ?? ''}') ?? DateTime.fromMillisecondsSinceEpoch(0),
        hash: '${j['hash'] ?? ''}',
        origin: '${j['origin'] ?? ''}',
      );

  /// Applies one item of the AI tagging answer (see LibraryTagger).
  void applyTags(Map<String, dynamic> it) {
    final k = '${it['kind'] ?? ''}'.trim().toLowerCase().replaceAll(' ', '_');
    if (libraryKinds.contains(k)) kind = k;
    String s(String key) => '${it[key] ?? ''}'.trim();
    if (s('era').isNotEmpty) era = s('era');
    if (s('region').isNotEmpty) region = s('region');
    if (s('mood').isNotEmpty) mood = s('mood');
    if (s('desc').isNotEmpty) description = s('desc');
    final t = it['tags'];
    if (t is List) {
      tags = {
        for (final v in t)
          if ('$v'.trim().isNotEmpty) '$v'.trim().toLowerCase(),
      }.take(12).toList();
    }
    // The file decides transparency when it can; the AI only fills the gap.
    if (it['transparent'] == true && type == MediaType.image && !file.toLowerCase().endsWith('.jpg') && !file.toLowerCase().endsWith('.jpeg')) {
      transparent = true;
    }
  }
}

/// A named group of library assets ("Village kit").
class AssetKit {
  final String id;
  String name;
  final List<String> assetIds;
  AssetKit({required this.id, required this.name, List<String>? assetIds}) : assetIds = assetIds ?? [];

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'assets': assetIds};
  static AssetKit fromJson(Map<String, dynamic> j) =>
      AssetKit(id: '${j['id']}', name: '${j['name'] ?? 'Kit'}', assetIds: [for (final a in (j['assets'] as List? ?? const [])) '$a']);
}

/// The library's index.json: assets, kits, saved templates and recipe names.
class LibraryIndex {
  static const version = 1;
  final List<LibraryAsset> assets;
  final List<AssetKit> kits;
  final List<Map<String, dynamic>> templates; // SceneTemplate.toJson()
  final List<Map<String, dynamic>> recipes; // {name, created, note?}

  LibraryIndex({List<LibraryAsset>? assets, List<AssetKit>? kits, List<Map<String, dynamic>>? templates, List<Map<String, dynamic>>? recipes})
      : assets = assets ?? [],
        kits = kits ?? [],
        templates = templates ?? [],
        recipes = recipes ?? [];

  Map<String, dynamic> toJson() => {
        'version': version,
        'assets': [for (final a in assets) a.toJson()],
        'kits': [for (final k in kits) k.toJson()],
        'templates': templates,
        'recipes': recipes,
      };

  static LibraryIndex fromJson(Map<String, dynamic> j) => LibraryIndex(
        assets: [
          for (final a in (j['assets'] as List? ?? const []))
            if (a is Map) LibraryAsset.fromJson(Map<String, dynamic>.from(a)),
        ],
        kits: [
          for (final k in (j['kits'] as List? ?? const []))
            if (k is Map) AssetKit.fromJson(Map<String, dynamic>.from(k)),
        ],
        templates: [
          for (final t in (j['templates'] as List? ?? const []))
            if (t is Map) Map<String, dynamic>.from(t),
        ],
        recipes: [
          for (final r in (j['recipes'] as List? ?? const []))
            if (r is Map) Map<String, dynamic>.from(r),
        ],
      );

  static LibraryIndex parse(String text) {
    try {
      final d = jsonDecode(text);
      return d is Map ? fromJson(Map<String, dynamic>.from(d)) : LibraryIndex();
    } catch (_) {
      return LibraryIndex();
    }
  }
}

/// Search + filter, independent of files (used by the UI, the Director and tests).
/// Every word of [query] must match somewhere (name, description, tags, kind,
/// era, region, mood); results are ranked by how well they match.
List<LibraryAsset> searchAssets(Iterable<LibraryAsset> all, String query, {Iterable<String>? kinds, MediaType? type, bool? transparent}) {
  final words = query.toLowerCase().split(RegExp(r'[\s,]+')).where((w) => w.isNotEmpty).toList();
  final kindSet = kinds?.toSet();
  final scored = <(LibraryAsset, double)>[];
  for (final a in all) {
    if (kindSet != null && kindSet.isNotEmpty && !kindSet.contains(a.kind)) continue;
    if (type != null && a.type != type) continue;
    if (transparent != null && a.transparent != transparent) continue;
    var score = 0.0;
    var ok = true;
    for (final w in words) {
      double s = 0;
      if (a.kind == w || a.kind.replaceAll('_', ' ') == w) s = math.max(s, 5.0);
      if (a.tags.contains(w)) s = math.max(s, 4.0);
      if (a.name.toLowerCase().contains(w)) s = math.max(s, 3.0);
      if (a.tags.any((t) => t.contains(w))) s = math.max(s, 2.5);
      if (a.region.toLowerCase().contains(w) || a.era.toLowerCase().contains(w) || a.mood.toLowerCase().contains(w)) s = math.max(s, 2.0);
      if (a.description.toLowerCase().contains(w)) s = math.max(s, 1.0);
      if (a.kind.contains(w)) s = math.max(s, 1.0);
      if ((w == 'cutout' || w == 'cut-out' || w == 'png' || w == 'transparent') && a.transparent) s = math.max(s, 2.0);
      if (s == 0) {
        ok = false;
        break;
      }
      score += s;
    }
    if (ok) scored.add((a, score));
  }
  scored.sort((x, y) {
    final c = y.$2.compareTo(x.$2);
    return c != 0 ? c : y.$1.added.compareTo(x.$1.added);
  });
  return [for (final s in scored) s.$1];
}

/// True when an image file's header says it has an alpha channel.
bool fileHasAlpha(List<int> head) {
  bool at(int i, String s) {
    if (head.length < i + s.length) return false;
    for (int k = 0; k < s.length; k++) {
      if (head[i + k] != s.codeUnitAt(k)) return false;
    }
    return true;
  }

  // PNG: colour type 4 (grey+alpha) or 6 (RGBA), or a tRNS chunk before IDAT.
  if (head.length > 26 && head[0] == 0x89 && at(1, 'PNG')) {
    final ct = head[25];
    if (ct == 4 || ct == 6) return true;
    var i = 8;
    while (i + 8 <= head.length) {
      final len = (head[i] << 24) | (head[i + 1] << 16) | (head[i + 2] << 8) | head[i + 3];
      if (at(i + 4, 'tRNS')) return true;
      if (at(i + 4, 'IDAT') || len < 0) return false;
      i += 12 + len;
    }
    return false;
  }
  // WebP: extended header alpha flag, or lossless with the alpha hint bit.
  if (at(0, 'RIFF') && at(8, 'WEBP')) {
    if (at(12, 'VP8X') && head.length > 20) return (head[20] & 0x10) != 0;
    if (at(12, 'VP8L') && head.length > 24) return (head[24] & 0x10) != 0;
  }
  return false;
}

/// Asset library shared by every project: index.json + copied files in the
/// app support folder. Pure Dart (no widgets) so the Director and tests can
/// use it directly.
class AssetLibrary {
  final Directory root;
  LibraryIndex index;
  AssetLibrary._(this.root, this.index);

  static AssetLibrary? _shared;
  static Future<AssetLibrary>? _opening;

  /// The library if it has been opened already (sync access for the Director).
  static AssetLibrary? get loaded => _shared;

  /// Opens the app-wide library once (app support dir/library).
  static Future<AssetLibrary> shared() => _opening ??= open().then((l) => _shared = l).catchError((Object e) {
        _opening = null;
        throw e;
      });

  /// Opens the library in [dir] (default: app support dir/library).
  static Future<AssetLibrary> open([Directory? dir]) async {
    dir ??= Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}library');
    await Directory('${dir.path}${Platform.pathSeparator}files').create(recursive: true);
    final f = File('${dir.path}${Platform.pathSeparator}index.json');
    final index = await f.exists() ? LibraryIndex.parse(await f.readAsString()) : LibraryIndex();
    return AssetLibrary._(dir, index);
  }

  /// For tests: use [lib] as the shared library.
  static void setShared(AssetLibrary? lib) {
    _shared = lib;
    _opening = lib == null ? null : Future.value(lib);
  }

  String get _sep => Platform.pathSeparator;
  File get indexFile => File('${root.path}${_sep}index.json');
  Directory get filesDir => Directory('${root.path}${_sep}files');
  List<LibraryAsset> get assets => index.assets;
  List<AssetKit> get kits => index.kits;

  String pathOf(LibraryAsset a) => '${filesDir.path}$_sep${a.file}';

  static String _bare(String id) => id.startsWith('lib:') ? id.substring(4) : id;

  LibraryAsset? byId(String id) {
    final k = _bare(id);
    for (final a in index.assets) {
      if (a.id == k) return a;
    }
    return null;
  }

  Future<void> save() async {
    final tmp = File('${indexFile.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(index.toJson()));
    await tmp.rename(indexFile.path);
  }

  static Future<String> _hash(File f) async {
    final len = await f.length();
    final raf = await f.open();
    try {
      final head = await raf.read(math.min(len, 1 << 20));
      return '${md5.convert(head)}-$len';
    } finally {
      await raf.close();
    }
  }

  static String _newId() {
    final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'a$t${math.Random().nextInt(1 << 20).toRadixString(36)}';
  }

  /// Copies a file into the library (same file twice → the existing entry).
  Future<LibraryAsset> addFile(String path,
      {required MediaType type, String? name, double width = 0, double height = 0, double duration = 0, String description = '', String origin = ''}) async {
    final src = File(path);
    if (!await src.exists()) throw FileSystemException('File not found', path);
    final hash = await _hash(src);
    for (final a in index.assets) {
      if (a.hash == hash && await File(pathOf(a)).exists()) return a;
    }
    final id = _newId();
    final base = path.split(RegExp(r'[\\/]')).last;
    final ext = base.contains('.') ? base.split('.').last.toLowerCase() : (type == MediaType.video ? 'mp4' : type == MediaType.audio ? 'wav' : 'png');
    final file = '$id.$ext';
    await src.copy('${filesDir.path}$_sep$file');
    var alpha = false;
    if (type == MediaType.image) {
      final raf = await src.open();
      try {
        alpha = fileHasAlpha(await raf.read(64 * 1024));
      } finally {
        await raf.close();
      }
    }
    final display = name ?? (base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base);
    final a = LibraryAsset(
      id: id, type: type, file: file, name: display, width: width, height: height, duration: duration,
      description: description, transparent: alpha, hash: hash, origin: origin,
    );
    index.assets.insert(0, a);
    await save();
    return a;
  }

  /// Adds a project media item (keeps its AI description).
  Future<LibraryAsset> addMedia(MediaAsset m, {String origin = ''}) => addFile(m.path,
      type: m.type, name: m.name, width: m.width, height: m.height, duration: m.duration, description: m.description, origin: origin);

  Future<void> remove(String id) async {
    final a = byId(id);
    if (a == null) return;
    index.assets.remove(a);
    for (final k in index.kits) {
      k.assetIds.remove(a.id);
    }
    try {
      await File(pathOf(a)).delete();
    } catch (_) {}
    await save();
  }

  List<LibraryAsset> search(String query, {Iterable<String>? kinds, MediaType? type, String? kit, bool? transparent}) {
    Iterable<LibraryAsset> pool = index.assets;
    if (kit != null) {
      final k = index.kits.where((e) => e.id == kit).firstOrNull;
      final ids = k?.assetIds.toSet() ?? <String>{};
      pool = pool.where((a) => ids.contains(a.id));
    }
    return searchAssets(pool, query, kinds: kinds, type: type, transparent: transparent);
  }

  // ------------------------------------------------------------ kits

  Future<AssetKit> createKit(String name, [Iterable<String> assetIds = const []]) async {
    final k = AssetKit(id: 'k${_newId()}', name: name, assetIds: [for (final a in assetIds) _bare(a)]);
    index.kits.add(k);
    await save();
    return k;
  }

  Future<void> addToKit(String kitId, Iterable<String> assetIds) async {
    final k = index.kits.where((e) => e.id == kitId).firstOrNull;
    if (k == null) return;
    for (final a in assetIds) {
      if (!k.assetIds.contains(_bare(a))) k.assetIds.add(_bare(a));
    }
    await save();
  }

  Future<void> removeKit(String kitId) async {
    index.kits.removeWhere((k) => k.id == kitId);
    await save();
  }

  // ------------------------------------------------------------ templates & recipes

  Future<void> saveTemplate(Map<String, dynamic> json) async {
    index.templates.removeWhere((t) => t['id'] == json['id']);
    index.templates.insert(0, json);
    await save();
  }

  Future<void> deleteTemplate(String id) async {
    index.templates.removeWhere((t) => t['id'] == id);
    await save();
  }

  List<String> get recipeNames => [for (final r in index.recipes) '${r['name']}'];

  Future<void> noteRecipe(String name, {String note = ''}) async {
    index.recipes.removeWhere((r) => r['name'] == name);
    index.recipes.insert(0, {'name': name, 'created': DateTime.now().toIso8601String(), if (note.isNotEmpty) 'note': note});
    await save();
  }

  Future<void> forgetRecipe(String name) async {
    index.recipes.removeWhere((r) => r['name'] == name);
    await save();
  }

  // ------------------------------------------------------------ projects

  /// Where a library asset lives once imported into a project's media folder.
  static String importedPath(String mediaDir, LibraryAsset a) => '$mediaDir${Platform.pathSeparator}lib_${a.file}';

  /// Media id in [p] for library asset [libId] (copied into [mediaDir] once;
  /// PNG cut-outs keep their alpha because the file is copied as-is).
  Future<MediaAsset> importInto(Project p, String libId, {required String mediaDir}) async {
    final a = byId(libId);
    if (a == null) throw ArgumentError('No library asset "$libId"');
    final dest = importedPath(mediaDir, a);
    for (final m in p.media.values) {
      if (m.path == dest) return m;
    }
    if (!await File(dest).exists()) await File(pathOf(a)).copy(dest);
    final prefix = switch (a.type) { MediaType.video => 'vid', MediaType.audio => 'aud', MediaType.image => 'img' };
    final m = MediaAsset(
      id: Ids.next(prefix), type: a.type, path: dest, name: a.name, width: a.width, height: a.height, duration: a.duration,
      description: a.about,
    );
    p.media[m.id] = m;
    return m;
  }

  /// Library entries for the Director's media list (`lib:<id>`), skipping
  /// audio and assets already imported into [p].
  List<Map<String, dynamic>> directorEntries({Project? exclude, int limit = 60, String query = ''}) {
    final have = exclude == null ? const <String>{} : {for (final m in exclude.media.values) m.path.split(RegExp(r'[\\/]')).last};
    final pool = query.trim().isEmpty ? index.assets : search(query);
    final out = <Map<String, dynamic>>[];
    for (final a in pool) {
      if (a.type == MediaType.audio || have.contains('lib_${a.file}')) continue;
      out.add({
        'id': 'lib:${a.id}',
        'type': a.type.name,
        if (a.duration > 0) 'seconds': double.parse(a.duration.toStringAsFixed(1)),
        'about': 'LIBRARY ${a.about}',
      });
      if (out.length >= limit) break;
    }
    return out;
  }
}
