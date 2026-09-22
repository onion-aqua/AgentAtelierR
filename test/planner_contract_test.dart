import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/independent_performance_tools.dart';
import 'package:ryza_chat_mvp/src/speech_planner.dart';

void main() {
  test('unsupported exact request expands once and reports mismatch without substitute', () async {
    final capabilities = CharacterPerformancePromptContext(
      appearanceId: 'test',
      posture: 'sitting_normal',
      revision: 1,
      resourcesReady: true,
      playableActionDescriptions: {},
      playableMotionGroupDescriptions: {
        for (var i = 0; i < 30; i++) 'grp_test_$i': '资源$i',
      },
    );
    var calls = 0;
    final reasons = <String>[];
    final result = await ActionPlannerTool().plan(
      userInput: '伸懒腰',
      source: '莱莎：好呀',
      ids: [0],
      capabilities: capabilities,
      recentActions: [],
      onMismatch: reasons.add,
      complete: (messages) async {
        calls++;
        return '{"segments":[{"id":0,"action":"grp_test_0","match":"unsupported","reason":"候选只有转肩，无法举臂伸展"}]}';
      },
    );
    expect(calls, 2);
    expect(result[0], '[action:none]');
    expect(reasons, hasLength(1));
  });
  test('speech receives shared context and enforces sparse cue budget', () async {
    final plan = await SpeechPlanner().plan(
      source: '莱莎：你好。再见。',
      previousEmotion: 'sad',
      intensity: TtsEmotionIntensity.natural,
      density: TtsCueDensity.sparse,
      asmr: false,
      sharedContext: {'emotion': 'sad', 'current_reply': '旁白：她低下头。'},
      complete: (messages) async {
        expect(
          jsonDecode(messages.last['content']!)['shared_context']['emotion'],
          'sad',
        );
        return '{"segments":[{"id":0,"emotion":"sad","cues":[{"offset":0,"tag":"short pause"},{"offset":3,"tag":"emphasis"}]}]}';
      },
    );
    expect(plan.lines[0], '[sad][short pause]你好。再见。');
  });
  test('more than forty protected memories survive normalization', () {
    final memory = jsonEncode({
      'entries': [
        for (var i = 0; i < 45; i++)
          {
            'date': '2026-09-22',
            'category': 'promise',
            'importance': 5,
            'summary': '重要约定$i',
          },
      ],
    });
    final normalized = AppController.normalizeLongTermMemoryCandidate(
      memory,
      previousMemory: '',
      now: DateTime(2026, 9, 22),
    );
    expect(jsonDecode(normalized!)['entries'], hasLength(45));
  });
}
