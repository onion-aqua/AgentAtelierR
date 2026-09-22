import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/independent_performance_tools.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  final capabilities = CharacterPerformancePromptContext(
    appearanceId: 'test',
    posture: 'sitting_normal',
    revision: 1,
    resourcesReady: true,
    playableActionDescriptions: const {},
    playableMotionGroupDescriptions: {
      for (var i = 0; i < 100; i++) 'grp_fg_$i': '动作$i',
    },
    availablePostures: const {'sitting_normal': '自然坐姿', 'sitting_agura': '盘腿'},
  );

  test('independent requests preserve full catalogue and narration order', () async {
    var calls = 0;
    final output = await IndependentPerformanceTools().plan(
      userInput: '挥手',
      source: '旁白：她走近。\n莱莎：你好。\n译文：Hello.\n旁白：她笑了。',
      capabilities: capabilities,
      currentFace: 'neutral',
      recentActions: [],
      complete: (messages) async {
        calls++;
        final input = jsonDecode(messages.last['content']!);
        if (input.containsKey('candidates')) {
          if (input['catalogue_complete'] == false) {
            expect(input['candidates'].length, 17);
            return '{"request_catalog":true}';
          }
          expect(input['candidates'].length, 101);
          expect(input['candidates']['grp_fg_99'], '动作99');
          expect(input.containsKey('expression_intensities'), isFalse);
          return '{"segments":[{"id":1,"match":"exact","action":"grp_fg_99"}]}';
        }
        expect(input.containsKey('candidates'), isFalse);
        return '{"segments":[{"id":1,"face":"happy"}]}';
      },
    );
    expect(calls, 3);
    expect(
      output,
      '旁白：她走近。\n莱莎：[face:happy][action:grp_fg_99]你好。\n译文：Hello.\n旁白：她笑了。',
    );
  });

  for (final failExpression in [true, false]) {
    test('failure isolation expression=$failExpression', () async {
      var proposals = 0;
      final output = await IndependentPerformanceTools().plan(
        userInput: '你好',
        source: '莱莎：你好。',
        capabilities: capabilities,
        currentFace: 'neutral',
        recentActions: [],
        onStateProposal: (_) => proposals++,
        complete: (messages) async {
          final input = jsonDecode(messages.last['content']!);
          if (input.containsKey('candidates')) {
            return failExpression
                ? '{"segments":[{"id":0,"match":"exact","action":"grp_fg_1"}]}'
                : '{"segments":[{"id":0,"match":"exact","action":"unavailable"}]}';
          }
          return jsonEncode({
            'segments': [
              {'id': 0, 'face': failExpression ? 'invalid' : 'happy'},
            ],
            'state_delta': {'mood': 1},
          });
        },
      );
      expect(proposals, 1);
      expect(
        output,
        failExpression
            ? '莱莎：[action:grp_fg_1]你好。'
            : '莱莎：[face:happy][action:none]你好。',
      );
    });
  }

  test('posture switch suppresses actions from previous snapshot', () async {
    final result = await ActionPlannerTool().plan(
      userInput: '盘腿坐',
      source: '莱莎：好呀。\n莱莎：这样很舒服。',
      ids: [0, 1],
      capabilities: capabilities,
      recentActions: [],
      complete: (_) async => '{"segments":[{"id":0,"match":"exact","action":"grp_fg_1","posture":"sitting_agura"},{"id":1,"match":"exact","action":"grp_fg_2"}]}',
    );
    expect(result[0], '[action:none][posture:sitting_agura]');
    expect(result[1], '[action:none]');
  });
}
