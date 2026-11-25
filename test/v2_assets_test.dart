import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/core/engine/fx_math.dart';
import 'package:motionai/core/engine/text_clusters.dart';
import 'package:motionai/director/sfx.dart';

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
}
