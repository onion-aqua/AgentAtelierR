import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/relay/relay_page.dart';
import 'package:ryza_chat_mvp/src/relay/relay_protocol.dart';
import 'package:ryza_chat_mvp/src/relay/relay_server_config.dart';
import 'package:ryza_chat_mvp/src/relay/relay_service.dart';

import 'test_transport.dart';

void main() {
  final fixture = jsonDecode(
    File('test/relay/fixtures/qr-envelope-v2.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final valid = (fixture['vectors'] as List).first['envelope'] as String;
  final harness = jsonDecode(
    File('test/relay/fixtures/harness-qr-envelope-v2.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Future<
    ({RelayService service, MemoryRelayStore store, TestTransport transport})
  >
  mount(WidgetTester tester, String? input) async {
    final store = MemoryRelayStore();
    final transport = TestTransport();
    final service = RelayService(
      store: store,
      transport: transport,
      now: () => testNow,
      serverConfig: RelayServerConfig.pinned('https://relay.example.test'),
    );
    await service.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: RelayPage(service: service, scanPairingCode: (_) async => input),
      ),
    );
    await tester.pumpAndSettle();
    return (service: service, store: store, transport: transport);
  }

  Future<void> dispose(WidgetTester tester, RelayService service) async {
    await tester.pumpWidget(const SizedBox());
    service.dispose();
    debugDefaultTargetPlatformOverride = null;
  }

  Future<void> settleConsent(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('v2 ${platform.name} input preserves consent and claim', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final state = await mount(tester, valid);
      if (platform == TargetPlatform.windows) {
        await tester.tap(find.text('粘贴配对数据 / 重新配对'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), valid);
        await tester.tap(find.text('继续'));
      } else {
        await tester.tap(find.text('扫码绑定 / 重新配对'));
      }
      await settleConsent(tester);
      expect(find.text('确认配对此 PC'), findsOneWidget);
      expect(state.transport.calls, isEmpty);
      expect(state.service.profiles, isEmpty);
      expect(find.textContaining('a' * 64), findsNothing);
      expect(find.textContaining('ryzasync:v2:'), findsNothing);
      await tester.tap(find.text('配对连接'));
      await tester.pumpAndSettle();
      final claims = state.transport.calls.where(
        (c) => c['path'] == '/v1/pairings/claim',
      );
      expect(claims, hasLength(1));
      expect(object(claims.single['body'])['pairing_id'], pairingId);
      expect(object(claims.single['body'])['pairing_secret'], 'a' * 64);
      expect(state.service.profiles.single['state'], 'confirmed');
      expect(state.store.data, isNot(contains('a' * 64)));
      expect(state.store.data, isNot(contains('ryzasync:v2:')));
      await dispose(tester, state.service);
    });
  }

  for (final invalid in harness['invalid_cases'] as List) {
    testWidgets('invalid v2 ${invalid['id']} performs no binding or network', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final state = await mount(tester, invalid['input'] as String);
      final before = state.store.data;
      await tester.tap(find.text('扫码绑定 / 重新配对'));
      await tester.pumpAndSettle();
      expect(find.textContaining('配对二维码格式无效或不受支持'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(state.transport.calls, isEmpty);
      expect(state.service.profiles, isEmpty);
      expect(state.store.data, before);
      expect(find.textContaining('relay.example.invalid'), findsNothing);
      expect(find.textContaining('ryzasync:v2:'), findsNothing);
      await dispose(tester, state.service);
    });
  }
}
