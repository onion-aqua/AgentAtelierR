import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/alchemy_models.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';

class FixedRandom implements Random {
  FixedRandom(this.roll);
  final double roll;
  @override
  double nextDouble() => roll;
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppController controller;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    controller = await AppController.load();
    controller.alchemyState = AlchemyState(
      inventory: [
        AlchemyItem(
          instanceId: 'material',
          templateId: 'uni',
          quality: 50,
          quantity: 3,
          tagIds: const [],
          acquiredAt: DateTime(2026),
        ),
      ],
      history: const [],
    );
  });
  tearDown(() => controller.dispose());

  test(
    'both success and failure consume exact repeated material counts',
    () async {
      for (final success in [true, false]) {
        final item = controller.alchemyState.inventory.first;
        controller.alchemyState = AlchemyState(
          inventory: [item.copyWith(quantity: 3)],
          history: const [],
        );
        final previousCount = controller.synthesisCount;
        final result = controller.synthesizeCustomItem(
          name: 'Test',
          description: 'Fantasy item',
          ingredientIds: ['material', 'material'],
          random: FixedRandom(success ? 0 : .999),
        );
        expect(controller.alchemyState.inventory.first.quantity, 1);
        expect(
          result.templateId,
          success ? 'custom_product' : 'custom_failed_product',
        );
        expect(controller.synthesisCount, previousCount + (success ? 1 : 0));
        expect(
          controller.alchemyState.history.single.recipeId,
          success ? 'custom' : 'custom_failed',
        );
        await Future<void>.delayed(Duration.zero);
        final restored = await AppController.load();
        expect(restored.alchemyState.inventory.first.quantity, 1);
        expect(
          restored.alchemyState.history.single.result.templateId,
          result.templateId,
        );
        restored.dispose();
      }
    },
  );

  test(
    'invalid synthesis and excessive consumption never change inventory',
    () {
      final original = jsonEncode(controller.alchemyState.toJson());
      expect(
        () => controller.synthesizeCustomItem(
          name: 'Test',
          description: 'Test',
          ingredientIds: List.filled(4, 'material'),
        ),
        throwsFormatException,
      );
      expect(
        () => controller.consumeAlchemyItem('material', quantity: 4),
        throwsFormatException,
      );
      expect(
        () => controller.consumeAlchemyItem('material', quantity: 0),
        throwsFormatException,
      );
      expect(jsonEncode(controller.alchemyState.toJson()), original);
    },
  );

  test(
    'using an item persists depletion and rejects an already empty stack',
    () async {
      controller.consumeAlchemyItem('material', quantity: 3);
      expect(controller.alchemyState.inventory, isEmpty);
      expect(
        () => controller.consumeAlchemyItem('material'),
        throwsFormatException,
      );
      await Future<void>.delayed(Duration.zero);
      final restored = await AppController.load();
      expect(restored.alchemyState.inventory, isEmpty);
      restored.dispose();
    },
  );

  test('quality and catalyst improve chance without guaranteed success', () {
    final item = controller.alchemyState.inventory.first;
    const engine = AlchemyEngine();
    expect(engine.successChance([item]), closeTo(.75, .00001));
    expect(engine.successChance([item], catalyst: item), closeTo(.83, .00001));
  });
}
