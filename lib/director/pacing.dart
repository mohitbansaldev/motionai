import 'dart:math' as math;

import '../core/model/project.dart';
import 'capabilities.dart';
import 'chapters.dart';
import 'story_builder.dart';
import 'variety.dart';

/// Pacing rules from the reference videos.
class PacingOptions {
  final double hookSeconds; // the hook when there is no outline
  final double hookShot; // hook cuts every 1-2 s
  final double brollTarget; // later B-roll shots of 3-5 s
  final double brollMax;
  final double interruptEvery; // a pattern interrupt every ~45-60 s
  final double interruptMax;
  final double presenterMin, presenterMax; // presenter 25-35 % of the time
  final bool chapterCards;
  final bool titleSlam; // the chapter after the hook opens with the title slam
  const PacingOptions({
    this.hookSeconds = 15,
    this.hookShot = 1.6,
    this.brollTarget = 4,
    this.brollMax = 5.5,
    this.interruptEvery = 50,
    this.interruptMax = 60,
    this.presenterMin = 0.25,
    this.presenterMax = 0.35,
    this.chapterCards = true,
    this.titleSlam = true,
  });
}

/// Applies the pacing rules to a planned storyboard, deterministically:
/// first-appearance name tags, fast hook cuts, long shots split into 3-5 s
/// B-roll, presenter share capped, chapter title cards, and a pattern
/// interrupt (glitch/flash insert, zoom punch, title card) every ~50 s.
class Pacer {
  final MediaPool pool;
  final Capabilities caps;
  final PacingOptions o;
  Pacer(this.pool, {Capabilities? caps, this.o = const PacingOptions()}) : caps = caps ?? Capabilities();

  static const _cardTypes = ['title_slam', 'date_title', 'number_tiles'];
  static const _hardCuts = ['flash', 'glitch_flash', 'shatter'];

  /// True when the beat already breaks the pattern.
  static bool isInterrupt(Beat b) {
    final v = b.visual;
    return b.role == 'card' ||
        b.role == 'interrupt' ||
        v['punch'] == true ||
        v['flash'] == true ||
        _hardCuts.contains(v['transition']) ||
        [..._cardTypes, 'glow_word'].contains(v['component']);
  }

  /// Longest stretch without a pattern interrupt (start → first, between
  /// interrupts, last → end of the video).
  static double maxInterruptGap(List<Beat> beats) {
    final kept = beats.where((b) => b.keep).toList()..sort((a, b) => a.start.compareTo(b.start));
    if (kept.isEmpty) return 0;
    var last = kept.first.start, gap = 0.0;
    for (final b in kept) {
      if (!isInterrupt(b)) continue;
      gap = math.max(gap, b.start - last);
      last = b.start;
    }
    return math.max(gap, kept.map((b) => b.end).reduce(math.max) - last);
  }

  /// Returns the paced beats (a new list; beats may be split or inserted).
  /// With [only] set, only that chapter's beats change.
  List<Beat> apply(List<Beat> beats, List<Chapter> chapters, {bool presenter = false, String title = '', int? only}) {
    bool mut(Beat b) => only == null || b.chapter == only;
    var out = [...beats]..sort((a, b) => a.start.compareTo(b.start));
    _firstAppearance(out, mut);
    if (o.chapterCards && chapters.length > 1) out = _chapterCards(out, chapters, title, mut);
    if (presenter) out = _presenterShare(out, mut);
    out = _split(out, chapters, mut);
    _interrupts(out, mut);
    return out;
  }

  /// Pattern interrupts only (after other passes changed transitions).
  void interrupts(List<Beat> beats, {int? only}) => _interrupts(beats, (b) => only == null || b.chapter == only);

  // ------------------------------------------------------------ name tags

  void _firstAppearance(List<Beat> beats, bool Function(Beat) mut) {
    final seen = <String>{};
    for (final b in beats) {
      if (!b.keep) continue;
      final v = b.visual;
      final nt = v['name_tag'];
      final name = nt is Map && nt['name'] is String
          ? '${nt['name']}'
          : (v['component'] == 'name_tag' && v['name'] is String ? '${v['name']}' : null);
      if (name == null) continue;
      final key = name.trim().toLowerCase();
      if (seen.add(key) || !mut(b)) continue;
      if (nt is Map) {
        b.visual = Map<String, dynamic>.from(v)..remove('name_tag');
      } else if (v['over_aroll'] == true) {
        b.visual = {'aroll': true};
      }
    }
  }

  // ------------------------------------------------------------ cuts

  bool _isHook(Beat b, List<Chapter> chapters) {
    if (chapters.isNotEmpty && chapters.first.kind == 'hook') return b.chapter == chapters.first.index && b.start < o.hookSeconds * 2.5;
    return b.start < o.hookSeconds;
  }

  Map<String, int> _uses(List<Beat> beats) {
    final uses = <String, int>{};
    for (final b in beats) {
      final m = b.keep ? Variety.mediaOf(b.visual) : null;
      if (m != null) uses[m] = (uses[m] ?? 0) + 1;
    }
    return uses;
  }

  static const _rotation = ['push_in', 'pan_left', 'pull_out', 'pan_right', 'ken_burns', 'parallax'];

  /// Another shot for the same line: a different photo when one is free,
  /// else the same photo with another move.
  Map<String, dynamic>? _altShot(Map<String, dynamic> v, String line, Set<String> avoid, Map<String, int> uses, int k) {
    final m = Variety.mediaOf(v);
    final type = pool.p.media[m]?.type;
    final alt = pool.pick(line, avoid: {...avoid, ?m}, uses: uses, maxUses: 3, type: type);
    if (alt != null) {
      uses[alt] = (uses[alt] ?? 0) + 1;
      final mv = _rotation[k % _rotation.length];
      return {'media': alt, 'move': mv, 'transition': 'fade', 'sfx': 'none'};
    }
    if (m == null || type != MediaType.image) return null;
    final cur = Variety.moveOf(v);
    final moves = _rotation.where((x) => x != cur).toList();
    return {'media': m, 'move': moves[k % moves.length], 'transition': 'fade', 'sfx': 'none'};
  }

  Set<String> _recentMedia(List<Beat> out, int n) => {
        for (final b in out.reversed.take(n)) ?Variety.mediaOf(b.visual),
      };

  List<Beat> _split(List<Beat> beats, List<Chapter> chapters, bool Function(Beat) mut) {
    final uses = _uses(beats);
    final out = <Beat>[];
    for (final b in beats) {
      if (!b.keep || !mut(b) || b.role == 'card') {
        out.add(b);
        continue;
      }
      final k = Variety.kind(b.visual);
      final hook = _isHook(b, chapters);
      if (k == 'media') {
        final target = hook ? o.hookShot : o.brollTarget;
        final maxLen = hook ? o.hookShot * 1.4 : o.brollMax;
        if (b.length <= maxLen) {
          out.add(b);
          continue;
        }
        final n = math.max(2, (b.length / target).ceil());
        final d = b.length / n;
        final pieces = <Beat>[b.copy(end: b.start + d)];
        for (int j = 1; j < n; j++) {
          final alt = _altShot(b.visual, b.line, _recentMedia([...out, ...pieces], 6), uses, j + out.length);
          if (alt == null) break;
          pieces.add(b.copy(start: b.start + d * j, end: b.start + d * (j + 1), visual: alt, role: 'split'));
        }
        pieces.last.end = b.end;
        out.addAll(pieces);
      } else if (k == 'aroll' && hook && b.length > 3.0) {
        // Fast hook on the presenter: alternate normal framing and punch-ins.
        final n = math.max(2, (b.length / 1.8).floor());
        final d = b.length / n;
        for (int j = 0; j < n; j++) {
          out.add(b.copy(
            start: b.start + d * j,
            end: j == n - 1 ? b.end : b.start + d * (j + 1),
            visual: j.isOdd ? {'aroll': true, 'punch': true, 'sfx': 'none'} : {'aroll': true},
            role: j == 0 ? b.role : 'split',
          ));
        }
      } else {
        out.add(b);
      }
    }
    return out;
  }

  // ------------------------------------------------------------ presenter share

  List<Beat> _presenterShare(List<Beat> beats, bool Function(Beat) mut) {
    final kept = beats.where((b) => b.keep).toList();
    final total = kept.fold<double>(0, (s, b) => s + b.length);
    var aroll = kept.where((b) => b.visual['aroll'] == true).fold<double>(0, (s, b) => s + b.length);
    if (total <= 0 || aroll / total <= o.presenterMax) return beats;
    final target = (o.presenterMin + o.presenterMax) / 2;
    final uses = _uses(beats);
    final first = kept.isEmpty ? null : kept.reduce((a, b) => a.start <= b.start ? a : b);
    final out = [...beats];
    var k = 0;
    // Several passes: long presenter beats are halved (B-roll over the voice
    // in the second half), short ones become B-roll, until the share fits.
    for (int pass = 0; pass < 4 && aroll / total > target; pass++) {
      final cands = out.where((b) => b.keep && b.visual['aroll'] == true && b != first && mut(b) && b.visual['punch'] != true).toList()
        ..sort((a, b) => a.length != b.length ? b.length.compareTo(a.length) : a.start.compareTo(b.start));
      var changed = false;
      for (final b in cands) {
        if (aroll / total <= target) break;
        final avoid = {for (final x in out) if (x.keep && (x.start - b.start).abs() < 30) ?Variety.mediaOf(x.visual)};
        final media = pool.pick(b.line, avoid: avoid, uses: uses, maxUses: 3);
        if (media == null) break;
        uses[media] = (uses[media] ?? 0) + 1;
        final shot = {'media': media, 'move': _rotation[k++ % _rotation.length], 'transition': 'fade'};
        changed = true;
        if (b.length >= 4) {
          final mid = b.start + b.length / 2;
          out.add(b.copy(start: mid, visual: shot, role: 'split'));
          aroll -= b.end - mid;
          b.end = mid;
        } else {
          b.visual = shot;
          aroll -= b.length;
        }
      }
      if (!changed) break;
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  // ------------------------------------------------------------ chapter cards

  static String _words(String s, int n) => s.trim().split(RegExp(r'\s+')).take(n).join(' ').toUpperCase();

  Map<String, dynamic> cardFor(Chapter ch, List<Chapter> chapters, String title) {
    final intro = ch.index == 1 && chapters.first.kind == 'hook' && o.titleSlam && caps.has('title_slam');
    if (intro) {
      final t = title.trim().isNotEmpty ? title : ch.title;
      return {'component': 'title_slam', 'title': _words(t, 3)};
    }
    if (RegExp(r'\d').hasMatch(ch.date) && caps.has('date_title')) {
      return {'component': 'date_title', 'text': ch.date, 'subtitle': ch.title};
    }
    if (caps.has('number_tiles')) {
      return {'component': 'number_tiles', 'text': '${ch.index}'.padLeft(2, '0'), 'word': _words(ch.title, 3)};
    }
    return {'component': 'glow_word', 'text': _words(ch.title, 2)};
  }

  List<Beat> _chapterCards(List<Beat> beats, List<Chapter> chapters, String title, bool Function(Beat) mut) {
    final out = [...beats];
    for (final ch in chapters) {
      if (ch.index < 1) continue;
      final first = out.where((b) => b.keep && b.chapter == ch.index).fold<Beat?>(null, (a, b) => a == null || b.start < a.start ? b : a);
      if (first == null || !mut(first)) continue;
      if (first.role == 'card' || _cardTypes.contains(first.visual['component'])) continue;
      final card = cardFor(ch, chapters, title);
      final len = card['component'] == 'title_slam' ? 2.8 : 2.0;
      if (first.length <= len + 1.2) {
        if (first.length < 1.4) continue;
        first.visual = card;
        first.role = 'card';
      } else {
        out.add(Beat(first.start, first.start + len, first.line, card, chapter: ch.index, lineIndex: first.lineIndex, role: 'card'));
        first.start += len;
      }
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  // ------------------------------------------------------------ pattern interrupts

  static const _interruptCuts = ['glitch_flash', 'flash', 'zoom_in'];

  void _interrupts(List<Beat> beats, bool Function(Beat) mut) {
    final kept = beats.where((b) => b.keep).toList()..sort((a, b) => a.start.compareTo(b.start));
    if (kept.isEmpty) return;
    var last = kept.first.start;
    var rot = 0;
    for (int i = 0; i < kept.length; i++) {
      final b = kept[i];
      if (isInterrupt(b)) {
        last = b.start;
        continue;
      }
      final gap = b.start - last;
      final next = i + 1 < kept.length ? kept[i + 1] : null;
      final nextLate = (next?.start ?? b.end) - last > o.interruptMax;
      final due = gap >= o.interruptEvery || (nextLate && gap >= o.interruptEvery * 0.5);
      if (!due) {
        // A long presenter beat crossing the limit: punch in half-way.
        if (b.visual['aroll'] == true && mut(b) && b.end - last > o.interruptMax && b.length >= 6) {
          final t = math.max(b.start + 2, last + o.interruptEvery);
          if (t < b.end - 2) {
            final punch = b.copy(start: t, visual: {'aroll': true, 'punch': true, 'sfx': 'hit'}, role: 'interrupt');
            b.end = t;
            beats.add(punch);
            kept.insert(i + 1, punch);
          }
        }
        continue;
      }
      if (!mut(b)) continue;
      final v = Map<String, dynamic>.from(b.visual);
      final k = Variety.kind(v);
      if (k == 'aroll') {
        v['punch'] = true;
        v['sfx'] = 'hit';
      } else if (k == 'media') {
        final cut = _interruptCuts[rot++ % _interruptCuts.length];
        v['transition'] = cut;
        if (cut == 'zoom_in') v['move'] = 'push_in';
        v['sfx'] = 'hit';
      } else {
        v['flash'] = true;
      }
      b.visual = v;
      b.role = 'interrupt';
      last = b.start;
    }
    beats.sort((a, b) => a.start.compareTo(b.start));
  }
}
