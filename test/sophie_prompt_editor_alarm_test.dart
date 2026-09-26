import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/alarm_screen.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_prompt_editor.dart';
import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<AppController> sophieController(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final controller = (await tester.runAsync(() => AppController.load()))!;
    addTearDown(controller.dispose);
    await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
    tester.view.physicalSize = const Size(390, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    return controller;
  }

  for (final world in [false, true]) {
    testWidgets(
      'Sophie ${world ? 'world' : 'persona'} editor keeps her defaults',
      (tester) async {
        final controller = await sophieController(tester);
        final expected = world
            ? controller.activeCharacterProfile.defaultWorldSetting
            : controller.activeCharacterProfile.defaultPersona;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CharacterPromptEditor(
                      controller: controller,
                      world: world,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-slot-1')));
        await tester.pumpAndSettle();
        final input = tester.widget<TextField>(find.byType(TextField));
        expect(input.controller!.text, expected);
        expect(input.controller!.text, isNot(contains('莱莎')));

        await tester.enterText(find.byType(TextField), '临时修改');
        await tester.ensureVisible(find.text('恢复默认'));
        await tester.tap(find.text('恢复默认'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('恢复默认').last);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          expected,
        );
        await tester.ensureVisible(find.text('保存并使用'));
        await tester.tap(find.text('保存并使用'));
        await tester.pumpAndSettle();
        expect(
          world ? controller.worldSetting : controller.characterPersona,
          isEmpty,
        );
      },
    );
  }

  testWidgets('Sophie alarm page does not offer Ryza voice alarms', (
    tester,
  ) async {
    final controller = await sophieController(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: AlarmScreen(controller: controller, onMenuPressed: () {}),
      ),
    );
    await tester.pump();
    expect(find.text('苏菲的语音闹钟资源尚未提供'), findsOneWidget);
    expect(find.byTooltip('添加闹钟'), findsNothing);
    expect(find.textContaining('莱莎'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
