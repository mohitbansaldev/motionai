import 'package:flutter/material.dart';

import '../ai/ai_client.dart';
import '../core/model/layer.dart';
import '../services/captions.dart';
import '../state/editor_controller.dart';
import 'common.dart';

/// Pick a clip and caption options, then generate caption layers.
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

class _CaptionsSheetState extends State<CaptionsSheet> {
  String? _layerId;
  final _o = CaptionOptions();
  String? _status;
  bool _busy = false;

  List<Layer> get _sources =>
      widget.c.comp.layers.where((l) => l.type == LayerType.video || l.type == LayerType.audio).toList();

  @override
  void initState() {
    super.initState();
    final sel = widget.c.selectedLayer;
    _layerId = (sel != null && _sources.any((l) => l.id == sel.id))
        ? sel.id
        : (_sources.isEmpty ? null : _sources.first.id);
  }

  Future<void> _go() async {
    final l = widget.c.comp.layerById(_layerId ?? '');
    if (l == null) return;
    setState(() {
      _busy = true;
      _status = 'Starting…';
    });
    try {
      final cmds = await CaptionMaker.buildCommands(widget.c.project, l, _o,
          onStatus: (s) {
        if (mounted) setState(() => _status = s);
      });
      final err = widget.c.tryRun({'op': 'batch', 'commands': cmds});
      if (!mounted) return;
      if (err != null) {
        setState(() => _status = err);
      } else {
        Navigator.pop(context);
        showSnack(context, 'Added ${cmds.length} captions. Undo removes them all.');
      }
    } on AiException catch (e) {
      if (mounted) setState(() => _status = e.message);
    } catch (e) {
      if (mounted) setState(() => _status = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = _sources;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Auto captions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text('Uses OpenAI speech-to-text with your OpenAI key.', style: TextStyle(fontSize: 12, color: Colors.white60)),
        const SizedBox(height: 12),
        if (sources.isEmpty)
          const Text('Add a video or voiceover first.', style: TextStyle(color: Colors.white54))
        else ...[
          DropdownButton<String>(
            isExpanded: true,
            value: _layerId,
            items: [for (final l in sources) DropdownMenuItem(value: l.id, child: Text(l.name, overflow: TextOverflow.ellipsis))],
            onChanged: _busy ? null : (v) => setState(() => _layerId = v),
          ),
          const SectionTitle('Language'),
          Wrap(spacing: 6, runSpacing: 6, children: [
            ChoiceChip(
              label: const Text('Hindi (देवनागरी)'),
              selected: _o.language == 'hi' && !_o.roman,
              onSelected: (_) => setState(() {
                _o.language = 'hi';
                _o.roman = false;
              }),
            ),
            ChoiceChip(
              label: const Text('Hinglish (Roman)'),
              selected: _o.roman,
              onSelected: (_) => setState(() {
                _o.language = 'hi';
                _o.roman = true;
              }),
            ),
            ChoiceChip(
              label: const Text('English'),
              selected: _o.language == 'en' && !_o.roman,
              onSelected: (_) => setState(() {
                _o.language = 'en';
                _o.roman = false;
              }),
            ),
            ChoiceChip(
              label: const Text('Auto'),
              selected: _o.language == null && !_o.roman,
              onSelected: (_) => setState(() {
                _o.language = null;
                _o.roman = false;
              }),
            ),
          ]),
          const SectionTitle('Style'),
          Wrap(spacing: 6, children: [
            for (final st in const [('karaoke', 'Word highlight'), ('word_pop', 'Word pop'), ('plain', 'Plain box')])
              ChoiceChip(label: Text(st.$2), selected: _o.style == st.$1, onSelected: (_) => setState(() => _o.style = st.$1)),
          ]),
          const SectionTitle('Words per caption'),
          Slider(
            value: _o.maxWords.toDouble(),
            min: 1,
            max: 8,
            divisions: 7,
            label: '${_o.maxWords}',
            onChanged: (v) => setState(() => _o.maxWords = v.round()),
          ),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_status!, style: const TextStyle(color: Colors.white70)),
            ),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _go,
              icon: _busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.closed_caption),
              label: const Text('Generate captions'),
            ),
          ),
        ],
      ]),
    );
  }
}
