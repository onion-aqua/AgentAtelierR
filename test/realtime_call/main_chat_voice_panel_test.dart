import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_ui_models.dart';
import 'package:ryza_chat_mvp/src/realtime_call/main_chat_voice_panel.dart';

const _contact = CallContact(id: 'primary:ryza', displayName: '莱莎');

class _Calls extends CallUiController {
  @override
  final contacts = <CallContact>[_contact];
  @override
  final history = <CallHistoryEntry>[];
  @override
  CallUiSnapshot snapshot = const CallUiSnapshot(
    phase: CallUiPhase.listening,
    contact: _contact,
  );

  final actions = <String>[];
  Completer<void>? mutePending;
  Completer<void>? endPending;

  void show(CallUiSnapshot value) {
    snapshot = value;
    notifyListeners();
  }

  @override
  Future<void> startCall(String contactId) async =>
      actions.add('start:$contactId');
  @override
  Future<void> offerCall(String contactId) async =>
      actions.add('offer:$contactId');
  @override
  Future<void> acceptCall() async => actions.add('accept');
  @override
  Future<void> declineCall() async => actions.add('decline');
  @override
  Future<void> sendText(String text) async => actions.add('send:$text');
  @override
  Future<void> interrupt() async => actions.add('interrupt');
  @override
  Future<void> setSpeaker(bool value) async => actions.add('speaker:$value');

  @override
  Future<void> setMuted(bool value) async {
    actions.add('mute:$value');
    await mutePending?.future;
    show(
      CallUiSnapshot(
        phase: snapshot.phase,
        contact: snapshot.contact,
        muted: value,
      ),
    );
  }

  @override
  Future<void> endCall() async {
    actions.add('end');
    await endPending?.future;
    show(const CallUiSnapshot(phase: CallUiPhase.ended, contact: _contact));
  }
}

Finder _key(String key) => find.byKey(ValueKey(key));

void main() {
  late _Calls controller;
  late int settingsOpened;
  late int closed;

  setUp(() {
    controller = _Calls();
    settingsOpened = 0;
    closed = 0;
  });
  tearDown(() => controller.dispose());

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(390, 780),
    Size? panelSize,
    double textScale = 1,
    AppLanguage language = AppLanguage.chinese,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          backgroundColor: const Color(0xFF263449),
          body: SingleChildScrollView(
            child: SizedBox(
              width: panelSize?.width,
              height: panelSize?.height,
              child: MainChatVoicePanel(
                controller: controller,
                language: language,
                onClose: () => closed++,
                onOpenSettings: () => settingsOpened++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final phase in [CallUiPhase.preparing, CallUiPhase.dialing]) {
    testWidgets(
      '$phase keeps hangup available and deduplicates pending hangup',
      (tester) async {
        controller.show(CallUiSnapshot(phase: phase, contact: _contact));
        controller.endPending = Completer<void>();
        await mount(tester);
        expect(
          tester.widget<TextButton>(_key('main-chat-voice-mute')).onPressed,
          isNull,
        );
        expect(
          tester.widget<FilledButton>(_key('main-chat-voice-end')).onPressed,
          isNotNull,
        );

        await tester.tap(_key('main-chat-voice-end'));
        await tester.pump();
        await tester.tap(_key('main-chat-voice-end'));
        await tester.pump();
        expect(controller.actions, ['end']);
        expect(closed, 0);
        controller.endPending!.complete();
        await tester.pumpAndSettle();
        expect(find.text('通话已结束'), findsOneWidget);
        expect(_key('main-chat-voice-close'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'mute and unmute follow controller state without duplicate calls',
    (tester) async {
      controller.mutePending = Completer<void>();
      await mount(tester);
      expect(find.text('静音'), findsOneWidget);
      await tester.tap(_key('main-chat-voice-mute'));
      await tester.pump();
      await tester.tap(_key('main-chat-voice-mute'));
      await tester.pump();
      expect(controller.actions, ['mute:true']);
      expect(
        tester.widget<FilledButton>(_key('main-chat-voice-end')).onPressed,
        isNotNull,
        reason: 'A recorder operation must never prevent ending the session.',
      );
      controller.mutePending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('已静音'), findsOneWidget);
      expect(find.text('取消静音'), findsOneWidget);

      controller.mutePending = Completer<void>();
      await tester.tap(_key('main-chat-voice-mute'));
      await tester.pump();
      await tester.tap(_key('main-chat-voice-mute'));
      await tester.pump();
      expect(controller.actions, ['mute:true', 'mute:false']);
      controller.mutePending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('静音'), findsOneWidget);
      expect(find.textContaining('正在聆听'), findsOneWidget);
    },
  );

  testWidgets('interim recognition takes priority without mixing translation', (
    tester,
  ) async {
    controller.show(
      const CallUiSnapshot(
        phase: CallUiPhase.speaking,
        contact: _contact,
        elapsed: Duration(seconds: 87),
        caption: '今日はいい天気だね。',
        captionTranslation: '今天天气真好。',
      ),
    );
    await mount(tester);
    expect(find.text('今日はいい天気だね。'), findsOneWidget);
    expect(find.text('今天天气真好。'), findsOneWidget);
    expect(find.text('01:27'), findsOneWidget);
    controller.show(
      const CallUiSnapshot(
        phase: CallUiPhase.thinking,
        contact: _contact,
        interimTranscript: '我刚才想说的是另一件事',
        caption: '今日はいい天気だね。',
        captionTranslation: '今天天气真好。',
      ),
    );
    await tester.pump();
    expect(find.text('我刚才想说的是另一件事'), findsOneWidget);
    expect(find.text('今日はいい天気だね。'), findsNothing);
    expect(find.text('今天天气真好。'), findsNothing);
    expect(controller.actions, isEmpty);
  });

  testWidgets(
    'failed session remains passive and exposes settings and typing',
    (tester) async {
      controller.show(
        const CallUiSnapshot(phase: CallUiPhase.failed, error: '请先下载本地识别模型。'),
      );
      await mount(tester);
      await tester.pump(const Duration(minutes: 1));
      expect(find.text('请先下载本地识别模型。'), findsOneWidget);
      expect(_key('main-chat-voice-end'), findsNothing);
      expect(controller.actions, isEmpty);
      expect(controller.history, isEmpty);
      await tester.tap(_key('main-chat-voice-settings'));
      await tester.pump();
      expect(settingsOpened, 1);
      expect(controller.actions, isEmpty);
      await tester.tap(_key('main-chat-voice-close'));
      await tester.pump();
      expect(closed, 1);
      expect(controller.actions, isEmpty);
    },
  );

  testWidgets('failed mute is shown once without retrying or hanging up', (
    tester,
  ) async {
    controller.mutePending = Completer<void>();
    await mount(tester);
    await tester.tap(_key('main-chat-voice-mute'));
    await tester.pump();
    controller.mutePending!.completeError(StateError('recorder unavailable'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 40));
    expect(find.text('操作未完成，请重试。'), findsOneWidget);
    expect(controller.actions, ['mute:true']);
    expect(
      tester.widget<TextButton>(_key('main-chat-voice-mute')).onPressed,
      isNotNull,
    );
    expect(
      tester.widget<FilledButton>(_key('main-chat-voice-end')).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  for (final language in AppLanguage.values) {
    for (final phase in [CallUiPhase.speaking, CallUiPhase.failed]) {
      testWidgets('$language $phase fits narrow screen with large text', (
        tester,
      ) async {
        controller.show(
          CallUiSnapshot(
            phase: phase,
            contact: _contact,
            elapsed: const Duration(hours: 1, seconds: 8),
            caption: 'A long character response. ' * 12,
            captionTranslation: '这是一条很长的字幕翻译。' * 12,
            error: phase == CallUiPhase.failed
                ? '请检查本地识别模型和当前语音服务，然后手动重新开始通话。'
                : null,
          ),
        );
        await mount(
          tester,
          size: const Size(240, 780),
          textScale: 2,
          language: language,
        );
        expect(_key('main-chat-voice-panel'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(controller.actions, isEmpty);
      });
    }
  }

  for (final language in AppLanguage.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        '$language bounded panel keeps hangup visible at scale=$scale',
        (tester) async {
          controller.show(
            CallUiSnapshot(
              phase: CallUiPhase.speaking,
              contact: _contact,
              elapsed: const Duration(minutes: 12, seconds: 34),
              caption:
                  'This is a lengthy character reply with several sentences. ' *
                  15,
              captionTranslation: '这是一条很长的字幕翻译。' * 15,
              error: '上段语音发生错误，请检查设置；当前仍可挂断，不会自动重试。' * 6,
            ),
          );
          await mount(
            tester,
            panelSize: Size(240, scale == 1 ? 150 : 220),
            textScale: scale,
            language: language,
          );
          expect(tester.takeException(), isNull);
          expect(_key('main-chat-voice-end').hitTestable(), findsOneWidget);
          final endBeforeScroll = tester.getRect(_key('main-chat-voice-end'));
          final detailsScroll = find.descendant(
            of: _key('main-chat-voice-panel'),
            matching: find.byType(SingleChildScrollView),
          );
          expect(detailsScroll, findsOneWidget);
          await tester.drag(detailsScroll, const Offset(0, -400));
          await tester.pumpAndSettle();
          expect(tester.getRect(_key('main-chat-voice-end')), endBeforeScroll);
          expect(_key('main-chat-voice-end').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(_key('main-chat-voice-end'));
          await tester.pumpAndSettle();
          expect(controller.actions, ['end']);
          expect(_key('main-chat-voice-close').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final operation in ['mute', 'end']) {
    for (final fails in [false, true]) {
      testWidgets(
        'dispose during $operation handles late completion fails=$fails',
        (tester) async {
          final pending = Completer<void>();
          if (operation == 'mute') {
            controller.mutePending = pending;
          } else {
            controller.endPending = pending;
          }
          await mount(tester);
          await tester.tap(_key('main-chat-voice-$operation'));
          await tester.pump();
          await tester.pumpWidget(const SizedBox.shrink());
          if (fails) {
            pending.completeError(StateError('late native error'));
          } else {
            pending.complete();
          }
          await tester.pump();
          await tester.pump(const Duration(seconds: 2));
          expect(controller.actions, [
            operation == 'mute' ? 'mute:true' : 'end',
          ]);
          expect(closed, 0);
          expect(settingsOpened, 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
