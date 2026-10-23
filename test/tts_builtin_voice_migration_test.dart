import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';
import 'package:ryza_chat_mvp/src/mimo_tts_config.dart';
import 'package:ryza_chat_mvp/src/qwen_tts_config.dart';
import 'package:ryza_chat_mvp/src/tts_voice_settings_migration.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory supportDirectory;

  setUpAll(() async {
    supportDirectory = await Directory.systemTemp.createTemp(
      'voice_migration_',
    );
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

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppController> load() async {
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    return controller;
  }

  test(
    'blank overrides resolve to the correct built-in character voice',
    () async {
      final app = await load();
      expect(app.fishAudioReferenceId, isEmpty);
      expect(app.fishMcpVoice, isEmpty);
      expect(
        app.activeFishAudioReferenceId,
        '1380fd182e0f44639df49e1ae8feeed8',
      );
      expect(app.activeFishMcpVoice, app.activeFishAudioReferenceId);
      expect(
        AppController.defaultFishAudioAsmrReferenceId,
        AppController.defaultFishAudioReferenceId,
      );
      expect(
        app.fishAudioReferenceIdForMode(asmr: true),
        AppController.defaultFishS2AsmrReferenceId,
      );
      expect(
        app.fishMcpVoiceForMode(asmr: true),
        AppController.defaultFishAudioAsmrReferenceId,
      );

      app.activeCharacterId = CharacterRuntimeIds.sophie;
      expect(
        app.resolvedFishAudioReferenceId,
        AppController.defaultSophieFishAudioReferenceId,
      );
      expect(
        app.fishMcpVoiceForMode(asmr: false),
        AppController.defaultSophieFishAudioReferenceId,
      );
      expect(
        AppController.resolveFishAudioReferenceId(
          '  ',
          characterId: CharacterRuntimeIds.sophie,
        ),
        AppController.defaultSophieFishAudioReferenceId,
      );
      app.fishAudioReferenceId = ' personal-voice ';
      app.fishMcpVoice = ' personal-mcp-voice ';
      expect(app.activeFishAudioReferenceId, 'personal-voice');
      expect(app.activeFishMcpVoice, 'personal-mcp-voice');
      app.fishAudioAsmrReferenceId = 'sophie-personal-asmr';
      app.fishMcpAsmrVoice = 'sophie-personal-mcp-asmr';
      expect(
        app.fishAudioReferenceIdForMode(asmr: true),
        'sophie-personal-asmr',
      );
      expect(app.fishMcpVoiceForMode(asmr: true), 'sophie-personal-mcp-asmr');
    },
  );

  test('upgrade removes all legacy remote voice overrides once and preserves other data', () async {
    final slots = {
      'character': {
        'active': 0,
        'entries': [
          {'text': '用户的人物设定'},
        ],
      },
    };
    final oldSession = {
      'format': 'agent-atelier-r-local-backup',
      'version': 1,
      'characterId': CharacterRuntimeIds.sophie,
      'preferences': {
        'fishAudioReferenceId': 'old-sophie',
        'fishAudioAsmrReferenceId': 'old-sophie-asmr',
        'fishMcpVoice': 'old-sophie-mcp',
        'fishMcpAsmrVoice': 'old-sophie-mcp-asmr',
        'dashScopeTtsModel': 'qwen-audio-3.1-tts-flash',
        'dashScopeTtsVoice': 'old-qwen',
        'dashScopeTtsAsmrVoice': 'old-qwen-asmr',
        'genericTtsVoice': 'old-generic',
        'genericTtsAsmrVoice': 'old-generic-asmr',
        'mimoTts': {
          'voice': 'old-mimo',
          'referencePath': 'keep-reference.wav',
          'model': MimoTtsConfig.cloneModel,
        },
        'fishMcpModel': 'drama-3',
        'localTtsVoiceProfileId': 'local-reference',
      },
    };
    SharedPreferences.setMockInitialValues({
      'fish_audio_reference_id': 'old-fish',
      'fish_audio_asmr_reference_id': 'old-fish-asmr',
      'fish_mcp_voice': 'old-mcp',
      'fish_mcp_asmr_voice': 'old-mcp-asmr',
      'fish_mcp_model': 'drama-3',
      'fish_audio_speed': 1.25,
      'fish_audio_base_url': 'https://fish.example/tts',
      'dashscope_tts_model': 'qwen-audio-3.1-tts-flash',
      'dashscope_tts_voice': 'old-qwen',
      'dashscope_tts_asmr_voice': 'old-qwen-asmr',
      'generic_tts_voice': 'old-generic',
      'generic_tts_asmr_voice': 'old-generic-asmr',
      'local_tts_voice_profile_id': 'keep-local-reference',
      'mimo_tts_config': jsonEncode({
        'voice': 'old-mimo',
        'model': MimoTtsConfig.cloneModel,
        'referencePath': 'keep-reference.wav',
      }),
      'settings_slots_v1': jsonEncode(slots),
      'character_sessions_v1': jsonEncode({
        CharacterRuntimeIds.sophie: oldSession,
      }),
      'realtime_call_settings_v1': jsonEncode({
        'asr': {'modelPath': 'keep-asr.onnx'},
        'fishModel': 'drama-3',
        'voiceOverrides': {'npc_ryza': 'old-call-voice'},
      }),
      'unrelated_key': 'keep-value',
    });

    final app = await load();
    expect(app.fishAudioReferenceId, isEmpty);
    expect(app.fishMcpVoice, isEmpty);
    expect(app.fishMcpAsmrVoice, isEmpty);
    expect(
      app.fishAudioAsmrReferenceId,
      AppController.defaultFishAudioAsmrReferenceId,
    );
    expect(app.dashScopeTtsVoice, QwenTtsConfig.modern31Voices.first);
    expect(app.dashScopeTtsAsmrVoice, isEmpty);
    expect(app.genericTtsVoice, 'alloy');
    expect(app.genericTtsAsmrVoice, isEmpty);
    expect(app.mimoTts.voice, const MimoTtsConfig().voice);
    expect(app.mimoTts.referencePath, 'keep-reference.wav');
    expect(app.localTtsVoiceProfileId, 'keep-local-reference');
    expect(app.fishMcpModel, 'drama-3');
    expect(app.fishAudioSpeed, 1.25);
    expect(app.fishAudioBaseUrl, 'https://fish.example/tts');

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('unrelated_key'), 'keep-value');
    expect(jsonDecode(preferences.getString('settings_slots_v1')!), slots);
    final sessions =
        jsonDecode(preferences.getString('character_sessions_v1')!) as Map;
    final session = sessions[CharacterRuntimeIds.sophie] as Map;
    expect(session[TtsVoiceSettingsMigration.backupKey], 1);
    final saved = session['preferences'] as Map;
    expect(saved['fishAudioReferenceId'], isEmpty);
    expect(saved['fishMcpAsmrVoice'], isEmpty);
    expect(saved['dashScopeTtsVoice'], QwenTtsConfig.modern31Voices.first);
    expect(saved['localTtsVoiceProfileId'], 'local-reference');
    expect((saved['mimoTts'] as Map)['referencePath'], 'keep-reference.wav');
    expect(preferences.getInt(TtsVoiceSettingsMigration.preferenceKey), 1);
    final calls =
        jsonDecode(preferences.getString('realtime_call_settings_v1')!) as Map;
    expect(calls['voiceOverrides'], isEmpty);
    expect((calls['asr'] as Map)['modelPath'], 'keep-asr.onnx');
    expect(calls['fishModel'], 'drama-3');

    app.configureFishAudio(
      enabled: true,
      model: 'drama-3',
      referenceId: 'new-user-voice',
    );
    app.configureFishMcp(
      model: 'drama-3',
      voice: 'new-mcp',
      asmrVoice: 'new-asmr',
      autoFallback: false,
    );
    final restarted = await load();
    expect(restarted.fishAudioReferenceId, 'new-user-voice');
    expect(restarted.fishMcpVoice, 'new-mcp');
    expect(restarted.fishMcpAsmrVoice, 'new-asmr');

    await restarted.setActiveCharacter(CharacterRuntimeIds.sophie);
    expect(restarted.fishAudioReferenceId, isEmpty);
    expect(
      restarted.activeFishAudioReferenceId,
      AppController.defaultSophieFishAudioReferenceId,
    );
    expect(
      restarted.activeFishMcpVoice,
      AppController.defaultSophieFishAudioReferenceId,
    );
    restarted.configureFishAudio(
      enabled: true,
      model: 'drama-3',
      referenceId: 'new-sophie-voice',
    );
    final sophieRestarted = await load();
    expect(sophieRestarted.activeCharacterId, CharacterRuntimeIds.sophie);
    expect(sophieRestarted.activeFishAudioReferenceId, 'new-sophie-voice');
  });

  test('old backup import cannot revive retired IDs, new backup preserves replacement IDs', () async {
    final app = await load();
    final backup = app.exportData();
    backup.remove(TtsVoiceSettingsMigration.backupKey);
    (backup['preferences'] as Map).addAll(<String, Object>{
      'fishAudioReferenceId': 'retired-fish',
      'fishAudioAsmrReferenceId': 'retired-asmr',
      'fishMcpVoice': 'retired-mcp',
      'fishMcpAsmrVoice': 'retired-mcp-asmr',
      'dashScopeTtsModel': 'qwen-audio-3.1-tts-flash',
      'dashScopeTtsVoice': 'retired-qwen',
      'genericTtsVoice': 'retired-generic',
      'fishAudioSpeed': 1.3,
      'fishMcpModel': 'drama-3',
    });
    await app.importData(backup);
    expect(app.fishAudioReferenceId, isEmpty);
    expect(app.fishMcpVoice, isEmpty);
    expect(app.fishMcpAsmrVoice, isEmpty);
    expect(app.dashScopeTtsVoice, QwenTtsConfig.modern31Voices.first);
    expect(app.genericTtsVoice, 'alloy');
    expect(
      app.activeFishAudioReferenceId,
      AppController.defaultFishAudioReferenceId,
    );
    expect(app.fishAudioSpeed, 1.3);
    expect(app.fishMcpModel, 'drama-3');

    app.configureFishAudio(
      enabled: true,
      model: 'drama-3',
      referenceId: 'replacement-fish',
    );
    app.configureFishMcp(
      model: 'drama-3',
      voice: 'replacement-mcp',
      asmrVoice: 'replacement-asmr',
      autoFallback: false,
    );
    final replacement =
        jsonDecode(jsonEncode(app.exportData())) as Map<String, dynamic>;
    expect(replacement[TtsVoiceSettingsMigration.backupKey], 1);
    await app.importData(backup);
    expect(app.fishAudioReferenceId, isEmpty);
    await app.importData(replacement);
    expect(app.fishAudioReferenceId, 'replacement-fish');
    expect(app.fishMcpVoice, 'replacement-mcp');
    expect(app.fishMcpAsmrVoice, 'replacement-asmr');
    final restarted = await load();
    expect(restarted.fishAudioReferenceId, 'replacement-fish');
    expect(restarted.fishMcpAsmrVoice, 'replacement-asmr');
  });

  test('historical built-in ASMR ID resolves by model without clearing custom voices', () async {
    SharedPreferences.setMockInitialValues({
      TtsVoiceSettingsMigration.preferenceKey:
          TtsVoiceSettingsMigration.revision,
      'fish_audio_reference_id': 'keep-custom-normal',
      'fish_audio_asmr_reference_id':
          AppController.legacyFishAudioAsmrReferenceId,
      'fish_mcp_voice': 'keep-custom-mcp-normal',
      'fish_mcp_asmr_voice': AppController.legacyFishAudioAsmrReferenceId,
      'tts_voice_mode': 'asmr',
    });
    final app = await load();
    expect(app.fishAudioReferenceId, 'keep-custom-normal');
    expect(app.fishMcpVoice, 'keep-custom-mcp-normal');
    expect(
      app.activeFishAudioReferenceId,
      AppController.defaultFishS2AsmrReferenceId,
    );
    expect(app.activeFishMcpVoice, AppController.defaultFishAudioReferenceId);

    app.configureFishAudio(
      enabled: true,
      model: 's2-pro',
      referenceId: 'keep-custom-normal',
    );
    app.fishAudioAsmrReferenceId = 'new-custom-asmr';
    app.configureFishMcp(
      model: 'drama-3',
      voice: 'keep-custom-mcp-normal',
      asmrVoice: 'new-custom-mcp-asmr',
      autoFallback: false,
    );
    final restarted = await load();
    expect(restarted.fishAudioReferenceId, 'keep-custom-normal');
    expect(restarted.activeFishAudioReferenceId, 'new-custom-asmr');
    expect(restarted.fishMcpVoice, 'keep-custom-mcp-normal');
    expect(restarted.activeFishMcpVoice, 'new-custom-mcp-asmr');
  });

  test('saved character sessions and current backups resolve model-specific ASMR defaults', () async {
    final app = await load();
    final oldSession = app.exportData();
    (oldSession['preferences'] as Map)
      ..['fishAudioReferenceId'] = 'saved-normal'
      ..['fishAudioAsmrReferenceId'] =
          AppController.legacyFishAudioAsmrReferenceId
      ..['fishMcpVoice'] = 'saved-mcp-normal'
      ..['fishMcpAsmrVoice'] = AppController.legacyFishAudioAsmrReferenceId
      ..['ttsVoiceMode'] = 'asmr';
    final preferences = await SharedPreferences.getInstance();
    final sophieSession =
        jsonDecode(jsonEncode(app.exportData())) as Map<String, dynamic>;
    sophieSession['characterId'] = CharacterRuntimeIds.sophie;
    (sophieSession['preferences'] as Map)
      ..['fishAudioAsmrReferenceId'] = ''
      ..['ttsVoiceMode'] = 'normal';
    await preferences.setString(
      'active_character_id_v1',
      CharacterRuntimeIds.sophie,
    );
    await preferences.setString(
      'character_sessions_v1',
      jsonEncode({
        CharacterRuntimeIds.ryza: oldSession,
        CharacterRuntimeIds.sophie: sophieSession,
      }),
    );
    // A restore from the already migrated character bank must resolve the old
    // built-in even though migration no longer removes user voice settings.
    final restored = await load();
    await restored.setActiveCharacter(CharacterRuntimeIds.ryza);
    expect(restored.fishAudioReferenceId, 'saved-normal');
    expect(restored.fishMcpVoice, 'saved-mcp-normal');
    expect(
      restored.activeFishAudioReferenceId,
      AppController.defaultFishS2AsmrReferenceId,
    );
    expect(
      restored.activeFishMcpVoice,
      AppController.defaultFishAudioReferenceId,
    );
    await restored.importData(oldSession);
    expect(
      restored.activeFishAudioReferenceId,
      AppController.defaultFishS2AsmrReferenceId,
    );
    expect(
      restored.activeFishMcpVoice,
      AppController.defaultFishAudioReferenceId,
    );
    await restored.setActiveCharacter(CharacterRuntimeIds.sophie);
    expect(
      restored.activeFishAudioReferenceId,
      AppController.defaultSophieFishAudioReferenceId,
    );
    await restored.setActiveCharacter(CharacterRuntimeIds.ryza);
    expect(
      restored.activeFishAudioReferenceId,
      AppController.defaultFishS2AsmrReferenceId,
    );
    expect(
      restored.activeFishMcpVoice,
      AppController.defaultFishAudioReferenceId,
    );
    final restarted = await load();
    expect(
      restarted.activeFishAudioReferenceId,
      AppController.defaultFishS2AsmrReferenceId,
    );
    expect(
      restarted.activeFishMcpVoice,
      AppController.defaultFishAudioReferenceId,
    );
  });
}
