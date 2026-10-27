import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';
import 'package:ryza_chat_mvp/src/character_state.dart';
import 'package:ryza_chat_mvp/src/shop_catalog.dart';
import 'package:ryza_chat_mvp/src/story_clock.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _jsonCopy(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

Map<String, dynamic> _runtime(AppController controller) => _jsonCopy({
  'state': controller.characterState.toJson(),
  'clock': controller.storyClock.toJson(),
  'scene': controller.sceneTime.name,
  'automatic': controller.automaticSceneTime,
  'enabled': controller.storyClockEnabled,
  'mood': controller.characterMood.name,
  'count': controller.userMessageCount,
  'points': controller.relationshipPoints,
});

CharacterState _seedState({int mood = -301, int energy = 20}) => CharacterState(
  values: {'mood': mood, 'energy': energy, 'closeness': 42, 'curiosity': 73},
  bands: {'mood': 0, 'energy': 0, 'closeness': 1, 'curiosity': 2},
  delta: {'mood': -500, 'energy': -3, 'closeness': 1, 'curiosity': 2},
  emotion: 'sad',
  reason: '上一轮的真实状态',
  updatedAt: DateTime.utc(2026, 10, 26, 1, 2, 3),
  settled: ['previous-turn', 'previous-turn:recovery'],
  oathRingLossPending: mood < -250,
);

Map<String, dynamic> _proposal({String kind = 'rest', int minutes = 60}) => {
  'state_delta': {'mood': 5, 'energy': -5, 'closeness': 2, 'curiosity': -2},
  'emotion': 'happy',
  'reason': '本轮互动改变人物状态',
  'time_advance': {'kind': kind, 'minutes': minutes},
};

void _settle(
  AppController controller,
  String turn, {
  String kind = 'rest',
  int minutes = 60,
}) {
  final revision = controller.dataRevision;
  final proposal = _proposal(kind: kind, minutes: minutes);
  expect(controller.settleCharacterState(turn, proposal, revision), isTrue);
  expect(controller.settleStoryTime(turn, proposal, revision), isTrue);
  controller.addAssistantMessage('本轮回复：$turn');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory support;

  setUpAll(() async {
    support = await Directory.systemTemp.createTemp('turn-undo-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return support.path;
          }
          return null;
        });
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

  void seed(AppController controller) {
    controller.characterState = _seedState();
    controller.setStoryClockEnabled(true);
    controller.storyClock = StoryClock(
      totalMinutes: 23 * 60 + 55,
      satiety: 8,
      settledTurns: ['previous-turn'],
    );
    controller.sceneTime = SceneTime.night;
    controller.characterMood = CharacterMood.concerned;
    controller.userMessageCount = 7;
    controller.relationshipPoints = 19;
  }

  test('undo restores the exact pre-turn state, clock, and counters', () async {
    final controller = await create();
    seed(controller);
    final before = _runtime(controller);
    final id = controller.addUserMessage('休息一会儿吧');
    expect(controller.messages.last.turnSnapshot, isNotNull);
    _settle(controller, 'rest-turn');
    expect(controller.storyClock.day, 2);
    expect(_runtime(controller), isNot(before));

    expect(controller.undoLastUserTurn()?.id, id);
    expect(_runtime(controller), before);
    expect(controller.characterState.reconciliationPurchaseBlocked, isTrue);
    expect(controller.characterState.settled, isNot(contains('rest-turn')));
    expect(controller.storyClock.settledTurns, isNot(contains('rest-turn')));
    expect(controller.messages.any((m) => m.id == id), isFalse);
  });

  test(
    'repeated undo reverses midnight hunger and recovery one turn at a time',
    () async {
      final controller = await create();
      seed(controller);
      final first = _runtime(controller);
      controller.addUserMessage('我们走一小时');
      _settle(controller, 'travel-turn', kind: 'travel', minutes: 60);
      final second = _runtime(controller);
      expect(controller.storyClock.satiety, 4);
      expect(controller.characterState.values['energy'], 13);
      controller.addUserMessage('睡一觉');
      _settle(controller, 'sleep-turn', kind: 'sleep', minutes: 180);
      expect(controller.characterState.values['energy'], 80);
      controller.undoLastUserTurn();
      expect(_runtime(controller), second);
      controller.undoLastUserTurn();
      expect(_runtime(controller), first);
    },
  );

  test(
    'disabled story clock still reverses rest recovery and emotion',
    () async {
      final controller = await create();
      controller.characterState = _seedState();
      controller.setStoryClockEnabled(false);
      final before = _runtime(controller);
      controller.addUserMessage('先休息一下');
      _settle(controller, 'without-clock');
      expect(controller.characterState.values['energy'], 25);
      controller.undoLastUserTurn();
      expect(_runtime(controller), before);
    },
  );

  test(
    'snapshot owns copies rather than mutable state maps and lists',
    () async {
      final controller = await create();
      seed(controller);
      final before = _runtime(controller);
      controller.addUserMessage('保留当前状态');
      controller.characterState.values['energy'] = 99;
      controller.characterState.delta['mood'] = 99;
      controller.characterState.settled.add('mutated');
      controller.storyClock.settledTurns.add('mutated');
      controller.undoLastUserTurn();
      expect(_runtime(controller), before);
    },
  );

  test(
    'undo invalidates late planner state and time; replay can settle normally',
    () async {
      final controller = await create();
      seed(controller);
      final before = _runtime(controller);
      controller.addUserMessage('稍后才完成的回复');
      final oldRevision = controller.dataRevision;
      var resets = 0;
      controller.addDataResetListener(() => resets++);
      controller.undoLastUserTurn();
      expect(resets, 1);
      expect(controller.dataRevision, greaterThan(oldRevision));
      expect(
        controller.settleCharacterState('late', _proposal(), oldRevision),
        isFalse,
      );
      expect(
        controller.settleStoryTime('late', _proposal(), oldRevision),
        isFalse,
      );
      expect(_runtime(controller), before);

      controller.addUserMessage('重新发送同一条');
      _settle(controller, 'late');
      expect(controller.characterState.settled, contains('late'));
      expect(controller.storyClock.settledTurns, contains('late'));
    },
  );

  test('message JSON roundtrip and copy retain the undo snapshot', () async {
    final controller = await create();
    seed(controller);
    controller.addUserMessage('记录随对话保存');
    final original = controller.messages.last;
    final decoded = ChatMessage.fromJson(_jsonCopy(original.toJson()));
    expect(decoded.turnSnapshot, isNotNull);
    expect(decoded.toJson()['turnSnapshot'], original.toJson()['turnSnapshot']);
    expect(
      decoded.copyWith(text: '修改后的文本').toJson()['turnSnapshot'],
      original.toJson()['turnSnapshot'],
    );
  });

  test(
    'undo snapshot survives app restart and remains persisted after undo',
    () async {
      final controller = await create();
      seed(controller);
      final before = _runtime(controller);
      controller.addUserMessage('重启后撤回');
      _settle(controller, 'restart');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final restored = await create();
      expect(
        restored.messages.lastWhere((m) => m.isUser).turnSnapshot,
        isNotNull,
      );
      restored.undoLastUserTurn();
      expect(_runtime(restored), before);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final restartedAgain = await create();
      expect(_runtime(restartedAgain), before);
    },
  );

  test('local save loading restores its own pre-turn snapshot', () async {
    final controller = await create();
    seed(controller);
    final before = _runtime(controller);
    controller.addUserMessage('保存在槽位的对话');
    _settle(controller, 'saved-turn');
    await controller.saveToLocalSlot(0);
    controller.addUserMessage('存档之后');
    _settle(controller, 'later-turn');
    await controller.loadFromLocalSlot(0);
    controller.undoLastUserTurn();
    expect(_runtime(controller), before);
  });

  test('portable backup preserves per-turn snapshots', () async {
    final controller = await create();
    seed(controller);
    final before = _runtime(controller);
    controller.addUserMessage('导出后撤回');
    _settle(controller, 'export-turn');
    final backup = _jsonCopy(controller.exportData());
    final imported = await create();
    await imported.importData(backup);
    imported.undoLastUserTurn();
    expect(_runtime(imported), before);
  });

  test('characters retain separate undo snapshots when switching', () async {
    final controller = await create();
    seed(controller);
    final ryzaBefore = _runtime(controller);
    controller.addUserMessage('莱莎这一轮');
    _settle(controller, 'ryza-turn');
    await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
    controller.characterState = _seedState(mood: 12, energy: 50);
    controller.setStoryClockEnabled(true);
    final sophieBefore = _runtime(controller);
    controller.addUserMessage('苏菲这一轮');
    _settle(controller, 'sophie-turn');
    controller.undoLastUserTurn();
    expect(_runtime(controller), sophieBefore);
    await controller.setActiveCharacter(CharacterRuntimeIds.ryza);
    controller.undoLastUserTurn();
    expect(_runtime(controller), ryzaBefore);
  });

  test(
    'legacy messages and malformed snapshots keep current state and time',
    () async {
      final controller = await create();
      seed(controller);
      for (final snapshot in [
        null,
        'broken',
        {'version': 999},
        {'version': 1},
      ]) {
        final json = <String, dynamic>{
          'id': 'legacy',
          'text': '旧版对话',
          'isUser': true,
          'turnSnapshot': ?snapshot,
        };
        final message = ChatMessage.fromJson(json);
        expect(message.turnSnapshot, isNull);
        controller.messages = [
          message,
          const ChatMessage(text: '旧版回复', isUser: false),
        ];
        final beforeState = _jsonCopy(controller.characterState.toJson());
        final beforeClock = _jsonCopy(controller.storyClock.toJson());
        expect(controller.undoLastUserTurn()?.id, 'legacy');
        expect(controller.characterState.toJson(), beforeState);
        expect(controller.storyClock.toJson(), beforeClock);
      }
    },
  );

  test(
    'undo revokes only the turn award and never refunds a shop purchase',
    () async {
      final controller = await create();
      controller.relationshipPoints = 6000;
      controller.addUserMessage('想买一个纪念品');
      controller.addAssistantMessage('好好保管它哦。');
      final ring = ShopCatalog.byId(ShopCatalog.oathRingId)!;
      expect(controller.buyShopItem(ring.id), isTrue);
      expect(controller.relationshipPoints, 6001 - ring.price);
      controller.undoLastUserTurn();
      expect(controller.relationshipPoints, 6000 - ring.price);
      expect(controller.preciousItems[ring.id], 1);
      expect(controller.userMessageCount, 0);
    },
  );

  test(
    'undo retains the ring loss penalty and inventory while restoring time',
    () async {
      final controller = await create();
      seed(controller);
      controller.relationshipPoints = 10000;
      expect(controller.buyShopItem(ShopCatalog.oathRingId), isTrue);
      final beforeClock = _jsonCopy(controller.storyClock.toJson());
      controller.addUserMessage('休息后看看戒指');
      _settle(controller, 'before-ring-loss');
      final moodBeforeLoss = controller.characterState.values['mood']!;
      expect(
        controller.loseOathRing(expectedRevision: controller.dataRevision),
        isTrue,
      );
      final lossState = _jsonCopy(controller.characterState.toJson());
      expect(controller.characterState.values['mood'], moodBeforeLoss - 500);
      expect(controller.preciousItems[ShopCatalog.oathRingId], isNull);
      final withdrawn = controller.undoLastUserTurn()!;
      expect(withdrawn.turnSnapshot!.canRestoreCharacterState, isFalse);
      expect(controller.characterState.toJson(), lossState);
      expect(controller.characterState.oathRingLossPending, isTrue);
      expect(controller.characterState.reconciliationPurchaseBlocked, isTrue);
      expect(
        controller.canBuyShopItem(ShopCatalog.reconciliationVoucherId),
        isFalse,
      );
      expect(controller.preciousItems[ShopCatalog.oathRingId], isNull);
      expect(controller.storyClock.toJson(), beforeClock);
    },
  );

  test('consuming an item invalidates older state checkpoints and new turns capture it', () async {
    final controller = await create();
    seed(controller);
    controller.relationshipPoints = 6000;
    expect(controller.buyShopItem('ryza_gift'), isTrue);
    controller.addUserMessage('第一轮对话');
    _settle(controller, 'before-gift-1');
    controller.addUserMessage('第二轮对话');
    _settle(controller, 'before-gift-2');
    expect(
      controller.messages
          .where((m) => m.isUser)
          .every((m) => m.turnSnapshot!.canRestoreCharacterState),
      isTrue,
    );
    expect(controller.useShopItem('ryza_gift'), isTrue);
    final itemState = _jsonCopy(controller.characterState.toJson());
    expect(controller.preciousItems['ryza_gift'], isNull);
    expect(
      controller.messages
          .where((m) => m.isUser)
          .every((m) => !m.turnSnapshot!.canRestoreCharacterState),
      isTrue,
    );
    controller.undoLastUserTurn();
    expect(controller.characterState.toJson(), itemState);
    controller.undoLastUserTurn();
    expect(controller.characterState.toJson(), itemState);
    final afterItem = _runtime(controller);
    controller.addUserMessage('道具之后的新一轮');
    expect(
      controller.messages.last.turnSnapshot!.canRestoreCharacterState,
      isTrue,
    );
    _settle(controller, 'after-gift');
    controller.undoLastUserTurn();
    expect(_runtime(controller), afterItem);
  });

  test(
    'item-state checkpoint invalidation persists through restart and slot JSON',
    () async {
      final controller = await create();
      seed(controller);
      controller.preciousItems = {'ryza_gift': 1};
      controller.addUserMessage('道具效果应被保留');
      _settle(controller, 'persist-item');
      expect(controller.useShopItem('ryza_gift'), isTrue);
      final itemState = _jsonCopy(controller.characterState.toJson());
      await controller.saveToLocalSlot(0);
      final slot = controller.exportLocalSlot(0);
      final slotMessages = (slot['snapshot'] as Map)['messages'] as List;
      final user = slotMessages.cast<Map>().singleWhere(
        (m) => m['isUser'] == true,
      );
      expect(
        (user['turnSnapshot'] as Map)['canRestoreCharacterState'],
        isFalse,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final restored = await create();
      expect(
        restored.messages
            .lastWhere((m) => m.isUser)
            .turnSnapshot!
            .canRestoreCharacterState,
        isFalse,
      );
      await restored.loadFromLocalSlot(0);
      expect(
        restored.messages
            .lastWhere((m) => m.isUser)
            .turnSnapshot!
            .canRestoreCharacterState,
        isFalse,
      );
      restored.undoLastUserTurn();
      expect(restored.characterState.toJson(), itemState);
      expect(restored.preciousItems['ryza_gift'], isNull);
    },
  );

  test(
    'no user turn leaves state, time, counters, and revision untouched',
    () async {
      final controller = await create();
      seed(controller);
      final before = _runtime(controller);
      final revision = controller.dataRevision;
      expect(controller.undoLastUserTurn(), isNull);
      expect(_runtime(controller), before);
      expect(controller.dataRevision, revision);
    },
  );
}
