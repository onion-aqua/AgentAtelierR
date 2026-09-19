import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'reasoning switch persists, sends chosen effort and respects provider',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      controller.configureAi(
        enabled: true,
        baseUrl: 'https://example.test/v1',
        model: 'gpt-5.1',
      );
      expect(controller.activeReasoningEffort, isNull);
      controller.setModelThinkingEnabled(true);
      controller.setModelReasoningEffort(ReasoningEffort.high);
      expect(controller.activeReasoningEffort, 'high');
      await Future<void>.delayed(Duration.zero);
      final restored = await AppController.load();
      addTearDown(restored.dispose);
      expect(restored.activeReasoningEffort, 'high');
      restored.setModelThinkingEnabled(false);
      expect(restored.activeReasoningEffort, isNull);
      expect(restored.openAiReasoningEffort, ReasoningEffort.high);
      controller.configureAi(
        enabled: true,
        baseUrl: 'https://example.test/v1',
        model: 'qwen3',
      );
      controller.setModelThinkingEnabled(true);
      expect(controller.activeReasoningEffort, isNull);
      expect(controller.activeThinkingEnabled, isTrue);
      expect(controller.openAiAdvancedEnabled, isTrue);
      controller.configureAi(
        enabled: true,
        baseUrl: 'https://example.test/v1',
        model: 'custom-unknown',
      );
      expect(controller.activeThinkingEnabled, isNull);
      expect(controller.activeReasoningEffort, isNull);
      // An unknown model must not erase the user's saved preference.
      expect(controller.openAiAdvancedEnabled, isTrue);
    },
  );
}
