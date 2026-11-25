import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/ai/command_spec.dart';
import 'package:motionai/audio/audio_cache.dart';
import 'package:motionai/audio/sfx_library.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/commands/pattern_commands.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/components.dart';
import 'package:motionai/core/presets/doc_transitions.dart';
import 'package:motionai/core/presets/templates.dart';
import 'package:motionai/core/presets/world_map.dart';
import 'package:motionai/director/capabilities.dart';
import 'package:motionai/director/cue_classifier.dart';
import 'package:motionai/director/director.dart';
import 'package:motionai/director/pattern_engine.dart';
import 'package:motionai/director/patterns.dart';
import 'package:motionai/remote/mcp_protocol.dart';

Project project() {
  final p = Project(id: 'p', name: 'Doc', main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: 10));
  p.media['img'] = MediaAsset(id: 'img', type: MediaType.image, path: '/a.jpg', name: 'snow plate', width: 1600, height: 900);
  p.media['cut'] = MediaAsset(id: 'cut', type: MediaType.image, path: '/c.png', name: 'person (subject)', width: 600, height: 1200);
  p.media['clip'] = MediaAsset(id: 'clip', type: MediaType.video, path: '/v.mp4', name: 'presenter', width: 1920, height: 1080, duration: 120);
  return p;
}

List<String> types(List<Cue> cues) => [for (final c in cues) c.type];
Cue first(List<Cue> cues, String type) => cues.firstWhere((c) => c.type == type);

/// A ~100 s snow story mixing English, Hindi and Hinglish, 4 s per line.
List<Map<String, dynamic>> story() {
  const lines = [
    '13 October 1972 को एक विमान Montevideo से Santiago तक जा रहा था',
    'Plane mein 45 passengers the, jinmein se 19 rugby players the',
    'Andes ke pahadon ke upar mausam kharab ho gaya',
    'According to a report, the pilot thought they had crossed the mountains',
    'Phir plane barf se takra gaya',
    'Sab kuch shaant ho gaya',
    'Dosto, aap sochiye, aap uss barf mein hote toh kya karte?',
    'Unke paas chocolate, wine aur crackers the',
    'Day 10 par radio par khabar aayi ki search band kar di gayi',
    'Unki umeed khatam ho gayi',
    'Phir unhone ek pact kiya',
    'Nando Parrado ne apni kitab mein likha ki unhe zinda rehna tha',
    'Kitne din? Pure 72 din',
    'Usne kaha "hum zinda hain"',
    'Helicopter se talaash phir shuru hui',
    'Aakhirkar 16 log zinda bache',
    'Aap comment mein batao, aap kya karte',
    'Yeh kahani hume sikhati hai ki umeed kabhi nahi chhodni chahiye',
    'Chile aur Argentina ke beech yeh pahad aaj bhi khade hain',
    'Doston, video achha laga toh channel subscribe karo',
    'Barf ke beech woh 72 din duniya ki sabse mushkil kahani hai',
    'Aur aaj bhi log Andes jaakar unhe yaad karte hain',
    'Survivors aaj bhi har saal milte hain',
    'Aap bhi unki kahani yaad rakhiye',
    'Milte hain agli video mein',
  ];
  return [for (int i = 0; i < lines.length; i++) {'text': lines[i], 'start': i * 4.0, 'end': i * 4.0 + 4.0}];
}

void main() {
  late Directory tmp;
  setUpAll(() => WorldMap.load(File('assets/world_countries.json').readAsStringSync()));
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('v3pt');
    SfxLibrary.dir = tmp.path;
    AudioCache.clear();
  });
  tearDown(() {
    SfxLibrary.dir = null;
    AudioCache.clear();
    Capabilities.enablePatterns = false;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('cue classifier', () {
    test('English: year, route, places, passengers', () {
      final c = CueClassifier.classify('In 1972 a plane flew from Uruguay to Chile with 45 passengers.', start: 0, end: 4);
      expect(types(c), containsAll(['date', 'route', 'place', 'number', 'people_count']));
      expect(first(c, 'date').value, '1972');
      expect(first(c, 'route').value, {'from': 'Uruguay', 'to': 'Chile'});
      expect((first(c, 'people_count').value as Map)['value'], 45);
      for (final x in c) {
        expect(x.at, inInclusiveRange(0, 4));
      }
      // the keyword time grows along the line
      expect(first(c, 'people_count').at!, greaterThan(first(c, 'date').at!));
    });

    test('Hindi (Devanagari): full date and a city-to-city route', () {
      final c = CueClassifier.classify('13 अक्टूबर 1972 को विमान मोंटेवीडियो से सैंटियागो तक जा रहा था');
      expect(types(c), containsAll(['date', 'place', 'route']));
      expect(c.where((x) => x.type == 'date').map((x) => x.value), contains('13 OCT 1972'));
      expect(types(c), isNot(contains('number')), reason: '13 is the day of the month');
      expect(first(c, 'route').value, {'from': 'Uruguay', 'to': 'Chile'});
      expect([for (final x in c.where((x) => x.type == 'place')) (x.value as Map)['name']], containsAll(['Montevideo', 'Santiago']));
    });

    test('Devanagari digits and nukta spellings', () {
      expect(first(CueClassifier.classify('१९७२ में'), 'date').value, '1972');
      expect(types(CueClassifier.classify('बर्फ़ में ज़िंदा')), containsAll(['snow', 'hope']));
      expect(types(CueClassifier.classify('बर्फ में जिंदा')), containsAll(['snow', 'hope']));
    });

    test('Hinglish: presenter address, duration, snow, hope', () {
      final c = CueClassifier.classify('Dosto, socho 72 din tak barf mein zinda rehna kitna mushkil tha');
      expect(types(c), containsAll(['presenter', 'duration', 'snow', 'hope']));
      expect(first(c, 'duration').value, {'value': 72.0, 'unit': 'days'});
      expect(types(c), isNot(contains('survivors')), reason: 'no count of survivors');
    });

    test('despair beats hope ("umeed khatam")', () {
      final c = CueClassifier.classify('Unki maut ho gayi aur umeed khatam ho gayi');
      expect(types(c), contains('dread'));
      expect(types(c), isNot(contains('hope')));
      expect(types(c), isNot(contains('list')));
    });

    test('quotes, books, articles, second sources, notes', () {
      final q = CueClassifier.classify('Usne kaha "hum zinda hain"');
      expect(types(q), containsAll(['dialogue', 'quote']));
      expect(first(q, 'dialogue').value, 'hum zinda hain');
      expect(types(CueClassifier.classify('Nando ne apni kitab mein likha')), contains('book'));
      expect(types(CueClassifier.classify('According to a New York Times report')), contains('article'));
      expect(types(CueClassifier.classify('अख़बार के मुताबिक़')), contains('article'));
      expect(types(CueClassifier.classify('Ek podcast interview mein usne bataya')), contains('second_source'));
      expect(types(CueClassifier.classify('Uski chitthi mein likha tha')), contains('handwritten'));
    });

    test('lists, objects, radio, search, concepts', () {
      final l = CueClassifier.classify('Unke paas chocolate, wine aur crackers the');
      expect(types(l), contains('list'));
      expect((first(l, 'list').value as List).length, 3);
      final r = CueClassifier.classify('Raat ke 3:21 baje radio par signal aaya');
      expect(types(r), containsAll(['time', 'radio']));
      expect(first(r, 'time').value, '03:21');
      expect(types(CueClassifier.classify('Helicopter se talaash shuru hui')), contains('search'));
      expect(types(CueClassifier.classify('Phir unhone ek pact kiya')), contains('concept'));
      expect(types(CueClassifier.classify('Unke haath mein ek compass tha')), contains('object'));
    });

    test('day counts, "kitne din", numbers with units', () {
      expect(first(CueClassifier.classify('Day 61 par unhe radio mila'), 'day_count').value, 'DAY 61');
      expect(first(CueClassifier.classify('61वें दिन वो निकले'), 'day_count').value, 'DAY 61');
      final k = CueClassifier.classify('Aap sochiye, kitne din?');
      expect(types(k), containsAll(['presenter', 'duration', 'question']));
      expect(first(k, 'duration').value, {'question': true});
      expect((first(CueClassifier.classify('60 km ka safar'), 'number').value as Map)['text'], '60 KM');
      final lakh = CueClassifier.classify('45 लाख लोग');
      expect((first(lakh, 'number').value as Map)['value'], 4500000);
      expect(types(lakh), contains('people_count'));
      expect(first(CueClassifier.classify('Woh Tuesday tha'), 'date').value, 'TUESDAY');
      expect(types(CueClassifier.classify('teen din baad')), contains('duration'));
    });

    test('pain, witness, recap, crash, lightning, turning point', () {
      expect(types(CueClassifier.classify('Woh dard se cheekh pada')), contains('pain'));
      expect(types(CueClassifier.classify('Usne apni aankhon se dekha')), contains('witness'));
      expect(types(CueClassifier.classify('Yaad karo woh kaun the')), contains('recap'));
      expect(types(CueClassifier.classify('Plane pahad se takra gaya')), contains('crash'));
      expect(types(CueClassifier.classify('Achanak bijli chamki')), containsAll(['turning_point', 'lightning']));
    });

    test('story tone', () {
      expect(CueClassifier.toneOf(['Barf hi barf thi', 'Andes ki thand']), 'snow');
      expect(CueClassifier.toneOf(['Delhi ki ek gali']), 'neutral');
      expect(CueClassifier.toneOf(['Registan ki ret', 'Sahara desert']), 'desert');
    });
  });

  group('registry', () {
    test('ids unique, every spec pattern 1–43 and 47–65 present, cues known', () {
      final ids = <String>{};
      final ns = <int>{};
      for (final p in PatternLibrary.all) {
        expect(ids.add(p.id), isTrue, reason: 'duplicate ${p.id}');
        ns.add(p.n);
        expect(p.when, isNotEmpty, reason: p.id);
        expect(p.primary, isNotEmpty, reason: p.id);
        for (final c in p.cues.keys) {
          expect(CueTypes.all, contains(c), reason: '${p.id}: $c');
        }
      }
      for (final n in [for (int i = 1; i <= 43; i++) i, for (int i = 47; i <= 65; i++) i]) {
        expect(ns, contains(n), reason: 'pattern #$n');
      }
      for (final f in ['presenter', 'reenactment_shot', 'push_through', 'foreground_wipe', 'map_drop', 'flash_cut', 'light_leak_wipe', 'censor_bar',
        'crane_down_reveal', 'push_between_subjects', 'rack_focus_encounter', 'fog_tracking', 'human_detail_insert', 'crash_to_black']) {
        expect(PatternLibrary.byId(f), isNotNull, reason: f);
      }
    });

    test('command spec lists every pattern id with its trigger', () {
      expect(commandSpec, contains('WHEN TO USE'));
      for (final p in PatternLibrary.all) {
        expect(commandSpec, contains('  ${p.id} — '), reason: p.id);
      }
      for (final op in PatternCommands.ops) {
        expect(commandSpec, contains(op), reason: op);
        expect(EditCommands.ops, contains(op), reason: op);
      }
    });

    test('a template per pattern in "Doc patterns"', () {
      expect(SceneTemplates.categories, contains('Doc patterns'));
      for (final p in PatternLibrary.all) {
        final t = SceneTemplates.byId('pattern_${p.id}');
        expect(t, isNotNull, reason: p.id);
        expect(t!.category, 'Doc patterns');
        expect(t.available, isTrue);
      }
    });
  });

  group('fallback', () {
    final ctx = PatternCtx(project(), start: 0, end: 5, pfx: 'x', plate: 'plate', prevPlate: 'prev', tone: 'snow');

    test('a missing component falls back to plain layers; once installed it is used', () {
      final p = PatternLibrary.byId('unit_chart')!;
      final base = PatternRuntime.preview(p, ctx,
          caps: PatternCaps(components: Components.types.where((t) => t != 'unit_chart'), ops: EditCommands.ops.where((o) => o != 'unit_chart')));
      expect(base.first['primary'], 'unit_chart');
      expect(base.first['uses'], 'layers');
      expect(base.first['fallback'], isTrue);
      final merged = PatternRuntime.preview(p, ctx, caps: PatternCaps(components: [...Components.types, 'unit_chart'], ops: EditCommands.ops.where((o) => o != 'unit_chart')));
      expect(merged.first['uses'], 'unit_chart');
      expect(merged.first['fallback'], isFalse);
      // an op of that name is preferred over nothing, too
      final asOp = PatternRuntime.preview(p, ctx, caps: PatternCaps(ops: [...EditCommands.ops, 'unit_chart']));
      expect(asOp.first['uses'], 'unit_chart');
    });

    test('a missing transition falls back to existing documentary transitions', () {
      final p = PatternLibrary.byId('powder_burst')!;
      final without = DocTransitions.types.where((t) => t != 'powder_burst' && t != 'debris_burst');
      final ops = EditCommands.ops.where((o) => o != 'powder_burst' && o != 'debris_burst');
      expect(PatternRuntime.preview(p, ctx, caps: PatternCaps(transitions: without, ops: ops)).first['uses'], 'transition:smoke_reveal');
      expect(PatternRuntime.preview(p, ctx, caps: PatternCaps(transitions: [...without, 'powder_burst'], ops: ops)).first['uses'], 'transition:powder_burst');
      expect(PatternRuntime.preview(p, ctx, caps: PatternCaps(transitions: const [], ops: ops)).first['uses'], 'animate_in:smoke');
    });

    test('an alternative that exists but fails is rolled back and the next one runs', () {
      final p = project();
      final caps = PatternCaps(ops: [...EditCommands.ops, 'mood_flood']); // "exists" but the dispatcher rejects it
      final r = CommandResult();
      PatternRuntime.apply(p, {
        'plan': {
          'beats': [
            {'pattern': 'mood_flood', 'start': 0, 'end': 4, 'reveal_at': 1.0},
          ],
        },
        'prefix': 'mf',
        'sfx': false,
      }, r, (c) {
        final res = EditCommands.runAtomic(p, c);
        r.createdIds.addAll(res.createdIds);
      }, caps: caps);
      expect(p.main.layerById('mf0_plate'), isNotNull);
      expect(p.main.layerById('mf0_flood'), isNotNull, reason: 'adjustment-layer fallback');
      expect(r.log.last, contains('apply_patterns'));
    });

    test('text styles, animators and fonts are checked by name', () {
      final caps = PatternCaps(animators: const ['typewriter', 'word_pop', 'random_pop', 'fade_up']);
      expect(caps.resolve({'op': 'add_layer', 'type': 'text', 'animator': 'letter_drop'}), isNull);
      expect(caps.resolve({'op': 'add_layer', 'type': 'text', 'animator': 'random_pop'}), isNotNull);
      expect(caps.resolve({'op': 'add_layer', 'type': 'text', 'font': 'No Such Font'}), isNull);
      expect(caps.resolve({'op': 'add_layer', 'type': 'text', 'font': 'Poppins'}), isNotNull);
      expect(PatternCaps(textStyles: const []).resolve({'op': 'add_layer', 'type': 'text', 'text_style': 'stat_yellow'}), isNull);
      expect(PatternRuntime.sfxKind('radio_crackle', {'glitch', 'pop'}), 'glitch');
      expect(PatternRuntime.sfxKind('thunder', {'thunder', 'impact'}), 'thunder');
    });
  });

  group('suggest', () {
    test('pacing grammar on a 100 s mixed-language snow story', () {
      final plan = PatternEngine.suggest(story(), context: const {'style': 'nr_doc'});
      final beats = (plan['beats'] as List).cast<Map<String, dynamic>>();
      final stats = plan['stats'] as Map<String, dynamic>;
      expect(plan['tone'], 'snow');
      expect(beats, isNotEmpty);
      // never the same pattern twice in a row
      expect(stats['same_pattern_repeats'], 0);
      for (int i = 1; i < beats.length; i++) {
        expect(beats[i]['pattern'], isNot(beats[i - 1]['pattern']), reason: 'beat $i');
      }
      // shot rhythm and a new element every ≤ 2.5 s
      expect(stats['asl'] as double, inInclusiveRange(2.5, 6.0));
      expect(stats['max_element_gap'] as double, lessThanOrEqualTo(2.5));
      // presenter share and returns
      expect(stats['presenter_share'] as double, inInclusiveRange(0.15, 0.45));
      expect(stats['presenter_returns'] as int, greaterThanOrEqualTo(3));
      expect(stats['max_presenter_gap'] as double, lessThanOrEqualTo(30));
      // one CTA stint (social_cta / social_bug) at least
      expect(stats['cta'] as int, greaterThanOrEqualTo(1));
      for (final b in beats) {
        final s = (b['start'] as num).toDouble(), e = (b['end'] as num).toDouble();
        expect(e, greaterThan(s));
        if (b['reveal_at'] is num) expect((b['reveal_at'] as num).toDouble(), inInclusiveRange(s + 0.1, e));
        expect(PatternLibrary.byId('${b['pattern']}'), isNotNull);
        final tr = '${b['transition_in']}';
        expect(tr == 'cut' || PatternLibrary.byId(tr) != null, isTrue, reason: tr);
      }
      // the snow signature transition is used
      expect(beats.map((b) => b['transition_in']), contains('powder_burst'));
      // presenter beats are graded warm; snowy b-roll cold
      expect(beats.where((b) => b['pattern'] == 'presenter').every((b) => b['grade'] == 'warm'), isTrue);
      // CTA overlays sit inside a presenter stint ≥ 5 s, 2–3 s in
      for (final b in beats.where((b) => b['pattern'] == 'presenter')) {
        for (final o in (b['overlays'] as List).where((o) => '${o['pattern']}'.startsWith('social_'))) {
          expect((b['end'] as num) - (b['start'] as num), greaterThanOrEqualTo(5));
          expect((o['at'] as num) - (b['start'] as num), inInclusiveRange(2.0, 3.0));
        }
      }
    });

    test('evidence is followed by a reenactment; never the presenter right after a crash', () {
      final plan = PatternEngine.suggest(story());
      final beats = (plan['beats'] as List).cast<Map<String, dynamic>>();
      var evidence = 0;
      for (int i = 0; i + 1 < beats.length; i++) {
        final p = PatternLibrary.byId('${beats[i]['pattern']}')!;
        final next = beats[i + 1];
        if (p.isEvidence && next['pattern'] != 'presenter') {
          evidence++;
          expect(next['pattern'], 'reenactment_shot', reason: 'after ${p.id}');
        }
        if (const {'crash_to_black', 'cut_to_black', 'mood_flood'}.contains(p.id)) {
          expect(next['pattern'], isNot('presenter'), reason: 'after ${p.id}');
        }
      }
      expect(evidence, greaterThanOrEqualTo(1));
    });

    test('cues pick the expected patterns and slots', () {
      final plan = PatternEngine.suggest([
        {'text': 'Uruguay se Chile tak ki flight', 'start': 0, 'end': 4},
        {'text': 'Plane mein 45 passengers the, jinmein se 19 rugby players the', 'start': 4, 'end': 8},
        {'text': '13 October 1972, Friday', 'start': 8, 'end': 11},
        {'text': 'Unki maut ho gayi', 'start': 11, 'end': 14},
      ], context: const {'presenter': false});
      final beats = (plan['beats'] as List).cast<Map<String, dynamic>>();
      expect(beats.map((b) => b['pattern']), isNot(contains('presenter')));
      final route = beats.firstWhere((b) => b['pattern'] == 'route_arrow_follow');
      expect(route['slots'], containsPair('from', 'Uruguay'));
      expect(route['slots'], containsPair('to', 'Chile'));
      final chart = beats.firstWhere((b) => b['pattern'] == 'unit_chart');
      expect((chart['slots'] as Map)['total'], 45);
      final date = beats.where((b) => b['pattern'] == 'clock_stamp' || ((b['overlays'] as List?) ?? const []).any((o) => o['pattern'] == 'clock_stamp'));
      expect(date, isNotEmpty);
      expect(beats.map((b) => b['pattern']), contains('mood_flood'));
      // reveal lands just after the keyword
      final c = CueClassifier.classify('Uruguay se Chile tak ki flight', start: 0, end: 4);
      expect((route['reveal_at'] as num).toDouble(), closeTo(first(c, 'route').at! + 0.2, 0.25));
      expect(plan['resolved'], contains('route_arrow_follow'));
    });

    test('tone option chooses the transition family; deterministic', () {
      final a = PatternEngine.suggest(story(), context: const {'tone': 'neutral'});
      final b = PatternEngine.suggest(story(), context: const {'tone': 'neutral'});
      expect(jsonEncode(a), jsonEncode(b));
      expect((a['beats'] as List).map((b) => b['transition_in']), isNot(contains('powder_burst')));
      final d = PatternEngine.suggest(story(), context: const {'story_tone': 'desert'});
      expect(d['tone'], 'desert');
    });

    test('suggest_patterns op logs the plan; apply_patterns builds it as one step', () {
      final p = project();
      final r = EditCommands.runAtomic(p, {'op': 'suggest_patterns', 'lines': story().take(8).toList(), 'style': 'nr_doc'});
      expect(p.main.layers, isEmpty, reason: 'info op');
      final plan = jsonDecode(r.log.single) as Map<String, dynamic>;
      expect(plan['beats'], isNotEmpty);
      final before = ProjectSnapshot.take(p);
      final a = EditCommands.runAtomic(p, {'op': 'apply_patterns', 'plan': plan, 'assets': {'presenter': 'clip', 'broll': ['img']}});
      expect(a.createdIds, isNotEmpty);
      expect(p.main.layers.where((l) => l.mediaId == 'clip'), isNotEmpty, reason: 'presenter A-roll placed');
      expect(p.main.duration, greaterThanOrEqualTo(30));
      // one undo step = one snapshot back
      ProjectSnapshot.restore(p, before);
      expect(p.main.layers, isEmpty);
      // string lines and list_patterns
      final s = EditCommands.runAtomic(p, {'op': 'suggest_patterns', 'lines': 'Chile ka naksha\nDosto, aap batao'});
      expect((jsonDecode(s.log.single)['beats'] as List).length, greaterThanOrEqualTo(1));
      final l = EditCommands.runAtomic(p, {'op': 'list_patterns', 'category': 'maps'});
      expect((jsonDecode(l.log.single)['patterns'] as List).every((x) => x['category'] == 'maps'), isTrue);
      expect(() => EditCommands.runAtomic(p, {'op': 'apply_patterns', 'plan': {'beats': [{'pattern': 'nope'}]}}), throwsA(isA<CommandError>()));
    });
  });

  group('wiring', () {
    test('MCP tool suggest_patterns is listed, read-only, and returns the plan', () {
      expect(kMcpToolNames, contains('suggest_patterns'));
      final t = kMcpTools.firstWhere((t) => t['name'] == 'suggest_patterns');
      expect((t['annotations'] as Map)['readOnlyHint'], isTrue);
      expect(kMcpEditTools.contains('suggest_patterns'), isFalse);
      final plan = PatternCommands.suggest({'lines': [{'text': 'Chile se Argentina tak', 'start': 0, 'end': 3}]});
      expect((plan['beats'] as List).first['pattern'], 'route_arrow_follow');
    });

    test('Director: opt-in pattern hints and prompt section', () {
      final lines = [(0.0, 4.0, 'Uruguay se Chile tak ki flight'), (4.0, 8.0, 'Usne kaha "hum zinda hain"')];
      final h = PatternEngine.hints(lines);
      expect(h.first['patterns'], contains('route_arrow_follow'));
      expect(Director.directorPrompt(caps: Capabilities()), isNot(contains('STORY PATTERNS')));
      Capabilities.enablePatterns = true;
      expect(Capabilities().patterns, isTrue);
      expect(Director.directorPrompt(caps: Capabilities()), contains('STORY PATTERNS'));
    });
  });
}
