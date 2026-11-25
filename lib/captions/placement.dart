import 'dart:math' as math;

import '../core/engine/evaluator.dart';
import '../core/model/layer.dart';
import '../core/model/project.dart';
import 'styles.dart';
import 'text_rules.dart';

/// Axis-aligned rectangle in composition pixels.
class CapRect {
  final double left, top, right, bottom;
  const CapRect(this.left, this.top, this.right, this.bottom);
  factory CapRect.center(double cx, double cy, double w, double h) => CapRect(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2);

  double get width => right - left;
  double get height => bottom - top;
  double get cx => (left + right) / 2;
  double get cy => (top + bottom) / 2;
  double get area => math.max(0, width) * math.max(0, height);

  CapRect shift(double dy) => CapRect(left, top + dy, right, bottom + dy);
  CapRect inflate(double d) => CapRect(left - d, top - d, right + d, bottom + d);
  bool overlaps(CapRect o) => left < o.right && o.left < right && top < o.bottom && o.top < bottom;

  @override
  String toString() => 'CapRect(${left.round()}, ${top.round()}, ${right.round()}, ${bottom.round()})';
}

/// Frame-dependent sizes for a caption style: font size, text box width,
/// characters per line, and where the caption block sits.
class CaptionLayout {
  final double width, height;
  final bool vertical;
  final double fontSize;
  final double lineHeight;
  final double boxWidth;
  final double maxLineChars;

  /// Default block placement: [anchorY] is the block's bottom edge for
  /// bottom/lower styles and its centre for centre styles.
  final double anchorY;
  final bool anchorBottom;

  /// Vertical safe zone (shorts UI: top bar, bottom caption/description
  /// area, right-hand buttons are avoided by [boxWidth]).
  final double safeTop, safeBottom;

  /// Width of one visual character in px.
  final double charWidth;

  const CaptionLayout._({
    required this.width,
    required this.height,
    required this.vertical,
    required this.fontSize,
    required this.lineHeight,
    required this.boxWidth,
    required this.maxLineChars,
    required this.anchorY,
    required this.anchorBottom,
    required this.safeTop,
    required this.safeBottom,
    required this.charWidth,
  });

  /// Layout of [style] in a [w]×[h] frame. [devanagari]: the text is Hindi in Devanagari.
  factory CaptionLayout.of(double w, double h, CaptionStyle style, {bool devanagari = false}) {
    final vertical = h > w * 1.2;
    final short = math.min(w, h);
    final fs = (short * (vertical ? style.sizeV : style.sizeH) * (devanagari ? style.devanagariScale : 1)).roundToDouble();
    // Vertical: keep clear of the right-hand buttons (centred, 74% wide).
    final boxW = vertical ? w * 0.74 : w * 0.86;
    final charW = fs * (style.uppercase ? 0.5 : 0.55);
    final maxChars = math.max(4.0, math.min(style.maxLineChars, boxW / charW));
    final lineH = fs * (devanagari ? 1.45 : 1.3) + (style.box != null ? fs * 0.3 : 0);
    final safeTop = h * (vertical ? 0.12 : 0.06);
    final safeBottom = h * (vertical ? 0.76 : 0.94);
    double anchor;
    var bottom = true;
    switch (style.position) {
      case 'center':
        anchor = h * (vertical ? 0.58 : 0.66);
        bottom = false;
        break;
      case 'lower':
        anchor = h * (vertical ? 0.75 : 0.94);
        break;
      default:
        anchor = h * (vertical ? 0.73 : 0.9);
    }
    return CaptionLayout._(
      width: w,
      height: h,
      vertical: vertical,
      fontSize: fs,
      lineHeight: lineH,
      boxWidth: boxW,
      maxLineChars: maxChars,
      anchorY: anchor,
      anchorBottom: bottom,
      safeTop: safeTop,
      safeBottom: safeBottom,
      charWidth: charW,
    );
  }

  /// Estimated on-screen width of a line of text.
  double textWidth(String line) => math.min(boxWidth, TextRules.visualLength(line) * charWidth + fontSize * 0.4);

  /// Default rectangle of a caption block with [lines] of text.
  CaptionBlock block(List<String> lines) {
    final n = math.max(1, lines.length);
    final h = n * lineHeight;
    final w = lines.fold(0.0, (m, l) => math.max(m, textWidth(l)));
    var top = anchorBottom ? anchorY - h : anchorY - h / 2;
    top = top.clamp(safeTop, math.max(safeTop, safeBottom - h)).toDouble();
    return CaptionBlock(CapRect.center(width / 2, top + h / 2, w, h), lineHeight);
  }
}

/// Where a caption's lines go. [rect] is the text block.
class CaptionBlock {
  final CapRect rect;
  final double lineHeight;
  const CaptionBlock(this.rect, this.lineHeight);

  /// Centre y of line [i].
  double lineY(int i) => rect.top + lineHeight * (i + 0.5);
  CaptionBlock shift(double dy) => CaptionBlock(rect.shift(dy), lineHeight);
}

/// Keeps captions clear of other on-screen text (name tags, lower thirds,
/// labels) and inside the safe zone.
class CaptionSafeArea {
  /// Screen boxes of other text/shape layers visible between [t0] and [t1].
  /// Caption layers (ids starting with [captionPrefix]) and big layers
  /// (backgrounds, > 35% of the frame) are ignored.
  static List<CapRect> obstacles(Composition comp, double t0, double t1, {String captionPrefix = 'cap_'}) {
    final frame = comp.width * comp.height;
    final out = <CapRect>[];
    final seen = <String>{};
    final mid = (t0 + t1) / 2;
    for (final t in [t0 + 0.02, mid, math.max(t0 + 0.02, t1 - 0.05)]) {
      List<RenderItem> items;
      try {
        items = Evaluator.evaluate(comp, t);
      } catch (_) {
        continue;
      }
      for (final it in items) {
        final l = it.layer;
        if (l.id.startsWith(captionPrefix)) continue;
        if (l.type != LayerType.text && l.type != LayerType.shape) continue;
        if (it.opacity < 0.05) continue;
        final cs = it.corners();
        var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
        for (final c in cs) {
          minX = math.min(minX, c.x);
          maxX = math.max(maxX, c.x);
          minY = math.min(minY, c.y);
          maxY = math.max(maxY, c.y);
        }
        if (!minX.isFinite || !maxY.isFinite) continue;
        final r = CapRect(minX, minY, maxX, maxY);
        if (r.area <= 1 || r.area > frame * 0.35) continue;
        final key = '${l.id}|${r.left.round()}|${r.top.round()}';
        if (seen.add(key)) out.add(r);
      }
    }
    return out;
  }

  /// Vertical offset that moves [block] off every obstacle: first up (above
  /// the highest obstacle it hits), else down, staying between [top] and
  /// [bottom]. 0 when nothing is in the way or nothing works.
  static double offsetFor(CapRect block, List<CapRect> obstacles, {required double top, required double bottom, double margin = 12}) {
    if (obstacles.isEmpty) return 0;
    bool clear(CapRect r) => !obstacles.any((o) => o.overlaps(r.inflate(margin)));
    if (clear(block)) return 0;
    // Up.
    var r = block;
    for (int i = 0; i < 8; i++) {
      final hits = obstacles.where((o) => o.overlaps(r.inflate(margin))).toList();
      if (hits.isEmpty) break;
      final ceiling = hits.map((o) => o.top).reduce(math.min);
      r = r.shift(ceiling - margin - r.bottom - 0.5);
      if (r.top < top) break;
    }
    if (r.top >= top && clear(r)) return r.top - block.top;
    // Down.
    r = block;
    for (int i = 0; i < 8; i++) {
      final hits = obstacles.where((o) => o.overlaps(r.inflate(margin))).toList();
      if (hits.isEmpty) break;
      final floor = hits.map((o) => o.bottom).reduce(math.max);
      r = r.shift(floor + margin - r.top + 0.5);
      if (r.bottom > bottom) break;
    }
    if (r.bottom <= bottom && clear(r)) return r.top - block.top;
    return 0;
  }
}
