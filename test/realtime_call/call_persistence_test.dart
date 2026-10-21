import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';
import 'package:ryza_chat_mvp/src/npc_chat_models.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_records.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_ui_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

CallRecord record({
  required String id,
  required String contactId,
  required String contactName,
  String user = '今晚去哪里？',
  String assistant = '去港口吹吹风吧。',
}) => CallRecord(
  id: id,
  contactId: contactId,
  contactName: contactName,
  startedAt: DateTime.utc(2026, 10, 21, 12),
  incoming: false,
  seconds: 12,
  status: CallHistoryStatus.completed,
  turns: [
    {'user': user, 'assistant': assistant},
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory supportDirectory;

  setUpAll(() async {
    supportDirectory = await Directory.systemTemp.createTemp(
      'realtime-call-persistence-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProvider,
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? supportDirectory.path
              : null,
        );
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await supportDirectory.delete(recursive: true);
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('call records round trip JSON and reject malformed transcripts', () {
    final original = record(
      id: 'call-1',
      contactId: 'primary:ryza',
      contactName: '莱莎',
    );
    final restored = CallRecord.fromJson(
      jsonDecode(jsonEncode(original.toJson())),
    );
    expect(restored.toJson(), original.toJson());
    expect(restored.startedAt.isUtc, isTrue);

    final malformed = original.toJson()
      ..['turns'] = [
        {'user': '只有用户，没有已播放回复'},
      ];
    expect(() => CallRecord.fromJson(malformed), throwsFormatException);
    expect(
      () => parseCallRecords(List.filled(101, original.toJson())),
      throwsFormatException,
    );
  });

  test(
    'call history and spoken main-character text follow local save revisions',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      await controller.saveToLocalSlot(0, name: '电话前');
      final firstRevision = controller.dataRevision;
      final primary = 'primary:${controller.activeCharacterId}';

      controller.recordCallExchange(
        primary,
        '今晚去哪里？',
        '去港口吹吹风吧。',
        expectedRevision: firstRevision,
      );
      controller.saveCallRecord(
        record(id: 'call-old', contactId: primary, contactName: '莱莎'),
        expectedRevision: firstRevision,
      );
      await controller.saveToLocalSlot(0, name: '有电话的存档');

      await controller.createLocalSlot(1, name: '新存档');
      expect(controller.callRecords, isEmpty);
      final freshMessages = controller.messages.map((m) => m.text).toList();

      controller.recordCallExchange(
        primary,
        '这条来自旧通话',
        '不应写进新档',
        expectedRevision: firstRevision,
      );
      controller.saveCallRecord(
        record(id: 'late-old', contactId: primary, contactName: '莱莎'),
        expectedRevision: firstRevision,
      );
      expect(controller.callRecords, isEmpty);
      expect(controller.messages.map((m) => m.text), freshMessages);

      await controller.loadFromLocalSlot(0);
      expect(controller.callRecords.map((r) => r.id), ['call-old']);
      expect(controller.messages.map((m) => m.text), contains('今晚去哪里？'));
      expect(
        controller.messages.map((m) => m.text),
        contains('角色[ryza]：去港口吹吹风吧。'),
      );
      expect(controller.callMemoryFor(primary), contains('去港口吹吹风吧'));
      expect(controller.callMemoryFor(primary), isNot(contains('不应写进新档')));
    },
  );

  test(
    'data reset callback seals the old call before a new save replaces it',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      await controller.saveToLocalSlot(0, name: '通话中的存档');
      final revision = controller.dataRevision;
      final primary = 'primary:${controller.activeCharacterId}';
      late final void Function() sealCall;
      sealCall = () {
        controller.removeDataResetListener(sealCall);
        controller.recordCallExchange(
          primary,
          '切档前最后一句',
          '这句已经完整播放。',
          expectedRevision: revision,
        );
        controller.saveCallRecord(
          record(
            id: 'sealed-call',
            contactId: primary,
            contactName: '莱莎',
            user: '切档前最后一句',
            assistant: '这句已经完整播放。',
          ),
          expectedRevision: revision,
        );
      };
      controller.addDataResetListener(sealCall);

      await controller.createLocalSlot(1, name: '新存档');
      expect(controller.callRecords, isEmpty);
      expect(
        controller.messages.map((message) => message.text),
        isNot(contains('切档前最后一句')),
      );

      await controller.loadFromLocalSlot(0);
      expect(controller.callRecords.map((item) => item.id), ['sealed-call']);
      expect(
        controller.messages.map((message) => message.text),
        contains('切档前最后一句'),
      );
      expect(controller.callMemoryFor(primary), contains('这句已经完整播放'));
    },
  );

  test(
    'NPC phone exchanges share its message thread and require a contact',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      final revision = controller.dataRevision;

      controller.recordCallExchange(
        'claudia',
        '还没加好友',
        '不能写入',
        expectedRevision: revision,
      );
      expect(controller.npcChats.threadFor('claudia').messages, isEmpty);

      expect(controller.addNpcContact('claudia'), isTrue);
      controller.recordCallExchange(
        'claudia',
        '明天一起喝茶吗？',
        '当然，我会准备好茶点。',
        expectedRevision: revision,
      );
      final messages = controller.npcChats.threadFor('claudia').messages;
      expect(messages.map((m) => m.text), ['明天一起喝茶吗？', '当然，我会准备好茶点。']);

      controller.recordCallExchange(
        'claudia',
        '未播放的问题',
        '',
        expectedRevision: revision,
      );
      expect(controller.npcChats.threadFor('claudia').messages, hasLength(2));
    },
  );

  test(
    'call records stay isolated across character sessions and backups',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      final ryzaRecord = record(
        id: 'ryza-call',
        contactId: 'primary:ryza',
        contactName: '莱莎',
      );
      controller.saveCallRecord(
        ryzaRecord,
        expectedRevision: controller.dataRevision,
      );
      final backup = controller.exportData();

      await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
      expect(controller.callRecords, isEmpty);
      controller.saveCallRecord(
        record(
          id: 'sophie-call',
          contactId: 'primary:sophie',
          contactName: '苏菲',
        ),
        expectedRevision: controller.dataRevision,
      );
      expect(controller.callRecords.map((r) => r.id), ['sophie-call']);

      await controller.setActiveCharacter(CharacterRuntimeIds.ryza);
      expect(controller.callRecords.map((r) => r.id), ['ryza-call']);

      controller.callRecords = [];
      await controller.importData(backup);
      expect(controller.callRecords.map((r) => r.id), ['ryza-call']);
    },
  );

  test(
    'save export without conversation history omits call transcripts',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      controller.saveCallRecord(
        record(
          id: 'private-call',
          contactId: 'primary:ryza',
          contactName: '莱莎',
        ),
        expectedRevision: controller.dataRevision,
      );
      controller.addNpcContact('claudia');
      controller.recordCallExchange(
        'claudia',
        '这是私密问题',
        '这是电话里播放过的回答',
        expectedRevision: controller.dataRevision,
      );
      await controller.saveToLocalSlot(0);

      final withoutHistory = controller.exportLocalSlot(
        0,
        includeConversationHistory: false,
      );
      final snapshot = withoutHistory['snapshot'] as Map;
      expect(snapshot['messages'], isEmpty);
      expect(snapshot['callRecords'], isEmpty);
      final exportedNpcState = NpcChatState.fromJson(snapshot['npcChats']);
      expect(exportedNpcState.contactIds, contains('claudia'));
      expect(
        exportedNpcState.threads,
        isEmpty,
        reason: 'NPC message threads can contain phone transcripts',
      );
      expect(
        (controller.exportLocalSlot(0)['snapshot'] as Map)['callRecords'],
        isNotEmpty,
      );
      expect(
        NpcChatState.fromJson(
          (controller.exportLocalSlot(0)['snapshot'] as Map)['npcChats'],
        ).threads['claudia']!.messages,
        isNotEmpty,
      );
    },
  );
}
