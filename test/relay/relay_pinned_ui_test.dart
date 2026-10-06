import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/relay/relay_page.dart';
import 'package:ryza_chat_mvp/src/relay/relay_protocol.dart';
import 'package:ryza_chat_mvp/src/relay/relay_server_config.dart';
import 'package:ryza_chat_mvp/src/relay/relay_service.dart';

import 'test_transport.dart';

const _origin = 'https://relay.example.test';
const _otherOrigin = 'https://other.example.test';

Future<RelayService> _create({
  required TestTransport transport,
  required bool pinned,
}) async {
  final service = RelayService(
    store: MemoryRelayStore(),
    transport: transport,
    now: () => testNow,
    serverConfig: pinned
        ? RelayServerConfig.pinned(_origin)
        : const RelayServerConfig.unrestricted(),
  );
  await service.initialize();
  return service;
}

Future<void> _mount(
  WidgetTester tester,
  RelayService service, {
  String? scanned,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: RelayPage(service: service, scanPairingCode: (_) async => scanned),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _dispose(WidgetTester tester, RelayService service) async {
  await tester.pumpWidget(const SizedBox());
  service.dispose();
}

Future<void> _pumpConfirmation(WidgetTester tester) async {
  // The waiting confirmation deliberately keeps the page busy and animated.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('pinned profile hides its server and the raw QR input', (
    tester,
  ) async {
    final transport = TestTransport();
    final service = await _create(transport: transport, pinned: true);
    await service.pair(PairingQr.parse(qrText()), '测试手机', trustedByUser: true);
    await service.sync(service.profiles.single['device_id'], snapshot: true);
    await _mount(tester, service);
    expect(find.text('测试PC'), findsOneWidget);
    expect(find.text('内置联动服务'), findsOneWidget);
    expect(find.textContaining('relay.example.test'), findsNothing);
    expect(find.text('粘贴二维码数据'), findsNothing);
    expect(find.text('扫码绑定 / 重新配对'), findsOneWidget);
    await _dispose(tester, service);
  });

  testWidgets(
    'pinned pairing still requires explicit consent without an origin',
    (tester) async {
      final transport = TestTransport();
      final service = await _create(transport: transport, pinned: true);
      await _mount(tester, service, scanned: qrText());
      await tester.tap(find.text('扫码绑定 / 重新配对'));
      await _pumpConfirmation(tester);
      expect(find.text('确认配对此 PC'), findsOneWidget);
      expect(find.textContaining('内置联动服务配对'), findsOneWidget);
      expect(find.textContaining('relay.example.test'), findsNothing);
      expect(find.text('申请配对'), findsOneWidget);
      expect(transport.calls, isEmpty);
      expect(service.profiles, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(transport.calls, isEmpty);
      expect(service.profiles, isEmpty);
      await _dispose(tester, service);
    },
  );

  testWidgets('pinned pairing sends the checked QR only after consent', (
    tester,
  ) async {
    final transport = TestTransport();
    final service = await _create(transport: transport, pinned: true);
    await _mount(tester, service, scanned: qrText());
    await tester.tap(find.text('扫码绑定 / 重新配对'));
    await _pumpConfirmation(tester);
    expect(transport.calls, isEmpty);
    await tester.tap(find.text('申请配对'));
    await tester.pumpAndSettle();
    final claims = transport.calls
        .where((call) => call['path'] == '/v1/pairings/claim')
        .toList();
    expect(claims, hasLength(1));
    expect(claims.single['origin'], _origin);
    expect(object(claims.single['body'])['pairing_id'], pairingId);
    expect(service.profiles.single['state'], 'confirmed');
    expect(find.textContaining('relay.example.test'), findsNothing);
    await _dispose(tester, service);
  });

  testWidgets(
    'wrong server QR is rejected before a dialog or network request',
    (tester) async {
      final transport = TestTransport();
      final service = await _create(transport: transport, pinned: true);
      await _mount(tester, service, scanned: qrText(origin: _otherOrigin));
      await tester.tap(find.text('扫码绑定 / 重新配对'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('此版本只支持内置联动服务'), findsOneWidget);
      expect(find.textContaining('other.example.test'), findsNothing);
      expect(find.textContaining('relay.example.test'), findsNothing);
      expect(transport.calls, isEmpty);
      expect(service.profiles, isEmpty);
      await _dispose(tester, service);
    },
  );

  testWidgets('malformed scanned content does not echo a server or QR secret', (
    tester,
  ) async {
    final transport = TestTransport();
    final service = await _create(transport: transport, pinned: true);
    await _mount(
      tester,
      service,
      scanned: '$_otherOrigin synthetic-qr-secret not json',
    );
    await tester.tap(find.text('扫码绑定 / 重新配对'));
    await tester.pumpAndSettle();
    expect(find.textContaining('配对二维码格式无效'), findsOneWidget);
    expect(find.textContaining('other.example.test'), findsNothing);
    expect(find.textContaining('synthetic-qr-secret'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(transport.calls, isEmpty);
    await _dispose(tester, service);
  });

  testWidgets(
    'public pairing preserves server trust confirmation and QR input',
    (tester) async {
      final transport = TestTransport();
      final service = await _create(transport: transport, pinned: false);
      await _mount(tester, service, scanned: qrText(origin: _otherOrigin));
      expect(find.text('粘贴二维码数据'), findsOneWidget);
      await tester.tap(find.text('扫码绑定 / 重新配对'));
      await _pumpConfirmation(tester);
      expect(find.text('确认信任此联动服务器'), findsOneWidget);
      expect(find.textContaining(_otherOrigin), findsOneWidget);
      expect(find.text('信任并申请配对'), findsOneWidget);
      expect(transport.calls, isEmpty);
      await tester.tap(find.text('信任并申请配对'));
      await tester.pumpAndSettle();
      expect(transport.calls.first['origin'], _otherOrigin);
      expect(find.text(_otherOrigin), findsOneWidget);
      await _dispose(tester, service);
    },
  );

  testWidgets('public pasted QR still enters the consent flow', (tester) async {
    final transport = TestTransport();
    final service = await _create(transport: transport, pinned: false);
    await _mount(tester, service);
    await tester.tap(find.text('粘贴二维码数据'));
    await tester.pumpAndSettle();
    expect(find.text('粘贴配对二维码 JSON'), findsOneWidget);
    await tester.enterText(find.byType(TextField), qrText());
    await tester.tap(find.text('继续'));
    await _pumpConfirmation(tester);
    expect(find.text('确认信任此联动服务器'), findsOneWidget);
    expect(find.textContaining(_origin), findsOneWidget);
    expect(transport.calls, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await _dispose(tester, service);
  });

  testWidgets('pinned UI preserves addresses in PC supplied task content', (
    tester,
  ) async {
    const body = '检查文档链接 https://relay.example.test/readme';
    final transport = TestTransport()
      ..state = {
        ...snapshot(),
        'tasks': [
          {
            'task_id': 'task-1',
            'pc_id': pcId,
            'session_id': 'session-1',
            'status': 'completed',
            'summary': body,
          },
        ],
      };
    final service = await _create(transport: transport, pinned: true);
    await service.pair(PairingQr.parse(qrText()), '测试手机', trustedByUser: true);
    await service.sync(service.profiles.single['device_id'], snapshot: true);
    await _mount(tester, service);
    await tester.scrollUntilVisible(find.text(body), 250);
    expect(find.text(body), findsOneWidget);
    expect(find.text(_origin), findsNothing);
    await _dispose(tester, service);
  });
}
