import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:ryza_chat_mvp/src/relay/relay_page.dart';
import 'package:ryza_chat_mvp/src/relay/relay_protocol.dart';
import 'package:ryza_chat_mvp/src/relay/relay_server_config.dart';
import 'package:ryza_chat_mvp/src/relay/relay_service.dart';

import 'test_transport.dart';

const _origin = 'https://relay.example.test';
const _otherOrigin = 'https://other.example.test';
const _pasteButton = '粘贴配对数据 / 重新配对';

Future<RelayService> _mount(
  WidgetTester tester,
  TestTransport transport, {
  bool pinned = true,
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
  await tester.pumpWidget(
    MaterialApp(
      home: RelayPage(
        service: service,
        scanPairingCode: (_) async =>
            throw StateError('Windows must not invoke the camera scanner'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return service;
}

Future<void> _paste(WidgetTester tester, String text) async {
  await tester.tap(find.text(_pasteButton));
  await tester.pumpAndSettle();
  expect(find.text('粘贴配对二维码数据'), findsOneWidget);
  expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.text('继续'));
  // A consent dialog deliberately leaves the underlying progress bar active.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _dispose(WidgetTester tester, RelayService service) async {
  await tester.pumpWidget(const SizedBox());
  service.dispose();
  // Restore before Flutter checks its per-widget-test debug invariants.
  debugDefaultTargetPlatformOverride = null;
}

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets(
    'Windows exposes paste pairing and omits camera and mobile push',
    (tester) async {
      final service = await _mount(tester, TestTransport());
      expect(find.text(_pasteButton), findsOneWidget);
      expect(find.text('扫码绑定 / 重新配对'), findsNothing);
      expect(find.byType(MobileScanner), findsNothing);
      expect(find.byIcon(Icons.qr_code_scanner), findsNothing);
      expect(find.text('启用推送 / 申请通知权限'), findsNothing);
      expect(find.text('停用推送'), findsNothing);
      expect(find.text('远程通知'), findsNothing);
      expect(find.textContaining('重新打开后补拉'), findsOneWidget);
      expect(find.textContaining(_origin), findsNothing);
      await _dispose(tester, service);
    },
  );

  testWidgets(
    'Windows pinned paste keeps consent and hides the private origin',
    (tester) async {
      final transport = TestTransport();
      final service = await _mount(tester, transport);
      await _paste(tester, qrText());
      expect(find.text('确认配对此 PC'), findsOneWidget);
      expect(find.textContaining('内置联动服务配对'), findsOneWidget);
      expect(find.textContaining(_origin), findsNothing);
      expect(find.byType(MobileScanner), findsNothing);
      expect(transport.calls, isEmpty);
      expect(service.profiles, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(transport.calls, isEmpty);
      expect(service.profiles, isEmpty);
      await _dispose(tester, service);
    },
  );

  testWidgets(
    'Windows pasted pairing uses normal authenticated sync after consent',
    (tester) async {
      final transport = TestTransport();
      final service = await _mount(tester, transport);
      await _paste(tester, qrText());
      expect(transport.calls, isEmpty);
      await tester.tap(find.text('配对连接'));
      await tester.pumpAndSettle();
      final claims = transport.calls
          .where((call) => call['path'] == '/v1/pairings/claim')
          .toList();
      expect(claims, hasLength(1));
      expect(claims.single['origin'], _origin);
      expect(object(claims.single['body'])['pairing_id'], pairingId);
      expect(
        object(claims.single['body'])['device_name'],
        'AgentAtelierR Windows',
      );
      expect(service.profiles.single['state'], 'confirmed');
      expect(
        transport.calls.any((call) => call['path'] == '/v1/state'),
        isTrue,
      );
      expect(find.textContaining(_origin), findsNothing);
      await _dispose(tester, service);
    },
  );

  testWidgets('Windows pasted QR cannot bypass the pinned server check', (
    tester,
  ) async {
    final transport = TestTransport();
    final service = await _mount(tester, transport);
    await _paste(tester, qrText(origin: _otherOrigin));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('二维码与当前中继地址不一致'), findsOneWidget);
    expect(find.textContaining(_origin), findsNothing);
    expect(find.textContaining(_otherOrigin), findsNothing);
    expect(transport.calls, isEmpty);
    expect(service.profiles, isEmpty);
    await _dispose(tester, service);
  });

  testWidgets('Windows malformed paste never echoes QR secrets', (
    tester,
  ) async {
    final transport = TestTransport();
    final service = await _mount(tester, transport);
    await _paste(tester, '$_otherOrigin synthetic-qr-secret not json');
    await tester.pumpAndSettle();
    expect(find.textContaining('配对二维码格式无效'), findsOneWidget);
    expect(find.textContaining(_otherOrigin), findsNothing);
    expect(find.textContaining('synthetic-qr-secret'), findsNothing);
    expect(transport.calls, isEmpty);
    await _dispose(tester, service);
  });

  testWidgets('Windows configurable server still requires explicit trust', (
    tester,
  ) async {
    final transport = TestTransport();
    final service = await _mount(tester, transport, pinned: false);
    await _paste(tester, qrText(origin: _otherOrigin));
    expect(find.text('确认信任此联动服务器'), findsOneWidget);
    expect(find.textContaining(_otherOrigin), findsOneWidget);
    expect(transport.calls, isEmpty);
    await tester.tap(find.text('信任并配对连接'));
    await tester.pumpAndSettle();
    expect(transport.calls.first['origin'], _otherOrigin);
    expect(service.profiles.single['state'], 'confirmed');
    await _dispose(tester, service);
  });
}
