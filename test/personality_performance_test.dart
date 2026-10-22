import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/independent_performance_tools.dart';
import 'package:ryza_chat_mvp/src/personality/personality_performance_preferences.dart';
import 'package:ryza_chat_mvp/src/speech_planner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const preferences = {
    'face': '克制地表现害羞',
    'action': '倾向自然的小幅手势',
    'voice': '语气柔和，速度稍缓',
  };
  final capabilities = CharacterPerformancePromptContext(
    appearanceId: 'test',
    posture: 'sitting_normal',
    revision: 1,
    resourcesReady: true,
    playableActionDescriptions: const {},
    playableMotionGroupDescriptions: const {'grp_fg_1': '挥手'},
    availablePostures: const {'sitting_normal': '自然坐姿'},
  );

  test(
    'filtering is advisory, bounded, and preserves contexts when disabled',
    () {
      const original = <String, dynamic>{'emotion': 'sad'};
      expect(
        identical(personalityPlannerContext(original, 'face'), original),
        isTrue,
      );
      expect(personalityPlannerInstruction(original, 'voice'), isEmpty);
      final raw = <String, dynamic>{
        ...original,
        'personality_preferences': {'face': true, 'voice': 'v' * 400},
      };
      expect(personalityPlannerContext(raw, 'face'), original);
      expect(personalityPlannerInstruction(raw, 'face'), isEmpty);
      expect(
        (personalityPlannerContext(raw, 'voice')['personality_preferences']
            as Map)['voice'],
        hasLength(240),
      );
      expect(personalityPlannerContext(raw, 'unsupported'), original);
      expect(raw['personality_preferences'], containsPair('face', true));
    },
  );

  Future<List<Map<String, String>>> expressionRequest(
    Map<String, dynamic> context,
  ) async {
    late List<Map<String, String>> captured;
    await ExpressionPlannerTool().plan(
      userInput: '谢谢你',
      source: '莱莎：不用客气。',
      ids: [0],
      currentFace: 'neutral',
      currentIntensity: 'normal',
      intensities: const {},
      sharedContext: context,
      complete: (messages) async {
        captured = messages;
        return '{"segments":[{"id":0,"face":"shy","intensity":"normal"}]}';
      },
    );
    return captured;
  }

  Future<List<Map<String, String>>> voiceRequest(
    Map<String, dynamic> context,
  ) async {
    late List<Map<String, String>> captured;
    await SpeechPlanner().plan(
      source: '莱莎：不用客气。',
      previousEmotion: 'sad',
      intensity: TtsEmotionIntensity.natural,
      density: TtsCueDensity.normal,
      asmr: false,
      sharedContext: context,
      complete: (messages) async {
        captured = messages;
        return '{"segments":[{"id":0,"emotion":"sad","cues":[]}]}';
      },
    );
    return captured;
  }

  Future<List<Map<String, String>>> actionRequest(
    Map<String, dynamic> context,
  ) async {
    late List<Map<String, String>> captured;
    await ActionPlannerTool().plan(
      userInput: '挥挥手',
      source: '莱莎：你好。',
      ids: [0],
      capabilities: capabilities,
      recentActions: [],
      sharedContext: context,
      complete: (messages) async {
        captured = messages;
        return '{"segments":[{"id":0,"action":"grp_fg_1","match":"exact"}]}';
      },
    );
    return captured;
  }

  Future<List<Map<String, String>>> singingRequest(
    Map<String, dynamic> context,
  ) async {
    late List<Map<String, String>> captured;
    await SingingPlannerTool().plan(
      userInput: '唱首歌',
      source: '莱莎：你好。',
      sharedContext: context,
      complete: (messages) async {
        captured = messages;
        return '{"segments":[{"id":0,"tags":["singing","soft singing"]}]}';
      },
    );
    return captured;
  }

  for (final channel in ['face', 'action', 'voice']) {
    test(
      '$channel planner receives only its enabled personality dimension',
      () async {
        final request = switch (channel) {
          'face' => expressionRequest,
          'action' => actionRequest,
          _ => voiceRequest,
        };
        final enabled = await request({
          'emotion': 'sad',
          'personality_preferences': preferences,
        });
        final payload = jsonDecode(enabled.last['content']!) as Map;
        final context = payload['shared_context'] as Map;
        expect(context['personality_preferences'], {
          channel: preferences[channel],
        });
        expect(enabled.first['content'], contains('低优先级演出倾向'));
        expect(enabled.first['content'], contains('合法候选与用户边界'));
        expect(context['emotion'], 'sad');

        final baseline = await request({'emotion': 'sad'});
        final disabled = await request({
          'emotion': 'sad',
          'personality_preferences': {
            for (final entry in preferences.entries)
              if (entry.key != channel) entry.key: entry.value,
          },
        });
        expect(disabled, baseline);
        expect(
          baseline.first['content'],
          isNot(contains('personality_preferences')),
        );
      },
    );
  }

  test(
    'personality does not authorize unavailable face or action tags',
    () async {
      final result = await IndependentPerformanceTools().plan(
        userInput: '挥挥手',
        source: '莱莎：你好。',
        capabilities: capabilities,
        currentFace: 'neutral',
        recentActions: [],
        sharedContext: {'personality_preferences': preferences},
        complete: (messages) async {
          final payload = jsonDecode(messages.last['content']!) as Map;
          return payload.containsKey('candidates')
              ? '{"segments":[{"id":0,"action":"personality_unavailable_action","match":"exact"}]}'
              : '{"segments":[{"id":0,"face":"personality_unavailable_face"}]}';
        },
      );
      expect(result, '莱莎：[action:none]你好。');
      expect(result, isNot(contains('personality_unavailable')));
    },
  );

  test(
    'voice preference cannot change dialogue or introduce unsupported cues',
    () async {
      final result = await SpeechPlanner().plan(
        source: '莱莎：不用客气。',
        previousEmotion: 'sad',
        intensity: TtsEmotionIntensity.natural,
        density: TtsCueDensity.normal,
        asmr: false,
        sharedContext: {'personality_preferences': preferences},
        complete: (_) async => '{"segments":[{"id":0,"emotion":"sad","cues":[{"offset":0,"tag":"action:invented"}],"text":"changed"}]}',
      );
      expect(result.lines[0], '[sad]不用客气。');
    },
  );

  test(
    'singing follows voice only and ignores other disabled dimensions',
    () async {
      final request = await singingRequest({
        'emotion': 'sad',
        'personality_preferences': preferences,
      });
      final data = jsonDecode(request.last['content']!) as Map;
      expect((data['shared_context'] as Map)['personality_preferences'], {
        'voice': preferences['voice'],
      });
      final baseline = await singingRequest({'emotion': 'sad'});
      final withoutVoice = await singingRequest({
        'emotion': 'sad',
        'personality_preferences': {
          'face': preferences['face'],
          'action': preferences['action'],
        },
      });
      expect(withoutVoice, baseline);
    },
  );
}
