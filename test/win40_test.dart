// win-40: geo layers (GEOlayers-style live maps), AE one-node / two-node camera,
// lens presets, focus lock, blur level, working 3D views + view layouts, Deep Glow.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/ai/command_spec.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/geo/geo_projection.dart';
import 'package:motionai/core/geo/geo_spec.dart';
import 'package:motionai/core/geo/geo_styles.dart';
import 'package:motionai/core/model/camera.dart';
import 'package:motionai/core/model/effects_catalog.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/world_map.dart';
import 'package:motionai/ui/preview/composition_canvas.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

Project project() => Project(id: 'p', name: 'Geo', main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: 10));

CommandResult run(Project p, Map<String, dynamic> c) => EditCommands.runAtomic(p, c);

void main() {
  setUpAll(() => WorldMap.load(File('assets/world_countries.json').readAsStringSync()));

  group('projections', () {
    test('every projection puts the centre in the middle', () {
      for (final pr in GeoProjections.all) {
        final v = GeoView(pr, 1920, 1080, 78, 22, 3);
        final (x, y, vis) = v.project(78, 22);
        expect(vis, isTrue, reason: pr);
        expect(x, closeTo(960, 1e-6), reason: pr);
        expect(y, closeTo(540, 1e-6), reason: pr);
      }
    });

    test('east is right, north is up; the globe hides the far side', () {
      for (final pr in GeoProjections.all) {
        final v = GeoView(pr, 1920, 1080, 0, 0, 1);
        final (ex, _, _) = v.project(20, 0);
        final (_, ny, _) = v.project(0, 20);
        expect(ex, greaterThan(960), reason: pr);
        expect(ny, lessThan(540), reason: pr);
      }
      final g = GeoView('globe', 1000, 1000, 0, 0, 1);
      expect(g.project(170, 0).$3, isFalse);
      final (rx, ry, _) = g.project(170, 0); // pushed onto the rim
      expect(math.sqrt(math.pow(rx - 500, 2) + math.pow(ry - 500, 2)), closeTo(g.radius, 1e-6));
    });

    test('longitudes wrap round the date line', () {
      final v = GeoView('equirectangular', 1920, 1080, 170, 0, 4);
      final (x1, _, _) = v.project(-175, 0); // 15° east of the centre, across the date line
      expect(x1, closeTo(960 + 15 * v.k, 1e-6));
    });

    test('fitZoom frames India tighter than the world; great circles keep their ends', () {
      final india = [68.0, 6.0, 97.5, 35.5];
      for (final pr in GeoProjections.all) {
        expect(GeoView.fitZoom(pr, 1920, 1080, india), greaterThan(1.5), reason: pr);
      }
      final gc = GeoView.greatCircle([77.2, 28.6], [-0.1, 51.5], n: 20);
      expect(gc.length, 21);
      expect(gc.first[0], closeTo(77.2, 1e-6));
      expect(gc.last[1], closeTo(51.5, 1e-6));
      // Delhi → London bends north of the straight lat line (great circle).
      expect(gc[10][1], greaterThan((28.6 + 51.5) / 2));
    });
  });

  group('geo spec + add_geo', () {
    test('12 premium styles, aliases, unknown style is an error', () {
      expect(GeoStyles.all.length, greaterThanOrEqualTo(12));
      expect(GeoStyles.byId('paper').id, 'paper_vintage');
      expect(() => GeoStyles.byId('nope'), throwsFormatException);
      final p = project();
      expect(() => run(p, {'op': 'add_geo', 'style': 'nope'}), throwsA(isA<CommandError>()));
      expect(p.main.layers, isEmpty); // atomic
    });

    test('add_geo: focus fits the country, highlights + labels, reveal keys progress, JSON round trip', () {
      final p = project();
      final r = run(p, {
        'op': 'add_geo', 'id': 'map', 'style': 'satellite', 'projection': 'natural_earth', 'focus': 'India',
        'highlight': [{'code': 'India', 'extrude': 24, 'glow': 80}, 'Pakistan'],
        'routes': [{'points': [[77.2, 28.6], [-0.1, 51.5]], 'arc': 0.4, 'dashed': true}],
        'pins': [{'lon': 77.2, 'lat': 28.6, 'label': 'Delhi'}],
        'reveal': {'start': 1, 'duration': 3},
      });
      expect(r.createdIds, ['map']);
      final l = p.main.requireLayer('map');
      expect(l.type, LayerType.shape);
      final g = l.geo!;
      expect(g.projection, 'natural_earth');
      expect(g.highlights.map((h) => h.code), ['India', 'Pakistan']);
      expect(g.highlights.first.extrude, 24);
      expect(g.highlights.first.label, ''); // auto label = country name
      final c = l.prop(GeoProps.center).valueAt(0);
      expect(c[0], inInclusiveRange(75, 90));
      expect(c[1], inInclusiveRange(15, 30));
      expect(l.prop(GeoProps.zoom).valueAt(0)[0], greaterThan(2));
      final pr = l.prop(GeoProps.progress);
      expect(pr.valueAt(1)[0], 0);
      expect(pr.valueAt(4)[0], 100);
      final back = Layer.fromJson(jsonDecode(jsonEncode(l.toJson())) as Map<String, dynamic>);
      expect(back.geo!.signature, g.signature);
      expect(back.geo!.routes.first.dashed, isTrue);
    });

    test('unknown country is rejected; update_geo switches to a globe', () {
      final p = project();
      expect(() => run(p, {'op': 'add_geo', 'highlight': 'Atlantis'}), throwsA(isA<CommandError>()));
      run(p, {'op': 'add_geo', 'id': 'm'});
      run(p, {'op': 'update_geo', 'layer': 'm', 'projection': 'orthographic', 'style': 'neon', 'focus': 'Japan'});
      expect(p.main.requireLayer('m').geo!.projection, 'globe');
      expect(() => run(p, {'op': 'update_geo', 'layer': 'm', 'projection': 'cylinder'}), throwsA(isA<CommandError>()));
    });

    test('geo_fly: shortest way round, mid-flight pull back on long hops', () {
      final p = project();
      run(p, {'op': 'add_geo', 'id': 'm', 'center': [170, 0], 'zoom': 4});
      run(p, {'op': 'geo_fly', 'layer': 'm', 'to': [-170, 10], 'zoom': 4, 'start': 0, 'duration': 2});
      final c = p.main.requireLayer('m').prop(GeoProps.center);
      expect(c.valueAt(2)[0], closeTo(190, 1e-6)); // 170 → 190 (= −170), not back across 340°
      run(p, {'op': 'geo_fly', 'layer': 'm', 'from': 'India', 'to': 'Brazil', 'start': 3, 'duration': 3});
      final z = p.main.requireLayer('m').prop(GeoProps.zoom);
      final mid = z.valueAt(4.5)[0];
      expect(mid, lessThan(z.valueAt(3)[0]));
      expect(mid, lessThan(z.valueAt(6)[0]));
    });

    testWidgets('canvas draws every style and projection without errors', (tester) async {
      final p = project();
      run(p, {
        'op': 'add_geo', 'id': 'm', 'focus': 'India', 'highlight': [{'code': 'India', 'extrude': 20}], 'graticule': true,
        'routes': [{'points': [[77.2, 28.6], [100.5, 13.7], [126.9, 37.5]], 'arc': 0.3, 'from': 0, 'to': 1}],
        'pins': [{'lon': 77.2, 'lat': 28.6, 'label': 'Delhi', 'kind': 'pulse', 'at': 0}],
        'reveal': {'start': 0, 'duration': 2},
      });
      for (final st in GeoStyles.all) {
        for (final pr in GeoProjections.all) {
          run(p, {'op': 'update_geo', 'layer': 'm', 'style': st.id, 'projection': pr});
          await tester.pumpWidget(Directionality(
            textDirection: TextDirection.ltr,
            child: Center(child: FittedBox(child: CompositionCanvas(project: p, time: 1.2, draft: true))),
          ));
          expect(tester.takeException(), isNull, reason: '${st.id} / $pr');
        }
      }
    });
  });

  group('camera', () {
    test('lens presets convert to AE zoom; set_camera switches to one-node keeping the aim', () {
      expect(zoomForLens(1920, 50), closeTo(2666.67, 0.01));
      expect(lensForZoom(1920, zoomForLens(1920, 35)), closeTo(35, 1e-9));
      final p = project();
      run(p, {'op': 'set_camera_mode', 'mode': '3d'});
      final rig = p.main.camera;
      rig.props[CamProps.poi]!.staticValue = [1200, 540, 0];
      final before = Evaluator.camera3D(p.main, 0).forward;
      run(p, {'op': 'set_camera', 'type': 'one_node', 'lens_mm': 85});
      expect(rig.type, 'one_node');
      final after = Evaluator.camera3D(p.main, 0);
      expect(after.forward.dot(before), closeTo(1, 1e-6)); // same aim
      expect(after.zoom, closeTo(zoomForLens(1920, 85), 1e-6));
      expect(() => run(p, {'op': 'set_camera', 'type': 'three_node'}), throwsA(isA<CommandError>()));
    });

    test('focus lock keeps the POI sharp; blur level scales the aperture', () {
      final p = project();
      run(p, {'op': 'set_camera_mode', 'mode': '3d'});
      run(p, {'op': 'set_camera', 'focus_lock': true, 'aperture': 80, 'blur_level': 50});
      final cam = Evaluator.camera3D(p.main, 0);
      final rig = p.main.camera;
      final pos = rig.props[CamProps.position]!.valueAt(0), poi = rig.props[CamProps.poi]!.valueAt(0);
      final d = Vector3(poi[0] - pos[0], poi[1] - pos[1], poi[2] - pos[2]).length;
      expect(cam.focus, closeTo(d, 1e-6));
      expect(cam.aperture, closeTo(40, 1e-9));
      final back = CameraRig.fromJson(jsonDecode(jsonEncode(rig.toJson())) as Map<String, dynamic>);
      expect(back.focusLock, isTrue);
    });

    test('one-node orientation: + Y yaw turns right, + X pitch looks down', () {
      final r = Evaluator.oneNodeForward(0, 30);
      expect(r.x, greaterThan(0));
      final d = Evaluator.oneNodeForward(30, 0);
      expect(d.y, greaterThan(0));
    });
  });

  group('views', () {
    test('working views: Top looks down, Front matches the comp, custom views orbit', () {
      final p = project();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'card', 'width': 800, 'height': 450, 'start': 0, 'duration': 5});
      run(p, {'op': 'update_layer', 'layer': 'card', 'is3d': true});
      run(p, {'op': 'set_property', 'target': 'card', 'prop': 'position', 'value': [960, 540, 600]});
      run(p, {'op': 'set_property', 'target': 'card', 'prop': 'rotation', 'value': [25, 30, 0]}); // not edge-on in any view
      for (final k in ViewCam.kinds) {
        final v = ViewCam.build(p.main, 1, k);
        if (k == 'active') {
          expect(v, isNull);
          continue;
        }
        final items = Evaluator.evaluate(p.main, 1, view: v);
        expect(items.where((i) => i.layer.id == 'card'), isNotEmpty, reason: k);
      }
      final top = ViewCam.build(p.main, 1, 'top')!;
      expect(top.ortho, isTrue);
      final near = top.toScreen(Vector3(960, 540, 0)), far = top.toScreen(Vector3(960, 540, 600));
      expect(far.y, lessThan(near.y)); // deeper = higher on the Top view
      final front = ViewCam.build(p.main, 1, 'front')!;
      final a = front.toScreen(Vector3(0, 0, 0)), b = front.toScreen(Vector3(1920, 0, 0));
      expect(b.x, greaterThan(a.x));
    });

    test('2D layers are not drawn in working views (like After Effects)', () {
      final p = project();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'flat', 'start': 0, 'duration': 5});
      final v = ViewCam.build(p.main, 1, 'custom1');
      expect(Evaluator.evaluate(p.main, 1, view: v).where((i) => i.layer.id == 'flat'), isEmpty);
    });

    test('set_view_layout validates and round-trips', () {
      final p = project();
      run(p, {'op': 'set_view_layout', 'layout': '4', 'views': ['active', 'top', 'custom2', 'right'], 'custom': {'custom2': [10, 20, 2]}});
      expect(p.main.viewLayout, '4');
      expect(p.main.views[2], 'custom2');
      final back = Composition.fromJson(jsonDecode(jsonEncode(p.main.toJson())) as Map<String, dynamic>);
      expect(back.viewLayout, '4');
      expect(back.customViews['custom2'], [10, 20, 2]);
      expect(() => run(p, {'op': 'set_view_layout', 'layout': '3'}), throwsA(isA<CommandError>()));
      expect(() => run(p, {'op': 'set_view_layout', 'views': ['side']}), throwsA(isA<CommandError>()));
    });
  });

  test('deep_glow is an effect; ops + spec are documented', () {
    final p = project();
    run(p, {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'GLOW', 'start': 0, 'duration': 3});
    run(p, {'op': 'add_effect', 'layer': 't', 'effect': 'deep_glow', 'params': {'amount': 120, 'chromatic': 40, 'tint': '#FFB547'}});
    expect(p.main.requireLayer('t').effects.single.type, 'deep_glow');
    expect(EffectsCatalog.create('deep_glow', 'x').params.keys, containsAll(['threshold', 'spread', 'aspect', 'chromatic', 'tint']));
    for (final op in ['add_geo', 'update_geo', 'geo_fly', 'set_camera', 'set_view_layout']) {
      expect(EditCommands.ops, contains(op));
      expect(commandSpec, contains(op));
    }
  });

  testWidgets('deep_glow renders', (tester) async {
    final p = project();
    run(p, {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'GLOW', 'start': 0, 'duration': 3});
    run(p, {'op': 'add_effect', 'layer': 't', 'effect': 'deep_glow', 'params': {'chromatic': 50}});
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: FittedBox(child: CompositionCanvas(project: p, time: 1))),
    ));
    expect(tester.takeException(), isNull);
  });
}
