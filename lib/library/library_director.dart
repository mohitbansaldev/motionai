import '../core/model/project.dart';
import 'asset_library.dart';

/// Lets the Director pick assets from the cross-project library: they are
/// listed as `lib:<id>` media and imported into the project when used.
class LibraryDirector {
  /// Opens the shared library (call before planning; never throws).
  static Future<void> warmUp() async {
    try {
      await AssetLibrary.shared();
    } catch (_) {}
  }

  /// Extra entries for the Director's media list (empty if the library isn't open).
  static List<Map<String, dynamic>> mediaEntries(Project p, {int limit = 60}) {
    try {
      return AssetLibrary.loaded?.directorEntries(exclude: p, limit: limit) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// Every `lib:<id>` string inside [values] (nested maps/lists).
  static Set<String> libraryRefs(Object? values) {
    final out = <String>{};
    void walk(Object? v) {
      if (v is String && v.startsWith('lib:')) out.add(v);
      if (v is Map) v.values.forEach(walk);
      if (v is List) v.forEach(walk);
    }

    walk(values);
    return out;
  }

  /// Replaces `lib:<id>` strings inside [values] (mutable maps/lists) using [ids].
  static void replaceRefs(Object? values, Map<String, String> ids) {
    if (values is Map) {
      for (final k in values.keys.toList()) {
        final v = values[k];
        if (v is String && ids.containsKey(v)) {
          values[k] = ids[v];
        } else {
          replaceRefs(v, ids);
        }
      }
    } else if (values is List) {
      for (int i = 0; i < values.length; i++) {
        final v = values[i];
        if (v is String && ids.containsKey(v)) {
          values[i] = ids[v];
        } else {
          replaceRefs(v, ids);
        }
      }
    }
  }

  /// Imports the library assets the storyboard uses and rewrites their ids
  /// to project media ids. Unknown ids are dropped from lists / removed.
  static Future<int> importUsed(Project p, List<Map<String, dynamic>> visuals, String mediaDir, {AssetLibrary? library}) async {
    final refs = libraryRefs(visuals);
    if (refs.isEmpty) return 0;
    final lib = library ?? AssetLibrary.loaded ?? await AssetLibrary.shared();
    final ids = <String, String>{};
    for (final r in refs) {
      try {
        ids[r] = (await lib.importInto(p, r, mediaDir: mediaDir)).id;
      } catch (_) {
        // Missing file: leave the reference out.
      }
    }
    replaceRefs(visuals, ids);
    _dropUnresolved(visuals);
    return ids.length;
  }

  static void _dropUnresolved(Object? v) {
    if (v is Map) {
      v.removeWhere((k, x) => x is String && x.startsWith('lib:'));
      v.values.forEach(_dropUnresolved);
    } else if (v is List) {
      v.removeWhere((x) => x is String && x.startsWith('lib:'));
      v.forEach(_dropUnresolved);
    }
  }
}
