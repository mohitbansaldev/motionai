// win-40 >>> GEO LAYERS: live vector world map painter.
//
// Draws a [GeoSpec] for one [GeoView] (projection + centre + zoom): ocean,
// satellite texture (mesh-warped Blue Marble), graticule, land with coast
// glow, borders, highlighted countries (extruded slab, glow border, reveal),
// great-circle routes (draw-on, glow, dash, arrow, comet head), pins (pop,
// pulse) and labels; on the globe an atmosphere rim and terminator shading.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/geo/geo_projection.dart';
import '../../../core/geo/geo_spec.dart';
import '../../../core/geo/geo_styles.dart';
import '../../../core/model/layer.dart';
import '../../../core/presets/world_map.dart';
import '../../../fonts/font_catalog.dart';
import 'map_texture.dart';

/// The geo layer's content widget (layer-size box).
class GeoLayerView extends StatelessWidget {
  final Layer layer;
  final double time;
  final bool draft;
  const GeoLayerView({super.key, required this.layer, required this.time, this.draft = false});

  static GeoView viewOf(Layer l, double t) {
    final g = l.geo!;
    final c = l.props[GeoProps.center]?.valueAt(t) ?? const [0.0, 20.0];
    final z = l.props[GeoProps.zoom]?.valueAt(t)[0] ?? 1.0;
    return GeoView(g.projection, l.width, l.height, c[0], c[1], z);
  }

  @override
  Widget build(BuildContext context) {
    final g = layer.geo!;
    GeoStyle st;
    try {
      st = GeoStyles.byId(g.style);
    } catch (_) {
      st = GeoStyles.all.first;
    }
    final wantsTex = g.texture && st.texture == 'satellite';
    if (wantsTex && MapTexture.image.value == null) MapTexture.load();
    final view = viewOf(layer, time);
    final prog = ((layer.props[GeoProps.progress]?.valueAt(time)[0] ?? 100) / 100).clamp(0.0, 1.0).toDouble();
    return ValueListenableBuilder<ui.Image?>(
      valueListenable: MapTexture.image,
      builder: (context, img, _) => CustomPaint(
        size: Size(layer.width, layer.height),
        painter: GeoPainter(g, st, view, prog, time - layer.start, wantsTex ? img : null, draft),
      ),
    );
  }
}

class GeoPainter extends CustomPainter {
  final GeoSpec g;
  final GeoStyle st;
  final GeoView v;
  final double progress; // 0..1
  final double local; // seconds into the layer (pulses)
  final ui.Image? tex;
  final bool draft;

  GeoPainter(this.g, this.st, this.v, this.progress, this.local, this.tex, this.draft);

  static Color _c(int argb, [double a = 1]) => Color(argb).withValues(alpha: Color(argb).a * a.clamp(0.0, 1.0));

  static double _ease(double x) {
    final t = x.clamp(0.0, 1.0);
    return 1 - math.pow(1 - t, 3).toDouble();
  }

  double _reveal(double from, double to) {
    if (to <= from) return progress >= from ? 1 : 0;
    return _ease((progress - from) / (to - from));
  }

  // ------------------------------------------------------------ geometry

  /// One country ring as a projected path (null when fully on the far side).
  Path? _ring(List<double> r) {
    final n = r.length ~/ 2;
    if (n < 3) return null;
    final p = Path();
    var dl = v.dLon(r[0]);
    var prevLon = r[0];
    var anyVisible = false;
    for (int i = 0; i < n; i++) {
      final lon = r[2 * i], lat = r[2 * i + 1];
      if (i > 0) {
        var d = lon - prevLon;
        if (d > 180) d -= 360;
        if (d < -180) d += 360;
        dl += d;
      }
      prevLon = lon;
      final (x, y, vis) = v.projectRel(dl, lat);
      if (vis) anyVisible = true;
      if (i == 0) {
        p.moveTo(x, y);
      } else {
        p.lineTo(x, y);
      }
    }
    if (v.isGlobe && !anyVisible) return null;
    p.close();
    return p;
  }

  /// Country path with wrap copies for flat projections.
  Path? _country(Country c) {
    Path? out;
    for (final r in c.rings) {
      final p = _ring(r);
      if (p == null) continue;
      (out ??= Path()).addPath(p, Offset.zero);
    }
    if (out == null || v.isGlobe) return out;
    final b = out.getBounds();
    final ww = v.worldWidth;
    final res = Path()..addPath(out, Offset.zero);
    if (b.left < 0) res.addPath(out, Offset(ww, 0));
    if (b.right > v.w) res.addPath(out, Offset(-ww, 0));
    if (b.right < 0 || b.left > v.w) {
      final shift = b.right < 0 ? ww : -ww;
      return Path()..addPath(out, Offset(shift, 0));
    }
    return res;
  }

  static String? _cacheKey;
  static final Map<String, Path?> _paths = {};
  static Path? _landCache;

  Path? _countryCached(Country c) => _paths.putIfAbsent(c.a3 + c.name, () => _country(c));

  void _prepare() {
    final key = '${v.projection}|${v.w}|${v.h}|${v.lon0.toStringAsFixed(4)}|${v.lat0.toStringAsFixed(4)}|${v.zoom.toStringAsFixed(5)}';
    if (key == _cacheKey) return;
    _cacheKey = key;
    _paths.clear();
    final land = Path();
    for (final c in WorldMap.countries) {
      final p = _countryCached(c);
      if (p != null) land.addPath(p, Offset.zero);
    }
    _landCache = land;
  }

  // --------------------------------------------------------------- paint

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final globe = v.isGlobe;
    final disc = Path()..addOval(Rect.fromCircle(center: Offset(v.cx, v.cy), radius: v.radius));
    _prepare();

    // Ocean.
    final oceanPaint = Paint()
      ..shader = ui.Gradient.radial(globe ? Offset(v.cx - v.radius * 0.35, v.cy - v.radius * 0.35) : rect.center,
          globe ? v.radius * 1.4 : size.longestSide * 0.75, [_c(st.ocean), _c(st.ocean2)]);
    if (globe) {
      if (g.atmosphere) _atmosphere(canvas);
      canvas.drawPath(disc, oceanPaint);
      canvas.save();
      canvas.clipPath(disc);
    } else {
      canvas.drawRect(rect, oceanPaint);
      canvas.save();
      canvas.clipRect(rect);
    }

    final land = _landCache;
    final highlighted = <String, GeoHighlight>{};
    for (final h in g.highlights) {
      final c = WorldMap.find(h.code);
      if (c != null) highlighted[c.a3 + c.name] = h;
    }

    // Coast glow under the land.
    if (land != null && st.coast >> 24 != 0 && st.coastGlow > 0) {
      canvas.drawPath(
          land,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = st.coastGlow * 1.6
            ..color = _c(st.coast, 0.55)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, st.coastGlow));
    }

    // Satellite texture.
    final tx = tex;
    if (tx != null) _texture(canvas, tx, st.textureOpacity);

    // Land fill.
    if (land != null && (tx == null || st.textureOpacity < 0.99)) {
      final landPaint = Paint()..shader = ui.Gradient.linear(Offset(0, 0), Offset(0, size.height), [_c(st.land), _c(st.land2)]);
      if (g.dimOthers && highlighted.isNotEmpty) {
        final dim = Paint()..color = _c(st.dimmed);
        for (final c in WorldMap.countries) {
          final p = _paths[c.a3 + c.name];
          if (p == null) continue;
          canvas.drawPath(p, highlighted.containsKey(c.a3 + c.name) ? landPaint : dim);
        }
      } else {
        canvas.drawPath(land, landPaint);
      }
    }

    if (g.graticule) _graticule(canvas);

    // Borders.
    if (land != null && g.borders) {
      final bp = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = g.borderWidth
        ..strokeJoin = StrokeJoin.round
        ..color = _c(st.border);
      for (final c in WorldMap.countries) {
        final p = _paths[c.a3 + c.name];
        if (p != null) canvas.drawPath(p, bp);
      }
      if (st.landStroke) {
        canvas.drawPath(
            land,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = g.borderWidth * 1.8
              ..color = _c(st.coast == 0 ? st.border : st.coast, 0.9));
      }
    }

    // Highlights (extruded slabs, glow borders).
    for (final h in g.highlights) {
      final c = WorldMap.find(h.code);
      if (c == null) continue;
      final p = _paths[c.a3 + c.name];
      if (p == null) continue;
      _highlight(canvas, p, h, _reveal(h.from, h.to));
    }

    if (globe) _terminator(canvas);
    _styleTexture(canvas, size);

    // Routes, pins, labels on top.
    for (final r in g.routes) {
      _route(canvas, r);
    }
    for (final pin in g.pins) {
      _pin(canvas, pin);
    }
    if (g.labels) {
      for (final h in g.highlights) {
        if (h.label == null) continue;
        final c = WorldMap.find(h.code);
        if (c == null) continue;
        final a = _reveal(h.from, h.to);
        if (a <= 0) continue;
        final (x, y, vis) = v.project(c.labelLon, c.labelLat);
        if (!vis) continue;
        final text = (h.label!.isEmpty ? c.name : h.label!).toUpperCase();
        _text(canvas, text, Offset(x, y + h.extrude * 0.5), g.labelSize, _c(st.labelColor, a), center: true, lift: (1 - a) * 18);
      }
    }
    canvas.restore();

    // Vignette.
    if (st.vignette > 0) {
      canvas.drawRect(
          rect,
          Paint()
            ..shader = ui.Gradient.radial(rect.center, size.longestSide * 0.62, [const Color(0x00000000), Color.fromRGBO(0, 0, 0, st.vignette * 0.85)],
                [0.55, 1.0]));
    }
  }

  void _atmosphere(Canvas canvas) {
    final r = v.radius;
    final o = Offset(v.cx, v.cy);
    canvas.drawCircle(
        o,
        r * 1.16,
        Paint()
          ..shader = ui.Gradient.radial(o, r * 1.16, [_c(st.atmosphere, 0.0), _c(st.atmosphere, 0.55), _c(st.atmosphere, 0.0)],
              [0.80, 0.865, 1.0]));
  }

  void _terminator(Canvas canvas) {
    final r = v.radius;
    final o = Offset(v.cx, v.cy);
    // Light from the upper left: a soft night side and a bright rim.
    canvas.drawCircle(
        o,
        r,
        Paint()
          ..shader = ui.Gradient.radial(o.translate(-r * 0.45, -r * 0.45), r * 1.9,
              [const Color(0x00000000), const Color(0x00000000), const Color(0xB0000000)], [0.0, 0.45, 1.0]));
    canvas.drawCircle(
        o,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.03
          ..color = _c(st.atmosphere, 0.5)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.02));
  }

  void _texture(Canvas canvas, ui.Image img, double opacity) {
    final cols = draft ? 36 : 72, rows = draft ? 18 : 36;
    final iw = img.width.toDouble(), ih = img.height.toDouble();
    final pos = <Offset>[], uv = <Offset>[], vis = <bool>[];
    for (int j = 0; j <= rows; j++) {
      final lat = 90 - 180 * j / rows;
      for (int i = 0; i <= cols; i++) {
        final dl = -180 + 360 * i / cols; // relative longitude
        final lon = v.lon0 + dl;
        final (x, y, ok) = v.projectRel(dl, lat);
        pos.add(Offset(x, y));
        vis.add(ok);
        uv.add(Offset((lon + 180) / 360 * iw, (90 - lat) / 180 * ih));
      }
    }
    final tri = <int>[];
    for (int j = 0; j < rows; j++) {
      for (int i = 0; i < cols; i++) {
        final a = j * (cols + 1) + i, b = a + 1, c = a + cols + 1, d = c + 1;
        if (v.isGlobe && !(vis[a] || vis[b] || vis[c] || vis[d])) continue;
        tri.addAll([a, b, c, b, d, c]);
      }
    }
    if (tri.isEmpty) return;
    final vertices = ui.Vertices(ui.VertexMode.triangles, pos, textureCoordinates: uv, indices: tri);
    final paint = Paint()
      ..shader = ImageShader(img, TileMode.repeated, TileMode.clamp, Float64List.fromList(Matrix4.identity().storage),
          filterQuality: draft ? FilterQuality.low : FilterQuality.medium)
      ..color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0));
    canvas.drawVertices(vertices, BlendMode.modulate, paint);
    vertices.dispose();
  }

  void _graticule(Canvas canvas) {
    final step = v.zoom > 6 ? 5.0 : (v.zoom > 2.5 ? 10.0 : 15.0);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = _c(st.graticule);
    for (double lon = -180; lon < 180; lon += step) {
      _polyline(canvas, [for (double lat = -80; lat <= 80; lat += 2) [lon, lat]], paint);
    }
    for (double lat = -75; lat <= 75; lat += step) {
      _polyline(canvas, [for (double lon = -180; lon <= 180; lon += 2) [lon, lat]], paint);
    }
  }

  void _polyline(Canvas canvas, List<List<double>> pts, Paint paint) {
    Path? p;
    var down = false;
    var dl = v.dLon(pts.first[0]);
    var prev = pts.first[0];
    for (int i = 0; i < pts.length; i++) {
      if (i > 0) {
        var d = pts[i][0] - prev;
        if (d > 180) d -= 360;
        if (d < -180) d += 360;
        dl += d;
      }
      prev = pts[i][0];
      final (x, y, vis) = v.projectRel(dl, pts[i][1]);
      if (!vis) {
        down = false;
        continue;
      }
      p ??= Path();
      if (!down) {
        p.moveTo(x, y);
        down = true;
      } else {
        p.lineTo(x, y);
      }
    }
    if (p != null) canvas.drawPath(p, paint);
  }

  void _highlight(Canvas canvas, Path p, GeoHighlight h, double a) {
    if (a <= 0) return;
    final fill = h.fill ?? st.highlight;
    final stroke = h.stroke ?? st.highlightStroke;
    final ex = h.extrude * a;
    final base = Color(fill);
    if (ex > 0.5) {
      // Drop shadow, then the slab sides (darker), then the top face lifted.
      canvas.drawPath(
          p.shift(Offset(ex * 0.4, ex + 6)),
          Paint()
            ..color = Color.fromRGBO(0, 0, 0, 0.45 * a)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 + ex * 0.4));
      final steps = math.min(28, ex.ceil());
      for (int i = steps; i >= 1; i--) {
        final f = i / steps;
        final shade = Color.lerp(base, Colors.black, 0.35 + 0.25 * f)!;
        canvas.drawPath(p.shift(Offset(0, ex * f)), Paint()..color = shade.withValues(alpha: shade.a * a));
      }
    }
    final top = p.shift(Offset.zero);
    final b = top.getBounds();
    canvas.drawPath(
        top,
        Paint()
          ..shader = ui.Gradient.linear(b.topLeft, b.bottomRight,
              [Color.lerp(base, Colors.white, 0.18)!.withValues(alpha: base.a * a), base.withValues(alpha: base.a * a)]));
    if (h.glow > 0 && st.glow >> 24 != 0) {
      canvas.drawPath(
          top,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3 + h.glow * 0.12
            ..color = _c(st.glow, 0.85 * a)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 + h.glow * 0.16));
    }
    canvas.drawPath(
        top,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeJoin = StrokeJoin.round
          ..color = _c(stroke, a));
  }

  /// Projected route points (screen), with the arc lift applied.
  List<Offset> _routePoints(GeoRoute r) {
    final pts = <List<double>>[];
    for (int i = 0; i + 1 < r.points.length; i++) {
      final a = r.points[i], b = r.points[i + 1];
      final gc = GeoView.greatCircle(a, b, n: 64);
      if (i > 0) gc.removeAt(0);
      pts.addAll(gc);
    }
    final out = <Offset>[];
    var dl = v.dLon(pts.first[0]);
    var prev = pts.first[0];
    for (int i = 0; i < pts.length; i++) {
      if (i > 0) {
        var d = pts[i][0] - prev;
        if (d > 180) d -= 360;
        if (d < -180) d += 360;
        dl += d;
      }
      prev = pts[i][0];
      final (x, y, vis) = v.projectRel(dl, pts[i][1]);
      if (v.isGlobe && !vis) {
        out.add(Offset.infinite);
        continue;
      }
      out.add(Offset(x, y));
    }
    if (r.arc > 0 && out.length > 2) {
      var len = 0.0;
      for (int i = 1; i < out.length; i++) {
        if (out[i].isFinite && out[i - 1].isFinite) len += (out[i] - out[i - 1]).distance;
      }
      final n = out.length - 1;
      for (int i = 0; i <= n; i++) {
        if (!out[i].isFinite) continue;
        final s = math.sin(math.pi * i / n);
        if (v.isGlobe) {
          final o = Offset(v.cx, v.cy);
          out[i] = o + (out[i] - o) * (1 + r.arc * 0.18 * s);
        } else {
          out[i] = out[i].translate(0, -r.arc * 0.22 * len * s);
        }
      }
    }
    return out;
  }

  void _route(Canvas canvas, GeoRoute r) {
    final p = _reveal(r.from, r.to);
    if (p <= 0) return;
    final pts = _routePoints(r);
    // Cumulative length (visible segments only).
    final cum = <double>[0];
    for (int i = 1; i < pts.length; i++) {
      final ok = pts[i].isFinite && pts[i - 1].isFinite;
      cum.add(cum.last + (ok ? (pts[i] - pts[i - 1]).distance : 0));
    }
    final total = cum.last;
    if (total <= 0) return;
    final upto = total * p;
    final path = Path();
    var down = false;
    Offset? tip, before;
    for (int i = 0; i < pts.length; i++) {
      if (!pts[i].isFinite) {
        down = false;
        continue;
      }
      if (cum[i] > upto) {
        if (i > 0 && pts[i - 1].isFinite) {
          final f = (upto - cum[i - 1]) / math.max(1e-6, cum[i] - cum[i - 1]);
          final q = Offset.lerp(pts[i - 1], pts[i], f)!;
          path.lineTo(q.dx, q.dy);
          before = pts[i - 1];
          tip = q;
        }
        break;
      }
      if (!down) {
        path.moveTo(pts[i].dx, pts[i].dy);
        down = true;
      } else {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      before = tip;
      tip = pts[i];
    }
    var drawn = path;
    if (r.dashed) {
      drawn = Path();
      final dash = r.width * 3.2, gap = r.width * 2.2;
      for (final m in path.computeMetrics()) {
        var d = 0.0;
        while (d < m.length) {
          drawn.addPath(m.extractPath(d, math.min(m.length, d + dash)), Offset.zero);
          d += dash + gap;
        }
      }
    }
    final col = Color(r.color);
    if (r.glow > 0) {
      canvas.drawPath(
          drawn,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = r.width * (1.8 + r.glow / 40)
            ..strokeCap = StrokeCap.round
            ..color = col.withValues(alpha: 0.55)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r.width * (0.8 + r.glow / 35)));
    }
    canvas.drawPath(
        drawn,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r.width
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = col);
    if (tip != null && before != null) {
      final dir = tip - before;
      if (r.comet && p < 0.999) {
        canvas.drawCircle(
            tip,
            r.width * 3.2,
            Paint()
              ..shader = ui.Gradient.radial(tip, r.width * 3.2, [Colors.white, col.withValues(alpha: 0.6), col.withValues(alpha: 0)], [0, 0.35, 1]));
      }
      if (r.arrow && dir.distance > 0.01) {
        final u = dir / dir.distance;
        final n = Offset(-u.dy, u.dx);
        final s = r.width * 2.6;
        final head = Path()
          ..moveTo(tip.dx + u.dx * s, tip.dy + u.dy * s)
          ..lineTo(tip.dx - u.dx * s * 0.6 + n.dx * s, tip.dy - u.dy * s * 0.6 + n.dy * s)
          ..lineTo(tip.dx - u.dx * s * 0.2, tip.dy - u.dy * s * 0.2)
          ..lineTo(tip.dx - u.dx * s * 0.6 - n.dx * s, tip.dy - u.dy * s * 0.6 - n.dy * s)
          ..close();
        canvas.drawPath(head, Paint()..color = col);
      }
    }
    final label = r.label;
    if (label != null && label.isNotEmpty && p > 0.6 && pts.isNotEmpty) {
      final mid = pts[pts.length ~/ 2];
      if (mid.isFinite) _text(canvas, label.toUpperCase(), mid.translate(0, -r.width * 4), g.labelSize * 0.6, col.withValues(alpha: (p - 0.6) / 0.4), center: true);
    }
  }

  void _pin(Canvas canvas, GeoPin pin) {
    final since = progress - pin.at;
    if (since < 0) return;
    final (x, y, vis) = v.project(pin.lon, pin.lat);
    if (!vis) return;
    final o = Offset(x, y);
    final pop = since >= 0.05 ? 1.0 : _back(since / 0.05);
    final col = Color(pin.color);
    final s = pin.size * pop;
    if (pin.kind == 'pulse' || pin.kind == 'ring') {
      for (int k = 0; k < (pin.kind == 'pulse' ? 3 : 1); k++) {
        final ph = ((local * 0.8 + k / 3) % 1.0);
        canvas.drawCircle(
            o,
            s * (1.2 + ph * 3.2),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.5
              ..color = col.withValues(alpha: (1 - ph) * 0.8));
      }
    }
    canvas.drawCircle(o, s * 1.5, Paint()..color = col.withValues(alpha: 0.35)..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.8));
    if (pin.kind == 'diamond') {
      final d = Path()
        ..moveTo(x, y - s)
        ..lineTo(x + s, y)
        ..lineTo(x, y + s)
        ..lineTo(x - s, y)
        ..close();
      canvas.drawPath(d, Paint()..color = col);
      canvas.drawPath(d, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = Colors.white);
    } else {
      canvas.drawCircle(o, s * 0.62, Paint()..color = Colors.white);
      canvas.drawCircle(o, s * 0.45, Paint()..color = col);
    }
    final label = pin.label;
    if (label != null && label.isNotEmpty) {
      _text(canvas, label.toUpperCase(), o.translate(s * 1.6, -g.labelSize * 0.32), g.labelSize * 0.55, _c(st.labelColor, pop.clamp(0.0, 1.0)));
    }
  }

  static double _back(double x) {
    const c1 = 1.70158, c3 = c1 + 1;
    final t = x.clamp(0.0, 1.0) - 1;
    return 1 + c3 * t * t * t + c1 * t * t;
  }

  void _text(Canvas canvas, String text, Offset at, double size, Color color, {bool center = false, double lift = 0}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: FontCatalog.resolve(g.font, text),
          fontSize: size,
          fontWeight: FontWeight.w700,
          letterSpacing: size * 0.08,
          color: color,
          shadows: [Shadow(color: _c(st.labelShadow, color.a), blurRadius: size * 0.25, offset: Offset(0, size * 0.05))],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final o = center ? at.translate(-tp.width / 2, -tp.height / 2 - lift) : at.translate(0, -lift);
    tp.paint(canvas, o);
  }

  void _styleTexture(Canvas canvas, Size size) {
    switch (st.texture) {
      case 'paper':
        final rnd = math.Random(7);
        final p = Paint()..color = const Color(0x14301E0E);
        for (int i = 0; i < (draft ? 900 : 2600); i++) {
          canvas.drawCircle(Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height), rnd.nextDouble() * 1.6, p);
        }
      case 'grid':
        final p = Paint()
          ..color = _c(st.graticule == 0 ? 0x22FFFFFF : st.graticule, 0.8)
          ..strokeWidth = 1;
        for (double x = 0; x < size.width; x += 48) {
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
        }
        for (double y = 0; y < size.height; y += 48) {
          canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
        }
      case 'scan':
        final p = Paint()..color = const Color(0x1400FFC8);
        for (double y = 0; y < size.height; y += 4) {
          canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1.2), p);
        }
      case 'dots':
        final p = Paint()..color = const Color(0x16000000);
        for (double y = 0; y < size.height; y += 7) {
          for (double x = (y ~/ 7).isEven ? 0 : 3.5; x < size.width; x += 7) {
            canvas.drawCircle(Offset(x, y), 1.1, p);
          }
        }
    }
  }

  @override
  bool shouldRepaint(covariant GeoPainter o) =>
      o.g != g || o.st != st || o.progress != progress || o.local != local || o.tex != tex || o.draft != draft ||
      o.v.projection != v.projection || o.v.lon0 != v.lon0 || o.v.lat0 != v.lat0 || o.v.zoom != v.zoom || o.v.w != v.w || o.v.h != v.h;
}
// <<< win-40
