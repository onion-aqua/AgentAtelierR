import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'recent batches are idempotent and manual edits reject stale results',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);

      for (var index = 0; index < 8; index++) {
        controller.addUserMessage('对话 $index');
        final id = controller.messages.last.id;
        expect(
          controller.appendRecentMemory('摘要 $index', lastMessageId: id),
          isTrue,
        );
        expect(
          controller.appendRecentMemory('摘要 $index', lastMessageId: id),
          isFalse,
        );
      }
      expect(controller.pendingRecentMemoryCount, 8);
      expect(controller.memoryPromptForCurrentConversation(), contains('摘要 7'));
      controller.configureLongTermMemory(
        enabled: true,
        summary: controller.memorySummary,
      );
      controller.setLongTermMemoryEnabled(false);
      controller.setLongTermMemoryEnabled(true);
      expect(controller.pendingRecentMemoryCount, 8);

      final version = controller.memoryEditRevision;
      controller.updateMemorySummary('手动保留的记忆\n另一行');
      expect(controller.pendingRecentMemoryCount, 0);
      final candidate = jsonEncode({
        'entries': [
          {'summary': '自动记忆', 'date': '2026-09-26', 'category': 'other'},
        ],
      });
      expect(
        controller.applyConsolidatedLongTermMemory(
          candidate,
          expectedEditRevision: version,
          throughRecentMemoryCount: 8,
        ),
        isFalse,
      );
      expect(controller.memorySummary, '手动保留的记忆\n另一行');

      controller.addUserMessage('新对话');
      expect(
        controller.appendRecentMemory(
          '新摘要',
          lastMessageId: controller.messages.last.id,
        ),
        isTrue,
      );
      expect(
        controller.applyConsolidatedLongTermMemory(
          candidate,
          expectedEditRevision: controller.memoryEditRevision,
          throughRecentMemoryCount: 9,
        ),
        isTrue,
      );
      expect(controller.pendingRecentMemoryCount, 0);
      final migrated = jsonDecode(controller.memorySummary) as Map;
      final entries = migrated['entries'] as List;
      expect(
        entries.where(
          (entry) =>
              entry['category'] == 'legacy' &&
              entry['summary'] == '手动保留的记忆\n另一行',
        ),
        hasLength(1),
      );
      expect(entries.any((entry) => entry['summary'] == '自动记忆'), isTrue);
    },
  );

  test(
    'recent memories and prompt survive backup and save switching',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      controller.setMemoryConsolidationPrompt('自定义长期整理规则');
      controller.addUserMessage('第一段');
      final anchor = controller.messages.last.id;
      expect(
        controller.appendRecentMemory('第一条最近记忆', lastMessageId: anchor),
        isTrue,
      );
      final backup = controller.exportData();
      await controller.saveToLocalSlot(0);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final restored = await AppController.load();
      addTearDown(restored.dispose);
      expect(restored.recentMemories, ['第一条最近记忆']);
      expect(restored.lastRecentMemoryMessageId, anchor);
      expect(restored.memoryConsolidationPrompt, '自定义长期整理规则');
      await controller.createLocalSlot(1);
      expect(controller.recentMemories, isEmpty);
      expect(controller.memoryConsolidationPrompt, '自定义长期整理规则');

      await controller.loadFromLocalSlot(0);
      expect(controller.recentMemories, ['第一条最近记忆']);
      expect(controller.lastRecentMemoryMessageId, anchor);
      expect(controller.pendingRecentMemoryCount, 1);

      controller.clearChatHistory(clearLongTermMemory: true);
      await controller.importData(backup);
      expect(controller.recentMemories, ['第一条最近记忆']);
      expect(controller.lastRecentMemoryMessageId, anchor);
      expect(controller.memoryConsolidationPrompt, '自定义长期整理规则');
    },
  );

  test('undoing a recently summarized turn restores the checkpoint', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    for (var index = 0; index < 4; index++) {
      controller.addUserMessage('对话 $index');
    }
    final lastId = controller.messages.last.id;
    expect(
      controller.appendRecentMemory('四轮摘要', lastMessageId: lastId),
      isTrue,
    );
    expect(controller.undoLastUserTurn()?.id, lastId);
    expect(controller.lastRecentMemoryMessageId, isNull);
    expect(controller.recentMemories, isEmpty);
    controller.addUserMessage('改写的第四轮');
    expect(
      controller.appendRecentMemory(
        '改写后的四轮摘要',
        lastMessageId: controller.messages.last.id,
      ),
      isTrue,
    );
    expect(controller.recentMemories, ['改写后的四轮摘要']);
  });

  test(
    'a collapsed long-term result cannot replace the existing timeline',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      controller.updateMemorySummary(
        jsonEncode({
          'entries': [
            for (var index = 0; index < 4; index++)
              {
                'summary': '原有记忆 $index',
                'date': '2026-09-26',
                'category': 'other',
              },
          ],
        }),
      );
      final original = controller.memorySummary;
      controller.addUserMessage('新对话');
      expect(
        controller.appendRecentMemory(
          '新对话摘要',
          lastMessageId: controller.messages.last.id,
        ),
        isTrue,
      );
      final collapsed = jsonEncode({
        'entries': [
          {'summary': '只剩一条', 'date': '2026-09-26', 'category': 'other'},
        ],
      });
      expect(
        controller.applyConsolidatedLongTermMemory(
          collapsed,
          expectedEditRevision: controller.memoryEditRevision,
          throughRecentMemoryCount: 1,
        ),
        isFalse,
      );
      expect(controller.memorySummary, original);
      expect(controller.pendingRecentMemoryCount, 1);
      final oldEntries =
          (jsonDecode(original) as Map<String, dynamic>)['entries']
              as List<dynamic>;
      final valid = jsonEncode({
        'entries': [
          ...oldEntries,
          {'summary': '新记忆', 'date': '2026-09-26', 'category': 'other'},
        ],
      });
      expect(
        controller.applyConsolidatedLongTermMemory(
          valid,
          expectedEditRevision: controller.memoryEditRevision,
          throughRecentMemoryCount: 1,
        ),
        isTrue,
      );
      expect(controller.pendingRecentMemoryCount, 0);
      expect(controller.memorySummary, contains('新记忆'));
    },
  );
}
