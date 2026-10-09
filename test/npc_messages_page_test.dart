import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/app_theme.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/npc_chat_models.dart';
import 'package:ryza_chat_mvp/src/npc_chat_service.dart';
import 'package:ryza_chat_mvp/src/npc_contact_requests.dart';
import 'package:ryza_chat_mvp/src/npc_messages_page.dart';
import 'package:ryza_chat_mvp/src/virtual_phone.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Backend implements NpcReplyBackend {
  final requests = <NpcReplyRequest>[];
  final streams = <StreamController<String>>[];

  @override
  Stream<String> reply(NpcReplyRequest request) {
    requests.add(request);
    final output = StreamController<String>(sync: true);
    streams.add(output);
    return output.stream;
  }

  Future<void> dispose() async {
    for (final stream in streams) {
      if (!stream.isClosed) await stream.close();
    }
  }
}

Finder _contact(String id) => find.byKey(ValueKey('npc-contact-$id'));
Finder _draft(String id) => find.byKey(ValueKey('npc-draft-$id'));
Finder _send(String id) => find.byKey(ValueKey('npc-send-$id'));
final _back = find.byKey(const ValueKey('virtual-phone-back'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory support;
  late AppController controller;
  late NpcChatService service;
  late _Backend backend;

  setUpAll(() async {
    support = await Directory.systemTemp.createTemp('npc_messages_ui_');
  });
  tearDownAll(() async {
    await support.delete(recursive: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProvider,
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? support.path
              : null,
        );
    controller = await AppController.load();
    // The message page now shows only explicitly added contacts. Seed the
    // fixture with the catalog contacts used by these legacy UI tests.
    for (final contact in controller.npcChatContacts) {
      controller.addNpcContact(contact.id);
    }
    controller.aiEnabled = true;
    backend = _Backend();
    service = NpcChatService(
      controller: controller,
      backend: backend,
      notifyInterval: Duration.zero,
    );
  });

  tearDown(() async {
    service.dispose();
    controller.dispose();
    await backend.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
  });

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(390, 800),
    double textScale = 1,
    ValueNotifier<bool>? glass,
    ValueNotifier<double>? keyboard,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: atelierTheme(AppAccentTheme.jade, Brightness.light),
        builder: (context, child) => AnimatedBuilder(
          animation: Listenable.merge([?glass, ?keyboard]),
          child: child,
          builder: (context, child) => GlassStyleScope(
            enabled: glass?.value ?? false,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(textScale),
                viewInsets: EdgeInsets.only(bottom: keyboard?.value ?? 0),
              ),
              child: child!,
            ),
          ),
        ),
        home: VirtualPhoneLauncher(
          language: AppLanguage.chinese,
          liquidGlass: false,
          pages: {
            VirtualPhoneApp.messages: (_) =>
                NpcMessagesPage(controller: controller, service: service),
          },
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.smartphone_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('virtual-phone-app-messages')));
    await tester.pumpAndSettle();
  }

  Future<void> openContact(WidgetTester tester, String id) async {
    await tester.scrollUntilVisible(
      _contact(id),
      100,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('npc-contacts-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(_contact(id));
    await tester.pumpAndSettle();
    await tester.tap(_contact(id));
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, String id, String text) async {
    await tester.enterText(_draft(id), text);
    await tester.pump();
    await tester.tap(_send(id));
    await tester.pump();
  }

  testWidgets(
    'message settings choose a language and back returns to the selected chat',
    (tester) async {
      controller.characterReplyLanguage = AppLanguage.japanese;
      controller.translationLanguage = TranslationLanguage.chinese;
      await mount(tester);
      await openContact(tester, 'claudia');
      await tester.enterText(_draft('claudia'), '保留草稿');
      await tester.tap(
        find.byKey(const ValueKey('npc-message-settings-button')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('npc-message-settings-page')),
        findsOneWidget,
      );
      expect(find.text('跟随莱莎（日本語）'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('npc-reply-language-follow')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();
      expect(controller.npcReplyLanguage, AppLanguage.english);
      await tester.tap(
        find.byKey(const ValueKey('npc-translation-language-follow')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('不翻译').last);
      await tester.pumpAndSettle();
      expect(controller.npcTranslationLanguage, TranslationLanguage.none);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('npc-conversation-claudia')),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(_draft('claudia')).controller!.text,
        '保留草稿',
      );
      await send(tester, 'claudia', '明天去哪？');
      expect(backend.requests.single.replyLanguage, AppLanguage.english);
      expect(backend.requests.single.systemPrompt, contains('用 English'));
      backend.streams.single.add('We can explore the island tomorrow.');
      unawaited(backend.streams.single.close());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'message language settings fit a narrow phone and return to contacts',
    (tester) async {
      await mount(tester, size: const Size(320, 640), textScale: 1.5);
      await tester.tap(
        find.byKey(const ValueKey('npc-message-settings-button')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('npc-message-settings-page')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(_back);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('npc-contacts-list')), findsOneWidget);
      expect(backend.requests, isEmpty);
    },
  );

  testWidgets(
    'all contacts can be searched and selecting or drafting never sends',
    (tester) async {
      await mount(tester);
      expect(controller.npcChatContacts.length, greaterThan(1));
      await tester.enterText(
        find.byKey(const ValueKey('npc-contacts-search')),
        '科洛蒂娅',
      );
      await tester.pumpAndSettle();
      expect(_contact('claudia'), findsOneWidget);
      expect(_contact('lent'), findsNothing);
      await tester.tap(_contact('claudia'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('npc-conversation-claudia')),
        findsOneWidget,
      );
      await tester.enterText(_draft('claudia'), '还没有发送');
      await tester.pump();
      expect(backend.requests, isEmpty);
      expect(controller.npcChats.threads, isEmpty);
      final appBar = tester.getRect(find.byType(AppBar));
      final backRect = tester.getRect(_back);
      expect(backRect.center.dy - appBar.top, 28);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'phone back returns to contacts and each NPC keeps its own draft',
    (tester) async {
      await mount(tester);
      await openContact(tester, 'claudia');
      await tester.enterText(_draft('claudia'), '科洛蒂娅草稿');
      await tester.tap(_back);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('npc-contacts-list')), findsOneWidget);
      await openContact(tester, 'lent');
      expect(
        tester.widget<TextField>(_draft('lent')).controller!.text,
        isEmpty,
      );
      await tester.enterText(_draft('lent'), '兰托草稿');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await openContact(tester, 'claudia');
      expect(
        tester.widget<TextField>(_draft('claudia')).controller!.text,
        '科洛蒂娅草稿',
      );
      await tester.tap(_back);
      await tester.pumpAndSettle();
      await openContact(tester, 'lent');
      expect(tester.widget<TextField>(_draft('lent')).controller!.text, '兰托草稿');
      expect(backend.requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit send streams, prevents duplicates and stores a reply preview',
    (tester) async {
      controller.characterReplyLanguage = AppLanguage.japanese;
      await mount(tester);
      await openContact(tester, 'claudia');
      await send(tester, 'claudia', '晚上一起听笛子吗？');
      expect(backend.requests.length, 1);
      expect(backend.requests.single.contact.id, 'claudia');
      expect(find.byKey(const ValueKey('npc-stop-claudia')), findsOneWidget);
      expect(
        tester.widget<TextField>(_draft('claudia')).controller!.text,
        isEmpty,
      );
      backend.streams.single.add('もちろん、');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('もちろん、'), findsOneWidget);
      await tester.enterText(_draft('claudia'), '下条草稿');
      await tester.pump();
      expect(_send('claudia'), findsNothing);
      expect(backend.requests.length, 1);
      backend.streams.single.add('ライザ。');
      unawaited(backend.streams.single.close());
      await tester.pumpAndSettle();
      expect(find.text('もちろん、ライザ。'), findsOneWidget);
      expect(controller.npcChats.threadFor('claudia').messages.length, 2);
      expect(
        controller.npcChats.threadFor('claudia').messages.last.status,
        NpcChatStatus.completed,
      );
      expect(controller.npcChats.threadFor('lent').messages, isEmpty);
      expect(
        tester.widget<TextField>(_draft('claudia')).controller!.text,
        '下条草稿',
      );
      await tester.tap(_back);
      await tester.pumpAndSettle();
      expect(find.text('もちろん、ライザ。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed reply retries explicitly without duplicating the user message',
    (tester) async {
      await mount(tester);
      await openContact(tester, 'claudia');
      await send(tester, 'claudia', '需要回复的消息');
      backend.streams.single.addError(StateError('test backend failed'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('npc-retry-claudia')), findsOneWidget);
      expect(
        controller.npcChats.threadFor('claudia').messages.last.status,
        NpcChatStatus.failed,
      );
      expect(backend.requests.length, 1);
      await tester.tap(find.byKey(const ValueKey('npc-retry-claudia')));
      await tester.pump();
      expect(backend.requests.length, 2);
      backend.streams.last.add('重试后的回复');
      unawaited(backend.streams.last.close());
      await tester.pumpAndSettle();
      final messages = controller.npcChats.threadFor('claudia').messages;
      expect(
        messages.where((message) => message.role == NpcChatRole.user).length,
        1,
      );
      expect(messages.length, 2);
      expect(messages.last.text, '重试后的回复');
      expect(messages.last.status, NpcChatStatus.completed);
      expect(find.byKey(const ValueKey('npc-retry-claudia')), findsNothing);
    },
  );

  testWidgets('stop preserves partial text and can be retried on request', (
    tester,
  ) async {
    await mount(tester);
    await openContact(tester, 'claudia');
    await send(tester, 'claudia', '需要长回复');
    backend.streams.single.add('已经收到的部分');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('npc-stop-claudia')));
    await tester.pumpAndSettle();
    expect(service.isSending('claudia'), isFalse);
    final last = controller.npcChats.threadFor('claudia').messages.last;
    expect(last.text, '已经收到的部分');
    expect(last.status, NpcChatStatus.interrupted);
    expect(find.byKey(const ValueKey('npc-retry-claudia')), findsOneWidget);
    expect(backend.requests.length, 1);
  });

  testWidgets('closing messages does not cancel controller-owned generation', (
    tester,
  ) async {
    await mount(tester);
    await openContact(tester, 'claudia');
    await send(tester, 'claudia', '离开页面后继续回复');
    await tester.tap(_back);
    await tester.pump();
    await tester.tap(_back);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.byType(NpcMessagesPage), findsNothing);
    expect(service.isSending('claudia'), isTrue);
    backend.streams.single.add('后台完成的回复');
    unawaited(backend.streams.single.close());
    await tester.pumpAndSettle();
    expect(
      controller.npcChats.threadFor('claudia').messages.last.text,
      '后台完成的回复',
    );
    await tester.tap(find.byKey(const ValueKey('virtual-phone-app-messages')));
    await tester.pumpAndSettle();
    expect(find.text('后台完成的回复'), findsOneWidget);
    expect(backend.requests.length, 1);
  });

  testWidgets('rejected configuration preserves the unsent draft', (
    tester,
  ) async {
    controller.aiEnabled = false;
    await mount(tester);
    await openContact(tester, 'claudia');
    await send(tester, 'claudia', '请保留这条消息');
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(_draft('claudia')).controller!.text,
      '请保留这条消息',
    );
    expect(controller.npcChats.threadFor('claudia').messages, isEmpty);
    expect(backend.requests, isEmpty);
    expect(find.textContaining('启用主 LLM'), findsOneWidget);
  });

  testWidgets('new save clears contact selection and all NPC drafts', (
    tester,
  ) async {
    await mount(tester);
    await openContact(tester, 'claudia');
    await tester.enterText(_draft('claudia'), '旧存档草稿');
    await tester.runAsync(() => controller.createLocalSlot(0));
    await tester.pumpAndSettle();
    expect(find.textContaining('在主对话中询问 NPC'), findsOneWidget);
    controller.addNpcContact('claudia');
    await tester.pumpAndSettle();
    await openContact(tester, 'claudia');
    expect(
      tester.widget<TextField>(_draft('claudia')).controller!.text,
      isEmpty,
    );
    await tester.tap(_back);
    await tester.pumpAndSettle();
    expect(find.byType(NpcMessagesPage), findsOneWidget);
    await tester.tap(_back);
    await tester.pumpAndSettle();
    expect(find.byType(NpcMessagesPage), findsNothing);
    expect(backend.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'confirming an exchange immediately creates a usable contact in messages',
    (tester) async {
      controller.replaceNpcChats(
        const NpcChatState.empty(),
        expectedRevision: controller.dataRevision,
      );
      await mount(tester);
      expect(_contact('claudia'), findsNothing);
      expect(find.textContaining('在主对话中询问 NPC'), findsOneWidget);
      final request = NpcContactRequestDetector.detect(
        '科洛蒂娅，能加我 LINE 吗？',
        contacts: controller.npcChatContacts,
      )!;
      final accepted = NpcContactRequestDetector.acceptedContactIds(
        'クラウディア：「うん、いいよ！」',
        request,
        contacts: controller.npcChatContacts,
        primaryCharacterId: controller.activeCharacterId,
      );
      expect(accepted, ['claudia']);
      // This is the same controller operation performed by the confirmation
      // dialog; the already-open messages page must react without reopening.
      expect(controller.addNpcContact(accepted.single), isTrue);
      await tester.pumpAndSettle();
      expect(_contact('claudia'), findsOneWidget);
      expect(_contact('lent'), findsNothing);
      expect(controller.npcChats.threads, isEmpty);
      expect(controller.addNpcContact(accepted.single), isTrue);
      await tester.pumpAndSettle();
      expect(_contact('claudia'), findsOneWidget);
      await openContact(tester, 'claudia');
      expect(_draft('claudia'), findsOneWidget);
      await send(tester, 'claudia', '刚才交换联系方式了，你还记得吗？');
      expect(backend.requests.single.contact.id, 'claudia');
      backend.streams.single.add('もちろん、覚えているよ！');
      unawaited(backend.streams.single.close());
      await tester.pumpAndSettle();
      expect(find.text('もちろん、覚えているよ！'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('glass changes keep drafts without sending or saving anything', (
    tester,
  ) async {
    final glass = ValueNotifier(false);
    addTearDown(glass.dispose);
    await mount(tester, glass: glass);
    await openContact(tester, 'claudia');
    await tester.enterText(_draft('claudia'), '玻璃切换时的草稿');
    final state = tester.state(find.byType(NpcMessagesPage));
    final chats = controller.npcChats.toJson();
    expect(find.byType(BackdropFilter), findsNothing);
    glass.value = true;
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsWidgets);
    expect(tester.state(find.byType(NpcMessagesPage)), same(state));
    glass.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(
      tester.widget<TextField>(_draft('claudia')).controller!.text,
      '玻璃切换时的草稿',
    );
    expect(controller.npcChats.toJson(), chats);
    expect(backend.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'character switching clears selected contact and keeps worlds apart',
    (tester) async {
      await mount(tester);
      await openContact(tester, 'claudia');
      await tester.enterText(_draft('claudia'), '莱莎世界的草稿');
      await tester.runAsync(() => controller.setActiveCharacter('sophie'));
      await tester.pumpAndSettle();
      for (final contact in controller.npcChatContacts) {
        controller.addNpcContact(contact.id);
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('npc-contacts-list')), findsOneWidget);
      expect(_contact('claudia'), findsNothing);
      expect(
        controller.npcChatContacts.every(
          (contact) => contact.id.startsWith('sophie_'),
        ),
        isTrue,
      );
      final sophieContact = controller.npcChatContacts.first.id;
      await openContact(tester, sophieContact);
      expect(
        tester.widget<TextField>(_draft(sophieContact)).controller!.text,
        isEmpty,
      );
      await tester.enterText(_draft(sophieContact), '苏菲世界的草稿');
      await tester.runAsync(() => controller.setActiveCharacter('ryza'));
      await tester.pumpAndSettle();
      await openContact(tester, 'claudia');
      expect(
        tester.widget<TextField>(_draft('claudia')).controller!.text,
        isEmpty,
      );
      expect(controller.npcChats.threads, isEmpty);
      expect(backend.requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('saved replies display their accompanying translation', (
    tester,
  ) async {
    final user = NpcChatMessage(
      id: 'test-user',
      role: NpcChatRole.user,
      text: '明日の予定は？',
      createdAt: DateTime.utc(2026, 10, 5),
    );
    final reply = NpcChatMessage(
      id: 'test-reply',
      role: NpcChatRole.assistant,
      text: '明日は一緒に出かけましょう。',
      translatedText: '明天一起出去吧。',
      createdAt: DateTime.utc(2026, 10, 5, 1),
    );
    controller.replaceNpcChats(
      controller.npcChats.withThread(
        NpcChatThread(npcId: 'claudia', messages: [user, reply]),
      ),
      expectedRevision: controller.dataRevision,
    );
    await mount(tester);
    await openContact(tester, 'claudia');
    expect(find.text('明日は一緒に出かけましょう。'), findsOneWidget);
    expect(find.text('明天一起出去吧。'), findsOneWidget);
    expect(backend.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'narrow phone and visible keyboard keep composer and back usable',
    (tester) async {
      final keyboard = ValueNotifier(0.0);
      addTearDown(keyboard.dispose);
      await mount(
        tester,
        size: const Size(320, 640),
        textScale: 1.5,
        keyboard: keyboard,
      );
      await openContact(tester, 'claudia');
      await tester.enterText(_draft('claudia'), '键盘中的草稿');
      keyboard.value = 240;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_send('claudia').hitTestable(), findsOneWidget);
      await tester.tap(_back);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('npc-conversation-claudia')),
        findsOneWidget,
      );
      keyboard.value = 0;
      await tester.pumpAndSettle();
      await tester.tap(_back);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('npc-contacts-list')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
