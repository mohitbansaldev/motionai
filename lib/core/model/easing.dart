import 'dart:math' as math;

/// Interpolation curve used between a keyframe and the next one.
enum EaseType { linear, hold, easeIn, easeOut, easyEase, bezier, bounce, elastic, back }

/// An easing curve. For [EaseType.bezier] the control points (x1,y1,x2,y2)
/// define a CSS-style cubic-bezier, like After Effects' graph editor handles.
class Easing {
  final EaseType type;
  final double x1, y1, x2, y2;

  const Easing(this.type, {this.x1 = 0, this.y1 = 0, this.x2 = 1, this.y2 = 1});

  const Easing.bezierCurve(this.x1, this.y1, this.x2, this.y2) : type = EaseType.bezier;

  static const linear = Easing(EaseType.linear);
  static const hold = Easing(EaseType.hold);
  static const easeIn = Easing(EaseType.easeIn);
  static const easeOut = Easing(EaseType.easeOut);
  static const easyEase = Easing(EaseType.easyEase);
  static const bounce = Easing(EaseType.bounce);
  static const elastic = Easing(EaseType.elastic);
  static const back = Easing(EaseType.back);

  /// Maps linear progress [t] (0..1) to eased progress.
  double transform(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    switch (type) {
      case EaseType.linear:
        return t;
      case EaseType.hold:
        return 0;
      case EaseType.easeIn:
        return _cubicBezier(0.42, 0, 1, 1, t);
      case EaseType.easeOut:
        return _cubicBezier(0, 0, 0.58, 1, t);
      case EaseType.easyEase:
        return _cubicBezier(0.33, 0, 0.67, 1, t);
      case EaseType.bezier:
        return _cubicBezier(x1, y1, x2, y2, t);
      case EaseType.bounce:
        return _bounceOut(t);
      case EaseType.elastic:
        const c4 = (2 * math.pi) / 3;
        return math.pow(2, -10 * t).toDouble() * math.sin((t * 10 - 0.75) * c4) + 1;
      case EaseType.back:
        const c1 = 1.70158;
        const c3 = c1 + 1;
        final u = t - 1;
        return 1 + c3 * u * u * u + c1 * u * u;
    }
  }

  static double _bounceOut(double t) {
    const n1 = 7.5625;
    const d1 = 2.75;
    if (t < 1 / d1) return n1 * t * t;
    if (t < 2 / d1) {
      t -= 1.5 / d1;
      return n1 * t * t + 0.75;
    }
    if (t < 2.5 / d1) {
      t -= 2.25 / d1;
      return n1 * t * t + 0.9375;
    }
    t -= 2.625 / d1;
    return n1 * t * t + 0.984375;
  }

  /// Solves a cubic bezier with P0=(0,0), P3=(1,1) for x = [x], returns y.
  static double _cubicBezier(double x1, double y1, double x2, double y2, double x) {
    double bx(double t) => 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t;
    double by(double t) => 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t;
    double dbx(double t) =>
        3 * (1 - t) * (1 - t) * x1 + 6 * (1 - t) * t * (x2 - x1) + 3 * t * t * (1 - x2);

    // Newton-Raphson, then bisection fallback.
    double t = x;
    for (int i = 0; i < 8; i++) {
      final err = bx(t) - x;
      if (err.abs() < 1e-6) return by(t);
      final d = dbx(t);
      if (d.abs() < 1e-6) break;
      t -= err / d;
    }
    double lo = 0, hi = 1;
    t = x;
    for (int i = 0; i < 40; i++) {
      final v = bx(t);
      if ((v - x).abs() < 1e-6) break;
      if (v < x) {
        lo = t;
      } else {
        hi = t;
      }
      t = (lo + hi) / 2;
    }
    return by(t);
  }

  Map<String, dynamic> toJson() => type == EaseType.bezier
      ? {'type': type.name, 'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2}
      : {'type': type.name};

  static Easing fromJson(dynamic json) {
    if (json == null) return Easing.linear;
    if (json is String) return Easing.parse(json);
    final m = json as Map<String, dynamic>;
    final type = _typeFromName(m['type'] as String? ?? 'linear');
    if (type == EaseType.bezier) {
      return Easing.bezierCurve(
        (m['x1'] as num? ?? 0).toDouble(),
        (m['y1'] as num? ?? 0).toDouble(),
        (m['x2'] as num? ?? 1).toDouble(),
        (m['y2'] as num? ?? 1).toDouble(),
      );
    }
    return Easing(type);
  }

  /// Accepts names like "linear", "hold", "easeIn", "ease_in", "easy_ease".
  static Easing parse(String name) => Easing(_typeFromName(name));

  static EaseType _typeFromName(String name) {
    final n = name.replaceAll('_', '').replaceAll('-', '').toLowerCase();
    for (final t in EaseType.values) {
      if (t.name.toLowerCase() == n) return t;
    }
    if (n == 'easeinout' || n == 'ease') return EaseType.easyEase;
    throw FormatException('Unknown easing "$name"');
  }

  String get label {
    switch (type) {
      case EaseType.linear:
        return 'Linear';
      case EaseType.hold:
        return 'Hold';
      case EaseType.easeIn:
        return 'Ease In';
      case EaseType.easeOut:
        return 'Ease Out';
      case EaseType.easyEase:
        return 'Easy Ease';
      case EaseType.bezier:
        return 'Custom Bezier';
      case EaseType.bounce:
        return 'Bounce';
      case EaseType.elastic:
        return 'Elastic';
      case EaseType.back:
        return 'Back';
    }
  }
}
