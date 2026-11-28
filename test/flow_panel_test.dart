// win-43: Flow panel file naming (roles for library_import_folder).
import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/platform/flow_panel.dart';
import 'package:motionai/remote/mcp_protocol.dart';

void main() {
  group('Flow panel (win-43)', () {
    test('role prefix from the border and the title', () {
      expect(flowFileStem('Miner wearing helmet lamp', green: true, dark: false), 'char_miner_wearing_helmet_lamp');
      expect(flowFileStem('Rusted ore cart', green: true, dark: false), 'prop_rusted_ore_cart');
      expect(flowFileStem('Dust drifting in light', green: false, dark: true), 'fx_dust_drifting_in_light');
      expect(flowFileStem('Abandoned mine headframes at dawn', green: false, dark: false), 'plate_abandoned_mine_headframes_at_dawn');
    });

    test('a role prefix already in the title is kept', () {
      expect(flowFileStem('char_surveyor full body', green: false, dark: false), 'char_surveyor_full_body');
      expect(flowFileStem('PLATE_tunnel', green: true, dark: false), 'plate_tunnel');
    });

    test('empty and long titles', () {
      expect(flowFileStem('', green: false, dark: false), 'plate_image');
      expect(flowFileStem('x' * 80, green: false, dark: false).length, lessThanOrEqualTo(6 + 48));
    });

    test('tools are declared; flow_pull waits for exports', () {
      for (final n in ['flow_panel_open', 'flow_pull', 'flow_panel_eval', 'flow_panel_close']) {
        expect(kMcpToolNames, contains(n));
      }
      expect(kMcpEditTools, contains('flow_pull'));
    });
  });
}
