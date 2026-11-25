// win-40 >>> GEO LAYERS (After Effects GEOlayers-style live maps).
//
// A geo layer is a shape layer with a [GeoSpec]: a live vector world map that
// re-projects every frame. Its camera over the Earth is animatable through the
// layer props [GeoProps.center] ([lon, lat]), [GeoProps.zoom] (1 = whole world
// across the layer for flat projections, the globe filling 90 % of the short
// side for the globe) and [GeoProps.progress] (0..100: draws routes and reveals
// highlights / pins / labels in order). Everything else is static styling.

int _hex(dynamic v, int def) {
  if (v is int) return v;
  if (v is String) {
    var s = v.trim().replaceFirst('#', '');
    if (s.length == 6) s = 'FF$s';
    if (s.length == 8) {
      final n = int.tryParse(s, radix: 16);
      if (n != null) return n;
    }
  }
  return def;
}

double _d(dynamic v, double def) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) ?? def : def);

String _hexOut(int c) => '#${c.toRadixString(16).padLeft(8, '0').toUpperCase()}';

class GeoProps {
  static const center = 'geo_center'; // [lon, lat]
  static const zoom = 'geo_zoom'; // [x]
  static const progress = 'geo_progress'; // [0..100]
  static const all = [center, zoom, progress];
}

/// Projections a geo layer can use.
class GeoProjections {
  static const all = ['equirectangular', 'mercator', 'natural_earth', 'globe'];
  static String parse(dynamic v) {
    final s = '${v ?? 'equirectangular'}'.toLowerCase().replaceAll('-', '_').replaceAll(' ', '_');
    if (s == 'orthographic' || s == 'sphere' || s == 'earth') return 'globe';
    if (s == 'plate_carree' || s == 'flat' || s == 'equirect') return 'equirectangular';
    if (s == 'naturalearth' || s == 'natural') return 'natural_earth';
    if (all.contains(s)) return s;
    throw FormatException('Unknown map projection "$v" (use ${all.join(', ')})');
  }
}

/// One highlighted country (ISO A3 / A2 code or name).
class GeoHighlight {
  String code;
  int? fill; // null = style highlight colour
  int? stroke;
  double glow; // 0..100
  double extrude; // px of 3D slab thickness (0 = flat)
  String? label; // null = no label, '' = country name
  double from, to; // reveal window on geo_progress (0..1)
  bool flag; // fill with the country's flag colours (see flags.dart) when known

  GeoHighlight(this.code, {this.fill, this.stroke, this.glow = 60, this.extrude = 0, this.label, this.from = 0, this.to = 0.15, this.flag = false});

  GeoHighlight copy() => GeoHighlight(code, fill: fill, stroke: stroke, glow: glow, extrude: extrude, label: label, from: from, to: to, flag: flag);

  Map<String, dynamic> toJson() => {
        'code': code,
        if (fill != null) 'fill': _hexOut(fill!),
        if (stroke != null) 'stroke': _hexOut(stroke!),
        'glow': glow,
        'extrude': extrude,
        if (label != null) 'label': label,
        'from': from,
        'to': to,
        if (flag) 'flag': true,
      };

  static GeoHighlight fromJson(dynamic j) {
    if (j is String) return GeoHighlight(j);
    final m = Map<String, dynamic>.from(j as Map);
    final code = '${m['code'] ?? m['country'] ?? m['name'] ?? ''}';
    if (code.isEmpty) throw const FormatException('A highlight needs "code" (country name or ISO code)');
    final l = m['label'];
    return GeoHighlight(code,
        fill: m['fill'] == null ? null : _hex(m['fill'], 0xFFD0202A),
        stroke: m['stroke'] == null ? null : _hex(m['stroke'], 0xFFFFFFFF),
        glow: _d(m['glow'], 60),
        extrude: _d(m['extrude'], 0),
        label: l == null ? null : (l == true ? '' : (l == false ? null : '$l')),
        from: _d(m['from'], 0).clamp(0, 1).toDouble(),
        to: _d(m['to'], 0.15).clamp(0, 1).toDouble(),
        flag: m['flag'] == true);
  }
}

/// A route over the Earth: great-circle legs between [points] ([lon, lat]).
class GeoRoute {
  List<List<double>> points;
  int color;
  double width; // px at zoom 1
  bool dashed;
  double glow; // 0..100
  bool arrow;
  double arc; // 0..1 lift of the route above flat maps / globe (flight arcs)
  double from, to; // draw window on geo_progress (0..1)
  String? label;
  bool comet; // bright moving head while drawing

  GeoRoute(this.points,
      {this.color = 0xFFFFD23F, this.width = 6, this.dashed = false, this.glow = 50, this.arrow = true, this.arc = 0, this.from = 0.2, this.to = 0.8, this.label, this.comet = true});

  GeoRoute copy() => GeoRoute([for (final p in points) List.of(p)],
      color: color, width: width, dashed: dashed, glow: glow, arrow: arrow, arc: arc, from: from, to: to, label: label, comet: comet);

  Map<String, dynamic> toJson() => {
        'points': points,
        'color': _hexOut(color),
        'width': width,
        if (dashed) 'dashed': true,
        'glow': glow,
        'arrow': arrow,
        'arc': arc,
        'from': from,
        'to': to,
        if (label != null) 'label': label,
        'comet': comet,
      };

  static GeoRoute fromJson(dynamic j) {
    final m = Map<String, dynamic>.from(j as Map);
    final raw = m['points'] ?? m['via'] ?? [if (m['from_point'] != null) m['from_point'], if (m['to_point'] != null) m['to_point']];
    final pts = <List<double>>[for (final p in (raw as List)) [((p as List)[0] as num).toDouble(), (p[1] as num).toDouble()]];
    if (pts.length < 2) throw const FormatException('A route needs at least 2 points ([lon, lat])');
    return GeoRoute(pts,
        color: _hex(m['color'], 0xFFFFD23F),
        width: _d(m['width'], 6),
        dashed: m['dashed'] == true || m['dash'] == true,
        glow: _d(m['glow'], 50),
        arrow: m['arrow'] != false,
        arc: _d(m['arc'], 0).clamp(0, 1).toDouble(),
        from: _d(m['from'], 0.2).clamp(0, 1).toDouble(),
        to: _d(m['to'], 0.8).clamp(0, 1).toDouble(),
        label: m['label'] as String?,
        comet: m['comet'] != false);
  }
}

/// A pin (city, event) at [lon], [lat].
class GeoPin {
  double lon, lat;
  String? label;
  int color;
  String kind; // dot | ring | pulse | diamond
  double at; // appears at this geo_progress (0..1)
  double size; // px

  GeoPin(this.lon, this.lat, {this.label, this.color = 0xFFFF3B30, this.kind = 'pulse', this.at = 0.1, this.size = 14});

  GeoPin copy() => GeoPin(lon, lat, label: label, color: color, kind: kind, at: at, size: size);

  Map<String, dynamic> toJson() => {'lon': lon, 'lat': lat, if (label != null) 'label': label, 'color': _hexOut(color), 'kind': kind, 'at': at, 'size': size};

  static GeoPin fromJson(dynamic j) {
    final m = Map<String, dynamic>.from(j as Map);
    double lon, lat;
    if (m['at_point'] is List || m['point'] is List) {
      final p = (m['at_point'] ?? m['point']) as List;
      lon = (p[0] as num).toDouble();
      lat = (p[1] as num).toDouble();
    } else {
      lon = _d(m['lon'] ?? m['lng'], double.nan);
      lat = _d(m['lat'], double.nan);
    }
    if (lon.isNaN || lat.isNaN) throw const FormatException('A pin needs lon and lat');
    const kinds = ['dot', 'ring', 'pulse', 'diamond'];
    final kind = '${m['kind'] ?? 'pulse'}';
    return GeoPin(lon, lat,
        label: m['label'] as String?,
        color: _hex(m['color'], 0xFFFF3B30),
        kind: kinds.contains(kind) ? kind : 'pulse',
        at: _d(m['at'] ?? m['appear'], 0.1).clamp(0, 1).toDouble(),
        size: _d(m['size'], 14));
  }
}

/// Everything static about a geo layer (the animatable view is in props).
class GeoSpec {
  String style; // see GeoStyles
  String projection;
  bool graticule;
  bool borders;
  bool labels; // auto-label highlighted countries
  bool texture; // satellite texture when the style has one
  String font;
  double labelSize; // px at zoom 1
  double borderWidth; // px
  List<GeoHighlight> highlights;
  List<GeoRoute> routes;
  List<GeoPin> pins;
  bool dimOthers; // darken countries that are not highlighted
  bool atmosphere; // globe rim glow

  GeoSpec({
    this.style = 'dark_political',
    this.projection = 'equirectangular',
    this.graticule = false,
    this.borders = true,
    this.labels = true,
    this.texture = true,
    this.font = 'Oswald',
    this.labelSize = 42,
    this.borderWidth = 1.2,
    List<GeoHighlight>? highlights,
    List<GeoRoute>? routes,
    List<GeoPin>? pins,
    this.dimOthers = false,
    this.atmosphere = true,
  })  : highlights = highlights ?? [],
        routes = routes ?? [],
        pins = pins ?? [];

  GeoSpec copy() => GeoSpec(
        style: style,
        projection: projection,
        graticule: graticule,
        borders: borders,
        labels: labels,
        texture: texture,
        font: font,
        labelSize: labelSize,
        borderWidth: borderWidth,
        highlights: [for (final h in highlights) h.copy()],
        routes: [for (final r in routes) r.copy()],
        pins: [for (final p in pins) p.copy()],
        dimOthers: dimOthers,
        atmosphere: atmosphere,
      );

  Map<String, dynamic> toJson() => {
        'style': style,
        'projection': projection,
        'graticule': graticule,
        'borders': borders,
        'labels': labels,
        'texture': texture,
        'font': font,
        'labelSize': labelSize,
        'borderWidth': borderWidth,
        'highlights': [for (final h in highlights) h.toJson()],
        'routes': [for (final r in routes) r.toJson()],
        'pins': [for (final p in pins) p.toJson()],
        'dimOthers': dimOthers,
        'atmosphere': atmosphere,
      };

  /// Applies the keys present in [m] (used by both add_geo and update_geo).
  void apply(Map<String, dynamic> m) {
    if (m.containsKey('style')) style = '${m['style']}';
    if (m.containsKey('projection')) projection = GeoProjections.parse(m['projection']);
    if (m['graticule'] is bool) graticule = m['graticule'] as bool;
    if (m['borders'] is bool) borders = m['borders'] as bool;
    if (m['labels'] is bool) labels = m['labels'] as bool;
    if (m['texture'] is bool) texture = m['texture'] as bool;
    if (m['font'] is String) font = m['font'] as String;
    if (m.containsKey('label_size') || m.containsKey('labelSize')) labelSize = _d(m['label_size'] ?? m['labelSize'], labelSize);
    if (m.containsKey('border_width') || m.containsKey('borderWidth')) borderWidth = _d(m['border_width'] ?? m['borderWidth'], borderWidth);
    if (m['highlight'] != null || m['highlights'] != null) {
      final h = m['highlights'] ?? m['highlight'];
      highlights = [for (final x in (h is List ? h : [h])) GeoHighlight.fromJson(x)];
    }
    if (m['routes'] is List) routes = [for (final r in m['routes'] as List) GeoRoute.fromJson(r)];
    if (m['pins'] is List) pins = [for (final p in m['pins'] as List) GeoPin.fromJson(p)];
    if (m['dim_others'] is bool || m['dimOthers'] is bool) dimOthers = (m['dim_others'] ?? m['dimOthers']) as bool;
    if (m['atmosphere'] is bool) atmosphere = m['atmosphere'] as bool;
  }

  static GeoSpec fromJson(Map<String, dynamic> j) {
    final s = GeoSpec();
    s.apply({
      ...j,
      if (j['highlights'] is List) 'highlights': j['highlights'],
    });
    return s;
  }

  /// Content fingerprint (preview caching).
  int get signature => Object.hash(style, projection, graticule, borders, labels, texture, font, labelSize, borderWidth, dimOthers, atmosphere,
      Object.hashAll([for (final h in highlights) Object.hash(h.code, h.fill, h.stroke, h.glow, h.extrude, h.label, h.from, h.to, h.flag)]),
      Object.hashAll([for (final r in routes) Object.hash(Object.hashAll(r.points.expand((p) => p)), r.color, r.width, r.dashed, r.glow, r.arrow, r.arc, r.from, r.to, r.label)]),
      Object.hashAll([for (final p in pins) Object.hash(p.lon, p.lat, p.label, p.color, p.kind, p.at, p.size)]));
}
// <<< win-40
