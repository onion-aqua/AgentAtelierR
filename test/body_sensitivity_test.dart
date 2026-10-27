import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/body_sensitivity.dart';
import 'package:ryza_chat_mvp/src/character_runtime_profile.dart';
import 'package:ryza_chat_mvp/src/conversation_turn_snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory support;

  setUpAll(() async {
    support = await Directory.systemTemp.createTemp('body-sensitivity-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? support.path
              : null,
        );
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await support.delete(recursive: true);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppController> create() async {
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    return controller;
  }

  test('nine bounded values preserve eight unlocked parts and round-trip', () {
    final original = <BodySensitivityPart, int>{BodySensitivityPart.head: 24};
    final state = BodySensitivityState(values: original);
    original[BodySensitivityPart.head] = 99;
    expect(state.valueFor(BodySensitivityPart.head), 24);
    expect(state.valueFor(BodySensitivityPart.legs), 50);
    expect(state.values, hasLength(9));
    expect(state.unlocked, hasLength(8));
    expect(state.isUnlocked(BodySensitivityPart.intimate), isFalse);
    expect(state.valueFor(BodySensitivityPart.intimate), 50);
    expect(
      () => state.values[BodySensitivityPart.head] = 1,
      throwsUnsupportedError,
    );
    expect(
      () => state.unlocked.add(BodySensitivityPart.intimate),
      throwsUnsupportedError,
    );
    final unlockedSource = {BodySensitivityPart.head};
    final copied = BodySensitivityState(unlocked: unlockedSource);
    unlockedSource.add(BodySensitivityPart.intimate);
    expect(copied.isUnlocked(BodySensitivityPart.intimate), isFalse);
    expect(
      BodySensitivityState.fromJson(state.toJson()).toJson(),
      state.toJson(),
    );
    expect(
      () => state.withValue(BodySensitivityPart.head, -1),
      throwsRangeError,
    );
    expect(
      () => state.withValue(BodySensitivityPart.head, 101),
      throwsRangeError,
    );
    expect(BodySensitivityState.fromJson(null).values.values, everyElement(50));
  });

  test('malformed and future sensitivity data is rejected', () {
    final valid = BodySensitivityState().toJson();
    for (final bad in <Object?>[
      [],
      'wrong',
      {...valid, 'version': 3},
      {...valid, 'unlocked': null},
      {
        ...valid,
        'unlocked': ['unknown'],
      },
      {
        ...valid,
        'unlocked': ['head', 'head'],
      },
      {
        ...valid,
        'unlocked': [1],
      },
      {
        ...valid,
        'values': {'head': 50},
      },
      {
        ...valid,
        'values': {...valid['values'] as Map, 'head': 101},
      },
      {
        ...valid,
        'values': {...valid['values'] as Map, 'chest': true},
      },
      {
        ...valid,
        'values': {...valid['values'] as Map, 'head': 49.5},
      },
    ]) {
      expect(() => BodySensitivityState.fromJson(bad), throwsFormatException);
    }
  });

  test('version one migrates values without inventing an intimate unlock', () {
    final legacy = {
      'version': 1,
      'values': {
        for (final part in BodySensitivityState.initiallyUnlocked)
          part.name: part == BodySensitivityPart.head ? 81 : 24,
      },
    };
    final migrated = BodySensitivityState.fromJson(legacy);
    expect(migrated.valueFor(BodySensitivityPart.head), 81);
    expect(migrated.valueFor(BodySensitivityPart.legs), 24);
    expect(migrated.isUnlocked(BodySensitivityPart.intimate), isFalse);
    expect(migrated.unlocked, BodySensitivityState.initiallyUnlocked);
    expect(migrated.toJson()['version'], 2);
    expect(
      () => migrated.withValue(BodySensitivityPart.intimate, 99),
      throwsStateError,
    );
    expect(
      migrated
          .unlock(BodySensitivityPart.intimate)
          .withValue(BodySensitivityPart.intimate, 79)
          .valueFor(BodySensitivityPart.intimate),
      79,
    );
    expect(migrated.isUnlocked(BodySensitivityPart.intimate), isFalse);
  });

  test(
    'only deliberate touch or explicit action unlocks the new part',
    () async {
      final controller = await create();
      expect(
        controller.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
        isFalse,
      );
      expect(controller.recordBodySensitivityTouch('intimate'), isFalse);
      controller.setBodySensitivity(BodySensitivityPart.intimate, 95);
      expect(
        controller.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
        isFalse,
      );
      expect(
        controller.bodySensitivity.valueFor(BodySensitivityPart.intimate),
        50,
      );
      expect(
        controller.recordBodySensitivityTouch('intimate', deliberate: true),
        isTrue,
      );
      expect(
        controller.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
        isTrue,
      );
      expect(
        controller.bodySensitivity.valueFor(BodySensitivityPart.intimate),
        51,
      );
      expect(
        controller.recordBodySensitivityTouch('intimate', deliberate: true),
        isFalse,
      );
      expect(
        controller.unlockBodySensitivity(BodySensitivityPart.intimate),
        isFalse,
      );
      controller.setBodySensitivity(BodySensitivityPart.intimate, 100);
      expect(
        controller.recordBodySensitivityTouch('intimate', deliberate: true),
        isFalse,
      );
      expect(
        controller.bodySensitivity.valueFor(BodySensitivityPart.intimate),
        100,
      );
    },
  );

  test('deliberate unlock works while automatic growth is disabled', () async {
    final controller = await create();
    controller.setBodySensitivityTouchEnabled(false);
    expect(controller.recordBodySensitivityTouch('intimate'), isFalse);
    expect(
      controller.recordBodySensitivityTouch('intimate', deliberate: true),
      isTrue,
    );
    expect(
      controller.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
      isTrue,
    );
    expect(
      controller.bodySensitivity.valueFor(BodySensitivityPart.intimate),
      50,
    );
    controller.setBodySensitivity(BodySensitivityPart.intimate, 62);
    expect(
      controller.bodySensitivity.valueFor(BodySensitivityPart.intimate),
      62,
    );
    expect(
      controller.recordBodySensitivityTouch('intimate', deliberate: true),
      isFalse,
    );
  });

  test(
    'explicit unlock is saved and cannot be erased by an earlier turn undo',
    () async {
      final controller = await create();
      controller.addUserMessage('before unlocking');
      expect(
        controller.messages.last.turnSnapshot!.bodySensitivity!.isUnlocked(
          BodySensitivityPart.intimate,
        ),
        isFalse,
      );
      expect(
        controller.unlockBodySensitivity(BodySensitivityPart.intimate),
        isTrue,
      );
      expect(
        controller.messages.last.turnSnapshot!.canRestoreBodySensitivity,
        isFalse,
      );
      controller.undoLastUserTurn();
      expect(
        controller.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
        isTrue,
      );
      controller.addUserMessage('after unlocking');
      final snapshot = ConversationTurnSnapshot.tryFromJson(
        controller.messages.last.turnSnapshot!.toJson(),
      );
      expect(
        snapshot!.bodySensitivity!.isUnlocked(BodySensitivityPart.intimate),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final restored = await create();
      expect(
        restored.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
        isTrue,
      );
    },
  );

  test(
    'manual editing changes only one part and rejects invalid writes',
    () async {
      final controller = await create();
      controller.setBodySensitivity(BodySensitivityPart.waist, 0);
      controller.setBodySensitivity(BodySensitivityPart.hands, 100);
      expect(controller.bodySensitivity.valueFor(BodySensitivityPart.waist), 0);
      expect(
        controller.bodySensitivity.valueFor(BodySensitivityPart.hands),
        100,
      );
      expect(controller.bodySensitivity.valueFor(BodySensitivityPart.head), 50);
      final before = controller.bodySensitivity.toJson();
      expect(
        () => controller.setBodySensitivity(BodySensitivityPart.head, 101),
        throwsRangeError,
      );
      expect(controller.bodySensitivity.toJson(), before);
      expect(
        controller.characterState.values.keys,
        unorderedEquals(['mood', 'energy', 'closeness', 'curiosity']),
      );
    },
  );

  test(
    'touch changes can be disabled and debounce only the hit part',
    () async {
      final controller = await create();
      expect(controller.bodySensitivityTouchEnabled, isTrue);
      controller.setBodySensitivityTouchEnabled(false);
      expect(controller.recordBodySensitivityTouch('head'), isFalse);
      controller.setBodySensitivityTouchEnabled(true);
      expect(controller.recordBodySensitivityTouch('head'), isTrue);
      expect(controller.recordBodySensitivityTouch('head'), isFalse);
      expect(controller.recordBodySensitivityTouch('arm_l'), isTrue);
      expect(controller.recordBodySensitivityTouch('not-a-hit'), isFalse);
      expect(controller.bodySensitivity.valueFor(BodySensitivityPart.head), 51);
      expect(
        controller.bodySensitivity.valueFor(BodySensitivityPart.leftArm),
        51,
      );
      expect(
        controller.bodySensitivity.valueFor(BodySensitivityPart.rightArm),
        50,
      );
      controller.setBodySensitivity(BodySensitivityPart.chest, 100);
      expect(controller.recordBodySensitivityTouch('breast'), isFalse);
      expect(controller.recordBodySensitivityTouch('weast'), isTrue);
      expect(
        controller.bodySensitivity.valueFor(BodySensitivityPart.waist),
        51,
      );
      controller.setBodySensitivityTouchEnabled(false);
      expect(controller.recordBodySensitivityTouch('body'), isFalse);
    },
  );

  test(
    'values and mode survive restart without copying the runtime cooldown',
    () async {
      final first = await create();
      first.setBodySensitivity(BodySensitivityPart.abdomen, 77);
      first.unlockBodySensitivity(BodySensitivityPart.intimate);
      first.setBodySensitivity(BodySensitivityPart.intimate, 74);
      first.setBodySensitivityTouchEnabled(true);
      expect(first.recordBodySensitivityTouch('head'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final restored = await create();
      expect(
        restored.bodySensitivity.valueFor(BodySensitivityPart.abdomen),
        77,
      );
      expect(restored.bodySensitivity.valueFor(BodySensitivityPart.head), 51);
      expect(restored.bodySensitivityTouchEnabled, isTrue);
      expect(
        restored.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
        isTrue,
      );
      expect(
        restored.bodySensitivity.valueFor(BodySensitivityPart.intimate),
        74,
      );
      expect(restored.recordBodySensitivityTouch('head'), isTrue);
    },
  );

  test(
    'each save restores its values and a new save gets fresh defaults',
    () async {
      final controller = await create();
      controller.setBodySensitivity(BodySensitivityPart.head, 80);
      controller.unlockBodySensitivity(BodySensitivityPart.intimate);
      controller.setBodySensitivity(BodySensitivityPart.intimate, 69);
      controller.setBodySensitivityTouchEnabled(true);
      await controller.saveToLocalSlot(0, name: 'first');
      await controller.createLocalSlot(1, name: 'new');
      expect(controller.bodySensitivity.values.values, everyElement(50));
      expect(controller.bodySensitivityTouchEnabled, isTrue);
      expect(
        controller.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
        isFalse,
      );
      controller.setBodySensitivityTouchEnabled(false);
      controller.setBodySensitivity(BodySensitivityPart.head, 25);
      await controller.saveToLocalSlot(1);
      await controller.loadFromLocalSlot(0);
      expect(controller.bodySensitivity.valueFor(BodySensitivityPart.head), 80);
      expect(
        controller.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
        isTrue,
      );
      expect(
        controller.bodySensitivity.valueFor(BodySensitivityPart.intimate),
        69,
      );
      expect(controller.bodySensitivityTouchEnabled, isTrue);
      expect(controller.recordBodySensitivityTouch('head'), isTrue);
      await controller.loadFromLocalSlot(1);
      expect(controller.bodySensitivity.valueFor(BodySensitivityPart.head), 25);
      expect(
        controller.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
        isFalse,
      );
      expect(controller.bodySensitivityTouchEnabled, isFalse);
      await controller.loadFromLocalSlot(0);
      expect(controller.recordBodySensitivityTouch('head'), isTrue);
    },
  );

  test(
    'portable and slot exports include sensitivity and old imports default',
    () async {
      final controller = await create();
      controller.setBodySensitivity(BodySensitivityPart.legs, 91);
      controller.unlockBodySensitivity(BodySensitivityPart.intimate);
      controller.setBodySensitivity(BodySensitivityPart.intimate, 73);
      controller.setBodySensitivityTouchEnabled(true);
      await controller.saveToLocalSlot(0);
      final portable = _copy(controller.exportData());
      final slot = _copy(controller.exportLocalSlot(0));
      final imported = await create();
      await imported.importData(portable);
      expect(imported.bodySensitivity.valueFor(BodySensitivityPart.legs), 91);
      expect(
        imported.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
        isTrue,
      );
      expect(
        imported.bodySensitivity.valueFor(BodySensitivityPart.intimate),
        73,
      );
      expect(imported.bodySensitivityTouchEnabled, isTrue);
      await imported.importLocalSlot(2, slot);
      imported.setBodySensitivity(BodySensitivityPart.legs, 5);
      await imported.loadFromLocalSlot(2);
      expect(imported.bodySensitivity.valueFor(BodySensitivityPart.legs), 91);
      expect(
        imported.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
        isTrue,
      );
      portable.remove('bodySensitivity');
      portable.remove('bodySensitivityTouchEnabled');
      await imported.importData(portable);
      expect(imported.bodySensitivity.values.values, everyElement(50));
      expect(
        imported.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
        isFalse,
      );
      expect(imported.bodySensitivityTouchEnabled, isTrue);
      (slot['snapshot'] as Map).remove('bodySensitivity');
      (slot['snapshot'] as Map).remove('bodySensitivityTouchEnabled');
      await imported.importLocalSlot(3, slot);
      await imported.loadFromLocalSlot(3);
      expect(imported.bodySensitivity.values.values, everyElement(50));
    },
  );

  test(
    'failed imports do not partially replace live state or a slot',
    () async {
      final controller = await create();
      controller.setBodySensitivity(BodySensitivityPart.head, 87);
      controller.addUserMessage('keep this conversation');
      await controller.saveToLocalSlot(0);
      final before = controller.bodySensitivity.toJson();
      final slot = _copy(controller.exportLocalSlot(0));
      final malformed = _copy(controller.exportData());
      (malformed['bodySensitivity']['values'] as Map)['head'] = -10;
      malformed['messages'] = [];
      await expectLater(
        controller.importData(malformed),
        throwsFormatException,
      );
      expect(controller.bodySensitivity.toJson(), before);
      expect(controller.messages.last.text, 'keep this conversation');
      (slot['snapshot'] as Map)['bodySensitivityTouchEnabled'] = 'yes';
      await expectLater(
        controller.importLocalSlot(0, slot),
        throwsFormatException,
      );
      expect(
        (controller.exportLocalSlot(0)['snapshot'] as Map)['bodySensitivity'],
        before,
      );
    },
  );

  test('characters keep separate values including after restart', () async {
    final controller = await create();
    controller.setBodySensitivity(BodySensitivityPart.head, 17);
    controller.unlockBodySensitivity(BodySensitivityPart.intimate);
    controller.setBodySensitivity(BodySensitivityPart.intimate, 68);
    controller.setBodySensitivityTouchEnabled(false);
    await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
    expect(controller.bodySensitivity.values.values, everyElement(50));
    expect(
      controller.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
      isFalse,
    );
    controller.setBodySensitivity(BodySensitivityPart.head, 83);
    controller.setBodySensitivityTouchEnabled(true);
    await controller.setActiveCharacter(CharacterRuntimeIds.ryza);
    expect(controller.bodySensitivity.valueFor(BodySensitivityPart.head), 17);
    expect(
      controller.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
      isTrue,
    );
    expect(
      controller.bodySensitivity.valueFor(BodySensitivityPart.intimate),
      68,
    );
    expect(controller.bodySensitivityTouchEnabled, isFalse);
    await controller.setActiveCharacter(CharacterRuntimeIds.sophie);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final restored = await create();
    expect(restored.activeCharacterId, CharacterRuntimeIds.sophie);
    expect(restored.bodySensitivity.valueFor(BodySensitivityPart.head), 83);
    expect(
      restored.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
      isFalse,
    );
    expect(restored.bodySensitivityTouchEnabled, isTrue);
    await restored.setActiveCharacter(CharacterRuntimeIds.ryza);
    expect(restored.bodySensitivity.valueFor(BodySensitivityPart.head), 17);
    expect(
      restored.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
      isTrue,
    );
  });

  test('clear history preserves sensitivity until full state reset', () async {
    final controller = await create();
    controller.setBodySensitivity(BodySensitivityPart.head, 70);
    controller.unlockBodySensitivity(BodySensitivityPart.intimate);
    controller.setBodySensitivityTouchEnabled(true);
    controller.clearChatHistory();
    expect(controller.bodySensitivity.valueFor(BodySensitivityPart.head), 70);
    expect(controller.bodySensitivityTouchEnabled, isTrue);
    expect(
      controller.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
      isTrue,
    );
    controller.clearChatHistory(clearLongTermMemory: true);
    expect(controller.bodySensitivity.values.values, everyElement(50));
    expect(
      controller.bodySensitivity.isUnlocked(BodySensitivityPart.intimate),
      isFalse,
    );
    expect(controller.bodySensitivityTouchEnabled, isTrue);
  });

  test(
    'undo checkpoint round-trips sensitivity without erasing direct edits',
    () async {
      final controller = await create();
      controller.setBodySensitivity(BodySensitivityPart.head, 10);
      controller.addUserMessage('turn with sensitivity checkpoint');
      final checkpoint = controller.messages.last.turnSnapshot!;
      expect(
        checkpoint.bodySensitivity!.valueFor(BodySensitivityPart.head),
        10,
      );
      expect(
        ConversationTurnSnapshot.tryFromJson(checkpoint.toJson())!
            .bodySensitivity!
            .toJson(),
        checkpoint.bodySensitivity!.toJson(),
      );
      controller.setBodySensitivity(BodySensitivityPart.head, 20);
      expect(
        controller.messages.last.turnSnapshot!.canRestoreBodySensitivity,
        isFalse,
      );
      controller.undoLastUserTurn();
      expect(controller.bodySensitivity.valueFor(BodySensitivityPart.head), 20);

      controller.addUserMessage('new checkpoint');
      final snapshot = controller.messages.last.turnSnapshot!;
      expect(snapshot.bodySensitivity!.valueFor(BodySensitivityPart.head), 20);
      expect(snapshot.canRestoreBodySensitivity, isTrue);
      final message = controller.messages.last;
      controller.setBodySensitivity(BodySensitivityPart.head, 75);
      controller.messages = [
        message,
      ]; // Simulate a saved turn with its valid pre-turn checkpoint.
      controller.undoLastUserTurn();
      expect(controller.bodySensitivity.valueFor(BodySensitivityPart.head), 20);
    },
  );

  test(
    'legacy undo checkpoint does not invent a default sensitivity history',
    () async {
      final controller = await create();
      controller.addUserMessage('legacy turn');
      final message = controller.messages.last.toJson();
      final rawSnapshot = message['turnSnapshot'] as Map;
      rawSnapshot.remove('bodySensitivity');
      rawSnapshot.remove('canRestoreBodySensitivity');
      final legacy = ChatMessage.fromJson(message);
      expect(legacy.turnSnapshot!.bodySensitivity, isNull);
      controller.setBodySensitivity(BodySensitivityPart.head, 88);
      controller.messages = [legacy];
      controller.undoLastUserTurn();
      expect(controller.bodySensitivity.valueFor(BodySensitivityPart.head), 88);
    },
  );

  test(
    'valid explicit opt-out survives corrupt persisted sensitivity',
    () async {
      SharedPreferences.setMockInitialValues({
        'body_sensitivity_v1.ryza': 'broken',
        'body_sensitivity_touch_enabled_v1.ryza': false,
      });
      final controller = await create();
      expect(controller.bodySensitivity.values.values, everyElement(50));
      expect(controller.bodySensitivityTouchEnabled, isFalse);
      expect(controller.recordBodySensitivityTouch('head'), isFalse);
    },
  );

  test(
    'corrupt persisted sensitivity falls back without blocking startup',
    () async {
      SharedPreferences.setMockInitialValues({
        'body_sensitivity_v1.ryza': 'broken',
      });
      final controller = await create();
      expect(controller.bodySensitivity.values.values, everyElement(50));
      expect(controller.bodySensitivityTouchEnabled, isTrue);
    },
  );
}
