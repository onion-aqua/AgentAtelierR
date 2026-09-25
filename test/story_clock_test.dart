import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/alchemy_models.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/story_clock.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('time proposal is bounded, crosses days, and settles once', () {
    final start = StoryClock(totalMinutes: 23 * 60 + 50, satiety: 40);
    final next = start.advance('turn-a', {
      'time_advance': {'kind': 'activity', 'minutes': 10},
    })!;
    expect(next.day, 2);
    expect(next.timeLabel, '00:00');
    expect(next.satiety, 36);
    expect(next.advance('turn-a', null), isNull);
    expect(
      next.advance('turn-b', {'time_advance': 'invalid'})!.totalMinutes,
      next.totalMinutes + 2,
    );
    expect(
      start.advance('turn-c', {
        'time_advance': {'kind': 'conversation', 'minutes': 99},
      })!.totalMinutes,
      start.totalMinutes + 6,
    );
    expect(StoryClock.fromJson(next.toJson()).settledTurns, contains('turn-a'));
    expect(
      start.advance('skip', {
        'time_advance': {'kind': 'time_skip', 'minutes': 360},
      })!.timeLabel,
      '05:50',
    );
  });

  test('story clock and satiety belong to each save slot', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    await controller.createLocalSlot(0, name: 'first');
    expect(controller.storyClockEnabled, isFalse);
    expect(controller.storyClock.day, 1);
    expect(controller.storyClock.timeLabel, '09:00');

    controller.setStoryClockEnabled(true);
    expect(controller.automaticSceneTime, isFalse);
    final revision = controller.dataRevision;
    expect(
      controller.settleStoryTime('a', {
        'time_advance': {'kind': 'sleep', 'minutes': 720},
      }, revision),
      isTrue,
    );
    expect(controller.storyClock.timeLabel, '21:00');
    expect(controller.storyClock.satiety, 32);
    expect(controller.settleStoryTime('a', null, revision), isFalse);
    await controller.saveToLocalSlot(0);

    await controller.createLocalSlot(1, name: 'second');
    expect(controller.storyClockEnabled, isFalse);
    expect(controller.storyClock.satiety, 80);
    await controller.loadFromLocalSlot(0);
    expect(controller.storyClockEnabled, isTrue);
    expect(controller.storyClock.timeLabel, '21:00');
    expect(controller.storyClock.satiety, 32);
    expect(
      controller.settleStoryTime('a', null, controller.dataRevision),
      isFalse,
    );
  });

  test('manual scene switching advances the story clock', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    controller.setStoryClockEnabled(true);
    controller.setSceneTime(SceneTime.afternoon);
    expect(controller.storyClock.timeLabel, '13:00');
    expect(controller.sceneTime, SceneTime.afternoon);
    controller.setAutomaticSceneTime(true);
    expect(controller.storyClockEnabled, isFalse);
  });

  test('low satiety drains energy on elapsed game hours', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    controller.storyClock = StoryClock(satiety: 4);
    controller.setStoryClockEnabled(true);
    expect(
      controller.settleStoryTime('hungry', {
        'time_advance': {'kind': 'activity', 'minutes': 90},
      }, controller.dataRevision),
      isTrue,
    );
    expect(controller.storyClock.satiety, 0);
    expect(controller.characterState.values['energy'], 63);
  });

  test('eating consumes only edible inventory and restores satiety', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    controller.setStoryClockEnabled(true);
    controller.setAgentEnabled(true);
    controller.alchemyState = AlchemyState(
      inventory: [
        AlchemyItem(
          instanceId: 'food',
          templateId: 'custom_food',
          customName: '面包',
          customCategories: const ['food'],
          quality: 50,
          quantity: 2,
          tagIds: const [],
          acquiredAt: DateTime(2026),
        ),
        AlchemyItem(
          instanceId: 'stone',
          templateId: 'custom_stone',
          customName: '石头',
          customCategories: const ['material'],
          quality: 50,
          quantity: 1,
          tagIds: const [],
          acquiredAt: DateTime(2026),
        ),
      ],
      history: const [],
    );
    final refused = jsonDecode(
      controller.queryContextTool('consume_inventory_item', {
        'instance_id': 'stone',
        'quantity': 1,
        'purpose': 'eat',
      }),
    ) as Map<String, dynamic>;
    expect(refused['ok'], isFalse);
    expect(controller.alchemyState.inventory.length, 2);
    final eaten = jsonDecode(
      controller.queryContextTool('consume_inventory_item', {
        'instance_id': 'food',
        'quantity': 1,
        'purpose': 'eat',
      }),
    ) as Map<String, dynamic>;
    expect(eaten['ok'], isTrue);
    expect(controller.storyClock.satiety, 100);
    expect(controller.alchemyState.inventory.first.quantity, 1);
  });

  test('legacy save without clock fields starts with clock disabled', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    controller.setStoryClockEnabled(true);
    await controller.saveToLocalSlot(0);
    final legacy = controller.exportLocalSlot(0);
    final snapshot = Map<String, dynamic>.from(legacy['snapshot'] as Map);
    snapshot.remove('storyClockEnabled');
    snapshot.remove('storyClock');
    legacy['snapshot'] = snapshot;
    await controller.importLocalSlot(1, legacy);
    await controller.loadFromLocalSlot(1);
    expect(controller.storyClockEnabled, isFalse);
    expect(controller.storyClock.timeLabel, '09:00');
  });
}
