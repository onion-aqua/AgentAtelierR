import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppController> load() async {
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    return controller;
  }

  test(
    'REST fallback sends the selected MCP model instead of the old API model',
    () async {
      final controller = await load();
      controller.fishAudioModel = 's2.1-pro';
      controller.configureFishMcp(
        model: 'drama-3',
        voice: 'local-voice',
        autoFallback: true,
      );
      final models = <String?>[];
      final client = MockClient((request) async {
        models.add(request.headers['model']);
        return http.Response.bytes(
          [0x49, 0x44, 0x33],
          200,
          headers: {'content-type': 'audio/mpeg'},
        );
      });
      addTearDown(client.close);
      await FishAudioClient(client: client).synthesizeBytes(
        apiKey: 'local-test-only',
        referenceId: 'local-voice',
        text: 'local test',
        model: controller.fishMcpRestFallbackModel,
      );
      expect(models, ['drama-3']);
      expect(controller.fishAudioModel, 's2.1-pro');
    },
  );

  test(
    'service-default MCP selection retains the configured REST fallback model',
    () async {
      final controller = await load();
      controller.fishAudioModel = 's2.1-pro-free';
      controller.configureFishMcp(model: '', voice: '', autoFallback: true);
      expect(controller.fishMcpRestFallbackModel, 's2.1-pro-free');
    },
  );

  test(
    'ordinary and ASMR requests choose separate configured voices',
    () async {
      final controller = await load();
      controller.configureFishMcp(
        model: 'drama-3',
        voice: ' ordinary-voice ',
        asmrVoice: ' asmr-voice ',
        autoFallback: false,
      );
      expect(controller.fishMcpVoice, 'ordinary-voice');
      expect(controller.fishMcpAsmrVoice, 'asmr-voice');
      expect(controller.activeFishMcpVoice, 'ordinary-voice');
      expect(controller.fishMcpVoiceForMode(asmr: false), 'ordinary-voice');
      // Continuous ASMR explicitly selects its voice even in ordinary mode.
      expect(controller.fishMcpVoiceForMode(asmr: true), 'asmr-voice');
      expect(controller.setTtsVoiceMode(TtsVoiceMode.asmr), isTrue);
      expect(controller.activeFishMcpVoice, 'asmr-voice');
      expect(controller.fishMcpVoiceForMode(asmr: false), 'ordinary-voice');
      controller.setTtsVoiceMode(TtsVoiceMode.normal);
      expect(controller.activeFishMcpVoice, 'ordinary-voice');
    },
  );

  test('blank Ryza voice configurations resolve the built-in ordinary and ASMR voices', () async {
    final controller = await load();
    controller.configureFishMcp(
      model: '',
      voice: 'ordinary-voice',
      asmrVoice: '  ',
      autoFallback: false,
    );
    controller.setTtsVoiceMode(TtsVoiceMode.asmr);
    expect(
      controller.activeFishMcpVoice,
      AppController.defaultFishAudioAsmrReferenceId,
    );
    expect(
      controller.fishMcpVoiceForMode(asmr: true),
      AppController.defaultFishAudioAsmrReferenceId,
    );
    expect(controller.hasVoiceForMode(TtsVoiceMode.asmr), isTrue);
    controller.configureFishMcp(model: '', voice: '', autoFallback: false);
    expect(
      controller.activeFishMcpVoice,
      AppController.defaultFishAudioAsmrReferenceId,
    );
    expect(
      controller.fishMcpVoiceForMode(asmr: false),
      AppController.defaultFishAudioReferenceId,
    );
  });

  test('omitting ASMR on an ordinary update preserves it; explicit blank clears it', () async {
    final controller = await load();
    controller.configureFishMcp(
      model: 'drama-3',
      voice: 'ordinary',
      asmrVoice: 'asmr',
      autoFallback: false,
    );
    controller.configureFishMcp(
      model: 'new-model',
      voice: 'new-ordinary',
      autoFallback: true,
    );
    expect(controller.fishMcpAsmrVoice, 'asmr');
    expect(controller.fishMcpVoiceForMode(asmr: true), 'asmr');
    controller.configureFishMcp(
      model: 'new-model',
      voice: 'new-ordinary',
      asmrVoice: '',
      autoFallback: false,
    );
    expect(controller.fishMcpAsmrVoice, isEmpty);
    expect(
      controller.fishMcpVoiceForMode(asmr: true),
      AppController.defaultFishAudioAsmrReferenceId,
    );
  });

  test('separate voices and mode survive controller restart', () async {
    final controller = await load();
    controller.configureFishMcp(
      model: 'drama-3',
      voice: 'ordinary',
      asmrVoice: 'asmr',
      autoFallback: false,
    );
    controller.setTtsVoiceMode(TtsVoiceMode.asmr);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('fish_mcp_voice'), 'ordinary');
    expect(preferences.getString('fish_mcp_asmr_voice'), 'asmr');
    final restored = await load();
    expect(restored.fishMcpVoice, 'ordinary');
    expect(restored.fishMcpAsmrVoice, 'asmr');
    expect(restored.ttsVoiceMode, TtsVoiceMode.asmr);
    expect(restored.activeFishMcpVoice, 'asmr');
  });

  test(
    'legacy preferences retire the old voice and resolve built-in ASMR',
    () async {
      SharedPreferences.setMockInitialValues({
        'tts_provider': 'fishAudioMcp',
        'fish_mcp_voice': 'legacy-voice',
        'tts_voice_mode': 'asmr',
      });
      final controller = await load();
      expect(controller.fishMcpAsmrVoice, isEmpty);
      expect(controller.fishMcpVoice, isEmpty);
      expect(
        controller.activeFishMcpVoice,
        AppController.defaultFishAudioAsmrReferenceId,
      );
    },
  );

  test('portable backup round trips both voices and selected mode', () async {
    final source = await load();
    source.configureFishMcp(
      model: 'drama-3',
      voice: 'ordinary-backup',
      asmrVoice: 'asmr-backup',
      autoFallback: false,
    );
    source.setTtsVoiceMode(TtsVoiceMode.asmr);
    final backup =
        jsonDecode(jsonEncode(source.exportData())) as Map<String, dynamic>;
    expect((backup['preferences'] as Map)['fishMcpAsmrVoice'], 'asmr-backup');
    final target = await load();
    target.configureFishMcp(
      model: '',
      voice: 'other',
      asmrVoice: 'other-asmr',
      autoFallback: true,
    );
    await target.importData(backup);
    expect(target.fishMcpVoice, 'ordinary-backup');
    expect(target.fishMcpAsmrVoice, 'asmr-backup');
    expect(target.activeFishMcpVoice, 'asmr-backup');
    expect(target.fishMcpAutoFallback, isFalse);
    final restarted = await load();
    expect(restarted.activeFishMcpVoice, 'asmr-backup');
  });

  test(
    'legacy backup without ASMR field preserves the existing ASMR setting',
    () async {
      final controller = await load();
      controller.configureFishMcp(
        model: '',
        voice: 'ordinary',
        asmrVoice: 'keep-asmr',
        autoFallback: false,
      );
      final backup = controller.exportData();
      (backup['preferences'] as Map)
        ..remove('fishMcpAsmrVoice')
        ..['fishMcpVoice'] = 'imported-ordinary';
      await controller.importData(backup);
      expect(controller.fishMcpVoice, 'imported-ordinary');
      expect(controller.fishMcpAsmrVoice, 'keep-asmr');
    },
  );
}
