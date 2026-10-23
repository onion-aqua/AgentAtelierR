import 'dart:async';

import 'package:alarm/alarm.dart';
import 'package:alarm/service/alarm_storage.dart';
import 'package:alarm/src/generated/platform_bindings.g.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/alarm_ringing_overlay.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAccess implements AlarmRingingAccess {
  final events = StreamController<List<AlarmSettings>>.broadcast(sync: true);
  List<AlarmSettings> active = [];
  final stopped = <int>[];
  Future<bool> Function(int)? onStop;
  Future<List<AlarmSettings>> Function()? onRead;
  var reads = 0;

  @override
  List<AlarmSettings> get currentRinging => active;

  @override
  Stream<List<AlarmSettings>> get ringing => events.stream;

  @override
  Future<List<AlarmSettings>> readRinging() {
    reads++;
    return onRead?.call() ?? Future.value(active.toList());
  }

  @override
  Future<bool> stop(int id) async {
    stopped.add(id);
    return await onStop?.call(id) ?? true;
  }

  void emit(List<AlarmSettings> alarms) {
    active = alarms;
    events.add(alarms);
  }
}

AlarmSettings _alarm(int id) => AlarmSettings(
  id: id,
  dateTime: DateTime(2026, 10, 23, 9, id),
  assetAudioPath: 'assets/audio/alarm/test.m4a',
  volumeSettings: const VolumeSettings.fixed(),
  notificationSettings: NotificationSettings(
    title: 'Reminder $id',
    body: 'Time for reminder $id',
  ),
);

const _surface = ValueKey('alarm-ringing-surface');
const _stop = ValueKey('alarm-ringing-stop');
const _stopAll = ValueKey('alarm-ringing-stop-all');

Future<void> _show(
  WidgetTester tester,
  AlarmRingingAccess access, {
  bool enabled = true,
  Widget? home,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) => AlarmRingingOverlay(
        enabled: enabled,
        language: AppLanguage.chinese,
        access: access,
        child: child!,
      ),
      home: home ?? const Scaffold(body: Text('Chat page')),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAccess access;
  setUp(() {
    access = _FakeAccess();
  });
  tearDown(() async {
    await access.events.close();
  });

  testWidgets('startup discovers native ringing without a new stream event', (
    tester,
  ) async {
    access.onRead = () async => [_alarm(1)];
    await _show(tester, access);
    expect(find.byKey(_surface), findsOneWidget);
    expect(find.byKey(_stop).hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(_stop));
    await tester.pumpAndSettle();
    expect(access.stopped, [1]);
    expect(find.byKey(_surface), findsNothing);
  });

  testWidgets('ringing control stays above an already open Navigator dialog', (
    tester,
  ) async {
    await _show(
      tester,
      access,
      home: Builder(
        builder: (context) {
          return Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) =>
                    const AlertDialog(title: Text('Settings dialog')),
              ),
              child: const Text('Open dialog'),
            ),
          );
        },
      ),
    );
    await tester.tap(find.text('Open dialog'));
    await tester.pumpAndSettle();
    access.emit([_alarm(2)]);
    await tester.pumpAndSettle();
    expect(find.byKey(_stop).hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(_stop));
    await tester.pumpAndSettle();
    expect(access.stopped, [2]);
    expect(find.text('Settings dialog'), findsOneWidget);
  });

  testWidgets('stopping one overlapping alarm exposes the remaining alarm', (
    tester,
  ) async {
    access.active = [_alarm(2), _alarm(1)];
    await _show(tester, access);
    expect(find.text('Reminder 1'), findsOneWidget);
    await tester.tap(find.byKey(_stop));
    await tester.pumpAndSettle();
    expect(access.stopped, [1]);
    expect(find.text('Reminder 2'), findsOneWidget);
    expect(find.byKey(_stopAll), findsNothing);
    await tester.tap(find.byKey(_stop));
    await tester.pumpAndSettle();
    expect(access.stopped, [1, 2]);
    expect(find.byKey(_surface), findsNothing);
  });

  testWidgets('stop all acts only on the sounding IDs', (tester) async {
    access.active = [_alarm(1), _alarm(2)];
    await _show(tester, access);
    await tester.tap(find.byKey(_stopAll));
    await tester.pumpAndSettle();
    expect(access.stopped, [1, 2]);
    expect(find.byKey(_surface), findsNothing);
  });

  for (final throws in [false, true]) {
    testWidgets(
      'failed stop keeps control usable (${throws ? 'throw' : 'false'})',
      (tester) async {
        access.active = [_alarm(1)];
        access.onStop = (_) async {
          if (throws) throw StateError('native failed');
          return false;
        };
        await _show(tester, access);
        await tester.tap(find.byKey(_stop));
        await tester.pumpAndSettle();
        expect(find.text('停止失败，请重试'), findsOneWidget);
        expect(find.byKey(_stop).hitTestable(), findsOneWidget);
        access.onStop = (_) async => true;
        await tester.tap(find.byKey(_stop));
        await tester.pumpAndSettle();
        expect(access.stopped, [1, 1]);
        expect(find.byKey(_surface), findsNothing);
      },
    );
  }

  testWidgets('pending native stop stays visible and prevents double submit', (
    tester,
  ) async {
    final completion = Completer<bool>();
    access.active = [_alarm(1)];
    access.onStop = (_) => completion.future;
    await _show(tester, access);
    await tester.tap(find.byKey(_stop));
    await tester.pump();
    expect(find.text('正在停止…'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(_stop)).onPressed, isNull);
    await tester.tap(find.byKey(_stop));
    expect(access.stopped, [1]);
    completion.complete(true);
    await tester.pumpAndSettle();
    expect(find.byKey(_surface), findsNothing);
  });

  testWidgets('notification stop or snooze dismisses the ringing surface', (
    tester,
  ) async {
    access.active = [_alarm(1)];
    await _show(tester, access);
    access.emit([]);
    await tester.pumpAndSettle();
    expect(find.byKey(_surface), findsNothing);
    expect(access.stopped, isEmpty);
  });

  testWidgets('resume queries native state after a missed background event', (
    tester,
  ) async {
    await _show(tester, access);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    access.active = [_alarm(3)];
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Reminder 3'), findsOneWidget);
    expect(access.reads, 2);
  });

  testWidgets('a stale native query cannot resurrect a stopped alarm', (
    tester,
  ) async {
    final query = Completer<List<AlarmSettings>>();
    access.active = [_alarm(1)];
    access.onRead = () => query.future;
    await _show(tester, access);
    await tester.tap(find.byKey(_stop));
    await tester.pumpAndSettle();
    query.complete([_alarm(1)]);
    await tester.pumpAndSettle();
    expect(find.byKey(_surface), findsNothing);
  });

  testWidgets('native query failure retains known ringing controls', (
    tester,
  ) async {
    access.active = [_alarm(1)];
    access.onRead = () async => throw StateError('query unavailable');
    await _show(tester, access);
    expect(find.byKey(_stop).hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(_stop));
    await tester.pumpAndSettle();
    expect(access.stopped, [1]);
  });

  testWidgets('unsupported platform makes no native calls', (tester) async {
    access.active = [_alarm(1)];
    await _show(tester, access, enabled: false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(access.reads, 0);
    expect(find.byKey(_surface), findsNothing);
  });

  testWidgets(
    'short viewport with large text keeps the stop button reachable',
    (tester) async {
      tester.view.physicalSize = const Size(340, 380);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      access.active = [_alarm(1), _alarm(2)];
      await _show(tester, access);
      await tester.ensureVisible(find.byKey(_stopAll));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(_stopAll));
      await tester.pumpAndSettle();
      expect(access.stopped, [1, 2]);
    },
  );

  group('plugin native boundary', () {
    const queryChannel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.alarm.AlarmApi.isRinging',
      AlarmApi.pigeonChannelCodec,
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AlarmStorage.resetForTesting();
      Alarm.resetForTesting();
      messenger.setMockMethodCallHandler(
        const MethodChannel('com.ajinasokan.flutter_fgbg/events'),
        (_) async => null,
      );
    });
    tearDown(() {
      AlarmStorage.resetForTesting();
      Alarm.resetForTesting();
      messenger.setMockDecodedMessageHandler<Object?>(queryChannel, null);
      messenger.setMockMethodCallHandler(
        const MethodChannel('com.ajinasokan.flutter_fgbg/events'),
        null,
      );
    });

    testWidgets('native discovery survives the stream initial empty replay', (
      tester,
    ) async {
      await AlarmStorage.saveAlarm(_alarm(4));
      messenger.setMockDecodedMessageHandler<Object?>(
        queryChannel,
        (_) async => [true],
      );
      await _show(tester, const PluginAlarmRingingAccess());
      expect(find.text('Reminder 4'), findsOneWidget);
    });

    test(
      'failed native query propagates rather than reporting not ringing',
      () async {
        await AlarmStorage.saveAlarm(_alarm(1));
        messenger.setMockDecodedMessageHandler<Object?>(
          queryChannel,
          (_) async => ['1', 'unavailable', null],
        );
        expect(
          const PluginAlarmRingingAccess().readRinging(),
          throwsA(isA<PlatformException>()),
        );
      },
    );

    test(
      'a failed stop storage removal cannot erase active ID discovery',
      () async {
        Alarm.alarmRang(_alarm(5));
        final ids = <int>[];
        messenger.setMockDecodedMessageHandler<Object?>(queryChannel, (
          message,
        ) async {
          ids.add((message as List).single as int);
          return [true];
        });
        expect(await const PluginAlarmRingingAccess().readRinging(), [
          _alarm(5),
        ]);
        expect(ids, [5]);
      },
    );
  });
}
