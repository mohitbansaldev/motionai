import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/ai/ai_client.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/components.dart';
import 'package:motionai/core/presets/world_map.dart';
import 'package:motionai/director/capabilities.dart';
import 'package:motionai/director/chapters.dart';
import 'package:motionai/director/director.dart';
import 'package:motionai/director/json_repair.dart';
import 'package:motionai/director/pacing.dart';
import 'package:motionai/director/planner.dart';
import 'package:motionai/director/sfx.dart';
import 'package:motionai/director/story_builder.dart';
import 'package:motionai/director/storyboard.dart';
import 'package:motionai/director/variety.dart';

Project project({double presenterSeconds = 300}) {
  final p = Project(id: 'p', name: 'Doc', main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: 5));
  for (int i = 0; i < 10; i++) {
    p.media['img$i'] = MediaAsset(
        id: 'img$i', type: MediaType.image, path: '/i$i.jpg', name: 'photo $i', width: 1600, height: 1000, description: '[place] gold mine number $i');
  }
  p.media['fg'] = MediaAsset(id: 'fg', type: MediaType.image, path: '/fg.png', name: 'photo 2 (subject)', width: 1600, height: 1000);
  p.media['bg'] = MediaAsset(id: 'bg', type: MediaType.image, path: '/bg.jpg', name: 'photo 2 (background)', width: 1600, height: 1000);
  p.media['shot'] = MediaAsset(id: 'shot', type: MediaType.image, path: '/s.png', name: 'article', width: 1080, height: 2400, description: '[screenshot] news article');
  p.media['logo'] = MediaAsset(id: 'logo', type: MediaType.image, path: '/l.png', name: 'logo', width: 512, height: 512, description: '[logo] bank');
  p.media['clipb'] = MediaAsset(id: 'clipb', type: MediaType.video, path: '/b.mp4', name: 'footage', width: 1920, height: 1080, duration: 12, description: '[footage] river');
  p.media['clip'] = MediaAsset(id: 'clip', type: MediaType.video, path: '/v.mp4', name: 'talk', width: 1920, height: 1080, duration: presenterSeconds);
  p.media['music'] = MediaAsset(id: 'music', type: MediaType.audio, path: '/m.mp3', name: 'music', width: 0, height: 0, duration: 60);
  for (final k in Sfx.kinds) {
    p.media['sfx_$k'] = MediaAsset(id: 'sfx_$k', type: MediaType.audio, path: '/$k.wav', name: 'SFX $k', width: 0, height: 0, duration: Sfx.length(k));
  }
  EditCommands.runAtomic(p, {'op': 'add_layer', 'type': 'video', 'media': 'clip', 'id': 'aroll', 'start': 0, 'fit': 'cover'});
  return p;
}

List<(double, double, String)> lines(int n, {double each = 4}) =>
    [for (int i = 0; i < n; i++) (i * each, i * each + each - 0.2, 'Line $i about the gold rush and the money')];

void main() {
  setUpAll(() => WorldMap.load(File('assets/world_countries.json').readAsStringSync()));

  group('JSON repair', () {
    test('code fences, prose and trailing commas', () {
      final j = JsonRepair.decode('Here you go:\n```json\n{"a": [1, 2, 3,], "b": {"c": "x",},}\n```\nThanks!');
      expect(j['a'], [1, 2, 3]);
      expect((j['b'] as Map)['c'], 'x');
    });

    test('a cut-off answer keeps every complete item', () {
      final full = jsonEncode({
        'look': 'noir',
        'beats': [for (int i = 0; i < 10; i++) {'i': i, 'visual': {'media': 'img$i', 'move': 'push_in', 'text': 'a, b } c'}}],
      });
      final cut = full.substring(0, full.length * 2 ~/ 3);
      final j = JsonRepair.decode(cut);
      expect(j['look'], 'noir');
      final beats = j['beats'] as List;
      expect(beats.length, greaterThanOrEqualTo(5));
      expect(beats.length, lessThan(10));
      for (final b in beats) {
        expect((b as Map)['visual'], isA<Map>());
      }
      expect(JsonRepair.tryDecode('no json here'), isNull);
    });
  });

  group('chapters', () {
    test('outline parsing: sorted, clamped, no gaps or overlaps', () {
      final j = JsonRepair.decode('''```json
{"title":"Gold Rush","chapters":[
 {"title":"Crash","kind":"conflict","first":20,"last":80,"mood":"sad",},
 {"title":"Hook","kind":"hook","first":0,"last":3},
 {"title":"Context","kind":"Turning Point","first":"6","last":25,"mood":"history","date":"1848","set":["img1","nope"]},
 {"title":"Swallowed","first":7,"last":9},
]}
```''');
      final ch = ChapterPlanner.parseOutline(j, 60, mediaIds: {'img1'});
      expect(ch.length, 3);
      expect([for (final c in ch) c.title], ['Hook', 'Context', 'Crash']);
      expect([for (final c in ch) [c.first, c.last]], [[0, 5], [6, 25], [26, 59]]);
      expect(ch[1].kind, 'turning_point');
      expect(ch[1].atmosphere, 'dust');
      expect(ch[2].atmosphere, 'rain');
      expect(ch[1].set, ['img1']);
      expect([for (final c in ch) c.index], [0, 1, 2]);
      expect(ChapterPlanner.parseOutline({'chapters': 'nope'}, 10), isEmpty);
    });

    test('heuristic split of a 20 minute script', () {
      final l = lines(300); // 20 minutes
      final ch = ChapterPlanner.heuristic(l);
      expect(ch.first.kind, 'hook');
      expect(l[ch.first.last].$2, lessThanOrEqualTo(21));
      expect(ch.last.kind, 'ending');
      expect(ch.length, inInclusiveRange(7, 14));
      expect(ch.first.first, 0);
      expect(ch.last.last, 299);
      for (int i = 1; i < ch.length; i++) {
        expect(ch[i].first, ch[i - 1].last + 1);
      }
    });
  });

  group('variety', () {
    List<Beat> repetitive() => [
          for (int i = 0; i < 12; i++)
            Beat(i * 4.0, i * 4.0 + 4, 'line $i', {'media': 'img0', 'move': 'push_in', 'transition': 'whip'}, lineIndex: i),
          Beat(48, 52, 'five hundred crore', {'component': 'counter', 'to': 500, 'suffix': ' CRORE'}, lineIndex: 12),
          Beat(52, 56, 'nine hundred', {'component': 'counter', 'to': 900}, lineIndex: 13),
        ];

    test('scores repeats and repairs them deterministically', () {
      final p = project();
      const v = Variety();
      final beats = repetitive();
      final before = v.score(beats);
      expect(before.count('media_repeat'), greaterThan(5));
      expect(before.count('move_repeat'), greaterThan(5));
      expect(before.count('transition_repeat'), greaterThan(5));
      expect(before.count('same_kind_adjacent'), 1);
      expect(before.count('media_overuse'), greaterThan(0));
      final after = v.repair(beats, MediaPool(p));
      expect(after.count('media_repeat'), 0);
      expect(after.count('move_repeat'), 0);
      expect(after.count('transition_repeat'), 0);
      expect(after.count('same_kind_adjacent'), 0);
      expect(after.score, greaterThan(before.score + 30));
      expect(after.score, greaterThanOrEqualTo(95));
      expect(beats[13].visual['component'], 'number_tiles');
      expect(beats[13].visual['text'], '900');
      // Never picks screenshots or logos as B-roll.
      expect(beats.any((b) => b.visual['media'] == 'shot' || b.visual['media'] == 'logo'), isFalse);
      // Same input → same output.
      final again = repetitive();
      v.repair(again, MediaPool(p));
      expect(jsonEncode([for (final b in again) b.visual]), jsonEncode([for (final b in beats) b.visual]));
    });

    test('repair only touches the chapter being rebuilt', () {
      final p = project();
      final beats = repetitive();
      for (final b in beats) {
        b.chapter = b.start < 24 ? 0 : 1;
      }
      const Variety().repair(beats, MediaPool(p), mutable: (b) => b.chapter == 1);
      for (final b in beats.where((b) => b.chapter == 0)) {
        expect(b.visual['media'], 'img0');
        expect(b.visual['transition'], 'whip');
      }
      expect(beats.where((b) => b.chapter == 1).any((b) => b.visual['media'] != 'img0' && b.visual['media'] != null), isTrue);
    });
  });

  group('pacing', () {
    final chapters = [
      Chapter(index: 0, title: 'Hook', kind: 'hook', first: 0, last: 1),
      Chapter(index: 1, title: 'The Gold Rush', kind: 'context', first: 2, last: 20),
      Chapter(index: 2, title: 'The Crash', kind: 'conflict', first: 21, last: 39, date: '1929'),
    ];
    List<Beat> plain() => [
          for (int i = 0; i < 40; i++)
            Beat(i * 8.0, i * 8.0 + 8, 'line $i about gold', {'media': 'img${i % 8}', 'move': 'ken_burns', 'transition': 'fade'},
                chapter: i < 2 ? 0 : (i <= 20 ? 1 : 2), lineIndex: i),
        ];

    test('fast hook, 3-5 s B-roll, chapter title cards, pattern interrupts', () {
      final p = project();
      final out = Pacer(MediaPool(p)).apply(plain(), chapters, title: 'Gold Rush Story');
      for (final b in out.where((b) => b.chapter == 0)) {
        expect(b.length, lessThanOrEqualTo(1.6 * 1.4 + 1e-6), reason: 'hook cut at ${b.start}');
      }
      for (final b in out.where((b) => b.chapter > 0 && b.role != 'card')) {
        expect(b.length, inInclusiveRange(2.5, 5.5 + 1e-6), reason: 'shot at ${b.start}');
      }
      final intro = out.firstWhere((b) => b.chapter == 1);
      expect(intro.role, 'card');
      expect(intro.visual['component'], 'title_slam');
      expect(intro.visual['title'], 'GOLD RUSH STORY');
      final crash = out.firstWhere((b) => b.chapter == 2);
      expect(crash.visual['component'], 'date_title');
      expect(crash.visual['text'], '1929');
      // Interrupts: never more than 60 s without one.
      expect(Pacer.maxInterruptGap(plain()), greaterThan(60));
      expect(Pacer.maxInterruptGap(out), lessThanOrEqualTo(60));
      expect(out.where((b) => b.role == 'interrupt').length, greaterThanOrEqualTo(3));
      // Timeline stays continuous: no overlaps, no holes.
      for (int i = 1; i < out.length; i++) {
        expect(out[i].start, closeTo(out[i - 1].end, 1e-6));
      }
      // Pacing again changes nothing (resume / re-finish is safe).
      final twice = Pacer(MediaPool(p)).apply(out, chapters, title: 'Gold Rush Story');
      expect(twice.length, out.length);
    });

    test('presenter beats: hook punch-ins, long talk gets interrupts, share capped', () {
      final p = project();
      final beats = [
        Beat(0, 6, 'hello', {'aroll': true}, chapter: 0, lineIndex: 0),
        for (int i = 1; i < 10; i++) Beat(i * 20.0 - 14, i * 20.0 + 6, 'talking $i', {'aroll': true}, chapter: 1, lineIndex: i),
      ];
      final ch = [Chapter(index: 0, title: 'Hook', kind: 'hook', first: 0, last: 0), Chapter(index: 1, title: 'Talk', first: 1, last: 9)];
      final out = Pacer(MediaPool(p), o: const PacingOptions(chapterCards: false)).apply(beats, ch, presenter: true);
      expect(out.where((b) => b.chapter == 0 && b.visual['punch'] == true), isNotEmpty);
      final total = out.fold<double>(0, (s, b) => s + b.length);
      final talk = out.where((b) => b.visual['aroll'] == true).fold<double>(0, (s, b) => s + b.length);
      expect(talk / total, lessThanOrEqualTo(0.36));
      expect(Pacer.maxInterruptGap(out), lessThanOrEqualTo(60));
    });

    test('name tags only on first appearance', () {
      final p = project();
      final beats = [
        Beat(0, 4, 'a', {'media': 'img1', 'name_tag': {'name': 'John Sutter', 'role': 'Mill owner'}}),
        Beat(4, 8, 'b', {'media': 'img2', 'name_tag': {'name': 'john sutter'}}),
        Beat(8, 12, 'c', {'component': 'name_tag', 'name': 'John Sutter', 'over_aroll': true}),
      ];
      final out = Pacer(MediaPool(p), o: const PacingOptions(hookSeconds: 0)).apply(beats, const []);
      expect(out.length, 3);
      expect(out[0].visual['name_tag'], isNotNull);
      expect(out[1].visual['name_tag'], isNull);
      expect(out[2].visual['aroll'], isTrue);
    });
  });

  group('gating', () {
    final caps = Capabilities(
      ops: EditCommands.ops.where((o) => o != 'make_3d' && o != 'camera_shot'),
      components: Components.types.where((t) => !Capabilities.mapComponents.contains(t)),
    );

    test('unavailable scene/map ops become visuals this build can make', () {
      expect(caps.has3d, isFalse);
      expect(caps.adapt({'media': 'img0', 'move': 'push_through'})['move'], 'push_in');
      expect(caps.adapt({'media': 'img0', 'move': 'pull_back'})['move'], 'pull_out');
      final fly = caps.adapt({'component': 'map_fly', 'from': 'India', 'to': 'France'});
      expect(fly['component'], 'map');
      expect(fly['route'], ['India', 'France']);
      expect(fly['focus'], 'France');
      final route = caps.adapt({'component': 'route_follow', 'from': 'India', 'to': 'France'});
      expect(route['focus'], isNull);
      expect(route['route'], ['India', 'France']);
      final pin = caps.adapt({'component': 'needle_pin', 'country': 'Japan', 'label': 'Tokyo'});
      expect(pin['component'], 'map');
      expect(pin['pin'], 'Tokyo');
      expect(caps.adapt({'component': 'room', 'media': 'img1'})['media'], 'img1');
      expect(caps.adapt({'component': 'nonsense', 'text': 'big money'})['component'], 'glow_word');
      expect(caps.adapt({'component': 'nonsense'})['aroll'], isTrue);
      expect(caps.adapt({'media': 'img0', 'transition': 'teleport'})['transition'], 'fade');
      expect(caps.adapt({'media': 'img0', 'atmosphere': 'lava'}).containsKey('atmosphere'), isFalse);

      final full = Capabilities(ops: [...EditCommands.ops, 'make_3d', 'camera_shot'], components: [...Components.types, ...Capabilities.mapComponents]);
      expect(full.has3d, isTrue);
      expect(full.adapt({'component': 'map_fly', 'from': 'India', 'to': 'France'})['component'], 'map_fly');
      expect(full.adapt({'media': 'img0', 'move': 'push_through'})['move'], 'push_through');
    });

    test('the prompt only offers what exists', () {
      final prompt = Director.directorPrompt(caps: caps, chapters: true);
      for (final w in ['map_fly', 'route_follow', 'needle_pin', 'push_through', 'pull_back', 'orbit']) {
        expect(prompt, isNot(contains(w)), reason: w);
      }
      for (final w in ['"route"', '"pin"', '"shots"', 'last_visuals', 'people_already_introduced', 'icon_stream', 'scanner', 'silhouette_crowd', 'glass_screen', 'article']) {
        expect(prompt, contains(w), reason: w);
      }
      final full = Capabilities(ops: [...EditCommands.ops, 'make_3d', 'camera_shot'], components: [...Components.types, ...Capabilities.mapComponents]);
      expect(Director.directorPrompt(caps: full), contains('map_fly'));
      expect(Director.directorPrompt(caps: full), contains('push_through'));
      expect(Director.directorPrompt(caps: caps), isNot(contains('LONG VIDEO')));
    });

    test('the builder never emits ops this build lacks', () {
      final p = project();
      final cmds = StoryBuilder.build(p, [Beat(0, 3, 'x', {'media': 'img0', 'move': 'drift'})], BuildOptions(caps: caps, tag: 'g'));
      expect(cmds.any((c) => c['op'] == 'make_3d' || c['op'] == 'camera_shot'), isFalse);
      EditCommands.runAtomic(p, {'op': 'batch', 'commands': cmds});
      expect(p.main.requireLayer('dg_0_m').prop(Props.scale).isAnimated, isTrue);
    });
  });

  group('planner', () {
    String outline() => '''Sure!
```json
{"title":"Gold Rush","look":"noir","chapters":[
 {"title":"Hook","kind":"hook","first":0,"last":3},
 {"title":"Context","kind":"context","first":4,"last":25,"mood":"history","date":"1848"},
 {"title":"Crash","kind":"conflict","first":26,"last":59,"mood":"sad",},
]}
```''';

    test('outline, chunked shots with repair/retry, running memory, resume after failure', () async {
      final sb = Storyboard(projectId: 'p', lines: lines(60), look: 'auto');
      var shotCalls = 0;
      var fail = false;
      Future<String> ai(String system, String user) async {
        if (system.contains('STORY EDITOR')) return outline();
        if (fail) throw AiException('offline');
        shotCalls++;
        final j = jsonDecode(user) as Map<String, dynamic>;
        expect(j['chapter'], isA<Map>());
        expect(j.containsKey('media_used_so_far'), isTrue);
        final ls = j['lines'] as List;
        final beats = [
          for (final l in ls)
            if ((l['i'] as int) == 0)
              {'i': 0, 'shots': [{'media': 'img1', 'move': 'push_in'}, {'media': 'img2', 'move': 'pan_left'}]}
            else
              {'i': l['i'], 'visual': {'media': 'img${(l['i'] as int) % 10}', 'move': 'push_in'}},
        ];
        final text = jsonEncode({'look': 'noir', 'beats': beats});
        if (shotCalls == 2) return text.substring(0, text.length ~/ 3); // cut off → repaired or retried
        return text;
      }

      final planner = StoryPlanner(ai, chunk: 10);
      await planner.outline(sb, media: [for (int i = 0; i < 10; i++) {'id': 'img$i', 'about': 'mine'}], looks: const ['noir', 'cinematic_doc']);
      expect(sb.title, 'Gold Rush');
      expect(sb.look, 'noir');
      expect([for (final c in sb.chapters) c.kind], ['hook', 'context', 'conflict']);
      final system = Director.directorPrompt(chapters: true);

      // Chapter 0 and 1 plan fine; the network dies in chapter 2.
      for (final k in [0, 1]) {
        sb.replaceChapter(k, await planner.planChapter(sb, k, system: system, base: const {}));
      }
      expect(sb.chapters[0].planned && sb.chapters[1].planned, isTrue);
      expect(sb.beatsOf(0).where((b) => b.lineIndex == 0).length, 2); // "shots" split the line
      expect(shotCalls, greaterThanOrEqualTo(4)); // 1 (hook) + 3 chunks, plus a retry
      fail = true;
      await expectLater(planner.planChapter(sb, 2, system: system, base: const {}), throwsA(isA<AiException>()));
      expect(sb.chapters[2].status, 'failed');
      expect(sb.plannedChapters, 2);

      // Saved and loaded, then resumed with the network back.
      final back = Storyboard.decode(sb.encode())!;
      expect(back.chapters.length, 3);
      expect(back.beats.length, sb.beats.length);
      expect(back.lines.length, 60);
      fail = false;
      final rest = await StoryPlanner(ai, chunk: 10).planChapter(back, 2, system: system, base: const {});
      back.replaceChapter(2, rest);
      expect(back.planned, isTrue);
      for (int i = 0; i < 60; i++) {
        expect(back.beats.any((b) => b.lineIndex == i), isTrue, reason: 'line $i');
      }
      // The running memory saw the earlier chapters.
      expect(back.memory.usedMedia.values.fold<int>(0, (a, b) => a + b), greaterThan(40));
    });

    test('cancel stops between calls', () async {
      final sb = Storyboard(projectId: 'p', lines: lines(10));
      sb.chapters = [Chapter(index: 0, title: 'All', first: 0, last: 9)];
      final token = CancelToken()..cancel();
      final planner = StoryPlanner((s, u) async => '{"beats":[]}', cancel: token);
      await expectLater(planner.planChapter(sb, 0, system: '', base: const {}), throwsA(isA<DirectorCancelled>()));
    });
  });

  test('StoryBuilder builds a 60-beat, 5-chapter storyboard and rebuilds one chapter', () {
    final p = project();
    final chapters = [
      Chapter(index: 0, title: 'Hook', kind: 'hook', first: 0, last: 3),
      Chapter(index: 1, title: 'Gold Fever', kind: 'context', first: 4, last: 17, mood: 'history'),
      Chapter(index: 2, title: 'The Crash', kind: 'conflict', first: 18, last: 33, mood: 'sad', date: '1857'),
      Chapter(index: 3, title: 'New Money', kind: 'turning_point', first: 34, last: 47, places: ['France']),
      Chapter(index: 4, title: 'Party', kind: 'ending', first: 48, last: 59, mood: 'celebration', look: 'warm_travel'),
    ];
    final visuals = <Map<String, dynamic>>[
      {'media': 'img2', 'move': 'depth', 'behind_text': 'GOLD', 'name_tag': {'name': 'John Sutter', 'role': 'Mill owner'}},
      {'aroll': true, 'punch': true},
      {'component': 'counter', 'from': 0, 'to': 300000, 'suffix': ' CRORE'},
      {'component': 'map', 'countries': ['India', 'France', 'Atlantis'], 'focus': 'France', 'route': ['India', 'France'], 'pin': 'Paris'},
      {'media': 'img3', 'move': 'drift', 'transition': 'ink', 'label': 'MINER'},
      {'component': 'date_title', 'text': '1849', 'subtitle': 'California'},
      {'media': 'clipb', 'move': 'pan_right', 'transition': 'iris', 'atmosphere': 'leaves'},
      {'component': 'icon_stream', 'icons': ['₹', 'img4']},
      {'component': 'silhouette_crowd', 'media': ['fg'], 'labels': ['WORKERS']},
      {'component': 'glass_screen', 'media': ['clipb', 'img5']},
      {'component': 'map_fly', 'from': 'India', 'to': 'France'},
      {'component': 'needle_pin', 'country': 'Japan', 'label': 'Tokyo'},
      {'component': 'article', 'media': 'shot', 'marks': [{'box': [0.1, 0.3, 0.6, 0.32], 'style': 'highlight'}]},
      {'media': 'img6', 'move': 'pull_back', 'transition': 'smoke'},
      {'component': 'number_tiles', 'text': '200', 'word': 'YEARS'},
      {'media': 'img7', 'move': 'push_in', 'transition': 'glitch_flash'},
      {'component': 'name_tag', 'name': 'John Sutter', 'role': 'again', 'over_aroll': true},
      {'aroll': true},
    ];
    final ls = lines(60);
    final sb = Storyboard(projectId: 'p', tag: 't', title: 'Gold Rush', look: 'cinematic_doc', lines: ls, arollLayer: 'aroll', chapters: chapters);
    sb.beats = [
      for (int i = 0; i < 60; i++)
        Beat(ls[i].$1, ls[i].$2 + 0.2, ls[i].$3, Map<String, dynamic>.from(visuals[i % visuals.length]),
            chapter: chapters.firstWhere((c) => c.contains(i)).index, lineIndex: i),
    ];
    final caps = Capabilities();
    final report = StoryPlanner.finish(p, sb, caps: caps, presenter: true, cutouts: {'img2'});
    expect(sb.beats.length, greaterThanOrEqualTo(60));
    expect(report.score, greaterThan(50));
    expect(Pacer.maxInterruptGap(sb.beats), lessThanOrEqualTo(60));
    // Unavailable map/scene visuals were adapted, never dropped.
    if (!caps.has('map_fly')) expect(sb.beats.any((b) => b.visual['component'] == 'map_fly'), isFalse);
    expect(sb.beats.where((b) => b.visual['component'] == 'name_tag'), isEmpty); // John was introduced already

    final words = [for (final l in ls) WordTiming(l.$3.split(' ').first, l.$1, l.$1 + 0.5)];
    final o = BuildOptions(
      arollLayer: 'aroll',
      musicMedia: 'music',
      speech: StoryBuilder.speechFromWords(words),
      sfxMedia: {for (final k in Sfx.kinds) k: 'sfx_$k'},
      cutouts: {'img2': ('fg', 'bg')},
      captionWords: words,
      look: 'cinematic_doc',
      tag: 't',
      chapters: chapters,
      caps: caps,
    );
    final cmds = StoryBuilder.build(p, sb.beats, o);
    if (!caps.has3d) expect(cmds.any((c) => c['op'] == 'make_3d'), isFalse);
    EditCommands.runAtomic(p, {'op': 'batch', 'commands': cmds});
    final comp = p.main;
    for (int k = 0; k < 5; k++) {
      expect(comp.layers.any((l) => l.id.startsWith('dtc${k}_')), isTrue, reason: 'chapter $k');
    }
    expect(comp.layers.first.id, startsWith('cap_'));
    // Chapter moods → particles; the last chapter has its own look.
    final rain = comp.layers.where((l) => l.id.startsWith('dtc2_atm'));
    expect(rain, isNotEmpty);
    expect(rain.first.effects.any((e) => e.type == 'particles'), isTrue);
    expect(comp.layers.any((l) => l.id.startsWith('dtc4_atm')), isTrue);
    // Map beats get a route and a pin on the focus country.
    expect(comp.layers.any((l) => l.id.contains('_rt')), isTrue);
    expect(comp.layers.any((l) => l.id.contains('_pin')), isTrue);
    expect(comp.duration, greaterThanOrEqualTo(239));

    // ---- rebuild only chapter 2
    final others = {for (final l in comp.layers) if (!l.id.startsWith('dtc2_')) l.id};
    final before2 = comp.layers.where((l) => l.id.startsWith('dtc2_')).length;
    final mine = sb.beatsOf(2);
    mine.first.visual = {'component': 'glow_word', 'text': 'CRASH'};
    for (final b in mine.skip(1)) {
      if (b.visual['aroll'] == true) b.visual = {'media': 'img8', 'move': 'pan_left'};
    }
    final re = StoryBuilder.rebuildChapter(p, sb.beats, o, 2);
    EditCommands.runAtomic(p, {'op': 'batch', 'commands': re});
    final ids = [for (final l in comp.layers) l.id];
    expect(ids.toSet().length, ids.length); // no duplicates
    expect({for (final l in comp.layers) if (!l.id.startsWith('dtc2_')) l.id}, others);
    expect(comp.layers.where((l) => l.id.startsWith('dtc2_')).length, greaterThan(before2 ~/ 2));
    final captions = [for (int i = 0; i < comp.layers.length; i++) if (comp.layers[i].id.startsWith('cap_')) i];
    expect(captions.first, 0);
    expect(captions.last, captions.length - 1);
    // The presenter has no punch-in left inside chapter 2 when none is planned there.
    final (t0, t1) = sb.rangeOf(2);
    final punched = sb.beatsOf(2).any((b) => b.visual['punch'] == true);
    if (!punched) {
      final s = comp.requireLayer('aroll').prop(Props.scale);
      final base = s.valueAt(0.01)[0];
      for (double t = t0 + 0.5; t < t1 - 0.5; t += 0.5) {
        expect(s.valueAt(t)[0], closeTo(base, 0.5), reason: 't=$t');
      }
    }
  });
}
