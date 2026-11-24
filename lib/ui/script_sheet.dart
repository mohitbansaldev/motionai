import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ai/ai_client.dart';
import '../ai/ai_settings.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../core/presets/components.dart';
import '../services/speech.dart';
import '../state/editor_controller.dart';
import 'common.dart';
import 'theme.dart';

class _Beat {
  double start, end;
  String line;
  Map<String, dynamic> visual;
  bool keep = true;
  _Beat(this.start, this.end, this.line, this.visual);
}

/// Script → storyboard → timeline, in the style of a documentary explainer.
class ScriptSheet extends StatefulWidget {
  final EditorController c;
  const ScriptSheet({super.key, required this.c});

  static Future<void> open(BuildContext context, EditorController c) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ScriptSheet(c: c)));

  @override
  State<ScriptSheet> createState() => _ScriptSheetState();
}

class _ScriptSheetState extends State<ScriptSheet> {
  final _script = TextEditingController();
  String? _aroll; // layer id of the talking-head video
  List<_Beat> _beats = [];
  String? _status;
  bool _busy = false;

  EditorController get c => widget.c;

  static const _prompt = r'''
You are a documentary B-roll planner for a Hindi/English explainer YouTube channel (presenter on camera, visuals for almost every line).
Input: script lines with start/end seconds, the available media, and the frame size.
For EACH line choose ONE visual. Return ONLY JSON: {"beats":[{"i":<line index>,"visual":{...}}]}
Visual options:
- {"aroll":true}  (stay on the presenter; use for opinions, transitions, jokes, calls to action — about 30% of lines)
- {"media":"<media id>","move":"push_in|ken_burns|parallax"}  (show a photo/video that fits the line)
- {"component":"source_card","source":"Source: <site>","headline":"...","body":"<the cited claim, 1-3 sentences>","highlights":["<key phrase from body>"],"circle":"<date or number from body>"}  (when the line cites a book, article, report or "according to")
- {"component":"lower_third","source":"Source: <site>","text":"...","highlights":["..."]}
- {"component":"map","countries":["<country names>"],"focus":"<country>","style":"dark|paper|blue"}  (when a place/country is mentioned)
- {"component":"badge","label":"<ORGANISATION / PARTY / GROUP>","media":"<optional media id>"}  (organisations, parties, agencies)
- {"component":"counter","from":0,"to":<number>,"prefix":"$ or ₹ or ''","suffix":" BARRELS / % / CRORE …"}  (when a big number is said)
- {"component":"timeline","from":<decade start>,"to":<decade end>,"marker":<year>,"label":"<MON YYYY>"}  (when a date/year matters)
- {"component":"glow_word","text":"<ONE KEY WORD>"}  (a dramatic single word)
- {"component":"speech_bubble","text":"\"<short quote>\""}  (a quoted statement)
- {"component":"photo_card","media":"<image id>","caption":"<name>"}  (a person or object introduced)
Rules: never invent media ids; vary visuals; keep text short and factual; only use information present in the script line (do not add facts).
''';

  Future<void> _plan() async {
    setState(() {
      _busy = true;
      _status = 'Reading the script…';
      _beats = [];
    });
    try {
      final s = await AiSettings.load();
      var lines = <(double, double, String)>[];
      final aroll = _aroll == null ? null : c.comp.layerById(_aroll!);
      if (_script.text.trim().isEmpty && aroll != null) {
        lines = await _transcribe(aroll, s);
      } else {
        lines = _split(_script.text, aroll?.start ?? c.time);
      }
      if (lines.isEmpty) throw AiException('Paste a script or choose your talking-head video.');
      setState(() => _status = 'Planning ${lines.length} beats…');
      final media = [
        for (final m in c.project.media.values)
          if (m.type != MediaType.audio) {'id': m.id, 'type': m.type.name, 'name': m.name},
      ];
      final payload = {
        'frame': [c.comp.width, c.comp.height],
        'media': media,
        'lines': [for (int i = 0; i < lines.length; i++) {'i': i, 'start': lines[i].$1, 'end': lines[i].$2, 'text': lines[i].$3}],
      };
      final raw = await AiClient.complete(s: s, system: _prompt, messages: [AiMessage('user', jsonEncode(payload))]);
      final start = raw.indexOf('{'), end = raw.lastIndexOf('}');
      final j = jsonDecode(raw.substring(start, end + 1)) as Map<String, dynamic>;
      final beats = <_Beat>[];
      for (final b in (j['beats'] as List? ?? [])) {
        final m = b as Map<String, dynamic>;
        final i = (m['i'] as num?)?.toInt() ?? -1;
        if (i < 0 || i >= lines.length) continue;
        beats.add(_Beat(lines[i].$1, lines[i].$2, lines[i].$3, Map<String, dynamic>.from(m['visual'] as Map? ?? {'aroll': true})));
      }
      setState(() {
        _beats = beats;
        _status = 'Storyboard ready — untick anything you don\'t want, then Build.';
      });
    } on AiException catch (e) {
      setState(() => _status = e.message);
    } catch (e) {
      setState(() => _status = 'Planning failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Splits a script into sentences with estimated timings (~2.6 words/s).
  List<(double, double, String)> _split(String text, double t0) {
    final parts = text
        .replaceAll('\n', ' ')
        .split(RegExp(r'(?<=[.!?।])\s+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    var t = t0;
    return [
      for (final p in parts)
        () {
          final d = math.max(1.6, p.split(RegExp(r'\s+')).length / 2.6);
          final r = (t, t + d, p);
          t += d;
          return r;
        }(),
    ];
  }

  Future<List<(double, double, String)>> _transcribe(Layer l, AiSettings s) async {
    final m = c.project.media[l.mediaId]!;
    final words = await Speech.words(
      m.path,
      language: s.captionLanguage,
      sourceIn: l.sourceIn,
      duration: l.duration * l.speed,
      onStatus: (msg) {
        if (mounted) setState(() => _status = msg);
      },
    );
    return [
      for (final (a, b, t) in Speech.lines(words))
        (l.start + (a - l.sourceIn) / l.speed, l.start + (b - l.sourceIn) / l.speed, t),
    ].where((e) => e.$1 >= l.start && e.$1 < l.end).toList();
  }

  void _build() {
    final w = c.comp.width, h = c.comp.height;
    final cmds = <Map<String, dynamic>>[];
    var n = 0;
    for (final b in _beats.where((b) => b.keep)) {
      final v = b.visual;
      final dur = math.max(1.2, b.end - b.start);
      final tag = 'sb${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}_${n++}';
      if (v['aroll'] == true) continue;
      final media = v['media'] is String ? c.project.media[v['media']] : null;
      if (v['component'] == null && media != null) {
        final id = '${tag}_m';
        cmds.add({'op': 'add_layer', 'type': media.type == MediaType.video ? 'video' : 'image', 'media': media.id, 'id': id, 'start': b.start, 'duration': dur, 'fit': 'cover'});
        cmds.add({'op': 'animate_in', 'layer': id, 'preset': 'fade', 'duration': 0.3});
        final mv = '${v['move'] ?? 'ken_burns'}';
        cmds.add({'op': 'set_property', 'target': id, 'prop': 'opacity', 'value': 100});
        cmds.add({'op': 'add_effect', 'layer': id, 'effect': 'vignette', 'params': {'amount': 55}});
        if (mv == 'parallax' || mv == 'push_in') {
          cmds.add({'op': 'update_layer', 'layer': id, 'is3d': true});
        }
        // Slow push: scale keyframes relative to the cover scale (applied after add).
        cmds.add({'op': '__kenburns', 'layer': id, 'start': b.start, 'end': b.start + dur});
        continue;
      }
      final type = '${v['component']}';
      if (!Components.types.contains(type)) continue;
      final needsBg = !['map', 'lower_third', 'cta', 'pin', 'route_arrow'].contains(type);
      if (needsBg) {
        final bg = '${tag}_bg';
        cmds.add({'op': 'add_layer', 'type': 'solid', 'id': bg, 'color': '#141414', 'start': b.start, 'duration': dur, 'width': w, 'height': h});
        cmds.add({'op': 'add_effect', 'layer': bg, 'effect': 'grunge', 'params': {'amount': 70}});
        cmds.add({'op': 'add_effect', 'layer': bg, 'effect': 'dust', 'params': {'amount': 35}});
        cmds.add({'op': 'add_effect', 'layer': bg, 'effect': 'vignette', 'params': {'amount': 75}});
      }
      final comp = Map<String, dynamic>.from(v)..remove('component');
      if (comp['media'] != null && c.project.media[comp['media']] == null) comp.remove('media');
      if (type == 'photo_card' && comp['media'] == null) continue;
      cmds.add({'op': 'add_component', 'type': type, 'id': tag, 'start': b.start, 'duration': dur, ...comp});
    }
    // Expand the Ken Burns helper into real keyframes now that cover scales are known.
    final real = <Map<String, dynamic>>[];
    final kb = <Map<String, dynamic>>[];
    for (final cmd in cmds) {
      (cmd['op'] == '__kenburns' ? kb : real).add(cmd);
    }
    final err = c.tryRun({'op': 'batch', 'commands': real});
    if (err != null) {
      setState(() => _status = 'Build failed: $err');
      return;
    }
    for (final k in kb) {
      final l = c.comp.layerById('${k['layer']}');
      if (l == null) continue;
      final s0 = l.prop(Props.scale).staticValue[0];
      c.run({'op': 'batch', 'commands': [
        {'op': 'set_keyframe', 'target': l.id, 'prop': 'scale', 'time': k['start'], 'value': [s0, s0, 100], 'ease': 'linear'},
        {'op': 'set_keyframe', 'target': l.id, 'prop': 'scale', 'time': k['end'], 'value': [s0 * 1.1, s0 * 1.1, 100]},
      ]}, record: false);
    }
    final end = _beats.isEmpty ? 0.0 : _beats.map((b) => b.end).reduce(math.max);
    if (end > c.comp.duration) c.tryRun({'op': 'set_comp', 'duration': end});
    Navigator.pop(context);
    showSnack(context, 'Timeline built from ${_beats.where((b) => b.keep).length} beats. One Undo removes it.');
  }

  IconData _icon(Map<String, dynamic> v) {
    if (v['aroll'] == true) return Icons.person_outline;
    if (v['media'] != null && v['component'] == null) return Icons.image_outlined;
    return switch ('${v['component']}') {
      'map' => Icons.public,
      'source_card' || 'lower_third' => Icons.article_outlined,
      'badge' => Icons.verified_outlined,
      'counter' => Icons.onetwothree,
      'timeline' => Icons.timeline,
      'glow_word' => Icons.flare,
      'speech_bubble' => Icons.chat_bubble_outline,
      'photo_card' => Icons.photo_outlined,
      _ => Icons.widgets_outlined,
    };
  }

  String _describe(Map<String, dynamic> v) {
    if (v['aroll'] == true) return 'Presenter on camera';
    if (v['component'] == null) return 'Photo/video · ${v['move'] ?? 'ken burns'}';
    final t = Components.label('${v['component']}');
    final detail = v['headline'] ?? v['label'] ?? v['text'] ?? v['focus'] ?? v['to'] ?? '';
    return '$t${detail == '' ? '' : ' · $detail'}';
  }

  @override
  Widget build(BuildContext context) {
    final videos = c.comp.layers.where((l) => l.type == LayerType.video).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Script → Video')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Paste your script, or pick your talking-head clip and leave the script empty to transcribe it '
            '(transcribed on your phone). The AI plans a visual for every line. For a full documentary, use Director in the AI tab.',
            style: TextStyle(color: MA.textDim, fontSize: 12.5)),
        const SizedBox(height: 12),
        if (videos.isNotEmpty)
          DropdownButtonFormField<String?>(
            initialValue: _aroll,
            decoration: const InputDecoration(labelText: 'Talking-head video (A-roll, optional)', isDense: true),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('None')),
              for (final v in videos) DropdownMenuItem<String?>(value: v.id, child: Text(v.name, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _aroll = v),
          ),
        const SizedBox(height: 10),
        TextField(
          controller: _script,
          minLines: 6,
          maxLines: 14,
          decoration: const InputDecoration(hintText: 'Paste your script here (Hindi, Hinglish or English)…'),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: _busy ? null : _plan,
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.auto_awesome),
          label: const Text('Plan storyboard'),
        ),
        if (_status != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_status!, style: const TextStyle(color: MA.textDim))),
        for (final b in _beats)
          Card(
            margin: const EdgeInsets.only(top: 8),
            child: CheckboxListTile(
              value: b.keep,
              onChanged: (v) => setState(() => b.keep = v ?? true),
              secondary: Icon(_icon(b.visual), color: MA.accent2),
              title: Text(b.line, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              subtitle: Text('${formatTime(b.start, 30)} · ${_describe(b.visual)}', style: const TextStyle(fontSize: 11.5)),
            ),
          ),
        if (_beats.isNotEmpty) ...[
          const SizedBox(height: 12),
          GradientButton(label: 'Build timeline', icon: Icons.movie_creation_outlined, onTap: _build),
        ],
      ]),
    );
  }
}
