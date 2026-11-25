import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/ai/command_spec.dart';
import 'package:motionai/core/commands/edit_commands.dart';
import 'package:motionai/core/model/layer.dart';
import 'package:motionai/core/model/project.dart';
import 'package:motionai/fonts/font_catalog.dart';
import 'package:motionai/fonts/font_commands.dart';
import 'package:motionai/fonts/text_styles.dart';
import 'package:motionai/ui/fonts/font_picker.dart';

Project newProject() => Project(
      id: 'p1',
      name: 'Fonts',
      main: Composition(id: 'main', name: 'Main', width: 1920, height: 1080, fps: 30, duration: 10),
    );

void run(Project p, Map<String, dynamic> c) => EditCommands.runAtomic(p, c);

TextData textOf(Project p, String id) => p.main.layerById(id)!.text!;

/// family → asset paths from the `fonts:` section of pubspec.yaml.
Map<String, List<String>> pubspecFonts() {
  final lines = File('pubspec.yaml').readAsLinesSync();
  final out = <String, List<String>>{};
  var inFonts = false;
  String? family;
  for (final raw in lines) {
    if (RegExp(r'^  fonts:\s*$').hasMatch(raw)) {
      inFonts = true;
      continue;
    }
    if (!inFonts) continue;
    if (raw.trim().isEmpty || raw.trimLeft().startsWith('#')) continue;
    if (!raw.startsWith('    ')) break; // left the fonts: block
    final fam = RegExp(r'^    - family:\s*(.+?)\s*$').firstMatch(raw);
    if (fam != null) {
      family = fam.group(1)!.replaceAll(RegExp('^["\']|["\']\$'), '');
      out[family] = [];
      continue;
    }
    final asset = RegExp(r'-\s*asset:\s*(\S+)').firstMatch(raw);
    if (asset != null && family != null) out[family]!.add(asset.group(1)!);
  }
  return out;
}

List<String> pubspecAssets() => [
      for (final l in File('pubspec.yaml').readAsLinesSync())
        if (RegExp(r'^    - assets/').hasMatch(l)) l.trim().substring(2).trim(),
    ];

void main() {
  group('catalog consistency', () {
    test('pubspec fonts and catalog list the same families and files', () {
      final pub = pubspecFonts();
      expect(pub, isNotEmpty);
      expect(pub.keys.toSet(), FontCatalog.families.toSet());
      for (final f in FontCatalog.all) {
        expect(pub[f.family]!.toSet(), f.assetPaths.toSet(), reason: f.family);
      }
      expect(FontCatalog.families.toSet().length, FontCatalog.all.length, reason: 'duplicate family');
    });

    test('every font file exists, is a TrueType/OpenType font and has its licence', () {
      final assets = pubspecAssets();
      var total = 0;
      for (final f in FontCatalog.all) {
        for (final path in f.assetPaths) {
          final file = File(path);
          expect(file.existsSync(), isTrue, reason: path);
          final b = file.readAsBytesSync();
          total += b.length;
          final magic = b.sublist(0, 4);
          final ok = (magic[0] == 0 && magic[1] == 1 && magic[2] == 0 && magic[3] == 0) ||
              String.fromCharCodes(magic) == 'OTTO' ||
              String.fromCharCodes(magic) == 'true';
          expect(ok, isTrue, reason: '$path is not a font');
        }
        final lic = File(f.licensePath);
        expect(lic.existsSync(), isTrue, reason: f.licensePath);
        final txt = lic.readAsStringSync();
        expect(txt.contains(f.license == 'Apache-2.0' ? 'Apache License' : 'SIL OPEN FONT LICENSE'), isTrue,
            reason: f.licensePath);
        expect(assets, contains(f.licensePath), reason: 'licence not bundled');
      }
      expect(total, lessThan(25 * 1024 * 1024));
    });

    test('no stray font files outside the catalog', () {
      final known = {for (final f in FontCatalog.all) ...f.assetPaths};
      final onDisk = Directory('assets/fonts')
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.replaceAll('\\', '/'))
          .where((p) => p.endsWith('.ttf') || p.endsWith('.otf'))
          .toSet();
      expect(onDisk, known);
    });

    test('weights and Devanagari matches are valid', () {
      for (final f in FontCatalog.all) {
        expect(f.minWeight <= f.maxWeight, isTrue, reason: f.family);
        if (f.hasDevanagari) {
          expect(f.devanagariMatch, isNull, reason: f.family);
        } else {
          final m = FontCatalog.lookup(FontCatalog.devanagariFor(f.family));
          expect(m, isNotNull, reason: f.family);
          expect(m!.hasDevanagari, isTrue, reason: '${f.family} → ${m.family}');
        }
      }
      for (final c in FontCategory.values) {
        expect(FontCatalog.byCategory(c), isNotEmpty, reason: c.name);
      }
    });
  });

  group('lookup and Devanagari fallback', () {
    test('lookup is case/space-insensitive and knows aliases', () {
      expect(FontCatalog.lookup('anton')!.family, 'Anton');
      expect(FontCatalog.lookup('bebas_neue')!.family, 'Bebas Neue');
      expect(FontCatalog.lookup('Playfair-Display')!.family, 'Playfair Display');
      expect(FontCatalog.lookup('serif')!.family, 'Playfair Display');
      expect(FontCatalog.lookup('monospace')!.family, 'Roboto Mono');
      expect(FontCatalog.lookup('baloo2')!.family, 'Baloo 2');
      expect(FontCatalog.lookup('Comic Sans'), isNull);
      expect(FontCatalog.lookup(null), isNull);
    });

    test('detects Devanagari', () {
      expect(FontCatalog.hasDevanagari('भारत'), isTrue);
      expect(FontCatalog.hasDevanagari('Bharat का safar'), isTrue);
      expect(FontCatalog.hasDevanagari('India 1947'), isFalse);
    });

    test('Latin-only fonts switch to a matching Devanagari family', () {
      expect(FontCatalog.resolve('Anton', 'भारत 1947'), 'Teko');
      expect(FontCatalog.resolve('Bebas Neue', 'नमस्ते'), 'Teko');
      expect(FontCatalog.resolve('Playfair Display', '१८३१ ई.'), 'Rozha One');
      expect(FontCatalog.resolve('serif', 'इतिहास'), 'Rozha One');
      expect(FontCatalog.resolve('Great Vibes', 'मोहित'), 'Kalam');
      expect(FontCatalog.resolve('Inter', 'सच'), 'Mukta');
      expect(FontCatalog.resolve('Special Elite', 'गुप्त'), 'Noto Sans Devanagari');
    });

    test('Devanagari fonts and Latin text keep the chosen family', () {
      expect(FontCatalog.resolve('Teko', 'भारत'), 'Teko');
      expect(FontCatalog.resolve('Poppins', 'सच kya hai'), 'Poppins');
      expect(FontCatalog.resolve('Anton', 'INDIA'), 'Anton');
      expect(FontCatalog.resolve('serif', '1831'), 'Playfair Display');
    });

    test('no family: Latin keeps the system font, Hindi gets the default Hindi font', () {
      expect(FontCatalog.resolve(null, 'Hello'), isNull);
      expect(FontCatalog.resolve(null, 'नमस्ते'), FontCatalog.defaultDevanagari);
      expect(FontCatalog.resolve('', 'नमस्ते'), FontCatalog.defaultDevanagari);
      // Unknown (system) names pass through untouched.
      expect(FontCatalog.resolve('Roboto', 'Hello'), 'Roboto');
    });

    test('fallback list ends with Noto Sans Devanagari', () {
      expect(FontCatalog.fallbackFor('Anton'), ['Teko', 'Noto Sans Devanagari']);
      expect(FontCatalog.fallbackFor(null).last, 'Noto Sans Devanagari');
      expect(FontCatalog.fallbackFor('Roboto Mono'), ['Noto Sans Devanagari']);
    });

    test('search finds by name, category and Hindi', () {
      expect(FontCatalog.search('vibes').map((f) => f.family), ['Great Vibes']);
      expect(FontCatalog.search('serif').map((f) => f.family), containsAll(['Playfair Display', 'DM Serif Display']));
      expect(FontCatalog.search('hindi').every((f) => f.hasDevanagari), isTrue);
      expect(FontCatalog.search('').length, FontCatalog.all.length);
    });
  });

  group('commands', () {
    test('font is validated and stored canonically, weight snaps to the font', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'TITLE', 'font': 'anton'});
      expect(textOf(p, 't').fontFamily, 'Anton');
      expect(textOf(p, 't').fontWeight, 400);
      run(p, {'op': 'update_layer', 'layer': 't', 'font': 'Barlow Condensed', 'font_weight': 900});
      expect(textOf(p, 't').fontFamily, 'Barlow Condensed');
      expect(textOf(p, 't').fontWeight, 900);
      run(p, {'op': 'update_layer', 'layer': 't', 'font': 'serif'});
      expect(textOf(p, 't').fontFamily, 'Playfair Display');
    });

    test('unknown font is rejected with suggestions and nothing changes', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'X', 'font': 'Anton'});
      expect(
        () => run(p, {'op': 'update_layer', 'layer': 't', 'font': 'Comic Sans'}),
        throwsA(isA<CommandError>().having((e) => e.message, 'message', contains('Available'))),
      );
      expect(textOf(p, 't').fontFamily, 'Anton');
    });

    test('font_family stays lenient (system fonts, generic names)', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': 'X', 'font_family': 'monospace'});
      expect(textOf(p, 't').fontFamily, 'monospace');
    });

    test('text_style presets apply a full look, explicit keys win', () {
      final p = newProject();
      run(p, {'op': 'add_layer', 'type': 'text', 'id': 'd', 'text': '1831', 'text_style': 'date_serif'});
      expect(textOf(p, 'd').fontFamily, 'Playfair Display');
      expect(textOf(p, 'd').fontWeight, 900);

      run(p, {'op': 'add_layer', 'type': 'text', 'id': 'v', 'text': 'VIRAL', 'text_style': 'doc_title', 'text_color': '#FF0000'});
      final v = textOf(p, 'v');
      expect(v.fontFamily, 'Anton');
      expect(v.extrude, greaterThan(0));
      expect(v.color, 0xFFFF0000);

      run(p, {'op': 'add_layer', 'type': 'text', 'id': 'n', 'text': 'NEON', 'text_style': 'neon_outline'});
      final n = p.main.layerById('n')!;
      expect(n.text!.outline, greaterThan(0));
      expect(n.effects.where((e) => e.type == 'glow').length, 1);
      // Re-applying does not stack a second glow.
      run(p, {'op': 'update_layer', 'layer': 'n', 'text_style': 'neon_outline'});
      expect(n.effects.where((e) => e.type == 'glow').length, 1);

      // Switching preset clears the previous edge/outline.
      run(p, {'op': 'update_layer', 'layer': 'v', 'text_style': 'script_name'});
      expect(textOf(p, 'v').fontFamily, 'Great Vibes');
      expect(textOf(p, 'v').extrude, 0);
      expect(textOf(p, 'v').outline, 0);

      run(p, {'op': 'add_layer', 'type': 'text', 'id': 'h', 'text': 'भारत', 'text_style': 'hindi_bold'});
      expect(textOf(p, 'h').fontFamily, 'Rozha One');

      run(p, {'op': 'add_layer', 'type': 'text', 'id': 'w', 'text': 'CASE', 'text_style': 'typewriter', 'font': 'Roboto Mono'});
      expect(textOf(p, 'w').fontFamily, 'Roboto Mono');
      expect(textOf(p, 'w').animator, 'typewriter');
    });

    test('unknown text_style is rejected', () {
      final p = newProject();
      expect(() => run(p, {'op': 'add_layer', 'type': 'text', 'text': 'X', 'text_style': 'comic'}), throwsA(isA<CommandError>()));
      expect(p.main.layers, isEmpty);
    });

    test('every preset uses a catalog font and applies cleanly', () {
      for (final s in TextStylePresets.all) {
        expect(FontCatalog.lookup(s.font)?.family, s.font, reason: s.id);
        final p = newProject();
        run(p, {'op': 'add_layer', 'type': 'text', 'id': 't', 'text': s.sample, 'text_style': s.id});
        expect(textOf(p, 't').fontFamily, s.font, reason: s.id);
      }
      expect(FontCommands.canonical('ROZHA ONE'), 'Rozha One');
    });

    test('AI command spec documents every font and preset', () {
      expect(commandSpec, contains('text_style'));
      for (final f in FontCatalog.families) {
        expect(commandSpec, contains(f), reason: f);
      }
      for (final id in TextStylePresets.ids) {
        expect(commandSpec, contains(id), reason: id);
      }
    });
  });

  group('picker', () {
    testWidgets('search and pick returns the family', (tester) async {
      String? picked = 'unset';
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async => picked = await FontPicker.open(ctx, 'Anton', sample: 'भारत'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(FontPicker), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'rozha');
      await tester.pumpAndSettle();
      expect(find.text('Rozha One'), findsOneWidget);
      expect(find.text('Anton'), findsNothing);
      await tester.tap(find.text('Rozha One'));
      await tester.pumpAndSettle();
      expect(picked, 'Rozha One');
    });

    testWidgets('style picker lists every preset', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: const Scaffold(body: SizedBox(width: 800, height: 2000, child: TextStylePicker())),
      ));
      await tester.pumpAndSettle();
      expect(find.text(TextStylePresets.all.first.label), findsOneWidget);
    });
  });
}
