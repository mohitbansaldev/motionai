import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/commands/edit_commands.dart';
import '../state/editor_controller.dart';

/// Paste and run JSON edit commands — the exact interface the AI agent
/// will use. Handy for testing agent output before the agent exists.
class CommandConsole extends StatefulWidget {
  final EditorController c;
  const CommandConsole({super.key, required this.c});

  static Future<void> open(BuildContext context, EditorController c) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => CommandConsole(c: c)),
      );

  @override
  State<CommandConsole> createState() => _CommandConsoleState();
}

class _CommandConsoleState extends State<CommandConsole> {
  final _ctl = TextEditingController(text: _example);
  String _output = '';
  bool _error = false;

  static const _example = '''[
  {"op": "add_layer", "type": "solid", "id": "bg", "color": "#101826"},
  {"op": "add_layer", "type": "text", "id": "title", "text": "MOTIONAI", "font_size": 160},
  {"op": "set_keyframe", "target": "title", "prop": "opacity", "time": 0, "value": 0},
  {"op": "set_keyframe", "target": "title", "prop": "opacity", "time": 1, "value": 100},
  {"op": "set_keyframe", "target": "title", "prop": "scale", "time": 0, "value": 80, "ease": "back"},
  {"op": "set_keyframe", "target": "title", "prop": "scale", "time": 1.2, "value": 100},
  {"op": "parallax_rig", "layers": ["bg", "title"], "depth": 600, "push": 300, "start": 0, "duration": 4}
]''';

  void _run() {
    try {
      final cmd = EditCommands.parse(_ctl.text);
      final r = widget.c.run(cmd);
      setState(() {
        _error = false;
        _output = const JsonEncoder.withIndent('  ').convert(r.toJson());
      });
    } on CommandError catch (e) {
      setState(() {
        _error = true;
        _output = e.message;
      });
    } on FormatException catch (e) {
      setState(() {
        _error = true;
        _output = 'Invalid JSON: ${e.message}';
      });
    }
  }

  void _copyState() {
    Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent(' ').convert(widget.c.project.toJson())));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Project JSON copied')));
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit commands'),
        actions: [
          IconButton(tooltip: 'Copy project JSON', icon: const Icon(Icons.data_object), onPressed: _copyState),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Expanded(
            flex: 3,
            child: TextField(
              controller: _ctl,
              maxLines: null,
              expands: true,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'JSON command or list'),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton.icon(onPressed: _run, icon: const Icon(Icons.play_arrow), label: const Text('Run')),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: () => _ctl.clear(), child: const Text('Clear')),
            const Spacer(),
            Text('Layers: ${widget.c.comp.layers.map((l) => l.id).join(', ')}',
                style: const TextStyle(fontSize: 11, color: Colors.white54)),
          ]),
          const SizedBox(height: 8),
          Expanded(
            flex: 2,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(color: _error ? Colors.redAccent : Colors.white24),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  _output.isEmpty ? 'Output appears here. Batches are all-or-nothing and one Undo reverts them.' : _output,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: _error ? Colors.redAccent : Colors.white70),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
