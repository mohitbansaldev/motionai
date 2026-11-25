// V3-B: evidence kit — articles, books, cards, notes (PATTERN_LIBRARY_SPEC P-B 11–20, 55–60).
import 'dart:typed_data';

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/ai/command_spec.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/components.dart';
import 'package:motionai/ui/preview/composition_canvas.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

const double kW = 1920, kH = 1080;

const v3Types = [
  'circle_mark', 'inset_circle', 'book', 'note_card', 'list_card', 'handwrite_card', 'quote_hole',
  'source_tag', 'photo_wall', 'stain', 'doodle', 'object_reveal',
];

Project project({double w = kW, double h = kH, double duration = 12}) {
  final p = Project(id: 'p', name: 'Evidence', main: Composition(id: 'main', name: 'Main', width: w, height: h, fps: 30, duration: duration));
  void img(String id, double w, double h) => p.media[id] = MediaAsset(id: id, type: MediaType.image, path: '/$id.png', name: id, width: w, height: h);
  img('shot', 1080, 4200); // tall article screenshot
  img('shot2', 1200, 900);
  img('img', 1200, 800);
  img('cut', 600, 1200);
  img('pen', 300, 900);
  p.media['clip'] = MediaAsset(id: 'clip', type: MediaType.video, path: '/v.mp4', name: 'footage', width: 1920, height: 1080, duration: 12);
  return p;
}

CommandResult run(Project p, Map<String, dynamic> c) => EditCommands.runAtomic(p, c);

Layer layer(Project p, String id, {String comp = 'main'}) => (comp == 'main' ? p.main : p.comps[comp]!).requireLayer(id);

/// Screen position of a layer-local point.
Vector3 screen(Composition c, Layer l, double t, double x, double y) => Evaluator.worldMatrix(c, l, t).transformed3(Vector3(x, y, 0));

void main() {
  group('registry', () {
    test('every V3 component is registered with a label and documented', () {
      for (final t in v3Types) {
        expect(Components.types, contains(t));
        expect(Components.label(t), isNot(t), reason: t);
        expect(commandSpec, contains(t), reason: 'command_spec documents $t');
      }
      for (final w in ['write_on', 'slide_up_over', 'tilt3d', 'focus', 'scroll_whip', 'newsprint_wall', 'newspaper_collage', 'pen_circle', 'text_color', 'at_word']) {
        expect(commandSpec, contains(w), reason: w);
      }
      expect(TextAnimators.all, contains('write_on'));
    });

    test('every V3 component builds with defaults, evaluates, and is one undo step', () {
      for (final t in v3Types) {
        final p = project();
        final before = ProjectSnapshot.take(p);
        final r = run(p, {'op': 'add_component', 'type': t, 'id': 'k', 'start': 0.5});
        expect(r.createdIds, isNotEmpty, reason: t);
        for (double time = 0; time < 9; time += 0.37) {
          Evaluator.evaluate(p.main, time);
        }
        ProjectSnapshot.restore(p, before);
        expect(ProjectSnapshot.take(p), before, reason: '$t undoes in one step');
      }
    });

    test('a failing V3 component leaves the project untouched', () {
      final p = project();
      final before = ProjectSnapshot.take(p);
      expect(() => run(p, {'op': 'add_component', 'type': 'note_card', 'id': 'k', 'font': 'No Such Font'}), throwsA(isA<CommandError>()));
      expect(ProjectSnapshot.take(p), before);
    });
  });

  group('article upgrades (55 + 11)', () {
    test('old commands still build the V1 article', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'article', 'id': 'ar', 'start': 0, 'duration': 6, 'media': 'shot2', 'marks': [{'box': [0.1, 0.3, 0.6, 0.32]}]});
      expect(p.main.layerById('ar_bgn'), isNull);
      expect(p.main.layerById('ar_bg'), isNotNull);
    });

    test('fullbleed + slide_up_over + exit slide_left', () {
      final p = project();
      run(p, {
        'op': 'add_component', 'type': 'article', 'id': 'ar', 'start': 1, 'duration': 5, 'media': 'shot2',
        'fullbleed': true, 'enter': 'slide_up_over', 'exit': 'slide_left',
      });
      final paper = layer(p, 'ar_a0_paper');
      expect(paper.width, closeTo(kW, 1), reason: 'covers the frame width');
      expect(paper.height, closeTo(kH, 1), reason: 'taller than the frame: a full-frame window that scrolls');
      expect(layer(p, 'ar_a0_img').masks, hasLength(1));
      expect(paper.effects.any((e) => e.type == 'torn_edge'), isFalse);
      final pg = layer(p, 'ar_a0_page').prop(Props.position);
      expect(pg.valueAt(1)[1], closeTo(kH * 1.05, 1));
      expect(pg.valueAt(1.3)[1], closeTo(0, 1e-6));
      expect(pg.valueAt(1.1)[1], lessThan(kH * 0.5), reason: 'expo-out: most of the slide happens early');
      final g = layer(p, 'ar_g').prop(Props.position);
      expect(g.valueAt(5.5)[0], closeTo(kW / 2, 1e-6));
      expect(g.valueAt(5.98)[0], lessThan(-kW * 0.5));
      expect(layer(p, 'ar_a0_img').effects.any((e) => e.type == 'motion_blur'), isTrue);
    });

    test('tilt3d: the page goes into a precomp shown as one 3D layer settling flat', () {
      final p = project();
      run(p, {
        'op': 'add_component', 'type': 'article', 'id': 'ar', 'start': 0, 'duration': 5, 'media': 'shot2', 'backdrop': 'clean',
        'tilt3d': {'from': [22, 0, -2], 'to': [0, 0, -1], 'duration': 0.5},
        'marks': [{'box': [0.1, 0.3, 0.6, 0.32], 'style': 'highlight'}],
      });
      final cl = layer(p, 'ar_3d');
      expect(cl.type, LayerType.comp);
      expect(cl.is3D, isTrue);
      final rot = cl.prop(Props.rotation);
      expect(rot.valueAt(0), [22, 0, -2]);
      expect(rot.valueAt(0.5)[0], closeTo(0, 1e-6));
      expect(rot.valueAt(0.5)[2], closeTo(-1, 1e-6));
      final inner = p.comps['ar_pc']!;
      expect(inner.layerById('ar_a0_img'), isNotNull);
      expect(inner.layerById('ar_a0_m0_0'), isNotNull, reason: 'marks travel with the page');
      expect(p.main.layerById('ar_a0_img'), isNull);
      expect(p.main.layerById('ar_bd'), isNotNull, reason: 'backdrop stays flat in main');
      for (double t = 0; t < 5; t += 0.4) {
        Evaluator.evaluate(p.main, t);
        Evaluator.evaluate(inner, t);
      }
    });

    test('focus punch-in centres the mark (zoom 1.9) and pen_circle / loop draw as one stroke', () {
      final p = project();
      run(p, {
        'op': 'add_component', 'type': 'article', 'id': 'ar', 'start': 0, 'duration': 6, 'media': 'shot2', 'backdrop': 'none', 'tilt': 0, 'drift': 0,
        'marks': [
          {'id': 'noun', 'box': [0.6, 0.5, 0.8, 0.53], 'style': 'pen_circle', 'delay': 2},
          {'boxes': [[0.1, 0.3, 0.9, 0.32], [0.1, 0.33, 0.5, 0.35]], 'style': 'circle', 'ellipse_style': 'loop', 'delay': 4},
        ],
        'focus': [{'mark': 'noun', 'zoom': 1.9, 'duration': 0.35}],
      });
      final pg = layer(p, 'ar_a0_page');
      expect(pg.prop(Props.scale).valueAt(1.5)[0], closeTo(100, 1e-6));
      expect(pg.prop(Props.scale).valueAt(2.0)[0], closeTo(190, 1e-6));
      final circle = layer(p, 'ar_a0_m0');
      expect(circle.parentId, 'ar_a0_img');
      expect(circle.prop(Props.trim).valueAt(2.0), [0, 0]);
      expect(circle.prop(Props.trim).valueAt(2.4)[1], closeTo(100, 1e-6));
      // The marked box centre sits in the middle of the frame after the punch-in.
      final img = layer(p, 'ar_a0_img');
      final c = screen(p.main, img, 2.2, 0.7 * 1200, 0.515 * 900);
      expect(c.x, closeTo(kW / 2, 1));
      expect(c.y, closeTo(kH / 2, 1));
      final loop = layer(p, 'ar_a0_m1');
      expect(loop.shape!.rings.single.length, greaterThan(80), reason: 'one ellipse around both lines with a tail');
    });

    test('sequential highlight lines, multiply highlight, brush, text_color, underline', () {
      final p = project();
      run(p, {
        'op': 'add_component', 'type': 'article', 'id': 'ar', 'start': 0, 'duration': 9, 'media': 'shot2', 'backdrop': 'newsprint_wall',
        'lines': 'sequential', 'blend': 'multiply',
        'marks': [
          {'boxes': [[0.1, 0.2, 0.9, 0.22], [0.1, 0.23, 0.9, 0.25], [0.1, 0.26, 0.4, 0.28]], 'style': 'highlight', 'delay': 1},
          {'box': [0.1, 0.4, 0.5, 0.42], 'style': 'brush', 'delay': 3.5},
          {'box': [0.1, 0.5, 0.7, 0.52], 'style': 'text_color', 'color': '#E8F53A', 'delay': 5},
          {'boxes': [[0.1, 0.6, 0.9, 0.62], [0.1, 0.63, 0.6, 0.65]], 'style': 'underline', 'delay': 6.5},
        ],
      });
      // Highlight: three copies of the page tinted like a highlighter (multiply), 0.6 s per line.
      final starts = [for (int j = 0; j < 3; j++) layer(p, 'ar_a0_m0_$j').start];
      expect(starts[0], closeTo(1, 1e-6));
      expect(starts[1], closeTo(1.6, 1e-6));
      expect(starts[2], closeTo(2.2, 1e-6));
      final h0 = layer(p, 'ar_a0_m0_0');
      expect(h0.type, LayerType.image);
      expect(h0.mediaId, 'shot2');
      expect(h0.effects.single.type, 'duotone');
      expect(h0.masks.single.props['size']!.valueAt(1)[0], closeTo(1, 1e-6));
      expect(h0.masks.single.props['size']!.valueAt(1.6)[0], greaterThan(900));
      // Default highlighter colour on newsprint is lime.
      final light = h0.effects.single.params['light']!.staticValue;
      expect(light, [0xE5, 0xF5, 0x1A]);
      // Brush (multiply): jagged matte shape + tinted page copy using it.
      final brush = layer(p, 'ar_a0_m1_0');
      expect(brush.matte?.layerId, 'ar_a0_m1_0_shape');
      expect(layer(p, 'ar_a0_m1_0_shape').shape!.rings.single.length, greaterThan(20));
      // text_color recolours the dark text.
      final tc = layer(p, 'ar_a0_m2_0');
      expect(tc.effects.single.params['dark']!.staticValue, [0xE8, 0xF5, 0x3A]);
      // Underline per line, drawn with trim.
      expect(layer(p, 'ar_a0_m3_1').prop(Props.trim).isAnimated, isTrue);
      expect(p.main.layerById('ar_bd_wall'), isNotNull);
      expect(layer(p, 'ar_bd_wall').parentId, 'ar_bgn');
    });

    test('marks at caption word timings; done marks are drawn already', () {
      final p = project();
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 'cap', 'text': 'the plane crashed in the Andes', 'start': 0, 'duration': 10,
          'words': [{'w': 'the', 's': 0.5, 'e': 0.7}, {'w': 'plane', 's': 0.7, 'e': 1.0}, {'w': 'crashed,', 's': 3.2, 'e': 3.6}, {'w': 'in', 's': 3.6, 'e': 3.7}, {'w': 'the', 's': 3.7, 'e': 3.8}, {'w': 'Andes', 's': 3.8, 'e': 4.3}]});
      run(p, {
        'op': 'add_component', 'type': 'article', 'id': 'ar', 'start': 1, 'duration': 6, 'media': 'shot2', 'backdrop': 'none',
        'marks': [
          {'box': [0.1, 0.3, 0.5, 0.32], 'style': 'highlight', 'at_word': 'Crashed'},
          {'box': [0.1, 0.5, 0.5, 0.52], 'style': 'underline', 'at_word': 'the andes'},
          {'box': [0.1, 0.7, 0.5, 0.72], 'style': 'underline', 'done': true},
        ],
      });
      final layers = p.main.layers.where((l) => l.parentId == 'ar_a0_img').toList();
      double startOf(double y) => layers.firstWhere((l) => (l.prop(Props.position).staticValue[1] - y * 900).abs() < 40).start;
      expect(startOf(0.31), closeTo(3.35, 1e-6), reason: 'lands 0.15 s after "crashed"');
      expect(startOf(0.53), closeTo(3.85, 1e-6));
      final done = layers.firstWhere((l) => l.start == 1 && l.shape != null);
      expect(done.prop(Props.trim).valueAt(1.05)[1], closeTo(100, 1e-6));
    });

    test('scroll_whip: the move to the mark takes 0.25 s; embed photo after a mark; dark theme', () {
      final p = project();
      run(p, {
        'op': 'add_component', 'type': 'article', 'id': 'ar', 'start': 0, 'duration': 8, 'media': 'shot', 'theme': 'dark',
        'scroll_whip': {'to_mark': 1, 'duration': 0.25},
        'marks': [
          {'box': [0.1, 0.2, 0.6, 0.21], 'style': 'text_color', 'delay': 1.5},
          {'box': [0.1, 0.8, 0.6, 0.81], 'style': 'highlight', 'delay': 4},
        ],
        'embed': {'media': 'img', 'after_mark': 0, 'width': 0.7},
      });
      final img = layer(p, 'ar_a0_img');
      final pos = img.prop(Props.position);
      expect(pos.valueAt(3.69)[1], closeTo(pos.valueAt(3.0)[1], 1e-6), reason: 'holds until the whip');
      expect(pos.valueAt(3.95)[1], closeTo(pos.valueAt(5)[1], 1e-6), reason: 'arrived 0.05 s before the mark');
      expect(img.effects.map((e) => e.type), containsAll(['duotone', 'glow', 'chromatic_aberration', 'motion_blur']));
      expect(layer(p, 'ar_a0_paper').shape!.fill, 0xFF0B0B0C);
      final emb = layer(p, 'ar_embed');
      expect(emb.parentId, 'ar_a0_img');
      expect(emb.mediaId, 'img');
      expect(emb.start, closeTo(2.2, 1e-6));
      expect(emb.prop(Props.position).staticValue[1], greaterThan(0.21 * 4200));
    });

    test('newspaper_collage backdrop is blurred clippings', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'article', 'id': 'ar', 'start': 0, 'duration': 4, 'backdrop': 'newspaper_collage'});
      final clips = [for (int g = 0; g < 3; g++) layer(p, 'ar_bd_clip$g')];
      expect(clips.fold<int>(0, (a, l) => a + l.shape!.rings.length), 12);
      for (final l in clips) {
        expect(l.effects.map((e) => e.type), containsAll(['shadow', 'blur']));
      }
    });
  });

  group('marks on photos', () {
    test('circle_mark draws clockwise from 12 o\'clock, holds, then undraws', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'circle_mark', 'id': 'cm', 'start': 1, 'x': 800, 'y': 400, 'width': 200, 'height': 160});
      final ring = layer(p, 'cm_ring');
      expect(ring.shape!.stroke, 0xFFF01818);
      expect(ring.shape!.strokeWidth, closeTo(kH * 0.012, 1e-6));
      final trim = ring.prop(Props.trim);
      expect(trim.valueAt(1), [0, 0]);
      expect(trim.valueAt(1.5)[1], closeTo(100, 1e-6));
      expect(trim.valueAt(2.3), [0, 100]);
      expect(trim.valueAt(ring.end - 0.01)[0], closeTo(100, 1e-6));
      // First point: top of the ellipse.
      final pos = ring.prop(Props.position).staticValue;
      final x0 = pos[0] - ring.width / 2 + ring.shape!.rings[0][0], y0 = pos[1] - ring.height / 2 + ring.shape!.rings[0][1];
      expect(x0, closeTo(800, 2));
      expect(y0, closeTo(400 - 80, 4));
      final x1 = pos[0] - ring.width / 2 + ring.shape!.rings[0][2];
      expect(x1, greaterThan(x0), reason: 'clockwise: heads right first');
      expect(ring.effects.single.type, 'glow');
    });

    test('inset_circle grows from a point with a ring and a yellow outlined label', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'inset_circle', 'id': 'ic', 'start': 0, 'duration': 4, 'media': 'img', 'x': 1400, 'y': 400, 'from': [900, 700], 'label': 'radio'});
      final g = layer(p, 'ic_g');
      expect(g.prop(Props.position).valueAt(0), [900, 700, 0]);
      expect(g.prop(Props.position).valueAt(0.45), [1400, 400, 0]);
      expect(g.prop(Props.scale).valueAt(0)[0], closeTo(4, 1e-6));
      expect(g.prop(Props.scale).valueAt(3.99)[0], lessThan(10), reason: 'shrinks back to the point');
      final im = layer(p, 'ic_img');
      expect(im.masks.single.shape, 'ellipse');
      expect(im.masks.single.props['size']!.staticValue[0], closeTo(800, 1), reason: 'circle = 0.3 h on the 800 px side');
      final label = layer(p, 'ic_label');
      expect(label.text!.text, 'RADIO');
      expect(label.text!.color, 0xFFFFD21F);
      expect(label.effects.single.type, 'outline');
    });

    test('object_reveal wipes a layer on as the prop rolls past', () {
      final p = project();
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 'kp', 'text': 'THE OLD CHRISTIANS', 'width': 1000, 'height': 160, 'position': [960, 700], 'start': 0, 'duration': 6});
      run(p, {'op': 'add_component', 'type': 'object_reveal', 'id': 'or', 'start': 1, 'duration': 2, 'media': 'cut', 'y': 700, 'reveals': ['kp']});
      final kp = layer(p, 'kp');
      final m = kp.masks.single;
      // Prop x = -size → w + size over 2 s (linear); the text box spans 460..1460.
      final size = kH * 0.22, xa = -size, xb = kW + size;
      double tAt(double x) => 1 + (x - xa) / (xb - xa) * 2;
      expect(m.props['size']!.valueAt(tAt(460) - 0.01)[0], closeTo(1, 1e-6));
      expect(m.props['size']!.valueAt(tAt(960))[0], closeTo(500, 2));
      expect(m.props['size']!.valueAt(tAt(1460) + 0.01)[0], closeTo(1000, 1e-6));
      expect(layer(p, 'or_obj').prop(Props.rotation).valueAt(3)[2], greaterThan(360));
    });

    test('stain grows in tones; doodle draws paths in order and stamps letters', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'stain', 'id': 'st', 'start': 0, 'x': 900, 'y': 500, 'tones': 2});
      expect(layer(p, 'st_tone0').shape!.rings.length, greaterThan(5), reason: 'blob + droplets');
      expect(layer(p, 'st_tone1').prop(Props.scale).valueAt(0.08)[0], closeTo(4, 1e-6));
      expect(layer(p, 'st_tone0').prop(Props.scale).valueAt(0.5)[0], closeTo(100, 1e-6));
      run(p, {
        'op': 'add_component', 'type': 'doodle', 'id': 'dd', 'start': 0, 'draw': 2,
        'paths': [[[100, 100], [300, 100]], {'points': [[300, 300], [300, 700]], 'arrow': true}],
        'stamp': {'text': 'TRICK', 'x': 900, 'y': 200},
      });
      final p0 = layer(p, 'dd_p0'), p1 = layer(p, 'dd_p1');
      expect(p0.prop(Props.trim).valueAt(0.6667)[1], closeTo(100, 0.5));
      expect(p1.prop(Props.trim).valueAt(0.6667)[1], closeTo(0, 0.5));
      expect(p1.prop(Props.trim).valueAt(2)[1], closeTo(100, 1e-6));
      expect(p1.shape!.arrowEnd, isTrue);
      expect(layer(p, 'dd_stamp0').text!.animator, 'random_pop');
    });
  });

  group('books and cards', () {
    test('book: generated cover, hinge open, flip, zoom into a text page with marks', () {
      final p = project();
      run(p, {
        'op': 'add_component', 'type': 'book', 'id': 'bk', 'start': 0, 'title': 'Alive', 'author': 'A Writer', 'colors': ['#1D2B4F', '#F2D21B'],
        'pages': [{'text': 'First page.'}, {'text': 'They had no food left and the radio said the search was over.'}],
        'marks': [{'phrase': 'no food left', 'style': 'highlight'}, {'phrase': 'search was over', 'style': 'underline'}],
      });
      expect(layer(p, 'bk_cvtitle').text!.text, 'ALIVE');
      expect(layer(p, 'bk_bd').effects.any((e) => e.type == 'grunge'), isTrue);
      final cover = layer(p, 'bk_cover').prop(Props.scale);
      expect(cover.valueAt(1.6)[0], closeTo(100, 1e-6));
      expect(cover.valueAt(1.8)[0], closeTo(1, 1e-6));
      expect(layer(p, 'bk_inside').prop(Props.scale).valueAt(2.0)[0], closeTo(100, 1e-6));
      expect(p.main.layerById('bk_leaf0'), isNotNull);
      // Rises with a back-ease overshoot.
      final pos = layer(p, 'bk_g').prop(Props.position);
      final ys = [for (double t = 0; t <= 0.6; t += 0.02) pos.valueAt(t)[1]];
      expect(ys.reduce((a, b) => a < b ? a : b), lessThan(kH * 0.52 - 1), reason: 'overshoots above its rest');
      // Zoomed in: scale 100 % and the right page centre in the middle of the frame.
      final g = layer(p, 'bk_g');
      final tz = 1.6 + 0.45 + 0.3 + 0.1 + 0.8;
      expect(g.prop(Props.scale).valueAt(tz)[0], closeTo(100, 1e-6));
      final page = layer(p, 'bk_pg1');
      final c = screen(p.main, page, tz, page.width / 2, page.height / 2);
      expect(c.x, closeTo(kW / 2, 1));
      expect(c.y, closeTo(kH / 2, 1));
      final marks = page.text!.marks;
      expect(marks.map((m) => m.style), ['highlight', 'underline']);
      expect(marks.first.start, greaterThan(tz));
      expect(marks.last.start, greaterThan(marks.first.start));
    });

    test('book side_popin has no backdrop and pops in beside the presenter', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'book', 'id': 'bk', 'start': 0, 'duration': 4, 'enter': 'side_popin', 'zoom_to': 'none'});
      expect(p.main.layerById('bk_bd'), isNull);
      final g = layer(p, 'bk_g');
      expect(g.prop(Props.position).valueAt(1)[0], closeTo(kW * 0.86, 1e-6));
      expect(g.prop(Props.scale).valueAt(0)[0], lessThan(g.prop(Props.scale).valueAt(1)[0]));
    });

    test('note_card drops in rotated, glides 15 %, red word written on', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'note_card', 'id': 'nc', 'start': 0, 'text': 'pact', 'x': 960, 'y': 540, 'tilt': -6});
      final g = layer(p, 'nc_g');
      expect(g.prop(Props.rotation).valueAt(0)[2], closeTo(1, 1e-6));
      expect(g.prop(Props.rotation).valueAt(1.0)[2], closeTo(-6, 1e-6));
      expect(g.prop(Props.position).valueAt(0)[0], closeTo(960 + kW * 0.15, 1e-6));
      expect(g.prop(Props.position).valueAt(1.0)[0], closeTo(960, 1e-6));
      expect(g.prop(Props.scale).valueAt(0)[0], 135);
      final word = layer(p, 'nc_word');
      expect(word.text!.text, 'PACT');
      expect(word.text!.color, 0xFFB3121E);
      expect(word.text!.animator, 'write_on');
      expect(layer(p, 'nc_rule').shape!.rings.length, greaterThan(5));
      expect(p.main.layerById('nc_curl'), isNotNull);
    });

    test('list_card writes items one after another, pops them, drops out', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'list_card', 'id': 'lc', 'start': 0, 'items': ['rugby team', 'toothpaste', {'text': 'wine', 'at': 4}], 'title': 'Food left'});
      final items = [for (int i = 0; i < 3; i++) layer(p, 'lc_item$i')];
      expect(items[0].start, lessThan(items[1].start));
      expect(items[2].start, closeTo(4, 1e-6));
      expect(items[0].text!.animator, 'write_on');
      expect(items[0].text!.fontFamily, 'Kalam');
      expect(items[1].prop(Props.scale).valueAt(items[1].start)[0], closeTo(160, 1e-6));
      expect(items[1].prop(Props.scale).valueAt(items[1].start + 0.3)[0], closeTo(100, 1e-6));
      final g = layer(p, 'lc_g');
      expect(g.prop(Props.position).valueAt(g.end - 0.01)[1], greaterThan(kH), reason: 'drops out');
    });

    test('handwrite_card: write speed from write_cps, optional pen follows the lines', () {
      final p = project();
      const text = 'We are alive. Please come and find us soon.';
      run(p, {'op': 'add_component', 'type': 'handwrite_card', 'id': 'hw', 'start': 0, 'text': text, 'write_cps': 8, 'pen': 'pen'});
      final t = layer(p, 'hw_text');
      expect(t.text!.animator, 'write_on');
      expect(t.text!.animDuration, closeTo(text.length / 8, 1e-6));
      final pen = layer(p, 'hw_pen').prop(Props.position);
      expect(pen.isAnimated, isTrue);
      expect(pen.valueAt(0.5)[0], lessThan(pen.valueAt(1.2)[0]), reason: 'moves right while writing');
      expect(layer(p, 'hw_g').end, closeTo(0.5 + text.length / 8 + 0.5 + 1.5 + 0.3, 1e-6));
    });

    test('quote_hole: plate seen through a ragged hole, highlighted quote, settle', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'quote_hole', 'id': 'qh', 'start': 0, 'plate': 'img', 'source': 'The podcast', 'body': 'We ate what we had to eat to stay alive.', 'highlights': ['to stay alive']});
      final plate = layer(p, 'qh_plate');
      expect(plate.matte?.layerId, 'qh_hole');
      expect(layer(p, 'qh_hole').shape!.rings.single.length, greaterThan(40));
      expect(layer(p, 'qh_card').shape!.fill, 0xFF1F2B45);
      expect(layer(p, 'qh_source').text!.color, 0xFFDDF06A);
      final body = layer(p, 'qh_body');
      expect(body.text!.marks.single.phrase, 'to stay alive');
      final g = layer(p, 'qh_g').prop(Props.scale);
      expect(g.valueAt(0)[0], 104);
      expect(g.valueAt(0.3)[0], closeTo(100, 1e-6));
    });

    test('source_tag pill under a layer', () {
      final p = project();
      run(p, {'op': 'add_layer', 'type': 'image', 'media': 'img', 'id': 'photo', 'fit': 'none', 'position': [960, 400], 'scale': [50, 50, 100]});
      run(p, {'op': 'add_component', 'type': 'source_tag', 'id': 'src', 'start': 0, 'text': 'Source – example.com', 'attach': 'photo'});
      final g = layer(p, 'src_g').prop(Props.position).staticValue;
      expect(g[0], closeTo(960, 1));
      expect(g[1], greaterThan(400 + 200));
      expect(layer(p, 'src_pill').shape!.fill, 0xFFF2A6A6);
      expect(layer(p, 'src_text').text!.color, 0xFF5A1414);
      expect(layer(p, 'src_pill').prop(Props.scale).valueAt(0)[0], 0);
    });

    test('photo_card frames, backdrops and a key phrase revealed by a rolling prop', () {
      final p = project();
      run(p, {
        'op': 'add_component', 'type': 'photo_card', 'id': 'pc', 'start': 0, 'duration': 5, 'media': 'img', 'frame': 'torn_white',
        'backdrop': 'grunge_navy', 'title': 'The old christians', 'key_phrase': 'rugby club', 'reveal_prop': 'cut',
      });
      expect(layer(p, 'pc_bd').shape!.fill, 0xFF1B2A4A);
      expect(layer(p, 'pc_frame').shape!.rings.single.length, greaterThan(40), reason: 'torn edge');
      expect(layer(p, 'pc_photo').effects.map((e) => e.type), contains('mono'));
      expect(layer(p, 'pc_title').text!.animator, 'typewriter');
      expect(layer(p, 'pc_key').masks.single.id, 'pc_key_reveal');
      expect(layer(p, 'pc_key').text!.color, 0xFF2EE6E6);
      expect(layer(p, 'pc_g').prop(Props.scale).valueAt(4)[0], closeTo(105, 1e-6), reason: 'push 5 % per 4 s');
      // Plain photo_card commands keep the V1 look.
      final q = project();
      run(q, {'op': 'add_component', 'type': 'photo_card', 'id': 'pc', 'start': 0, 'media': 'img'});
      expect(q.main.layerById('pc_bd'), isNull);
    });

    test('photo_wall: B&W photos (colour last) with splatters; the wall moves photo to photo', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'photo_wall', 'id': 'pw', 'start': 0, 'photos': ['img', 'cut', 'img'], 'dwell': 2.5});
      expect(layer(p, 'pw_g').end, closeTo(3 * 2.5 + 0.4, 1e-6));
      expect(layer(p, 'pw_card0_photo').effects.any((e) => e.type == 'mono'), isTrue);
      expect(layer(p, 'pw_card2_photo').effects.any((e) => e.type == 'mono'), isFalse);
      expect(layer(p, 'pw_card1_ink').shape!.rings.length, 15);
      for (final k in [0, 1, 2]) {
        final card = layer(p, 'pw_card$k');
        final c = screen(p.main, card, k * 2.5 + 0.8, 0, 0);
        expect(c.x, closeTo(kW / 2, kW * 0.02), reason: 'photo $k centred during its dwell');
      }
      final rot = [for (int k = 0; k < 3; k++) layer(p, 'pw_card$k').prop(Props.rotation).staticValue[2].abs()];
      expect(rot.every((r) => r >= 2 && r <= 8), isTrue);
    });
  });

  group('labels (20)', () {
    test('character_label plain/print: small red role over a big name, no box', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'character_label', 'id': 'cl', 'start': 0, 'style': 'print', 'text': 'Nando', 'role': 'survivor', 'x': 600, 'y': 300});
      expect(layer(p, 'cl_name').text!.text, 'NANDO');
      expect(layer(p, 'cl_name').text!.color, 0xFF141414);
      expect(layer(p, 'cl_role').text!.color, 0xFFD0202A);
      expect(p.main.layerById('cl_tag'), isNull);
    });

    test('arrow_callout circle:false: half-arc arrow and role/name', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'arrow_callout', 'id': 'ac', 'start': 0, 'circle': false, 'from': [500, 700], 'to': [900, 700], 'role': 'pilot', 'name': 'Ferradas'});
      final arrow = layer(p, 'ac_arrow');
      expect(arrow.shape!.arrowEnd, isTrue);
      expect(arrow.prop(Props.trim).valueAt(0.5)[1], closeTo(100, 1e-6));
      expect(p.main.layerById('ac_ring'), isNull);
      expect(layer(p, 'ac_name').text!.text, 'FERRADAS');
      // The arc bulges away from the chord (≈ 180°).
      final pos = arrow.prop(Props.position).staticValue;
      expect((pos[1] - 700).abs(), greaterThan(40));
    });
  });

  group('write_on renders', () {
    testWidgets('words appear left to right over anim_duration', (tester) async {
      final p = project(w: 600, h: 200);
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'AAAA BBBB CCCC', 'width': 580, 'height': 120, 'position': [300, 100],
          'font_size': 30, 'text_color': '#FFFFFF', 'shadow': false, 'animator': 'write_on', 'anim_duration': 1.5, 'start': 0, 'duration': 4});
      bool lit(int r, int g, int b) => r > 100 || g > 100 || b > 100;
      int litIn(Uint8List b, int x0, int x1) {
        var n = 0;
        for (int y = 0; y < 200; y++) {
          for (int x = x0; x < x1; x++) {
            final i = (y * 600 + x) * 4;
            if (lit(b[i], b[i + 1], b[i + 2])) n++;
          }
        }
        return n;
      }

      final early = await render(tester, p, 0.3);
      final done = await render(tester, p, 2);
      expect(litIn(done, 0, 600), greaterThan(1000));
      expect(litIn(early, 0, 600), lessThan(litIn(done, 0, 600) * 0.45));
      expect(litIn(early, 400, 600), 0, reason: 'the last word is not written yet');
    });

    testWidgets('new evidence pieces render without errors', (tester) async {
      final p = project(w: 960, h: 540);
      run(p, {
        'op': 'add_component', 'type': 'article', 'id': 'ar', 'start': 0, 'duration': 3, 'backdrop': 'newsprint_wall', 'theme': 'dark',
        'tilt3d': true, 'marks': [{'box': [0.1, 0.3, 0.6, 0.33], 'style': 'brush'}, {'box': [0.2, 0.5, 0.6, 0.53], 'style': 'pen_circle'}],
      });
      run(p, {'op': 'add_component', 'type': 'book', 'id': 'bk', 'start': 3, 'duration': 4, 'pages': [{'text': 'Hello world'}], 'marks': [{'phrase': 'world'}]});
      run(p, {'op': 'add_component', 'type': 'quote_hole', 'id': 'qh', 'start': 7, 'duration': 2, 'body': 'A quote', 'source': 'show'});
      for (final t in [0.2, 1.0, 2.5, 3.5, 5.0, 6.5, 7.5]) {
        await render(tester, p, t);
      }
    });
  });
}

/// Renders the main comp at [t] (RGBA, 1 px = 1 comp px).
Future<Uint8List> render(WidgetTester tester, Project p, double t) async {
  final comp = p.main;
  tester.view.physicalSize = Size(comp.width, comp.height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    child: Center(child: RepaintBoundary(key: key, child: CompositionCanvas(project: p, time: t))),
  ));
  expect(tester.takeException(), isNull);
  late Uint8List bytes;
  await tester.runAsync(() async {
    final ro = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await ro.toImage();
    bytes = (await img.toByteData())!.buffer.asUint8List();
    img.dispose();
  });
  return bytes;
}
