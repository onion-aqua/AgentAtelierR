import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'chat bubble style defaults off and survives restart and backup',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      expect(controller.chatBubbleStyle, isFalse);

      controller.setChatBubbleStyle(true);
      await Future<void>.delayed(Duration.zero);
      final restored = await AppController.load();
      addTearDown(restored.dispose);
      expect(restored.chatBubbleStyle, isTrue);
      final backup = restored.exportData();
      expect(backup['chatBubbleStyle'], isTrue);

      restored.setChatBubbleStyle(false);
      await restored.importData(backup);
      expect(restored.chatBubbleStyle, isTrue);

      final legacyBackup = Map<String, dynamic>.from(backup)
        ..remove('chatBubbleStyle');
      await restored.importData(legacyBackup);
      expect(restored.chatBubbleStyle, isFalse);
    },
  );

  testWidgets('appearance page switches the bubble style without leaving it', (
    tester,
  ) async {
    final controller = (await tester.runAsync(() => AppController.load()))!;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          controller: controller,
          onMenuPressed: () {},
          embedded: true,
          initialSection: SettingsSection.appearance,
        ),
      ),
    );
    final toggle = find.byKey(const ValueKey('settings-chat-bubble-style'));
    await tester.scrollUntilVisible(toggle, 160);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(controller.chatBubbleStyle, isTrue);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(controller.chatBubbleStyle, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
