import 'dart:convert';

/// Country outlines from Natural Earth (public domain), India point-of-view
/// borders, simplified. Loaded once from assets/world_countries.json.
/// Map space: equirectangular, 3600 × 1800 px (10 px per degree).
class Country {
  final String name, a3, a2;
  final double labelLon, labelLat;
  final List<List<double>> rings; // [lon, lat, lon, lat, ...]
  Country(this.name, this.a3, this.a2, this.labelLon, this.labelLat, this.rings);
}

class WorldMap {
  static const double width = 3600, height = 1800;
  static List<Country>? _countries;

  static bool get loaded => _countries != null;
  static List<Country> get countries => _countries ?? const [];

  static void load(String json) {
    final list = jsonDecode(json) as List;
    _countries = [
      for (final c in list)
        Country(
          '${c['n']}',
          '${c['a3']}',
          '${c['a2']}',
          (c['lx'] as num).toDouble(),
          (c['ly'] as num).toDouble(),
          [for (final r in c['r'] as List) (r as List).map((v) => (v as num).toDouble()).toList()],
        ),
    ];
  }

  static List<double> project(double lon, double lat) => [(lon + 180) * 10, (90 - lat) * 10];

  /// Finds a country by ISO code (IND / IN) or name (case-insensitive, partial).
  static Country? find(String q) {
    final s = q.trim().toLowerCase();
    if (s.isEmpty) return null;
    for (final c in countries) {
      if (c.a3.toLowerCase() == s || c.a2.toLowerCase() == s || c.name.toLowerCase() == s) return c;
    }
    // Common long / old / informal names ("United States of America", "UK").
    final alias = _aliases[s];
    if (alias != null) return find(alias);
    for (final c in countries) {
      if (c.name.toLowerCase().contains(s)) return c;
    }
    // A longer name that contains a country name ("Republic of India").
    Country? best;
    for (final c in countries) {
      final n = c.name.toLowerCase();
      if (n.length >= 4 && s.contains(n) && (best == null || n.length > best.name.length)) best = c;
    }
    return best;
  }

  static const _aliases = {
    'united states of america': 'USA', 'america': 'USA', 'us': 'USA', 'the united states': 'USA',
    'uk': 'GBR', 'britain': 'GBR', 'great britain': 'GBR', 'england': 'GBR', 'scotland': 'GBR', 'wales': 'GBR',
    'holland': 'NLD', 'burma': 'MMR', 'persia': 'IRN', 'ceylon': 'LKA', 'siam': 'THA', 'russia': 'RUS',
    'south korea': 'KOR', 'north korea': 'PRK', 'czech republic': 'CZE', 'ivory coast': 'CIV', 'uae': 'ARE',
  };

  /// Rings projected into map pixels, optionally relative to an origin.
  static List<List<double>> projectRings(Country c) => [
        for (final r in c.rings)
          [
            for (int i = 0; i + 1 < r.length; i += 2) ...project(r[i], r[i + 1]),
          ],
      ];

  /// Bounding box in map pixels: [minX, minY, maxX, maxY] (largest landmass only,
  /// so far-away islands don't make the zoom too wide).
  static List<double> bbox(Country c) {
    List<double>? best;
    double bestArea = -1;
    for (final r in projectRings(c)) {
      double minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9;
      for (int i = 0; i + 1 < r.length; i += 2) {
        if (r[i] < minX) minX = r[i];
        if (r[i] > maxX) maxX = r[i];
        if (r[i + 1] < minY) minY = r[i + 1];
        if (r[i + 1] > maxY) maxY = r[i + 1];
      }
      final a = (maxX - minX) * (maxY - minY);
      if (a > bestArea) {
        bestArea = a;
        best = [minX, minY, maxX, maxY];
      }
    }
    return best ?? [0, 0, width, height];
  }
}
