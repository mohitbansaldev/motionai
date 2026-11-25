import 'package:flutter/material.dart';

import '../ai/ai_settings.dart';
import '../ai/phrase_finder.dart';
import '../core/model/project.dart';
import '../director/director.dart';
import '../core/presets/components.dart';
import '../core/presets/world_map.dart';
import '../state/editor_controller.dart';
import 'common.dart';
import 'theme.dart';

class _Field {
  final String key, label;
  final String kind; // text | long | number | list | media | medias | audio | country
  final String? hint;
  final dynamic initial;
  const _Field(this.key, this.label, {this.kind = 'text', this.hint, this.initial});
}

/// Add shapes and documentary-kit components with a small form each.
class DocKitSheet extends StatefulWidget {
  final EditorController c;
  final bool shapesOnly;
  final String? initial; // open straight on this component's form
  const DocKitSheet({super.key, required this.c, this.shapesOnly = false, this.initial});

  static Future<void> open(BuildContext context, EditorController c, {bool shapes = false, String? component}) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          maxChildSize: 0.95,
          builder: (_, sc) => PrimaryScrollController(controller: sc, child: DocKitSheet(c: c, shapesOnly: shapes, initial: component)),
        ),
      );

  @override
  State<DocKitSheet> createState() => _DocKitSheetState();
}

class _DocKitSheetState extends State<DocKitSheet> {
  String? _type;
  final Map<String, TextEditingController> _ctl = {};
  final Map<String, String?> _media = {};
  final Map<String, Set<String>> _multi = {};
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final t = widget.initial;
    if (t != null && _fields.containsKey(t)) _select(t);
  }

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
    'name_tag': [_Field('name', 'Name', initial: 'Name Surname'), _Field('role', 'Role (on the yellow bar)', initial: 'Founder, Example Corp')],
    'character_label': [
      _Field('text', 'Label', initial: 'SUSPECT'),
      _Field('style', 'Style: black / red', initial: 'black'),
    ],
    'arrow_callout': [_Field('text', 'Text at the arrow start (optional)', hint: 'Look here')],
    'censor_bar': [_Field('text', 'Text on the bar (optional)', hint: 'CENSORED')],
    'plaque': [
      _Field('name', 'Name', initial: 'JOHN DOE'),
      _Field('dates', 'Dates', initial: '1835 – 1902'),
      _Field('text', 'Epitaph', initial: 'Rest in peace'),
      _Field('style', 'Style: stone / bronze / wood', initial: 'stone'),
    ],
    'poster': [
      _Field('title', 'Title', initial: 'WANTED'),
      _Field('subtitle', 'Subtitle', initial: 'WORKERS FOR THE NEW WORLD'),
      _Field('body', 'Text', kind: 'long', initial: 'Apply at the harbour office. Good wages, free passage.'),
      _Field('media', 'Picture (optional)', kind: 'media'),
    ],
    'glass_screen': [_Field('media', 'Footage / photos on the screen', kind: 'medias')],
    'title_slam': [
      _Field('title', 'Title', initial: 'VIRAL 3D'),
      _Field('subtitle', 'Subtitle (letters pop in)', initial: 'ANIMATION'),
      _Field('hit', 'Impact sound (optional)', kind: 'audio'),
      _Field('music', 'Music that drops in (optional)', kind: 'audio'),
    ],
    'foreground_wipe': [
      _Field('media', 'Cut-out that sweeps past (tree, cloud…)', kind: 'media'),
      _Field('direction', 'Direction: left / right', initial: 'left'),
    ],
    'icon_badge': [
      _Field('media', 'Icon picture (optional)', kind: 'media'),
      _Field('text', 'Or emoji / letters', initial: '★'),
      _Field('shape', 'Shape: rounded / circle', initial: 'rounded'),
      _Field('color', 'Colour', initial: '#2E7DF6'),
    ],
    'icon_stream': [
      _Field('icons', 'Icon pictures', kind: 'medias'),
      _Field('icon_texts', 'Or emoji / short texts (comma separated)', kind: 'list', initial: '₹, \$, €, ¥'),
      _Field('count', 'How many', kind: 'number', initial: 8),
    ],
    'scanner': [
      _Field('logo', 'Logo (optional)', kind: 'media'),
      _Field('target_media', 'Targets (faces / photos)', kind: 'medias'),
      _Field('labels', 'Target labels (comma separated)', kind: 'list', initial: 'TARGET 1, TARGET 2, TARGET 3'),
    ],
    'silhouette_crowd': [
      _Field('media', 'Cut-out people (PNG)', kind: 'medias'),
      _Field('labels', 'Labels (comma separated)', kind: 'list'),
      _Field('color', 'Fill colour', initial: '#FFC107'),
      _Field('highlight', 'Keep this one in colour (number, optional)', kind: 'number'),
    ],
    'number_tiles': [_Field('text', 'Characters', initial: '200 Y'), _Field('word', 'Word after (optional)', initial: 'AGO')],
    'date_title': [_Field('text', 'Date / year', initial: '1831'), _Field('subtitle', 'Line under it (optional)')],
    'article': [
      _Field('media', 'Screenshot of the article', kind: 'media'),
      _Field('phrase', 'Words to mark (found with AI vision)', hint: 'exact words from the screenshot'),
      _Field('mark_style', 'Mark: highlight / circle / underline / redact', initial: 'highlight'),
      _Field('coming_up', '"Coming up next" tag (yes / no)', initial: 'no'),
    ],
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
    'name_tag': Icons.badge_outlined,
    'character_label': Icons.label_outline,
    'arrow_callout': Icons.ads_click,
    'censor_bar': Icons.visibility_off_outlined,
    'plaque': Icons.account_balance_outlined,
    'poster': Icons.wallpaper,
    'glass_screen': Icons.desktop_windows_outlined,
    'title_slam': Icons.bolt,
    'foreground_wipe': Icons.forest_outlined,
    'icon_badge': Icons.apps,
    'icon_stream': Icons.scatter_plot_outlined,
    'scanner': Icons.radar,
    'silhouette_crowd': Icons.groups_outlined,
    'number_tiles': Icons.casino_outlined,
    'date_title': Icons.event_outlined,
    'article': Icons.newspaper,
  };

  static const _shapes = [
    ('rect', 'Rectangle', Icons.crop_square),
    ('ellipse', 'Circle', Icons.circle_outlined),
    ('star', 'Star', Icons.star_border),
    ('polygon', 'Polygon', Icons.hexagon_outlined),
    ('arrow', 'Arrow line', Icons.trending_flat),
    ('line', 'Line', Icons.horizontal_rule),
  ];

  void _pick(String t) => setState(() => _select(t));

  void _select(String t) {
    _type = t;
    _error = null;
    _ctl.clear();
    _media.clear();
    _multi.clear();
    for (final f in _fields[t] ?? const <_Field>[]) {
      _ctl[f.key] = TextEditingController(text: f.initial == null ? '' : '${f.initial}');
    }
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
        'start': widget.c.time, // V2-B: add_layer no longer defaults to the playhead
      };
    } else {
      cmd = {
        'op': 'add_layer', 'type': 'shape', 'kind': kind, 'width': w * 0.2, 'height': w * 0.2,
        'fill': '#FFC400', 'stroke': '#FFFFFF', 'stroke_width': 0, 'sides': kind == 'star' ? 5 : 6,
        'name': kind[0].toUpperCase() + kind.substring(1),
        'start': widget.c.time, // V2-B
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

  Future<void> _addComponent() async {
    final t = _type!;
    final cmd = <String, dynamic>{'op': 'add_component', 'type': t, 'start': widget.c.time};
    for (final f in _fields[t] ?? const <_Field>[]) {
      final v = _ctl[f.key]?.text.trim() ?? '';
      switch (f.kind) {
        case 'media':
        case 'audio':
          if (_media[f.key] != null) cmd[f.key] = _media[f.key];
        case 'medias':
          if ((_multi[f.key] ?? const {}).isNotEmpty) cmd[f.key] = _multi[f.key]!.toList();
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
    _shapeArgs(t, cmd);
    if (t == 'article' && cmd['phrase'] is String) {
      final phrase = cmd.remove('phrase') as String;
      final style = '${cmd.remove('mark_style') ?? 'highlight'}';
      final m = widget.c.project.media[cmd['media']];
      if (m == null) {
        setState(() => _error = 'Pick the screenshot first, then the words to mark.');
        return;
      }
      setState(() {
        _busy = true;
        _error = null;
      });
      try {
        final img = await Director.thumbnail(m, size: 1600);
        if (img == null) throw Exception('could not read the screenshot');
        final boxes = await PhraseFinder.find(settings: await AiSettings.load(), image: img, phrase: phrase, width: m.width, height: m.height);
        if (boxes.isEmpty) {
          if (mounted) showSnack(context, 'Could not find "$phrase" in the screenshot. Added without a mark.');
        } else {
          cmd['marks'] = [
            {'boxes': boxes, 'style': style, 'delay': 1.0, if (style == 'redact') 'word': phrase},
          ];
        }
      } catch (e) {
        if (mounted) showSnack(context, 'Phrase finder: $e');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      if (!mounted) return;
    }
    cmd.remove('mark_style');
    if (_tryRun(cmd) != null && mounted) {
      Navigator.pop(context);
      showSnack(context, '${Components.label(t)} added. Edit its parts in the timeline.');
    }
  }

  /// Turns form values into the component's params.
  void _shapeArgs(String t, Map<String, dynamic> cmd) {
    switch (t) {
      case 'icon_stream':
        cmd['icons'] = [...(cmd['icons'] as List? ?? const []), ...(cmd.remove('icon_texts') as List? ?? const [])];
        if ((cmd['icons'] as List).isEmpty) cmd.remove('icons');
      case 'scanner':
        final media = (cmd.remove('target_media') as List? ?? const []).map((e) => '$e').toList();
        final labels = (cmd.remove('labels') as List? ?? const []).map((e) => '$e').toList();
        final n = media.isNotEmpty ? media.length : labels.length;
        if (n > 0) {
          cmd['targets'] = [
            for (int i = 0; i < n; i++) {if (i < media.length) 'media': media[i], 'label': i < labels.length ? labels[i] : ''},
          ];
        }
      case 'character_label':
        final sel = widget.c.selectedLayerId;
        if (sel != null) cmd['attach'] = sel;
      case 'article':
        cmd['coming_up'] = '${cmd['coming_up'] ?? 'no'}'.toLowerCase().startsWith('y');
      case 'silhouette_crowd':
        if (cmd['highlight'] is double) cmd['highlight'] = (cmd['highlight'] as double).round();
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
    final audio = widget.c.project.media.values.where((m) => m.type == MediaType.audio).toList();
    Widget picker(_Field f) {
      if (f.kind == 'medias') {
        final sel = _multi.putIfAbsent(f.key, () => <String>{});
        return InputDecorator(
          decoration: InputDecoration(labelText: f.label, isDense: true),
          child: media.isEmpty
              ? const Text('Import photos first', style: TextStyle(color: MA.textDim, fontSize: 12))
              : Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final m in media)
                    FilterChip(
                      label: Text(m.name, overflow: TextOverflow.ellipsis),
                      selected: sel.contains(m.id),
                      onSelected: (v) => setState(() => v ? sel.add(m.id) : sel.remove(m.id)),
                    ),
                ]),
        );
      }
      final list = f.kind == 'audio' ? audio : media;
      return DropdownButtonFormField<String>(
        initialValue: _media[f.key],
        decoration: InputDecoration(labelText: f.label, isDense: true),
        items: [for (final m in list) DropdownMenuItem(value: m.id, child: Text(m.name, overflow: TextOverflow.ellipsis))],
        onChanged: (v) => setState(() => _media[f.key] = v),
      );
    }

    return [
      if (t == 'map' && !WorldMap.loaded)
        const Text('Map data is still loading, try again in a second.', style: TextStyle(color: Colors.orangeAccent)),
      if (t == 'character_label')
        Text(widget.c.selectedLayer == null ? 'Tip: select a layer first to pin the label to it.' : 'Pinned to the selected layer: ${widget.c.selectedLayer!.name}',
            style: const TextStyle(fontSize: 12, color: MA.textDim)),
      for (final f in _fields[t] ?? const <_Field>[])
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: f.kind == 'media' || f.kind == 'medias' || f.kind == 'audio'
              ? picker(f)
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
      FilledButton.icon(
        onPressed: _busy ? null : _addComponent,
        icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.add),
        label: Text(_busy ? 'Finding the words…' : 'Add'),
      ),
    ];
  }
}
