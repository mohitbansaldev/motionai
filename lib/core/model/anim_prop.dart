import 'easing.dart';

/// Time tolerance for treating two keyframes as the same (≈ 1/1000 s).
const double kTimeEpsilon = 1e-3;

/// One keyframe: a value at a time, plus the easing used to travel
/// from this keyframe to the next one.
class Keyframe {
  double time;
  List<double> value;
  Easing easing;

  Keyframe(this.time, List<double> value, {this.easing = Easing.easyEase}) : value = List.of(value);

  Keyframe copy() => Keyframe(time, value, easing: easing);

  Map<String, dynamic> toJson() => {'t': time, 'v': value, 'e': easing.toJson()};

  static Keyframe fromJson(Map<String, dynamic> j) => Keyframe(
        (j['t'] as num).toDouble(),
        (j['v'] as List).map((e) => (e as num).toDouble()).toList(),
        easing: Easing.fromJson(j['e']),
      );
}

/// An animatable property with 1..3 dimensions (opacity, position, scale...).
/// When it has no keyframes the [staticValue] is used.
class AnimProp {
  final int dims;
  List<double> staticValue;
  final List<Keyframe> keyframes;

  AnimProp(List<double> value, {List<Keyframe>? keyframes})
      : dims = value.length,
        staticValue = List.of(value),
        keyframes = keyframes ?? [];

  AnimProp.scalar(double v) : this([v]);

  bool get isAnimated => keyframes.isNotEmpty;

  AnimProp copy() => AnimProp(staticValue, keyframes: keyframes.map((k) => k.copy()).toList());

  List<double> _fit(List<double> v) {
    if (v.length == dims) return List.of(v);
    if (v.length == 1) return List.filled(dims, v[0]);
    final out = List.of(staticValue);
    for (int i = 0; i < dims && i < v.length; i++) {
      out[i] = v[i];
    }
    return out;
  }

  /// Value at time [t] (seconds, in the owner's time base).
  List<double> valueAt(double t) {
    if (keyframes.isEmpty) return List.of(staticValue);
    if (t <= keyframes.first.time) return List.of(keyframes.first.value);
    if (t >= keyframes.last.time) return List.of(keyframes.last.value);
    // Binary search for the segment.
    int lo = 0, hi = keyframes.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (keyframes[mid].time <= t) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = keyframes[lo], b = keyframes[hi];
    final span = b.time - a.time;
    final p = span <= 0 ? 1.0 : a.easing.transform((t - a.time) / span);
    return List.generate(dims, (i) => a.value[i] + (b.value[i] - a.value[i]) * p);
  }

  double scalarAt(double t) => valueAt(t)[0];

  /// Sets the value: adds/updates a keyframe at [t] if animated (or if
  /// [forceKeyframe]), otherwise changes the static value.
  void setValue(double t, List<double> v, {bool forceKeyframe = false, Easing? easing}) {
    final fitted = _fit(v);
    if (isAnimated || forceKeyframe) {
      setKeyframe(t, fitted, easing: easing);
    } else {
      staticValue = fitted;
    }
  }

  Keyframe? keyframeAt(double t) {
    for (final k in keyframes) {
      if ((k.time - t).abs() < kTimeEpsilon) return k;
    }
    return null;
  }

  void setKeyframe(double t, List<double> v, {Easing? easing}) {
    final fitted = _fit(v);
    final existing = keyframeAt(t);
    if (existing != null) {
      existing.value = fitted;
      if (easing != null) existing.easing = easing;
    } else {
      keyframes.add(Keyframe(t, fitted, easing: easing ?? Easing.easyEase));
      keyframes.sort((a, b) => a.time.compareTo(b.time));
    }
  }

  bool removeKeyframe(double t) {
    final k = keyframeAt(t);
    if (k == null) return false;
    keyframes.remove(k);
    if (keyframes.isEmpty) staticValue = List.of(k.value);
    return true;
  }

  /// Removes all keyframes, keeping the value at time [t] as static value.
  void clearKeyframes([double t = 0]) {
    staticValue = valueAt(t);
    keyframes.clear();
  }

  /// Shifts every keyframe by [dt] seconds.
  void shift(double dt) {
    for (final k in keyframes) {
      k.time += dt;
    }
  }

  Map<String, dynamic> toJson() => {
        'v': staticValue,
        if (keyframes.isNotEmpty) 'k': keyframes.map((k) => k.toJson()).toList(),
      };

  static AnimProp fromJson(Map<String, dynamic> j) {
    final v = (j['v'] as List).map((e) => (e as num).toDouble()).toList();
    final ks = (j['k'] as List?)?.map((e) => Keyframe.fromJson(e as Map<String, dynamic>)).toList();
    ks?.sort((a, b) => a.time.compareTo(b.time));
    return AnimProp(v, keyframes: ks);
  }
}
