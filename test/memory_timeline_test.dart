import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/memory_timeline.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _decode(String value) =>
    jsonDecode(value) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'same-day transitions keep event order and expose only newest state',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      final first = AppController.normalizeLongTermMemoryCandidate(
        jsonEncode({
          'entries': [
            {
              'date': '2026-09-23',
              'category': 'relationship_turning_point',
              'importance': 5,
              'summary': '两人确认成为朋友。',
              'state_change': {'domain': '关系', 'from': '陌生人', 'to': '朋友'},
              'keywords': ['关系'],
            },
          ],
        }),
        previousMemory: '',
        now: DateTime(2026, 9, 23, 10),
      )!;
      final previousEntry = (_decode(first)['entries'] as List).single as Map;
      final second = AppController.normalizeLongTermMemoryCandidate(
        jsonEncode({
          'entries': [
            previousEntry,
            {
              'date': '2026-09-23',
              'category': 'relationship_turning_point',
              'importance': 5,
              'summary': '两人后来确认恋人关系。',
              'state_change': {'domain': '关系', 'from': '朋友', 'to': '恋人'},
              'keywords': ['关系'],
            },
          ],
        }),
        previousMemory: first,
        now: DateTime(2026, 9, 23, 15),
      )!;
      final document = _decode(second);
      final entries = document['entries'] as List;
      expect(entries.map((e) => e['id']), ['AM0001', 'AM0002']);
      expect(entries.map((e) => e['sequence']), [1, 2]);
      expect(entries.first['status'], 'superseded');
      expect(entries.last['status'], 'active');
      expect((document['current_state'] as Map)['关系'], {
        'value': '恋人',
        'since': 'AM0002',
      });
      controller.updateMemorySummary(second);
      final recalled = _decode(
        controller.memoryPromptForCurrentConversation(
          currentInput: '我们现在是什么关系？',
        ),
      );
      expect((recalled['current_state'] as Map)['关系']['value'], '恋人');
      expect((recalled['entries'] as List).map((e) => e['id']), [
        'AM0001',
        'AM0002',
      ]);
      controller.agentEnabled = true;
      expect(controller.buildCharacterPrompt(), contains('已确认的当前状态'));
      expect(controller.buildCharacterPrompt(), contains('恋人'));
      controller.agentEnabled = false;
      controller.llmContextCompatibility = true;
      expect(controller.buildCharacterPrompt(), contains('已确认的当前状态'));
      expect(
        controller.buildCharacterPrompt(independentPerformance: true),
        contains('已确认的当前状态'),
      );
      await controller.saveToLocalSlot(0);
      controller.updateMemorySummary(first);
      await controller.loadFromLocalSlot(0);
      expect(
        (_decode(controller.memorySummary)['current_state']
            as Map)['关系']['value'],
        '恋人',
      );
    },
  );

  test('legacy dates migrate once; deletion renumbers display IDs only', () {
    final old = jsonEncode({
      'entries': [
        {'date': '2026-09-23', 'summary': '当天第二件事', 'importance': 1},
        {'date': '2026-09-22', 'summary': '前一天的事', 'importance': 1},
        {'date': '2026-09-23', 'summary': '当天第三件事', 'importance': 1},
      ],
    });
    final migrated = _decode(MemoryTimeline.normalizeExisting(old));
    final entries = migrated['entries'] as List;
    expect(entries.map((e) => e['summary']), ['前一天的事', '当天第二件事', '当天第三件事']);
    expect(entries.map((e) => e['id']), ['AM0001', 'AM0002', 'AM0003']);
    entries.removeAt(1);
    final edited = _decode(
      MemoryTimeline.normalizeExisting(jsonEncode(migrated)),
    );
    expect((edited['entries'] as List).map((e) => e['id']), [
      'AM0001',
      'AM0002',
    ]);
    expect((edited['entries'] as List).map((e) => e['sequence']), [1, 3]);
    final added = _decode(
      AppController.normalizeLongTermMemoryCandidate(
        jsonEncode({
          'entries': [
            ...(edited['entries'] as List),
            {'date': '2026-09-23', 'summary': '新事件', 'importance': 1},
          ],
        }),
        previousMemory: jsonEncode(edited),
        now: DateTime(2026, 9, 23),
      )!,
    );
    expect((added['entries'] as List).map((e) => e['sequence']), [1, 3, 4]);
    expect((added['entries'] as List).map((e) => e['id']), [
      'AM0001',
      'AM0002',
      'AM0003',
    ]);
    (added['entries'] as List).removeLast();
    final withoutLast = MemoryTimeline.normalizeExisting(jsonEncode(added));
    final afterDelete = _decode(
      AppController.normalizeLongTermMemoryCandidate(
        jsonEncode({
          'entries': [
            ...(_decode(withoutLast)['entries'] as List),
            {'date': '2026-09-23', 'summary': '删除后的新事件'},
          ],
        }),
        previousMemory: withoutLast,
        now: DateTime(2026, 9, 23),
      )!,
    );
    expect((afterDelete['entries'] as List).last['sequence'], 5);
    expect((afterDelete['entries'] as List).last['id'], 'AM0003');
  });

  test(
    'critical history survives omitted candidate and summaries are bounded',
    () {
      final previous = MemoryTimeline.normalizeExisting(
        jsonEncode({
          'entries': [
            {
              'date': '2026-09-22',
              'category': 'promise',
              'importance': 5,
              'summary': '两人约定第二天一起采集。',
            },
          ],
        }),
      );
      final result = _decode(
        AppController.normalizeLongTermMemoryCandidate(
          jsonEncode({
            'entries': [
              {
                'date': '2026-09-23',
                'category': 'other',
                'importance': 1,
                'summary': '莱莎' * 70,
                'key_quotes': ['无关引用'],
              },
            ],
          }),
          previousMemory: previous,
          now: DateTime(2026, 9, 23),
        )!,
      );
      final entries = result['entries'] as List;
      expect(entries.first['summary'], '两人约定第二天一起采集。');
      expect((entries.last['summary'] as String).runes.length, 50);
      expect(entries.last['key_quotes'], isNull);
      expect(entries.map((e) => e['id']), ['AM0001', 'AM0002']);
    },
  );
}
