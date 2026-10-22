import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/cold_start_wake_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _wakeKey = ValueKey('cold-start-wake-button');

// Component/controller tests only. The real ChatScreen also needs encrypted
// Spine assets, so its stage/input integration is checked separately on device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cold-start greeting wakes once without changing save data', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    final before = controller.exportData()..remove('exportedAt');
    final revision = controller.dataRevision;
    expect(controller.characterAwaitingWake, isFalse);
    controller.startColdLaunchGreeting();
    expect(controller.characterAwaitingWake, isTrue);
    expect(controller.wakeCharacter(), isTrue);
    expect(controller.characterAwaitingWake, isFalse);
    expect(controller.wakeCharacter(), isFalse);
    controller.startColdLaunchGreeting();
    expect(controller.characterAwaitingWake, isFalse);
    expect(controller.exportData()..remove('exportedAt'), before);
    expect(controller.dataRevision, revision);
  });

  test(
    'save loading does not restart sleep or export its runtime state',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      controller.addUserMessage('存档中的对话');
      await controller.saveToLocalSlot(0);
      controller.startColdLaunchGreeting();
      await controller.loadFromLocalSlot(0);
      expect(controller.characterAwaitingWake, isTrue);
      controller.wakeCharacter();
      await controller.loadFromLocalSlot(0);
      expect(controller.characterAwaitingWake, isFalse);
      for (final data in [
        controller.exportData(),
        controller.exportLocalSlot(0),
      ]) {
        expect(data.containsKey('characterAwaitingWake'), isFalse);
        expect(data.containsKey('startupWakePending'), isFalse);
        expect(data.containsKey('coldLaunchGreetingStarted'), isFalse);
      }
      // Fresh runtime explicitly starts a new greeting. It does not inherit the
      // previous process's awake state from a backup or preferences.
      final restored = await AppController.load();
      addTearDown(restored.dispose);
      expect(restored.characterAwaitingWake, isFalse);
      restored.startColdLaunchGreeting();
      expect(restored.characterAwaitingWake, isTrue);
    },
  );

  test('another active character does not receive Ryza wake lock', () async {
    SharedPreferences.setMockInitialValues({
      'active_character_id_v1': 'sophie',
    });
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    controller.startColdLaunchGreeting();
    expect(controller.characterAwaitingWake, isFalse);
    expect(controller.wakeCharacter(), isFalse);
  });

  test(
    'appearance and language changes preserve the current wake state',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      controller.startColdLaunchGreeting();
      controller.setCharacterAppearance('standing_99');
      controller.configureLanguages(
        interface: AppLanguage.english,
        characterReply: AppLanguage.english,
        narrator: AppLanguage.english,
        translation: TranslationLanguage.none,
      );
      expect(controller.characterAwaitingWake, isTrue);
      controller.wakeCharacter();
      controller.setCharacterAppearance('seated_01');
      controller.configureLanguages(
        interface: AppLanguage.japanese,
        characterReply: AppLanguage.japanese,
        narrator: AppLanguage.japanese,
        translation: TranslationLanguage.none,
      );
      expect(controller.characterAwaitingWake, isFalse);
    },
  );

  test(
    'duplicate wake actions notify once and do not record interaction',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications++);
      final messages = controller.messages.length;
      final touches = controller.characterTouchCount;
      controller.startColdLaunchGreeting();
      controller.startColdLaunchGreeting();
      expect(notifications, 1);
      expect(controller.wakeCharacter(), isTrue);
      expect(controller.wakeCharacter(), isFalse);
      expect(notifications, 2);
      expect(controller.messages.length, messages);
      expect(controller.characterTouchCount, touches);
    },
  );

  testWidgets(
    'wake button consumes the runtime lock without sending a message',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      controller.startColdLaunchGreeting();
      final messages = controller.messages.length;
      final touches = controller.characterTouchCount;
      var callbacks = 0;
      await _mountButton(tester, AppLanguage.chinese, () {
        callbacks++;
        controller.wakeCharacter();
      });
      expect(find.text('点击叫醒莱莎'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(find.byKey(_wakeKey));
      await tester.pump();
      expect(callbacks, 1);
      expect(controller.characterAwaitingWake, isFalse);
      expect(controller.messages.length, messages);
      expect(controller.characterTouchCount, touches);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('foreground resume and component rebuild do not auto-wake', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    controller.startColdLaunchGreeting();
    var callbacks = 0;
    void wake() {
      callbacks++;
      controller.wakeCharacter();
    }

    await _mountButton(tester, AppLanguage.chinese, wake);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _mountButton(tester, AppLanguage.english, wake);
    expect(controller.characterAwaitingWake, isTrue);
    expect(callbacks, 0);
    await tester.tap(find.byKey(_wakeKey));
    await tester.pump();
    await _mountButton(tester, AppLanguage.japanese, wake);
    expect(controller.characterAwaitingWake, isFalse);
    expect(callbacks, 1);
    expect(tester.takeException(), isNull);
  });

  for (final language in AppLanguage.values) {
    testWidgets(
      'waking feedback stays visible and blocks repeated taps $language',
      (tester) async {
        var calls = 0;
        final waking = ValueNotifier(false);
        addTearDown(waking.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: waking,
                builder: (context, value, _) => ColdStartWakeButton(
                  language: language,
                  waking: value,
                  onPressed: () {
                    calls++;
                    waking.value = true;
                  },
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(_wakeKey));
        await tester.pump();
        expect(
          find.text(
            language.text('莱莎正在醒来…', 'Ryza is waking up…', 'ライザが目を覚ましています…'),
          ),
          findsOneWidget,
        );
        expect(
          tester.widget<TextButton>(find.byKey(_wakeKey)).onPressed,
          isNull,
        );
        await tester.tap(find.byKey(_wakeKey));
        await tester.pump(const Duration(milliseconds: 220));
        expect(calls, 1);
        expect(
          tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
          .97,
        );
        expect(find.byType(TextField), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'wake prompt is readable in narrow large-text layout $language',
      (tester) async {
        tester.view.physicalSize = const Size(280, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var calls = 0;
        await _mountButton(tester, language, () => calls++, textScale: 1.5);
        final expected = language.text(
          '点击叫醒莱莎',
          'Tap to wake Ryza',
          'タップしてライザを起こす',
        );
        expect(find.text(expected), findsOneWidget);
        expect(
          tester.getSize(find.byKey(_wakeKey)).height,
          greaterThanOrEqualTo(46),
        );
        expect(find.byType(TextField), findsNothing);
        await tester.tap(find.byKey(_wakeKey));
        await tester.pump();
        expect(calls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<void> _mountButton(
  WidgetTester tester,
  AppLanguage language,
  VoidCallback onPressed, {
  double textScale = 1,
}) => tester.pumpWidget(
  MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Align(
        alignment: Alignment.bottomCenter,
        child: ColdStartWakeButton(language: language, onPressed: onPressed),
      ),
    ),
  ),
);
