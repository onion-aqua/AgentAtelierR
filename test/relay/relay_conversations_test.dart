import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/relay/relay_conversations.dart';
import 'package:ryza_chat_mvp/src/relay/relay_protocol.dart';
import 'package:ryza_chat_mvp/src/relay/relay_service.dart';

import 'test_transport.dart';

class _HistoryService extends RelayService {
  _HistoryService()
    : super(store: MemoryRelayStore(), transport: TestTransport());

  final Map<String, Json> bindings = {};
  final List<(String, String, bool)> refreshes = [];
  Completer<void>? pending;
  Object? failure;

  @override
  Json? profile(String id) => bindings[id];

  @override
  Future<void> refreshSessionHistory(
    String profileId,
    String sessionId, {
    bool older = false,
  }) async {
    refreshes.add((profileId, sessionId, older));
    if (pending != null) await pending!.future;
    if (failure != null) throw failure!;
  }

  void changed() => notifyListeners();

  void foregroundChanged(bool value) {
    foreground = value;
    changed();
  }
}

Json _message(
  String id,
  int seq, {
  String session = 'session-1',
  int revision = 1,
  String text = '桌面正文',
  String role = 'assistant',
  String state = 'completed',
}) => {
  'message_id': id,
  'session_id': session,
  'seq': seq,
  'revision': revision,
  'role': role,
  'content': text,
  'created_at': '2026-10-05T12:00:00Z',
  'updated_at': '2026-10-05T12:01:00Z',
  'state': state,
};

Json _profile(List<Json> messages, {bool hasMore = false}) => {
  'state': 'confirmed',
  'device_token': 'test-only-device-token',
  'history_read': true,
  'cache': {
    ...RelayService.emptyCache(),
    'history': [
      {
        'session_id': 'session-1',
        'availability': 'available',
        'has_more': hasMore,
        'messages': messages,
      },
    ],
    'tasks': [
      {'summary': '这不是桌面聊天正文'},
    ],
    'outbox': [
      {
        'body': {
          'payload': {'prompt': '这不是完整历史消息'},
        },
      },
    ],
  },
};

void main() {
  test(
    'desktop messages retain revisions and order without task substitutes',
    () {
      final service = _HistoryService();
      final conversations = RelayConversations(service);
      addTearDown(conversations.dispose);
      addTearDown(service.dispose);
      service.bindings['phone-1'] = _profile([
        _message('reply', 2, text: '旧片段'),
        _message('prompt', 1, text: '真正的用户消息', role: 'user'),
        _message('reply', 2, revision: 3, text: '最新正文', state: 'streaming'),
        _message('reply', 2, revision: 2, text: '过期更新'),
        _message('other', 3, session: 'another-session'),
        {'message_id': 'incomplete'},
      ]);
      final messages = conversations.messages('phone-1', 'session-1');
      expect(messages.map((m) => m.id), ['prompt', 'reply']);
      expect(messages.map((m) => m.text), ['真正的用户消息', '最新正文']);
      expect(messages.last.role, 'assistant');
      expect(messages.last.seq, 2);
      expect(messages.last.revision, 3);
      expect(messages.last.state, 'streaming');
      expect(messages.last.createdAt, DateTime.utc(2026, 10, 5, 12));
      expect(messages.last.updatedAt, DateTime.utc(2026, 10, 5, 12, 1));
      expect(() => messages.clear(), throwsUnsupportedError);
    },
  );

  test('identical session IDs in different PC profiles remain isolated', () {
    final service = _HistoryService();
    final conversations = RelayConversations(service);
    addTearDown(conversations.dispose);
    addTearDown(service.dispose);
    service.bindings['phone-1'] = _profile([
      _message('same-message-id', 1, text: '第一台 PC'),
    ]);
    service.bindings['phone-2'] = _profile([
      _message('same-message-id', 1, text: '第二台 PC'),
    ]);
    expect(
      conversations.messages('phone-1', 'session-1').single.text,
      '第一台 PC',
    );
    expect(
      conversations.messages('phone-2', 'session-1').single.text,
      '第二台 PC',
    );
    expect(conversations.messages('phone-1', 'another-session'), isEmpty);
    expect(
      conversations.history('phone-1', 'another-session').availability,
      'not_ready',
    );
    expect(conversations.messages('missing-profile', 'session-1'), isEmpty);
  });

  test(
    'refreshes are deduplicated and older loads require cached pagination',
    () async {
      final service = _HistoryService();
      final conversations = RelayConversations(service);
      addTearDown(conversations.dispose);
      addTearDown(service.dispose);
      service.bindings['phone-1'] = _profile([], hasMore: true);
      service.pending = Completer<void>();
      final first = conversations.refresh('phone-1', 'session-1');
      final duplicate = conversations.refresh('phone-1', 'session-1');
      final olderWhileLoading = conversations.loadOlder('phone-1', 'session-1');
      expect(identical(first, duplicate), isTrue);
      expect(identical(first, olderWhileLoading), isTrue);
      expect(service.refreshes, [('phone-1', 'session-1', false)]);
      expect(conversations.history('phone-1', 'session-1').loading, isTrue);
      expect(
        conversations.history('phone-1', 'session-1').loadingOlder,
        isFalse,
      );
      service.pending!.complete();
      await first;
      expect(conversations.history('phone-1', 'session-1').loading, isFalse);

      service.pending = Completer<void>();
      final older = conversations.loadOlder('phone-1', 'session-1');
      expect(service.refreshes.last, ('phone-1', 'session-1', true));
      expect(
        conversations.history('phone-1', 'session-1').loadingOlder,
        isTrue,
      );
      service.pending!.complete();
      await older;
      service.bindings['phone-1'] = _profile([]);
      await conversations.loadOlder('phone-1', 'session-1');
      expect(service.refreshes, hasLength(2));
    },
  );

  test('failed refresh preserves cached body and never exposes raw transport errors', () async {
    final service = _HistoryService();
    final conversations = RelayConversations(service);
    addTearDown(conversations.dispose);
    addTearDown(service.dispose);
    service.bindings['phone-1'] = _profile([_message('reply', 1)]);
    service.failure = StateError('Authorization: sensitive-test-value');
    await conversations.refresh('phone-1', 'session-1');
    expect(
      conversations.history('phone-1', 'session-1').error,
      '历史记录暂时无法读取，请稍后重试',
    );
    expect(conversations.messages('phone-1', 'session-1').single.text, '桌面正文');
    service.failure = null;
    await conversations.refresh('phone-1', 'session-1');
    expect(conversations.history('phone-1', 'session-1').error, isNull);
  });

  testWidgets(
    'active session polls in foreground and resumes once after background',
    (tester) async {
      final service = _HistoryService();
      final conversations = RelayConversations(service);
      service.bindings['phone-1'] = _profile([]);
      service.foregroundChanged(true);
      conversations.activate('phone-1', 'session-1');
      await tester.pump();
      expect(service.refreshes, hasLength(1));
      conversations.activate('phone-1', 'session-1');
      await tester.pump();
      expect(service.refreshes, hasLength(1));
      await tester.pump(const Duration(seconds: 15));
      expect(service.refreshes, hasLength(2));
      service.foregroundChanged(false);
      await tester.pump(const Duration(minutes: 1));
      expect(service.refreshes, hasLength(2));
      service.foregroundChanged(true);
      await tester.pump();
      expect(service.refreshes, hasLength(3));
      conversations.activate(null, null);
      await tester.pump(const Duration(seconds: 30));
      expect(service.refreshes, hasLength(3));
      conversations.dispose();
      service.dispose();
    },
  );

  testWidgets(
    'revocation immediately hides retained history and stops active polling',
    (tester) async {
      final service = _HistoryService();
      final conversations = RelayConversations(service);
      service.bindings['phone-1'] = _profile([
        _message('reply', 1),
      ], hasMore: true);
      service.foregroundChanged(true);
      var changes = 0;
      conversations.addListener(() => changes++);
      conversations.activate('phone-1', 'session-1');
      await tester.pump();
      final originalChanges = changes;
      service.bindings['phone-1']!['state'] = 'revoked';
      service.changed();
      expect(changes, greaterThan(originalChanges));
      expect(conversations.messages('phone-1', 'session-1'), isEmpty);
      expect(conversations.history('phone-1', 'session-1').hasMore, isFalse);
      await tester.pump(const Duration(minutes: 1));
      await conversations.refresh('phone-1', 'session-1');
      expect(service.refreshes, hasLength(1));
      conversations.dispose();
      service.dispose();
    },
  );

  testWidgets(
    'history permission is independent from task and pairing access',
    (tester) async {
      final service = _HistoryService();
      final conversations = RelayConversations(service);
      service.bindings['phone-1'] = _profile([_message('reply', 1)]);
      service.foregroundChanged(true);
      conversations.activate('phone-1', 'session-1');
      await tester.pump();
      service.bindings['phone-1']!['history_read'] = false;
      service.changed();
      expect(
        conversations.history('phone-1', 'session-1').availability,
        'forbidden',
      );
      expect(conversations.messages('phone-1', 'session-1'), isEmpty);
      await tester.pump(const Duration(seconds: 30));
      await conversations.refresh('phone-1', 'session-1');
      expect(service.refreshes, hasLength(1));
      service.bindings['phone-1']!['history_read'] = true;
      service.changed();
      await tester.pump();
      expect(service.refreshes, hasLength(2));
      expect(
        conversations.history('phone-1', 'session-1').availability,
        'available',
      );
      await tester.pump(const Duration(seconds: 15));
      expect(service.refreshes, hasLength(3));
      conversations.dispose();
      service.dispose();
    },
  );

  testWidgets(
    'an older server is unsupported without exposing its retained cache',
    (tester) async {
      final service = _HistoryService();
      final conversations = RelayConversations(service);
      final binding = _profile([_message('reply', 1)], hasMore: true);
      binding['history_read'] = false;
      (binding['cache'] as Json)['history_feature'] = {
        'supported': false,
        'permission': false,
      };
      service.bindings['phone-1'] = binding;
      service.foregroundChanged(true);
      conversations.activate('phone-1', 'session-1');
      await tester.pump(const Duration(seconds: 30));
      expect(
        conversations.history('phone-1', 'session-1').availability,
        'unsupported',
      );
      expect(conversations.messages('phone-1', 'session-1'), isEmpty);
      expect(service.refreshes, isEmpty);
      (binding['cache'] as Json)['history_feature'] = {
        'supported': true,
        'permission': false,
      };
      service.changed();
      expect(
        conversations.history('phone-1', 'session-1').availability,
        'forbidden',
      );
      expect(conversations.messages('phone-1', 'session-1'), isEmpty);
      expect(service.refreshes, isEmpty);
      conversations.dispose();
      service.dispose();
    },
  );

  testWidgets(
    'selected history revision refreshes once without polling on every notification',
    (tester) async {
      final service = _HistoryService();
      final conversations = RelayConversations(service);
      final binding = _profile([]);
      (binding['cache'] as Json)['sessions'] = [
        {'session_id': 'session-1', 'history_revision': 1},
      ];
      service.bindings['phone-1'] = binding;
      service.foregroundChanged(true);
      conversations.activate('phone-1', 'session-1');
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        service.changed();
        await tester.pump();
      }
      expect(service.refreshes, hasLength(1));
      (binding['cache'] as Json)['sessions'] = [
        {'session_id': 'session-1', 'history_revision': 2},
      ];
      service.changed();
      await tester.pump();
      expect(service.refreshes, hasLength(2));
      service.changed();
      await tester.pump();
      expect(service.refreshes, hasLength(2));

      (binding['cache'] as Json)['events'] = [
        {
          'event_id': 'history-update-1',
          'type': 'session.history.updated',
          'session_id': 'session-1',
        },
      ];
      service.changed();
      await tester.pump();
      expect(service.refreshes, hasLength(3));
      service.changed();
      await tester.pump();
      expect(service.refreshes, hasLength(3));
      conversations.dispose();
      service.dispose();
    },
  );
}
