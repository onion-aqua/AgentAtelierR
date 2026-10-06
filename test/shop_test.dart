import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('purchases spend points and item effects apply once', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    controller.relationshipPoints = 1000;
    expect(controller.buyShopItem('unknown'), isFalse);
    expect(controller.buyShopItem('ryza_gift'), isTrue);
    expect(controller.relationshipPoints, 950);
    expect(controller.preciousItems['ryza_gift'], 1);
    expect(controller.useShopItem('ryza_gift'), isTrue);
    expect(controller.characterState.values, {
      'mood': 10,
      'energy': 70,
      'closeness': 50,
      'curiosity': 55,
    });
    expect(controller.useShopItem('ryza_gift'), isFalse);
    expect(controller.buyShopItem('advanced_energy_tonic'), isTrue);
    expect(controller.relationshipPoints, 800);
    expect(controller.useShopItem('advanced_energy_tonic'), isTrue);
    expect(controller.characterState.values['mood'], 0);
    expect(controller.characterState.values['energy'], 100);
    expect(controller.characterState.values['closeness'], 20);
    controller.dispose();
  });

  test('voucher only consumes when a negative stat exists', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    controller.relationshipPoints = 500;
    expect(controller.buyShopItem('reconciliation_voucher'), isTrue);
    expect(controller.relationshipPoints, 300);
    expect(controller.useShopItem('reconciliation_voucher'), isFalse);
    expect(controller.preciousItems['reconciliation_voucher'], 1);
    controller.characterState = CharacterState(
      values: {'mood': -35, 'energy': 40, 'closeness': 10, 'curiosity': 20},
    );
    expect(controller.useShopItem('reconciliation_voucher'), isTrue);
    expect(controller.characterState.values['mood'], 0);
    expect(controller.characterState.values['energy'], 40);
    expect(controller.preciousItems, isEmpty);
    controller.dispose();
  });

  test(
    'phone purchase with fewer than 499 points has no side effects',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      controller.relationshipPoints = 498;
      controller.preciousItems = {'ryza_gift': 1};
      final stateBefore = Map<String, int>.from(
        controller.characterState.values,
      );
      expect(controller.buyShopItem('iphone_18_pro_max'), isFalse);
      expect(controller.relationshipPoints, 498);
      expect(controller.preciousItems, {'ryza_gift': 1});
      expect(controller.characterState.values, stateBefore);
      expect(controller.useShopItem('iphone_18_pro_max'), isFalse);
      expect(controller.characterState.values, stateBefore);
    },
  );

  for (final (initialMood, expectedMood) in [(-35, 65), (35, 100)]) {
    test(
      'phone costs 499 and applies mood once ($initialMood to $expectedMood)',
      () async {
        SharedPreferences.setMockInitialValues({});
        final controller = await AppController.load();
        addTearDown(controller.dispose);
        controller.relationshipPoints = 499;
        controller.characterState = CharacterState(
          values: {
            'mood': initialMood,
            'energy': 41,
            'closeness': 32,
            'curiosity': 79,
          },
        );
        final stateBefore = Map<String, int>.from(
          controller.characterState.values,
        );
        expect(controller.buyShopItem('iphone_18_pro_max'), isTrue);
        expect(controller.relationshipPoints, 0);
        expect(controller.preciousItems, {'iphone_18_pro_max': 1});
        expect(controller.characterState.values, stateBefore);
        expect(controller.useShopItem('iphone_18_pro_max'), isTrue);
        final expectedState = {
          'mood': expectedMood,
          'energy': 41,
          'closeness': 32,
          'curiosity': 79,
        };
        expect(controller.characterState.values, expectedState);
        expect(controller.preciousItems, isEmpty);
        expect(controller.relationshipPoints, 0);
        expect(controller.useShopItem('iphone_18_pro_max'), isFalse);
        expect(controller.characterState.values, expectedState);
        expect(controller.relationshipPoints, 0);
      },
    );
  }

  test(
    'precious inventory survives restart, slots and backup import',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      controller.relationshipPoints = 1000;
      expect(controller.buyShopItem('ryza_gift'), isTrue);
      expect(controller.buyShopItem('iphone_18_pro_max'), isTrue);
      await controller.saveToLocalSlot(0);
      expect(controller.buyShopItem('advanced_energy_tonic'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final restarted = await AppController.load();
      expect(restarted.preciousItems, {
        'ryza_gift': 1,
        'iphone_18_pro_max': 1,
        'advanced_energy_tonic': 1,
      });
      expect(restarted.relationshipPoints, 301);
      await restarted.loadFromLocalSlot(0);
      expect(restarted.preciousItems, {'ryza_gift': 1, 'iphone_18_pro_max': 1});
      expect(restarted.relationshipPoints, 451);
      final backup = jsonDecode(
        jsonEncode(restarted.exportData()),
      ) as Map<String, dynamic>;
      final imported = await AppController.load();
      await imported.importData(backup);
      expect(imported.preciousItems, {'ryza_gift': 1, 'iphone_18_pro_max': 1});
      expect(imported.relationshipPoints, 451);
      final invalid = Map<String, dynamic>.from(backup)
        ..['preciousItems'] = {'unknown': 3};
      await expectLater(imported.importData(invalid), throwsFormatException);
      expect(imported.preciousItems, {'ryza_gift': 1, 'iphone_18_pro_max': 1});
      expect(imported.relationshipPoints, 451);
      controller.dispose();
      restarted.dispose();
      imported.dispose();
    },
  );
}
