import 'dart:async';
import 'dart:convert';

import 'package:ryza_chat_mvp/src/relay/relay_protocol.dart';
import 'package:ryza_chat_mvp/src/relay/relay_store.dart';
import 'package:ryza_chat_mvp/src/relay/relay_transport.dart';
import 'package:ryza_chat_mvp/src/relay/relay_push.dart';

/// Test-only, replaceable transport. Never imported by lib or a production APK.
class MemoryRelayStore implements RelayStore {
  String? data;
  bool failWrite = false;
  @override
  Future<String?> read() async => data;
  @override
  Future<void> write(String value) async {
    if (failWrite) throw StateError('simulated storage failure');
    data = value;
  }
}

const pcId = '00000000-0000-4000-8000-000000000001';
const pairingId = '00000000-0000-4000-8000-000000000002';
const eventId = '00000000-0000-4000-8000-000000000003';
const time = '2026-10-04T10:00:00Z';
final testNow = DateTime.parse(time);
String qrText({
  String origin = 'https://relay.example.test',
  String id = pairingId,
}) => jsonEncode({
  'type': 'agent-relay-pair',
  'v': 1,
  'server_base_url': origin,
  'pairing_id': id,
  'pairing_secret': 'a' * 64,
});
Json request({
  String state = 'pending',
  String kind = 'question',
  String id = 'request-1',
}) => {
  'request_id': id,
  'pc_id': pcId,
  'session_id': 'session-1',
  'kind': kind,
  'state': state,
  'created_at': time,
  'expires_at': '2026-10-04T11:00:00Z',
  'payload': kind == 'approval'
      ? {
          'title': '审批',
          'description': '请批准',
          'operation_summary': '修改工作区文件',
          'allowed_decisions': ['approve', 'reject'],
          'state': state,
        }
      : {
          'title': '请选择',
          'body': '问题正文',
          'input': {
            'kind': 'single_choice',
            'options': [
              {'id': 'a', 'label': '甲'},
              {'id': 'b', 'label': '乙'},
            ],
            'allow_text': false,
          },
          'state': state,
        },
};
Json snapshot({int seq = 0, List<Json>? requests, List<Json>? actions}) => {
  'snapshot_seq': seq,
  'devices': [
    {
      'device_id': pcId,
      'role': 'pc',
      'device_name': '测试PC',
      'pc_id': pcId,
      'connection_state': 'online',
      'capabilities': [],
    },
  ],
  'workspaces': [
    {'workspace_id': 'workspace-1', 'pc_id': pcId, 'label': '授权工作区'},
  ],
  'sessions': [
    {
      'session_id': 'session-1',
      'pc_id': pcId,
      'workspace_id': 'workspace-1',
      'title': '测试会话',
      'status': 'running',
      'updated_at': time,
    },
  ],
  'requests': requests ?? [],
  'tasks': [],
  'actions': actions ?? [],
};
Json event(
  int seq, {
  String type = 'question.created',
  String id = eventId,
  Json? payload,
  String rid = 'request-1',
}) => {
  'event_id': id,
  'seq': seq,
  'source_event_id': newUuid(),
  'type': type,
  'pc_id': pcId,
  'session_id': 'session-1',
  'request_id': rid,
  'created_at': time,
  'expires_at': '2026-10-04T11:00:00Z',
  'payload': payload ?? request()['payload'],
};

class TestSocket implements RelaySocket {
  final frames = StreamController<Object?>.broadcast();
  final List<Json> sent = [];
  @override
  Stream<Object?> get messages => frames.stream;
  @override
  void send(Json value) => sent.add(value);
  @override
  Future<void> close() async {
    if (!frames.isClosed) await frames.close();
  }
}

class TestTransport implements RelayTransport {
  String pairingState = 'confirmed';
  List<String> capabilities = [
    'question.answer',
    'approval.respond',
    'task.start',
    'task.cancel',
  ];
  Json? singleEventResponse;
  String? claimError;
  bool failActionOnce = false;
  String actionResponseStatus = 'queued';
  bool revoked = false;
  bool cursorExpired = false;
  Json state = snapshot();
  List<Json> events = [];
  final List<Json> calls = [];
  final List<TestSocket> sockets = [];
  final Map<String, Json> results = {};
  void Function(Json call)? before;
  @override
  Future<Json> request(
    Uri origin,
    String method,
    String path, {
    String? token,
    Json? body,
  }) async {
    final call = {
      'origin': origin.toString(),
      'method': method,
      'path': path,
      'token': token,
      'body': body,
    };
    calls.add(call);
    before?.call(call);
    if (path == '/v1/pairings/claim') {
      if (claimError != null) throw RelayFailure(claimError!, retryable: true);
      return {
        'pairing_id': body!['pairing_id'],
        'state': 'pending_confirmation',
        'expires_at': '2026-10-04T11:00:00Z',
      };
    }
    if (path.endsWith('/status')) {
      return {
        'state': pairingState,
        'pc_id': pcId,
        'device_id': null,
        'expires_at': '2026-10-04T11:00:00Z',
        'capabilities': capabilities,
      };
    }
    if (revoked) throw const RelayFailure('DEVICE_REVOKED');
    if (path == '/v1/state') return object(jsonDecode(jsonEncode(state)));
    if (path.startsWith('/v1/events?')) {
      if (cursorExpired) {
        cursorExpired = false;
        throw const RelayFailure('CURSOR_EXPIRED');
      }
      final after = int.parse(Uri.parse(path).queryParameters['after_seq']!);
      final list = events.where((e) => (e['seq'] as int) > after).toList();
      return {
        'events': list,
        'next_seq': list.isEmpty ? after : list.last['seq'],
        'has_more': false,
      };
    }
    if (path == '/v1/events/ack') return {};
    if (path.startsWith('/v1/events/')) {
      return singleEventResponse ??
          {
            'event': events.firstWhere(
              (e) => path.endsWith(e['event_id'] as String),
            ),
          };
    }
    if (path == '/v1/actions') {
      if (failActionOnce) {
        failActionOnce = false;
        throw const RelayFailure('NETWORK', retryable: true);
      }
      return {'action_id': body!['action_id'], 'status': actionResponseStatus};
    }
    if (path.startsWith('/v1/actions/')) {
      return {
        'action':
            results[path.split('/').last] ??
            {'action_id': path.split('/').last, 'status': 'delivered'},
      };
    }
    if (path == '/v1/push/subscriptions') return {'subscription_id': 'sub-1'};
    if (method == 'DELETE') return {};
    throw StateError('Unexpected test request $path');
  }

  @override
  Future<RelaySocket> connect(Uri origin, String token) async {
    final s = TestSocket();
    sockets.add(s);
    return s;
  }

  @override
  void dispose() {
    for (final s in sockets) {
      unawaited(s.close());
    }
  }
}

class TestPush implements RelayPushProvider {
  final tokens = StreamController<String>.broadcast();
  final messages = StreamController<PushHint>.broadcast();
  bool deleted = false;
  @override
  String get name => 'test-only';
  @override
  Future<String?> initialize() async => 'fake-registration-token';
  @override
  Stream<String> get tokenChanges => tokens.stream;
  @override
  Stream<PushHint> get hints => messages.stream;
  @override
  Future<PushHint?> initialHint() async => null;
  @override
  Future<void> deleteToken() async {
    deleted = true;
  }

  @override
  void dispose() {
    unawaited(tokens.close());
    unawaited(messages.close());
  }
}
