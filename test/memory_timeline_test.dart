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

  test(
    'automatic merge preserves omitted and manually edited ordinary facts',
    () {
      final previous = MemoryTimeline.normalizeExisting(
        jsonEncode({
          'entries': [
            {
              'sequence': 1,
              'date': '2026-09-22',
              'category': 'other',
              'importance': 2,
              'summary': '用户手动修正后的采集地点是湖边。',
              'keywords': ['湖边'],
            },
            {
              'sequence': 2,
              'date': '2026-09-23',
              'category': 'other',
              'importance': 1,
              'summary': '两人一起整理了药草。',
            },
          ],
        }),
      );
      final merged = _decode(
        MemoryTimeline.normalizeCandidate(
          jsonEncode({
            'entries': [
              {
                'sequence': 1,
                'date': '2026-09-22',
                'summary': '模型仍认为采集地点是森林。',
                'importance': 5,
              },
              {'date': '2026-09-24', 'summary': '莱莎和用户开始准备新的旅行。'},
            ],
          }),
          previousMemory: previous,
          now: DateTime(2026, 9, 24),
        )!,
      );
      final entries = merged['entries'] as List;
      expect(entries.map((entry) => entry['summary']), [
        '用户手动修正后的采集地点是湖边。',
        '两人一起整理了药草。',
        '莱莎和用户开始准备新的旅行。',
      ]);
      expect(entries.first['importance'], 2);
      expect(entries.first['keywords'], ['湖边']);
    },
  );

  test('repeated event summaries do not create duplicate long-term facts', () {
    final previous = MemoryTimeline.normalizeCandidate(
      jsonEncode({
        'entries': [
          {'date': '2026-09-25', 'summary': '莱莎和用户在湖边约定明天一起采集药草。'},
        ],
      }),
      previousMemory: '',
      now: DateTime(2026, 9, 25),
    )!;
    final merged = _decode(
      MemoryTimeline.normalizeCandidate(
        jsonEncode({
          'entries': [
            {'date': '2026-09-25', 'summary': '莱莎和用户在湖边约定明天一起采集药草'},
            {'date': '2026-09-25', 'summary': '莱莎和用户在湖边约定明天一起采集药草，随后道别。'},
            {'date': '2026-09-25', 'summary': '两人在工坊准备了旅行行李。'},
            {'date': '2026-09-25', 'summary': '两人在工坊准备了旅行行李！'},
          ],
        }),
        previousMemory: previous,
        now: DateTime(2026, 9, 25),
      )!,
    );
    expect((merged['entries'] as List).map((entry) => entry['summary']), [
      '莱莎和用户在湖边约定明天一起采集药草。',
      '两人在工坊准备了旅行行李。',
    ]);
    expect(merged['last_sequence'], 2);
  });

  test('same-day repeated transition survives an intervening reversal', () {
    final previous = MemoryTimeline.normalizeCandidate(
      jsonEncode({
        'entries': [
          {
            'date': '2026-09-25',
            'summary': '两人确认从陌生人成为朋友。',
            'state_change': {'domain': '关系', 'from': '陌生人', 'to': '朋友'},
          },
          {
            'date': '2026-09-25',
            'summary': '两人争执后关系回到陌生人。',
            'state_change': {'domain': '关系', 'from': '朋友', 'to': '陌生人'},
          },
        ],
      }),
      previousMemory: '',
      now: DateTime(2026, 9, 25),
    )!;
    final merged = _decode(
      MemoryTimeline.normalizeCandidate(
        jsonEncode({
          'entries': [
            {
              'date': '2026-09-25',
              'summary': '两人确认从陌生人成为朋友。',
              'state_change': {'domain': '关系', 'from': '陌生人', 'to': '朋友'},
            },
            {
              'date': '2026-09-25',
              'summary': '两人确认从陌生人成为朋友。',
              'state_change': {'domain': '关系', 'from': '陌生人', 'to': '朋友'},
            },
          ],
        }),
        previousMemory: previous,
        now: DateTime(2026, 9, 25),
      )!,
    );
    final entries = merged['entries'] as List;
    expect(entries.map((entry) => entry['sequence']), [1, 2, 3]);
    expect(entries.first['status'], 'superseded');
    expect(entries[1]['status'], 'superseded');
    expect(entries.last['status'], 'active');
    expect((merged['current_state'] as Map)['关系'], {
      'value': '朋友',
      'since': 'AM0003',
    });
  });

  test('new facts remain available after 40 entries and 6000 characters', () {
    final previous = MemoryTimeline.normalizeExisting(
      jsonEncode({
        'entries': [
          for (var i = 1; i <= 40; i++)
            {'sequence': i, 'date': '2026-09-25', 'summary': '已保存的普通事件 $i'},
        ],
      }),
    );
    final merged = _decode(
      MemoryTimeline.normalizeCandidate(
        jsonEncode({
          'entries': [
            {'date': '2026-09-26', 'summary': '新增的普通事件'},
          ],
        }),
        previousMemory: previous,
        now: DateTime(2026, 9, 26),
      )!,
    );
    expect((merged['entries'] as List).length, 41);
    expect((merged['entries'] as List)[39]['summary'], '已保存的普通事件 40');
    expect((merged['entries'] as List).last['summary'], '新增的普通事件');
    expect(merged['last_sequence'], 41);

    final largeFact = '必须保留的用户手动记录' * 700;
    final oversizedPrevious = MemoryTimeline.normalizeExisting(
      jsonEncode({
        'entries': [
          {'date': '2026-09-25', 'summary': largeFact},
        ],
      }),
    );
    final oversizedMerged = _decode(
      MemoryTimeline.normalizeCandidate(
        jsonEncode({
          'entries': [
            {'date': '2026-09-26', 'summary': '新增的普通事件'},
          ],
        }),
        previousMemory: oversizedPrevious,
        now: DateTime(2026, 9, 26),
      )!,
    );
    expect((oversizedMerged['entries'] as List).first['summary'], largeFact);
    expect((oversizedMerged['entries'] as List).last['summary'], '新增的普通事件');
  });

  test('a deleted sequence is not restored by a later model response', () {
    final initial = _decode(
      MemoryTimeline.normalizeExisting(
        jsonEncode({
          'entries': [
            {'sequence': 1, 'summary': '保留的事件'},
            {'sequence': 2, 'summary': '用户随后删除的事件'},
          ],
        }),
      ),
    );
    (initial['entries'] as List).removeLast();
    final edited = MemoryTimeline.normalizeExisting(jsonEncode(initial));
    final merged = _decode(
      MemoryTimeline.normalizeCandidate(
        jsonEncode({
          'entries': [
            {'sequence': 2, 'date': '2026-09-26', 'summary': '用户随后删除的事件'},
          ],
        }),
        previousMemory: edited,
        now: DateTime(2026, 9, 26),
      )!,
    );
    expect((merged['entries'] as List).map((entry) => entry['summary']), [
      '保留的事件',
    ]);
    expect(merged['last_sequence'], 2);
  });

  test(
    'legacy plain-text memory migrates without losing any original text',
    () {
      const raw = '  用户手动写下的重要经历，\n不可丢失。明天一起采集药草。  ';
      expect(MemoryTimeline.normalizeExisting(raw), raw);
      expect(MemoryTimeline.normalizeExisting('  \n\t  '), isEmpty);
      final result = _decode(
        MemoryTimeline.normalizeCandidate(
          jsonEncode({
            'entries': [
              {'date': '2026-09-26', 'summary': '明天一起采集药草'},
            ],
          }),
          previousMemory: raw,
          now: DateTime(2026, 9, 26),
        )!,
      );
      final entries = result['entries'] as List;
      expect(entries.length, 2);
      expect(entries.first['category'], 'legacy');
      expect(entries.first['importance'], 5);
      expect(entries.first['date'], isNull);
      expect(entries.first['summary'], raw);
      expect(entries.last['summary'], '明天一起采集药草');

      final saved = MemoryTimeline.normalizeExisting(jsonEncode(result));
      expect((_decode(saved)['entries'] as List).first['date'], isNull);
      expect((_decode(saved)['entries'] as List).first['summary'], raw);
      final next = _decode(
        MemoryTimeline.normalizeCandidate(
          jsonEncode({'entries': []}),
          previousMemory: saved,
          now: DateTime(2026, 9, 27),
        )!,
      );
      expect((next['entries'] as List).first['summary'], raw);
    },
  );
}
