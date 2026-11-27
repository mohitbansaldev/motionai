// win-42: the control manual served over MCP (get_manual, motionai://manual).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/remote/manual.dart';
import 'package:motionai/remote/mcp_protocol.dart';

Map<String, dynamic> _call(int id, String name, [Map<String, dynamic> args = const {}]) => {
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': args},
    };

void main() {
  group('manual (win-42)', () {
    test('the embedded text is docs/MOTIONAI_MANUAL.md', () {
      final doc = File('docs/MOTIONAI_MANUAL.md').readAsStringSync().replaceAll('\r\n', '\n');
      expect(kManual == doc, isTrue, reason: 'lib/remote/manual_text.dart is out of date: run python tool/gen_manual.py');
    });

    test('every MCP tool is documented in the manual', () {
      for (final n in kMcpToolNames) {
        expect(RegExp('\\b$n\\b').hasMatch(kManual), isTrue, reason: '$n is missing from docs/MOTIONAI_MANUAL.md');
      }
    });

    test('sections by number, words, toc; misses are null', () {
      expect(Manual.section(null), kManual);
      expect(Manual.section('all'), kManual);
      expect(Manual.section('toc'), contains('16. Known quirks'));
      expect(Manual.section('0'), startsWith('## 0. Golden rules'));
      expect(Manual.section('2'), startsWith('## 2. Connecting'));
      expect(Manual.section('7.3'), startsWith('### 7.3'));
      expect(Manual.section('A.1'), startsWith('### A.1'));
      expect(Manual.section('quirks'), startsWith('## 16.'));
      expect(Manual.section('16')!.contains('## 17.'), isFalse, reason: 'a chapter stops at the next chapter');
      expect(Manual.section('no such chapter xyz'), isNull);
      expect(Manual.headings.where((h) => h.level == 2).length, greaterThanOrEqualTo(22));
    });

    test('listed first, in the instructions, and a resource', () {
      expect(kMcpTools.first['name'], 'get_manual');
      expect(kMcpInstructions, contains('get_manual'));
      expect([for (final r in kMcpResources) r['uri']], contains(kResourceManual));
      expect(kMcpEditTools.contains('get_manual'), isFalse);
    });

    test('the stdio bridge answers the manual while the app is closed', () {
      final r = BridgeFraming.manualAnswer(_call(1, 'get_manual', {'section': '2'}))!;
      final res = r['result'] as Map;
      expect(res['isError'], isFalse);
      expect(((res['content'] as List).first as Map)['text'], startsWith('## 2. Connecting'));
      final miss = BridgeFraming.manualAnswer(_call(2, 'get_manual', {'section': 'zzz nothing'}))!;
      expect((miss['result'] as Map)['isError'], isTrue);
      expect(BridgeFraming.manualAnswer(_call(3, 'get_manual', {'section': 'spec'})), isNull, reason: 'spec needs the app');
      expect(BridgeFraming.manualAnswer(_call(4, 'get_state')), isNull);
      final rr = BridgeFraming.manualAnswer({
        'jsonrpc': '2.0',
        'id': 5,
        'method': 'resources/read',
        'params': {'uri': kResourceManual},
      })!;
      final contents = (rr['result'] as Map)['contents'] as List;
      expect((contents.first as Map)['text'], kManual);
    });
  });
}
