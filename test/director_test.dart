import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/world_map.dart';
import 'package:motionai/director/director.dart';
import 'package:motionai/director/sfx.dart';
import 'package:motionai/director/story_builder.dart';

Project project() {
  final p = Project(
    id: 'p',
    name: 'Doc',
    main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: 5),
  );
  p.media['photo'] = MediaAsset(id: 'photo', type: MediaType.image, path: '/a.jpg', name: 'a', width: 1200, height: 800, description: '[portrait · clear subject] Man in a suit');
  p.media['fg'] = MediaAsset(id: 'fg', type: MediaType.image, path: '/fg.png', name: 'a (subject)', width: 1200, height: 800);
  p.media['bg'] = MediaAsset(id: 'bg', type: MediaType.image, path: '/bg.jpg', name: 'a (background)', width: 1200, height: 800);
  p.media['clip'] = MediaAsset(id: 'clip', type: MediaType.video, path: '/v.mp4', name: 'talk', width: 1920, height: 1080, duration: 20);
  p.media['music'] = MediaAsset(id: 'music', type: MediaType.audio, path: '/m.mp3', name: 'music', width: 0, height: 0, duration: 8);
  for (final k in Sfx.kinds) {
    p.media['sfx_$k'] = MediaAsset(id: 'sfx_$k', type: MediaType.audio, path: '/$k.wav', name: 'SFX $k', width: 0, height: 0, duration: Sfx.length(k));
  }
  EditCommands.runAtomic(p, {'op': 'add_layer', 'type': 'video', 'media': 'clip', 'id': 'aroll', 'start': 0, 'fit': 'cover'});
  return p;
}

void main() {
  setUpAll(() => WorldMap.load(File('assets/world_countries.json').readAsStringSync()));

  test('media description survives save/load', () {
    final p = project();
    final back = Project.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(back.media['photo']!.description, contains('clear subject'));
    expect(back.media['fg']!.description, '');
  });

  test('sound effects are valid WAV files of the right length', () {
    for (final k in Sfx.kinds) {
      final b = Sfx.wav(k);
      expect(String.fromCharCodes(b.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(b.sublist(8, 12)), 'WAVE');
      expect((b.length - 44) / 4 / Sfx.rate, closeTo(Sfx.length(k), 0.01));
      expect(b.sublist(44).any((x) => x != 0), isTrue);
    }
  });

  test('duck envelope dips under speech and comes back', () {
    final env = StoryBuilder.duckEnvelope([(2, 4), (4.3, 6), (10, 11)], 14, 0.3, 0.1);
    for (int i = 1; i < env.length; i++) {
      expect(env[i].$1, greaterThan(env[i - 1].$1));
    }
    double at(double t) {
      for (int i = 1; i < env.length; i++) {
        if (t <= env[i].$1) {
          final a = env[i - 1], b = env[i];
          return a.$2 + (b.$2 - a.$2) * (t - a.$1) / (b.$1 - a.$1);
        }
      }
      return env.last.$2;
    }

    expect(at(1.0), closeTo(0.3, 1e-9));
    expect(at(3.0), closeTo(0.1, 1e-9));
    expect(at(4.15), closeTo(0.1, 1e-9)); // short gap bridged
    expect(at(8.0), closeTo(0.3, 1e-9));
    expect(at(10.5), closeTo(0.1, 1e-9));
    expect(at(13.5), closeTo(0.3, 1e-9));
    expect(StoryBuilder.duckEnvelope([], 5, 0.3, 0.1), [(0.0, 0.3), (5.0, 0.3)]);
  });

  test('full storyboard builds in one batch', () {
    final p = project();
    final beats = [
      Beat(0, 2, 'Ye kahani shuru hoti hai', {'media': 'photo', 'move': 'depth', 'behind_text': 'DHOKHA', 'transition': 'zoom_in'}),
      Beat(2, 4, 'Main aapko batata hoon', {'aroll': true, 'punch': true}),
      Beat(4, 6, '3 lakh crore ka nuksaan', {'component': 'counter', 'from': 0, 'to': 300000, 'suffix': ' CRORE'}),
      Beat(6, 8, 'Sri Lanka mein', {'component': 'map', 'countries': ['Sri Lanka', 'India'], 'focus': 'Sri Lanka'}),
      Beat(8, 10, 'Report ke mutabik', {'component': 'source_card', 'source': 'Source: example.org', 'headline': 'Debt', 'body': 'Debt rose in 2022.', 'highlights': ['2022']}),
      Beat(10, 12, 'Aur phir', {'media': 'photo', 'move': 'pan_left', 'transition': 'whip'}),
      Beat(12, 13, 'skip me', {'component': 'glow_word', 'text': 'NO'})..keep = false,
    ];
    final words = [for (int i = 0; i < 24; i++) WordTiming('w$i', i * 0.5, i * 0.5 + 0.4)];
    final o = BuildOptions(
      arollLayer: 'aroll',
      musicMedia: 'music',
      speech: StoryBuilder.speechFromWords(words),
      sfxMedia: {for (final k in Sfx.kinds) k: 'sfx_$k'},
      cutouts: {'photo': ('fg', 'bg')},
      captionWords: words,
      look: 'cinematic_doc',
      tag: 't',
    );
    final cmds = StoryBuilder.build(p, beats, o);
    EditCommands.runAtomic(p, {'op': 'batch', 'commands': cmds});
    final comp = p.main;

    // Depth: background, glowing word, subject on top of the word.
    final fg = comp.indexOf('dt_0_fg'), bg = comp.indexOf('dt_0_bg');
    final word = comp.layers.indexWhere((l) => l.id.startsWith('dt_0_w') && l.type == LayerType.text);
    expect(fg, greaterThanOrEqualTo(0));
    expect(word, greaterThan(fg));
    expect(bg, greaterThan(word));
    // Punch-in on the presenter.
    final s = comp.requireLayer('aroll').prop(Props.scale);
    expect(s.valueAt(3)[0], greaterThan(s.valueAt(1)[0] * 1.1));
    expect(s.valueAt(5)[0], closeTo(s.valueAt(1)[0], 0.01));
    // Skipped beat is not built.
    expect(comp.layers.any((l) => l.id.startsWith('dt_6')), isFalse);
    // Music loops to cover the video and is ducked under speech.
    final music = comp.layers.where((l) => l.name.startsWith('Music')).toList();
    expect(music.length, greaterThanOrEqualTo(2));
    expect(music.first.prop(Props.volume).scalarAt(3), lessThan(15));
    expect(comp.duration, greaterThanOrEqualTo(20));
    // Sound effects and captions.
    expect(comp.layers.where((l) => l.name.startsWith('SFX')).length, greaterThanOrEqualTo(3));
    expect(comp.layers.where((l) => l.id.startsWith('cap_')).isNotEmpty, isTrue);
  });

  test('depth without a cut-out falls back to a push-in', () {
    final p = project();
    final cmds = StoryBuilder.build(p, [Beat(0, 3, 'x', {'media': 'photo', 'move': 'depth'})], BuildOptions(tag: 'z'));
    EditCommands.runAtomic(p, {'op': 'batch', 'commands': cmds});
    final l = p.main.requireLayer('dz_0_m');
    expect(l.prop(Props.scale).valueAt(3)[0], greaterThan(l.prop(Props.scale).valueAt(0)[0] * 1.15));
  });

  test('script splitting and timing', () {
    final parts = Director.splitScript('Pehli line hai. Doosri line!\nTeesri line।');
    expect(parts.length, 3);
    final t = Director.estimateTimings(parts, 1);
    expect(t.first.$1, 1);
    expect(t[1].$1, greaterThan(t[0].$2));
  });

  test('director prompt mentions every component it may use', () {
    final prompt = Director.directorPrompt();
    for (final c in ['source_card', 'map', 'counter', 'timeline', 'glow_word', 'badge', 'depth', 'behind_text']) {
      expect(prompt, contains(c));
    }
    expect(Director.directorPrompt(cutouts: false), isNot(contains('behind_text')));
  });
}
