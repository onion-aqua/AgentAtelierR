import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/performance_planner.dart';
import 'package:ryza_chat_mvp/src/memory_refresh_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('continuation retry removes failure without losing previous user or assistant messages', () async {
    SharedPreferences.setMockInitialValues({});
    final c = await AppController.load();
    addTearDown(c.dispose);
    c.addUserMessage('hello');
    c.addAssistantMessage('莱莎：你好');
    final before = c.messages.toList();
    c.beginAssistantStream();
    c.failAssistantStream('HTTP 404');
    expect(c.messages.last.isFailure, isTrue);
    expect(c.contextMessagesForModel().any((m) => m.isFailure), isFalse);
    expect(ChatMessage.fromJson(c.messages.last.toJson()).isFailure, isTrue);
    c.beginAssistantStream();
    expect(c.messages.take(before.length), before);
    expect(c.messages.any((m) => m.isFailure), isFalse);
    c.appendAssistantDelta('莱莎：继续');
    c.finishAssistantStream();
    expect(c.messages.last.text, '莱莎：继续');
    expect(
      ChatMessage.fromJson({'text': '连接失败：HTTP 404', 'isUser': false})
          .isFailure,
      isTrue,
    );
    expect(
      ChatMessage.fromJson({'text': '连接失败：HTTP 404', 'isUser': true}).isFailure,
      isFalse,
    );
  });

  test('valid state update survives an invalid animation plan', () async {
    Map<String, dynamic>? state;
    await expectLater(
      PerformancePlanner().plan(
        userInput: '休息一下',
        source: '莱莎：好呀',
        currentFace: 'neutral',
        recentActions: [],
        capabilities: CharacterPerformancePromptContext(
          appearanceId: 'test',
          posture: 'standing',
          revision: 1,
          resourcesReady: true,
          playableActionDescriptions: const {},
        ),
        characterState: {'emotion': 'neutral'},
        onStateProposal: (value) => state = value,
        complete: (_) async => '{"segments":[{"id":0,"face":"invalid","action":"none"}],"state_delta":{"energy":2},"emotion":"happy","reason":"休息恢复精力"}',
      ),
      throwsFormatException,
    );
    expect(state?['reason'], '休息恢复精力');
  });

  test('old memory requests cannot block or unlock new work after loading', () {
    final gate = MemoryRefreshGate();
    final old = gate.begin()!;
    expect(gate.begin(), isNull);
    gate.invalidate(afterLoad: true);
    expect(gate.refreshAfterLoad, isTrue);
    final current = gate.begin()!;
    expect(gate.owns(old), isFalse);
    expect(gate.finish(old), isFalse);
    expect(gate.running, isTrue);
    expect(gate.finish(current), isTrue);
    expect(gate.running, isFalse);
    expect(gate.begin(), isNotNull);
  });

  test(
    'rendering posture and Ryza state are not user profile or fixed commands',
    () async {
      SharedPreferences.setMockInitialValues({});
      final c = await AppController.load();
      addTearDown(c.dispose);
      final prompt = c.buildCharacterPrompt(independentPerformance: true);
      final profile = prompt.split('用户资料：').last.split('\n').first;
      expect(jsonDecode(profile), isNot(contains('莱莎当前状态')));
      expect(prompt, contains('应用渲染快照'));
      expect(prompt, contains('不是用户的角色设定或保持不动的命令'));
      expect(prompt, contains('应用提供的莱莎状态'));
    },
  );
}
