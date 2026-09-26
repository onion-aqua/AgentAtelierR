import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';
import 'package:ryza_chat_mvp/src/mimo_tts_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory supportDirectory;

  setUpAll(() async {
    supportDirectory = await Directory.systemTemp.createTemp(
      'character_switch_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return supportDirectory.path;
          }
          return null;
        });
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await supportDirectory.delete(recursive: true);
  });

  test(
    'characters keep separate conversation, memory, role and save slots',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      controller.configureAi(
        enabled: true,
        baseUrl: 'https://llm.example.test/v1',
        model: 'shared-model',
      );
      controller.addUserMessage('莱莎的旧对话');
      controller.setCharacterPersona('莱莎专用人物设定');
      controller.setWorldSetting('莱莎专用世界书');
      controller.configureLongTermMemory(enabled: true, summary: '莱莎的回忆');
      controller.configureFishAudio(
        enabled: true,
        model: 's2-pro',
        referenceId: 'ryza-voice',
      );
      await controller.saveToLocalSlot(0, name: '莱莎存档');

      await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
      expect(controller.activeCharacterId, CharacterRuntimeIds.sophie);
      expect(
        controller.messages.map((message) => message.text).join(),
        isNot(contains('莱莎的旧对话')),
      );
      expect(controller.memorySummary, isEmpty);
      expect(controller.editableCharacterPersona, contains('苏菲'));
      expect(controller.editableWorldSetting, contains('艾尔德'));
      expect(controller.localSaveSlots[0], isNull);
      expect(
        controller.fishAudioReferenceId,
        '6f17c6b98133437aafdcded111102d4c',
      );
      expect(controller.openAiBaseUrl, 'https://llm.example.test/v1');
      expect(controller.openAiModel, 'shared-model');
      expect(controller.aiEnabled, isTrue);
      expect(
        controller.characterCatalog.encountersFor(controller.selectedStageId),
        isEmpty,
      );

      controller.addUserMessage('苏菲的新对话');
      controller.setCharacterPersona('苏菲专用人物设定');
      controller.configureLongTermMemory(enabled: true, summary: '苏菲的回忆');
      await controller.saveToLocalSlot(0, name: '苏菲存档');
      expect(controller.localSaveSlots[0]!.name, '苏菲存档');

      await controller.setActiveCharacter(CharacterRuntimeIds.ryza);
      expect(
        controller.messages.map((message) => message.text).join(),
        contains('莱莎的旧对话'),
      );
      expect(controller.memorySummary, '莱莎的回忆');
      expect(controller.characterPersona, '莱莎专用人物设定');
      expect(controller.worldSetting, '莱莎专用世界书');
      expect(controller.fishAudioReferenceId, 'ryza-voice');
      expect(controller.localSaveSlots[0]!.name, '莱莎存档');
      expect(
        controller.messages.map((message) => message.text).join(),
        isNot(contains('苏菲的新对话')),
      );

      await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
      expect(
        controller.messages.map((message) => message.text).join(),
        contains('苏菲的新对话'),
      );
      expect(controller.memorySummary, '苏菲的回忆');
      expect(controller.characterPersona, '苏菲专用人物设定');
      expect(controller.localSaveSlots[0]!.name, '苏菲存档');
      expect(controller.openAiModel, 'shared-model');
    },
  );

  test(
    'Sophie stays selected after restart and never inherits Ryza prompt',
    () async {
      SharedPreferences.setMockInitialValues({});
      final first = await AppController.load();
      first.addUserMessage('只有莱莎知道的事');
      await first.setActiveCharacter(CharacterRuntimeIds.sophie);
      first.addUserMessage('只有苏菲知道的事');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      first.dispose();

      final restored = await AppController.load();
      addTearDown(restored.dispose);
      expect(restored.activeCharacterId, CharacterRuntimeIds.sophie);
      expect(
        restored.messages.map((message) => message.text).join(),
        contains('只有苏菲知道的事'),
      );
      expect(
        restored.messages.map((message) => message.text).join(),
        isNot(contains('只有莱莎知道的事')),
      );
      final prompt = restored.buildCharacterPrompt();
      expect(prompt, contains('苏菲：'));
      expect(prompt, isNot(contains('莱莎')));
      expect(restored.buildUserReplySuggestionPrompt(), contains('不要扮演苏菲'));
      expect(restored.buildUserReplySuggestionPrompt(), isNot(contains('莱莎')));
      expect(restored.worldTravelCatalog.destinations, isEmpty);
    },
  );

  test('reselecting Sophie cancels an in-flight Ryza switch', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    await controller.setActiveCharacter(CharacterRuntimeIds.sophie);

    final pendingRyza = controller.setActiveCharacter(CharacterRuntimeIds.ryza);
    await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
    await pendingRyza;

    expect(controller.activeCharacterId, CharacterRuntimeIds.sophie);
    expect(
      controller.characterCatalog.encountersFor(controller.selectedStageId),
      isEmpty,
    );
  });

  test('MiMo local references survive character switching and restart', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    controller.configureMimoTts(
      config: const MimoTtsConfig(
        referencePath: 'C:/private/ryza.wav',
        referenceName: 'ryza.wav',
      ),
      enabled: true,
      emotionIntensity: TtsEmotionIntensity.natural,
      cueDensity: TtsCueDensity.normal,
      previewText: '试音',
    );

    await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
    controller.configureMimoTts(
      config: const MimoTtsConfig(
        referencePath: 'C:/private/sophie.wav',
        referenceName: 'sophie.wav',
      ),
      enabled: true,
      emotionIntensity: TtsEmotionIntensity.natural,
      cueDensity: TtsCueDensity.normal,
      previewText: '试音',
    );
    final exportedTts =
        (controller.exportData()['preferences'] as Map<String, dynamic>)['mimoTts']
            as Map<String, dynamic>;
    expect(exportedTts.containsKey('referencePath'), isFalse);
    await controller.saveToLocalSlot(0);
    await controller.loadFromLocalSlot(0);
    expect(controller.mimoTts.referencePath, 'C:/private/sophie.wav');

    await controller.setActiveCharacter(CharacterRuntimeIds.ryza);
    expect(controller.mimoTts.referencePath, 'C:/private/ryza.wav');
    await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
    expect(controller.mimoTts.referencePath, 'C:/private/sophie.wav');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    controller.dispose();

    final restored = await AppController.load();
    addTearDown(restored.dispose);
    expect(restored.activeCharacterId, CharacterRuntimeIds.sophie);
    expect(restored.mimoTts.referencePath, 'C:/private/sophie.wav');
  });
}
