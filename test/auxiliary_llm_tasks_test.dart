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
}
