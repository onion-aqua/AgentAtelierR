import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/conversation_history_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('history keeps only user, narration and Ryza visible text', () {
    final entries = visibleConversationHistory(const [
      ChatMessage(text: '旁白：你把瓶子放在桌上\n发言：帮我看看\n旁白：你安静等着', isUser: true),
      ChatMessage(
        text: '旁白：莱莎拿起瓶子。\n莱莎：[happy][face:smile][action:think] 这个很有趣！\n译文：Very interesting!\n角色[klaudia]：我也来看看。\n译文：I will take a look.',
        isUser: false,
      ),
      ChatMessage(text: '连接失败：HTTP 404', isUser: false, isFailure: true),
    ]);

    expect(entries.map((entry) => entry.speaker), [
      ConversationHistorySpeaker.narrator,
      ConversationHistorySpeaker.user,
      ConversationHistorySpeaker.narrator,
      ConversationHistorySpeaker.narrator,
      ConversationHistorySpeaker.ryza,
    ]);
    expect(entries.map((entry) => entry.text), [
      '你把瓶子放在桌上',
      '帮我看看',
      '你安静等着',
      '莱莎拿起瓶子。',
      '这个很有趣！',
    ]);
    expect(entries.last.translation, 'Very interesting!');
    expect(entries.first.translation, isNull);
  });

  test('saved history restores attached translation', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    controller.addAssistantMessage('莱莎：おはよう！');
    final original = controller.messages.last;
    expect(
      await controller.attachTranslation(original, '莱莎：おはよう！\n译文：早上好！'),
      isTrue,
    );
    controller.addUserMessage('没有译文的旧对话');
    await controller.saveToLocalSlot(0, name: '双语存档');
    controller.dispose();

    final restored = await AppController.load();
    addTearDown(restored.dispose);
    final entries = savedConversationHistory(restored).single.entries;
    final translated = entries.singleWhere((entry) => entry.text == 'おはよう！');
    expect(translated.translation, '早上好！');
    expect(entries.last.text, '没有译文的旧对话');
    expect(entries.last.translation, isNull);
  });

  testWidgets('history shows and searches translated dialogue', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final controller = (await tester.runAsync(() => AppController.load()))!;
    addTearDown(controller.dispose);
    controller.addAssistantMessage('莱莎：おはよう！\n译文：早上好！');
    controller.addUserMessage('没有译文的旧对话');
    await tester.runAsync(() => controller.saveToLocalSlot(0, name: '双语存档'));

    await tester.pumpWidget(
      MaterialApp(home: ConversationHistoryPage(controller: controller)),
    );
    await tester.pump();
    await tester.tap(find.text('双语存档'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('おはよう！'), findsOneWidget);
    expect(find.text('译文：早上好！'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '早上好');
    await tester.pump();
    expect(find.text('译文：早上好！'), findsOneWidget);
    expect(find.text('没有译文的旧对话'), findsNothing);
  });

  test('export can omit history without changing stored save', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    controller.addUserMessage('要保留的历史');
    await controller.saveToLocalSlot(0);

    final withoutHistory = controller.exportLocalSlot(
      0,
      includeConversationHistory: false,
    );
    expect((withoutHistory['snapshot'] as Map)['messages'], isEmpty);
    expect(withoutHistory['messageCount'], 0);
    expect(withoutHistory['preview'], '');

    final stored = controller.exportLocalSlot(0);
    expect((stored['snapshot'] as Map)['messages'], isNotEmpty);
    expect(stored['messageCount'], greaterThan(0));

    await controller.importLocalSlot(1, withoutHistory);
    await controller.loadFromLocalSlot(1);
    expect(controller.messages, isEmpty);
  });

  testWidgets('Sophie history shows Sophie identity and assets', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'active_character_id_v1': 'sophie',
    });
    final controller = (await tester.runAsync(() => AppController.load()))!;
    addTearDown(controller.dispose);
    controller.addAssistantMessage('苏菲：今天一起调合吧。');
    await tester.runAsync(() => controller.saveToLocalSlot(0, name: '苏菲存档'));

    await tester.pumpWidget(
      MaterialApp(home: ConversationHistoryPage(controller: controller)),
    );
    await tester.pump();
    await tester.tap(find.text('苏菲存档'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('苏菲'), findsWidgets);
    expect(find.text('莱莎'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName ==
                'assets/images/character_switch/sophie.png',
      ),
      findsWidgets,
    );
  });
}
