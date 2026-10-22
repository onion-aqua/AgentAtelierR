import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';

void main() {
  testWidgets('live glass toggle preserves draft, selection and focus', (
    tester,
  ) async {
    final glass = ValueNotifier(false);
    addTearDown(glass.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: glass,
            builder: (context, enabled, _) =>
                GlassSurface(liquidGlass: enabled, child: const TextField()),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '尚未保存的内容');
    final original = tester.state<EditableTextState>(find.byType(EditableText));
    original.widget.controller.selection = const TextSelection.collapsed(
      offset: 3,
    );
    for (final enabled in [true, false, true]) {
      glass.value = enabled;
      await tester.pumpAndSettle();
      final current = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      expect(current, same(original));
      expect(current.widget.controller.text, '尚未保存的内容');
      expect(current.widget.controller.selection.baseOffset, 3);
      expect(current.widget.focusNode.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    }
  });
}
