import 'package:flutter/material.dart';

import 'app_controller.dart';

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
    final completed = AppController.missions
        .where(controller.isMissionComplete)
        .length;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: onMenuPressed,
          tooltip: '菜单',
          icon: const Icon(Icons.menu),
        ),
        title: const Text('欢迎任务'),
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
                          '$completed / ${AppController.missions.length} 已完成',
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
      color: Colors.white,
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
                    mission.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    mission.description,
                    style: const TextStyle(color: Colors.black54, fontSize: 13),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    '$progress / ${mission.target}  ·  奖励 ${mission.reward} 星',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
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
                          SnackBar(content: Text('获得 ${mission.reward} 星')),
                        );
                      }
                    : null,
                child: const Text('领取'),
              ),
          ],
        ),
      ),
    );
  }
}
