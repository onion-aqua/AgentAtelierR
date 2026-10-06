import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/relay/relay_protocol.dart';
import 'package:ryza_chat_mvp/src/relay/relay_service.dart';
import 'package:ryza_chat_mvp/src/relay/relay_page.dart';

import 'test_transport.dart';

void main() {
  testWidgets(
    'global questions queue, deduplicate, close on cancellation and background',
    (tester) async {
      final transport = TestTransport()
        ..state = snapshot(
          requests: [
            request(),
            request(id: 'second'),
          ],
        );
      final service = RelayService(
        store: MemoryRelayStore(),
        transport: transport,
        now: () => testNow,
      );
      await service.initialize();
      final id = await service.pair(
        PairingQr.parse(qrText()),
        '手机',
        trustedByUser: true,
      );
      await service.setForeground(true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RelayForegroundHost(service: service)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RelayQuestionDialog), findsOneWidget);
      expect(find.textContaining('测试PC'), findsOneWidget);
      await tester.tap(find.text('稍后 / 关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(RelayQuestionDialog), findsOneWidget);
      expect(object(service.profile(id)!['cache'])['presented'], hasLength(2));
      transport.state = snapshot(
        seq: 1,
        requests: [
          request(state: 'resolved'),
          request(id: 'second', state: 'cancelled'),
        ],
      );
      await service.sync(id, snapshot: true);
      await tester.pumpAndSettle();
      expect(find.byType(RelayQuestionDialog), findsNothing);
      transport.state = snapshot(seq: 2, requests: [request(id: 'third')]);
      await service.sync(id, snapshot: true);
      await tester.pumpAndSettle();
      expect(find.byType(RelayQuestionDialog), findsOneWidget);
      await service.setForeground(false);
      await tester.pumpAndSettle();
      expect(find.byType(RelayQuestionDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      service.dispose();
    },
  );
  testWidgets('approval does not send until explicit user decision', (
    tester,
  ) async {
    final transport = TestTransport()
      ..state = snapshot(requests: [request(kind: 'approval')]);
    final service = RelayService(
      store: MemoryRelayStore(),
      transport: transport,
      now: () => testNow,
    );
    await service.initialize();
    final id = await service.pair(
      PairingQr.parse(qrText()),
      '手机',
      trustedByUser: true,
    );
    await service.setForeground(true);
    await tester.pumpWidget(
      MaterialApp(
        home: RelayQuestionDialog(
          service: service,
          profileId: id,
          requestId: 'request-1',
        ),
      ),
    );
    expect(transport.calls.any((c) => c['path'] == '/v1/actions'), isFalse);
    await tester.tap(find.text('明确批准'));
    await tester.pumpAndSettle();
    expect(
      transport.calls.where((c) => c['path'] == '/v1/actions'),
      hasLength(1),
    );
    expect(find.textContaining('等待 PC'), findsOneWidget);
    await tester.tap(find.text('明确批准'));
    await tester.pumpAndSettle();
    expect(
      transport.calls.where((c) => c['path'] == '/v1/actions'),
      hasLength(1),
    );
    await tester.pumpWidget(const SizedBox());
    service.dispose();
  });
}
