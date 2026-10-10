import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/chat_screen.dart';
import 'package:ryza_chat_mvp/src/npc_messages_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Exercises the real screen's send, streamed reply, confirmation and virtual
/// phone flow. The only service is a loopback fixture, never a live provider.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final audioChannels = <String>{
    'xyz.luan/audioplayers.global',
    'xyz.luan/audioplayers.global/events',
    'xyz.luan/audioplayers',
  };
  setUpAll(() {
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
  });
  tearDownAll(() {
    for (final name in audioChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  for (final narrationRequest in [true, false]) {
    testWidgets(
      narrationRequest
          ? 'narrated request and Japanese name reply show add dialog before missing TTS config'
          : 'speech request confirms a Japanese NPC before failed TTS and opens messages',
      (tester) async {
        tester.view.physicalSize = const Size(390, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final originalOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        final support = await tester.runAsync(
          () => Directory.systemTemp.createTemp('npc_contact_screen_'),
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              pathProvider,
              (call) async => call.method == 'getApplicationSupportDirectory'
                  ? support!.path
                  : null,
            );
        final server = (await tester.runAsync(
          () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        ))!;
        var streamedReplies = 0;
        var plannerRequests = 0;
        var ttsRequests = 0;
        final receivedUserText = <String>[];
        final serving = server.listen((request) async {
          request.response.persistentConnection = false;
          final body = await utf8.decoder.bind(request).join();
          if (request.uri.path == '/tts') {
            if (request.method == 'POST') ttsRequests += 1;
            request.response.statusCode = HttpStatus.unauthorized;
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              '{"error":"test fixture rejected voice key"}',
            );
          } else {
            final data = jsonDecode(body) as Map<String, dynamic>;
            if (data['stream'] == true) {
              streamedReplies += 1;
              receivedUserText.add(
                ((data['messages'] as List).last as Map)['content'] as String,
              );
              request.response.headers.contentType = ContentType(
                'text',
                'event-stream',
                charset: 'utf-8',
              );
              const reply =
                  '苏菲：いいわね、連絡先を交換しましょう。\n'
                  'プラフタ（人形）：「うん、いいよ！LINEを交換しましょう。」';
              request.response.write(
                'data: ${jsonEncode({
                  'choices': [
                    {
                      'delta': {'content': reply},
                    },
                  ],
                })}\n\ndata: [DONE]\n\n',
              );
            } else {
              plannerRequests += 1;
              // Invalid planning responses intentionally exercise graceful
              // planner fallback after consent, with no animation assets.
              request.response.headers.contentType = ContentType.json;
              request.response.write(
                jsonEncode({
                  'choices': [
                    {
                      'message': {'content': '{"segments":[]}'},
                    },
                  ],
                }),
              );
            }
          }
          await request.response.close();
        });
        SharedPreferences.setMockInitialValues({
          'active_character_id_v1': 'sophie',
          'ai_enabled': true,
          'fish_tts_enabled': true,
          'openai_base_url': 'http://127.0.0.1:${server.port}/v1',
        });
        FlutterSecureStorage.setMockInitialValues({
          'openai_api_key': 'test-only',
          if (!narrationRequest) 'fish_audio_api_key': 'test-rejected-key',
        });
        final controller = await AppController.load();
        controller.agentEnabled = false;
        controller.independentSpeechPerformance = false;
        controller.longTermMemoryEnabled = false;
        controller.fishAudioBaseUrl = 'http://127.0.0.1:${server.port}/tts';
        controller.configureLanguages(
          interface: AppLanguage.chinese,
          narrator: AppLanguage.chinese,
          characterReply: AppLanguage.japanese,
          translation: TranslationLanguage.none,
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
          await tester.runAsync(() async {
            await server.close(force: true);
            await serving.cancel();
            await support!.delete(recursive: true);
          });
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(pathProvider, null);
          HttpOverrides.global = originalOverrides;
        });

        Future<void> waitFor(bool Function() condition) async {
          for (var attempt = 0; attempt < 120 && !condition(); attempt += 1) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(condition(), isTrue, reason: 'loopback screen flow timed out');
        }

        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
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
        final send = find.byKey(const ValueKey('chat-send-button'));
        if (narrationRequest) {
          await tester.longPress(send);
          await tester.pump();
          await tester.enterText(
            find.byKey(const ValueKey('narration-input-0')),
            '我询问人偶普拉芙妲是否可以交换 LINE 联系方式。',
          );
        } else {
          await tester.enterText(
            find.byWidgetPredicate(
              (widget) =>
                  widget is TextField &&
                  widget.decoration?.hintText == '和苏菲说点什么…',
            ),
            '人偶普拉芙妲，可以交换 LINE 联系方式吗？',
          );
        }
        await tester.tap(send);
        await waitFor(() => find.text('加入信息').evaluate().isNotEmpty);
        expect(streamedReplies, 1);
        expect(receivedUserText.single, contains('普拉芙妲'));
        expect(receivedUserText.single, contains('LINE'));
        expect(plannerRequests, 0);
        expect(ttsRequests, 0);
        expect(controller.npcMessagingContacts, isEmpty);
        await tester.tap(find.text('加入信息'));
        await tester.pump(const Duration(milliseconds: 250));
        expect(controller.npcMessagingContacts.map((contact) => contact.id), [
          'sophie_plachta_doll',
        ]);
        if (!narrationRequest) {
          await waitFor(() => ttsRequests == 1);
        } else {
          await waitFor(() => plannerRequests > 0);
          expect(ttsRequests, 0);
        }
        await waitFor(() => tester.widget<IconButton>(send).icon is Icon);
        expect(controller.messages.last.isFailure, isFalse);
        // Success/failure snackbars from the main scene can cover the first
        // contact in this short test viewport; dismiss them as a user can.
        ScaffoldMessenger.of(tester.element(send)).clearSnackBars();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byIcon(Icons.smartphone_rounded));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('virtual-phone-app-messages')),
        );
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pump();
        expect(find.byType(NpcMessagesPage), findsOneWidget);
        final contact = find.byKey(
          const ValueKey('npc-contact-sophie_plachta_doll'),
        );
        expect(contact, findsOneWidget);
        expect(
          find.byKey(const ValueKey('npc-contact-sophie_plachta_young')),
          findsNothing,
        );
        await tester.tap(contact);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('npc-draft-sophie_plachta_doll')),
          findsOneWidget,
        );
        expect(controller.npcChats.threads, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  const pendingContactReply = '角色[sophie_plachta_doll]：WeChatってどんな連絡方法なの？';
  const smsAgreementReply =
      '角色[sophie_plachta_doll]：SMSでも構わないわ。'
      'そちらのほうが都合がいいなら、交換しましょう。';
  const explicitContactRequest = '人偶普拉芙妲，可以加个微信吗？';
  const channelFollowUp = '或者SMS也行';

  testWidgets(
    'adjacent SMS alternative uses the NPC response and opens its messages window',
    (tester) async {
      final fixture = await _NpcContactScreenFixture.open(
        tester,
        replies: const [
          _ScreenReply(pendingContactReply),
          _ScreenReply(smsAgreementReply),
        ],
      );
      await fixture.send(explicitContactRequest);
      await fixture.waitForIdle();
      expect(find.text('加入信息'), findsNothing);
      expect(fixture.controller.npcMessagingContacts, isEmpty);

      await fixture.send(channelFollowUp);
      await fixture.waitFor(() => find.text('加入信息').evaluate().isNotEmpty);
      expect(fixture.receivedUserText, hasLength(2));
      expect(fixture.receivedUserText.last, contains(channelFollowUp));
      expect(find.textContaining('短信 / SMS'), findsOneWidget);
      // Actual NPC agreement still requires the user's explicit confirmation.
      expect(fixture.controller.npcMessagingContacts, isEmpty);
      await tester.tap(find.text('加入信息'));
      await fixture.waitForIdle();
      expect(
        fixture.controller.npcMessagingContacts.map((contact) => contact.id),
        ['sophie_plachta_doll'],
      );

      await fixture.openMessages();
      final contact = find.byKey(
        const ValueKey('npc-contact-sophie_plachta_doll'),
      );
      expect(contact, findsOneWidget);
      expect(
        find.byKey(const ValueKey('npc-contact-sophie_plachta_young')),
        findsNothing,
      );
      await tester.tap(contact);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('npc-draft-sophie_plachta_doll')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed request cannot continue into an SMS alternative', (
    tester,
  ) async {
    final fixture = await _NpcContactScreenFixture.open(
      tester,
      replies: const [
        _ScreenReply('', statusCode: HttpStatus.unauthorized),
        _ScreenReply(smsAgreementReply),
      ],
    );
    await fixture.send(explicitContactRequest);
    await fixture.waitForIdle();
    expect(fixture.controller.messages.last.isFailure, isTrue);
    await fixture.send(channelFollowUp);
    await fixture.waitForIdle();
    expect(fixture.controller.messages.last.isFailure, isFalse);
    expect(find.text('加入信息'), findsNothing);
    expect(fixture.controller.npcMessagingContacts, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cancelled partial reply cannot continue into an SMS alternative',
    (tester) async {
      final fixture = await _NpcContactScreenFixture.open(
        tester,
        replies: const [
          _ScreenReply(pendingContactReply, holdOpen: true),
          _ScreenReply(smsAgreementReply),
        ],
      );
      await fixture.send(explicitContactRequest);
      await fixture.waitFor(
        () => fixture.controller.messages.last.text == pendingContactReply,
        reason: () =>
            'Partial reply is ${fixture.controller.messages.last.text}; '
            '${fixture.heldReplies.length} held replies',
      );
      expect(tester.widget<IconButton>(fixture.sendButton).icon, isA<Stack>());
      // The server has delivered real partial text without [DONE]. The same
      // button now stops generation, which can leave non-failure partial text.
      await tester.tap(fixture.sendButton);
      await tester.pump();
      await fixture.waitForIdle();
      expect(fixture.controller.messages.last.isFailure, isFalse);
      fixture.releaseHeldReplies();

      await fixture.send(channelFollowUp);
      await fixture.waitForIdle();
      expect(fixture.receivedUserText, hasLength(2));
      expect(fixture.controller.messages.last.text, smsAgreementReply);
      expect(find.text('加入信息'), findsNothing);
      expect(fixture.controller.npcMessagingContacts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an unrelated turn consumes the previous contact request', (
    tester,
  ) async {
    final fixture = await _NpcContactScreenFixture.open(
      tester,
      replies: const [
        _ScreenReply(pendingContactReply),
        _ScreenReply('角色[sophie_plachta_doll]：今日はいい天気だね。'),
        _ScreenReply(smsAgreementReply),
      ],
    );
    await fixture.send(explicitContactRequest);
    await fixture.waitForIdle();
    await fixture.send('先聊聊今天的天气吧。');
    await fixture.waitForIdle();
    await fixture.send(channelFollowUp);
    await fixture.waitForIdle();
    expect(find.text('加入信息'), findsNothing);
    expect(fixture.controller.npcMessagingContacts, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'declining the add dialog does not reopen it on channel follow-up',
    (tester) async {
      final fixture = await _NpcContactScreenFixture.open(
        tester,
        replies: const [
          _ScreenReply('角色[sophie_plachta_doll]：うん、いいよ！'),
          _ScreenReply(smsAgreementReply),
        ],
      );
      await fixture.send(explicitContactRequest);
      await fixture.waitFor(() => find.text('暂不添加').evaluate().isNotEmpty);
      await tester.tap(find.text('暂不添加'));
      await fixture.waitForIdle();
      await fixture.send(channelFollowUp);
      await fixture.waitForIdle();
      expect(find.text('加入信息'), findsNothing);
      expect(fixture.controller.npcMessagingContacts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a new save cannot inherit an unconfirmed contact request', (
    tester,
  ) async {
    final fixture = await _NpcContactScreenFixture.open(
      tester,
      replies: const [
        _ScreenReply(pendingContactReply),
        _ScreenReply(smsAgreementReply),
      ],
    );
    await fixture.send(explicitContactRequest);
    await fixture.waitForIdle();
    await fixture.controller.createLocalSlot(0, name: '新的联系人存档');
    await tester.pump();
    await fixture.send(channelFollowUp);
    await fixture.waitForIdle();
    expect(find.text('加入信息'), findsNothing);
    expect(fixture.controller.npcMessagingContacts, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

class _ScreenReply {
  const _ScreenReply(
    this.text, {
    this.statusCode = HttpStatus.ok,
    this.holdOpen = false,
  });

  final String text;
  final int statusCode;
  final bool holdOpen;
}

/// Real ChatScreen actions with only the HTTP response replaced. Keeping the
/// follow-up cases in one fixture makes their conversation boundaries explicit.
class _NpcContactScreenFixture {
  _NpcContactScreenFixture(
    this.tester,
    this.controller,
    this.receivedUserText,
    this.heldReplies,
  );

  final WidgetTester tester;
  final AppController controller;
  final List<String> receivedUserText;
  final List<Completer<void>> heldReplies;

  Finder get sendButton => find.byKey(const ValueKey('chat-send-button'));

  static Future<_NpcContactScreenFixture> open(
    WidgetTester tester, {
    required List<_ScreenReply> replies,
  }) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final originalOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final support = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('npc_contact_follow_up_'),
    ))!;
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      pathProvider,
      (call) async =>
          call.method == 'getApplicationSupportDirectory' ? support.path : null,
    );
    final server = (await tester.runAsync(
      () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    ))!;
    final receivedUserText = <String>[];
    final heldReplies = <Completer<void>>[];
    final serving = server.listen((request) async {
      request.response.persistentConnection = false;
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data['stream'] == true) {
        final replyIndex = receivedUserText.length;
        receivedUserText.add(
          ((data['messages'] as List).last as Map)['content'] as String,
        );
        // Unexpected extra main-chat calls must fail rather than accidentally
        // recycling consent from an earlier fixture response.
        final reply = replyIndex < replies.length
            ? replies[replyIndex]
            : const _ScreenReply('', statusCode: HttpStatus.badRequest);
        request.response.statusCode = reply.statusCode;
        if (reply.statusCode == HttpStatus.ok) {
          if (reply.holdOpen) {
            request.response.bufferOutput = false;
            request.response.headers.chunkedTransferEncoding = true;
          }
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': reply.text},
                },
              ],
            })}\n\n${reply.holdOpen ? '' : 'data: [DONE]\n\n'}',
          );
          if (reply.holdOpen) {
            final completion = Completer<void>();
            heldReplies.add(completion);
            try {
              await request.response.flush();
              await completion.future;
            } on HttpException {
              // Expected when the user cancels this intentionally open stream.
            } on SocketException {
              // The fixture client may close its socket before completion.
            }
          }
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"error":"fixture rejected request"}');
        }
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '{"segments":[]}'},
              },
            ],
          }),
        );
      }
      try {
        await request.response.close();
      } on HttpException {
        // Cancelling a partial response may close its connection first.
      } on SocketException {
        // Also permit the socket variant of the same expected cancellation.
      }
    });
    SharedPreferences.setMockInitialValues({
      'active_character_id_v1': 'sophie',
      'ai_enabled': true,
      'fish_tts_enabled': true,
      'openai_base_url': 'http://127.0.0.1:${server.port}/v1',
    });
    FlutterSecureStorage.setMockInitialValues({'openai_api_key': 'test-only'});
    final controller = await AppController.load();
    controller.agentEnabled = false;
    controller.independentSpeechPerformance = false;
    controller.longTermMemoryEnabled = false;
    controller.configureLanguages(
      interface: AppLanguage.chinese,
      narrator: AppLanguage.chinese,
      characterReply: AppLanguage.japanese,
      translation: TranslationLanguage.none,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.runAsync(() async {
        for (final completion in heldReplies) {
          if (!completion.isCompleted) completion.complete();
        }
        await server.close(force: true);
        await serving.cancel();
        await support.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(pathProvider, null);
      HttpOverrides.global = originalOverrides;
    });
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
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
    return _NpcContactScreenFixture(
      tester,
      controller,
      receivedUserText,
      heldReplies,
    );
  }

  Future<void> waitFor(
    bool Function() condition, {
    String Function()? reason,
  }) async {
    for (var attempt = 0; attempt < 120 && !condition(); attempt += 1) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      condition(),
      isTrue,
      reason: reason?.call() ?? 'loopback follow-up flow timed out',
    );
  }

  Future<void> send(String text) async {
    final previousRequests = receivedUserText.length;
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '和苏菲说点什么…',
      ),
      text,
    );
    await tester.tap(sendButton);
    await waitFor(() => receivedUserText.length > previousRequests);
  }

  Future<void> waitForIdle() =>
      waitFor(() => tester.widget<IconButton>(sendButton).icon is Icon);

  void releaseHeldReplies() {
    for (final completion in heldReplies) {
      if (!completion.isCompleted) completion.complete();
    }
  }

  Future<void> openMessages() async {
    ScaffoldMessenger.of(tester.element(sendButton)).clearSnackBars();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byIcon(Icons.smartphone_rounded));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('virtual-phone-app-messages')));
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
    expect(find.byType(NpcMessagesPage), findsOneWidget);
  }
}
