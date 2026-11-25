import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/ai/command_spec.dart';
import 'package:motionai/ai/phrase_finder.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/components.dart';
import 'package:motionai/core/presets/world_map.dart';
import 'package:motionai/director/director.dart';
import 'package:motionai/director/sfx.dart';
import 'package:motionai/director/story_builder.dart';
import 'package:vector_math/vector_math_64.dart';

const v1Types = [
  'name_tag', 'character_label', 'arrow_callout', 'censor_bar', 'plaque', 'poster', 'glass_screen',
  'title_slam', 'foreground_wipe', 'icon_stream', 'icon_badge', 'scanner', 'silhouette_crowd',
  'number_tiles', 'date_title', 'article', 'timeline',
];

Project project() {
  final p = Project(id: 'p', name: 'Doc', main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: 10));
  p.media['img'] = MediaAsset(id: 'img', type: MediaType.image, path: '/a.jpg', name: 'portrait', width: 1200, height: 800);
  p.media['cut'] = MediaAsset(id: 'cut', type: MediaType.image, path: '/c.png', name: 'person (subject)', width: 600, height: 1200);
  p.media['shot'] = MediaAsset(id: 'shot', type: MediaType.image, path: '/s.png', name: 'article screenshot', width: 1080, height: 4200);
  p.media['shot2'] = MediaAsset(id: 'shot2', type: MediaType.image, path: '/s2.png', name: 'tweet', width: 1200, height: 900);
  p.media['clip'] = MediaAsset(id: 'clip', type: MediaType.video, path: '/v.mp4', name: 'footage', width: 1920, height: 1080, duration: 12);
  p.media['music'] = MediaAsset(id: 'music', type: MediaType.audio, path: '/m.mp3', name: 'music', width: 0, height: 0, duration: 30);
  p.media['boom'] = MediaAsset(id: 'boom', type: MediaType.audio, path: '/i.wav', name: 'SFX impact', width: 0, height: 0, duration: 2.4);
  return p;
}

Map<String, dynamic> withMedia(String t) => switch (t) {
      'poster' => {'items': [{'title': 'WANTED', 'media': 'img'}, {'title': 'JOBS'}, {'title': 'LAND'}]},
      'glass_screen' => {'media': ['clip', 'img']},
      'title_slam' => {'title': 'GOLD RUSH', 'subtitle': 'STORY', 'music': 'music'},
      'foreground_wipe' => {'media': 'cut'},
      'icon_stream' => {'icons': ['img', '₹', {'text': 'A', 'color': '#FF0000'}]},
      'icon_badge' => {'media': 'img', 'shape': 'circle'},
      'scanner' => {'logo': 'img', 'targets': [{'media': 'cut', 'label': 'one'}, {'label': 'two'}]},
      'silhouette_crowd' => {'media': ['cut'], 'labels': ['FARMER', 'WORKER'], 'highlight': 2, 'confetti': true},
      'number_tiles' => {'text': '1996', 'word': 'AGO'},
      'date_title' => {'text': '1835', 'subtitle': 'Kentucky'},
      'article' => {
          'media': ['shot', 'shot2'],
          'coming_up': true,
          'marks': [
            {'box': [0.1, 0.30, 0.6, 0.32], 'style': 'highlight'},
            {'boxes': [[0.1, 0.62, 0.9, 0.64], [0.1, 0.65, 0.4, 0.67]], 'style': 'circle'},
            {'box': [0.2, 0.8, 0.5, 0.82], 'style': 'redact', 'word': 'SECRET'},
            {'box': [0.2, 0.2, 0.5, 0.25], 'style': 'underline', 'item': 1},
            {'phrase': 'not located yet'},
          ],
        },
      'character_label' => {'text': 'Hero'},
      'plaque' => {'style': 'bronze', 'name': 'ABE'},
      _ => <String, dynamic>{},
    };

void main() {
  setUpAll(() => WorldMap.load(File('assets/world_countries.json').readAsStringSync()));

  test('every V1 component is registered', () {
    for (final t in v1Types) {
      expect(Components.types, contains(t));
      expect(Components.label(t), isNot(t), reason: t);
    }
  });

  test('every V1 component builds with defaults and with media', () {
    for (final t in v1Types) {
      for (final extra in [<String, dynamic>{}, withMedia(t)]) {
        final p = project();
        EditCommands.runAtomic(p, {'op': 'add_layer', 'type': 'image', 'media': 'img', 'id': 'photo', 'fit': 'cover'});
        final r = EditCommands.runAtomic(p, {'op': 'add_component', 'type': t, 'id': 'k', 'start': 0.5, 'duration': 6, ...extra});
        expect(r.createdIds, isNotEmpty, reason: t);
        for (double time = 0; time < 7; time += 0.45) {
          Evaluator.evaluate(p.main, time);
        }
      }
    }
  });

  test('name tag: highlight bar sweeps in from the left', () {
    final p = project();
    EditCommands.runAtomic(p, {'op': 'add_component', 'type': 'name_tag', 'id': 'nt', 'start': 1, 'name': 'Mohit', 'role': 'Host'});
    final bar = p.main.requireLayer('nt_bar');
    expect(bar.parentId, 'nt_g');
    expect(bar.prop(Props.anchor).staticValue[0], 0);
    expect(bar.prop(Props.scale).valueAt(1.3)[0], 0);
    expect(bar.prop(Props.scale).valueAt(2)[0], 100);
    expect(p.main.requireLayer('nt_role').start, greaterThan(1.3));
  });

  test('character label pins to a layer', () {
    final p = project();
    EditCommands.runAtomic(p, {'op': 'add_layer', 'type': 'solid', 'id': 'guy', 'width': 200, 'height': 400, 'position': [600, 500, 0]});
    EditCommands.runAtomic(p, {'op': 'add_component', 'type': 'character_label', 'id': 'cl', 'start': 0, 'text': 'boss', 'attach': 'guy', 'at': [0.5, 0]});
    final g = p.main.requireLayer('cl_g').prop(Props.position).staticValue;
    expect(g[0], closeTo(600, 0.5));
    expect(g[1], closeTo(300, 0.5));
    expect(p.main.requireLayer('cl_label').text!.text, 'BOSS');
  });

  test('icon stream uses Layer.path + path_progress', () {
    final p = project();
    final c = {'op': 'add_component', 'type': 'icon_stream', 'id': 'is', 'start': 0, 'duration': 5, 'count': 3, 'from': [100, 900], 'to': [1800, 200]};
    final cmds = Components.build(p, c, 0);
    final paths = cmds.where((m) => m['op'] == 'update_layer' && m['path'] != null).toList();
    expect(paths.length, 3);
    expect((paths.first['path'] as Map)['points'], hasLength(3));
    expect(((paths.first['path'] as Map)['points'] as List).first, [100, 900]);
    final prog = cmds.where((m) => m['op'] == 'set_keyframe' && m['prop'] == 'path_progress').toList();
    expect(prog.length, 6);
    EditCommands.runAtomic(p, c);
    final icon = p.main.requireLayer('is_i1_icon');
    expect(icon.prop('path_progress').valueAt(0.35 + 1.2)[0], closeTo(50, 0.01));
  });

  test('scanner: targets matted to the beam, beam swings to each target', () {
    final p = project();
    final c = {
      'op': 'add_component', 'type': 'scanner', 'id': 'sc', 'start': 0, 'duration': 6,
      'targets': [{'label': 'A', 'x': 400, 'y': 300}, {'label': 'B', 'x': 1500, 'y': 300}],
    };
    final cmds = Components.build(p, c, 0);
    final mattes = cmds.where((m) => m['op'] == 'update_layer' && m['matte'] != null).toList();
    expect(mattes.length, 2);
    expect(mattes.first['matte'], {'layer': 'sc_beam_matte', 'mode': 'alpha'});
    EditCommands.runAtomic(p, c);
    final rig = p.main.requireLayer('sc_rig').prop(Props.rotation);
    // origin (960, 928.8): target A is up-left, B up-right.
    expect(rig.valueAt(1.0)[2], lessThan(-90));
    expect(rig.valueAt(3.0)[2], greaterThan(-90));
    expect(p.main.requireLayer('sc_tag1').start, greaterThan(2));
  });

  test('silhouette crowd: colour stored as rgb, highlight keeps colour, figures rise', () {
    final p = project();
    EditCommands.runAtomic(p, {'op': 'add_component', 'type': 'silhouette_crowd', 'id': 'cr', 'start': 0, 'media': ['cut'], 'count': 4, 'highlight': 1, 'color': '#FFC107'});
    final f0 = p.main.requireLayer('cr_f0');
    final fx = f0.effects.firstWhere((e) => e.type == 'silhouette');
    expect(fx.params['color']!.staticValue, [255, 193, 7]);
    expect(p.main.requireLayer('cr_f1').effects.any((e) => e.type == 'silhouette'), isFalse);
    expect(p.main.layerById('cr_bar1'), isNotNull);
    expect(f0.prop(Props.position).valueAt(0)[1], greaterThan(f0.prop(Props.position).valueAt(2)[1]));
  });

  test('number tiles: the reel window stays on the tile while rolling', () {
    final p = project();
    EditCommands.runAtomic(p, {'op': 'add_component', 'type': 'number_tiles', 'id': 'nt', 'start': 0, 'text': '42'});
    final reel = p.main.requireLayer('nt_r0');
    final tile = p.main.requireLayer('nt_tile0');
    final mask = reel.masks.single;
    for (final t in [0.1, 0.5, 0.9, 1.4]) {
      final c = mask.props['center']!.valueAt(t);
      final onScreen = Evaluator.worldMatrix(p.main, reel, t).transformed3(Vector3(c[0], c[1], 0));
      final tileCenter = Evaluator.worldMatrix(p.main, tile, t).transformed3(Vector3(tile.width / 2, tile.height / 2, 0));
      expect(onScreen.x, closeTo(tileCenter.x, 0.5));
      expect(onScreen.y, closeTo(tileCenter.y, 0.5));
    }
    // Ends on the real character.
    expect(reel.text!.text.split('\n').last, '4');
  });

  test('year ruler stops with the marker year under the marker', () {
    final p = project();
    EditCommands.runAtomic(p, {'op': 'add_component', 'type': 'timeline', 'id': 'tl', 'start': 0, 'from': 1800, 'to': 1900, 'step': 10, 'marker': 1835});
    final ruler = p.main.requireLayer('tl_ruler');
    final label = p.main.layers.firstWhere((l) => l.parentId == 'tl_ruler' && l.text?.text == '1830');
    final x0 = Evaluator.worldMatrix(p.main, label, 0).transformed3(Vector3(label.width / 2, 0, 0)).x;
    final x1 = Evaluator.worldMatrix(p.main, label, 4).transformed3(Vector3(label.width / 2, 0, 0)).x;
    expect(x1, lessThan(x0));
    // 1835 sits at the group centre (x = 960) when the ruler stops.
    final pxYear = 1920 * 0.16 / 10;
    expect(x1 + 5 * pxYear, closeTo(960, 0.5));
    expect(ruler.prop(Props.position).isAnimated, isTrue);
    expect(p.main.requireLayer('tl_date').text!.text, '1835');
    // The old look is still there.
    EditCommands.runAtomic(p, {'op': 'add_component', 'type': 'timeline', 'id': 'old', 'start': 0, 'style': 'classic'});
    expect(p.main.layerById('old_marker'), isNotNull);
  });

  test('title slam: impact decays to silence, music drops, flashes at 0 and drop', () {
    final p = project();
    EditCommands.runAtomic(p, {'op': 'add_component', 'type': 'title_slam', 'id': 'ts', 'start': 0, 'duration': 5, 'music': 'music'});
    final hit = p.main.requireLayer('ts_hit');
    expect(hit.mediaId, 'boom'); // found by name "SFX impact"
    expect(hit.prop(Props.volume).valueAt(0)[0], 100);
    expect(hit.prop(Props.volume).valueAt(2.4)[0], closeTo(0, 0.01));
    final music = p.main.requireLayer('ts_music');
    expect(music.start, closeTo(2.6, 1e-9));
    final flash = p.main.requireLayer('ts_flash').prop(Props.opacity);
    expect(flash.valueAt(0)[0], 100);
    expect(flash.valueAt(1.5)[0], 0);
    expect(flash.valueAt(2.6)[0], 100);
    final sub = p.main.requireLayer('ts_sub');
    expect(sub.text!.animator, 'random_pop');
    expect(sub.effects.any((e) => e.type == 'glow'), isTrue);
    expect(p.main.requireLayer('ts_bokeh').effects.single.type, 'particles');
    expect(p.main.requireLayer('ts_g').prop(Props.scale).valueAt(0)[0], greaterThan(150));
    // hit: none → no sound.
    final q = project();
    EditCommands.runAtomic(q, {'op': 'add_component', 'type': 'title_slam', 'id': 'ts', 'start': 0, 'hit': 'none'});
    expect(q.main.layerById('ts_hit'), isNull);
  });

  test('article: tall screenshot scrolls and stops on each mark, marks live in the screenshot', () {
    final p = project();
    EditCommands.runAtomic(p, {
      'op': 'add_component', 'type': 'article', 'id': 'ar', 'start': 0, 'duration': 8, 'media': 'shot', 'coming_up': 'Next',
      'marks': [
        {'box': [0.1, 0.70, 0.6, 0.72], 'style': 'circle', 'delay': 4},
        {'box': [0.1, 0.30, 0.6, 0.32], 'style': 'highlight', 'delay': 1.5},
        {'box': [0.2, 0.5, 0.5, 0.52], 'style': 'redact', 'word': 'SECRET', 'delay': 2.8},
        {'phrase': 'unknown words'},
      ],
    });
    final img = p.main.requireLayer('ar_a0_img');
    expect(img.masks, hasLength(1));
    final pos = img.prop(Props.position);
    expect(pos.isAnimated, isTrue);
    // Moves up (scrolls down the page) and stops at each mark.
    expect(pos.valueAt(1.5)[1], lessThan(pos.valueAt(0)[1]));
    expect(pos.valueAt(4)[1], lessThan(pos.valueAt(2.8)[1]));
    expect(pos.valueAt(1.5)[1], closeTo(pos.valueAt(1.8)[1], 1e-6));
    // The visible window stays put: the mask moves opposite to the content.
    final m = img.masks.single.props['center']!;
    for (final t in [0.6, 1.0, 2.0, 3.5, 5.0]) {
      final c = Evaluator.worldMatrix(p.main, img, t).transformed3(Vector3(m.valueAt(t)[0], m.valueAt(t)[1], 0));
      expect(c.x, closeTo(960, 0.5));
      expect(c.y, closeTo(540, 0.5));
    }
    final marks = p.main.layers.where((l) => l.parentId == 'ar_a0_img').toList();
    expect(marks.length, 4); // highlight, redact bar + its word, circle (phrase-only mark skipped)
    final word = marks.firstWhere((l) => l.type == LayerType.text);
    expect(word.text!.text, 'SECRET');
    expect(word.text!.animator, 'scramble');
    expect(p.main.requireLayer('ar_a0_paper').effects.map((e) => e.type), containsAll(['torn_edge', 'shadow']));
    expect(p.main.requireLayer('ar_next_text').text!.text, 'NEXT');
  });

  test('article boxes are clamped and ordered', () {
    final p = project();
    EditCommands.runAtomic(p, {
      'op': 'add_component', 'type': 'article', 'id': 'ar', 'start': 0, 'media': 'shot2', 'backdrop': 'none',
      'marks': [{'box': [0.9, 0.5, -0.2, 0.4], 'style': 'box'}],
    });
    final mark = p.main.layers.firstWhere((l) => l.parentId == 'ar_a0_img');
    final px = mark.prop(Props.position).staticValue;
    expect(px[0], closeTo(0.45 * 1200, 0.5));
    expect(px[1], closeTo(0.45 * 900, 0.5));
    expect(p.main.layerById('ar_bg'), isNull);
  });

  group('renderer contract names (B) are accepted before the merge', () {
    test('effects with colour and option params', () {
      final p = project();
      EditCommands.runAtomic(p, {
        'op': 'batch',
        'commands': [
          {'op': 'add_layer', 'type': 'solid', 'id': 's'},
          {'op': 'add_effect', 'layer': 's', 'effect': 'particles', 'id': 'pa', 'params': {'kind': 'leaves', 'amount': 30, 'color': '#102030'}},
          {'op': 'add_effect', 'layer': 's', 'effect': 'reveal', 'id': 'rv', 'params': {'kind': 'ink', 'progress': 0}},
          {'op': 'set_keyframe', 'target': 's', 'effect': 'rv', 'prop': 'progress', 'time': 1, 'value': 100},
          {'op': 'add_effect', 'layer': 's', 'effect': 'torn_edge', 'params': {'side': 'top'}},
          {'op': 'add_effect', 'layer': 's', 'effect': 'curve', 'params': {'bend': 30}},
          {'op': 'add_effect', 'layer': 's', 'effect': 'tint', 'params': {'color': '#FF8000'}},
        ],
      });
      final s = p.main.requireLayer('s');
      final pa = s.effectById('pa')!;
      expect(pa.params['color']!.staticValue, [16, 32, 48]);
      expect(pa.params['kind']!.staticValue, [1]);
      expect(s.effectById('rv')!.params['progress']!.keyframes, hasLength(1));
      expect(s.effects.firstWhere((e) => e.type == 'tint').params['color']!.staticValue, [255, 128, 0]);
      expect(() => EditCommands.runAtomic(p, {'op': 'add_effect', 'layer': 's', 'effect': 'sparkle_magic'}), throwsA(isA<CommandError>()));
      expect(() => EditCommands.runAtomic(p, {'op': 'add_effect', 'layer': 's', 'effect': 'particles', 'params': {'kind': 'fireflies'}}), throwsA(isA<CommandError>()));
    });

    test('animators, transitions, path_progress, matte/path data, motion blur', () {
      final p = project();
      EditCommands.runAtomic(p, {
        'op': 'batch',
        'commands': [
          {'op': 'add_layer', 'type': 'solid', 'id': 'mt', 'width': 400, 'height': 400},
          {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'HELLO', 'animator': 'random_pop', 'extrude': {'depth': 10, 'color': '#888888'}},
          {'op': 'update_layer', 'layer': 't', 'animator': 'scramble', 'matte': {'layer': 'mt', 'mode': 'alpha'}, 'path': {'points': [[0, 0], [100, 100]]}},
          for (final tr in ['iris', 'ink', 'smoke', 'spin', 'flash', 'glitch_flash']) {'op': 'animate_in', 'layer': 't', 'preset': tr},
          {'op': 'set_keyframe', 'target': 't', 'prop': 'path_progress', 'time': 0, 'value': 0},
          {'op': 'set_keyframe', 'target': 't', 'prop': 'path_progress', 'time': 2, 'value': 100},
          {'op': 'set_comp', 'motion_blur': true},
        ],
      });
      final t = p.main.requireLayer('t');
      expect(t.text!.animator, 'scramble');
      expect(t.matte, const LayerMatte('mt'));
      expect(t.text!.extrude, 10);
      expect(t.prop('path_progress').valueAt(1)[0], greaterThan(0));
      expect(() => EditCommands.runAtomic(p, {'op': 'update_layer', 'layer': 't', 'matte': {'layer': 't'}}), throwsA(isA<CommandError>()));
      expect(() => EditCommands.runAtomic(p, {'op': 'update_layer', 'layer': 't', 'animator': 'wobble'}), throwsA(isA<CommandError>()));
      expect(() => EditCommands.runAtomic(p, {'op': 'set_comp', 'motion_blur': 'yes'}), throwsA(isA<CommandError>()));
    });
  });

  group('phrase finder', () {
    test('parses fractions, pixels, percentages and maps', () {
      expect(PhraseFinder.parseBoxes('{"found":true,"boxes":[[0.1,0.2,0.5,0.25]]}'), [[0.1, 0.2, 0.5, 0.25]]);
      final px = PhraseFinder.parseBoxes('Here: {"boxes":[[120, 400, 600, 450]]}', width: 1200, height: 800);
      expect(px.single[0], closeTo(0.1, 1e-9));
      expect(px.single[3], closeTo(450 / 800, 1e-9));
      expect(PhraseFinder.parseBoxes('{"boxes":[[10, 20, 50, 25]]}').single, [0.1, 0.2, 0.5, 0.25]);
      final m = PhraseFinder.parseBoxes('{"boxes":[{"x":0.1,"y":0.2,"w":0.3,"h":0.05}, {"x0":0.6,"y0":0.5,"x1":0.2,"y1":0.45}]}');
      expect(m[0][2], closeTo(0.4, 1e-9));
      expect(m[1], [0.2, 0.45, 0.6, 0.5]);
      expect(PhraseFinder.parseBoxes('{"found":false,"boxes":[]}'), isEmpty);
      expect(PhraseFinder.parseBoxes('sorry, no JSON'), isEmpty);
      expect(PhraseFinder.parseBoxes('[[0.1,0.1,0.2,0.2]]'), hasLength(1));
      expect(PhraseFinder.parseBoxes('{"boxes":[[0.3,0.3,0.3,0.3]]}'), isEmpty); // empty box
    });

    test('found boxes drive article marks', () {
      final boxes = PhraseFinder.parseBoxes('{"boxes":[[0.1,0.30,0.6,0.32],[0.1,0.33,0.3,0.35]]}');
      final p = project();
      EditCommands.runAtomic(p, {'op': 'add_component', 'type': 'article', 'id': 'ar', 'start': 0, 'media': 'shot2', 'marks': [{'boxes': boxes, 'style': 'underline'}]});
      expect(p.main.layers.where((l) => l.parentId == 'ar_a0_img').length, 2);
    });
  });

  group('AI wiring', () {
    test('command spec documents every new component, effect and op', () {
      for (final w in [
        ...v1Types, 'make_3d', 'camera_shot', 'room', 'board', 'map_fly', 'route_follow', 'needle_pin', 'avatar_pin',
        'silhouette', 'mono', 'duotone', 'edge_blur', 'curve', 'glass_frame', 'torn_edge', 'particles', 'light_rays', 'sway',
        'reveal', 'motion_blur', 'random_pop', 'scramble', 'extrude', 'matte', 'path_progress', 'iris', 'glitch_flash',
      ]) {
        expect(commandSpec, contains(w), reason: w);
      }
    });

    test('director prompt knows the new visuals', () {
      final prompt = Director.directorPrompt();
      for (final w in [
        'name_tag', 'label', 'article', 'phrase', 'map_fly', 'needle_pin', 'route_follow', 'icon_stream', 'scanner',
        'silhouette_crowd', 'drift', 'push_through', 'pull_back', 'foreground_wipe', 'glass_screen', 'title_slam',
      ]) {
        expect(prompt, contains(w), reason: w);
      }
      expect(Director.directorPrompt(cutouts: false), isNot(contains('behind_text')));
    });

    test('impact sound decays to silence', () {
      final b = Sfx.wav('impact');
      expect((b.length - 44) / 4 / Sfx.rate, closeTo(2.4, 0.01));
      int level(int from, int to) {
        var m = 0;
        for (int i = 44 + from * 4; i < 44 + to * 4; i += 2) {
          final v = b[i] | (b[i + 1] << 8);
          final s = v >= 0x8000 ? v - 0x10000 : v;
          if (s.abs() > m) m = s.abs();
        }
        return m;
      }

      final n = (b.length - 44) ~/ 4;
      expect(level(0, n ~/ 10), greaterThan(level(n * 9 ~/ 10, n) * 8));
    });

    test('storyboard with the new visuals builds in one batch', () {
      final p = project();
      for (final k in Sfx.kinds) {
        p.media['sfx_$k'] = MediaAsset(id: 'sfx_$k', type: MediaType.audio, path: '/$k.wav', name: 'SFX $k', width: 0, height: 0, duration: Sfx.length(k));
      }
      final beats = [
        Beat(0, 3, 'Gold rush', {'component': 'title_slam', 'title': 'GOLD RUSH', 'subtitle': 'STORY'}),
        Beat(3, 5, 'Meet John', {'media': 'img', 'move': 'push_in', 'transition': 'ink', 'name_tag': {'name': 'John', 'role': 'Miner'}, 'label': 'JOHN'}),
        Beat(5, 7, 'The report said', {'component': 'article', 'media': 'shot', 'marks': [{'box': [0.1, 0.3, 0.6, 0.32], 'style': 'highlight'}, {'phrase': 'x'}]}),
        Beat(7, 9, 'Money flowed', {'component': 'icon_stream', 'icons': ['₹', 'img', 'nope']}),
        Beat(9, 11, 'They watched', {'component': 'scanner', 'targets': [{'media': 'cut', 'label': 'A'}]}),
        Beat(11, 13, 'Thousands', {'component': 'silhouette_crowd', 'media': ['cut', 'missing'], 'labels': ['A']}),
        Beat(13, 15, 'Then', {'media': 'clip', 'move': 'drift', 'transition': 'foreground_wipe'}),
        Beat(15, 17, 'On screen', {'component': 'glass_screen', 'media': ['clip']}),
        Beat(17, 19, 'In 1835', {'component': 'date_title', 'text': '1835'}),
        Beat(19, 21, '200 years', {'component': 'number_tiles', 'text': '200', 'word': 'YEARS'}),
        Beat(21, 23, 'Off to France', {'component': 'route_follow', 'from': 'India', 'to': 'France'}),
      ];
      final o = BuildOptions(musicMedia: 'music', sfxMedia: {for (final k in Sfx.kinds) k: 'sfx_$k'}, tag: 'q');
      final cmds = StoryBuilder.build(p, beats, o);
      EditCommands.runAtomic(p, {'op': 'batch', 'commands': cmds});
      final comp = p.main;
      expect(comp.layerById('dq_0_hit')!.mediaId, 'sfx_impact');
      // The intro stays silent until the drop: music starts after it.
      final music = comp.layers.where((l) => l.name.startsWith('Music')).toList();
      expect(music.map((l) => l.start).reduce((a, b) => a < b ? a : b), closeTo(2.6, 1e-6));
      expect(comp.layerById('dq_1_nt_g'), isNotNull);
      expect(comp.layerById('dq_1_lb_g'), isNotNull);
      expect(comp.layerById('dq_2_a0_img'), isNotNull);
      expect(comp.layerById('dq_6_wipe_wipe'), isNotNull);
      expect(comp.layers.any((l) => l.id.startsWith('dq_10')), isFalse); // not available on this build → skipped
      // Without the 3D scene ops, 3D moves fall back to a 2D push.
      if (!StoryBuilder.has3d) expect(comp.requireLayer('dq_6_m').prop(Props.scale).isAnimated, isTrue);
    });
  });
}
