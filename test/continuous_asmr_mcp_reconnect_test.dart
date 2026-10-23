import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/continuous_asmr_page.dart';
import 'package:ryza_chat_mvp/src/fish_mcp_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'MCP without saved OAuth reports connection rather than API key',
    (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      final channels = <String>{
        'xyz.luan/audioplayers',
        'xyz.luan/audioplayers.global',
        'agent_atelier_r/companion_runtime',
        'agent_atelier_r/companion_runtime/events',
        'plugins.flutter.io/path_provider',
      };
      for (final name in channels) {
        messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
          if (name == 'plugins.flutter.io/path_provider') {
            return Directory.systemTemp.path;
          }
          if (name == 'agent_atelier_r/companion_runtime') {
            return {
              'running': true,
              'stopRequested': false,
              'muted': false,
              'callActive': false,
              'notificationsAllowed': true,
            };
          }
          if (name == 'xyz.luan/audioplayers' && call.method == 'create') {
            final id = (call.arguments as Map)['playerId'];
            final events = 'xyz.luan/audioplayers/events/$id';
            channels.add(events);
            messenger.setMockMethodCallHandler(
              MethodChannel(events),
              (_) async => null,
            );
          }
          return null;
        });
      }
      addTearDown(() {
        for (final name in channels) {
          messenger.setMockMethodCallHandler(MethodChannel(name), null);
        }
      });
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({
        'openai_api_key': 'local-test-key',
      });
      final service = FishMcpService.instance;
      await service.disconnect(clearError: true);
      final controller = (await tester.runAsync(AppController.load))!;
      addTearDown(controller.dispose);
      controller.configureAi(
        enabled: true,
        baseUrl: 'https://example.test/v1',
        model: 'test-llm',
      );
      controller.configureFishMcp(
        model: 'drama-3',
        voice: '',
        autoFallback: true,
      );
      var networkRequests = 0;
      final client = MockClient((request) async {
        networkRequests++;
        throw StateError('Missing OAuth must not request LLM, TTS, or REST');
      });
      addTearDown(client.close);
      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(home: ContinuousAsmrPage(controller: controller)),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '雨声');
        await tester.tap(find.widgetWithText(FilledButton, '确定'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Fish Audio MCP 未恢复连接'), findsOneWidget);
        expect(find.textContaining('API Key 未配置'), findsNothing);
        expect(networkRequests, 0);
        expect(service.isReady, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }, () => client);
    },
  );
}
