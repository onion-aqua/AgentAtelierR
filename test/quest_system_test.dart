import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/alchemy_models.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/mission_screen.dart';
import 'package:ryza_chat_mvp/src/quest_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'accepting a quest through structured speech creates a real commission',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load()
        ..setAgentEnabled(true);
      controller.addAssistantMessage('莱莎：有一个委托，和我聊一次炼金术，好吗？');
      controller.addUserMessage('旁白：我点头\n发言：好的\n旁白：露出微笑');
      final result = jsonDecode(
        controller.queryContextTool('create_quest', {
          'title': '聊炼金术',
          'description': '和莱莎交流一次。',
          'objective_type': 'chat',
          'target': 1,
          'authorization': 'user_accepted',
        }),
      );
      expect(result['ok'], isTrue);
      final quest = controller.dynamicQuests.single;
      controller.addUserMessage('发言：我们聊聊材料吧');
      expect(controller.isDynamicQuestComplete(quest), isTrue);
      expect(controller.claimDynamicQuest(quest.id), isTrue);
      controller.dispose();
    },
  );

  test('built-in story contains 20 localized sequential quests', () {
    expect(builtInStoryQuests, hasLength(20));
    expect(builtInStoryQuests.map((quest) => quest.id).toSet(), hasLength(20));
    for (final quest in builtInStoryQuests) {
      expect(quest.titleZh, isNotEmpty);
      expect(quest.titleEn, isNotEmpty);
      expect(quest.titleJa, isNotEmpty);
      expect(quest.descriptionZh, isNotEmpty);
      expect(quest.target, inInclusiveRange(1, 10));
      expect(quest.reward, greaterThan(0));
    }
  });

  test(
    'story quest starts from an upgrade-safe baseline and unlocks in order',
    () async {
      SharedPreferences.setMockInitialValues({'travel_count': 5});
      final controller = await AppController.load();
      final first = builtInStoryQuests.first;

      expect(controller.currentStoryQuest, same(first));
      expect(controller.storyQuestProgress(first), 0);
      expect(controller.claimStoryQuest(first.id), isFalse);

      controller.selectLocation(areaId: 'new', stageId: 'new');
      expect(controller.storyQuestProgress(first), 1);
      expect(controller.claimStoryQuest(first.id), isTrue);
      expect(controller.storyQuestIndex, 1);

      final second = builtInStoryQuests[1];
      expect(controller.currentStoryQuest, same(second));
      controller.addUserMessage('第一句话');
      expect(controller.storyQuestProgress(second), 1);
      expect(controller.claimStoryQuest(second.id), isFalse);
      controller.addUserMessage('第二句话');
      expect(controller.claimStoryQuest(second.id), isTrue);
      expect(controller.storyQuestIndex, 2);
    },
  );

  test(
    'current story quest is exposed to prompts and the quest tool',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load()
        ..setAgentEnabled(true);

      expect(controller.buildCharacterPrompt(), contains('当前内置主线 1/20：越过湖面'));
      final result = jsonDecode(
        controller.queryContextTool('inspect_quests', const {}),
      ) as Map<String, dynamic>;
      final story = result['main_story'] as Map<String, dynamic>;
      expect(story['total'], 20);
      expect(
        (story['current'] as Map<String, dynamic>)['id'],
        'story_01_cross_the_lake',
      );
    },
  );

  test('dynamic quests track chat, travel, gathering, and synthesis', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    final chat = controller.createDynamicQuest(
      title: '多聊聊',
      description: '再和莱莎说一句话。',
      objectiveType: QuestObjectiveType.chat,
      target: 1,
    );
    final travel = controller.createDynamicQuest(
      title: '踏出一步',
      description: '前往一个地点。',
      objectiveType: QuestObjectiveType.travel,
      target: 1,
    );
    final gather = controller.createDynamicQuest(
      title: '收集素材',
      description: '完成一次采集。',
      objectiveType: QuestObjectiveType.gather,
      target: 1,
    );
    final synthesis = controller.createDynamicQuest(
      title: '第一次调合',
      description: '完成一次调合。',
      objectiveType: QuestObjectiveType.synthesize,
      target: 1,
    );

    controller.addUserMessage('出发吧');
    controller.selectLocation(areaId: 'test', stageId: 'test_stage');
    controller.gatherAtCurrentLocation(
      random: Random(1),
      discoveries: const [
        GatherDiscovery(
          name: '测试叶片',
          description: '用于测试的柔软叶片。',
          categories: ['plant'],
        ),
      ],
    );
    final ingredient = controller.alchemyState.inventory.first;
    controller.synthesizeCustomItem(
      name: '测试护符',
      description: '明显属于幻想炼金的测试护符。',
      ingredientIds: [ingredient.instanceId],
      random: Random(2),
    );

    expect(controller.questProgress(chat), 1);
    expect(controller.questProgress(travel), 1);
    expect(controller.questProgress(gather), 1);
    expect(controller.questProgress(synthesis), 1);
  });

  test('quest rewards can only be claimed once', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    final quest = controller.createDynamicQuest(
      title: '说句话',
      description: '完成一次交流。',
      objectiveType: QuestObjectiveType.chat,
      target: 1,
    );

    expect(controller.claimDynamicQuest(quest.id), isFalse);
    controller.addUserMessage('你好');
    expect(controller.claimDynamicQuest(quest.id), isTrue);
    expect(controller.stars, quest.reward);
    expect(controller.claimDynamicQuest(quest.id), isFalse);
    expect(controller.stars, quest.reward);
  });

  test('quest list enforces the active limit', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    for (
      var index = 0;
      index < AppController.maxActiveDynamicQuests;
      index += 1
    ) {
      controller.createDynamicQuest(
        title: '任务 $index',
        description: '完成一次交流。',
        objectiveType: QuestObjectiveType.chat,
        target: 1,
      );
    }

    expect(
      () => controller.createDynamicQuest(
        title: '超额任务',
        description: '不应被加入。',
        objectiveType: QuestObjectiveType.chat,
        target: 1,
      ),
      throwsStateError,
    );
  });

  test(
    'quest tool requires actual user authorization and rejects duplicates',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load()
        ..setAgentEnabled(true);
      const args = {
        'title': '森林的小发现',
        'description': '在当前地点完成一次采集。',
        'objective_type': 'gather',
        'target': 1,
        'authorization': 'user_requested',
      };

      var result = jsonDecode(
        controller.queryContextTool('create_quest', args),
      );
      expect(result['ok'], isFalse);
      controller.addUserMessage('莱莎，给我想一个采集任务');
      result = jsonDecode(controller.queryContextTool('create_quest', args));
      expect(result['ok'], isTrue);
      result = jsonDecode(controller.queryContextTool('create_quest', args));
      expect(result['ok'], isFalse);
      expect(result['message'], contains('同名'));
    },
  );

  test('dynamic quests persist through preferences and local export', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    controller.createDynamicQuest(
      title: '远行准备',
      description: '移动两次。',
      objectiveType: QuestObjectiveType.travel,
      target: 2,
    );
    controller.selectLocation(areaId: 'one', stageId: 'one');
    expect(controller.claimStoryQuest(builtInStoryQuests.first.id), isTrue);
    await Future<void>.delayed(Duration.zero);

    final restored = await AppController.load();
    expect(restored.dynamicQuests.single.title, '远行准备');
    expect(restored.questProgress(restored.dynamicQuests.single), 1);
    expect(restored.storyQuestIndex, 1);

    final imported = await AppController.load();
    await imported.importData(controller.exportData());
    expect(imported.dynamicQuests.single.title, '远行准备');
    expect(imported.questProgress(imported.dynamicQuests.single), 1);
    expect(imported.storyQuestIndex, 1);
  });

  testWidgets('quest page separates the built-in story and Ryza quests', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = (await tester.runAsync(AppController.load))!;
    await tester.pumpWidget(
      MaterialApp(home: MissionScreen(controller: controller)),
    );
    expect(find.text('越过湖面'), findsOneWidget);
    expect(find.text('主线进度 0 / 20'), findsOneWidget);
    await tester.tap(find.text('莱莎委托'));
    await tester.pumpAndSettle();
    expect(find.text('还没有莱莎委托'), findsOneWidget);

    controller.createDynamicQuest(
      title: '聊聊炼金术',
      description: '和莱莎交流一次。',
      objectiveType: QuestObjectiveType.chat,
      target: 1,
    );
    await tester.pumpWidget(
      MaterialApp(home: MissionScreen(controller: controller)),
    );
    await tester.tap(find.text('莱莎委托'));
    await tester.pumpAndSettle();
    expect(find.text('聊聊炼金术'), findsOneWidget);
    expect(find.textContaining('0 / 1'), findsOneWidget);
  });
}
