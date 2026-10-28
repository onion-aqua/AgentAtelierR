import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/rag_memory_runtime.dart';
import 'package:ryza_chat_mvp/src/rag_memory_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<AppController> _controller() async {
  SharedPreferences.setMockInitialValues({});
  return AppController.load(
    ragRuntime: RagMemoryRuntime(
      embed: (_) async => throw StateError('Offline test'),
    ),
  );
}

Future<void> _mount(
  WidgetTester tester,
  AppController controller, {
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(390, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: RagMemorySettingsCard(controller: controller),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'trial toggle is reversible and respects the main memory switch',
    (tester) async {
      final controller = await _controller();
      addTearDown(controller.dispose);
      await _mount(tester, controller);
      final toggle = find.byKey(const ValueKey('rag-memory-enabled'));
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(controller.ragMemoryEnabled, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(controller.ragMemoryEnabled, isTrue);
      controller.setLongTermMemoryEnabled(false);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
    },
  );

  testWidgets(
    'local recall shows archived evidence and clears it when disabled',
    (tester) async {
      final controller = await _controller();
      addTearDown(controller.dispose);
      controller.addUserMessage('蓝色工具箱的暗号是松果七号。');
      controller.addAssistantMessage('莱莎：我记住了，蓝色工具箱用松果七号。');
      await _mount(tester, controller);
      expect(find.text('当前存档已归档 1 轮对话'), findsOneWidget);
      await tester.tap(find.text('测试回忆'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('rag-memory-test-query')),
        '蓝色工具箱的暗号',
      );
      await tester.tap(find.byKey(const ValueKey('rag-memory-test-run')));
      await tester.pumpAndSettle();
      final results = find.byKey(const ValueKey('rag-memory-test-results'));
      expect(tester.widget<SelectableText>(results).data, contains('松果七号'));
      await tester.ensureVisible(
        find.byKey(const ValueKey('rag-memory-enabled')),
      );
      await tester.tap(find.byKey(const ValueKey('rag-memory-enabled')));
      await tester.pumpAndSettle();
      expect(results, findsNothing);
    },
  );

  testWidgets('read or undo cannot leave another save evidence visible', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    controller.addUserMessage('密码纸写着银色羽毛。');
    controller.addAssistantMessage('莱莎：密码纸上是银色羽毛。');
    await _mount(tester, controller);
    await tester.tap(find.text('测试回忆'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('rag-memory-test-query')),
      '密码纸',
    );
    await tester.tap(find.byKey(const ValueKey('rag-memory-test-run')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('rag-memory-test-results')),
      findsOneWidget,
    );
    controller.undoLastUserTurn();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rag-memory-test-results')), findsNothing);
  });

  testWidgets('recall settings fit a narrow screen at enlarged text', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _mount(tester, controller, scale: 2);
    tester.view.physicalSize = const Size(320, 740);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('测试回忆'));
    await tester.tap(find.text('测试回忆'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
