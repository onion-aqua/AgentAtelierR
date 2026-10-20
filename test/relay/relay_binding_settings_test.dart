import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/relay/relay_page.dart';
import 'package:ryza_chat_mvp/src/relay/relay_protocol.dart';
import 'package:ryza_chat_mvp/src/relay/relay_server_config.dart';
import 'package:ryza_chat_mvp/src/relay/relay_service.dart';

import 'test_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'direct claim saves independent identity and binding expiry before restart',
    () async {
      final store = MemoryRelayStore();
      final transport = TestTransport()
        ..claimReturnsConfirmed = true
        ..bindingExpiresAt = '2026-10-07T10:00:00.000Z';
      final service = RelayService(
        store: store,
        transport: transport,
        now: () => testNow,
      );
      addTearDown(service.dispose);
      await service.initialize();
      final id = await service.pair(
        PairingQr.parse(qrText()),
        'phone',
        trustedByUser: true,
      );
      final original = service.profile(id)!;
      expect(original['state'], 'confirmed');
      expect(original['binding_expires_at'], transport.bindingExpiresAt);
      expect(store.data, isNot(contains('pairing_secret')));
      final restored = RelayService(
        store: store,
        transport: TestTransport(),
        now: () => testNow,
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.profile(id)!['device_token'], original['device_token']);
      expect(
        restored.profile(id)!['binding_expires_at'],
        transport.bindingExpiresAt,
      );
    },
  );

  for (final state in ['confirmed', 'pending_confirmation']) {
    test(
      'offline $state unpair removes local cache and restores only a DELETE retry',
      () async {
        final store = MemoryRelayStore();
        final transport = TestTransport()
          ..pairingState = state
          ..deleteError = 'NETWORK';
        final service = RelayService(
          store: store,
          transport: transport,
          now: () => testNow,
        );
        await service.initialize();
        final id = await service.pair(
          PairingQr.parse(qrText()),
          'phone',
          trustedByUser: true,
        );
        final token = service.profile(id)!['device_token'];
        await service.unpair(id);
        expect(service.profile(id), isNull);
        expect(service.ready, isNot(contains(id)));
        await service.retryPendingRevocations();
        expect(service.pendingRevocationCount, 1);
        final saved = object(jsonDecode(store.data!));
        expect(saved['profiles'], isEmpty);
        final retry = objects(saved['pending_revocations']).single;
        expect(retry['device_token'], token);
        expect(retry.keys.toSet(), {
          'device_id',
          'device_token',
          'server_base_url',
          'queued_at',
        });
        service.dispose();

        final retryTransport = TestTransport();
        final restored = RelayService(
          store: store,
          transport: retryTransport,
          now: () => testNow,
        );
        addTearDown(restored.dispose);
        await restored.initialize();
        await restored.configureServer('https://different.example.test');
        await restored.retryPendingRevocations();
        expect(restored.profiles, isEmpty);
        expect(restored.pendingRevocationCount, 0);
        expect(retryTransport.calls, hasLength(1));
        expect(retryTransport.calls.single['method'], 'DELETE');
        expect(retryTransport.calls.single['path'], '/v1/devices/$id');
        expect(
          retryTransport.calls.single['origin'],
          'https://relay.example.test',
        );
        expect(retryTransport.calls.single['token'], token);
        expect(retryTransport.sockets, isEmpty);
        expect(store.data, isNot(contains(token as String)));
      },
    );
  }

  test(
    'local unpair does not wait for an unavailable server response',
    () async {
      final transport = _DelayedDeleteTransport();
      final store = MemoryRelayStore();
      final service = RelayService(store: store, transport: transport);
      addTearDown(service.dispose);
      await service.initialize();
      final id = await service.pair(
        PairingQr.parse(qrText()),
        'phone',
        trustedByUser: true,
      );
      await service.unpair(id);
      expect(service.profiles, isEmpty);
      expect(service.pendingRevocationCount, 1);
      await Future<void>.delayed(Duration.zero);
      expect(transport.deleting.isCompleted, true);
      expect(transport.release.isCompleted, false);
      await service.configureServer('https://custom.example.test');
      final second = await service.pair(
        PairingQr.parse(
          qrText(
            origin: 'https://custom.example.test',
            id: '00000000-0000-4000-8000-000000000004',
          ),
        ),
        'second phone',
        trustedByUser: true,
      );
      await service.unpair(second);
      expect(service.profiles, isEmpty);
      expect(service.pendingRevocationCount, 2);
      transport.release.complete();
      await service.retryPendingRevocations();
      await service.retryPendingRevocations(); // Includes the second removal.
      expect(service.pendingRevocationCount, 0);
    },
  );

  test(
    'local unpair commits before a held claim and ignores its late reply',
    () async {
      final transport = _DelayedClaimTransport();
      final store = MemoryRelayStore();
      final service = RelayService(
        store: store,
        transport: transport,
        now: () => testNow,
      );
      addTearDown(service.dispose);
      await service.initialize();
      final pairing = service.pair(
        PairingQr.parse(qrText()),
        'phone',
        trustedByUser: true,
      );
      await transport.claiming.future;
      final id = service.profiles.single['device_id'] as String;
      await service.unpair(id).timeout(const Duration(seconds: 1));
      expect(transport.release.isCompleted, false);
      expect(service.profile(id), isNull);
      expect(objects(object(jsonDecode(store.data!))['profiles']), isEmpty);
      expect(service.pendingRevocationCount, 1);
      await service.retryPendingRevocations();
      // Claim may still be creating this identity. Do not prematurely accept a
      // DELETE/NOT_FOUND and discard the sole durable revocation credential.
      expect(transport.calls.where((c) => c['method'] == 'DELETE'), isEmpty);
      await service.configureServer('https://different.example.test');
      transport.release.complete();
      await pairing;
      await service.retryPendingRevocations();
      expect(service.profiles, isEmpty);
      expect(service.ready, isEmpty);
      expect(transport.sockets, isEmpty);
      expect(service.connections, isEmpty);
      expect(
        transport.calls.where((c) => c['path'].endsWith('/status')),
        isEmpty,
      );
      final removal = transport.calls.singleWhere(
        (c) => c['method'] == 'DELETE',
      );
      expect(removal['origin'], 'https://relay.example.test');
    },
  );

  for (final heldPath in ['status', '/v1/state']) {
    test('local unpair completes while sync holds $heldPath', () async {
      final transport = _DelayedSyncTransport(heldPath)
        ..deleteError = 'NETWORK';
      final store = MemoryRelayStore();
      final service = RelayService(
        store: store,
        transport: transport,
        now: () => testNow,
      );
      addTearDown(service.dispose);
      await service.initialize();
      final id = await service.pair(
        PairingQr.parse(qrText()),
        'phone',
        trustedByUser: true,
      );
      transport.hold = true;
      final syncing = service.sync(id, snapshot: true);
      await transport.syncing.future;
      await service.unpair(id).timeout(const Duration(seconds: 1));
      expect(transport.release.isCompleted, false);
      expect(service.profile(id), isNull);
      expect(objects(object(jsonDecode(store.data!))['profiles']), isEmpty);
      expect(service.pendingRevocationCount, 1);
      transport.release.complete();
      await syncing;
      expect(service.profiles, isEmpty);
      expect(service.ready, isEmpty);
      expect(service.connections, isEmpty);
      expect(service.errors, isEmpty);
      expect(transport.sockets, isEmpty);
      expect(
        transport.calls.where((c) => c['path'].startsWith('/v1/events')),
        isEmpty,
      );
    });
  }

  for (final ambiguousCode in ['UNAUTHORIZED', 'NOT_FOUND']) {
    test(
      'restart retains $ambiguousCode revocation until unknown claim expires',
      () async {
        var clock = testNow;
        final store = MemoryRelayStore();
        final pendingTransport = _DelayedClaimTransport();
        final original = RelayService(
          store: store,
          transport: pendingTransport,
          now: () => clock,
        );
        await original.initialize();
        final pairing = original.pair(
          PairingQr.parse(qrText()),
          'phone',
          trustedByUser: true,
        );
        await pendingTransport.claiming.future;
        await original.unpair(original.profiles.single['device_id'] as String);
        final saved = object(jsonDecode(store.data!));
        final revocation = objects(saved['pending_revocations']).single;
        expect(revocation['claim_guard_until'], isNotNull);
        original.dispose();
        pendingTransport.release.complete();
        await pairing;

        final transport = TestTransport()..deleteError = ambiguousCode;
        final restored = RelayService(
          store: store,
          transport: transport,
          now: () => clock,
        );
        addTearDown(restored.dispose);
        await restored.initialize();
        await restored.configureServer('https://different.example.test');
        await restored.retryPendingRevocations();
        expect(restored.profiles, isEmpty);
        expect(restored.pendingRevocationCount, 1);
        clock = testNow.add(const Duration(minutes: 5, seconds: 1));
        await restored.retryPendingRevocations();
        expect(restored.pendingRevocationCount, 0);
        expect(transport.calls, hasLength(2));
        expect(
          transport.calls.every(
            (call) =>
                call['method'] == 'DELETE' &&
                call['origin'] == 'https://relay.example.test',
          ),
          true,
        );
      },
    );
  }

  test(
    'simultaneous local removals and settings retain every durable mutation',
    () async {
      final store = MemoryRelayStore();
      final service = RelayService(
        store: store,
        transport: TestTransport()..deleteError = 'NETWORK',
        now: () => testNow,
      );
      addTearDown(service.dispose);
      await service.initialize();
      final first = await service.pair(
        PairingQr.parse(qrText()),
        'first',
        trustedByUser: true,
      );
      final second = await service.pair(
        PairingQr.parse(qrText(id: '00000000-0000-4000-8000-000000000004')),
        'second',
        trustedByUser: true,
      );
      await Future.wait([
        service.unpair(first),
        service.configureServer('https://different.example.test'),
        service.unpair(second),
      ]);
      final saved = object(jsonDecode(store.data!));
      expect(saved['profiles'], isEmpty);
      expect(saved['server_override'], 'https://different.example.test');
      expect(
        objects(saved['pending_revocations'])
            .map((r) => r['device_id'])
            .toSet(),
        {first, second},
      );
    },
  );

  test(
    'failed secure removal keeps the existing binding recoverable',
    () async {
      final store = MemoryRelayStore();
      final transport = TestTransport();
      final service = RelayService(
        store: store,
        transport: transport,
        now: () => testNow,
      );
      addTearDown(service.dispose);
      await service.initialize();
      final id = await service.pair(
        PairingQr.parse(qrText()),
        'phone',
        trustedByUser: true,
      );
      final saved = store.data;
      store.failWrite = true;
      await expectLater(service.unpair(id), throwsStateError);
      expect(service.profile(id), isNotNull);
      expect(service.pendingRevocationCount, 0);
      expect(store.data, saved);
      expect(transport.calls.where((c) => c['method'] == 'DELETE'), isEmpty);
    },
  );

  test(
    'revoked pending pairing is terminal and may be locally deleted',
    () async {
      final transport = TestTransport()..pairingState = 'revoked';
      final service = RelayService(
        store: MemoryRelayStore(),
        transport: transport,
        now: () => testNow,
      );
      addTearDown(service.dispose);
      await service.initialize();
      final id = await service.pair(
        PairingQr.parse(qrText()),
        'phone',
        trustedByUser: true,
      );
      expect(service.profile(id)!['state'], 'revoked');
      expect(service.profile(id)!.containsKey('device_token'), false);
      await service.unpair(id);
      expect(service.profiles, isEmpty);
      expect(service.pendingRevocationCount, 0);
    },
  );

  test(
    'local binding deadline stops sending and clears cached content offline',
    () async {
      var clock = testNow;
      final transport = TestTransport()
        ..state = snapshot(requests: [request()])
        ..bindingExpiresAt = '2026-10-05T10:00:00.000Z';
      final service = RelayService(
        store: MemoryRelayStore(),
        transport: transport,
        now: () => clock,
      );
      addTearDown(service.dispose);
      await service.initialize();
      final id = await service.pair(
        PairingQr.parse(qrText()),
        'phone',
        trustedByUser: true,
      );
      await service.setForeground(true);
      expect(service.requestCanSend(service.profile(id)!, request()), true);
      clock = testNow.add(const Duration(days: 1));
      expect(service.requestCanSend(service.profile(id)!, request()), false);
      await expectLater(
        service.startTask(id, prompt: 'late', workspaceId: 'workspace-1'),
        throwsA(isA<RelayFailure>()),
      );
      transport.calls.clear();
      await service.sync(id);
      expect(transport.calls, isEmpty);
      expect(service.profile(id)!['state'], 'expired');
      expect(service.profile(id)!.containsKey('device_token'), false);
      expect(service.collection(service.profile(id)!, 'requests'), isEmpty);
      expect(service.ready, isNot(contains(id)));
    },
  );

  testWidgets(
    'custom server settings survive restart and default remains concealed',
    (tester) async {
      final store = MemoryRelayStore();
      final service = RelayService(
        store: store,
        transport: TestTransport(),
        serverConfig: RelayServerConfig.pinned('https://relay.example.test'),
      );
      await service.initialize();
      await tester.pumpWidget(MaterialApp(home: RelayPage(service: service)));
      expect(find.textContaining('relay.example.test'), findsNothing);
      await tester.tap(find.text('云中继设置'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(
        find.byType(TextField),
        'https://custom.example.test/',
      );
      await tester.tap(find.text('继续'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(service.serverOverride, 'https://custom.example.test');
      expect(find.text('https://custom.example.test'), findsOneWidget);
      expect(find.text('粘贴二维码数据'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      service.dispose();
      final restored = RelayService(
        store: store,
        transport: TestTransport(),
        serverConfig: RelayServerConfig.pinned('https://relay.example.test'),
      );
      await restored.initialize();
      expect(restored.serverOverride, 'https://custom.example.test');
      restored.dispose();
    },
  );

  testWidgets('a held claim keeps settings scan and local unpair available', (
    tester,
  ) async {
    final transport = _DelayedClaimTransport();
    final service = RelayService(
      store: MemoryRelayStore(),
      transport: transport,
      now: () => testNow,
    );
    await service.initialize();
    var scans = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RelayPage(
          service: service,
          scanPairingCode: (_) async => ++scans == 1 ? qrText() : null,
        ),
      ),
    );
    await tester.tap(find.text('扫码绑定 / 重新配对'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('信任并配对连接'));
    // A pending network progress bar animates, so intentionally avoid
    // pumpAndSettle until the transport has been released.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(transport.claiming.isCompleted, true);
    expect(transport.release.isCompleted, false);
    await tester.tap(find.text('云中继设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(
      find.byType(TextField),
      'https://custom.example.test',
    );
    await tester.tap(find.text('继续'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(service.serverOverride, 'https://custom.example.test');
    await tester.tap(find.text('扫码绑定 / 重新配对'));
    await tester.pump();
    expect(scans, 2);
    await tester.ensureVisible(find.text('解绑'));
    await tester.tap(find.text('解绑'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('确认'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(service.profiles, isEmpty);
    expect(service.pendingRevocationCount, 1);
    expect(transport.release.isCompleted, false);
    transport.release.complete();
    await tester.pumpAndSettle();
    expect(service.profiles, isEmpty);
    await tester.pumpWidget(const SizedBox());
    service.dispose();
  });

  testWidgets(
    'manual refresh leaves settings and scan available during a held DELETE',
    (tester) async {
      final transport = _DelayedDeleteTransport();
      final service = RelayService(
        store: MemoryRelayStore(),
        transport: transport,
        now: () => testNow,
      );
      await service.initialize();
      final id = await service.pair(
        PairingQr.parse(qrText()),
        'phone',
        trustedByUser: true,
      );
      await service.unpair(id);
      await transport.deleting.future;
      var scans = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: RelayPage(
            service: service,
            scanPairingCode: (_) async {
              scans++;
              return null;
            },
          ),
        ),
      );
      await tester.tap(find.byTooltip('同步'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(transport.release.isCompleted, false);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.tap(find.text('云中继设置'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'https://custom.example.test',
      );
      await tester.tap(find.text('继续'));
      await tester.pumpAndSettle();
      expect(service.serverOverride, 'https://custom.example.test');
      await tester.tap(find.text('扫码绑定 / 重新配对'));
      await tester.pumpAndSettle();
      expect(scans, 1);
      expect(transport.release.isCompleted, false);
      transport.release.complete();
      await service.retryPendingRevocations();
      await tester.pumpWidget(const SizedBox());
      service.dispose();
    },
  );

  testWidgets(
    'offline unpair disappears from the page without waiting for PC',
    (tester) async {
      final transport = TestTransport()..deleteError = 'NETWORK';
      final service = RelayService(
        store: MemoryRelayStore(),
        transport: transport,
        now: () => testNow,
      );
      await service.initialize();
      await service.pair(
        PairingQr.parse(qrText()),
        'phone',
        trustedByUser: true,
      );
      await tester.pumpWidget(MaterialApp(home: RelayPage(service: service)));
      await tester.ensureVisible(find.text('解绑'));
      await tester.tap(find.text('解绑'));
      await tester.pumpAndSettle();
      expect(find.textContaining('无需 PC 确认'), findsOneWidget);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(service.profiles, isEmpty);
      expect(find.text('尚未绑定 PC。请在 PC 端生成配对二维码。'), findsOneWidget);
      expect(find.textContaining('服务器撤销等待联网重试'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      service.dispose();
    },
  );
}

class _DelayedDeleteTransport extends TestTransport {
  final deleting = Completer<void>();
  final release = Completer<void>();

  @override
  Future<Json> request(
    Uri origin,
    String method,
    String path, {
    String? token,
    Json? body,
  }) async {
    if (method == 'DELETE') {
      if (!deleting.isCompleted) deleting.complete();
      await release.future;
    }
    return super.request(origin, method, path, token: token, body: body);
  }
}

class _DelayedClaimTransport extends TestTransport {
  final claiming = Completer<void>();
  final release = Completer<void>();

  @override
  Future<Json> request(
    Uri origin,
    String method,
    String path, {
    String? token,
    Json? body,
  }) async {
    if (path == '/v1/pairings/claim') {
      claiming.complete();
      await release.future;
    }
    return super.request(origin, method, path, token: token, body: body);
  }
}

class _DelayedSyncTransport extends TestTransport {
  _DelayedSyncTransport(this.heldPath);
  final String heldPath;
  bool hold = false;
  final syncing = Completer<void>();
  final release = Completer<void>();

  @override
  Future<Json> request(
    Uri origin,
    String method,
    String path, {
    String? token,
    Json? body,
  }) async {
    if (hold && method == 'GET' && path.endsWith(heldPath)) {
      if (!syncing.isCompleted) syncing.complete();
      await release.future;
    }
    return super.request(origin, method, path, token: token, body: body);
  }
}
