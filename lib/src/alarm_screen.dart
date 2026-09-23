import 'dart:async';

import 'package:alarm/alarm.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_controller.dart';
import 'app_localization.dart';
import 'alarm_audio.dart';
import 'glass_ui.dart';
import 'runtime_log.dart';

class AlarmScreen extends StatefulWidget {
  const AlarmScreen({
    super.key,
    required this.controller,
    required this.onMenuPressed,
  });

  final AppController controller;
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
    final language = widget.controller.interfaceLanguage;
    await Permission.notification.request();
    final exactAlarmStatus = await Permission.scheduleExactAlarm.request();
    if (!exactAlarmStatus.isGranted && !exactAlarmStatus.isLimited) {
      RuntimeLog.instance.warning('Alarm', '精确闹钟权限未授予');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            language.text(
              '需要“闹钟和提醒”权限才能准时响铃',
              'Alarm permission is required to ring on time',
              '正確な時刻に鳴らすにはアラーム権限が必要です',
            ),
          ),
        ),
      );
      return;
    }

    if (!mounted) return;
    final now = DateTime.now();
    final selectedDuration = await _pickAlarmTime(now, language);
    if (selectedDuration == null) return;
    final selected = TimeOfDay(
      hour: selectedDuration.inHours,
      minute: selectedDuration.inMinutes.remainder(60),
    );
    var dateTime = DateTime(
      now.year,
      now.month,
      now.day,
      selected.hour,
      selected.minute,
      selectedDuration.inSeconds.remainder(60),
    );
    if (!dateTime.isAfter(now)) {
      dateTime = dateTime.add(const Duration(days: 1));
    }
    if (!mounted) return;
    final reminderType = await _selectReminderType(language);
    if (reminderType == null) return;

    final alarmId = DateTime.now().millisecondsSinceEpoch.remainder(1000000000);
    final audioAsset = alarmVoiceAsset(
      language: widget.controller.characterReplyLanguage,
      type: reminderType,
      asmr: widget.controller.asmrModeEnabled,
      hour: selected.hour,
      variantSeed: alarmId,
    );

    final settings = AlarmSettings(
      id: alarmId,
      dateTime: dateTime,
      assetAudioPath: audioAsset,
      loopAudio: true,
      vibrate: true,
      androidFullScreenIntent: true,
      volumeSettings: VolumeSettings.fade(
        volume: 0.85,
        fadeDuration: const Duration(seconds: 4),
      ),
      androidSnoozeDuration: const Duration(minutes: 5),
      notificationSettings: NotificationSettings(
        title: language.text(
          '莱莎的${reminderType.label(language)}',
          'Ryza: ${reminderType.label(language)}',
          'ライザ・${reminderType.label(language)}',
        ),
        body: reminderType.description(language),
        stopButton: language.text('停止', 'Stop', '停止'),
        androidSnoozeButton: language.text('稍后提醒', 'Snooze', 'スヌーズ'),
        androidStopAlarmOnDismiss: false,
      ),
    );
    final success = await Alarm.set(alarmSettings: settings);
    if (success) {
      RuntimeLog.instance.info(
        'Alarm',
        '闹钟设置成功，时间=${dateTime.toIso8601String()} '
            '类型=${reminderType.name} 语音=$audioAsset',
      );
    } else {
      RuntimeLog.instance.warning('Alarm', 'Alarm.set 返回失败');
    }
    await _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(success ? '闹钟已设置' : '闹钟设置失败')));
  }

  Future<Duration?> _pickAlarmTime(DateTime now, AppLanguage language) {
    final target = now.add(const Duration(minutes: 1));
    var selected = Duration(
      hours: target.hour,
      minutes: target.minute,
      seconds: 0,
    );
    final dark = Theme.of(context).brightness == Brightness.dark;
    return showDialog<Duration>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
        child: GlassSurface(
          liquidGlass: widget.controller.liquidGlassChatUi,
          tone: dark ? GlassTone.dark : GlassTone.light,
          fallbackColor: dark
              ? const Color(0xE824282C)
              : const Color(0xE8F1F3F4),
          borderRadius: BorderRadius.circular(26),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    language.text('选择响铃时间', 'Choose alarm time', 'アラーム時刻を選択'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 190,
                  child: CupertinoTheme(
                    data: CupertinoThemeData(
                      brightness: Theme.of(dialogContext).brightness,
                      textTheme: CupertinoTextThemeData(
                        dateTimePickerTextStyle: TextStyle(
                          color: Theme.of(dialogContext).colorScheme.onSurface,
                          fontSize: 25,
                        ),
                      ),
                    ),
                    child: CupertinoTimerPicker(
                      mode: CupertinoTimerPickerMode.hms,
                      initialTimerDuration: selected,
                      onTimerDurationChanged: (value) => selected = value,
                    ),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: Text(language.text('取消', 'Cancel', 'キャンセル')),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, selected),
                      child: Text(language.text('确定', 'OK', '決定')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _deleteAlarm(AlarmSettings settings) async {
    await Alarm.stop(settings.id);
    RuntimeLog.instance.info('Alarm', '闹钟已删除，id=${settings.id}');
    await _refresh();
  }

  Future<AlarmReminderType?> _selectReminderType(AppLanguage language) {
    final whisper = widget.controller.asmrModeEnabled;
    return showDialog<AlarmReminderType>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(language.text('选择提醒类型', 'Reminder type', 'リマインダー種類')),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              whisper
                  ? language.text(
                      '当前 ASMR 模式：使用耳语闹钟',
                      'ASMR mode: whisper alarm voice',
                      'ASMR モード：ささやきボイス',
                    )
                  : language.text(
                      '当前普通模式：使用普通闹钟',
                      'Normal mode: regular alarm voice',
                      '通常モード：通常ボイス',
                    ),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
          for (final type in AlarmReminderType.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, type),
              child: Row(
                children: [
                  Icon(_reminderIcon(type)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(type.label(language)),
                        const SizedBox(height: 2),
                        Text(
                          type.description(language),
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  IconData _reminderIcon(AlarmReminderType type) => switch (type) {
    AlarmReminderType.goodMorning => Icons.wb_sunny_outlined,
    AlarmReminderType.playWithMe => Icons.favorite_border_rounded,
    AlarmReminderType.task => Icons.task_alt_rounded,
    AlarmReminderType.wellDone => Icons.celebration_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final language = widget.controller.interfaceLanguage;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: glassPageHeaderColor(context),
        automaticallyImplyLeading: false,
        title: Padding(
          padding: const EdgeInsets.only(left: 58),
          child: Text(language.text('语音闹钟', 'Voice alarms', 'ボイスアラーム')),
        ),
      ),
      floatingActionButton: GlassIconButton(
        liquidGlass: widget.controller.liquidGlassChatUi,
        onPressed: _addAlarm,
        tooltip: language.text('添加闹钟', 'Add alarm', 'アラームを追加'),
        icon: Icons.add_alarm_outlined,
        size: 52,
      ),
      body: GlassPageSurface(
        liquidGlass: widget.controller.liquidGlassChatUi,
        child: _alarms.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.alarm_off_outlined,
                      size: 48,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    SizedBox(height: 12),
                    Text(
                      language.text('还没有闹钟', 'No alarms yet', 'アラームはありません'),
                      style: const TextStyle(fontSize: 18),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      language.text(
                        '添加后可在锁屏状态响铃',
                        'Alarms can ring while the screen is locked',
                        'ロック画面でもアラームを鳴らせます',
                      ),
                    ),
                  ],
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                itemCount: _alarms.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final alarm = _alarms[index];
                  final audioAsset = alarm.assetAudioPath ?? '';
                  final reminderType = alarmReminderTypeFromAsset(audioAsset);
                  final time = TimeOfDay.fromDateTime(alarm.dateTime)
                      .format(context);
                  return GlassContentCard(
                    liquidGlass: widget.controller.liquidGlassChatUi,
                    child: ListTile(
                      contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      leading: Icon(_reminderIcon(reminderType)),
                      title: Text(
                        time,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        '${reminderType.label(language)} · '
                        '${alarmAssetUsesWhisper(audioAsset) ? language.text('耳语', 'Whisper', 'ささやき') : language.text('普通', 'Normal', '通常')}\n'
                        '${_dateLabel(alarm.dateTime, language)}',
                      ),
                      trailing: IconButton(
                        onPressed: () => _deleteAlarm(alarm),
                        tooltip: language.text(
                          '删除闹钟',
                          'Delete alarm',
                          'アラームを削除',
                        ),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  String _dateLabel(DateTime value, AppLanguage language) => language.text(
    '${value.month}月${value.day}日 · 循环语音 · 振动',
    '${value.month}/${value.day} · Looping voice · Vibrate',
    '${value.month}月${value.day}日 · 音声ループ · バイブレーション',
  );
}
