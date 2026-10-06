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

  testWidgets('new phone product opens complete details on a small screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: ShopScreen(controller: controller, embedded: true),
      ),
    );
    await tester.pumpAndSettle();
    final item = ShopCatalog.byId('iphone_18_pro_max')!;
    final image = find.byKey(ValueKey('shop-item-image-${item.id}'));
    await tester.ensureVisible(image);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('${item.price}'), findsOneWidget);
    await tester.tap(image);
    await tester.pumpAndSettle();
    final dialog = find.byType(Dialog);
    expect(
      find.descendant(of: dialog, matching: find.text(item.nameZh)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text(item.descriptionZh)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text(item.effectZh)),
      findsOneWidget,
    );
    final preview = tester.widget<Image>(
      find.byKey(ValueKey('shop-item-preview-${item.id}')),
    );
    final provider = preview.image;
    final asset = provider is ResizeImage ? provider.imageProvider : provider;
    expect((asset as AssetImage).assetName, item.imageAsset);
    await tester.ensureVisible(find.text('关闭'));
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(tester.takeException(), isNull);
  });

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
