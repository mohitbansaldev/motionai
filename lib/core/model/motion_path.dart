import 'dart:math' as math;
import 'dart:typed_data';

/// One sampled point on a motion path.
class PathSample {
  final double x, y;

  /// Direction of travel in degrees (0 = right, 90 = down).
  final double angle;
  const PathSample(this.x, this.y, this.angle);
}

/// A motion path: the layer's position follows this curve at the
/// `path_progress` property (0..100). Points are in the layer's parent space
/// (composition pixels for unparented layers). While a path is set the
/// layer's own position X/Y acts as an offset from the path.
///
/// JSON / command form: `{'points': [[x,y],...], 'smooth': true, 'orient': false}`.
class MotionPath {
  final List<List<double>> points;
  final bool smooth;
  final bool orient;

  MotionPath({required List<List<double>> points, this.smooth = true, this.orient = false})
      : points = List.unmodifiable([
          for (final p in points) List<double>.unmodifiable([p.isNotEmpty ? p[0] : 0.0, p.length > 1 ? p[1] : 0.0]),
        ]);

  /// Steps per curve segment when flattening a smooth path.
  static const int _steps = 24;

  // Flattened polyline: xs, ys, cumulative length. Built lazily once.
  Float64List? _xs, _ys, _len;

  MotionPath copy() => MotionPath(points: points, smooth: smooth, orient: orient);

  Map<String, dynamic> toJson() => {
        'points': [for (final p in points) [p[0], p[1]]],
        'smooth': smooth,
        'orient': orient,
      };

  static MotionPath fromJson(Map<String, dynamic> j) => MotionPath(
        points: [
          for (final p in (j['points'] as List? ?? const []))
            [for (final v in (p as List)) (v as num).toDouble()],
        ],
        smooth: j['smooth'] as bool? ?? true,
        orient: j['orient'] as bool? ?? false,
      );

  /// A path from [a] to [b] that bows sideways by [bend] px (0 = straight line;
  /// positive bends to the left of the travel direction, i.e. upward for a
  /// left→right path).
  static MotionPath arc(List<double> a, List<double> b, double bend, {bool orient = false}) {
    if (bend.abs() < 0.5) return MotionPath(points: [a, b], smooth: false, orient: orient);
    final dx = b[0] - a[0], dy = b[1] - a[1];
    final len = math.max(1e-9, math.sqrt(dx * dx + dy * dy));
    // Left normal (screen y is down).
    final nx = dy / len, ny = -dx / len;
    final mid = [(a[0] + b[0]) / 2 + nx * bend, (a[1] + b[1]) / 2 + ny * bend];
    return MotionPath(points: [a, mid, b], smooth: true, orient: orient);
  }

  /// For a path made by [arc]: (start, end, bend). Returns null for other paths.
  ({List<double> a, List<double> b, double bend})? get arcParams {
    if (points.length == 2) return (a: points[0], b: points[1], bend: 0);
    if (points.length != 3) return null;
    final a = points[0], m = points[1], b = points[2];
    final dx = b[0] - a[0], dy = b[1] - a[1];
    final len = math.max(1e-9, math.sqrt(dx * dx + dy * dy));
    final nx = dy / len, ny = -dx / len;
    final bend = (m[0] - (a[0] + b[0]) / 2) * nx + (m[1] - (a[1] + b[1]) / 2) * ny;
    return (a: a, b: b, bend: bend);
  }

  void _build() {
    if (_len != null) return;
    final xs = <double>[], ys = <double>[];
    final n = points.length;
    if (n == 0) {
      xs.add(0);
      ys.add(0);
    } else if (n < 3 || !smooth) {
      for (final p in points) {
        xs.add(p[0]);
        ys.add(p[1]);
      }
    } else {
      // Same curve as ShapeData smooth paths: Catmull-Rom as cubic Béziers.
      List<double> at(int i) => points[i.clamp(0, n - 1)];
      xs.add(points[0][0]);
      ys.add(points[0][1]);
      for (int i = 0; i < n - 1; i++) {
        final p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2);
        final c1x = p1[0] + (p2[0] - p0[0]) / 6, c1y = p1[1] + (p2[1] - p0[1]) / 6;
        final c2x = p2[0] - (p3[0] - p1[0]) / 6, c2y = p2[1] - (p3[1] - p1[1]) / 6;
        for (int s = 1; s <= _steps; s++) {
          final t = s / _steps, u = 1 - t;
          final b0 = u * u * u, b1 = 3 * u * u * t, b2 = 3 * u * t * t, b3 = t * t * t;
          xs.add(b0 * p1[0] + b1 * c1x + b2 * c2x + b3 * p2[0]);
          ys.add(b0 * p1[1] + b1 * c1y + b2 * c2y + b3 * p2[1]);
        }
      }
    }
    final len = Float64List(xs.length);
    for (int i = 1; i < xs.length; i++) {
      final dx = xs[i] - xs[i - 1], dy = ys[i] - ys[i - 1];
      len[i] = len[i - 1] + math.sqrt(dx * dx + dy * dy);
    }
    _xs = Float64List.fromList(xs);
    _ys = Float64List.fromList(ys);
    _len = len;
  }

  /// Total arc length in px.
  double get length {
    _build();
    return _len!.last;
  }

  /// Point at [progress] (0..1 of the arc length; clamped).
  PathSample sample(double progress) {
    _build();
    final xs = _xs!, ys = _ys!, len = _len!;
    final n = xs.length;
    if (n == 1) return PathSample(xs[0], ys[0], 0);
    final total = len[n - 1];
    final target = total * progress.clamp(0.0, 1.0);
    int lo = 0, hi = n - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (len[mid] <= target) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final seg = len[hi] - len[lo];
    final f = seg <= 1e-12 ? 0.0 : (target - len[lo]) / seg;
    final dx = xs[hi] - xs[lo], dy = ys[hi] - ys[lo];
    final ang = (dx == 0 && dy == 0) ? 0.0 : math.atan2(dy, dx) * 180 / math.pi;
    return PathSample(xs[lo] + dx * f, ys[lo] + dy * f, ang);
  }
}

/// Track matte: the layer is shown only inside ([mode] 'alpha') or outside
/// ('inverse') the pixels of layer [layerId]. The matte layer itself is hidden.
class LayerMatte {
  final String layerId;
  final String mode; // alpha | inverse
  const LayerMatte(this.layerId, {this.mode = 'alpha'});

  static const modes = ['alpha', 'inverse'];

  bool get inverse => mode == 'inverse';

  Map<String, dynamic> toJson() => {'layer': layerId, 'mode': mode};

  static LayerMatte fromJson(Map<String, dynamic> j) =>
      LayerMatte('${j['layer']}', mode: j['mode'] == 'inverse' ? 'inverse' : 'alpha');

  @override
  bool operator ==(Object other) => other is LayerMatte && other.layerId == layerId && other.mode == mode;
  @override
  int get hashCode => Object.hash(layerId, mode);
}
