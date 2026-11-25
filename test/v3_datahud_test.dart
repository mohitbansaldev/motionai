// V3-C: data, HUD & overlays — components, text keys/animators/styles,
// blend modes, disintegrate, vector icons, flags, templates, docs.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/ai/command_spec.dart';
import 'package:motionai/core/commands/datahud_commands.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/engine/text_v3.dart';
import 'package:motionai/core/model/easing.dart';
import 'package:motionai/core/model/effects_catalog.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/components.dart';
import 'package:motionai/core/presets/flags.dart';
import 'package:motionai/core/presets/templates.dart';
import 'package:motionai/core/presets/vector_icons.dart';
import 'package:motionai/fonts/font_catalog.dart';
import 'package:motionai/fonts/text_styles.dart';
import 'package:motionai/ui/preview/composition_canvas.dart';
import 'package:motionai/ui/preview/fx/datahud_fx.dart';
import 'package:motionai/ui/preview/fx/layer_cache.dart';

Project project({double w = 1920, double h = 1080}) {
  final p = Project(
    id: 'p',
    name: 'DataHUD',
    main: Composition(id: 'main', name: 'Main', width: w, height: h, fps: 30, duration: 10, background: 0xFF000000),
  );
  p.media['img'] = MediaAsset(id: 'img', type: MediaType.image, path: '/a.jpg', name: 'photo', width: 1200, height: 800);
  p.media['cut'] = MediaAsset(id: 'cut', type: MediaType.image, path: '/c.png', name: 'person', width: 600, height: 1200);
  return p;
}

CommandResult run(Project p, Map<String, dynamic> c) => EditCommands.runAtomic(p, c);

Layer lay(Project p, String id) => p.main.requireLayer(id);

const v3Types = [
  'unit_chart', 'people_grid', 'stat_figure', 'calendar_flip', 'clock_stamp', 'clock_overlay', 'split_screen', 'gauge_hud',
  'icon_sticker', 'icon_drop', 'social_cta', 'social_bug', 'ui_toggle', 'audio_wave', 'flag_badge', 'presenter_stats',
  'info_card', 'stat_title',
];

Future<Uint8List> render(WidgetTester tester, Project p, double t, {bool draft = false}) async {
  final comp = p.main;
  tester.view.physicalSize = Size(comp.width, comp.height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    child: Center(child: RepaintBoundary(key: key, child: CompositionCanvas(project: p, time: t, draft: draft))),
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

int count(Uint8List b, bool Function(int r, int g, int b) f) {
  var n = 0;
  for (int i = 0; i + 3 < b.length; i += 4) {
    if (f(b[i], b[i + 1], b[i + 2])) n++;
  }
  return n;
}

void main() {
  group('components', () {
    test('every V3-C component is registered, labelled and builds with defaults as one undo step', () {
      for (final t in v3Types) {
        expect(Components.types, contains(t));
        expect(Components.label(t), isNot(t), reason: t);
        final p = project();
        final r = run(p, {'op': 'add_component', 'type': t, 'id': 'k', 'start': 0, 'duration': 4});
        expect(r.createdIds, isNotEmpty, reason: t);
        expect(p.main.layers.any((l) => l.id.startsWith('k_')), isTrue, reason: t);
        for (double time = 0; time < 4.2; time += 0.35) {
          Evaluator.evaluate(p.main, time);
        }
        // the whole component is one atomic batch: a failing follow-up restores everything
        final before = p.main.layers.length;
        expect(() => run(p, {'op': 'batch', 'commands': [{'op': 'add_component', 'type': t, 'id': 'z', 'start': 0}, {'op': 'nope'}]}),
            throwsA(isA<CommandError>()));
        expect(p.main.layers.length, before, reason: t);
      }
    });

    test('components work with sfx off and inside a precomp', () {
      for (final t in v3Types) {
        final p = project();
        run(p, {'op': 'add_component', 'type': t, 'id': 'k', 'start': 0, 'duration': 3, 'sfx': false});
        expect(p.main.layers.where((l) => l.type == LayerType.audio), isEmpty, reason: t);
        final q = project();
        run(q, {'op': 'add_comp', 'id': 'C1', 'name': 'Shot', 'duration': 4});
        run(q, {'op': 'add_component', 'in_comp': 'C1', 'type': t, 'id': 'k', 'start': 0, 'duration': 3});
        expect(q.comps['C1']!.layers.any((l) => l.id.startsWith('k_')), isTrue, reason: t);
      }
    });

    test('unit_chart: one pictogram per unit, popping row by row; group labels at their time', () {
      final p = project();
      run(p, {
        'op': 'add_component', 'type': 'unit_chart', 'id': 'u', 'start': 1, 'duration': 6, 'total_label': '45 passengers',
        'groups': [
          {'count': 29, 'color': '#9E9E9E', 'label': 'died in the crash'},
          {'count': 16, 'color': '#E53935', 'label': 'survived', 'at': 3},
        ],
      });
      final icons = p.main.layers.where((l) => RegExp(r'^u_u\d+$').hasMatch(l.id)).toList();
      expect(icons.length, 45);
      expect(lay(p, 'u_total').text!.text, '45 PASSENGERS');
      expect(lay(p, 'u_total').effects.single.type, 'blur');
      final s0 = lay(p, 'u_u0').prop(Props.scale), s44 = lay(p, 'u_u44').prop(Props.scale);
      expect(s0.keyframes.first.value[0], 0);
      expect(s0.keyframes.map((k) => k.value[0]).reduce((a, b) => a > b ? a : b), closeTo(115, 0.01));
      expect(s44.keyframes.first.time, greaterThan(s0.keyframes.first.time + 1.2));
      expect(lay(p, 'u_u44').shape!.fill, 0xFFE53935);
      expect(lay(p, 'u_u0').shape!.fill, 0xFF9E9E9E);
      expect(lay(p, 'u_g1_num').start, closeTo(4, 1e-9));
      expect(lay(p, 'u_g1_label').text!.text, 'SURVIVED');
      expect(lay(p, 'u_g0_label').text!.text, 'DIED IN\nTHE CRASH');
      expect(p.main.layers.where((l) => l.type == LayerType.audio), isNotEmpty, reason: 'pop sfx');
    });

    test('people_grid: dead figures fade from red to grey, the count slides in', () {
      final p = project();
      run(p, {
        'op': 'add_component', 'type': 'people_grid', 'id': 'pg', 'start': 0, 'duration': 6, 'total': 10, 'alive': 4, 'dead_at': 2,
        'names': [{'name': 'Roberto', 'role': 'Medical student'}, 'Nando'], 'media': 'img',
      });
      final red = p.main.layers.where((l) => l.id.startsWith('pg_red')).toList();
      final grey = p.main.layers.where((l) => l.id.startsWith('pg_grey')).toList();
      expect(red.length, 10);
      expect(grey.length, 6);
      final dead = red.firstWhere((l) => l.prop(Props.opacity).isAnimated);
      expect(dead.prop(Props.opacity).scalarAt(1.9), closeTo(100, 1e-6));
      expect(dead.prop(Props.opacity).scalarAt(3.2), closeTo(0, 1e-6));
      expect(lay(p, 'pg_count').text!.text, '4 SURVIVED');
      expect(lay(p, 'pg_count').start, closeTo(3.1, 1e-9));
      expect(lay(p, 'pg_n0').text!.text, 'ROBERTO');
      expect(lay(p, 'pg_r0').text!.text, 'Medical student');
      expect(lay(p, 'pg_under').prop(Props.opacity).scalarAt(0), closeTo(20, 1e-9));
      final x = project();
      run(x, {'op': 'add_component', 'type': 'people_grid', 'id': 'q', 'start': 0, 'duration': 5, 'total': 4, 'alive': 1, 'dead': 'x'});
      expect(x.main.layers.where((l) => RegExp(r'^q_x\d+$').hasMatch(l.id)).length, 3);
    });

    test('stat_figure: number steps (rolling) and turns red; silhouette tints', () {
      final p = project();
      run(p, {
        'op': 'add_component', 'type': 'stat_figure', 'id': 'sf', 'start': 0, 'duration': 5, 'icon': 'scale', 'from': 80, 'to': 50,
        'steps': 6, 'unit': 'KG', 'label': 'weight',
      });
      final vals = [for (int k = 0; k <= 6; k++) lay(p, 'sf_v$k')];
      expect(vals.first.text!.text, '80 KG');
      expect(vals.last.text!.text, '50 KG');
      expect(vals.last.text!.color, 0xFFE53935);
      expect(vals.first.text!.color, 0xFFFFFFFF);
      expect(vals[3].start - vals[2].start, closeTo(0.25, 1e-9));
      expect(lay(p, 'sf_label').text!.animator, 'typewriter');
      final red = lay(p, 'sf_fig_red').prop(Props.opacity);
      expect(red.scalarAt(0.5), 0);
      expect(red.scalarAt(3), closeTo(100, 1e-6));
    });

    test('calendar_flip: 3D tear-off pages flip over the binding, the last page stays', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'calendar_flip', 'id': 'cal', 'start': 0, 'duration': 6, 'from': 1, 'to': 12, 'rate': 4, 'caption': 'days'});
      expect(lay(p, 'cal_g').is3D, isTrue);
      expect(lay(p, 'cal_g').prop(Props.rotation).valueAt(0), [50, 0, -20]);
      final pages = p.main.layers.where((l) => RegExp(r'^cal_p\d+$').hasMatch(l.id)).toList();
      expect(pages.length, 12);
      expect(lay(p, 'cal_p11_num').text!.text, '12');
      expect(lay(p, 'cal_p11').end, closeTo(6, 1e-9));
      final fold = lay(p, 'cal_p0').prop(Props.scale);
      expect(fold.valueAt(0.4)[1], closeTo(100, 1e-9));
      expect(fold.valueAt(0.5 + 0.42)[1], closeTo(4, 1e-6));
      expect(lay(p, 'cal_p0_paper').prop(Props.opacity).scalarAt(0.95), closeTo(0, 1e-6));
      expect(lay(p, 'cal_p0_paper').is3D, isTrue);
      expect(lay(p, 'cal_caption').text!.text, 'DAYS');
      // long ranges are sampled to max_pages
      final q = project();
      run(q, {'op': 'add_component', 'type': 'calendar_flip', 'id': 'c', 'start': 0, 'duration': 8, 'from': 1, 'to': 400, 'rate': 10});
      final qp = q.main.layers.where((l) => RegExp(r'^c_p\d+$').hasMatch(l.id)).length;
      expect(qp, lessThanOrEqualTo(41));
    });

    test('clock_stamp: typed italic mono lines, blinking colon, retype on a time jump', () {
      final p = project();
      run(p, {
        'op': 'add_component', 'type': 'clock_stamp', 'id': 'cs', 'start': 0, 'duration': 6,
        'lines': ['DAY 61', '03:21 PM'], 'retype': [{'text': '05:40 PM', 'at': 4}],
      });
      final l0 = lay(p, 'cs_l0').text!;
      expect(l0.text, 'DAY 61');
      expect(l0.fontFamily, 'Share Tech Mono');
      expect(l0.italic, isTrue);
      expect(l0.animator, 'typewriter');
      expect(l0.animDuration, closeTo(6 / 13, 1e-9));
      expect(lay(p, 'cs_l1').text!.text, '03 21 PM');
      final colon = lay(p, 'cs_c1');
      expect(colon.text!.text, '  :     ');
      final op = colon.prop(Props.opacity);
      final blinks = op.keyframes.where((k) => k.time < colon.end - 0.35).toList();
      expect(blinks.length, greaterThan(3));
      expect(blinks.every((k) => k.easing.type == EaseType.hold), isTrue);
      expect({for (final k in blinks) k.value[0]}, {0.0, 100.0});
      expect(lay(p, 'cs_l1').end, closeTo(4, 1e-9), reason: 'retyped at 4 s');
      expect(lay(p, 'cs_l2').text!.text, '05 40 PM');
      expect(lay(p, 'cs_l2').start, closeTo(4, 1e-9));
      expect(lay(p, 'cs_shade').shape!.fill2 >> 24, closeTo(77, 1));
    });

    test('clock_overlay: translucent face, hands spin, clock_tick bed', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'clock_overlay', 'id': 'co', 'start': 0, 'duration': 4, 'spin': 1, 'enter': 'rise', 'blend': 'screen'});
      expect(lay(p, 'co_ring').prop(Props.opacity).scalarAt(2), closeTo(30, 1e-6));
      final m = lay(p, 'co_minute').prop(Props.rotation);
      expect(m.valueAt(4)[2] - m.valueAt(0)[2], closeTo(360 * 4, 1e-6));
      final h = lay(p, 'co_hour').prop(Props.rotation);
      expect(h.valueAt(4)[2] - h.valueAt(0)[2], closeTo(120, 1e-6));
      expect(lay(p, 'co_minute').blendMode, 'screen');
      expect(p.main.layers.any((l) => l.type == LayerType.audio), isTrue, reason: 'clock_tick bed');
      expect(lay(p, 'co_g').prop(Props.position).valueAt(0)[1], greaterThan(540));
    });

    test('split_screen: divider draws first, halves wipe from it, media masked, bars grow', () {
      final p = project();
      run(p, {
        'op': 'add_component', 'type': 'split_screen', 'id': 'ss', 'start': 0, 'duration': 5, 'orientation': 'diagonal',
        'a': {'media': 'img', 'label': 'they said', 'value': 3}, 'b': {'label': 'it was', 'value': 9, 'note': 'three times more'},
        'middle': 'cut',
      });
      expect(lay(p, 'ss_media0').matte!.layerId, 'ss_half0');
      expect(lay(p, 'ss_divider').prop(Props.trim).valueAt(0), [50, 50]);
      expect(lay(p, 'ss_divider').prop(Props.trim).valueAt(0.25), [0, 100]);
      expect(lay(p, 'ss_half0').prop(Props.scale).valueAt(0.25)[0], 0);
      expect(lay(p, 'ss_half0').prop(Props.scale).valueAt(0.8)[0], closeTo(100, 1e-6));
      expect(lay(p, 'ss_half1').shape!.fill, isNot(0xFFFFFFFF), reason: 'panel B without media is a visible panel');
      final bar0 = lay(p, 'ss_bar0'), bar1 = lay(p, 'ss_bar1');
      expect(bar1.width / bar0.width, closeTo(3, 0.01));
      expect(lay(p, 'ss_label0').text!.text, 'THEY SAID');
      expect(lay(p, 'ss_note1').text!.text, 'three times more');
      expect(lay(p, 'ss_middle').mediaId, 'cut');
    });

    test('gauge_hud: tape scrolls so "to" ends under the fixed pointer, labels masked by a soft window', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'gauge_hud', 'id': 'gh', 'start': 0, 'duration': 5, 'from': 20000, 'to': 12000, 'step': 1000, 'spacing': 100});
      final tape = lay(p, 'gh_tape').prop(Props.position);
      expect(tape.valueAt(0.3)[1], 0);
      expect(tape.valueAt(5)[1], closeTo(-800, 1e-6), reason: 'lower values come up from below');
      final labs = p.main.layers.where((l) => RegExp(r'^gh_lab\d+$').hasMatch(l.id)).toList();
      expect(labs.map((l) => l.text!.text), contains('20000 FT'));
      expect(labs.every((l) => l.matte?.layerId == 'gh_window'), isTrue);
      expect(lay(p, 'gh_window').effects.single.type, 'blur');
      expect(lay(p, 'gh_pointer').shape!.fill, 0xFFE01010);
    });

    test('icon_sticker: disc pops, items squash-morph on their times', () {
      final p = project();
      run(p, {
        'op': 'add_component', 'type': 'icon_sticker', 'id': 'st', 'start': 0, 'duration': 5,
        'items': [{'icon': 'plane', 'at': 0.3}, {'icon': 'radio', 'at': 1.5}, {'text': 'SOS', 'at': 2.8}],
      });
      expect(lay(p, 'st_disc').shape!.fill, 0xFFFFE500);
      final i1 = lay(p, 'st_i1').prop(Props.scale);
      expect(i1.valueAt(1.5), [130, 0, 100]);
      expect(i1.valueAt(1.8), [100, 100, 100]);
      final i0 = lay(p, 'st_i0');
      expect(i0.end, closeTo(1.62, 1e-9));
      expect(lay(p, 'st_i2_txt').text!.text, 'SOS');
      final disc = lay(p, 'st_disc').prop(Props.scale);
      expect(disc.valueAt(1.5)[0], closeTo(112, 1e-6));
    });

    test('icon_drop: bounces in from above (or rises) with a pop', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'icon_drop', 'id': 'id', 'start': 0, 'duration': 3, 'icon': 'stop'});
      final pos = lay(p, 'id_g').prop(Props.position);
      expect(pos.keyframes.first.easing.type, EaseType.bounce);
      expect(pos.valueAt(0)[1], lessThan(0));
      expect(pos.valueAt(0.75)[1], closeTo(540, 1e-6));
      expect(p.main.layers.any((l) => l.text?.text == 'STOP'), isTrue);
      final q = project();
      run(q, {'op': 'add_component', 'type': 'icon_drop', 'id': 'r', 'start': 0, 'duration': 3, 'icon': 'handshake', 'enter': 'rise'});
      expect(q.main.requireLayer('r_g').prop(Props.position).valueAt(0)[1], greaterThan(1080));
    });

    test('social_cta / social_bug: glyph + 2-line caps + handle, swoosh draws, bug breaks into pixels', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'social_cta', 'id': 'sc', 'start': 1, 'platform': 'whatsapp'});
      expect(lay(p, 'sc_g').duration, closeTo(0.4 + 2.8 + 0.3, 1e-9));
      expect(lay(p, 'sc_l1').text!.text, 'JOIN US ON');
      expect(lay(p, 'sc_l2').text!.text, 'WhatsApp');
      expect(lay(p, 'sc_l3').text!.text, '@Mohitflix');
      expect(lay(p, 'sc_swoosh').shape!.stroke, 0xFF25D366);
      expect(lay(p, 'sc_swoosh').prop(Props.trim).valueAt(1.45), [0, 100]);
      final b = project();
      run(b, {'op': 'add_component', 'type': 'social_bug', 'id': 'sb', 'start': 0, 'platform': 'instagram', 'hold': 2});
      final txt = b.main.requireLayer('sb_l2');
      final fx = txt.effects.firstWhere((e) => e.type == 'disintegrate');
      expect(fx.params['progress']!.scalarAt(2.2), 0);
      expect(fx.params['progress']!.scalarAt(2.7), closeTo(100, 1e-6));
      for (final pl in ['youtube', 'facebook', 'twitter', 'x', 'telegram', 'custom']) {
        final q = project();
        run(q, {'op': 'add_component', 'type': 'social_cta', 'id': 'q', 'start': 0, 'platform': pl, 'handle': 'none'});
        expect(q.main.layerById('q_l3'), isNull, reason: pl);
      }
    });

    test('ui_toggle: knob slides off → on with a bump, track turns green, click', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'ui_toggle', 'id': 'tg', 'start': 0, 'duration': 3, 'at': 1, 'label': 'engine', 'labels': true});
      final knob = lay(p, 'tg_knob').prop(Props.position);
      expect(knob.valueAt(0.9)[0], lessThan(0));
      expect(knob.valueAt(1.2)[0], greaterThan(0));
      expect(lay(p, 'tg_track_on').prop(Props.opacity).scalarAt(0.5), 0);
      expect(lay(p, 'tg_track_on').prop(Props.opacity).scalarAt(1.3), closeTo(100, 1e-6));
      expect(lay(p, 'tg_knob').prop(Props.scale).valueAt(1.18)[0], closeTo(105, 1e-6));
      expect(lay(p, 'tg_on_txt').prop(Props.opacity).scalarAt(1.5), closeTo(100, 1e-6));
      expect(p.main.layers.any((l) => l.type == LayerType.audio), isTrue);
    });

    test('audio_wave: N bars dancing on eased keyframes; levels shape the profile', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'audio_wave', 'id': 'aw', 'start': 0, 'duration': 4, 'bars': 24, 'label': 'radio montevideo'});
      final bars = p.main.layers.where((l) => RegExp(r'^aw_b\d+$').hasMatch(l.id)).toList();
      expect(bars.length, 24);
      final sc = bars[12].prop(Props.scale);
      expect(sc.keyframes.length, greaterThan(10));
      expect(sc.keyframes.every((k) => k.easing.type == EaseType.easyEase), isTrue);
      expect(lay(p, 'aw_card').shape!.fill, 0xFF0B1E6B);
      final q = project();
      run(q, {'op': 'add_component', 'type': 'audio_wave', 'id': 'w', 'start': 0, 'duration': 2, 'bars': 4, 'levels': [0, 1]});
      final s0 = q.main.requireLayer('w_b0').prop(Props.scale).keyframes.map((k) => k.value[1]);
      expect(s0.every((v) => v <= 6.0001), isTrue);
    });

    test('flag_badge: drawn flag clipped to a circle; unknown country = disc + code', () {
      final p = project();
      run(p, {'op': 'add_component', 'type': 'flag_badge', 'id': 'fb', 'start': 0, 'duration': 3, 'country': 'Uruguay', 'label': true});
      final parts = p.main.layers.where((l) => RegExp(r'^fb_f\d+$').hasMatch(l.id)).toList();
      expect(parts, isNotEmpty);
      expect(parts.every((l) => l.matte?.layerId == 'fb_clip'), isTrue);
      expect(lay(p, 'fb_label').text!.text, 'URUGUAY');
      final q = project();
      run(q, {'op': 'add_component', 'type': 'flag_badge', 'id': 'n', 'start': 0, 'duration': 3, 'country': 'NPL'});
      expect(q.main.requireLayer('n_code').text!.text, 'NPL');
    });

    test('presenter_stats, info_card, stat_title and lower_third bar_wipe', () {
      final p = project();
      run(p, {
        'op': 'add_component', 'type': 'presenter_stats', 'id': 'ps', 'start': 0, 'duration': 6,
        'lines': [{'text': '72 days', 'at': 0.5}, {'text': '16 survivors', 'at': 2}, 'no food'], 'lead_color': '#E53935',
      });
      expect(lay(p, 'ps_s0').text!.text, '72 DAYS');
      expect(lay(p, 'ps_s1').start, closeTo(2, 1e-9));
      expect(lay(p, 'ps_s0').text!.leadColor, 0xFFE53935);
      expect(lay(p, 'ps_s0').text!.leadChars, 3);
      expect(lay(p, 'ps_s1').prop(Props.position).valueAt(2)[1], greaterThan(lay(p, 'ps_s0').prop(Props.position).valueAt(2)[1]));
      run(p, {'op': 'add_component', 'type': 'info_card', 'id': 'ic', 'start': 0, 'duration': 4, 'title': 'Old Christians', 'lines': ['13 Oct 1972', 'Montevideo']});
      expect(lay(p, 'ic_title').text!.text, 'OLD CHRISTIANS');
      expect(lay(p, 'ic_line1').text!.text, 'Montevideo');
      run(p, {'op': 'add_component', 'type': 'stat_title', 'id': 'st', 'start': 0, 'duration': 4, 'line1': 'he survived', 'line2': '72 days'});
      final l1 = lay(p, 'st_l1').text!, l2 = lay(p, 'st_l2').text!;
      expect(l2.fontSize / l1.fontSize, closeTo(1.6, 1e-9));
      expect(l2.color, 0xFFD3123F);
      expect(l2.stroke, 4);
      expect(l2.animator, 'typewriter_soft');
      run(p, {'op': 'add_component', 'type': 'stat_title', 'id': 'sy', 'start': 0, 'duration': 4, 'style': 'yellow', 'line2': '60KM'});
      expect(lay(p, 'sy_l2').text!.animator, 'letter_drop');
      run(p, {'op': 'add_component', 'type': 'lower_third', 'id': 'lt', 'start': 0, 'duration': 4, 'style': 'bar_wipe', 'text': 'subscribe', 'gradient': ['#E53935', '#7A0F2B']});
      final bar = lay(p, 'lt_bar');
      expect(bar.prop(Props.rotation).valueAt(0)[2], -90);
      expect(bar.prop(Props.scale).valueAt(0)[1], 0);
      expect(bar.prop(Props.scale).valueAt(0.25)[1], closeTo(100, 1e-6));
      expect(lay(p, 'lt_txt').text!.animator, 'typewriter');
      expect(lay(p, 'lt_g').prop(Props.position).valueAt(4)[1], greaterThan(lay(p, 'lt_g').prop(Props.position).valueAt(1)[1]));
      // the classic lower third is unchanged
      run(p, {'op': 'add_component', 'type': 'lower_third', 'id': 'old', 'start': 0, 'duration': 4});
      expect(lay(p, 'old_src').text!.text, 'Source: example.com');
    });
  });

  group('text keys, animators and styles', () {
    test('stroke, italic, letter_spacing, lead colour and word times parse and round-trip', () {
      final p = project();
      run(p, {
        'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'SIXTEEN MEN LIVED', 'stroke': {'width': 5, 'color': '#101010'}, 'italic': true,
        'letter_spacing': 3, 'lead_color': '#E53935', 'animator': 'word_fade_grey', 'word_times': [0.2, 0.9, 1.6], 'dim_color': '#555555',
      });
      final t = lay(p, 't').text!;
      expect(t.stroke, 5);
      expect(t.strokeColor, 0xFF101010);
      expect(t.italic, isTrue);
      expect(t.letterSpacing, 3);
      expect(t.leadColor, 0xFFE53935);
      expect(t.leadChars, 3);
      expect(t.wordTimes, [0.2, 0.9, 1.6]);
      expect(t.dimColor, 0xFF555555);
      final back = TextData.fromJson(t.toJson());
      expect(back.toJson(), t.toJson());
      expect(t.copy().toJson(), t.toJson());
      run(p, {'op': 'update_layer', 'layer': 't', 'stroke': 'none', 'stroke_color': '#FFFFFF', 'lead_chars': 2});
      expect(lay(p, 't').text!.stroke, 0);
      expect(lay(p, 't').text!.leadChars, 2);
      expect(() => run(p, {'op': 'update_layer', 'layer': 't', 'word_times': ['a']}), throwsA(isA<CommandError>()));
      expect(() => run(p, {'op': 'update_layer', 'layer': 't', 'stroke': 'thick'}), throwsA(isA<CommandError>()));
      // old projects have none of the keys
      expect(TextData.fromJson({'text': 'x'}).stroke, 0);
      expect(TextData().toJson().containsKey('stroke'), isFalse);
    });

    test('new animators are listed and accepted', () {
      for (final a in ['typewriter_soft', 'letter_drop', 'word_fade_grey']) {
        expect(TextAnimators.all, contains(a));
        expect(TextAnimators.label(a), isNot(a));
        final p = project();
        run(p, {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'HELLO', 'animator': a});
        expect(lay(p, 't').text!.animator, a);
      }
    });

    test('V3 text styles apply a full look; switching style clears the edge', () {
      final ids = ['caption_red_outline', 'stat_red_outline', 'osd_timestamp', 'label_yellow_outline', 'stat_yellow'];
      for (final id in ids) {
        expect(TextStylePresets.byId(id), isNotNull, reason: id);
      }
      final p = project();
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 'c', 'text': 'KOI NAHI', 'text_style': 'caption_red_outline'});
      var t = lay(p, 'c').text!;
      expect(t.color, 0xFFE8254F);
      expect(t.stroke, 4);
      expect(t.strokeColor, 0xFFFFFFFF);
      expect(t.fontWeight, 800, reason: 'Poppins ExtraBold is bundled');
      expect(t.animator, 'word_pop');
      run(p, {'op': 'update_layer', 'layer': 'c', 'text_style': 'osd_timestamp'});
      t = lay(p, 'c').text!;
      expect(t.stroke, 0);
      expect(t.italic, isTrue);
      expect(t.fontFamily, 'Share Tech Mono');
      run(p, {'op': 'update_layer', 'layer': 'c', 'text_style': 'stat_yellow'});
      t = lay(p, 'c').text!;
      expect(t.italic, isFalse);
      expect(t.color, 0xFFFFE000);
      expect(t.animator, 'letter_drop');
    });

    test('animator maths: eased, staggered, settled by the end', () {
      // typewriter_soft
      final (a0, b0) = TextV3.soft(0, 10, 0, 1);
      expect(a0, 0);
      expect(b0, TextV3.softBlur);
      final (a1, b1) = TextV3.soft(9, 10, 1, 1);
      expect(a1, closeTo(1, 1e-9));
      expect(b1, closeTo(0, 1e-9));
      final (am, _) = TextV3.soft(5, 10, 0.3, 1);
      expect(am, 0, reason: 'later letters wait their turn');
      // letter_drop: above → small bounce below → rest
      expect(TextV3.drop(0, 4, 0, 1).$2, closeTo(-1.1, 1e-9));
      var below = false;
      for (double t = 0; t < 0.4; t += 0.01) {
        if (TextV3.drop(0, 4, t, 1).$2 > 0.005) below = true;
      }
      expect(below, isTrue, reason: 'overshoots past the line (bounce)');
      expect(TextV3.drop(3, 4, 2, 1).$2, 0);
      expect(TextV3.dropStaggerFor(4, 1), closeTo(0.08, 1e-9));
      expect(TextV3.dropStaggerFor(40, 1), lessThan(0.08));
      // word_fade_grey
      expect(TextV3.wordLevel(1, 3, 0.85, 1, [0.2, 0.9, 1.6]), 0);
      expect(TextV3.wordLevel(1, 3, 1.1, 1, [0.2, 0.9, 1.6]), closeTo(1, 1e-9));
      expect(TextV3.wordsDone(3, 1, [0.2, 0.9, 1.6]), closeTo(1.8, 1e-9));
      // lead colour
      final (shown, from) = TextV3.lead(10, 0.5, 1, 3);
      expect(shown, 5);
      expect(from, inInclusiveRange(2, 4));
      expect(TextV3.lead(10, 5, 1, 3), (10, 10));
      expect(TextV3.settleTime('letter_drop', 5, 1, 1, 0, const []), closeTo(4 * 0.08 + TextV3.dropTime + 0.02, 1e-9));
    });

    test('preview cache keeps animating word_fade_grey past anim_duration, then freezes', () {
      final p = project();
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'A B C', 'animator': 'word_fade_grey', 'anim_duration': 0.5, 'word_times': [0, 1, 2]});
      final l = lay(p, 't');
      int? sig(double t) => LayerSig.content(p, l, t, draft: true, playing: false);
      expect(sig(1.0), isNot(sig(1.1)));
      expect(sig(2.5), sig(2.9));
    });
  });

  group('blend, disintegrate', () {
    test('blend names are validated; UI blend modes all render', () {
      final p = project();
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 's', 'color': '#808080'});
      run(p, {'op': 'update_layer', 'layer': 's', 'blend': 'Screen'});
      expect(lay(p, 's').blendMode, 'screen');
      run(p, {'op': 'update_layer', 'layer': 's', 'blend': 'plus'});
      expect(lay(p, 's').blendMode, 'add');
      expect(() => run(p, {'op': 'update_layer', 'layer': 's', 'blend': 'glow'}), throwsA(isA<CommandError>()));
      for (final n in DataHudBlend.names) {
        expect(n == 'normal' || LayerBlend.of(n) != null, isTrue, reason: n);
      }
      for (final m in ['normal', 'multiply', 'screen', 'overlay', 'add', 'darken', 'lighten']) {
        expect(DataHudBlend.names, contains(m), reason: 'bulk menu mode $m');
      }
    });

    test('disintegrate effect: catalogued, block thresholds sweep left → right', () {
      final d = EffectsCatalog.byType('disintegrate');
      expect(d, isNotNull);
      expect(LayerSig.paramDriven, contains('disintegrate'));
      var left = 0.0, right = 0.0;
      for (int y = 0; y < 20; y++) {
        left += DisintegrateFx.threshold(0, y, 30, 7);
        right += DisintegrateFx.threshold(29, y, 30, 7);
      }
      expect(right, greaterThan(left));
      for (int x = 0; x < 30; x++) {
        final t = DisintegrateFx.threshold(x, 3, 30, 7);
        expect(t, inExclusiveRange(0, 1));
      }
      expect(DisintegrateFx.alpha(0.5, 0.2), 1);
      expect(DisintegrateFx.alpha(0.5, 0.6), 0);
    });
  });

  group('icons and flags', () {
    test('every vector icon resolves and stays in its 100 × 100 box', () {
      expect(VectorIcons.names.length, 17);
      for (final n in VectorIcons.names) {
        final ic = VectorIcons.byId(n)!;
        expect(ic.parts, isNotEmpty, reason: n);
        for (final part in ic.parts) {
          for (final r in part.rings) {
            expect(r.length.isEven && r.length >= 4, isTrue, reason: n);
            for (final v in r) {
              expect(v, inInclusiveRange(-1, 101), reason: n);
            }
          }
        }
      }
      expect(VectorIcons.resolve('Passenger'), 'person');
      expect(VectorIcons.resolve('deal'), 'handshake');
      expect(VectorIcons.resolve('unicorn'), isNull);
    });

    test('flags: codes, alpha-3 and names find the drawing; parts are valid rings', () {
      expect(Flags.find('in')!.name, 'India');
      expect(Flags.find('URY')!.code, 'UY');
      expect(Flags.find('united kingdom')!.code, 'GB');
      expect(Flags.find('Atlantis'), isNull);
      expect(Flags.codeFor('Atlantis'), 'AT');
      for (final f in Flags.all) {
        expect(f.parts, isNotEmpty, reason: f.code);
        for (final part in f.parts) {
          expect(part.color, matches(RegExp(r'^#[0-9A-F]{6}$')), reason: f.code);
          for (final r in part.rings) {
            expect(r.length.isEven && r.length >= 6, isTrue, reason: '${f.code} ${part.color}');
          }
        }
      }
      expect(Flags.all.map((f) => f.code).toSet().length, Flags.all.length);
    });
  });

  group('fonts, templates, docs', () {
    test('Share Tech Mono, Comic Neue and Poppins 800 are bundled', () {
      expect(FontCatalog.lookup('share tech mono')!.family, 'Share Tech Mono');
      expect(FontCatalog.lookup('comic')!.family, 'Comic Neue');
      expect(FontCatalog.lookup('vcr')!.family, 'Share Tech Mono');
      expect(FontCatalog.lookup('Poppins')!.assetPaths, contains('assets/fonts/poppins/Poppins-ExtraBold.ttf'));
      for (final f in ['assets/fonts/sharetechmono/OFL.txt', 'assets/fonts/comicneue/OFL.txt']) {
        expect(File(f).readAsStringSync(), contains('SIL OPEN FONT LICENSE'));
      }
    });

    test('V3-C templates build at the insert time', () {
      for (final id in ['stat_title', 'date_stamp', 'day_counter', 'passenger_tally', 'social_bug']) {
        final t = SceneTemplates.byId(id);
        expect(t, isNotNull, reason: id);
        expect(t!.available, isTrue, reason: id);
        final p = project();
        final r = EditCommands.runAtomic(p, {'op': 'batch', 'commands': SceneTemplates.commands(p, t, start: 2)}, now: 2);
        expect(r.createdIds, isNotEmpty, reason: id);
        expect(p.main.layers.where((l) => l.start < 2 - 1e-6), isEmpty, reason: id);
      }
    });

    test('AI spec and EDIT_COMMANDS document every V3-C op, key, animator and style', () {
      final md = File('docs/EDIT_COMMANDS.md').readAsStringSync();
      for (final t in v3Types) {
        expect(commandSpec, contains('$t {'), reason: t);
        expect(md, contains('`$t`'), reason: t);
      }
      for (final k in ['stroke', 'italic', 'letter_spacing', 'lead_color', 'word_times', 'typewriter_soft', 'letter_drop', 'word_fade_grey',
        'caption_red_outline', 'stat_red_outline', 'osd_timestamp', 'label_yellow_outline', 'stat_yellow', 'disintegrate', 'bar_wipe', 'blend']) {
        expect(commandSpec, contains(k), reason: k);
        expect(md, contains(k), reason: k);
      }
      expect(RegExp(r'WHEN').allMatches(commandSpec.substring(commandSpec.indexOf('V3-C DATA'))).length, greaterThanOrEqualTo(v3Types.length));
    });
  });

  group('render', () {
    testWidgets('stroke draws a white edge around red letters', (tester) async {
      final p = project(w: 480, h: 270);
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'HI', 'font_size': 120, 'text_color': '#FF0000', 'stroke': 8, 'stroke_color': '#FFFFFF', 'shadow': false, 'width': 480, 'height': 200});
      final px = await render(tester, p, 1);
      expect(count(px, (r, g, b) => r > 200 && g < 60 && b < 60), greaterThan(200));
      expect(count(px, (r, g, b) => r > 220 && g > 220 && b > 220), greaterThan(100));
    });

    testWidgets('V3 animators draw while animating and settle to the static text', (tester) async {
      for (final a in ['typewriter_soft', 'letter_drop', 'word_fade_grey', 'word_pop']) {
        final p = project(w: 480, h: 270);
        run(p, {
          'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'AB CD', 'font_size': 80, 'text_color': '#FFFFFF', 'shadow': false, 'animator': a,
          'anim_duration': 1, 'stroke': a == 'word_pop' ? 4 : 0, 'width': 480, 'height': 200, 'start': 0, 'duration': 5,
        });
        final mid = await render(tester, p, 0.5);
        final end = await render(tester, p, 4);
        final lit = count(end, (r, g, b) => r > 200 && g > 200 && b > 200);
        expect(lit, greaterThan(100), reason: a);
        expect(count(mid, (r, g, b) => r > 40), greaterThan(20), reason: '$a draws mid-animation');
      }
      // typewriter lead colour: newest letters red while typing
      final p = project(w: 480, h: 270);
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'ABCDEFGH', 'font_size': 60, 'text_color': '#FFFFFF', 'shadow': false, 'animator': 'typewriter', 'anim_duration': 1, 'lead_color': '#FF0000', 'width': 480, 'height': 200, 'start': 0, 'duration': 5});
      final typing = await render(tester, p, 0.5);
      expect(count(typing, (r, g, b) => r > 200 && g < 60 && b < 60), greaterThan(50));
      final done = await render(tester, p, 4);
      expect(count(done, (r, g, b) => r > 200 && g < 60 && b < 60), 0);
    });

    testWidgets('screen blend lightens what is below; disintegrate removes blocks', (tester) async {
      final p = project(w: 200, h: 100);
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'color': '#808080', 'width': 200, 'height': 100});
      run(p, {'op': 'add_layer', 'type': 'solid', 'id': 'top', 'color': '#808080', 'width': 100, 'height': 100, 'position': [50, 50, 0]});
      final normal = await render(tester, p, 1);
      run(p, {'op': 'update_layer', 'layer': 'top', 'blend': 'screen'});
      final screen = await render(tester, p, 1);
      int at(Uint8List b, int x, int y) => b[(y * 200 + x) * 4];
      expect(at(normal, 50, 50), closeTo(128, 3));
      expect(at(screen, 50, 50), greaterThan(180), reason: 'screen(0.5, 0.5) = 0.75');
      expect(at(screen, 150, 50), closeTo(128, 3), reason: 'outside the layer unchanged');
      final draft = await render(tester, p, 1, draft: true);
      expect(at(draft, 50, 50), greaterThan(170));

      final q = project(w: 200, h: 100);
      run(q, {'op': 'add_layer', 'type': 'solid', 'id': 's', 'color': '#FFFFFF', 'width': 200, 'height': 100});
      run(q, {'op': 'add_effect', 'layer': 's', 'effect': 'disintegrate', 'id': 'd', 'params': {'progress': 0, 'size': 10}});
      final full = count(await render(tester, q, 1), (r, g, b) => r > 200);
      run(q, {'op': 'set_effect_param', 'layer': 's', 'effect': 'd', 'param': 'progress', 'value': 50});
      final half = count(await render(tester, q, 1), (r, g, b) => r > 200);
      expect(full, 200 * 100);
      expect(half, lessThan(full * 0.85));
      expect(half, greaterThan(full * 0.1));
    });

    testWidgets('every V3-C component renders something', (tester) async {
      for (final t in v3Types) {
        final p = project(w: 960, h: 540);
        run(p, {'op': 'add_component', 'type': t, 'id': 'k', 'start': 0, 'duration': 4, 'sfx': false});
        var best = 0;
        for (final time in [0.5, 1.6, 3.0]) {
          best = [best, count(await render(tester, p, time), (r, g, b) => r > 6 || g > 6 || b > 6)].reduce((a, b) => a > b ? a : b);
        }
        await render(tester, p, 1.2, draft: true);
        expect(best, greaterThan(50), reason: t);
      }
    });
  });
}
