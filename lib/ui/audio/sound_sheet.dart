import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../audio/audio_cache.dart';
import '../../audio/auto_mix.dart';
import '../../audio/music_analysis.dart';
import '../../audio/pcm_source.dart';
import '../../audio/sfx_library.dart';
import '../../core/model/layer.dart';
import '../../core/model/project.dart';
import '../../director/sfx.dart';
import '../../state/editor_controller.dart';

/// Sound design sheet: synthesised SFX browser (preview + insert at the
/// playhead), music analysis with beat markers, beat sync, auto mix and
/// ambience beds. Every change is one edit command (undoable).
class SoundSheet extends StatefulWidget {
  final EditorController c;
  final int initialTab;
  const SoundSheet({super.key, required this.c, this.initialTab = 0});

  /// [tab]: 0 effects, 1 music & beats, 2 mix.
  static Future<void> open(BuildContext context, EditorController c, {int tab = 0}) async {
    SfxLibrary.dir ??= await c.storage.mediaDir();
    if (!context.mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (_, sc) => PrimaryScrollController(controller: sc, child: SoundSheet(c: c, initialTab: tab)),
      ),
    );
  }

  @override
  State<SoundSheet> createState() => _SoundSheetState();
}

class _SoundSheetState extends State<SoundSheet> {
  EditorController get c => widget.c;
  String _category = Sfx.categories.first;
  VideoPlayerController? _preview;
  String? _previewKind;
  String? _status;

  // Music & beats
  String? _musicId;
  MusicAnalysis? _analysis;
  bool _busy = false;
  double _tolerance = 0.25;
  final _bpm = TextEditingController();

  // Mix
  bool _duck = true, _fades = true;
  String _bed = Sfx.beds.first;
  bool _bedWhole = true;
  double _bedSeconds = 10;

  @override
  void initState() {
    super.initState();
    final music = _audioLayers().where((l) => AutoMix.roleOf(c.project, l) == 'music').toList();
    final all = _audioLayers();
    final sel = c.selectedLayer;
    _musicId = sel != null && sel.type == LayerType.audio ? sel.id : (music.isNotEmpty ? music.first.id : (all.isNotEmpty ? all.first.id : null));
    _loadCached();
  }

  @override
  void dispose() {
    _preview?.dispose();
    _bpm.dispose();
    super.dispose();
  }

  List<Layer> _audioLayers() => [for (final l in c.comp.layers) if (l.type == LayerType.audio && l.mediaId != null) l];

  Layer? get _music => _musicId == null ? null : c.comp.layerById(_musicId!);
  MediaAsset? get _musicMedia {
    final l = _music;
    return l?.mediaId == null ? null : c.project.media[l!.mediaId];
  }

  void _loadCached() {
    final m = _musicMedia;
    _analysis = m == null ? null : AudioCache.musicFor(m);
  }

  void _say(String s) {
    if (mounted) setState(() => _status = s);
  }

  void _run(Map<String, dynamic> cmd, String ok) {
    final err = c.tryRun(cmd);
    _say(err ?? ok);
  }

  // ------------------------------------------------------------- effects

  Future<void> _play(String kind) async {
    final old = _preview;
    _preview = null;
    await old?.dispose();
    setState(() => _previewKind = kind);
    try {
      final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}sfx_preview_$kind.wav');
      if (!f.existsSync()) await f.writeAsBytes(Sfx.wav(kind));
      final p = VideoPlayerController.file(f, videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
      _preview = p;
      await p.initialize();
      if (_preview != p) return;
      await p.play();
    } catch (_) {
      _say('Preview is not available on this device — insert it and press play instead.');
    } finally {
      if (mounted) setState(() => _previewKind = null);
    }
  }

  void _insert(String kind) {
    final dur = Sfx.isBed(kind) ? math.min(30.0, math.max(Sfx.length(kind), c.comp.duration - c.time)) : null;
    _run({'op': 'add_sfx', 'kind': kind, 'time': c.time, 'duration': ?dur},
        '${Sfx.info(kind).$1} added${Sfx.peak(kind) > 0 ? ' (its peak lands on the playhead)' : ''}');
  }

  Widget _effects() {
    final kinds = Sfx.all.where((k) => Sfx.info(k).$2 == _category).toList();
    return Column(children: [
      SizedBox(
        height: 46,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
          for (final cat in Sfx.categories)
            Padding(
              padding: const EdgeInsets.all(4),
              child: ChoiceChip(label: Text(cat), selected: cat == _category, onSelected: (_) => setState(() => _category = cat)),
            ),
        ]),
      ),
      Expanded(
        child: ListView(children: [
          for (final k in kinds)
            ListTile(
              dense: true,
              leading: Icon(Sfx.isBed(k) ? Icons.waves : Icons.graphic_eq),
              title: Text(Sfx.info(k).$1),
              subtitle: Text('${Sfx.info(k).$3} · ${Sfx.length(k).toStringAsFixed(1)} s'
                  '${Sfx.peak(k) > 0 ? ' · peak ${Sfx.peak(k).toStringAsFixed(2)} s' : ''}${Sfx.isBed(k) ? ' · loops' : ''}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Preview',
                  icon: _previewKind == k ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow),
                  onPressed: () => _play(k),
                ),
                IconButton(tooltip: 'Insert at playhead', icon: const Icon(Icons.add_circle_outline), onPressed: () => _insert(k)),
              ]),
            ),
        ]),
      ),
    ]);
  }

  // ------------------------------------------------------------- music & beats

  Future<void> _analyse() async {
    final m = _musicMedia;
    if (m == null) return;
    setState(() => _busy = true);
    try {
      final a = await AudioAnalyzer.music(m);
      if (a == null) {
        _say('Could not decode "${m.name}" on this device. Type the BPM instead.');
      } else {
        _analysis = a;
        _say(a.summary());
      }
    } catch (e) {
      _say('Analysis failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _beatSource() {
    final bpm = double.tryParse(_bpm.text.trim());
    return {
      'music': _musicId,
      if (_analysis == null && bpm != null) 'bpm': bpm,
      if (_analysis == null && bpm != null) 'offset': _music?.start ?? 0,
    };
  }

  Widget _beats() {
    final layers = _audioLayers();
    final a = _analysis;
    final music = _music;
    return ListView(padding: const EdgeInsets.all(12), children: [
      if (layers.isEmpty) const Text('Add a music track first (Add → Music / VO).'),
      if (layers.isNotEmpty)
        Row(children: [
          const Text('Music: '),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              value: layers.any((l) => l.id == _musicId) ? _musicId : null,
              items: [for (final l in layers) DropdownMenuItem(value: l.id, child: Text(l.name, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() {
                _musicId = v;
                _loadCached();
              }),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _busy || music == null ? null : _analyse,
            icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.analytics_outlined),
            label: Text(a == null ? 'Analyse' : 'Re-analyse'),
          ),
        ]),
      if (a != null && music != null) ...[
        const SizedBox(height: 8),
        Text(a.summary(), style: const TextStyle(fontSize: 12.5, color: Colors.white70)),
        const SizedBox(height: 8),
        SizedBox(
          height: 96,
          child: ValueListenableBuilder<double>(
            valueListenable: c.timeNotifier,
            builder: (_, t, _) => LayoutBuilder(
              builder: (_, box) => GestureDetector(
                onTapDown: (d) => c.seek(d.localPosition.dx / box.maxWidth * c.comp.duration),
                child: CustomPaint(size: Size(box.maxWidth, 96), painter: BeatStripPainter(a, music, c.comp.duration, t)),
              ),
            ),
          ),
        ),
        const Text('white = beats · yellow = bars · red = drop · blue = sections', style: TextStyle(fontSize: 11, color: Colors.white54)),
      ],
      if (a == null && music != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: TextField(
            controller: _bpm,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'or type the BPM (first beat = start of the track)', isDense: true),
          ),
        ),
      const SizedBox(height: 12),
      Text('Snap distance: ${(_tolerance * 1000).round()} ms'),
      Slider(value: _tolerance, min: 0.05, max: 0.6, onChanged: (v) => setState(() => _tolerance = v)),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
          onPressed: music == null ? null : () => _run({'op': 'beat_sync', 'mode': 'cuts', 'tolerance': _tolerance, ..._beatSource()}, 'Cuts moved onto the beat'),
          icon: const Icon(Icons.content_cut),
          label: const Text('Sync cuts to beat'),
        ),
        OutlinedButton.icon(
          onPressed: music == null ? null : () => _run({'op': 'beat_sync', 'mode': 'pops', 'tolerance': _tolerance + 0.1, ..._beatSource()}, 'Text pops moved onto beats'),
          icon: const Icon(Icons.text_fields),
          label: const Text('Text pops on beats'),
        ),
        OutlinedButton.icon(
          onPressed: music == null || (a?.mainDrop == null) ? null : () => _run({'op': 'beat_sync', 'mode': 'drop', 'music': _musicId, 'at': c.time}, 'The drop now hits at the playhead'),
          icon: const Icon(Icons.bolt),
          label: const Text('Hit the drop at playhead'),
        ),
      ]),
    ]);
  }

  // ------------------------------------------------------------- mix

  Future<void> _autoMix() async {
    setState(() => _busy = true);
    try {
      // Measure what we can (voice activity + loudness) before levelling.
      for (final l in c.comp.layers) {
        if (l.type != LayerType.audio && l.type != LayerType.video) continue;
        final m = l.mediaId == null ? null : c.project.media[l.mediaId];
        if (m == null || AudioCache.lufsFor(m) != null && AudioCache.speechFor(m) != null) continue;
        final role = AutoMix.roleOf(c.project, l);
        if (role == 'voice') {
          await AudioAnalyzer.voice(m);
        } else {
          await AudioAnalyzer.loudness(m);
        }
      }
    } catch (_) {
      // Unmeasured tracks use typical levels.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    _run({'op': 'auto_mix', 'duck': _duck, 'fades': _fades}, 'Mixed: voice −16, music −28, SFX −20, ambience −32 LUFS');
  }

  Widget _mix() {
    return ListView(padding: const EdgeInsets.all(12), children: [
      const Text('Auto mix levels every track (voice −16, music −28, SFX −20, ambience −32 LUFS), '
          'ducks the music under the voice and fades music and beds in and out.', style: TextStyle(fontSize: 12.5, color: Colors.white70)),
      SwitchListTile(dense: true, title: const Text('Duck music under the voice'), value: _duck, onChanged: (v) => setState(() => _duck = v)),
      SwitchListTile(dense: true, title: const Text('Fade in / out'), value: _fades, onChanged: (v) => setState(() => _fades = v)),
      FilledButton.icon(
        onPressed: _busy ? null : _autoMix,
        icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.tune),
        label: const Text('Auto mix'),
      ),
      const Divider(height: 28),
      const Text('Ambience bed', style: TextStyle(fontWeight: FontWeight.w600)),
      DropdownButton<String>(
        isExpanded: true,
        value: _bed,
        items: [for (final b in Sfx.beds) DropdownMenuItem(value: b, child: Text('${Sfx.info(b).$1} — ${Sfx.info(b).$3}'))],
        onChanged: (v) => setState(() => _bed = v ?? _bed),
      ),
      SwitchListTile(dense: true, title: const Text('Whole video'), value: _bedWhole, onChanged: (v) => setState(() => _bedWhole = v)),
      if (!_bedWhole) ...[
        Text('From the playhead for ${_bedSeconds.round()} s'),
        Slider(value: _bedSeconds, min: 2, max: 120, onChanged: (v) => setState(() => _bedSeconds = v)),
      ],
      OutlinedButton.icon(
        onPressed: () {
          final from = _bedWhole ? 0.0 : c.time;
          final dur = _bedWhole ? c.comp.duration : math.min(_bedSeconds, math.max(1.0, c.comp.duration - c.time));
          _run({'op': 'add_sfx', 'kind': _bed, 'time': from, 'duration': dur}, '${Sfx.info(_bed).$1} bed added');
        },
        icon: const Icon(Icons.waves),
        label: const Text('Add bed'),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      initialIndex: widget.initialTab.clamp(0, 2),
      child: Column(children: [
        const SizedBox(height: 6),
        const TabBar(tabs: [Tab(text: 'Effects'), Tab(text: 'Music & beats'), Tab(text: 'Mix')]),
        Expanded(child: TabBarView(children: [_effects(), _beats(), _mix()])),
        if (_status != null)
          Container(
            width: double.infinity,
            color: const Color(0xFF1E2127),
            padding: const EdgeInsets.all(10),
            child: Text(_status!, style: const TextStyle(fontSize: 12.5)),
          ),
      ]),
    );
  }
}

/// Energy curve + beat / bar / drop / section markers of [a], drawn on the
/// composition timeline of the music [layer] (0..[total] s across).
/// Reusable by the timeline (lib/ui/timeline) for beat markers.
class BeatStripPainter extends CustomPainter {
  final MusicAnalysis a;
  final Layer layer;
  final double total;
  final double playhead;
  BeatStripPainter(this.a, this.layer, this.total, this.playhead);

  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    double x(double compT) => compT / total * size.width;
    double comp(double src) => layer.start + (src - layer.sourceIn) / layer.speed;
    bool shown(double src) {
      final t = comp(src);
      return t >= layer.start && t <= layer.end;
    }

    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF15171B));
    // Energy
    if (a.energy.isNotEmpty) {
      final path = Path()..moveTo(x(layer.start), size.height);
      final step = math.max(1, (a.energy.length / size.width / 2).floor());
      for (int i = 0; i < a.energy.length; i += step) {
        final src = i / a.energyRate;
        if (!shown(src)) continue;
        path.lineTo(x(comp(src)), size.height - a.energy[i] * size.height * 0.85);
      }
      path.lineTo(x(math.min(layer.end, total)), size.height);
      path.close();
      canvas.drawPath(path, Paint()..color = const Color(0xFF1F9AA8).withValues(alpha: 0.45));
    }
    final beat = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    for (final b in a.beats) {
      if (shown(b)) canvas.drawLine(Offset(x(comp(b)), size.height * 0.7), Offset(x(comp(b)), size.height), beat);
    }
    final bar = Paint()
      ..color = const Color(0xFFFFC107)
      ..strokeWidth = 1.5;
    for (final b in a.downbeats) {
      if (shown(b)) canvas.drawLine(Offset(x(comp(b)), size.height * 0.45), Offset(x(comp(b)), size.height), bar);
    }
    final sec = Paint()
      ..color = const Color(0xFF0A84FF)
      ..strokeWidth = 2;
    for (final s in a.sections) {
      if (shown(s)) canvas.drawLine(Offset(x(comp(s)), 0), Offset(x(comp(s)), size.height * 0.3), sec);
    }
    final drop = Paint()
      ..color = const Color(0xFFFF3B30)
      ..strokeWidth = 3;
    for (final d in a.drops) {
      if (shown(d)) canvas.drawLine(Offset(x(comp(d)), 0), Offset(x(comp(d)), size.height), drop);
    }
    final ph = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(x(playhead), 0), Offset(x(playhead), size.height), ph);
  }

  @override
  bool shouldRepaint(BeatStripPainter old) => old.a != a || old.playhead != playhead || old.total != total || old.layer != layer;
}
