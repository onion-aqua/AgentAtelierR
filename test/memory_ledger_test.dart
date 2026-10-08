import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/memory_ledger.dart';
import 'package:ryza_chat_mvp/src/memory_timeline.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _document(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('extracts every high signal sentence and keeps provenance', () {
    final facts = MemoryLedger.extractTurn(
      userText: '我们约定明天去森林。收到你的苹果。',
      assistantText:
          '<think>内部推理：明天。</think><answer>好，明天一起出发。</answer>\n'
          '<tool_call>不要保存这个工具参数</tool_call>',
      sourceMessageId: 'assistant-1',
      now: DateTime(2026, 10, 6),
    );

    expect(facts, isNotEmpty);
    expect(facts.where((fact) => fact.category == 'promise'), hasLength(2));
    expect(facts.any((fact) => fact.category == 'item'), isTrue);
    expect(facts.every((fact) => !fact.summary.contains('内部推理')), isTrue);
    expect(facts.every((fact) => !fact.summary.contains('工具参数')), isTrue);
    expect(facts.any((fact) => fact.sourceRole == 'user'), isTrue);
    expect(facts.any((fact) => fact.sourceRole == 'assistant'), isTrue);
  });

  test('drops an unclosed reasoning block from a partial model response', () {
    final facts = MemoryLedger.extractTurn(
      userText: '我们约定明天见。',
      assistantText: '<think>明天的内部计划还没有结束，不能成为记忆。',
      sourceMessageId: 'assistant-partial',
    );
    expect(facts, hasLength(1));
    expect(facts.single.summary, contains('约定明天'));
    expect(facts.single.summary, isNot(contains('内部计划')));
  });

  test('append-only merge is idempotent and preserves user facts', () {
    final first = MemoryLedger.extractTurn(
      userText: '我喜欢在湖边采集。',
      assistantText: '好，明天一起去湖边。',
      sourceMessageId: 'assistant-1',
      now: DateTime(2026, 10, 6),
    );
    final saved = MemoryLedger.mergeIntoTimeline('', first)!;
    final repeated = MemoryLedger.mergeIntoTimeline(saved, first)!;
    expect(_document(repeated)['entries'], hasLength(2));

    final edited = MemoryTimeline.normalizeExisting(
      jsonEncode({
        'entries': [
          {
            'sequence': 1,
            'category': 'user_preference',
            'summary': '用户手动修正为喜欢在海岸采集。',
            'importance': 4,
          },
        ],
      }),
    );
    final protected = MemoryLedger.mergeIntoTimeline(edited, first)!;
    final entries = _document(protected)['entries'] as List;
    expect(entries.first['summary'], '用户手动修正为喜欢在海岸采集。');
  });

  test('local facts are recorded without an auxiliary model', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    controller.setLongTermMemoryEnabled(true);
    controller.addUserMessage('我希望明天去森林。');
    controller.addAssistantMessage('好，我们约定明天一起出发。');

    expect(
      controller.recordDeterministicMemoryForLastTurn(
        now: DateTime(2026, 10, 6),
      ),
      isTrue,
    );
    final memory = _document(controller.memorySummary);
    expect(
      (memory['entries'] as List).any(
        (entry) => entry['category'] == 'promise',
      ),
      isTrue,
    );
    expect(
      controller.memoryPromptForCurrentConversation(currentInput: '森林'),
      contains('森林'),
    );
  });

  test(
    'completed stream commits local facts through the chat entry point',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      controller.setLongTermMemoryEnabled(true);
      controller.addUserMessage('我们约定明天去森林。');
      controller.beginAssistantStream();
      controller.appendAssistantDelta('好，明天一起出发。');
      final messageId = controller.messages.last.id;

      controller.finishAssistantStream(recordMemory: true);

      final entries = _document(controller.memorySummary)['entries'] as List;
      expect(entries, isNotEmpty);
      expect(
        entries.every((entry) => entry['source_message_id'] == messageId),
        isTrue,
      );
      expect(
        controller.memoryPromptForCurrentConversation(currentInput: '森林'),
        contains('森林'),
      );
    },
  );

  for (final failed in [false, true]) {
    test(
      '${failed ? 'failed' : 'cancelled'} stream does not commit partial facts',
      () async {
        SharedPreferences.setMockInitialValues({});
        final controller = await AppController.load();
        addTearDown(controller.dispose);
        controller.setLongTermMemoryEnabled(true);
        controller.addUserMessage('我们约定明天去森林。');
        controller.beginAssistantStream();
        controller.appendAssistantDelta('好，明天一起');

        if (failed) {
          controller.failAssistantStream('网络连接中断');
        } else {
          controller.finishAssistantStream();
        }

        expect(controller.memorySummary, isEmpty);
      },
    );
  }
}
