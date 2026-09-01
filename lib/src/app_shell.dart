import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'alarm_screen.dart';
import 'chat_screen.dart';
import 'mission_screen.dart';
import 'settings_screen.dart';
import 'soundscape_controller.dart';
import 'world_map_screen.dart';

enum AppDestination { chat, worldMap, missions, alarms, settings }

extension AppDestinationData on AppDestination {
  String get label => switch (this) {
    AppDestination.chat => '角色聊天',
    AppDestination.worldMap => '世界地图',
    AppDestination.missions => '欢迎任务',
    AppDestination.alarms => '语音闹钟',
    AppDestination.settings => '设置',
  };

  IconData get icon => switch (this) {
    AppDestination.chat => Icons.chat_bubble_outline,
    AppDestination.worldMap => Icons.map_outlined,
    AppDestination.missions => Icons.task_alt_outlined,
    AppDestination.alarms => Icons.alarm_outlined,
    AppDestination.settings => Icons.settings_outlined,
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
          _soundscape.sync(widget.controller);
        });
        return Scaffold(
          key: _scaffoldKey,
          drawer: _AppDrawer(
            selected: _destination,
            stars: widget.controller.stars,
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
              ),
              MissionScreen(
                controller: widget.controller,
                onMenuPressed: _openMenu,
              ),
              AlarmScreen(onMenuPressed: _openMenu),
              SettingsScreen(
                controller: widget.controller,
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
    required this.onSelected,
  });

  final AppDestination selected;
  final int stars;
  final ValueChanged<AppDestination> onSelected;

  @override
  Widget build(BuildContext context) {
    return NavigationDrawer(
      selectedIndex: selected.index,
      onDestinationSelected: (index) =>
          onSelected(AppDestination.values[index]),
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
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ryza Chat',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text('本地原型', style: TextStyle(color: Colors.black54)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFE8A6),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.star_rounded, size: 17),
                    const SizedBox(width: 3),
                    Text('$stars'),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        const SizedBox(height: 8),
        for (final destination in AppDestination.values)
          NavigationDrawerDestination(
            icon: Icon(destination.icon),
            selectedIcon: Icon(destination.icon, fill: 1),
            label: Text(destination.label),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 24, 24, 12),
          child: Text(
            'AI 与 Fish Audio 可在设置中配置',
            style: TextStyle(color: Colors.black45, fontSize: 12),
          ),
        ),
      ],
    );
  }
}
