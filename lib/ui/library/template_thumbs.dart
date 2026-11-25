import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;

import '../../core/model/project.dart';
import '../../core/presets/templates.dart';
import '../../library/asset_library.dart';
import '../preview/composition_canvas.dart';

/// Gallery thumbnails: each template is inserted into a scratch project with
/// its default slots and its first frames are rendered with CompositionCanvas
/// into a small PNG (cached for the session).
class TemplateThumbs {
  static final Map<String, Uint8List> cache = {};
  static final Set<String> failed = {};
  static const double width = 256;

  static String key(SceneTemplate t, Project p) => '${t.id}@${p.main.width.round()}x${p.main.height.round()}';

  /// Scratch copy of [from]'s media + an empty comp of the same size, with
  /// [t] inserted at 0. `lib:<id>` values are shown straight from the library
  /// file (nothing is imported). Null if the template can't be built.
  static Project? scratch(SceneTemplate t, Project from, {Map<String, dynamic> values = const {}}) {
    final comp = Composition(id: 'preview', name: 'Preview', width: from.main.width, height: from.main.height, fps: 30, duration: t.duration <= 0 ? 5 : t.duration);
    final p = Project(id: 'preview', name: 'Preview', main: comp, media: {...from.media});
    final lib = AssetLibrary.loaded;
    void addLib(Object? v) {
      if (v is List) {
        v.forEach(addLib);
        return;
      }
      if (v is! String || !v.startsWith('lib:') || lib == null) return;
      final a = lib.byId(v);
      if (a == null) return;
      p.media[v] = MediaAsset(id: v, type: a.type, path: lib.pathOf(a), name: a.name, width: a.width, height: a.height, duration: a.duration);
    }

    for (final s in t.slots) {
      addLib(values.containsKey(s.key) ? values[s.key] : s.initial);
    }
    try {
      SceneTemplates.insert(p, t, start: 0, values: values);
      return p;
    } catch (_) {
      return null;
    }
  }
}

/// Invisible render stage (put it UNDER opaque content in a Stack): renders
/// queued templates one by one and fills [TemplateThumbs.cache].
class ThumbStage extends StatefulWidget {
  final Project source;
  final List<SceneTemplate> queue;
  final VoidCallback onRendered;
  const ThumbStage({super.key, required this.source, required this.queue, required this.onRendered});

  @override
  State<ThumbStage> createState() => _ThumbStageState();
}

class _ThumbStageState extends State<ThumbStage> {
  final _boundary = GlobalKey();
  Project? _p;
  double _t = 0;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _kick();
  }

  @override
  void didUpdateWidget(ThumbStage old) {
    super.didUpdateWidget(old);
    _kick();
  }

  void _kick() {
    if (_running) return;
    scheduleMicrotask(_run);
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    try {
      while (mounted) {
        SceneTemplate? next;
        for (final t in widget.queue) {
          final k = TemplateThumbs.key(t, widget.source);
          if (!TemplateThumbs.cache.containsKey(k) && !TemplateThumbs.failed.contains(k)) {
            next = t;
            break;
          }
        }
        if (next == null) break;
        final tpl = next;
        final k = TemplateThumbs.key(tpl, widget.source);
        final p = TemplateThumbs.scratch(tpl, widget.source);
        if (p == null) {
          TemplateThumbs.failed.add(k);
          widget.onRendered();
          continue;
        }
        setState(() {
          _p = p;
          _t = tpl.previewTime.clamp(0.0, p.main.duration).toDouble();
        });
        await WidgetsBinding.instance.endOfFrame;
        final hasMedia = p.main.layers.any((l) => l.mediaId != null);
        await Future<void>.delayed(Duration(milliseconds: hasMedia ? 260 : 40));
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) break;
        try {
          final ro = _boundary.currentContext?.findRenderObject();
          if (ro is! RenderRepaintBoundary) throw StateError('no stage');
          final img = await ro.toImage(pixelRatio: 1.5);
          final png = await img.toByteData(format: ui.ImageByteFormat.png);
          img.dispose();
          if (png == null) throw StateError('no png');
          TemplateThumbs.cache[k] = png.buffer.asUint8List();
        } catch (_) {
          TemplateThumbs.failed.add(k);
        }
        if (mounted) widget.onRendered();
      }
    } finally {
      _running = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final h = TemplateThumbs.width * widget.source.main.height / (widget.source.main.width <= 0 ? 1 : widget.source.main.width);
    return IgnorePointer(
      child: RepaintBoundary(
        key: _boundary,
        child: SizedBox(
          width: TemplateThumbs.width,
          height: h,
          child: p == null ? const ColoredBox(color: Colors.black) : FittedBox(fit: BoxFit.contain, child: CompositionCanvas(project: p, time: _t)),
        ),
      ),
    );
  }
}
