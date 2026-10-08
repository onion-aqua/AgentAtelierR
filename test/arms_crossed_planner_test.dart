import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/character_motion_semantics.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/independent_performance_tools.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final groups = parseCharacterMotionGroups(
    File(
      'assets/character/ryza/crf_skn_002_0001_01/crf_skn_002_0001_01_gesture.json',
    ).readAsStringSync(),
  );
  String description(String id) => characterMotionPromptDescription(
    groups.firstWhere((group) => group.id == id),
  );
  CharacterPerformancePromptContext capabilities(
    Map<String, String> catalogue,
  ) => CharacterPerformancePromptContext(
    appearanceId: 'seated_01',
    posture: 'sitting_normal',
    revision: 1,
    resourcesReady: true,
    playableActionDescriptions: const {},
    playableMotionGroupDescriptions: catalogue,
  );
  const source =
      '旁白：莱莎听话地挺直身子，准备在胸前抱起双臂，带着一点得意的笑意看向你。\n'
      '莱莎：こんな感じかな？ちょっと格好よく見えるでしょ、相棒。\n'
      '译文：大概是这样吧？看起来是不是有点帅气，伙伴。';
  final catalogue = {
    'grp_b_05': description('grp_b_05'),
    for (var i = 0; i < 100; i++)
      'grp_recipe_decoy_$i': '双手放在胸前，身体挺直，带着得意笑意；occupancy=FG',
  };

  test('screenshot request exposes the real crossed-arms candidate on the first call', () async {
    var calls = 0;
    final result = await ActionPlannerTool().plan(
      userInput: '请在胸前抱起双臂。',
      source: source,
      ids: [1],
      capabilities: capabilities(catalogue),
      recentActions: ['grp_b_05'],
      complete: (messages) async {
        calls++;
        final input = jsonDecode(messages.last['content']!) as Map;
        expect(input['line_ids'], [1]);
        final candidates = input['candidates'] as Map;
        expect(candidates['grp_b_05'], contains('双臂在胸前交叉抱臂'));
        expect(input['incomplete_candidates'], isNot(contains('grp_b_05')));
        expect(candidates.length, lessThanOrEqualTo(17));
        expect(messages.first['content'], contains('允许同一姿势的常用同义表达'));
        return '{"segments":[{"id":1,"action":"grp_b_05","match":"exact","reason":"胸前双臂交叉抱臂"}]}';
      },
    );
    expect(calls, 1);
    expect(result, {1: '[action:grp_b_05]'});
  });

  test('a refused quoted or past request stays none even when crossed arms is retrieved', () async {
    for (final input in ['不要抱臂。', '你以前抱臂是什么样？', '他说“请抱臂”，我没有要求你做。']) {
      final result = await ActionPlannerTool().plan(
        userInput: input,
        source: '莱莎：嗯，我保持现在的姿势。',
        ids: [0],
        capabilities: capabilities({'grp_b_05': description('grp_b_05')}),
        recentActions: const [],
        complete: (_) async => '{"segments":[{"id":0,"action":"none","match":"none","reason":"没有接受新的动作要求"}]}',
      );
      expect(result, {0: '[action:none]'});
    }
  });

  test(
    'sleeve-tucked hands never get locally upgraded into crossed arms',
    () async {
      final result = await ActionPlannerTool().plan(
        userInput: '把双手揣进对方袖口里面。',
        source: '莱莎：这套服装没有这种袖口。',
        ids: [0],
        capabilities: capabilities({'grp_b_05': description('grp_b_05')}),
        recentActions: const [],
        complete: (_) async => '{"segments":[{"id":0,"action":"none","match":"unsupported","reason":"当前抱臂不等于把手藏进袖口"}]}',
      );
      expect(result, {0: '[action:none]'});
    },
  );

  test('a mistaken unsupported result can be repaired within one wider retry', () async {
    var calls = 0;
    final result = await ActionPlannerTool().plan(
      userInput: '胸前交叉抱臂。',
      source: source,
      ids: [1],
      capabilities: capabilities(catalogue),
      recentActions: const [],
      complete: (messages) async {
        calls++;
        final input = jsonDecode(messages.last['content']!) as Map;
        expect((input['candidates'] as Map).containsKey('grp_b_05'), isTrue);
        if (calls == 1) {
          return '{"segments":[{"id":1,"action":"none","match":"unsupported","reason":"需要重新核对抱臂姿势"}],"search_query":"双臂胸前交叉抱臂"}';
        }
        expect(input['can_expand'], isFalse);
        return '{"segments":[{"id":1,"action":"grp_b_05","match":"exact","reason":"确认当前资源为交叉抱臂"}]}';
      },
    );
    expect(calls, 2);
    expect(result, {1: '[action:grp_b_05]'});
  });

  test('hands placed at chest cannot stand in for missing crossed arms', () async {
    final result = await ActionPlannerTool().plan(
      userInput: '胸前交叉抱臂。',
      source: source,
      ids: [1],
      capabilities: capabilities({'grp_b_07': description('grp_b_07')}),
      recentActions: const [],
      complete: (messages) async {
        final candidates =
            jsonDecode(messages.last['content']!)['candidates'] as Map;
        expect(candidates.containsKey('grp_b_05'), isFalse);
        expect(candidates.containsKey('grp_fg_023'), isFalse);
        return '{"segments":[{"id":1,"action":"none","match":"unsupported","reason":"双手放胸前不能替代双臂交叉"}]}';
      },
    );
    expect(result, {1: '[action:none]'});
  });
}
