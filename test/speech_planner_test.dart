import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/character_state.dart';
import 'package:ryza_chat_mvp/src/speech_planner.dart';

void main() {
  test('saved sadness survives speech planning fallback and delivery cues', () {
    final fallback = fishEmotionForContinuity(
      CharacterState(emotion: 'sad'),
      'relaxed',
      CharacterMood.neutral,
    );
    expect(fallback, 'sad');
    expect(
      ensureFishEmotionCue(
        '[singing]我还在难过。',
        CharacterMood.neutral,
        fallbackEmotion: fallback,
      ),
      '[sad] [singing]我还在难过。',
    );
    expect(
      ensureFishEmotionCue(
        '[happy]我好多了。',
        CharacterMood.neutral,
        fallbackEmotion: fallback,
      ),
      '[happy]我好多了。',
    );
    expect(
      fishEmotionForContinuity(
        CharacterState(emotion: 'neutral'),
        'sad',
        CharacterMood.neutral,
      ),
      'sad',
    );
  });
  test('inline emotion survives while unsupported cues are isolated', () async {
    final result = await SpeechPlanner().plan(
      source: '莱莎：别怕，继续吧。',
      previousEmotion: 'hopeful',
      intensity: TtsEmotionIntensity.natural,
      density: TtsCueDensity.normal,
      asmr: false,
      complete: (_) async => jsonEncode({
        'segments': [
          {
            'id': 0,
            'emotion': 'hopeful',
            'cues': [
              {'offset': 3, 'tag': 'encouraging'},
              {'offset': 0, 'tag': 'action:wave'},
              {'offset': 'oops', 'tag': 'pause'},
              null,
            ],
          },
        ],
      }),
    );
    expect(result.lines[0], '[hopeful]别怕，[encouraging]继续吧。');
  });
  const source = '旁白：她笑了。\n莱莎：你好😀。\n旁白：她挥挥手。\n角色[lent]：早上好。';
  Future<SpeechPlan> plan(
    Object output, {
    TtsCueDensity density = TtsCueDensity.normal,
    TtsEmotionIntensity intensity = TtsEmotionIntensity.natural,
  }) => SpeechPlanner().plan(
    source: source,
    previousEmotion: 'sad',
    intensity: intensity,
    density: density,
    asmr: true,
    complete: (_) async => jsonEncode(output),
  );
  Map<String, Object> row({
    int id = 1,
    int offset = 2,
    String tag = 'breathy',
  }) => {
    'id': id,
    'emotion': 'happy',
    'cues': [
      {'offset': offset, 'tag': tag},
    ],
  };

  test(
    'annotates original speech only and preserves performance and narration',
    () async {
      final result = await plan({
        'segments': [row()],
      });
      final applied = result.apply(
        source.replaceFirst('莱莎：', '莱莎：[face:happy][action:wave]'),
      );
      expect(
        applied,
        contains('莱莎：[face:happy][action:wave][happy]你好[breathy]😀。'),
      );
      expect(
        displayTextForAssistantResponse(applied),
        displayTextForAssistantResponse(source),
      );
      expect(applied, contains('旁白：她挥挥手。\n角色[lent]：早上好。'));
      expect(result.lastEmotion, 'happy');
      expect(
        () => result.apply(source.replaceFirst('你好', '再见')),
        throwsFormatException,
      );
    },
  );
  test('rejects missing duplicate and unknown IDs', () async {
    for (final rows in [
      [],
      [row(), row()],
      [row(id: 0)],
    ]) {
      await expectLater(plan({'segments': rows}), throwsFormatException);
    }
  });
  test(
    'invalid cue positions preserve the valid turn and Unicode text',
    () async {
      final result = await plan({
        'segments': [
          {
            'id': 1,
            'emotion': 'happy',
            'cues': [
              {'offset': 999, 'tag': 'pause'},
              {'offset': -1, 'tag': 'pause'},
              {'offset': 3, 'tag': 'breathy'},
              {'offset': 5, 'tag': 'short pause'},
            ],
          },
        ],
      });
      expect(result.lines[1], '[happy]你好[breathy]😀。');
      expect(
        displayTextForAssistantResponse(result.apply(source)),
        displayTextForAssistantResponse(source),
      );
    },
  );
  test(
    'off controls remove planned emotion and inline tags independently',
    () async {
      final result = await plan(
        {
          'segments': [row()],
        },
        density: TtsCueDensity.off,
        intensity: TtsEmotionIntensity.off,
      );
      expect(result.apply(source), source);
      final emotionOnly = await plan({
        'segments': [row()],
      }, density: TtsCueDensity.off);
      expect(emotionOnly.lines[1], '[happy]你好😀。');
    },
  );
  test('request contains voice context only and no request for narrator-only output', () async {
    var called = false;
    await SpeechPlanner().plan(
      source: source,
      previousEmotion: 'sad',
      intensity: TtsEmotionIntensity.vivid,
      density: TtsCueDensity.sparse,
      asmr: true,
      complete: (messages) async {
        called = true;
        final payload = jsonDecode(messages.last['content']!);
        expect(payload['previous_emotion'], 'sad');
        expect(payload['asmr'], isTrue);
        expect(payload['lines'], hasLength(1));
        expect(payload['lines'][0]['text'], '你好😀。');
        return jsonEncode({
          'segments': [row()],
        });
      },
    );
    expect(called, isTrue);
    await SpeechPlanner().plan(
      source: '旁白：风吹过。',
      previousEmotion: 'sad',
      intensity: TtsEmotionIntensity.natural,
      density: TtsCueDensity.normal,
      asmr: false,
      complete: (_) async => throw StateError('must not request'),
    );
  });

  test('speech planner receives the settled emotion and its reason', () async {
    final plan = await SpeechPlanner().plan(
      source: '莱莎：我明白了。',
      previousEmotion: 'sad',
      intensity: TtsEmotionIntensity.natural,
      density: TtsCueDensity.normal,
      asmr: false,
      sharedContext: const {
        'character_state': {'emotion': 'sad', 'reason': '刚得知坏消息'},
        'current_face': 'sad',
      },
      complete: (messages) async {
        final input = jsonDecode(messages.last['content']!);
        expect(input['previous_emotion'], 'sad');
        expect(input['shared_context']['character_state']['reason'], '刚得知坏消息');
        expect(input['shared_context']['current_face'], 'sad');
        return '{"segments":[{"id":0,"emotion":"sad","cues":[]}]}';
      },
    );
    expect(plan.apply('莱莎：我明白了。'), '莱莎：[sad]我明白了。');
  });
}
