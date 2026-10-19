import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_theme.dart';
import 'package:ryza_chat_mvp/src/conversation_collection_store.dart';
import 'package:ryza_chat_mvp/src/conversation_collections_page.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const audioChannels = [
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
    'agent_atelier_r/companion_runtime/events',
  ];
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final playerEventChannels = <String>{};

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('collection-page-test-');
    messenger.setMockMethodCallHandler(pathChannel, (_) async => root.path);
    for (final name in audioChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          final events = 'xyz.luan/audioplayers/events/$id';
          playerEventChannels.add(events);
          messenger.setMockMethodCallHandler(
            MethodChannel(events),
            (_) async => null,
          );
        }
        return 1;
      });
    }
    await AudioPlayer.global.ensureInitialized();
    final store = await ConversationCollectionStore.open();
    await store.collect([
      {
        'key': 'page-test',
        'text': '主题测试',
        'isUser': true,
        'saveText': true,
        'saveVoice': false,
      },
    ], name: '收藏主题测试');
  });
  tearDownAll(() async {
    messenger.setMockMethodCallHandler(pathChannel, null);
    for (final name in audioChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    for (final name in playerEventChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
    await root.delete(recursive: true);
  });

  testWidgets('collection cards follow both themes and the live glass switch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final controller = (await tester.runAsync(() => AppController.load()))!;
    addTearDown(controller.dispose);
    for (final brightness in Brightness.values) {
      controller.setLiquidGlassChatUi(false);
      await tester.pumpWidget(
        MaterialApp(
          theme: atelierTheme(AppAccentTheme.jade, brightness),
          home: ConversationCollectionsPage(controller: controller),
        ),
      );
      for (var attempt = 0; attempt < 40; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 16));
        if (find.byType(GlassContentCard).evaluate().isNotEmpty) break;
      }
      await tester.pumpAndSettle();
      final card = find.byType(GlassContentCard);
      expect(card, findsOneWidget);
      final surface = find.descendant(
        of: card,
        matching: find.byType(GlassSurface),
      );
      final widget = tester.widget<GlassSurface>(surface);
      expect(
        widget.tone,
        brightness == Brightness.light ? GlassTone.light : GlassTone.dark,
      );
      expect(
        widget.fallbackColor.computeLuminance(),
        brightness == Brightness.light ? greaterThan(.8) : lessThan(.1),
      );
      controller.setLiquidGlassChatUi(true);
      await tester.pumpAndSettle();
      expect(tester.widget<GlassSurface>(surface).liquidGlass, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });
}
