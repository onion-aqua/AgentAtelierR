import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/continuous_asmr_page.dart';

void main() {
  testWidgets(
    'ASMR page exposes topic, countdown and time without starting requests',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      for (final channel in [
        'xyz.luan/audioplayers',
        'xyz.luan/audioplayers.global',
      ]) {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MethodChannel(channel),
          (_) async => 1,
        );
      }
      final c = (await tester.runAsync(() => AppController.load()))!;
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(home: ContinuousAsmrPage(controller: c)),
      );
      await tester.pump();
      expect(find.text('ASMR 主题'), findsOneWidget);
      expect(find.text('倒计时（分钟）'), findsOneWidget);
      expect(find.text('或选择停止时间'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '雨夜轻声陪伴');
      await tester.tap(find.text('开始'));
      await tester.pump();
      expect(find.text('请先启用并配置 LLM 和语音合成'), findsOneWidget);
      expect(c.messages.length, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
