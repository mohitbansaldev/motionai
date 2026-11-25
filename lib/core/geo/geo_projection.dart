// win-40: map projections for geo layers (pure Dart, testable).
import 'dart:math' as math;

const double _rad = math.pi / 180;

double _wrap180(double d) {
  var x = (d + 180) % 360;
  if (x < 0) x += 360;
  return x - 180;
}

/// Where the layer's "camera over the Earth" looks: projection, centre
/// ([lon0], [lat0]) and [zoom], for a layer of [w] × [h] px.
class GeoView {
  final String projection;
  final double w, h, lon0, lat0, zoom;
  late final double k; // px per projection unit
  late final double _y0; // projected y of lat0 (flat projections)
  late final double _sinL0, _cosL0;

  GeoView(this.projection, this.w, this.h, this.lon0, this.lat0, double zoom) : zoom = math.max(0.05, zoom) {
    switch (projection) {
      case 'globe':
        k = 0.45 * math.min(w, h) * this.zoom; // globe radius
        _y0 = 0;
      case 'mercator':
        k = w / (2 * math.pi) * this.zoom;
        _y0 = _mercY(lat0);
      case 'natural_earth':
        k = w / (2 * math.pi * 0.8707) * this.zoom;
        _y0 = _neY(lat0 * _rad);
      default:
        k = w / 360 * this.zoom;
        _y0 = lat0;
    }
    _sinL0 = math.sin(lat0 * _rad);
    _cosL0 = math.cos(lat0 * _rad);
  }

  bool get isGlobe => projection == 'globe';
  double get radius => k; // globe radius (globe only)
  double get cx => w / 2;
  double get cy => h / 2;

  /// Pixels per degree near the centre (label sizes, line widths).
  double get pxPerDegree => isGlobe ? k * _rad : (projection == 'equirectangular' ? k : k * _rad);

  static double _mercY(double lat) {
    final l = lat.clamp(-85.0, 85.0) * _rad;
    return math.log(math.tan(math.pi / 4 + l / 2));
  }

  static double _neX(double l, double p) {
    final p2 = p * p, p4 = p2 * p2;
    return l * (0.870700 - 0.131979 * p2 + p4 * (-0.013791 + p4 * (0.003971 * p2 - 0.001529 * p4)));
  }

  static double _neY(double p) {
    final p2 = p * p, p4 = p2 * p2;
    return p * (1.007226 + p2 * (0.015085 + p4 * (-0.044475 + 0.028874 * p2 - 0.005916 * p4)));
  }

  /// Longitude relative to the centre, in −180..180.
  double dLon(double lon) => _wrap180(lon - lon0);

  /// Projects with an already-unwrapped relative longitude [dl] (degrees).
  /// Returns (x, y, visible). Hidden globe points are pushed onto the rim.
  (double, double, bool) projectRel(double dl, double lat) {
    switch (projection) {
      case 'globe':
        final la = lat * _rad, dlr = dl * _rad;
        final cl = math.cos(la), sl = math.sin(la), cd = math.cos(dlr);
        final cosc = _sinL0 * sl + _cosL0 * cl * cd;
        var x = cl * math.sin(dlr);
        var y = _cosL0 * sl - _sinL0 * cl * cd;
        if (cosc < 0) {
          final n = math.sqrt(x * x + y * y);
          if (n > 1e-9) {
            x /= n;
            y /= n;
          }
          return (cx + x * k, cy - y * k, false);
        }
        return (cx + x * k, cy - y * k, true);
      case 'mercator':
        return (cx + dl * _rad * k, cy - (_mercY(lat) - _y0) * k, true);
      case 'natural_earth':
        final p = lat.clamp(-90.0, 90.0) * _rad;
        return (cx + _neX(dl * _rad, p) * k, cy - (_neY(p) - _y0) * k, true);
      default:
        return (cx + dl * k, cy - (lat - _y0) * k, true);
    }
  }

  (double, double, bool) project(double lon, double lat) => projectRel(dLon(lon), lat);

  /// Width of one full turn of the Earth in px (flat projections; wrap copies).
  double get worldWidth {
    switch (projection) {
      case 'mercator':
        return 2 * math.pi * k;
      case 'natural_earth':
        return 2 * math.pi * 0.8707 * k;
      default:
        return 360 * k;
    }
  }

  /// Zoom that fits a lon/lat box ([west, south, east, north]) in [fill] of the frame.
  static double fitZoom(String projection, double w, double h, List<double> box, {double fill = 0.7}) {
    final lonSpan = math.max(0.5, (box[2] - box[0]).abs());
    final latSpan = math.max(0.5, (box[3] - box[1]).abs());
    switch (projection) {
      case 'globe':
        final half = math.max(lonSpan, latSpan) / 2; // degrees of arc from the centre
        final s = math.sin(math.min(89.0, half) * _rad);
        return (fill / math.max(s, 0.02)).clamp(0.2, 400.0).toDouble();
      case 'mercator':
        final ys = (_mercY(box[3]) - _mercY(box[1])).abs();
        final zx = fill * 2 * math.pi / (lonSpan * _rad);
        final zy = fill * h * 2 * math.pi / (w * math.max(ys, 1e-4));
        return math.min(zx, zy).clamp(0.2, 4000.0).toDouble();
      default:
        final zx = fill * 360 / lonSpan;
        final zy = fill * h * 360 / (w * latSpan);
        final ne = projection == 'natural_earth' ? 0.8707 : 1.0;
        return (math.min(zx, zy) * ne).clamp(0.2, 4000.0).toDouble();
    }
  }

  /// Points along the great circle from a to b ([lon, lat]), [n] segments.
  static List<List<double>> greatCircle(List<double> a, List<double> b, {int n = 48}) {
    final l1 = a[0] * _rad, p1 = a[1] * _rad, l2 = b[0] * _rad, p2 = b[1] * _rad;
    final x1 = math.cos(p1) * math.cos(l1), y1 = math.cos(p1) * math.sin(l1), z1 = math.sin(p1);
    final x2 = math.cos(p2) * math.cos(l2), y2 = math.cos(p2) * math.sin(l2), z2 = math.sin(p2);
    final dot = (x1 * x2 + y1 * y2 + z1 * z2).clamp(-1.0, 1.0);
    final om = math.acos(dot);
    if (om < 1e-6) return [List.of(a), List.of(b)];
    final so = math.sin(om);
    final out = <List<double>>[];
    for (int i = 0; i <= n; i++) {
      final f = i / n;
      final s1 = math.sin((1 - f) * om) / so, s2 = math.sin(f * om) / so;
      final x = s1 * x1 + s2 * x2, y = s1 * y1 + s2 * y2, z = s1 * z1 + s2 * z2;
      out.add([math.atan2(y, x) / _rad, math.atan2(z, math.sqrt(x * x + y * y)) / _rad]);
    }
    return out;
  }
}
