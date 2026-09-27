import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('normalizes dense Japanese commas for display and TTS only', () {
    const response =
        '莱莎：うん、行こ。昨日、の、分、だけ、じゃ、足りない、から、今日は、草、も、探す。'
        '……あ、点心、の、こと、まだ、考え、て、る、でしょ。顔、に、書い、て、ある。';
    const normalized =
        '莱莎：うん、行こ。昨日の分だけじゃ足りないから今日は草も探す。'
        '……あ、点心のことまだ考えてるでしょ。顔に書いてある。';

    expect(normalizeDenseJapanesePunctuation(response), normalized);
    expect(displayTextForAssistantResponse(response), normalized);
    expect(
      ttsTextForAssistantResponse(
        response,
        fallbackMood: CharacterMood.neutral,
      ),
      '[relaxed] うん、行こ。昨日の分だけじゃ足りないから今日は草も探す。'
      '……あ、点心のことまだ考えてるでしょ。顔に書いてある。',
    );
  });

  test('raw conversation output keeps the model text unchanged', () {
    const response = '莱莎：昨日、の、分、だけ、じゃ、足りない、から、今日は、草、も、探す。';
    expect(
      conversationTextForAssistantResponse(response, showRawOutput: true),
      response,
    );
  });

  test('natural long Japanese clauses keep their commas', () {
    const response =
        '莱莎：これは自然な長い節です、こちらも自然な節です、'
        'さらに別の節です、説明を続ける節です、最後の節です。';
    expect(normalizeDenseJapanesePunctuation(response), response);
  });

  test('short Japanese item lists keep their commas', () {
    const response = '莱莎：火、水、風、土、光、闇を順番に集めよう。';
    expect(normalizeDenseJapanesePunctuation(response), response);
  });

  test('natural interjection pauses survive dense comma repair', () {
    const response =
        '莱莎：うん、行こ。今日は、まず、苔むした、岩、の、裏、あたり、見て、'
        'それ、から、森、の、入口、の、方、に、回ろ。……あ、点心、の、こと、'
        'まだ、考え、て、る、でしょ。';
    final normalized = normalizeDenseJapanesePunctuation(response);
    expect(normalized, contains('うん、行こ。'));
    expect(normalized, contains('……あ、点心'));
    expect(normalized, isNot(contains('岩、の、裏')));
  });

  test(
    'model context uses repaired text without changing saved history',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      controller.configureLanguages(
        interface: AppLanguage.chinese,
        narrator: AppLanguage.japanese,
        characterReply: AppLanguage.japanese,
        translation: TranslationLanguage.none,
      );
      const response =
          '莱莎：昨日、の、分、だけ、じゃ、足りない、から、今日は、草、も、探す。'
          '点心、の、こと、まだ、考え、て、る、でしょ。';
      controller.addAssistantMessage(response);

      expect(controller.messages.last.text, response);
      expect(controller.contextMessagesForModel().last.text, isNot(response));
      expect(
        controller.contextMessagesForModel().last.text,
        isNot(contains('の、分')),
      );
      expect(
        controller.buildCharacterPrompt(independentPerformance: true),
        contains('不要在每个词、助词、汉字或短语之间机械添加'),
      );
    },
  );
}
