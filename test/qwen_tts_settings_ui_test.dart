import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/qwen_tts_config.dart';
import 'package:ryza_chat_mvp/src/settings_detail_page.dart';
import 'package:ryza_chat_mvp/src/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<AppController> setup(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final controller = (await tester.runAsync(AppController.load))!;
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messenger = tester.binding.defaultBinaryMessenger;
    const companion = MethodChannel('agent_atelier_r/companion_runtime');
    const companionEvents = MethodChannel(
      'agent_atelier_r/companion_runtime/events',
    );
    messenger.setMockMethodCallHandler(
      companion,
      (_) async => {
        'running': true,
        'muted': false,
        'notificationsAllowed': true,
        'stopRequested': false,
      },
    );
    messenger.setMockMethodCallHandler(companionEvents, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(companion, null));
    addTearDown(
      () => messenger.setMockMethodCallHandler(companionEvents, null),
    );
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      final channel = MethodChannel(name);
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }
    const playerChannel = MethodChannel('xyz.luan/audioplayers');
    messenger.setMockMethodCallHandler(playerChannel, (call) async {
      if (call.method == 'create') {
        final id = (call.arguments as Map)['playerId'];
        final events = MethodChannel('xyz.luan/audioplayers/events/$id');
        messenger.setMockMethodCallHandler(events, (_) async => null);
        addTearDown(() => messenger.setMockMethodCallHandler(events, null));
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(playerChannel, null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: SettingsScreen(
          controller: controller,
          onMenuPressed: () {},
          initialSection: SettingsSection.audio,
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('百炼 Qwen-TTS'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(
      tester.element(find.text('百炼 Qwen-TTS')),
      alignment: .5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('百炼 Qwen-TTS'));
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String key, String label) async {
    final dropdown = find.byKey(ValueKey(key));
    await reveal(tester, dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Qwen modern preset saves matching region, voice and language on a narrow screen',
    (tester) async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        throw StateError('Changing Qwen settings must not generate paid audio');
      });
      addTearDown(client.close);
      await http.runWithClient(() async {
        final controller = await setup(tester);
        final workspace = find.byKey(const ValueKey('qwen-workspace'));
        await reveal(tester, workspace);
        await tester.enterText(workspace, 'workspace-test');
        await choose(tester, 'qwen-region', '新加坡');
        await choose(
          tester,
          'qwen-model-qwen3-tts-flash',
          QwenTtsConfig.modelLabel('qwen-audio-3.1-tts-flash'),
        );

        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('qwen-voice')))
              .controller!
              .text,
          QwenTtsConfig.modern31Voices.first,
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('qwen-clone-model')))
              .controller!
              .text,
          'qwen-audio-3.1-tts-flash',
        );
        expect(
          find.byKey(const ValueKey('qwen-reference-url')),
          findsOneWidget,
        );
        expect(find.text('选择音频'), findsNothing);
        await choose(tester, 'qwen-language', '日语');
        await choose(tester, 'qwen-sample-rate', '48000 Hz');

        final rate = find.byKey(const ValueKey('qwen-rate'));
        await reveal(tester, rate);
        final rateRect = tester.getRect(rate);
        await tester.tapAt(
          Offset(rateRect.left + rateRect.width * .75, rateRect.center.dy),
        );
        await tester.pumpAndSettle();
        final chosenRate = tester.widget<Slider>(rate).value;
        expect(chosenRate, greaterThan(1));
        expect(tester.takeException(), isNull);
        expect(requests, 0);
        expect(controller.dashScopeTtsModel, 'qwen3-tts-flash');

        await tester.tap(find.widgetWithText(FilledButton, '保存设置'));
        await tester.pumpAndSettle();
        for (
          var attempt = 0;
          attempt < 20 && controller.dashScopeTtsModel == 'qwen3-tts-flash';
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 10));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
        }
        await tester.pumpAndSettle();
        expect(find.byType(SettingsDetailPage), findsNothing);
        expect(controller.dashScopeTtsModel, 'qwen-audio-3.1-tts-flash');
        expect(
          controller.dashScopeTtsVoice,
          QwenTtsConfig.modern31Voices.first,
        );
        expect(
          QwenTtsConfig.normalizeLanguage(controller.dashScopeTtsLanguage),
          'ja',
        );
        expect(
          controller.dashScopeTtsBaseUrl,
          'https://workspace-test.ap-southeast-1.maas.aliyuncs.com'
          '/api/v1/services/audio/tts/SpeechSynthesizer',
        );
        expect(controller.dashScopeTtsOptions.sampleRate, 48000);
        expect(controller.dashScopeTtsOptions.rate, chosenRate);
        expect(requests, 0);

        final reloaded = (await tester.runAsync(AppController.load))!;
        addTearDown(reloaded.dispose);
        expect(reloaded.dashScopeTtsBaseUrl, controller.dashScopeTtsBaseUrl);
        expect(reloaded.dashScopeTtsModel, controller.dashScopeTtsModel);
        expect(reloaded.dashScopeTtsVoice, controller.dashScopeTtsVoice);
        expect(
          QwenTtsConfig.normalizeLanguage(reloaded.dashScopeTtsLanguage),
          'ja',
        );
        expect(
          reloaded.dashScopeTtsOptions.toJson(),
          controller.dashScopeTtsOptions.toJson(),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    },
  );

  testWidgets(
    'Qwen Cancel discards draft model, endpoint and voice without network calls',
    (tester) async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        throw StateError('Changing Qwen settings must not generate paid audio');
      });
      addTearDown(client.close);
      await http.runWithClient(() async {
        final controller = await setup(tester);
        final before = (controller.exportData()['preferences'] as Map).map(
          (key, value) => MapEntry(key, value),
        );
        await choose(
          tester,
          'qwen-model-qwen3-tts-flash',
          QwenTtsConfig.modelLabel('qwen-audio-3.1-tts-flash'),
        );
        final endpoint = find.byKey(const ValueKey('qwen-endpoint'));
        await reveal(tester, endpoint);
        await tester.enterText(endpoint, 'https://draft.example/tts');
        final voice = find.byKey(const ValueKey('qwen-voice'));
        await reveal(tester, voice);
        await tester.enterText(voice, 'draft-voice');
        await tester.tap(find.widgetWithText(TextButton, '取消'));
        await tester.pumpAndSettle();

        expect(find.byType(SettingsDetailPage), findsNothing);
        expect(controller.exportData()['preferences'], before);
        expect(requests, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    },
  );

  testWidgets(
    'Qwen modern blank normal voice stays on settings and preserves configuration',
    (tester) async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        throw StateError('Saving settings must not generate audio');
      });
      addTearDown(client.close);
      await http.runWithClient(() async {
        final controller = await setup(tester);
        final before = controller.exportData()['preferences'];
        await choose(
          tester,
          'qwen-model-qwen3-tts-flash',
          QwenTtsConfig.modelLabel('qwen-audio-3.1-tts-flash'),
        );
        final endpoint = find.byKey(const ValueKey('qwen-endpoint'));
        await reveal(tester, endpoint);
        await tester.enterText(
          endpoint,
          'https://workspace-direct.cn-beijing.maas.aliyuncs.com'
          '/api/v1/services/audio/tts/SpeechSynthesizer',
        );
        final voice = find.byKey(const ValueKey('qwen-voice'));
        await reveal(tester, voice);
        await tester.enterText(voice, '');
        await tester.tap(find.byKey(const ValueKey('qwen-save')));
        await tester.pumpAndSettle();

        expect(find.byType(SettingsDetailPage), findsOneWidget);
        expect(find.textContaining('请填写普通模式 Voice ID 或选择系统音色'), findsWidgets);
        expect(controller.exportData()['preferences'], before);
        expect(requests, 0);
        expect(tester.takeException(), isNull);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    },
  );

  testWidgets(
    'Qwen URL cloning uses a directly entered endpoint and snapshots its target model',
    (tester) async {
      final response = Completer<http.Response>();
      final requests = <http.Request>[];
      final client = MockClient((request) {
        requests.add(request);
        return response.future;
      });
      addTearDown(client.close);
      await http.runWithClient(() async {
        await setup(tester);
        FlutterSecureStorage.setMockInitialValues({
          'dashscope_api_key': 'test-key',
        });
        await choose(
          tester,
          'qwen-model-qwen3-tts-flash',
          QwenTtsConfig.modelLabel('qwen-audio-3.1-tts-flash'),
        );
        const directEndpoint =
            'https://workspace-direct.cn-beijing.maas.aliyuncs.com'
            '/api/v1/services/audio/tts/SpeechSynthesizer';
        final endpoint = find.byKey(const ValueKey('qwen-endpoint'));
        await reveal(tester, endpoint);
        await tester.enterText(endpoint, directEndpoint);
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('qwen-workspace')))
              .controller!
              .text,
          isEmpty,
        );
        final reference = find.byKey(const ValueKey('qwen-reference-url'));
        await reveal(tester, reference);
        await tester.enterText(
          reference,
          'https://audio.example/reference.wav',
        );
        final button = find.widgetWithText(
          OutlinedButton,
          '创建音色并自动回填 Voice ID',
        );
        await reveal(tester, button);
        final action =
            (tester.widget<OutlinedButton>(button).onPressed as dynamic)();
        for (var attempt = 0; attempt < 20 && requests.isEmpty; attempt++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
        }
        expect(requests, hasLength(1));
        expect(
          requests.single.url.toString(),
          'https://workspace-direct.cn-beijing.maas.aliyuncs.com'
          '/api/v1/services/audio/tts/customization',
        );
        final sent = jsonDecode(requests.single.body) as Map;
        expect(
          (sent['input'] as Map)['target_model'],
          'qwen-audio-3.1-tts-flash',
        );

        // Simulate a controller edit while the network response is still pending.
        // Completion must use the model that was actually sent for enrollment.
        tester
                .widget<TextField>(
                  find.byKey(const ValueKey('qwen-clone-model')),
                )
                .controller!
                .text =
            'qwen-audio-3.0-tts-plus';
        const createdVoice = 'qwen-audio-3.1-tts-flash-ryzavoice-id';
        response.complete(
          http.Response(
            jsonEncode({
              'output': {'voice_id': createdVoice},
            }),
            200,
          ),
        );
        await action;
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('qwen-model')))
              .controller!
              .text,
          'qwen-audio-3.1-tts-flash',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('qwen-voice')))
              .controller!
              .text,
          createdVoice,
        );
        expect(
          tester.widget<TextField>(endpoint).controller!.text,
          directEndpoint,
        );
        expect(requests, hasLength(1));
        expect(tester.takeException(), isNull);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    },
  );
}
