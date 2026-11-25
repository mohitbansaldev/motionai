// V2-F: roles, file-name tagging and smart (fuzzy, role-aware) search for
// the asset library, used by folder import, the Director and the MCP tools.
// Pure Dart, no network.
import 'dart:math' as math;

import '../core/model/project.dart';
import 'asset_library.dart';

/// What an asset is used for in a shot.
const assetRoles = ['character', 'object', 'plate', 'overlay', 'set_piece', 'audio'];

/// Role + kind + tags guessed from a file name prefix / folder.
class RoleGuess {
  final String role, kind;
  final List<String> tags;
  const RoleGuess(this.role, this.kind, this.tags);
}

class AssetRoles {
  /// File name prefixes (Google Flow kit convention: char_*, prop_*, …).
  static const prefixes = <String, RoleGuess>{
    'char': RoleGuess('character', 'person', ['character', 'person']),
    'character': RoleGuess('character', 'person', ['character', 'person']),
    'person': RoleGuess('character', 'person', ['character', 'person']),
    'animal': RoleGuess('character', 'animal', ['character', 'animal']),
    'prop': RoleGuess('object', 'prop', ['object', 'prop']),
    'obj': RoleGuess('object', 'prop', ['object', 'prop']),
    'object': RoleGuess('object', 'prop', ['object', 'prop']),
    'plate': RoleGuess('plate', 'plate', ['background', 'plate']),
    'bg': RoleGuess('plate', 'plate', ['background', 'plate']),
    'background': RoleGuess('plate', 'plate', ['background', 'plate']),
    'fx': RoleGuess('overlay', 'overlay', ['overlay', 'fx']),
    'overlay': RoleGuess('overlay', 'overlay', ['overlay', 'fx']),
    'cut': RoleGuess('set_piece', 'set_piece', ['cut-out', 'set piece']),
    'set': RoleGuess('set_piece', 'set_piece', ['cut-out', 'set piece']),
  };

  /// Folder names → role (cutouts/ only says "has alpha": no role).
  static const folders = <String, String>{
    'chars': 'char', 'characters': 'char', 'people': 'char', 'persons': 'char',
    'props': 'prop', 'objects': 'prop',
    'plates': 'plate', 'backgrounds': 'plate', 'bg': 'plate', 'bgs': 'plate',
    'fx': 'fx', 'overlays': 'fx', 'effects': 'fx',
    'sets': 'cut', 'set_pieces': 'cut',
  };

  /// Kind → role for assets tagged by hand or by the AI.
  static const kindRoles = {
    'person': 'character', 'animal': 'character',
    'prop': 'object', 'vehicle': 'object', 'icon': 'object', 'logo': 'object', 'document': 'object', 'plant': 'object',
    'sky': 'plate', 'ground': 'plate', 'interior': 'plate', 'map': 'plate', 'texture': 'plate', 'plate': 'plate',
    'overlay': 'overlay',
    'building': 'set_piece', 'grass_strip': 'set_piece', 'set_piece': 'set_piece',
  };

  /// Words people (and Claude) use for a role.
  static const synonyms = {
    'character': 'character', 'characters': 'character', 'char': 'character', 'person': 'character', 'people': 'character',
    'human': 'character', 'subject': 'character', 'figure': 'character',
    'object': 'object', 'objects': 'object', 'prop': 'object', 'props': 'object', 'item': 'object', 'obj': 'object',
    'plate': 'plate', 'plates': 'plate', 'background': 'plate', 'backgrounds': 'plate', 'bg': 'plate', 'backdrop': 'plate', 'scene': 'plate', 'environment': 'plate',
    'overlay': 'overlay', 'overlays': 'overlay', 'fx': 'overlay', 'effect': 'overlay', 'effects': 'overlay',
    'set_piece': 'set_piece', 'set piece': 'set_piece', 'setpiece': 'set_piece', 'cut': 'set_piece', 'cutout': 'set_piece', 'cut-out': 'set_piece', 'cut_out': 'set_piece',
    'audio': 'audio', 'sound': 'audio', 'music': 'audio', 'sfx': 'audio',
  };

  /// Canonical role for a word ("background" → plate), or null.
  static String? normalize(String? word) {
    if (word == null) return null;
    final k = word.trim().toLowerCase();
    return synonyms[k] ?? synonyms[k.replaceAll(' ', '_')];
  }

  /// Role of a library asset (kind first, then tags, then media type).
  static String roleOf(LibraryAsset a) {
    if (a.type == MediaType.audio) return 'audio';
    final r = kindRoles[a.kind];
    if (r != null) return r;
    for (final t in a.tags) {
      final n = normalize(t);
      if (n != null) return n;
    }
    return '';
  }

  /// Guess from a relative path like "cutouts/char_merchant.png".
  static RoleGuess? guess(String relPath) {
    final parts = relPath.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    final stem = _stem(parts.last).toLowerCase();
    final m = RegExp(r'^([a-z]+)[_\- ]').firstMatch(stem);
    if (m != null) {
      final g = prefixes[m.group(1)];
      if (g != null) return g;
    }
    for (final dir in parts.reversed.skip(1)) {
      final p = folders[dir.toLowerCase()];
      if (p != null) return prefixes[p];
    }
    return null;
  }

  static String _stem(String base) => base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base;

  /// Words of a file name as tags: "char_dutch_merchant_02" → [dutch, merchant].
  static List<String> nameTags(String fileName) {
    final stem = _stem(fileName.split(RegExp(r'[\\/]')).last).toLowerCase();
    final words = stem.split(RegExp(r'[^a-z0-9ऀ-ॿ]+')).where((w) => w.isNotEmpty).toList();
    if (words.isNotEmpty && prefixes.containsKey(words.first)) words.removeAt(0);
    return [
      for (final w in words)
        if (w.length >= 3 && !RegExp(r'^\d+$').hasMatch(w) && !_variantWords.contains(w) && !_stop.contains(w)) w,
    ];
  }

  static const _variantWords = {'green', 'greenscreen', 'gs', 'chroma', 'clean', 'alpha', 'nobg', 'cutout', 'png', 'jpg', 'final', 'copy', 'v1', 'v2', 'v3'};

  /// Same-picture key for "char_x.jpg" (green screen) vs "char_x.png" (clean)
  /// and "char_x_green.jpg" vs "char_x_clean.png".
  static String variantKey(String fileName) {
    var stem = _stem(fileName.split(RegExp(r'[\\/]')).last).toLowerCase();
    stem = stem.replaceAll(RegExp(r'([_\- ](green ?screen|greenscreen|green|gs|chroma|clean|alpha|nobg|cutout|cut_out))+$'), '');
    return stem;
  }

  // ------------------------------------------------------------ search

  static const _stop = {
    'the', 'a', 'an', 'of', 'and', 'or', 'with', 'in', 'on', 'at', 'to', 'for', 'from', 'by', 'is', 'are', 'was', 'his', 'her', 'their', 'its',
    'this', 'that', 'into', 'over', 'under', 'shot', 'frame', 'show', 'showing', 'some', 'very', 'then', 'while',
    'ka', 'ki', 'ke', 'hai', 'aur', 'se', 'mein', 'me', 'ko', 'ne', 'par', 'ek', 'tha', 'thi',
  };

  /// Lower-case search words of [text] (Unicode letters/digits, stop words
  /// dropped, simple plural → singular).
  static List<String> terms(String text) {
    final out = <String>[];
    for (var w in text.toLowerCase().split(RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true))) {
      if (w.isEmpty || _stop.contains(w)) continue;
      if (w.length > 4 && w.endsWith('ies')) {
        w = '${w.substring(0, w.length - 3)}y';
      } else if (w.length > 3 && w.endsWith('s') && !w.endsWith('ss')) {
        w = w.substring(0, w.length - 1);
      }
      if (!out.contains(w)) out.add(w);
    }
    return out;
  }

  /// Levenshtein distance, giving up above [max].
  static int distance(String a, String b, {int max = 3}) {
    if ((a.length - b.length).abs() > max) return max + 1;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (int i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
      var rowMin = cur[0];
      for (int j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
        rowMin = math.min(rowMin, cur[j]);
      }
      if (rowMin > max) return max + 1;
      prev = cur;
    }
    return prev[b.length];
  }

  static bool _fuzzy(String term, String word) {
    if (term.length < 4 || word.length < 4) return false;
    final max = term.length >= 7 ? 2 : 1;
    return distance(term, word, max: max) <= max;
  }

  /// How well [a] matches [terms] (0 = not at all) and why.
  static (double, List<String>) score(LibraryAsset a, List<String> terms) {
    final nameWords = terms0(a.name);
    final descWords = terms0(a.description);
    final tagWords = {for (final t in a.tags) ...terms0(t)};
    final kind = a.kind.replaceAll('_', ' ');
    final role = roleOf(a);
    var total = 0.0;
    final why = <String>[];
    for (final t in terms) {
      var s = 0.0;
      var reason = '';
      void hit(double v, String r) {
        if (v > s) {
          s = v;
          reason = r;
        }
      }

      if (a.tags.contains(t) || tagWords.contains(t)) hit(4, 'tag:$t');
      if (nameWords.contains(t)) hit(3.5, 'name:$t');
      if (kind == t || a.kind == t) hit(3, 'kind:$t');
      if (normalize(t) != null && normalize(t) == role) hit(2.5, 'role:$role');
      if (t.length >= 3 && (nameWords.any((w) => w.startsWith(t)) || tagWords.any((w) => w.startsWith(t)))) hit(2.5, 'prefix:$t');
      if (a.region.toLowerCase().contains(t) || a.era.toLowerCase().contains(t) || a.mood.toLowerCase().contains(t)) hit(2, 'about:$t');
      if (s < 2) {
        for (final w in [...nameWords, ...tagWords]) {
          if (_fuzzy(t, w)) {
            hit(2, 'fuzzy:$t~$w');
            break;
          }
        }
      }
      if (descWords.contains(t)) hit(1.5, 'desc:$t');
      if (s == 0 && t.length >= 4 && a.description.toLowerCase().contains(t)) hit(0.8, 'desc~$t');
      if (s > 0) {
        total += s;
        why.add(reason);
      }
    }
    return (total, why);
  }

  /// Words of a name / description without plural folding of the stop list.
  static List<String> terms0(String text) => terms(text.replaceAll('_', ' '));
}

/// One ranked search / suggest hit.
class AssetHit {
  final LibraryAsset asset;
  final double score;
  final List<String> why;
  const AssetHit(this.asset, this.score, this.why);

  Map<String, dynamic> toJson() => {
        'id': 'lib:${asset.id}',
        'name': asset.name,
        'type': asset.type.name,
        if (AssetRoles.roleOf(asset).isNotEmpty) 'role': AssetRoles.roleOf(asset),
        if (asset.kind.isNotEmpty) 'kind': asset.kind,
        if (asset.tags.isNotEmpty) 'tags': asset.tags,
        if (asset.description.isNotEmpty) 'description': asset.description,
        if (asset.transparent) 'transparent': true,
        if (asset.cleaned.isNotEmpty) 'cleaned': asset.cleaned,
        'size': [asset.width.round(), asset.height.round()],
        if (asset.duration > 0) 'duration': double.parse(asset.duration.toStringAsFixed(2)),
        'score': double.parse(score.toStringAsFixed(2)),
        if (why.isNotEmpty) 'why': why,
      };
}

/// Smart library search: role / tag / type filters plus soft, fuzzy word
/// scoring (not every word has to match). Empty query → newest first.
List<AssetHit> smartSearch(Iterable<LibraryAsset> all, String query,
    {Iterable<String>? roles, Iterable<String>? tags, MediaType? type, bool? transparent, Set<String>? only, int limit = 30}) {
  final roleSet = {for (final r in roles ?? const <String>[]) ?AssetRoles.normalize(r)};
  final tagSet = {for (final t in tags ?? const <String>[]) t.trim().toLowerCase()}..remove('');
  final terms = AssetRoles.terms(query);
  final hits = <AssetHit>[];
  for (final a in all) {
    if (only != null && !only.contains(a.id)) continue;
    if (type != null && a.type != type) continue;
    if (transparent != null && a.transparent != transparent) continue;
    if (roleSet.isNotEmpty && !roleSet.contains(AssetRoles.roleOf(a))) continue;
    if (tagSet.isNotEmpty && !tagSet.every((t) => a.tags.contains(t))) continue;
    if (terms.isEmpty) {
      hits.add(AssetHit(a, 0, const []));
      continue;
    }
    final (s, why) = AssetRoles.score(a, terms);
    if (s > 0) hits.add(AssetHit(a, s, why));
  }
  hits.sort((x, y) {
    final c = y.score.compareTo(x.score);
    return c != 0 ? c : y.asset.added.compareTo(x.asset.added);
  });
  return hits.take(limit).toList();
}

/// Ranked assets for a shot [brief] ("dutch merchant counting tulip bulbs
/// in a 1630s market") per role. Cut-outs get a small bonus for character /
/// object / set-piece roles. A role with no keyword match falls back to its
/// newest assets (score 0) so the Director always sees what exists.
Map<String, List<AssetHit>> suggestAssets(Iterable<LibraryAsset> all, String brief, {Iterable<String>? roles, int limit = 5, Set<String>? only}) {
  final terms = AssetRoles.terms(brief);
  var wanted = [for (final r in roles ?? const <String>[]) ?AssetRoles.normalize(r)];
  if (wanted.isEmpty) wanted = ['character', 'object', 'set_piece', 'plate', 'overlay'];
  final out = <String, List<AssetHit>>{};
  for (final role in wanted.toSet()) {
    final pool = [
      for (final a in all)
        if ((only == null || only.contains(a.id)) && AssetRoles.roleOf(a) == role) a,
    ];
    final hits = <AssetHit>[];
    for (final a in pool) {
      var (s, why) = AssetRoles.score(a, terms);
      if (s > 0 && a.transparent && (role == 'character' || role == 'object' || role == 'set_piece')) s += 0.5;
      if (s > 0) hits.add(AssetHit(a, s, why));
    }
    hits.sort((x, y) {
      final c = y.score.compareTo(x.score);
      return c != 0 ? c : y.asset.added.compareTo(x.asset.added);
    });
    if (hits.isEmpty) {
      pool.sort((x, y) => y.added.compareTo(x.added));
      hits.addAll([for (final a in pool.take(limit)) AssetHit(a, 0, const ['no keyword match: newest'])]);
    }
    out[role] = hits.take(limit).toList();
  }
  return out;
}
