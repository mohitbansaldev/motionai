import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../ai/agent.dart';
import '../ai/ai_client.dart';
import '../ai/ai_settings.dart';
import '../ai/command_spec.dart';
import '../ai/phrase_finder.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../core/commands/edit_commands.dart';
import '../core/presets/motion_presets.dart';
import '../library/library_director.dart'; // Library (Agent G)
import '../services/captions.dart';
import '../services/media_bridge.dart';
import '../services/speech.dart';
import '../state/editor_controller.dart';
import 'capabilities.dart';
import 'json_repair.dart';
import 'planner.dart';
import 'sfx.dart';
import 'story_builder.dart';
import 'storyboard.dart';
import 'variety.dart';

/// Where the voice of the video comes from.
enum Narration {
  aroll, // a talking-head video (the presenter on camera)
  voiceover, // a recorded voice-over audio file
  phoneVoice, // the script, read by the phone's text-to-speech voice
  silent, // the script as on-screen text timing only
}

class DirectorInput {
  String brief = ''; // topic / instructions, in the user's words
  String script = ''; // narration; empty + brief = the AI writes it
  Narration narration = Narration.aroll;
  String? arollMedia; // video media id
  String? voiceMedia; // audio media id
  String? musicMedia; // audio media id
  String language = 'hi'; // hi | en | auto
  bool roman = false; // Hinglish captions in Roman script
  bool captions = true;
  bool sfx = true;
  bool depth = true; // AI cut-outs for depth shots
  bool review = true; // look at rendered frames and fix problems
  String look = 'auto';
  int minutes = 3; // length when the AI writes the script
}

class NarrationResult {
  final List<(double, double, String)> lines; // composition seconds
  final List<WordTiming> words; // composition seconds
  final String? arollLayer;
  NarrationResult(this.lines, this.words, this.arollLayer);
}

/// Director mode: turns a pile of photos, clips, a voice and a brief into a
/// finished documentary timeline.
///
/// understand media → narration (speech-to-text / phone voice / script) →
/// storyboard (AI, in chunks) → tools (cut-outs, sound effects) → build
/// (one Undo) → review rendered frames and fix.
class Director {
  final EditorController c;
  final void Function(String status) status;
  Director(this.c, this.status);

  Project get p => c.project;

  // ------------------------------------------------------------ 1. understand

  /// Writes an AI description for every photo/video that has none, so the
  /// storyboard is planned from what is actually in each picture.
  Future<int> understandMedia({bool force = false}) async {
    final s = await AiSettings.load();
    final todo = [
      for (final m in p.media.values)
        if (m.type != MediaType.audio && (force || m.description.isEmpty) && !m.name.startsWith('SFX ')) m,
    ];
    var done = 0;
    for (int i = 0; i < todo.length; i += 6) {
      final batch = todo.sublist(i, math.min(todo.length, i + 6));
      status('Looking at your media… ${math.min(todo.length, i + 6)}/${todo.length}');
      final images = <Uint8List>[];
      final ids = <String>[];
      for (final m in batch) {
        final b = await thumbnail(m);
        if (b == null) continue;
        images.add(b);
        ids.add(m.id);
      }
      if (images.isEmpty) continue;
      final raw = await AiClient.complete(
        s: s,
        system: _describePrompt,
        messages: [
          AiMessage('user', jsonEncode({
            'images': [
              for (final id in ids) {'id': id, 'type': p.media[id]!.type.name, 'file': p.media[id]!.name, if (p.media[id]!.duration > 0) 'seconds': p.media[id]!.duration.round()},
            ],
          }), images: images),
        ],
      );
      final j = _json(raw);
      for (final it in (j['items'] as List? ?? const [])) {
        final m = p.media['${(it as Map)['id']}'];
        if (m == null) continue;
        final kind = '${it['kind'] ?? 'photo'}';
        final subj = it['subject'] == true ? ' · clear subject' : '';
        final text = (it['text'] ?? '').toString().trim();
        m.description = '[$kind$subj] ${it['desc'] ?? ''}${text.isEmpty ? '' : ' · text: "$text"'}'.trim();
        done++;
      }
    }
    if (done > 0) c.mediaChanged();
    return done;
  }

  static const _describePrompt = '''
You label media for a documentary editor. For each attached image (in order, matching "images"), return ONLY JSON:
{"items":[{"id":"<id>","kind":"portrait|group|crowd|place|building|map|document|newspaper|screenshot|logo|object|chart|footage|presenter|graphic","subject":<true if ONE clear foreground subject (person/object) that could be cut out>,"desc":"<max 22 words: who/what, where, era, mood, colours>","text":"<important visible text, or empty>"}]}
Do not guess names of private people. Name famous people, places or logos only when you are confident.''';

  static Future<Uint8List?> thumbnail(MediaAsset m, {int size = 512}) async {
    try {
      if (m.type == MediaType.video) return await MediaBridge.thumbnailJpeg(m.path, m.duration / 3, maxSize: size);
      if (m.type != MediaType.image) return null;
      final codec = await ui.instantiateImageCodec(await File(m.path).readAsBytes(), targetWidth: size);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ 2. narration

  Future<NarrationResult> narrate(DirectorInput o) async {
    final s = await AiSettings.load();
    final lang = o.language == 'auto' ? null : o.language;
    switch (o.narration) {
      case Narration.aroll:
      case Narration.voiceover:
        final media = p.media[o.narration == Narration.aroll ? o.arollMedia : o.voiceMedia];
        if (media == null) {
          throw AiException(o.narration == Narration.aroll ? 'Choose your talking-head video.' : 'Choose your voice-over audio.');
        }
        final layerId = await _placeNarration(media, o.narration == Narration.aroll);
        final words = await Speech.words(media.path, language: lang, roman: o.roman, onStatus: status);
        if (o.roman && words.any((w) => RegExp(r'[ऀ-ॿ]').hasMatch(w.word))) await _romanize(s, words);
        return NarrationResult(Speech.lines(words), words, o.narration == Narration.aroll ? layerId : null);

      case Narration.phoneVoice:
      case Narration.silent:
        var script = o.script.trim();
        if (script.isEmpty) script = await writeScript(o);
        final parts = splitScript(script);
        if (parts.isEmpty) throw AiException('Paste a script, or write a brief so the AI can write one.');
        if (o.narration == Narration.silent) {
          final lines = estimateTimings(parts, 0);
          return NarrationResult(lines, _spreadWords(lines), null);
        }
        status('Recording the voice-over with your phone\'s voice…');
        final dir = await c.storage.mediaDir();
        final clips = await MediaBridge.tts(parts, dir, lang: o.language == 'en' ? 'en-IN' : 'hi-IN', rate: 1.05);
        final lines = <(double, double, String)>[];
        final cmds = <Map<String, dynamic>>[];
        var t = 0.4;
        for (int i = 0; i < clips.length; i++) {
          final (path, dur) = clips[i];
          final a = MediaAsset(id: Ids.next('voice'), type: MediaType.audio, path: path, name: 'Voice ${i + 1}', width: 0, height: 0, duration: dur);
          p.media[a.id] = a;
          cmds.add({'op': 'add_layer', 'type': 'audio', 'media': a.id, 'id': '${a.id}_l', 'name': 'Voice ${i + 1}', 'start': t, 'duration': dur, 'index': 9999});
          lines.add((t, t + dur, parts[i]));
          t += dur + 0.3;
        }
        c.mediaChanged();
        final err = c.tryRun({'op': 'batch', 'commands': cmds}, record: false);
        if (err != null) throw AiException('Could not place the voice-over: $err');
        return NarrationResult(lines, _spreadWords(lines), null);
    }
  }

  Future<String> _placeNarration(MediaAsset m, bool video) async {
    final existing = c.comp.layers.where((l) => l.mediaId == m.id).toList();
    if (existing.isNotEmpty) return existing.first.id;
    final id = Ids.next(video ? 'aroll' : 'vo');
    final err = c.tryRun({
      'op': 'batch',
      'commands': [
        {'op': 'add_layer', 'type': video ? 'video' : 'audio', 'media': m.id, 'id': id, 'name': video ? 'Presenter' : 'Voice-over', 'start': 0, if (video) 'fit': 'cover', 'index': 9999},
        if (m.duration > c.comp.duration) {'op': 'set_comp', 'duration': m.duration},
      ],
    }, record: false);
    if (err != null) throw AiException('Could not place the clip: $err');
    return id;
  }

  Future<void> _romanize(AiSettings s, List<WordTiming> words) async {
    status('Converting to Roman script…');
    for (int i = 0; i < words.length; i += 300) {
      final chunk = words.sublist(i, math.min(words.length, i + 300));
      try {
        final raw = await AiClient.complete(
          s: s,
          system: 'Transliterate Hindi words to casual Roman-script Hinglish. Return JSON {"words": [...]} with exactly the same number of items, in order.',
          messages: [AiMessage('user', jsonEncode({'words': chunk.map((w) => w.word).toList()}))],
        );
        final out = (_json(raw)['words'] as List? ?? const []).map((e) => '$e').toList();
        if (out.length == chunk.length) {
          for (int k = 0; k < chunk.length; k++) {
            chunk[k].word = out[k];
          }
        }
      } catch (_) {}
    }
  }

  Future<String> writeScript(DirectorInput o) async {
    if (o.brief.trim().isEmpty) throw AiException('Write a brief (what the video is about) or paste a script.');
    status('Writing the script…');
    final s = await AiSettings.load();
    final media = _mediaList();
    final raw = await AiClient.complete(
      s: s,
      system: '''
You are a scriptwriter for a ${o.language == 'en' ? 'English' : 'Hindi/Hinglish'} documentary YouTube channel. Write narration for about ${o.minutes} minute(s) (~${o.minutes * 150} words).
Structure: a 2-3 sentence hook with a question or surprising fact, then the story in clear short sentences, then a one-line ending that invites a comment.
Use ONLY facts given in the brief or visible in the media descriptions; if a fact is uncertain, phrase it carefully. ${o.language == 'en' ? '' : 'Write in Devanagari Hindi with common English words where natural.'}
Return ONLY JSON: {"title":"...","lines":["sentence", ...]}''',
      messages: [AiMessage('user', jsonEncode({'brief': o.brief, 'media': media, 'style_notes': s.styleNotes}))],
    );
    final j = _json(raw);
    final lines = (j['lines'] as List? ?? const []).map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList();
    if (lines.isEmpty) throw AiException('The AI did not return a script. Try again or paste your own.');
    final title = j['title'];
    if (title is String && title.trim().isNotEmpty && p.name.startsWith('Untitled')) p.name = title.trim();
    return lines.join('\n');
  }

  static List<String> splitScript(String text) => text
      .split(RegExp(r'(?<=[.!?।])\s+|\n+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  /// ~2.6 words a second, at least 1.6 s a line.
  static List<(double, double, String)> estimateTimings(List<String> parts, double t0) {
    var t = t0;
    return [
      for (final p in parts)
        () {
          final d = math.max(1.6, p.split(RegExp(r'\s+')).length / 2.6);
          final r = (t, t + d, p);
          t += d + 0.2;
          return r;
        }(),
    ];
  }

  static List<WordTiming> _spreadWords(List<(double, double, String)> lines) {
    final out = <WordTiming>[];
    for (final (a, b, text) in lines) {
      final ws = text.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
      final total = ws.fold<int>(0, (s, w) => s + w.length + 1);
      var t = a;
      for (final w in ws) {
        final d = (b - a) * (w.length + 1) / math.max(1, total);
        out.add(WordTiming(w, t, t + d));
        t += d;
      }
    }
    return out;
  }

  // ------------------------------------------------------------ 3. storyboard

  List<Map<String, dynamic>> _mediaList() => [
        for (final m in p.media.values)
          if (m.type != MediaType.audio && !m.name.endsWith('(subject)') && !m.name.endsWith('(background)'))
            {
              'id': m.id,
              'type': m.type.name,
              if (m.duration > 0) 'seconds': double.parse(m.duration.toStringAsFixed(1)),
              'about': m.description.isEmpty ? m.name : m.description,
            },
        ...LibraryDirector.mediaEntries(p), // Library (Agent G): "lib:<id>" assets, imported on use in prepare()
      ];

  Future<(List<Beat>, String)> plan(DirectorInput o, NarrationResult n) async {
    final s = await AiSettings.load();
    await LibraryDirector.warmUp(); // Library (Agent G)
    final beats = <Beat>[];
    var look = o.look;
    final used = <String, int>{};
    const chunk = 30;
    for (int i = 0; i < n.lines.length; i += chunk) {
      final end = math.min(n.lines.length, i + chunk);
      status('Planning shots ${i + 1}–$end of ${n.lines.length}…');
      final payload = {
        'frame': [c.comp.width, c.comp.height],
        'presenter_on_camera': n.arollLayer != null,
        'brief': o.brief,
        'style_notes': s.styleNotes,
        'media': _mediaList(),
        'media_used_so_far': used,
        if (i > 0) 'previous_visuals': [for (final b in beats.skip(math.max(0, beats.length - 4))) b.visual],
        'lines': [for (int k = i; k < end; k++) {'i': k, 'start': _r(n.lines[k].$1), 'end': _r(n.lines[k].$2), 'text': n.lines[k].$3}],
      };
      final raw = await AiClient.complete(s: s, system: directorPrompt(cutouts: o.depth), messages: [AiMessage('user', jsonEncode(payload))]);
      final j = _json(raw);
      if (i == 0 && look == 'auto' && j['look'] is String) look = '${j['look']}';
      for (final b in (j['beats'] as List? ?? const [])) {
        final m = b as Map;
        final k = (m['i'] as num?)?.toInt() ?? -1;
        if (k < 0 || k >= n.lines.length) continue;
        final v = Map<String, dynamic>.from(m['visual'] as Map? ?? {'aroll': true});
        if (v['media'] is String) used['${v['media']}'] = (used['${v['media']}'] ?? 0) + 1;
        beats.add(Beat(n.lines[k].$1, n.lines[k].$2, n.lines[k].$3, v));
      }
    }
    // Lines the AI skipped stay on the presenter (or get the previous visual's look).
    final have = beats.map((b) => b.start).toSet();
    for (final l in n.lines) {
      if (!have.contains(l.$1)) beats.add(Beat(l.$1, l.$2, l.$3, {'aroll': true}));
    }
    beats.sort((a, b) => a.start.compareTo(b.start));
    if (n.arollLayer == null) _fillGaps(beats);
    return (beats, look == 'auto' ? 'cinematic_doc' : look);
  }

  /// Without a presenter, a beat on "aroll" would be a black frame: reuse
  /// the previous visual or put up a glowing key word.
  void _fillGaps(List<Beat> beats) {
    Map<String, dynamic>? last;
    for (final b in beats) {
      if (b.visual['aroll'] == true) {
        if (last != null && last['media'] != null && last['component'] == null) {
          b.visual = {...last, 'move': 'pull_out', 'transition': 'fade', 'sfx': 'none'};
        } else {
          final word = b.line.split(RegExp(r'\s+')).reduce((a, x) => x.length > a.length ? x : a);
          b.visual = {'component': 'glow_word', 'text': word.replaceAll(RegExp(r'[^\wऀ-ॿ]'), '')};
        }
      } else {
        last = b.visual;
      }
    }
  }

  static double _r(double v) => double.parse(v.toStringAsFixed(2));

  /// The shot planner's system prompt. With [caps], only visuals this build
  /// can make are offered (scene/map ops come from another branch); with
  /// [chapters], the long-video rules (chapter style, running memory, fast
  /// hook, "shots") are added.
  static String directorPrompt({bool cutouts = true, Capabilities? caps, bool chapters = false}) {
    bool has(String t) => caps == null || caps.has(t);
    final threeD = caps == null || caps.has3d;
    final moves = [
      'ken_burns', 'push_in', 'pull_out', 'pan_left', 'pan_right', 'parallax',
      if (cutouts) 'depth',
      if (threeD) ...StoryBuilder.moves3d,
    ];
    final trans = [
      'fade', 'zoom_in', 'zoom_out', 'slide_left', 'slide_right', 'whip', 'blur', 'pop', 'shatter',
      'iris', 'ink', 'smoke', 'flash', 'glitch_flash',
      if (has('foreground_wipe')) 'foreground_wipe',
    ];
    final particles = caps == null || caps.particles;
    final v = <String>[
      '- {"aroll":true,"punch":<true for emphasis — a hard zoom on the presenter>}  — only if presenter_on_camera; ~25-35% of lines (opinions, jokes, questions to the viewer, transitions)',
      '- {"media":"<media id>","move":"${moves.join('|')}","transition":"${trans.join('|')}"'
          '${cutouts ? ',"behind_text":"<optional ONE dramatic word shown BETWEEN the subject and background>"' : ''}'
          ',"name_tag":{"name":"<person>","role":"<who they are>"},"label":"<SHORT TAG on the subject>"}  — name_tag and label are optional overlays: name_tag ONLY when a person is first introduced, label to tag a character in the picture',
      if (cutouts)
        '  "depth" cuts the subject out and moves it separately from the background (3D parallax). Use it ONLY on photos whose "about" says "clear subject" — great for people introduced, hooks and dramatic moments, at most ~1 in 6 lines.',
      if (threeD)
        '  3D camera moves for scenic stills (the photo becomes a 3D scene${cutouts ? ', subject cut out when it has a clear subject' : ''}): "drift" slow float, "fly_to" glide towards the subject, "push_through" fast push into a door/window/the subject (a cut), "pass_by" sideways past it, "reveal" from behind, "pull_back" from an extreme close-up, "orbit" around it. At most ~1 in 5 lines.',
      '  "ink"/"smoke"/"iris" are soft story transitions, "flash"/"glitch_flash" hard hits${has('foreground_wipe') ? ', "foreground_wipe" hides a cut behind something sweeping past the lens' : ''}.',
      '- {"component":"source_card","source":"Source: <site>","headline":"...","body":"<the cited claim, 1-3 sentences>","highlights":["<key phrase from body>"],"circle":"<date or number from body>"}  — when a line cites a report, article, book or "according to" and you have NO screenshot of it',
      '- {"component":"lower_third","source":"Source: <site>","text":"...","highlights":["..."],"over_aroll":true}',
      '- {"component":"map","countries":["<English country names>"],"focus":"<country>","style":"dark|paper|blue","route":["<from country>","<to country>"],"pin":"<optional label pinned on the focus>"}  — places/countries/borders; "route" draws an arrow between two countries',
      '- {"component":"badge","label":"<ORGANISATION / PARTY / AGENCY>","media":"<optional logo/photo media id>"}',
      '- {"component":"counter","from":0,"to":<number>,"prefix":"\$ or ₹ or \'\'","suffix":" CRORE / % / BARRELS …"}  — when a big number is spoken',
      '- {"component":"timeline","from":<decade start>,"to":<decade end>,"marker":<year>,"label":"<MON YYYY>"}  — when a year/date matters',
      '- {"component":"glow_word","text":"<ONE KEY WORD>"}  — a dramatic single word',
      '- {"component":"speech_bubble","text":"\\"<short quote>\\""}  — a quoted statement',
      '- {"component":"photo_card","media":"<image id>","caption":"<name>"}  — a person or object introduced',
      '- {"component":"cta","text":"<Subscribe / Comment …>","over_aroll":true}  — once, near the end',
      if (has('title_slam'))
        '- {"component":"title_slam","title":"<2-3 WORDS>","subtitle":"<1 WORD>"}  — ONLY as the very first line when the video opens with a punchy title (impact sound → silence → music drop)',
      if (has('article'))
        '- {"component":"article","media":"<screenshot/newspaper/document media id>","marks":[{"phrase":"<exact words visible in that screenshot>","style":"highlight|circle|underline|redact"}],"coming_up":false}  — when a line quotes or cites an article, post or document you HAVE as media; 1-2 marks; the app finds each phrase in the screenshot; "redact" hides a word (add "word" to reveal it)',
      if (has('name_tag'))
        '- {"component":"name_tag","name":"<person>","role":"<role>","over_aroll":true}  — introduce the presenter or someone on screen (first appearance only)',
      if (has('date_title'))
        '- {"component":"date_title","text":"<YEAR or DATE>","subtitle":"<optional place/name>"}  — a dramatic jump in time',
      if (has('number_tiles'))
        '- {"component":"number_tiles","text":"<short number/year like 200 or 1996>","word":"<optional word after, e.g. YEARS AGO>"}  — a striking number or year',
      if (has('icon_stream'))
        '- {"component":"icon_stream","icons":["<media ids of logos/flags/items or short emoji>"]}  — money/data/goods/people flowing from one place to another',
      if (has('scanner'))
        '- {"component":"scanner","logo":"<logo media id>","targets":[{"media":"<face/photo id>","label":"<NAME>"}]}  — "who is involved": an agency/company watching, searching or choosing people',
      if (has('silhouette_crowd'))
        '- {"component":"silhouette_crowd","media":["<person photo ids>"],"labels":["<SHORT LABELS>"],"highlight":<index of the one to keep in colour, or -1>}  — groups, victims, workers, "millions of people"',
      if (has('glass_screen'))
        '- {"component":"glass_screen","media":["<footage/photo ids>"]}  — a montage: websites, apps, news footage shown on a curved glass screen (3-5 media in one shot)',
      if (has('plaque'))
        '- {"component":"plaque","name":"<NAME>","dates":"<YYYY – YYYY>","text":"<short epitaph>"}  — a death or memorial',
      if (has('poster'))
        '- {"component":"poster","title":"<WANTED / JOBS …>","subtitle":"...","media":"<optional image id>"}  — old adverts, recruitment, propaganda',
      if (has('route_follow'))
        '- {"component":"route_follow","from":"<country>","to":"<country>","avatar":"<optional face media id>"}  — a journey, migration, trade or escape route',
      if (has('map_fly'))
        '- {"component":"map_fly","from":"<country>","to":"<country>"}  — the story moves from one country to another',
      if (has('needle_pin'))
        '- {"component":"needle_pin","country":"<country>","label":"<place>"}  — pin one place on a map',
    ];
    final opt = [
      '"sfx":"whoosh|hit|riser|pop|tick|none" (defaults are chosen for you; use "riser" before the big reveal of the hook, "none" to keep a moment quiet)',
      if (particles) '"atmosphere":"rain|confetti|dust|leaves|snow|smoke|bokeh|none" (particles over the shot; chapters already get one from their mood)',
    ];
    final long = chapters
        ? '''

LONG VIDEO (chapter mode)
- The message gives "chapter" (title, kind, mood, look, recurring_media, places, date, idea) and the running memory: "media_used_so_far", "last_visuals", "people_already_introduced", "components_used_so_far". Plan ONLY the given lines.
- Keep the chapter's style: reuse its recurring_media, use its places for map moments${has('map_fly') || has('route_follow') ? ' (map_fly/route_follow/needle_pin)' : ' (map with route/pin)'}, match its mood.
- Pacing: in a "hook" chapter cut every 1-2 s — give a line several shots: {"i":k,"shots":[{visual},{visual}]} instead of "visual". Later lines get one 3-5 s shot each; a long line may use "shots" too.
- Never repeat anything in last_visuals; no component type on more than 1 in 4 shots; never a name_tag for people_already_introduced.
- The app adds chapter title cards and pattern interrupts (flash inserts, punch-ins) itself — do not add title cards at the chapter start.
- If "editor_note" is given, it is the channel owner's feedback on this chapter: follow it.'''
        : '';
    return '''
You are the DIRECTOR and EDITOR of a Hindi/English documentary explainer channel. You turn narration lines into a storyboard: one visual per line, timed to the words.
Return ONLY JSON: {"look":"cinematic_doc|retro_film|noir|warm_travel|clean_minimal|shorts_punch","beats":[{"i":<line index>,"visual":{...}}]}

VISUALS (pick ONE per line):
${v.join('\n')}
Optional on any visual: ${opt.join('; ')}.

DIRECTING RULES
- Plan from "about" (what is IN each picture), not the file name. A visual must match what the line says. Never invent media ids.
- Hook (first 3-4 lines): the strongest visuals — depth shot, counter, map or glow word; fast cuts.
- Keep the eye moving: never the same component type or same media on two lines in a row; use each media at most twice (see media_used_so_far).
- Text on screen must be short, factual and ONLY from the narration line — never add facts.
- Use transitions with intent: "fade" by default, "whip"/"slide" for change of place or time, "zoom_in" into details, "shatter" at most once for a dramatic break.
- Prefer the specific documentary visuals above when they fit the line (article for quotes you have screenshots of, name_tag for introductions, maps for movement between places, number_tiles/date_title for big numbers and years, icon_stream for flows, scanner for who is involved, silhouette_crowd for groups, glass_screen for montages); never invent screenshots or faces.
- If there's no presenter, every line needs a real visual.
- Follow style_notes from the channel owner when given; they override these defaults.$long''';
  }

  // ------------------------------------------------------------ 3b. Director v2 (long videos)

  /// Variety score of the last planned (or re-planned) storyboard.
  VarietyReport? variety;

  Future<Storyboard?> loadStoryboard() async {
    try {
      return await StoryboardStore.load(await c.storage.mediaDir(), p.id);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveStoryboard(Storyboard sb) async {
    try {
      await StoryboardStore.save(await c.storage.mediaDir(), sb);
    } catch (_) {
      // Saving is best-effort; planning goes on.
    }
  }

  Future<void> discardStoryboard() async {
    try {
      await StoryboardStore.clear(await c.storage.mediaDir(), p.id);
    } catch (_) {}
  }

  static Map<String, dynamic> inputJson(DirectorInput o) => {
        'brief': o.brief,
        'script': o.script,
        'narration': o.narration.name,
        if (o.arollMedia != null) 'aroll': o.arollMedia,
        if (o.voiceMedia != null) 'voice': o.voiceMedia,
        if (o.musicMedia != null) 'music': o.musicMedia,
        'language': o.language,
        'roman': o.roman,
        'captions': o.captions,
        'sfx': o.sfx,
        'depth': o.depth,
        'review': o.review,
        'look': o.look,
      };

  /// Restores the form of a saved storyboard (for Resume / Rebuild).
  static void applyInput(DirectorInput o, Map<String, dynamic> j) {
    String str(String k, String d) => j[k] is String ? '${j[k]}' : d;
    bool flag(String k, bool d) => j[k] is bool ? j[k] as bool : d;
    o
      ..brief = str('brief', o.brief)
      ..script = str('script', o.script)
      ..narration = Narration.values.firstWhere((n) => n.name == j['narration'], orElse: () => o.narration)
      ..arollMedia = j['aroll'] as String? ?? o.arollMedia
      ..voiceMedia = j['voice'] as String? ?? o.voiceMedia
      ..musicMedia = j['music'] as String? ?? o.musicMedia
      ..language = str('language', o.language)
      ..roman = flag('roman', o.roman)
      ..captions = flag('captions', o.captions)
      ..sfx = flag('sfx', o.sfx)
      ..depth = flag('depth', o.depth)
      ..review = flag('review', o.review)
      ..look = str('look', o.look);
  }

  /// The narration of a saved storyboard, re-placing the presenter or the
  /// voice-over when its layer was removed (same media → same timings).
  Future<NarrationResult> resumeNarration(Storyboard sb, DirectorInput o) async {
    var aroll = sb.arollLayer;
    if (aroll != null && c.comp.layerById(aroll) == null) {
      final m = p.media[o.arollMedia];
      if (m == null) throw AiException('The presenter video of this storyboard is gone. Start again.');
      aroll = await _placeNarration(m, true);
      sb.arollLayer = aroll;
    }
    if (o.narration == Narration.voiceover) {
      final m = p.media[o.voiceMedia];
      if (m != null && !c.comp.layers.any((l) => l.mediaId == m.id)) await _placeNarration(m, false);
    }
    if (o.narration == Narration.phoneVoice && !c.comp.layers.any((l) => l.type == LayerType.audio && l.name.startsWith('Voice '))) {
      throw AiException('The AI voice clips of this storyboard were removed. Start again.');
    }
    return NarrationResult(sb.lines, sb.words, aroll);
  }

  Map<String, dynamic> _basePayload(DirectorInput o, bool presenter, String styleNotes) => {
        'frame': [c.comp.width, c.comp.height],
        'presenter_on_camera': presenter,
        'brief': o.brief,
        if (styleNotes.isNotEmpty) 'style_notes': styleNotes,
        'media': _mediaList(),
      };

  /// Photos the depth step will try to cut out.
  Set<String> _cutoutCandidates(DirectorInput o) => o.depth
      ? {for (final m in p.media.values) if (m.type == MediaType.image && m.description.contains('clear subject')) m.id}
      : <String>{};

  StoryPlanner _planner(AiSettings s, CancelToken? cancel) => StoryPlanner(
        (system, user) => AiClient.complete(s: s, system: system, messages: [AiMessage('user', user)]),
        status: status,
        cancel: cancel,
      );

  VarietyReport _finishPlan(Storyboard sb, DirectorInput o, Capabilities caps, {int? only}) {
    if (!MotionPresets.styles.contains(sb.look)) sb.look = MotionPresets.styles.contains(o.look) ? o.look : 'cinematic_doc';
    for (final ch in sb.chapters) {
      if (ch.look.isNotEmpty && !MotionPresets.styles.contains(ch.look)) ch.look = '';
    }
    return variety = StoryPlanner.finish(p, sb, caps: caps, presenter: sb.arollLayer != null, cutouts: _cutoutCandidates(o), only: only);
  }

  /// Plans a long video: chapters first, then shots chapter by chapter with
  /// a running memory, saving after every chapter. Pass a saved storyboard
  /// as [resume] to continue where it stopped.
  Future<Storyboard> planStoryboard(DirectorInput o, NarrationResult n,
      {Storyboard? resume, CancelToken? cancel, void Function(Storyboard)? onProgress}) async {
    final s = await AiSettings.load();
    await LibraryDirector.warmUp(); // Library (Agent G): "lib:<id>" assets in the media list
    final caps = Capabilities();
    final sb = resume ??
        Storyboard(projectId: p.id, look: o.look, lines: n.lines, words: n.words, arollLayer: n.arollLayer, input: inputJson(o));
    sb.arollLayer = n.arollLayer;
    final planner = _planner(s, cancel);
    if (!sb.outlined) {
      await planner.outline(sb, brief: o.brief, styleNotes: s.styleNotes, media: _mediaList(), looks: MotionPresets.styles);
      await saveStoryboard(sb);
      onProgress?.call(sb);
    }
    final system = directorPrompt(cutouts: o.depth, caps: caps, chapters: true);
    final base = _basePayload(o, n.arollLayer != null, s.styleNotes);
    for (final ch in sb.chapters) {
      if (ch.planned) continue;
      cancel?.check();
      ch.status = 'planning';
      onProgress?.call(sb);
      try {
        final beats = await planner.planChapter(sb, ch.index, system: system, base: base);
        sb.replaceChapter(ch.index, beats);
      } on DirectorCancelled {
        ch.status = 'pending';
        await saveStoryboard(sb);
        rethrow;
      } catch (e) {
        ch.status = 'failed';
        ch.error = '$e';
        await saveStoryboard(sb);
        onProgress?.call(sb);
        rethrow;
      }
      sb.stage = 'planning';
      await saveStoryboard(sb);
      onProgress?.call(sb);
    }
    _finishPlan(sb, o, caps);
    sb.stage = 'planned';
    await saveStoryboard(sb);
    onProgress?.call(sb);
    return sb;
  }

  /// Cut-outs, sound effects and the build of a planned storyboard.
  Future<int> buildStoryboard(Storyboard sb, DirectorInput o, NarrationResult n) async {
    final opts = await prepare(sb.beats, o, n, MotionPresets.styles.contains(sb.look) ? sb.look : 'cinematic_doc');
    opts
      ..tag = sb.tag
      ..chapters = sb.chapters
      ..caps = Capabilities();
    status('Building ${sb.chapters.length} chapters…');
    final dropped = build(sb.beats, opts);
    for (final ch in sb.chapters) {
      ch.status = 'built';
    }
    sb.stage = 'built';
    await saveStoryboard(sb);
    return dropped;
  }

  /// Re-plans (unless [replan] is false) and rebuilds one chapter; the rest
  /// of the edit is untouched. One Undo removes the change.
  Future<int> rebuildChapter(Storyboard sb, int chapter, DirectorInput o, {String note = '', bool replan = true, CancelToken? cancel}) async {
    final s = await AiSettings.load();
    final caps = Capabilities();
    final ch = sb.chapters.firstWhere((x) => x.index == chapter);
    if (replan) {
      final beats = await _planner(s, cancel).planChapter(
        sb,
        chapter,
        system: directorPrompt(cutouts: o.depth, caps: caps, chapters: true),
        base: _basePayload(o, sb.arollLayer != null, s.styleNotes),
        note: note,
      );
      sb.replaceChapter(chapter, beats);
      _finishPlan(sb, o, caps, only: chapter);
      await saveStoryboard(sb);
    }
    cancel?.check();
    final n = NarrationResult(sb.lines, sb.words, sb.arollLayer);
    final opts = await prepare(sb.beatsOf(chapter), o, n, MotionPresets.styles.contains(sb.look) ? sb.look : 'cinematic_doc');
    opts
      ..tag = sb.tag
      ..chapters = sb.chapters
      ..caps = caps;
    status('Rebuilding chapter ${chapter + 1}: ${ch.title}…');
    var dropped = 0;
    var err = c.tryRun({'op': 'batch', 'commands': StoryBuilder.rebuildChapter(p, sb.beats, opts, chapter)});
    if (err != null) {
      dropped = _dropFailing(sb.beatsOf(chapter), opts);
      err = c.tryRun({'op': 'batch', 'commands': StoryBuilder.rebuildChapter(p, sb.beats, opts, chapter)});
      if (err != null) throw AiException('Could not rebuild chapter ${chapter + 1}: $err');
    }
    ch.status = 'built';
    await saveStoryboard(sb);
    return dropped;
  }

  /// Review, chapter by chapter: a few rendered frames of each chapter and
  /// only that chapter's layers go to the AI, which fixes what looks wrong.
  Future<String> reviewChapters(Storyboard sb, Future<List<(double, Uint8List)>> Function(List<double> times) render,
      {int perChapter = 3, CancelToken? cancel, void Function(int chapter)? onChapter, Set<int>? only}) async {
    final s = await AiSettings.load();
    final notes = <String>[];
    for (final ch in sb.chapters) {
      if (only != null && !only.contains(ch.index)) continue;
      cancel?.check();
      onChapter?.call(ch.index);
      final kept = sb.beatsOf(ch.index).where((b) => b.keep).toList()..sort((a, b) => a.start.compareTo(b.start));
      final pick = samplePick(kept, perChapter);
      if (pick.isEmpty) continue;
      status('Watching chapter ${ch.index + 1}/${sb.chapters.length}: ${ch.title}…');
      final frames = await render([for (final b in pick) b.start + math.min(1.2, (b.end - b.start) * 0.6)]);
      if (frames.isEmpty) continue;
      cancel?.check();
      final (t0, t1) = sb.rangeOf(ch.index);
      final state = jsonEncode(chapterSummary(EditAgent.projectSummary(c), t0, t1));
      final convo = [
        AiMessage(
          'user',
          'DIRECTOR REVIEW of chapter ${ch.index + 1} "${ch.title}" (${_r(t0)}–${_r(t1)} s, mood ${ch.mood}). The attached images are rendered frames at '
          '${frames.map((f) => f.$1.toStringAsFixed(1)).join(', ')} s. Narration at those times: '
          '${jsonEncode([for (final b in pick) {'t': _r(b.start), 'line': b.line}])}.\n'
          'Check each frame like a senior editor: text cut off or outside the frame, text overlapping captions or other text, '
          'unreadable text (too small, low contrast), black or empty frames, a picture that obviously does not match its line, '
          'a subject\'s face covered by graphics, the same picture or graphic repeated. Fix only real problems in THIS chapter with edit commands '
          '(move/resize/recolor/retime layers, swap media with replace_media). If everything is fine return "commands": []. '
          'Put a 1-sentence verdict in "reply".\n\nTHIS CHAPTER\'S LAYERS (JSON):\n$state',
          images: [for (final f in frames) f.$2],
        ),
      ];
      var note = '';
      for (int attempt = 0; attempt < 2; attempt++) {
        final raw = await AiClient.complete(s: s, system: commandSpec, messages: convo);
        final j = _json(raw);
        note = '${j['reply'] ?? ''}'.trim();
        final cmds = (j['commands'] as List?) ?? const [];
        if (cmds.isEmpty) break;
        final err = c.tryRun({'op': 'batch', 'commands': cmds}, record: false);
        if (err == null) break;
        convo
          ..add(AiMessage('assistant', raw))
          ..add(AiMessage('user', 'Rejected, nothing changed: $err\nReturn the corrected JSON.'));
      }
      if (note.isNotEmpty) notes.add('${ch.index + 1}. ${ch.title}: $note');
    }
    return notes.join('\n');
  }

  /// Up to [n] beats spread evenly over [beats].
  static List<Beat> samplePick(List<Beat> beats, int n) {
    if (beats.length <= n) return [...beats];
    final out = <Beat>[];
    for (int i = 0; i < n; i++) {
      final b = beats[(i * beats.length / n).floor()];
      if (!out.contains(b)) out.add(b);
    }
    return out;
  }

  /// The project summary cut down to the layers active in [t0, t1].
  static Map<String, dynamic> chapterSummary(Map<String, dynamic> full, double t0, double t1) {
    double toD(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
    final layers = [
      for (final l in (full['layers_top_to_bottom'] as List? ?? const []))
        if (l is Map && toD(l['end']) > t0 && toD(l['start']) < t1) l,
    ];
    final used = {for (final l in layers) l['media']};
    return {
      ...full,
      'chapter_range': [t0, t1],
      'media': [for (final m in (full['media'] as List? ?? const [])) if (m is Map && used.contains(m['id'])) m],
      'layers_top_to_bottom': layers,
    };
  }

  // ------------------------------------------------------------ 4. tools

  /// Cut-outs for depth shots and synthesised sound effects, registered as
  /// project media.
  Future<BuildOptions> prepare(List<Beat> beats, DirectorInput o, NarrationResult n, String look) async {
    final dir = await c.storage.mediaDir();
    await LibraryDirector.importUsed(p, [for (final b in beats) b.visual], dir); // Library (Agent G): lib:<id> → project media
    final cutouts = <String, (String, String)>{};
    if (o.depth) {
      final want = {
        for (final b in beats)
          if (b.keep && b.visual['move'] == 'depth' && b.visual['media'] is String && p.media[b.visual['media']]?.type == MediaType.image)
            '${b.visual['media']}',
      };
      var k = 0;
      for (final id in want) {
        k++;
        status('Cutting out subjects for depth shots… $k/${want.length}');
        final m = p.media[id]!;
        try {
          final stamp = DateTime.now().millisecondsSinceEpoch;
          final fgPath = '$dir/cut_${stamp}_fg.png', bgPath = '$dir/cut_${stamp}_bg.jpg';
          final (w, h) = await MediaBridge.cutout(m.path, fgPath, bgPath);
          final fg = MediaAsset(id: Ids.next('img'), type: MediaType.image, path: fgPath, name: '${m.name} (subject)', width: w.toDouble(), height: h.toDouble());
          final bg = MediaAsset(id: Ids.next('img'), type: MediaType.image, path: bgPath, name: '${m.name} (background)', width: w.toDouble(), height: h.toDouble());
          p.media[fg.id] = fg;
          p.media[bg.id] = bg;
          cutouts[id] = (fg.id, bg.id);
        } catch (_) {
          // No clear subject: the builder falls back to a push-in.
        }
      }
    }
    await _locatePhrases(beats);
    final sfx = <String, String>{};
    if (o.sfx) {
      status('Making sound effects…');
      for (final kind in Sfx.kinds) {
        final existing = p.media.values.where((m) => m.name == 'SFX $kind' && File(m.path).existsSync()).toList();
        if (existing.isNotEmpty) {
          sfx[kind] = existing.first.id;
          continue;
        }
        final path = '$dir/sfx_$kind.wav';
        await File(path).writeAsBytes(Sfx.wav(kind));
        final a = MediaAsset(id: Ids.next('sfx'), type: MediaType.audio, path: path, name: 'SFX $kind', width: 0, height: 0, duration: Sfx.length(kind));
        p.media[a.id] = a;
        sfx[kind] = a.id;
      }
    }
    c.mediaChanged();
    return BuildOptions(
      arollLayer: n.arollLayer,
      musicMedia: o.musicMedia,
      speech: StoryBuilder.speechFromWords(n.words),
      sfxMedia: sfx,
      cutouts: cutouts,
      captionWords: o.captions ? n.words : null,
      captions: CaptionOptions(language: o.language == 'auto' ? null : o.language, roman: o.roman, style: 'karaoke'),
      look: look,
    );
  }

  /// Article beats name phrases; find them in the screenshot with vision so
  /// the highlights land on the right words.
  Future<void> _locatePhrases(List<Beat> beats) async {
    final todo = [
      for (final b in beats)
        if (b.keep && b.visual['component'] == 'article' && b.visual['marks'] is List && (b.visual['marks'] as List).any((m) => m is Map && m['phrase'] is String && m['box'] == null && m['boxes'] == null))
          b,
    ];
    if (todo.isEmpty) return;
    final s = await AiSettings.load();
    var k = 0;
    for (final b in todo) {
      k++;
      status('Finding the quoted words in the screenshots… $k/${todo.length}');
      final media = b.visual['media'];
      final m = p.media[media is List ? (media.isEmpty ? '' : '${media.first}') : '$media'];
      final marks = [for (final x in b.visual['marks'] as List) if (x is Map) Map<String, dynamic>.from(x)];
      if (m == null || m.type != MediaType.image) {
        b.visual = {...b.visual, 'marks': [for (final x in marks) if (x['box'] != null || x['boxes'] != null) x]};
        continue;
      }
      try {
        final img = await thumbnail(m, size: 1600);
        if (img == null) throw AiException('no image');
        final resolved = await PhraseFinder.resolveMarks(settings: s, image: img, marks: marks, width: m.width, height: m.height);
        b.visual = {...b.visual, 'marks': resolved};
      } catch (_) {
        b.visual = {...b.visual, 'marks': [for (final x in marks) if (x['box'] != null || x['boxes'] != null) x]};
      }
    }
  }

  // ------------------------------------------------------------ 5. build

  /// Applies the storyboard. Beats whose commands fail are dropped instead
  /// of failing the whole video. Returns the number of dropped beats.
  int build(List<Beat> beats, BuildOptions o) {
    if (c.tryRun({'op': 'batch', 'commands': StoryBuilder.build(p, beats, o)}, record: false) == null) return 0;
    status('Fixing a few shots that didn\'t fit…');
    final dropped = _dropFailing(beats, o);
    var err = c.tryRun({'op': 'batch', 'commands': StoryBuilder.build(p, beats, o)}, record: false);
    if (err != null && o.chapters.isNotEmpty && o.caps?.particles != false) {
      // Last resort: without the atmosphere particles.
      o.caps = Capabilities(particles: false);
      err = c.tryRun({'op': 'batch', 'commands': StoryBuilder.build(p, beats, o)}, record: false);
    }
    if (err != null) throw AiException('Build failed: $err');
    return dropped;
  }

  /// Finds the beats that fail on their own (on a snapshot) and unticks them.
  int _dropFailing(List<Beat> beats, BuildOptions o) {
    final snap = ProjectSnapshot.take(p);
    final bad = <Beat>{};
    var k = 0;
    for (final b in beats.where((b) => b.keep)) {
      final one = StoryBuilder.build(p, [b], BuildOptions(arollLayer: o.arollLayer, cutouts: o.cutouts, caps: o.caps, tag: '${o.tag}t${k++}'));
      try {
        EditCommands.runAtomic(p, {'op': 'batch', 'commands': one});
      } on CommandError {
        bad.add(b);
      }
    }
    ProjectSnapshot.restore(p, snap);
    for (final b in bad) {
      b.keep = false;
    }
    return bad.length;
  }

  // ------------------------------------------------------------ 6. review

  /// Shows the AI rendered frames and lets it fix what looks wrong
  /// (unreadable text, overlaps, black frames, a picture that doesn't match).
  Future<String> review(List<Beat> beats, Future<List<(double, Uint8List)>> Function(List<double> times) render,
      {int rounds = 1}) async {
    final s = await AiSettings.load();
    final kept = beats.where((b) => b.keep).toList();
    if (kept.isEmpty) return '';
    final pick = <Beat>[];
    final step = math.max(1, kept.length ~/ 8);
    for (int i = 0; i < kept.length && pick.length < 8; i += step) {
      pick.add(kept[i]);
    }
    var notes = '';
    for (int r = 0; r < rounds; r++) {
      status('Watching the edit…');
      final times = [for (final b in pick) b.start + math.min(1.2, (b.end - b.start) * 0.6)];
      final frames = await render(times);
      if (frames.isEmpty) return notes;
      status('Reviewing frames…');
      final state = jsonEncode(EditAgent.projectSummary(c));
      final convo = [
        AiMessage(
          'user',
          'DIRECTOR REVIEW. The attached images are rendered frames of the edit at times '
          '${frames.map((f) => f.$1.toStringAsFixed(1)).join(', ')} s. Narration at those times: '
          '${jsonEncode([for (final b in pick) {'t': _r(b.start), 'line': b.line}])}.\n'
          'Check each frame like a senior editor: text cut off or outside the frame, text overlapping captions or other text, '
          'unreadable text (too small, low contrast), black or empty frames, a picture that obviously does not match its line, '
          'a subject\'s face covered by graphics. Fix only real problems with edit commands (move/resize/recolor/retime layers, '
          'swap media with replace_media). If everything is fine return "commands": []. Put a 1-2 sentence verdict in "reply".\n\n'
          'CURRENT PROJECT (JSON):\n$state',
          images: [for (final f in frames) f.$2],
        ),
      ];
      for (int attempt = 0; attempt < 2; attempt++) {
        final raw = await AiClient.complete(s: s, system: commandSpec, messages: convo);
        final j = _json(raw);
        notes = '${j['reply'] ?? ''}'.trim();
        final cmds = (j['commands'] as List?) ?? const [];
        if (cmds.isEmpty) return notes;
        final err = c.tryRun({'op': 'batch', 'commands': cmds}, record: false);
        if (err == null) break;
        convo
          ..add(AiMessage('assistant', raw))
          ..add(AiMessage('user', 'Rejected, nothing changed: $err\nReturn the corrected JSON.'));
      }
    }
    return notes;
  }

  static Map<String, dynamic> _json(String raw) {
    final j = JsonRepair.tryDecode(raw);
    if (j != null) return j;
    throw AiException(raw.contains('{') ? 'The AI\'s answer was cut off or malformed. Try again.' : 'The AI answered without JSON. Try again.');
  }
}
