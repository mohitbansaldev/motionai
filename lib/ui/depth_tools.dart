// V2-E (Depth from photo): runs photo_to_3d / depth_map jobs for the editor
// and for Claude (MCP: run_commands + job_status), with a small progress
// card over the app.
import 'dart:async';

import 'package:flutter/material.dart';

import '../core/commands/depth_commands.dart';
import '../core/commands/edit_commands.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../platform/windows_ai/win_ai.dart';
import '../remote/remote_control.dart';
import '../remote/remote_jobs.dart';
import '../state/editor_controller.dart';
import 'common.dart';
import 'theme.dart';

class DepthTools {
  /// What the running depth job is doing (null = idle).
  static final ValueNotifier<String?> status = ValueNotifier(null);
  static OverlayEntry? _entry;
  static Timer? _hideTimer;

  /// Lets the edit commands start depth jobs (idempotent).
  static void install() => DepthCommands.launcher = _launch;

  /// "Make 3D from photo" in the layer panel.
  static void makeFromPhoto(BuildContext context, EditorController c, Layer l) {
    install();
    final err = c.tryRun({'op': 'photo_to_3d', 'layer': l.id});
    showSnack(context, err ?? 'Building a 3D scene from this photo… (keep editing; it appears as one undo step)');
  }

  static String _launch(DepthRequest req) {
    final job = RemoteControl.instance.tools.jobs.start('depth');
    job.message = 'Starting…';
    // After the current command batch has finished.
    Timer.run(() => unawaited(_run(req, job)));
    return job.id;
  }

  static Future<void> _run(DepthRequest req, RemoteJob job) async {
    final c = RemoteControl.instance.editor;
    if (c == null || !identical(c.project, req.project)) {
      job.fail('The project was closed before the depth job started.');
      return;
    }
    void say(String m) {
      job.message = m;
      status.value = m;
    }

    _show();
    say(req.kind == 'depth_map' ? 'Reading depth…' : 'Making 3D from ${req.media.name}…');
    try {
      final dir = await c.storage.mediaDir();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      if (req.kind == 'depth_map') {
        final res = await WinAi.depthMap(req.media.path, '$dir/depth_${stamp}_map.png', model: req.model, onStatus: say);
        _checkOpen(c);
        final a = _asset('${res['path']}', '${req.media.name} (depth map)', res['w'] as int, res['h'] as int);
        c.project.media[a.id] = a;
        c.mediaChanged();
        job.done({'media': a.id, 'model': res['model'], if (res['note'] != null) 'note': res['note']},
            message: 'Depth map ready: media ${a.id} (${res['model'] == 'depth' ? 'AI depth' : 'estimated depth'})');
      } else {
        final res = await WinAi.photoTo3d(req.media.path, '$dir/depth_$stamp',
            mediaWidth: req.media.width, layers: req.layers, pad: req.pad, model: req.model, onStatus: say);
        _checkOpen(c);
        final names = ['far', 'mid', 'near', 'front', 'front 2', 'front 3'];
        final prepared = <Map<String, dynamic>>[];
        final layers = (res['layers'] as List).cast<Map>();
        for (final (i, l) in layers.indexed) {
          final a = _asset('${l['path']}', '${req.media.name} (depth ${names[i.clamp(0, names.length - 1)]})', l['w'] as int, l['h'] as int);
          c.project.media[a.id] = a;
          prepared.add({'media': a.id, 'x': l['x'], 'y': l['y'], 'k': l['k'], 'depth': l['depth']});
        }
        c.mediaChanged();
        final r = c.run({
          ...req.command,
          'prepared': {'model': res['model'], 'layers': prepared},
        });
        job.done({
          'created': r.createdIds,
          'model': res['model'],
          if (res['note'] != null) 'note': res['note'],
          'log': r.log.take(12).toList(),
        }, message: 'Added ${prepared.length} depth layers with a camera move (one undo step).');
      }
      say(job.message);
    } on CommandError catch (e) {
      job.fail(e.message);
      say('3D photo failed: ${e.message}');
    } catch (e) {
      job.fail(e);
      say('3D photo failed: $e');
    } finally {
      _hideLater();
    }
  }

  static void _checkOpen(EditorController c) {
    if (!identical(RemoteControl.instance.editor, c)) throw StateError('The project was closed while the depth job ran.');
  }

  static MediaAsset _asset(String path, String name, int w, int h) =>
      MediaAsset(id: Ids.next('img'), type: MediaType.image, path: path, name: name, width: w.toDouble(), height: h.toDouble());

  // ------------------------------------------------------------ progress card

  static void _show() {
    _hideTimer?.cancel();
    if (_entry != null) return;
    final overlay = RemoteControl.instance.navigatorKey.currentState?.overlay;
    if (overlay == null) return;
    final e = OverlayEntry(builder: (_) => const _DepthProgress());
    _entry = e;
    overlay.insert(e);
  }

  static void _hideLater() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      _entry?.remove();
      _entry = null;
      status.value = null;
    });
  }
}

class _DepthProgress extends StatelessWidget {
  const _DepthProgress();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 16,
      bottom: 16,
      child: IgnorePointer(
        child: ValueListenableBuilder<String?>(
          valueListenable: DepthTools.status,
          builder: (context, msg, _) {
            if (msg == null) return const SizedBox.shrink();
            final busy = !msg.startsWith('Added') && !msg.startsWith('Depth map ready') && !msg.contains('failed');
            return Material(
              color: MA.surface2,
              elevation: 6,
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (busy)
                      const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2))
                    else
                      const Icon(Icons.view_in_ar, size: 18, color: MA.accent2),
                    const SizedBox(width: 10),
                    Flexible(child: Text(msg, style: const TextStyle(color: MA.text, fontSize: 13))),
                  ]),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
