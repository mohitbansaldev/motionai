import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/model/camera.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/components.dart';
import 'package:motionai/core/presets/scene3d.dart';
import 'package:motionai/core/presets/world_map.dart';

Project project() {
  final p = Project(id: 'p', name: 'Scene', main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: 10));
  p.media['img'] = MediaAsset(id: 'img', type: MediaType.image, path: '/a.jpg', name: 'photo', width: 1200, height: 800);
  p.media['cut'] = MediaAsset(id: 'cut', type: MediaType.image, path: '/c.png', name: 'person', width: 600, height: 1200);
  p.media['face'] = MediaAsset(id: 'face', type: MediaType.image, path: '/f.png', name: 'face', width: 400, height: 500);
  return p;
}

CommandResult run(Project p, Map<String, dynamic> c) => EditCommands.runAtomic(p, c);

Map<String, dynamic> rect(String id, double w, double h, double x, double y, {String fill = '#888888', double st = 0, double du = 6, String? name}) => {
      'op': 'add_layer', 'type': 'shape', 'id': id, 'kind': 'rect', 'width': w, 'height': h, 'position': [x, y, 0],
      'fill': fill, 'start': st, 'duration': du, 'name': ?name,
    };

/// A flat village-like scene: sky, ground, houses, hero hut + door, grass, reeds.
Project village() {
  final p = project();
  run(p, {
    'op': 'batch',
    'commands': [
      rect('sky', 1920, 1080, 960, 540, fill: '#8EC3EE', name: 'Sky'),
      rect('ground', 2600, 300, 960, 990, fill: '#7A9A45'),
      rect('cloud', 200, 90, 500, 160, fill: '#FFFFFF'),
      rect('house0', 300, 260, 300, 640),
      rect('house1', 260, 220, 1500, 620),
      rect('hero', 540, 390, 1040, 650, fill: '#B98B62'),
      rect('door', 108, 194, 1040, 745, fill: '#2A1A10'),
      rect('grass', 2500, 150, 960, 1000, fill: '#4E7F2C'),
      rect('plant', 190, 970, 1770, 840, fill: '#26401A', name: 'Reeds'),
    ],
  });
  return p;
}

Map<String, List<List<double>>> corners(Composition comp, double t) => {
      for (final it in Evaluator.evaluate(comp, t)) it.layer.id: [for (final c in it.corners()) [c.x, c.y]],
    };

void expectSameFrame(Map<String, List<List<double>>> a, Map<String, List<List<double>>> b, {double tol = 1.0}) {
  expect(b.keys.toSet(), a.keys.toSet());
  for (final id in a.keys) {
    for (int i = 0; i < 4; i++) {
      expect(b[id]![i][0], closeTo(a[id]![i][0], tol), reason: '$id corner $i x');
      expect(b[id]![i][1], closeTo(a[id]![i][1], tol), reason: '$id corner $i y');
    }
  }
}

void main() {
  setUpAll(() => WorldMap.load(File('assets/world_countries.json').readAsStringSync()));

  group('make_3d', () {
    test('first frame is identical for many layer types, incl. parented and components', () {
      final p = village();
      run(p, {
        'op': 'batch',
        'commands': [
          {'op': 'add_layer', 'type': 'image', 'media': 'img', 'id': 'photo', 'start': 0, 'duration': 6, 'fit': 'none', 'position': [600, 300, 0], 'scale': [30, 30, 100]},
          {'op': 'set_property', 'target': 'photo', 'prop': 'rotation', 'value': [0, 0, 12]},
          {'op': 'add_layer', 'type': 'text', 'id': 'title', 'text': 'THE VILLAGE', 'start': 0, 'duration': 6, 'position': [960, 200, 0]},
          {'op': 'add_layer', 'type': 'null', 'id': 'grp', 'start': 0, 'duration': 6, 'position': [1300, 400, 0], 'scale': [80, 80, 100]},
          {'op': 'set_property', 'target': 'grp', 'prop': 'rotation', 'value': [0, 0, -8]},
          {...rect('card', 300, 160, 0, 0, fill: '#FFFFFF'), 'parent': 'grp'},
          {...rect('chip', 80, 40, 60, -40, fill: '#E53935'), 'parent': 'card'},
          {'op': 'add_component', 'type': 'name_tag', 'id': 'nt', 'start': 0, 'duration': 6, 'name': 'Ravi', 'role': 'Farmer'},
          {'op': 'set_keyframe', 'target': 'photo', 'prop': 'position', 'time': 0, 'value': [600, 300, 0]},
          {'op': 'set_keyframe', 'target': 'photo', 'prop': 'position', 'time': 4, 'value': [700, 340, 0]},
        ],
      });
      final comp = p.main;
      const t = 1.5; // after the name tag's pop-in
      final before = corners(comp, t);
      final r = run(p, {'op': 'make_3d', 'start': t});
      expect(comp.camera.mode, CameraMode.threeD);
      final after = corners(comp, t);
      expectSameFrame(before, after);
      for (final l in comp.layers.where(Scene3D.isVisual)) {
        expect(l.is3D, isTrue, reason: l.id);
      }
      // Bands were guessed.
      expect(Scene3D.bandOf(comp, comp.requireLayer('sky'), t), 'sky');
      expect(Scene3D.bandOf(comp, comp.requireLayer('grass'), t), 'near');
      expect(Scene3D.bandOf(comp, comp.requireLayer('plant'), t), 'front');
      expect(Scene3D.bandOf(comp, comp.requireLayer('cloud'), t), 'far');
      expect(Scene3D.bandOf(comp, comp.requireLayer('hero'), t), 'mid');
      expect(r.log, isNotEmpty);
      // Layers really are at different depths now.
      final depths = {for (final it in Evaluator.evaluate(comp, t)) it.layer.id: it.depth};
      expect(depths['sky']!, greaterThan(depths['hero']! * 2));
      expect(depths['plant']!, lessThan(depths['hero']!));
      // Children stay on top of their parent's plane.
      expect(depths['chip']!, lessThan(depths['card']!));
    });

    test('explicit bands, a subset of layers and a parented child moves its group root', () {
      final p = village();
      run(p, {
        'op': 'batch',
        'commands': [
          {'op': 'add_layer', 'type': 'null', 'id': 'g', 'start': 0, 'duration': 6, 'position': [400, 500, 0]},
          {...rect('kid', 120, 120, 30, 20), 'parent': 'g'},
        ],
      });
      final comp = p.main;
      final before = corners(comp, 0);
      run(p, {
        'op': 'make_3d',
        'layers': ['sky', 'hero', 'kid'],
        'bands': {'hero': 'near', 'kid': 'far'},
        'start': 0,
      });
      expectSameFrame(before, corners(comp, 0));
      expect(comp.requireLayer('g').is3D, isTrue);
      expect(comp.requireLayer('ground').is3D, isFalse);
      expect(Scene3D.bandOf(comp, comp.requireLayer('hero'), 0), 'near');
      expect(Scene3D.bandOf(comp, comp.requireLayer('kid'), 0), 'far');
      expect(() => run(p, {'op': 'make_3d', 'bands': {'hero': 'ceiling'}}), throwsA(isA<CommandError>()));
      expect(() => run(p, {'op': 'make_3d', 'layers': ['nope']}), throwsA(isA<CommandError>()));
    });

    test('a later make_3d cuts the camera back home', () {
      final p = village();
      run(p, {'op': 'make_3d', 'start': 0});
      run(p, {'op': 'camera_shot', 'move': 'fly_to', 'target': 'hero', 'start': 0, 'duration': 2});
      run(p, {...rect('late', 400, 300, 960, 540), 'start': 3, 'duration': 2});
      final before = corners(p.main, 3);
      run(p, {'op': 'make_3d', 'layers': ['late'], 'start': 3});
      final after = corners(p.main, 3);
      expect(after['late']![0][0], closeTo(before['late']![0][0], 1));
      expect(after['late']![2][1], closeTo(before['late']![2][1], 1));
    });
  });

  group('camera_shot', () {
    for (final move in Scene3D.moves) {
      for (final intensity in [0.5, 1.0]) {
        test('$move (intensity $intensity) writes keyframes and keeps clear of every layer', () {
          final p = village();
          run(p, {'op': 'make_3d', 'start': 0});
          run(p, {'op': 'camera_shot', 'move': move, 'target': 'door', 'start': 1, 'duration': 2, 'intensity': intensity});
          final rig = p.main.camera;
          final pos = rig.prop(CamProps.position), poi = rig.prop(CamProps.poi);
          expect(pos.keyframes.length, greaterThanOrEqualTo(2));
          expect(poi.keyframes, isNotEmpty);
          expect(rig.prop(CamProps.zoom).keyframes, isNotEmpty);
          expect(pos.keyframes.last.time, closeTo(3, 1e-6));
          // The camera actually moves.
          final a = pos.valueAt(1), b = pos.valueAt(3);
          final moved = math.sqrt(math.pow(a[0] - b[0], 2) + math.pow(a[1] - b[1], 2) + math.pow(a[2] - b[2], 2));
          expect(moved, greaterThan(1), reason: 'camera moved');
          for (double t = 1; t <= 3 + 1e-9; t += 0.05) {
            expect(Scene3D.nearestLayerDistance(p.main, t), greaterThanOrEqualTo(Scene3D.minClearance - 1e-6), reason: 't=$t');
          }
          // Every frame still evaluates.
          for (double t = 0; t < 4; t += 0.25) {
            Evaluator.evaluate(p.main, t);
          }
        });
      }
    }

    test('orbit stays within ±25°', () {
      final p = village();
      run(p, {'op': 'make_3d', 'start': 0});
      run(p, {'op': 'camera_shot', 'move': 'orbit', 'target': 'hero', 'start': 0, 'duration': 3, 'intensity': 1});
      final rig = p.main.camera;
      final q = rig.prop(CamProps.poi).valueAt(3);
      for (double t = 0; t <= 3; t += 0.1) {
        final c = rig.prop(CamProps.position).valueAt(t);
        final ang = math.atan2(c[0] - q[0], q[2] - c[2]).abs() * 180 / math.pi;
        expect(ang, lessThanOrEqualTo(25.5), reason: 't=$t');
      }
    });

    test('a tapped point aims the move; drift without a target works', () {
      final p = village();
      run(p, {'op': 'make_3d', 'start': 0});
      run(p, {'op': 'camera_shot', 'move': 'fly_to', 'point': [300, 640], 'start': 0, 'duration': 2});
      final poi = p.main.camera.prop(CamProps.poi).valueAt(2);
      final house = Scene3D.worldBox(p.main, p.main.requireLayer('house0'), 0)!.center;
      expect(poi[0], closeTo(house.x, 80));
      run(p, {'op': 'camera_shot', 'move': 'drift', 'start': 2, 'duration': 2});
      expect(p.main.camera.prop(CamProps.position).keyframes.last.time, closeTo(4, 1e-6));
      expect(() => run(p, {'op': 'camera_shot', 'move': 'teleport'}), throwsA(isA<CommandError>()));
    });

    test('backgrounds grow so the move shows no empty edges', () {
      final p = village();
      run(p, {'op': 'make_3d', 'start': 0});
      run(p, {'op': 'camera_shot', 'move': 'pass_by', 'target': 'hero', 'start': 0, 'duration': 2, 'intensity': 1});
      final sky = p.main.requireLayer('sky');
      for (double t = 0; t <= 2; t += 0.25) {
        expect(Scene3D.coverScale(p.main, sky, math.min(t, 2 - 1e-4)), lessThanOrEqualTo(1.0 + 1e-3), reason: 't=$t');
      }
    });

    test('push_through cuts to the next shot behind a white flash, motion blur on', () {
      final p = village();
      run(p, {'op': 'make_3d', 'start': 0});
      run(p, {...rect('interior', 1920, 1080, 960, 540, fill: '#4A2E1A'), 'start': 1.8, 'duration': 1.5});
      final r = run(p, {'op': 'camera_shot', 'move': 'push_through', 'target': 'door', 'start': 1, 'duration': 1, 'cut_to': 'interior'});
      final comp = p.main;
      expect(comp.motionBlur, isTrue);
      for (final id in ['sky', 'hero', 'door', 'plant', 'cloud']) {
        expect(comp.requireLayer(id).end, closeTo(2, 1e-6), reason: id);
      }
      final interior = comp.requireLayer('interior');
      expect(interior.start, closeTo(2, 1e-6));
      expect(interior.is3D, isFalse);
      final flash = comp.requireLayer(r.createdIds.single);
      expect(comp.layers.first.id, flash.id);
      expect(flash.prop(Props.opacity).scalarAt(2), closeTo(100, 1e-6));
      expect(flash.prop(Props.opacity).scalarAt(2.4), closeTo(0, 1e-6));
      // After the cut only the interior (and the fading flash) is drawn.
      final ids = Evaluator.evaluate(comp, 2.5).map((i) => i.layer.id).toSet();
      expect(ids, {'interior'});
      // The camera ends close to the door but never inside it.
      expect(Scene3D.nearestLayerDistance(comp, 1.99), greaterThanOrEqualTo(Scene3D.minClearance));
      expect(() => run(p, {'op': 'camera_shot', 'move': 'push_through', 'cut_to': 'nope'}), throwsA(isA<CommandError>()));
    });

    test('reveal starts behind the nearest front layer, pull_back starts close', () {
      final p = village();
      run(p, {'op': 'make_3d', 'start': 0});
      final r = run(p, {'op': 'camera_shot', 'move': 'reveal', 'target': 'hero', 'start': 0, 'duration': 2});
      expect(r.log.any((l) => l.contains('Reeds')), isTrue);
      final start = p.main.camera.prop(CamProps.position).valueAt(0);
      final reeds = Scene3D.worldBox(p.main, p.main.requireLayer('plant'), 0)!.center;
      expect(start[0], closeTo(reeds.x, 1));
      final p2 = village();
      run(p2, {'op': 'make_3d', 'start': 0});
      run(p2, {'op': 'camera_shot', 'move': 'pull_back', 'target': 'door', 'start': 0, 'duration': 2});
      final door = Scene3D.worldBox(p2.main, p2.main.requireLayer('door'), 0)!.center;
      final c0 = p2.main.camera.prop(CamProps.position).valueAt(0);
      expect(door.z - c0[2], lessThan(500));
      expect(door.z - c0[2], greaterThanOrEqualTo(Scene3D.minClearance));
    });
  });

  group('scene components', () {
    void evalAll(Project p) {
      for (double t = 0; t < p.main.duration; t += 0.4) {
        Evaluator.evaluate(p.main, t);
      }
    }

    test('map_fly over a new map and over an existing one', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'map_fly', 'id': 'fly', 'start': 0, 'duration': 6, 'from': 'India', 'to': 'France', 'style': 'paper'});
      final g = p.main.requireLayer('fly_map_g');
      expect(g.prop(Props.position).keyframes.length, greaterThan(5));
      expect(g.prop(Props.scale).keyframes.length, greaterThan(5));
      expect(p.main.layers.where((l) => l.name == 'India' || l.name == 'France'), hasLength(2));
      // Mid-flight it is zoomed out compared to the ends.
      final s0 = g.prop(Props.scale).valueAt(0.4)[0], sm = g.prop(Props.scale).valueAt(3)[0], s1 = g.prop(Props.scale).valueAt(5.9)[0];
      expect(sm, lessThan(math.max(s0, s1)));
      evalAll(p);

      final q = project();
      run(q, {'op': 'add_component', 'type': 'map', 'id': 'm', 'start': 0, 'duration': 6, 'countries': ['India', 'France'], 'zoom': false});
      final n = q.main.layers.length;
      run(q, {'op': 'add_component', 'type': 'map_fly', 'id': 'f', 'map': 'm', 'start': 0, 'duration': 6, 'from': 'India', 'to': 'France'});
      expect(q.main.layers.length, n, reason: 'highlights already on the map are reused');
      expect(q.main.requireLayer('m_g').prop(Props.position).isAnimated, isTrue);
      expect(() => run(q, {'op': 'add_component', 'type': 'map_fly', 'map': 'nomap'}), throwsA(isA<CommandError>()));
      expect(() => run(q, {'op': 'add_component', 'type': 'map_fly', 'from': 'Atlantis'}), throwsA(isA<CommandError>()));
    });

    test('route_follow: line draws, map follows the tip, avatar travels, motion blur on', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'route_follow', 'id': 'r', 'start': 0, 'duration': 6, 'from': 'India', 'to': 'France', 'avatar': 'face'});
      final comp = p.main;
      expect(comp.motionBlur, isTrue);
      final line = comp.requireLayer('r_line');
      expect(line.prop(Props.trim).valueAt(0)[1], closeTo(0, 1e-6));
      expect(line.prop(Props.trim).valueAt(6)[1], closeTo(100, 1e-6));
      final av = comp.requireLayer('r_av');
      expect(av.path, isNotNull);
      expect(av.prop(Props.pathProgress).valueAt(6)[0], closeTo(100, 1e-6));
      // The traveller stays near the frame centre while the map moves under it.
      for (final t in [1.0, 2.5, 4.0]) {
        final item = Evaluator.evaluate(comp, t).firstWhere((i) => i.layer.id == 'r_ring');
        final c = item.project(item.layer.width / 2, item.layer.height / 2);
        expect((c.x - 960).abs(), lessThan(400), reason: 't=$t');
        expect((c.y - 540).abs(), lessThan(400), reason: 't=$t');
      }
      expect(comp.layerById('r_clouds'), isNotNull); // road map with clouds by default
      expect(comp.requireLayer('r_map_ocean').color, 0xFFA8D4E6);
      evalAll(p);
      // Defaults work too (and [lat, lon] places).
      final q = project();
      run(q, {'op': 'add_component', 'type': 'route_follow'});
      run(q, {'op': 'add_component', 'type': 'route_follow', 'from': [28.6, 77.2], 'to': [48.8, 2.3], 'start': 1});
      evalAll(q);
    });

    test('needle_pin and avatar_pin drop onto a new or existing map and keep their screen size', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'needle_pin', 'id': 'np', 'start': 0, 'duration': 5, 'country': 'Japan', 'label': 'Tokyo'});
      final comp = p.main;
      expect(comp.layerById('np_map_world'), isNotNull);
      final g = comp.requireLayer('np_g');
      expect(g.parentId, 'np_map_g');
      final map = comp.requireLayer('np_map_g');
      for (final t in [0.0, 1.0, 2.5, 4.0]) {
        final s = map.prop(Props.scale).valueAt(t)[0] * g.prop(Props.scale).valueAt(t)[0] / 100;
        expect(s, closeTo(100, 6), reason: 't=$t: pin keeps its size on screen');
      }
      // Drops in: above the point before landing, on it after.
      final drop = comp.requireLayer('np_drop');
      expect(drop.prop(Props.position).valueAt(drop.start)[1], lessThan(-100));
      expect(drop.prop(Props.position).valueAt(4)[1], closeTo(0, 1e-6));
      evalAll(p);

      run(p, {'op': 'add_component', 'type': 'avatar_pin', 'id': 'ap', 'start': 0.5, 'duration': 4, 'country': 'India', 'media': 'face', 'label': 'Ravi'});
      expect(comp.requireLayer('ap_g').parentId, 'np_map_g', reason: 'uses the map that is already there');
      expect(comp.requireLayer('ap_face').masks, isNotEmpty);
      run(p, {'op': 'add_component', 'type': 'needle_pin', 'id': 'np2', 'map': 'np_map', 'lat': 48.85, 'lon': 2.35, 'color': '#1E88E5'});
      expect(comp.requireLayer('np2_g').parentId, 'np_map_g');
      run(p, {'op': 'add_component', 'type': 'avatar_pin', 'id': 'ap2'}); // defaults: no face → initial disc
      evalAll(p);
    });

    test('map component: road style and clouds', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'map', 'id': 'm', 'style': 'road', 'clouds': true, 'countries': ['India']});
      expect(p.main.requireLayer('m_ocean').color, 0xFFA8D4E6);
      expect(p.main.requireLayer('m_roads').shape!.rings, isNotEmpty);
      final clouds = p.main.requireLayer('m_clouds');
      expect(clouds.effects.single.type, 'particles');
      expect(p.main.indexOf('m_clouds'), 0, reason: 'clouds drift over the map');
      evalAll(p);
    });

    test('room builds 3D planes; board pops its picture out', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'room', 'id': 'rm', 'floor': 'img', 'items': ['cut'], 'color': '#7A5C44'});
      final comp = p.main;
      expect(comp.camera.mode, CameraMode.threeD);
      for (final part in ['back', 'floor', 'left', 'right', 'item0']) {
        expect(comp.requireLayer('rm_$part').is3D, isTrue, reason: part);
      }
      expect(comp.requireLayer('rm_floor').mediaId, 'img');
      expect(comp.requireLayer('rm_floor').prop(Props.rotation).staticValue[0], -90);
      final drawn = Evaluator.evaluate(comp, 1).map((i) => i.layer.id).toSet();
      expect(drawn, containsAll(['rm_back', 'rm_floor', 'rm_left', 'rm_right', 'rm_item0']));
      // Room + camera move: the camera keeps clear of the walls.
      run(p, {'op': 'camera_shot', 'move': 'push_through', 'target': 'rm_item0', 'start': 0, 'duration': 2});
      for (double t = 0; t <= 2; t += 0.1) {
        expect(Scene3D.nearestLayerDistance(comp, t), greaterThanOrEqualTo(Scene3D.minClearance - 1e-6));
      }

      run(p, {'op': 'add_component', 'type': 'board', 'id': 'bd', 'media': 'img', 'curve': 40, 'frame': 'glass', 'pop': true, 'start': 0, 'duration': 4});
      final pic = comp.requireLayer('bd_pic');
      expect(pic.effects.any((e) => e.type == 'curve'), isTrue);
      expect(comp.requireLayer('bd_panel').effects.any((e) => e.type == 'glass_frame'), isTrue);
      expect(pic.prop(Props.scale).valueAt(3)[0], greaterThan(pic.prop(Props.scale).valueAt(0)[0] * 1.1));
      final curve = pic.effects.firstWhere((e) => e.type == 'curve');
      expect(curve.params['bend']!.valueAt(3)[0], closeTo(0, 1e-6));
      run(p, {'op': 'add_component', 'type': 'board'}); // defaults: wood, no picture
      for (double t = 0; t < 5; t += 0.4) {
        Evaluator.evaluate(comp, t);
      }
    });

    test('every scene component builds with defaults', () {
      for (final t in ['room', 'board', 'needle_pin', 'avatar_pin', 'map_fly', 'route_follow']) {
        expect(Components.types, contains(t));
        final p = project();
        run(p, {'op': 'add_component', 'type': t});
        expect(p.main.layers, isNotEmpty, reason: t);
      }
    });
  });

  group('shots and recipes', () {
    test('save_shot / load_shot round trip through project JSON', () {
      final p = village();
      run(p, {'op': 'make_3d', 'start': 0});
      run(p, {'op': 'camera_shot', 'move': 'fly_to', 'target': 'hero', 'start': 0, 'duration': 2});
      run(p, {'op': 'save_shot', 'name': 'Hut approach'});
      final back = Project.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.shots.keys, ['Hut approach']);
      final want = p.main.camera.prop(CamProps.position).valueAt(1.3);
      // Load into a fresh copy of the flat scene at t = 5.
      final q = village();
      q.shots.addAll(back.shots);
      final r = run(q, {'op': 'load_shot', 'name': 'Hut approach', 'start': 5});
      expect(r.log, isEmpty, reason: 'every saved layer exists in the copy');
      expect(q.main.camera.mode, CameraMode.threeD);
      final got = q.main.camera.prop(CamProps.position).valueAt(6.3);
      for (int i = 0; i < 3; i++) {
        expect(got[i], closeTo(want[i], 1e-6));
      }
      expect(q.main.requireLayer('sky').is3D, isTrue);
      expect(q.main.requireLayer('sky').prop(Props.position).valueAt(5)[2], closeTo(p.main.requireLayer('sky').prop(Props.position).valueAt(0)[2], 1e-6));
      expect(() => run(q, {'op': 'load_shot', 'name': 'nope'}), throwsA(isA<CommandError>()));
    });

    test('recipes: save from a layer, apply to another, delete; JSON + undo safe', () {
      final p = project();
      run(p, {
        'op': 'batch',
        'commands': [
          {'op': 'add_layer', 'type': 'image', 'media': 'img', 'id': 'a', 'start': 1, 'duration': 4},
          {'op': 'animate_in', 'layer': 'a', 'preset': 'zoom_in', 'duration': 0.5},
          {'op': 'set_keyframe', 'target': 'a', 'prop': 'position', 'time': 1, 'value': [960, 540, 0]},
          {'op': 'set_keyframe', 'target': 'a', 'prop': 'position', 'time': 4, 'value': [1060, 500, 0]},
          {'op': 'add_effect', 'layer': 'a', 'effect': 'vignette', 'params': {'amount': 80}},
          {'op': 'add_effect', 'layer': 'a', 'effect': 'particles', 'params': {'kind': 'dust', 'amount': 30}},
          {'op': 'add_layer', 'type': 'image', 'media': 'cut', 'id': 'b', 'start': 6, 'duration': 3, 'position': [500, 500, 0]},
        ],
      });
      run(p, {'op': 'save_recipe', 'name': 'Dreamy push', 'layer': 'a'});
      expect(p.recipes.keys, ['Dreamy push']);
      // Survives save/load.
      final back = Project.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.recipes['Dreamy push'], p.recipes['Dreamy push']);
      // The panel reads names from the project JSON.
      expect((jsonDecode(ProjectSnapshot.take(p)) as Map)['recipes'], isA<Map>());

      run(p, {'op': 'apply_recipe', 'name': 'Dreamy push', 'layer': 'b', 'start': 6});
      final b = p.main.requireLayer('b');
      final pos = b.prop(Props.position);
      expect(pos.valueAt(6)[0], closeTo(500, 1e-6));
      expect(pos.valueAt(9)[0], closeTo(600, 1e-6)); // same +100 px move, relative
      expect(b.prop(Props.opacity).valueAt(6)[0], closeTo(0, 1e-6)); // the transition came along
      expect(b.effects.map((e) => e.type).toSet(), {'vignette', 'particles'});
      run(p, {'op': 'apply_recipe', 'name': 'Dreamy push', 'layer': 'b', 'start': 6});
      expect(b.effects.length, 2, reason: 'applying twice replaces, does not stack');

      // A failing batch leaves recipes as they were.
      expect(
        () => run(p, {
          'op': 'batch',
          'commands': [
            {'op': 'delete_recipe', 'name': 'Dreamy push'},
            {'op': 'remove_layer', 'layer': 'nope'},
          ],
        }),
        throwsA(isA<CommandError>()),
      );
      expect(p.recipes.keys, ['Dreamy push']);
      run(p, {'op': 'delete_recipe', 'name': 'Dreamy push'});
      expect(p.recipes, isEmpty);
      expect(() => run(p, {'op': 'apply_recipe', 'name': 'Dreamy push', 'layer': 'b'}), throwsA(isA<CommandError>()));
      for (final op in ['make_3d', 'camera_shot', 'save_shot', 'load_shot', 'save_recipe', 'apply_recipe', 'delete_recipe']) {
        expect(EditCommands.ops, contains(op));
      }
    });
  });
}
