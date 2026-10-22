import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_audio.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_reply.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_session.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_settings.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_ui_models.dart';
import 'package:ryza_chat_mvp/src/realtime_call/local_call_asr.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('phone prefetches two sentences while first is pending and preserves playback order', () async {
    SharedPreferences.setMockInitialValues({});
    final app = await AppController.load();
    app.configureAi(
      enabled: true,
      baseUrl: 'https://example.test/v1',
      model: 'model',
    );
    final first = StreamController<Uint8List>();
    final requested = <String>[];
    final output = _RecordingOutput();
    final fixture = await _callFixture(
      app,
      reply: '莱莎：第一句。第二句。第三句。',
      output: output,
      speechFactory: (text, voice, model, key) {
        requested.add(text);
        final number = requested.length;
        return CallSpeech(
          number == 1
              ? first.stream
              : Stream.value(Uint8List.fromList([number, 0])),
          () async {},
        );
      },
    );
    await fixture.controller.startCall('primary:ryza');
    await fixture.controller.sendText('继续说');
    await _waitUntil(() => requested.length == 2);
    expect(output.values, isEmpty);
    first.add(Uint8List.fromList([1, 0]));
    await first.close();
    await _waitUntil(
      () => fixture.controller.snapshot.phase == CallUiPhase.listening,
    );
    expect(requested, ['第一句。', '第二句。', '第三句。']);
    expect(output.values, [1, 2, 3]);
    expect(app.callRecords.single.turns.single['assistant'], '第一句。第二句。第三句。');
    await fixture.controller.endCall();
    fixture.controller.dispose();
    app.dispose();
    await fixture.directory.delete(recursive: true);
  });

  test('phone directory offers only Ryza and Claudia, regardless of other contacts', () async {
    SharedPreferences.setMockInitialValues({});
    final app = await AppController.load();
    app.addNpcContact('kala');
    final controller = RealtimeCallController(app: app, asr: _FakeAsr());
    expect(controller.contacts.map((contact) => contact.id), [
      'primary:ryza',
      'claudia',
    ]);
    await expectLater(
      controller.offerCall('kala'),
      throwsA(isA<FormatException>()),
    );
    controller.dispose();
    app.dispose();
  });

  test(
    'Claudia follows Ryza speech language and CC translation is never spoken',
    () async {
      SharedPreferences.setMockInitialValues({});
      final app = await AppController.load();
      app.configureAi(
        enabled: true,
        baseUrl: 'https://example.test/v1',
        model: 'model',
      );
      app.configureLanguages(
        interface: AppLanguage.chinese,
        narrator: AppLanguage.chinese,
        characterReply: AppLanguage.japanese,
        translation: TranslationLanguage.chinese,
      );
      app.configureNpcMessageLanguages(
        reply: AppLanguage.english,
        translation: TranslationLanguage.english,
      );
      final backend = _CaptionReplyBackend('科洛蒂娅：こんにちは。', translation: '你好。');
      final spoken = <String>[];
      final fixture = await _callFixture(
        app,
        reply: '',
        output: _FakeOutput(),
        backend: backend,
        spoken: spoken,
      );
      final controller = fixture.controller;
      await controller.startCall('claudia');
      expect(app.isNpcContactAdded('claudia'), isTrue);
      await controller.sendText('你好');
      await _waitUntil(() => controller.snapshot.captionTranslation == '你好。');
      expect(backend.request!.prompt, contains('用Japanese说自然口语'));
      expect(backend.translationLanguage, TranslationLanguage.chinese);
      expect(spoken, ['こんにちは。']);
      expect(controller.snapshot.caption, 'こんにちは。');
      await controller.endCall();
      controller.dispose();
      app.dispose();
      await fixture.directory.delete(recursive: true);
    },
  );

  test('late CC translation is discarded after language changes or translation is disabled', () async {
    SharedPreferences.setMockInitialValues({});
    final app = await AppController.load();
    app.configureAi(
      enabled: true,
      baseUrl: 'https://example.test/v1',
      model: 'model',
    );
    app.configureLanguages(
      interface: AppLanguage.chinese,
      narrator: AppLanguage.chinese,
      characterReply: AppLanguage.japanese,
      translation: TranslationLanguage.chinese,
    );
    final pending = Completer<String>();
    final backend = _CaptionReplyBackend('こんにちは。', pending: pending);
    final fixture = await _callFixture(
      app,
      reply: '',
      output: _FakeOutput(),
      backend: backend,
    );
    final controller = fixture.controller;
    await controller.startCall('primary:ryza');
    await controller.sendText('你好');
    await backend.translationStarted.future;
    app.configureLanguages(
      interface: AppLanguage.chinese,
      narrator: AppLanguage.chinese,
      characterReply: AppLanguage.japanese,
      translation: TranslationLanguage.none,
    );
    pending.complete('你好。');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(controller.snapshot.captionTranslation, isEmpty);
    await controller.sendText('再说一句');
    await _waitUntil(() => controller.snapshot.phase == CallUiPhase.listening);
    expect(backend.translations, 1);
    await controller.endCall();
    controller.dispose();
    app.dispose();
    await fixture.directory.delete(recursive: true);
  });

  test(
    'terminal call can be dismissed back to the contact directory',
    () async {
      SharedPreferences.setMockInitialValues({});
      final app = await AppController.load();
      final controller = RealtimeCallController(app: app, asr: _FakeAsr());
      await controller.offerCall('primary:ryza');
      expect(controller.snapshot.phase, CallUiPhase.incoming);
      await controller.declineCall();
      expect(controller.snapshot.phase, CallUiPhase.ended);
      await controller.endCall();
      expect(controller.snapshot.phase, CallUiPhase.idle);
      expect(controller.snapshot.contact, isNull);
      controller.dispose();
      app.dispose();
    },
  );

  test(
    'Claudia falls back to the built-in voice id and played text persists',
    () async {
      SharedPreferences.setMockInitialValues({});
      final app = await AppController.load();
      app
        ..configureAi(
          enabled: true,
          baseUrl: 'https://example.test/v1',
          model: 'model',
        )
        ..addNpcContact('claudia');
      app.fishAudioReferenceId = 'voice';
      final directory = await Directory.systemTemp.createTemp('call-session-');
      final model = File('${directory.path}/model.int8.onnx');
      final tokens = File('${directory.path}/tokens.txt');
      final vad = File('${directory.path}/silero_vad.onnx');
      for (final file in [model, tokens, vad]) {
        await file.writeAsBytes([1]);
      }
      final asr = _FakeAsr();
      final output = _FakeOutput();
      String? selectedVoice;
      final controller = RealtimeCallController(
        app: app,
        asr: asr,
        output: output,
        replies: _ReplyBackend(Stream.value('科洛蒂娅：听得到。')),
        settingsStore: _SettingsStore(
          CallSettings(
            asr: LocalCallAsrConfig(
              modelPath: model.path,
              tokensPath: tokens.path,
              vadModelPath: vad.path,
            ),
            voiceOverrides: const {},
          ),
        ),
        readFishKey: () async => 'fish-key',
        speechFactory: (text, voice, model, key) {
          selectedVoice = voice;
          return CallSpeech(
            Stream.value(Uint8List.fromList([0, 0, 0, 0])),
            () async {},
          );
        },
      );
      await controller.startCall('claudia');
      expect(controller.snapshot.phase, CallUiPhase.listening);
      await controller.sendText('听得到吗？');
      await _waitUntil(
        () => controller.snapshot.phase == CallUiPhase.listening,
      );
      expect(selectedVoice, klaudiaFishAudioReferenceId);
      expect(output.drains, 1);
      expect(app.callRecords.single.turns.single, {
        'user': '听得到吗？',
        'assistant': '听得到。',
      });
      expect(
        app.npcChats.threadFor('claudia').messages.map((m) => m.text),
        containsAllInOrder(['听得到吗？', '听得到。']),
      );
      await controller.endCall();
      controller.dispose();
      app.dispose();
      await directory.delete(recursive: true);
    },
  );

  test(
    'interrupt keeps only sentences whose AudioTrack drain completed',
    () async {
      SharedPreferences.setMockInitialValues({});
      final app = await AppController.load();
      app.configureAi(
        enabled: true,
        baseUrl: 'https://example.test/v1',
        model: 'model',
      );
      final output = _BlockingSecondDrainOutput();
      final fixture = await _callFixture(
        app,
        reply: '莱莎：第一句。第二句。',
        output: output,
      );
      final controller = fixture.controller;
      await controller.startCall('primary:ryza');
      await controller.sendText('继续说');
      await output.secondDrainStarted.future;
      await controller.interrupt();
      expect(controller.snapshot.phase, CallUiPhase.listening);
      expect(app.callRecords.single.turns.single, {
        'user': '继续说',
        'assistant': '第一句。',
      });
      final lastAssistant = app.messages
          .where((message) => !message.isUser)
          .last
          .text;
      expect(lastAssistant, contains('第一句。'));
      expect(lastAssistant, isNot(contains('第二句。')));
      await controller.endCall();
      controller.dispose();
      app.dispose();
      await fixture.directory.delete(recursive: true);
    },
  );

  test(
    'voice onset stops playback and queues a transcript during cancellation',
    () async {
      SharedPreferences.setMockInitialValues({});
      final app = await AppController.load();
      app.configureAi(
        enabled: true,
        baseUrl: 'https://example.test/v1',
        model: 'model',
      );
      final asr = _FakeAsr();
      final releaseStop = Completer<void>();
      final output = _BlockingSecondDrainOutput(
        stopBarrier: releaseStop.future,
      );
      var requests = 0;
      final fixture = await _callFixture(
        app,
        reply: '',
        output: output,
        asr: asr,
        backend: _CountingReplyBackend(() {
          requests++;
          return Stream.value(requests == 1 ? '莱莎：第一句。尚未播完。' : '莱莎：听到你的新问题了。');
        }),
      );
      final controller = fixture.controller;
      await controller.startCall('primary:ryza');
      await controller.sendText('先说两句');
      await output.secondDrainStarted.future;
      expect(asr.listeningEnabled, isTrue);
      asr.controller.add(
        const LocalCallAsrEvent(LocalCallAsrEventKind.speechStarted),
      );
      await _waitUntil(() => output.stops == 1);
      expect(controller.snapshot.phase, CallUiPhase.interrupted);
      asr.controller.add(
        const LocalCallAsrEvent(
          LocalCallAsrEventKind.transcript,
          text: '等等，换个问题',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(requests, 1);
      releaseStop.complete();
      await _waitUntil(
        () =>
            requests == 2 && controller.snapshot.phase == CallUiPhase.listening,
      );
      expect(app.callRecords.single.turns, [
        {'user': '先说两句', 'assistant': '第一句。'},
        {'user': '等等，换个问题', 'assistant': '听到你的新问题了。'},
      ]);
      expect(asr.preservedSpeech, isTrue);
      await controller.endCall();
      controller.dispose();
      app.dispose();
      await fixture.directory.delete(recursive: true);
    },
  );

  test(
    'user speech cancels thinking, while muted speech cannot interrupt',
    () async {
      SharedPreferences.setMockInitialValues({});
      final app = await AppController.load();
      app.configureAi(
        enabled: true,
        baseUrl: 'https://example.test/v1',
        model: 'model',
      );
      final asr = _FakeAsr();
      var cancelled = false;
      final pendingReply = StreamController<String>(
        onCancel: () {
          cancelled = true;
        },
      );
      final fixture = await _callFixture(
        app,
        reply: '',
        output: _FakeOutput(),
        asr: asr,
        backend: _ReplyBackend(pendingReply.stream),
      );
      final controller = fixture.controller;
      await controller.startCall('primary:ryza');
      await controller.sendText('问一个问题');
      await controller.setMuted(true);
      asr.controller.add(
        const LocalCallAsrEvent(LocalCallAsrEventKind.speechStarted),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.snapshot.phase, CallUiPhase.thinking);
      expect(cancelled, isFalse);
      await controller.setMuted(false);
      asr.controller.add(
        const LocalCallAsrEvent(LocalCallAsrEventKind.speechStarted),
      );
      await _waitUntil(
        () => cancelled && controller.snapshot.phase == CallUiPhase.listening,
      );
      expect(app.callRecords.single.turns, isEmpty);
      await controller.endCall();
      controller.dispose();
      app.dispose();
      await pendingReply.close();
      await fixture.directory.delete(recursive: true);
    },
  );

  test(
    'prepareForDataReset synchronously finalizes the old save record',
    () async {
      SharedPreferences.setMockInitialValues({});
      final app = await AppController.load();
      app.configureAi(
        enabled: true,
        baseUrl: 'https://example.test/v1',
        model: 'model',
      );
      final output = _BlockingSecondDrainOutput();
      final fixture = await _callFixture(
        app,
        reply: '莱莎：已经播放。还没播放。',
        output: output,
      );
      final controller = fixture.controller;
      await controller.startCall('primary:ryza');
      await controller.sendText('存档切换');
      await output.secondDrainStarted.future;
      controller.prepareForDataReset();
      expect(app.callRecords.single.status, CallHistoryStatus.cancelled);
      expect(app.callRecords.single.turns.single['assistant'], '已经播放。');
      await _waitUntil(() => output.stops > 0);
      controller.dispose();
      app.dispose();
      await fixture.directory.delete(recursive: true);
    },
  );

  test(
    'moving to background cancels the call and releases local capture',
    () async {
      SharedPreferences.setMockInitialValues({});
      final app = await AppController.load();
      app.configureAi(
        enabled: true,
        baseUrl: 'https://example.test/v1',
        model: 'model',
      );
      final fixture = await _callFixture(
        app,
        reply: '莱莎：稍后再聊。',
        output: _FakeOutput(),
      );
      final controller = fixture.controller;
      await controller.startCall('primary:ryza');

      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      await _waitUntil(
        () =>
            controller.snapshot.phase == CallUiPhase.failed &&
            app.callRecords.single.status == CallHistoryStatus.cancelled,
      );

      await _waitUntil(() => !(controller.asr as _FakeAsr).running);
      expect((controller.asr as _FakeAsr).running, isFalse);
      expect(controller.snapshot.error, contains('应用已进入后台'));
      controller.dispose();
      app.dispose();
      await fixture.directory.delete(recursive: true);
    },
  );

  test('old preparation cleanup cannot stop a newly started call', () async {
    SharedPreferences.setMockInitialValues({});
    final app = await AppController.load();
    app.configureAi(
      enabled: true,
      baseUrl: 'https://example.test/v1',
      model: 'model',
    );
    final output = _BlockingFirstStartOutput();
    final fixture = await _callFixture(app, reply: '莱莎：听得到。', output: output);
    final controller = fixture.controller;

    final oldPreparation = controller.startCall('primary:ryza');
    await output.firstStartEntered.future;
    controller.prepareForDataReset();
    final nextCall = controller.startCall('primary:ryza');
    await Future<void>.delayed(Duration.zero);
    expect(output.starts, 1);

    output.releaseFirstStart();
    await oldPreparation;
    await nextCall;

    expect(output.starts, 2);
    expect(output.stops, 1);
    expect(controller.snapshot.phase, CallUiPhase.listening);
    expect((controller.asr as _FakeAsr).running, isTrue);
    await controller.endCall();
    controller.dispose();
    app.dispose();
    await fixture.directory.delete(recursive: true);
  });

  test(
    'a failed reply reopens local recognition without repeating the POST',
    () async {
      SharedPreferences.setMockInitialValues({});
      final app = await AppController.load();
      app.configureAi(
        enabled: true,
        baseUrl: 'https://example.test/v1',
        model: 'model',
      );
      final asr = _FakeAsr();
      app.fishAudioReferenceId = 'voice';
      final directory = await Directory.systemTemp.createTemp('call-recovery-');
      final files = [
        File('${directory.path}/model.int8.onnx'),
        File('${directory.path}/tokens.txt'),
        File('${directory.path}/silero_vad.onnx'),
      ];
      for (final file in files) {
        await file.writeAsBytes([1]);
      }
      var requests = 0;
      final controller = RealtimeCallController(
        app: app,
        asr: asr,
        output: _FakeOutput(),
        replies: _CountingReplyBackend(() {
          requests++;
          return Stream<String>.error(StateError('upstream failed'));
        }),
        settingsStore: _SettingsStore(
          CallSettings(
            asr: LocalCallAsrConfig(
              modelPath: files[0].path,
              tokensPath: files[1].path,
              vadModelPath: files[2].path,
            ),
            voiceOverrides: const {'primary:ryza': 'voice'},
          ),
        ),
        readFishKey: () async => 'fish-key',
      );
      await controller.startCall('primary:ryza');
      await controller.sendText('能听见吗？');
      await _waitUntil(
        () => controller.snapshot.phase == CallUiPhase.listening,
      );
      expect(requests, 1);
      expect(asr.listeningEnabled, isTrue);
      expect(controller.snapshot.error, isNotNull);
      await controller.endCall();
      controller.dispose();
      app.dispose();
      await directory.delete(recursive: true);
    },
  );
}

Future<
  ({
    RealtimeCallController controller,
    CallPcmOutput output,
    Directory directory,
  })
>
_callFixture(
  AppController app, {
  required String reply,
  required CallPcmOutput output,
  CallReplyBackend? backend,
  List<String>? spoken,
  _FakeAsr? asr,
  CallSpeechFactory? speechFactory,
}) async {
  app.fishAudioReferenceId = 'voice';
  final directory = await Directory.systemTemp.createTemp('call-session-');
  final files = [
    File('${directory.path}/model.int8.onnx'),
    File('${directory.path}/tokens.txt'),
    File('${directory.path}/silero_vad.onnx'),
  ];
  for (final file in files) {
    await file.writeAsBytes([1]);
  }
  final controller = RealtimeCallController(
    app: app,
    asr: asr ?? _FakeAsr(),
    output: output,
    replies: backend ?? _ReplyBackend(Stream.value(reply)),
    settingsStore: _SettingsStore(
      CallSettings(
        asr: LocalCallAsrConfig(
          modelPath: files[0].path,
          tokensPath: files[1].path,
          vadModelPath: files[2].path,
        ),
        voiceOverrides: const {'primary:ryza': 'voice'},
      ),
    ),
    readFishKey: () async => 'fish-key',
    speechFactory:
        speechFactory ??
        (text, voice, model, key) {
          spoken?.add(text);
          return CallSpeech(
            Stream.value(Uint8List.fromList([0, 0, 0, 0])),
            () async {},
          );
        },
  );
  return (controller: controller, output: output, directory: directory);
}

Future<void> _waitUntil(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'condition did not settle');
}

class _FakeAsr extends LocalCallAsr {
  final controller = StreamController<LocalCallAsrEvent>.broadcast();
  bool running = false;
  bool listeningEnabled = true;
  bool preservedSpeech = false;
  @override
  Stream<LocalCallAsrEvent> get events => controller.stream;
  @override
  Future<void> start(LocalCallAsrConfig config) async => running = true;
  @override
  Future<void> stop() async => running = false;
  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> setListeningEnabled(bool enabled) async {
    listeningEnabled = enabled;
  }

  @override
  Future<void> setPlaybackActive(
    bool active, {
    bool preserveSpeech = false,
  }) async {
    preservedSpeech |= preserveSpeech;
  }

  @override
  void addPlaybackPcm(Uint8List pcm) {}

  @override
  Future<void> dispose() => controller.close();
}

class _FakeOutput implements CallPcmOutput {
  int drains = 0;
  @override
  Future<void> start() async {}
  @override
  Future<void> write(Uint8List pcm) async {}
  @override
  Future<void> drain() async => drains++;
  @override
  Future<void> stop() async {}
  @override
  Future<bool> setSpeaker(bool value) async => true;
}

class _RecordingOutput extends _FakeOutput {
  final values = <int>[];
  @override
  Future<void> write(Uint8List pcm) async => values.add(pcm.first);
}

class _BlockingSecondDrainOutput implements CallPcmOutput {
  _BlockingSecondDrainOutput({this.stopBarrier});
  final Future<void>? stopBarrier;
  final secondDrainStarted = Completer<void>();
  final _secondDrain = Completer<void>();
  int drains = 0, stops = 0;
  @override
  Future<void> start() async {}
  @override
  Future<void> write(Uint8List pcm) async {}
  @override
  Future<void> drain() {
    drains++;
    if (drains != 2) return Future.value();
    if (!secondDrainStarted.isCompleted) secondDrainStarted.complete();
    return _secondDrain.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (secondDrainStarted.isCompleted && !_secondDrain.isCompleted) {
      _secondDrain.completeError(StateError('playback cancelled'));
    }
    await stopBarrier;
  }

  @override
  Future<bool> setSpeaker(bool value) async => true;
}

class _BlockingFirstStartOutput implements CallPcmOutput {
  final firstStartEntered = Completer<void>();
  final _firstStart = Completer<void>();
  int starts = 0, stops = 0;

  @override
  Future<void> start() {
    starts++;
    if (starts != 1) return Future<void>.value();
    firstStartEntered.complete();
    return _firstStart.future;
  }

  void releaseFirstStart() {
    if (!_firstStart.isCompleted) _firstStart.complete();
  }

  @override
  Future<void> write(Uint8List pcm) async {}

  @override
  Future<void> drain() async {}

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<bool> setSpeaker(bool value) async => true;
}

class _ReplyBackend implements CallReplyBackend {
  _ReplyBackend(this.value);
  final Stream<String> value;
  @override
  Stream<String> reply(CallReplyRequest request) => value;
}

class _CountingReplyBackend implements CallReplyBackend {
  _CountingReplyBackend(this.create);
  final Stream<String> Function() create;
  @override
  Stream<String> reply(CallReplyRequest request) => create();
}

class _CaptionReplyBackend
    implements CallReplyBackend, CallCaptionTranslationBackend {
  _CaptionReplyBackend(this.replyText, {this.translation = '', this.pending});
  final String replyText, translation;
  final Completer<String>? pending;
  final translationStarted = Completer<void>();
  CallReplyRequest? request;
  TranslationLanguage? translationLanguage;
  int translations = 0;
  @override
  Stream<String> reply(CallReplyRequest request) {
    this.request = request;
    return Stream.value(replyText);
  }

  @override
  Future<String> translateCaption(
    CallReplyRequest request,
    String source,
    TranslationLanguage language,
  ) {
    translations++;
    translationLanguage = language;
    if (!translationStarted.isCompleted) translationStarted.complete();
    return pending?.future ?? Future.value(translation);
  }
}

class _SettingsStore extends CallSettingsStore {
  _SettingsStore(this.value);
  final CallSettings value;
  @override
  Future<CallSettings> load() async => value;
}
