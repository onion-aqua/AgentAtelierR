import 'dart:async';
import 'dart:convert';

import 'package:alarm/alarm.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/character_alarm_coordinator.dart';
import 'package:ryza_chat_mvp/src/desktop_updates_page.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_audio.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_reply.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_session.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_settings.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_ui_models.dart';
import 'package:ryza_chat_mvp/src/realtime_call/local_call_asr.dart';
import 'package:ryza_chat_mvp/src/settings_screen.dart';
import 'package:ryza_chat_mvp/src/update/update_center_page.dart';
import 'package:ryza_chat_mvp/src/virtual_phone.dart';
import 'package:shared_preferences/shared_preferences.dart';

void platformTestWidgets(
  String description,
  WidgetTesterCallback callback, {
  TargetPlatform platform = TargetPlatform.windows,
}) {
  testWidgets(
    description,
    callback,
    variant: TargetPlatformVariant({platform}),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Future<void> openPhone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: VirtualPhoneLauncher(
          language: AppLanguage.chinese,
          liquidGlass: false,
          pages: {
            for (final app in VirtualPhoneApp.values)
              app: (_) =>
                  Scaffold(body: Center(child: Text('opened-${app.name}'))),
          },
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.smartphone_rounded));
    await tester.pumpAndSettle();
  }

  platformTestWidgets('Windows phone hides mobile calling and voice alarms', (
    tester,
  ) async {
    await openPhone(tester);
    expect(VirtualPhoneApp.phone.supported, isFalse);
    expect(VirtualPhoneApp.alarms.supported, isFalse);
    expect(find.byKey(const ValueKey('virtual-phone-app-phone')), findsNothing);
    expect(
      find.byKey(const ValueKey('virtual-phone-app-alarms')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  for (final app in [
    VirtualPhoneApp.messages,
    VirtualPhoneApp.outfit,
    VirtualPhoneApp.motion,
    VirtualPhoneApp.imageGeneration,
    VirtualPhoneApp.wallpaper,
  ]) {
    platformTestWidgets(
      'Windows ${app.name} remains reachable inside virtual phone',
      (tester) async {
        await openPhone(tester);
        final icon = find.byKey(ValueKey('virtual-phone-app-${app.name}'));
        expect(app.supported, isTrue);
        await tester.ensureVisible(icon);
        await tester.tap(icon);
        await tester.pumpAndSettle();
        expect(find.text('opened-${app.name}'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('virtual-phone-back')));
        await tester.pumpAndSettle();
        expect(icon.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  platformTestWidgets('Android retains calling and voice alarm icons', (
    tester,
  ) async {
    await openPhone(tester);
    expect(VirtualPhoneApp.phone.supported, isTrue);
    expect(VirtualPhoneApp.alarms.supported, isTrue);
    expect(
      find.byKey(const ValueKey('virtual-phone-app-phone')),
      findsOneWidget,
    );
    final alarm = find.byKey(const ValueKey('virtual-phone-app-alarms'));
    await tester.scrollUntilVisible(
      alarm,
      150,
      scrollable: find
          .descendant(
            of: find.byType(GridView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(alarm.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, platform: TargetPlatform.android);

  platformTestWidgets(
    'Windows settings opens PC downloads without APK update controls',
    (tester) async {
      final app = (await tester.runAsync(AppController.load))!;
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(controller: app, onMenuPressed: () {}),
        ),
      );
      final about = find.byKey(const ValueKey('settings-category-about'));
      await tester.scrollUntilVisible(
        about,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(about);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('about-update-center-tile')));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopUpdatesPage), findsOneWidget);
      expect(find.byType(UpdateCenterPage), findsNothing);
      expect(
        find.byKey(const ValueKey('desktop-release-download')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('update-auto-check')), findsNothing);
      expect(find.byKey(const ValueKey('update-check-now')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final result in ['success', 'false', 'exception']) {
    platformTestWidgets(
      'PC download opens official release and exposes fallback on $result',
      (tester) async {
        Uri? requested;
        var calls = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: DesktopUpdatesPage(
              language: AppLanguage.chinese,
              liquidGlass: false,
              openRelease: (uri) async {
                requested = uri;
                calls++;
                if (result == 'exception') {
                  throw StateError('browser unavailable');
                }
                return result == 'success';
              },
            ),
          ),
        );
        final download = find.byKey(const ValueKey('desktop-release-download'));
        await tester.ensureVisible(download);
        await tester.tap(download);
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(
          requested,
          Uri.parse(
            'https://github.com/onion-aqua/AgentAtelierR/releases/latest',
          ),
        );
        final copyableUrl = find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText && widget.data == requested.toString(),
        );
        expect(
          copyableUrl,
          result == 'success' ? findsNothing : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'Windows calling is inert before microphone, models, keys or network',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final app = await AppController.load();
      final asr = _ObservedAsr();
      final output = _ObservedOutput();
      final replies = _ObservedReply();
      final settings = _ObservedSettings();
      var keyReads = 0, speechRequests = 0;
      final controller = RealtimeCallController(
        app: app,
        asr: asr,
        output: output,
        replies: replies,
        settingsStore: settings,
        readFishKey: () async {
          keyReads++;
          return 'unused';
        },
        speechFactory: (_, _, _, _) {
          speechRequests++;
          throw StateError('Windows must not synthesize calls');
        },
      );
      final initialMessages = app.messages.toList();
      for (final id in ['primary:ryza', 'claudia', 'unknown']) {
        await controller.offerCall(id);
        await controller.startCall(id);
      }
      await controller.acceptCall();
      await controller.sendText('do not send');
      expect(controller.contacts, isEmpty);
      expect(controller.snapshot.phase, CallUiPhase.idle);
      expect(controller.snapshot.contact, isNull);
      expect(controller.snapshot.error, isNull);
      expect(controller.active, isFalse);
      expect(asr.starts, 0);
      expect(output.operations, isEmpty);
      expect(settings.loads, 0);
      expect(replies.requests, 0);
      expect(keyReads, 0);
      expect(speechRequests, 0);
      expect(app.callRecords, isEmpty);
      expect(app.messages, initialMessages);
      expect(app.isNpcContactAdded('claudia'), isFalse);
      controller.dispose();
      await asr.disposed.future;
      app.dispose();
    },
  );

  test('Windows startup preserves imported paused mobile alarms without native access', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final expired = AlarmSettings(
      id: 740,
      dateTime: DateTime.now().subtract(const Duration(days: 1)),
      payload: CharacterAlarmCoordinator.ryzaVoicePayload,
      volumeSettings: const VolumeSettings.fixed(volume: 0.8),
      notificationSettings: const NotificationSettings(
        title: 'alarm',
        body: 'mobile',
      ),
    );
    const key = 'paused_ryza_voice_alarms_v1';
    final imported = jsonEncode([expired.toJson()]);
    SharedPreferences.setMockInitialValues({key: imported});
    final app = await AppController.load();
    addTearDown(app.dispose);
    final access = _ObservedNativeAlarmAccess();
    await app.initializeAlarmRuntime(access: access);
    await app.initializeAlarmRuntime();
    // Reselecting the current character must not activate a hidden coordinator.
    await app.setActiveCharacter(app.activeCharacterId);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(key), imported);
    expect(access.operations, isEmpty);
  });
}

class _ObservedAsr extends LocalCallAsr {
  final _events = StreamController<LocalCallAsrEvent>.broadcast();
  final disposed = Completer<void>();
  var starts = 0;
  @override
  Stream<LocalCallAsrEvent> get events => _events.stream;
  @override
  Future<void> start(LocalCallAsrConfig config) async => starts++;
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    await _events.close();
    disposed.complete();
  }
}

class _ObservedOutput implements CallPcmOutput {
  final operations = <String>[];
  @override
  Future<void> start() async => operations.add('start');
  @override
  Future<void> write(Uint8List pcm) async => operations.add('write');
  @override
  Future<void> drain() async => operations.add('drain');
  @override
  Future<void> stop() async => operations.add('stop');
  @override
  Future<bool> setSpeaker(bool value) async {
    operations.add('speaker');
    return true;
  }
}

class _ObservedReply implements CallReplyBackend {
  var requests = 0;
  @override
  Stream<String> reply(CallReplyRequest request) {
    requests++;
    return const Stream.empty();
  }
}

class _ObservedSettings extends CallSettingsStore {
  var loads = 0;
  @override
  Future<CallSettings> load() async {
    loads++;
    return CallSettings();
  }
}

class _ObservedNativeAlarmAccess extends PluginCharacterAlarmAccess {
  final operations = <String>[];
  @override
  Future<List<AlarmSettings>> getAlarms() async {
    operations.add('get');
    return const [];
  }

  @override
  Future<bool> set(AlarmSettings settings) async {
    operations.add('set');
    return true;
  }

  @override
  Future<bool> stop(int id) async {
    operations.add('stop');
    return true;
  }
}
