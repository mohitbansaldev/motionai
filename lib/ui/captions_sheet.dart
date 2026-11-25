import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../ai/ai_client.dart';
import '../captions/captions.dart';
import '../core/commands/edit_commands.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../services/captions.dart' show CaptionMaker;
import '../state/editor_controller.dart';
import 'common.dart';
import 'preview/composition_canvas.dart';

/// Captions: pick a style (live preview), generate from speech, edit words
/// and timing, restyle, and import / export .srt / .vtt.
class CaptionsSheet extends StatefulWidget {
  final EditorController c;
  const CaptionsSheet({super.key, required this.c});

  static Future<void> open(BuildContext context, EditorController c) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => CaptionsSheet(c: c),
      );

  @override
  State<CaptionsSheet> createState() => _CaptionsSheetState();
}

class _CaptionsSheetState extends State<CaptionsSheet> with SingleTickerProviderStateMixin {
  String? _layerId;
  final _o = CaptionOptions();
  String? _status;
  bool _busy = false;
  int _tab = 0;

  // Edit state: captions read from the timeline, edited here, applied as one batch.
  List<CaptionCue> _cues = [];
  String? _loadedStyle;
  bool _dirty = false;
  double _offset = 0;
  int? _open;

  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200))..repeat();

  EditorController get c => widget.c;

  List<Layer> get _sources => c.comp.layers.where((l) => l.type == LayerType.video || l.type == LayerType.audio).toList();

  @override
  void initState() {
    super.initState();
    final sel = c.selectedLayer;
    _layerId = (sel != null && _sources.any((l) => l.id == sel.id)) ? sel.id : (_sources.isEmpty ? null : _sources.first.id);
    _reload();
    if (_cues.isNotEmpty) _tab = 1;
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _reload() {
    _cues = CaptionTrack.read(c.comp);
    _dirty = false;
    _offset = 0;
    _open = null;
    _loadedStyle = _o.style;
  }

  CaptionStyle get _style => CaptionStyles.byId(_o.style);

  void _pickStyle(CaptionStyle s) => setState(() {
        _o.style = s.id;
        if (s.script == 'roman') {
          _o.roman = true;
          _o.language = 'hi';
        } else if (s.script == 'devanagari') {
          _o.roman = false;
          _o.language = 'hi';
        }
      });

  // ------------------------------------------------------------ actions

  Future<void> _generate() async {
    final l = c.comp.layerById(_layerId ?? '');
    if (l == null) return;
    setState(() {
      _busy = true;
      _status = 'Starting…';
    });
    try {
      final cmds = await CaptionMaker.buildCommands(c.project, l, _o, onStatus: (s) {
        if (mounted) setState(() => _status = s);
      });
      final err = c.tryRun({'op': 'batch', 'commands': cmds});
      if (!mounted) return;
      if (err != null) {
        setState(() => _status = err);
      } else {
        final n = cmds.where((m) => m['op'] == 'add_layer').length;
        setState(() {
          _reload();
          _tab = 1;
          _status = 'Added $n caption layers. Undo removes them all.';
        });
      }
    } on AiException catch (e) {
      if (mounted) setState(() => _status = e.message);
    } catch (e) {
      if (mounted) setState(() => _status = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _findKeywordsWithAi() async {
    if (_cues.isEmpty) return;
    setState(() {
      _busy = true;
      _status = 'Asking the AI for key words…';
    });
    final words = await CaptionMaker.aiEmphasis([for (final q in _cues) ...q.words]);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _o.emphasisWords.addAll(words);
      _dirty = words.isNotEmpty || _dirty;
      _status = words.isEmpty ? 'No key words found (is AI set up?).' : 'Key words: ${words.take(12).join(', ')}${words.length > 12 ? '…' : ''}. Tap Apply.';
    });
  }

  void _apply() {
    if (_cues.isEmpty) return;
    final cues = [for (final q in _cues) q.copy()..shift(_offset)];
    final cmd = CaptionTrack.replaceCommand(c.project, cues, _style, options: _o, relayout: _loadedStyle != _o.style);
    final err = c.tryRun(cmd);
    setState(() {
      if (err != null) {
        _status = err;
      } else {
        _reload();
        _status = 'Captions updated. Undo restores the old ones.';
      }
    });
  }

  void _removeAll() {
    final ids = CaptionTrack.layers(c.comp).map((l) => l.id).toList();
    if (ids.isEmpty) return;
    final err = c.tryRun({'op': 'batch', 'commands': [for (final id in ids) {'op': 'remove_layer', 'layer': id}]});
    setState(() {
      _status = err ?? 'Removed ${ids.length} caption layers.';
      _reload();
    });
  }

  Future<void> _export(bool vtt) async {
    final cues = _cues.isEmpty ? CaptionTrack.read(c.comp) : [for (final q in _cues) q.copy()..shift(_offset)];
    if (cues.isEmpty) {
      setState(() => _status = 'No captions to export yet.');
      return;
    }
    final text = vtt ? Subtitles.toVtt(cues) : Subtitles.toSrt(cues);
    await Clipboard.setData(ClipboardData(text: text));
    final base = c.project.name.replaceAll(RegExp(r'[^\w\- ]+'), '').trim();
    final name = '${base.isEmpty ? 'captions' : base}.${vtt ? 'vtt' : 'srt'}';
    String where;
    try {
      where = await _saveText(name, text);
    } catch (e) {
      where = 'could not save a file ($e)';
    }
    if (mounted) setState(() => _status = 'Copied ${cues.length} captions to the clipboard and saved to $where');
  }

  static Future<String> _saveText(String name, String text) async {
    Directory? dir;
    try {
      dir = await getDownloadsDirectory();
    } catch (_) {}
    if (dir == null && Platform.isAndroid) {
      try {
        dir = await getExternalStorageDirectory();
      } catch (_) {}
    }
    dir ??= await getApplicationDocumentsDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    final f = File('${dir.path}${Platform.pathSeparator}$name');
    await f.writeAsString(text);
    return f.path;
  }

  Future<void> _import() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.any);
      if (files.isEmpty) return;
      final f = files.first;
      String text;
      final path = f.path;
      if (path != null && await File(path).exists()) {
        text = await File(path).readAsString();
      } else {
        final bytes = <int>[];
        await for (final chunk in f.readAsByteStream()) {
          bytes.addAll(chunk);
        }
        text = utf8.decode(bytes, allowMalformed: true);
      }
      final cues = Subtitles.parse(text);
      if (cues.isEmpty) {
        setState(() => _status = 'No subtitles found in ${f.name}. Pick an .srt or .vtt file.');
        return;
      }
      final cmd = CaptionTrack.replaceCommand(c.project, cues, _style, options: _o, relayout: false);
      final err = c.tryRun(cmd);
      setState(() {
        if (err != null) {
          _status = err;
        } else {
          _reload();
          _tab = 1;
          _status = 'Imported ${cues.length} captions from ${f.name}.';
        }
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Import failed: $e');
    }
  }

  Future<void> _editWord(CaptionCue q, int i) async {
    final w = q.words[i];
    final text = TextEditingController(text: w.word);
    final s = TextEditingController(text: w.start.toStringAsFixed(2));
    final e = TextEditingController(text: w.end.toStringAsFixed(2));
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit word'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: text, autofocus: true, decoration: const InputDecoration(labelText: 'Word')),
          Row(children: [
            Expanded(child: TextField(controller: s, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Start (s)'))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: e, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'End (s)'))),
          ]),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'delete'), child: const Text('Delete word')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'ok'), child: const Text('OK')),
        ],
      ),
    );
    if (r == null || !mounted) return;
    setState(() {
      if (r == 'delete') {
        q.words.removeAt(i);
        q.lineStarts = {
          for (final k in q.lineStarts)
            if (k <= i) k else k - 1,
        }.where((k) => k > 0 && k < q.words.length).toList()
          ..sort();
        q.emphasis = {};
        if (q.words.isEmpty) _cues.remove(q);
      } else {
        final t = text.text.trim();
        if (t.isNotEmpty) w.word = t;
        final ns = double.tryParse(s.text.trim()), ne = double.tryParse(e.text.trim());
        if (ns != null) w.start = ns;
        if (ne != null && ne > w.start) w.end = ne;
        if (q.words.first == w) q.start = w.start;
        if (q.words.last == w) q.end = w.end;
      }
      _dirty = true;
    });
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: mq.size.height * 0.92),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 14, 16, 12 + mq.viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('Captions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
              if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ]),
            const SizedBox(height: 8),
            _livePreview(),
            const SectionTitle('Style'),
            _gallery(),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              segments: [
                const ButtonSegment(value: 0, label: Text('Create'), icon: Icon(Icons.mic_none)),
                ButtonSegment(value: 1, label: Text('Edit (${_cues.length})'), icon: const Icon(Icons.edit_note)),
                const ButtonSegment(value: 2, label: Text('Files'), icon: Icon(Icons.subtitles_outlined)),
              ],
              selected: {_tab},
              onSelectionChanged: (v) => setState(() => _tab = v.first),
            ),
            const SizedBox(height: 8),
            if (_tab == 0) _createTab(),
            if (_tab == 1) _editTab(),
            if (_tab == 2) _filesTab(),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_status!, style: const TextStyle(color: Colors.white70)),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _livePreview() {
    final comp = c.comp;
    final aspect = comp.width / comp.height;
    final p = _CaptionPreviews.project(comp.width, comp.height, _style, _sampleScript, _o);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: aspect < 1 ? 300 : 200),
        child: AspectRatio(
          aspectRatio: aspect,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AnimatedBuilder(
              animation: _anim,
              builder: (_, _) => FittedBox(
                fit: BoxFit.contain,
                child: CompositionCanvas(project: p, time: _anim.value * 3.2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _sampleScript {
    final s = _style.script;
    if (s == 'devanagari') return 'deva';
    if (s == 'roman' || _o.roman) return 'roman';
    if (_o.language == 'en') return 'en';
    return _o.language == 'hi' ? 'deva' : 'en';
  }

  Widget _gallery() {
    final comp = c.comp;
    final aspect = comp.width / comp.height;
    final h = aspect < 1 ? 132.0 : 86.0;
    return SizedBox(
      height: h + 26,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final s in CaptionStyles.all)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                onTap: _busy ? null : () => _pickStyle(s),
                borderRadius: BorderRadius.circular(8),
                child: Column(children: [
                  Container(
                    height: h,
                    width: h * aspect,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: s.id == _style.id ? Colors.amber : Colors.white24, width: 2),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: CompositionCanvas(
                        project: _CaptionPreviews.project(comp.width, comp.height, s, s.script == 'devanagari' ? 'deva' : (s.script == 'roman' ? 'roman' : _sampleScript), _o),
                        time: 1.15,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(s.label, style: TextStyle(fontSize: 11, color: s.id == _style.id ? Colors.amber : Colors.white70)),
                ]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _createTab() {
    final sources = _sources;
    if (sources.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('Add a video or voiceover first, or import an .srt file in Files.', style: TextStyle(color: Colors.white54)),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      DropdownButton<String>(
        isExpanded: true,
        value: _layerId,
        items: [for (final l in sources) DropdownMenuItem(value: l.id, child: Text(l.name, overflow: TextOverflow.ellipsis))],
        onChanged: _busy ? null : (v) => setState(() => _layerId = v),
      ),
      const SectionTitle('Language'),
      Wrap(spacing: 6, runSpacing: 6, children: [
        _lang('Hindi (देवनागरी)', _o.language == 'hi' && !_o.roman, 'hi', false),
        _lang('Hinglish (Roman)', _o.roman, 'hi', true),
        _lang('English', _o.language == 'en' && !_o.roman, 'en', false),
        _lang('Auto', _o.language == null && !_o.roman, null, false),
      ]),
      const SectionTitle('Words per caption'),
      Row(children: [
        Expanded(
          child: Slider(
            value: _o.maxWords.toDouble(),
            min: 0,
            max: 8,
            divisions: 8,
            label: _o.maxWords == 0 ? 'Style default' : '${_o.maxWords}',
            onChanged: (v) => setState(() => _o.maxWords = v.round()),
          ),
        ),
        SizedBox(width: 64, child: Text(_o.maxWords == 0 ? 'Auto (${_style.maxWords})' : '${_o.maxWords}', style: const TextStyle(fontSize: 12))),
      ]),
      _options(),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _busy ? null : _generate,
          icon: const Icon(Icons.closed_caption),
          label: const Text('Generate captions'),
        ),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Text('Speech is transcribed on this device (the model downloads once). You can switch to OpenAI in AI settings.',
            style: TextStyle(fontSize: 12, color: Colors.white60)),
      ),
    ]);
  }

  Widget _options() => Column(children: [
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Highlight key words'),
          subtitle: const Text('Numbers, ₹/\$ amounts, years, names'),
          value: _o.emphasis,
          onChanged: (v) => setState(() {
            _o.emphasis = v;
            _dirty = true;
          }),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('AI picks key words'),
          subtitle: const Text('One AI request for the whole transcript'),
          value: _o.aiEmphasis,
          onChanged: (v) => setState(() => _o.aiEmphasis = v),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Keep clear of other text'),
          subtitle: const Text('Moves captions above name tags / lower thirds'),
          value: _o.safeArea,
          onChanged: (v) => setState(() {
            _o.safeArea = v;
            _dirty = true;
          }),
        ),
      ]);

  Widget _lang(String label, bool selected, String? lang, bool roman) => ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() {
          _o.language = lang;
          _o.roman = roman;
        }),
      );

  Widget _editTab() {
    if (_cues.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('No captions yet. Generate them in Create or import an .srt in Files.', style: TextStyle(color: Colors.white54)),
      );
    }
    final fps = c.comp.fps;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Text('Offset', style: TextStyle(fontSize: 12)),
        Expanded(
          child: Slider(
            value: _offset,
            min: -2,
            max: 2,
            divisions: 80,
            label: '${_offset >= 0 ? '+' : ''}${_offset.toStringAsFixed(2)} s',
            onChanged: (v) => setState(() {
              _offset = v;
              _dirty = true;
            }),
          ),
        ),
        SizedBox(width: 56, child: Text('${_offset >= 0 ? '+' : ''}${_offset.toStringAsFixed(2)}s', style: const TextStyle(fontSize: 12))),
      ]),
      SizedBox(
        height: 240,
        child: ListView.builder(
          itemCount: _cues.length,
          itemBuilder: (_, i) {
            final q = _cues[i];
            final open = _open == i;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Text(formatTime(q.start + _offset, fps), style: const TextStyle(fontSize: 11, color: Colors.white54)),
                title: Text(q.text.replaceAll('\n', ' / '), maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  icon: const Icon(Icons.play_arrow, size: 18),
                  tooltip: 'Go to caption',
                  onPressed: () => c.seek(q.start + _offset + 0.05, snap: false),
                ),
                onTap: () => setState(() => _open = open ? null : i),
              ),
              if (open)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Wrap(spacing: 4, runSpacing: 4, children: [
                    for (int k = 0; k < q.words.length; k++)
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(q.words[k].word),
                        tooltip: '${q.words[k].start.toStringAsFixed(2)}–${q.words[k].end.toStringAsFixed(2)} s',
                        onPressed: () => _editWord(q, k),
                      ),
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('Delete caption'),
                      onPressed: () => setState(() {
                        _cues.removeAt(i);
                        _open = null;
                        _dirty = true;
                      }),
                    ),
                  ]),
                ),
            ]);
          },
        ),
      ),
      _options(),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
          onPressed: _busy || (!_dirty && _loadedStyle == _o.style) ? null : _apply,
          icon: const Icon(Icons.check),
          label: Text(_loadedStyle != _o.style ? 'Apply ${_style.label}' : 'Apply edits'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : _findKeywordsWithAi,
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: const Text('AI key words'),
        ),
        OutlinedButton.icon(
          onPressed: _busy || _sources.isEmpty ? null : () => setState(() => _tab = 0),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Regenerate from speech'),
        ),
        TextButton.icon(
          onPressed: _busy ? null : _removeAll,
          icon: const Icon(Icons.delete_sweep_outlined, size: 18),
          label: const Text('Remove all'),
        ),
      ]),
    ]);
  }

  Widget _filesTab() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Export the captions for YouTube (or another editor), or bring in subtitles made elsewhere.',
            style: TextStyle(fontSize: 12, color: Colors.white60)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.tonalIcon(onPressed: _busy ? null : () => _export(false), icon: const Icon(Icons.download), label: const Text('Export .srt')),
          FilledButton.tonalIcon(onPressed: _busy ? null : () => _export(true), icon: const Icon(Icons.download), label: const Text('Export .vtt')),
          OutlinedButton.icon(onPressed: _busy ? null : _import, icon: const Icon(Icons.upload_file), label: const Text('Import .srt / .vtt')),
        ]),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Import replaces the current captions and uses the selected style.', style: TextStyle(fontSize: 11, color: Colors.white38)),
        ),
      ]);
}

/// Small preview projects with sample captions, cached per style/frame/script.
class _CaptionPreviews {
  static final Map<String, Project> _cache = {};

  static const samples = {
    'en': 'In 1991 India had only \$1 billion left',
    'roman': '1991 mein Bharat ke paas sirf ₹500 crore the',
    'deva': '1991 में भारत के पास सिर्फ़ ₹500 करोड़ थे',
  };

  static Project project(double w, double h, CaptionStyle style, String script, CaptionOptions o) {
    final key = '${w.round()}x${h.round()}|${style.id}|$script|${o.emphasis}|${o.maxWords}';
    final hit = _cache[key];
    if (hit != null) return hit;
    final p = Project(
      id: 'caption_preview',
      name: 'Preview',
      main: Composition(id: 'main', name: 'Preview', width: w, height: h, fps: 30, duration: 3.2, background: 0xFF1E2A36),
    );
    final text = samples[script] ?? samples['en']!;
    final parts = text.split(' ');
    final words = [for (int i = 0; i < parts.length; i++) WordTiming(parts[i], 0.15 + i * 0.32, 0.15 + i * 0.32 + 0.28)];
    final opts = CaptionOptions(style: style.id, maxWords: o.maxWords, emphasis: o.emphasis, safeArea: false);
    try {
      // A soft lower vignette so captions read like on footage.
      EditCommands.runAtomic(p, {
        'op': 'batch',
        'commands': [
          {'op': 'add_layer', 'type': 'solid', 'id': 'bg', 'color': '#2C3E50', 'start': 0, 'duration': 3.2},
          {'op': 'add_effect', 'layer': 'bg', 'effect': 'vignette', 'params': {'amount': 70}},
          ...CaptionBuilder.fromWords(p, words, opts, stamp: 'pv'),
        ],
      });
    } catch (_) {
      // A broken preview must not break the sheet.
    }
    if (_cache.length > 40) _cache.clear();
    return _cache[key] = p;
  }
}
