import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/continuous_asmr_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'ASMR prompt follows the active character and its role settings',
    () async {
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => Directory.systemTemp.path,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final controller = await AppController.load();
      addTearDown(controller.dispose);

      await controller.setActiveCharacter('sophie');
      controller.setCharacterPersona('苏菲专用性格');
      controller.setWorldSetting('苏菲专用世界');
      final sophiePrompt = buildContinuousAsmrSystemPrompt(
        controller,
        targetChars: 350,
      );
      expect(sophiePrompt, contains('你是苏菲'));
      expect(sophiePrompt, contains('苏菲专用性格'));
      expect(sophiePrompt, contains('苏菲专用世界'));
      expect(sophiePrompt, isNot(contains('你是莱莎')));

      controller.setWorldSettingInjectionEnabled(false);
      final withoutWorld = buildContinuousAsmrSystemPrompt(
        controller,
        targetChars: 350,
      );
      expect(withoutWorld, isNot(contains('苏菲专用世界')));
      expect(withoutWorld, isNot(contains('世界参考：')));

      await controller.setActiveCharacter('ryza');
      final ryzaPrompt = buildContinuousAsmrSystemPrompt(
        controller,
        targetChars: 350,
      );
      expect(ryzaPrompt, contains('你是莱莎'));
      expect(ryzaPrompt, isNot(contains('苏菲专用性格')));
      expect(ryzaPrompt, isNot(contains('苏菲专用世界')));
    },
  );

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

  test('ASMR display text hides voice directions but keeps spoken words', () {
    expect(asmrSpokenText('[whispering]今晚下雨了，[short pause]慢慢听。'), '今晚下雨了，慢慢听。');
  });

  testWidgets('ASMR playback stays black and fits a narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    var stopped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: AsmrPlaybackSurface(
          text: '雨落在窗边，声音很轻。' * 12,
          translation: 'The rain is falling softly by the window.' * 4,
          voiceArea: const SizedBox(
            key: ValueKey('asmr-voice-area'),
            width: double.infinity,
            height: 180,
          ),
          stopLabel: '停止',
          onStop: () => stopped = true,
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      Colors.black,
    );
    expect(find.byKey(const ValueKey('asmr-current-text')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('asmr-current-translation')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('asmr-voice-area')), findsOneWidget);
    await tester.tap(find.byTooltip('停止'));
    expect(stopped, isTrue);
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
      expect(find.byKey(const ValueKey('asmr-voice-area')), findsOneWidget);
      expect(find.text('确定'), findsOneWidget);
      expect(find.text('生成'), findsNothing);
      expect(
        tester.widget<IconButton>(find.byType(IconButton).last).onPressed,
        isNull,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('asmr-voice-area'))).height,
        300,
      );
      await tester.tap(find.text('指定时刻关闭'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('asmr-clock')), findsOneWidget);
      await tester.enterText(find.byType(TextField), '雨夜轻声陪伴');
      await tester.tap(find.text('确定'));
      await tester.pump();
      expect(find.text('请先启用并配置 LLM 和语音合成'), findsOneWidget);
      expect(c.messages.length, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
