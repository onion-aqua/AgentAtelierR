import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/qwen_tts_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  const options = QwenTtsOptions(
    sampleRate: 48000,
    rate: 1.15,
    pitch: 0.9,
    volume: 65,
    optimizeInstructions: false,
  );

  test('Qwen options survive preferences and backup round trips', () async {
    final controller = await AppController.load();
    _configureQwen(controller, options: options);
    await Future<void>.delayed(Duration.zero);

    final stored = (await SharedPreferences.getInstance()).getString(
      'dashscope_tts_options',
    );
    expect(jsonDecode(stored!), options.toJson());

    final reloaded = await AppController.load();
    expect(reloaded.dashScopeTtsOptions.toJson(), options.toJson());
    expect(reloaded.dashScopeTtsModel, 'qwen3-tts-instruct-flash');
    expect(reloaded.dashScopeTtsVoice, 'custom-normal');
    expect(reloaded.dashScopeTtsAsmrVoice, 'custom-asmr');

    final backup = controller.exportData();
    expect(
      (backup['preferences'] as Map)['dashscope_tts_options'],
      options.toJson(),
    );

    final restored = await AppController.load();
    restored.dashScopeTtsOptions = const QwenTtsOptions();
    await restored.importData(backup);
    expect(restored.dashScopeTtsOptions.toJson(), options.toJson());

    controller.dispose();
    reloaded.dispose();
    restored.dispose();
  });

  test(
    'older preferences keep configured model and voices with default options',
    () async {
      SharedPreferences.setMockInitialValues({
        'dashscope_tts_model': 'qwen3-tts-flash',
        'dashscope_tts_voice': 'previous-normal',
        'dashscope_tts_asmr_voice': 'previous-asmr',
        'dashscope_tts_base_url': 'https://configured.example/generation',
      });
      final controller = await AppController.load();

      expect(
        controller.dashScopeTtsOptions.toJson(),
        const QwenTtsOptions().toJson(),
      );
      expect(controller.dashScopeTtsModel, 'qwen3-tts-flash');
      expect(controller.dashScopeTtsVoice, 'previous-normal');
      expect(controller.dashScopeTtsAsmrVoice, 'previous-asmr');
      expect(
        controller.dashScopeTtsBaseUrl,
        'https://configured.example/generation',
      );

      controller.dispose();
    },
  );

  test(
    'older backups and other provider settings preserve Qwen options',
    () async {
      final controller = await AppController.load();
      _configureQwen(controller, options: options);
      _configureQwen(controller);
      expect(controller.dashScopeTtsOptions.toJson(), options.toJson());

      final oldBackup = controller.exportData();
      (oldBackup['preferences'] as Map).remove('dashscope_tts_options');
      await controller.importData(oldBackup);
      expect(controller.dashScopeTtsOptions.toJson(), options.toJson());

      controller.dispose();
    },
  );

  test('malformed saved Qwen option JSON restores defaults', () async {
    SharedPreferences.setMockInitialValues({
      'dashscope_tts_options': '{broken',
    });
    final controller = await AppController.load();

    expect(
      controller.dashScopeTtsOptions.toJson(),
      const QwenTtsOptions().toJson(),
    );

    controller.dispose();
  });

  test('blank modern voice falls back within its model family', () async {
    final controller = await AppController.load();
    _configureQwen(controller, model: 'qwen-audio-3.1-tts-flash', voice: '');

    expect(controller.dashScopeTtsVoice, QwenTtsConfig.modern31Voices.first);
    expect(controller.dashScopeTtsVoice, isNot('Cherry'));

    _configureQwen(controller, model: 'qwen-audio-future-tts', voice: '');
    expect(controller.dashScopeTtsVoice, isEmpty);

    _configureQwen(controller, voice: '');
    expect(controller.dashScopeTtsVoice, 'Cherry');
    controller.dispose();
  });
}

void _configureQwen(
  AppController controller, {
  QwenTtsOptions? options,
  String model = 'qwen3-tts-instruct-flash',
  String voice = 'custom-normal',
}) {
  controller.configureTts(
    enabled: true,
    provider: TtsProvider.dashScope,
    fishModel: controller.fishAudioModel,
    fishReferenceId: controller.fishAudioReferenceId,
    fishAsmrReferenceId: controller.fishAudioAsmrReferenceId,
    format: controller.fishAudioFormat,
    latency: controller.fishAudioLatency,
    speed: controller.fishAudioSpeed,
    dashBaseUrl: controller.dashScopeTtsBaseUrl,
    dashScopeModel: model,
    dashScopeVoice: voice,
    dashScopeAsmrVoice: 'custom-asmr',
    dashScopeLanguage: 'Japanese',
    dashInstructions: '自然地朗读。',
    dashScopeOptions: options,
    genericBaseUrl: controller.genericTtsBaseUrl,
    genericModel: controller.genericTtsModel,
    genericVoice: controller.genericTtsVoice,
    genericAsmrVoice: controller.genericTtsAsmrVoice,
    emotionIntensity: controller.ttsEmotionIntensity,
    previewText: controller.ttsPreviewText,
  );
}
