import 'dart:math' as math;

/// One act of a long documentary: a run of narration lines with its own
/// look, mood (atmosphere), recurring set of media and map moments.
class Chapter {
  int index;
  String title;
  String kind; // hook | context | conflict | turning_point | ending | story
  int first, last; // narration line indices, inclusive
  String mood; // neutral | sad | tense | celebration | history | autumn | mystery | hopeful | winter
  String look; // MotionPresets style, or '' for the video's look
  String date; // year/date the chapter is about ('' = none)
  List<String> places; // countries for map moments
  List<String> set; // media ids that recur in this chapter
  String notes; // the visual idea, in one sentence
  String status; // pending | planning | planned | built | failed
  String error;

  Chapter({
    required this.index,
    required this.title,
    this.kind = 'story',
    required this.first,
    required this.last,
    this.mood = 'neutral',
    this.look = '',
    this.date = '',
    List<String>? places,
    List<String>? set,
    this.notes = '',
    this.status = 'pending',
    this.error = '',
  })  : places = places ?? [],
        set = set ?? [];

  int get lineCount => last - first + 1;
  bool contains(int line) => line >= first && line <= last;
  bool get planned => status == 'planned' || status == 'built';

  /// Particles that match the chapter's mood (null = none).
  String? get atmosphere => ChapterPlanner.atmosphereFor(mood);

  Map<String, dynamic> toJson() => {
        'index': index,
        'title': title,
        'kind': kind,
        'first': first,
        'last': last,
        'mood': mood,
        if (look.isNotEmpty) 'look': look,
        if (date.isNotEmpty) 'date': date,
        if (places.isNotEmpty) 'places': places,
        if (set.isNotEmpty) 'set': set,
        if (notes.isNotEmpty) 'notes': notes,
        'status': status,
        if (error.isNotEmpty) 'error': error,
      };

  static Chapter fromJson(Map<String, dynamic> j) => Chapter(
        index: (j['index'] as num?)?.toInt() ?? 0,
        title: '${j['title'] ?? ''}',
        kind: '${j['kind'] ?? 'story'}',
        first: (j['first'] as num?)?.toInt() ?? 0,
        last: (j['last'] as num?)?.toInt() ?? 0,
        mood: '${j['mood'] ?? 'neutral'}',
        look: '${j['look'] ?? ''}',
        date: '${j['date'] ?? ''}',
        places: [for (final e in (j['places'] as List? ?? const [])) '$e'],
        set: [for (final e in (j['set'] as List? ?? const [])) '$e'],
        notes: '${j['notes'] ?? ''}',
        status: '${j['status'] ?? 'pending'}',
        error: '${j['error'] ?? ''}',
      );

  /// What the shot planner is told about this chapter.
  Map<String, dynamic> forPrompt(int count) => {
        'chapter': index + 1,
        'of': count,
        'title': title,
        'kind': kind,
        'mood': mood,
        if (look.isNotEmpty) 'look': look,
        if (date.isNotEmpty) 'date': date,
        if (places.isNotEmpty) 'places': places,
        if (set.isNotEmpty) 'recurring_media': set,
        if (notes.isNotEmpty) 'idea': notes,
      };
}

/// The first planning pass: the AI outlines chapters from the narration
/// lines; [parseOutline] makes any answer usable (sorted, no gaps, no
/// overlaps) and [heuristic] splits by time when the AI fails.
class ChapterPlanner {
  static const kinds = ['hook', 'context', 'conflict', 'turning_point', 'ending', 'story'];
  static const moods = ['neutral', 'sad', 'tense', 'celebration', 'history', 'autumn', 'mystery', 'hopeful', 'winter'];

  static String? atmosphereFor(String mood) => const {
        'sad': 'rain',
        'celebration': 'confetti',
        'history': 'dust',
        'autumn': 'leaves',
        'mystery': 'smoke',
        'hopeful': 'bokeh',
        'winter': 'snow',
      }[mood];

  static String outlinePrompt({List<String> looks = const []}) => '''
You are the STORY EDITOR of a long Hindi/English documentary (8-20 minutes) for YouTube. Before any shot is planned, split the narration lines into chapters (acts).
Return ONLY JSON:
{"title":"<video title, 2-4 words>","look":"${looks.isEmpty ? 'cinematic_doc' : looks.join('|')}","chapters":[{"title":"<2-4 word chapter title>","kind":"${kinds.join('|')}","first":<first line index>,"last":<last line index>,"mood":"${moods.join('|')}","look":"<optional style for this chapter, or empty>","date":"<the year/date this chapter is about, or empty>","places":["<English country names that matter in this chapter>"],"set":["<media ids that should recur through this chapter>"],"notes":"<one sentence: the visual idea of this chapter>"}]}
RULES
- Chapters cover ALL lines, in order, with no gaps or overlaps.
- The first chapter is the HOOK: the first 15-30 seconds (2-6 lines) — the most surprising fact or question.
- Then 3-9 chapters of about 1-3 minutes each following the story: context → conflict → turning points → ending (the ending invites a comment).
- Mood drives the atmosphere: sad → rain, celebration → confetti, history → dust, autumn → leaves, mystery → smoke, hopeful → bokeh, winter → snow; "neutral" = none. Use non-neutral moods only when the chapter really feels that way.
- "set": pick media (by "about") that belong to this chapter's place/people so the chapter has a recognisable look; never invent media ids.''';

  /// Builds chapters from the AI's outline. Indices are clamped, chapters
  /// sorted, gaps given to the previous chapter and overlaps trimmed so the
  /// result covers lines 0..[lineCount]-1 exactly.
  static List<Chapter> parseOutline(Map<String, dynamic> j, int lineCount, {Set<String> mediaIds = const {}}) {
    if (lineCount <= 0) return [];
    final raw = j['chapters'] ?? j['acts'] ?? j['outline'];
    final out = <Chapter>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        int? n(List<String> keys) {
          for (final k in keys) {
            final v = m[k];
            if (v is num) return v.toInt();
            if (v is String && int.tryParse(v.trim()) != null) return int.parse(v.trim());
          }
          return null;
        }

        var first = n(['first', 'from', 'start', 'start_line', 'first_line']);
        var last = n(['last', 'to', 'end', 'end_line', 'last_line']);
        final lines = m['lines'];
        if ((first == null || last == null) && lines is List && lines.isNotEmpty) {
          final idx = [for (final x in lines) if (x is num) x.toInt()];
          if (idx.isNotEmpty) {
            first ??= idx.reduce(math.min);
            last ??= idx.reduce(math.max);
          }
        }
        if (first == null) continue;
        first = first.clamp(0, lineCount - 1);
        last = (last ?? first).clamp(first, lineCount - 1);
        final kind = '${m['kind'] ?? m['type'] ?? 'story'}'.toLowerCase().replaceAll(' ', '_').replaceAll('-', '_');
        final mood = '${m['mood'] ?? 'neutral'}'.toLowerCase();
        out.add(Chapter(
          index: 0,
          title: _clean('${m['title'] ?? m['name'] ?? ''}'),
          kind: kinds.contains(kind) ? kind : 'story',
          first: first,
          last: last,
          mood: moods.contains(mood) ? mood : 'neutral',
          look: '${m['look'] ?? ''}',
          date: _clean('${m['date'] ?? m['year'] ?? ''}'),
          places: [for (final x in (m['places'] as List? ?? const [])) if ('$x'.trim().isNotEmpty) '$x'.trim()],
          set: [for (final x in (m['set'] as List? ?? const [])) if (mediaIds.isEmpty || mediaIds.contains('$x')) '$x'],
          notes: '${m['notes'] ?? m['idea'] ?? ''}',
        ));
      }
    }
    if (out.isEmpty) return [];
    out.sort((a, b) => a.first != b.first ? a.first.compareTo(b.first) : b.last.compareTo(a.last));
    // Remove chapters swallowed by an earlier one, then make them contiguous.
    final fixed = <Chapter>[];
    for (final c in out) {
      if (fixed.isNotEmpty && c.last <= fixed.last.last) continue;
      if (fixed.isNotEmpty && c.first <= fixed.last.last) c.first = fixed.last.last + 1;
      if (fixed.isNotEmpty && c.first > fixed.last.last + 1) fixed.last.last = c.first - 1; // gap → previous chapter
      fixed.add(c);
    }
    fixed.first.first = 0;
    fixed.last.last = lineCount - 1;
    for (int i = 0; i < fixed.length; i++) {
      fixed[i].index = i;
      if (fixed[i].title.isEmpty) fixed[i].title = 'Part ${i + 1}';
    }
    return fixed;
  }

  /// Time-based split when the AI outline is unusable: a hook of ~20 s, then
  /// chapters of ~[target] seconds cut at the longest pause, last = ending.
  static List<Chapter> heuristic(List<(double, double, String)> lines, {double hook = 20, double target = 120}) {
    if (lines.isEmpty) return [];
    final n = lines.length;
    final t0 = lines.first.$1;
    var hookEnd = 0;
    while (hookEnd + 1 < n && lines[hookEnd + 1].$2 - t0 <= hook) {
      hookEnd++;
    }
    if (n >= 4) hookEnd = hookEnd.clamp(1, n - 2);
    final out = <Chapter>[Chapter(index: 0, title: 'Hook', kind: 'hook', first: 0, last: hookEnd)];
    var start = hookEnd + 1;
    while (start < n) {
      final s0 = lines[start].$1;
      var end = start;
      while (end + 1 < n && lines[end + 1].$2 - s0 <= target) {
        end++;
      }
      if (end + 1 < n) {
        // Prefer the longest pause in the last third of the window.
        var best = end, gap = -1.0;
        for (int k = start + (end - start) * 2 ~/ 3; k <= end; k++) {
          if (k + 1 >= n) break;
          final g = lines[k + 1].$1 - lines[k].$2;
          if (g >= gap) {
            gap = g;
            best = k;
          }
        }
        end = best;
        // Do not leave a tiny tail chapter.
        if (lines.last.$2 - lines[end + 1].$1 < target * 0.35) end = n - 1;
      }
      out.add(Chapter(index: out.length, title: 'Part ${out.length}', kind: 'story', first: start, last: end));
      start = end + 1;
    }
    if (out.length > 2) {
      out[1].kind = 'context';
      out.last.kind = 'ending';
    } else if (out.length == 2) {
      out.last.kind = 'story';
    }
    return out;
  }

  static String _clean(String s) {
    final t = s.trim();
    return t == 'null' ? '' : t;
  }
}
