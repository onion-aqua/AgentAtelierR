import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/shop_screen.dart';
import 'package:ryza_chat_mvp/src/shop_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppController controller;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    controller = await AppController.load();
  });

  tearDownAll(() => controller.dispose());

  testWidgets('shop keeps two columns without overflow on narrow screens', (
    tester,
  ) async {
    for (final size in [const Size(320, 640), const Size(393, 852)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(home: ShopScreen(controller: controller)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      expect(
        find.text(ShopCatalog.items.first.name(controller.interfaceLanguage)),
        findsOneWidget,
      );
      expect(find.text('详情'), findsNothing);
      expect(find.text('购买'), findsWidgets);
      for (final item in ShopCatalog.items) {
        expect(
          find.text(item.effect(controller.interfaceLanguage)),
          findsNothing,
        );
        expect(
          find.text(item.description(controller.interfaceLanguage)),
          findsNothing,
        );
      }
      final button = find.widgetWithText(FilledButton, '购买').first;
      final row = find.ancestor(of: button, matching: find.byType(Row)).first;
      final price = find.descendant(
        of: row,
        matching: find.text('${ShopCatalog.items.first.price}'),
      );
      expect(price, findsOneWidget);
      expect(tester.getCenter(price).dx, lessThan(tester.getCenter(button).dx));

      await tester.tap(
        find.byKey(ValueKey('shop-item-image-${ShopCatalog.items.first.id}')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final dialog = find.byType(Dialog);
      final item = ShopCatalog.items.first;
      final title = find.descendant(
        of: dialog,
        matching: find.text(item.name(controller.interfaceLanguage)),
      );
      final image = find.descendant(
        of: dialog,
        matching: find.byKey(ValueKey('shop-item-preview-${item.id}')),
      );
      final description = find.descendant(
        of: dialog,
        matching: find.text(item.description(controller.interfaceLanguage)),
      );
      final effect = find.descendant(
        of: dialog,
        matching: find.text(item.effect(controller.interfaceLanguage)),
      );
      expect(title, findsOneWidget);
      expect(image, findsOneWidget);
      expect(description, findsOneWidget);
      expect(effect, findsOneWidget);
      expect(
        tester.getTopLeft(title).dy,
        lessThan(tester.getTopLeft(image).dy),
      );
      expect(
        tester.getTopLeft(image).dy,
        lessThan(tester.getTopLeft(description).dy),
      );
      expect(
        tester.getTopLeft(description).dy,
        lessThan(tester.getTopLeft(effect).dy),
      );
      await tester.ensureVisible(find.text('关闭'));
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
