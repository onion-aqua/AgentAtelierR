import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/manual_memory_consolidation.dart';
import 'package:ryza_chat_mvp/src/memory_timeline.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppController> makeController() async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    controller.setLongTermMemoryEnabled(true);
    return controller;
  }

  test('manual review saves edited recent and long-term text with translations', () async {
    final controller = await makeController();
    controller.addUserMessage('明天一起采集素材吧');
    controller.addAssistantMessage('莱莎：好，我们明天一起去。');
    var recentRequests = 0;
    final proposal = await ManualMemoryConsolidation().prepare(
      controller: controller,
      now: DateTime(2026, 9, 26),
      complete: (messages) async {
        final prompt = messages.first['content']!;
        if (prompt.contains('最近四轮对话')) {
          recentRequests++;
          expect(messages.last['content'], contains('明天一起采集素材'));
          return '{"summary":"双方约定明天采集素材"}';
        }
        if (prompt.contains('从最近记忆中提炼')) {
          return '{"entries":[{"date":"2026-09-26",'
              '"category":"promise","importance":5,'
              '"summary":"双方约定明天一起采集素材"}]}';
        }
        final input = jsonDecode(messages.last['content']!) as Map;
        expect(input['recent'], hasLength(1));
        expect(input['entries'], hasLength(1));
        return '{"recent":[{"index":0,"translation":"They agreed to gather materials tomorrow."}],'
            '"entries":[{"sequence":1,"translation":"They agreed to gather materials tomorrow."}]}';
      },
    );
    expect(recentRequests, 1);
    expect(proposal, isNotNull);
    expect(controller.memorySummary, isEmpty);
    expect(controller.recentMemories, isEmpty);
    proposal!.recent.single.summary = '双方确认明天采集素材';
    proposal.recent.single.translation =
        'They confirmed a gathering trip tomorrow.';
    proposal.newEntries.single['summary'] = '双方确认明天一起采集素材';
    proposal.newEntries.single['translation'] =
        'They confirmed a gathering trip tomorrow.';

    expect(proposal.commit(controller), isTrue);
    expect(
      controller.recentMemories.single,
      '双方确认明天采集素材\n译文：They confirmed a gathering trip tomorrow.',
    );
    final saved = MemoryTimeline.decode(controller.memorySummary)!;
    final entry = (saved['entries'] as List).single as Map;
    expect(entry['summary'], '双方确认明天一起采集素材');
    expect(entry['translation'], 'They confirmed a gathering trip tomorrow.');
    expect(controller.pendingRecentMemoryCount, 0);
    expect(proposal.commit(controller), isFalse);
  });

  test('stale manual proposal cannot replace a subsequent user edit', () async {
    final controller = await makeController();
    controller.addUserMessage('约好明天再见');
    final proposal = await ManualMemoryConsolidation().prepare(
      controller: controller,
      complete: (messages) async {
        final prompt = messages.first['content']!;
        if (prompt.contains('最近四轮对话')) {
          return '{"summary":"约好明天再见"}';
        }
        if (prompt.contains('从最近记忆中提炼')) {
          return '{"entries":[{"summary":"约好明天再见"}]}';
        }
        return '{"recent":[{"index":0,"translation":"Meet tomorrow."}],'
            '"entries":[{"sequence":1,"translation":"Meet tomorrow."}]}';
      },
    );
    controller.updateMemorySummary('用户手动修改的重要记忆');
    expect(proposal!.commit(controller), isFalse);
    expect(controller.memorySummary, '用户手动修改的重要记忆');
    expect(controller.recentMemories, isEmpty);
  });

  test('incomplete translations do not produce a review proposal', () async {
    final controller = await makeController();
    controller.addUserMessage('记住我们的约定');
    await expectLater(
      ManualMemoryConsolidation().prepare(
        controller: controller,
        complete: (messages) async {
          final prompt = messages.first['content']!;
          if (prompt.contains('最近四轮对话')) {
            return '{"summary":"双方许下约定"}';
          }
          if (prompt.contains('从最近记忆中提炼')) {
            return '{"entries":[{"summary":"双方许下约定"}]}';
          }
          return '{"recent":[],"entries":[]}';
        },
      ),
      throwsFormatException,
    );
    expect(controller.recentMemories, isEmpty);
    expect(controller.memorySummary, isEmpty);
  });

  test('a rejected long-term review leaves recent memory untouched', () async {
    final controller = await makeController();
    controller.updateMemorySummary(
      jsonEncode({
        'entries': [
          for (var index = 1; index <= 4; index++)
            {
              'date': '2026-09-25',
              'summary': '已确认的重要事实 $index',
              'translation': 'Previously confirmed fact $index',
            },
        ],
      }),
    );
    final original = controller.memorySummary;
    controller.addUserMessage('刚刚又谈了一件事');
    final proposal = await ManualMemoryConsolidation().prepare(
      controller: controller,
      complete: (messages) async {
        final prompt = messages.first['content']!;
        if (prompt.contains('最近四轮对话')) {
          return '{"summary":"刚刚谈了一件事"}';
        }
        if (prompt.contains('从最近记忆中提炼')) {
          return '{"entries":[]}';
        }
        return '{"recent":[{"index":0,"translation":"They discussed something."}],'
            '"entries":[]}';
      },
    );
    final entries = proposal!.document['entries'] as List;
    entries.removeRange(0, 3);
    expect(proposal.commit(controller), isFalse);
    expect(controller.recentMemories, isEmpty);
    expect(controller.memorySummary, original);
  });

  test('a protected old-entry rewrite fails without partially adding recent memory', () async {
    final controller = await makeController();
    controller.updateMemorySummary(
      jsonEncode({
        'entries': [
          {
            'sequence': 1,
            'summary': '[happy]角色的一句旧原话',
            'source': 'local_ledger',
          },
          {
            'sequence': 2,
            'summary': '用户亲自确认的重要约定',
            'translation': 'A promise confirmed by the user.',
            'source': 'manual',
          },
        ],
      }),
    );
    final original = controller.memorySummary;
    controller.addUserMessage('今天整理了一些素材');
    final proposal = await ManualMemoryConsolidation().prepare(
      controller: controller,
      complete: (messages) async {
        final prompt = messages.first['content']!;
        if (prompt.contains('最近四轮对话')) {
          return '{"summary":"用户整理了素材"}';
        }
        if (prompt.contains('从最近记忆中提炼')) {
          return '{"entries":[]}';
        }
        if (prompt.contains('重新整理旧版本地')) {
          return '{"entries":[{"sequence":1,"summary":"莱莎回应了用户。","category":"other","importance":1}]}';
        }
        return '{"recent":[{"index":0,"translation":"The user sorted materials."}],'
            '"entries":[{"sequence":1,"translation":"Ryza replied to the user."}]}';
      },
    );
    final entries = proposal!.document['entries'] as List;
    (entries.last as Map)['summary'] = '未经审阅的旧条目替换';
    expect(proposal.commit(controller), isFalse);
    expect(controller.memorySummary, original);
    expect(controller.recentMemories, isEmpty);
    expect(controller.lastRecentMemoryMessageId, isNull);
  });

  test('old local dialogue is repaired only after review, using full source', () async {
    final controller = await makeController();
    controller.addUserMessage('你的伙伴都是什么样的人？');
    controller.addAssistantMessage('莱莎：[happy]タオは本が大好きなんだ。');
    final sourceId = controller.messages.last.id;
    controller.updateMemorySummary(
      jsonEncode({
        'entries': [
          {
            'sequence': 1,
            'summary': '[happy]タオは本が大好',
            'source': 'local_ledger',
            'source_message_id': sourceId,
            'category': 'relationship_turning_point',
            'importance': 5,
          },
          {
            'sequence': 2,
            'summary': '用户手写的约定',
            'source': 'manual',
            'translation': 'A manually recorded promise.',
          },
        ],
      }),
    );
    controller.appendRecentMemory(
      '用户询问伙伴性格',
      lastMessageId: controller.messages.firstWhere((m) => m.isUser).id,
    );
    controller.longTermMemoryConsolidatedCount =
        controller.recentMemories.length;
    final original = controller.memorySummary;
    final proposal = await ManualMemoryConsolidation().prepare(
      controller: controller,
      complete: (messages) async {
        final input = jsonDecode(messages.last['content']!) as Map;
        if (messages.first['content']!.contains('重新整理旧版本地')) {
          final record = (input['entries'] as List).single as Map;
          expect(record['source_dialogue'], contains('タオは本が大好きなんだ'));
          expect(record['source_dialogue'], isNot(contains('[happy]')));
          return '{"entries":[{"sequence":1,"summary":"莱莎介绍了塔奥爱读书的特点。",'
              '"category":"other","importance":1}]}';
        }
        expect(input['recent'], isEmpty);
        expect(input['entries'], hasLength(1));
        return '{"recent":[],"entries":[{"sequence":1,"translation":"Ryza described Tao as a book lover."}]}';
      },
    );
    expect(controller.memorySummary, original);
    expect(proposal!.repairedEntrySequences, {1});
    expect(proposal.newEntries.single['summary'], '莱莎介绍了塔奥爱读书的特点。');
    expect(proposal.commit(controller), isTrue);
    final saved = MemoryTimeline.decode(controller.memorySummary)!;
    final entries = saved['entries'] as List;
    expect(entries[0]['category'], 'other');
    expect(entries[0]['summary'], '莱莎介绍了塔奥爱读书的特点。');
    expect(entries[0]['translation'], 'Ryza described Tao as a book lover.');
    expect(entries[0]['source_message_id'], sourceId);
    expect(entries[1]['summary'], '用户手写的约定');
    expect(proposal.commit(controller), isFalse);
  });

  test('manual missing translations can be filled without new dialogue', () async {
    final controller = await makeController();
    controller.updateMemorySummary(
      jsonEncode({
        'entries': [
          {'sequence': 1, 'summary': '用户与莱莎约好去海边', 'source': 'manual'},
        ],
      }),
    );
    final proposal = await ManualMemoryConsolidation().prepare(
      controller: controller,
      complete: (messages) async {
        expect(messages.first['content'], contains('只翻译'));
        return '{"recent":[],"entries":[{"sequence":1,"translation":"They agreed to go to the coast."}]}';
      },
    );
    expect(proposal!.repairedEntrySequences, isEmpty);
    expect(proposal.translationOnlyEntrySequences, {1});
    expect(proposal.commit(controller), isTrue);
    final entry =
        (MemoryTimeline.decode(controller.memorySummary)!['entries'] as List)
            .single;
    expect(entry['summary'], '用户与莱莎约好去海边');
    expect(entry['source'], 'manual');
    expect(entry['translation'], 'They agreed to go to the coast.');
  });

  test(
    'failed legacy repair keeps all memories and checkpoints untouched',
    () async {
      final controller = await makeController();
      controller.updateMemorySummary(
        jsonEncode({
          'entries': [
            {'sequence': 1, 'summary': '角色原话', 'source': 'local_ledger'},
          ],
        }),
      );
      final original = controller.memorySummary;
      await expectLater(
        ManualMemoryConsolidation().prepare(
          controller: controller,
          complete: (_) async => '{"entries":[]}',
        ),
        throwsFormatException,
      );
      expect(controller.memorySummary, original);
      expect(controller.recentMemories, isEmpty);
      expect(controller.lastRecentMemoryMessageId, isNull);
    },
  );

  test('legacy display ids recover once and map shuffled replies by source ref', () async {
    final controller = await makeController();
    controller.updateMemorySummary(
      jsonEncode({
        'entries': [
          {'sequence': 10, 'summary': '莱莎说塔奥爱读书', 'source': 'local_ledger'},
          {'sequence': 25, 'summary': '用户约好明天采集', 'source': 'local_ledger'},
          {
            'sequence': 40,
            'summary': '用户手写的重要事实',
            'source': 'manual',
            'translation': 'A fact confirmed by the user.',
          },
        ],
      }),
    );
    final original = controller.memorySummary;
    var repairRequests = 0;
    var notices = 0;
    final proposal = await ManualMemoryConsolidation().prepare(
      controller: controller,
      onLegacyNumberingRecovery: () => notices++,
      complete: (messages) async {
        final input = jsonDecode(messages.last['content']!) as Map;
        if (messages.first['content']!.contains('重新整理旧版本地')) {
          repairRequests++;
          if (repairRequests == 1) {
            expect((input['entries'] as List).first['sequence'], 10);
            return '{"entries":[{"sequence":"AM0001","summary":"错误编号"},'
                '{"sequence":2,"summary":"错误编号"}]}';
          }
          expect(notices, 1);
          final entries = input['entries'] as List;
          expect(
            entries.every((entry) => !(entry as Map).containsKey('sequence')),
            isTrue,
          );
          expect(entries.map((entry) => entry['source_ref']), [
            'legacy_1',
            'legacy_2',
          ]);
          return '{"entries":[{"source_ref":"legacy_2","summary":"双方约好明天采集。"},'
              '{"source_ref":"legacy_1","summary":"莱莎介绍塔奥爱读书。"}]}';
        }
        return '{"recent":[],"entries":[{"sequence":10,"translation":"Tao enjoys reading."},'
            '{"sequence":25,"translation":"They will gather tomorrow."}]}';
      },
    );
    expect(repairRequests, 2);
    expect(notices, 1);
    expect(proposal!.usedLegacyNumberingRecovery, isTrue);
    expect(controller.memorySummary, original);
    expect(proposal.repairedEntrySequences, {10, 25});
    expect(proposal.commit(controller), isTrue);
    final entries =
        MemoryTimeline.decode(controller.memorySummary)!['entries'] as List;
    expect(entries.map((entry) => entry['sequence']), [10, 25, 40]);
    expect(entries[0]['summary'], '莱莎介绍塔奥爱读书。');
    expect(entries[1]['summary'], '双方约好明天采集。');
    expect(entries[2]['summary'], '用户手写的重要事实');
    expect(entries[2]['source'], 'manual');
  });

  test(
    'legacy recovery never guesses duplicate or unknown references',
    () async {
      for (final invalid in [
        '{"entries":[{"source_ref":"unknown","summary":"不能保存"},'
            '{"source_ref":"legacy_2","summary":"第二条"}]}',
        '{"entries":[]}',
        '{"entries":[{"source_ref":"legacy_1","summary":"不能保存"},'
            '{"source_ref":"legacy_1","summary":"重复"}]}',
      ]) {
        final controller = await makeController();
        controller.updateMemorySummary(
          jsonEncode({
            'entries': [
              {'sequence': 15, 'summary': '保留的事实', 'source': 'local_ledger'},
              {'sequence': 35, 'summary': '另一条旧事实', 'source': 'local_ledger'},
            ],
          }),
        );
        final original = controller.memorySummary;
        var requests = 0;
        var notices = 0;
        await expectLater(
          ManualMemoryConsolidation().prepare(
            controller: controller,
            onLegacyNumberingRecovery: () => notices++,
            complete: (_) async => ++requests == 1
                ? '{"entries":[{"sequence":1,"summary":"旧编号"}]}'
                : invalid,
          ),
          throwsFormatException,
        );
        expect(requests, 2);
        expect(notices, 1);
        expect(controller.memorySummary, original);
        expect(controller.recentMemories, isEmpty);
        expect(controller.lastRecentMemoryMessageId, isNull);
      }
    },
  );

  test(
    'changing memory when notified cancels recovery before another request',
    () async {
      final controller = await makeController();
      controller.updateMemorySummary(
        jsonEncode({
          'entries': [
            {'sequence': 12, 'summary': '旧事实', 'source': 'local_ledger'},
          ],
        }),
      );
      var requests = 0;
      await expectLater(
        ManualMemoryConsolidation().prepare(
          controller: controller,
          onLegacyNumberingRecovery: () =>
              controller.updateMemorySummary('新的用户记忆'),
          complete: (_) async {
            requests++;
            return '{"entries":[{"sequence":1,"summary":"旧编号"}]}';
          },
        ),
        throwsStateError,
      );
      expect(requests, 1);
      expect(controller.memorySummary, '新的用户记忆');
    },
  );

  test(
    'later legacy batches use refs directly with only one extra request',
    () async {
      final controller = await makeController();
      controller.updateMemorySummary(
        jsonEncode({
          'entries': [
            for (var index = 1; index <= 9; index++)
              {
                'sequence': index * 10,
                'summary': '原有事实$index',
                'source': 'local_ledger',
              },
          ],
        }),
      );
      var repairs = 0;
      var notices = 0;
      final proposal = await ManualMemoryConsolidation().prepare(
        controller: controller,
        onLegacyNumberingRecovery: () => notices++,
        complete: (messages) async {
          final input = jsonDecode(messages.last['content']!) as Map;
          if (messages.first['content']!.contains('重新整理旧版本地')) {
            repairs++;
            if (repairs == 1) {
              return '{"entries":[{"sequence":1,"summary":"旧编号"}]}';
            }
            return jsonEncode({
              'entries': [
                for (final entry in input['entries'] as List)
                  {
                    'source_ref': entry['source_ref'],
                    'summary': entry['summary'],
                  },
              ],
            });
          }
          return jsonEncode({
            'recent': [],
            'entries': [
              for (final entry in input['entries'] as List)
                {
                  'sequence': entry['sequence'],
                  'translation': 'Confirmed fact.',
                },
            ],
          });
        },
      );
      expect(repairs, 3);
      expect(notices, 1);
      expect(proposal!.repairedEntrySequences, hasLength(9));
      expect(proposal.commit(controller), isTrue);
      expect(
        MemoryTimeline.decode(controller.memorySummary)!['entries'],
        hasLength(9),
      );
    },
  );

  test(
    'stale recovery response cannot translate or overwrite a changed save',
    () async {
      final controller = await makeController();
      controller.updateMemorySummary(
        jsonEncode({
          'entries': [
            {'sequence': 12, 'summary': '旧事实', 'source': 'local_ledger'},
          ],
        }),
      );
      var requests = 0;
      await expectLater(
        ManualMemoryConsolidation().prepare(
          controller: controller,
          complete: (_) async {
            requests++;
            if (requests == 1) {
              return '{"entries":[{"sequence":"AM0001","summary":"旧编号"}]}';
            }
            controller.updateMemorySummary('后来修改的当前记忆');
            return '{"entries":[{"source_ref":"legacy_1","summary":"迟到的结果"}]}';
          },
        ),
        throwsStateError,
      );
      expect(requests, 2);
      expect(controller.memorySummary, '后来修改的当前记忆');
      expect(controller.recentMemories, isEmpty);
    },
  );

  test('malformed JSON is not treated as a legacy numbering failure', () async {
    final controller = await makeController();
    controller.updateMemorySummary(
      jsonEncode({
        'entries': [
          {'sequence': 12, 'summary': '原有事实', 'source': 'local_ledger'},
        ],
      }),
    );
    final original = controller.memorySummary;
    var requests = 0;
    var notices = 0;
    await expectLater(
      ManualMemoryConsolidation().prepare(
        controller: controller,
        onLegacyNumberingRecovery: () => notices++,
        complete: (_) async {
          requests++;
          return 'not JSON';
        },
      ),
      throwsFormatException,
    );
    expect(requests, 1);
    expect(notices, 0);
    expect(controller.memorySummary, original);
  });

  test('valid legacy sequences need neither recovery nor notice', () async {
    final controller = await makeController();
    controller.updateMemorySummary(
      jsonEncode({
        'entries': [
          {'sequence': 22, 'summary': '用户喜欢红茶', 'source': 'local_ledger'},
        ],
      }),
    );
    var notices = 0;
    final proposal = await ManualMemoryConsolidation().prepare(
      controller: controller,
      onLegacyNumberingRecovery: () => notices++,
      complete: (messages) async =>
          messages.first['content']!.contains('重新整理旧版本地')
          ? '{"entries":[{"sequence":22,"summary":"用户喜欢红茶。"}]}'
          : '{"recent":[],"entries":[{"sequence":22,"translation":"The user likes tea."}]}',
    );
    expect(notices, 0);
    expect(proposal!.usedLegacyNumberingRecovery, isFalse);
  });
}
