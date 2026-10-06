import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/relay/relay_protocol.dart';
import 'package:ryza_chat_mvp/src/relay/relay_service.dart';
import 'package:ryza_chat_mvp/src/relay/relay_transport.dart';
import 'package:ryza_chat_mvp/src/relay/relay_push.dart';
import 'package:ryza_chat_mvp/src/relay/relay_server_config.dart';

import 'test_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryRelayStore store;
  late TestTransport transport;
  late RelayService s;
  setUp(() {
    store = MemoryRelayStore();
    transport = TestTransport();
    s = RelayService(store: store, transport: transport, now: () => testNow);
  });
  tearDown(() => s.dispose());
  Future<String> paired() async {
    await s.initialize();
    final id = await s.pair(
      PairingQr.parse(qrText()),
      '手机',
      trustedByUser: true,
    );
    await s.setForeground(true);
    return id;
  }

  test('strict QR and high entropy identities; no secrets in toString', () async {
    final qr = PairingQr.parse(qrText());
    expect(qr.toString(), isNot(contains(qr.secret)));
    for (final origin in [
      'http://example.test',
      'https://user:pass@example.test',
      'https://example.test/path',
      'https://example.test?x=1',
      'https://example.test#x',
    ]) {
      expect(
        () => PairingQr.parse(qrText(origin: origin)),
        throwsFormatException,
      );
    }
    for (final bad in [
      qrText().replaceFirst('"v":1', '"v":2'),
      qrText().replaceFirst('agent-relay-pair', 'other'),
      qrText(id: 'bad'),
    ]) {
      expect(() => PairingQr.parse(bad), throwsFormatException);
    }
    final tokens = List.generate(100, (_) => newDeviceToken());
    expect(tokens.toSet().length, 100);
    expect(
      tokens.every((t) => RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(t)),
      isTrue,
    );
    expect(
      await tokenDigest('abc'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      relayTimestamp(DateTime.utc(2026, 10, 5, 6, 7, 8, 9, 876)),
      '2026-10-05T06:07:08.009Z',
    );
    expect(
      RegExp(
        r'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{3}Z$',
      ).hasMatch(relayTimestamp(DateTime.now())),
      isTrue,
    );
  });
  test(
    'store before claim, retry identical identity, pending survives restart',
    () async {
      transport.pairingState = 'pending_confirmation';
      transport.claimError = 'NETWORK';
      await s.initialize();
      transport.before = (call) {
        if (call['path'] == '/v1/pairings/claim') {
          final saved = object(jsonDecode(store.data!));
          expect(saved['profiles'], hasLength(1));
          expect(store.data, isNot(contains('pairing_secret')));
          expect(store.data, isNot(contains('a' * 64)));
        }
      };
      final qr = PairingQr.parse(qrText());
      await expectLater(
        s.pair(qr, '手机', trustedByUser: false),
        throwsA(isA<RelayFailure>()),
      );
      expect(store.data, isNull);
      await expectLater(
        s.pair(qr, '手机', trustedByUser: true),
        throwsA(isA<RelayFailure>()),
      );
      final first = object(transport.calls.last['body']);
      transport.claimError = null;
      await s.pair(qr, '手机', trustedByUser: true);
      expect(
        transport.calls
            .where((c) => c['path'] == '/v1/pairings/claim')
            .last['body'],
        first,
      );
      final restored = RelayService(
        store: store,
        transport: transport,
        now: () => testNow,
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      await restored.setForeground(true);
      expect(restored.profiles.single['state'], 'pending_confirmation');
      expect(transport.calls.any((c) => c['path'] == '/v1/state'), isFalse);
      expect(transport.sockets, isEmpty);
      transport.pairingState = 'confirmed';
      await restored.sync(restored.profiles.single['device_id'] as String);
      expect(restored.profiles.single['state'], 'confirmed');
      expect(transport.sockets, isNotEmpty);
    },
  );
  for (final code in ['PAIRING_USED', 'PAIRING_EXPIRED', 'DEVICE_EXISTS']) {
    test('claim terminal $code removes credential', () async {
      await s.initialize();
      transport.claimError = code;
      await expectLater(
        s.pair(PairingQr.parse(qrText()), '手机', trustedByUser: true),
        throwsA(isA<RelayFailure>()),
      );
      expect(s.profiles.single.containsKey('device_token'), isFalse);
    });
  }
  test(
    'multiple PC profiles never overwrite each other; revoke clears cache',
    () async {
      final id = await paired();
      final token = s.profile(id)!['device_token'];
      await s.pair(
        PairingQr.parse(qrText(id: '00000000-0000-4000-8000-000000000004')),
        '第二个',
        trustedByUser: true,
      );
      expect(s.profiles, hasLength(2));
      expect(s.profile(id)!['device_token'], token);
      transport.revoked = true;
      await s.sync(id);
      expect(s.profile(id)!['state'], 'revoked');
      expect(s.profile(id)!.containsKey('device_token'), isFalse);
      expect(s.collection(s.profile(id)!, 'requests'), isEmpty);
      expect(s.ready, isNot(contains(id)));
    },
  );
  test('contiguous ACK only after durable store; duplicate WSS/pull/push one request', () async {
    final id = await paired();
    transport.events = [event(1), event(1)];
    transport.before = (call) {
      if (call['path'] == '/v1/events/ack') {
        final profiles = objects(object(jsonDecode(store.data!))['profiles']);
        expect(
          object(profiles.single['cache'])['cursor'],
          object(call['body'])['seq'],
        );
      }
    };
    await s.sync(id);
    expect(s.collection(s.profile(id)!, 'requests'), hasLength(1));
    expect(object(s.profile(id)!['cache'])['cursor'], 1);
    transport.sockets.last.frames.add({
      'v': 1,
      'type': 'event',
      'event': event(1),
    });
    transport.state = snapshot(seq: 1, requests: [request()]);
    await s.handlePush(const PushHint(eventId, pcId, 'question', opened: true));
    await s.sync(id);
    expect(s.collection(s.profile(id)!, 'requests'), hasLength(1));
    expect(s.focusRequest, 'request-1');
    transport.events.add(
      event(
        2,
        id: newUuid(),
        type: 'question.updated',
        payload: {'state': 'cancelled'},
      ),
    );
    store.failWrite = true;
    await s.sync(id);
    expect(object(s.profile(id)!['cache'])['cursor'], 1);
    expect(
      transport.calls.where((c) => c['path'] == '/v1/events/ack').last['body'],
      {'seq': 1},
    );
  });
  test(
    'push opens the authenticated event envelope and deduplicates with pull',
    () async {
      transport.events = [event(1)];
      transport.state = snapshot(seq: 1, requests: [request()]);
      final id = await paired();
      await s.handlePush(
        const PushHint(eventId, pcId, 'question', opened: true),
      );
      await s.handlePush(
        const PushHint(eventId, pcId, 'question', opened: true),
      );
      expect(s.focusProfile, id);
      expect(s.focusRequest, 'request-1');
      expect(s.collection(s.profile(id)!, 'requests'), hasLength(1));
      expect(object(s.profile(id)!['cache'])['cursor'], 1);
      s.clearFocus();
      transport.singleEventResponse = {'event': event(1, id: newUuid())};
      await s.handlePush(
        const PushHint(eventId, pcId, 'question', opened: true),
      );
      expect(s.focusRequest, isNull);
      transport.singleEventResponse = event(1); // Unwrapped data is not v1.
      await s.handlePush(
        const PushHint(eventId, pcId, 'question', opened: true),
      );
      expect(s.focusRequest, isNull);
    },
  );
  test(
    'confirmation capabilities narrow actions and refresh before retry',
    () async {
      transport.state = snapshot(
        requests: [
          request(),
          request(kind: 'approval', id: 'approval-1'),
        ],
      );
      transport.capabilities = ['question.answer', 'task.start'];
      final id = await paired();
      expect(s.profile(id)!['capabilities'], ['question.answer', 'task.start']);
      await expectLater(
        s.answer(id, 'approval-1', decision: 'approve'),
        throwsA(isA<RelayFailure>().having((e) => e.code, 'code', 'FORBIDDEN')),
      );
      transport.failActionOnce = true;
      final aid = await s.startTask(
        id,
        prompt: 'test',
        workspaceId: 'workspace-1',
      );
      expect(
        s.collection(s.profile(id)!, 'outbox').single['local_status'],
        'retry',
      );
      transport.capabilities = [];
      await s.sync(id);
      expect(s.profile(id)!['capabilities'], isEmpty);
      expect(s.requestCanSend(s.profile(id)!, request()), isFalse);
      expect(
        s.collection(s.profile(id)!, 'outbox').single['local_status'],
        'rejected',
      );
      expect(
        transport.calls.where((c) => c['path'] == '/v1/actions'),
        hasLength(1),
      );
      await s.retryAction(id, aid);
      await expectLater(
        s.answer(id, 'request-1', selected: ['a']),
        throwsA(isA<RelayFailure>().having((e) => e.code, 'code', 'FORBIDDEN')),
      );
    },
  );
  test('mobile device snapshot narrows capabilities without trusting PC capabilities', () async {
    final id = await paired();
    transport.state = snapshot(requests: [request()]);
    (transport.state['devices'] as List).add({
      'device_id': id,
      'role': 'mobile',
      'device_name': '手机',
      'pc_id': pcId,
      'connection_state': 'online',
      'capabilities': ['question.answer'],
    });
    await s.sync(id, snapshot: true);
    expect(s.profile(id)!['capabilities'], ['question.answer']);
    expect(s.requestCanSend(s.profile(id)!, request()), isTrue);
    await expectLater(
      s.startTask(id, prompt: 'test', workspaceId: 'workspace-1'),
      throwsA(isA<RelayFailure>().having((e) => e.code, 'code', 'FORBIDDEN')),
    );
  });
  test(
    'PC recovery request is never imported into mobile action state',
    () async {
      final aid = newUuid();
      final pcOnlyRequest = {
        'args': {'prompt': 'PC recovery only'},
      };
      transport.state = snapshot(
        actions: [
          {'action_id': aid, 'status': 'queued', 'request': pcOnlyRequest},
        ],
      );
      final id = await paired();
      expect(
        s.collection(s.profile(id)!, 'actions').single.containsKey('request'),
        isFalse,
      );
      final started = await s.startTask(
        id,
        prompt: 'test',
        workspaceId: 'workspace-1',
      );
      transport.results[started] = {
        'action_id': started,
        'status': 'delivered',
        'request': pcOnlyRequest,
      };
      await s.sync(id);
      expect(
        s
            .collection(s.profile(id)!, 'actions')
            .every((a) => !a.containsKey('request')),
        isTrue,
      );
      expect(store.data, isNot(contains('PC recovery only')));
      transport.events = [
        event(
          1,
          type: 'action.result',
          payload: {
            'action_id': started,
            'status': 'accepted',
            'request': pcOnlyRequest,
          },
        ),
      ];
      await s.sync(id);
      expect(store.data, isNot(contains('PC recovery only')));
      expect(
        () => validateEvent(event(1, type: 'action.request')),
        throwsFormatException,
      );
    },
  );
  test('gap cannot ACK beyond missing seq; CURSOR_EXPIRED uses consistent snapshot', () async {
    final id = await paired();
    transport.events = [event(2)];
    await s.sync(id);
    expect(object(s.profile(id)!['cache'])['cursor'], 0);
    transport.events = [];
    transport.state = snapshot(seq: 200, requests: [request()]);
    transport.cursorExpired = true;
    await s.sync(id);
    expect(object(s.profile(id)!['cache'])['cursor'], 200);
    expect(s.collection(s.profile(id)!, 'requests'), hasLength(1));
    expect(
      transport.calls.any(
        (c) => c['path'] == '/v1/events?after_seq=200&limit=100',
      ),
      isTrue,
    );
  });
  test('answer exact option IDs, stable action retry, queued not accepted, PC conflict', () async {
    transport.state = snapshot(requests: [request()]);
    final id = await paired();
    transport.failActionOnce = true;
    await expectLater(
      s.answer(id, 'request-1', selected: ['甲']),
      throwsFormatException,
    );
    final aid = await s.answer(id, 'request-1', selected: ['a']);
    expect(
      s.actionForRequest(s.profile(id)!, 'request-1')!['local_status'],
      'retry',
    );
    final sent = object(
      transport.calls.where((c) => c['path'] == '/v1/actions').last['body'],
    );
    await s.retryAction(id, aid);
    expect(
      transport.calls.where((c) => c['path'] == '/v1/actions').last['body'],
      sent,
    );
    expect(
      s.actionForRequest(s.profile(id)!, 'request-1')!['local_status'],
      'queued',
    );
    await expectLater(
      s.answer(id, 'request-1', selected: ['b']),
      throwsA(isA<RelayFailure>()),
    );
    transport.events = [
      event(
        1,
        type: 'question.updated',
        payload: {'state': 'resolved', 'resolved_by_device_id': pcId},
      ),
      event(
        2,
        id: newUuid(),
        type: 'action.result',
        payload: {
          'action_id': aid,
          'status': 'conflict',
          'session_id': 'session-1',
          'task_id': null,
          'request_id': 'request-1',
          'error': null,
          'updated_at': time,
        },
      ),
    ];
    await s.sync(id);
    expect(
      s.actionForRequest(s.profile(id)!, 'request-1')!['local_status'],
      'conflict',
    );
    expect(
      s.collection(s.profile(id)!, 'requests').single['state'],
      'resolved',
    );
  });

  test('idempotent task retry accepts the relay current status and keeps one action', () async {
    final id = await paired();
    final actionIds = <String>[];
    for (final responseStatus in ['accepted', 'unknown']) {
      transport.failActionOnce = true;
      final aid = await s.startTask(
        id,
        prompt: 'test $responseStatus',
        workspaceId: 'workspace-1',
      );
      actionIds.add(aid);
      expect(
        s.collection(s.profile(id)!, 'outbox').last['local_status'],
        'retry',
      );

      // The first request may have committed before its response was lost.
      // The idempotent retry can therefore return the current action status.
      transport.actionResponseStatus = responseStatus;
      await s.retryAction(id, aid);

      final outbox = s.collection(s.profile(id)!, 'outbox');
      final local = outbox.last;
      expect(local['action_id'], aid);
      expect(local['local_status'], responseStatus);
      expect(
        s.collection(s.profile(id)!, 'actions').last['status'],
        responseStatus,
      );
    }
    final outbox = s.collection(s.profile(id)!, 'outbox');
    expect(outbox, hasLength(2));
    expect(outbox.map((a) => a['action_id']), actionIds);
    final bodies = transport.calls
        .where((c) => c['path'] == '/v1/actions')
        .map((c) => object(c['body']))
        .toList();
    expect(bodies, hasLength(4));
    expect(bodies[0], bodies[1]);
    expect(bodies[2], bodies[3]);
    expect(bodies[0]['action_id'], isNot(bodies[2]['action_id']));
  });
  test('expired retry reconciles an existing action before posting again', () async {
    final id = await paired();
    transport.failActionOnce = true;
    final aid = await s.startTask(
      id,
      prompt: 'expired body',
      workspaceId: 'workspace-1',
    );
    final storedOutbox = object(s.profile(id)!['cache'])['outbox'] as List;
    object(storedOutbox.last)['body']['expires_at'] =
        '2026-10-04T09:00:00.000Z';
    transport.results[aid] = {'action_id': aid, 'status': 'accepted'};

    expect(
      object(s.collection(s.profile(id)!, 'outbox').last['body'])['expires_at'],
      '2026-10-04T09:00:00.000Z',
    );

    await s.retryAction(id, aid);

    // The expired retry must reconcile by GET rather than issuing another POST.
    expect(transport.calls.map((c) => c['path']), contains('/v1/actions/$aid'));
    expect(
      s.collection(s.profile(id)!, 'outbox').last['local_status'],
      'accepted',
    );
    expect(transport.calls.where((c) => c['path'] == '/v1/actions').length, 1);
    expect(
      transport.calls.where((c) => c['path'] == '/v1/actions/$aid').length,
      1,
    );
  });
  test('explicit approval, authorized new task, accepted then finished, cancel targets task', () async {
    transport.state = snapshot(requests: [request(kind: 'approval')]);
    final id = await paired();
    await expectLater(s.answer(id, 'request-1'), throwsFormatException);
    await s.answer(id, 'request-1', decision: 'reject');
    await expectLater(
      s.startTask(id, prompt: 'test', workspaceId: 'arbitrary/path'),
      throwsFormatException,
    );
    final aid = await s.startTask(
      id,
      prompt: 'test',
      workspaceId: 'workspace-1',
    );
    transport.events = [
      event(
        1,
        type: 'action.result',
        payload: {
          'action_id': aid,
          'status': 'accepted',
          'session_id': 'session-1',
          'task_id': 'task-1',
          'request_id': null,
          'error': null,
          'updated_at': time,
        },
      ),
      event(
        2,
        id: newUuid(),
        type: 'task.updated',
        payload: {
          'task_id': 'task-1',
          'status': 'running',
          'summary': 'test',
          'error': null,
          'updated_at': time,
        },
      ),
    ];
    await s.sync(id);
    final cancelId = await s.cancelTask(id, 'task-1');
    expect(await s.cancelTask(id, 'task-1'), cancelId);
    expect(
      object(
        transport.calls.where((c) => c['path'] == '/v1/actions').last['body'],
      )['payload'],
      {'task_id': 'task-1'},
    );
    transport.events.add(
      event(
        3,
        id: newUuid(),
        type: 'task.updated',
        payload: {
          'task_id': 'task-1',
          'status': 'succeeded',
          'summary': 'done',
          'error': null,
          'updated_at': time,
        },
      ),
    );
    await s.sync(id);
    expect(s.collection(s.profile(id)!, 'tasks').single['status'], 'succeeded');
  });
  test(
    'background disconnect; resume reconciles cancellation before ready',
    () async {
      transport.state = snapshot(requests: [request()]);
      final id = await paired();
      await s.markPresented(id, requestKey(request()));
      await s.setForeground(false);
      expect(s.ready, isEmpty);
      transport.state = snapshot(
        seq: 4,
        requests: [request(state: 'cancelled')],
      );
      await s.setForeground(true);
      expect(
        s.collection(s.profile(id)!, 'requests').single['state'],
        'cancelled',
      );
      expect(s.ready, contains(id));
      expect(
        object(s.profile(id)!['cache'])['presented'],
        contains(requestKey(request())),
      );
    },
  );
  test('expired question refuses action locally', () async {
    transport.state = snapshot(
      requests: [
        {...request(), 'expires_at': '2026-10-04T09:00:00Z'},
      ],
    );
    final id = await paired();
    await expectLater(
      s.answer(id, 'request-1', selected: ['a']),
      throwsA(isA<RelayFailure>()),
    );
    expect(transport.calls.any((c) => c['path'] == '/v1/actions'), isFalse);
  });
  test(
    'push registers refresh and removes subscription; no token in role backups',
    () async {
      final push = TestPush();
      final other = RelayService(
        store: store,
        transport: transport,
        push: push,
        now: () => testNow,
      );
      addTearDown(other.dispose);
      await other.initialize();
      final id = await other.pair(
        PairingQr.parse(qrText()),
        '手机',
        trustedByUser: true,
      );
      await other.setForeground(true);
      await other.enablePush();
      expect(other.profile(id)!['push_subscription_id'], 'sub-1');
      push.tokens.add('new-token');
      await Future<void>.delayed(Duration.zero);
      await other.sync(id);
      expect(other.profile(id)!['push_registration_token'], 'new-token');
      await other.disablePush();
      expect(push.deleted, isTrue);
      expect(
        other.profile(id)!.containsKey('push_registration_token'),
        isFalse,
      );
      expect(
        transport.calls.any(
          (c) =>
              c['method'] == 'DELETE' &&
              c['path'] == '/v1/push/subscriptions/sub-1',
        ),
        isTrue,
      );
    },
  );
  test('production transport blocks HTTP and redirects, uses Authorization not URL', () async {
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer test-token');
      expect(request.url.toString(), isNot(contains('test-token')));
      expect(request.followRedirects, isFalse);
      return http.Response('{"events":[],"has_more":false,"next_seq":0}', 200);
    });
    final t = HttpsRelayTransport(client: client);
    addTearDown(t.dispose);
    await expectLater(
      t.request(Uri.parse('http://example.test'), 'GET', '/v1/state'),
      throwsFormatException,
    );
    await t.request(
      Uri.parse('https://example.test'),
      'GET',
      '/v1/events?after_seq=0&limit=100',
      token: 'test-token',
    );
  });

  test('pinned QR validation rejects a different origin before storage or network writes', () async {
    final fixed = RelayService(
      store: store,
      transport: transport,
      now: () => testNow,
      serverConfig: RelayServerConfig.pinned('https://relay.example.test'),
    );
    addTearDown(fixed.dispose);
    await fixed.initialize();
    expect(fixed.serverConfig.isPinned, true);
    final qr = PairingQr.parse(qrText(origin: 'https://other.example.test'));
    expect(() => fixed.verifyPairingServer(qr), throwsFormatException);
    await expectLater(
      fixed.pair(qr, '手机', trustedByUser: true),
      throwsFormatException,
    );
    expect(store.data, isNull);
    expect(fixed.profiles, isEmpty);
    expect(transport.calls, isEmpty);
    expect(transport.sockets, isEmpty);
    final id = await fixed.pair(
      PairingQr.parse(qrText()),
      '手机',
      trustedByUser: true,
    );
    expect(fixed.profile(id)!['server_base_url'], 'https://relay.example.test');
    expect(
      transport.calls.every(
        (call) => call['origin'] == 'https://relay.example.test',
      ),
      true,
    );
  });

  test('fixed builds preserve blocked profiles while matching bindings still connect', () async {
    final matching = _policyProfile(origin: 'https://relay.example.test');
    final blocked = _policyProfile(origin: 'https://old.example.test');
    store.data = jsonEncode({
      'v': 1,
      'profiles': [matching, blocked],
      'push_enabled': false,
    });
    final fixed = RelayService(
      store: store,
      transport: transport,
      push: TestPush(),
      now: () => testNow,
      serverConfig: RelayServerConfig.pinned('https://relay.example.test'),
    );
    addTearDown(fixed.dispose);
    await fixed.initialize();
    expect(fixed.initialized, true);
    expect(fixed.startupError, isNull);
    final blockedId = blocked['device_id'] as String;
    final matchingId = matching['device_id'] as String;
    expect(fixed.connections[blockedId], 'server_disabled');
    expect(fixed.errors[blockedId], isNot(contains('old.example.test')));
    expect(fixed.profile(blockedId), blocked);
    await fixed.setForeground(true);
    await fixed.sync(blockedId, snapshot: true);
    await fixed.handlePush(
      const PushHint(eventId, pcId, 'question', opened: true),
    );
    await fixed.enablePush();
    await fixed.disablePush();
    expect(fixed.ready, contains(matchingId));
    expect(fixed.ready, isNot(contains(blockedId)));
    expect(
      fixed.profile(matchingId)!['device_token'],
      matching['device_token'],
    );
    expect(fixed.profile(blockedId), blocked);
    expect(transport.sockets, isNotEmpty);
    expect(
      transport.calls.every(
        (call) => call['origin'] == 'https://relay.example.test',
      ),
      true,
    );
    await expectLater(fixed.unpair(blockedId), throwsFormatException);
    expect(fixed.profile(blockedId), blocked);
  });

  test('history reads, actions and re-pairing cannot bypass a pinned profile origin', () async {
    final blocked = _policyProfile(origin: 'https://old.example.test');
    store.data = jsonEncode({
      'v': 1,
      'profiles': [blocked],
      'push_enabled': false,
    });
    final original = store.data;
    final fixed = RelayService(
      store: store,
      transport: transport,
      now: () => testNow,
      serverConfig: RelayServerConfig.pinned('https://relay.example.test'),
    );
    addTearDown(fixed.dispose);
    await fixed.initialize();
    await fixed.setForeground(true);
    final id = blocked['device_id'] as String;
    await expectLater(
      fixed.refreshSessionHistory(id, 'session-1'),
      throwsFormatException,
    );
    // A stale UI readiness flag is not sufficient authority to enqueue a task.
    fixed.ready.add(id);
    await expectLater(
      fixed.startTask(id, prompt: 'blocked task', workspaceId: 'workspace-1'),
      throwsFormatException,
    );
    await expectLater(fixed.retryAction(id, 'action-1'), throwsFormatException);
    await expectLater(
      fixed.pair(
        PairingQr.parse(qrText(origin: 'https://old.example.test')),
        '手机',
        trustedByUser: true,
      ),
      throwsFormatException,
    );
    expect(transport.calls, isEmpty);
    expect(transport.sockets, isEmpty);
    expect(store.data, original);
  });

  test('encrypted configuration failures stop before reading storage and cannot fall back to unrestricted networking', () async {
    final registry = _ObservedStore();
    final failed = RelayService(
      store: registry,
      transport: transport,
      serverConfigLoader: () => RelayServerConfig.fromProtectedDefines(
        encrypted: 'not-an-authenticated-envelope',
        key: 'invalid-key',
      ),
    );
    addTearDown(failed.dispose);
    await failed.initialize();
    expect(failed.initialized, false);
    expect(failed.startupError, contains('停用联网'));
    expect(registry.reads, 0);
    expect(
      () => failed.verifyPairingServer(PairingQr.parse(qrText())),
      throwsFormatException,
    );
    await expectLater(
      failed.pair(PairingQr.parse(qrText()), '手机', trustedByUser: true),
      throwsA(isA<RelayFailure>()),
    );
    await failed.setForeground(true);
    await failed.sync('unknown-device');
    await failed.handlePush(
      const PushHint(eventId, pcId, 'question', opened: true),
    );
    await failed.enablePush();
    expect(registry.writes, 0);
    expect(transport.calls, isEmpty);
    expect(transport.sockets, isEmpty);
  });

  test('server configuration is loaded before stored bindings can open connections', () async {
    final registry = _ObservedStore()
      ..data = jsonEncode({
        'v': 1,
        'profiles': [_policyProfile(origin: 'https://relay.example.test')],
        'push_enabled': false,
      });
    final readyConfig = Completer<RelayServerConfig>();
    final loading = RelayService(
      store: registry,
      transport: transport,
      now: () => testNow,
      serverConfigLoader: () => readyConfig.future,
    );
    addTearDown(loading.dispose);
    final pending = loading.initialize();
    await loading.setForeground(true);
    expect(registry.reads, 0);
    expect(
      () => loading.verifyPairingServer(PairingQr.parse(qrText())),
      throwsFormatException,
    );
    readyConfig.complete(
      RelayServerConfig.pinned('https://relay.example.test'),
    );
    await pending;
    expect(registry.reads, 1);
    expect(loading.serverConfig.isPinned, true);
    expect(loading.initialized, true);
    expect(loading.ready, isNotEmpty);
    expect(
      transport.calls.every(
        (call) => call['origin'] == 'https://relay.example.test',
      ),
      true,
    );
  });

  testWidgets(
    'timer and push wakeups never connect retained foreign profiles',
    (tester) async {
      final blocked = _policyProfile(origin: 'https://old.example.test');
      store.data = jsonEncode({
        'v': 1,
        'profiles': [blocked],
        'push_enabled': false,
      });
      final fixed = RelayService(
        store: store,
        transport: transport,
        now: () => testNow,
        serverConfig: RelayServerConfig.pinned('https://relay.example.test'),
      );
      await fixed.initialize();
      await fixed.setForeground(true);
      await tester.pump(const Duration(seconds: 21));
      await fixed.handlePush(
        const PushHint(eventId, pcId, 'question', opened: true),
      );
      expect(transport.calls, isEmpty);
      expect(transport.sockets, isEmpty);
      expect(fixed.profile(blocked['device_id'] as String), blocked);
      fixed.dispose();
    },
  );
}

class _ObservedStore extends MemoryRelayStore {
  int reads = 0;
  int writes = 0;
  @override
  Future<String?> read() {
    reads++;
    return super.read();
  }

  @override
  Future<void> write(String value) {
    writes++;
    return super.write(value);
  }
}

Json _policyProfile({required String origin}) {
  final cache = RelayService.emptyCache();
  final state = snapshot();
  for (final key in [
    'devices',
    'workspaces',
    'sessions',
    'requests',
    'tasks',
    'actions',
  ]) {
    cache[key] = state[key];
  }
  return {
    'server_base_url': origin,
    'pairing_id': pairingId,
    'device_id': newUuid(),
    'device_token': newDeviceToken(),
    'device_name': '保留手机',
    'state': 'confirmed',
    'pc_id': pcId,
    'capabilities': [
      'question.answer',
      'approval.respond',
      'task.start',
      'task.cancel',
    ],
    'history_read': true,
    'cache': cache,
  };
}
