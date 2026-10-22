import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/glass_ui.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/virtual_phone.dart';
import 'package:ryza_chat_mvp/src/relay/relay_chat_page.dart';
import 'package:ryza_chat_mvp/src/relay/relay_conversations.dart';
import 'package:ryza_chat_mvp/src/relay/relay_page.dart';
import 'package:ryza_chat_mvp/src/relay/relay_protocol.dart';
import 'package:ryza_chat_mvp/src/relay/relay_service.dart';

import 'test_transport.dart';

/// UI-only fixture. Network/protocol behavior is tested by relay service tests.
class _FixtureConversations extends RelayConversations {
  _FixtureConversations(super.service);
  String availability = 'available';
  final List<(String, String)> refreshed = [];
  List<RelayHistoryMessage> fixtureMessages = [
    RelayHistoryMessage(
      id: 'message-user',
      role: 'user',
      text: '桌面用户的真实正文',
      createdAt: testNow,
      updatedAt: testNow,
      state: 'completed',
      seq: 1,
      revision: 1,
    ),
    RelayHistoryMessage(
      id: 'message-agent',
      role: 'assistant',
      text: '桌面 Agent 的完整回复',
      createdAt: testNow,
      updatedAt: testNow,
      state: 'completed',
      seq: 2,
      revision: 1,
    ),
  ];

  @override
  List<RelayHistoryMessage> messages(String profileId, String sessionId) =>
      fixtureMessages;

  @override
  RelayHistoryStatus history(String profileId, String sessionId) =>
      RelayHistoryStatus(
        loading: false,
        loadingOlder: false,
        error: null,
        availability: availability,
        hasMore: false,
      );

  @override
  Future<void> refresh(String profileId, String sessionId) async {
    refreshed.add((profileId, sessionId));
  }

  @override
  void activate(String? profileId, String? sessionId) {}

  void replaceMessages(List<RelayHistoryMessage> messages) {
    fixtureMessages = messages;
    notifyListeners();
  }
}

class _AcceptedTaskTransport extends TestTransport {
  @override
  Future<Json> request(
    Uri origin,
    String method,
    String path, {
    String? token,
    Json? body,
  }) async {
    final result = await super.request(
      origin,
      method,
      path,
      token: token,
      body: body,
    );
    if (path == '/v1/actions') {
      return {
        ...result,
        'status': 'accepted',
        'session_id': 'session-new-actual',
      };
    }
    return result;
  }
}

class _DelayedTaskTransport extends TestTransport {
  static const secondPcId = '00000000-0000-4000-8000-000000000099';
  final submitted = Completer<void>();
  final completion = Completer<void>();
  Object? submissionError;
  bool acceptTask = false;
  int actionAttempts = 0;

  @override
  Future<Json> request(
    Uri origin,
    String method,
    String path, {
    String? token,
    Json? body,
  }) async {
    if (path == '/v1/actions' && method == 'POST') {
      actionAttempts++;
      if (!submitted.isCompleted) submitted.complete();
      await completion.future;
      if (submissionError != null) throw submissionError!;
    }
    final result = await super.request(
      origin,
      method,
      path,
      token: token,
      body: body,
    );
    if (origin.host == 'second-relay.example.test') {
      if (path.endsWith('/status')) return {...result, 'pc_id': secondPcId};
      if (path == '/v1/state') {
        return {
          ...result,
          'devices': [
            {
              ...objects(result['devices']).single,
              'pc_id': secondPcId,
              'device_id': secondPcId,
              'device_name': '另一台PC',
            },
          ],
          for (final key in ['sessions', 'workspaces'])
            key: [
              for (final row in objects(result[key]))
                {...row, 'pc_id': secondPcId},
            ],
        };
      }
    }
    return path == '/v1/actions' && method == 'POST' && acceptTask
        ? {
            ...result,
            'status': 'accepted',
            'session_id': 'session-old-submission',
          }
        : result;
  }
}

Future<(RelayService, _FixtureConversations)> _create(
  TestTransport transport,
) async {
  final service = RelayService(
    store: MemoryRelayStore(),
    transport: transport,
    now: () => testNow,
  );
  await service.initialize();
  await service.pair(PairingQr.parse(qrText()), '测试手机', trustedByUser: true);
  await service.setForeground(true);
  return (service, _FixtureConversations(service));
}

Future<void> _mount(
  WidgetTester tester,
  RelayService service,
  RelayConversations conversations, {
  ValueNotifier<bool>? glass,
  double textScale = 1,
  ValueNotifier<double>? keyboard,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => AnimatedBuilder(
        animation: Listenable.merge([?glass, ?keyboard]),
        child: child,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            viewInsets: EdgeInsets.only(bottom: keyboard?.value ?? 0),
          ),
          child: GlassStyleScope(enabled: glass?.value ?? false, child: child!),
        ),
      ),
      home: RelayChatPage(
        service: service,
        conversations: conversations,
        embedded: true,
        managementBuilder: (_) => const Scaffold(body: Text('管理功能入口')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openSession(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('relay-chat-history')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('relay-session-session-1')));
  await tester.pumpAndSettle();
}

Future<void> _dispose(
  WidgetTester tester,
  RelayService service,
  RelayConversations conversations,
) async {
  await tester.pumpWidget(const SizedBox());
  conversations.dispose();
  service.dispose();
}

void main() {
  for (final switchProfile in [false, true]) {
    for (final failSubmission in [false, true]) {
      testWidgets(
        'a delayed task result stays with its original view (PC=$switchProfile, failure=$failSubmission)',
        (tester) async {
          final transport = _DelayedTaskTransport()
            ..acceptTask = !failSubmission;
          final (service, conversations) = await _create(transport);
          final originalProfileId =
              service.profiles.single['device_id'] as String;
          if (switchProfile) {
            final secondProfileId = await service.pair(
              PairingQr.parse(
                qrText(origin: 'https://second-relay.example.test'),
              ),
              '另一台测试手机',
              trustedByUser: true,
            );
            await service.sync(secondProfileId, snapshot: true);
          }
          await _mount(tester, service, conversations);
          await tester.tap(find.byType(DropdownButtonFormField<String>).last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('授权工作区').last);
          await tester.pumpAndSettle();
          final prompt = find.byKey(const ValueKey('relay-chat-prompt'));
          await tester.enterText(prompt, '创建旧会话任务');
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('relay-chat-send')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('确认发送'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          expect(transport.submitted.isCompleted, isTrue);
          if (switchProfile) {
            await tester.tap(find.byTooltip('选择目标 PC'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
            await tester.tap(find.text('另一台PC').last);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
          } else {
            await tester.tap(find.byKey(const ValueKey('relay-chat-history')));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
            await tester.tap(
              find.byKey(const ValueKey('relay-session-session-1')),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
            expect(conversations.refreshed.last.$2, 'session-1');
          }
          expect(tester.widget<TextField>(prompt).enabled, isFalse);
          expect(
            tester
                .widget<IconButton>(
                  find.byKey(const ValueKey('relay-chat-send')),
                )
                .onPressed,
            isNull,
          );
          if (failSubmission) {
            // An uncategorized transport failure reaches the page's error handler.
            transport.submissionError = StateError(
              'simulated transport failure',
            );
          }
          transport.completion.complete();
          await tester.pumpAndSettle();
          expect(
            switchProfile ? find.textContaining('另一台PC ·') : find.text('测试会话'),
            findsOneWidget,
          );
          expect(find.text('操作失败，请检查网络或配置后重试'), findsNothing);
          expect(tester.widget<TextField>(prompt).enabled, isTrue);
          final oldTask = service
              .collection(service.profile(originalProfileId)!, 'outbox')
              .single;
          expect(
            object(object(oldTask['body'])['payload'])['prompt'],
            '创建旧会话任务',
          );
          expect(
            oldTask['local_status'],
            failSubmission ? 'sending' : 'accepted',
          );
          await tester.tap(find.byKey(const ValueKey('relay-chat-new')));
          await tester.pumpAndSettle();
          await tester.enterText(prompt, '新会话草稿');
          await tester.pump(const Duration(seconds: 1));
          await tester.pumpAndSettle();
          expect(find.text('session-old-submission'), findsNothing);
          expect(tester.widget<TextField>(prompt).controller!.text, '新会话草稿');
          if (switchProfile) {
            await tester.tap(find.byTooltip('选择目标 PC'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('测试PC').last);
            await tester.pumpAndSettle();
          }
          expect(find.text('创建旧会话任务'), findsOneWidget);
          expect(find.text(failSubmission ? '发送中' : 'PC 已接受'), findsOneWidget);
          expect(transport.actionAttempts, 1);
          expect(tester.takeException(), isNull);
          await _dispose(tester, service, conversations);
        },
      );
    }
  }
  testWidgets(
    'phone-managed PC back remains behind drawer during animation and returns one level',
    (tester) async {
      final (service, conversations) = await _create(TestTransport());
      await tester.pumpWidget(
        MaterialApp(
          home: VirtualPhoneLauncher(
            language: AppLanguage.chinese,
            liquidGlass: false,
            pageManagedBackApps: const {VirtualPhoneApp.pcAgent},
            pages: {
              VirtualPhoneApp.pcAgent: (_) => RelayChatPage(
                service: service,
                conversations: conversations,
                embedded: true,
                managementBuilder: (_) => const Scaffold(body: Text('管理功能入口')),
              ),
            },
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.smartphone_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('virtual-phone-app-pcAgent')));
      await tester.pumpAndSettle();
      final back = find.byKey(const ValueKey('virtual-phone-back'));
      expect(back, findsOneWidget);
      expect(back.hitTestable(), findsOneWidget);
      final page = find.byType(RelayChatPage);
      final localNavigator = Navigator.of(tester.element(page));
      final scaffold = tester.state<ScaffoldState>(
        find.descendant(of: page, matching: find.byType(Scaffold)),
      );
      await tester.tap(find.byKey(const ValueKey('relay-chat-history')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(back.hitTestable(), findsNothing);
      expect(page, findsOneWidget);
      await tester.pumpAndSettle();
      expect(scaffold.isDrawerOpen, true);
      expect(back.hitTestable(), findsNothing);
      await localNavigator.maybePop();
      await tester.pumpAndSettle();
      expect(scaffold.isDrawerOpen, false);
      expect(page, findsOneWidget);
      expect(back.hitTestable(), findsOneWidget);
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(page, findsNothing);
      expect(
        find.byKey(const ValueKey('virtual-phone-screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('virtual-phone-app-pcAgent')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _dispose(tester, service, conversations);
    },
  );

  testWidgets(
    'embedded back button belongs to the page and stays behind the history drawer',
    (tester) async {
      final (service, conversations) = await _create(TestTransport());
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('虚拟手机桌面'))),
        ),
      );
      final navigator = Navigator.of(tester.element(find.text('虚拟手机桌面')));
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => RelayChatPage(
            service: service,
            conversations: conversations,
            embedded: true,
            managementBuilder: (_) => const Scaffold(body: Text('管理功能入口')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final back = find.byKey(const ValueKey('virtual-phone-back'));
      expect(back, findsOneWidget);
      expect(back.hitTestable(), findsOneWidget);
      final backRect = tester.getRect(back);
      final historyRect = tester.getRect(
        find.byKey(const ValueKey('relay-chat-history')),
      );
      expect(backRect.size, const Size(48, 48));
      expect(historyRect.left, greaterThanOrEqualTo(56));
      expect(historyRect.height, 48);
      final scaffold = tester.state<ScaffoldState>(
        find.descendant(
          of: find.byType(RelayChatPage),
          matching: find.byType(Scaffold),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('relay-chat-history')));
      await tester.pumpAndSettle();
      expect(scaffold.isDrawerOpen, true);
      expect(back.hitTestable(), findsNothing);
      expect(find.byType(RelayChatPage), findsOneWidget);
      await navigator.maybePop();
      await tester.pumpAndSettle();
      expect(scaffold.isDrawerOpen, false);
      expect(find.byType(RelayChatPage), findsOneWidget);
      expect(back.hitTestable(), findsOneWidget);
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(find.byType(RelayChatPage), findsNothing);
      expect(find.text('虚拟手机桌面'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _dispose(tester, service, conversations);
    },
  );

  testWidgets(
    'chat page keeps history and composer state during live glass changes',
    (tester) async {
      final glass = ValueNotifier(false);
      addTearDown(glass.dispose);
      final transport = TestTransport();
      final (service, conversations) = await _create(transport);
      await _mount(tester, service, conversations, glass: glass);
      final state = tester.state(find.byType(RelayChatPage));
      expect(
        find.byWidgetPredicate(
          (widget) => widget is BackdropFilter && widget.enabled,
        ),
        findsNothing,
      );
      final historyButton = tester.getRect(
        find.byKey(const ValueKey('relay-chat-history')),
      );
      expect(historyButton.left, greaterThanOrEqualTo(56));
      expect(historyButton.height, 48);
      await tester.tap(find.byKey(const ValueKey('relay-chat-history')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('relay-history-search')),
        '测试',
      );
      await tester.pump();
      glass.value = true;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(RelayChatPage)), same(state));
      expect(
        find.byWidgetPredicate(
          (widget) => widget is BackdropFilter && widget.enabled,
        ),
        findsNWidgets(2),
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('relay-history-search')),
            )
            .controller!
            .text,
        '测试',
      );
      await tester.enterText(
        find.byKey(const ValueKey('relay-history-search')),
        '',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('relay-session-session-1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('relay-chat-prompt')),
        '保留待发送文本',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('relay-chat-send')));
      await tester.pumpAndSettle();
      expect(find.text('向 PC 发送任务？'), findsOneWidget);
      final glassAlpha = tester
          .widget<AlertDialog>(find.byType(AlertDialog))
          .backgroundColor!
          .a;
      glass.value = false;
      await tester.pumpAndSettle();
      expect(
        tester.widget<AlertDialog>(find.byType(AlertDialog)).backgroundColor!.a,
        greaterThan(glassAlpha),
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('relay-chat-prompt')))
            .controller!
            .text,
        '保留待发送文本',
      );
      expect(
        transport.calls.where((call) => call['path'] == '/v1/actions'),
        isEmpty,
      );
      expect(
        find.byWidgetPredicate(
          (widget) => widget is BackdropFilter && widget.enabled,
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _dispose(tester, service, conversations);
    },
  );

  testWidgets(
    'snapshot tasks map to the real action session and keep PCs isolated',
    (tester) async {
      final transport = TestTransport();
      transport.state = snapshot(
        actions: [
          {
            'action_id': 'action-task',
            'action_type': 'task.start',
            'target_pc_id': pcId,
            'session_id': 'session-1',
            'task_id': 'task-real',
            'request_id': null,
            'status': 'accepted',
            'error': null,
            'updated_at': time,
          },
          {
            'action_id': 'action-foreign',
            'action_type': 'task.start',
            'target_pc_id': 'another-pc',
            'session_id': 'session-1',
            'task_id': 'task-foreign',
            'request_id': null,
            'status': 'accepted',
            'error': null,
            'updated_at': time,
          },
        ],
      );
      transport.state['tasks'] = [
        {
          'task_id': 'task-real',
          'summary': '映射后的真实任务',
          'status': 'succeeded',
          'error': null,
          'updated_at': time,
        },
        {
          'task_id': 'task-foreign',
          'summary': '其他 PC 的任务',
          'status': 'succeeded',
          'error': null,
          'updated_at': time,
        },
        {
          'task_id': 'task-unmapped',
          'summary': '未确认会话的任务',
          'status': 'succeeded',
          'error': null,
          'updated_at': time,
        },
      ];
      final (service, conversations) = await _create(transport);
      await _mount(tester, service, conversations);
      await _openSession(tester);
      expect(find.text('映射后的真实任务'), findsOneWidget);
      expect(find.text('其他 PC 的任务'), findsNothing);
      expect(find.text('未确认会话的任务'), findsNothing);
      await _dispose(tester, service, conversations);
    },
  );

  testWidgets('history follows latest replies but preserves reading position', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(340, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (service, conversations) = await _create(TestTransport());
    final messages = List.generate(
      24,
      (i) => RelayHistoryMessage(
        id: 'message-$i',
        role: i.isEven ? 'user' : 'assistant',
        text: '第 $i 条消息。${'用于检验长历史滚动位置的正文。' * 6}',
        createdAt: testNow,
        updatedAt: testNow,
        state: 'completed',
        seq: i,
        revision: 1,
      ),
    );
    conversations.fixtureMessages = messages;
    await _mount(tester, service, conversations);
    await _openSession(tester);
    final scroll = tester
        .widget<ListView>(
          find.byKey(
            ValueKey(
              'relay-chat-content-${service.profiles.single['device_id']}-session-1',
            ),
          ),
        )
        .controller!;
    expect(scroll.position.extentAfter, lessThan(2));
    conversations.replaceMessages([
      ...messages,
      RelayHistoryMessage(
        id: 'message-new',
        role: 'assistant',
        text: '刚同步的新回复。' * 20,
        createdAt: testNow,
        updatedAt: testNow,
        state: 'streaming',
        seq: 25,
        revision: 1,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(scroll.position.extentAfter, lessThan(2));
    scroll.jumpTo(120);
    await tester.pumpAndSettle();
    final readingOffset = scroll.offset;
    conversations.replaceMessages([
      ...messages,
      RelayHistoryMessage(
        id: 'message-new',
        role: 'assistant',
        text: '内容更长但阅读位置应该保持。' * 30,
        createdAt: testNow,
        updatedAt: testNow,
        state: 'completed',
        seq: 25,
        revision: 2,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(readingOffset, 1));
    await tester.tap(find.byKey(const ValueKey('relay-chat-new')));
    await tester.pumpAndSettle();
    await _openSession(tester);
    expect(scroll.position.extentAfter, lessThan(2));
    await _dispose(tester, service, conversations);
  });

  testWidgets('drawer searches actual PC sessions and opens full messages', (
    tester,
  ) async {
    final transport = TestTransport();
    final state = snapshot();
    state['sessions'] = [
      ...objects(state['sessions']),
      {
        'session_id': 'older-session',
        'pc_id': pcId,
        'workspace_id': 'workspace-1',
        'title': '一个更早会话',
        'status': 'idle',
        'updated_at': '2026-09-01T10:00:00Z',
      },
      {
        'session_id': 'foreign-session',
        'pc_id': 'another-pc',
        'title': '其他 PC 私有会话',
        'status': 'idle',
        'updated_at': time,
      },
    ];
    transport.state = state;
    final (service, conversations) = await _create(transport);
    await _mount(tester, service, conversations);
    await tester.tap(find.byKey(const ValueKey('relay-chat-history')));
    await tester.pumpAndSettle();
    expect(find.text('7 天内'), findsOneWidget);
    expect(find.text('更早'), findsOneWidget);
    expect(find.text('其他 PC 私有会话'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('relay-history-search')),
      '测试',
    );
    await tester.pumpAndSettle();
    expect(find.text('一个更早会话'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('relay-session-session-1')));
    await tester.pumpAndSettle();
    expect(find.text('桌面用户的真实正文'), findsOneWidget);
    expect(find.text('桌面 Agent 的完整回复'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('relay-chat-new')));
    await tester.pumpAndSettle();
    expect(find.text('桌面用户的真实正文'), findsNothing);
    expect(find.text('向 PC Agent 发送任务'), findsOneWidget);
    await _dispose(tester, service, conversations);
  });

  testWidgets(
    'unsupported history remains explicit and does not invent messages',
    (tester) async {
      final (service, conversations) = await _create(TestTransport());
      conversations.availability = 'unsupported';
      conversations.fixtureMessages = [];
      await _mount(tester, service, conversations);
      await _openSession(tester);
      expect(find.textContaining('尚未提供完整聊天历史'), findsOneWidget);
      expect(find.text('桌面 Agent 的完整回复'), findsNothing);
      await _dispose(tester, service, conversations);
    },
  );

  testWidgets('history permission names the desktop opt-in setting', (
    tester,
  ) async {
    final (service, conversations) = await _create(TestTransport());
    conversations.availability = 'forbidden';
    conversations.fixtureMessages = [];
    await _mount(tester, service, conversations);
    await _openSession(tester);
    expect(find.textContaining('为此手机启用读取历史'), findsOneWidget);
    expect(find.text('桌面 Agent 的完整回复'), findsNothing);
    await _dispose(tester, service, conversations);
  });

  testWidgets(
    'new task requires confirmation and queued task cannot duplicate',
    (tester) async {
      final transport = TestTransport();
      final (service, conversations) = await _create(transport);
      await _mount(tester, service, conversations);
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('授权工作区').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('relay-chat-prompt')),
        '请读取当前项目',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('relay-chat-send')));
      await tester.pumpAndSettle();
      expect(transport.calls.where((c) => c['path'] == '/v1/actions'), isEmpty);
      await tester.tap(find.text('确认发送'));
      await tester.pumpAndSettle();
      expect(
        transport.calls.where((c) => c['path'] == '/v1/actions'),
        hasLength(1),
      );
      expect(find.textContaining('等待 PC'), findsWidgets);
      await tester.enterText(
        find.byKey(const ValueKey('relay-chat-prompt')),
        '不要重复新建',
      );
      await tester.pump();
      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('relay-chat-send')),
      );
      expect(button.onPressed, isNull);
      expect(find.textContaining('新对话任务尚未确认结果'), findsOneWidget);
      await _dispose(tester, service, conversations);
    },
  );

  testWidgets('approval uses the existing explicit decision dialog', (
    tester,
  ) async {
    final transport = TestTransport()
      ..state = snapshot(requests: [request(kind: 'approval')]);
    final (service, conversations) = await _create(transport);
    await _mount(tester, service, conversations);
    await tester.tap(find.text('审批'));
    await tester.pumpAndSettle();
    expect(find.byType(RelayQuestionDialog), findsOneWidget);
    expect(transport.calls.where((c) => c['path'] == '/v1/actions'), isEmpty);
    await tester.tap(find.text('稍后 / 关闭'));
    await tester.pumpAndSettle();
    await _dispose(tester, service, conversations);
  });

  testWidgets(
    'accepted new task selects the PC assigned session before list sync',
    (tester) async {
      final transport = _AcceptedTaskTransport();
      final (service, conversations) = await _create(transport);
      await _mount(tester, service, conversations);
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('授权工作区').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('relay-chat-prompt')),
        '由 PC 创建会话',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('relay-chat-send')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认发送'));
      await tester.pumpAndSettle();
      expect(
        service
            .collection(service.profiles.single, 'sessions')
            .any((session) => session['session_id'] == 'session-new-actual'),
        isFalse,
      );
      expect(conversations.refreshed.last.$2, 'session-new-actual');
      expect(find.text('session-new-actual'), findsOneWidget);
      expect(find.text('桌面 Agent 的完整回复'), findsOneWidget);
      expect(find.textContaining('新对话任务尚未确认结果'), findsNothing);
      await _dispose(tester, service, conversations);
    },
  );

  testWidgets(
    'unknown send retries the original action instead of starting again',
    (tester) async {
      final transport = TestTransport()..failActionOnce = true;
      final (service, conversations) = await _create(transport);
      await _mount(tester, service, conversations);
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('授权工作区').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('relay-chat-prompt')),
        '仅发送一次任务',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('relay-chat-send')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认发送'));
      await tester.pumpAndSettle();
      final first = transport.calls.singleWhere(
        (c) => c['path'] == '/v1/actions',
      );
      final retry = find.text('幂等重试');
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      final calls = transport.calls
          .where((c) => c['path'] == '/v1/actions')
          .toList();
      expect(calls, hasLength(2));
      expect(
        object(calls.last['body'])['action_id'],
        object(first['body'])['action_id'],
      );
      await _dispose(tester, service, conversations);
    },
  );

  testWidgets('large text and keyboard keep a multiline task composer usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final keyboard = ValueNotifier(0.0);
    addTearDown(keyboard.dispose);
    final (service, conversations) = await _create(TestTransport());
    await _mount(
      tester,
      service,
      conversations,
      textScale: 2,
      keyboard: keyboard,
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('授权工作区').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('relay-chat-prompt')),
      '第一行任务\n第二行任务\n第三行任务\n第四行任务\n第五行任务',
    );
    keyboard.value = 260;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final send = find.byKey(const ValueKey('relay-chat-send'));
    await tester.ensureVisible(send);
    await tester.pumpAndSettle();
    expect(tester.getRect(send).bottom, lessThanOrEqualTo(308));
    expect(tester.widget<IconButton>(send).onPressed, isNotNull);
    await tester.tap(send);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认发送'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final pending = find.textContaining('新对话任务尚未确认结果');
    await tester.ensureVisible(pending);
    await tester.pumpAndSettle();
    expect(pending, findsOneWidget);
    expect(tester.getRect(pending).bottom, lessThanOrEqualTo(308));
    expect(tester.takeException(), isNull);
    await _dispose(tester, service, conversations);
  });

  testWidgets('narrow phone keeps drawer and composer within its page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(340, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (service, conversations) = await _create(TestTransport());
    await _mount(tester, service, conversations);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('relay-chat-history')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('relay-chat-management')));
    await tester.pumpAndSettle();
    expect(find.text('管理功能入口'), findsOneWidget);
    await _dispose(tester, service, conversations);
  });
}
