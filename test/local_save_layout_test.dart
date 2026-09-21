import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/local_save_dialog.dart';

void main() {
  testWidgets(
    'save actions and last slot remain accessible on narrow large-text screens',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final controller = (await tester.runAsync(() => AppController.load()))!;
      addTearDown(controller.dispose);
      await controller.saveToLocalSlot(0);
      await controller.renameLocalSlot(0, '很长的存档名称用于确认窄屏也能完整显示');
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showLocalSaveDialog(context, controller),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('读取'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('6'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(find.text('6').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
