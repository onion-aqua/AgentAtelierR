import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/fish_speech_speed_defaults.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'Windows and non-Fish defaults preserve their existing 1.0 speed',
    () async {
      expect(FishSpeechSpeedDefaults.defaultForProvider('generic'), 1);
      expect(FishSpeechSpeedDefaults.defaultForProvider('dashScope'), 1);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({'fish_audio_speed': 1.0});
      final preferences = await SharedPreferences.getInstance();
      await FishSpeechSpeedDefaults.migrate(preferences);
      expect(preferences.getDouble('fish_audio_speed'), 1);
      final app = await AppController.load();
      addTearDown(app.dispose);
      expect(app.fishAudioSpeed, 1);
      expect(FishSpeechSpeedDefaults.defaultForProvider('fishAudioMcp'), 1);
    },
  );

  test('new Fish settings use 0.9 for ordinary and ASMR speech', () async {
    final app = await AppController.load();
    addTearDown(app.dispose);
    expect(app.fishAudioSpeed, .9);
    app.configureFishMcp(model: 'drama-3', voice: '', autoFallback: false);
    expect(app.fishAudioSpeed, .9);
    app.setAsmrModeEnabled(true);
    expect(app.fishAudioSpeed, .9);
  });

  test(
    'legacy defaults migrate once and explicit later 1.0 stays saved',
    () async {
      SharedPreferences.setMockInitialValues({
        'fish_audio_speed': 1.0,
        'tts_provider': 'fishAudioMcp',
      });
      final preferences = await SharedPreferences.getInstance();
      await FishSpeechSpeedDefaults.migrate(preferences);
      expect(preferences.getDouble('fish_audio_speed'), .9);
      await preferences.setDouble('fish_audio_speed', 1);
      await FishSpeechSpeedDefaults.migrate(preferences);
      expect(preferences.getDouble('fish_audio_speed'), 1);
    },
  );

  test(
    'explicit non-default speed and other provider settings are preserved',
    () async {
      for (final settings in [
        {'tts_provider': 'fishAudio', 'fish_audio_speed': .8},
        {'tts_provider': 'fishAudioMcp', 'fish_audio_speed': 1.2},
        {'tts_provider': 'generic', 'fish_audio_speed': 1.0},
      ]) {
        SharedPreferences.setMockInitialValues(settings);
        final preferences = await SharedPreferences.getInstance();
        await FishSpeechSpeedDefaults.migrate(preferences);
        expect(
          preferences.getDouble('fish_audio_speed'),
          settings['fish_audio_speed'],
        );
      }
    },
  );

  test(
    'character banks adopt defaults without changing custom speeds or voices',
    () async {
      SharedPreferences.setMockInitialValues({
        'character_sessions_v1': jsonEncode({
          'ryza': {
            'preferences': {
              'ttsProvider': 'fishAudioMcp',
              'fishAudioSpeed': 1.0,
              'fishMcpVoice': 'personal-voice',
            },
          },
          'sophie': {
            'preferences': {'ttsProvider': 'fishAudio', 'fishAudioSpeed': .75},
          },
          'other': {
            'preferences': {'ttsProvider': 'generic', 'fishAudioSpeed': 1.0},
          },
        }),
      });
      final preferences = await SharedPreferences.getInstance();
      await FishSpeechSpeedDefaults.migrate(preferences);
      final bank =
          jsonDecode(preferences.getString('character_sessions_v1')!) as Map;
      expect(bank['ryza']['preferences']['fishAudioSpeed'], .9);
      expect(bank['ryza']['preferences']['fishMcpVoice'], 'personal-voice');
      expect(bank['sophie']['preferences']['fishAudioSpeed'], .75);
      expect(bank['other']['preferences']['fishAudioSpeed'], 1.0);
    },
  );

  test(
    'MCP speed can be saved and is shared with the API configuration',
    () async {
      final app = await AppController.load();
      addTearDown(app.dispose);
      app.configureFishMcp(
        model: 'drama-3',
        voice: '',
        speed: .85,
        autoFallback: false,
      );
      await Future<void>.delayed(Duration.zero);
      final restored = await AppController.load();
      addTearDown(restored.dispose);
      expect(restored.fishAudioSpeed, .85);
      expect(
        restored.exportData()['preferences'],
        containsPair('fishAudioSpeed', .85),
      );
      restored.configureFishMcp(
        model: 'drama-3',
        voice: '',
        speed: 1,
        autoFallback: false,
      );
      await Future<void>.delayed(Duration.zero);
      final restarted = await AppController.load();
      addTearDown(restarted.dispose);
      expect(restarted.fishAudioSpeed, 1);
    },
  );
}
