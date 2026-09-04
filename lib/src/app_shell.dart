import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'app_localization.dart';
import 'alarm_screen.dart';
import 'chat_screen.dart';
import 'glass_ui.dart';
import 'mission_screen.dart';
import 'settings_screen.dart';
import 'soundscape_controller.dart';
import 'world_map_screen.dart';

enum AppDestination { chat, worldMap, missions, alarms, settings, runtimeLogs }

extension AppDestinationData on AppDestination {
  String label(AppLanguage language) => switch (this) {
    AppDestination.chat => language.text('角色聊天', 'Character chat', 'キャラクター会話'),
    AppDestination.worldMap => language.text('世界地图', 'World map', 'ワールドマップ'),
    AppDestination.missions => language.text(
      '欢迎任务',
      'Welcome missions',
      'ウェルカムミッション',
    ),
    AppDestination.alarms => language.text('语音闹钟', 'Voice alarms', 'ボイスアラーム'),
    AppDestination.settings => language.text('设置', 'Settings', '設定'),
    AppDestination.runtimeLogs => language.text('运行日志', 'Runtime logs', '実行ログ'),
  };

  IconData get icon => switch (this) {
    AppDestination.chat => Icons.chat_bubble_outline,
    AppDestination.worldMap => Icons.map_outlined,
    AppDestination.missions => Icons.task_alt_outlined,
    AppDestination.alarms => Icons.alarm_outlined,
    AppDestination.settings => Icons.settings_outlined,
    AppDestination.runtimeLogs => Icons.bug_report_outlined,
  };
}

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _soundscape = SoundscapeController();
  AppDestination _destination = AppDestination.chat;

  @override
  void dispose() {
    _soundscape.dispose();
    super.dispose();
  }

  void _openMenu() => _scaffoldKey.currentState?.openDrawer();

  void _selectDestination(AppDestination value) {
    Navigator.maybePop(context);
    if (value == AppDestination.worldMap && _destination != value) {
      widget.controller.recordMapVisit();
    }
    setState(() => _destination = value);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _soundscape.sync(
            widget.controller,
            worldMapVisible: _destination == AppDestination.worldMap,
          );
        });
        return Scaffold(
          key: _scaffoldKey,
          drawer: _AppDrawer(
            selected: _destination,
            stars: widget.controller.stars,
            language: widget.controller.interfaceLanguage,
            liquidGlass: widget.controller.liquidGlassChatUi,
            onSelected: _selectDestination,
          ),
          body: IndexedStack(
            index: _destination.index,
            children: [
              ChatScreen(
                controller: widget.controller,
                onMenuPressed: _openMenu,
              ),
              WorldMapScreen(
                controller: widget.controller,
                onMenuPressed: _openMenu,
                onClose: () => _selectDestination(AppDestination.chat),
              ),
              MissionScreen(
                controller: widget.controller,
                onMenuPressed: _openMenu,
              ),
              AlarmScreen(
                controller: widget.controller,
                onMenuPressed: _openMenu,
              ),
              SettingsScreen(
                controller: widget.controller,
                onMenuPressed: _openMenu,
              ),
              RuntimeLogScreen(
                language: widget.controller.interfaceLanguage,
                onMenuPressed: _openMenu,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AppDrawer extends StatelessWidget {
  const _AppDrawer({
    required this.selected,
    required this.stars,
    required this.language,
    required this.liquidGlass,
    required this.onSelected,
  });

  final AppDestination selected;
  final int stars;
  final AppLanguage language;
  final bool liquidGlass;
  final ValueChanged<AppDestination> onSelected;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      width: MediaQuery.sizeOf(context).width.clamp(280, 360).toDouble(),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(22)),
      ),
      child: GlassSurface(
        liquidGlass: liquidGlass,
        tone: GlassTone.light,
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(22)),
        fallbackColor: const Color(0xF2F4F7F4),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 16, 18),
                child: Row(
                  children: [
                    const CircleAvatar(
                      radius: 25,
                      backgroundImage: AssetImage(
                        'assets/images/chara_icons/ryza.png',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Ryza Chat',
                            style: TextStyle(
                              color: Color(0xFF24302E),
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            language.text('本地原型', 'Local prototype', 'ローカル版'),
                            style: TextStyle(color: Color(0xA624302E)),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.52),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.star_rounded,
                            size: 17,
                            color: Color(0xFFFFD66B),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '$stars',
                            style: const TextStyle(color: Color(0xFF24302E)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0x2424302E)),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final destination in AppDestination.values)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: ListTile(
                          selected: destination == selected,
                          selectedTileColor: Colors.white.withValues(
                            alpha: 0.52,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                            side: destination == selected
                                ? const BorderSide(color: Color(0x2424302E))
                                : BorderSide.none,
                          ),
                          leading: Icon(
                            destination.icon,
                            color: const Color(0xFF334542),
                          ),
                          title: Text(
                            destination.label(language),
                            style: const TextStyle(color: Color(0xFF24302E)),
                          ),
                          onTap: () => onSelected(destination),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
                child: Text(
                  language.text(
                    'AI 与语音服务可在设置中配置',
                    'Configure AI and voice services in Settings',
                    'AIと音声サービスは設定から変更できます',
                  ),
                  style: const TextStyle(
                    color: Color(0xA624302E),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
