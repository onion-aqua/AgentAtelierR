import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_page.dart';

const _ryza = CallContact(
  id: 'primary:ryza',
  displayName: '莱莎',
  subtitle: '当前角色',
);
const _klaudia = CallContact(
  id: 'klaudia',
  displayName: '科洛蒂娅',
  subtitle: '已添加的联系人',
);

class _Calls extends CallUiController {
  @override
  final contacts = <CallContact>[_ryza, _klaudia];
  @override
  final history = <CallHistoryEntry>[];
  @override
  CallUiSnapshot snapshot = const CallUiSnapshot();
  final actions = <String>[];
  Completer<void>? dialing;

  void show(CallUiSnapshot value) {
    snapshot = value;
    notifyListeners();
  }

  @override
  Future<void> startCall(String contactId) async {
    actions.add('start:$contactId');
    show(
      CallUiSnapshot(
        phase: CallUiPhase.dialing,
        contact: contacts.firstWhere((c) => c.id == contactId),
      ),
    );
    await dialing?.future;
  }

  @override
  Future<void> offerCall(String contactId) async {
    actions.add('offer:$contactId');
    show(
      CallUiSnapshot(
        phase: CallUiPhase.incoming,
        contact: contacts.firstWhere((c) => c.id == contactId),
      ),
    );
  }

  @override
  Future<void> acceptCall() async {
    actions.add('accept');
    show(
      CallUiSnapshot(phase: CallUiPhase.preparing, contact: snapshot.contact),
    );
  }

  @override
  Future<void> declineCall() async {
    actions.add('decline');
    show(const CallUiSnapshot());
  }

  @override
  Future<void> endCall() async {
    actions.add('end');
    show(const CallUiSnapshot());
  }

  @override
  Future<void> setMuted(bool value) async => actions.add('mute:$value');
  @override
  Future<void> setSpeaker(bool value) async => actions.add('speaker:$value');
  @override
  Future<void> sendText(String text) async => actions.add('text:$text');
  @override
  Future<void> interrupt() async => actions.add('interrupt');
}

Finder _key(String id) => find.byKey(ValueKey(id));

void main() {
  late _Calls controller;

  setUp(() => controller = _Calls());
  tearDown(() => controller.dispose());

  testWidgets(
    'CC hides assistant breath artifacts without altering user transcript',
    (tester) async {
      controller.show(
        const CallUiSnapshot(
          phase: CallUiPhase.speaking,
          contact: _ryza,
          caption: 'あ……っ、待って。',
          captionTranslation: '……つ。待って。',
          interimTranscript: 'あ……っ、私の声。',
        ),
      );
      tester.view.physicalSize = const Size(390, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: RealtimeCallPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.text('あ……、待って。'), findsOneWidget);
      expect(find.text('……。待って。'), findsOneWidget);
      expect(find.text('你：あ……っ、私の声。'), findsOneWidget);
      expect(controller.snapshot.caption, 'あ……っ、待って。');
    },
  );

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(390, 780),
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
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
        home: RealtimeCallPage(
          controller: controller,
          wallpaper: const ColoredBox(color: Color(0xFF263449)),
          onOpenSettings: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'directory calls only supplied current-save contacts and shows recents',
    (tester) async {
      controller.history.add(
        CallHistoryEntry(
          contactId: 'primary:ryza',
          contactName: '莱莎',
          startedAt: DateTime.utc(2026, 10, 21, 1, 7),
          duration: Duration.zero,
          incoming: false,
          status: CallHistoryStatus.completed,
        ),
      );
      controller.history.add(
        CallHistoryEntry(
          contactId: 'klaudia',
          contactName: '科洛蒂娅',
          startedAt: DateTime(2026, 10, 21, 17, 42),
          duration: const Duration(seconds: 85),
          incoming: true,
          status: CallHistoryStatus.completed,
        ),
      );
      await mount(tester);
      expect(find.text('莱莎'), findsOneWidget);
      expect(find.text('科洛蒂娅'), findsOneWidget);
      await tester.tap(_key('call-tab-history'));
      await tester.pumpAndSettle();
      expect(find.text('01:25'), findsOneWidget);
      expect(find.textContaining('10/21 17:42'), findsOneWidget);
      final local = DateTime.utc(2026, 10, 21, 1, 7).toLocal();
      expect(
        find.textContaining(
          '${local.month}/${local.day} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('科洛蒂娅'));
      await tester.pumpAndSettle();
      expect(controller.actions, ['start:klaudia']);
      expect(find.text('正在呼叫…'), findsOneWidget);
      expect(_key('call-timer'), findsNothing);
    },
  );

  testWidgets(
    'dialing does not imply connected and hangup remains available during setup',
    (tester) async {
      controller.dialing = Completer<void>();
      await mount(tester);
      await tester.tap(_key('call-contact-primary:ryza'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 20));
      expect(find.text('正在呼叫…'), findsOneWidget);
      expect(_key('call-timer'), findsNothing);
      await tester.ensureVisible(_key('call-end'));
      await tester.tap(_key('call-end'));
      await tester.pump();
      expect(controller.actions, ['start:primary:ryza', 'end']);
      expect(_key('call-tab-contacts'), findsOneWidget);
      controller.dialing!.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'incoming is explicitly in-app and acceptance waits for preparation',
    (tester) async {
      controller.show(
        const CallUiSnapshot(phase: CallUiPhase.incoming, contact: _ryza),
      );
      await mount(tester);
      expect(find.text('应用内来电'), findsOneWidget);
      expect(_key('call-accept'), findsOneWidget);
      await tester.tap(_key('call-accept'));
      await tester.pumpAndSettle();
      expect(controller.actions, ['accept']);
      expect(find.text('正在准备麦克风与语音识别…'), findsOneWidget);
      expect(_key('call-timer'), findsNothing);
    },
  );

  testWidgets('incoming decline returns to contacts', (tester) async {
    controller.show(
      const CallUiSnapshot(phase: CallUiPhase.incoming, contact: _klaudia),
    );
    await mount(tester);
    await tester.tap(_key('call-decline'));
    await tester.pumpAndSettle();
    expect(controller.actions, ['decline']);
    expect(_key('call-tab-contacts'), findsOneWidget);
  });

  testWidgets('incoming message reports the exact NPC or primary contact', (
    tester,
  ) async {
    String? opened;
    controller.show(
      const CallUiSnapshot(phase: CallUiPhase.incoming, contact: _klaudia),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeCallPage(
          controller: controller,
          wallpaper: const ColoredBox(color: Color(0xFF263449)),
          onOpenMessages: (id) => opened = id,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_key('call-message'));
    await tester.pumpAndSettle();
    expect(opened, 'klaudia');
    expect(controller.actions, ['decline', 'end']);

    controller.show(
      const CallUiSnapshot(phase: CallUiPhase.incoming, contact: _ryza),
    );
    await tester.pump();
    await tester.tap(_key('call-message'));
    await tester.pumpAndSettle();
    expect(opened, 'primary:ryza');
    expect(controller.actions, ['decline', 'end', 'decline', 'end']);
  });

  testWidgets('listening guidance follows the phone interface language', (
    tester,
  ) async {
    controller.show(
      const CallUiSnapshot(
        phase: CallUiPhase.listening,
        contact: _ryza,
        statusMessage: '正在聆听 · 说完后停顿片刻',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RealtimeCallPage(
          controller: controller,
          language: AppLanguage.english,
          wallpaper: const ColoredBox(color: Color(0xFF263449)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Listening · pause briefly when finished'),
      findsOneWidget,
    );
    expect(find.textContaining('正在聆听'), findsNothing);
  });

  testWidgets(
    'actual Bluetooth output replaces speaker icon and can switch back',
    (tester) async {
      controller.show(
        const CallUiSnapshot(
          phase: CallUiPhase.listening,
          contact: _ryza,
          speaker: false,
          audioRoute: CallAudioRoute.bluetooth,
        ),
      );
      await mount(tester);
      expect(find.text('蓝牙'), findsOneWidget);
      expect(find.byIcon(Icons.bluetooth_audio_rounded), findsOneWidget);
      await tester.tap(_key('call-speaker'));
      await tester.pump();
      expect(controller.actions, ['speaker:true']);

      controller.show(
        const CallUiSnapshot(
          phase: CallUiPhase.listening,
          contact: _ryza,
          audioRoute: CallAudioRoute.speaker,
        ),
      );
      await tester.pump();
      expect(find.text('扬声器'), findsOneWidget);
      expect(find.text('蓝牙'), findsNothing);
      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);

      controller.show(
        const CallUiSnapshot(
          phase: CallUiPhase.listening,
          contact: _ryza,
          speaker: false,
          audioRoute: CallAudioRoute.wired,
        ),
      );
      await tester.pump();
      expect(find.text('耳机'), findsOneWidget);
      expect(find.byIcon(Icons.headphones_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('explicit contact menu offers an in-app call', (tester) async {
    await mount(tester);
    await tester.tap(_key('call-contact-menu-klaudia'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('让 TA 来电（应用内）'));
    await tester.pumpAndSettle();
    expect(controller.actions, ['offer:klaudia']);
    expect(find.text('应用内来电'), findsOneWidget);
  });

  testWidgets('real state transitions update elapsed, captions and interrupt', (
    tester,
  ) async {
    controller.show(
      const CallUiSnapshot(
        phase: CallUiPhase.listening,
        contact: _ryza,
        elapsed: Duration(seconds: 12),
        interimTranscript: '下午好',
      ),
    );
    await mount(tester);
    expect(find.text('00:12'), findsOneWidget);
    expect(find.text('你：下午好'), findsOneWidget);
    controller.show(
      const CallUiSnapshot(
        phase: CallUiPhase.speaking,
        contact: _ryza,
        elapsed: Duration(seconds: 15),
        caption: 'やっほー！',
        captionTranslation: '你好呀！',
      ),
    );
    await tester.pump();
    expect(find.text('正在说话'), findsOneWidget);
    expect(find.text('00:15'), findsOneWidget);
    expect(find.text('你好呀！'), findsOneWidget);
    await tester.ensureVisible(_key('call-interrupt'));
    await tester.tap(_key('call-interrupt'));
    await tester.pumpAndSettle();
    expect(controller.actions, ['interrupt']);
    await tester.tap(_key('call-captions'));
    await tester.pump();
    expect(find.text('やっほー！'), findsNothing);
    expect(find.text('你好呀！'), findsNothing);
    await tester.tap(_key('call-captions'));
    await tester.pump();
    expect(find.text('やっほー！'), findsOneWidget);
  });

  testWidgets('keypad sends text and dialog retires its own text controller', (
    tester,
  ) async {
    controller.show(
      const CallUiSnapshot(phase: CallUiPhase.listening, contact: _ryza),
    );
    await mount(tester);
    await tester.tap(_key('call-keypad'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('call-text-draft'), ' 晚上好 ');
    await tester.tap(_key('call-text-send'));
    await tester.pumpAndSettle();
    expect(controller.actions, ['text:晚上好']);
    expect(tester.takeException(), isNull);
  });

  for (final phase in [
    CallUiPhase.incoming,
    CallUiPhase.speaking,
    CallUiPhase.failed,
  ]) {
    testWidgets('narrow screen and large fonts remain usable: ${phase.name}', (
      tester,
    ) async {
      controller.show(
        CallUiSnapshot(
          phase: phase,
          contact: const CallContact(
            id: 'long',
            displayName: '科洛蒂娅·巴兰茨与非常长的联系人名称',
          ),
          caption: '这是一段较长的实时通话字幕。\n保持文字可读，并让所有通话控制可以滚动访问。',
          error: phase == CallUiPhase.failed
              ? '语音识别模型尚未下载，请到通话设置选择本地模型。'
              : null,
        ),
      );
      await mount(tester, size: const Size(320, 460), scale: 1.8);
      final target = phase == CallUiPhase.incoming
          ? 'call-accept'
          : phase == CallUiPhase.failed
          ? 'call-close'
          : 'call-end';
      await tester.ensureVisible(_key(target));
      await tester.pumpAndSettle();
      expect(_key(target).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
