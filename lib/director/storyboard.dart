import 'dart:convert';
import 'dart:io';

import '../core/model/layer.dart';
import 'chapters.dart';
import 'story_builder.dart';
import 'variety.dart';

/// What the planner remembers between chunks of a long script, so chapter
/// 7 knows what chapters 1-6 already showed.
class PlanMemory {
  final Map<String, int> usedMedia;
  final List<String> recent; // last visual signatures ("map:India", "media:img_3:push_in", …)
  final List<String> people; // name tags already shown
  final Map<String, int> components; // component type → times used

  PlanMemory({Map<String, int>? usedMedia, List<String>? recent, List<String>? people, Map<String, int>? components})
      : usedMedia = usedMedia ?? {},
        recent = recent ?? [],
        people = people ?? [],
        components = components ?? {};

  static String signature(Map<String, dynamic> v) {
    final k = Variety.kind(v);
    if (k == 'aroll') return v['punch'] == true ? 'presenter:punch' : 'presenter';
    if (k == 'media') return 'media:${Variety.mediaOf(v)}:${Variety.moveOf(v)}';
    final detail = v['focus'] ?? v['text'] ?? v['title'] ?? v['to'] ?? v['name'] ?? '';
    return '$k${detail == '' ? '' : ':$detail'}';
  }

  void absorb(Iterable<Beat> beats) {
    for (final b in beats) {
      if (!b.keep) continue;
      final v = b.visual;
      final m = Variety.mediaOf(v);
      if (m != null) usedMedia[m] = (usedMedia[m] ?? 0) + 1;
      final k = Variety.kind(v);
      if (k != 'aroll' && k != 'media') components[k] = (components[k] ?? 0) + 1;
      final nt = v['name_tag'];
      final name = nt is Map ? nt['name'] : (k == 'name_tag' ? v['name'] : null);
      if (name is String && !people.contains(name)) people.add(name);
      recent.add(signature(v));
    }
    if (recent.length > 8) recent.removeRange(0, recent.length - 8);
  }

  Map<String, dynamic> forPrompt() => {
        'media_used_so_far': usedMedia,
        if (recent.isNotEmpty) 'last_visuals': recent,
        if (people.isNotEmpty) 'people_already_introduced': people,
        if (components.isNotEmpty) 'components_used_so_far': components,
      };

  Map<String, dynamic> toJson() => {'used': usedMedia, 'recent': recent, 'people': people, 'components': components};

  static PlanMemory fromJson(Map<String, dynamic>? j) => j == null
      ? PlanMemory()
      : PlanMemory(
          usedMedia: {for (final e in (j['used'] as Map? ?? const {}).entries) '${e.key}': (e.value as num).toInt()},
          recent: [for (final e in (j['recent'] as List? ?? const [])) '$e'],
          people: [for (final e in (j['people'] as List? ?? const [])) '$e'],
          components: {for (final e in (j['components'] as Map? ?? const {}).entries) '${e.key}': (e.value as num).toInt()},
        );

  /// Memory rebuilt from the beats of the chapters before [chapter].
  static PlanMemory before(List<Beat> beats, int chapter) {
    final m = PlanMemory();
    m.absorb([for (final b in beats) if (b.chapter < chapter) b]..sort((a, b) => a.start.compareTo(b.start)));
    return m;
  }
}

/// A Director v2 storyboard: narration, chapters and shots, saved next to the
/// project after every planned chapter so a long plan can resume after a
/// failure or a cancel, and so one chapter can be rebuilt later.
class Storyboard {
  static const version = 2;

  String projectId;
  String tag; // id prefix of everything the build creates
  String title;
  String look;
  String stage; // narrated | outlined | planning | planned | built
  List<(double, double, String)> lines;
  List<WordTiming> words;
  String? arollLayer;
  List<Chapter> chapters;
  List<Beat> beats;
  PlanMemory memory;
  Map<String, dynamic> input; // brief, narration kind, media ids…
  DateTime updated;

  Storyboard({
    required this.projectId,
    String? tag,
    this.title = '',
    this.look = 'auto',
    this.stage = 'narrated',
    List<(double, double, String)>? lines,
    List<WordTiming>? words,
    this.arollLayer,
    List<Chapter>? chapters,
    List<Beat>? beats,
    PlanMemory? memory,
    Map<String, dynamic>? input,
    DateTime? updated,
  })  : tag = tag ?? DateTime.now().millisecondsSinceEpoch.toRadixString(36),
        lines = lines ?? [],
        words = words ?? [],
        chapters = chapters ?? [],
        beats = beats ?? [],
        memory = memory ?? PlanMemory(),
        input = input ?? {},
        updated = updated ?? DateTime.now();

  bool get outlined => chapters.isNotEmpty;
  bool get planned => chapters.isNotEmpty && chapters.every((c) => c.planned);
  int get plannedChapters => chapters.where((c) => c.planned).length;

  List<Beat> beatsOf(int chapter) => [for (final b in beats) if (b.chapter == chapter) b];

  /// Replaces one chapter's beats, keeping the others in time order.
  void replaceChapter(int chapter, List<Beat> next) {
    beats = [
      for (final b in beats) if (b.chapter != chapter) b,
      for (final b in next) (b..chapter = chapter),
    ]..sort((a, b) => a.start.compareTo(b.start));
  }

  /// Time range of a chapter, from its narration lines (falls back to beats).
  (double, double) rangeOf(int chapter) {
    final ch = chapters.firstWhere((c) => c.index == chapter);
    if (lines.isNotEmpty && ch.first < lines.length) {
      return (lines[ch.first].$1, lines[ch.last.clamp(ch.first, lines.length - 1)].$2);
    }
    final bs = beatsOf(chapter);
    if (bs.isEmpty) return (0, 0);
    return (bs.map((b) => b.start).reduce((a, b) => a < b ? a : b), bs.map((b) => b.end).reduce((a, b) => a > b ? a : b));
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'project': projectId,
        'tag': tag,
        'title': title,
        'look': look,
        'stage': stage,
        'lines': [for (final l in lines) [l.$1, l.$2, l.$3]],
        'words': [for (final w in words) w.toJson()],
        if (arollLayer != null) 'aroll': arollLayer,
        'chapters': [for (final c in chapters) c.toJson()],
        'beats': [for (final b in beats) b.toJson()],
        'memory': memory.toJson(),
        'input': input,
        'updated': updated.toIso8601String(),
      };

  static Storyboard fromJson(Map<String, dynamic> j) => Storyboard(
        projectId: '${j['project'] ?? ''}',
        tag: '${j['tag'] ?? 'x'}',
        title: '${j['title'] ?? ''}',
        look: '${j['look'] ?? 'auto'}',
        stage: '${j['stage'] ?? 'narrated'}',
        lines: [
          for (final l in (j['lines'] as List? ?? const []))
            if (l is List && l.length >= 3) ((l[0] as num).toDouble(), (l[1] as num).toDouble(), '${l[2]}'),
        ],
        words: [for (final w in (j['words'] as List? ?? const [])) WordTiming.fromJson(Map<String, dynamic>.from(w as Map))],
        arollLayer: j['aroll'] as String?,
        chapters: [for (final c in (j['chapters'] as List? ?? const [])) Chapter.fromJson(Map<String, dynamic>.from(c as Map))],
        beats: [for (final b in (j['beats'] as List? ?? const [])) Beat.fromJson(Map<String, dynamic>.from(b as Map))],
        memory: PlanMemory.fromJson(j['memory'] is Map ? Map<String, dynamic>.from(j['memory'] as Map) : null),
        input: Map<String, dynamic>.from(j['input'] as Map? ?? const {}),
        updated: DateTime.tryParse('${j['updated']}') ?? DateTime.now(),
      );

  String encode() => jsonEncode(toJson());
  static Storyboard? decode(String s) {
    try {
      final j = jsonDecode(s);
      if (j is! Map || (j['version'] as num?)?.toInt() != version) return null;
      return fromJson(Map<String, dynamic>.from(j));
    } catch (_) {
      return null;
    }
  }
}

/// Saves the storyboard as `director_<project id>.json` in a folder (the
/// app's media folder), so it survives app restarts.
class StoryboardStore {
  static String pathIn(String dir, String projectId) => '$dir/director_${projectId.replaceAll(RegExp(r'[^\w-]'), '_')}.json';

  static Future<void> save(String dir, Storyboard sb) async {
    sb.updated = DateTime.now();
    final f = File(pathIn(dir, sb.projectId));
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(sb.encode(), flush: true);
    await tmp.rename(f.path);
  }

  static Future<Storyboard?> load(String dir, String projectId) async {
    final f = File(pathIn(dir, projectId));
    if (!await f.exists()) return null;
    return Storyboard.decode(await f.readAsString());
  }

  static Future<void> clear(String dir, String projectId) async {
    final f = File(pathIn(dir, projectId));
    if (await f.exists()) await f.delete();
  }
}
