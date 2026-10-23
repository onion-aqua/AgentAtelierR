import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_audio.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_reply.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_session.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_settings.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_ui_models.dart';
import 'package:ryza_chat_mvp/src/realtime_call/local_call_asr.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final provider in [TtsProvider.fishAudio, TtsProvider.fishAudioMcp]) {
    test(
      '$provider uses Ryza built-in ordinary voice with no custom ID',
      () async {
        final fixture = await _ProviderFixture.create(provider);
        addTearDown(fixture.dispose);
        fixture.app.fishAudioReferenceId = '';
        fixture.app.fishMcpVoice = '';
        // Calls always use the ordinary voice, even if the chat was in ASMR.
        fixture.app.setTtsVoiceMode(TtsVoiceMode.asmr);
        await fixture.controller.startCall('primary:ryza');
        await fixture.playTurn();
        final requests = provider == TtsProvider.fishAudio
            ? fixture.restRequests
            : fixture.mcpRequests;
        expect(requests.single.voice, '1380fd182e0f44639df49e1ae8feeed8');
        expect(fixture.controller.snapshot.phase, CallUiPhase.listening);
      },
    );
  }

  test(
    'sleeping character explains how to unlock calls without starting audio',
    () async {
      final fixture = await _ProviderFixture.create(TtsProvider.fishAudioMcp);
      addTearDown(fixture.dispose);
      fixture.app.startColdLaunchGreeting();
      await fixture.controller.startCall('primary:ryza');
      expect(fixture.controller.snapshot.error, contains('叫醒莱莎'));
      expect(fixture.asr.starts, 0);
      expect(fixture.preparedModels, isEmpty);
      expect(fixture.keyReads, 0);
      expect(fixture.mcpRequests, isEmpty);
    },
  );

  test(
    'MCP Drama 3 inherits its own voice/model without reading REST key',
    () async {
      final fixture = await _ProviderFixture.create(TtsProvider.fishAudioMcp);
      addTearDown(fixture.dispose);
      await fixture.controller.startCall('primary:ryza');
      expect(fixture.controller.snapshot.phase, CallUiPhase.listening);
      expect(fixture.preparedModels, ['drama-3']);
      expect(fixture.keyReads, 0);
      await fixture.playTurn();
      expect(fixture.mcpRequests, hasLength(1));
      expect(fixture.mcpRequests.single, (
        text: '听得到。',
        voice: 'mcp-normal-voice',
        model: 'drama-3',
        key: '',
      ));
      expect(fixture.restRequests, isEmpty);
      expect(fixture.keyReads, 0);
    },
  );

  test('REST uses only its REST key and ordinary voice/model', () async {
    final fixture = await _ProviderFixture.create(TtsProvider.fishAudio);
    addTearDown(fixture.dispose);
    await fixture.controller.startCall('primary:ryza');
    expect(fixture.controller.snapshot.phase, CallUiPhase.listening);
    expect(fixture.keyReads, 1);
    expect(fixture.preparedModels, isEmpty);
    await fixture.playTurn();
    expect(fixture.restRequests.single, (
      text: '听得到。',
      voice: 'rest-normal-voice',
      model: 's2.1-pro',
      key: 'independent-rest-key',
    ));
    expect(fixture.mcpRequests, isEmpty);
  });

  test('legacy overrides cannot replace shared MCP model or voice', () async {
    final fixture = await _ProviderFixture.create(
      TtsProvider.fishAudioMcp,
      callModel: 'call-specific-backend',
      callVoice: 'call-specific-voice',
    );
    addTearDown(fixture.dispose);
    await fixture.controller.startCall('primary:ryza');
    await fixture.playTurn();
    expect(fixture.preparedModels, ['drama-3']);
    expect(fixture.mcpRequests.single.model, 'drama-3');
    expect(fixture.mcpRequests.single.voice, 'mcp-normal-voice');
    expect(fixture.keyReads, 0);
    expect(fixture.restRequests, isEmpty);
  });

  test(
    'MCP setup failure never reads REST key or starts a paid request',
    () async {
      final fixture = await _ProviderFixture.create(
        TtsProvider.fishAudioMcp,
        preparationError: StateError('MCP is not connected'),
      );
      addTearDown(fixture.dispose);
      await fixture.controller.startCall('primary:ryza');
      expect(fixture.controller.snapshot.phase, CallUiPhase.failed);
      expect(fixture.preparedModels, ['drama-3']);
      expect(fixture.keyReads, 0);
      expect(fixture.mcpRequests, isEmpty);
      expect(fixture.restRequests, isEmpty);
      expect(fixture.asr.starts, 0);
    },
  );

  test(
    'ending a call during MCP recovery never starts audio or generation',
    () async {
      final preparation = Completer<void>();
      final fixture = await _ProviderFixture.create(
        TtsProvider.fishAudioMcp,
        preparationWait: preparation.future,
      );
      addTearDown(fixture.dispose);
      final connecting = fixture.controller.startCall('primary:ryza');
      await _until(() => fixture.preparedModels.isNotEmpty);
      expect(fixture.controller.snapshot.phase, CallUiPhase.preparing);
      await fixture.controller.endCall();
      preparation.complete();
      await connecting;

      expect(fixture.controller.snapshot.isActive, isFalse);
      expect(fixture.asr.starts, 0);
      expect(fixture.keyReads, 0);
      expect(fixture.mcpRequests, isEmpty);
      expect(fixture.restRequests, isEmpty);
    },
  );

  test(
    'MCP synthesis error is attempted once without enabled REST fallback',
    () async {
      final fixture = await _ProviderFixture.create(
        TtsProvider.fishAudioMcp,
        synthesisError: StateError('submitted MCP generation result unknown'),
      );
      addTearDown(fixture.dispose);
      expect(fixture.app.fishMcpAutoFallback, isTrue);
      await fixture.controller.startCall('primary:ryza');
      await fixture.playTurn();
      expect(fixture.mcpRequests, hasLength(1));
      expect(fixture.restRequests, isEmpty);
      expect(fixture.keyReads, 0);
      expect(fixture.controller.snapshot.error, isNotEmpty);
      expect(fixture.output.drains, 0);
    },
  );

  test('missing REST key cannot borrow an MCP connection', () async {
    final fixture = await _ProviderFixture.create(
      TtsProvider.fishAudio,
      restKey: '',
    );
    addTearDown(fixture.dispose);
    await fixture.controller.startCall('primary:ryza');
    expect(fixture.controller.snapshot.phase, CallUiPhase.failed);
    expect(fixture.keyReads, 1);
    expect(fixture.preparedModels, isEmpty);
    expect(fixture.mcpRequests, isEmpty);
    expect(fixture.restRequests, isEmpty);
  });

  test(
    'unsupported provider is rejected without hidden Fish REST routing',
    () async {
      final fixture = await _ProviderFixture.create(TtsProvider.generic);
      addTearDown(fixture.dispose);
      await fixture.controller.startCall('primary:ryza');
      expect(fixture.controller.snapshot.phase, CallUiPhase.failed);
      expect(fixture.keyReads, 0);
      expect(fixture.preparedModels, isEmpty);
      expect(fixture.mcpRequests, isEmpty);
      expect(fixture.restRequests, isEmpty);
      expect(fixture.asr.starts, 0);
    },
  );

  for (final initial in [TtsProvider.fishAudioMcp, TtsProvider.fishAudio]) {
    test(
      'switching ${initial.name} while speaking closes the old route',
      () async {
        final fixture = await _ProviderFixture.create(initial, holdDrain: true);
        addTearDown(fixture.dispose);
        await fixture.controller.startCall('primary:ryza');
        await fixture.controller.sendText('能听到吗？');
        await fixture.output.drainStarted.future;
        expect(fixture.controller.snapshot.phase, CallUiPhase.speaking);
        fixture.app.setTtsProvider(
          initial == TtsProvider.fishAudioMcp
              ? TtsProvider.fishAudio
              : TtsProvider.fishAudioMcp,
        );
        await _until(() => !fixture.controller.snapshot.isActive);
        await fixture.controller.endCall();
        final attempts =
            fixture.mcpRequests.length + fixture.restRequests.length;
        expect(attempts, 1);
        expect(fixture.speechCancellations, greaterThanOrEqualTo(1));
        expect(fixture.asr.running, isFalse);
        expect(fixture.output.stops, greaterThanOrEqualTo(1));
        await fixture.controller.sendText('不应再生成');
        await Future<void>.delayed(Duration.zero);
        expect(
          fixture.mcpRequests.length + fixture.restRequests.length,
          attempts,
        );
        expect(
          fixture.preparedModels.length,
          initial == TtsProvider.fishAudioMcp ? 1 : 0,
        );
        expect(fixture.keyReads, initial == TtsProvider.fishAudio ? 1 : 0);
      },
    );
  }

  testWidgets('MCP call settings explain OAuth without requiring a REST key', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const MaterialApp(
        home: RealtimeCallSettingsPage(ttsProvider: TtsProvider.fishAudioMcp),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('call-voice-provider')),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    final notice = tester
        .widget<Text>(find.byKey(const ValueKey('call-voice-provider')))
        .data!;
    expect(notice, contains('Fish Audio MCP'));
    expect(notice, contains('不读取 REST API Key'));
    expect(notice, contains('不自动回退'));
    expect(find.byKey(const ValueKey('call-fish-model')), findsNothing);
    expect(find.byType(ActionChip), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
  });
}

typedef _SpeechRequest = ({
  String text,
  String voice,
  String model,
  String key,
});

class _ProviderFixture {
  _ProviderFixture(this.app, this.directory, this.asr, this.output);

  final AppController app;
  final Directory directory;
  final _ProviderAsr asr;
  final _ProviderOutput output;
  late final RealtimeCallController controller;
  final preparedModels = <String>[];
  final restRequests = <_SpeechRequest>[];
  final mcpRequests = <_SpeechRequest>[];
  int keyReads = 0;
  int speechCancellations = 0;

  static Future<_ProviderFixture> create(
    TtsProvider provider, {
    String callModel = '',
    String? callVoice,
    String restKey = 'independent-rest-key',
    Object? preparationError,
    Future<void>? preparationWait,
    Object? synthesisError,
    bool holdDrain = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final app = await AppController.load();
    app.configureAi(
      enabled: true,
      baseUrl: 'https://example.test/v1',
      model: 'test-llm',
    );
    app.configureLanguages(
      interface: AppLanguage.chinese,
      narrator: AppLanguage.chinese,
      characterReply: AppLanguage.chinese,
      translation: TranslationLanguage.none,
    );
    app.fishAudioModel = 's2.1-pro';
    app.fishAudioReferenceId = 'rest-normal-voice';
    app.configureFishMcp(
      model: 'drama-3',
      voice: 'mcp-normal-voice',
      asmrVoice: 'mcp-asmr-voice',
      autoFallback: true,
    );
    app.setTtsProvider(provider);
    final directory = await Directory.systemTemp.createTemp('call-provider-');
    final files = [
      File('${directory.path}/model.int8.onnx'),
      File('${directory.path}/tokens.txt'),
      File('${directory.path}/silero_vad.onnx'),
    ];
    for (final file in files) {
      await file.writeAsBytes([1]);
    }
    final fixture = _ProviderFixture(
      app,
      directory,
      _ProviderAsr(),
      _ProviderOutput(holdDrain),
    );
    fixture.controller = RealtimeCallController(
      app: app,
      asr: fixture.asr,
      output: fixture.output,
      replies: const _ProviderReplies(),
      settingsStore: _ProviderSettingsStore(
        CallSettings(
          asr: LocalCallAsrConfig(
            modelPath: files[0].path,
            tokensPath: files[1].path,
            vadModelPath: files[2].path,
          ),
          fishModel: callModel,
          voiceOverrides: {'primary:ryza': ?callVoice},
        ),
      ),
      readFishKey: () async {
        fixture.keyReads++;
        return restKey;
      },
      prepareMcp: (model) async {
        fixture.preparedModels.add(model);
        if (preparationWait != null) await preparationWait;
        if (preparationError != null) throw preparationError;
      },
      speechFactory: (text, voice, model, key) {
        fixture.restRequests.add((
          text: text,
          voice: voice,
          model: model,
          key: key,
        ));
        return fixture.speech();
      },
      mcpSpeechFactory: (text, voice, model, key) {
        fixture.mcpRequests.add((
          text: text,
          voice: voice,
          model: model,
          key: key,
        ));
        return fixture.speech(error: synthesisError);
      },
    );
    return fixture;
  }

  CallSpeech speech({Object? error}) => CallSpeech(
    error == null
        ? Stream.value(Uint8List.fromList([0, 0, 0, 0]))
        : Stream<Uint8List>.error(error),
    () async {
      speechCancellations++;
    },
  );

  Future<void> playTurn() async {
    expect(controller.snapshot.phase, CallUiPhase.listening);
    await controller.sendText('能听到吗？');
    await _until(
      () =>
          controller.snapshot.phase == CallUiPhase.listening ||
          controller.snapshot.phase == CallUiPhase.failed,
    );
  }

  Future<void> dispose() async {
    await controller.endCall();
    controller.dispose();
    app.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

Future<void> _until(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100 && !predicate(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(predicate(), isTrue, reason: 'call provider operation did not settle');
}

class _ProviderSettingsStore extends CallSettingsStore {
  _ProviderSettingsStore(this.settings);
  final CallSettings settings;
  @override
  Future<CallSettings> load() async => settings;
}

class _ProviderReplies implements CallReplyBackend {
  const _ProviderReplies();
  @override
  Stream<String> reply(CallReplyRequest request) => Stream.value('莱莎：听得到。');
}

class _ProviderAsr extends LocalCallAsr {
  final _events = StreamController<LocalCallAsrEvent>.broadcast();
  bool running = false;
  int starts = 0;
  @override
  Stream<LocalCallAsrEvent> get events => _events.stream;
  @override
  Future<void> start(LocalCallAsrConfig config) async {
    starts++;
    running = true;
  }

  @override
  Future<void> stop() async {
    running = false;
  }

  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> setListeningEnabled(bool enabled) async {}
  @override
  Future<void> setPlaybackActive(
    bool active, {
    bool preserveSpeech = true,
  }) async {}
  @override
  void addPlaybackPcm(Uint8List pcm) {}
  @override
  Future<void> dispose() => _events.close();
}

class _ProviderOutput implements CallPcmOutput {
  _ProviderOutput(this.holdDrain);
  final bool holdDrain;
  final drainStarted = Completer<void>();
  final _pendingDrain = Completer<void>();
  int drains = 0, stops = 0;
  @override
  Future<void> start() async {}
  @override
  Future<void> write(Uint8List pcm) async {}
  @override
  Future<void> drain() {
    drains++;
    if (!drainStarted.isCompleted) drainStarted.complete();
    return holdDrain ? _pendingDrain.future : Future<void>.value();
  }

  @override
  Future<void> stop() async {
    stops++;
    if (holdDrain && drainStarted.isCompleted && !_pendingDrain.isCompleted) {
      _pendingDrain.completeError(StateError('playback cancelled'));
    }
  }

  @override
  Future<bool> setSpeaker(bool value) async => true;
}
