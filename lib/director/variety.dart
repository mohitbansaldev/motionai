import 'dart:math' as math;

import '../core/model/project.dart';
import 'capabilities.dart';
import 'story_builder.dart';

/// The photos/videos a storyboard can draw from, with the ones that have a
/// cut-out (depth shots). Picks replacements deterministically.
class MediaPool {
  final Project p;
  final Set<String> cutouts;
  MediaPool(this.p, {Set<String>? cutouts}) : cutouts = cutouts ?? {};

  static const _notBroll = ['[screenshot', '[logo', '[document', '[newspaper', '[chart', '[graphic', '[map'];

  static bool usable(MediaAsset m) =>
      m.type != MediaType.audio &&
      !m.name.endsWith('(subject)') &&
      !m.name.endsWith('(background)') &&
      !m.name.startsWith('SFX ') &&
      !m.name.startsWith('Voice ');

  /// Media that make good generic B-roll (not screenshots, logos, charts…).
  List<MediaAsset> get broll => [
        for (final m in p.media.values)
          if (usable(m) && !_notBroll.any((k) => m.description.startsWith(k))) m,
      ];

  static final _split = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
  static Set<String> words(String s) => {for (final w in s.toLowerCase().split(_split)) if (w.length >= 3) w};

  /// The best stand-in for [line]: not in [avoid], used fewer than [maxUses]
  /// times, preferring [type], then words shared with the line, then the
  /// least used, then import order.
  String? pick(String line, {Set<String> avoid = const {}, Map<String, int> uses = const {}, int maxUses = 1 << 20, MediaType? type}) {
    final lw = words(line);
    String? best;
    var bestScore = -1e9;
    for (final m in broll) {
      if (avoid.contains(m.id) || (uses[m.id] ?? 0) >= maxUses) continue;
      final overlap = words('${m.description} ${m.name}').intersection(lw).length;
      final score = (type == null || m.type == type ? 4.0 : 0.0) + overlap * 3.0 - (uses[m.id] ?? 0) * 2.0;
      if (score > bestScore) {
        bestScore = score;
        best = m.id;
      }
    }
    return best;
  }
}

class VarietyIssue {
  final int beat; // index into the kept, time-sorted beats (-1 = whole video)
  final String rule;
  final String detail;
  const VarietyIssue(this.beat, this.rule, this.detail);
  @override
  String toString() => '$rule@$beat: $detail';
}

class VarietyReport {
  final double score; // 0..100
  final List<VarietyIssue> issues;
  final Map<String, int> mix; // visual kind → beats
  final double presenterShare; // 0..1 of the time on the presenter
  const VarietyReport(this.score, this.issues, this.mix, this.presenterShare);
  int count(String rule) => issues.where((i) => i.rule == rule).length;
}

/// Visual variety: scores a storyboard for repeats (the same component type,
/// media or camera move within a few beats, the same transition twice,
/// overused photos, one component dominating) and repairs it
/// deterministically before the build.
class Variety {
  final int window; // beats in which a component type / move should not repeat
  final int mediaWindow; // beats in which a photo should not come back
  final int maxMediaUses;
  const Variety({this.window = 4, this.mediaWindow = 8, this.maxMediaUses = 3});

  static String kind(Map<String, dynamic> v) {
    if (v['aroll'] == true) return 'aroll';
    if (v['component'] is String) return '${v['component']}';
    return v['media'] != null ? 'media' : 'none';
  }

  static String? mediaOf(Map<String, dynamic> v) {
    final m = v['media'];
    if (m is String) return m;
    if (m is List && m.isNotEmpty) return '${m.first}';
    return null;
  }

  static String moveOf(Map<String, dynamic> v) => v['move'] is String ? '${v['move']}' : 'ken_burns';
  static String transitionOf(Map<String, dynamic> v) => v['transition'] is String ? '${v['transition']}' : 'fade';

  /// Same type twice in a row is fine for maps that move to another place.
  static bool _sameShot(Map<String, dynamic> a, Map<String, dynamic> b) {
    final k = kind(a);
    if (k != kind(b)) return false;
    if (k == 'map') return '${a['focus']}${a['countries']}' == '${b['focus']}${b['countries']}';
    return true;
  }

  static List<Beat> _sorted(List<Beat> beats) => beats.where((b) => b.keep).toList()..sort((a, b) => a.start.compareTo(b.start));

  VarietyReport score(List<Beat> beats, {bool presenter = false}) {
    final kept = _sorted(beats);
    final issues = <VarietyIssue>[];
    var penalty = 0.0;
    final uses = <String, int>{};
    final mix = <String, int>{};
    final shots = <int>[]; // indices of non-presenter beats so far
    var arollTime = 0.0, total = 0.0;
    void add(int i, String rule, String detail, double p) {
      issues.add(VarietyIssue(i, rule, detail));
      penalty += p;
    }

    for (int i = 0; i < kept.length; i++) {
      final b = kept[i];
      final v = b.visual;
      final k = kind(v);
      total += b.length;
      mix[k] = (mix[k] ?? 0) + 1;
      if (k == 'aroll') {
        arollTime += b.length;
        continue;
      }
      final recent = shots.reversed.take(window).toList();
      final prev = shots.isEmpty ? null : kept[shots.last];
      if (k != 'media' && prev != null && _sameShot(prev.visual, v) && b.role != 'card') {
        add(i, 'same_kind_adjacent', k, 4);
      } else if (k != 'media' && recent.skip(1).any((j) => kind(kept[j].visual) == k) && !_cards.contains(k) && k != 'map') {
        add(i, 'component_repeat', k, 1.5);
      }
      final m = mediaOf(v);
      if (m != null) {
        uses[m] = (uses[m] ?? 0) + 1;
        if (uses[m]! > maxMediaUses) add(i, 'media_overuse', m, 3);
        final back = shots.reversed.take(mediaWindow);
        if (back.any((j) => mediaOf(kept[j].visual) == m && !(b.lineIndex >= 0 && kept[j].lineIndex == b.lineIndex))) {
          add(i, 'media_repeat', m, 4);
        }
      }
      if (k == 'media') {
        final mv = moveOf(v);
        if (recent.any((j) => kind(kept[j].visual) == 'media' && moveOf(kept[j].visual) == mv)) add(i, 'move_repeat', mv, 2);
      }
      final t = transitionOf(v);
      if (t != 'fade' && prev != null && transitionOf(prev.visual) == t && b.role != 'interrupt') add(i, 'transition_repeat', t, 1);
      shots.add(i);
    }
    final nonAroll = shots.length;
    if (nonAroll >= 8) {
      for (final e in mix.entries) {
        if (e.key == 'media' || e.key == 'aroll' || e.key == 'none') continue;
        if (e.value / nonAroll > 0.25) add(-1, 'mix', '${e.key} on ${e.value}/$nonAroll shots', 6);
      }
    }
    final share = total > 0 ? arollTime / total : 0.0;
    if (presenter && total > 0 && (share < 0.2 || share > 0.45)) add(-1, 'presenter_share', '${(share * 100).round()}%', 8);
    final score = (100 - 100 * penalty / (math.max(1, kept.length) * 3)).clamp(0.0, 100.0).toDouble();
    return VarietyReport(score, issues, mix, share);
  }

  static const _cards = ['title_slam', 'date_title', 'number_tiles'];

  /// Fixes repeats in place, earliest first, so every decision sees the
  /// already-repaired beats before it. Only beats for which [mutable] is true
  /// change (e.g. one chapter being rebuilt). Returns the new score.
  VarietyReport repair(List<Beat> beats, MediaPool pool, {Capabilities? caps, bool presenter = false, bool Function(Beat)? mutable}) {
    final cap = caps ?? Capabilities();
    final kept = _sorted(beats);
    final uses = <String, int>{};
    final shots = <int>[];
    var rot = 0;
    for (int i = 0; i < kept.length; i++) {
      final b = kept[i];
      final k = kind(b.visual);
      if (k == 'aroll') continue;
      final canEdit = mutable == null || mutable(b);
      final recent = shots.reversed.take(window).toList();
      final prev = shots.isEmpty ? null : kept[shots.last];
      if (canEdit) {
        var v = Map<String, dynamic>.from(b.visual);
        // ---------------- components: swap to a sibling visual
        if (k != 'media' && b.role != 'card' && b.role != 'interrupt') {
          final adjacent = prev != null && _sameShot(prev.visual, v) && b.role != 'card';
          final nearby = k == 'glow_word' && recent.skip(1).any((j) => kind(kept[j].visual) == k);
          if (adjacent || nearby) {
            final avoid = {for (final j in shots.reversed.take(mediaWindow)) ?mediaOf(kept[j].visual)};
            final alt = _variant(v, cap, pool, b.line, avoid, uses);
            if (alt != null) v = alt;
          }
        }
        // ---------------- photos / videos
        if (kind(v) == 'media') {
          final m = mediaOf(v);
          final back = shots.reversed.take(mediaWindow).toList();
          final repeated = m != null &&
              (back.any((j) => mediaOf(kept[j].visual) == m && !(b.lineIndex >= 0 && kept[j].lineIndex == b.lineIndex)) ||
                  (uses[m] ?? 0) >= maxMediaUses);
          final personal = v['name_tag'] != null || v['label'] != null;
          if (repeated && !personal) {
            final avoid = {for (final j in back) ?mediaOf(kept[j].visual), m};
            final type = pool.p.media[m]?.type;
            final alt = pool.pick(b.line, avoid: avoid, uses: uses, maxUses: maxMediaUses, type: type);
            if (alt != null) {
              v['media'] = alt;
              if (v['move'] == 'depth' && !pool.cutouts.contains(alt)) v['move'] = 'push_in';
            }
          }
          if (v['move'] != 'depth') v.remove('behind_text');
          final mv = moveOf(v);
          final recentMoves = {for (final j in recent) if (kind(kept[j].visual) == 'media') moveOf(kept[j].visual)};
          final depthNear = mv == 'depth' && shots.reversed.take(6).any((j) => moveOf(kept[j].visual) == 'depth');
          if (recentMoves.contains(mv) || depthNear) {
            final isImage = pool.p.media[mediaOf(v)]?.type == MediaType.image;
            final options = [
              'ken_burns', 'push_in', 'pan_left', 'pull_out', 'pan_right', 'parallax',
              if (cap.has3d && isImage) ...['drift', 'pass_by', 'pull_back'],
            ];
            for (int r = 0; r < options.length; r++) {
              final cand = options[(rot + r) % options.length];
              if (!recentMoves.contains(cand)) {
                v['move'] = cand;
                rot = (rot + r + 1) % options.length;
                break;
              }
            }
          }
        }
        // ---------------- transitions
        final t = transitionOf(v);
        if (t != 'fade' && prev != null && transitionOf(prev.visual) == t && b.role != 'interrupt') v['transition'] = 'fade';
        b.visual = v;
      }
      final m = mediaOf(b.visual);
      if (m != null) uses[m] = (uses[m] ?? 0) + 1;
      shots.add(i);
    }
    return score(beats, presenter: presenter);
  }

  /// A sibling visual that says the same thing differently.
  static Map<String, dynamic>? _variant(
      Map<String, dynamic> v, Capabilities cap, MediaPool pool, String line, Set<String> avoid, Map<String, int> uses) {
    num? number(dynamic x) => x is num ? x : num.tryParse('$x'.replaceAll(RegExp(r'[^0-9.]'), ''));
    final keep = {if (v['sfx'] != null) 'sfx': v['sfx'], if (v['over_aroll'] == true) 'over_aroll': true};
    switch ('${v['component']}') {
      case 'counter':
        final to = number(v['to']);
        if (to == null || !cap.has('number_tiles')) return null;
        final suffix = '${v['suffix'] ?? ''}'.trim();
        return {'component': 'number_tiles', 'text': '${v['prefix'] ?? ''}${to % 1 == 0 ? to.toInt() : to}', if (suffix.isNotEmpty) 'word': suffix.toUpperCase(), ...keep};
      case 'number_tiles':
        final n = number(v['text']);
        if (n == null || !cap.has('counter')) return null;
        final word = '${v['word'] ?? ''}'.trim();
        return {'component': 'counter', 'from': 0, 'to': n, if (word.isNotEmpty) 'suffix': ' $word', ...keep};
      case 'date_title':
        final y = RegExp(r'\d{4}').firstMatch('${v['text']}');
        if (y == null || !cap.has('timeline')) return null;
        final year = int.parse(y.group(0)!);
        final d = year ~/ 10 * 10;
        return {'component': 'timeline', 'from': d - 30, 'to': d + 20, 'marker': year, 'label': '${v['text']}', ...keep};
      case 'timeline':
        final m = v['marker'];
        if (m is! num || !cap.has('date_title')) return null;
        return {'component': 'date_title', 'text': '${m.toInt()}', if (v['label'] is String) 'subtitle': v['label'], ...keep};
      case 'glow_word':
        final n = number(v['text']);
        if (n != null && '${v['text']}'.trim().isNotEmpty && cap.has('number_tiles')) {
          return {'component': 'number_tiles', 'text': '${v['text']}'.trim(), ...keep};
        }
        final alt = pool.pick(line, avoid: avoid, uses: uses, maxUses: 3);
        return alt == null ? null : {'media': alt, 'move': 'push_in', 'transition': 'zoom_in'};
    }
    return null;
  }
}
