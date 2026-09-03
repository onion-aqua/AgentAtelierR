import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_localization.dart';

class MissionScreen extends StatelessWidget {
  const MissionScreen({
    super.key,
    required this.controller,
    required this.onMenuPressed,
  });

  final AppController controller;
  final VoidCallback onMenuPressed;

  @override
  Widget build(BuildContext context) {
    final language = controller.interfaceLanguage;
    final completed = AppController.missions
        .where(controller.isMissionComplete)
        .length;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: onMenuPressed,
          tooltip: language.text('菜单', 'Menu', 'メニュー'),
          icon: const Icon(Icons.menu),
        ),
        title: Text(language.text('欢迎任务', 'Welcome missions', 'ウェルカムミッション')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Row(
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
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Stack(
              children: [
                SizedBox(
                  width: double.infinity,
                  height: 176,
                  child: Image.asset(
                    'assets/welcome_mission/bg.jpg',
                    fit: BoxFit.cover,
                  ),
                ),
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.32),
                  ),
                ),
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          language.text(
                            '$completed / ${AppController.missions.length} 已完成',
                            '$completed / ${AppController.missions.length} complete',
                            '$completed / ${AppController.missions.length} 完了',
                          ),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        LinearProgressIndicator(
                          value: completed / AppController.missions.length,
                          minHeight: 7,
                          borderRadius: BorderRadius.circular(4),
                          backgroundColor: Colors.white24,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 28),
            sliver: SliverList.separated(
              itemCount: AppController.missions.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final mission = AppController.missions[index];
                return _MissionTile(controller: controller, mission: mission);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MissionTile extends StatelessWidget {
  const _MissionTile({required this.controller, required this.mission});

  final AppController controller;
  final MissionDefinition mission;

  @override
  Widget build(BuildContext context) {
    final progress = mission.progressOf(controller).clamp(0, mission.target);
    final complete = controller.isMissionComplete(mission);
    final claimed = controller.claimedMissionIds.contains(mission.id);

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: claimed
                    ? const Color(0xFFE1EFEA)
                    : const Color(0xFFFFF0C7),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(
                claimed ? Icons.check_rounded : Icons.auto_awesome,
                color: claimed
                    ? const Color(0xFF2D796A)
                    : const Color(0xFFB57012),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _missionTitle(mission.id, controller.interfaceLanguage),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _missionDescription(
                      mission.id,
                      controller.interfaceLanguage,
                    ),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    controller.interfaceLanguage.text(
                      '$progress / ${mission.target}  ·  奖励 ${mission.reward} 星',
                      '$progress / ${mission.target}  ·  ${mission.reward} stars',
                      '$progress / ${mission.target}  ·  ${mission.reward}スター',
                    ),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (claimed)
              const Icon(Icons.verified_rounded, color: Color(0xFF2D796A))
            else
              FilledButton.tonal(
                onPressed: complete
                    ? () {
                        controller.claimMission(mission);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              controller.interfaceLanguage.text(
                                '获得 ${mission.reward} 星',
                                'Earned ${mission.reward} stars',
                                '${mission.reward}スターを獲得',
                              ),
                            ),
                          ),
                        );
                      }
                    : null,
                child: Text(
                  controller.interfaceLanguage.text('领取', 'Claim', '受け取る'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _missionTitle(String id, AppLanguage language) => switch (id) {
  'touch_character' => language.text('打个招呼', 'Say hello', 'あいさつする'),
  'first_chat' => language.text('开始聊天', 'Start chatting', '会話を始める'),
  'open_map' => language.text('查看世界', 'View the world', '世界を見る'),
  'travel' => language.text('选择目的地', 'Choose a destination', '目的地を選ぶ'),
  'scene_time' => language.text('改变时间', 'Change the time', '時間を変える'),
  _ => id,
};

String _missionDescription(String id, AppLanguage language) => switch (id) {
  'touch_character' => language.text(
    '点击莱莎触发一次互动',
    'Tap Ryza once',
    'ライザをタップして交流する',
  ),
  'first_chat' => language.text(
    '向莱莎发送第一条消息',
    'Send Ryza your first message',
    'ライザに最初のメッセージを送る',
  ),
  'open_map' => language.text('打开世界地图', 'Open the world map', 'ワールドマップを開く'),
  'travel' => language.text(
    '在地图中选择一个地点',
    'Choose a location on the map',
    'マップで場所を選ぶ',
  ),
  'scene_time' => language.text(
    '手动切换一次场景时间',
    'Change the scene time once',
    'シーンの時間を変更する',
  ),
  _ => id,
};
