import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../ai/ai_client.dart';
import '../ai/ai_settings.dart';
import '../core/model/project.dart';
import '../director/director.dart';
import 'asset_library.dart';

/// AI auto-tagging of library assets with the vision model (same thumbnails
/// and client the Director uses to understand media).
class LibraryTagger {
  static const prompt = '''
You tag reusable assets for a documentary motion-graphics library. For each attached image (in order, matching "images"), return ONLY JSON:
{"items":[{"id":"<id>","kind":"building|plant|grass_strip|sky|ground|prop|person|animal|vehicle|icon|texture|interior|map|document|logo","era":"<e.g. ancient, medieval, 1800s, 1940s, modern, or empty>","region":"<country/region style, e.g. India, Rajasthan, Europe, or empty>","mood":"<1-2 words: calm, dramatic, dark, warm…>","transparent":<true if the picture is a cut-out on a transparent/checkerboard/plain removed background>,"tags":["<3-8 short lowercase words>"],"desc":"<max 18 words: what it is, colours, angle>"}]}
grass_strip = a horizontal strip of grass/bushes used to hide the bottom of buildings. Do not guess names of private people.''';

  /// Tags [assets] (default: every untagged image/video). Returns how many were tagged.
  static Future<int> tag(AssetLibrary lib, {List<LibraryAsset>? assets, void Function(String status)? status}) async {
    final s = await AiSettings.load();
    final todo = assets ?? [for (final a in lib.assets) if (!a.tagged && a.type != MediaType.audio) a];
    var done = 0;
    for (int i = 0; i < todo.length; i += 6) {
      final batch = todo.sublist(i, math.min(todo.length, i + 6));
      status?.call('Tagging library… ${math.min(todo.length, i + 6)}/${todo.length}');
      final images = <Uint8List>[];
      final ids = <String>[];
      for (final a in batch) {
        final b = await Director.thumbnail(asMedia(lib, a));
        if (b == null) continue;
        images.add(b);
        ids.add(a.id);
      }
      if (images.isEmpty) continue;
      final raw = await AiClient.complete(s: s, system: prompt, messages: [
        AiMessage('user', jsonEncode({
          'images': [
            for (final id in ids) {'id': id, 'file': lib.byId(id)!.name, 'type': lib.byId(id)!.type.name, if (lib.byId(id)!.transparent) 'has_alpha': true},
          ],
        }), images: images),
      ]);
      done += applyAnswer(lib, raw);
    }
    if (done > 0) await lib.save();
    return done;
  }

  /// Applies the AI answer to the library entries (without saving).
  static int applyAnswer(AssetLibrary lib, String raw) {
    final a = raw.indexOf('{'), b = raw.lastIndexOf('}');
    if (a < 0 || b <= a) return 0;
    Map<String, dynamic> j;
    try {
      j = jsonDecode(raw.substring(a, b + 1)) as Map<String, dynamic>;
    } catch (_) {
      return 0;
    }
    var n = 0;
    for (final it in (j['items'] as List? ?? const [])) {
      if (it is! Map) continue;
      final asset = lib.byId('${it['id']}');
      if (asset == null) continue;
      asset.applyTags(Map<String, dynamic>.from(it));
      n++;
    }
    return n;
  }

  /// A temporary MediaAsset pointing at the library file (for thumbnails).
  static MediaAsset asMedia(AssetLibrary lib, LibraryAsset a) => MediaAsset(
        id: 'lib:${a.id}', type: a.type, path: lib.pathOf(a), name: a.name, width: a.width, height: a.height, duration: a.duration,
        description: a.about,
      );
}
