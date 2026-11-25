// V3-A: maps & geo documentary patterns.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/ai/command_spec.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/model/camera.dart';
import 'package:motionai/core/model/effects_catalog.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/components.dart';
import 'package:motionai/core/presets/world_map.dart';
import 'package:motionai/ui/preview/composition_canvas.dart';
import 'package:motionai/ui/preview/fx/map_texture.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

Project project() {
  final p = Project(id: 'p', name: 'Maps', main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: 10));
  p.media['plane'] = MediaAsset(id: 'plane', type: MediaType.image, path: '/plane.png', name: 'plane', width: 600, height: 300);
  p.media['heli'] = MediaAsset(id: 'heli', type: MediaType.image, path: '/heli.png', name: 'heli', width: 500, height: 500);
  p.media['snow'] = MediaAsset(id: 'snow', type: MediaType.image, path: '/snow.jpg', name: 'snow', width: 2400, height: 1600);
  p.media['valley'] = MediaAsset(id: 'valley', type: MediaType.image, path: '/valley.jpg', name: 'valley', width: 1920, height: 1080);
  return p;
}

CommandResult run(Project p, Map<String, dynamic> c) => EditCommands.runAtomic(p, c);

void evalAll(Project p, {double step = 0.25}) {
  for (double t = 0; t <= p.main.duration; t += step) {
    Evaluator.evaluate(p.main, t);
  }
}

/// Screen centre of a drawn layer at [t].
(double, double) centre(Composition comp, String id, double t) {
  final it = Evaluator.evaluate(comp, t).firstWhere((i) => i.layer.id == id);
  final c = it.project(it.layer.width / 2, it.layer.height / 2);
  return (c.x, c.y);
}

double alphaOf(int argb) => ((argb >> 24) & 0xFF) / 255;

void main() {
  setUpAll(() => WorldMap.load(File('assets/world_countries.json').readAsStringSync()));

  group('1. satellite map', () {
    test('satellite style: texture layer (map_texture), borders, dark teal ocean, dark land fallback underneath', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'map', 'id': 'm', 'style': 'satellite', 'countries': ['Chile', 'Argentina'], 'focus': 'Chile', 'start': 0, 'duration': 8});
      final comp = p.main;
      final sat = comp.requireLayer('m_sat');
      expect(sat.parentId, 'm_g');
      expect(sat.width, WorldMap.width);
      expect(sat.height, WorldMap.height);
      expect(sat.effects.single.type, 'map_texture');
      // The dark vector land stays under the texture (fallback when the asset is missing).
      final ids = [for (final l in comp.layers) l.id];
      expect(ids.indexOf('m_world'), greaterThan(ids.indexOf('m_sat')));
      expect(ids.indexOf('m_sat'), greaterThan(ids.indexOf('m_borders')));
      expect(comp.requireLayer('m_borders').shape!.fill, 0);
      expect(comp.requireLayer('m_ocean').color, 0xFF08171C);
      expect(comp.layerById('m_vig'), isNotNull);
      evalAll(p);
    });

    test('country fills are semi-transparent, borders thin on screen, labels heavy caps that pop when named', () {
      final p = project();
      run(p, {
        'op': 'add_component', 'type': 'map', 'id': 'm', 'style': 'satellite', 'focus': 'Argentina', 'zoom': false, 'start': 0, 'duration': 8,
        'countries': ['Argentina', {'code': 'CHL', 'fill': '#B0309A', 'at': 2.0}],
      });
      final comp = p.main;
      final s = comp.requireLayer('m_g').prop(Props.scale).valueAt(0)[0] / 100;
      final arg = comp.requireLayer('m_c0');
      expect(alphaOf(arg.shape!.fill), closeTo(0.62, 0.01));
      expect(arg.shape!.fill & 0xFFFFFF, 0xA83232); // first satellite palette colour
      expect(arg.shape!.strokeWidth * s, closeTo(1.6, 0.01)); // thin on screen
      expect(comp.requireLayer('m_c1').shape!.fill & 0xFFFFFF, 0xB0309A);
      expect(comp.requireLayer('m_c1').start, closeTo(2.0, 1e-9)); // named at 2 s
      final label = comp.requireLayer('m_c0_label');
      expect(label.text!.text, 'ARGENTINA');
      expect(label.text!.fontFamily, 'Poppins');
      expect(label.text!.fontWeight, 900);
      expect(label.text!.fontSize * s, closeTo(1080 * 0.06, 1)); // 6 % of frame height on screen
      final sc = label.prop(Props.scale);
      expect(sc.valueAt(label.start)[0], closeTo(120, 1e-6));
      expect(sc.valueAt(label.start + 0.25)[0], closeTo(100, 1e-6));
      // Non-focus country at 60 %.
      expect(comp.requireLayer('m_c1').prop(Props.opacity).valueAt(7)[0], closeTo(60, 1e-6));
      expect(arg.prop(Props.opacity).valueAt(7)[0], closeTo(100, 1e-6));
      evalAll(p);
    });

    test('label_rotate auto turns labels of thin countries along their long axis; typewriter + stagger', () {
      final p = project();
      run(p, {
        'op': 'add_component', 'type': 'map', 'id': 'm', 'style': 'satellite', 'start': 0, 'duration': 8,
        'countries': ['Chile', 'Brazil'], 'label_animator': 'typewriter', 'label_stagger': 0.8, 'label_size': 0.05, 'fill_opacity': 55,
      });
      final comp = p.main;
      final chile = comp.requireLayer('m_c0_label'), brazil = comp.requireLayer('m_c1_label');
      final rc = chile.prop(Props.rotation).valueAt(5)[2];
      expect(rc.abs(), greaterThan(60), reason: 'Chile is long and thin: label along its axis (got $rc)');
      expect(brazil.prop(Props.rotation).valueAt(5)[2], 0);
      expect(chile.text!.animator, 'typewriter');
      expect(comp.requireLayer('m_c1').start - comp.requireLayer('m_c0').start, closeTo(0.8, 1e-9));
      expect(alphaOf(comp.requireLayer('m_c0').shape!.fill), closeTo(0.55, 0.01));
      // label_rotate: 0 keeps labels flat.
      final q = project();
      run(q, {'op': 'add_component', 'type': 'map', 'id': 'm', 'style': 'satellite', 'countries': ['Chile'], 'label_rotate': 0});
      expect(q.main.requireLayer('m_c0_label').prop(Props.rotation).valueAt(1)[2], 0);
    });

    test('city tags: tiny white box with black caps, keeps its screen size while the map zooms', () {
      final p = project();
      run(p, {
        'op': 'add_component', 'type': 'map', 'id': 'm', 'style': 'satellite', 'focus': 'Chile', 'start': 0, 'duration': 8,
        'cities': [{'name': 'Santiago', 'lat': -33.45, 'lon': -70.66, 'at': 0.5}],
      });
      final comp = p.main;
      final box = comp.requireLayer('m_city0_box'), tag = comp.requireLayer('m_city0_tag');
      expect(box.shape!.fill, 0xFFFFFFFF);
      expect(tag.text!.color, 0xFF111111);
      expect(tag.text!.text, 'SANTIAGO');
      expect(box.start, closeTo(0.5, 1e-9));
      final g = comp.requireLayer('m_city0_g');
      expect(g.prop(Props.scale).isAnimated, isTrue); // counter-scaled against the zoom
      final w1 = Evaluator.evaluate(comp, 1.2).firstWhere((i) => i.layer.id == 'm_city0_box');
      final w2 = Evaluator.evaluate(comp, 7.5).firstWhere((i) => i.layer.id == 'm_city0_box');
      double width(RenderItem it) => (it.project(it.layer.width, 0).x - it.project(0, 0).x).abs();
      expect(width(w2), closeTo(width(w1), width(w1) * 0.05));
      // map_pin with tag_style box on the visible map.
      run(p, {'op': 'add_component', 'type': 'map_pin', 'id': 'pin', 'tag_style': 'box', 'lat': -23.65, 'lon': -70.4, 'label': 'Antofagasta', 'start': 1});
      expect(comp.requireLayer('pin_g').parentId, 'm_g');
      expect(comp.requireLayer('pin_tag').text!.text, 'ANTOFAGASTA');
      evalAll(p);
    });

    test('bounds frame a region; the classic map is unchanged without V3 keys; JSON round trip', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'map', 'id': 'm', 'style': 'satellite', 'bounds': [[-56, -80], [-17, -60]], 'zoom': false});
      final g = p.main.requireLayer('m_g');
      final s = g.prop(Props.scale).valueAt(0)[0] / 100;
      final c = WorldMap.project(-70, -36.5);
      final pos = g.prop(Props.position).valueAt(0);
      expect(pos[0] + s * c[0], closeTo(960, 2));
      expect(pos[1] + s * c[1], closeTo(540, 2));
      final back = Project.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.main.requireLayer('m_sat').effects.single.type, 'map_texture');
      final q = project();
      run(q, {'op': 'add_component', 'type': 'map', 'id': 'm', 'countries': ['India']});
      expect(q.main.layerById('m_sat'), isNull);
      expect(q.main.requireLayer('m_c0').shape!.fill, 0xFFC9A227);
    });

    test('map_texture effect + bundled Blue Marble asset', () {
      expect(EffectsCatalog.byType('map_texture'), isNotNull);
      final f = File('assets/maps/blue_marble_dark.jpg');
      expect(f.existsSync(), isTrue);
      final bytes = f.readAsBytesSync();
      expect(bytes.length, lessThan(1500 * 1024));
      expect(bytes[0], 0xFF);
      expect(bytes[1], 0xD8); // JPEG
      expect(File('pubspec.yaml').readAsStringSync(), contains(MapTexture.asset));
    });

    testWidgets('canvas draws a satellite map (with or without the texture loaded)', (tester) async {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'map', 'id': 'm', 'style': 'satellite', 'countries': ['Chile'], 'focus': 'Chile', 'start': 0, 'duration': 4});
      for (final draft in [false, true]) {
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: FittedBox(child: CompositionCanvas(project: p, time: 3, draft: draft))),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('2/6. routes', () {
    test('route_follow: white arrow draws A→B, map keeps the tip in frame, arrival fill + label, motion blur', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'route_follow', 'id': 'r', 'from': 'Uruguay', 'to': 'Chile', 'arrow_head': true, 'start': 0, 'duration': 6});
      final comp = p.main;
      expect(comp.motionBlur, isTrue);
      expect(comp.layerById('r_map_sat'), isNotNull); // satellite map by default
      final line = comp.requireLayer('r_line');
      expect(line.shape!.stroke, 0xFFFFFFFF);
      expect(line.shape!.arrowEnd, isTrue);
      expect(line.shape!.dash, isEmpty);
      final tr = line.prop(Props.trim);
      expect(tr.valueAt(0.1)[1], closeTo(0, 1e-6));
      expect(tr.valueAt(5.9)[1], closeTo(100, 1e-6));
      // Draw time ~2.2 s.
      final tEnd = tr.keyframes.last.time;
      expect(tEnd - tr.keyframes.first.time, closeTo(2.2, 0.05));
      // Destination fills on arrival.
      final land = comp.requireLayer('r_land');
      expect(land.name, 'Chile');
      expect(land.start, closeTo(tEnd, 1e-6));
      expect(comp.requireLayer('r_land_label').text!.text, 'CHILE');
      expect(comp.requireLayer('r_land_from').name, 'Uruguay');
      // The tip stays inside the frame.
      for (final t in [0.8, 1.5, 2.2]) {
        final (x, y) = centre(comp, 'r_tip', t);
        expect(x, inInclusiveRange(0, 1920), reason: 't=$t');
        expect(y, inInclusiveRange(0, 1080), reason: 't=$t');
      }
      evalAll(p);
    });

    test('route_follow: dashed, vehicle oriented along the path, trail fade, duration label at the midpoint', () {
      final p = project();
      run(p, {
        'op': 'route_follow', 'id': 'r', 'from': [-34.6, -58.4], 'to': [-33.45, -70.66], 'line_style': 'dashed', 'vehicle': 'plane',
        'trail_fade': true, 'label': '11 mins', 'start': 0, 'duration': 6,
      });
      final comp = p.main;
      final line = comp.requireLayer('r_line');
      expect(line.shape!.dash.length, 2);
      final av = comp.requireLayer('r_av');
      expect(av.path!.orient, isTrue);
      expect(comp.requireLayer('r_veh').parentId, 'r_av');
      // Trail: the tail follows the head.
      final mid = line.prop(Props.trim).valueAt(2.0);
      expect(mid[0], greaterThan(0));
      expect(mid[1], greaterThan(mid[0]));
      final lab = comp.requireLayer('r_label');
      expect(lab.text!.text, '11 MINS');
      expect(lab.effects.any((e) => e.type == 'reveal'), isTrue);
      final wipe = lab.effects.firstWhere((e) => e.type == 'reveal');
      expect(wipe.params['progress']!.valueAt(lab.start)[0], closeTo(0, 1e-6));
      expect(wipe.params['progress']!.valueAt(lab.start + 0.4)[0], closeTo(100, 1e-6));
      final rot = lab.prop(Props.rotation).valueAt(5)[2];
      expect(rot, inInclusiveRange(-90, 90));
      evalAll(p);
      expect(() => run(p, {'op': 'route_follow', 'vehicle': 'nope', 'from': 'Chile', 'to': 'Peru'}), throwsA(isA<CommandError>()));
    });

    test('map_route with a duration label along its tangent', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'map', 'id': 'm', 'style': 'satellite', 'focus': 'Chile', 'zoom': false});
      run(p, {'op': 'add_component', 'type': 'map_route', 'id': 'mr', 'map': 'm', 'from': [-33.4, -70.6], 'to': [-35.0, -70.0], 'label': '11 MINS', 'line_style': 'dashed'});
      final comp = p.main;
      expect(comp.requireLayer('mr_line').shape!.dash, isNotEmpty);
      expect(comp.requireLayer('mr_label').parentId, 'm_g');
      expect(comp.requireLayer('mr_label').text!.text, '11 MINS');
      evalAll(p);
    });
  });

  group('3. punch_in', () {
    test('2D camera punch: ×2.6 in 0.45 s ease-in, the point stays put, motion blur + whoosh', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'map', 'id': 'm', 'style': 'satellite', 'focus': 'Chile', 'zoom': false});
      run(p, {'op': 'camera_move', 'preset': 'punch_in', 'point': [1400, 300], 'start': 2});
      final comp = p.main;
      expect(comp.camera.mode, CameraMode.twoD);
      final z = comp.camera.prop(CamProps.zoom2d);
      expect(z.valueAt(2)[0], closeTo(100, 1e-6));
      expect(z.valueAt(2.45)[0], closeTo(260, 1e-6));
      expect(z.valueAt(2.2)[0], lessThan(180)); // ease-in: slow start, fast end
      for (final t in [2.0, 2.45]) {
        final v = Evaluator.camera2D(comp, t).transform3(Vector3(1400, 300, 0));
        expect(v.x, closeTo(1400, 0.5));
        expect(v.y, closeTo(300, 0.5));
      }
      expect(comp.motionBlur, isTrue);
      expect(comp.layers.any((l) => l.type == LayerType.audio && l.start <= 2.45), isTrue);
    });

    test('punch on a map group (layer mode) and the 3D-camera guard', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'map', 'id': 'm', 'style': 'satellite', 'focus': 'Chile', 'zoom': false});
      final g = p.main.requireLayer('m_g');
      final before = g.prop(Props.scale).valueAt(0)[0];
      run(p, {'op': 'camera_move', 'preset': 'punch_in', 'map': 'm', 'point': [900, 500], 'amount': 3, 'start': 1, 'sound': false});
      expect(g.prop(Props.scale).valueAt(1.45)[0], closeTo(before * 3, 1e-6));
      // A map point under (900, 500) stays at (900, 500).
      final s0 = before / 100, p0 = g.prop(Props.position).valueAt(1);
      final mx = (900 - p0[0]) / s0, my = (500 - p0[1]) / s0;
      final p1 = g.prop(Props.position).valueAt(1.45);
      expect(p1[0] + s0 * 3 * mx, closeTo(900, 0.01));
      expect(p1[1] + s0 * 3 * my, closeTo(500, 0.01));
      expect(p.main.camera.mode, CameraMode.off);
      run(p, {'op': 'set_camera_mode', 'mode': '3d'});
      expect(() => run(p, {'op': 'camera_move', 'preset': 'punch_in'}), throwsA(isA<CommandError>()));
    });
  });

  group('7. rings', () {
    test('status_ring: red dashed ring attached to a layer, spinning 4 s per turn', () {
      final p = project();
      run(p, {'op': 'add_layer', 'type': 'image', 'id': 'heli', 'media': 'heli', 'fit': 'none', 'position': [800, 400, 0], 'scale': [40, 40, 100], 'start': 0, 'duration': 8});
      run(p, {'op': 'status_ring', 'id': 'sr', 'attach': 'heli', 'start': 0, 'duration': 8});
      final comp = p.main;
      final ring = comp.requireLayer('sr_ring');
      expect(ring.shape!.dash.length, 2);
      expect(ring.shape!.stroke & 0xFFFFFF, 0xD0202A);
      expect(comp.requireLayer('sr_g').parentId, 'heli');
      final rot = ring.prop(Props.rotation);
      expect(rot.valueAt(4)[2], closeTo(360, 1e-6));
      // Screen size is the given size (the parent's 40 % is cancelled).
      final it = Evaluator.evaluate(comp, 2).firstWhere((i) => i.layer.id == 'sr_ring');
      final c = it.project(ring.width / 2, ring.height / 2);
      expect(c.x, closeTo(800, 1));
      expect(c.y, closeTo(400, 1));
      final wpx = (it.project(ring.width, ring.height / 2) - it.project(0, ring.height / 2)).length;
      expect(wpx, closeTo(1080 * 0.06 * 2, 2));
      expect(() => run(p, {'op': 'status_ring', 'attach': 'nope'}), throwsA(isA<CommandError>()));
    });

    test('signal_rings: flattened red rings repeating every 0.75 s; pulse_rings: 4 white rings 1.2 s', () {
      final p = project();
      run(p, {'op': 'signal_rings', 'id': 'sg', 'x': 700, 'y': 500, 'start': 0, 'duration': 3});
      final comp = p.main;
      final r0 = comp.requireLayer('sg_ring0');
      expect(r0.height / r0.width, closeTo(0.65, 0.01));
      expect(comp.layerById('sg_ring2'), isNotNull);
      expect(comp.layerById('sg_ring3'), isNull);
      final sc = r0.prop(Props.scale);
      expect(sc.valueAt(0.0)[0], closeTo(12, 1e-6));
      expect(sc.valueAt(0.75)[0], closeTo(12, 1e-6)); // restarted
      expect(sc.valueAt(0.7)[0], greaterThan(80));
      expect(comp.requireLayer('sg_ring1').prop(Props.opacity).valueAt(0.1)[0], 0); // waits for its phase
      run(p, {'op': 'pulse_rings', 'id': 'pr', 'x': 300, 'y': 300, 'start': 0, 'duration': 3});
      final pr = comp.requireLayer('pr_ring0');
      expect(pr.shape!.stroke, 0xFFFFFFFF);
      expect(pr.height, closeTo(pr.width, 1e-6));
      expect(comp.layerById('pr_ring3'), isNotNull);
      expect(pr.prop(Props.scale).valueAt(1.2)[0], closeTo(12, 1e-6));
      evalAll(p);
    });

    test('rings on a map place keep their screen size', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'map', 'id': 'm', 'style': 'satellite', 'focus': 'Chile'});
      run(p, {'op': 'signal_rings', 'id': 'sg', 'lat': -34.9, 'lon': -70.0, 'start': 0, 'duration': 6});
      expect(p.main.requireLayer('sg_g').parentId, 'm_g');
      expect(p.main.requireLayer('sg_g').prop(Props.scale).isAnimated, isTrue);
      evalAll(p);
    });
  });

  group('8. geo_label / path_text', () {
    test('geo_label: dot, hooked pointer drawing on, typed heavy caps', () {
      final p = project();
      run(p, {'op': 'geo_label', 'id': 'gl', 'text': 'crash site', 'at': [1100, 600], 'start': 1, 'duration': 5});
      final comp = p.main;
      expect(comp.requireLayer('gl_g').prop(Props.position).valueAt(1)[0], 1100);
      final ptr = comp.requireLayer('gl_pointer');
      expect(ptr.shape!.smooth, isTrue);
      expect(ptr.prop(Props.trim).valueAt(1.1)[1], closeTo(0, 1e-6));
      expect(ptr.prop(Props.trim).valueAt(1.6)[1], closeTo(100, 1e-6));
      final txt = comp.requireLayer('gl_text');
      expect(txt.text!.text, 'CRASH SITE');
      expect(txt.text!.animator, 'typewriter');
      expect(txt.start, greaterThan(1.3));
      // Text sits to the right of the hook, above the point.
      final (tx, ty) = centre(comp, 'gl_text', 4);
      expect(tx, greaterThan(1100));
      expect(ty, lessThan(600));
      run(p, {'op': 'geo_label', 'id': 'gl2', 'text': 'here', 'x': 400, 'y': 700, 'side': 'left', 'pointer': 'line'});
      expect(centre(comp, 'gl2_text', 3).$1, lessThan(400));
      evalAll(p);
    });

    test('path_text: letters typed along a path layer, rotated to its tangent', () {
      final p = project();
      run(p, {
        'op': 'add_layer', 'type': 'shape', 'id': 'route', 'points': [[200, 800], [900, 500], [1700, 450]], 'smooth': true,
        'stroke': '#FFFFFF', 'stroke_width': 4, 'dash': [12, 8], 'start': 0, 'duration': 6,
      });
      run(p, {'op': 'path_text', 'id': 'pt', 'text': 'Plan to go', 'path_layer': 'route', 'start': 0.5, 'duration': 5});
      final comp = p.main;
      final letters = [for (final l in comp.layers) if (l.id.startsWith('pt_ch')) l];
      expect(letters.length, 8); // spaces skipped
      final first = comp.requireLayer('pt_ch0'), last = comp.requireLayer('pt_ch7');
      expect(first.text!.text, 'P');
      expect(last.text!.text, 'O');
      expect(last.start, greaterThan(first.start)); // typed on
      // Rising first part of the path: negative (counter-clockwise) rotation.
      expect(first.prop(Props.rotation).valueAt(5)[2], lessThan(-5));
      final (x0, _) = centre(comp, 'pt_ch0', 5.4), (x1, _) = centre(comp, 'pt_ch7', 5.4);
      expect(x1, greaterThan(x0 + 200));
      expect(() => run(p, {'op': 'path_text', 'path_layer': 'pt_ch0'}), throwsA(isA<CommandError>()));
      run(p, {'op': 'path_text', 'id': 'pd'}); // defaults
      evalAll(p);
    });
  });

  group('4/5. terrain label, tilt, ghost word', () {
    test('terrain_label: letter-spaced along the Andes on a satellite map, reads bottom→top, peak glyphs', () {
      final p = project();
      run(p, {'op': 'terrain_label', 'id': 'tl', 'start': 0, 'duration': 6});
      final comp = p.main;
      expect(comp.layerById('tl_map_sat'), isNotNull);
      final a = comp.requireLayer('tl_l0'), s = comp.requireLayer('tl_l4');
      expect(a.text!.text, 'A');
      expect(s.text!.text, 'S');
      expect(a.parentId, 'tl_map_g');
      final rot = a.prop(Props.rotation).valueAt(3)[2];
      expect(rot, inInclusiveRange(-120, -55)); // vertical range: text goes up
      final (_, ya) = centre(comp, 'tl_l0', 3), (_, ys) = centre(comp, 'tl_l4', 3);
      expect(ya, greaterThan(ys)); // first letter lowest
      expect(comp.requireLayer('tl_peaks').shape!.rings.length, greaterThan(4));
      evalAll(p);
    });

    test('map_tilt: map moves into a 1.6× precomp, pitches back 38° with −10° roll; flat before', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'map', 'id': 'm', 'style': 'satellite', 'focus': 'Chile', 'countries': ['Chile'], 'zoom': false});
      final before = centre(p.main, 'm_ocean', 0.5);
      run(p, {'op': 'map_tilt', 'map': 'm', 'at': 2});
      final comp = p.main;
      expect(comp.layerById('m_g'), isNull);
      final cl = comp.requireLayer('m_tilted');
      expect(cl.is3D, isTrue);
      expect(cl.width, closeTo(1920 * 1.6, 1e-6));
      expect(cl.prop(Props.rotation).valueAt(1)[0], 0);
      expect(cl.prop(Props.rotation).valueAt(2.6)[0], closeTo(-38, 1e-6));
      expect(cl.prop(Props.rotation).valueAt(2.6)[2], closeTo(-10, 1e-6));
      final child = p.comps['m_tilt']!;
      expect(child.layerById('m_c0_label'), isNotNull);
      expect(comp.layerById('m_ocean'), isNotNull); // background stays flat
      expect(centre(comp, 'm_ocean', 0.5), before);
      // The comp layer covers the frame at the start (no edges), centred.
      final it = Evaluator.evaluate(comp, 1).firstWhere((i) => i.layer.id == 'm_tilted');
      final c0 = it.project(0, 0), c1 = it.project(cl.width, cl.height);
      expect(c0.x, closeTo(-0.3 * 1920, 1));
      expect(c1.y, closeTo(1.3 * 1080, 1));
      evalAll(p);
      // tilt as a map option.
      final q = project();
      run(q, {'op': 'add_component', 'type': 'map', 'id': 'm', 'style': 'satellite', 'focus': 'Peru', 'tilt': 35, 'tilt_at': 3});
      expect(q.main.requireLayer('m_tilted').prop(Props.rotation).valueAt(5)[0], closeTo(-35, 1e-6));
      expect(() => run(project(), {'op': 'map_tilt'}), throwsA(isA<CommandError>()));
    });

    test('map_watermark: giant country word, 60 % opacity, rotated to the country axis', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'map', 'id': 'm', 'style': 'satellite', 'focus': 'Chile', 'zoom': false});
      run(p, {'op': 'map_watermark', 'id': 'wm', 'code': 'CHL', 'start': 0, 'duration': 5});
      final comp = p.main;
      final w = comp.requireLayer('wm_word');
      expect(w.parentId, 'm_g');
      expect(w.text!.text, 'CHILE');
      expect(w.prop(Props.opacity).valueAt(4)[0], closeTo(60, 1e-6));
      expect(w.prop(Props.rotation).valueAt(4)[2].abs(), greaterThan(60));
      final s = comp.requireLayer('m_g').prop(Props.scale).valueAt(0)[0] / 100;
      expect(w.text!.fontSize * s, closeTo(1080 * 0.35, 1));
      run(project(), {'op': 'map_watermark', 'code': 'India'}); // makes its own map
      expect(() => run(project(), {'op': 'map_watermark', 'code': 'Atlantis'}), throwsA(isA<CommandError>()));
    });
  });

  group('9/10. scenes', () {
    test('search_sweep: snow ground, giant dark-red place word, vehicle on a path, wandering searchlight, typed label', () {
      final p = project();
      run(p, {'op': 'search_sweep', 'id': 'ss', 'place': 'Andes', 'label': 'search begins', 'vehicle': 'heli', 'ground': 'snow', 'start': 0});
      final comp = p.main;
      expect(comp.requireLayer('ss_g').duration, closeTo(4.5, 1e-9));
      expect(comp.requireLayer('ss_place').text!.color, 0xFF7A1420);
      expect(comp.requireLayer('ss_place').text!.text, 'ANDES');
      expect(comp.requireLayer('ss_veh').parentId, 'ss_heli');
      expect(comp.requireLayer('ss_heli').path!.orient, isTrue);
      final beam = comp.requireLayer('ss_beam');
      expect(beam.prop(Props.position).keyframes.length, greaterThan(10));
      expect(comp.requireLayer('ss_label').text!.animator, 'typewriter');
      expect(comp.layerById('ss_snow'), isNotNull);
      evalAll(p);
      run(p, {'op': 'search_sweep', 'id': 'ss2', 'start': 5, 'snow': false}); // vector helicopter
      expect(p.main.layerById('ss2_rotor'), isNotNull);
      expect(p.main.layerById('ss2_snow'), isNull);
      evalAll(p);
    });

    test('sketch_map: parchment + ink items + red block arrows + chrome compass; directions reveal photos and re-aim the needle', () {
      final p = project();
      run(p, {
        'op': 'sketch_map', 'id': 'sk', 'start': 0, 'duration': 8,
        'items': [
          {'icon': 'mountain', 'x': 0.3, 'y': 0.4, 'label': 'Andes', 'arrow': 'down'},
          {'icon': 'crash', 'x': 0.6, 'y': 0.6, 'label': 'Crash site'},
        ],
        'directions': [
          {'label': 'Chile', 'side': 'left', 'at': 2.5, 'reveal': 'valley'},
          {'label': 'Argentina', 'side': 'right', 'at': 5.0, 'reveal': 'snow'},
        ],
      });
      final comp = p.main;
      expect(comp.requireLayer('sk_icon0').prop(Props.trim).isAnimated, isTrue);
      expect(comp.requireLayer('sk_label0').text!.fontFamily, 'Special Elite');
      expect(comp.requireLayer('sk_arrow0').shape!.fill & 0xFFFFFF, 0xD0202A);
      expect(comp.requireLayer('sk_photo0').start, closeTo(2.5, 1e-9));
      expect(comp.requireLayer('sk_photo1').mediaId, 'snow');
      final needle = comp.requireLayer('sk_compass_needle').prop(Props.rotation);
      expect(needle.valueAt(3.6)[2], closeTo(-90, 1e-6)); // left
      expect(needle.valueAt(6.1)[2], closeTo(90, 1e-6)); // right
      final rim = comp.requireLayer('sk_compass_g').prop(Props.rotation);
      expect(rim.valueAt(0.3)[2], closeTo(-180, 1e-6));
      expect(rim.valueAt(1.2)[2], closeTo(0, 1e-6));
      // The parchment slides aside when the first photo is revealed.
      final g = comp.requireLayer('sk_g').prop(Props.position);
      expect(g.valueAt(3.5)[0], greaterThan(g.valueAt(2.0)[0]));
      evalAll(p);
    });
  });

  group('integration', () {
    test('every geo component builds with defaults; ops are documented', () {
      for (final t in ['map_watermark', 'geo_label', 'path_text', 'terrain_label', 'status_ring', 'signal_rings', 'pulse_rings', 'search_sweep', 'sketch_map']) {
        expect(Components.types, contains(t));
        final p = project();
        run(p, {'op': 'add_component', 'type': t});
        expect(p.main.layers, isNotEmpty, reason: t);
        evalAll(p, step: 0.5);
        expect(EditCommands.ops, contains(t));
        expect(commandSpec, contains(t), reason: t);
      }
      for (final w in ['satellite', 'punch_in', 'map_tilt', 'label_rotate', 'tag_style', 'line_style', 'trail_fade', 'land_highlight', 'label_at']) {
        expect(commandSpec, contains(w), reason: w);
      }
      final docs = File('docs/EDIT_COMMANDS.md').readAsStringSync();
      for (final w in ['satellite', 'punch_in', 'map_tilt', 'status_ring', 'signal_rings', 'pulse_rings', 'geo_label', 'path_text', 'terrain_label', 'map_watermark', 'search_sweep', 'sketch_map']) {
        expect(docs, contains(w), reason: w);
      }
    });

    test('one command = one undo step: a failing geo command changes nothing', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'map', 'id': 'm', 'style': 'satellite'});
      final snap = jsonEncode(p.toJson());
      expect(() => run(p, {'op': 'batch', 'commands': [
            {'op': 'signal_rings', 'id': 'ok', 'x': 100, 'y': 100},
            {'op': 'status_ring', 'attach': 'missing'},
          ]}), throwsA(isA<CommandError>()));
      expect(jsonEncode(p.toJson()), snap);
      final n = p.main.layers.length;
      run(p, {'op': 'route_follow', 'from': 'Chile', 'to': 'Argentina', 'map': 'm'});
      expect(p.main.layers.length, greaterThan(n));
    });

    test('route label angle helper reads left→right', () {
      // Indirect: a westward route still gets an upright label.
      final p = project();
      run(p, {'op': 'route_follow', 'id': 'r', 'from': 'Argentina', 'to': 'Chile', 'label': '2 DAYS', 'start': 0, 'duration': 5});
      final rot = p.main.requireLayer('r_label').prop(Props.rotation).valueAt(4)[2];
      expect(rot, greaterThanOrEqualTo(-90));
      expect(rot, lessThan(90));
      expect(math.cos(rot * math.pi / 180), greaterThanOrEqualTo(0));
    });
  });
}
