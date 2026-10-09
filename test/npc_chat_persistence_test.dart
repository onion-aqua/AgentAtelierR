import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';
import 'package:ryza_chat_mvp/src/npc_chat_models.dart';
import 'package:ryza_chat_mvp/src/npc_contact_requests.dart';
import 'package:shared_preferences/shared_preferences.dart';

NpcChatState conversation(String npcId, String topic) => NpcChatState(
  threads: {
    npcId: NpcChatThread(
      npcId: npcId,
      messages: [
        NpcChatMessage(
          id: '${npcId}_u',
          role: NpcChatRole.user,
          text: topic,
          createdAt: DateTime.utc(2026, 10, 5),
        ),
        NpcChatMessage(
          id: '${npcId}_a',
          role: NpcChatRole.assistant,
          text: '我记得你说的：$topic',
          createdAt: DateTime.utc(2026, 10, 5, 1),
        ),
      ],
    ),
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('npc_save_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? directory.path
              : null,
        );
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'message language follows live settings or persists its explicit override',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      expect(controller.npcReplyLanguageOverride, isNull);
      expect(controller.npcTranslationLanguageOverride, isNull);
      controller.configureLanguages(
        interface: AppLanguage.chinese,
        narrator: AppLanguage.chinese,
        characterReply: AppLanguage.japanese,
        translation: TranslationLanguage.chinese,
      );
      expect(controller.npcReplyLanguage, AppLanguage.japanese);
      expect(controller.npcTranslationLanguage, TranslationLanguage.chinese);
      expect(
        controller.buildNpcMessagePrompt('claudia'),
        contains('用 Japanese'),
      );
      controller.configureNpcMessageLanguages(
        reply: AppLanguage.english,
        translation: TranslationLanguage.none,
      );
      controller.configureLanguages(
        interface: AppLanguage.chinese,
        narrator: AppLanguage.chinese,
        characterReply: AppLanguage.chinese,
        translation: TranslationLanguage.japanese,
      );
      expect(controller.npcReplyLanguage, AppLanguage.english);
      expect(controller.npcTranslationLanguage, TranslationLanguage.none);
      expect(
        controller.buildNpcMessagePrompt('claudia'),
        contains('用 English'),
      );
      await controller.saveToLocalSlot(0);
      final restored = await AppController.load();
      addTearDown(restored.dispose);
      expect(restored.npcReplyLanguageOverride, AppLanguage.english);
      expect(restored.npcTranslationLanguageOverride, TranslationLanguage.none);
      final backup = controller.exportData();
      controller.configureNpcMessageLanguages(reply: null, translation: null);
      expect(controller.npcReplyLanguage, AppLanguage.chinese);
      expect(controller.npcTranslationLanguage, TranslationLanguage.japanese);
      await controller.importData(backup);
      expect(controller.npcReplyLanguageOverride, AppLanguage.english);
      expect(
        controller.npcTranslationLanguageOverride,
        TranslationLanguage.none,
      );
      backup.remove('npcReplyLanguageOverride');
      backup.remove('npcTranslationLanguageOverride');
      await controller.importData(backup);
      expect(controller.npcReplyLanguageOverride, isNull);
      expect(controller.npcTranslationLanguageOverride, isNull);
      expect(controller.npcReplyLanguage, controller.characterReplyLanguage);
      expect(controller.npcTranslationLanguage, controller.translationLanguage);
    },
  );

  test('NPC messages automatically join active save, restart and reset with a new save', () async {
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    await controller.saveToLocalSlot(0);
    final originalSlot = controller.exportLocalSlot(0);
    final state = conversation('claudia', '明天去采七色苹果');
    expect(
      controller.replaceNpcChats(
        state,
        expectedRevision: controller.dataRevision,
      ),
      isTrue,
    );
    // Saving another slot waits for the shared write queue without rewriting slot 0.
    await controller.saveToLocalSlot(1);
    final saved = controller.exportLocalSlot(0);
    expect((saved['snapshot'] as Map)['npcChats'], state.toJson());
    expect(saved['savedAt'], originalSlot['savedAt']);
    final restarted = await AppController.load();
    addTearDown(restarted.dispose);
    expect(restarted.npcChats.toJson(), state.toJson());
    final oldRevision = controller.dataRevision;
    await controller.createLocalSlot(2);
    expect(controller.npcChats.threads, isEmpty);
    expect(
      controller.replaceNpcChats(state, expectedRevision: oldRevision),
      isFalse,
    );
    expect(controller.npcChats.threads, isEmpty);
    await controller.loadFromLocalSlot(0);
    expect(controller.npcChats.toJson(), state.toJson());
  });

  test(
    'NPC records round trip backups and slot imports, old saves start empty',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      final state = conversation('tao', '蓝色书签属于我');
      controller.replaceNpcChats(
        state,
        expectedRevision: controller.dataRevision,
      );
      await controller.saveToLocalSlot(0);
      final backup = controller.exportData();
      final slot = controller.exportLocalSlot(0);
      await controller.createLocalSlot(1);
      await controller.importLocalSlot(2, slot);
      expect(controller.npcChats.threads, isEmpty);
      await controller.loadFromLocalSlot(2);
      expect(controller.npcChats.toJson(), state.toJson());
      await controller.importData(backup);
      expect(controller.npcChats.toJson(), state.toJson());
      final legacy = Map<String, dynamic>.from(backup)..remove('npcChats');
      await controller.importData(legacy);
      expect(controller.npcChats.threads, isEmpty);
      final corrupt = Map<String, dynamic>.from(backup)
        ..['npcChats'] = {'version': 99, 'threads': {}};
      await expectLater(controller.importData(corrupt), throwsFormatException);
      expect(controller.npcChats.threads, isEmpty);
    },
  );

  test(
    'NPC records and contacts stay separate across character sessions',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      final ryza = conversation('claudia', '海边的白色贝壳');
      controller.replaceNpcChats(
        ryza,
        expectedRevision: controller.dataRevision,
      );
      await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
      expect(controller.npcChats.threads, isEmpty);
      expect(
        controller.npcChatContacts.every((c) => c.id.startsWith('sophie_')),
        isTrue,
      );
      final sophie = conversation('sophie_plachta_young', '我喜欢梦里的金色花朵');
      controller.replaceNpcChats(
        sophie,
        expectedRevision: controller.dataRevision,
      );
      await controller.saveToLocalSlot(0);
      await controller.setActiveCharacter(CharacterRuntimeIds.ryza);
      expect(controller.npcChats.toJson(), ryza.toJson());
      await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
      expect(controller.npcChats.toJson(), sophie.toJson());
      await controller.loadFromLocalSlot(0);
      expect(controller.npcChats.toJson(), sophie.toJson());
    },
  );

  test(
    'explicitly added contacts follow the current save and reset on a new one',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      expect(controller.npcMessagingContacts, isEmpty);
      expect(controller.addNpcContact('claudia'), isTrue);
      expect(
        controller.npcMessagingContacts.map((contact) => contact.id),
        contains('claudia'),
      );
      await controller.saveToLocalSlot(0);
      await controller.createLocalSlot(1);
      expect(controller.npcMessagingContacts, isEmpty);
      await controller.loadFromLocalSlot(0);
      expect(
        controller.npcMessagingContacts.map((contact) => contact.id),
        contains('claudia'),
      );
    },
  );

  test(
    'confirmed exchange survives a restart before any private message',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      await controller.saveToLocalSlot(0);
      final revision = controller.dataRevision;
      final request = NpcContactRequestDetector.detect(
        '我询问科洛蒂娅是否可以交换联系方式。',
        contacts: controller.npcChatContacts,
      )!;
      const reply = '科洛蒂娅：当然可以。';
      controller.addUserMessage('发言：科洛蒂娅，交换一下联系方式吧。');
      controller.addAssistantMessage(reply);
      expect(controller.dataRevision, revision);
      final accepted = NpcContactRequestDetector.acceptedContactIds(
        reply,
        request,
        contacts: controller.npcChatContacts,
        primaryCharacterId: controller.activeCharacterId,
      );
      expect(accepted, ['claudia']);
      expect(controller.addNpcContact(accepted.single), isTrue);
      // Saving waits for the same serial slot writes used by contact addition.
      await controller.saveToLocalSlot(0);
      final restarted = await AppController.load();
      addTearDown(restarted.dispose);
      expect(restarted.npcMessagingContacts.map((contact) => contact.id), [
        'claudia',
      ]);
      expect(restarted.npcChats.threads, isEmpty);
      await restarted.createLocalSlot(1);
      expect(restarted.npcMessagingContacts, isEmpty);
      await restarted.loadFromLocalSlot(0);
      expect(restarted.npcMessagingContacts.map((contact) => contact.id), [
        'claudia',
      ]);
    },
  );

  test('main prompts retrieve the mentioned NPC memory without unrelated private messages', () async {
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    final state = conversation(
      'claudia',
      '我们约好了去采七色苹果',
    ).withThread(conversation('tao', '给塔奥的独占暗号斑点雪狐').threadFor('tao'));
    controller.replaceNpcChats(
      state,
      expectedRevision: controller.dataRevision,
    );
    for (final compatibility in [false, true]) {
      controller.llmContextCompatibility = compatibility;
      for (final agent in [false, true]) {
        controller.agentEnabled = agent;
        for (final performance in [false, true]) {
          final prompt = controller.buildCharacterPrompt(
            currentInput: '我去找科洛蒂娅，聊聊采七色苹果的约定',
            independentPerformance: performance,
          );
          expect(prompt, contains('七色苹果'));
          expect(prompt, isNot(contains('独占暗号斑点雪狐')));
          expect(prompt, contains('仅相应 NPC'));
        }
      }
    }
    final npcPrompt = controller.buildNpcMessagePrompt(
      'tao',
      currentInput: '我的暗号是什么？',
    );
    expect(npcPrompt, contains('独占暗号斑点雪狐'));
    expect(npcPrompt, isNot(contains('七色苹果')));
    expect(npcPrompt, contains('用户与主角的关系设定不自动等于'));
    controller.addUserMessage('再见塔奥');
    controller.addAssistantMessage('角色[tao]：明天给你带一本旅行手记。');
    expect(controller.buildNpcMessagePrompt('tao'), contains('旅行手记'));
    expect(
      controller.buildNpcMessagePrompt('claudia'),
      isNot(contains('旅行手记')),
    );
    expect(
      controller.buildCharacterPrompt(currentInput: '我想找科洛蒂娅聊聊'),
      isNot(contains('独占暗号斑点雪狐')),
    );
  });

  test(
    'invalid cross-character backup preserves the current Sophie session',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      final ryzaBackup = controller.exportData();
      await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
      final own = conversation('sophie_alette', '梦里买的花种');
      controller.replaceNpcChats(
        own,
        expectedRevision: controller.dataRevision,
      );
      final corrupt = Map<String, dynamic>.from(ryzaBackup)
        ..['npcChats'] = conversation('unknown_npc', '不能导入的内容').toJson();
      await expectLater(controller.importData(corrupt), throwsFormatException);
      expect(controller.activeCharacterId, CharacterRuntimeIds.sophie);
      expect(controller.npcChats.toJson(), own.toJson());
      expect(controller.characterCatalog.allProfiles, isEmpty);
    },
  );

  test(
    'Sophie main chat recalls only the selected Plachta private memory',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
      final state = conversation('sophie_plachta_young', '幼年的约定金色纸鹤')
          .withThread(
            conversation(
              'sophie_plachta_doll',
              '人偶的秘密蓝色星灯',
            ).threadFor('sophie_plachta_doll'),
          );
      controller.replaceNpcChats(
        state,
        expectedRevision: controller.dataRevision,
      );
      final contact = controller.npcChatContacts.firstWhere(
        (contact) => contact.id == 'sophie_plachta_young',
      );
      final prompt = controller.buildCharacterPrompt(
        currentInput: '我去找${contact.names.chinese}聊聊金色纸鹤',
      );
      expect(prompt, contains('金色纸鹤'));
      expect(prompt, isNot(contains('蓝色星灯')));
    },
  );
}
