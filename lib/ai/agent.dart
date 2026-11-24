import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/commands/edit_commands.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../services/media_bridge.dart';
import '../state/editor_controller.dart';
import 'ai_client.dart';
import 'ai_settings.dart';
import 'command_spec.dart';

class ChatEntry {
  final bool fromUser;
  final String text;
  final int applied; // number of commands applied
  final int? undoMark; // controller undo depth right after applying
  final bool isError;
  ChatEntry({required this.fromUser, required this.text, this.applied = 0, this.undoMark, this.isError = false});
}

/// The AI edit assistant: sends the request plus a compact project
/// description to the model, applies the returned commands as one undo
/// step, and retries automatically if a command is rejected.
class EditAgent {
  final EditorController c;
  final List<ChatEntry> log = [];
  final List<AiMessage> _history = [];
  final Map<String, Uint8List> _thumbCache = {};
  bool busy = false;

  EditAgent(this.c);

  Future<ChatEntry> send(String request) async {
    busy = true;
    log.add(ChatEntry(fromUser: true, text: request));
    try {
      final s = await AiSettings.load();
      final images = s.shareMedia ? await _thumbnails() : <Uint8List>[];
      final state = jsonEncode(projectSummary(c));
      final userMsg = AiMessage(
        'user',
        '$request\n\nCURRENT PROJECT (JSON):\n$state'
        '${images.isEmpty ? '' : '\n\nAttached images are thumbnails of the media, in the order of "media" above (only media with "thumb": true).'}',
        images: images,
      );
      final convo = [..._history.takeLast(8), userMsg];

      String? lastError;
      for (int attempt = 0; attempt < 3; attempt++) {
        final raw = await AiClient.complete(s: s, system: commandSpec, messages: convo);
        final parsed = _parse(raw);
        final reply = (parsed['reply'] as String?)?.trim() ?? '';
        final cmds = (parsed['commands'] as List?) ?? const [];
        if (cmds.isEmpty) {
          return _finish(request, raw, ChatEntry(fromUser: false, text: reply.isEmpty ? 'Done.' : reply));
        }
        try {
          c.run({'op': 'batch', 'commands': cmds});
          return _finish(
            request,
            raw,
            ChatEntry(
              fromUser: false,
              text: reply.isEmpty ? 'Applied the changes.' : reply,
              applied: cmds.length,
              undoMark: c.undoDepth,
            ),
          );
        } on CommandError catch (e) {
          lastError = e.message;
          convo
            ..add(AiMessage('assistant', raw))
            ..add(AiMessage('user',
                'Those commands were rejected and nothing was changed. Error: ${e.message}\nReturn the full corrected JSON.'));
        }
      }
      return _finish(request, null,
          ChatEntry(fromUser: false, text: 'I couldn\'t apply that edit: $lastError', isError: true));
    } on AiException catch (e) {
      return _finish(request, null, ChatEntry(fromUser: false, text: e.message, isError: true));
    } on SocketException {
      return _finish(request, null, ChatEntry(fromUser: false, text: 'No internet connection.', isError: true));
    } catch (e) {
      return _finish(request, null, ChatEntry(fromUser: false, text: 'Something went wrong: $e', isError: true));
    } finally {
      busy = false;
    }
  }

  ChatEntry _finish(String request, String? raw, ChatEntry entry) {
    log.add(entry);
    if (raw != null) {
      _history
        ..add(AiMessage('user', request))
        ..add(AiMessage('assistant', raw));
    }
    return entry;
  }

  static Map<String, dynamic> _parse(String raw) {
    var t = raw.trim();
    final start = t.indexOf('{');
    final end = t.lastIndexOf('}');
    if (start >= 0 && end > start) t = t.substring(start, end + 1);
    try {
      final j = jsonDecode(t);
      if (j is Map<String, dynamic>) return j;
    } catch (_) {}
    return {'reply': raw, 'commands': []};
  }

  Future<List<Uint8List>> _thumbnails() async {
    final out = <Uint8List>[];
    for (final m in c.project.media.values) {
      if (out.length >= 8) break;
      final cached = _thumbCache[m.id];
      if (cached != null) {
        out.add(cached);
        continue;
      }
      Uint8List? bytes;
      try {
        if (m.type == MediaType.image) {
          final codec = await ui.instantiateImageCodec(await File(m.path).readAsBytes(), targetWidth: 512);
          final frame = await codec.getNextFrame();
          final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
          bytes = data?.buffer.asUint8List();
          frame.image.dispose();
        } else if (m.type == MediaType.video) {
          bytes = await MediaBridge.thumbnailJpeg(m.path, m.duration / 2);
        }
      } catch (_) {}
      if (bytes != null) {
        _thumbCache[m.id] = bytes;
        out.add(bytes);
      }
    }
    return out;
  }

  /// Compact, model-friendly description of the project.
  static Map<String, dynamic> projectSummary(EditorController c) {
    final comp = c.comp;
    String r(double v) => v.toStringAsFixed(2);
    dynamic prop(Layer l, String k) {
      final p = l.props[k];
      if (p == null) return null;
      if (p.isAnimated) return {'keys': p.keyframes.map((k) => {'t': r(k.time), 'v': k.value.map((e) => e.round()).toList()}).toList()};
      return p.staticValue.map((e) => double.parse(e.toStringAsFixed(1))).toList();
    }

    int thumbIndex = 0;
    return {
      'comp': {
        'width': comp.width,
        'height': comp.height,
        'fps': comp.fps,
        'duration': r(comp.duration),
        'playhead': r(c.time),
      },
      'camera': {'mode': comp.camera.mode.name, 'keyframes': comp.camera.allKeyframeTimes().length},
      'media': [
        for (final m in c.project.media.values)
          {
            'id': m.id,
            'type': m.type.name,
            'name': m.name,
            'size': [m.width.round(), m.height.round()],
            if (m.duration > 0) 'duration': r(m.duration),
            if (m.type != MediaType.audio && thumbIndex++ < 8) 'thumb': true,
          },
      ],
      'layers_top_to_bottom': [
        for (final l in comp.layers)
          {
            'id': l.id,
            'name': l.name,
            'type': l.type.name,
            'start': r(l.start),
            'end': r(l.end),
            if (l.mediaId != null) 'media': l.mediaId,
            if (l.is3D) 'is3d': true,
            if (!l.visible) 'hidden': true,
            if (l.parentId != null) 'parent': l.parentId,
            if (l.type == LayerType.text) 'text': l.text?.text,
            if (l.type == LayerType.text && l.text?.animator != 'none') 'animator': l.text?.animator,
            'size': [l.width.round(), l.height.round()],
            'position': prop(l, Props.position),
            'scale': prop(l, Props.scale),
            if (l.prop(Props.rotation).isAnimated || l.prop(Props.rotation).staticValue.any((v) => v != 0))
              'rotation': prop(l, Props.rotation),
            'opacity': prop(l, Props.opacity),
            if (l.effects.isNotEmpty) 'effects': [for (final e in l.effects) '${e.id}:${e.type}'],
            if (l.masks.isNotEmpty) 'masks': [for (final m in l.masks) '${m.id}:${m.shape}'],
          },
      ],
    };
  }
}

extension<T> on List<T> {
  List<T> takeLast(int n) => length <= n ? List.of(this) : sublist(length - n);
}
