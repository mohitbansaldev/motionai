import 'dart:math' as math;

/// V3-C: MotionAI's own vector pictogram set (no emoji fonts, no third-party
/// icons). Every icon is drawn in a 100 × 100 box (y down, centre 50,50) as
/// filled rings and stroked lines, so it renders as ordinary shape layers.
///
/// Part roles: `main` (the icon colour), `detail` (contrast marks drawn on
/// top: tick, needle, window — skipped in mono pictograms), `accent` (a
/// second colour, e.g. cuffs; mono → main colour).
class IconPart {
  final List<List<double>> rings; // flat [x0,y0,x1,y1,...] per ring, box units
  final String role; // main | detail | accent
  final double stroke; // > 0: stroked lines of this width (box units), no fill
  final bool closed;
  final String? text; // text part (e.g. "STOP"): drawn as a text layer
  final double x, y, size; // text centre and size (box units)
  const IconPart(this.rings, {this.role = 'main', this.stroke = 0, this.closed = true})
      : text = null,
        x = 50,
        y = 50,
        size = 0;
  const IconPart.text(this.text, this.x, this.y, this.size, {this.role = 'detail'})
      : rings = const [],
        stroke = 0,
        closed = true;
  bool get isText => text != null;
}

class VectorIcon {
  final String id;
  final String label;
  final String main; // default colours (#RRGGBB)
  final String detail;
  final String accent;
  final List<IconPart> parts;
  const VectorIcon(this.id, this.label, this.parts, {this.main = '#FFFFFF', this.detail = '#111111', this.accent = '#1E40D0'});
}

class VectorIcons {
  VectorIcons._();

  static const names = [
    'person', 'seat', 'scale', 'money', 'clock', 'fuel', 'stop', 'handshake', 'check', 'cross', 'warning', 'music', 'heart',
    'radio', 'plane', 'helicopter', 'globe',
  ];

  /// Synonyms the AI / users may type.
  static const aliases = {
    'people': 'person', 'human': 'person', 'man': 'person', 'passenger': 'person', 'chair': 'seat', 'weight': 'scale',
    'balance': 'scale', 'justice': 'scale', 'cash': 'money', 'rupee': 'money', 'dollar': 'money', 'time': 'clock',
    'watch': 'clock', 'petrol': 'fuel', 'gas': 'fuel', 'octagon': 'stop', 'deal': 'handshake', 'pact': 'handshake',
    'yes': 'check', 'tick': 'check', 'ok': 'check', 'no': 'cross', 'x': 'cross', 'wrong': 'cross', 'danger': 'warning',
    'alert': 'warning', 'note': 'music', 'song': 'music', 'love': 'heart', 'life': 'heart', 'broadcast': 'radio',
    'airplane': 'plane', 'aircraft': 'plane', 'flight': 'plane', 'chopper': 'helicopter', 'world': 'globe', 'earth': 'globe',
  };

  static String? resolve(String? name) {
    if (name == null) return null;
    final k = name.trim().toLowerCase().replaceAll(RegExp(r'[\s\-]+'), '_');
    if (names.contains(k)) return k;
    return aliases[k];
  }

  static final Map<String, VectorIcon> _cache = {};

  static VectorIcon? byId(String? name) {
    final k = resolve(name);
    if (k == null) return null;
    return _cache[k] ??= _build(k);
  }

  // ------------------------------------------------------------ geometry

  /// Circle / ellipse ring ([ccw] for holes).
  static List<double> ellipse(double cx, double cy, double rx, double ry, {int n = 36, bool ccw = false, double rot = 0}) {
    final out = <double>[];
    final cr = math.cos(rot * math.pi / 180), sr = math.sin(rot * math.pi / 180);
    for (int i = 0; i < n; i++) {
      final a = (ccw ? -1 : 1) * i * 2 * math.pi / n;
      final x = math.cos(a) * rx, y = math.sin(a) * ry;
      out
        ..add(cx + x * cr - y * sr)
        ..add(cy + x * sr + y * cr);
    }
    return out;
  }

  static List<double> circle(double cx, double cy, double r, {int n = 36, bool ccw = false}) => ellipse(cx, cy, r, r, n: n, ccw: ccw);

  static List<double> rect(double x0, double y0, double x1, double y1, {bool ccw = false}) =>
      ccw ? [x0, y0, x0, y1, x1, y1, x1, y0] : [x0, y0, x1, y0, x1, y1, x0, y1];

  /// Rounded rectangle ring (corner radius [r]).
  static List<double> rrect(double x0, double y0, double x1, double y1, double r, {bool ccw = false}) {
    final out = <double>[];
    final rr = math.min(r, math.min((x1 - x0) / 2, (y1 - y0) / 2));
    final corners = [
      [x1 - rr, y0 + rr, -90.0],
      [x1 - rr, y1 - rr, 0.0],
      [x0 + rr, y1 - rr, 90.0],
      [x0 + rr, y0 + rr, 180.0],
    ];
    for (final c in corners) {
      for (int k = 0; k <= 6; k++) {
        final a = (c[2] + k * 15) * math.pi / 180;
        out
          ..add(c[0] + math.cos(a) * rr)
          ..add(c[1] + math.sin(a) * rr);
      }
    }
    return ccw ? reverse(out) : out;
  }

  /// Regular polygon (e.g. the 8-sided STOP sign), first vertex at [startDeg].
  static List<double> regular(double cx, double cy, double r, int sides, {double startDeg = -90}) => [
        for (int i = 0; i < sides; i++) ...[
          cx + math.cos((startDeg + i * 360 / sides) * math.pi / 180) * r,
          cy + math.sin((startDeg + i * 360 / sides) * math.pi / 180) * r,
        ],
      ];

  static List<double> reverse(List<double> ring) => [
        for (int i = ring.length - 2; i >= 0; i -= 2) ...[ring[i], ring[i + 1]],
      ];

  /// Arc points from [a0] to [a1] degrees (0 = right, 90 = down).
  static List<double> arc(double cx, double cy, double rx, double ry, double a0, double a1, {int n = 16}) => [
        for (int i = 0; i <= n; i++) ...[
          cx + math.cos((a0 + (a1 - a0) * i / n) * math.pi / 180) * rx,
          cy + math.sin((a0 + (a1 - a0) * i / n) * math.pi / 180) * ry,
        ],
      ];

  /// Mirrors a half outline (x ≥ 50, listed top → bottom) into a closed ring.
  static List<double> mirrored(List<double> half) {
    final out = List<double>.of(half);
    for (int i = half.length - 2; i >= 0; i -= 2) {
      out
        ..add(100 - half[i])
        ..add(half[i + 1]);
    }
    return out;
  }

  // -------------------------------------------------------------- icons

  static VectorIcon _build(String k) {
    switch (k) {
      case 'person':
        return VectorIcon('person', 'Person', [
          IconPart([circle(50, 22, 14)]),
          IconPart([
            [21, 96, ...arc(50, 64, 29, 26, 180, 360), 79, 96],
          ]),
        ]);
      case 'seat':
        return VectorIcon('seat', 'Seat', [
          IconPart([
            rrect(26, 8, 46, 64, 8),
            rrect(26, 56, 80, 72, 6),
            rect(42, 70, 50, 88),
            rrect(28, 86, 70, 94, 4),
            rrect(48, 44, 78, 52, 4),
          ]),
        ]);
      case 'scale':
        return VectorIcon('scale', 'Scales', [
          IconPart([
            rect(47, 18, 53, 86),
            [32, 84, 68, 84, 76, 95, 24, 95],
            [12, 21, 88, 21, 88, 27, 12, 27],
            circle(50, 15, 6),
            [6, 58, 42, 58, ...arc(24, 58, 18, 12, 0, 180)],
            [58, 52, 94, 52, ...arc(76, 52, 18, 12, 0, 180)],
          ]),
          IconPart([
            [24, 25, 7, 58],
            [24, 25, 41, 58],
            [76, 25, 59, 52],
            [76, 25, 93, 52],
          ], stroke: 2.4, closed: false),
        ]);
      case 'money':
        return VectorIcon('money', 'Money', [
          IconPart([rrect(4, 22, 96, 78, 6)]),
          IconPart([circle(50, 50, 15), circle(18, 50, 4), circle(82, 50, 4)], role: 'detail'),
          IconPart([rrect(11, 29, 89, 71, 3)], role: 'detail', stroke: 2.4),
        ], main: '#2E9E4F', detail: '#E6F6D8');
      case 'clock':
        return VectorIcon('clock', 'Clock', [
          IconPart([circle(50, 52, 44)]),
          IconPart([circle(50, 52, 36)], role: 'detail'),
          IconPart([
            [50, 52, 50, 26],
            [50, 52, 68, 60],
          ], stroke: 6, closed: false),
          IconPart([circle(50, 52, 5), rect(46, 2, 54, 9), rect(42, 0, 58, 4)]),
        ]);
      case 'fuel':
        return VectorIcon('fuel', 'Fuel', [
          IconPart([rrect(18, 14, 62, 92, 6), rect(12, 86, 68, 96)]),
          IconPart([rrect(26, 22, 54, 44, 3)], role: 'detail'),
          IconPart([
            [62, 34, 76, 40, 80, 74, 72, 82],
          ], stroke: 5, closed: false),
          IconPart([rrect(74, 24, 90, 34, 2), rect(80, 34, 86, 44)]),
        ], main: '#E0A21B', detail: '#2A2A2A');
      case 'stop':
        return VectorIcon('stop', 'Stop', [
          IconPart([regular(50, 50, 48, 8, startDeg: -112.5)]),
          IconPart([regular(50, 50, 41, 8, startDeg: -112.5)], role: 'detail', stroke: 3),
          const IconPart.text('STOP', 50, 52, 27),
        ], main: '#D0202A', detail: '#FFFFFF');
      case 'handshake':
        return VectorIcon('handshake', 'Handshake', [
          IconPart([
            [26, 52, 42, 38, 58, 40, 74, 50, 68, 62, 54, 72, 38, 68, 30, 60],
          ]),
          IconPart([
            [2, 60, 20, 42, 32, 56, 14, 74],
            [98, 60, 80, 42, 68, 56, 86, 74],
          ], role: 'accent'),
          IconPart([
            [44, 50, 52, 62],
            [52, 46, 60, 58],
            [37, 55, 44, 65],
          ], role: 'detail', stroke: 2.6, closed: false),
        ], main: '#F2C29A', detail: '#8A5A3A', accent: '#1E40D0');
      case 'check':
        return VectorIcon('check', 'Check', [
          IconPart([circle(50, 50, 46)]),
          IconPart([
            [27, 52, 43, 68, 74, 35],
          ], role: 'detail', stroke: 10, closed: false),
        ], main: '#2ECC40', detail: '#FFFFFF');
      case 'cross':
        return VectorIcon('cross', 'Cross', [
          IconPart([circle(50, 50, 46)]),
          IconPart([
            [32, 32, 68, 68],
            [68, 32, 32, 68],
          ], role: 'detail', stroke: 10, closed: false),
        ], main: '#D0202A', detail: '#FFFFFF');
      case 'warning':
        return VectorIcon('warning', 'Warning', [
          IconPart([
            [50, 6, 96, 90, 4, 90],
          ]),
          IconPart([
            [45, 34, 55, 34, 53, 64, 47, 64],
            circle(50, 76, 5.5),
          ], role: 'detail'),
        ], main: '#FFD21F', detail: '#111111');
      case 'music':
        return VectorIcon('music', 'Music', [
          IconPart([
            ellipse(30, 78, 13, 9.5, rot: -22),
            ellipse(74, 68, 13, 9.5, rot: -22),
            rect(37, 22, 43, 77),
            rect(81, 12, 87, 67),
            [37, 22, 87, 12, 87, 25, 37, 35],
          ]),
        ]);
      case 'heart':
        return VectorIcon('heart', 'Heart', [
          IconPart([
            [
              for (int i = 0; i < 48; i++) ...[
                50 + 2.85 * 16 * math.pow(math.sin(i * 2 * math.pi / 48), 3).toDouble(),
                46 -
                    2.85 *
                        (13 * math.cos(i * 2 * math.pi / 48) -
                            5 * math.cos(2 * i * 2 * math.pi / 48) -
                            2 * math.cos(3 * i * 2 * math.pi / 48) -
                            math.cos(4 * i * 2 * math.pi / 48)),
              ],
            ],
          ]),
        ], main: '#E53935');
      case 'radio':
        return VectorIcon('radio', 'Radio', [
          IconPart([rrect(8, 34, 92, 90, 8)]),
          IconPart([
            [26, 34, 70, 8],
          ], stroke: 3.5, closed: false),
          IconPart([circle(32, 62, 15), rrect(56, 46, 82, 56, 2), circle(62, 74, 5), circle(77, 74, 5)], role: 'detail'),
        ], main: '#4A4A4A', detail: '#D9D9D9');
      case 'plane':
        return VectorIcon('plane', 'Plane', [
          IconPart([
            mirrored([50, 2, 54, 8, 55, 38, 94, 58, 94, 66, 55, 58, 54, 80, 66, 90, 66, 96, 50, 92]),
          ]),
        ]);
      case 'helicopter':
        return VectorIcon('helicopter', 'Helicopter', [
          IconPart([
            [16, 56, ...arc(40, 56, 24, 18, 180, 360), 66, 56, 64, 70, 40, 74, 22, 70],
            [62, 50, 96, 44, 96, 50, 62, 60],
            rect(43, 24, 49, 40),
          ]),
          IconPart([
            [8, 24, 86, 24],
            [92, 36, 96, 56],
            [22, 84, 70, 84],
            [30, 72, 28, 84],
            [56, 72, 58, 84],
          ], stroke: 3.5, closed: false),
          IconPart([
            [22, 50, 30, 42, 42, 40, 42, 54, 22, 54],
          ], role: 'detail'),
        ], detail: '#7FB2FF');
      case 'globe':
      default:
        return VectorIcon('globe', 'Globe', [
          IconPart([circle(50, 50, 46)]),
          IconPart([ellipse(50, 50, 18, 45)], role: 'detail', stroke: 2.6),
          IconPart([
            [5, 50, 95, 50],
            [50, 4, 50, 96],
            [12, 28, 88, 28],
            [12, 72, 88, 72],
          ], role: 'detail', stroke: 2.6, closed: false),
        ], main: '#2E5BD6', detail: '#BFE3FF');
    }
  }
}
