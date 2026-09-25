import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/independent_performance_tools.dart';

void main() {
  test(
    'singing request detection includes short verses but excludes negation',
    () {
      expect(isExplicitSingingRequest('请唱一段给我听'), isTrue);
      expect(isExplicitSingingRequest('能不能唱几句'), isTrue);
      expect(isExplicitSingingRequest('请不要唱歌'), isFalse);
      expect(isExplicitSingingRequest('这首歌是谁唱的？'), isFalse);
    },
  );

  test('singing plan keeps tags out of the rendered dialogue text', () async {
    final plan = await SingingPlannerTool().plan(
      userInput: '请唱一首轻柔的歌给我听',
      source: '莱莎：[face:happy][action:none]啦啦啦♪',
      complete: (messages) async =>
          '{"segments":[{"id":0,"tags":["singing","soft singing"]}]}',
    );

    final performance = plan.apply('莱莎：[face:happy][action:none]啦啦啦♪');
    expect(performance, contains('[singing][soft singing]'));
    expect(performance, contains('啦啦啦♪'));
  });

  test(
    'invalid singing tags are ignored rather than sent to Fish Audio',
    () async {
      final plan = await SingingPlannerTool().plan(
        userInput: '请唱歌',
        source: '莱莎：试试看',
        complete: (messages) async =>
            '{"segments":[{"id":0,"tags":["singing","unknown-provider-tag"]}]}',
      );

      expect(plan.tagsBySegment[0], ['singing']);
    },
  );

  test('empty model tags still sing every line and sentence', () async {
    final plan = await SingingPlannerTool().plan(
      userInput: '请唱一首歌给我听',
      source: '莱莎：第一句。第二句。\n旁白：她停了一下。\n莱莎：第三句。',
      sharedContext: const {
        'character_state': {'emotion': 'sad'},
      },
      complete: (messages) async {
        final payload = jsonDecode(messages.last['content']!);
        expect(payload['shared_context']['character_state']['emotion'], 'sad');
        return '{"segments":[{"id":0,"tags":[]},{"id":2,"tags":[]}]}';
      },
    );
    final tagged = plan.apply('莱莎：[face:sad]第一句。第二句。\n旁白：她停了一下。\n莱莎：第三句。');
    final spoken = performanceSegmentsForAssistantResponse(
      tagged,
      fallbackMood: CharacterMood.neutral,
      fallbackEmotion: 'sad',
    );
    expect(spoken, hasLength(2));
    expect(spoken.first.speechText, contains('[singing]第一句。[singing]第二句。'));
    expect(spoken.last.speechText, contains('[singing]第三句。'));
    final fishText = applyFishEmotionIntensityPerSentence(
      spoken.first.speechText,
      TtsEmotionIntensity.natural,
    );
    expect(RegExp(r'\[singing\]').allMatches(fishText), hasLength(2));
    expect(tagged, contains('旁白：她停了一下。'));
  });

  test('planner failure fallback keeps the full reply in singing mode', () {
    final plan = SingingPlan.forAllLines('莱莎：一句。\n莱莎：再一句。');
    expect(plan.tagsBySegment.keys, {0, 1});
    expect(plan.apply('莱莎：一句。\n莱莎：再一句。'), '莱莎：[singing]一句。\n莱莎：[singing]再一句。');
  });

  test(
    'conflicting humming and spoken-style tags cannot override singing',
    () async {
      final plan = await SingingPlannerTool().plan(
        userInput: '请唱一段',
        source: '莱莎：第一句。第二句。',
        complete: (_) async => '{"segments":[{"id":0,"tags":["humming","soft humming","whispering","gentle singing"]}]}',
      );
      expect(plan.tagsBySegment[0], ['singing', 'gentle singing']);
      expect(
        plan.apply('莱莎：第一句。第二句。'),
        '莱莎：[singing][gentle singing]第一句。[singing]第二句。',
      );
    },
  );
}
