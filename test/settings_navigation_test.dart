import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/settings_screen.dart';

void main() {
  testWidgets(
    'settings categories preserve navigation and live changes on a narrow screen',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = (await tester.runAsync(() => AppController.load()))!;
      controller.setLiquidGlassChatUi(false);
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: SettingsScreen(controller: controller, onMenuPressed: () {}),
        ),
      );
      expect(find.byType(SwitchListTile), findsNothing);
      for (final entry in {
        'appearance': '主题',
        'audio': '点击语音',
        'profile': '称呼与自画像',
        'ai': 'OpenAI 兼容接口',
        'roleplay': '人物设定注入',
        'data': '导出本地数据',
        'about': 'AgentAtelierR',
      }.entries) {
        final tile = find.byKey(ValueKey('settings-category-${entry.key}'));
        await tester.scrollUntilVisible(
          tile,
          240,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(tile);
        await tester.pumpAndSettle();
        expect(find.text(entry.value), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (entry.key == 'appearance') {
          controller.setShowMicrophoneButton(true);
          controller.setUnlockInputWhileReplying(true);
          await tester.pump();
          expect(
            tester
                .widget<SwitchListTile>(
                  find.widgetWithText(SwitchListTile, '显示麦克风按钮'),
                )
                .value,
            isTrue,
          );
          expect(
            tester
                .widget<SwitchListTile>(
                  find.widgetWithText(SwitchListTile, '回复时解锁输入框'),
                )
                .value,
            isTrue,
          );
        }
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
