import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Exercise pending native writes using the preferences package's test store.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _DelayedSlotStore extends InMemorySharedPreferencesStore {
  _DelayedSlotStore() : super.withData({});

  Completer<void>? _release;
  Completer<void>? _started;
  String? _key;

  void delayNextWrite(String key) {
    _key = 'flutter.$key';
    _release = Completer<void>();
    _started = Completer<void>();
  }

  Future<void> get writeStarted => _started!.future;
  void releaseWrite() => _release!.complete();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == _key) {
      _key = null;
      _started!.complete();
      await _release!.future;
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory support;

  setUpAll(() async {
    support = await Directory.systemTemp.createTemp('data-export-regression-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => support.path);
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await support.delete(recursive: true);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppController> create() async {
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    return controller;
  }

  test('history-free save export also removes archived raw dialogue', () async {
    final controller = await create();
    controller.addUserMessage('仅在原话中的秘密标记 alpha-4829');
    controller.addAssistantMessage('莱莎：另一句原始答复 beta-7284');
    controller.configureLongTermMemory(enabled: true, summary: '保留整理后的记忆');
    await controller.saveToLocalSlot(0);
    expect(controller.ragArchiveTurnCount, 1);

    final exported = controller.exportLocalSlot(
      0,
      includeConversationHistory: false,
    );
    final snapshot = exported['snapshot'] as Map;
    expect(snapshot['messages'], isEmpty);
    expect((snapshot['ragMemoryArchive'] as Map)['turns'], isEmpty);
    expect(snapshot['recentMemoryCheckpoints'], isEmpty);
    expect(snapshot['lastRecentMemoryMessageId'], isNull);
    expect(snapshot['memorySummary'], contains('保留整理后的记忆'));
    expect(jsonEncode(exported), isNot(contains('alpha-4829')));
    expect(jsonEncode(exported), isNot(contains('beta-7284')));
    final original = controller.exportLocalSlot(0)['snapshot'] as Map;
    expect((original['ragMemoryArchive'] as Map)['turns'], hasLength(1));

    await controller.importLocalSlot(1, exported);
    await controller.loadFromLocalSlot(1);
    expect(controller.messages, isEmpty);
    expect(controller.ragArchiveTurnCount, 0);
  });

  test(
    'explicit empty backup replaces history; absent history preserves it',
    () async {
      final controller = await create();
      controller.addUserMessage('不应残留的旧对话');
      final settingsOnly = controller.exportData()..remove('messages');
      await controller.importData(settingsOnly);
      expect(controller.messages.last.text, '不应残留的旧对话');

      final emptyBackup = controller.exportData()..['messages'] = <Object>[];
      await controller.importData(emptyBackup);
      expect(controller.messages, isEmpty);
    },
  );

  test(
    'switching to an empty character session does not copy the old chat',
    () async {
      final controller = await create();
      controller.addUserMessage('莱莎自己的对话');
      await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
      controller.messages = [];
      await controller.setActiveCharacter(CharacterRuntimeIds.ryza);
      expect(controller.messages.last.text, '莱莎自己的对话');
      await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
      expect(controller.messages, isEmpty);
    },
  );

  for (final raw in [
    '{"messages":[]}',
    '[{"text":123,"isUser":true}]',
    '[{"text":"hello","isUser":"yes"}]',
  ]) {
    test('malformed stored dialogue does not prevent startup: $raw', () async {
      SharedPreferences.setMockInitialValues({'chat_messages': raw});
      final controller = await create();
      expect(controller.messages, hasLength(1));
      expect(controller.messages.single.isUser, isFalse);
      expect(controller.messages.single.text, isNotEmpty);
    });
  }

  test(
    'a delayed save updates the active slot for its original character',
    () async {
      final store = _DelayedSlotStore();
      SharedPreferencesStorePlatform.instance = store;
      final controller = await create();
      store.delayNextWrite('local_save_slot_0');
      final saving = controller.saveToLocalSlot(0);
      await store.writeStarted;
      await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
      store.releaseWrite();
      await saving;

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getInt('active_local_save_slot'), 0);
      expect(preferences.getInt('active_local_save_slot_sophie'), isNull);
      expect(controller.activeLocalSaveSlot, isNull);
      final saved =
          jsonDecode(preferences.getString('local_save_slot_0')!) as Map;
      expect(
        (saved['snapshot'] as Map)['characterId'],
        CharacterRuntimeIds.ryza,
      );
    },
  );

  test('deleting a slot waits for its pending translation write', () async {
    final store = _DelayedSlotStore();
    SharedPreferencesStorePlatform.instance = store;
    final controller = await create();
    controller.addUserMessage('hello');
    controller.addAssistantMessage('莱莎：こんにちは。');
    await controller.saveToLocalSlot(0);
    store.delayNextWrite('local_save_slot_0');
    final translating = controller.attachTranslation(
      controller.messages.last,
      '你好。',
    );
    await store.writeStarted;
    final deleting = controller.deleteLocalSlot(0);
    await Future<void>.delayed(Duration.zero);
    store.releaseWrite();
    await translating;
    await deleting;

    // Reload the platform store: the shared_preferences cache alone would
    // hide a delayed write resurrecting a slot after its deletion.
    final preferences = await SharedPreferences.getInstance();
    await preferences.reload();
    expect(preferences.containsKey('local_save_slot_0'), isFalse);
    expect(preferences.containsKey('active_local_save_slot'), isFalse);
  });

  test(
    'legacy load migration keeps its character after a delayed write',
    () async {
      final store = _DelayedSlotStore();
      SharedPreferencesStorePlatform.instance = store;
      final controller = await create();
      await controller.saveToLocalSlot(0);
      final preferences = await SharedPreferences.getInstance();
      final legacy =
          jsonDecode(preferences.getString('local_save_slot_0')!) as Map;
      (legacy['snapshot'] as Map).remove('virtualPhoneCarrier');
      await preferences.setString('local_save_slot_0', jsonEncode(legacy));
      await preferences.remove('active_local_save_slot');

      store.delayNextWrite('local_save_slot_0');
      final loading = controller.loadFromLocalSlot(0);
      await store.writeStarted;
      await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
      store.releaseWrite();
      await loading;

      expect(preferences.getInt('active_local_save_slot'), 0);
      expect(preferences.getInt('active_local_save_slot_sophie'), isNull);
      expect(preferences.containsKey('local_save_slot_sophie_0'), isFalse);
      final migrated =
          jsonDecode(preferences.getString('local_save_slot_0')!) as Map;
      expect((migrated['snapshot'] as Map)['virtualPhoneCarrier'], isA<Map>());
      expect(
        (migrated['snapshot'] as Map)['characterId'],
        CharacterRuntimeIds.ryza,
      );
    },
  );

  test(
    'a pending thumbnail load cannot invalidate a switched character',
    () async {
      final controller = await create();
      controller.addUserMessage(
        '莱莎存档中的图片',
        attachments: const [
          ChatAttachment(
            name: 'preview.png',
            mimeType: 'image/png',
            size: 10,
            thumbnailKey: 'thumb_1_1.png',
          ),
        ],
      );
      await controller.saveToLocalSlot(0);
      final directoryRequested = Completer<void>();
      final directoryReady = Completer<String>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(pathProvider, (_) {
        if (!directoryRequested.isCompleted) directoryRequested.complete();
        return directoryReady.future;
      });
      try {
        final loading = expectLater(
          controller.loadFromLocalSlot(0),
          throwsStateError,
        );
        await directoryRequested.future;
        await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
        final revision = controller.dataRevision;
        final messages = controller.messages
            .map((message) => message.text)
            .toList();
        directoryReady.complete(support.path);
        await loading;
        expect(controller.activeCharacterId, CharacterRuntimeIds.sophie);
        expect(controller.dataRevision, revision);
        expect(controller.messages.map((message) => message.text), messages);
        expect(controller.activeLocalSaveSlot, isNull);
      } finally {
        if (!directoryReady.isCompleted) directoryReady.complete(support.path);
        messenger.setMockMethodCallHandler(
          pathProvider,
          (_) async => support.path,
        );
      }
    },
  );
}
