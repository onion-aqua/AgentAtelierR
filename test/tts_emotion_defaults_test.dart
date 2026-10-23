import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'new installations use the lowest emotion intensity for every provider',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);

      expect(controller.ttsEmotionIntensity, TtsEmotionIntensity.off);
      expect(controller.ttsEmotionIntensity.fishTemperature, 0.55);
      for (final provider in TtsProvider.values) {
        controller.setTtsProvider(provider);
        expect(controller.ttsEmotionIntensity, TtsEmotionIntensity.off);
      }
      expect(
        (controller.exportData()['preferences'] as Map)['ttsEmotionIntensity'],
        'off',
      );
    },
  );

  test(
    'unrecognized saved emotion intensity falls back to the minimum',
    () async {
      SharedPreferences.setMockInitialValues({
        'tts_emotion_intensity': 'retired-intensity',
      });
      final controller = await AppController.load();
      addTearDown(controller.dispose);

      expect(controller.ttsEmotionIntensity, TtsEmotionIntensity.off);
    },
  );

  test('all valid saved emotion choices survive application loading', () async {
    for (final intensity in TtsEmotionIntensity.values) {
      SharedPreferences.setMockInitialValues({
        'tts_emotion_intensity': intensity.name,
      });
      final controller = await AppController.load();
      expect(controller.ttsEmotionIntensity, intensity);
      controller.dispose();
    }
  });

  test('backups without a valid emotion choice use the minimum', () async {
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    final backup = controller.exportData();
    final preferences = backup['preferences'] as Map<String, dynamic>;

    for (final savedValue in [null, 'retired-intensity']) {
      controller.setTtsEmotionIntensity(TtsEmotionIntensity.vivid);
      if (savedValue == null) {
        preferences.remove('ttsEmotionIntensity');
      } else {
        preferences['ttsEmotionIntensity'] = savedValue;
      }
      await controller.importData(backup);
      expect(controller.ttsEmotionIntensity, TtsEmotionIntensity.off);
    }
  });

  test(
    'backups preserve every explicitly selected emotion intensity',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      final backup = controller.exportData();
      final preferences = backup['preferences'] as Map<String, dynamic>;

      for (final intensity in TtsEmotionIntensity.values) {
        preferences['ttsEmotionIntensity'] = intensity.name;
        await controller.importData(backup);
        expect(controller.ttsEmotionIntensity, intensity);
      }
    },
  );
}
