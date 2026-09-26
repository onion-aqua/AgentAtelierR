import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/character_performance.dart';

void main() {
  test('late performance cues align with the already synthesized speech', () {
    const speech = '莱莎：[happy]你来啦！\n旁白：她走近。\n莱莎：[relaxed]先坐下吧。';
    const planned =
        '莱莎：[face:happy][action:wave]你来啦！\n旁白：她走近。\n莱莎：[face:neutral][action:none]先坐下吧。';
    final aligned = performanceSegmentsMatchingSpeech(
      speech,
      planned,
      fallbackMood: CharacterMood.neutral,
    );
    expect(aligned, hasLength(2));
    expect(aligned!.first.action, CharacterAction.wave);
    expect(
      performanceSegmentsMatchingSpeech(
        speech,
        planned.replaceFirst('先坐下吧', '现在走吧'),
        fallbackMood: CharacterMood.neutral,
      ),
      isNull,
    );
  });

  test('user narration preserves both sides including empty speech', () {
    final parts = parseUserComposerParts('旁白：走近\n发言：你好\n旁白：挥手\n微笑');
    expect(parts.narration, '走近');
    expect(parts.speech, '你好');
    expect(parts.bottomNarration, '挥手\n微笑');
    final bottomOnly = parseUserComposerParts('发言：\n旁白：离开');
    expect(bottomOnly.narration, isEmpty);
    expect(bottomOnly.speech, isEmpty);
    expect(bottomOnly.bottomNarration, '离开');
  });
  test('user narration is separate and retains multiline continuation', () {
    final parts = parseUserComposerParts('旁白：摸摸头\n轻轻笑了。\n发言：见到你很开心\n真的。');
    expect(parts.narration, '摸摸头\n轻轻笑了。');
    expect(parts.speech, '见到你很开心\n真的。');
    expect(parseUserComposerParts('你好').speech, '你好');
    expect(parseUserComposerParts('旁白：挥手').speech, isEmpty);
  });
  test('tavern-style wrapped asides stay outside character dialogue', () {
    const response = '''<|assistant|>
*莱莎抬起头，耳朵轻轻动了一下。*
莱莎：[happy][face:happy][action:acknowledge] 你来啦！
*她把手里的素材放回桌面。*
莱莎：我们继续研究吧。''';

    final segments = parseAssistantSegments(response);
    expect(segments.map((segment) => segment.speaker), [
      ChatSpeaker.narrator,
      ChatSpeaker.ryza,
      ChatSpeaker.narrator,
      ChatSpeaker.ryza,
    ]);
    expect(segments[0].text, '莱莎抬起头，耳朵轻轻动了一下。');
    expect(
      groupAssistantSegmentsForDisplay(response)
          .map((run) => run.first.speaker),
      [
        ChatSpeaker.narrator,
        ChatSpeaker.ryza,
        ChatSpeaker.narrator,
        ChatSpeaker.ryza,
      ],
    );
  });

  test(
    'role prefixes accept localized character ids and transport markers',
    () {
      const response = '''### Assistant:
角色[莉拉]：别急，先观察材料的反应。
译文：Wait and observe the material first.''';

      final segments = parseAssistantSegments(response);
      expect(segments, hasLength(2));
      expect(segments.first.speaker, ChatSpeaker.character);
      expect(segments.first.characterId, '莉拉');
      expect(segments.last.speaker, ChatSpeaker.translation);
    },
  );

  test('inline speaker prefixes are split into separate display runs', () {
    final runs = groupAssistantSegmentsForDisplay(
      '旁白：风吹过工房。 莱莎：准备好了吗？ 旁白：她握紧了拳头。',
    );
    expect(runs.map((run) => run.first.speaker), [
      ChatSpeaker.narrator,
      ChatSpeaker.ryza,
      ChatSpeaker.narrator,
    ]);
  });

  test('Sophie dialogue stays on the primary speech channel', () {
    const response =
        '旁白：书页翻动。 苏菲：[happy][face:happy][action:none]找到配方了！\n'
        'ソフィー：再看看材料。';
    final segments = parseAssistantSegments(response);
    expect(segments.map((segment) => segment.speaker), [
      ChatSpeaker.narrator,
      ChatSpeaker.ryza,
      ChatSpeaker.ryza,
    ]);
    expect(segments[1].primaryCharacterId, 'sophie');
    expect(segments[2].primaryCharacterId, 'sophie');
    expect(
      displayTextForAssistantResponse(response),
      '旁白：书页翻动。\n苏菲：找到配方了！\n苏菲：再看看材料。',
    );
    expect(
      ttsTextForAssistantResponse(
        response,
        fallbackMood: CharacterMood.neutral,
      ),
      contains('找到配方了！'),
    );
    expect(
      performanceSegmentsForAssistantResponse(
        response,
        fallbackMood: CharacterMood.neutral,
      ),
      hasLength(2),
    );
  });

  test('performance plans cannot be reused across different protagonists', () {
    expect(
      performanceSegmentsMatchingSpeech(
        '苏菲：你好。',
        '莱莎：[face:happy][action:none]你好。',
        fallbackMood: CharacterMood.neutral,
      ),
      isNull,
    );
  });
}
