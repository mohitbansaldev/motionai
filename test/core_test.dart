import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/engine/evaluator.dart';
import 'package:motionai/core/model/anim_prop.dart';
import 'package:motionai/core/model/camera.dart';
import 'package:motionai/core/model/easing.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/core/presets/templates.dart';

Project newProject() => Project(
      id: 'p1',
      name: 'Test',
      main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: 10),
    );

void main() {
  group('easing', () {
    test('endpoints', () {
      for (final e in EaseType.values.where((t) => t != EaseType.hold)) {
        final ease = Easing(e);
        expect(ease.transform(0), 0);
        expect(ease.transform(1), 1);
      }
    });
    test('easy ease is symmetric and slow at the ends', () {
      expect(Easing.easyEase.transform(0.5), closeTo(0.5, 1e-3));
      expect(Easing.easyEase.transform(0.1), lessThan(0.1));
    });
    test('parse names', () {
      expect(Easing.parse('ease_in').type, EaseType.easeIn);
      expect(Easing.parse('easy-ease').type, EaseType.easyEase);
      expect(() => Easing.parse('wobble'), throwsFormatException);
    });
  });

  group('AnimProp', () {
    test('interpolates between keyframes', () {
      final p = AnimProp([0, 0]);
      p.setKeyframe(0, [0, 0], easing: Easing.linear);
      p.setKeyframe(2, [100, 50]);
      expect(p.valueAt(1), [50, 25]);
      expect(p.valueAt(-1), [0, 0]);
      expect(p.valueAt(5), [100, 50]);
    });
    test('hold keeps the value until the next key', () {
      final p = AnimProp([0]);
      p.setKeyframe(0, [10], easing: Easing.hold);
      p.setKeyframe(1, [20]);
      expect(p.scalarAt(0.99), 10);
      expect(p.scalarAt(1), 20);
    });
    test('setValue on animated prop adds a keyframe', () {
      final p = AnimProp([0]);
      p.setKeyframe(0, [0]);
      p.setValue(3, [9]);
      expect(p.keyframes.length, 2);
      expect(p.scalarAt(3), 9);
    });
    test('json round trip', () {
      final p = AnimProp([1, 2, 3]);
      p.setKeyframe(1, [4, 5, 6], easing: const Easing.bezierCurve(0.1, 0.2, 0.3, 0.9));
      final q = AnimProp.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(q.valueAt(1), [4, 5, 6]);
      expect(q.keyframes.first.easing.type, EaseType.bezier);
    });
  });

  group('evaluator', () {
    test('2D layer at center maps its anchor to the center', () {
      final pr = newProject();
      EditCommands.runAtomic(pr, {'op': 'add_layer', 'type': 'solid', 'id': 's', 'width': 200, 'height': 100});
      final items = Evaluator.evaluate(pr.main, 0);
      expect(items.length, 1);
      final c = items.first.project(100, 50);
      expect(c.x, closeTo(960, 1e-6));
      expect(c.y, closeTo(540, 1e-6));
    });

    test('3D layer at z=0 with default camera looks identical to 2D', () {
      final pr = newProject();
      EditCommands.runAtomic(pr, {'op': 'add_layer', 'type': 'solid', 'id': 's', 'width': 400, 'height': 200, 'is3d': true});
      final item = Evaluator.evaluate(pr.main, 0).first;
      final tl = item.project(0, 0);
      expect(tl.x, closeTo(960 - 200, 1e-3));
      expect(tl.y, closeTo(540 - 100, 1e-3));
    });

    test('farther 3D layers look smaller and draw first', () {
      final pr = newProject();
      EditCommands.runAtomic(pr, {
        'op': 'batch',
        'commands': [
          {'op': 'add_layer', 'type': 'solid', 'id': 'near', 'width': 400, 'height': 400, 'is3d': true},
          {'op': 'add_layer', 'type': 'solid', 'id': 'far', 'width': 400, 'height': 400, 'is3d': true, 'index': 0},
          {'op': 'set_property', 'target': 'far', 'prop': 'position.z', 'value': 2000},
        ],
      });
      final items = Evaluator.evaluate(pr.main, 0);
      expect(items.first.layer.id, 'far'); // painted first even though it is the top layer
      double width(RenderItem i) => i.project(400, 200).x - i.project(0, 200).x;
      expect(width(items.first), lessThan(width(items.last)));
    });

    test('parallax rig keeps the first frame unchanged', () {
      final pr = newProject();
      EditCommands.runAtomic(pr, {
        'op': 'batch',
        'commands': [
          {'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'width': 1920, 'height': 1080},
          {'op': 'add_layer', 'type': 'solid', 'id': 'fg', 'width': 300, 'height': 300, 'position': [400, 300, 0]},
        ],
      });
      final before = Evaluator.evaluate(pr.main, 0).map((i) => i.project(0, 0)).toList();
      EditCommands.runAtomic(pr, {'op': 'parallax_rig', 'layers': ['bg', 'fg'], 'start': 0, 'duration': 4});
      expect(pr.main.camera.mode, CameraMode.threeD);
      final after = Evaluator.evaluate(pr.main, 0).map((i) => i.project(0, 0)).toList();
      for (int i = 0; i < before.length; i++) {
        expect(after[i].x, closeTo(before[i].x, 0.5));
        expect(after[i].y, closeTo(before[i].y, 0.5));
      }
      // ...and that the near layer grows more than the far one as the camera pushes in.
      double width(RenderItem i) => i.project(i.layer.width, 0).x - i.project(0, 0).x;
      final start = Evaluator.evaluate(pr.main, 0);
      final end = Evaluator.evaluate(pr.main, 4);
      final bgGrowth = width(end[0]) / width(start[0]);
      final fgGrowth = width(end[1]) / width(start[1]);
      expect(fgGrowth, greaterThan(bgGrowth));
      expect(bgGrowth, greaterThan(1));
    });
  });

  group('edit commands', () {
    test('batch is atomic', () {
      final pr = newProject();
      expect(
        () => EditCommands.runAtomic(pr, {
          'op': 'batch',
          'commands': [
            {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'Hi'},
            {'op': 'set_keyframe', 'target': 'missing', 'prop': 'opacity', 'value': 0},
          ],
        }),
        throwsA(isA<CommandError>()),
      );
      expect(pr.main.layers, isEmpty);
    });

    test('split keeps source continuity', () {
      final pr = newProject();
      pr.media['v'] = MediaAsset(id: 'v', type: MediaType.video, path: '/x.mp4', name: 'x', width: 1920, height: 1080, duration: 8);
      final r = EditCommands.runAtomic(pr, {'op': 'add_layer', 'type': 'video', 'media': 'v', 'id': 'a'});
      expect(r.createdIds, ['a']);
      EditCommands.runAtomic(pr, {'op': 'split_layer', 'layer': 'a', 'time': 3, 'new_id': 'b'});
      final a = pr.main.requireLayer('a'), b = pr.main.requireLayer('b');
      expect(a.duration, closeTo(3, 1e-9));
      expect(b.start, 3);
      expect(b.sourceIn, closeTo(3, 1e-9));
      expect(b.duration, closeTo(5, 1e-9));
    });

    test('moving a layer moves its keyframes', () {
      final pr = newProject();
      EditCommands.runAtomic(pr, {
        'op': 'batch',
        'commands': [
          {'op': 'add_layer', 'type': 'solid', 'id': 's'},
          {'op': 'set_keyframe', 'target': 's', 'prop': 'opacity', 'time': 1, 'value': 0},
          {'op': 'update_layer', 'layer': 's', 'start': 2},
        ],
      });
      expect(pr.main.requireLayer('s').prop(Props.opacity).keyframes.first.time, 3);
    });

    test('camera move preset creates keyframes', () {
      final pr = newProject();
      EditCommands.runAtomic(pr, {'op': 'camera_move', 'preset': 'orbit', 'start': 0, 'duration': 3, 'amount': 45});
      expect(pr.main.camera.mode, CameraMode.threeD);
      expect(pr.main.camera.prop(CamProps.position).keyframes.length, 9);
    });

    test('effect params are keyframeable through set_keyframe', () {
      final pr = newProject();
      EditCommands.runAtomic(pr, {
        'op': 'batch',
        'commands': [
          {'op': 'add_layer', 'type': 'solid', 'id': 's'},
          {'op': 'add_effect', 'layer': 's', 'effect': 'blur', 'id': 'fx1'},
          {'op': 'set_keyframe', 'target': 's', 'effect': 'fx1', 'prop': 'amount', 'time': 0, 'value': 40},
          {'op': 'set_keyframe', 'target': 's', 'effect': 'fx1', 'prop': 'amount', 'time': 1, 'value': 0},
        ],
      });
      final fx = pr.main.requireLayer('s').effectById('fx1')!;
      expect(fx.params['amount']!.keyframes.length, 2);
    });

    test('project json round trip', () {
      final pr = newProject();
      EditCommands.runAtomic(pr, {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'Hello', 'is3d': true});
      EditCommands.runAtomic(pr, {'op': 'camera_move', 'preset': 'push_in'});
      final copy = Project.fromJson(jsonDecode(jsonEncode(pr.toJson())) as Map<String, dynamic>);
      expect(jsonEncode(copy.toJson()), jsonEncode(pr.toJson()));
    });

    test('errors name valid options for the agent', () {
      final pr = newProject();
      try {
        EditCommands.runAtomic(pr, {'op': 'camera_move', 'preset': 'spin'});
        fail('should throw');
      } on CommandError catch (e) {
        expect(e.message, contains('push_in'));
      }
    });
  });

  group('v2 commands', () {
    Project withPhoto() {
      final pr = newProject();
      pr.media['img'] = MediaAsset(id: 'img', type: MediaType.image, path: '/a.jpg', name: 'a', width: 1920, height: 1080);
      EditCommands.runAtomic(pr, {'op': 'add_layer', 'type': 'image', 'media': 'img', 'id': 'p', 'duration': 4});
      return pr;
    }

    test('animate_in fade adds opacity keys at layer start', () {
      final pr = withPhoto();
      EditCommands.runAtomic(pr, {'op': 'animate_in', 'layer': 'p', 'preset': 'fade', 'duration': 1});
      final o = pr.main.requireLayer('p').prop(Props.opacity);
      expect(o.scalarAt(0), 0);
      expect(o.scalarAt(1), 100);
    });

    test('every transition preset runs in and out', () {
      for (final t in ['fade', 'zoom_in', 'zoom_out', 'slide_left', 'slide_right', 'slide_up', 'slide_down', 'blur', 'spin', 'pop', 'whip']) {
        final pr = withPhoto();
        EditCommands.runAtomic(pr, {'op': 'animate_in', 'layer': 'p', 'preset': t});
        EditCommands.runAtomic(pr, {'op': 'animate_out', 'layer': 'p', 'preset': t});
      }
    });

    test('styles replace each other', () {
      final pr = withPhoto();
      EditCommands.runAtomic(pr, {'op': 'apply_style', 'style': 'cinematic_doc'});
      final n1 = pr.main.requireLayer('p').effects.length;
      EditCommands.runAtomic(pr, {'op': 'apply_style', 'style': 'cinematic_doc'});
      expect(pr.main.requireLayer('p').effects.length, n1);
      EditCommands.runAtomic(pr, {'op': 'apply_style', 'style': 'shorts_punch'});
      expect(pr.main.requireLayer('p').effects.length, lessThan(n1));
    });

    test('masks are keyframeable and survive json', () {
      final pr = withPhoto();
      EditCommands.runAtomic(pr, {
        'op': 'batch',
        'commands': [
          {'op': 'add_mask', 'layer': 'p', 'shape': 'rect', 'id': 'm1', 'feather': 20},
          {'op': 'set_keyframe', 'target': 'p', 'mask': 'm1', 'prop': 'size', 'time': 0, 'value': [100, 100]},
          {'op': 'set_keyframe', 'target': 'p', 'mask': 'm1', 'prop': 'size', 'time': 2, 'value': [1920, 1080]},
        ],
      });
      final copy = Project.fromJson(jsonDecode(jsonEncode(pr.toJson())) as Map<String, dynamic>);
      expect(copy.main.requireLayer('p').maskById('m1')!.props['size']!.keyframes.length, 2);
    });

    test('text animator and caption words', () {
      final pr = newProject();
      EditCommands.runAtomic(pr, {
        'op': 'add_layer',
        'type': 'text',
        'id': 't',
        'text': 'hello world',
        'animator': 'karaoke',
        'words': [
          {'w': 'hello', 's': 0, 'e': 0.5},
          {'w': 'world', 's': 0.5, 'e': 1},
        ],
      });
      final t = pr.main.requireLayer('t').text!;
      expect(t.animator, 'karaoke');
      expect(t.words.length, 2);
      EditCommands.runAtomic(pr, {'op': 'update_layer', 'layer': 't', 'start': 2});
      expect(pr.main.requireLayer('t').text!.words.first.start, 2);
    });

    test('audio layer from audio media', () {
      final pr = newProject();
      pr.media['a'] = MediaAsset(id: 'a', type: MediaType.audio, path: '/m.mp3', name: 'm', width: 0, height: 0, duration: 30);
      EditCommands.runAtomic(pr, {'op': 'add_layer', 'type': 'audio', 'media': 'a', 'id': 'music'});
      expect(pr.main.requireLayer('music').duration, 30);
      expect(Evaluator.evaluate(pr.main, 1), isEmpty);
    });
  });

  test('all templates build without errors', () {
    for (final t in Templates.all) {
      final pr = Project(
        id: 't',
        name: t.name,
        main: Composition(id: 'main', name: 'Main', width: t.width, height: t.height, duration: t.duration),
      );
      EditCommands.runAtomic(pr, {'op': 'batch', 'commands': t.commands(t.width, t.height)});
      expect(pr.main.layers, isNotEmpty, reason: t.name);
      for (double time = 0; time < t.duration; time += 0.5) {
        Evaluator.evaluate(pr.main, time);
      }
    }
  });
}
