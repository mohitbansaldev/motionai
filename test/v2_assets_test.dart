import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:motionai/core/engine/fx_math.dart';
import 'package:motionai/core/engine/text_clusters.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/director/sfx.dart';
import 'package:motionai/library/asset_library.dart';
import 'package:motionai/library/asset_search.dart';
import 'package:motionai/library/image_clean.dart';
import 'package:motionai/library/library_ops.dart';
import 'package:motionai/platform/windows_ai/image_io.dart';

/// Synthetic RGBA image from a colour function.
Rgba paint(int w, int h, List<int> Function(int x, int y) f) {
  final d = Uint8List(w * h * 4);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final c = f(x, y);
      final o = (y * w + x) * 4;
      d[o] = c[0];
      d[o + 1] = c[1];
      d[o + 2] = c[2];
      d[o + 3] = c.length > 3 ? c[3] : 255;
    }
  }
  return Rgba(w, h, d);
}

int noise(int x, int y, int amp) => ((hash01(x * 31 + 7, y * 17 + 3) * 2 - 1) * amp).round();

/// Subject (red ellipse + white box) on a flat green screen.
Rgba greenShot(int w, int h, {List<int> screen = const [20, 200, 70]}) => paint(w, h, (x, y) {
      final dx = (x - w / 2) / (w * 0.22), dy = (y - h / 2) / (h * 0.3);
      if (dx * dx + dy * dy <= 1) return [200, 60, 50];
      if (x > w * 0.1 && x < w * 0.2 && y > h * 0.4 && y < h * 0.6) return [240, 240, 240];
      final n = noise(x, y, 3);
      return [(screen[0] + n).clamp(0, 255), (screen[1] + n).clamp(0, 255), (screen[2] + n).clamp(0, 255)];
    });

/// 4-point sparkle (superellipse p = 0.6) of radius [r] at (cx, cy).
bool inStar(int x, int y, double cx, double cy, double r) {
  final ax = (x - cx).abs() / r, ay = (y - cy).abs() / r;
  return math.pow(ax, 0.6) + math.pow(ay, 0.6) <= 1;
}

Rgba greyPhoto(int w, int h, {bool star = false, bool square = false}) => paint(w, h, (x, y) {
      final cx = w - 15.0, cy = h - 15.0;
      if (star && inStar(x, y, cx, cy, 6.5)) return [255, 255, 255];
      if (square && (x - cx).abs() <= 6 && (y - cy).abs() <= 6) return [255, 255, 255];
      final v = 90 + noise(x, y, 10);
      return [v, v + 5, v - 5];
    });

void writeImg(String path, Rgba im) {
  File(path).parent.createSync(recursive: true);
  final i = ImageIo.fromRgba(im);
  File(path).writeAsBytesSync(path.endsWith('.png') ? img.encodePng(i) : img.encodeJpg(i, quality: 95));
}

LibraryAsset la(String id, String name, {String kind = '', List<String> tags = const [], bool alpha = false, String desc = ''}) =>
    LibraryAsset(id: id, type: MediaType.image, file: '$id.png', name: name, kind: kind, tags: [...tags], transparent: alpha, description: desc, width: 100, height: 100);

void main() {
  group('V2-F Devanagari letters', () {
    test('clusters keep conjuncts, matras, nukta and signs whole', () {
      expect(TextClusters.split('राजस्थान'), ['रा', 'ज', 'स्था', 'न']);
      expect(TextClusters.split('क्षत्रिय'), ['क्ष', 'त्रि', 'य']);
      expect(TextClusters.split('फ़रवरी'), ['फ़', 'र', 'व', 'री']); // फ़ = फ + nukta
      expect(TextClusters.split('फ़रवरी'), ['फ़', 'र', 'व', 'री']); // precomposed फ़
      expect(TextClusters.split('श्री'), ['श्री']);
      expect(TextClusters.split('हॉलैंड'), ['हॉ', 'लैं', 'ड']);
      expect(TextClusters.split('हॉलैंड · 1637'), ['हॉ', 'लैं', 'ड', ' ', '·', ' ', '1', '6', '3', '7']);
      expect(TextClusters.split('राजस्थान · 1568').join(), 'राजस्थान · 1568');
    });

    test('no cluster starts with a combining mark or virama', () {
      for (final t in ['राजस्थान', 'क्षत्रिय', 'फ़रवरी', 'श्री', 'हॉलैंड', 'हॉलैंड · 1637', 'मुग़ल साम्राज्य', 'ज़िंदगी']) {
        for (final c in TextClusters.split(t)) {
          final first = c.runes.first;
          final isMark = (first >= 0x093A && first <= 0x094F && first != 0x093D) || (first >= 0x0900 && first <= 0x0903) || first == 0x093C;
          expect(isMark, isFalse, reason: '"$c" in "$t"');
        }
        expect(TextClusters.split(t).join(), t);
      }
    });

    test('latin, emoji and flags', () {
      expect(TextClusters.split('TOP 1996'), ['T', 'O', 'P', ' ', '1', '9', '9', '6']);
      expect(TextClusters.split('éx'), ['é', 'x']);
      expect(TextClusters.count('👍🏽!'), 2);
      expect(TextClusters.count('🇮🇳🇳🇱'), 2);
      expect(TextClusters.count('👨‍👩‍👧'), 1);
      expect(TextClusters.split('a\r\nb'), ['a', '\r\n', 'b']);
    });

    test('typewriter prefix ends on whole letters', () {
      const t = 'राजस्थान';
      expect(t.substring(0, TextClusters.prefixEnd(t, 3)), 'राजस्था');
      expect(TextClusters.prefixEnd(t, 0), 0);
      expect(TextClusters.prefixEnd(t, 99), t.length);
    });

    test('scramble resolves to exactly the original text and stays in script', () {
      for (final t in ['राजस्थान', 'क्षत्रिय', 'फ़रवरी', 'श्री', 'हॉलैंड', 'हॉलैंड · 1637', 'राजस्थान · 1568']) {
        expect(TextFx.scrambleText(t, 1.2, 1.2, seed: 9), t);
        expect(TextFx.scrambleText(t, 5, 1.2, seed: 9), t);
        final n = TextClusters.count(t);
        final start = TextClusters.split(TextFx.scrambleText(t, 0.01, 1.2, seed: 9));
        expect(start.length, n, reason: t);
        final orig = TextClusters.split(t);
        for (int i = 0; i < n; i++) {
          final cls = TextClusters.classOf(orig[i]);
          if (cls == ClusterClass.space) expect(start[i], orig[i]);
          if (cls == ClusterClass.devanagari) expect(TextClusters.classOf(start[i]), ClusterClass.devanagari, reason: '${start[i]} for ${orig[i]}');
          if (cls == ClusterClass.digit) expect(TextClusters.classOf(start[i]), ClusterClass.digit);
        }
      }
      expect(TextFx.scrambleCluster('स्था', 0, 4, 0.01, 1, 3), isNot('स्था'));
      expect(TextFx.scrambleCluster('स्था', 0, 4, 1, 1, 3), 'स्था');
      expect(TextFx.scrambleCluster('१', 0, 1, 0.01, 1, 3).runes.first, inInclusiveRange(0x0966, 0x096F));
      expect(TextFx.lettersSettled(1.2, 1.2), isTrue);
      expect(TextFx.lettersSettled(1.1, 1.2), isFalse);
      expect(TextFx.lettersSettled(0, 0), isTrue);
    });

    test('random pop over clusters finishes by the duration', () {
      final n = TextClusters.count('हॉलैंड · 1637');
      for (int i = 0; i < n; i++) {
        expect(TextFx.randomPopProgress(i, n, 0.8, 0.8, 4), 1.0);
      }
    });

    test('typewriter clicks once per whole letter', () {
      expect(Sfx.typingTimes('राजस्थान', 1).length, 4);
      expect(Sfx.typingTimes('श्री राम', 1).length, 3);
    });
  });

  group('V2-F green screen', () {
    test('detects a flat green screen and keys it to alpha', () {
      final im = greenShot(160, 120);
      final s = ImageClean.detectScreen(im);
      expect(s, isNotNull);
      expect(s!.name, 'green');
      expect(s.coverage, greaterThan(0.9));
      final k = ImageClean.keyScreen(im, s);
      int a(int x, int y) => k.data[(y * 160 + x) * 4 + 3];
      expect(a(2, 2), 0);
      expect(a(157, 117), 0);
      expect(a(80, 60), 255); // red subject kept
      expect(k.data[(60 * 160 + 80) * 4], closeTo(200, 6));
      expect(a(24, 60), 255); // white box kept
      expect(ImageClean.hasRealAlpha(k), isTrue);
    });

    test('blue screens too; photos, foliage and cut-outs are left alone', () {
      expect(ImageClean.detectScreen(greenShot(120, 90, screen: const [10, 60, 200]))?.name, 'blue');
      // Textured grass under a sky: not a screen.
      final grass = paint(160, 120, (x, y) {
        if (y < 40) return [120, 170, 230];
        final k = 0.4 + hash01(x, y) * 1.0;
        return [(60 * k).round(), (150 * k).round().clamp(0, 255), (40 * k).round()];
      });
      expect(ImageClean.detectScreen(grass), isNull);
      // Clear sky plate: pale blue is not a chroma screen.
      expect(ImageClean.detectScreen(paint(120, 90, (x, y) => [110 + y ~/ 4, 160 + y ~/ 4, 230])), isNull);
      expect(ImageClean.detectScreen(greyPhoto(120, 90)), isNull);
      final cut = paint(100, 100, (x, y) => (x - 50).abs() < 20 && (y - 50).abs() < 30 ? [200, 0, 0, 255] : [0, 255, 0, 0]);
      expect(ImageClean.detectScreen(cut), isNull);
      // A green screen with the subject touching the bottom edge still counts.
      final standing = paint(160, 120, (x, y) => (x - 80).abs() < 25 && y > 40 ? [180, 120, 90] : [0, 190, 60]);
      expect(ImageClean.detectScreen(standing), isNotNull);
    });
  });

  group('V2-F watermark sparkle', () {
    test('finds the bottom-right sparkle and inpaints only that corner', () {
      final im = greyPhoto(400, 300, star: true);
      final m = ImageClean.detectMark(im);
      expect(m, isNotNull);
      expect(m!.x0, greaterThan(370));
      expect(m.y0, greaterThan(270));
      expect(m.size, inInclusiveRange(8, 16));
      final out = ImageClean.removeMark(im, m);
      final c = ((300 - 15) * 400 + (400 - 15)) * 4;
      expect(out.data[c], lessThan(130));
      // Far away pixels untouched.
      for (final (x, y) in [(10, 10), (200, 150), (300, 250)]) {
        final o = (y * 400 + x) * 4;
        expect(out.data[o], im.data[o]);
      }
      expect(ImageClean.detectMark(out), isNull);
    });

    test('conservative: no star, a solid square or a bright area is not a mark', () {
      expect(ImageClean.detectMark(greyPhoto(400, 300)), isNull);
      expect(ImageClean.detectMark(greyPhoto(400, 300, square: true)), isNull);
      final bright = paint(400, 300, (x, y) => x > 300 && y > 200 ? [250, 250, 250] : [90, 90, 90]);
      expect(ImageClean.detectMark(bright), isNull);
      // A star in the middle of the picture is content, not the mark.
      final mid = paint(400, 300, (x, y) => inStar(x, y, 200, 150, 6.5) ? [255, 255, 255] : [90, 90, 90]);
      expect(ImageClean.detectMark(mid), isNull);
    });
  });

  group('V2-F roles, tags and smart search', () {
    test('prefix and folder tagging', () {
      expect(AssetRoles.guess('char_dutch_merchant.png')!.role, 'character');
      expect(AssetRoles.guess('cutouts/prop_tulip.png')!.kind, 'prop');
      expect(AssetRoles.guess('plate_amsterdam_canal.jpg')!.tags, contains('background'));
      expect(AssetRoles.guess('fx_smoke.mp4')!.role, 'overlay');
      expect(AssetRoles.guess('cut_windmill.png')!.tags, containsAll(['cut-out', 'set piece']));
      expect(AssetRoles.guess('plates/amsterdam.jpg')!.role, 'plate');
      expect(AssetRoles.guess('fx/sparks.png')!.role, 'overlay');
      expect(AssetRoles.guess('cutouts/thing.png'), isNull);
      expect(AssetRoles.nameTags('char_dutch_merchant_02_green.jpg'), ['dutch', 'merchant']);
      expect(AssetRoles.variantKey('char_x_green.jpg'), AssetRoles.variantKey('cutouts/char_x.png'));
      expect(AssetRoles.normalize('Background'), 'plate');
      expect(AssetRoles.roleOf(la('a', 'x', kind: 'building')), 'set_piece');
    });

    test('folder plan prefers the PNG cut-out over the same-named JPEG', () {
      final p = LibraryOps.plan('/r', ['char_x.jpg', 'cutouts/char_x.png', 'plate_y.jpg', 'notes.txt', '.hidden.png', 'fx/fx_smoke.mp4', 'music.mp3']);
      final names = {for (final f in p) f.rel: f.skip};
      expect(names.containsKey('notes.txt'), isFalse);
      expect(names.containsKey('.hidden.png'), isFalse);
      expect(names['char_x.jpg'], startsWith('png_preferred'));
      expect(names['cutouts/char_x.png'], '');
      expect(names['plate_y.jpg'], '');
      expect(p.firstWhere((f) => f.rel == 'fx/fx_smoke.mp4').type, MediaType.video);
      expect(p.firstWhere((f) => f.rel == 'music.mp3').type, MediaType.audio);
      expect(LibraryOps.kitName(r'C:\Users\me\flow-mcp-out\Tulip_Library'), 'Tulip Library');
    });

    test('fuzzy, role-aware search and shot suggestions', () {
      final all = [
        la('m', 'char_dutch_merchant', kind: 'person', tags: ['character', 'person', 'dutch', 'merchant'], alpha: true),
        la('k', 'char_king', kind: 'person', tags: ['character', 'king'], alpha: true),
        la('t', 'prop_tulip_bulb', kind: 'prop', tags: ['object', 'tulip', 'bulb'], alpha: true),
        la('c', 'plate_market_square', kind: 'plate', tags: ['background', 'market'], desc: '1630s Amsterdam market'),
        la('s', 'fx_smoke', kind: 'overlay', tags: ['overlay', 'smoke']),
      ];
      expect(smartSearch(all, 'merchnt').first.asset.id, 'm');
      expect(smartSearch(all, 'tulips').first.asset.id, 't');
      expect(smartSearch(all, '', roles: ['background']).map((h) => h.asset.id), ['c']);
      expect(smartSearch(all, 'dutch king').map((h) => h.asset.id).take(2).toSet(), {'m', 'k'});
      expect(smartSearch(all, 'zebra'), isEmpty);
      final s = suggestAssets(all, 'A Dutch merchant holds a tulip bulb in the Amsterdam market, smoke drifting', roles: ['character', 'object', 'plate', 'overlay']);
      expect(s['character']!.first.asset.id, 'm');
      expect(s['object']!.first.asset.id, 't');
      expect(s['plate']!.first.asset.id, 'c');
      expect(s['overlay']!.first.asset.id, 's');
      // No keyword match: newest of the role, score 0.
      final f = suggestAssets(all, 'volcano', roles: ['plate']);
      expect(f['plate']!.single.score, 0);
    });
  });

  group('V2-F folder import + clean', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('v2f'));
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('imports a Flow kit folder: roles, kit, dedupe, PNG preferred, green screen keyed', () async {
      final root = '${tmp.path}/Tulip_Library';
      final cut = paint(80, 120, (x, y) => (x - 40).abs() < 20 && (y - 60).abs() < 50 ? [150, 90, 60, 255] : [0, 0, 0, 0]);
      writeImg('$root/cutouts/char_merchant.png', cut);
      writeImg('$root/char_merchant.jpg', greenShot(80, 120));
      writeImg('$root/dup/char_merchant_copy.png', cut);
      writeImg('$root/prop_tulip_green.jpg', greenShot(120, 120));
      writeImg('$root/plates/plate_market.jpg', greyPhoto(200, 120));
      writeImg('$root/cut_windmill.png', paint(60, 60, (x, y) => (x - 30).abs() < 10 ? [120, 120, 130, 255] : [0, 0, 0, 0]));
      File('$root/notes.txt').writeAsStringSync('hi');
      final lib = await AssetLibrary.open(Directory('${tmp.path}/lib'));
      final r = await LibraryOps.importFolder(lib, {'path': root, 'tags': ['holland']});
      expect(r['kit']['name'], 'Tulip Library');
      expect(r['imported'], 4);
      expect(r['duplicates'], 1);
      expect(r['green_screen_keyed'], 1);
      expect((r['skipped'] as List).map((e) => e['file']), contains('char_merchant.jpg'));
      final byName = {for (final a in lib.assets) a.name: a};
      final m = byName['char_merchant']!;
      expect(m.kind, 'person');
      expect(m.transparent, isTrue);
      expect(m.tags, containsAll(['character', 'merchant', 'tulip', 'holland', 'cut-out']));
      final t = byName['prop_tulip_green']!;
      expect(t.transparent, isTrue);
      expect(t.cleaned, ['green_screen']);
      expect(t.file, endsWith('.png'));
      expect(File('${lib.filesDir.path}/${t.original}').existsSync(), isTrue);
      final plate = byName['plate_market']!;
      expect(AssetRoles.roleOf(plate), 'plate');
      expect(plate.transparent, isFalse);
      expect(plate.width, 200);
      expect(AssetRoles.roleOf(byName['cut_windmill']!), 'set_piece');
      expect(lib.kits.single.assetIds.length, 4);
      // Re-import: everything is a duplicate, the kit is reused.
      final again = await LibraryOps.importFolder(lib, {'path': root});
      expect(again['imported'], 0);
      expect(lib.kits.length, 1);
      // Reopened from disk.
      final re = await AssetLibrary.open(Directory('${tmp.path}/lib'));
      expect(re.assets.firstWhere((a) => a.name == 'prop_tulip_green').cleaned, ['green_screen']);
      // Search / suggest JSON.
      expect(LibraryOps.search(lib, {'role': 'character', 'query': 'merchnt'})['assets'][0]['name'], 'char_merchant');
      final sug = LibraryOps.suggest(lib, {'brief': 'merchant with a tulip in the market', 'kit': 'Tulip Library'});
      expect(sug['roles']['character'][0]['name'], 'char_merchant');
      expect(sug['roles']['object'][0]['name'], 'prop_tulip_green');
      expect(sug['roles']['plate'][0]['name'], 'plate_market');
    });

    test('clean_assets keys + removes the mark in batch and can restore', () async {
      final lib = await AssetLibrary.open(Directory('${tmp.path}/lib'));
      writeImg('${tmp.path}/a.png', greenShot(120, 90));
      final marked = paint(400, 300, (x, y) => inStar(x, y, 385, 285, 6.5) ? [255, 255, 255] : [90 + noise(x, y, 10), 95, 85]);
      writeImg('${tmp.path}/b.png', marked);
      final a = await lib.addFile('${tmp.path}/a.png', type: MediaType.image, width: 120, height: 90);
      final b = await lib.addFile('${tmp.path}/b.png', type: MediaType.image, width: 400, height: 300);
      final r = await LibraryOps.clean(lib, {'ids': ['lib:${a.id}', b.id]});
      expect(r['changed'], 2);
      expect(a.cleaned, ['green_screen']);
      expect(a.transparent, isTrue);
      expect(b.cleaned, ['mark']);
      expect(b.transparent, isFalse);
      expect(File(lib.pathOf(b)).existsSync(), isTrue);
      final back = await LibraryOps.clean(lib, {'ids': [a.id], 'restore': true});
      expect(back['changed'], 1);
      expect(a.cleaned, isEmpty);
      expect(a.original, '');
      expect(File(lib.pathOf(a)).existsSync(), isTrue);
      await expectLater(LibraryOps.clean(lib, {}), throwsArgumentError);
    });
  });
}
