import 'dart:io';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_theme.dart';
import 'package:ryza_chat_mvp/src/character_camera.dart';
import 'package:ryza_chat_mvp/src/character_catalog.dart';
import 'package:ryza_chat_mvp/src/chat_screen.dart';
import 'package:ryza_chat_mvp/src/npc_messages_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spine_flutter/spine_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final audioChannels = <String>{
    'xyz.luan/audioplayers.global',
    'xyz.luan/audioplayers.global/events',
    'xyz.luan/audioplayers',
    'agent_atelier_r/companion_runtime/events',
  };
  setUpAll(() async {
    for (final name in audioChannels) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          final channel = 'xyz.luan/audioplayers/events/$id';
          audioChannels.add(channel);
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
  tearDownAll(() {
    for (final name in audioChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  Future<AppController> mountComposer(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
  }) async {
    SharedPreferences.setMockInitialValues({
      'active_character_id_v1': 'sophie',
      'ai_enabled': false,
      'fish_tts_enabled': false,
    });
    final controller = await AppController.load();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: atelierTheme(AppAccentTheme.jade, brightness),
        builder: (context, child) => RepaintBoundary(
          key: const ValueKey('composer-audit-capture'),
          child: child!,
        ),
        home: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => ChatScreen(
            controller: controller,
            onMenuPressed: () {},
            onShopPressed: () {},
            hideUi: false,
          ),
        ),
      ),
    );
    return controller;
  }

  Finder ordinaryInput() => find.byWidgetPredicate(
    (widget) =>
        widget is TextField && widget.decoration?.hintText == '和苏菲说点什么…',
  );

  for (final brightness in [Brightness.light, Brightness.dark]) {
    for (final glass in [false, true]) {
      testWidgets(
        'fullscreen composer follows theme $brightness glass=$glass',
        (tester) async {
          final controller = await mountComposer(
            tester,
            brightness: brightness,
          );
          controller.setLiquidGlassChatUi(glass);
          controller.setSplitNarrationComposer(true);
          await tester.pump();
          await tester.enterText(
            find.byKey(const ValueKey('narration-input-1')),
            '保留全屏草稿',
          );
          await tester.tap(find.byIcon(Icons.open_in_full_rounded));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 240));
          final field = tester.widget<TextField>(
            find.byKey(const ValueKey('narration-input-1')).last,
          );
          expect(field.controller!.text, '保留全屏草稿');
          expect(
            ThemeData.estimateBrightnessForColor(field.style!.color!),
            brightness == Brightness.light ? Brightness.dark : Brightness.light,
          );
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('composer-audit-capture')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            try {
              final png = (await image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!;
              final folder = Directory('build/ui-audit');
              await folder.create(recursive: true);
              await File(
                '${folder.path}/composer-${brightness.name}-$glass.png',
              ).writeAsBytes(
                png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
              );
            } finally {
              image.dispose();
            }
          });
          await tester.tap(find.text('返回（保留草稿）'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 240));
          expect(
            tester
                .widget<TextField>(
                  find.byKey(const ValueKey('narration-input-1')),
                )
                .controller!
                .text,
            '保留全屏草稿',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'Sophie dialogue never borrows avatar or name metadata from Ryza contacts',
    (tester) async {
      final controller = await mountComposer(tester);
      await tester.runAsync(CharacterCatalog.load);
      controller.addAssistantMessage('角色[fee]：一个未属于此人物世界的发言。');
      await tester.pump();
      expect(find.text('fee'), findsWidgets);
      expect(find.text('菲'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Image &&
              widget.image is AssetImage &&
              (widget.image as AssetImage).assetName.endsWith('/fee.png'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('phone detail header remains readable with light liquid glass', (
    tester,
  ) async {
    final controller = await mountComposer(tester);
    controller.setLiquidGlassChatUi(true);
    await tester.pump();
    await tester.tap(find.byIcon(Icons.smartphone_rounded));
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('virtual-phone-app-status')));
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    final bar = tester.widget<AppBar>(
      find.ancestor(of: find.text('角色状态'), matching: find.byType(AppBar)),
    );
    expect(bar.backgroundColor, isNot(Colors.transparent));
    expect(bar.backgroundColor!.computeLuminance(), greaterThan(.8));
    expect(tester.takeException(), isNull);
  });

  testWidgets('real chat screen phone messages app opens NPC contacts', (
    tester,
  ) async {
    final controller = await mountComposer(tester);
    for (final contact in controller.npcChatContacts) {
      controller.addNpcContact(contact.id);
    }
    await tester.pump();
    final mainMessages = controller.messages.length;
    await tester.tap(find.byIcon(Icons.smartphone_rounded));
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('virtual-phone-app-messages')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(find.byType(NpcMessagesPage), findsOneWidget);
    expect(find.byKey(const ValueKey('npc-contacts-list')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('npc-contact-sophie_plachta_doll')),
      findsOneWidget,
    );
    expect(controller.npcChats.threads, isEmpty);
    expect(controller.messages.length, mainMessages);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'holding send switches input modes without sending or losing drafts',
    (tester) async {
      final controller = await mountComposer(tester);
      final initialMessages = controller.messages.length;
      final send = find.byKey(const ValueKey('chat-send-button'));
      expect(find.byIcon(Icons.view_agenda_outlined), findsNothing);

      await tester.enterText(ordinaryInput(), '保留的台词');
      await tester.longPress(send);
      await tester.pump();
      expect(controller.splitNarrationComposer, isTrue);
      expect(controller.messages.length, initialMessages);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('narration-input-1')))
            .controller!
            .text,
        '保留的台词',
      );
      await tester.enterText(
        find.byKey(const ValueKey('narration-input-0')),
        '保留的开场旁白',
      );
      await tester.enterText(
        find.byKey(const ValueKey('narration-input-2')),
        '保留的结尾旁白',
      );

      await tester.longPress(send);
      await tester.pump();
      expect(controller.splitNarrationComposer, isFalse);
      expect(find.byKey(const ValueKey('narration-input-0')), findsNothing);
      expect(
        tester.widget<TextField>(ordinaryInput()).controller!.text,
        '保留的台词',
      );
      expect(controller.messages.length, initialMessages);

      await tester.longPress(send);
      await tester.pump();
      for (final (index, text) in [
        (0, '保留的开场旁白'),
        (1, '保留的台词'),
        (2, '保留的结尾旁白'),
      ]) {
        expect(
          tester
              .widget<TextField>(find.byKey(ValueKey('narration-input-$index')))
              .controller!
              .text,
          text,
        );
      }
      expect(controller.messages.length, initialMessages);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tapping send submits once and keeps the input mode', (
    tester,
  ) async {
    final controller = await mountComposer(tester);
    final initialUsers = controller.messages
        .where((message) => message.isUser)
        .length;
    final initialReplies = controller.messages
        .where((message) => !message.isUser)
        .length;
    await tester.enterText(ordinaryInput(), '点击发送的台词');
    final input = tester.widget<TextField>(ordinaryInput()).controller!;

    await tester.tap(find.byKey(const ValueKey('chat-send-button')));
    await tester.pump();
    expect(controller.splitNarrationComposer, isFalse);
    expect(
      controller.messages.where((message) => message.isUser).length,
      initialUsers + 1,
    );
    expect(controller.messages.last.text, '发言：点击发送的台词');
    expect(input.text, isEmpty);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(
      controller.messages.where((message) => message.isUser).length,
      initialUsers + 1,
    );
    expect(
      controller.messages.where((message) => !message.isUser).length,
      initialReplies + 1,
    );
    expect(controller.splitNarrationComposer, isFalse);
    expect(find.byKey(const ValueKey('narration-input-0')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Sophie uses her portrait without mounting Ryza Spine', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'active_character_id_v1': 'sophie',
    });
    final controller = await AppController.load();

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          controller: controller,
          onMenuPressed: () {},
          onShopPressed: () {},
          hideUi: false,
        ),
      ),
    );

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName ==
                'assets/images/characters/sophie_portrait.png',
      ),
      findsOneWidget,
    );
    expect(find.byType(CharacterCamera), findsNothing);
    expect(find.byType(SpineWidget), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '和苏菲说点什么…',
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('conversation replacement clears every composer draft', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'active_character_id_v1': 'sophie',
    });
    final controller = await AppController.load();
    controller.setSplitNarrationComposer(true);
    await controller.saveToLocalSlot(0);

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          controller: controller,
          onMenuPressed: () {},
          onShopPressed: () {},
          hideUi: false,
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('narration-input-0')),
      '旧人物的开场旁白',
    );
    await tester.enterText(
      find.byKey(const ValueKey('narration-input-1')),
      '旧人物的台词',
    );
    await tester.enterText(
      find.byKey(const ValueKey('narration-input-2')),
      '旧人物的结尾旁白',
    );

    await controller.loadFromLocalSlot(0);
    await tester.pump();

    for (var index = 0; index < 3; index++) {
      final field = tester.widget<TextField>(
        find.byKey(ValueKey('narration-input-$index')),
      );
      expect(field.controller!.text, isEmpty);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
