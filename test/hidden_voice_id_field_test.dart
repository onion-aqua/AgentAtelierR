import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/hidden_voice_id_field.dart';

void main() {
  const fieldKey = ValueKey('voice-replacement');

  Future<void> showField(
    WidgetTester tester,
    TextEditingController controller, {
    String resetValue = '',
    ValueChanged<String>? onChanged,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HiddenVoiceIdField(
          fieldKey: fieldKey,
          controller: controller,
          labelText: '普通音色 ID',
          resetValue: resetValue,
          onChanged: onChanged,
        ),
      ),
    ),
  );

  testWidgets('opening a saved voice keeps its identifier out of the editor', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'private-saved-voice');
    addTearDown(controller.dispose);
    await showField(tester, controller);

    final editor = tester.widget<TextField>(find.byKey(fieldKey));
    expect(editor.controller!.text, isEmpty);
    expect(editor.obscureText, isTrue);
    expect(find.text('private-saved-voice'), findsNothing);
    expect(controller.text, 'private-saved-voice');
    await tester.enterText(find.byKey(fieldKey), '');
    expect(controller.text, 'private-saved-voice');
  });

  testWidgets('replacement is immediately available to save and preview', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'previous-voice');
    addTearDown(controller.dispose);
    String? changed;
    await showField(tester, controller, onChanged: (value) => changed = value);

    await tester.enterText(find.byKey(fieldKey), 'new-custom-voice');
    expect(controller.text, 'new-custom-voice');
    expect(changed, 'new-custom-voice');
    expect(tester.widget<TextField>(find.byKey(fieldKey)).obscureText, isTrue);
    await tester.enterText(find.byKey(fieldKey), '');
    expect(controller.text, 'previous-voice');
    expect(changed, 'previous-voice');
  });

  testWidgets('reset is explicit and can restore a provider default', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'private-custom-voice');
    addTearDown(controller.dispose);
    await showField(tester, controller, resetValue: 'preset-default');
    await tester.tap(find.byTooltip('恢复默认音色'));
    await tester.pump();
    expect(controller.text, 'preset-default');
    expect(tester.widget<TextField>(find.byKey(fieldKey)).controller!.text, '');
    expect(find.text('private-custom-voice'), findsNothing);
    expect(find.text('preset-default'), findsNothing);
  });

  testWidgets(
    'cloning or preset changes replace drafts without revealing IDs',
    (tester) async {
      final controller = TextEditingController(text: 'saved-voice');
      addTearDown(controller.dispose);
      await showField(tester, controller);
      await tester.enterText(find.byKey(fieldKey), 'unfinished-replacement');
      controller.text = 'newly-cloned-voice';
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byKey(fieldKey)).controller!.text,
        '',
      );
      expect(find.text('newly-cloned-voice'), findsNothing);
      await tester.enterText(find.byKey(fieldKey), '');
      expect(controller.text, 'newly-cloned-voice');
      expect(tester.takeException(), isNull);
    },
  );
}
