import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_localization.dart';
import 'glass_ui.dart';
import 'quest_models.dart';

class MissionScreen extends StatelessWidget {
  const MissionScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final language = controller.interfaceLanguage;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: glassPageHeaderColor(context),
          automaticallyImplyLeading: false,
          title: Padding(
            padding: const EdgeInsets.only(left: 58),
            child: Text(language.text('任务', 'Quests', 'クエスト')),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.star_rounded, color: Color(0xFFE39B28)),
                    const SizedBox(width: 4),
                    Text(
                      '${controller.stars}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(text: language.text('主线', 'Story', 'メイン')),
              Tab(text: language.text('莱莎委托', 'Ryza quests', 'ライザの依頼')),
            ],
          ),
        ),
        body: GlassPageSurface(
          liquidGlass: controller.liquidGlassChatUi,
          child: TabBarView(
            children: [
              _StoryQuestList(controller: controller),
              _DynamicQuestList(controller: controller),
            ],
          ),
        ),
      ),
    );
  }
}

class _StoryQuestList extends StatelessWidget {
  const _StoryQuestList({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final language = controller.interfaceLanguage;
    return ListView(
      key: const PageStorageKey('story-quests'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          language.text(
            '主线进度 ${controller.storyQuestIndex} / ${builtInStoryQuests.length}',
            'Story ${controller.storyQuestIndex} / ${builtInStoryQuests.length}',
            'メイン進行 ${controller.storyQuestIndex} / ${builtInStoryQuests.length}',
          ),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: controller.storyQuestIndex / builtInStoryQuests.length,
          minHeight: 7,
          borderRadius: BorderRadius.circular(4),
        ),
        const SizedBox(height: 8),
        Text(
          language.text(
            '以《莱莎的炼金工房 1》的主要旅程为灵感重新概括，不复制原作任务文本。',
            'An original condensed progression inspired by Atelier Ryza 1, without copied quest text.',
            '「ライザのアトリエ1」の旅を着想に再構成した、原文を複製しない進行です。',
          ),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 14),
        for (var index = 0; index < builtInStoryQuests.length; index++) ...[
          _StoryQuestCard(
            controller: controller,
            quest: builtInStoryQuests[index],
            index: index,
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _StoryQuestCard extends StatelessWidget {
  const _StoryQuestCard({
    required this.controller,
    required this.quest,
    required this.index,
  });

  final AppController controller;
  final StoryQuestDefinition quest;
  final int index;

  @override
  Widget build(BuildContext context) {
    final language = controller.interfaceLanguage;
    final colorScheme = Theme.of(context).colorScheme;
    final claimed = index < controller.storyQuestIndex;
    final active = index == controller.storyQuestIndex;
    final locked = index > controller.storyQuestIndex;
    final progress = controller.storyQuestProgress(quest);
    final complete = active && controller.isStoryQuestComplete(quest);
    final status = claimed
        ? language.text('已完成', 'Complete', '完了')
        : locked
        ? language.text('未解锁', 'Locked', '未解放')
        : complete
        ? language.text('可领取', 'Ready', '受取可能')
        : language.text('进行中', 'Active', '進行中');
    return Opacity(
      opacity: locked ? 0.58 : 1,
      child: GlassSurface(
        liquidGlass: controller.liquidGlassChatUi,
        tone: Theme.of(context).brightness == Brightness.dark
            ? GlassTone.dark
            : GlassTone.light,
        borderRadius: BorderRadius.circular(18),
        fallbackColor: colorScheme.surfaceContainer.withValues(alpha: 0.66),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 17,
                    backgroundColor: claimed
                        ? const Color(0xFF4F8B78)
                        : active
                        ? colorScheme.primary
                        : colorScheme.surfaceContainerHighest,
                    foregroundColor: claimed || active
                        ? colorScheme.onPrimary
                        : colorScheme.onSurfaceVariant,
                    child: claimed
                        ? const Icon(Icons.check_rounded, size: 20)
                        : locked
                        ? const Icon(Icons.lock_outline_rounded, size: 18)
                        : Text('${index + 1}'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      quest.title(language),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    status,
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                quest.description(language),
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: locked ? 0 : progress / quest.target,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Text(
                          '${quest.objectiveType.label(language)}  $progress / ${quest.target}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        Text(
                          language.text(
                            '奖励 ${quest.reward} 星',
                            '${quest.reward} stars',
                            '報酬 ${quest.reward} スター',
                          ),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  if (active)
                    FilledButton.tonalIcon(
                      onPressed: complete
                          ? () {
                              if (!controller.claimStoryQuest(quest.id)) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    language.text(
                                      '主线推进，获得 ${quest.reward} 星',
                                      'Story advanced. Earned ${quest.reward} stars',
                                      'メイン進行。${quest.reward} スターを獲得',
                                    ),
                                  ),
                                ),
                              );
                            }
                          : null,
                      icon: const Icon(Icons.star_rounded),
                      label: Text(language.text('完成', 'Complete', '完了')),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DynamicQuestList extends StatelessWidget {
  const _DynamicQuestList({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final language = controller.interfaceLanguage;
    final quests = controller.dynamicQuests;
    final unclaimed = quests.where((quest) => !quest.isClaimed).length;
    if (quests.isEmpty) return _EmptyQuestState(language: language);
    return ListView(
      key: const PageStorageKey('dynamic-quests'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          language.text(
            '进行中 $unclaimed / ${AppController.maxActiveDynamicQuests}',
            'Active $unclaimed / ${AppController.maxActiveDynamicQuests}',
            '進行中 $unclaimed / ${AppController.maxActiveDynamicQuests}',
          ),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        for (final quest in quests) ...[
          _DynamicQuestCard(controller: controller, quest: quest),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _EmptyQuestState extends StatelessWidget {
  const _EmptyQuestState({required this.language});

  final AppLanguage language;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.assignment_outlined,
            size: 56,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 14),
          Text(
            language.text('还没有莱莎委托', 'No Ryza quests yet', 'ライザの依頼はまだありません'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            language.text(
              '开启 AI 接口中的联网 Agent，然后在聊天中说“给我一个委托”，或接受莱莎提出的任务。工具创建成功后会显示在这里；采集、调合、旅行或交流会自动记录进度。',
              'Enable Agent in AI settings, then ask Ryza for a quest or accept her proposal. Quests appear here after successful tool creation; gathering, synthesis, travel and conversation update progress automatically.',
              'AI設定のAgentを有効にして「依頼を作って」と話しかけるか、ライザの提案を受けてください。ツールで作成された依頼がここに表示され、採取・調合・移動・会話で進行します。',
            ),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

class _DynamicQuestCard extends StatelessWidget {
  const _DynamicQuestCard({required this.controller, required this.quest});

  final AppController controller;
  final DynamicQuest quest;

  Future<void> _confirmRemove(BuildContext context) async {
    final language = controller.interfaceLanguage;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(language.text('放弃任务？', 'Abandon quest?', 'クエストを破棄しますか？')),
        content: Text(quest.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(language.text('取消', 'Cancel', 'キャンセル')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(language.text('放弃', 'Abandon', '破棄')),
          ),
        ],
      ),
    );
    if (confirmed == true) controller.removeDynamicQuest(quest.id);
  }

  @override
  Widget build(BuildContext context) {
    final language = controller.interfaceLanguage;
    final progress = controller.questProgress(quest);
    final complete = controller.isDynamicQuestComplete(quest);
    final claimed = quest.isClaimed;
    final colorScheme = Theme.of(context).colorScheme;
    final status = claimed
        ? language.text('已领取', 'Claimed', '受取済み')
        : complete
        ? language.text('可领取', 'Ready', '受取可能')
        : language.text('进行中', 'Active', '進行中');
    return GlassSurface(
      liquidGlass: controller.liquidGlassChatUi,
      tone: Theme.of(context).brightness == Brightness.dark
          ? GlassTone.dark
          : GlassTone.light,
      borderRadius: BorderRadius.circular(18),
      fallbackColor: colorScheme.surfaceContainer.withValues(alpha: 0.66),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  claimed ? Icons.task_alt_rounded : Icons.assignment_outlined,
                  color: claimed
                      ? const Color(0xFF4F8B78)
                      : colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    quest.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  status,
                  style: TextStyle(
                    color: claimed
                        ? const Color(0xFF4F8B78)
                        : colorScheme.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              quest.description,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: progress / quest.target,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '${quest.objectiveType.label(language)}  $progress / ${quest.target}',
                  style: const TextStyle(fontSize: 12),
                ),
                Text(
                  language.text(
                    '奖励 ${quest.reward} 星',
                    '${quest.reward} stars',
                    '報酬 ${quest.reward} スター',
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  onPressed: () => _confirmRemove(context),
                  tooltip: language.text('放弃任务', 'Abandon quest', 'クエストを破棄'),
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
                if (!claimed)
                  FilledButton.tonalIcon(
                    onPressed: complete
                        ? () {
                            if (!controller.claimDynamicQuest(quest.id)) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  language.text(
                                    '获得 ${quest.reward} 星',
                                    'Earned ${quest.reward} stars',
                                    '${quest.reward} スターを獲得',
                                  ),
                                ),
                              ),
                            );
                          }
                        : null,
                    icon: const Icon(Icons.star_rounded),
                    label: Text(language.text('领取', 'Claim', '受け取る')),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
