import 'package:flutter/material.dart';

import '../../fonts/font_catalog.dart';
import '../../fonts/text_styles.dart';
import 'font_licenses.dart';

/// TextStyle for previewing [family] with [text] (bundled family, Devanagari
/// fallback, weight snapped to what the font has).
TextStyle fontPreviewStyle(String family, String text, {double size = 24, int weight = 700, Color color = Colors.white}) {
  final info = FontCatalog.lookup(family);
  final w = info?.clampWeight(weight) ?? weight;
  return TextStyle(
    fontFamily: FontCatalog.resolve(family, text),
    fontFamilyFallback: FontCatalog.fallbackFor(family),
    fontSize: size,
    fontWeight: FontWeight.values[((w ~/ 100) - 1).clamp(0, FontWeight.values.length - 1)],
    color: color,
    height: 1.2,
  );
}

/// Searchable font list with live previews, categories and a Hindi preview.
///
/// `final f = await FontPicker.open(context, layer.text?.fontFamily);`
/// returns the chosen family (pubspec name) or null when cancelled.
class FontPicker extends StatefulWidget {
  final String? current;
  final String? sample;
  const FontPicker({super.key, this.current, this.sample});

  static Future<String?> open(BuildContext context, String? current, {String? sample}) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final picker = FontPicker(current: current, sample: sample);
    if (wide) {
      return showDialog<String>(
        context: context,
        builder: (ctx) => Dialog(
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720), child: picker),
        ),
      );
    }
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SizedBox(height: MediaQuery.sizeOf(ctx).height * 0.85, child: picker),
    );
  }

  @override
  State<FontPicker> createState() => _FontPickerState();
}

class _FontPickerState extends State<FontPicker> {
  static const _hindiSample = 'भारत का इतिहास 1947';
  final _search = TextEditingController();
  late final TextEditingController _sample;
  FontCategory? _cat;
  bool _hindi = false;

  @override
  void initState() {
    super.initState();
    final s = widget.sample?.trim() ?? '';
    _sample = TextEditingController(text: s.isEmpty ? 'The Untold Story 1831' : (s.length > 40 ? s.substring(0, 40) : s));
    _hindi = FontCatalog.hasDevanagari(_sample.text);
  }

  @override
  void dispose() {
    _search.dispose();
    _sample.dispose();
    super.dispose();
  }

  String get _previewText => _hindi && !FontCatalog.hasDevanagari(_sample.text) ? _hindiSample : _sample.text;

  List<FontInfo> get _fonts {
    var list = FontCatalog.search(_search.text);
    if (_cat != null) list = [for (final f in list) if (f.category == _cat) f];
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final current = FontCatalog.lookup(widget.current)?.family ?? widget.current;
    final fonts = _fonts;
    final text = _previewText;
    return Material(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(children: [
            const Expanded(child: Text('Font', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
            IconButton(
              tooltip: 'Font licences',
              icon: const Icon(Icons.info_outline, size: 20),
              onPressed: () {
                FontLicenses.ensureRegistered();
                showLicensePage(context: context, applicationName: 'MotionAI');
              },
            ),
            IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: TextField(
            controller: _search,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 20),
              hintText: 'Search fonts (serif, script, hindi, date...)',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _sample,
                decoration: const InputDecoration(isDense: true, labelText: 'Preview text', border: OutlineInputBorder()),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            FilterChip(
              label: const Text('हिंदी'),
              selected: _hindi,
              onSelected: (v) => setState(() => _hindi = v),
            ),
          ]),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: ChoiceChip(label: const Text('All'), selected: _cat == null, onSelected: (_) => setState(() => _cat = null)),
              ),
              for (final c in FontCategory.values)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: ChoiceChip(
                    label: Text(c.label),
                    selected: _cat == c,
                    onSelected: (_) => setState(() => _cat = _cat == c ? null : c),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: fonts.isEmpty
              ? const Center(child: Text('No font matches', style: TextStyle(color: Colors.white54)))
              : ListView.builder(
                  itemCount: fonts.length,
                  itemBuilder: (ctx, i) => _FontTile(
                    info: fonts[i],
                    text: text,
                    selected: fonts[i].family == current,
                    onTap: () => Navigator.pop(context, fonts[i].family),
                  ),
                ),
        ),
      ]),
    );
  }
}

class _FontTile extends StatelessWidget {
  final FontInfo info;
  final String text;
  final bool selected;
  final VoidCallback onTap;
  const _FontTile({required this.info, required this.text, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final deva = FontCatalog.hasDevanagari(text);
    final swapped = deva && !info.hasDevanagari;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        color: selected ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.16) : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(
                info.family,
                style: const TextStyle(fontSize: 12, color: Colors.white70, fontWeight: FontWeight.w600),
              ),
            ),
            if (info.hasDevanagari) const _Tag('हिंदी'),
            if (swapped) _Tag('Hindi → ${FontCatalog.devanagariFor(info.family)}'),
            if (selected) const Icon(Icons.check, size: 18),
          ]),
          const SizedBox(height: 4),
          Text(
            text.isEmpty ? info.family : text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: fontPreviewStyle(info.family, text, size: 28, weight: info.maxWeight >= 700 ? 700 : 400),
          ),
          Text(info.use, style: const TextStyle(fontSize: 11, color: Colors.white38)),
        ]),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  const _Tag(this.text);

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.white24)),
        child: Text(text, style: const TextStyle(fontSize: 10, color: Colors.white60)),
      );
}

/// Grid of [TextStylePresets] rendered in their own font; returns a preset id.
class TextStylePicker extends StatelessWidget {
  const TextStylePicker({super.key});

  static Future<String?> open(BuildContext context) => showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (ctx) => SizedBox(height: MediaQuery.sizeOf(ctx).height * 0.7, child: const TextStylePicker()),
      );

  static Color _hex(Object? v) {
    final s = '${v ?? '#FFFFFF'}'.replaceFirst('#', '');
    final n = int.tryParse(s.length == 6 ? 'FF$s' : s, radix: 16) ?? 0xFFFFFFFF;
    return Color(n);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(children: [
            const Expanded(child: Text('Text style', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
            IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
          ]),
        ),
        Expanded(
          child: GridView.extent(
            maxCrossAxisExtent: 260,
            childAspectRatio: 1.7,
            padding: const EdgeInsets.all(12),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: [
              for (final p in TextStylePresets.all)
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => Navigator.pop(context, p.id),
                  child: Ink(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: const Color(0xFF1B1E26), borderRadius: BorderRadius.circular(10)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.label, style: const TextStyle(fontSize: 11, color: Colors.white60)),
                      Expanded(
                        child: Center(
                          child: FittedBox(
                            child: Text(
                              p.sample,
                              style: fontPreviewStyle(p.font, p.sample,
                                  size: 30, weight: (p.keys['font_weight'] as int?) ?? 700, color: _hex(p.keys['text_color'])),
                            ),
                          ),
                        ),
                      ),
                      Text(p.font, style: const TextStyle(fontSize: 10, color: Colors.white38)),
                    ]),
                  ),
                ),
            ],
          ),
        ),
      ]),
    );
  }
}

/// Font + style buttons for the text section of the layer panel.
/// [run] executes an edit command (EditorController.tryRun).
class FontPanelRow extends StatelessWidget {
  final String? fontFamily;
  final String text;
  final void Function(Map<String, dynamic> cmd) run;
  final String layerId;
  const FontPanelRow({super.key, required this.layerId, required this.fontFamily, required this.text, required this.run});

  @override
  Widget build(BuildContext context) {
    final name = FontCatalog.resolve(fontFamily, text) ?? 'Default';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        const SizedBox(width: 84, child: Text('Font', style: TextStyle(fontSize: 12.5, color: Colors.white70))),
        Expanded(
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft, padding: const EdgeInsets.symmetric(horizontal: 10)),
            onPressed: () async {
              final f = await FontPicker.open(context, fontFamily, sample: text);
              if (f != null) run({'op': 'update_layer', 'layer': layerId, 'font': f});
            },
            child: Text(name, overflow: TextOverflow.ellipsis, style: fontPreviewStyle(name, name, size: 15, weight: 400)),
          ),
        ),
        const SizedBox(width: 6),
        OutlinedButton.icon(
          icon: const Icon(Icons.auto_awesome, size: 16),
          label: const Text('Style'),
          onPressed: () async {
            final id = await TextStylePicker.open(context);
            if (id != null) run({'op': 'update_layer', 'layer': layerId, 'text_style': id});
          },
        ),
      ]),
    );
  }
}
