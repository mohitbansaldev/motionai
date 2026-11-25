import 'dart:convert';
import 'dart:typed_data';

import 'ai_client.dart';
import 'ai_settings.dart';

/// Finds where a phrase is in a screenshot (article, tweet, document) with
/// the vision model, as normalised boxes [x0, y0, x1, y1] (0..1, top-left
/// origin) — one box per line the phrase covers. The `article` component
/// takes these boxes for highlights, circles, underlines and redactions.
class PhraseFinder {
  static const system = '''
You locate text in an image for a video editor. The user gives a PHRASE and ONE image (a screenshot of an article, post or document).
Find the phrase (case-insensitive, ignore punctuation and line breaks; if it is not there exactly, the closest matching words).
Return ONLY JSON: {"found": true|false, "boxes": [[x0, y0, x1, y1], ...]}
- Coordinates are fractions of the image width/height (0..1), origin top-left; x0<x1, y0<y1.
- Boxes are tight around the words. If the phrase wraps onto several lines, give one box per line, in reading order.
- If the phrase appears more than once, return only the most prominent occurrence (headline or first in the body).
- If it is not in the image: {"found": false, "boxes": []}''';

  /// Asks the vision model. [width]/[height] are the image's pixel size, used
  /// when the model answers in pixels instead of fractions.
  static Future<List<List<double>>> find({
    required AiSettings settings,
    required Uint8List image,
    required String phrase,
    double? width,
    double? height,
  }) async {
    final raw = await AiClient.complete(
      s: settings,
      system: system,
      messages: [
        AiMessage('user', jsonEncode({'phrase': phrase, if (width != null && height != null) 'image_size_px': [width.round(), height.round()]}), images: [image]),
      ],
    );
    return parseBoxes(raw, width: width, height: height);
  }

  /// Parses the model's answer into clean normalised boxes. Accepts
  /// [x0,y0,x1,y1] lists, {x0,y0,x1,y1} / {x,y,w,h} / {left,top,right,bottom}
  /// maps, pixel values (with [width]/[height]) and 0..100 percentages.
  static List<List<double>> parseBoxes(String raw, {double? width, double? height}) {
    final a = raw.indexOf('{'), b = raw.lastIndexOf('}');
    dynamic j;
    try {
      j = a >= 0 && b > a ? jsonDecode(raw.substring(a, b + 1)) : jsonDecode(raw.trim());
    } catch (_) {
      final la = raw.indexOf('['), lb = raw.lastIndexOf(']');
      if (la < 0 || lb <= la) return const [];
      try {
        j = {'boxes': jsonDecode(raw.substring(la, lb + 1))};
      } catch (_) {
        return const [];
      }
    }
    final list = j is Map ? (j['boxes'] ?? (j['box'] == null ? null : [j['box']])) : j;
    if (list is! List) return const [];
    final out = <List<double>>[];
    for (final item in list) {
      List<double>? v;
      if (item is List && item.length >= 4 && item.take(4).every((e) => e is num)) {
        v = [for (final e in item.take(4)) (e as num).toDouble()];
      } else if (item is Map) {
        double? g(String k) => (item[k] as num?)?.toDouble();
        if (g('x0') != null && g('y0') != null && g('x1') != null && g('y1') != null) {
          v = [g('x0')!, g('y0')!, g('x1')!, g('y1')!];
        } else if (g('left') != null && g('top') != null && g('right') != null && g('bottom') != null) {
          v = [g('left')!, g('top')!, g('right')!, g('bottom')!];
        } else if (g('x') != null && g('y') != null && (g('w') ?? g('width')) != null && (g('h') ?? g('height')) != null) {
          final x = g('x')!, y = g('y')!, w = (g('w') ?? g('width'))!, h = (g('h') ?? g('height'))!;
          v = [x, y, x + w, y + h];
        }
      }
      if (v == null) continue;
      final big = v.any((e) => e > 1.5);
      if (big) {
        if (width != null && height != null && width > 0 && height > 0 && v.any((e) => e > 100.5)) {
          v = [v[0] / width, v[1] / height, v[2] / width, v[3] / height];
        } else if (v.every((e) => e <= 100.5)) {
          v = [for (final e in v) e / 100];
        } else if (width != null && height != null && width > 0 && height > 0) {
          v = [v[0] / width, v[1] / height, v[2] / width, v[3] / height];
        } else {
          continue;
        }
      }
      double c(double e) => e.clamp(0.0, 1.0).toDouble();
      final box = [c(v[0] < v[2] ? v[0] : v[2]), c(v[1] < v[3] ? v[1] : v[3]), c(v[0] < v[2] ? v[2] : v[0]), c(v[1] < v[3] ? v[3] : v[1])];
      if (box[2] - box[0] < 1e-4 || box[3] - box[1] < 1e-4) continue;
      out.add(box);
    }
    return out;
  }

  /// Fills in "boxes" for every mark that has a "phrase" but no box, using
  /// [image] (the screenshot). Marks whose phrase can't be found are dropped.
  static Future<List<Map<String, dynamic>>> resolveMarks({
    required AiSettings settings,
    required Uint8List image,
    required List<Map<String, dynamic>> marks,
    double? width,
    double? height,
  }) async {
    final out = <Map<String, dynamic>>[];
    for (final m in marks) {
      if (m['box'] != null || m['boxes'] != null || m['phrase'] is! String) {
        out.add(m);
        continue;
      }
      try {
        final boxes = await find(settings: settings, image: image, phrase: '${m['phrase']}', width: width, height: height);
        if (boxes.isNotEmpty) out.add({...m, 'boxes': boxes});
      } on AiException {
        rethrow;
      } catch (_) {
        // Not found / unreadable answer: skip this mark.
      }
    }
    return out;
  }
}
