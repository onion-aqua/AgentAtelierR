import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/auxiliary_llm_tasks.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const source =
      '旁白：她抬起头。\n莱莎：[happy][face:happy][action:none]おはよう！\n角色[klaudia]：こんにちは。';
  test('batch translation binds ids, preserves narration and original performance', () async {
    final output = await DialogueTranslator().translate(
      source: source,
      language: 'Chinese',
      complete: (messages) async {
        final data = jsonDecode(messages.last['content']!) as Map;
        expect(data['lines'], hasLength(2));
        expect(messages.last['content'], isNot(contains('[face:')));
        return '{"translations":[{"id":2,"text":"你好。"},{"id":1,"text":"早上好！"}]}';
      },
    );
    expect(output, contains('[happy][face:happy][action:none]おはよう！\n译文：早上好！'));
    expect(output, contains('角色[klaudia]：こんにちは。\n译文：你好。'));
    expect(output, startsWith('旁白：她抬起头。'));
  });

  test('incomplete, duplicate, unknown or injected translations are rejected', () async {
    for (final invalid in [
      '{"translations":[]}',
      '{"translations":[{"id":1,"text":"a"},{"id":1,"text":"b"}]}',
      '{"translations":[{"id":9,"text":"a"}]}',
      '{"translations":[{"id":1,"text":"[action:wave]"},{"id":2,"text":"b"}]}',
    ]) {
      await expectLater(
        DialogueTranslator().translate(
          source: source,
          language: 'Chinese',
          complete: (_) async => invalid,
        ),
        throwsFormatException,
      );
    }
  });

  test('translation preserves raw text through storage and cannot attach to withdrawn reply', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    controller.addUserMessage('Hello');
    controller.addAssistantMessage(source);
    final original = controller.messages.last;
    expect(controller.attachTranslation(original, '$source\n译文：你好'), isTrue);
    final restored = ChatMessage.fromJson(controller.messages.last.toJson());
    expect(restored.text, source);
    expect(restored.displayText, contains('译文：你好'));
    controller.undoLastUserTurn();
    expect(controller.attachTranslation(original, 'late result'), isFalse);
    controller.dispose();
  });

  test('translation-only view falls back to original while translation unavailable', () {
    final segments = parseAssistantSegments('莱莎：Hello');
    expect(dialogueDisplayIndices(segments, true), [0]);
  });

  test(
    'memory service validates structured output and retains protected memories',
    () async {
      final previous = jsonEncode({
        'entries': [
          {
            'date': '2026-09-19',
            'category': 'promise',
            'importance': 5,
            'summary': '约定明天见面',
            'status': 'active',
            'keywords': ['约定'],
          },
        ],
      });
      final service = MemoryConsolidator();
      expect(
        await service.consolidate(
          previousMemory: previous,
          dialogue: '你好',
          now: DateTime(2026, 9, 19),
          complete: (_) async => 'not json',
        ),
        isNull,
      );
      final result = await service.consolidate(
        previousMemory: previous,
        dialogue: '你好',
        now: DateTime(2026, 9, 19),
        complete: (messages) async {
          expect(messages, hasLength(2));
          expect(messages.first['content'], isNot(contains('[action:')));
          return '{"entries":[]}';
        },
      );
      expect(result, contains('约定明天见面'));
    },
  );

  test(
    'recent memory records one bounded summary from a dialogue batch',
    () async {
      final result = await RecentMemoryConsolidator().consolidate(
        dialogue: '用户：我们明天去森林。\n莱莎：好。',
        now: DateTime(2026, 9, 26),
        complete: (messages) async {
          expect(messages.last['content'], contains('new_dialogue'));
          expect(messages.first['content'], contains('最近四轮对话'));
          return '{"summary":"约定明天去森林。"}';
        },
      );
      expect(result, '约定明天去森林。');
      expect(
        await RecentMemoryConsolidator().consolidate(
          dialogue: '你好',
          now: DateTime(2026, 9, 26),
          complete: (_) async => '{"summary":""}',
        ),
        isNull,
      );
    },
  );

  test('long-term memory uses recent batch and editable prompt', () async {
    final result = await MemoryConsolidator().consolidate(
      previousMemory: '{"entries":[]}',
      recentMemories: const ['约定明天去森林。', '找到了素材。'],
      promptOverride: '请整理 {current_time}，偏移 {utc_offset_minutes}。',
      now: DateTime(2026, 9, 26),
      complete: (messages) async {
        expect(messages.first['content'], contains('2026-09-26'));
        expect(messages.first['content'], isNot(contains('{current_time}')));
        final data = jsonDecode(messages.last['content']!) as Map;
        expect(data['new_recent_memories'], hasLength(2));
        expect(data, isNot(contains('new_dialogue')));
        return '{"entries":[{"summary":"约定明天去森林","date":"2026-09-26"}]}';
      },
    );
    expect(result, contains('约定明天去森林'));
  });

  test(
    'long-term model sees bounded reference while saved history stays whole',
    () async {
      final previous = jsonEncode({
        'entries': [
          for (var sequence = 1; sequence <= 50; sequence++)
            {
              'sequence': sequence,
              'date': '2026-09-25',
              'summary': '已记录事件 $sequence',
              'importance': sequence.isEven ? 2 : 4,
            },
        ],
      });
      final result = await MemoryConsolidator().consolidate(
        previousMemory: previous,
        recentMemories: const ['没有新的重要事件。'],
        now: DateTime(2026, 9, 26),
        complete: (messages) async {
          final data = jsonDecode(messages.last['content']!) as Map;
          final reference =
              jsonDecode(data['previous_memory'] as String) as Map;
          expect(reference['entries'], hasLength(lessThanOrEqualTo(32)));
          expect(reference['omitted_entry_count'], greaterThan(0));
          return '{"entries":[]}';
        },
      );
      final saved = jsonDecode(result!) as Map;
      expect(saved['entries'], hasLength(50));
    },
  );

  test('legacy plain-text memory is retained during consolidation', () async {
    const legacy = '用户手写的重要旧记忆。';
    final result = await MemoryConsolidator().consolidate(
      previousMemory: legacy,
      recentMemories: const ['与莱莎约定明天见面。'],
      now: DateTime(2026, 9, 26),
      complete: (messages) async {
        final data = jsonDecode(messages.last['content']!) as Map;
        expect(data['previous_memory'], legacy);
        return '{"entries":[{"date":"2026-09-26","summary":"与莱莎约定明天见面。"}]}';
      },
    );
    expect(result, contains(legacy));
    expect(result, contains('与莱莎约定明天见面'));
  });
}
