import 'dart:async';
import 'dart:io';

import 'package:alarm/alarm.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_alarm_coordinator.dart';
import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAlarmAccess implements CharacterAlarmAccess {
  final alarms = <int, AlarmSettings>{};
  final stopped = <int>[];
  final restored = <int>[];
  final stopFailures = <int>{};
  Completer<void>? stopEntered;
  Completer<void>? allowStop;

  @override
  Future<List<AlarmSettings>> getAlarms() async => alarms.values.toList();

  @override
  Future<bool> set(AlarmSettings settings) async {
    restored.add(settings.id);
    alarms[settings.id] = settings;
    return true;
  }

  @override
  Future<bool> stop(int id) async {
    stopped.add(id);
    stopEntered?.complete();
    await allowStop?.future;
    if (stopFailures.contains(id)) return false;
    alarms.remove(id);
    return true;
  }
}

AlarmSettings _alarm(
  int id,
  DateTime dateTime, {
  String? path,
  String? payload,
}) => AlarmSettings(
  id: id,
  dateTime: dateTime,
  assetAudioPath: path,
  payload: payload,
  volumeSettings: const VolumeSettings.fixed(volume: 0.8),
  notificationSettings: const NotificationSettings(
    title: 'Voice alarm',
    body: 'Wake up',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory supportDirectory;

  setUpAll(() async {
    supportDirectory = await Directory.systemTemp.createTemp('alarm_switch_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return supportDirectory.path;
          }
          return null;
        });
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await supportDirectory.delete(recursive: true);
  });

  test('pauses only Ryza voice alarms and restores future alarms', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final access = _FakeAlarmAccess();
    final future = DateTime.now().add(const Duration(hours: 2));
    final legacy = _alarm(
      101,
      future,
      path: 'assets/audio/alarm/voices/ja_normal_task_morning_1.m4a',
    );
    final tagged = _alarm(
      102,
      future.add(const Duration(minutes: 1)),
      payload: CharacterAlarmCoordinator.ryzaVoicePayload,
    );
    final unrelated = _alarm(103, future, path: 'assets/audio/alarm/other.m4a');
    access.alarms.addAll({101: legacy, 102: tagged, 103: unrelated});
    final coordinator = CharacterAlarmCoordinator(preferences, access: access);

    await coordinator.syncForCharacter(CharacterRuntimeIds.sophie);
    expect(access.stopped, [101, 102]);
    expect(access.alarms.keys, [103]);

    final afterRestart = CharacterAlarmCoordinator(preferences, access: access);
    await afterRestart.syncForCharacter(CharacterRuntimeIds.ryza);
    expect(access.restored, [101, 102]);
    expect(
      access.alarms[101],
      legacy.copyWith(allowSameSecondScheduling: true),
    );
    expect(
      access.alarms[102],
      tagged.copyWith(allowSameSecondScheduling: true),
    );
    expect(access.alarms[103], unrelated);

    await afterRestart.syncForCharacter(CharacterRuntimeIds.ryza);
    expect(access.restored, [101, 102]);
  });

  test('expired alarms are not rescheduled after Sophie mode', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final access = _FakeAlarmAccess();
    access.alarms[104] = _alarm(
      104,
      DateTime.now().subtract(const Duration(minutes: 1)),
      path: 'assets/audio/alarm/voices/en_normal_task_daytime_1.m4a',
    );
    final coordinator = CharacterAlarmCoordinator(preferences, access: access);
    await coordinator.syncForCharacter(CharacterRuntimeIds.sophie);
    await coordinator.syncForCharacter(CharacterRuntimeIds.ryza);
    expect(access.restored, isEmpty);
    expect(access.alarms, isEmpty);
  });

  test('failed pause restores already stopped alarms', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final access = _FakeAlarmAccess()..stopFailures.add(108);
    final future = DateTime.now().add(const Duration(hours: 1));
    for (final id in [107, 108]) {
      access.alarms[id] = _alarm(
        id,
        future.add(Duration(minutes: id - 107)),
        path: 'assets/audio/alarm/voices/en_normal_task_morning_$id.m4a',
      );
    }
    final coordinator = CharacterAlarmCoordinator(preferences, access: access);
    await expectLater(
      coordinator.syncForCharacter(CharacterRuntimeIds.sophie),
      throwsStateError,
    );
    expect(access.alarms.keys, containsAll([107, 108]));
    await coordinator.syncForCharacter(CharacterRuntimeIds.ryza);
    expect(access.alarms.keys, containsAll([107, 108]));
  });

  test('controller switches suspend and resume Ryza alarms', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    final access = _FakeAlarmAccess();
    access.alarms[105] = _alarm(
      105,
      DateTime.now().add(const Duration(hours: 1)),
      path: 'assets/audio/alarm/voices/ja_normal_task_morning_2.m4a',
    );
    await controller.initializeAlarmRuntime(access: access);

    await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
    expect(access.alarms, isEmpty);
    await controller.setActiveCharacter(CharacterRuntimeIds.ryza);
    expect(access.alarms.keys, [105]);
  });

  test('startup with Sophie pauses legacy Ryza alarms', () async {
    SharedPreferences.setMockInitialValues({
      'active_character_id_v1': CharacterRuntimeIds.sophie,
    });
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    final access = _FakeAlarmAccess();
    access.alarms[109] = _alarm(
      109,
      DateTime.now().add(const Duration(hours: 1)),
      path: 'assets/audio/alarm/voices/ja_normal_task_morning_4.m4a',
    );

    await controller.initializeAlarmRuntime(access: access);
    expect(controller.activeCharacterId, CharacterRuntimeIds.sophie);
    expect(access.stopped, [109]);
    expect(access.alarms, isEmpty);
  });

  test('reselecting Ryza cancels an in-flight switch to Sophie', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    final access = _FakeAlarmAccess()
      ..stopEntered = Completer<void>()
      ..allowStop = Completer<void>();
    access.alarms[106] = _alarm(
      106,
      DateTime.now().add(const Duration(hours: 1)),
      path: 'assets/audio/alarm/voices/ja_normal_task_morning_3.m4a',
    );
    await controller.initializeAlarmRuntime(access: access);

    final switchToSophie = controller.setActiveCharacter(
      CharacterRuntimeIds.sophie,
    );
    await access.stopEntered!.future;
    final stayWithRyza = controller.setActiveCharacter(
      CharacterRuntimeIds.ryza,
    );
    access.allowStop!.complete();
    await Future.wait([switchToSophie, stayWithRyza]);

    expect(controller.activeCharacterId, CharacterRuntimeIds.ryza);
    expect(access.alarms.keys, [106]);
  });
}
