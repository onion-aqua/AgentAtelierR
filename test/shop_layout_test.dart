import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/shop_screen.dart';
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
      expect(find.text('给莱莎的礼物'), findsOneWidget);
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
