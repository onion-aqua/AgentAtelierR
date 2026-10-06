import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/local_save_dialog.dart';

class _RouteObserver extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
  }
}

Future<_RouteObserver> _mountPhonePage(
  WidgetTester tester,
  AppController controller,
) async {
  final rootObserver = _RouteObserver();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      navigatorObservers: [rootObserver],
      home: Scaffold(
        body: Center(
          child: SizedBox(
            key: const ValueKey('phone-bounds'),
            width: 300,
            height: 480,
            child: ClipRect(
              child: Navigator(
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => LocalSavePage(controller: controller),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return rootObserver;
}

Future<void> _slotAction(WidgetTester tester, int index, String action) async {
  final menu = find.byKey(ValueKey('local-save-manage-$index'));
  await tester.ensureVisible(menu);
  await tester.tap(menu);
  await tester.pumpAndSettle();
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
}

void _expectDialogInsidePhone(WidgetTester tester) {
  final phone = tester.getRect(find.byKey(const ValueKey('phone-bounds')));
  final dialog = tester.getRect(find.byType(AlertDialog));
  expect(dialog.left, greaterThanOrEqualTo(phone.left));
  expect(dialog.top, greaterThanOrEqualTo(phone.top));
  expect(dialog.right, lessThanOrEqualTo(phone.right));
  expect(dialog.bottom, lessThanOrEqualTo(phone.bottom));
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('embedded saves create, rename and delete within the phone', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = (await tester.runAsync(() => AppController.load()))!;
    addTearDown(controller.dispose);
    final rootObserver = await _mountPhonePage(tester, controller);

    expect(find.byType(Dialog), findsNothing);
    await tester.tap(find.byKey(const ValueKey('local-save-create')));
    await tester.pumpAndSettle();
    _expectDialogInsidePhone(tester);
    await tester.enterText(find.byType(TextField), '手机存档');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(controller.localSaveSlots.first?.name, '手机存档');
    expect(controller.activeLocalSaveSlot, 0);
    expect(find.byType(LocalSavePage), findsOneWidget);

    await _slotAction(tester, 0, '重命名');
    _expectDialogInsidePhone(tester);
    await tester.enterText(find.byType(TextField), '新存档名称');
    await tester.tap(find.widgetWithText(TextButton, '保存').hitTestable());
    await tester.pumpAndSettle();
    expect(controller.localSaveSlots.first?.name, '新存档名称');
    expect(find.text('新存档名称'), findsOneWidget);

    await _slotAction(tester, 0, '删除');
    _expectDialogInsidePhone(tester);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(controller.localSaveSlots.first, isNull);
    expect(find.byType(LocalSavePage), findsOneWidget);
    expect(rootObserver.pushes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('embedded saves load and overwrite without closing the phone', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = (await tester.runAsync(() => AppController.load()))!;
    addTearDown(controller.dispose);
    controller.addUserMessage('槽位一的内容');
    await controller.saveToLocalSlot(0, name: '存档一');
    controller.addUserMessage('槽位二的内容');
    await controller.saveToLocalSlot(1, name: '存档二');
    final rootObserver = await _mountPhonePage(tester, controller);

    await tester.tap(find.byKey(const ValueKey('local-save-load-0')));
    await tester.pumpAndSettle();
    _expectDialogInsidePhone(tester);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(controller.activeLocalSaveSlot, 0);
    expect(controller.messages.last.text, '槽位一的内容');
    expect(find.byType(LocalSavePage), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);

    controller.addUserMessage('更新内容');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('local-save-write-0')));
    await tester.pumpAndSettle();
    _expectDialogInsidePhone(tester);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(controller.localSaveSlots.first?.preview, '更新内容');
    expect(find.byType(LocalSavePage), findsOneWidget);
    expect(rootObserver.pushes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('embedded export keeps history choice in the phone navigator', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = (await tester.runAsync(() => AppController.load()))!;
    addTearDown(controller.dispose);
    await controller.saveToLocalSlot(0);
    final rootObserver = await _mountPhonePage(tester, controller);

    await _slotAction(tester, 0, '导出');
    _expectDialogInsidePhone(tester);
    expect(find.text('是否包含历史对话？'), findsOneWidget);
    expect(find.text('包含'), findsOneWidget);
    expect(find.text('不包含'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(LocalSavePage), findsOneWidget);
    expect(rootObserver.pushes, 1);
    expect(tester.takeException(), isNull);
  });
}
