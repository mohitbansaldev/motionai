import 'dart:math' as math;

import '../core/commands/edit_commands.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import '../core/presets/components.dart';
import '../core/presets/motion_presets.dart';
import '../core/presets/world_map.dart';
import 'capabilities.dart';
import 'chapters.dart';
import 'sfx.dart';
import '../services/captions.dart';

/// One line of the story and the visual chosen for it.
class Beat {
  double start, end;
  String line;
  Map<String, dynamic> visual;
  bool keep = true;
  int chapter; // Chapter.index
  int lineIndex; // narration line (-1 = none)
  String role; // '' | card (chapter title) | split (extra shot of a line) | interrupt
  Beat(this.start, this.end, this.line, this.visual, {this.chapter = 0, this.lineIndex = -1, this.role = ''});

  double get length => end - start;

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'line': line,
        'visual': visual,
        if (!keep) 'keep': false,
        if (chapter != 0) 'chapter': chapter,
        if (lineIndex >= 0) 'li': lineIndex,
        if (role.isNotEmpty) 'role': role,
      };

  static Beat fromJson(Map<String, dynamic> j) => Beat(
        (j['start'] as num).toDouble(),
        (j['end'] as num).toDouble(),
        '${j['line'] ?? ''}',
        Map<String, dynamic>.from(j['visual'] as Map? ?? const {'aroll': true}),
        chapter: (j['chapter'] as num?)?.toInt() ?? 0,
        lineIndex: (j['li'] as num?)?.toInt() ?? -1,
        role: '${j['role'] ?? ''}',
      )..keep = j['keep'] != false;

  Beat copy({double? start, double? end, Map<String, dynamic>? visual, String? role}) =>
      Beat(start ?? this.start, end ?? this.end, line, visual ?? Map<String, dynamic>.from(this.visual),
          chapter: chapter, lineIndex: lineIndex, role: role ?? this.role)
        ..keep = keep;
}


class BuildOptions {
  String? arollLayer; // talking-head layer id
  String? musicMedia; // audio media id
  double musicLevel; // 0..1 when nobody talks
  double duckLevel; // 0..1 under the voice
  List<(double, double)> speech; // voice intervals, composition seconds
  Map<String, String> sfxMedia; // sound kind → media id
  double sfxLevel; // 0..1
  Map<String, (String, String)> cutouts; // media id → (subject id, background id)
  List<WordTiming>? captionWords; // composition seconds
  CaptionOptions? captions;
  String? look; // MotionPresets style for B-roll
  String tag;
  List<Chapter> chapters; // Director v2: per-chapter ids, looks and atmosphere
  Capabilities? caps;

  BuildOptions({
    this.arollLayer,
    this.musicMedia,
    this.musicLevel = 0.32,
    this.duckLevel = 0.09,
    this.speech = const [],
    this.sfxMedia = const {},
    this.sfxLevel = 0.55,
    this.cutouts = const {},
    this.captionWords,
    this.captions,
    this.look,
    String? tag,
    this.chapters = const [],
    this.caps,
  }) : tag = tag ?? DateTime.now().millisecondsSinceEpoch.toRadixString(36);
}

/// Turns a storyboard into edit commands: B-roll with camera moves, depth
/// shots from cut-outs (text behind the subject), doc-kit components,
/// presenter punch-ins, sound effects on cuts, music ducked under the voice,
/// and captions. Pure Dart, so it is unit-tested.
///
/// With chapters (Director v2) every layer a chapter creates starts with
/// `d<tag>c<chapter>_`, so one chapter can be rebuilt on its own
/// ([rebuildChapter]); chapters carry their own look and atmosphere.
class StoryBuilder {
  static const transitions = [
    'fade', 'zoom_in', 'zoom_out', 'slide_left', 'slide_right', 'whip', 'blur', 'pop', 'shatter',
    'iris', 'ink', 'smoke', 'spin', 'flash', 'glitch_flash', 'foreground_wipe',
  ];
  static const moves = ['ken_burns', 'push_in', 'pull_out', 'pan_left', 'pan_right', 'parallax', 'depth', ...moves3d];

  /// 3D camera moves ("compose flat, play deep": make_3d + camera_shot).
  static const moves3d = ['drift', 'fly_to', 'push_through', 'pass_by', 'reveal', 'pull_back', 'orbit'];

  /// Components that are drawn over whatever is below (no backdrop needed).
  static const overlays = [
    'map', 'lower_third', 'cta', 'pin', 'route_arrow', 'map_pin', 'map_route', 'name_tag', 'character_label',
    'arrow_callout', 'censor_bar', 'foreground_wipe', 'needle_pin',
  ];

  /// Components that bring their own full-frame backdrop.
  static const ownBackdrop = ['article', 'title_slam', 'glass_screen', 'route_follow', 'map_fly', 'room'];

  /// True when this build knows the 3D scene ops (they come with the scene branch).
  static bool get has3d => EditCommands.ops.contains('make_3d') && EditCommands.ops.contains('camera_shot');

  static const _seaColors = {'dark': '#0B1622', 'paper': '#D9CDB4', 'blue': '#0E4A6B'};

  /// Id prefix of everything built for [chapter].
  static String chapterPrefix(String tag, int chapter) => 'd${tag}c${chapter}_';

  /// Builds the storyboard. With [only], just that chapter's beats (no
  /// music or captions) — see [rebuildChapter].
  static List<Map<String, dynamic>> build(Project p, List<Beat> beats, BuildOptions o, {int? only}) {
    final comp = p.main;
    final w = comp.width, h = comp.height;
    final cmds = <Map<String, dynamic>>[];
    final chaptered = o.chapters.isNotEmpty;
    final can3d = o.caps?.has3d ?? has3d;
    final canParticles = o.caps?.particles ?? true;
    final chapterById = {for (final c in o.chapters) c.index: c};
    final sfx = <(double, String, int)>[]; // (time of impact, kind, chapter)
    final brollIds = <int, List<String>>{}; // chapter → B-roll layers (for the look)
    final atmos = <(double, double, String, int)>[]; // runs of (start, end, particles, chapter)
    final kept = beats.where((b) => b.keep && (only == null || b.chapter == only)).toList()..sort((a, b) => a.start.compareTo(b.start));
    final aroll = o.arollLayer == null ? null : comp.layerById(o.arollLayer!);
    final arollScale = aroll?.prop(Props.scale).staticValue[0] ?? 100.0;
    var prevWasAroll = true;
    final counters = <int, int>{};
    var musicFrom = 0.0; // a title slam keeps the intro silent until its drop
    String prefixOf(int ch) => chaptered ? chapterPrefix(o.tag, ch) : 'd${o.tag}_';

    for (final b in kept) {
      final v = b.visual;
      final dur = math.max(0.8, b.end - b.start);
      final key = chaptered ? b.chapter : 0;
      final n = counters[key] ?? 0;
      counters[key] = n + 1;
      final tag = '${prefixOf(b.chapter)}$n';
      final broll = brollIds.putIfAbsent(b.chapter, () => []);
      var trans = transitions.contains(v['transition']) ? '${v['transition']}' : 'fade';
      if (trans == 'foreground_wipe') {
        // Something sweeps past the lens and hides the cut at the beat start.
        cmds.add({'op': 'add_component', 'type': 'foreground_wipe', 'id': '${tag}_wipe', 'start': math.max(0.0, b.start - 0.35), 'length': 0.7, if (v['wipe_media'] is String && p.media[v['wipe_media']] != null) 'media': v['wipe_media']});
        trans = 'fade';
      }
      final sfxKind = v['sfx'] is String ? '${v['sfx']}' : null;

      // ---------------------------------------------------- presenter beats
      if (v['aroll'] == true) {
        if (v['punch'] == true && aroll != null) {
          // A jump cut: hold the normal framing until one frame before, then cut in.
          final s1 = arollScale * 1.14;
          final f = 1 / comp.fps;
          cmds.addAll([
            {'op': 'set_keyframe', 'target': aroll.id, 'prop': 'scale', 'time': b.start - f, 'value': [arollScale, arollScale, 100], 'ease': 'hold'},
            {'op': 'set_keyframe', 'target': aroll.id, 'prop': 'scale', 'time': b.start, 'value': [s1, s1, 100], 'ease': 'linear'},
            {'op': 'set_keyframe', 'target': aroll.id, 'prop': 'scale', 'time': b.start + dur - f, 'value': [s1 * 1.02, s1 * 1.02, 100], 'ease': 'hold'},
            {'op': 'set_keyframe', 'target': aroll.id, 'prop': 'scale', 'time': b.start + dur, 'value': [arollScale, arollScale, 100]},
          ]);
          if (sfxKind != null && sfxKind != 'none') sfx.add((b.start, sfxKind, b.chapter));
        }
        prevWasAroll = true;
        continue;
      }

      // ---------------------------------------------------- atmosphere (chapter mood or per shot)
      final atm = v['atmosphere'] is String ? '${v['atmosphere']}' : chapterById[b.chapter]?.atmosphere;
      final buildable = v['component'] == null || Components.types.contains(v['component']);
      if (buildable && canParticles && atm != null && atm != 'none' && Capabilities.particleKinds.contains(atm) && v['component'] != 'title_slam') {
        if (atmos.isNotEmpty && atmos.last.$3 == atm && atmos.last.$4 == b.chapter && b.start - atmos.last.$2 < 0.05) {
          atmos[atmos.length - 1] = (atmos.last.$1, b.start + dur, atm, b.chapter);
        } else {
          atmos.add((b.start, b.start + dur, atm, b.chapter));
        }
      }

      final media = v['media'] is String ? p.media[v['media']] : null;

      // ---------------------------------------------------- photo / video beats
      if (v['component'] == null && media != null && media.type != MediaType.audio) {
        var move = moves.contains(v['move']) ? '${v['move']}' : 'ken_burns';
        if (moves3d.contains(move) && (!can3d || media.type != MediaType.image)) move = move == 'pull_back' ? 'pull_out' : 'push_in';
        final cut = o.cutouts[media.id];
        if (moves3d.contains(move)) {
          final hasCut = cut != null && p.media[cut.$1] != null && p.media[cut.$2] != null;
          final ids = hasCut ? ['${tag}_bg', '${tag}_fg'] : ['${tag}_m'];
          final srcs = hasCut ? [cut.$2, cut.$1] : [media.id];
          for (int k = 0; k < ids.length; k++) {
            cmds.add({'op': 'add_layer', 'type': 'image', 'media': srcs[k], 'id': ids[k], 'name': k == 0 ? _short(b.line) : 'Subject', 'start': b.start, 'duration': dur, 'fit': 'cover'});
          }
          cmds.add({'op': 'animate_in', 'layer': ids.first, 'preset': trans, 'duration': 0.35});
          cmds.add({'op': 'make_3d', 'layers': ids, 'bands': hasCut ? {ids[0]: 'far', ids[1]: 'near'} : {ids[0]: 'mid'}, 'start': b.start});
          cmds.add({'op': 'camera_shot', 'move': move, 'target': ids.last, 'start': b.start, 'duration': dur});
          broll.addAll(ids);
          _overlays(cmds, v, tag, ids.last, b.start, dur);
        } else if (move == 'depth' && cut != null && p.media[cut.$1] != null && p.media[cut.$2] != null) {
          _depthShot(cmds, p, b.start, dur, tag, cut.$2, cut.$1, v['behind_text'] is String ? '${v['behind_text']}' : null, trans);
          broll.addAll(['${tag}_bg', '${tag}_fg']);
          _overlays(cmds, v, tag, '${tag}_fg', b.start, dur);
        } else {
          final id = '${tag}_m';
          cmds.add({
            'op': 'add_layer',
            'type': media.type == MediaType.video ? 'video' : 'image',
            'media': media.id,
            'id': id,
            'name': _short(b.line),
            'start': b.start,
            'duration': dur,
            'fit': 'cover',
          });
          cmds.addAll(_move(id, media, w, h, b.start, dur, move == 'depth' ? 'push_in' : move));
          cmds.add({'op': 'animate_in', 'layer': id, 'preset': trans, 'duration': trans == 'fade' ? 0.25 : 0.4});
          cmds.add({'op': 'add_effect', 'layer': id, 'effect': 'vignette', 'params': {'amount': 50}});
          broll.add(id);
          _overlays(cmds, v, tag, id, b.start, dur);
        }
        if (v['flash'] == true) _flash(cmds, tag, b.start, w, h);
        sfx.add((b.start, sfxKind ?? (prevWasAroll || trans != 'fade' ? 'whoosh' : 'none'), b.chapter));
        prevWasAroll = false;
        continue;
      }

      // ---------------------------------------------------- doc-kit components
      final type = '${v['component']}';
      if (!Components.types.contains(type)) continue;
      final needsBg = !overlays.contains(type) && !ownBackdrop.contains(type) && v['over_aroll'] != true;
      if (needsBg) {
        final bg = '${tag}_bg';
        cmds.add({'op': 'add_layer', 'type': 'solid', 'id': bg, 'name': 'Backdrop', 'color': v['bg'] is String ? v['bg'] : '#141414', 'start': b.start, 'duration': dur, 'width': w, 'height': h});
        cmds.add({'op': 'add_effect', 'layer': bg, 'effect': 'grunge', 'params': {'amount': 70}});
        cmds.add({'op': 'add_effect', 'layer': bg, 'effect': 'dust', 'params': {'amount': 35}});
        cmds.add({'op': 'add_effect', 'layer': bg, 'effect': 'vignette', 'params': {'amount': 75}});
      }
      final args = Map<String, dynamic>.from(v)
        ..remove('component')
        ..remove('sfx')
        ..remove('transition')
        ..remove('over_aroll')
        ..remove('bg')
        ..remove('atmosphere')
        ..remove('flash');
      if (args['media'] is String && p.media[args['media']] == null) args.remove('media');
      if (type == 'photo_card' && args['media'] == null) continue;
      if (type == 'title_slam') {
        final hit = o.sfxMedia['impact'] ?? o.sfxMedia['hit'];
        args['hit'] = hit != null && p.media[hit] != null ? hit : 'none';
        args['music'] = 'none'; // the music loop below starts on the drop
        args['drop'] = math.min(2.6, math.max(0.5, dur - 0.2));
        if (b.start < 1) musicFrom = b.start + (args['drop'] as double);
      }
      for (final k in ['media', 'logo', 'avatar']) {
        final mv = args[k];
        if (mv is List) args[k] = [for (final e in mv) if (p.media['$e'] != null) '$e'];
      }
      if (type == 'map') {
        _mapBeat(cmds, args, tag, b.start, dur, w, h);
      } else if (type == 'map_fly' && args['map'] == null) {
        // The scene branch's camera flight needs a map to fly over.
        _mapBeat(cmds, {
          'countries': [for (final k in ['from', 'to']) if (args[k] is String) args[k]],
          'style': args['style'] ?? 'paper',
        }, '${tag}_map', b.start, dur, w, h);
        cmds.add({'op': 'add_component', 'type': type, 'id': tag, 'start': b.start, 'duration': dur, ...args, 'map': '${tag}_map'});
      } else {
        cmds.add({'op': 'add_component', 'type': type, 'id': tag, 'start': b.start, 'duration': dur, ...args});
      }
      if (v['flash'] == true) _flash(cmds, tag, b.start, w, h);
      sfx.add((
        b.start,
        sfxKind ??
            switch (type) {
              'counter' || 'glow_word' || 'badge' || 'date_title' || 'plaque' => 'hit',
              'timeline' || 'number_tiles' => 'tick',
              'source_card' || 'photo_card' || 'speech_bubble' || 'lower_third' || 'cta' || 'name_tag' || 'character_label' || 'article' || 'poster' => 'pop',
              'scanner' => 'riser',
              'title_slam' || 'foreground_wipe' => 'none',
              _ => 'whoosh',
            },
        b.chapter,
      ));
      prevWasAroll = !needsBg;
    }

    // ---------------------------------------------------- looks (per chapter when it has its own)
    final looks = <String, List<String>>{};
    for (final e in brollIds.entries) {
      if (e.value.isEmpty) continue;
      final own = chapterById[e.key]?.look ?? '';
      final style = MotionPresets.styles.contains(own) ? own : o.look;
      if (style != null) looks.putIfAbsent(style, () => []).addAll(e.value);
    }
    for (final e in looks.entries) {
      cmds.add({'op': 'apply_style', 'style': e.key, 'layers': e.value});
    }

    // ---------------------------------------------------- atmosphere particles
    final atmCount = <int, int>{};
    for (final (t0, t1, kind, ch) in atmos) {
      final k = atmCount[ch] ?? 0;
      atmCount[ch] = k + 1;
      final id = '${prefixOf(ch)}atm$k';
      cmds.add({'op': 'add_layer', 'type': 'solid', 'id': id, 'name': 'Atmosphere $kind', 'color': '#00000000', 'width': w, 'height': h, 'position': [w / 2, h / 2, 0], 'start': t0, 'duration': math.max(0.5, t1 - t0)});
      cmds.add({'op': 'add_effect', 'layer': id, 'effect': 'particles', 'params': {'kind': kind, 'amount': _atmAmount[kind] ?? 40, 'speed': 1}});
      cmds.add({'op': 'set_property', 'target': id, 'prop': 'opacity', 'value': 75});
    }

    // ---------------------------------------------------- sound effects
    var lastSfx = -10.0;
    final sfxCount = <int, int>{};
    for (final (t, kind, ch) in sfx) {
      final media = o.sfxMedia[kind];
      if (kind == 'none' || media == null || p.media[media] == null) continue;
      if (t - lastSfx < 0.6) continue;
      lastSfx = t;
      final start = math.max(0.0, t - Sfx.peak(kind));
      final key = chaptered ? ch : 0;
      final s = sfxCount[key] ?? 0;
      sfxCount[key] = s + 1;
      final id = chaptered ? '${prefixOf(ch)}sfx$s' : 'd${o.tag}_sfx$s';
      cmds.add({'op': 'add_layer', 'type': 'audio', 'media': media, 'id': id, 'name': 'SFX $kind', 'start': start, 'duration': Sfx.length(kind)});
      cmds.add({'op': 'set_property', 'target': id, 'prop': 'volume', 'value': (o.sfxLevel * 100).roundToDouble()});
    }

    // ---------------------------------------------------- length
    var end = kept.isEmpty ? 0.0 : kept.map((b) => b.end).reduce(math.max);
    if (aroll != null) end = math.max(end, aroll.start + aroll.duration);
    if (end > comp.duration) cmds.add({'op': 'set_comp', 'duration': end});
    if (only != null) return cmds;

    // ---------------------------------------------------- music, ducked under the voice
    final music = o.musicMedia == null ? null : p.media[o.musicMedia];
    if (music != null && end > 0) {
      final len = music.duration > 1 ? music.duration : end;
      var t = musicFrom < end - 0.5 ? musicFrom : 0.0;
      var k = 0;
      final env = duckEnvelope(o.speech, end, o.musicLevel, o.duckLevel);
      while (t < end - 0.05 && k < 50) {
        final id = 'd${o.tag}_music$k';
        final d = math.min(len, end - t);
        cmds.add({'op': 'add_layer', 'type': 'audio', 'media': music.id, 'id': id, 'name': k == 0 ? 'Music' : 'Music (loop $k)', 'start': t, 'duration': d});
        final inside = env.where((e) => e.$1 >= t && e.$1 <= t + d).toList();
        if (inside.isEmpty || env.length < 2) {
          cmds.add({'op': 'set_property', 'target': id, 'prop': 'volume', 'value': _pct(_gainAt(env, t + d / 2))});
        } else {
          cmds.add({'op': 'set_keyframe', 'target': id, 'prop': 'volume', 'time': t, 'value': _pct(_gainAt(env, t)), 'ease': 'linear'});
          for (final e in inside) {
            cmds.add({'op': 'set_keyframe', 'target': id, 'prop': 'volume', 'time': e.$1, 'value': _pct(e.$2), 'ease': 'linear'});
          }
          cmds.add({'op': 'set_keyframe', 'target': id, 'prop': 'volume', 'time': t + d, 'value': _pct(_gainAt(env, t + d)), 'ease': 'linear'});
        }
        t += d;
        k++;
      }
    }

    // ---------------------------------------------------- captions
    if (o.captionWords != null && o.captionWords!.isNotEmpty) {
      cmds.addAll(CaptionMaker.fromWords(p, o.captionWords!, o.captions ?? CaptionOptions(), pending: cmds)); // keep clear of name tags etc.
    }
    return cmds;
  }

  static const _atmAmount = {'rain': 45, 'dust': 30, 'confetti': 55, 'leaves': 35, 'snow': 40, 'smoke': 25, 'bokeh': 35};

  /// Commands that replace one chapter of an existing build: its old layers
  /// and presenter punch-ins go, the chapter is built again, and the
  /// captions stay on top. Run them as one batch (one Undo).
  static List<Map<String, dynamic>> rebuildChapter(Project p, List<Beat> beats, BuildOptions o, int chapter) {
    final comp = p.main;
    final prefix = chapterPrefix(o.tag, chapter);
    final cmds = <Map<String, dynamic>>[
      for (final l in comp.layers)
        if (l.id.startsWith(prefix)) {'op': 'remove_layer', 'layer': l.id},
    ];
    final mine = [for (final b in beats) if (b.chapter == chapter) b];
    final aroll = o.arollLayer == null ? null : comp.layerById(o.arollLayer!);
    if (aroll != null && mine.isNotEmpty) {
      final scale = aroll.prop(Props.scale);
      if (scale.isAnimated) {
        final f = 1 / comp.fps;
        final t0 = mine.map((b) => b.start).reduce(math.min), t1 = mine.map((b) => b.end).reduce(math.max);
        for (final k in [...scale.keyframes]) {
          if (k.time >= t0 - f * 0.5 && k.time <= t1 - f * 0.5) {
            cmds.add({'op': 'remove_keyframe', 'target': aroll.id, 'prop': 'scale', 'time': k.time});
          }
        }
        final s = scale.staticValue[0];
        cmds.add({'op': 'set_keyframe', 'target': aroll.id, 'prop': 'scale', 'time': t0, 'value': [s, s, 100], 'ease': 'linear'});
        cmds.add({'op': 'set_keyframe', 'target': aroll.id, 'prop': 'scale', 'time': t1 - f, 'value': [s, s, 100], 'ease': 'hold'});
      }
    }
    cmds.addAll(build(p, beats, o, only: chapter));
    final captions = [for (final l in comp.layers) if (l.id.startsWith('cap_')) l.id];
    for (int i = 0; i < captions.length; i++) {
      cmds.add({'op': 'reorder_layer', 'layer': captions[i], 'index': i});
    }
    return cmds;
  }

  /// A white flash over the cut (pattern interrupt).
  static void _flash(List<Map<String, dynamic>> cmds, String tag, double t, double w, double h) {
    final id = '${tag}_flash';
    final t0 = math.max(0.0, t - 0.04);
    cmds.addAll([
      {'op': 'add_layer', 'type': 'solid', 'id': id, 'name': 'Flash', 'color': '#FFFFFF', 'width': w, 'height': h, 'position': [w / 2, h / 2, 0], 'start': t0, 'duration': 0.45},
      {'op': 'set_keyframe', 'target': id, 'prop': 'opacity', 'time': t0, 'value': 100, 'ease': 'ease_out'},
      {'op': 'set_keyframe', 'target': id, 'prop': 'opacity', 'time': t0 + 0.4, 'value': 0, 'ease': 'linear'},
    ]);
  }

  /// A map beat: a sea under the map (the map's own ocean sits at the very
  /// bottom, under a presenter), unknown countries dropped, and the
  /// optional "route": [from, to] arrow and "pin": label on the focus.
  static void _mapBeat(List<Map<String, dynamic>> cmds, Map<String, dynamic> args, String tag, double t0, double dur, double w, double h) {
    final a = Map<String, dynamic>.from(args);
    final route = a.remove('route');
    final pin = a.remove('pin');
    final loaded = WorldMap.loaded;
    if (loaded) {
      final cs = a['countries'];
      if (cs is List) {
        a['countries'] = [
          for (final c in cs)
            if (WorldMap.find(c is Map ? '${c['code'] ?? c['name']}' : '$c') != null) c,
        ];
      }
      if (a['focus'] != null && WorldMap.find('${a['focus']}') == null) a.remove('focus');
    }
    final style = _seaColors.containsKey(a['style']) ? '${a['style']}' : 'dark';
    cmds.add({'op': 'add_layer', 'type': 'solid', 'id': '${tag}_sea', 'name': 'Map sea', 'color': _seaColors[style], 'start': t0, 'duration': dur, 'width': w, 'height': h});
    cmds.add({'op': 'add_component', 'type': 'map', 'id': tag, 'start': t0, 'duration': dur, ...a});
    if (!loaded) return;
    final zoomed = a['focus'] != null && a['zoom'] != false;
    if (route is List && route.length >= 2 && dur > 1.6) {
      final from = WorldMap.find('${route[0]}'), to = WorldMap.find('${route[1]}');
      if (from != null && to != null && from != to) {
        final s = t0 + math.min(zoomed ? 2.0 : 0.8, dur * 0.4);
        cmds.add({
          'op': 'add_component', 'type': 'map_route', 'id': '${tag}_rt', 'map': tag, 'start': s, 'duration': t0 + dur - s,
          'from': [from.labelLat, from.labelLon], 'to': [to.labelLat, to.labelLon], 'color': '#FF3B30',
        });
      }
    }
    if (pin is String && pin.trim().isNotEmpty && a['focus'] != null) {
      final c = WorldMap.find('${a['focus']}');
      if (c != null) {
        final s = t0 + math.min(zoomed ? 2.8 : 0.6, dur * 0.6);
        cmds.add({
          'op': 'add_component', 'type': 'map_pin', 'id': '${tag}_pin', 'map': tag, 'start': s, 'duration': t0 + dur - s,
          'lat': c.labelLat, 'lon': c.labelLon, 'label': pin.trim(),
        });
      }
    }
  }

  static double _pct(double g) => (g * 1000).roundToDouble() / 10;

  /// Optional overlays on a photo/video beat: a name tag introducing the
  /// person and a label pinned to the subject.
  static void _overlays(List<Map<String, dynamic>> cmds, Map<String, dynamic> v, String tag, String subject, double t0, double dur) {
    final nt = v['name_tag'];
    if (nt is Map && nt['name'] is String) {
      final t1 = t0 + math.min(0.5, dur * 0.2);
      cmds.add({'op': 'add_component', 'type': 'name_tag', 'id': '${tag}_nt', 'start': t1, 'duration': math.max(0.8, dur - (t1 - t0)), 'name': nt['name'], if (nt['role'] is String) 'role': nt['role']});
    }
    final label = v['label'];
    if (label is String && label.trim().isNotEmpty) {
      final t1 = t0 + math.min(0.4, dur * 0.2);
      cmds.add({'op': 'add_component', 'type': 'character_label', 'id': '${tag}_lb', 'start': t1, 'duration': math.max(0.8, dur - (t1 - t0)), 'text': label.trim(), 'attach': subject, 'at': [0.5, 0.2]});
    }
  }

  static String _short(String s) {
    final t = s.trim();
    return t.length <= 28 ? t : '${t.substring(0, 26)}…';
  }

  /// Camera move keyframes for a cover-fitted photo or video.
  static List<Map<String, dynamic>> _move(String id, MediaAsset m, double w, double h, double t0, double dur, String move) {
    final cover = math.max(w / math.max(1, m.width), h / math.max(1, m.height)) * 100;
    List<double> sc(double f) => [cover * f, cover * f, 100];
    final t1 = t0 + dur;
    Map<String, dynamic> kf(String prop, double t, List<double> v, [String ease = 'easy_ease']) =>
        {'op': 'set_keyframe', 'target': id, 'prop': prop, 'time': t, 'value': v, 'ease': ease};
    switch (move) {
      case 'push_in':
        return [kf('scale', t0, sc(1.0)), kf('scale', t1, sc(1.18))];
      case 'pull_out':
        return [kf('scale', t0, sc(1.18)), kf('scale', t1, sc(1.0))];
      case 'pan_left':
      case 'pan_right':
        final dx = w * 0.06 * (move == 'pan_left' ? 1 : -1);
        return [
          {'op': 'set_property', 'target': id, 'prop': 'scale', 'value': sc(1.16)},
          kf('position', t0, [w / 2 + dx, h / 2, 0], 'linear'),
          kf('position', t1, [w / 2 - dx, h / 2, 0], 'linear'),
        ];
      case 'parallax':
        return [
          kf('scale', t0, sc(1.04), 'linear'),
          kf('scale', t1, sc(1.14), 'linear'),
          kf('position', t0, [w / 2 - w * 0.025, h / 2 + h * 0.01, 0], 'linear'),
          kf('position', t1, [w / 2 + w * 0.025, h / 2 - h * 0.01, 0], 'linear'),
          kf('rotation', t0, [0, 0, -0.6], 'linear'),
          kf('rotation', t1, [0, 0, 0.6], 'linear'),
        ];
      default: // ken_burns
        return [kf('scale', t0, sc(1.0), 'linear'), kf('scale', t1, sc(1.1), 'linear')];
    }
  }

  /// Background and subject from a cut-out, moving at different speeds,
  /// with an optional glowing word between them.
  static void _depthShot(List<Map<String, dynamic>> cmds, Project p, double t0, double dur, String tag, String bgMedia,
      String fgMedia, String? behindText, String trans) {
    final comp = p.main;
    final w = comp.width, h = comp.height;
    final t1 = t0 + dur;
    final bg = p.media[bgMedia]!, fg = p.media[fgMedia]!;
    final bgId = '${tag}_bg', fgId = '${tag}_fg';
    cmds.add({'op': 'add_layer', 'type': 'image', 'media': bg.id, 'id': bgId, 'name': 'Depth background', 'start': t0, 'duration': dur, 'fit': 'cover'});
    final cb = math.max(w / math.max(1, bg.width), h / math.max(1, bg.height)) * 100;
    cmds.addAll([
      {'op': 'set_keyframe', 'target': bgId, 'prop': 'scale', 'time': t0, 'value': [cb * 1.02, cb * 1.02, 100], 'ease': 'linear'},
      {'op': 'set_keyframe', 'target': bgId, 'prop': 'scale', 'time': t1, 'value': [cb * 1.08, cb * 1.08, 100], 'ease': 'linear'},
      {'op': 'add_effect', 'layer': bgId, 'effect': 'blur', 'params': {'amount': 4}},
      {'op': 'add_effect', 'layer': bgId, 'effect': 'color', 'params': {'brightness': -18}},
      {'op': 'animate_in', 'layer': bgId, 'preset': trans, 'duration': 0.35},
    ]);
    if (behindText != null && behindText.trim().isNotEmpty) {
      cmds.add({'op': 'add_component', 'type': 'glow_word', 'id': '${tag}_w', 'text': behindText.trim(), 'start': t0 + 0.15, 'duration': dur - 0.15, 'y': h * 0.42});
    }
    cmds.add({'op': 'add_layer', 'type': 'image', 'media': fg.id, 'id': fgId, 'name': 'Depth subject', 'start': t0, 'duration': dur, 'fit': 'cover'});
    final cf = math.max(w / math.max(1, fg.width), h / math.max(1, fg.height)) * 100;
    cmds.addAll([
      {'op': 'set_keyframe', 'target': fgId, 'prop': 'scale', 'time': t0, 'value': [cf * 1.02, cf * 1.02, 100], 'ease': 'linear'},
      {'op': 'set_keyframe', 'target': fgId, 'prop': 'scale', 'time': t1, 'value': [cf * 1.17, cf * 1.17, 100], 'ease': 'linear'},
      {'op': 'set_keyframe', 'target': fgId, 'prop': 'position', 'time': t0, 'value': [w / 2, h / 2 + h * 0.015, 0], 'ease': 'linear'},
      {'op': 'set_keyframe', 'target': fgId, 'prop': 'position', 'time': t1, 'value': [w / 2, h / 2 - h * 0.01, 0], 'ease': 'linear'},
      {'op': 'add_effect', 'layer': fgId, 'effect': 'shadow', 'params': {'distance': 0, 'blur': 30, 'opacity': 70}},
      {'op': 'animate_in', 'layer': fgId, 'preset': trans, 'duration': 0.35},
    ]);
  }

  /// Music gain over time: [full] when nobody talks, [duck] under speech,
  /// with short fades. Returns (time, gain) points.
  static List<(double, double)> duckEnvelope(List<(double, double)> speech, double total, double full, double duck,
      {double attack = 0.25, double release = 0.5, double bridge = 0.9}) {
    if (speech.isEmpty) return [(0, full), (total, full)];
    final sorted = [...speech]..sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(double, double)>[];
    for (final s in sorted) {
      if (merged.isNotEmpty && s.$1 - merged.last.$2 < bridge) {
        merged[merged.length - 1] = (merged.last.$1, math.max(merged.last.$2, s.$2));
      } else {
        merged.add(s);
      }
    }
    final pts = <(double, double)>[(0, merged.first.$1 - attack <= 0 ? duck : full)];
    for (final m in merged) {
      final a = math.max(0.0, m.$1 - attack);
      if (a > pts.last.$1) pts.add((a, full));
      pts.add((math.max(a, m.$1), duck));
      pts.add((m.$2, duck));
      pts.add((math.min(total, m.$2 + release), full));
    }
    if (pts.last.$1 < total) pts.add((total, pts.last.$2));
    // Keep times increasing.
    final out = <(double, double)>[];
    for (final p in pts) {
      if (out.isNotEmpty && p.$1 <= out.last.$1) {
        out[out.length - 1] = (out.last.$1, p.$2);
      } else {
        out.add(p);
      }
    }
    return out;
  }

  static double _gainAt(List<(double, double)> env, double t) {
    if (env.isEmpty) return 1;
    if (t <= env.first.$1) return env.first.$2;
    for (int i = 1; i < env.length; i++) {
      if (t <= env[i].$1) {
        final a = env[i - 1], b = env[i];
        final k = (t - a.$1) / math.max(1e-6, b.$1 - a.$1);
        return a.$2 + (b.$2 - a.$2) * k;
      }
    }
    return env.last.$2;
  }

  /// Voice intervals from word timings.
  static List<(double, double)> speechFromWords(List<WordTiming> words) => [for (final w in words) (w.start, w.end)];
}
