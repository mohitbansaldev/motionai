import 'dart:collection';

import 'package:vector_math/vector_math_64.dart';

import '../model/layer.dart';
import '../model/project.dart';
import 'evaluator.dart';

/// Deepest allowed nesting of compositions (main = level 1).
const int kMaxPrecompDepth = 8;

/// A precomp problem: a comp that contains itself, or nesting deeper than
/// [kMaxPrecompDepth].
class PrecompError implements Exception {
  final String message;
  PrecompError(this.message);
  @override
  String toString() => 'PrecompError: $message';
}

/// One leaf layer of a nested render, with its matrix all the way to the
/// screen of the outermost composition.
class FlatItem {
  final RenderItem item;

  /// Layer-local pixels → outer composition pixels (may contain perspective).
  final Matrix4 matrix;

  /// Opacity including every enclosing comp layer (0..1).
  final double opacity;

  /// Comp ids from the outer comp down to the one holding this layer.
  final List<String> path;

  FlatItem(this.item, this.matrix, this.opacity, this.path);

  Layer get layer => item.layer;

  Vector2 project(double x, double y) => projectPoint(matrix, x, y);

  /// TL, TR, BR, BL on the outer comp's screen.
  List<Vector2> corners() => [
        project(0, 0),
        project(layer.width, 0),
        project(layer.width, layer.height),
        project(0, layer.height),
      ];
}

/// Nested compositions (precomps): time mapping, cycle checks, evaluation
/// with a small per-frame cache, and flattening (tests / hit-testing /
/// export helpers).
///
/// A comp layer (`LayerType.comp`, `Layer.compId`) shows its child comp at
/// child time `sourceIn + (t - start) * speed` (wrapped when `loop`), with the
/// child's own camera; the renderer draws that as one sub-canvas so every
/// effect, mask, matte and 3D transform of the comp layer applies to it.
class Precomp {
  /// Bumped on every edit (commands, undo, media changes) so cached child
  /// renders are never stale.
  static int revision = 0;
  static void touch() {
    revision++;
    _cache.clear();
  }

  static final LinkedHashMap<String, List<RenderItem>> _cache = LinkedHashMap();
  static const int _cacheSize = 48;

  /// Child comp shown by comp layer [l], or null.
  static Composition? childOf(Project p, Layer l) {
    final id = l.compId;
    if (l.type != LayerType.comp || id == null) return null;
    return p.compById(id);
  }

  /// Child-comp time shown by comp layer [l] at parent time [t]; null when
  /// it falls outside the child's duration (and the layer does not loop).
  static double? childTime(Layer l, Composition child, double t) {
    var ct = l.sourceIn + (t - l.start) * l.speed;
    final d = child.duration;
    if (l.loop && d > 0) {
      ct = ct % d;
      if (ct < 0) ct += d;
      return ct;
    }
    if (ct < -1e-9 || ct > d + 1e-9) return null;
    return ct.clamp(0.0, d).toDouble();
  }

  /// Evaluates [comp] at [t], cached per (comp object, time, edit revision).
  static List<RenderItem> evaluateCached(Composition comp, double t) {
    final key = '${identityHashCode(comp)}|$revision|$t';
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit; // most recent last
      return hit;
    }
    final items = Evaluator.evaluate(comp, t);
    _cache[key] = items;
    while (_cache.length > _cacheSize) {
      _cache.remove(_cache.keys.first);
    }
    return items;
  }

  /// Ids of comps referenced directly by comp layers of [c].
  static Iterable<String> directChildren(Composition c) sync* {
    for (final l in c.layers) {
      if (l.type == LayerType.comp && l.compId != null) yield l.compId!;
    }
  }

  /// True if [fromId] (or anything nested in it) shows comp [targetId].
  static bool reaches(Project p, String fromId, String targetId) {
    final seen = <String>{};
    final todo = <String>[fromId];
    while (todo.isNotEmpty) {
      final id = todo.removeLast();
      final c = p.compById(id);
      if (c == null || !seen.add(c.id)) continue;
      for (final k in directChildren(c)) {
        final kc = p.compById(k);
        if (kc == null) continue;
        if (kc.id == targetId || k == targetId) return true;
        todo.add(kc.id);
      }
    }
    return false;
  }

  /// Throws if putting comp [childId] inside comp [hostId] would make a loop
  /// or nest deeper than [kMaxPrecompDepth].
  static void checkCanNest(Project p, String hostId, String childId) {
    final host = p.compById(hostId), child = p.compById(childId);
    if (host == null || child == null) throw PrecompError('No comp "${host == null ? hostId : childId}"');
    if (host.id == child.id) throw PrecompError('A comp cannot contain itself ("${child.name}")');
    if (reaches(p, child.id, host.id)) {
      throw PrecompError('Comp "${child.name}" already contains "${host.name}" — nesting it would make a loop');
    }
    final depth = levelsAbove(p, host.id) + levelsBelow(p, child.id);
    if (depth > kMaxPrecompDepth) throw PrecompError('Nesting too deep ($depth levels, max $kMaxPrecompDepth)');
  }

  /// Nesting levels from [id] down (1 = no nested comps).
  static int levelsBelow(Project p, String id, [Set<String>? stack]) {
    final c = p.compById(id);
    if (c == null) return 0;
    final st = stack ?? <String>{};
    if (!st.add(c.id) || st.length > kMaxPrecompDepth * 2) return 1;
    var best = 0;
    for (final k in directChildren(c).toSet()) {
      final d = levelsBelow(p, k, st);
      if (d > best) best = d;
    }
    st.remove(c.id);
    return 1 + best;
  }

  /// Longest chain of comps above [id] (main = 1, a comp only in main = 2).
  static int levelsAbove(Project p, String id) {
    final target = p.compById(id);
    if (target == null || target.id == p.main.id) return 1;
    var best = 0;
    void walk(Composition c, int level, Set<String> stack) {
      if (!stack.add(c.id) || level > kMaxPrecompDepth * 2) return;
      for (final k in directChildren(c).toSet()) {
        final kc = p.compById(k);
        if (kc == null) continue;
        if (kc.id == target.id) {
          if (level + 1 > best) best = level + 1;
        } else {
          walk(kc, level + 1, stack);
        }
      }
      stack.remove(c.id);
    }

    walk(p.main, 1, <String>{});
    // A comp not used anywhere (opened on its own) is its own root.
    return best == 0 ? 1 : best;
  }

  /// Checks the whole project; returns one message per problem.
  static List<String> validate(Project p) {
    final out = <String>[];
    for (final c in [p.main, ...p.comps.values]) {
      if (reaches(p, c.id, c.id)) out.add('Comp "${c.name}" (${c.id}) contains itself');
    }
    final d = levelsBelow(p, p.main.id);
    if (d > kMaxPrecompDepth) out.add('Nesting too deep ($d levels, max $kMaxPrecompDepth)');
    return out;
  }

  /// Every leaf layer visible at [t] in [comp] with nested comps expanded, in
  /// paint order, matrices relative to [comp]'s screen. Throws [PrecompError]
  /// on a loop or nesting deeper than [kMaxPrecompDepth].
  static List<FlatItem> flatten(Project p, Composition comp, double t,
      {Matrix4? outer, double opacity = 1, List<String> stack = const []}) {
    final path = [...stack, comp.id];
    if (path.length > kMaxPrecompDepth) throw PrecompError('Nesting deeper than $kMaxPrecompDepth levels');
    final out = <FlatItem>[];
    for (final item in evaluateCached(comp, t)) {
      final m = outer == null ? item.matrix.clone() : outer.multiplied(item.matrix);
      final op = opacity * item.opacity;
      if (item.layer.type == LayerType.comp) {
        final child = childOf(p, item.layer);
        if (child == null) continue;
        if (path.contains(child.id)) throw PrecompError('Comp "${child.name}" contains itself');
        final ct = childTime(item.layer, child, t);
        if (ct == null) continue;
        out.addAll(flatten(p, child, ct, outer: m, opacity: op, stack: path));
      } else {
        out.add(FlatItem(item, m, op, path));
      }
    }
    return out;
  }

  /// Video/audio layers inside nested comps that play at [t], with the time
  /// of their own comp (so `layer.sourceTimeAt(compTime)` is the media time).
  /// For export / the video pool: layers of [root] itself (default main) are
  /// not included.
  static List<({Layer layer, double compTime, List<String> path})> nestedMedia(Project p, double t, {Composition? root}) {
    final out = <({Layer layer, double compTime, List<String> path})>[];
    void walk(Composition c, double ct, List<String> stack) {
      final path = [...stack, c.id];
      if (path.length > kMaxPrecompDepth) return;
      for (final l in c.layers) {
        if (!l.isActiveAt(ct)) continue;
        if (l.type == LayerType.comp) {
          final child = childOf(p, l);
          if (child == null || path.contains(child.id)) continue;
          final cct = childTime(l, child, ct);
          if (cct != null) walk(child, cct, path);
        } else if (stack.isNotEmpty && (l.type == LayerType.video || l.type == LayerType.audio)) {
          out.add((layer: l, compTime: ct, path: path));
        }
      }
    }

    walk(root ?? p.main, t, const []);
    return out;
  }

  /// Comp layers (in any comp) that show comp [id].
  static List<(Composition, Layer)> usersOf(Project p, String id) => [
        for (final c in [p.main, ...p.comps.values])
          for (final l in c.layers)
            if (l.type == LayerType.comp && l.compId != null && p.compById(l.compId!)?.id == id) (c, l),
      ];

  /// Path of comp ids from main down to [id] (breadcrumbs), or null.
  static List<String>? pathTo(Project p, String id) {
    final target = p.compById(id);
    if (target == null) return null;
    if (target.id == p.main.id) return [p.main.id];
    final prev = <String, String>{};
    final q = Queue<String>()..add(p.main.id);
    final seen = <String>{p.main.id};
    while (q.isNotEmpty) {
      final cur = q.removeFirst();
      final c = p.compById(cur);
      if (c == null) continue;
      for (final k in directChildren(c)) {
        final kc = p.compById(k);
        if (kc == null || !seen.add(kc.id)) continue;
        prev[kc.id] = cur;
        if (kc.id == target.id) {
          final out = <String>[kc.id];
          var x = cur;
          while (true) {
            out.insert(0, x);
            final px = prev[x];
            if (px == null) break;
            x = px;
          }
          return out;
        }
        q.add(kc.id);
      }
    }
    return [p.main.id, target.id]; // not used anywhere yet
  }
}
