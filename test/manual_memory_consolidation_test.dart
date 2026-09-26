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
    controller.updateMemorySummary(jsonEncode({
      'entries': [
        for (var index = 1; index <= 4; index++)
          {
            'date': '2026-09-25',
            'summary': '已确认的重要事实 $index',
          },
      ],
    }));
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
}
