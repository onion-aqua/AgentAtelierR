import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_camera.dart';
import 'package:ryza_chat_mvp/src/chat_screen.dart';
import 'package:ryza_chat_mvp/src/npc_messages_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spine_flutter/spine_flutter.dart';

void main() {
  Future<AppController> mountComposer(WidgetTester tester) async {
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
