import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/alchemy_models.dart';
import 'package:ryza_chat_mvp/src/attachment_thumbnail_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'inventory follows slots, consumption, restart and legacy empty saves',
    () async {
      SharedPreferences.setMockInitialValues({});
      final c = await AppController.load();
      c.alchemyState = AlchemyState(
        inventory: [
          AlchemyItem(
            instanceId: 'custom',
            templateId: 'custom_material',
            customName: '星砂',
            quantity: 5,
            quality: 60,
            tagIds: const [],
            acquiredAt: DateTime(2026),
          ),
        ],
        history: const [],
      );
      await c.saveToLocalSlot(0);
      c.consumeAlchemyItem('custom', quantity: 3);
      await c.saveToLocalSlot(1);
      await c.loadFromLocalSlot(0);
      expect(c.alchemyState.inventory.single.quantity, 5);
      await c.loadFromLocalSlot(1);
      expect(c.alchemyState.inventory.single.quantity, 2);
      await Future<void>.delayed(Duration.zero);
      final restored = await AppController.load();
      expect(restored.alchemyState.inventory.single.quantity, 2);
      final prefs = await SharedPreferences.getInstance();
      final legacy = jsonDecode(prefs.getString('local_save_slot_0')!) as Map;
      (legacy['snapshot'] as Map).remove('alchemy');
      await prefs.setString('local_save_slot_2', jsonEncode(legacy));
      await restored.loadFromLocalSlot(2);
      expect(restored.alchemyState.inventory, isEmpty);
      await restored.loadFromLocalSlot(0);
      expect(restored.alchemyState.inventory.single.quantity, 5);
      final malformed = Map<String, dynamic>.from(restored.exportData())
        ..['alchemy'] = 'broken';
      await expectLater(restored.importData(malformed), throwsFormatException);
      expect(restored.alchemyState.inventory.single.quantity, 5);
      c.dispose();
      restored.dispose();
    },
  );

  test('local save slots capture, restore, and delete game state', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    controller.addUserMessage('存档前的消息');
    controller.setWorldSetting('存档时的世界设定');
    controller.configureFishAudio(
      enabled: true,
      model: 's2-pro',
      referenceId: 'old-voice',
      baseUrl: 'https://old.example.test/v1/tts',
    );

    await controller.saveToLocalSlot(0);
    final saved = controller.localSaveSlots.first;
    expect(saved, isNotNull);
    expect(saved!.messageCount, controller.messages.length);
    expect(saved.preview, contains('存档前的消息'));

    controller.clearChatHistory();
    controller.setWorldSetting('当前全局世界设定');
    controller.configureFishAudio(
      enabled: true,
      model: 's2-pro',
      referenceId: 'current-voice',
      baseUrl: 'https://current.example.test/v1/tts',
    );
    await controller.loadFromLocalSlot(0);

    expect(controller.messages.last.text, '存档前的消息');
    expect(controller.worldSetting, '存档时的世界设定');
    expect(controller.fishAudioReferenceId, 'current-voice');
    expect(controller.fishAudioBaseUrl, 'https://current.example.test/v1/tts');

    await controller.deleteLocalSlot(0);
    expect(controller.localSaveSlots.first, isNull);
  });

  test(
    'save management roundtrips role settings without loading on import',
    () async {
      SharedPreferences.setMockInitialValues({});
      final c = await AppController.load();
      c.setCharacterPersona('存档人物');
      c.setWorldSetting('存档世界');
      c.setWorldSettingInjectionEnabled(false);
      final profile = c.exportData()['userProfile'];
      final slots = c.exportData()['settingsSlots'];
      c.messages = [];
      await c.saveToLocalSlot(0);
      await c.renameLocalSlot(0, ' 新旅程 ');
      final saved = c.exportLocalSlot(0);
      expect(c.localSaveSlots[0]!.name, '新旅程');
      expect(
        (saved['snapshot'] as Map)['roleSettings'],
        containsPair('userProfile', profile),
      );
      c.setCharacterPersona('当前人物');
      c.setWorldSetting('当前世界');
      c.setWorldSettingInjectionEnabled(true);
      c.addUserMessage('当前消息');
      await c.importLocalSlot(1, saved);
      expect(c.characterPersona, '当前人物');
      expect(c.messages.last.text, '当前消息');
      final malformed = jsonDecode(jsonEncode(saved)) as Map<String, dynamic>;
      (malformed['snapshot'] as Map)['roleSettings'] = 'broken';
      await expectLater(c.importLocalSlot(1, malformed), throwsFormatException);
      expect(c.localSaveSlots[1]!.name, '新旅程');
      await c.loadFromLocalSlot(1);
      expect(c.messages, isEmpty);
      expect(c.characterPersona, '存档人物');
      expect(c.worldSetting, '存档世界');
      expect(c.worldSettingInjectionEnabled, isFalse);
      expect(c.exportData()['userProfile'], profile);
      expect(c.exportData()['settingsSlots'], slots);
      final legacy = jsonDecode(jsonEncode(saved)) as Map<String, dynamic>;
      (legacy['snapshot'] as Map).remove('roleSettings');
      await c.importLocalSlot(2, legacy);
      c.setWorldSetting('旧存档保留当前设置');
      await c.loadFromLocalSlot(2);
      expect(c.worldSetting, '旧存档保留当前设置');
      c.dispose();
    },
  );

  test('empty and out-of-range save slots are rejected', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();

    await expectLater(controller.loadFromLocalSlot(0), throwsFormatException);
    expect(
      () => controller.saveToLocalSlot(AppController.localSaveSlotCount),
      throwsRangeError,
    );
  });

  test(
    'imports retain the newest 60 messages and reject partial updates',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      controller.addUserMessage('当前状态');
      final before = controller.messages
          .map((message) => message.text)
          .toList();
      final backup = controller.exportData();
      backup['messages'] = List.generate(
        65,
        (index) => {'text': '消息 $index', 'isUser': index.isEven},
      );

      await controller.importData(backup);
      expect(controller.messages, hasLength(60));
      expect(controller.messages.first.text, '消息 5');
      expect(controller.messages.last.text, '消息 64');

      final malformed = controller.exportData();
      malformed['messages'] = [
        {'text': '不应写入实时状态', 'isUser': true},
      ];
      malformed['userProfile'] = 'invalid';
      await expectLater(
        controller.importData(malformed),
        throwsA(isA<TypeError>()),
      );
      expect(controller.messages.last.text, '消息 64');
      expect(before, isNotEmpty);
    },
  );

  test(
    'custom provider and user profile fields persist across restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      controller.configureFishAudio(
        enabled: true,
        model: 's2-pro',
        referenceId: 'voice-id',
        baseUrl: 'https://tts.example.test/v1/tts',
      );
      controller.configureUserProfile(
        address: '伙伴',
        portrait: '',
        relationshipRole: UserRelationshipRole.familiarPartner,
        interactionStyle: UserInteractionStyle.balanced,
        relationshipCustom: '一起旅行的搭档',
        interactionCustom: '直率但不要替我决定',
        boundaries: '',
      );
      await Future<void>.delayed(Duration.zero);

      final restored = await AppController.load();
      expect(restored.fishAudioBaseUrl, 'https://tts.example.test/v1/tts');
      expect(restored.userRelationshipCustom, '一起旅行的搭档');
      expect(restored.userInteractionCustom, '直率但不要替我决定');
    },
  );

  test(
    'stored attachment thumbnails are restored without original bytes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'agent_atelier_thumbnail_test_',
      );
      AttachmentThumbnailStore.debugDirectoryOverride = directory;
      try {
        final thumbnail = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);
        final key = await AttachmentThumbnailStore.write(thumbnail);
        expect(key, isNotNull);
        final controller = await AppController.load();
        controller.addUserMessage(
          '图片',
          attachments: [
            ChatAttachment(
              name: 'preview.png',
              mimeType: 'image/png',
              size: 1024,
              bytes: Uint8List.fromList([9, 8, 7]),
              thumbnailBytes: thumbnail,
              thumbnailKey: key,
            ),
          ],
        );
        await Future<void>.delayed(Duration.zero);

        final restored = await AppController.load();
        final attachment = restored.messages.last.attachments.single;
        expect(attachment.bytes, isNull);
        expect(attachment.previewBytes, thumbnail);

        final portable = restored.exportData(includeAttachmentThumbnails: true);
        final destination = await Directory.systemTemp.createTemp(
          'agent_atelier_thumbnail_import_test_',
        );
        AttachmentThumbnailStore.debugDirectoryOverride = destination;
        try {
          final imported = await AppController.load();
          await imported.importData(portable);
          final importedAttachment = imported.messages.last.attachments.single;
          expect(importedAttachment.previewBytes, thumbnail);
          expect(importedAttachment.thumbnailKey, isNotNull);
          expect(
            await AttachmentThumbnailStore.read(
              importedAttachment.thumbnailKey,
            ),
            thumbnail,
          );
        } finally {
          await destination.delete(recursive: true);
        }
      } finally {
        AttachmentThumbnailStore.debugDirectoryOverride = null;
        await directory.delete(recursive: true);
      }
    },
  );
}
