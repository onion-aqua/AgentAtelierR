import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/character_performance.dart';

void main() {
  test('Klaudia speech follows Ryza dialogue without voicing narration or translation', () {
    const response = '''旁白：两人走进工房。
莱莎：[happy]先看看新材料吧。
译文：Let's look at the new materials first.
角色[claudia]：[calm]我来帮你整理。
译文：I will help you organize them.
角色[莉拉]：我也在这里。
角色[klaudia]：清单已经写好了。''';

    final speech = assistantSpeechSegmentsForResponse(
      response,
      activeCharacterId: 'ryza',
      fallbackMood: CharacterMood.neutral,
    );

    expect(speech.map((segment) => segment.speaker), [
      ChatSpeaker.ryza,
      ChatSpeaker.character,
      ChatSpeaker.character,
    ]);
    expect(speech.map((segment) => segment.characterId), [
      isNull,
      'claudia',
      'claudia',
    ]);
    expect(speech.first.primaryPerformance, isNotNull);
    expect(
      speech.skip(1).every((segment) => segment.primaryPerformance == null),
      isTrue,
    );
    final audible = speech
        .map(
          (segment) => displayTextForAssistantSegment(
            ChatSegment(speaker: segment.speaker, text: segment.speechText),
          ),
        )
        .toList();
    expect(audible, ['先看看新材料吧。', '我来帮你整理。', '清单已经写好了。']);
  });

  test(
    'Klaudia aliases are recognized only in Ryza mode with visible speech',
    () {
      const response = '''角色[科洛蒂娅]：一起来吧。
角色[クラウディア]：準備できました。
角色[科洛蒂亚]：路程交给我。
角色[克劳迪娅]：我会跟上。
角色[klaudia]：[happy][face:smile][action:wave]
角色[claudia]：
旁白：风吹过窗边。''';

      final ryzaSpeech = assistantSpeechSegmentsForResponse(
        response,
        activeCharacterId: 'ryza',
        fallbackMood: CharacterMood.neutral,
      );
      expect(ryzaSpeech, hasLength(4));
      expect(
        ryzaSpeech.map(
          (segment) => displayTextForAssistantSegment(
            ChatSegment(speaker: segment.speaker, text: segment.speechText),
          ),
        ),
        ['一起来吧。', '準備できました。', '路程交给我。', '我会跟上。'],
      );

      final sophieSpeech = assistantSpeechSegmentsForResponse(
        '苏菲：配方完成了。\n$response',
        activeCharacterId: 'sophie',
        fallbackMood: CharacterMood.neutral,
      );
      expect(sophieSpeech, hasLength(1));
      expect(sophieSpeech.single.speaker, ChatSpeaker.ryza);
      expect(
        sophieSpeech.single.primaryPerformance?.primaryCharacterId,
        'sophie',
      );
    },
  );

  test('cue-only primary segment does not shift mixed speech performance', () {
    const response = '''莱莎：[face:happy][action:think]
莱莎：[face:neutral][action:wave]这边请。
角色[klaudia]：我也来帮忙。''';

    final primary = performanceSegmentsForAssistantResponse(
      response,
      fallbackMood: CharacterMood.neutral,
    );
    final speech = assistantSpeechSegmentsForResponse(
      response,
      activeCharacterId: 'ryza',
      fallbackMood: CharacterMood.neutral,
    );

    expect(primary, hasLength(1));
    expect(speech, hasLength(2));
    expect(speech.map((segment) => segment.speaker), [
      ChatSpeaker.ryza,
      ChatSpeaker.character,
    ]);
    expect(
      speech.first.primaryPerformance?.speechText,
      primary.single.speechText,
    );
    expect(speech.first.primaryPerformance?.action, CharacterAction.wave);
    expect(
      displayTextForAssistantSegment(
        ChatSegment(speaker: ChatSpeaker.ryza, text: speech.first.speechText),
      ),
      '这边请。',
    );
    expect(speech.last.primaryPerformance, isNull);
    expect(speech.last.speechText, '我也来帮忙。');
  });
}
