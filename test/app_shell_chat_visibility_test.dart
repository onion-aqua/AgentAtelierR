import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/app_shell.dart';
import 'package:ryza_chat_mvp/src/app_theme.dart';
import 'package:ryza_chat_mvp/src/chat_screen.dart';
import 'package:ryza_chat_mvp/src/relay/relay_service.dart';
import 'package:ryza_chat_mvp/src/update/apk_update_installer.dart';
import 'package:ryza_chat_mvp/src/update/update_build_config.dart';
import 'package:ryza_chat_mvp/src/update/update_downloader.dart';
import 'package:ryza_chat_mvp/src/update/update_notes_loader.dart';
import 'package:ryza_chat_mvp/src/update/update_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'relay/test_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channels = <String>{
    'xyz.luan/audioplayers.global',
    'xyz.luan/audioplayers.global/events',
    'xyz.luan/audioplayers',
    'agent_atelier_r/companion_runtime',
    'agent_atelier_r/companion_runtime/events',
    'plugins.flutter.io/path_provider',
  };
  late Directory root;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('app-shell-chat-visibility-');
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => root.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          final channel = 'xyz.luan/audioplayers/events/$id';
          channels.add(channel);
          messenger.setMockMethodCallHandler(
            MethodChannel(channel),
            (_) async => null,
          );
        }
        return null;
      },
    );
    await AudioPlayer.global.ensureInitialized();
  });

  tearDownAll(() async {
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), null);
    }
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets(
    'actual shell keeps its visibility toggle and restores the draft',
    (tester) async {
      final fixture = await _mountShell(tester);
      try {
        final toggle = find.byKey(const ValueKey('chat-ui-visibility-toggle'));
        expect(toggle, findsOneWidget);
        expect(find.byTooltip('隐藏界面'), findsOneWidget);
        expect(tester.getTopLeft(toggle).dx, lessThan(32));
        expect(tester.getTopLeft(toggle).dy, lessThan(32));
        final chatElement = tester.element(find.byType(ChatScreen));
        await tester.enterText(_composer(), '隐藏后仍然保留这条草稿');
        expect(
          tester.widget<ChatScreen>(find.byType(ChatScreen)).hideUi,
          isFalse,
        );

        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(toggle, findsOneWidget);
        expect(find.byTooltip('恢复界面'), findsOneWidget);
        expect(_composer(), findsNothing);
        expect(
          tester.widget<ChatScreen>(find.byType(ChatScreen)).hideUi,
          isTrue,
        );
        expect(tester.element(find.byType(ChatScreen)), same(chatElement));

        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.byTooltip('隐藏界面'), findsOneWidget);
        expect(_composer(), findsOneWidget);
        expect(
          tester.widget<TextField>(_composer()).controller!.text,
          '隐藏后仍然保留这条草稿',
        );
        expect(tester.element(find.byType(ChatScreen)), same(chatElement));
        expect(tester.takeException(), isNull);
      } finally {
        await fixture.cleanup();
      }
    },
  );

  testWidgets(
    'bubble and theme switches keep shell visibility control usable',
    (tester) async {
      final fixture = await _mountShell(tester);
      final controller = fixture.controller;
      try {
        final toggle = find.byKey(const ValueKey('chat-ui-visibility-toggle'));
        for (final bubbles in [true, false]) {
          controller.setChatBubbleStyle(bubbles);
          for (final theme in [
            AppThemePreference.light,
            AppThemePreference.dark,
          ]) {
            controller.setThemePreference(theme);
            await tester.pumpAndSettle();
            expect(toggle, findsOneWidget);
            expect(
              Theme.of(tester.element(toggle)).brightness,
              theme == AppThemePreference.light
                  ? Brightness.light
                  : Brightness.dark,
            );
            expect(_composer(), findsOneWidget);
            await tester.tap(toggle);
            await tester.pumpAndSettle();
            expect(toggle, findsOneWidget);
            expect(_composer(), findsNothing);
            expect(find.byTooltip('恢复界面'), findsOneWidget);
            await tester.tap(toggle);
            await tester.pumpAndSettle();
            expect(_composer(), findsOneWidget);
            expect(find.byTooltip('隐藏界面'), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
        }
      } finally {
        await fixture.cleanup();
      }
    },
  );
}

Finder _composer() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      widget.decoration?.hintText?.contains('说点什么') == true,
);

Future<({AppController controller, Future<void> Function() cleanup})>
_mountShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(430, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  FlutterSecureStorage.setMockInitialValues({});
  SharedPreferences.setMockInitialValues({
    'active_character_id_v1': 'sophie',
    'ai_enabled': false,
    'fish_tts_enabled': false,
    'bgm_enabled': false,
    'ambient_sound_enabled': false,
  });
  final controller = (await tester.runAsync(AppController.load))!;
  controller.setChatBubbleStyle(true);
  controller.configureLanguages(
    interface: AppLanguage.chinese,
    narrator: AppLanguage.chinese,
    characterReply: AppLanguage.chinese,
    translation: TranslationLanguage.none,
  );
  final transport = TestTransport();
  final relay = RelayService(store: MemoryRelayStore(), transport: transport);
  final updates = UpdateRuntime(
    buildConfig: const UpdateBuildConfig.disabled(),
    installed: null,
    service: null,
    downloader: UpdateDownloader(),
    installer: ApkUpdateInstaller(),
    notesLoader: UpdateNotesLoader(),
    disabledReason: 'offline_widget_test',
  );
  var disposed = false;
  Future<void> cleanup() async {
    if (disposed) return;
    disposed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    relay.dispose();
    updates.dispose();
    controller.dispose();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }

  addTearDown(cleanup);
  await tester.pumpWidget(
    AnimatedBuilder(
      animation: controller,
      builder: (context, _) => MaterialApp(
        theme: atelierTheme(controller.accentTheme, Brightness.light),
        darkTheme: atelierTheme(controller.accentTheme, Brightness.dark),
        themeMode: switch (controller.themePreference) {
          AppThemePreference.system => ThemeMode.system,
          AppThemePreference.light => ThemeMode.light,
          AppThemePreference.dark => ThemeMode.dark,
        },
        home: AppShell(
          controller: controller,
          relayService: relay,
          updateRuntime: updates,
          startupUpdateCheckReady: false,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(transport.calls, isEmpty);
  return (controller: controller, cleanup: cleanup);
}
