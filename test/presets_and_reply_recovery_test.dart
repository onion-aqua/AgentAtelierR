import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/settings_slots.dart';
import 'package:ryza_chat_mvp/src/settings_preset_actions.dart';
import 'package:ryza_chat_mvp/src/performance_planner.dart';
import 'package:ryza_chat_mvp/src/memory_refresh_gate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('all three preset banks survive saves/imports/reload without changing active roles', () async {
    SharedPreferences.setMockInitialValues({});
    final c = await AppController.load();
    addTearDown(c.dispose);
    c.setCharacterPersona('saved role');
    c.updateMemorySummary('memory at save');
    await c.saveToLocalSlot(0);
    final backup = c.exportData();
    for (final kind in SettingsSlotKind.values) {
      final bank = c.presetSlots(kind);
      for (var i = 0; i < 5; i++) {
        bank.entries[i] = kind == SettingsSlotKind.user
            ? {
                'address': 'preset $i',
                'portrait': 'portrait $i',
                'preferCustom': 'true',
              }
            : {'text': '${kind.name} preset $i'};
      }
      bank.active = 4;
      await c.savePresetSlots(kind, bank);
      bank.entries[4]!.clear();
    }
    expect(c.characterPersona, 'saved role');
    expect(c.userAddress, isNot('preset 4'));
    c.updateMemorySummary('later memory');
    await c.loadFromLocalSlot(0);
    expect(c.memorySummary, 'memory at save');
    c.updateMemorySummary('new memory after load');
    expect(c.memorySummary, 'new memory after load');
    await c.importData(backup);
    final reloaded = await AppController.load();
    addTearDown(reloaded.dispose);
    for (final kind in SettingsSlotKind.values) {
      final bank = reloaded.presetSlots(kind);
      expect(bank.entries.whereType<Map>().length, 5);
      expect(bank.entries[4], isNotEmpty);
      expect(bank.active, 4);
    }
    expect(jsonEncode(c.exportLocalSlot(0)), isNot(contains('preset 4')));
  });

  test('configuration JSON roundtrip rejects wrong types and arbitrary application data', () {
    for (final kind in SettingsSlotKind.values) {
      final entry = kind == SettingsSlotKind.user
          ? {'address': '伙伴', 'portrait': '旅人'}
          : {'text': '设定'};
      final file = jsonDecode(
        jsonEncode(SettingsPresetFile.encode(kind, entry)),
      );
      expect(SettingsPresetFile.decode(file, kind), entry);
      final other = kind == SettingsSlotKind.user
          ? SettingsSlotKind.world
          : SettingsSlotKind.user;
      expect(
        () => SettingsPresetFile.decode(file, other),
        throwsFormatException,
      );
    }
    expect(
      () => SettingsPresetFile.decode({'messages': []}, SettingsSlotKind.world),
      throwsFormatException,
    );
    expect(
      () => SettingsPresetFile.decode(
        SettingsPresetFile.encode(SettingsSlotKind.world, {
          'text': 'x',
          'apiKey': 'invalid',
        }),
        SettingsSlotKind.world,
      ),
      throwsFormatException,
    );
  });

  test('continuation retry removes failure without losing previous user or assistant messages', () async {
    SharedPreferences.setMockInitialValues({});
    final c = await AppController.load();
    addTearDown(c.dispose);
    c.addUserMessage('hello');
    c.addAssistantMessage('莱莎：你好');
    final before = c.messages.toList();
    c.beginAssistantStream();
    c.failAssistantStream('HTTP 404');
    expect(c.messages.last.isFailure, isTrue);
    expect(c.contextMessagesForModel().any((m) => m.isFailure), isFalse);
    expect(ChatMessage.fromJson(c.messages.last.toJson()).isFailure, isTrue);
    c.beginAssistantStream();
    expect(c.messages.take(before.length), before);
    expect(c.messages.any((m) => m.isFailure), isFalse);
    c.appendAssistantDelta('莱莎：继续');
    c.finishAssistantStream();
    expect(c.messages.last.text, '莱莎：继续');
    expect(
      ChatMessage.fromJson({'text': '连接失败：HTTP 404', 'isUser': false})
          .isFailure,
      isTrue,
    );
    expect(
      ChatMessage.fromJson({'text': '连接失败：HTTP 404', 'isUser': true}).isFailure,
      isFalse,
    );
  });

  test('valid state update survives an invalid animation plan', () async {
    Map<String, dynamic>? state;
    await expectLater(
      PerformancePlanner().plan(
        userInput: '休息一下',
        source: '莱莎：好呀',
        currentFace: 'neutral',
        recentActions: [],
        capabilities: CharacterPerformancePromptContext(
          appearanceId: 'test',
          posture: 'standing',
          revision: 1,
          resourcesReady: true,
          playableActionDescriptions: const {},
        ),
        characterState: {'emotion': 'neutral'},
        onStateProposal: (value) => state = value,
        complete: (_) async => '{"segments":[{"id":0,"face":"invalid","action":"none"}],"state_delta":{"energy":2},"emotion":"happy","reason":"休息恢复精力"}',
      ),
      throwsFormatException,
    );
    expect(state?['reason'], '休息恢复精力');
  });

  test('old memory requests cannot block or unlock new work after loading', () {
    final gate = MemoryRefreshGate();
    final old = gate.begin()!;
    expect(gate.begin(), isNull);
    gate.invalidate(afterLoad: true);
    expect(gate.refreshAfterLoad, isTrue);
    final current = gate.begin()!;
    expect(gate.owns(old), isFalse);
    expect(gate.finish(old), isFalse);
    expect(gate.running, isTrue);
    expect(gate.finish(current), isTrue);
    expect(gate.running, isFalse);
    expect(gate.begin(), isNotNull);
  });

  test(
    'rendering posture and Ryza state are not user profile or fixed commands',
    () async {
      SharedPreferences.setMockInitialValues({});
      final c = await AppController.load();
      addTearDown(c.dispose);
      final prompt = c.buildCharacterPrompt(independentPerformance: true);
      final profile = prompt.split('用户资料：').last.split('\n').first;
      expect(jsonDecode(profile), isNot(contains('莱莎当前状态')));
      expect(prompt, contains('应用渲染快照'));
      expect(prompt, contains('不是用户的角色设定或保持不动的命令'));
      expect(prompt, contains('应用提供的莱莎状态'));
    },
  );
}
