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
import '../director/capabilities.dart';
import '../director/chapters.dart';
import '../director/director.dart';
import '../director/planner.dart';
import '../director/story_builder.dart';
import '../director/storyboard.dart';
import '../director/variety.dart';
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
  String _look = 'cinematic_doc';
  NarrationResult? _narration;
  String? _snapshot;
  double _time = 0;
  Map<String, ui.Image> _frames = {};
  Storyboard? _sb; // the storyboard being planned/built (Director v2)
  Storyboard? _saved; // an unfinished storyboard that can be resumed
  CancelToken? _cancel;
  int? _activeChapter;
  VarietyReport? _variety;

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
    _loadSaved();
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

  Director _director() => Director(c, (msg) {
        if (mounted) setState(() => _status = msg);
      });

  Future<void> _loadSaved() async {
    final sb = await _director().loadStoryboard();
    if (!mounted || sb == null || sb.lines.isEmpty) return;
    setState(() {
      if (sb.stage == 'built') {
        // A finished build: chapters can be rebuilt one by one.
        if (c.comp.layers.any((l) => l.id.startsWith('d${sb.tag}c'))) {
          _sb = sb;
          _beats = sb.beats;
          Director.applyInput(o, sb.input);
          _brief.text = o.brief;
          _script.text = o.script;
        }
      } else {
        _saved = sb;
      }
    });
  }

  Future<void> _discardSaved() async {
    await _director().discardStoryboard();
    if (mounted) setState(() => _saved = null);
  }

  void _cancelRun() {
    _cancel?.cancel();
    setState(() => _status = 'Stopping after this step…');
  }

  Future<void> _direct({Storyboard? resume}) async {
    final s = await AiSettings.load();
    if (!s.isConfigured) {
      if (mounted) showSnack(context, 'Connect ChatGPT or add an API key in the AI tab first.');
      return;
    }
    s.styleNotes = _notes.text.trim();
    await s.save();
    if (resume != null) {
      Director.applyInput(o, resume.input);
      _brief.text = o.brief;
      _script.text = o.script;
    } else {
      o
        ..brief = _brief.text.trim()
        ..script = _script.text.trim();
    }
    final cancel = CancelToken();
    setState(() {
      _busy = true;
      _error = null;
      _summary = null;
      _done.clear();
      _beats = [];
      _sb = resume;
      _saved = null;
      _cancel = cancel;
      _variety = null;
    });
    _snapshot = ProjectSnapshot.take(p);
    c.beginGesture();
    final d = _director();
    try {
      _set(_Step.understand);
      await d.understandMedia();
      cancel.check();
      _set(_Step.voice);
      _narration = resume != null && resume.lines.isNotEmpty ? await d.resumeNarration(resume, o) : await d.narrate(o);
      cancel.check();
      _set(_Step.plan);
      final sb = await d.planStoryboard(o, _narration!, resume: resume, cancel: cancel, onProgress: (sb) {
        if (mounted) setState(() => _sb = sb);
      });
      _sb = sb;
      _beats = sb.beats;
      _look = o.look == 'auto' ? sb.look : o.look;
      _variety = d.variety;
      if (_checkFirst) {
        c.endGesture();
        setState(() {
          _busy = false;
          _status = 'Storyboard ready: ${sb.chapters.length} chapters, ${_beats.length} shots. Untick anything you don\'t want, then Build.';
        });
        return;
      }
      await _finish(d);
    } on DirectorCancelled {
      _fail('Stopped. Your storyboard is saved — tap Resume to continue where it stopped.', stopped: true);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _finish(Director d) async {
    final sb = _sb;
    if (sb == null) return;
    final cancel = _cancel ?? CancelToken();
    setState(() {
      _busy = true;
      _cancel = cancel;
    });
    if (_checkFirst) c.beginGesture();
    try {
      _set(_Step.tools);
      final opts = await d.prepare(_beats, o, _narration!, _look);
      opts
        ..tag = sb.tag
        ..chapters = sb.chapters
        ..caps = Capabilities();
      cancel.check();
      _set(_Step.build);
      setState(() => _status = 'Building ${sb.chapters.length} chapters…');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final dropped = d.build(_beats, opts);
      for (final ch in sb.chapters) {
        ch.status = 'built';
      }
      sb.stage = 'built';
      await d.saveStoryboard(sb);
      var notes = '';
      if (o.review) {
        _set(_Step.review);
        try {
          notes = await d.reviewChapters(sb, _render, cancel: cancel, onChapter: (k) {
            if (mounted) setState(() => _activeChapter = k);
          });
        } on DirectorCancelled {
          notes = 'Review stopped.';
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
        _activeChapter = null;
        _cancel = null;
        _summary = 'Built ${formatTime(c.comp.duration, c.comp.fps)} in ${sb.chapters.length} chapters with $kept shots'
            '${dropped > 0 ? ' ($dropped skipped)' : ''}. One Undo removes everything. '
            'Tap "Rebuild" on a chapter to redo only that part.'
            '${notes.isEmpty ? '' : '\n\nDirector\'s notes:\n$notes'}';
      });
    } on DirectorCancelled {
      _fail('Stopped before the build. Your storyboard is saved — tap Resume to build it.', stopped: true);
    } catch (e) {
      _fail(e);
    }
  }

  /// Keeps the narration when a storyboard is saved (so Resume can use it);
  /// otherwise everything goes back to how it was.
  void _fail(Object e, {bool stopped = false}) {
    final resumable = _sb != null && _sb!.outlined && _sb!.stage != 'built';
    if (!resumable && _snapshot != null) ProjectSnapshot.restore(p, _snapshot!);
    c.endGesture();
    c.mediaChanged();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _cancel = null;
      _activeChapter = null;
      if (resumable) _saved = _sb;
      final msg = e is AiException ? e.message : (e is String ? e : 'Something went wrong: $e');
      _error = resumable && !stopped ? '$msg\nYour storyboard is saved — tap Resume to try again from this chapter.' : msg;
    });
  }

  Future<void> _rebuild(int chapter) async {
    final sb = _sb;
    if (sb == null) return;
    final ch = sb.chapters.firstWhere((x) => x.index == chapter);
    final note = TextEditingController();
    var replan = true;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('Rebuild chapter ${chapter + 1}: ${ch.title}'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Only this chapter changes; the rest of the edit stays as it is.', style: TextStyle(color: MA.textDim, fontSize: 12.5)),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Plan new shots with the AI'),
              subtitle: const Text('Off: rebuild the shots as they are planned', style: TextStyle(fontSize: 11.5)),
              value: replan,
              onChanged: (v) => setD(() => replan = v),
            ),
            if (replan)
              TextField(
                controller: note,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(hintText: 'What should change? e.g. "more maps, less presenter, no glow words"'),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Rebuild')),
          ],
        ),
      ),
    );
    final text = note.text;
    note.dispose();
    if (go != true || !mounted) return;
    final cancel = CancelToken();
    setState(() {
      _busy = true;
      _error = null;
      _summary = null;
      _cancel = cancel;
      _activeChapter = chapter;
      _status = 'Rebuilding chapter ${chapter + 1}…';
    });
    final d = _director();
    try {
      final dropped = await d.rebuildChapter(sb, chapter, o, note: text, replan: replan, cancel: cancel);
      var notes = '';
      if (o.review) {
        try {
          notes = await d.reviewChapters(sb, _render, only: {chapter}, cancel: cancel);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _cancel = null;
        _activeChapter = null;
        _beats = sb.beats;
        _variety = d.variety ?? _variety;
        _summary = 'Chapter ${chapter + 1} rebuilt with ${sb.beatsOf(chapter).where((b) => b.keep).length} shots'
            '${dropped > 0 ? ' ($dropped skipped)' : ''}. Undo brings the old version back.'
            '${notes.isEmpty ? '' : '\n\nDirector\'s notes:\n$notes'}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _cancel = null;
        _activeChapter = null;
        _error = e is DirectorCancelled ? 'Stopped.' : (e is AiException ? e.message : 'Could not rebuild: $e');
      });
    }
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
      if (_saved != null && !_busy) _resumeCard(_saved!),
      if (_beats.isNotEmpty && !_busy && _checkFirst && _summary == null && _error == null && _sb != null && _sb!.stage == 'planned')
        GradientButton(
          label: 'Build ${_beats.where((b) => b.keep).length} shots',
          icon: Icons.movie_creation_outlined,
          onTap: () => _finish(_director()),
        )
      else
        GradientButton(label: _busy ? 'Directing…' : 'Direct my video', icon: Icons.movie_filter_outlined, onTap: _busy ? null : () => _direct()),
      if (_busy) ...[
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _cancel == null || _cancel!.cancelled ? null : _cancelRun,
          icon: const Icon(Icons.stop_circle_outlined, size: 18),
          label: Text(_cancel != null && _cancel!.cancelled ? 'Stopping…' : 'Cancel'),
        ),
      ],
      const SizedBox(height: 24),
    ];
  }

  Widget _resumeCard(Storyboard sb) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Unfinished storyboard', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 3),
            Text(
              '${sb.title.isEmpty ? '' : '"${sb.title}" · '}${sb.plannedChapters}/${sb.chapters.length} chapters planned · '
              '${sb.beats.length} shots · ${formatTime(sb.lines.isEmpty ? 0.0 : sb.lines.last.$2, 30)} of narration',
              style: const TextStyle(color: MA.textDim, fontSize: 12),
            ),
            const SizedBox(height: 10),
            Row(children: [
              FilledButton.icon(onPressed: () => _direct(resume: sb), icon: const Icon(Icons.play_arrow, size: 18), label: const Text('Resume')),
              const SizedBox(width: 8),
              TextButton(onPressed: _discardSaved, child: const Text('Discard')),
            ]),
          ]),
        ),
      );

  List<Widget> _chapterPanel() {
    final sb = _sb;
    if (sb == null || sb.chapters.isEmpty) return const [];
    final built = sb.stage == 'built' && c.comp.layers.any((l) => l.id.startsWith('d${sb.tag}c'));
    final v = _variety;
    return [
      const SizedBox(height: 12),
      Row(children: [
        const Text('Chapters', style: TextStyle(fontWeight: FontWeight.w800)),
        const Spacer(),
        if (v != null)
          Tooltip(
            message: v.issues.isEmpty ? 'No repeats' : v.issues.take(6).map((i) => '${i.rule.replaceAll('_', ' ')}: ${i.detail}').join('\n'),
            child: Text('Variety ${v.score.round()}/100', style: const TextStyle(color: MA.textDim, fontSize: 12)),
          ),
      ]),
      if (sb.title.isNotEmpty) Text(sb.title, style: const TextStyle(color: MA.textDim, fontSize: 12)),
      for (final ch in sb.chapters) _chapterTile(sb, ch, built),
    ];
  }

  Widget _chapterTile(Storyboard sb, Chapter ch, bool built) {
    final (t0, t1) = sb.rangeOf(ch.index);
    final shots = sb.beatsOf(ch.index).where((b) => b.keep).length;
    final active = _busy && (_activeChapter == ch.index || ch.status == 'planning');
    final Widget icon = active
        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
        : switch (ch.status) {
            'built' => const Icon(Icons.check_circle, color: Colors.greenAccent, size: 20),
            'planned' => const Icon(Icons.check_circle_outline, color: MA.accent2, size: 20),
            'failed' => const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
            _ => const Icon(Icons.radio_button_unchecked, color: MA.textDim, size: 20),
          };
    final atm = ch.atmosphere;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: icon,
      title: Text('${ch.index + 1}. ${ch.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${ch.kind.replaceAll('_', ' ')} · ${formatTime(t0, 30)}–${formatTime(t1, 30)}'
        '${shots > 0 ? ' · $shots shots' : ''}${atm == null ? '' : ' · $atm'}'
        '${ch.status == 'failed' && ch.error.isNotEmpty ? '\n${ch.error}' : ''}',
        style: const TextStyle(fontSize: 11),
      ),
      trailing: built && !_busy ? TextButton(onPressed: () => _rebuild(ch.index), child: const Text('Rebuild')) : null,
    );
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
      ..._chapterPanel(),
      if (_beats.isNotEmpty) ...[
        const SizedBox(height: 12),
        const Text('Storyboard', style: TextStyle(fontWeight: FontWeight.w800)),
        for (final (i, b) in _beats.indexed) ...[
          if (_sb != null && _sb!.chapters.length > 1 && (i == 0 || _beats[i - 1].chapter != b.chapter))
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 2),
              child: Text(
                'Chapter ${b.chapter + 1}${b.chapter < _sb!.chapters.length ? ' · ${_sb!.chapters[b.chapter].title}' : ''}',
                style: const TextStyle(color: MA.accent2, fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: b.keep,
            onChanged: _busy || _summary != null || (_sb != null && _sb!.stage == 'built') ? null : (v) => setState(() => b.keep = v ?? true),
            title: Text(b.line, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
            subtitle: Text('${formatTime(b.start, 30)} · ${b.role.isEmpty ? '' : '${b.role} · '}${describeVisual(b.visual, p)}', style: const TextStyle(fontSize: 11)),
          ),
        ],
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
