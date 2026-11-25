import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/captions/captions.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/services/captions.dart' show CaptionMaker;

Project project({double w = 1920, double h = 1080}) =>
    Project(id: 'p', name: 'Doc', main: Composition(id: 'main', name: 'Main', width: w, height: h, fps: 30, duration: 20));

/// Words of [text] spoken one after another from [start].
List<WordTiming> words(String text, {double start = 0.5, double step = 0.34, double len = 0.3}) {
  final parts = text.split(' ').where((w) => w.isNotEmpty).toList();
  return [for (int i = 0; i < parts.length; i++) WordTiming(parts[i], start + i * step, start + i * step + len)];
}

List<String> texts(List<CaptionCue> cues) => [for (final c in cues) c.flatText];

List<Layer> captionLayers(Project p) => CaptionTrack.layers(p.main);

void main() {
  group('grouping and line breaking', () {
    test('English: glued numbers and names stay together, sentences break', () {
      final ws = words('In 1991 the Reserve Bank of India had only ₹500 crore left. Then Manmohan Singh spoke.');
      final cues = CaptionGrouper.group(ws, const GroupingRules(maxWords: 4));
      final t = texts(cues);
      expect(t.any((s) => s.contains('₹500 crore')), isTrue, reason: '$t');
      expect(t.any((s) => s.contains('Reserve Bank')), isTrue, reason: '$t');
      expect(t.any((s) => s.contains('Manmohan Singh')), isTrue, reason: '$t');
      // The sentence end closes a caption.
      expect(cues.any((c) => c.words.last.word == 'left.'), isTrue, reason: '$t');
      for (final c in cues) {
        expect(c.words.length, lessThanOrEqualTo(6));
      }
      // Every word is used once, in order.
      expect([for (final c in cues) ...c.words.map((w) => w.word)], [for (final w in ws) w.word]);
    });

    test('long pauses start a new caption', () {
      final ws = [WordTiming('hello', 0, 0.3), WordTiming('there', 0.35, 0.6), WordTiming('friend', 2.0, 2.3)];
      final cues = CaptionGrouper.group(ws, const GroupingRules(maxWords: 4));
      expect(texts(cues), ['hello there', 'friend']);
    });

    test('Hinglish: postpositions never start a caption or a line', () {
      final ws = words('Bharat ka GDP 5 trillion dollar tak pahunch gaya hai aur ye sab sirf 30 saal mein hua');
      for (final maxWords in [2, 3, 4]) {
        final cues = CaptionGrouper.group(ws, GroupingRules(maxWords: maxWords, maxLineChars: 12));
        for (final c in cues) {
          expect(TextRules.isTrailingParticle(c.words.first.word), isFalse, reason: '${texts(cues)}');
          for (final line in c.lines) {
            expect(TextRules.isTrailingParticle(line.first.word), isFalse, reason: c.toString());
          }
        }
        final t = texts(cues);
        expect(t.any((s) => s.contains('5 trillion dollar')), isTrue, reason: '$t');
        expect(t.any((s) => s.contains('30 saal')), isTrue, reason: '$t');
      }
    });

    test('Devanagari: matras take no width, particles stay with their word', () {
      expect(TextRules.visualLength('कि'), lessThan(TextRules.visualLength('कक')));
      expect(TextRules.visualLength('क्ष'), lessThan(TextRules.visualLength('कष')));
      expect(TextRules.isDevanagari('भारत'), isTrue);
      final ws = words('भारत की अर्थव्यवस्था में ₹500 करोड़ का निवेश हुआ और 1991 में सब बदल गया');
      final cues = CaptionGrouper.group(ws, const GroupingRules(maxWords: 3, maxLineChars: 10));
      for (final c in cues) {
        for (final line in c.lines) {
          expect(TextRules.isTrailingParticle(line.first.word), isFalse, reason: '${texts(cues)}');
        }
      }
      expect(texts(cues).any((s) => s.contains('₹500 करोड़')), isTrue, reason: '${texts(cues)}');
    });

    test('line breaks are balanced and avoid glued words', () {
      final ws = 'Sarkar ne ₹20 lakh crore ka package diya'.split(' ');
      final br = CaptionGrouper.breakLines(ws, maxLines: 2, maxLineChars: 22);
      expect(br, hasLength(1));
      final k = br.first;
      expect(TextRules.glued(ws[k - 1], ws[k]), isFalse, reason: 'break at $k');
      final a = TextRules.lineLength(ws.sublist(0, k)), b = TextRules.lineLength(ws.sublist(k));
      expect((a - b).abs(), lessThan(14));
      // Short text stays on one line.
      expect(CaptionGrouper.breakLines(['short', 'line'], maxLineChars: 20), isEmpty);
      // Devanagari is measured without matras.
      final deva = 'यह कहानी बहुत पुरानी है लेकिन आज भी सच है'.split(' ');
      final bd = CaptionGrouper.breakLines(deva, maxLines: 2, maxLineChars: 20);
      expect(bd, hasLength(1));
      expect(TextRules.isTrailingParticle(deva[bd.first]), isFalse);
    });
  });

  group('emphasis', () {
    test('numbers, money, years and names', () {
      final ws = ['In', '1991', 'India', 'had', 'only', '₹500', 'crore', 'left'];
      expect(Emphasis.kindOf(ws, 1), EmphasisKind.year);
      expect(Emphasis.kindOf(ws, 5), EmphasisKind.money);
      expect(Emphasis.kindOf(ws, 6), EmphasisKind.money);
      expect(Emphasis.kindOf(ws, 2), EmphasisKind.name);
      expect(Emphasis.kindOf(ws, 0), EmphasisKind.none); // sentence start
      expect(Emphasis.kindOf(ws, 3), EmphasisKind.none);
      // Strongest two highlights: money run + year.
      expect(Emphasis.detect(ws, maxRuns: 2), {5, 6, 1});
      expect(Emphasis.detect(ws, maxRuns: 3), {1, 2, 5, 6});
      // AI words win.
      expect(Emphasis.detect(ws, aiWords: {'left'}, maxRuns: 1), {7});
      expect(Emphasis.kindOf(['\$5', 'billion'], 0), EmphasisKind.money);
      expect(Emphasis.kindOf(['37%'], 0), EmphasisKind.number);
      expect(Emphasis.kindOf(['भारत', 'ने', '१९९१', 'में'], 2), EmphasisKind.year);
      expect(Emphasis.kindOf(['5', 'लाख', 'रुपये'], 1), EmphasisKind.money);
      expect(Emphasis.kindOf(['he', 'met', 'Elon', 'Musk'], 2), EmphasisKind.name);
      expect(Emphasis.kindOf(['the', 'RBI', 'said'], 1), EmphasisKind.name);
      // ALL CAPS transcripts have no Title Case names.
      expect(Emphasis.kindOf(['THE', 'BANK', 'IS', 'CLOSED', 'NOW'], 1), EmphasisKind.none);
    });

    test('AI reply parsing', () {
      expect(EmphasisAi.parse('Sure! {"emphasis": ["₹500 crore", "Musk", "the"]} hope it helps'), {'₹500', 'crore', 'musk'});
      expect(EmphasisAi.parse('["Gold", "1848"]'), {'gold', '1848'});
      expect(EmphasisAi.parse('no json here'), isEmpty);
      expect(EmphasisAi.userMessage(['a', 'b']), contains('a b'));
    });

    test('apply marks at most a few words per caption', () {
      final cues = CaptionGrouper.group(words('In 1991 India had only ₹500 crore and 2 banks'), const GroupingRules(maxWords: 10, maxLineChars: 80));
      Emphasis.apply(cues, maxPerCue: 2);
      expect(cues.single.emphasis, {1, 5, 6});
    });
  });

  group('subtitles', () {
    final cues = [
      CaptionCue(words('Hello there friend', start: 1.0), lineStarts: [2]),
      CaptionCue(words('दूसरी लाइन ₹500', start: 3601.25)),
    ];

    test('SRT round trip', () {
      final srt = Subtitles.toSrt(cues);
      expect(srt, startsWith('1\n00:00:01,000 --> 00:00:01,980\nHello there\nfriend\n\n2\n01:00:01,250 --> '));
      final back = Subtitles.parse(srt);
      expect(back, hasLength(2));
      expect(back[0].text, 'Hello there\nfriend');
      expect(back[0].start, closeTo(1.0, 1e-6));
      expect(back[0].end, closeTo(1.98, 1e-6));
      expect(back[1].flatText, 'दूसरी लाइन ₹500');
      expect(back[1].start, closeTo(3601.25, 1e-6));
      expect(Subtitles.toSrt(back), srt);
      // Words are spread over the cue, in order.
      final w = back[0].words;
      expect(w.first.start, closeTo(1.0, 1e-6));
      expect(w.last.end, closeTo(1.98, 1e-6));
      for (int i = 1; i < w.length; i++) {
        expect(w[i].start, greaterThanOrEqualTo(w[i - 1].start));
      }
    });

    test('VTT export and messy SRT import', () {
      final vtt = Subtitles.toVtt(cues);
      expect(vtt, startsWith('WEBVTT\n\n00:00:01.000 --> 00:00:01.980\n'));
      expect(Subtitles.parse(vtt).map((c) => c.flatText), ['Hello there friend', 'दूसरी लाइन ₹500']);
      const messy = '﻿1\r\n00:00:02,5 --> 00:00:04,000\r\n<i>Hello</i> {\\an8}world\r\n\r\n2\r\n00:00:05,000 --> 00:00:04,000\r\nbad\r\n\r\n3\r\n00:06.000 --> 00:07.500 align:start\r\nshort &amp; form\r\n';
      final m = Subtitles.parse(messy);
      expect(m.map((c) => c.flatText), ['Hello world', 'short & form']);
      expect(m[0].start, closeTo(2.5, 1e-6));
      expect(m[1].start, closeTo(6.0, 1e-6));
      expect(Subtitles.timestamp(3725.0071), '01:02:05,007');
      expect(Subtitles.parseTime('01:02:05,007'), closeTo(3725.007, 1e-9));
    });
  });

  group('styles', () {
    const en = 'In 1991 the Reserve Bank of India had only ₹500 crore left. Then everything changed for 140 crore people.';
    const deva = 'साल 1991 में भारत के पास सिर्फ़ ₹500 करोड़ बचे थे और फिर सब कुछ बदल गया';
    const roman = 'Saal 1991 mein Bharat ke paas sirf ₹500 crore bache the aur phir sab badal gaya';

    for (final style in CaptionStyles.all) {
      for (final frame in [(1920.0, 1080.0), (1080.0, 1920.0)]) {
        for (final text in [en, deva, roman]) {
          test('${style.id} ${frame.$1.round()}x${frame.$2.round()} ${text.substring(0, 6)}', () {
            final p = project(w: frame.$1, h: frame.$2);
            final cmds = CaptionBuilder.fromWords(p, words(text), CaptionOptions(style: style.id));
            expect(cmds, isNotEmpty);
            EditCommands.runAtomic(p, {'op': 'batch', 'commands': cmds});
            final layers = captionLayers(p);
            expect(layers, isNotEmpty);
            for (final l in layers) {
              expect(l.type, LayerType.text);
              expect(l.text!.animator, style.animator);
              expect(l.text!.words, isNotEmpty);
              expect(l.duration, greaterThan(0));
              final pos = l.prop(Props.position).staticValue;
              // Inside the frame and the vertical safe zone.
              expect(pos[1], inInclusiveRange(frame.$2 * 0.1, frame.$2 * 0.95));
              if (frame.$2 > frame.$1) expect(pos[1] + l.text!.fontSize * 0.6, lessThanOrEqualTo(frame.$2 * 0.77));
              expect(l.width, lessThanOrEqualTo(frame.$1 * 0.9));
            }
            // Captions never overlap in time (lines of one caption share it).
            final cues = CaptionTrack.read(p.main);
            for (int i = 1; i < cues.length; i++) {
              expect(cues[i].start, greaterThanOrEqualTo(cues[i - 1].end - 1e-6));
            }
            // Every word survives.
            expect([for (final c in cues) ...c.words].length, words(text).length);
            // The renderer's evaluator copes at a few times.
            for (final t in [0.6, 2.0, 4.0]) {
              Evaluator.evaluate(p.main, t);
            }
            // Style specifics.
            if (style.box != null) expect(layers.every((l) => l.text!.boxColor != 0), isTrue);
            if (style.glow > 0) expect(layers.every((l) => l.effects.any((e) => e.type == 'glow')), isTrue);
            if (style.stroke > 0) expect(layers.every((l) => l.effects.any((e) => e.type == 'outline')), isTrue);
            if (style.bounce) expect(layers.every((l) => l.prop(Props.scale).keyframes.length >= 3), isTrue);
            if (style.hollow > 0) expect(layers.every((l) => l.text!.outline > 0), isTrue);
            if (style.uppercase && text == en) expect(layers.every((l) => l.text!.text == l.text!.text.toUpperCase()), isTrue);
            if (style.maxLines == 1) expect(layers.every((l) => !l.text!.text.contains('\n')), isTrue);
            if (style.colorMarks && text != deva) {
              expect(layers.any((l) => l.text!.marks.any((m) => m.style == 'color')), isTrue, reason: 'keywords coloured');
            }
            if (!style.colorMarks) expect(layers.every((l) => l.text!.marks.isEmpty), isTrue);
          });
        }
      }
    }

    test('style ids, aliases and fonts', () {
      expect(CaptionStyles.ids.toSet(), hasLength(CaptionStyles.all.length));
      expect(CaptionStyles.byId('plain').id, 'boxed');
      expect(CaptionStyles.byId('nope').id, 'karaoke');
      expect(CaptionStyles.all.length, greaterThanOrEqualTo(10));
      CaptionFonts.available = {'Poppins'};
      expect(CaptionFonts.pick(['Montserrat', 'Poppins']), 'Poppins');
      expect(CaptionFonts.pick(['Anton']), isNull);
      CaptionFonts.available = null;
      expect(CaptionFonts.pick(['Anton', 'Poppins']), 'Anton');
      final p = project();
      EditCommands.runAtomic(p, {'op': 'batch', 'commands': CaptionBuilder.fromWords(p, words('भारत ने ₹500 करोड़ खर्च किए'), CaptionOptions(style: 'karaoke'))});
      expect(captionLayers(p).first.text!.fontFamily, 'Noto Sans Devanagari');
    });

    test('vertical frames get bigger text than horizontal', () {
      final h = CaptionLayout.of(1920, 1080, CaptionStyles.karaoke);
      final v = CaptionLayout.of(1080, 1920, CaptionStyles.karaoke);
      expect(v.vertical, isTrue);
      expect(v.fontSize, greaterThan(h.fontSize));
      expect(v.boxWidth, lessThan(1080 * 0.8)); // clear of the right-hand buttons
      final punch = CaptionLayout.of(1080, 1920, CaptionStyles.punchy);
      expect(punch.fontSize, greaterThan(v.fontSize * 1.4));
    });

    test('punchy captions have 1-3 words; word pop spreads with speech', () {
      final p = project(w: 1080, h: 1920);
      final cues = CaptionBuilder.cues(p.main, words('this is the craziest thing that ever happened to me honestly'), CaptionStyles.punchy);
      expect(cues.every((c) => c.words.length <= 3 && c.lines.length == 1), isTrue, reason: '${texts(cues)}');
      final p2 = project();
      EditCommands.runAtomic(p2, {'op': 'batch', 'commands': CaptionBuilder.fromWords(p2, words('one two three four', step: 0.5), CaptionOptions(style: 'word_pop'))});
      final l = captionLayers(p2).single;
      // Last word starts 1.5 s after the first → pop spread ≈ 1.5 / 0.6.
      expect(l.text!.animDuration, closeTo(2.5, 0.01));
    });

    test('legacy CaptionMaker.fromWords API', () {
      final p = project();
      final cmds = CaptionMaker.fromWords(p, words('Hello world this is a test of captions'), CaptionOptions(language: 'hi', roman: false, maxWords: 4, style: 'plain'));
      EditCommands.runAtomic(p, {'op': 'batch', 'commands': cmds});
      final ls = captionLayers(p);
      expect(ls.every((l) => l.id.startsWith('cap_')), isTrue);
      expect(ls.every((l) => l.text!.boxColor != 0), isTrue);
      expect(CaptionTrack.read(p.main).length, 2);
    });
  });

  group('caption track', () {
    test('read back, restyle and offset as one batch', () {
      final p = project();
      final ws = words('In 1991 the Reserve Bank of India had only ₹500 crore left and then the reforms began');
      EditCommands.runAtomic(p, {'op': 'batch', 'commands': CaptionBuilder.fromWords(p, ws, CaptionOptions(style: 'karaoke'))});
      final before = captionLayers(p).map((l) => l.id).toSet();
      final cues = CaptionTrack.read(p.main);
      expect([for (final c in cues) ...c.words.map((w) => w.word)], [for (final w in ws) w.word]);

      // Restyle to punchy (regrouped), shifted +0.5 s.
      final shifted = [for (final c in cues) c.copy()..shift(0.5)];
      EditCommands.runAtomic(p, CaptionTrack.replaceCommand(p, shifted, CaptionStyles.punchy));
      final after = CaptionTrack.read(p.main);
      expect(after.every((c) => c.words.length <= 3), isTrue);
      expect(after.first.words.first.start, closeTo(ws.first.start + 0.5, 1e-6));
      expect([for (final c in after) ...c.words].length, ws.length);
      expect(captionLayers(p).any((l) => before.contains(l.id)), isFalse, reason: 'old caption layers removed');

      // Keep boundaries (edits only), boxed style → one layer per line.
      EditCommands.runAtomic(p, CaptionTrack.replaceCommand(p, after, CaptionStyles.boxed, relayout: false));
      expect(CaptionTrack.read(p.main).length, after.length);
    });

    test('import from srt makes caption layers', () {
      final p = project();
      final cues = Subtitles.parse('1\n00:00:01,000 --> 00:00:03,000\nPehli line yahan hai\n\n2\n00:00:03,500 --> 00:00:05,000\n₹500 crore ka sawal\n');
      EditCommands.runAtomic(p, CaptionTrack.replaceCommand(p, cues, CaptionStyles.keyword, relayout: false));
      final back = CaptionTrack.read(p.main);
      expect(back.map((c) => c.flatText), ['Pehli line yahan hai', '₹500 crore ka sawal']);
      expect(back[0].start, closeTo(1, 1e-6));
      expect(back[1].end, closeTo(5, 1e-6));
      final marks = captionLayers(p).expand((l) => l.text!.marks).toList();
      expect(marks.any((m) => m.phrase.contains('₹500')), isTrue);
    });
  });

  group('safe area', () {
    test('offsetFor moves up past obstacles, else down', () {
      const block = CapRect(500, 900, 1400, 990);
      expect(CaptionSafeArea.offsetFor(block, const [], top: 60, bottom: 1020), 0);
      expect(CaptionSafeArea.offsetFor(block, const [CapRect(0, 0, 300, 100)], top: 60, bottom: 1020), 0);
      final dy = CaptionSafeArea.offsetFor(block, const [CapRect(400, 940, 1500, 1040)], top: 60, bottom: 1020, margin: 10);
      expect(dy, lessThan(0));
      expect(block.shift(dy).bottom, lessThanOrEqualTo(930));
      // No room above → goes below.
      final dy2 = CaptionSafeArea.offsetFor(const CapRect(500, 80, 1400, 170), const [CapRect(0, 60, 1920, 200)], top: 60, bottom: 1020);
      expect(dy2, greaterThan(0));
    });

    test('captions move above a lower third that is on screen', () {
      final p = project();
      EditCommands.runAtomic(p, {
        'op': 'batch',
        'commands': [
          {'op': 'add_layer', 'type': 'text', 'id': 'lt', 'name': 'Lower third', 'text': 'Dr. Manmohan Singh, Finance Minister', 'start': 0, 'duration': 3, 'width': 1300, 'height': 90, 'position': [960, 955, 0], 'font_size': 54},
          {'op': 'add_component', 'type': 'name_tag', 'id': 'nt', 'start': 0, 'duration': 3, 'name': 'A Very Long Person Name Here', 'role': 'Governor'},
        ],
      });
      final ws = [...words('first caption while the tag shows', start: 0.5), ...words('later caption after the tag', start: 5)];
      final plain = project();
      final ref = CaptionBuilder.fromWords(plain, ws, CaptionOptions(style: 'karaoke', maxWords: 6));
      final cmds = CaptionBuilder.fromWords(p, ws, CaptionOptions(style: 'karaoke', maxWords: 6));
      // y of the first caption layer starting before / after 4 s.
      double y(List<Map<String, dynamic>> c, int i) {
        final adds = c.where((m) => m['op'] == 'add_layer' && ((m['start'] as num) < 4) == (i == 0)).toList();
        return ((adds.first['position'] as List)[1] as num).toDouble();
      }

      expect(y(cmds, 0), lessThan(y(ref, 0) - 50), reason: 'moved up while the lower third is visible');
      expect(y(cmds, 1), closeTo(y(ref, 1), 0.01), reason: 'back to normal once it is gone');
      EditCommands.runAtomic(p, {'op': 'batch', 'commands': cmds});

      // The moved caption no longer overlaps the other text.
      final first = captionLayers(p).firstWhere((l) => l.start < 1);
      final items = Evaluator.evaluate(p.main, 1.0);
      final capItem = items.firstWhere((it) => it.layer.id == first.id);
      final cy = capItem.project(first.width / 2, first.height / 2).y;
      final capRect = CapRect(960 - 300, cy - first.text!.fontSize * 0.65, 960 + 300, cy + first.text!.fontSize * 0.65);
      for (final o in CaptionSafeArea.obstacles(p.main, 0.5, 2.5)) {
        expect(o.overlaps(capRect), isFalse, reason: '$o vs $capRect');
      }
      // Obstacles that are still only commands (e.g. a storyboard batch) count too.
      final fresh = project();
      final pendingCmds = [
        {'op': 'add_layer', 'type': 'text', 'id': 'lt2', 'text': 'Dr. Manmohan Singh, Finance Minister', 'start': 0, 'duration': 3, 'width': 1300, 'height': 90, 'position': [960, 955, 0], 'font_size': 54},
      ];
      final withPending = CaptionMaker.fromWords(fresh, ws, CaptionOptions(style: 'karaoke', maxWords: 6), pending: pendingCmds);
      expect(y(withPending, 0), lessThan(y(ref, 0) - 30));
      expect(fresh.main.layers, isEmpty, reason: 'pending commands run on a copy');

      // Turning the safe area off keeps the default spot.
      final off = CaptionBuilder.fromWords(p, ws, CaptionOptions(style: 'karaoke', maxWords: 6, safeArea: false));
      expect(y(off, 0), closeTo(y(ref, 0), 0.01));
    });

    test('vertical shorts: captions stay above the bottom UI zone', () {
      final p = project(w: 1080, h: 1920);
      final layout = CaptionLayout.of(1080, 1920, CaptionStyles.boxed);
      expect(layout.safeBottom, closeTo(1920 * 0.76, 0.01));
      final b = layout.block(['line one is here', 'and line two']);
      expect(b.rect.bottom, lessThanOrEqualTo(layout.safeBottom));
      expect(b.rect.top, greaterThanOrEqualTo(layout.safeTop));
      EditCommands.runAtomic(p, {'op': 'batch', 'commands': CaptionBuilder.fromWords(p, words('one two three four five six seven eight nine ten eleven twelve'), CaptionOptions(style: 'boxed'))});
      for (final l in captionLayers(p)) {
        expect(l.prop(Props.position).staticValue[1], lessThan(1920 * 0.76));
      }
    });
  });
}
