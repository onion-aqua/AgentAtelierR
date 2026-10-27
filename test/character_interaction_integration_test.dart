import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/body_sensitivity.dart';
import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';
import 'package:ryza_chat_mvp/src/character_state.dart';
import 'package:ryza_chat_mvp/src/continuous_asmr_page.dart';
import 'package:ryza_chat_mvp/src/independent_performance_tools.dart';
import 'package:ryza_chat_mvp/src/personality/personality_presets.dart';
import 'package:ryza_chat_mvp/src/speech_planner.dart';
import 'package:ryza_chat_mvp/src/story_clock.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _heading = '【状态驱动的互动表现】';

Map<String, dynamic> _facts(String prompt) {
  final start = prompt.indexOf(_heading);
  expect(start, greaterThanOrEqualTo(0));
  return jsonDecode(prompt.substring(start).split('\n')[1])
      as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory support;
  setUpAll(() async {
    support = await Directory.systemTemp.createTemp('interaction-prompts-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => support.path);
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    await support.delete(recursive: true);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<AppController> load() async {
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    return controller;
  }

  void unsettled(AppController app, {int mood = -400, int head = 93}) {
    app.characterState = CharacterState(
      values: {'mood': mood, 'energy': 14, 'closeness': 85, 'curiosity': 80},
      emotion: 'sad',
      reason: '刚经历了令人失落的事情。',
    );
    app.storyClock = StoryClock(totalMinutes: 23 * 60 + 40, satiety: 9);
    app.setStoryClockEnabled(true);
    app.setBodySensitivity(BodySensitivityPart.head, head);
  }

  test('all main-character prompt paths use one current state and preserve persona', () async {
    final app = await load();
    for (final character in CharacterRuntimeIds.all) {
      await app.setActiveCharacter(character);
      unsettled(app);
      final profile = PersonalityPresets.create(
        'mischievous_teaser',
        character,
      );
      await app.savePersonalityConfiguration(
        app.personalityConfiguration.copyWith(
          enabled: true,
          activeProfileId: profile.profileId,
          profiles: [profile],
        ),
      );
      for (final compact in [false, true]) {
        app.llmContextCompatibility = compact;
        for (final independent in [false, true]) {
          final prompt = app.buildCharacterPrompt(
            currentInput: '今天想安静地聊一会儿。',
            independentPerformance: independent,
          );
          expect(_heading.allMatches(prompt), hasLength(1));
          expect(_facts(prompt), app.interactionStateForDialogue());
          expect(
            _facts(prompt)['character'],
            app.activeCharacterProfile.names.chinese,
          );
          expect(prompt, contains('心情严重低落'));
          expect(prompt, contains('更短的句子、更慢的节奏'));
          expect(prompt, contains('自然表达饥饿'));
          expect(prompt, contains('头部敏感度较高'));
          expect(
            prompt,
            contains(app.interpretPersonality('今天想安静地聊一会儿。').prompt),
          );
          expect(prompt, contains('人格设定与用户选择的人格预设决定基础口吻'));
          expect(
            (_facts(prompt)['sensitivity'] as Map).containsKey('intimate'),
            isFalse,
          );
          expect(_facts(prompt)['locked_parts'], contains('intimate'));
        }
      }
    }
  });

  test(
    'manual updates and explicit unlock change only future prompt facts',
    () async {
      final app = await load();
      final before = _facts(app.buildCharacterPrompt());
      app.setBodySensitivity(BodySensitivityPart.head, 8);
      app.setBodySensitivity(BodySensitivityPart.intimate, 99);
      var next = _facts(app.buildCharacterPrompt());
      expect((next['sensitivity'] as Map)['head'], 8);
      expect((before['sensitivity'] as Map)['head'], 50);
      expect((next['sensitivity'] as Map).containsKey('intimate'), isFalse);
      expect(app.unlockBodySensitivity(BodySensitivityPart.intimate), isTrue);
      app.setBodySensitivity(BodySensitivityPart.intimate, 79);
      next = _facts(app.buildCharacterPrompt());
      expect((next['sensitivity'] as Map)['intimate'], 79);
      expect(next['locked_parts'], isNot(contains('intimate')));
      app.characterState = CharacterState(
        values: {'mood': 80, 'energy': 90, 'closeness': 10, 'curiosity': 20},
      );
      final updated = app.buildCharacterPrompt();
      expect(updated, contains('心情较好'));
      expect(updated, contains('精力充足'));
      expect(updated, contains('称呼和用词保留适当距离'));
      expect(updated, isNot(contains('心情严重低落')));
    },
  );

  test('ASMR shares current state while language, whisper and translation stay authoritative', () async {
    final app = await load();
    unsettled(app);
    app.narratorLanguage = AppLanguage.chinese;
    app.characterReplyLanguage = AppLanguage.japanese;
    app.fishMcpModel = 'drama-3';
    app.ttsProvider = TtsProvider.fishAudioMcp;
    app.ttsEmotionIntensity = TtsEmotionIntensity.off;
    app.ttsCueDensity = TtsCueDensity.normal;
    for (final independent in [false, true]) {
      final policy = AsmrLanguagePolicy(
        replyLanguage: AppLanguage.japanese,
        translationLanguage: TranslationLanguage.english,
        independentTranslation: independent,
      );
      final prompt = buildContinuousAsmrSystemPrompt(
        app,
        targetChars: 600,
        languagePolicy: policy,
      );
      expect(_facts(prompt), app.interactionStateForDialogue());
      expect(_heading.allMatches(prompt), hasLength(1));
      expect(prompt, contains('心情严重低落'));
      expect(prompt, contains('不要情绪标签'));
      expect(prompt, contains('保持整段清晰连贯的耳语'));
      expect(prompt, contains('[whisper]'));
      expect(prompt, endsWith(policy.promptInstruction));
      expect(prompt, contains('全部朗读原文使用 Japanese'));
      expect(prompt, contains('画面原文与朗读内容完全相同'));
      expect(
        prompt,
        contains(independent ? '不输出译文、JSON' : '每条 translation 使用 English'),
      );
    }
  });

  test(
    'NPC private messages do not inherit the primary character physiology',
    () async {
      final app = await load();
      unsettled(app);
      app.unlockBodySensitivity(BodySensitivityPart.intimate);
      app.setBodySensitivity(BodySensitivityPart.intimate, 97);
      final contact = app.npcChatContacts.first;
      final npc = app.buildNpcMessagePrompt(contact.id, currentInput: '晚上好');
      expect(npc, isNot(contains(_heading)));
      expect(npc, isNot(contains('"sensitivity"')));
      expect(npc, isNot(contains('"intimate"')));
      expect(npc, isNot(contains('心情严重低落')));
      expect(npc, contains('不要把主角的经历或其他 NPC 私信当成自己的回忆'));
    },
  );

  test('save loads and restart rebuild state preferences without stale locked values', () async {
    final app = await load();
    unsettled(app);
    await app.saveToLocalSlot(0, name: 'sad');
    final original = app.interactionStateForDialogue();
    app.unlockBodySensitivity(BodySensitivityPart.intimate);
    app.setBodySensitivity(BodySensitivityPart.intimate, 88);
    app.setBodySensitivity(BodySensitivityPart.head, 8);
    app.characterState = CharacterState(
      values: {'mood': 90, 'energy': 95, 'closeness': 95, 'curiosity': 10},
    );
    await app.saveToLocalSlot(1, name: 'happy');
    await app.loadFromLocalSlot(0);
    expect(_facts(app.buildCharacterPrompt()), original);
    expect(app.buildCharacterPrompt(), contains('心情严重低落'));
    expect(
      (_facts(app.buildCharacterPrompt())['sensitivity'] as Map).containsKey(
        'intimate',
      ),
      isFalse,
    );
    final restarted = await load();
    expect(_facts(restarted.buildCharacterPrompt()), original);
    await restarted.loadFromLocalSlot(1);
    final second = _facts(restarted.buildCharacterPrompt());
    expect((second['state'] as Map)['mood'], 90);
    expect((second['sensitivity'] as Map)['intimate'], 88);
    expect(restarted.buildCharacterPrompt(), contains('心情较好'));
  });

  test(
    'turn rollback changes current delivery while direct touch changes remain',
    () async {
      final app = await load();
      app.setStoryClockEnabled(true);
      final before = app.interactionStateForDialogue();
      final turn = app.addUserMessage('我们先安静地休息一下吧');
      app.settleCharacterState(turn, {
        'state_delta': {'mood': -5, 'energy': -5},
        'emotion': 'sad',
        'reason': '这轮对话中的状态变化。',
      }, app.dataRevision);
      app.settleStoryTime(turn, {
        'time_advance': {'kind': 'conversation', 'minutes': 6},
      }, app.dataRevision);
      expect((_facts(app.buildCharacterPrompt())['state'] as Map)['mood'], -5);
      app.recordBodySensitivityTouch('head');
      app.undoLastUserTurn();
      final after = _facts(app.buildCharacterPrompt());
      expect(after['state'], before['state']);
      expect(after['story'], before['story']);
      expect((after['sensitivity'] as Map)['head'], 51);
      expect((after['sensitivity'] as Map).containsKey('intimate'), isFalse);
    },
  );

  test('voice and expression planners receive filtered facts and never rewrite dialogue', () async {
    final app = await load();
    unsettled(app);
    final snapshot = app.interactionStateForDialogue(posture: 'sitting_normal');
    final shared = <String, dynamic>{
      'character_interaction': snapshot,
      'character_state': app.characterState.toJson(),
      'current_face': 'sad',
      'previous_voice_emotion': 'sad',
    };
    const source = '莱莎：少しだけ、静かに話してくれる？';
    final before = jsonEncode(app.bodySensitivity.toJson());
    final speech = await SpeechPlanner().plan(
      source: source,
      previousEmotion: 'sad',
      intensity: TtsEmotionIntensity.off,
      density: TtsCueDensity.normal,
      asmr: true,
      drama3: true,
      sharedContext: shared,
      complete: (messages) async {
        final system = messages.first['content']!;
        final input = jsonDecode(messages.last['content']!) as Map;
        expect(input['shared_context']['character_interaction'], snapshot);
        expect(
          (input['shared_context']['character_interaction']['sensitivity']
                  as Map)
              .containsKey('intimate'),
          isFalse,
        );
        expect(system, contains('不新增身体互动或改写用词'));
        expect(system, contains('锁定部位不猜测数值'));
        expect(system, contains('情感关闭不等于关闭耳语发声'));
        return '{"segments":[{"id":0,"emotion":"sad","cues":[],"text":"ignored replacement","sensitivity":{"intimate":100},"unlock":"intimate"}]}';
      },
    );
    expect(speech.apply(source), source);
    Map<String, dynamic>? proposed;
    final face = await ExpressionPlannerTool().plan(
      userInput: '安静地聊聊',
      source: source,
      ids: [0],
      currentFace: 'sad',
      currentIntensity: 'normal',
      intensities: const {
        'sad': ['normal'],
      },
      sharedContext: shared,
      characterState: app.characterState.toJson(),
      onStateProposal: (data) => proposed = data,
      complete: (messages) async {
        final input = jsonDecode(messages.last['content']!) as Map;
        expect(input['shared_context']['character_interaction'], snapshot);
        expect(messages.first['content'], contains('不修改或解锁任何敏感度'));
        expect(messages.first['content'], contains('不改写台词'));
        return '{"segments":[{"id":0,"face":"sad","intensity":"normal","text":"ignored"}],"sensitivity":{"intimate":100},"unlock":"intimate"}';
      },
    );
    expect(face, {0: '[face:sad]'});
    expect(proposed, isNull);
    expect(jsonEncode(app.bodySensitivity.toJson()), before);
    expect(
      app.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
      isFalse,
    );
    expect(
      snapshot,
      app.interactionStateForDialogue(posture: 'sitting_normal'),
    );
  });
}
