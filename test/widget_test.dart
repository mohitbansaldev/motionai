// Kept so `flutter create .` doesn't generate the default counter test.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motionai/ui/common.dart';

void main() {
  testWidgets('swatch row reports the picked color', (tester) async {
    int? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SwatchRow(selected: kSwatches.first, onPick: (c) => picked = c)),
    ));
    await tester.tap(find.descendant(of: find.byType(SwatchRow), matching: find.byType(GestureDetector)).at(2));
    expect(picked, kSwatches[2]);
  });

  test('time format', () {
    expect(formatTime(61.5, 30), '01:01:15');
  });
}
