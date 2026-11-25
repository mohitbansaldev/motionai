import 'dart:convert';
import 'dart:io';

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/ai/command_spec.dart';
import 'package:motionai/audio/audio_cache.dart';
import 'package:motionai/audio/music_analysis.dart';
import 'package:motionai/audio/sfx_library.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/model/anim_prop.dart';
import 'package:motionai/core/model/easing.dart';
import 'package:motionai/core/model/effects_catalog.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/doc_transitions.dart';
import 'package:motionai/core/presets/templates.dart';
import 'package:motionai/director/sfx.dart';
import 'package:motionai/ui/preview/composition_canvas.dart';

Project newProject({double w = 1920, double h = 1080}) => Project(
      id: 'p',
      name: 'TR',
      main: Composition(id: 'main', name: 'Main', width: w, height: h, fps: 30, duration: 10),
    );

CommandResult run(Project p, Map<String, dynamic> c) => EditCommands.runAtomic(p, c);

/// Two shots: a (0..5 s) and b (5..10 s), plus a "door" and a "photo" layer for the region types.
Project twoShots() {
  final p = newProject();
  p.media['img'] = MediaAsset(id: 'img', type: MediaType.image, path: '/nonexistent/a.png', name: 'tree', width: 800, height: 1600);
  run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'b', 'color': '#806040', 'start': 5, 'duration': 5});
  run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'a', 'color': '#304060', 'start': 0, 'duration': 5});
  run(p, {'op': 'add_layer', 'type': 'shape', 'id': 'door', 'kind': 'rect', 'width': 200, 'height': 360, 'position': [960, 600, 0], 'fill': '#201008', 'start': 0, 'duration': 5});
  return p;
}

Map<String, dynamic> paramsFor(String type) => switch (type) {
      'push_through' => {'target': 'door'},
      'zoom_into_photo' => {'layer': 'door'},
      'match_cut' => {'from_point': [800, 500], 'to_point': [1100, 560], 'from_size': 200, 'to_size': 320},
      'foreground_wipe' => {'shape': 'tree'},
      _ => const {},
    };

const hardCuts = {'dolly_zoom', 'film_burn', 'glitch_cut', 'flash_cut', 'dip_to_black'};

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('v2tr');
    SfxLibrary.dir = tmp.path;
    AudioCache.clear();
  });
  tearDown(() {
    SfxLibrary.dir = null;
    AudioCache.clear();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('catalog', () {
    test('has every documentary type with unique ids, documented in the spec', () {
      const want = [
        'push_through', 'foreground_wipe', 'zoom_into_photo', 'map_drop', 'match_cut', 'whip_pan', 'parallax_slide',
        'paper_tear', 'burn_edge', 'page_turn', 'focus_pull', 'dolly_zoom', 'film_burn', 'light_leak_wipe', 'ink_bleed',
        'smoke_reveal', 'bw_to_colour', 'glitch_cut', 'flash_cut', 'dip_to_black',
      ];
      expect(DocTransitions.types.toSet(), containsAll(want)); // V3-D: more types (test/v3_fxtrans_test.dart)
      expect(DocTransitions.types.toSet().length, DocTransitions.types.length);
      for (final d in DocTransitions.catalog) {
        expect(commandSpec, contains(d.id), reason: d.id);
        expect(d.duration, greaterThan(0));
        expect(d.pre, inInclusiveRange(0, 1));
        for (final s in d.sounds) {
          expect(Sfx.all, contains(s), reason: '${d.id} sound $s');
        }
      }
      expect(EditCommands.ops, containsAll(['transition', 'list_transitions']));
      expect(EffectsCatalog.byType('burn_edge'), isNotNull);
      expect(EffectsCatalog.byType('page_curl'), isNotNull);
    });

    test('list_transitions logs the catalog JSON', () {
      final p = newProject();
      final r = run(p, {'op': 'list_transitions'});
      final j = jsonDecode(r.log.single) as List;
      expect(j.length, DocTransitions.catalog.length);
      final first = j.first as Map;
      expect(first.keys, containsAll(['id', 'label', 'best_for', 'default_duration', 'params', 'sound']));
    });

    test('registerAll registers every type and apply works on a comp', () {
      final names = <String>[];
      DocTransitions.registerAll((name, fn) => names.add(name));
      expect(names, DocTransitions.types);
      final p = twoShots();
      DocTransitions.apply(p.main, p.main.layerById('a')!, p.main.layerById('b')!, 'whip_pan', {'direction': 'right'});
      expect(p.main.layerById('b')!.prop(Props.position).keyframes, isNotEmpty);
    });

    test('gallery has a Transitions template for each type', () {
      for (final d in DocTransitions.catalog) {
        final t = SceneTemplates.byId('doc_tr_${d.id}');
        expect(t, isNotNull, reason: d.id);
        expect(t!.category, 'Transitions');
      }
    });
  });

  group('every type', () {
    for (final type in DocTransitions.types) {
      test('$type applies, cut on time, eased, SFX peak on the cut, one undo step', () {
        final p = twoShots();
        final before = ProjectSnapshot.take(p);
        final r = run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': type, 'params': paramsFor(type)});
        final comp = p.main;
        final a = comp.layerById('a')!, b = comp.layerById('b')!;
        const cut = 5.0;
        expect(r.log.join('\n'), contains('cut at 5.00'));
        // The two shots meet around the cut.
        expect(a.end, greaterThanOrEqualTo(cut - 1e-6), reason: 'outgoing reaches the cut');
        expect(b.start, lessThanOrEqualTo(cut + 1e-6), reason: 'incoming starts by the cut');
        if (hardCuts.contains(type)) {
          expect(b.start, closeTo(cut, 1e-6));
          expect(a.end, closeTo(cut, 1e-6));
        }
        // Something animated, and nothing linear.
        var keys = 0;
        void check(String what, List<Keyframe> ks) {
          for (int i = 0; i < ks.length - 1; i++) {
            keys++;
            expect(ks[i].easing.type, isNot(EaseType.linear), reason: '$type $what @${ks[i].time}');
          }
        }

        for (final l in comp.layers) {
          if (l.type == LayerType.audio) continue;
          if (!(l.id == 'a' || l.id == 'b' || l.id.startsWith('tr_b_') || l.id == 'door')) continue;
          l.props.forEach((k, v) => check('${l.id}.$k', v.keyframes));
          for (final e in l.effects) {
            e.params.forEach((k, v) => check('${l.id}.${e.id}.$k', v.keyframes));
          }
          for (final m in l.masks) {
            m.props.forEach((k, v) => check('${l.id}.${m.id}.$k', v.keyframes));
          }
        }
        expect(keys, greaterThan(0), reason: '$type writes keyframes');
        // Default sound: its peak lands on the cut.
        final sfx = [for (final l in comp.layers) if (l.type == LayerType.audio && l.id.startsWith('tr_b_sfx_')) l];
        expect(sfx.length, DocTransitions.byId(type)!.sounds.length);
        for (final l in sfx) {
          final kind = l.id.substring('tr_b_sfx_'.length);
          if (Sfx.isBed(kind)) {
            expect(l.start, lessThan(cut));
            expect(l.end, greaterThan(cut));
          } else {
            expect(l.start + Sfx.peak(kind) - l.sourceIn, closeTo(cut, 1e-6), reason: kind);
          }
        }
        // One undo step restores the project exactly.
        ProjectSnapshot.restore(p, before);
        expect(ProjectSnapshot.take(p), before);
      });
    }
  });

  group('options', () {
    test('at moves the cut; duration sets the window; sound false / kind', () {
      final p = twoShots();
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'whip_pan', 'at': 4.5, 'duration': 0.6, 'sound': false});
      final a = p.main.layerById('a')!, b = p.main.layerById('b')!;
      expect(b.start, closeTo(4.2, 1e-6));
      expect(a.end, closeTo(4.8, 1e-6));
      expect(p.main.layers.where((l) => l.type == LayerType.audio), isEmpty);
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'whip_pan', 'at': 4.5, 'sound': 'hit'});
      final hit = p.main.layerById('tr_b_sfx_hit')!;
      expect(hit.start + Sfx.peak('hit'), closeTo(4.5, 1e-6));
    });

    test('peak of a long riser lands on the cut', () {
      final p = twoShots();
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'dolly_zoom', 'sound': 'riser'});
      final l = p.main.layerById('tr_b_sfx_riser')!;
      expect(l.start + Sfx.peak('riser'), closeTo(5, 1e-6));
    });

    test('snap_to_beat with a beat list moves the cut to the nearest beat within 0.25 s', () {
      final p = twoShots();
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'flash_cut', 'snap_to_beat': true, 'beats': [3.0, 5.2, 6.0]});
      expect(p.main.layerById('b')!.start, closeTo(5.2, 1e-6));
      final q = twoShots();
      run(q, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'flash_cut', 'snap_to_beat': true, 'beats': [4.5, 5.6]});
      expect(q.main.layerById('b')!.start, closeTo(5.0, 1e-6), reason: 'beats too far: cut stays');
    });

    test('snap_to_beat uses analysed music on the timeline', () {
      final p = twoShots();
      p.media['song'] = MediaAsset(id: 'song', type: MediaType.audio, path: '/nonexistent/song.wav', name: 'music', width: 0, height: 0, duration: 20);
      run(p, {'op': 'add_layer', 'type': 'audio', 'media': 'song', 'id': 'music', 'name': 'Music', 'start': 0});
      AudioCache.putMusic(p.media['song']!, MusicAnalysis.grid(120, offset: 0.1, duration: 20)); // beats 0.1, 0.6 … 5.1
      final r = run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'whip_pan', 'snap_to_beat': true});
      expect(r.log.join('\n'), contains('beat'));
      final whoosh = p.main.layerById('tr_b_sfx_whoosh')!;
      expect(whoosh.start + Sfx.peak('whoosh'), closeTo(5.1, 1e-6));
    });

    test('re-applying replaces the previous transition', () {
      final p = twoShots();
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'smoke_reveal'});
      final n = p.main.layers.length;
      final fx = p.main.layerById('b')!.effects.length;
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'smoke_reveal'});
      expect(p.main.layers.length, n);
      expect(p.main.layerById('b')!.effects.length, fx);
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'ink_bleed'});
      expect(p.main.layerById('tr_b_smoke'), isNull);
      expect(p.main.layerById('b')!.effects.where((e) => e.type == 'reveal').length, 1);
    });

    test('layers: [from, to] form, image cut-out for foreground_wipe', () {
      final p = twoShots();
      run(p, {'op': 'transition', 'layers': ['a', 'b'], 'type': 'foreground_wipe', 'params': {'media': 'img', 'direction': 'right'}});
      final fg = p.main.layerById('tr_b_fg')!;
      expect(fg.mediaId, 'img');
      final pos = fg.prop(Props.position).keyframes;
      expect(pos.first.value[0], lessThan(0));
      expect(pos.last.value[0], greaterThan(1920));
      expect(p.main.layerById('b')!.masks.single.props['center']!.keyframes, isNotEmpty);
    });

    test('incoming stacking: reveal types put the incoming on top, peel types below', () {
      final p = twoShots();
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'ink_bleed'});
      expect(p.main.indexOf('b'), lessThan(p.main.indexOf('a')));
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'page_turn'});
      expect(p.main.indexOf('a'), lessThan(p.main.indexOf('b')));
    });

    test('push_through zooms the outgoing about the door and cuts a hole', () {
      final p = twoShots();
      run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'push_through', 'params': {'target': 'door'}});
      final a = p.main.layerById('a')!;
      final sc = a.prop(Props.scale).keyframes;
      expect(sc.last.value[0], greaterThan(400));
      final hole = a.masks.single;
      expect(hole.invert, isTrue);
      expect(hole.props['center']!.staticValue[0], closeTo(960, 2));
      expect(hole.props['center']!.staticValue[1], closeTo(600, 2));
      final door = p.main.layerById('door')!;
      expect(door.end, lessThanOrEqualTo(5 + 1 / 30 + 1e-6));
    });

    test('push_through into a layer inside the outgoing precomp', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'sky', 'color': '#406080'});
      run(p, {'op': 'add_layer', 'type': 'shape', 'id': 'win', 'kind': 'rect', 'width': 300, 'height': 200, 'position': [500, 300, 0], 'fill': '#000000'});
      run(p, {'op': 'precompose', 'layers': ['sky', 'win'], 'id': 'C1', 'layer_id': 'shotA'});
      run(p, {'op': 'update_layer', 'layer': 'shotA', 'duration': 5});
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'b', 'color': '#806040', 'start': 5, 'duration': 5});
      run(p, {'op': 'transition', 'from': 'shotA', 'to': 'b', 'type': 'push_through', 'params': {'target': 'win'}, 'sound': false});
      final hole = p.main.layerById('shotA')!.masks.single;
      expect(hole.props['center']!.staticValue[0], closeTo(500, 3));
      expect(hole.props['center']!.staticValue[1], closeTo(300, 3));
    });

    test('bw_to_colour adds a colour copy that ends with the bloom', () {
      final p = twoShots();
      final r = run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'bw_to_colour'});
      final copy = p.main.layerById('tr_b_colour')!;
      expect(r.createdIds, contains('tr_b_colour'));
      final b = p.main.layerById('b')!;
      expect(copy.end, closeTo(5 + 1.8, 1e-6));
      expect(p.main.indexOf(copy.id), lessThan(p.main.indexOf('b')));
      final mono = b.effects.firstWhere((e) => e.type == 'mono').params['amount']!;
      expect(mono.valueAt(5.5)[0], 100);
      expect(mono.valueAt(7.5)[0], 0);
    });

    test('bad input is a readable error and changes nothing', () {
      final p = twoShots();
      final snap = ProjectSnapshot.take(p);
      expect(() => run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'nope'}), throwsA(isA<CommandError>()));
      expect(() => run(p, {'op': 'transition', 'from': 'a', 'to': 'zz', 'type': 'whip_pan'}), throwsA(isA<CommandError>()));
      expect(() => run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'whip_pan', 'direction': 'sideways'}),
          throwsA(isA<CommandError>()));
      expect(() => run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'whip_pan', 'at': 12}), throwsA(isA<CommandError>()));
      expect(ProjectSnapshot.take(p), snap);
    });

    test('a short shot shrinks the window instead of failing', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'b', 'start': 1, 'duration': 0.4});
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'a', 'start': 0, 'duration': 1});
      final r = run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': 'map_drop', 'sound': false});
      expect(r.log.join(' '), contains('shortened'));
      expect(p.main.layerById('b')!.end, closeTo(1.4, 1e-6));
    });
  });

  group('render', () {
    testWidgets('every type paints at several moments without errors', (tester) async {
      for (final type in DocTransitions.types) {
        final p = twoShots();
        run(p, {'op': 'transition', 'from': 'a', 'to': 'b', 'type': type, 'params': paramsFor(type), 'sound': false});
        for (final draft in [false, true]) {
          for (final t in [4.6, 4.95, 5.0, 5.3]) {
            await tester.pumpWidget(Directionality(
              textDirection: TextDirection.ltr,
              child: FittedBox(child: CompositionCanvas(project: p, time: t, draft: draft)),
            ));
            expect(tester.takeException(), isNull, reason: '$type @$t draft=$draft');
          }
        }
      }
    });

    Future<List<int>> pixels(WidgetTester tester, Project p, double t, List<List<int>> at) async {
      final key = GlobalKey();
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: RepaintBoundary(key: key, child: CompositionCanvas(project: p, time: t))),
      ));
      expect(tester.takeException(), isNull);
      final out = <int>[];
      await tester.runAsync(() async {
        final ro = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final img = await ro.toImage();
        final bd = (await img.toByteData())!;
        for (final xy in at) {
          final i = (xy[1] * img.width + xy[0]) * 4;
          out.add((bd.getUint8(i + 3) << 24) | (bd.getUint8(i) << 16) | (bd.getUint8(i + 1) << 8) | bd.getUint8(i + 2));
        }
        img.dispose();
      });
      return out;
    }

    Project small(String effect, Map<String, dynamic> params) {
      final p = newProject(w: 200, h: 100);
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'red', 'color': '#FF0000', 'start': 0, 'duration': 5});
      run(p, {'op': 'add_effect', 'layer': 'red', 'effect': effect, 'id': 'e', 'params': params});
      return p;
    }

    testWidgets('page_curl uncovers the far side and keeps the near side', (tester) async {
      final p = small('page_curl', {'progress': 50, 'angle': 180});
      final px = await pixels(tester, p, 1, [[190, 50], [150, 50]]);
      expect(px[0] & 0xFFFFFF, lessThan(0x202020), reason: 'peeled part shows what is below');
      final q = small('page_curl', {'progress': 0, 'angle': 180});
      final px2 = await pixels(tester, q, 1, [[190, 50]]);
      expect(px2[0], 0xFFFF0000);
    });

    testWidgets('burn_edge burns a hole from its start point', (tester) async {
      final p = small('burn_edge', {'progress': 50, 'embers': 0});
      final px = await pixels(tester, p, 1, [[100, 50]]);
      expect((px[0] >> 16) & 0xFF, lessThan(60), reason: 'centre burnt through');
      final q = small('burn_edge', {'progress': 0});
      expect((await pixels(tester, q, 1, [[100, 50]]))[0], 0xFFFF0000);
    });
  });
}
