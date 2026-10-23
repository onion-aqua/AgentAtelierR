import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';
import 'package:ryza_chat_mvp/src/tts_voice_settings_migration.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const s2Models = ['s2-pro', 's2.1-pro', 's2.1-pro-free'];
  const s2Voice = 'c5de0b3f9ac54e08b21fb63120e4ebdb';
  const dramaVoice = '1380fd182e0f44639df49e1ae8feeed8';
  late Directory supportDirectory;

  setUpAll(() async {
    supportDirectory = await Directory.systemTemp.createTemp('asmr_model_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return supportDirectory.path;
          }
          return null;
        });
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await supportDirectory.delete(recursive: true);
  });

  void seed([Map<String, Object> values = const {}]) {
    SharedPreferences.setMockInitialValues({
      TtsVoiceSettingsMigration.preferenceKey:
          TtsVoiceSettingsMigration.revision,
      'fish_audio_s2_pro_migrated': true,
      ...values,
    });
  }

  setUp(seed);

  Future<AppController> load() async {
    final app = await AppController.load();
    addTearDown(app.dispose);
    return app;
  }

  test(
    'built-in markers select S2 ASMR voice only for the three S2 models',
    () {
      expect(AppController.defaultFishS2AsmrReferenceId, s2Voice);
      for (final marker in ['', '  ', s2Voice, dramaVoice]) {
        for (final model in s2Models) {
          expect(
            AppController.resolveFishAudioAsmrReferenceId(marker, model: model),
            s2Voice,
            reason: '$model must restore its ASMR voice for marker "$marker"',
          );
        }
        for (final model in [null, '', 'drama-3', 'custom-model']) {
          expect(
            AppController.resolveFishAudioAsmrReferenceId(marker, model: model),
            dramaVoice,
            reason: '$model must keep its existing built-in voice',
          );
        }
      }
      for (final model in [...s2Models, 'drama-3', '']) {
        expect(
          AppController.resolveFishAudioAsmrReferenceId(
            '  personal-asmr  ',
            model: model,
          ),
          'personal-asmr',
        );
      }
    },
  );

  for (final s2Model in s2Models) {
    test(
      '$s2Model and Drama-3 can switch ASMR voices in both directions',
      () async {
        final app = await load();
        app.ttsVoiceMode = TtsVoiceMode.asmr;
        for (final model in [s2Model, 'drama-3', s2Model]) {
          app.fishAudioModel = model;
          app.fishMcpModel = model;
          final expected = model == 'drama-3' ? dramaVoice : s2Voice;
          expect(app.activeFishAudioReferenceId, expected);
          expect(app.activeFishMcpVoice, expected);
          expect(app.fishAudioReferenceIdForMode(asmr: false), dramaVoice);
          expect(app.fishMcpVoiceForMode(asmr: false), dramaVoice);
        }
      },
    );

    for (final savedMarker in ['', s2Voice, dramaVoice]) {
      test(
        '$s2Model restores historical marker "$savedMarker" after restart',
        () async {
          seed({
            'fish_audio_model': s2Model,
            'fish_mcp_model': s2Model,
            'fish_audio_asmr_reference_id': savedMarker,
            'fish_mcp_asmr_voice': savedMarker,
            'tts_voice_mode': 'asmr',
          });
          final app = await load();
          expect(app.activeFishAudioReferenceId, s2Voice);
          expect(app.activeFishMcpVoice, s2Voice);
          app.configureFishAudio(
            enabled: true,
            model: s2Model,
            referenceId: '',
            asmrReferenceId: savedMarker,
          );
          app.configureFishMcp(
            model: s2Model,
            voice: '',
            asmrVoice: savedMarker,
            autoFallback: false,
          );
          // Allow the queued preference snapshot to complete before restarting.
          await Future<void>.delayed(Duration.zero);
          final restarted = await load();
          expect(restarted.fishAudioModel, s2Model);
          expect(restarted.fishMcpModel, s2Model);
          expect(restarted.activeFishAudioReferenceId, s2Voice);
          expect(restarted.activeFishMcpVoice, s2Voice);
          restarted.fishAudioModel = 'drama-3';
          restarted.fishMcpModel = 'drama-3';
          expect(restarted.activeFishAudioReferenceId, dramaVoice);
          expect(restarted.activeFishMcpVoice, dramaVoice);
        },
      );
    }
  }

  test(
    'REST and MCP resolve their own models and explicit fallback model',
    () async {
      final app = await load();
      app.ttsVoiceMode = TtsVoiceMode.asmr;
      for (final models in [
        ('drama-3', 's2.1-pro-free', dramaVoice, s2Voice),
        ('s2.1-pro', 'drama-3', s2Voice, dramaVoice),
      ]) {
        app.fishAudioModel = models.$1;
        app.fishMcpModel = models.$2;
        expect(app.activeFishAudioReferenceId, models.$3);
        expect(app.activeFishMcpVoice, models.$4);
        expect(app.fishMcpRestFallbackModel, models.$2);
        expect(
          app.fishAudioReferenceIdForMode(
            asmr: true,
            model: app.fishMcpRestFallbackModel,
          ),
          models.$4,
        );
      }
    },
  );

  test(
    'custom ASMR and normal voices survive model changes and restart',
    () async {
      final app = await load();
      app.configureFishAudio(
        enabled: true,
        model: 's2.1-pro-free',
        referenceId: 'normal-rest',
        asmrReferenceId: 'custom-rest',
      );
      app.configureFishMcp(
        model: 'drama-3',
        voice: 'normal-mcp',
        asmrVoice: 'custom-mcp',
        autoFallback: false,
      );
      app.setTtsVoiceMode(TtsVoiceMode.asmr);
      await Future<void>.delayed(Duration.zero);
      final restarted = await load();
      for (final model in [...s2Models, 'drama-3']) {
        restarted.fishAudioModel = model;
        restarted.fishMcpModel = model;
        expect(restarted.activeFishAudioReferenceId, 'custom-rest');
        expect(restarted.activeFishMcpVoice, 'custom-mcp');
        expect(
          restarted.fishAudioReferenceIdForMode(asmr: false),
          'normal-rest',
        );
        expect(restarted.fishMcpVoiceForMode(asmr: false), 'normal-mcp');
      }
    },
  );

  test(
    'Sophie keeps her own ASMR and normal voice settings for all models',
    () async {
      final app = await load();
      await app.setActiveCharacter(CharacterRuntimeIds.sophie);
      app.fishAudioAsmrReferenceId = 'sophie-asmr';
      app.fishMcpAsmrVoice = 'sophie-mcp-asmr';
      for (final model in [...s2Models, 'drama-3']) {
        app.fishAudioModel = model;
        app.fishMcpModel = model;
        expect(app.fishAudioReferenceIdForMode(asmr: true), 'sophie-asmr');
        expect(app.fishMcpVoiceForMode(asmr: true), 'sophie-mcp-asmr');
        expect(
          app.fishAudioReferenceIdForMode(asmr: true, model: 's2.1-pro-free'),
          'sophie-asmr',
        );
        expect(
          app.fishAudioReferenceIdForMode(asmr: false),
          AppController.defaultSophieFishAudioReferenceId,
        );
        expect(
          app.fishMcpVoiceForMode(asmr: false),
          AppController.defaultSophieFishAudioReferenceId,
        );
      }
      app.fishMcpAsmrVoice = '';
      expect(
        app.fishMcpVoiceForMode(asmr: true),
        AppController.defaultSophieFishAudioReferenceId,
      );
    },
  );
}
