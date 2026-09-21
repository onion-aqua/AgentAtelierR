import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/narration_composer_fields.dart';

void main() {
  testWidgets('long text scrolls inside each part without hiding siblings', (
    tester,
  ) async {
    final controllers = List.generate(3, (_) => TextEditingController());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 230,
              height: 174,
              child: NarrationComposerFields(
                controllers: controllers,
                hints: const ['Above', 'Speech', 'Below'],
                expanded: false,
                onToggleExpanded: () {},
                expandLabel: 'Expand',
                readOnly: false,
              ),
            ),
          ),
        ),
      ),
    );
    final before = List.generate(
      3,
      (i) => tester.getRect(find.byKey(ValueKey('narration-input-$i'))),
    );
    for (var i = 0; i < 3; i++) {
      await tester.enterText(
        find.byKey(ValueKey('narration-input-$i')),
        List.filled(20, 'long line of text\n').join(),
      );
      await tester.pumpAndSettle();
    }
    for (var i = 0; i < 3; i++) {
      expect(
        tester.getRect(find.byKey(ValueKey('narration-input-$i'))),
        before[i],
      );
    }
    expect(find.byType(Scrollbar), findsNWidgets(3));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    for (final controller in controllers) {
      controller.dispose();
    }
  });
}
