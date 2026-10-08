import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/independent_performance_tools.dart';

CharacterPerformancePromptContext _capabilities(Map<String, String> groups) =>
    CharacterPerformancePromptContext(
      appearanceId: 'test',
      posture: 'sitting_normal',
      revision: 1,
      resourcesReady: true,
      playableActionDescriptions: const {},
      playableMotionGroupDescriptions: groups,
      availablePostures: const {'sitting_normal': '自然坐姿'},
    );

void main() {
  test('an incomplete candidate summary cannot execute a claimed exact action', () async {
    final result = await ActionPlannerTool().plan(
      userInput: '请挥手。',
      source: '莱莎：我试试看。',
      ids: [0],
      capabilities: _capabilities({
        'grp_fg_wave': '挥手问候；${List.filled(300, '限制说明').join()}；不能双手挥手。',
      }),
      recentActions: const [],
      complete: (messages) async {
        final input = jsonDecode(messages.last['content']!) as Map;
        expect(input['incomplete_candidates'], contains('grp_fg_wave'));
        return '{"segments":[{"id":0,"action":"grp_fg_wave","match":"exact"}]}';
      },
    );
    expect(result, {0: '[action:none]'});
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  test(
    'action context retains settled state without duplicate dialogue',
    () async {
      final result = await ActionPlannerTool().plan(
        userInput: '你可以继续说。',
        source: '莱莎：嗯，我还记得刚才的事情。',
        ids: [0],
        capabilities: _capabilities(const {'grp_fg_wait': '安静等待'}),
        recentActions: ['grp_fg_wait'],
        sharedContext: {
          'emotion': 'sad',
          'current_face': 'sad',
          'current_face_intensity': 'weak',
          'current_posture': 'sitting_normal',
          'previous_voice_emotion': 'sad',
          'user_intent': 'redundant-user-intent',
          'current_reply': 'redundant-current-reply',
          'previous_dialogue': [
            {'text': 'redundant-history'},
          ],
          'character_state': {
            'emotion': 'sad',
            'reason': '刚才回忆起失落的经历。',
            'values': {'mood': -25, 'energy': 40},
            'bands': {'mood': 'low'},
            'history': 'irrelevant-state-history',
          },
          'recent_actions': ['a', 'b', 'c', 'd', 'e', 'f'],
        },
        complete: (messages) async {
          final input = jsonDecode(messages.last['content']!) as Map;
          final shared = input['shared_context'] as Map;
          expect(shared['emotion'], 'sad');
          expect(shared['current_face'], 'sad');
          expect(shared['current_face_intensity'], 'weak');
          expect(shared['previous_voice_emotion'], 'sad');
          expect(shared['character_state']['values']['mood'], -25);
          expect(shared['character_state']['values']['energy'], 40);
          expect(shared['character_state']['history'], isNull);
          expect(shared.containsKey('user_intent'), isFalse);
          expect(shared.containsKey('current_reply'), isFalse);
          expect(shared.containsKey('previous_dialogue'), isFalse);
          expect(shared.containsKey('recent_actions'), isFalse);
          expect(input['recent_actions'], ['grp_fg_wait']);
          return '{"segments":[{"id":0,"action":"none","match":"none"}]}';
        },
      );

      expect(result, {0: '[action:none]'});
    },
  );

  test('translation does not enter motion retrieval and original line ids survive', () async {
    await ActionPlannerTool().plan(
      userInput: '继续。',
      source: '旁白：她安静等着。\n莱莎：嗯。\n译文：abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz\n莱莎：我在听。',
      ids: [1, 3],
      capabilities: _capabilities({
        for (var i = 0; i < 20; i++) 'grp_fg_wait_$i': '她安静等着，我在听。',
        'grp_fg_translation_only':
            'abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz',
      }),
      recentActions: const [],
      complete: (messages) async {
        final input = jsonDecode(messages.last['content']!) as Map;
        expect(input['line_ids'], [1, 3]);
        final reply = input['reply'] as String;
        expect(reply, isNot(contains('译文')));
        expect(reply, isNot(contains('abcdefghijklmnopqrstuvwxyz')));
        expect(
          (input['candidates'] as Map).containsKey('grp_fg_translation_only'),
          isFalse,
        );
        expect(reply, contains('[id:1]'));
        expect(reply, contains('[id:3]'));
        return '{"segments":[{"id":1,"action":"none","match":"none"},{"id":3,"action":"none","match":"none"}]}';
      },
    );
  });

  test(
    'long dialogue and resource descriptions keep the action payload bounded',
    () async {
      final longDescription =
          '挥手问候；${List.filled(1000, '资源标签与非必要详细说明').join()}';
      final longReply = [
        for (var i = 0; i < 10; i++) '莱莎：${List.filled(1200, '话').join()}',
      ].join('\n');
      var calls = 0;
      await ActionPlannerTool().plan(
        userInput: '挥手${List.filled(2000, '字').join()}',
        source: longReply,
        ids: List.generate(10, (index) => index),
        capabilities: _capabilities({
          for (var i = 0; i < 100; i++) 'grp_fg_$i': longDescription,
        }),
        recentActions: const [],
        sharedContext: {
          'current_reply': List.filled(20000, '冗').join(),
          'character_state': {
            'emotion': 'sad',
            'reason': List.filled(500, '因').join(),
            'values': {'mood': -10, 'energy': 50},
          },
        },
        complete: (messages) async {
          calls++;
          final raw = messages.last['content']!;
          final input = jsonDecode(raw) as Map;
          expect((input['user'] as String).length, lessThanOrEqualTo(800));
          expect((input['reply'] as String).length, lessThanOrEqualTo(2400));
          expect(
            (input['shared_context']['character_state']['reason'] as String)
                .length,
            lessThanOrEqualTo(120),
          );
          final candidates = input['candidates'] as Map;
          expect(candidates.length, lessThanOrEqualTo(calls == 1 ? 17 : 49));
          expect(
            candidates.values.whereType<String>().every(
              (value) => value.length <= 220,
            ),
            isTrue,
          );
          // A compressed second request remains small even with very long
          // catalogue descriptions. This is a payload budget, not token math.
          expect(raw.length, lessThan(18000));
          if (calls == 1) return '{"request_catalog":true}';
          return jsonEncode({
            'segments': [
              for (var id = 0; id < 10; id++)
                {'id': id, 'action': 'none', 'match': 'none'},
            ],
          });
        },
      );
      expect(calls, 2);
    },
  );

  test(
    'search refinement replaces the first window instead of accumulating it',
    () async {
      var calls = 0;
      await ActionPlannerTool().plan(
        userInput: '挥手',
        source: '莱莎：让我试试看。',
        ids: [0],
        capabilities: _capabilities({
          for (var i = 0; i < 50; i++) 'grp_fg_wave_$i': '挥手问候$i',
          for (var i = 0; i < 100; i++) 'grp_fg_stretch_$i': '手臂伸展$i',
        }),
        recentActions: const [],
        complete: (messages) async {
          calls++;
          final input = jsonDecode(messages.last['content']!) as Map;
          final candidates = input['candidates'] as Map;
          expect(candidates.length, lessThanOrEqualTo(calls == 1 ? 17 : 49));
          if (calls == 1) {
            return '{"request_catalog":true,"search_query":"手臂伸展"}';
          }
          expect(
            candidates.keys.any(
              (key) => key.toString().startsWith('grp_fg_stretch_'),
            ),
            isTrue,
          );
          return '{"segments":[{"id":0,"action":"none","match":"none"}]}';
        },
      );
      expect(calls, 2);
    },
  );

  test('truncated evidence cannot start a guessed action or posture change', () async {
    final result = await ActionPlannerTool().plan(
      userInput: '挥手${List.filled(1000, '字').join()}不要挥手。',
      source: '莱莎：我先听你完整的要求。',
      ids: [0],
      capabilities: CharacterPerformancePromptContext(
        appearanceId: 'test',
        posture: 'sitting_normal',
        revision: 1,
        resourcesReady: true,
        playableActionDescriptions: const {},
        playableMotionGroupDescriptions: const {'grp_fg_wave': '挥手问候'},
        availablePostures: const {
          'sitting_normal': '自然坐姿',
          'sitting_agura': '盘腿',
        },
      ),
      recentActions: const [],
      complete: (messages) async {
        final input = jsonDecode(messages.last['content']!) as Map;
        expect(input['evidence_truncated'], isTrue);
        return '{"segments":[{"id":0,"action":"grp_fg_wave","match":"exact","posture":"sitting_agura"}]}';
      },
    );

    expect(result, {0: '[action:none]'});
  });

  test(
    'a repeated catalogue request ends in a safe no-action fallback',
    () async {
      var calls = 0;
      final output = await IndependentPerformanceTools().plan(
        userInput: '请做没有对应资源的动作。',
        source: '莱莎：我先想想。',
        capabilities: _capabilities({
          for (var i = 0; i < 100; i++) 'grp_fg_$i': '安静等待$i',
        }),
        currentFace: 'sad',
        recentActions: const [],
        complete: (messages) async {
          final input = jsonDecode(messages.last['content']!) as Map;
          if (!input.containsKey('candidates')) {
            return '{"segments":[{"id":0,"face":"sad"}]}';
          }
          calls++;
          return '{"request_catalog":true}';
        },
      );

      expect(calls, 2);
      expect(output, '莱莎：[face:sad][action:none]我先想想。');
    },
  );
}
