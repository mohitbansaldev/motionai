import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;

import '../ai/ai_client.dart';
import '../ai/ai_settings.dart';
import '../core/commands/edit_commands.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../core/presets/motion_presets.dart';
import '../director/director.dart';
import '../director/story_builder.dart';
import '../services/media_bridge.dart';
import '../services/media_importer.dart';
import '../state/editor_controller.dart';
import 'common.dart';
import 'preview/composition_canvas.dart';
import 'theme.dart';

/// Director mode: give it your material and a brief, get a finished edit.
class DirectorScreen extends StatefulWidget {
  final EditorController c;
  const DirectorScreen({super.key, required this.c});

  static Future<void> open(BuildContext context, EditorController c) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => DirectorScreen(c: c)));

  @override
  State<DirectorScreen> createState() => _DirectorScreenState();
}

enum _Step { understand, voice, plan, tools, build, review }

class _DirectorScreenState extends State<DirectorScreen> {
  final o = DirectorInput();
  final _brief = TextEditingController();
  final _script = TextEditingController();
  final _notes = TextEditingController();
  final _boundary = GlobalKey();
  bool _checkFirst = false;
  bool _busy = false;
  _Step? _step;
  final Set<_Step> _done = {};
  String _status = '';
  String? _error;
  String? _summary;
  List<Beat> _beats = [];
  BuildOptions? _opts;
  String _look = 'cinematic_doc';
  NarrationResult? _narration;
  String? _snapshot;
  double _time = 0;
  Map<String, ui.Image> _frames = {};

  EditorController get c => widget.c;
  Project get p => c.project;

  @override
  void initState() {
    super.initState();
    AiSettings.load().then((s) {
      if (!mounted) return;
      setState(() {
        _notes.text = s.styleNotes;
        o.language = s.captionLanguage;
        o.roman = s.captionsRoman;
      });
    });
    final videos = _media(MediaType.video);
    final audio = _media(MediaType.audio);
    if (videos.isNotEmpty) {
      o.arollMedia = videos.first.id;
    } else if (audio.isNotEmpty) {
      o.narration = Narration.voiceover;
      o.voiceMedia = audio.first.id;
    } else {
      o.narration = Narration.phoneVoice;
    }
  }

  @override
  void dispose() {
    for (final f in _frames.values) {
      f.dispose();
    }
    super.dispose();
  }

  List<MediaAsset> _media(MediaType t) =>
      p.media.values.where((m) => m.type == t && !m.name.startsWith('SFX ') && !m.name.startsWith('Voice ')).toList();

  Future<void> _import(MediaType t) async {
    final imp = MediaImporter(c.storage);
    final got = await imp.pick(kind: t);
    for (final m in got) {
      p.media[m.id] = m;
    }
    c.mediaChanged();
    if (!mounted) return;
    setState(() {
      if (t == MediaType.video && o.arollMedia == null && got.isNotEmpty) o.arollMedia = got.first.id;
    });
    if (imp.errors.isNotEmpty) showSnack(context, imp.errors.join('\n'));
  }

  // ------------------------------------------------------------ pipeline

  void _set(_Step s) => setState(() {
        if (_step != null) _done.add(_step!);
        _step = s;
      });

  Future<void> _direct() async {
    final s = await AiSettings.load();
    if (!s.isConfigured) {
      if (mounted) showSnack(context, 'Connect ChatGPT or add an API key in the AI tab first.');
      return;
    }
    s.styleNotes = _notes.text.trim();
    await s.save();
    o
      ..brief = _brief.text.trim()
      ..script = _script.text.trim();
    setState(() {
      _busy = true;
      _error = null;
      _summary = null;
      _done.clear();
      _beats = [];
    });
    _snapshot = ProjectSnapshot.take(p);
    c.beginGesture();
    final d = Director(c, (msg) {
      if (mounted) setState(() => _status = msg);
    });
    try {
      _set(_Step.understand);
      await d.understandMedia();
      _set(_Step.voice);
      _narration = await d.narrate(o);
      _set(_Step.plan);
      final (beats, look) = await d.plan(o, _narration!);
      _beats = beats;
      _look = o.look == 'auto' ? look : o.look;
      if (_checkFirst) {
        setState(() {
          _busy = false;
          _status = 'Storyboard ready: ${beats.length} shots. Untick anything you don\'t want, then Build.';
        });
        return;
      }
      await _finish(d);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _finish(Director d) async {
    setState(() => _busy = true);
    try {
      _set(_Step.tools);
      _opts = await d.prepare(_beats, o, _narration!, _look);
      _set(_Step.build);
      setState(() => _status = 'Building the timeline…');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final dropped = d.build(_beats, _opts!);
      var notes = '';
      if (o.review) {
        _set(_Step.review);
        try {
          notes = await d.review(_beats, _render);
        } catch (e) {
          notes = 'Review skipped: $e';
        }
      }
      _done.add(_step!);
      c.endGesture();
      final kept = _beats.where((b) => b.keep).length;
      setState(() {
        _busy = false;
        _step = null;
        _summary = 'Built ${formatTime(c.comp.duration, c.comp.fps)} with $kept shots'
            '${dropped > 0 ? ' ($dropped skipped)' : ''}. One Undo removes everything.'
            '${notes.isEmpty ? '' : '\n\nDirector\'s notes: $notes'}';
      });
    } catch (e) {
      _fail(e);
    }
  }

  void _fail(Object e) {
    if (_snapshot != null) ProjectSnapshot.restore(p, _snapshot!);
    c.endGesture();
    c.mediaChanged();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = e is AiException ? e.message : 'Something went wrong: $e';
    });
  }

  /// Renders frames of the edit (the preview card below) for the review.
  Future<List<(double, Uint8List)>> _render(List<double> times) async {
    final out = <(double, Uint8List)>[];
    try {
      for (final l in c.comp.layers) {
        if (l.type != LayerType.image) continue;
        final a = p.media[l.mediaId];
        if (a == null || !times.any(l.isActiveAt)) continue;
        if (!mounted) return out;
        await precacheImage(ResizeImage(FileImage(File(a.path)), width: math.min(l.width.round(), 2560)), context);
      }
      for (final t in times) {
        final frames = <String, ui.Image>{};
        for (final l in c.comp.layers) {
          if (l.type != LayerType.video || !l.isActiveAt(t)) continue;
          final a = p.media[l.mediaId];
          if (a == null) continue;
          final f = await MediaBridge.readerFrame('dir_${l.id}', a.path, l.sourceTimeAt(t).clamp(0.0, a.duration), maxSize: 720);
          if (f == null) continue;
          final done = Completer<ui.Image>();
          ui.decodeImageFromPixels(f.$3, f.$1, f.$2, ui.PixelFormat.rgba8888, done.complete);
          frames[l.id] = await done.future;
        }
        if (!mounted) return out;
        final old = _frames;
        setState(() {
          _time = t;
          _frames = frames;
        });
        await WidgetsBinding.instance.endOfFrame;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await WidgetsBinding.instance.endOfFrame;
        for (final img in old.values) {
          img.dispose();
        }
        final ro = _boundary.currentContext?.findRenderObject();
        if (ro is! RenderRepaintBoundary) continue;
        final short = math.min(ro.size.width, ro.size.height);
        final image = await ro.toImage(pixelRatio: 540 / math.max(1, short));
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (png != null) out.add((t, png.buffer.asUint8List()));
      }
    } finally {
      await MediaBridge.readerReleaseAll().catchError((_) {});
    }
    return out;
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Director')),
        body: LayoutBuilder(builder: (context, box) {
          final wide = box.maxWidth > 760;
          final form = ListView(padding: const EdgeInsets.all(16), children: _form());
          final side = _sidePanel();
          if (wide) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 3, child: form),
              SizedBox(width: math.min(420, box.maxWidth * 0.4), child: ListView(padding: const EdgeInsets.all(16), children: side)),
            ]);
          }
          return ListView(padding: const EdgeInsets.all(16), children: [..._form(), const SizedBox(height: 8), ...side]);
        }),
      ),
    );
  }

  Widget _section(String title, String? hint, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            if (hint != null) ...[
              const SizedBox(height: 3),
              Text(hint, style: const TextStyle(color: MA.textDim, fontSize: 12)),
            ],
            const SizedBox(height: 10),
            ...children,
          ]),
        ),
      );

  List<Widget> _form() {
    final images = _media(MediaType.image), videos = _media(MediaType.video), audio = _media(MediaType.audio);
    final described = p.media.values.where((m) => m.description.isNotEmpty).length;
    final enabled = !_busy;
    return [
      const Text(
        'Give the Director your photos, clips, voice and a brief. It looks at every picture, listens to the voice, '
        'plans a shot for each line, cuts out subjects for 3D depth, adds sound effects, ducks music under the voice, '
        'writes captions — then watches the result and fixes problems.',
        style: TextStyle(color: MA.textDim, fontSize: 12.5),
      ),
      const SizedBox(height: 12),
      _section('1 · Material', '${images.length} photos · ${videos.length} videos · ${audio.length} audio · $described described by AI', [
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: enabled ? () => _import(MediaType.image) : null, icon: const Icon(Icons.photo_library_outlined, size: 18), label: const Text('Photos')),
          OutlinedButton.icon(onPressed: enabled ? () => _import(MediaType.video) : null, icon: const Icon(Icons.video_library_outlined, size: 18), label: const Text('Videos')),
          OutlinedButton.icon(onPressed: enabled ? () => _import(MediaType.audio) : null, icon: const Icon(Icons.library_music_outlined, size: 18), label: const Text('Voice / music')),
        ]),
      ]),
      _section('2 · Voice', 'Where the narration comes from. Speech is transcribed on your phone — no API key needed.', [
        SegmentedButton<Narration>(
          segments: const [
            ButtonSegment(value: Narration.aroll, label: Text('Presenter'), icon: Icon(Icons.person_outline)),
            ButtonSegment(value: Narration.voiceover, label: Text('Voice-over'), icon: Icon(Icons.mic_none)),
            ButtonSegment(value: Narration.phoneVoice, label: Text('AI voice'), icon: Icon(Icons.record_voice_over_outlined)),
            ButtonSegment(value: Narration.silent, label: Text('None'), icon: Icon(Icons.voice_over_off_outlined)),
          ],
          selected: {o.narration},
          showSelectedIcon: false,
          onSelectionChanged: enabled ? (v) => setState(() => o.narration = v.first) : null,
        ),
        const SizedBox(height: 10),
        if (o.narration == Narration.aroll)
          _pick('Talking-head video', videos, o.arollMedia, (v) => o.arollMedia = v),
        if (o.narration == Narration.voiceover)
          _pick('Voice-over audio', audio, o.voiceMedia, (v) => o.voiceMedia = v),
        if (o.narration == Narration.phoneVoice)
          const Text('Your script is read aloud by the phone\'s own voice (Hindi or English). '
              'Great for a draft — record your own voice later and swap it in.',
              style: TextStyle(color: MA.textDim, fontSize: 12)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          for (final (code, label) in const [('hi', 'Hindi'), ('en', 'English'), ('auto', 'Auto')])
            ChoiceChip(label: Text(label), selected: o.language == code, onSelected: enabled ? (_) => setState(() => o.language = code) : null),
        ]),
      ]),
      _section('3 · Story', o.narration == Narration.aroll || o.narration == Narration.voiceover
          ? 'The brief tells the Director what the video is about and what matters.'
          : 'Paste your script — or leave it empty and the AI writes one from the brief and your media.', [
        TextField(
          controller: _brief,
          enabled: enabled,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(hintText: 'Brief: e.g. "Why Sri Lanka went bankrupt — serious tone, show the maps and the numbers"'),
        ),
        if (o.narration == Narration.phoneVoice || o.narration == Narration.silent) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _script,
            enabled: enabled,
            minLines: 4,
            maxLines: 12,
            decoration: const InputDecoration(hintText: 'Script (optional)…'),
          ),
          Row(children: [
            const Text('Length if AI writes', style: TextStyle(color: MA.textDim, fontSize: 12.5)),
            Expanded(
              child: Slider(
                value: o.minutes.toDouble(),
                min: 1,
                max: 12,
                divisions: 11,
                label: '${o.minutes} min',
                onChanged: enabled ? (v) => setState(() => o.minutes = v.round()) : null,
              ),
            ),
            Text('${o.minutes} min'),
          ]),
        ],
      ]),
      _section('4 · Style', 'Your channel\'s rules — the Director follows these over its defaults. Saved for next time.', [
        TextField(
          controller: _notes,
          enabled: enabled,
          minLines: 2,
          maxLines: 6,
          decoration: const InputDecoration(
              hintText: 'e.g. "B-roll on every sentence. Red circles on dates. Dark grunge backgrounds. No shatter transitions. CTA at 70%."'),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: o.look,
          decoration: const InputDecoration(labelText: 'Look', isDense: true),
          items: [
            const DropdownMenuItem(value: 'auto', child: Text('Let the Director choose')),
            for (final st in MotionPresets.styles) DropdownMenuItem(value: st, child: Text(MotionPresets.styleLabel(st))),
          ],
          onChanged: enabled ? (v) => setState(() => o.look = v ?? 'auto') : null,
        ),
      ]),
      _section('5 · Finishing', null, [
        _pick('Background music (optional)', audio, o.musicMedia, (v) => o.musicMedia = v, allowNone: true),
        _switch('Captions', 'Word-by-word, from the voice', o.captions, (v) => o.captions = v),
        if (o.captions && o.language != 'en') _switch('Hinglish (Roman script)', null, o.roman, (v) => o.roman = v),
        _switch('Sound effects', 'Whoosh on cuts, hits on numbers', o.sfx, (v) => o.sfx = v),
        _switch('3D depth shots', 'Cuts out subjects on your phone', o.depth, (v) => o.depth = v),
        _switch('Review & fix', 'The AI watches rendered frames and fixes problems', o.review, (v) => o.review = v),
        _switch('Let me check the storyboard first', null, _checkFirst, (v) => _checkFirst = v),
      ]),
      const SizedBox(height: 4),
      if (_beats.isNotEmpty && !_busy && _checkFirst && _summary == null && _error == null)
        GradientButton(
          label: 'Build ${_beats.where((b) => b.keep).length} shots',
          icon: Icons.movie_creation_outlined,
          onTap: () => _finish(Director(c, (m) {
            if (mounted) setState(() => _status = m);
          })),
        )
      else
        GradientButton(label: _busy ? 'Directing…' : 'Direct my video', icon: Icons.movie_filter_outlined, onTap: _busy ? null : _direct),
      const SizedBox(height: 24),
    ];
  }

  Widget _pick(String label, List<MediaAsset> list, String? value, void Function(String?) set, {bool allowNone = false}) {
    final v = list.any((m) => m.id == value) ? value : null;
    return DropdownButtonFormField<String?>(
      initialValue: v,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, isDense: true),
      items: [
        if (allowNone || list.isEmpty) const DropdownMenuItem<String?>(value: null, child: Text('None')),
        for (final m in list) DropdownMenuItem<String?>(value: m.id, child: Text(m.name, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: _busy ? null : (x) => setState(() => set(x)),
    );
  }

  Widget _switch(String title, String? sub, bool value, void Function(bool) set) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(title),
        subtitle: sub == null ? null : Text(sub, style: const TextStyle(fontSize: 11.5)),
        value: value,
        onChanged: _busy ? null : (x) => setState(() => set(x)),
      );

  List<Widget> _sidePanel() {
    final comp = c.comp;
    final aspect = comp.width / comp.height;
    const steps = {
      _Step.understand: 'Looking at your media',
      _Step.voice: 'Listening to the voice',
      _Step.plan: 'Planning every shot',
      _Step.tools: 'Cut-outs & sound effects',
      _Step.build: 'Building the timeline',
      _Step.review: 'Watching & fixing',
    };
    return [
      // Live preview — also the render target for the review step.
      Center(
        child: SizedBox(
          height: 240,
          child: AspectRatio(
            aspectRatio: aspect,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: RepaintBoundary(
                key: _boundary,
                child: FittedBox(fit: BoxFit.contain, child: CompositionCanvas(project: p, time: _time, videoFrames: _frames)),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 12),
      for (final e in steps.entries)
        if (e.key != _Step.review || o.review)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: _done.contains(e.key)
                ? const Icon(Icons.check_circle, color: Colors.greenAccent, size: 20)
                : _step == e.key && _busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.radio_button_unchecked, color: MA.textDim, size: 20),
            title: Text(e.value, style: TextStyle(color: _step == e.key || _done.contains(e.key) ? MA.text : MA.textDim)),
            subtitle: _step == e.key && _busy && _status.isNotEmpty ? Text(_status, style: const TextStyle(fontSize: 11.5)) : null,
          ),
      if (!_busy && _status.isNotEmpty && _summary == null && _error == null)
        Text(_status, style: const TextStyle(color: MA.textDim)),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ),
      if (_summary != null) ...[
        const SizedBox(height: 8),
        Text(_summary!, style: const TextStyle(color: MA.text)),
        const SizedBox(height: 10),
        FilledButton.icon(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.play_arrow), label: const Text('Open the edit')),
      ],
      if (_beats.isNotEmpty) ...[
        const SizedBox(height: 12),
        const Text('Storyboard', style: TextStyle(fontWeight: FontWeight.w800)),
        for (final b in _beats)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: b.keep,
            onChanged: _busy || _summary != null ? null : (v) => setState(() => b.keep = v ?? true),
            title: Text(b.line, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
            subtitle: Text('${formatTime(b.start, 30)} · ${describeVisual(b.visual, p)}', style: const TextStyle(fontSize: 11)),
          ),
      ],
    ];
  }

  static String describeVisual(Map<String, dynamic> v, Project p) {
    if (v['aroll'] == true) return v['punch'] == true ? 'Presenter · punch-in' : 'Presenter';
    if (v['component'] == null) {
      final m = p.media[v['media']];
      final what = m == null ? 'Photo/video' : m.name;
      return '$what · ${'${v['move'] ?? 'ken_burns'}'.replaceAll('_', ' ')}${v['behind_text'] != null ? ' · "${v['behind_text']}" behind' : ''}';
    }
    final detail = v['headline'] ?? v['label'] ?? v['text'] ?? v['focus'] ?? v['to'] ?? '';
    return '${v['component']}'.replaceAll('_', ' ') + (detail == '' ? '' : ' · $detail');
  }
}
