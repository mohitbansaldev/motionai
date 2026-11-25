import 'dart:math' as math;

import 'vector_icons.dart' show VectorIcons;

/// V3-C: simple drawn national flags for the round `flag_badge` (100 × 100
/// box, cropped to a circle by the component). Our own simplified drawings:
/// bands, crosses, discs, stars, crescents — emblems and fine detail are
/// left out. Unknown countries get a colour disc with the country code.
class FlagPart {
  final List<List<double>> rings;
  final String color;
  const FlagPart(this.color, this.rings);
}

class FlagDesign {
  final String code; // ISO 3166-1 alpha-2
  final String name;
  final List<String> names; // alpha-3 + common names (lower case)
  final List<FlagPart> parts;
  const FlagDesign(this.code, this.name, this.names, this.parts);
}

class Flags {
  Flags._();

  static List<double> _r(double x0, double y0, double x1, double y1) => [x0, y0, x1, y0, x1, y1, x0, y1];

  static List<FlagPart> _h(List<String> colors, [List<double>? weights]) {
    final w = weights ?? List.filled(colors.length, 1.0);
    final total = w.fold<double>(0, (a, b) => a + b);
    final out = <FlagPart>[];
    var y = 0.0;
    for (int i = 0; i < colors.length; i++) {
      final y1 = y + w[i] / total * 100;
      out.add(FlagPart(colors[i], [_r(-2, i == 0 ? -2 : y, 102, i == colors.length - 1 ? 102 : y1 + 0.6)]));
      y = y1;
    }
    return out;
  }

  static List<FlagPart> _v(List<String> colors) => [
        for (int i = 0; i < colors.length; i++)
          FlagPart(colors[i], [_r(i * 100 / colors.length - (i == 0 ? 2 : 0), -2, (i + 1) * 100 / colors.length + 0.6, 102)]),
      ];

  static List<double> star(double cx, double cy, double r, {int points = 5, double inner = 0.4, double rot = -90}) => [
        for (int i = 0; i < points * 2; i++) ...[
          cx + math.cos((rot + i * 180 / points) * math.pi / 180) * r * (i.isOdd ? inner : 1),
          cy + math.sin((rot + i * 180 / points) * math.pi / 180) * r * (i.isOdd ? inner : 1),
        ],
      ];

  /// Crescent: disc (cx, cy, r) minus a disc of radius [r2] shifted by [d]
  /// toward angle [dir] (degrees).
  static List<double> crescent(double cx, double cy, double r, double r2, double d, double dir) {
    final ox = cx + math.cos(dir * math.pi / 180) * d, oy = cy + math.sin(dir * math.pi / 180) * d;
    bool inside2(double x, double y) => (x - ox) * (x - ox) + (y - oy) * (y - oy) < r2 * r2;
    bool inside1(double x, double y) => (x - cx) * (x - cx) + (y - cy) * (y - cy) < r * r;
    const n = 90;
    final outer = <double>[], inner = <double>[];
    // outer arc: start opposite the cut so the kept points are contiguous
    for (int i = 0; i <= n; i++) {
      final a = (dir + 180 + (i - n / 2) * 360 / n) * math.pi / 180;
      final x = cx + math.cos(a) * r, y = cy + math.sin(a) * r;
      if (!inside2(x, y)) outer.addAll([x, y]);
    }
    for (int i = n; i >= 0; i--) {
      final a = (dir + 180 + (i - n / 2) * 360 / n) * math.pi / 180;
      final x = ox + math.cos(a) * r2, y = oy + math.sin(a) * r2;
      if (inside1(x, y)) inner.addAll([x, y]);
    }
    return [...outer, ...inner];
  }

  static List<FlagPart> _nordic(String bg, String cross, [String? inner]) => [
        FlagPart(bg, [_r(-2, -2, 102, 102)]),
        FlagPart(cross, [_r(28, -2, 46, 102), _r(-2, 41, 102, 59)]),
        if (inner != null) FlagPart(inner, [_r(32, -2, 42, 102), _r(-2, 45, 102, 55)]),
      ];

  static final List<FlagDesign> all = [
    FlagDesign('IN', 'India', ['ind', 'india', 'bharat', 'hindustan', 'भारत'], [
      ..._h(['#FF9933', '#FFFFFF', '#138808']),
      FlagPart('#000080', [VectorIcons.circle(50, 50, 12), VectorIcons.circle(50, 50, 9.6, ccw: true), VectorIcons.circle(50, 50, 2.6)]),
      FlagPart('#000080', [
        for (int i = 0; i < 12; i++)
          [
            50 + math.cos(i * math.pi / 12) * 10, 50 + math.sin(i * math.pi / 12) * 10,
            50 + math.cos(i * math.pi / 12 + 0.07) * 10, 50 + math.sin(i * math.pi / 12 + 0.07) * 10,
            50 - math.cos(i * math.pi / 12) * 10, 50 - math.sin(i * math.pi / 12) * 10,
            50 - math.cos(i * math.pi / 12 + 0.07) * 10, 50 - math.sin(i * math.pi / 12 + 0.07) * 10,
          ],
      ]),
    ]),
    FlagDesign('US', 'United States', ['usa', 'united states', 'america', 'us', 'united states of america'], [
      FlagPart('#B22234', [_r(-2, -2, 102, 102)]),
      FlagPart('#FFFFFF', [for (int i = 0; i < 6; i++) _r(-2, (2 * i + 1) * 100 / 13, 102, (2 * i + 2) * 100 / 13)]),
      FlagPart('#3C3B6E', [_r(-2, -2, 48, 7 * 100 / 13)]),
      FlagPart('#FFFFFF', [
        for (int r = 0; r < 4; r++)
          for (int c = 0; c < 4; c++) star(8.0 + c * 11 + (r.isOdd ? 5.5 : 0.0), 7.0 + r * 11, 3.2),
      ]),
    ]),
    FlagDesign('GB', 'United Kingdom', ['gbr', 'uk', 'united kingdom', 'britain', 'great britain', 'england'], [
      FlagPart('#012169', [_r(-2, -2, 102, 102)]),
      FlagPart('#FFFFFF', [
        [-2, 8, 8, -2, 102, 92, 92, 102],
        [92, -2, 102, 8, 8, 102, -2, 92],
      ]),
      FlagPart('#C8102E', [
        [-2, 2, 2, -2, 102, 98, 98, 102],
        [98, -2, 102, 2, 2, 102, -2, 98],
      ]),
      FlagPart('#FFFFFF', [_r(38, -2, 62, 102), _r(-2, 38, 102, 62)]),
      FlagPart('#C8102E', [_r(43, -2, 57, 102), _r(-2, 43, 102, 57)]),
    ]),
    FlagDesign('FR', 'France', ['fra', 'france'], _v(['#002395', '#FFFFFF', '#ED2939'])),
    FlagDesign('IT', 'Italy', ['ita', 'italy'], _v(['#009246', '#FFFFFF', '#CE2B37'])),
    FlagDesign('IE', 'Ireland', ['irl', 'ireland'], _v(['#169B62', '#FFFFFF', '#FF883E'])),
    FlagDesign('BE', 'Belgium', ['bel', 'belgium'], _v(['#000000', '#FAE042', '#ED2939'])),
    FlagDesign('RO', 'Romania', ['rou', 'romania'], _v(['#002B7F', '#FCD116', '#CE1126'])),
    FlagDesign('NG', 'Nigeria', ['nga', 'nigeria'], _v(['#008751', '#FFFFFF', '#008751'])),
    FlagDesign('PE', 'Peru', ['per', 'peru'], _v(['#D91023', '#FFFFFF', '#D91023'])),
    FlagDesign('MX', 'Mexico', ['mex', 'mexico'], [
      ..._v(['#006847', '#FFFFFF', '#CE1126']),
      FlagPart('#8C5A2B', [VectorIcons.circle(50, 50, 9)]),
    ]),
    FlagDesign('AF', 'Afghanistan', ['afg', 'afghanistan'], _v(['#000000', '#D32011', '#007A36'])),
    FlagDesign('DE', 'Germany', ['deu', 'germany'], _h(['#000000', '#DD0000', '#FFCE00'])),
    FlagDesign('RU', 'Russia', ['rus', 'russia'], _h(['#FFFFFF', '#0039A6', '#D52B1E'])),
    FlagDesign('NL', 'Netherlands', ['nld', 'netherlands', 'holland'], _h(['#AE1C28', '#FFFFFF', '#21468B'])),
    FlagDesign('AT', 'Austria', ['aut', 'austria'], _h(['#ED2939', '#FFFFFF', '#ED2939'])),
    FlagDesign('HU', 'Hungary', ['hun', 'hungary'], _h(['#CD2A3E', '#FFFFFF', '#436F4D'])),
    FlagDesign('PL', 'Poland', ['pol', 'poland'], _h(['#FFFFFF', '#DC143C'])),
    FlagDesign('UA', 'Ukraine', ['ukr', 'ukraine'], _h(['#0057B7', '#FFD700'])),
    FlagDesign('ID', 'Indonesia', ['idn', 'indonesia'], _h(['#FF0000', '#FFFFFF'])),
    FlagDesign('EG', 'Egypt', ['egy', 'egypt'], _h(['#CE1126', '#FFFFFF', '#000000'])),
    FlagDesign('IR', 'Iran', ['irn', 'iran'], _h(['#239F40', '#FFFFFF', '#DA0000'])),
    FlagDesign('BO', 'Bolivia', ['bol', 'bolivia'], _h(['#D52B1E', '#F9E300', '#007934'])),
    FlagDesign('ES', 'Spain', ['esp', 'spain'], _h(['#AA151B', '#F1BF00', '#AA151B'], [1, 2, 1])),
    FlagDesign('CO', 'Colombia', ['col', 'colombia'], _h(['#FCD116', '#003893', '#CE1126'], [2, 1, 1])),
    FlagDesign('TH', 'Thailand', ['tha', 'thailand'], _h(['#A51931', '#F4F5F8', '#2D2A4A', '#F4F5F8', '#A51931'], [1, 1, 2, 1, 1])),
    FlagDesign('MM', 'Myanmar', ['mmr', 'myanmar', 'burma'], [
      ..._h(['#FECB00', '#34B233', '#EA2839']),
      FlagPart('#FFFFFF', [star(50, 54, 30, inner: 0.38)]),
    ]),
    FlagDesign('UY', 'Uruguay', ['ury', 'uruguay'], [
      FlagPart('#FFFFFF', [_r(-2, -2, 102, 102)]),
      FlagPart('#0038A8', [for (final i in [1, 3, 5, 7]) _r(-2, i * 100 / 9, 102, (i + 1) * 100 / 9)]),
      FlagPart('#FFFFFF', [_r(-2, -2, 44, 5 * 100 / 9)]),
      FlagPart('#FCD116', [star(22, 27.5, 15, points: 16, inner: 0.62)]),
      FlagPart('#7B3F00', [VectorIcons.circle(22, 27.5, 6.2), VectorIcons.circle(22, 27.5, 5, ccw: true)]),
    ]),
    FlagDesign('AR', 'Argentina', ['arg', 'argentina'], [
      ..._h(['#74ACDF', '#FFFFFF', '#74ACDF']),
      FlagPart('#F6B40E', [star(50, 50, 12, points: 16, inner: 0.6)]),
    ]),
    FlagDesign('CL', 'Chile', ['chl', 'chile'], [
      ..._h(['#FFFFFF', '#D52B1E']),
      FlagPart('#0039A6', [_r(-2, -2, 40, 50)]),
      FlagPart('#FFFFFF', [star(19, 24, 11)]),
    ]),
    FlagDesign('BR', 'Brazil', ['bra', 'brazil', 'brasil'], [
      FlagPart('#009C3B', [_r(-2, -2, 102, 102)]),
      FlagPart('#FFDF00', [
        [50, 12, 94, 50, 50, 88, 6, 50],
      ]),
      FlagPart('#002776', [VectorIcons.circle(50, 50, 20)]),
    ]),
    FlagDesign('JP', 'Japan', ['jpn', 'japan'], [
      FlagPart('#FFFFFF', [_r(-2, -2, 102, 102)]),
      FlagPart('#BC002D', [VectorIcons.circle(50, 50, 24)]),
    ]),
    FlagDesign('BD', 'Bangladesh', ['bgd', 'bangladesh'], [
      FlagPart('#006A4E', [_r(-2, -2, 102, 102)]),
      FlagPart('#F42A41', [VectorIcons.circle(45, 50, 24)]),
    ]),
    FlagDesign('CN', 'China', ['chn', 'china', 'prc'], [
      FlagPart('#EE1C25', [_r(-2, -2, 102, 102)]),
      FlagPart('#FFFF00', [
        star(26, 30, 13),
        star(46, 14, 4.2, rot: -60),
        star(54, 24, 4.2, rot: -80),
        star(54, 37, 4.2, rot: -100),
        star(46, 46, 4.2, rot: -120),
      ]),
    ]),
    FlagDesign('VN', 'Vietnam', ['vnm', 'vietnam'], [
      FlagPart('#DA251D', [_r(-2, -2, 102, 102)]),
      FlagPart('#FFFF00', [star(50, 52, 28)]),
    ]),
    FlagDesign('PK', 'Pakistan', ['pak', 'pakistan'], [
      FlagPart('#01411C', [_r(-2, -2, 102, 102)]),
      FlagPart('#FFFFFF', [_r(-2, -2, 25, 102)]),
      FlagPart('#FFFFFF', [crescent(60, 52, 22, 19, 9, -45), star(70, 41, 7.5, rot: -45)]),
    ]),
    FlagDesign('TR', 'Turkey', ['tur', 'turkey', 'turkiye'], [
      FlagPart('#E30A17', [_r(-2, -2, 102, 102)]),
      FlagPart('#FFFFFF', [crescent(42, 50, 22, 18, 6.5, 0), star(64, 50, 8.5, rot: 180)]),
    ]),
    FlagDesign('SG', 'Singapore', ['sgp', 'singapore'], [
      ..._h(['#EF3340', '#FFFFFF']),
      FlagPart('#FFFFFF', [
        crescent(26, 25, 14, 12, 5, 0),
        for (int i = 0; i < 5; i++)
          star(38 + math.cos((-90 + i * 72) * math.pi / 180) * 8, 25 + math.sin((-90 + i * 72) * math.pi / 180) * 8, 2.6),
      ]),
    ]),
    FlagDesign('PH', 'Philippines', ['phl', 'philippines'], [
      ..._h(['#0038A8', '#CE1126']),
      FlagPart('#FFFFFF', [
        [-2, -2, 60, 50, -2, 102],
      ]),
      FlagPart('#FCD116', [star(18, 50, 11, points: 8, inner: 0.55)]),
    ]),
    FlagDesign('CU', 'Cuba', ['cub', 'cuba'], [
      ..._h(['#002A8F', '#FFFFFF', '#002A8F', '#FFFFFF', '#002A8F']),
      FlagPart('#CF142B', [
        [-2, -4, 52, 50, -2, 104],
      ]),
      FlagPart('#FFFFFF', [star(16, 50, 9)]),
    ]),
    FlagDesign('PT', 'Portugal', ['prt', 'portugal'], [
      FlagPart('#FF0000', [_r(-2, -2, 102, 102)]),
      FlagPart('#006600', [_r(-2, -2, 40, 102)]),
      FlagPart('#FFCC00', [VectorIcons.circle(40, 50, 14), VectorIcons.circle(40, 50, 10.5, ccw: true)]),
    ]),
    FlagDesign('GR', 'Greece', ['grc', 'greece'], [
      ..._h(['#0D5EAF', '#FFFFFF', '#0D5EAF', '#FFFFFF', '#0D5EAF', '#FFFFFF', '#0D5EAF', '#FFFFFF', '#0D5EAF']),
      FlagPart('#0D5EAF', [_r(-2, -2, 50, 5 * 100 / 9)]),
      FlagPart('#FFFFFF', [_r(19, -2, 30, 5 * 100 / 9), _r(-2, 22, 50, 33.5)]),
    ]),
    FlagDesign('AE', 'United Arab Emirates', ['are', 'uae', 'emirates', 'united arab emirates'], [
      ..._h(['#00732F', '#FFFFFF', '#000000']),
      FlagPart('#FF0000', [_r(-2, -2, 27, 102)]),
    ]),
    FlagDesign('CH', 'Switzerland', ['che', 'switzerland', 'swiss'], [
      FlagPart('#DA291C', [_r(-2, -2, 102, 102)]),
      FlagPart('#FFFFFF', [_r(42, 20, 58, 80), _r(20, 42, 80, 58)]),
    ]),
    FlagDesign('SE', 'Sweden', ['swe', 'sweden'], _nordic('#006AA7', '#FECC00')),
    FlagDesign('DK', 'Denmark', ['dnk', 'denmark'], _nordic('#C8102E', '#FFFFFF')),
    FlagDesign('FI', 'Finland', ['fin', 'finland'], _nordic('#FFFFFF', '#002F6C')),
    FlagDesign('NO', 'Norway', ['nor', 'norway'], _nordic('#BA0C2F', '#FFFFFF', '#00205B')),
    FlagDesign('IS', 'Iceland', ['isl', 'iceland'], _nordic('#02529C', '#FFFFFF', '#DC1E35')),
    FlagDesign('CA', 'Canada', ['can', 'canada'], [
      FlagPart('#FFFFFF', [_r(-2, -2, 102, 102)]),
      FlagPart('#D52B1E', [_r(-2, -2, 25, 102), _r(75, -2, 102, 102)]),
      FlagPart('#D52B1E', [
        VectorIcons.mirrored([50, 18, 54, 26, 58, 24, 57, 40, 64, 33, 66, 37, 72, 36, 68, 45, 71, 47, 60, 57, 61, 62, 52, 60, 52, 76]),
      ]),
    ]),
  ];

  static final Map<String, FlagDesign> _byKey = {
    for (final f in all) ...{f.code.toLowerCase(): f, for (final n in f.names) n: f},
  };

  /// Flag by ISO alpha-2 / alpha-3 code or English name ("IN", "IND", "India"), or null.
  static FlagDesign? find(String? country) {
    if (country == null) return null;
    final k = country.trim().toLowerCase();
    return _byKey[k] ?? _byKey[k.replaceAll('_', ' ')];
  }

  /// Short code shown on a fallback disc ("NPL" → "NP" stays 2-3 letters).
  static String codeFor(String country) {
    final f = find(country);
    if (f != null) return f.code;
    final s = country.trim().toUpperCase();
    if (s.length <= 3) return s;
    return s.replaceAll(RegExp('[^A-Z]'), '').padRight(2, 'X').substring(0, 2);
  }
}
