import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_state.dart';
import 'package:ryza_chat_mvp/src/shop_catalog.dart';
import 'package:ryza_chat_mvp/src/shop_screen.dart';
import 'package:ryza_chat_mvp/src/alchemy_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const ring = ShopCatalog.oathRingId;
  const voucher = ShopCatalog.reconciliationVoucherId;

  Future<AppController> controllerWithRing() async {
    final controller = await AppController.load();
    addTearDown(controller.dispose);
    controller.relationshipPoints = 20000;
    expect(controller.buyShopItem(ring), isTrue);
    return controller;
  }

  test(
    '4999 points buys a keepsake; insufficient funds cannot mutate it',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      controller.relationshipPoints = 4998;
      expect(controller.buyShopItem(ring), isFalse);
      expect(controller.preciousItems, isEmpty);
      expect(controller.relationshipPoints, 4998);
      controller.relationshipPoints = 4999;
      expect(controller.buyShopItem(ring), isTrue);
      expect(controller.relationshipPoints, 0);
      expect(controller.preciousItems[ring], 1);
      expect(controller.useShopItem(ring), isFalse);
      expect(controller.preciousItems[ring], 1);
      expect(controller.characterState.values['mood'], 0);
    },
  );

  test(
    'loss subtracts exactly 500 once and rejects stale save dialogs',
    () async {
      final controller = await controllerWithRing();
      expect(
        controller.loseOathRing(expectedRevision: controller.dataRevision + 1),
        isFalse,
      );
      expect(controller.preciousItems[ring], 1);
      expect(
        controller.loseOathRing(expectedRevision: controller.dataRevision),
        isTrue,
      );
      expect(controller.characterState.values['mood'], -500);
      expect(controller.characterState.delta['mood'], -500);
      expect(controller.preciousItems, isEmpty);
      expect(
        controller.loseOathRing(expectedRevision: controller.dataRevision),
        isFalse,
      );
      expect(controller.characterState.values['mood'], -500);
      final points = controller.relationshipPoints;
      expect(controller.canBuyShopItem(voucher), isFalse);
      expect(controller.buyShopItem(voucher), isFalse);
      expect(controller.relationshipPoints, points);
      expect(controller.canBuyShopItem('ryza_gift'), isTrue);
    },
  );

  test(
    'chat, gifts, unrelated recovery and tonic cannot erase low mood',
    () async {
      final controller = await controllerWithRing();
      controller.loseOathRing(expectedRevision: controller.dataRevision);
      controller.settleCharacterState('hello', {
        'state_delta': {'mood': 5},
        'reason': '安慰',
      }, controller.dataRevision);
      expect(controller.characterState.values['mood'], -495);
      controller.buyShopItem('ryza_gift');
      controller.useShopItem('ryza_gift');
      expect(controller.characterState.values['mood'], -485);
      controller.buyShopItem('advanced_energy_tonic');
      controller.useShopItem('advanced_energy_tonic');
      expect(controller.characterState.values['mood'], -485);
      final rested = controller.characterState.recoverAfterTime(
        'rest',
        'sleep',
        180,
      );
      expect(rested.values['mood'], -485);
      expect(rested.reconciliationPurchaseBlocked, isTrue);
      expect(CharacterState.fromJson(rested.toJson()).values['mood'], -485);
    },
  );

  for (final mood in [-251, -250, -249]) {
    test(
      'purchase threshold is live at $mood, stale flag cannot block recovery',
      () async {
        final controller = await controllerWithRing();
        controller.characterState = CharacterState.fromJson({
          'values': {'mood': mood},
          'oathRingLossPending': true,
        });
        expect(controller.canBuyShopItem(voucher), mood >= -250);
        expect(controller.buyShopItem(voucher), mood >= -250);
        expect(controller.characterState.oathRingLossPending, mood < -250);
      },
    );
  }

  test(
    'unlock is permanent until another loss and rebuying does not unlock',
    () async {
      final controller = await controllerWithRing();
      controller.loseOathRing(expectedRevision: controller.dataRevision);
      controller.buyShopItem(ring);
      expect(controller.canBuyShopItem(voucher), isFalse);
      for (var i = 0; i < 50; i++) {
        controller.settleCharacterState('comfort-$i', {
          'state_delta': {'mood': 5},
          'reason': '慢慢恢复',
        }, controller.dataRevision);
      }
      expect(controller.characterState.values['mood'], -250);
      expect(controller.canBuyShopItem(voucher), isTrue);
      controller.settleCharacterState('sad', {
        'state_delta': {'mood': -5},
        'reason': '小事失落',
      }, controller.dataRevision);
      expect(controller.characterState.values['mood'], -255);
      expect(controller.canBuyShopItem(voucher), isTrue);
      controller.loseOathRing(expectedRevision: controller.dataRevision);
      expect(controller.characterState.values['mood'], -755);
      expect(controller.canBuyShopItem(voucher), isFalse);
    },
  );

  test(
    'loss state survives restart, slots and backup; old saves default unlocked',
    () async {
      final controller = await controllerWithRing();
      await controller.saveToLocalSlot(0);
      controller.loseOathRing(expectedRevision: controller.dataRevision);
      await controller.saveToLocalSlot(1);
      final backup = jsonDecode(
        jsonEncode(controller.exportData()),
      ) as Map<String, dynamic>;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final restored = await AppController.load();
      addTearDown(restored.dispose);
      expect(restored.characterState.values['mood'], -500);
      expect(restored.canBuyShopItem(voucher), isFalse);
      await restored.loadFromLocalSlot(0);
      expect(restored.preciousItems[ring], 1);
      expect(restored.canBuyShopItem(voucher), isTrue);
      await restored.loadFromLocalSlot(1);
      expect(restored.characterState.values['mood'], -500);
      expect(restored.canBuyShopItem(voucher), isFalse);
      await restored.importData(backup);
      expect(restored.characterState.values['mood'], -500);
      expect(restored.canBuyShopItem(voucher), isFalse);
      expect(
        CharacterState.fromJson({
          'values': {'mood': -100},
        }).reconciliationPurchaseBlocked,
        isFalse,
      );
    },
  );

  testWidgets('open shop unlocks button immediately without reopening', (
    tester,
  ) async {
    final controller = await controllerWithRing();
    controller.characterState = CharacterState(
      values: {'mood': -251},
      oathRingLossPending: true,
    );
    await tester.pumpWidget(
      MaterialApp(home: ShopScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    final button = find.byKey(
      const ValueKey('shop-buy-reconciliation_voucher'),
    );
    await tester.scrollUntilVisible(button, 150);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    controller.settleCharacterState('recover', {
      'state_delta': {'mood': 1},
      'reason': '恢复',
    }, controller.dataRevision);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    expect(
      find.byKey(const ValueKey('shop-voucher-lock-reason')),
      findsNothing,
    );
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(controller.preciousItems[voucher], 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inventory loss requires confirmation; cancel preserves ring', (
    tester,
  ) async {
    final controller = await controllerWithRing();
    await tester.pumpWidget(
      MaterialApp(home: AlchemyScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    final action = find.byKey(const ValueKey('precious-item-action-oath_ring'));
    await tester.tap(action);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.preciousItems[ring], 1);
    expect(controller.characterState.values['mood'], 0);
    await tester.tap(action);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-lose-oath-ring')));
    await tester.pumpAndSettle();
    expect(controller.preciousItems[ring], isNull);
    expect(controller.characterState.values['mood'], -500);
    expect(tester.takeException(), isNull);
  });
}
