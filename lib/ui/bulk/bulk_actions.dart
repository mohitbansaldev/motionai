// BULK (Agent N): bulk operations on the editor's multi-selection.
import 'dart:convert';

import 'package:flutter/services.dart';

import '../../captions/builder.dart';
import '../../captions/caption_track.dart';
import '../../captions/styles.dart';
import '../../core/commands/bulk_commands.dart';
import '../../core/commands/edit_commands.dart';
import '../../core/model/layer.dart';
import '../../core/model/project.dart';
import '../../library/asset_library.dart';
import '../../state/editor_controller.dart';

/// Every bulk action is ONE edit command (a `batch`, `for_layers` or a
/// bulk op), so it is one undo step. Methods return an error message or null.
class BulkActions {
  final EditorController c;
  BulkActions(this.c);

  /// In-app clipboards (the layer clipboard also goes to the system clipboard as JSON).
  static Map<String, dynamic>? layerClipboard;
  static List<Map<String, dynamic>>? effectClipboard;
  static ({Map<String, dynamic> props, double start})? animationClipboard;

  /// Selected layers, top first.
  List<Layer> get layers => c.selectedLayers;
  List<String> get ids => [for (final l in layers) l.id];
  bool get isEmpty => ids.isEmpty;

  List<String> idsWhere(bool Function(Layer l) test) => [for (final l in layers) if (test(l)) l.id];

  String? _forLayers(List<String> ids, Map<String, dynamic> command, {bool skipErrors = false, bool record = true}) {
    if (ids.isEmpty) return 'Nothing selected that this applies to';
    return c.tryRun({'op': 'for_layers', 'layers': ids, 'command': command, if (skipErrors) 'skip_errors': true}, record: record);
  }

  // ----------------------------------------------------------- structure

  String? delete() {
    if (isEmpty) return null;
    return c.tryRun({'op': 'batch', 'commands': [for (final id in ids) {'op': 'remove_layer', 'layer': id}]});
  }

  /// Duplicates every selected layer (copies sit above their originals) and
  /// selects the copies. Parent links between copied layers follow the copies.
  String? duplicate({bool record = true}) {
    if (isEmpty) return null;
    final map = {for (final id in ids) id: Ids.next('L')};
    final cmds = [for (final e in map.entries) {'op': 'duplicate_layer', 'layer': e.key, 'new_id': e.value}];
    for (final l in layers) {
      final p = l.parentId;
      if (p != null && map.containsKey(p)) cmds.add({'op': 'update_layer', 'layer': map[l.id]!, 'parent': map[p]!});
    }
    final err = c.tryRun({'op': 'batch', 'commands': cmds}, record: record);
    if (err == null) c.selectMany(map.values, primary: map[c.selectedLayerId]);
    return err;
  }

  String? setVisible(bool v) => _forLayers(ids, {'op': 'update_layer', 'layer': r'$layer', 'visible': v});
  String? setLocked(bool v) => _forLayers(ids, {'op': 'update_layer', 'layer': r'$layer', 'locked': v});
  String? toggleVisible() => setVisible(!layers.any((l) => l.visible));
  String? toggleLocked() => setLocked(!layers.every((l) => l.locked));

  /// Splits every selected layer that crosses the playhead.
  String? splitAtPlayhead() {
    final t = c.time;
    final hit = idsWhere((l) => t > l.start + 1e-6 && t < l.end - 1e-6);
    if (hit.isEmpty) return 'No selected layer crosses the playhead';
    return _forLayers(hit, {'op': 'split_layer', 'layer': r'$layer', 'time': t});
  }

  /// Trims the start ([inPoint]) or end of every selected layer to the playhead.
  String? trimToPlayhead({required bool inPoint}) {
    final t = c.time;
    final hit = idsWhere((l) => t > l.start + 1e-6 && t < l.end - 1e-6);
    if (hit.isEmpty) return 'No selected layer crosses the playhead';
    return _forLayers(hit, {'op': 'trim_layer', 'layer': r'$layer', inPoint ? 'in' : 'out': t});
  }

  String? reorder(bool up) {
    final sel = ids;
    if (sel.isEmpty) return null;
    final order = [for (final l in c.comp.layers) l.id];
    if (up) {
      for (int i = 1; i < order.length; i++) {
        if (sel.contains(order[i]) && !sel.contains(order[i - 1])) {
          final t = order[i - 1];
          order[i - 1] = order[i];
          order[i] = t;
        }
      }
    } else {
      for (int i = order.length - 2; i >= 0; i--) {
        if (sel.contains(order[i]) && !sel.contains(order[i + 1])) {
          final t = order[i + 1];
          order[i + 1] = order[i];
          order[i] = t;
        }
      }
    }
    return c.tryRun({
      'op': 'batch',
      // Placing each layer from the top keeps the already placed ones in order.
      'commands': [
        for (int i = 0; i < order.length; i++) {'op': 'reorder_layer', 'layer': order[i], 'index': i},
      ],
    });
  }

  // ------------------------------------------------------------- moving

  String? shiftTime(double by, {bool record = true}) {
    final movable = idsWhere((l) => !l.locked);
    if (movable.isEmpty) return null;
    return c.tryRun({'op': 'shift_time', 'layers': movable, 'by': by}, record: record);
  }

  String? nudge(double dx, double dy, {bool record = true}) {
    final movable = idsWhere((l) => !l.locked);
    if (movable.isEmpty) return null;
    return c.tryRun({'op': 'transform_layers', 'layers': movable, 'move': [dx, dy]}, record: record);
  }

  String? transform({double scale = 1, double rotate = 0, List<double>? center, bool record = true}) {
    final movable = idsWhere((l) => !l.locked);
    if (movable.isEmpty) return null;
    return c.tryRun({
      'op': 'transform_layers',
      'layers': movable,
      'scale': scale,
      'rotate': rotate,
      'center': ?center,
    }, record: record);
  }

  String? align(String mode, {String? to}) =>
      isEmpty ? null : c.tryRun({'op': 'align', 'layers': ids, 'mode': mode, 'to': ?to});

  String? distribute(String axis, {String by = 'center'}) =>
      c.tryRun({'op': 'distribute', 'layers': ids, 'axis': axis, 'by': by});

  /// [mode]: start (at playhead) | end | stagger | sequence. Stagger/sequence
  /// go in stacking order, top layer first.
  String? alignTime(String mode, {double? step, double? frames, double? time}) => isEmpty
      ? null
      : c.tryRun({
          'op': 'align_time',
          'layers': ids,
          'mode': mode,
          'order': 'stack',
          'step': ?step,
          'frames': ?frames,
          if (mode == 'start' || mode == 'end') 'time': time ?? c.time,
          if (time != null && mode != 'start' && mode != 'end') 'time': time,
        });

  // ---------------------------------------------------------- properties

  /// Sets [prop] (optionally one [component]) on every selected layer that
  /// has it. [relative]: adds [value] (rotation, position offset…) instead.
  String? setProperty(String prop, double value, {int? component, bool relative = false, bool record = true}) {
    final key = component == null ? prop : '$prop.${'xyz'[component]}';
    final has = idsWhere((l) => l.props.containsKey(prop) && !(prop == Props.position && l.type == LayerType.audio));
    if (relative) return _forLayers(has, {'op': 'offset_property', 'layer': r'$layer', 'prop': key, 'by': value}, record: record);
    final v = component == null && (prop == Props.scale) ? [value, value] : value;
    return _forLayers(has, {'op': 'set_property', 'layer': r'$layer', 'prop': key, 'value': v}, record: record);
  }

  /// Multiplies [prop] on every selected layer (e.g. scale × 1.1).
  String? scaleProperty(String prop, double factor, {bool record = true}) {
    final has = idsWhere((l) => l.props.containsKey(prop));
    return _forLayers(has, {'op': 'offset_property', 'layer': r'$layer', 'prop': prop, 'factor': factor}, record: record);
  }

  String? setSpeed(double s) => _forLayers(
      idsWhere((l) => l.type == LayerType.video || l.type == LayerType.audio || l.type == LayerType.comp),
      {'op': 'update_layer', 'layer': r'$layer', 'speed': s});

  /// Make 3D / make 2D for every selected layer (audio excluded). Layers
  /// keep their look: z position stays as it is (0 for flat layers).
  String? set3D(bool on) => _forLayers(
      idsWhere((l) => l.type != LayerType.audio && l.is3D != on), {'op': 'update_layer', 'layer': r'$layer', 'is3d': on});

  /// Shift+3: all 3D when any is 2D, else all 2D.
  String? toggle3D() => set3D(layers.any((l) => l.type != LayerType.audio && !l.is3D));

  /// "Compose flat, play deep" depth bands (needs the scene agent's `make_3d`).
  static bool get hasDepthMake3d => EditCommands.ops.contains('make_3d');
  String? make3dScene() => c.tryRun({'op': 'make_3d', 'layers': idsWhere((l) => l.type != LayerType.audio)});

  String? setBlend(String mode) => _forLayers(ids, {'op': 'update_layer', 'layer': r'$layer', 'blend': mode});

  String? parentTo(String? parentId) {
    final targets = idsWhere((l) => l.id != parentId);
    if (targets.isEmpty) return null;
    return c.tryRun({'op': 'parent_layers', 'layers': targets, 'parent': parentId});
  }

  String? group() => isEmpty ? null : c.tryRun({'op': 'group_layers', 'layers': ids});

  String? setMatte(String? matteId, {String mode = 'alpha'}) => _forLayers(
      idsWhere((l) => l.id != matteId && l.type != LayerType.audio),
      {'op': 'update_layer', 'layer': r'$layer', 'matte': matteId == null ? 'none' : {'layer': matteId, 'mode': mode}});

  // ------------------------------------------------------------- effects

  String? addEffect(String type) =>
      _forLayers(idsWhere((l) => l.type != LayerType.audio && l.type != LayerType.nullObject), {'op': 'add_effect', 'layer': r'$layer', 'effect': type});

  String? removeEffectType(String type) {
    final cmds = [
      for (final l in layers)
        for (final e in l.effects)
          if (e.type == type) {'op': 'remove_effect', 'layer': l.id, 'effect': e.id},
    ];
    if (cmds.isEmpty) return null;
    return c.tryRun({'op': 'batch', 'commands': cmds});
  }

  /// Copies the primary layer's effects.
  String? copyEffects() {
    final l = c.selectedLayer;
    if (l == null) return 'Select a layer';
    if (l.effects.isEmpty) return '${l.name} has no effects';
    effectClipboard = [for (final e in l.effects) e.toJson()];
    return null;
  }

  String? pasteEffects({bool replace = false}) {
    final fx = effectClipboard;
    if (fx == null) return 'Copy effects first';
    return _forLayers(idsWhere((l) => l.type != LayerType.audio), {'op': 'paste_effects', 'layer': r'$layer', 'effects': fx, 'replace': replace});
  }

  // ----------------------------------------------------------- animation

  String? animate(String preset, {required bool isIn, double? duration}) => _forLayers(
      idsWhere((l) => l.type != LayerType.audio),
      {'op': isIn ? 'animate_in' : 'animate_out', 'layer': r'$layer', 'preset': preset, 'duration': ?duration});

  /// Copies the primary layer's transform animation (keyframes relative to its start).
  String? copyAnimation() {
    final l = c.selectedLayer;
    if (l == null) return 'Select a layer';
    final props = {for (final k in Props.all) if (l.props[k]?.isAnimated ?? false) k: l.props[k]!.toJson()};
    if (props.isEmpty) return '${l.name} has no keyframes';
    animationClipboard = (props: props, start: l.start);
    return null;
  }

  String? pasteAnimation() {
    final a = animationClipboard;
    if (a == null) return 'Copy an animation first';
    return _forLayers(ids, {'op': 'paste_animation', 'layer': r'$layer', 'props': a.props, 'from_start': a.start});
  }

  String? applyStyle(String style) {
    final media = idsWhere((l) => l.type == LayerType.image || l.type == LayerType.video);
    if (media.isEmpty) return 'Looks apply to photo and video layers';
    return c.tryRun({'op': 'apply_style', 'style': style, 'layers': media});
  }

  // ----------------------------------------------------------------- text

  List<String> get textIds => idsWhere((l) => l.type == LayerType.text);

  /// Any text keys of `update_layer` (font, text_style, font_size, text_color, animator…) on every text layer.
  String? setText(Map<String, dynamic> keys, {bool record = true}) =>
      _forLayers(textIds, {'op': 'update_layer', 'layer': r'$layer', ...keys}, record: record);

  /// Caption layers in the selection (main comp only).
  List<Layer> get captionLayers =>
      c.inPrecomp ? const [] : [for (final l in layers) if (CaptionBuilder.idPattern.hasMatch(l.id) && l.text != null) l];

  /// Redraws the selected captions in [styleId], keeping their words and timing.
  String? applyCaptionStyle(String styleId) {
    final caps = captionLayers;
    if (caps.isEmpty) return 'Select caption layers first';
    final scratch = Composition(id: 'sel', name: 'sel', width: c.comp.width, height: c.comp.height, layers: caps);
    final cues = CaptionTrack.read(scratch);
    final style = CaptionStyles.byId(styleId);
    final cmds = [
      for (final l in caps) {'op': 'remove_layer', 'layer': l.id},
      ...CaptionBuilder.build(c.project, cues, style),
    ];
    return c.tryRun({'op': 'batch', 'commands': cmds});
  }

  // --------------------------------------------------------- comps & library

  /// Precomposes the selection; the new comp layer becomes the selection.
  String? precompose({String? name}) {
    if (isEmpty) return null;
    try {
      final r = c.run({'op': 'precompose', 'layers': ids, 'name': ?name});
      if (r.createdIds.length >= 2) c.select(r.createdIds[1]);
      return null;
    } on CommandError catch (e) {
      return e.message;
    }
  }

  /// Adds the photos / videos / audio used by the selection to the asset library.
  Future<String> addMediaToLibrary() async {
    final media = <String, MediaAsset>{};
    for (final l in layers) {
      final m = l.mediaId == null ? null : c.project.media[l.mediaId!];
      if (m != null) media[m.id] = m;
    }
    if (media.isEmpty) return 'The selection uses no photos, videos or audio';
    final lib = await AssetLibrary.shared();
    for (final m in media.values) {
      await lib.addMedia(m, origin: c.project.name);
    }
    return 'Added ${media.length} file${media.length == 1 ? '' : 's'} to the library';
  }

  // ------------------------------------------------------------ clipboard

  /// Ctrl+C: the selection as a `paste_layers` command (JSON on the system clipboard).
  Future<String?> copyLayers() async {
    if (isEmpty) return 'Nothing selected';
    final cmd = BulkCommands.clipboardFor(c.project, c.comp, ids);
    layerClipboard = cmd;
    try {
      await Clipboard.setData(ClipboardData(text: jsonEncode(cmd)));
    } catch (_) {
      // No system clipboard (tests, some Linux setups): the in-app copy is enough.
    }
    return null;
  }

  Future<String?> cutLayers() async {
    final err = await copyLayers();
    return err ?? delete();
  }

  /// Ctrl+V: pastes copied layers at the playhead ([atOriginalTime] keeps
  /// their times). Works in another comp or project; the pasted layers are selected.
  Future<String?> pasteLayers({bool atOriginalTime = false}) async {
    Map<String, dynamic>? cmd;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      if (text != null && text.startsWith('{')) {
        final j = jsonDecode(text);
        if (j is Map && j['op'] == 'paste_layers') cmd = Map<String, dynamic>.from(j);
      }
    } catch (_) {
      // Fall back to the in-app clipboard.
    }
    cmd ??= layerClipboard;
    if (cmd == null) return 'Copy layers first (Ctrl+C)';
    final primary = c.selectedLayerId;
    final index = primary == null ? 0 : c.comp.indexOf(primary).clamp(0, c.comp.layers.length);
    return c.tryRun({...cmd, if (!atOriginalTime) 'time': c.time, 'index': index});
  }
}
