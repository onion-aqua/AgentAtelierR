import 'dart:async';

import 'package:alarm/alarm.dart';
// The public isRinging wrapper swallows native query errors as false, which
// would hide a sounding alarm's stop control. Covered by native-boundary tests.
// ignore: implementation_imports
import 'package:alarm/src/generated/platform_bindings.g.dart';
import 'package:flutter/material.dart';

import 'app_localization.dart';
import 'runtime_log.dart';

/// Native ringing state, rather than scheduled times, owns the stop surface.
abstract interface class AlarmRingingAccess {
  List<AlarmSettings> get currentRinging;
  Stream<List<AlarmSettings>> get ringing;
  Future<List<AlarmSettings>> readRinging();
  Future<bool> stop(int id);
}

class PluginAlarmRingingAccess implements AlarmRingingAccess {
  const PluginAlarmRingingAccess();

  @override
  List<AlarmSettings> get currentRinging => Alarm.ringing.value.alarms.toList();

  @override
  Stream<List<AlarmSettings>> get ringing =>
      // currentRinging already supplies the BehaviorSubject's initial value.
      // Replaying that snapshot must not invalidate the startup native query.
      Alarm.ringing.skip(1).map((value) => value.alarms.toList());

  @override
  Future<List<AlarmSettings>> readRinging() async {
    // stop() removes persisted settings before its platform call. Include the
    // live stream so a failed stop remains recoverable and can be retried.
    final known = {
      for (final alarm in await Alarm.getAlarms()) alarm.id: alarm,
      for (final alarm in currentRinging) alarm.id: alarm,
    };
    final active = <AlarmSettings>[];
    for (final alarm in known.values) {
      // Alarm.isRinging() turns platform failures into false. Read the native
      // binding directly so a query failure cannot hide a still-ringing alarm.
      if (await AlarmApi().isRinging(alarmId: alarm.id)) active.add(alarm);
    }
    return active;
  }

  @override
  Future<bool> stop(int id) => Alarm.stop(id);
}

/// Lives above the app Navigator so dialogs and virtual-phone routes cannot
/// cover the only in-app control that can silence a sounding native alarm.
class AlarmRingingOverlay extends StatefulWidget {
  const AlarmRingingOverlay({
    super.key,
    required this.enabled,
    required this.language,
    required this.child,
    this.access = const PluginAlarmRingingAccess(),
  });

  final bool enabled;
  final AppLanguage language;
  final Widget child;
  final AlarmRingingAccess access;

  @override
  State<AlarmRingingOverlay> createState() => _AlarmRingingOverlayState();
}

class _AlarmRingingOverlayState extends State<AlarmRingingOverlay>
    with WidgetsBindingObserver {
  StreamSubscription<List<AlarmSettings>>? _subscription;
  List<AlarmSettings> _alarms = const [];
  final _stopping = <int>{};
  bool _stopFailed = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listen();
  }

  @override
  void didUpdateWidget(AlarmRingingOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.access != widget.access) {
      _subscription?.cancel();
      _subscription = null;
      _revision++;
      _alarms = const [];
      _stopping.clear();
      _stopFailed = false;
      _listen();
    }
  }

  void _listen() {
    if (!widget.enabled) return;
    _alarms = _sorted(widget.access.currentRinging);
    _subscription = widget.access.ringing.listen(
      (alarms) {
        if (!mounted) return;
        _revision++;
        setState(() {
          _alarms = _sorted(alarms);
          if (_alarms.isEmpty) _stopFailed = false;
        });
      },
      onError: (Object error, StackTrace stack) {
        RuntimeLog.instance.error('Alarm', error, stack);
      },
    );
    unawaited(_refresh());
  }

  List<AlarmSettings> _sorted(List<AlarmSettings> alarms) =>
      (alarms.toList()..sort((a, b) {
        final byTime = a.dateTime.compareTo(b.dateTime);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      }));

  Future<void> _refresh() async {
    if (!widget.enabled) return;
    final revision = ++_revision;
    try {
      final active = await widget.access.readRinging();
      if (!mounted || revision != _revision || !widget.enabled) return;
      setState(() {
        _alarms = _sorted(active);
        if (_alarms.isEmpty) _stopFailed = false;
      });
    } on Object catch (error, stack) {
      // Keep known alarms and their stop buttons if Android cannot be queried.
      RuntimeLog.instance.error('Alarm', error, stack);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _stop(List<AlarmSettings> alarms) async {
    final access = widget.access;
    final ids = alarms.map((alarm) => alarm.id).toSet();
    if (ids.any(_stopping.contains)) return;
    _revision++; // An older resume query must not resurrect a stopped alarm.
    setState(() {
      _stopping.addAll(ids);
      _stopFailed = false;
    });
    for (final id in ids) {
      var stopped = false;
      try {
        stopped = await access.stop(id);
      } on Object catch (error, stack) {
        RuntimeLog.instance.error('Alarm', error, stack);
      }
      if (!mounted || access != widget.access) return;
      setState(() {
        _stopping.remove(id);
        if (stopped) {
          _alarms = _alarms.where((alarm) => alarm.id != id).toList();
        } else {
          _stopFailed = true;
        }
      });
      if (stopped) RuntimeLog.instance.info('Alarm', '已停止响铃，id=$id');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.enabled && _alarms.isNotEmpty;
    final language = widget.language;
    final colors = Theme.of(context).colorScheme;
    final alarm = visible ? _alarms.first : null;
    final busy = _stopping.isNotEmpty;
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeFocus(
          excluding: visible,
          child: ExcludeSemantics(
            excluding: visible,
            child: AbsorbPointer(absorbing: visible, child: widget.child),
          ),
        ),
        if (alarm != null) ...[
          const ModalBarrier(dismissible: false, color: Colors.black54),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Semantics(
                    scopesRoute: true,
                    namesRoute: true,
                    explicitChildNodes: true,
                    label: language.text('闹钟响铃中', 'Alarm ringing', 'アラーム鳴動中'),
                    child: Material(
                      key: const ValueKey('alarm-ringing-surface'),
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(28),
                      elevation: 12,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Icon(
                              Icons.alarm_rounded,
                              size: 52,
                              color: colors.primary,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              TimeOfDay.fromDateTime(alarm.dateTime)
                                  .format(context),
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.displayMedium,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              alarm.notificationSettings.title,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            if (alarm.notificationSettings.body.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                alarm.notificationSettings.body,
                                textAlign: TextAlign.center,
                              ),
                            ],
                            if (_alarms.length > 1) ...[
                              const SizedBox(height: 12),
                              Text(
                                language.text(
                                  '共有 ${_alarms.length} 个闹钟正在响铃',
                                  '${_alarms.length} alarms are ringing',
                                  '${_alarms.length} 件のアラームが鳴っています',
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                            if (_stopFailed) ...[
                              const SizedBox(height: 12),
                              Text(
                                language.text(
                                  '停止失败，请重试',
                                  'Could not stop the alarm. Try again.',
                                  '停止できませんでした。再試行してください',
                                ),
                                style: TextStyle(color: colors.error),
                                textAlign: TextAlign.center,
                              ),
                            ],
                            const SizedBox(height: 24),
                            FilledButton.icon(
                              key: const ValueKey('alarm-ringing-stop'),
                              onPressed: busy ? null : () => _stop([alarm]),
                              icon: const Icon(Icons.alarm_off_rounded),
                              label: Text(
                                language.text(
                                  busy ? '正在停止…' : '停止闹钟',
                                  busy ? 'Stopping…' : 'Stop alarm',
                                  busy ? '停止中…' : 'アラームを停止',
                                ),
                              ),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(56),
                              ),
                            ),
                            if (_alarms.length > 1) ...[
                              const SizedBox(height: 8),
                              TextButton(
                                key: const ValueKey('alarm-ringing-stop-all'),
                                onPressed: busy
                                    ? null
                                    : () => _stop(_alarms.toList()),
                                child: Text(
                                  language.text(
                                    '停止全部响铃',
                                    'Stop all ringing alarms',
                                    '鳴動中のアラームをすべて停止',
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
