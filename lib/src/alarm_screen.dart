import 'dart:async';

import 'package:alarm/alarm.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class AlarmScreen extends StatefulWidget {
  const AlarmScreen({super.key, required this.onMenuPressed});

  final VoidCallback onMenuPressed;

  @override
  State<AlarmScreen> createState() => _AlarmScreenState();
}

class _AlarmScreenState extends State<AlarmScreen> {
  List<AlarmSettings> _alarms = const [];
  StreamSubscription<dynamic>? _subscription;

  @override
  void initState() {
    super.initState();
    _refresh();
    _subscription = Alarm.scheduled.listen((_) => _refresh());
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final alarms = await Alarm.getAlarms();
    alarms.sort((a, b) => a.dateTime.compareTo(b.dateTime));
    if (mounted) setState(() => _alarms = alarms);
  }

  Future<void> _addAlarm() async {
    await Permission.notification.request();
    final exactAlarmStatus = await Permission.scheduleExactAlarm.request();
    if (!exactAlarmStatus.isGranted && !exactAlarmStatus.isLimited) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('需要“闹钟和提醒”权限才能准时响铃')));
      return;
    }

    if (!mounted) return;
    final now = DateTime.now();
    final selected = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 1))),
      helpText: '选择响铃时间',
    );
    if (selected == null) return;
    var dateTime = DateTime(
      now.year,
      now.month,
      now.day,
      selected.hour,
      selected.minute,
    );
    if (!dateTime.isAfter(now)) {
      dateTime = dateTime.add(const Duration(days: 1));
    }

    final settings = AlarmSettings(
      id: DateTime.now().millisecondsSinceEpoch.remainder(1000000000),
      dateTime: dateTime,
      assetAudioPath: 'assets/audio/alarm/alarm_ring.m4a',
      loopAudio: true,
      vibrate: true,
      androidFullScreenIntent: true,
      volumeSettings: VolumeSettings.fade(
        volume: 0.85,
        fadeDuration: const Duration(seconds: 4),
      ),
      androidSnoozeDuration: const Duration(minutes: 5),
      notificationSettings: const NotificationSettings(
        title: '莱莎来叫你了',
        body: '约定的时间到了，快醒醒吧。',
        stopButton: '停止',
        androidSnoozeButton: '稍后提醒',
        androidStopAlarmOnDismiss: false,
      ),
    );
    final success = await Alarm.set(alarmSettings: settings);
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(success ? '闹钟已设置' : '闹钟设置失败')));
  }

  Future<void> _deleteAlarm(AlarmSettings settings) async {
    await Alarm.stop(settings.id);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: widget.onMenuPressed,
          tooltip: '菜单',
          icon: const Icon(Icons.menu),
        ),
        title: const Text('语音闹钟'),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addAlarm,
        tooltip: '添加闹钟',
        child: const Icon(Icons.add_alarm_outlined),
      ),
      body: _alarms.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.alarm_off_outlined,
                    size: 48,
                    color: Colors.black38,
                  ),
                  SizedBox(height: 12),
                  Text('还没有闹钟', style: TextStyle(fontSize: 18)),
                  SizedBox(height: 5),
                  Text('添加后可在锁屏状态响铃', style: TextStyle(color: Colors.black54)),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              itemCount: _alarms.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final alarm = _alarms[index];
                final time = TimeOfDay.fromDateTime(alarm.dateTime)
                    .format(context);
                return Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  child: ListTile(
                    contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                    leading: const Icon(Icons.alarm_on_outlined),
                    title: Text(
                      time,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(_dateLabel(alarm.dateTime)),
                    trailing: IconButton(
                      onPressed: () => _deleteAlarm(alarm),
                      tooltip: '删除闹钟',
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ),
                );
              },
            ),
    );
  }

  String _dateLabel(DateTime value) =>
      '${value.month}月${value.day}日 · 循环语音 · 振动';
}
