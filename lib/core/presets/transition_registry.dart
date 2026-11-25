import '../model/layer.dart';
import '../model/project.dart';

/// A transition between two shots (comp layers in the same comp).
///
/// [outgoing] ends where [incoming] begins (they overlap by `params['overlap']`
/// seconds when the transition asked for an overlap). `params` holds the
/// transition spec from the command (`type`, `duration`, `overlap` and any
/// extra keys such as `color` or `direction`).
typedef ShotTransition = void Function(Composition comp, Layer outgoing, Layer incoming, Map<String, dynamic> params);

/// Registry of shot transitions by name (V2-B), used by the `sequence` op.
///
/// - [register] adds one transition. It takes any `Function` with the
///   [ShotTransition] parameters, so a provider can pass its functions
///   without importing this typedef.
/// - [addRegistrar] adds a provider that registers many transitions at once,
///   called lazily on the first [lookup]. The documentary transitions
///   (V2-C, lib/core/presets/doc_transitions.dart) plug in with ONE line:
///   `TransitionRegistry.addRegistrar(DocTransitions.registerAll);`
///   (`registerAll(void Function(String name, Function fn) register)`).
/// - [lookup] returns null for unknown names; `sequence` then falls back to
///   an `animate_in` preset on the incoming layer (flash, ink, smoke, iris…).
class TransitionRegistry {
  static final Map<String, ShotTransition> _fns = {};
  static final List<void Function(void Function(String name, Function fn) register)> _registrars = [];
  static int _booted = 0;

  static void register(String name, Function fn) {
    final key = name.trim();
    if (key.isEmpty) throw ArgumentError('A transition needs a name');
    if (fn is ShotTransition) {
      _fns[key] = fn;
    } else {
      _fns[key] = (comp, outgoing, incoming, params) => Function.apply(fn, [comp, outgoing, incoming, params]);
    }
  }

  static void addRegistrar(void Function(void Function(String name, Function fn) register) registrar) {
    if (!_registrars.contains(registrar)) _registrars.add(registrar);
  }

  static void _boot() {
    while (_booted < _registrars.length) {
      _registrars[_booted++](register);
    }
  }

  static ShotTransition? lookup(String name) {
    _boot();
    return _fns[name.trim()];
  }

  static bool has(String name) => lookup(name) != null;

  static List<String> get names {
    _boot();
    return _fns.keys.toList()..sort();
  }

  static bool unregister(String name) => _fns.remove(name.trim()) != null;
}
