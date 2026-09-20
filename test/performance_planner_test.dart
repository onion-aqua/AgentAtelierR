import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/performance_planner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'voice planning toggle persists and restores traditional voice prompt',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      expect(controller.independentSpeechPerformance, isTrue);
      controller.fishTtsEnabled = true;
      expect(
        controller.buildCharacterPrompt(independentPerformance: true),
        contains('不输出任何语音情绪'),
      );
      controller.setIndependentSpeechPerformance(false);
      expect(
        controller.buildCharacterPrompt(independentPerformance: true),
        contains('传统语音演出模式'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final restored = await AppController.load();
      expect(restored.independentSpeechPerformance, isFalse);
      expect(
        (restored.exportData()['preferences']
            as Map)['independentSpeechPerformance'],
        isFalse,
      );
      controller.dispose();
      restored.dispose();
    },
  );
  final capabilities = CharacterPerformancePromptContext(
    appearanceId: 'test',
    posture: 'sitting_normal',
    revision: 1,
    resourcesReady: true,
    playableActionDescriptions: const {},
    playableMotionGroupDescriptions: const {'grp_b_03': '双手叉腰'},
    availablePostures: const {'sitting_normal': '自然坐姿', 'sitting_agura': '盘腿'},
  );
  test('cross-legged plan emits persistent posture and suppresses old-pose gesture', () async {
    final result = await PerformancePlanner().plan(
      userInput: '盘腿坐',
      source: '莱莎：好呀',
      capabilities: capabilities,
      currentFace: 'happy',
      recentActions: [],
      complete: (messages) async {
        expect(messages.last['content'], contains('available_postures'));
        return '{"segments":[{"id":0,"face":"happy","action":"a1","posture":"sitting_agura"}]}';
      },
    );
    expect(result, contains('[action:none][posture:sitting_agura]'));
  });
  test('unsupported posture is rejected', () async {
    await expectLater(
      PerformancePlanner().plan(
        userInput: '站起来',
        source: '莱莎：好呀',
        capabilities: capabilities,
        currentFace: 'happy',
        recentActions: [],
        complete: (_) async => '{"segments":[{"id":0,"face":"happy","action":"none","posture":"standing"}]}',
      ),
      throwsFormatException,
    );
  });
  test(
    'planner binds available action and preserves original dialogue',
    () async {
      final result = await PerformancePlanner().plan(
        userInput: '叉腰看看',
        source: '旁白：她叉着腰。\n莱莎：怎么样？',
        capabilities: capabilities,
        currentFace: 'happy',
        recentActions: [],
        complete: (messages) async {
          expect(messages.last['content'], contains('双手叉腰'));
          expect(messages.last['content'], isNot(contains('grp_b_03')));
          return '{"segments":[{"id":1,"face":"tease","action":"a1"}]}';
        },
      );
      expect(result, contains('莱莎：[face:tease][action:grp_b_03]怎么样？'));
    },
  );
  test('invalid resource never becomes an executable action', () async {
    await expectLater(
      PerformancePlanner().plan(
        userInput: '你好',
        source: '莱莎：你好',
        capabilities: capabilities,
        currentFace: 'happy',
        recentActions: [],
        complete: (_) async =>
            '{"segments":[{"id":0,"face":"happy","action":"grp_unknown"}]}',
      ),
      throwsFormatException,
    );
  });
  test('demo main prompt omits the action catalog', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    final prompt = controller.buildCharacterPrompt(
      independentPerformance: true,
      performanceContext: capabilities,
    );
    expect(prompt, isNot(contains('motionGroups')));
    expect(prompt, isNot(contains('grp_b_03')));
    expect(prompt, contains('表演由独立模块处理'));
    controller.dispose();
  });
}
