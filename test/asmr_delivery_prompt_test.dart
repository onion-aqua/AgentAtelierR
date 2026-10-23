import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/continuous_asmr_page.dart';
import 'package:ryza_chat_mvp/src/speech_planner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('chat and continuous ASMR request sustained whisper delivery', () async {
    final app = await AppController.load();
    addTearDown(app.dispose);
    app.fishTtsEnabled = true;
    app.ttsVoiceMode = TtsVoiceMode.asmr;
    app.ttsEmotionIntensity = TtsEmotionIntensity.off;

    for (final drama3 in [false, true]) {
      app.ttsProvider = drama3
          ? TtsProvider.fishAudioMcp
          : TtsProvider.fishAudio;
      app.fishMcpModel = drama3 ? 'drama-3' : '';
      for (final compact in [false, true]) {
        app.llmContextCompatibility = compact;
        final chat = app.buildCharacterPrompt();
        expect(chat, contains('保持整段清晰连贯的耳语'));
        expect(chat, contains('使用${drama3 ? "whisper" : "whispering"}'));
        expect(chat, contains('不在短句结束后切回普通发声'));
        expect(chat, isNot(contains('near-whisper')));
      }
      final continuous = buildContinuousAsmrSystemPrompt(app, targetChars: 400);
      expect(continuous, contains('保持整段清晰连贯的耳语'));
      expect(continuous, contains('[${drama3 ? "whisper" : "whispering"}]'));
      expect(continuous, contains('不在句末恢复普通发声'));
      expect(continuous, contains('不要使用喘息、吸气、呼气'));

      app.ttsCueDensity = TtsCueDensity.off;
      final noCues = buildContinuousAsmrSystemPrompt(app, targetChars: 400);
      expect(noCues, contains('不要句内气声、耳语或停顿标签'));
      expect(noCues, isNot(contains('[soft')));
      expect(noCues, isNot(contains('[whisper')));
      expect(
        app.buildCharacterPrompt(),
        contains('不添加句内轻声、耳语或停顿控制标签，主情绪仍遵守情感设置'),
      );
      app.ttsCueDensity = TtsCueDensity.normal;
    }
  });

  test('independent voice planning separates whisper delivery from emotion and cue switches', () async {
    for (final drama3 in [false, true]) {
      await SpeechPlanner().plan(
        source: '莱莎：今日はゆっくり休もう。',
        previousEmotion: 'sad',
        intensity: TtsEmotionIntensity.off,
        density: TtsCueDensity.normal,
        asmr: true,
        drama3: drama3,
        complete: (messages) async {
          final prompt = messages.first['content']!;
          expect(prompt, contains('保持整段清晰连贯的耳语'));
          expect(prompt, contains('使用${drama3 ? "whisper" : "whispering"}'));
          expect(prompt, contains('不在短句结束后切回普通发声'));
          expect(prompt, contains('情感关闭不等于关闭耳语发声'));
          expect(prompt, contains('标签密度关闭时不输出任何发声标签'));
          expect(jsonDecode(messages.last['content']!)['intensity'], 'off');
          return '{"segments":[{"id":0,"emotion":"sad","cues":[]}]}';
        },
      );
    }
  });
}
