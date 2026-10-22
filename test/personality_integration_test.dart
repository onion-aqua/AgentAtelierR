import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';
import 'package:ryza_chat_mvp/src/personality/personality_profile.dart';
import 'package:ryza_chat_mvp/src/personality/personality_presets.dart';
import 'package:ryza_chat_mvp/src/continuous_asmr_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory supportDirectory;
  setUpAll(() async {
    supportDirectory = await Directory.systemTemp.createTemp(
      'personality_integration_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathChannel,
          (_) async => supportDirectory.path,
        );
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    await supportDirectory.delete(recursive: true);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppController> load() async {
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    return controller;
  }

  PersonalityConfiguration enabledConfiguration(AppController controller) {
    final profile = PersonalityPresets.create(
      'tsundere',
      controller.activeCharacterId,
    );
    return controller.personalityConfiguration.copyWith(
      enabled: true,
      profiles: [profile],
      activeProfileId: profile.profileId,
    );
  }

  test(
    'old installation stays disabled and off restores original prompt exactly',
    () async {
      final controller = await load();
      final original = controller.buildCharacterPrompt(currentInput: '你做得真好');
      final state = jsonEncode(controller.characterState.toJson());
      expect(controller.personalityEnabled, isFalse);
      expect(controller.interpretPersonality('夸奖').prompt, isEmpty);
      final next = enabledConfiguration(controller);
      await controller.savePersonalityConfiguration(next);
      final extended = controller.buildCharacterPrompt(currentInput: '你做得真好');
      expect(extended, contains(original.split('\n\n').first));
      expect(
        extended,
        contains(controller.interpretPersonality('你做得真好').prompt),
      );
      expect(extended.length, greaterThan(original.length));
      expect(jsonEncode(controller.characterState.toJson()), state);
      await controller.savePersonalityConfiguration(
        next.copyWith(enabled: false),
      );
      expect(controller.buildCharacterPrompt(currentInput: '你做得真好'), original);
    },
  );

  test(
    'character bank survives restart and game save loading cannot replace it',
    () async {
      final controller = await load();
      await controller.saveToLocalSlot(0);
      final next = enabledConfiguration(controller);
      await controller.savePersonalityConfiguration(next);
      await controller.loadFromLocalSlot(0);
      expect(controller.personalityConfiguration.toJson(), next.toJson());
      final restarted = await load();
      expect(restarted.personalityConfiguration.toJson(), next.toJson());
      await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
      expect(controller.personalityEnabled, isFalse);
      expect(
        controller.personalityConfiguration.characterId,
        CharacterRuntimeIds.sophie,
      );
      await controller.setActiveCharacter(CharacterRuntimeIds.ryza);
      expect(controller.personalityConfiguration.toJson(), next.toJson());
    },
  );

  test(
    'existing saved teaser style reaches the main prompt after restart',
    () async {
      final controller = await load();
      final p = PersonalityPresets.create(
        'mischievous_teaser',
        controller.activeCharacterId,
      );
      await controller.savePersonalityConfiguration(
        controller.personalityConfiguration.copyWith(
          enabled: true,
          profiles: [p],
          activeProfileId: p.profileId,
        ),
      );
      final restarted = await load();
      final prompt = restarted.buildCharacterPrompt(currentInput: '今天有什么安排？');
      expect(prompt, contains(p.metadata['style']!));
      expect(prompt, contains('调侃鲜明且主动'));
      expect(prompt, contains('原有角色身份'));
      await restarted.savePersonalityConfiguration(
        restarted.personalityConfiguration.copyWith(enabled: false),
      );
      final off = restarted.buildCharacterPrompt(currentInput: '今天有什么安排？');
      expect(off, isNot(contains(p.metadata['style']!)));
      expect(off, isNot(contains('【可选人格倾向】')));
    },
  );

  test(
    'custom roleplay instruction survives restart and disappears when disabled',
    () async {
      final controller = await load();
      final custom = PersonalityProfile(
        profileId: 'custom-quiet',
        name: '沉静的观察者',
        characterId: controller.activeCharacterId,
        traits: {'teasing': 10, 'curiosity': 90},
        metadata: {'style': '先描述具体观察，再用简短句子回应。'},
      );
      await controller.savePersonalityConfiguration(
        controller.personalityConfiguration.copyWith(
          enabled: true,
          activeProfileId: custom.profileId,
          profiles: [custom],
        ),
      );
      final restarted = await load();
      final prompt = restarted.buildCharacterPrompt(currentInput: '今天有什么安排？');
      expect(prompt, contains('选择自定义人格「沉静的观察者」'));
      expect(prompt, contains(custom.metadata['style']!));
      expect(prompt, contains('这是生效的扮演要求'));
      await restarted.savePersonalityConfiguration(
        restarted.personalityConfiguration.copyWith(enabled: false),
      );
      final off = restarted.buildCharacterPrompt(currentInput: '今天有什么安排？');
      expect(off, isNot(contains('当前扮演指令')));
      expect(off, isNot(contains(custom.metadata['style']!)));
    },
  );

  test(
    'full backup restores personality, malformed future data changes nothing',
    () async {
      final controller = await load();
      await controller.savePersonalityConfiguration(
        enabledConfiguration(controller),
      );
      final backup = jsonDecode(
        jsonEncode(controller.exportData()),
      ) as Map<String, dynamic>;
      await controller.savePersonalityConfiguration(
        controller.personalityConfiguration.copyWith(enabled: false),
      );
      await controller.importData(backup);
      expect(controller.personalityEnabled, isTrue);
      final before = jsonEncode(controller.personalityConfiguration.toJson());
      final messages = controller.messages.map((m) => m.id).toList();
      final invalid = Map<String, dynamic>.from(backup)
        ..['personalityConfiguration'] = {
          ...controller.personalityConfiguration.toJson(),
          'schemaVersion': 999,
        };
      await expectLater(controller.importData(invalid), throwsFormatException);
      expect(jsonEncode(controller.personalityConfiguration.toJson()), before);
      expect(controller.messages.map((m) => m.id), messages);
    },
  );

  test(
    'corrupt persisted data is preserved while returning disabled defaults',
    () async {
      const raw = '{broken-personality';
      final key = AppController.personalityPreferenceKey(
        CharacterRuntimeIds.ryza,
      );
      SharedPreferences.setMockInitialValues({key: raw});
      final controller = await load();
      expect(controller.personalityEnabled, isFalse);
      expect(controller.personalityLoadWarning, isNotNull);
      controller.settleCharacterState('test', {
        'state_delta': {'mood': 1},
        'reason': '测试',
      }, controller.dataRevision);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(key), raw);
      await controller.savePersonalityConfiguration(
        controller.personalityConfiguration,
      );
      expect(controller.personalityLoadWarning, isNull);
      expect(prefs.getString(key), isNot(raw));
    },
  );

  test('dialogue and performance switches work independently, ASMR shares dialogue preference', () async {
    final controller = await load();
    final base = controller.buildCharacterPrompt(currentInput: '帮帮我');
    var configuration = enabledConfiguration(controller);
    final profile = configuration.activeProfile.copyWith(
      expression: {
        'dialogue': false,
        'face': false,
        'action': false,
        'voice': true,
      },
    );
    configuration = configuration.copyWith(profiles: [profile]);
    await controller.savePersonalityConfiguration(configuration);
    expect(controller.buildCharacterPrompt(currentInput: '帮帮我'), base);
    expect(controller.interpretPersonality('帮帮我').preferences.keys, ['voice']);
    final asmrBase = buildContinuousAsmrSystemPrompt(
      controller,
      targetChars: 500,
    );
    expect(asmrBase, contains('【人格语音倾向】'));
    expect(asmrBase, isNot(contains('【可选人格倾向】')));
    controller.independentSpeechPerformance = false;
    controller.fishTtsEnabled = true;
    expect(
      controller.buildCharacterPrompt(currentInput: '帮帮我'),
      contains('【人格语音倾向】'),
    );
    await controller.savePersonalityConfiguration(
      configuration.copyWith(
        profiles: [
          profile.copyWith(
            expression: {
              'dialogue': false,
              'face': false,
              'action': false,
              'voice': false,
            },
          ),
        ],
      ),
    );
    expect(
      buildContinuousAsmrSystemPrompt(controller, targetChars: 500),
      isNot(contains('【人格语音倾向】')),
    );
    expect(
      controller.buildCharacterPrompt(currentInput: '帮帮我'),
      isNot(contains('【人格语音倾向】')),
    );
    configuration = configuration.copyWith(
      profiles: [
        profile.copyWith(
          expression: {
            'dialogue': true,
            'face': true,
            'action': true,
            'voice': true,
          },
        ),
      ],
    );
    await controller.savePersonalityConfiguration(configuration);
    expect(
      buildContinuousAsmrSystemPrompt(controller, targetChars: 500),
      isNot(asmrBase),
    );
  });
}
