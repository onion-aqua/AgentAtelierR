import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/relay/relay_protocol.dart';
import 'package:ryza_chat_mvp/src/relay/relay_service.dart';

import 'test_transport.dart';

Json fragment(
  String id,
  String text, {
  int ordinal = 0,
  int part = 0,
  int count = 1,
}) => {
  'message_id': id,
  'role': 'assistant',
  'body': text,
  'created_at': time,
  'updated_at': time,
  'ordinal': ordinal,
  'status': 'completed',
  'part_index': part,
  'part_count': count,
};

Json historyPage(
  List<Json> messages, {
  int revision = 1,
  String? cursor,
  String connection = 'online',
}) => {
  'pc_id': pcId,
  'session_id': 'session-1',
  'workspace_id': 'workspace-1',
  'snapshot_seq': 9000,
  'history_revision': revision,
  'sync_state': 'ready',
  'connection_state': connection,
  'messages': messages,
  'next_cursor': cursor,
  'has_more': cursor != null,
};

class HistoryTransport extends TestTransport {
  bool historyPermission = true;
  bool historySupported = true;
  String? historyError;
  bool changeOnSecondPage = false;
  List<Json>? projectedEvents;
  Completer<void>? messageArrived;
  Completer<void>? messageGate;
  final Map<String, Json> pages = {
    '': historyPage([fragment('m1', '本当の返事')]),
  };
  @override
  Future<Json> request(
    Uri origin,
    String method,
    String path, {
    String? token,
    Json? body,
  }) async {
    if (path.endsWith('/status')) {
      return {
        ...await super.request(origin, method, path, token: token, body: body),
        'history_read': historyPermission,
      };
    }
    final uri = Uri.parse(path);
    if (uri.path == '/v1/events' && projectedEvents != null) {
      calls.add({'method': method, 'path': path, 'token': token});
      return {
        'events': projectedEvents,
        'next_seq': projectedEvents!.last['seq'],
        'has_more': false,
      };
    }
    if (uri.path == '/v1/features' ||
        uri.path == '/v1/sessions' ||
        uri.path.startsWith('/v1/sessions/')) {
      calls.add({'method': method, 'path': path, 'token': token});
      if (revoked) throw const RelayFailure('DEVICE_REVOKED');
      if (uri.path == '/v1/features') {
        return {
          'protocol_version': 1,
          'pc_id': pcId,
          'connection_state': 'online',
          'features': {
            'session_history': {
              'version': 1,
              'supported': historySupported,
              'permission': historyPermission,
              'state': !historySupported
                  ? 'unsupported'
                  : historyPermission
                  ? 'ready'
                  : 'forbidden',
            },
          },
        };
      }
      if (!historyPermission) throw const RelayFailure('FORBIDDEN');
      if (uri.path == '/v1/sessions') {
        return {
          'pc_id': pcId,
          'connection_state': 'online',
          'snapshot_seq': 9000,
          'sessions': state['sessions'],
          'next_cursor': null,
          'has_more': false,
        };
      }
      if (historyError != null) throw RelayFailure(historyError!);
      if (messageArrived != null && !messageArrived!.isCompleted) {
        messageArrived!.complete();
      }
      if (messageGate != null) await messageGate!.future;
      final cursor = uri.queryParameters['cursor'] ?? '';
      if (changeOnSecondPage && cursor.isNotEmpty) {
        changeOnSecondPage = false;
        pages[''] = historyPage([fragment('m2', '編集された本文')], revision: 2);
        throw const RelayFailure('HISTORY_CHANGED', retryable: true);
      }
      return object(jsonDecode(jsonEncode(pages[cursor])));
    }
    return super.request(origin, method, path, token: token, body: body);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryRelayStore store;
  late HistoryTransport transport;
  late RelayService service;
  late String id;
  setUp(() async {
    store = MemoryRelayStore();
    transport = HistoryTransport();
    service = RelayService(
      store: store,
      transport: transport,
      now: () => testNow,
    );
    await service.initialize();
    id = await service.pair(
      PairingQr.parse(qrText()),
      '手机',
      trustedByUser: true,
    );
    await service.setForeground(true);
  });
  tearDown(() => service.dispose());
  Json cached() => service.collection(service.profile(id)!, 'history').single;

  test('joins fragments across opaque pages, persists full revision and never ACKs history watermark', () async {
    transport.pages[''] = historyPage([
      fragment('m1', 'こんにちは', part: 0, count: 2),
    ], cursor: 'cursor+/=');
    transport.pages['cursor+/='] = historyPage([
      fragment('m1', 'ライザ。', part: 1, count: 2),
    ]);
    await service.refreshSessionHistory(id, 'session-1');
    expect(objects(cached()['messages']).single['content'], 'こんにちはライザ。');
    expect(cached()['revision'], 1);
    expect(cached()['has_more'], false);
    expect(
      transport.calls
          .where((c) => c['path'].toString().contains('/messages'))
          .map((c) => Uri.parse(c['path'] as String).queryParameters['cursor'])
          .last,
      'cursor+/=',
    );
    expect(
      object(
        object(jsonDecode(store.data!))['profiles'].single,
      )['cache']['cursor'],
      0,
    );
    expect(
      transport.calls
          .where((c) => c['path'] == '/v1/events/ack')
          .every((c) => object(c['body'])['seq'] == 0),
      true,
    );
  });

  test('revision change discards incomplete pages; edits and deletions replace full cache', () async {
    await service.refreshSessionHistory(id, 'session-1');
    transport.pages[''] = historyPage(
      [fragment('m1', '削除予定', part: 0, count: 2)],
      revision: 2,
      cursor: 'next',
    );
    transport.changeOnSecondPage = true;
    await service.refreshSessionHistory(id, 'session-1');
    expect(objects(cached()['messages']).map((m) => m['message_id']), ['m2']);
    expect(objects(cached()['messages']).single['content'], '編集された本文');
    expect(cached()['revision'], 2);
  });

  test('incomplete/mismatched fragments and failed secure writes preserve last complete cache', () async {
    await service.refreshSessionHistory(id, 'session-1');
    transport.pages[''] = historyPage([
      fragment('m2', '未完成', part: 0, count: 2),
    ], revision: 2);
    await expectLater(
      service.refreshSessionHistory(id, 'session-1'),
      throwsFormatException,
    );
    expect(objects(cached()['messages']).single['message_id'], 'm1');
    transport.pages[''] = historyPage([fragment('m2', '新本文')], revision: 2);
    store.failWrite = true;
    await expectLater(
      service.refreshSessionHistory(id, 'session-1'),
      throwsStateError,
    );
    expect(objects(cached()['messages']).single['message_id'], 'm1');
  });

  test('read permission withdrawn clears persisted正文 and stops network history reads', () async {
    await service.refreshSessionHistory(id, 'session-1');
    transport.historyPermission = false;
    await service.sync(id);
    expect(service.profile(id)!['history_read'], false);
    expect(service.collection(service.profile(id)!, 'history'), isEmpty);
    expect(store.data, isNot(contains('本当の返事')));
    final before = transport.calls
        .where((c) => c['path'].toString().contains('/messages'))
        .length;
    await service.refreshSessionHistory(id, 'session-1');
    expect(cached()['availability'], 'forbidden');
    expect(
      transport.calls
          .where((c) => c['path'].toString().contains('/messages'))
          .length,
      before,
    );
  });

  test(
    'scope removal event clears history; redacted event retains contiguous ACK',
    () async {
      await service.refreshSessionHistory(id, 'session-1');
      transport.state['sessions'] = <Json>[];
      transport.events = [
        event(
          1,
          type: 'pc.state.updated',
          payload: {'sessions': [], 'workspaces': []},
        ),
        {
          ...event(
            2,
            type: 'scope.redacted',
            id: newUuid(),
            payload: {'reason': 'scope_removed'},
          ),
          'session_id': null,
          'request_id': null,
          'expires_at': null,
        },
      ];
      await service.sync(id);
      expect(service.collection(service.profile(id)!, 'history'), isEmpty);
      expect(object(service.profile(id)!['cache'])['cursor'], 2);
      expect(
        transport.calls
            .where((c) => c['path'] == '/v1/events/ack')
            .last['body'],
        {'seq': 2},
      );
    },
  );

  test(
    'device revocation while reading clears credentials and all history',
    () async {
      await service.refreshSessionHistory(id, 'session-1');
      transport.revoked = true;
      await service.refreshSessionHistory(id, 'session-1');
      expect(service.profile(id)!['state'], 'revoked');
      expect(service.profile(id)!.containsKey('device_token'), false);
      expect(service.collection(service.profile(id)!, 'history'), isEmpty);
    },
  );

  test(
    'redaction overrides an already seen event without retaining question body',
    () async {
      transport.events = [event(1)];
      await service.sync(id);
      expect(
        service.collection(service.profile(id)!, 'requests'),
        hasLength(1),
      );
      transport.projectedEvents = [
        {
          ...event(
            1,
            type: 'scope.redacted',
            payload: {'reason': 'scope_removed'},
          ),
          'session_id': null,
          'request_id': null,
          'expires_at': null,
        },
      ];
      await service.sync(id);
      expect(service.collection(service.profile(id)!, 'requests'), isEmpty);
      expect(
        service.collection(service.profile(id)!, 'events').single['type'],
        'scope.redacted',
      );
      expect(object(service.profile(id)!['cache'])['cursor'], 1);
      expect(store.data, isNot(contains('问题正文')));
    },
  );

  test('offline PC complete cache is readable and old transport is explicitly unsupported', () async {
    transport.pages[''] = historyPage([
      fragment('m1', 'オフラインの履歴'),
    ], connection: 'offline');
    await service.refreshSessionHistory(id, 'session-1');
    expect(cached()['connection_state'], 'offline');
    expect(objects(cached()['messages']).single['content'], 'オフラインの履歴');
    transport.historySupported = false;
    await service.refreshSessionHistory(id, 'session-1');
    expect(cached()['availability'], 'unsupported');
    expect(cached()['messages'], isEmpty);
  });

  test('a slow history page does not block tasks and cannot restore cache after unpair', () async {
    transport.messageArrived = Completer<void>();
    transport.messageGate = Completer<void>();
    final reading = service.refreshSessionHistory(id, 'session-1');
    await transport.messageArrived!.future;
    final actionId = await service
        .startTask(id, prompt: '明示的な作業', sessionId: 'session-1')
        .timeout(const Duration(seconds: 2));
    expect(actionId, isNotEmpty);
    await service.unpair(id).timeout(const Duration(seconds: 2));
    transport.messageGate!.complete();
    await reading;
    expect(service.profile(id), isNull);
    expect(store.data, isNot(contains('本当の返事')));
  });

  test(
    'same revision refresh does not fetch all body pages repeatedly',
    () async {
      transport.pages[''] = historyPage([
        fragment('m1', 'A', part: 0, count: 2),
      ], cursor: 'next');
      transport.pages['next'] = historyPage([
        fragment('m1', 'B', part: 1, count: 2),
      ]);
      await service.refreshSessionHistory(id, 'session-1');
      final before = transport.calls
          .where((c) => c['path'].toString().contains('/messages'))
          .length;
      await service.refreshSessionHistory(id, 'session-1');
      expect(
        transport.calls
            .where((c) => c['path'].toString().contains('/messages'))
            .length,
        before + 1,
      );
      expect(objects(cached()['messages']).single['content'], 'AB');
    },
  );
}
