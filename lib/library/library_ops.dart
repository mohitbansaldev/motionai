// V2-F: asset pipeline operations on the shared library, as JSON in / JSON
// out so the MCP server (library_import_folder, library_clean,
// library_search, library_suggest) and the UI call the same code.
import 'dart:io';
import 'dart:isolate';

import '../core/model/project.dart';
import '../platform/win_media.dart';
import 'asset_library.dart';
import 'asset_search.dart';
import 'image_clean.dart';

/// Size + duration of a video / audio file, or null when unknown.
typedef MediaProbe = Future<(double, double, double)?> Function(String path, MediaType type);

/// A file found by [LibraryOps.planFolder].
class PlannedFile {
  final String path, rel;
  final MediaType type;
  final RoleGuess? role;
  String skip = ''; // reason it is not imported
  PlannedFile(this.path, this.rel, this.type, this.role);
}

class LibraryOps {
  static const imageExt = {'png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif', 'tif', 'tiff'};
  static const videoExt = {'mp4', 'mov', 'm4v', 'webm', 'mkv', 'avi'};
  static const audioExt = {'mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac', 'opus'};

  static MediaType? typeOf(String path) {
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    if (imageExt.contains(ext)) return MediaType.image;
    if (videoExt.contains(ext)) return MediaType.video;
    if (audioExt.contains(ext)) return MediaType.audio;
    return null;
  }

  static bool _alphaFormat(String path) {
    final p = path.toLowerCase();
    return p.endsWith('.png') || p.endsWith('.webp');
  }

  /// Which files of a folder listing ([rel] paths relative to the folder)
  /// to import. Same-named pictures in different formats ("char_x.jpg" on
  /// green + "cutouts/char_x.png" clean) → the PNG/WebP cut-out wins.
  static List<PlannedFile> plan(String root, List<String> rels) {
    final sep = Platform.pathSeparator;
    final out = <PlannedFile>[];
    for (final rel in rels) {
      final base = rel.split(RegExp(r'[\\/]')).last;
      if (base.startsWith('.') || base.toLowerCase() == 'thumbs.db' || base.toLowerCase() == 'desktop.ini') continue;
      final t = typeOf(base);
      if (t == null) continue;
      out.add(PlannedFile('$root$sep${rel.replaceAll(RegExp(r'[\\/]'), sep)}', rel, t, AssetRoles.guess(rel)));
    }
    final groups = <String, List<PlannedFile>>{};
    for (final f in out) {
      if (f.type == MediaType.image) groups.putIfAbsent(AssetRoles.variantKey(f.rel), () => []).add(f);
    }
    for (final g in groups.values) {
      if (g.length < 2) continue;
      final cut = g.where((f) => _alphaFormat(f.path)).toList();
      if (cut.isEmpty) continue;
      for (final f in g) {
        if (!_alphaFormat(f.path)) f.skip = 'png_preferred (${cut.first.rel})';
      }
    }
    return out;
  }

  /// Every file under [dir] as relative paths ('/' separated).
  static Future<List<String>> listFolder(Directory dir, {bool recursive = true}) async {
    final out = <String>[];
    final root = dir.absolute.path;
    await for (final e in dir.list(recursive: recursive, followLinks: false)) {
      if (e is! File) continue;
      var rel = e.absolute.path.substring(root.length);
      rel = rel.replaceAll('\\', '/');
      while (rel.startsWith('/')) {
        rel = rel.substring(1);
      }
      out.add(rel);
    }
    out.sort();
    return out;
  }

  /// "Tulip_Library" → "Tulip Library".
  static String kitName(String folder) {
    final base = folder.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).lastOrNull ?? 'Kit';
    return base.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
  }

  static Future<(double, double, double)?> defaultProbe(String path, MediaType type) async {
    if (!Platform.isWindows) return null;
    try {
      final i = await WinMedia.probe(path);
      final rot = i.rotation % 180 != 0;
      return ((rot ? i.height : i.width).toDouble(), (rot ? i.width : i.height).toDouble(), i.duration);
    } catch (_) {
      return null;
    }
  }

  static String _gs(Object? v) {
    if (v == true || v == 'true' || v == 'on' || v == 'yes') return 'true';
    if (v == false || v == 'false' || v == 'off' || v == 'no') return 'false';
    return 'auto';
  }

  static List<String> _strs(Object? v) => v is List
      ? [for (final x in v) '$x'.trim().toLowerCase()].where((s) => s.isNotEmpty).toList()
      : (v is String && v.trim().isNotEmpty ? v.split(',').map((s) => s.trim().toLowerCase()).where((s) => s.isNotEmpty).toList() : <String>[]);

  static Future<CleanOutcome> _process(CleanJob job) => Isolate.run(() => ImageClean.processFile(job));

  /// `import_folder` {path, recursive?: true, kit?: name (default: folder
  /// name), tags?: [..], green_screen?: auto|true|false, remove_mark?: false}
  static Future<Map<String, dynamic>> importFolder(AssetLibrary lib, Map<String, dynamic> a,
      {MediaProbe? probe, void Function(String status)? status}) async {
    final path = '${a['path'] ?? ''}'.trim();
    if (path.isEmpty) throw ArgumentError('import_folder needs "path" (a folder)');
    final dir = Directory(path);
    if (!await dir.exists()) throw ArgumentError('Folder not found: $path');
    final recursive = a['recursive'] != false;
    final gs = _gs(a['green_screen']);
    final removeMark = a['remove_mark'] == true;
    final extraTags = _strs(a['tags']);
    final kitLabel = '${a['kit'] ?? ''}'.trim().isEmpty ? kitName(path) : '${a['kit']}'.trim();
    final kitTags = AssetRoles.nameTags(kitLabel.replaceAll(' ', '_')).where((t) => !const {'library', 'kit', 'assets', 'out', 'flow', 'mcp'}.contains(t));
    final files = plan(dir.absolute.path, await listFolder(dir, recursive: recursive));
    final tmp = Directory('${lib.root.path}${Platform.pathSeparator}tmp');
    await tmp.create(recursive: true);
    final probeFn = probe ?? defaultProbe;
    final ids = <String>[];
    final skipped = <Map<String, dynamic>>[];
    final assets = <Map<String, dynamic>>[];
    var imported = 0, dups = 0, keyed = 0, marks = 0, marksFound = 0;
    var n = 0;
    for (final f in files) {
      n++;
      if (f.skip.isNotEmpty) {
        skipped.add({'file': f.rel, 'reason': f.skip});
        continue;
      }
      status?.call('Importing $n/${files.length}: ${f.rel}');
      try {
        final hash = await AssetLibrary.hashFile(f.path);
        var asset = await lib.byHash(hash);
        final isDup = asset != null;
        CleanOutcome? clean;
        if (asset == null) {
          var w = 0.0, h = 0.0, dur = 0.0;
          if (f.type == MediaType.image) {
            clean = await _process(CleanJob(f.path, '${tmp.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}',
                // Auto mode never keys plates / overlays (a clear sky is not a blue screen).
                greenScreen: gs == 'auto' && (f.role?.role == 'plate' || f.role?.role == 'overlay') ? 'false' : gs,
                removeMark: removeMark));
            if (clean.error.isNotEmpty) throw FormatException(clean.error);
            w = clean.width.toDouble();
            h = clean.height.toDouble();
          } else {
            final p = await probeFn(f.path, f.type);
            if (p != null) (w, h, dur) = p;
            if (f.type == MediaType.video && w <= 0) (w, h) = (1920.0, 1080.0);
          }
          if (clean != null && clean.output.isNotEmpty) {
            asset = await lib.addPrepared(f.path, clean.output,
                type: f.type, width: w, height: h, transparent: clean.alpha, cleaned: clean.fixes, origin: 'folder', saveIndex: false);
            try {
              await File(clean.output).delete();
            } catch (_) {}
          } else {
            asset = await lib.addFile(f.path, type: f.type, width: w, height: h, duration: dur, origin: 'folder');
            if (clean != null) asset.transparent = clean.alpha;
          }
          if (clean != null) {
            if (clean.keyed) keyed++;
            if (clean.markRemoved) marks++;
            if (clean.markFound) marksFound++;
          }
          imported++;
        } else {
          dups++;
        }
        // Tags: role from prefix/folder, words of the name, the kit, extras.
        final g = f.role;
        if (g != null && (asset.kind.isEmpty || !isDup)) asset.kind = g.kind;
        final tags = <String>{...asset.tags, ...?g?.tags, ...AssetRoles.nameTags(f.rel), ...kitTags, ...extraTags};
        if (asset.transparent) tags.add('cut-out');
        if (f.rel.toLowerCase().split('/').contains('cutouts')) tags.add('cut-out');
        asset.tags = tags.take(16).toList();
        if (!ids.contains(asset.id)) ids.add(asset.id);
        if (assets.length < 300) {
          assets.add({
            ...AssetHit(asset, 0, const []).toJson()..remove('score'),
            'file': f.rel,
            if (isDup) 'duplicate': true,
            if (clean != null && clean.markFound && !clean.markRemoved) 'mark': 'found (remove_mark:true removes it)',
          });
        }
      } catch (e) {
        skipped.add({'file': f.rel, 'reason': 'error: $e'});
      }
    }
    // Group into a kit (an existing kit of that name is reused).
    AssetKit? kit;
    if (ids.isNotEmpty) {
      kit = lib.kits.where((k) => k.name.toLowerCase() == kitLabel.toLowerCase()).firstOrNull;
      if (kit == null) {
        kit = await lib.createKit(kitLabel, ids);
      } else {
        for (final id in ids) {
          if (!kit.assetIds.contains(id)) kit.assetIds.add(id);
        }
      }
    }
    await lib.save();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
    return {
      'ok': true,
      'folder': path,
      if (kit != null) 'kit': {'id': kit.id, 'name': kit.name, 'assets': kit.assetIds.length},
      'imported': imported,
      'duplicates': dups,
      'green_screen_keyed': keyed,
      'marks_removed': marks,
      if (marksFound > marks) 'marks_found_not_removed': marksFound - marks,
      'skipped': skipped,
      'assets': assets,
    };
  }

  /// Assets addressed by {ids?: ["lib:…"], kit?: id or name, all?: true}.
  static List<LibraryAsset> _pick(AssetLibrary lib, Map<String, dynamic> a) {
    final out = <LibraryAsset>[];
    final ids = a['ids'] ?? a['id'];
    for (final id in ids is List ? ids : (ids == null ? const [] : [ids])) {
      final x = lib.byId('$id');
      if (x == null) throw ArgumentError('No library asset "$id"');
      out.add(x);
    }
    final kit = _kit(lib, a['kit']);
    if (a['kit'] != null && kit == null) throw ArgumentError('No kit "${a['kit']}"');
    if (kit != null) {
      for (final id in kit.assetIds) {
        final x = lib.byId(id);
        if (x != null && !out.contains(x)) out.add(x);
      }
    }
    if (a['all'] == true) {
      for (final x in lib.assets) {
        if (!out.contains(x)) out.add(x);
      }
    }
    return out;
  }

  static AssetKit? _kit(AssetLibrary lib, Object? v) {
    if (v == null) return null;
    final s = '$v'.trim().toLowerCase();
    return lib.kits.where((k) => k.id.toLowerCase() == s || k.name.toLowerCase() == s).firstOrNull;
  }

  /// `clean_assets` {ids? | kit? | all?, green_screen?: auto|true|false
  /// (default auto), remove_mark?: true, restore?: true} — keys flat screens
  /// to alpha PNGs and removes the corner sparkle, batch; the original file
  /// is kept (restore: true goes back to it).
  static Future<Map<String, dynamic>> clean(AssetLibrary lib, Map<String, dynamic> a, {void Function(String status)? status}) async {
    final todo = _pick(lib, a).where((x) => x.type == MediaType.image).toList();
    if (todo.isEmpty) throw ArgumentError('clean: give "ids", "kit" or all:true (images only)');
    final sep = Platform.pathSeparator;
    final gs = _gs(a['green_screen']);
    final removeMark = a['remove_mark'] != false;
    final restore = a['restore'] == true;
    final results = <Map<String, dynamic>>[];
    var changed = 0;
    for (int i = 0; i < todo.length; i++) {
      final x = todo[i];
      status?.call('Cleaning ${i + 1}/${todo.length}: ${x.name}');
      final r = <String, dynamic>{'id': 'lib:${x.id}', 'name': x.name};
      try {
        if (restore) {
          if (x.original.isNotEmpty && await File('${lib.filesDir.path}$sep${x.original}').exists()) {
            final cur = x.file;
            x.file = x.original;
            x.original = '';
            x.cleaned = [];
            x.transparent = !x.file.toLowerCase().endsWith('.jpg') && !x.file.toLowerCase().endsWith('.jpeg') &&
                fileHasAlpha(await File(lib.pathOf(x)).openRead(0, 64 * 1024).fold<List<int>>([], (p, e) => p..addAll(e)));
            try {
              await File('${lib.filesDir.path}$sep$cur').delete();
            } catch (_) {}
            r['restored'] = true;
            changed++;
          } else {
            r['restored'] = false;
          }
          results.add(r);
          continue;
        }
        // Always clean from the untouched original.
        final src = x.original.isNotEmpty ? '${lib.filesDir.path}$sep${x.original}' : lib.pathOf(x);
        final base = '${lib.filesDir.path}$sep${x.id}_clean${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
        final o = await _process(CleanJob(src, base, greenScreen: gs, removeMark: removeMark));
        if (o.error.isNotEmpty) throw FormatException(o.error);
        r.addAll(o.toJson());
        if (o.output.isNotEmpty) {
          final old = x.file;
          if (x.original.isEmpty) {
            x.original = old; // keep the original
          } else if (old != x.original) {
            try {
              await File('${lib.filesDir.path}$sep$old').delete();
            } catch (_) {}
          }
          x.file = o.output.split(RegExp(r'[\\/]')).last;
          x.cleaned = o.fixes;
          x.transparent = o.alpha;
          x.width = o.width.toDouble();
          x.height = o.height.toDouble();
          if (o.alpha && !x.tags.contains('cut-out')) x.tags = [...x.tags, 'cut-out'];
          changed++;
          r['cleaned'] = o.fixes;
        } else {
          r['cleaned'] = const [];
        }
      } catch (e) {
        r['error'] = '$e';
      }
      results.add(r);
    }
    await lib.save();
    return {'ok': true, 'changed': changed, 'assets': results};
  }

  /// `search_assets` {query?, role?|roles?, tags?, kit?, type?, transparent?, limit?}
  static Map<String, dynamic> search(AssetLibrary lib, Map<String, dynamic> a) {
    final roles = [..._strs(a['roles']), ..._strs(a['role'])];
    final kit = _kit(lib, a['kit']);
    final type = switch ('${a['type'] ?? ''}') { 'image' => MediaType.image, 'video' => MediaType.video, 'audio' => MediaType.audio, _ => null };
    final limit = ((a['limit'] as num?) ?? 30).round().clamp(1, 100);
    final hits = smartSearch(lib.assets, '${a['query'] ?? ''}',
        roles: roles, tags: _strs(a['tags']), type: type, transparent: a['transparent'] is bool ? a['transparent'] as bool : null,
        only: kit?.assetIds.toSet(), limit: limit);
    return {'total': hits.length, 'assets': [for (final h in hits) h.toJson()]};
  }

  /// `suggest_assets` {brief, roles?: [character, object, plate, overlay, set_piece], kit?, limit? (per role, default 5)}
  static Map<String, dynamic> suggest(AssetLibrary lib, Map<String, dynamic> a) {
    final brief = '${a['brief'] ?? ''}';
    if (brief.trim().isEmpty) throw ArgumentError('suggest_assets needs "brief" (what the shot shows)');
    final kit = _kit(lib, a['kit']);
    final limit = ((a['limit'] as num?) ?? 5).round().clamp(1, 30);
    final res = suggestAssets(lib.assets, brief, roles: _strs(a['roles']), limit: limit, only: kit?.assetIds.toSet());
    return {
      'brief': brief,
      'terms': AssetRoles.terms(brief),
      'roles': {for (final e in res.entries) e.key: [for (final h in e.value) h.toJson()]},
    };
  }
}
