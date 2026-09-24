import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/continuous_asmr_page.dart';

void main() {
  test('deadline supports countdown and next-day clock time', () {
    final now = DateTime(2026, 9, 22, 23, 50);
    expect(
      asmrDeadline(now, const Duration(minutes: 15), null),
      DateTime(2026, 9, 23, 0, 5),
    );
    expect(
      asmrDeadline(now, Duration.zero, const TimeOfDay(hour: 0, minute: 10)),
      DateTime(2026, 9, 23, 0, 10),
    );
    expect(
      asmrDeadline(now, Duration.zero, const TimeOfDay(hour: 23, minute: 55)),
      DateTime(2026, 9, 22, 23, 55),
    );
  });
  test('complete ASMR script is segmented without dropping text or tags', () {
    const script =
        '[whispering]雨落在窗边，声音很轻。你可以慢慢闭上眼睛，听一会儿。\n'
        '[breathy]我会留在这里，等这一阵雨慢慢过去。';
    final segments = splitAsmrScript(script);

    expect(segments.length, greaterThan(1));
    expect(
      segments.map((segment) => segment.text).join(),
      script.replaceAll('\n', ''),
    );
    expect(segments.first.text, startsWith('[whispering]'));
    expect(segments.last.text, startsWith('[breathy]'));
    expect(segments.first.pauseAfter, greaterThan(Duration.zero));
    expect(segments.last.pauseAfter, Duration.zero);
  });

  test('long ASMR text stays in order and uses bounded TTS segments', () {
    final script = '[soft breathy voice]${'这是完整朗读稿，不应被裁掉。' * 25}';
    final segments = splitAsmrScript(script);

    expect(segments.length, greaterThan(3));
    expect(segments.every((segment) => segment.text.length <= 96), isTrue);
    expect(segments.map((segment) => segment.text).join(), script);
  });
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
      expect(find.text('输入 ASMR 主题'), findsOneWidget);
      expect(find.text('倒计时关闭'), findsOneWidget);
      expect(find.text('指定时刻关闭'), findsOneWidget);
      expect(find.byKey(const ValueKey('asmr-countdown')), findsOneWidget);
      await tester.tap(find.text('指定时刻关闭'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('asmr-clock')), findsOneWidget);
      await tester.enterText(find.byType(TextField), '雨夜轻声陪伴');
      await tester.tap(find.text('生成'));
      await tester.pump();
      expect(find.text('请先启用并配置 LLM 和语音合成'), findsOneWidget);
      expect(c.messages.length, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
