import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'background voice defaults on and persists the disabled preference',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      expect(controller.backgroundVoicePlayback, isTrue);
      controller.setBackgroundVoicePlayback(false);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final restored = await AppController.load();
      expect(restored.backgroundVoicePlayback, isFalse);
      expect(
        (restored.exportData()['preferences']
            as Map)['backgroundVoicePlayback'],
        isFalse,
      );
      controller.dispose();
      restored.dispose();
    },
  );
}
