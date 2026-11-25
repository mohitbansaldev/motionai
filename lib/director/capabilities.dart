import '../core/commands/edit_commands.dart';
import '../core/model/effects_catalog.dart';
import '../core/presets/components.dart';

/// What this build of the app can do. Scene/map ops and components come
/// from other branches; the Director only plans what exists and turns
/// anything else into the closest visual that does ([adapt]).
class Capabilities {
  final Set<String> ops;
  final Set<String> components;
  final bool particles;

  Capabilities({Iterable<String>? ops, Iterable<String>? components, bool? particles})
      : ops = {...(ops ?? EditCommands.ops)},
        components = {...(components ?? Components.types)},
        particles = particles ?? EffectsCatalog.byType('particles') != null;

  bool get has3d => ops.contains('make_3d') && ops.contains('camera_shot');
  bool has(String component) => components.contains(component);

  static const particleKinds = ['confetti', 'leaves', 'stars', 'rain', 'snow', 'smoke', 'dust', 'bokeh', 'streaks', 'birds', 'clouds'];
  static const moves2d = ['ken_burns', 'push_in', 'pull_out', 'pan_left', 'pan_right', 'parallax', 'depth'];
  static const moves3d = ['drift', 'fly_to', 'push_through', 'pass_by', 'reveal', 'pull_back', 'orbit'];
  static const transitions = [
    'fade', 'zoom_in', 'zoom_out', 'slide_left', 'slide_right', 'whip', 'blur', 'pop', 'shatter',
    'iris', 'ink', 'smoke', 'spin', 'flash', 'glitch_flash', 'foreground_wipe',
  ];

  /// Map moments that come with the scene/map branch.
  static const mapComponents = ['map_fly', 'route_follow', 'needle_pin', 'avatar_pin'];

  /// The closest 2D move for a 3D camera move.
  static String flatMove(String move) => switch (move) {
        'pull_back' => 'pull_out',
        'pass_by' => 'pan_left',
        'orbit' => 'parallax',
        'drift' => 'ken_burns',
        _ => 'push_in',
      };

  /// Returns a visual this build can make. Unknown or unavailable visuals
  /// become the nearest available one (3D move → 2D move, map_fly → zooming
  /// map with a route, needle_pin → map with a pin, …).
  Map<String, dynamic> adapt(Map<String, dynamic> visual) {
    final v = Map<String, dynamic>.from(visual);
    if (v['aroll'] == true) return v;
    final t = v['transition'];
    if (t != null && (!transitions.contains(t) || (t == 'foreground_wipe' && !has('foreground_wipe')))) v['transition'] = 'fade';
    final atm = v['atmosphere'];
    if (atm != null && (atm != 'none' && (!particles || !particleKinds.contains(atm)))) v.remove('atmosphere');
    final type = v['component'];
    if (type == null) {
      final move = v['move'];
      if (move is String && moves3d.contains(move) && !has3d) v['move'] = flatMove(move);
      if (move is String && !moves2d.contains(move) && !moves3d.contains(move)) v['move'] = 'ken_burns';
      return v;
    }
    final c = '$type';
    if (has(c)) return v;
    String? s(String k) => v[k] is String && '${v[k]}'.trim().isNotEmpty ? '${v[k]}'.trim() : null;
    switch (c) {
      case 'map_fly':
      case 'route_follow':
        final from = s('from'), to = s('to');
        if (from == null || to == null) {
          final one = to ?? from;
          return one == null ? _fallbackText(v) : {'component': 'map', 'countries': [one], 'focus': one, 'style': s('style') ?? 'paper'};
        }
        return {
          'component': 'map',
          'countries': [from, to],
          if (c == 'map_fly') 'focus': to,
          'route': [from, to],
          'style': s('style') ?? 'paper',
          if (v['sfx'] != null) 'sfx': v['sfx'],
        };
      case 'needle_pin':
      case 'avatar_pin':
        final country = s('country') ?? s('focus');
        if (country == null) return _fallbackText(v);
        return {'component': 'map', 'countries': [country], 'focus': country, 'pin': s('label') ?? country, 'style': s('style') ?? 'paper'};
      default:
        return _fallbackText(v);
    }
  }

  /// A photo when the visual names one, else its key word as a glow word,
  /// else back to the presenter.
  Map<String, dynamic> _fallbackText(Map<String, dynamic> v) {
    final m = v['media'];
    final media = m is String ? m : (m is List && m.isNotEmpty ? '${m.first}' : null);
    if (media != null) return {'media': media, 'move': 'ken_burns', if (v['transition'] != null) 'transition': v['transition']};
    for (final k in ['title', 'text', 'label', 'name', 'to', 'country']) {
      final t = v[k];
      if (t is String && t.trim().isNotEmpty && has('glow_word')) {
        final words = t.trim().split(RegExp(r'\s+'));
        return {'component': 'glow_word', 'text': words.take(2).join(' ').toUpperCase()};
      }
    }
    return {'aroll': true};
  }
}
