import 'package:flutter/material.dart';

import '../core/model/project.dart';
import '../core/presets/components.dart';
import '../core/presets/world_map.dart';
import '../state/editor_controller.dart';
import 'common.dart';
import 'theme.dart';

class _Field {
  final String key, label;
  final String kind; // text | long | number | list | media | country
  final String? hint;
  final dynamic initial;
  const _Field(this.key, this.label, {this.kind = 'text', this.hint, this.initial});
}

/// Add shapes and documentary-kit components with a small form each.
class DocKitSheet extends StatefulWidget {
  final EditorController c;
  final bool shapesOnly;
  const DocKitSheet({super.key, required this.c, this.shapesOnly = false});

  static Future<void> open(BuildContext context, EditorController c, {bool shapes = false}) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          maxChildSize: 0.95,
          builder: (_, sc) => PrimaryScrollController(controller: sc, child: DocKitSheet(c: c, shapesOnly: shapes)),
        ),
      );

  @override
  State<DocKitSheet> createState() => _DocKitSheetState();
}

class _DocKitSheetState extends State<DocKitSheet> {
  String? _type;
  final Map<String, TextEditingController> _ctl = {};
  String? _media;
  String? _error;

  static const _fields = <String, List<_Field>>{
    'source_card': [
      _Field('source', 'Source', initial: 'Source: www.example.com'),
      _Field('headline', 'Headline', initial: 'Headline of the article'),
      _Field('body', 'Quoted text', kind: 'long', initial: 'Paste the passage you are citing here.'),
      _Field('highlights', 'Highlight (comma separated phrases)', kind: 'list', hint: 'passage, citing'),
      _Field('circle', 'Circle a word/date', hint: '1941'),
    ],
    'lower_third': [
      _Field('source', 'Source', initial: 'Source: www.example.com'),
      _Field('text', 'Line of text', kind: 'long', initial: 'A short line from the source.'),
      _Field('highlights', 'Highlight phrases', kind: 'list'),
    ],
    'badge': [_Field('label', 'Label', initial: 'ORGANISATION'), _Field('media', 'Image (optional)', kind: 'media')],
    'photo_card': [_Field('media', 'Photo', kind: 'media'), _Field('caption', 'Caption', initial: 'Caption')],
    'pin': [_Field('label', 'Label', initial: 'Location')],
    'route_arrow': [_Field('bend', 'Curve (0 = straight)', kind: 'number', initial: 0.25)],
    'speech_bubble': [_Field('text', 'Quote', kind: 'long', initial: '"We will fight back"')],
    'cta': [_Field('text', 'Text', initial: 'SUBSCRIBE')],
    'timeline': [
      _Field('from', 'From year', kind: 'number', initial: 1930),
      _Field('to', 'To year', kind: 'number', initial: 1970),
      _Field('marker', 'Marker year', kind: 'number', initial: 1941),
      _Field('label', 'Marker label', initial: 'APR 1941'),
    ],
    'counter': [
      _Field('from', 'From', kind: 'number', initial: 0),
      _Field('to', 'To', kind: 'number', initial: 3000000),
      _Field('prefix', 'Prefix', hint: r'$'),
      _Field('suffix', 'Suffix', initial: ' BARRELS'),
    ],
    'glow_word': [_Field('text', 'Word', initial: 'POWER')],
    'map': [
      _Field('countries', 'Highlight countries (comma separated)', kind: 'list', initial: 'India, Iraq'),
      _Field('focus', 'Zoom to country', kind: 'country', initial: 'Iraq'),
      _Field('style', 'Style: dark / paper / blue', initial: 'dark'),
    ],
    'tv_frame': [],
  };

  static const _icons = <String, IconData>{
    'source_card': Icons.article_outlined,
    'lower_third': Icons.subtitles_outlined,
    'badge': Icons.verified_outlined,
    'photo_card': Icons.photo_outlined,
    'pin': Icons.place_outlined,
    'route_arrow': Icons.trending_flat,
    'speech_bubble': Icons.chat_bubble_outline,
    'cta': Icons.notifications_active_outlined,
    'timeline': Icons.timeline,
    'counter': Icons.onetwothree,
    'glow_word': Icons.flare,
    'map': Icons.public,
    'tv_frame': Icons.tv,
  };

  static const _shapes = [
    ('rect', 'Rectangle', Icons.crop_square),
    ('ellipse', 'Circle', Icons.circle_outlined),
    ('star', 'Star', Icons.star_border),
    ('polygon', 'Polygon', Icons.hexagon_outlined),
    ('arrow', 'Arrow line', Icons.trending_flat),
    ('line', 'Line', Icons.horizontal_rule),
  ];

  void _pick(String t) {
    setState(() {
      _type = t;
      _error = null;
      _ctl.clear();
      _media = null;
      for (final f in _fields[t] ?? const <_Field>[]) {
        _ctl[f.key] = TextEditingController(text: f.initial == null ? '' : '${f.initial}');
      }
    });
  }

  void _addShape(String kind) {
    final comp = widget.c.comp;
    final w = comp.width, h = comp.height;
    final Map<String, dynamic> cmd;
    if (kind == 'arrow' || kind == 'line') {
      cmd = {
        'op': 'add_layer', 'type': 'shape', 'name': kind == 'arrow' ? 'Arrow' : 'Line',
        'points': [[w * 0.3, h * 0.55], [w * 0.5, h * 0.42], [w * 0.7, h * 0.5]],
        'smooth': true, 'closed': false, 'fill': 'none', 'stroke': '#FFFFFF', 'stroke_width': w * 0.004,
        'arrow_end': kind == 'arrow',
      };
    } else {
      cmd = {
        'op': 'add_layer', 'type': 'shape', 'kind': kind, 'width': w * 0.2, 'height': w * 0.2,
        'fill': '#FFC400', 'stroke': '#FFFFFF', 'stroke_width': 0, 'sides': kind == 'star' ? 5 : 6,
        'name': kind[0].toUpperCase() + kind.substring(1),
      };
    }
    final r = _tryRun(cmd);
    if (r != null && mounted) {
      if (kind == 'arrow' || kind == 'line') {
        // Draw-on animation for lines.
        widget.c.tryRun({'op': 'batch', 'commands': [
          {'op': 'set_keyframe', 'target': r, 'prop': 'trim', 'time': widget.c.time, 'value': [0, 0], 'ease': 'easy_ease'},
          {'op': 'set_keyframe', 'target': r, 'prop': 'trim', 'time': widget.c.time + 1.2, 'value': [0, 100]},
        ]});
      }
      Navigator.pop(context);
    }
  }

  String? _tryRun(Map<String, dynamic> cmd) {
    try {
      final res = widget.c.run(cmd);
      final id = res.createdIds.isEmpty ? null : res.createdIds.first;
      if (id != null) widget.c.select(id);
      return id ?? '';
    } catch (e) {
      setState(() => _error = '$e'.replaceFirst('CommandError: ', ''));
      return null;
    }
  }

  void _addComponent() {
    final t = _type!;
    final cmd = <String, dynamic>{'op': 'add_component', 'type': t, 'start': widget.c.time};
    for (final f in _fields[t] ?? const <_Field>[]) {
      final v = _ctl[f.key]?.text.trim() ?? '';
      switch (f.kind) {
        case 'media':
          if (_media != null) cmd[f.key] = _media;
        case 'number':
          final n = double.tryParse(v);
          if (n != null) cmd[f.key] = n;
        case 'list':
          if (v.isNotEmpty) cmd[f.key] = v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        default:
          if (v.isNotEmpty) cmd[f.key] = v;
      }
    }
    if (t == 'map') {
      final duration = widget.c.comp.duration - widget.c.time;
      cmd['duration'] = duration < 3 ? 6 : duration;
    }
    if (_tryRun(cmd) != null && mounted) {
      Navigator.pop(context);
      showSnack(context, '${Components.label(t)} added. Edit its parts in the timeline.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _type;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: ListView(
        primary: true,
        children: [
          Row(children: [
            if (t != null)
              IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _type = null)),
            Text(t == null ? (widget.shapesOnly ? 'Add shape' : 'Documentary kit') : Components.label(t),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 10),
          if (t == null && widget.shapesOnly)
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final s in _shapes) _tile(s.$3, s.$2, () => _addShape(s.$1)),
            ]),
          if (t == null && !widget.shapesOnly)
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (final k in _fields.keys) _tile(_icons[k] ?? Icons.widgets_outlined, Components.label(k), () => _pick(k)),
            ]),
          if (t != null) ..._form(t),
        ],
      ),
    );
  }

  Widget _tile(IconData icon, String label, VoidCallback onTap) => SizedBox(
        width: 104,
        height: 88,
        child: Material(
          color: MA.surface2,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, color: MA.accent2),
              const SizedBox(height: 6),
              Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11.5)),
            ]),
          ),
        ),
      );

  List<Widget> _form(String t) {
    final media = widget.c.project.media.values.where((m) => m.type != MediaType.audio).toList();
    return [
      if (t == 'map' && !WorldMap.loaded)
        const Text('Map data is still loading, try again in a second.', style: TextStyle(color: Colors.orangeAccent)),
      for (final f in _fields[t] ?? const <_Field>[])
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: f.kind == 'media'
              ? DropdownButtonFormField<String>(
                  initialValue: _media,
                  decoration: InputDecoration(labelText: f.label, isDense: true),
                  items: [for (final m in media) DropdownMenuItem(value: m.id, child: Text(m.name, overflow: TextOverflow.ellipsis))],
                  onChanged: (v) => setState(() => _media = v),
                )
              : TextField(
                  controller: _ctl[f.key],
                  maxLines: f.kind == 'long' ? 4 : 1,
                  keyboardType: f.kind == 'number' ? const TextInputType.numberWithOptions(decimal: true, signed: true) : null,
                  decoration: InputDecoration(labelText: f.label, hintText: f.hint, isDense: true),
                ),
        ),
      if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
      const Text('Starts at the playhead. Every part stays editable on the timeline.', style: TextStyle(fontSize: 12, color: MA.textDim)),
      const SizedBox(height: 10),
      FilledButton.icon(onPressed: _addComponent, icon: const Icon(Icons.add), label: const Text('Add')),
    ];
  }
}
