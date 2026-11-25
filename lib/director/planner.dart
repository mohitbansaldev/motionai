import 'dart:convert';
import 'dart:math' as math;

import '../ai/ai_client.dart';
import '../core/model/project.dart';
import 'capabilities.dart';
import 'chapters.dart';
import 'json_repair.dart';
import 'pacing.dart';
import 'story_builder.dart';
import 'storyboard.dart';
import 'variety.dart';

/// One AI round trip: system prompt + user message → raw answer.
typedef AiCall = Future<String> Function(String system, String user);

class DirectorCancelled implements Exception {
  @override
  String toString() => 'Cancelled';
}

/// Set by the Cancel button; checked between AI calls.
class CancelToken {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
  void check() {
    if (_cancelled) throw DirectorCancelled();
  }
}

/// Director v2 planning for long scripts: an outline pass (chapters), then
/// shots per chapter in chunks with a running memory, each AI answer
/// repaired or retried until it is usable. The AI is injected ([AiCall]) so
/// this runs in tests.
class StoryPlanner {
  final AiCall ai;
  final void Function(String) status;
  final CancelToken cancel;
  final int retries;
  final int chunk; // lines per AI call

  StoryPlanner(this.ai, {void Function(String)? status, CancelToken? cancel, this.retries = 2, this.chunk = 24})
      : status = status ?? ((_) {}),
        cancel = cancel ?? CancelToken();

  /// Asks for a JSON object: cut-off answers are repaired, unusable ones
  /// retried with the reason. When every try fails [valid], the best
  /// partial answer is returned; with none at all an [AiException] is thrown.
  Future<Map<String, dynamic>> askJson(String system, String user, {bool Function(Map<String, dynamic>)? valid}) async {
    Object? last;
    Map<String, dynamic>? partial;
    for (int a = 0; a <= retries; a++) {
      cancel.check();
      final msg = a == 0
          ? user
          : '$user\n\nYOUR PREVIOUS ANSWER WAS REJECTED ($last). Return ONLY one complete JSON object — keep each visual short so it fits.';
      try {
        final raw = await ai(system, msg);
        cancel.check();
        final j = JsonRepair.tryDecode(raw);
        if (j == null) {
          last = 'it was not JSON';
          continue;
        }
        if (valid != null && !valid(j)) {
          partial ??= j;
          last = 'some lines were missing or malformed';
          continue;
        }
        return j;
      } on DirectorCancelled {
        rethrow;
      } on AiException catch (e) {
        last = e.message;
      } catch (e) {
        last = e;
      }
    }
    if (partial != null) return partial;
    throw AiException('The AI did not return a usable plan ($last).');
  }

  // ------------------------------------------------------------ outline

  /// Splits the narration into chapters (AI, with a time-based fallback).
  Future<void> outline(Storyboard sb,
      {String brief = '', String styleNotes = '', List<Map<String, dynamic>> media = const [], List<String> looks = const []}) async {
    final n = sb.lines.length;
    var chapters = <Chapter>[];
    final total = n == 0 ? 0.0 : sb.lines.last.$2 - sb.lines.first.$1;
    if (n >= 6 && total >= 75) {
      status('Outlining the chapters…');
      final ids = {for (final m in media) '${m['id']}'};
      try {
        final j = await askJson(
          ChapterPlanner.outlinePrompt(looks: looks),
          jsonEncode({
            'brief': brief,
            if (styleNotes.isNotEmpty) 'style_notes': styleNotes,
            'minutes': double.parse((total / 60).toStringAsFixed(1)),
            'media': [for (final m in media) {'id': m['id'], 'about': m['about']}],
            'lines': [for (int i = 0; i < n; i++) {'i': i, 't': _r(sb.lines[i].$1), 'text': _cut(sb.lines[i].$3, 160)}],
          }),
          valid: (j) => ChapterPlanner.parseOutline(j, n).length >= 2,
        );
        chapters = ChapterPlanner.parseOutline(j, n, mediaIds: ids);
        final title = j['title'];
        if (title is String && title.trim().isNotEmpty) sb.title = title.trim();
        final look = j['look'];
        if (sb.look == 'auto' && look is String && looks.contains(look)) sb.look = look;
      } on DirectorCancelled {
        rethrow;
      } catch (_) {
        chapters = [];
      }
    }
    if (chapters.length < 2) chapters = n >= 4 && total >= 40 ? ChapterPlanner.heuristic(sb.lines) : [Chapter(index: 0, title: 'Story', kind: 'story', first: 0, last: math.max(0, n - 1))];
    sb.chapters = chapters;
    sb.stage = 'outlined';
  }

  // ------------------------------------------------------------ shots

  /// Plans the shots of one chapter in chunks of [chunk] lines. [base] is
  /// the payload every call shares (frame, media list, brief…); the
  /// chapter's style and the running memory are added per call.
  Future<List<Beat>> planChapter(Storyboard sb, int chapter,
      {required String system, required Map<String, dynamic> base, String note = ''}) async {
    final ch = sb.chapters.firstWhere((c) => c.index == chapter);
    ch.status = 'planning';
    ch.error = '';
    final memory = PlanMemory.before(sb.beats, chapter);
    final out = <Beat>[];
    final idx = [for (int i = ch.first; i <= ch.last && i < sb.lines.length; i++) i];
    for (int s = 0; s < idx.length; s += chunk) {
      cancel.check();
      final part = idx.sublist(s, math.min(idx.length, s + chunk));
      status('Chapter ${chapter + 1}/${sb.chapters.length} · ${ch.title}: shots ${part.first + 1}–${part.last + 1} of ${sb.lines.length}');
      final payload = {
        ...base,
        'chapter': ch.forPrompt(sb.chapters.length),
        if (note.trim().isNotEmpty) 'editor_note': note.trim(),
        ...memory.forPrompt(),
        'lines': [
          for (final i in part) {'i': i, 'start': _r(sb.lines[i].$1), 'end': _r(sb.lines[i].$2), 'text': sb.lines[i].$3},
        ],
      };
      final Map<String, dynamic> j;
      try {
        j = await askJson(system, jsonEncode(payload), valid: (j) => parseBeats(j, sb, part, chapter).length >= (part.length * 0.6).ceil());
      } on DirectorCancelled {
        rethrow;
      } catch (e) {
        // No usable answer even after retries (network, quota…): stop here so
        // the chapter can be resumed, instead of silently filling it.
        ch.status = 'failed';
        ch.error = '$e';
        rethrow;
      }
      if (sb.look == 'auto' && j['look'] is String) sb.look = '${j['look']}';
      final got = parseBeats(j, sb, part, chapter);
      // Lines the AI skipped stay on the presenter (filled later without one).
      final have = {for (final b in got) b.lineIndex};
      for (final i in part) {
        if (!have.contains(i)) got.add(Beat(sb.lines[i].$1, sb.lines[i].$2, sb.lines[i].$3, {'aroll': true}, chapter: chapter, lineIndex: i));
      }
      got.sort((a, b) => a.start.compareTo(b.start));
      memory.absorb(got);
      out.addAll(got);
    }
    sb.memory = memory;
    ch.status = 'planned';
    return out;
  }

  /// Beats from one AI answer: {"beats":[{"i":k,"visual":{…}}]} or, for
  /// fast cuts, {"i":k,"shots":[{…},{…}]} (the line's time split evenly).
  static List<Beat> parseBeats(Map<String, dynamic> j, Storyboard sb, List<int> lines, int chapter) {
    final allowed = lines.toSet();
    final seen = <int>{};
    final out = <Beat>[];
    final raw = j['beats'] ?? j['shots'] ?? j['storyboard'];
    if (raw is! List) return out;
    for (final e in raw) {
      if (e is! Map) continue;
      final iv = e['i'] ?? e['line'] ?? e['index'];
      final i = iv is num ? iv.toInt() : int.tryParse('$iv');
      if (i == null || !allowed.contains(i) || i >= sb.lines.length || !seen.add(i)) continue;
      final (t0, t1, text) = sb.lines[i];
      final shots = [
        for (final s in (e['shots'] is List ? e['shots'] as List : const [])) if (s is Map) Map<String, dynamic>.from(s),
      ];
      if (shots.length > 1 && t1 - t0 >= 1.2 * shots.length) {
        final d = (t1 - t0) / shots.length;
        for (int k = 0; k < shots.length; k++) {
          out.add(Beat(t0 + d * k, k == shots.length - 1 ? t1 : t0 + d * (k + 1), text, shots[k],
              chapter: chapter, lineIndex: i, role: k == 0 ? '' : 'split'));
        }
        continue;
      }
      final vis = e['visual'] ?? (shots.isNotEmpty ? shots.first : null);
      out.add(Beat(t0, t1, text, vis is Map ? Map<String, dynamic>.from(vis) : {'aroll': true}, chapter: chapter, lineIndex: i));
    }
    return out;
  }

  // ------------------------------------------------------------ after planning

  /// Makes a planned storyboard buildable and well paced, deterministically:
  /// unavailable visuals adapted, pacing rules applied, variety repaired,
  /// presenter-less gaps filled. With [only], just that chapter changes.
  static VarietyReport finish(Project p, Storyboard sb,
      {Capabilities? caps, bool presenter = false, Set<String> cutouts = const {}, int? only, PacingOptions pacing = const PacingOptions()}) {
    final cap = caps ?? Capabilities();
    bool mut(Beat b) => only == null || b.chapter == only;
    for (final b in sb.beats) {
      if (mut(b)) b.visual = cap.adapt(b.visual);
    }
    final pool = MediaPool(p, cutouts: cutouts);
    final pacer = Pacer(pool, caps: cap, o: pacing);
    final beats = pacer.apply(sb.beats, sb.chapters, presenter: presenter, title: sb.title, only: only);
    const Variety().repair(beats, pool, caps: cap, presenter: presenter, mutable: mut);
    if (!presenter) fillGaps(beats, mut);
    pacer.interrupts(beats, only: only); // repairs may have softened a hard cut
    beats.sort((a, b) => a.start.compareTo(b.start));
    final report = const Variety().score(beats, presenter: presenter);
    sb.beats = beats;
    return report;
  }

  /// Without a presenter a beat on "aroll" would be a black frame: reuse
  /// the previous photo with another move, or put up a glowing key word.
  static void fillGaps(List<Beat> beats, [bool Function(Beat)? mutable]) {
    Map<String, dynamic>? last;
    for (final b in beats..sort((a, b) => a.start.compareTo(b.start))) {
      if (!b.keep) continue;
      if (b.visual['aroll'] == true) {
        if (mutable != null && !mutable(b)) continue;
        if (last != null && last['media'] != null && last['component'] == null) {
          b.visual = {...last, 'move': last['move'] == 'pull_out' ? 'push_in' : 'pull_out', 'transition': 'fade', 'sfx': 'none'}
            ..remove('name_tag')
            ..remove('label');
        } else {
          final words = b.line.split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
          final word = words.isEmpty ? '…' : words.reduce((a, x) => x.length > a.length ? x : a);
          b.visual = {'component': 'glow_word', 'text': word.replaceAll(RegExp(r'[^\wऀ-ॿ]'), '')};
        }
      } else {
        last = b.visual;
      }
    }
  }

  static double _r(double v) => double.parse(v.toStringAsFixed(2));
  static String _cut(String s, int n) => s.length <= n ? s : '${s.substring(0, n - 1)}…';
}
