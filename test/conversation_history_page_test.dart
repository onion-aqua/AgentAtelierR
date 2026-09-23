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
        text: '旁白：莱莎拿起瓶子。\n莱莎：[happy][face:smile][action:think] 这个很有趣！\n译文：Very interesting!\n角色[klaudia]：我也来看看。',
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
}
