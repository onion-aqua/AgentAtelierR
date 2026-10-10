import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/chat_screen.dart';
import 'package:ryza_chat_mvp/src/continuous_asmr_page.dart';
import 'package:ryza_chat_mvp/src/tts_spatial_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Run the real send/confirm and playback paths against loopback LLM/TTS. Only
// the native player is replaced; inspect the WAV actually handed to playback.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final audio = _AudioCapture();
  setUpAll(() async {
    audio.install();
    // Keep the plugin's static initialization future out of a widget test's
    // fake clock, otherwise the next test can await an inactive clock forever.
    await AudioPlayer.global.ensureInitialized();
  });
  tearDownAll(audio.uninstall);
  setUp(audio.reset);

  testWidgets(
    'normal replies play fixed left stereo even if settings change during TTS',
    (tester) async {
      final fixture = await _Fixture.create(
        tester,
        reply: '苏菲：「这是第一句轻声测试。」\n苏菲：「这是第二句轻声测试。」',
      );
      final controller = fixture.controller;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => ChatScreen(
              controller: controller,
              onMenuPressed: () {},
              onShopPressed: () {},
              hideUi: false,
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.hintText == '和苏菲说点什么…',
        ),
        '说两句话陪我聊聊吧。',
      );
      await tester.tap(find.byKey(const ValueKey('chat-send-button')));
      await _waitFor(tester, () => fixture.ttsRequests == 1);
      expect(audio.played, isEmpty);
      controller.configureTtsStereo(
        enabled: false,
        position: TtsStereoPosition.right,
      );
      fixture.releaseFirstTts();
      await _waitFor(tester, () => audio.played.length == 1);
      await audio.complete(audio.played.last.playerId);
      await _waitFor(tester, () => audio.played.length == 2);
      await audio.complete(audio.played.last.playerId);
      await _waitFor(
        tester,
        () =>
            tester
                    .widget<IconButton>(
                      find.byKey(const ValueKey('chat-send-button')),
                    )
                    .icon
                is Icon,
      );

      expect(fixture.streamedReplies, 1);
      expect(fixture.ttsRequests, 2);
      for (final played in audio.played) {
        _expectLeftStereo(played.bytes);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'continuous ASMR keeps all buffered and later clips at the session position',
    (tester) async {
      const script =
          '[whispering]雨落在窗边，声音很轻。你可以慢慢闭上眼睛，听一会儿。\n'
          '[breathy]我会留在这里，等这一阵雨慢慢过去，再陪你聊聊今天。\n'
          '[whispering]现在不用着急回答，安静地听着呼吸和窗外温柔的雨声。\n'
          '[breathy]等雨停了我们再一起出门，今天先好好地休息一会儿吧。';
      final fixture = await _Fixture.create(tester, reply: script);
      await tester.pumpWidget(
        MaterialApp(home: ContinuousAsmrPage(controller: fixture.controller)),
      );
      await tester.enterText(find.byType(TextField), '雨夜轻声陪伴');
      await tester.tap(find.text('确定'));
      await _waitFor(tester, () => fixture.ttsRequests == 1);
      fixture.controller.configureTtsStereo(
        enabled: false,
        position: TtsStereoPosition.right,
      );
      fixture.releaseFirstTts();
      await _waitFor(tester, () => fixture.ttsRequests == 3);
      await _waitFor(
        tester,
        () => find.text('雨夜轻声陪伴 · 3').evaluate().isNotEmpty,
      );
      expect(
        audio.played,
        isEmpty,
        reason: 'Confirm only buffers; it must not play',
      );
      expect(
        fixture.ttsRequests,
        3,
        reason: 'The fourth clip waits for buffer space',
      );
      await tester.ensureVisible(find.byTooltip('播放'));
      await tester.tap(find.byTooltip('播放'));
      await tester.pump();
      await _waitFor(tester, () => audio.played.length == 1);
      expect(find.byKey(const ValueKey('asmr-current-text')), findsOneWidget);
      for (var clip = 0; clip < 4; clip++) {
        await _waitFor(tester, () => audio.played.length == clip + 1);
        _expectLeftStereo(audio.played.last.bytes);
        await audio.complete(audio.played.last.playerId);
      }
      await _waitFor(tester, () => find.text('朗读结束').evaluate().isNotEmpty);
      expect(fixture.ttsRequests, 4);
      expect(audio.played, hasLength(4));
      expect(tester.takeException(), isNull);
    },
  );

  for (final badAudio in <String, Uint8List>{
    'truncated RIFF header': _truncatedWav(),
    'zero-frame WAV': _emptyWav(),
  }.entries) {
    testWidgets(
      'continuous ASMR retries ${badAudio.key} before handing audio to playback',
      (tester) async {
        final fixture = await _Fixture.create(
          tester,
          reply: '[whispering]雨声很轻，慢慢休息吧。',
          ttsResponses: [badAudio.value, _monoWav()],
        );
        await tester.pumpWidget(
          MaterialApp(home: ContinuousAsmrPage(controller: fixture.controller)),
        );
        await tester.enterText(find.byType(TextField), '雨夜轻声陪伴');
        await tester.tap(find.text('确定'));
        fixture.releaseFirstTts();
        await _waitFor(tester, () => fixture.ttsRequests == 2);
        await _waitFor(
          tester,
          () => find.text('雨夜轻声陪伴 · 1').evaluate().isNotEmpty,
        );

        expect(fixture.ttsTexts, hasLength(2));
        expect(fixture.ttsTexts[1], fixture.ttsTexts[0]);
        expect(audio.sources, isEmpty);
        expect(audio.played, isEmpty);
        final cached = await _speechCacheFiles(tester, fixture.directory);
        expect(cached, hasLength(1));
        expect(cached.single, endsWith('.balanced-stereo-left.wav'));
        await tester.ensureVisible(find.byTooltip('播放'));
        await tester.tap(find.byTooltip('播放'));
        await _waitFor(tester, () => audio.played.length == 1);
        _expectLeftStereo(audio.played.single.bytes);
        await audio.complete(audio.played.single.playerId);
        await _waitFor(tester, () => find.text('朗读结束').evaluate().isNotEmpty);
        expect(fixture.ttsRequests, 2);
        expect(audio.played, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'continuous ASMR stops after two invalid audio responses without setting source',
    (tester) async {
      final fixture = await _Fixture.create(
        tester,
        reply: '[whispering]雨声很轻，慢慢休息吧。',
        ttsResponses: [_truncatedWav(), _emptyWav()],
      );
      await tester.pumpWidget(
        MaterialApp(home: ContinuousAsmrPage(controller: fixture.controller)),
      );
      await tester.enterText(find.byType(TextField), '雨夜轻声陪伴');
      await tester.tap(find.text('确定'));
      fixture.releaseFirstTts();
      await _waitFor(tester, () => fixture.ttsRequests == 2);
      await _waitFor(
        tester,
        () => find.textContaining('失败').evaluate().isNotEmpty,
      );
      final status = tester
          .widgetList<Text>(find.textContaining('失败'))
          .map((text) => text.data ?? '')
          .join('\n');
      expect(status, contains('音频'));
      expect(status, contains('重试'));
      expect(fixture.ttsTexts, hasLength(2));
      expect(fixture.ttsTexts[1], fixture.ttsTexts[0]);
      expect(audio.sources, isEmpty);
      expect(audio.played, isEmpty);
      expect(await _speechCacheFiles(tester, fixture.directory), isEmpty);
      expect(find.text('雨夜轻声陪伴 · 1'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'continuous ASMR serializes rapid replay while a source is preparing',
    (tester) async {
      final fixture = await _Fixture.create(
        tester,
        reply: '[whispering]雨声很轻，慢慢休息吧。',
      );
      await tester.pumpWidget(
        MaterialApp(home: ContinuousAsmrPage(controller: fixture.controller)),
      );
      await tester.enterText(find.byType(TextField), '雨夜轻声陪伴');
      await tester.tap(find.text('确定'));
      fixture.releaseFirstTts();
      await _waitFor(
        tester,
        () => find.text('雨夜轻声陪伴 · 1').evaluate().isNotEmpty,
      );
      await tester.ensureVisible(find.byTooltip('播放'));
      await tester.tap(find.byTooltip('播放'));
      await _waitFor(tester, () => audio.played.length == 1);
      await audio.complete(audio.played.single.playerId);
      await _waitFor(tester, () => find.text('朗读结束').evaluate().isNotEmpty);

      // Queued taps can share the same frame and callback before the immersive
      // playback surface replaces the list. Hold native preparation to expose
      // concurrent attempts without relying on wall-clock timing.
      final replay = tester
          .widget<IconButton>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('asmr-voice-list')),
                  matching: find.byType(IconButton),
                )
                .first,
          )
          .onPressed!;
      final sourceGate = Completer<void>();
      final stopGate = Completer<void>();
      audio.sourceGate = sourceGate;
      audio.stopGate = stopGate;
      addTearDown(() {
        if (!sourceGate.isCompleted) sourceGate.complete();
        if (!stopGate.isCompleted) stopGate.complete();
      });
      final sourcesBefore = audio.sourcePreparations;
      replay();
      replay();
      replay();
      await _waitFor(tester, () => audio.inFlightSources == 1);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(audio.sourcePreparations, sourcesBefore + 1);
      expect(audio.maxInFlightSources, 1);
      expect(audio.played, hasLength(1));

      sourceGate.complete();
      stopGate.complete();
      await _waitFor(tester, () => audio.played.length == 2);
      _expectLeftStereo(audio.played.last.bytes);
      await audio.complete(audio.played.last.playerId);
      await _waitFor(tester, () => find.text('播放结束').evaluate().isNotEmpty);
      expect(audio.maxInFlightSources, 1);
      expect(fixture.ttsRequests, 1, reason: 'Replay reuses prepared audio');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'continuous ASMR survives native source error events and plays identical bytes',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final fixture = await _Fixture.create(
          tester,
          reply: '[whispering]雨声很轻，慢慢休息吧。',
        );
        await tester.pumpWidget(
          MaterialApp(home: ContinuousAsmrPage(controller: fixture.controller)),
        );
        await tester.enterText(find.byType(TextField), '雨夜轻声陪伴');
        await tester.tap(find.text('确定'));
        fixture.releaseFirstTts();
        await _waitFor(
          tester,
          () => find.text('雨夜轻声陪伴 · 1').evaluate().isNotEmpty,
        );
        audio.failFileSourceEvents = 1;
        await tester.ensureVisible(find.byTooltip('播放'));
        await tester.tap(find.byTooltip('播放'));
        await _waitFor(tester, () => audio.played.length == 1);
        expect(audio.failedFileBytes, hasLength(1));
        expect(audio.byteSources, hasLength(1));
        expect(audio.releaseCount, 1);
        expect(
          audio.played.single.bytes,
          orderedEquals(audio.failedFileBytes.single),
        );
        _expectLeftStereo(audio.played.single.bytes);
        expect(find.byKey(const ValueKey('asmr-current-text')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await audio.complete(audio.played.single.playerId);
        await _waitFor(tester, () => find.text('朗读结束').evaluate().isNotEmpty);
        expect(
          fixture.ttsRequests,
          1,
          reason: 'Playback retry reuses the same audio',
        );
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'continuous ASMR reports native errors after playback has started',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final fixture = await _Fixture.create(
          tester,
          reply: '[whispering]雨声很轻，慢慢休息吧。',
        );
        await tester.pumpWidget(
          MaterialApp(home: ContinuousAsmrPage(controller: fixture.controller)),
        );
        await tester.enterText(find.byType(TextField), '雨夜轻声陪伴');
        await tester.tap(find.text('确定'));
        fixture.releaseFirstTts();
        await _waitFor(
          tester,
          () => find.text('雨夜轻声陪伴 · 1').evaluate().isNotEmpty,
        );
        await tester.ensureVisible(find.byTooltip('播放'));
        await tester.tap(find.byTooltip('播放'));
        await _waitFor(tester, () => audio.played.length == 1);
        await tester.pump();
        await audio.error(audio.played.single.playerId);
        await _waitFor(
          tester,
          () => find.textContaining('已停止，请重试').evaluate().isNotEmpty,
        );
        expect(find.byKey(const ValueKey('asmr-current-text')), findsNothing);
        expect(audio.byteSources, isEmpty);
        expect(audio.played, hasLength(1));
        expect(fixture.ttsRequests, 1);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  for (final completesAfterError in [false, true]) {
    testWidgets(
      'continuous ASMR catches resume event errors with completion=$completesAfterError',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          final fixture = await _Fixture.create(
            tester,
            reply: '[whispering]雨声很轻，慢慢休息吧。',
          );
          await tester.pumpWidget(
            MaterialApp(home: ContinuousAsmrPage(controller: fixture.controller)),
          );
          await tester.enterText(find.byType(TextField), '雨夜轻声陪伴');
          await tester.tap(find.text('确定'));
          fixture.releaseFirstTts();
          await _waitFor(
            tester,
            () => find.text('雨夜轻声陪伴 · 1').evaluate().isNotEmpty,
          );

          // A prepared MediaPlayer can report an EventChannel error while the
          // resume method is still pending, then return success on that method.
          // Some backends also emit completion after that error. Neither case
          // may wait for the ten-minute timeout or count as completed speech.
          audio.failResumeEvents = 1;
          audio.completeAfterResumeError = completesAfterError;
          await tester.ensureVisible(find.byTooltip('播放'));
          await tester.tap(find.byTooltip('播放'));
          await _waitFor(
            tester,
            () => find.textContaining('已停止，请重试').evaluate().isNotEmpty,
          );
          expect(find.byKey(const ValueKey('asmr-current-text')), findsNothing);
          expect(find.text('朗读结束'), findsNothing);
          expect(audio.byteSources, isEmpty);
          expect(audio.releaseCount, 0);
          expect(audio.played, hasLength(1));
          expect(fixture.ttsRequests, 1);
          expect(tester.takeException(), isNull);

          // Replay shares the same prepare/resume boundary and must preserve
          // the failure instead of showing a successful playback status.
          audio.failResumeEvents = 1;
          final replay = find.descendant(
            of: find.byKey(const ValueKey('asmr-voice-list')),
            matching: find.byType(IconButton),
          ).first;
          await tester.ensureVisible(replay);
          await tester.tap(replay);
          await _waitFor(
            tester,
            () => find.textContaining('播放失败').evaluate().isNotEmpty,
          );
          expect(find.byKey(const ValueKey('asmr-current-text')), findsNothing);
          expect(find.text('播放结束'), findsNothing);
          expect(audio.byteSources, isEmpty);
          expect(audio.releaseCount, 0);
          expect(audio.played, hasLength(2));
          expect(fixture.ttsRequests, 1);
          expect(tester.takeException(), isNull);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}

Future<void> _waitFor(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 160 && !condition(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue, reason: 'Loopback speech playback timed out');
}

Future<List<String>> _speechCacheFiles(
  WidgetTester tester,
  Directory directory,
) async => (await tester.runAsync(
  () => directory
      .list()
      .where((entry) => entry is File && entry.path.contains('fish_tts_'))
      .map((entry) => entry.path)
      .toList(),
))!;

class _Fixture {
  _Fixture(this.controller, this.server, this.serving, this.directory);
  final AppController controller;
  final HttpServer server;
  final StreamSubscription<HttpRequest> serving;
  final Directory directory;
  final firstTts = Completer<void>();
  final ttsTexts = <String>[];
  int ttsRequests = 0;
  int streamedReplies = 0;

  void releaseFirstTts() {
    if (!firstTts.isCompleted) firstTts.complete();
  }

  static Future<_Fixture> create(
    WidgetTester tester, {
    required String reply,
    List<Uint8List>? ttsResponses,
  }) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final originalOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('tts_stereo_playback_'),
    ))!;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
    final server = (await tester.runAsync(
      () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    ))!;
    late final _Fixture fixture;
    final serving = server.listen((request) async {
      request.response.persistentConnection = false;
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (request.uri.path == '/tts') {
        fixture.ttsRequests++;
        fixture.ttsTexts.add(data['text'] as String);
        if (fixture.ttsRequests == 1) await fixture.firstTts.future;
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.add(
          ttsResponses == null
              ? _monoWav()
              : ttsResponses[min(
                  fixture.ttsRequests - 1,
                  ttsResponses.length - 1,
                )],
        );
      } else if (data['stream'] == true) {
        fixture.streamedReplies++;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': reply},
              },
            ],
          })}\n\ndata: [DONE]\n\n',
        );
      } else {
        // Only the ASMR script request receives speech. Auxiliary character
        // planners receive a graceful empty plan, so no assets are required.
        final messages = data['messages'] as List;
        final asmr = messages.any(
          (message) =>
              (message as Map)['content'].toString().contains('持续ASMR陪伴'),
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': asmr ? reply : '{"segments":[]}'},
              },
            ],
          }),
        );
      }
      await request.response.close();
    });
    SharedPreferences.setMockInitialValues({
      'active_character_id_v1': 'sophie',
      'ai_enabled': true,
      'fish_tts_enabled': true,
      'openai_base_url': 'http://127.0.0.1:${server.port}/v1',
    });
    FlutterSecureStorage.setMockInitialValues({
      'openai_api_key': 'loopback-only',
      'fish_audio_api_key': 'loopback-only',
    });
    final controller = (await tester.runAsync(() => AppController.load()))!;
    controller.agentEnabled = false;
    controller.independentSpeechPerformance = false;
    controller.longTermMemoryEnabled = false;
    controller.fishAudioBaseUrl = 'http://127.0.0.1:${server.port}/tts';
    controller.configureLanguages(
      interface: AppLanguage.chinese,
      narrator: AppLanguage.chinese,
      characterReply: AppLanguage.chinese,
      translation: TranslationLanguage.none,
    );
    controller.configureTtsStereo(
      enabled: true,
      position: TtsStereoPosition.left,
    );
    fixture = _Fixture(controller, server, serving, directory);
    addTearDown(() async {
      fixture.releaseFirstTts();
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.runAsync(() async {
        await server.close(force: true);
        await serving.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await directory.delete(recursive: true);
      });
      messenger.setMockMethodCallHandler(paths, null);
      HttpOverrides.global = originalOverrides;
    });
    return fixture;
  }
}

class _PlayedAudio {
  const _PlayedAudio(this.playerId, this.bytes);
  final String playerId;
  final Uint8List bytes;
}

class _AudioCapture {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channels = <String>{
    'xyz.luan/audioplayers.global',
    'xyz.luan/audioplayers.global/events',
    'xyz.luan/audioplayers',
  };
  final sources = <String, String>{};
  final played = <_PlayedAudio>[];
  final byteSources = <String, Uint8List>{};
  final failedFileBytes = <Uint8List>[];
  int failFileSourceEvents = 0;
  int failResumeEvents = 0;
  bool completeAfterResumeError = false;
  int releaseCount = 0;
  Completer<void>? sourceGate;
  Completer<void>? stopGate;
  int sourcePreparations = 0;
  int inFlightSources = 0;
  int maxInFlightSources = 0;

  void reset() {
    sources.clear();
    played.clear();
    byteSources.clear();
    failedFileBytes.clear();
    failFileSourceEvents = 0;
    failResumeEvents = 0;
    completeAfterResumeError = false;
    releaseCount = 0;
    sourceGate = null;
    stopGate = null;
    sourcePreparations = 0;
    inFlightSources = 0;
    maxInFlightSources = 0;
  }

  void install() {
    for (final name in channels) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        final args = call.arguments as Map;
        final playerId = args['playerId'] as String;
        switch (call.method) {
          case 'create':
            final channel = 'xyz.luan/audioplayers/events/$playerId';
            channels.add(channel);
            messenger.setMockMethodCallHandler(
              MethodChannel(channel),
              (_) async => null,
            );
          case 'setSourceUrl':
            sourcePreparations++;
            inFlightSources++;
            maxInFlightSources = max(maxInFlightSources, inFlightSources);
            try {
              await sourceGate?.future;
              sources[playerId] = args['url'] as String;
              byteSources.remove(playerId);
              if (failFileSourceEvents > 0) {
                failFileSourceEvents--;
                failedFileBytes.add(
                  await File(sources[playerId]!).readAsBytes(),
                );
                await error(playerId);
              } else {
                await _event(playerId, {
                  'event': 'audio.onPrepared',
                  'value': true,
                });
              }
            } finally {
              inFlightSources--;
            }
          case 'setSourceBytes':
            byteSources[playerId] = args['bytes'] as Uint8List;
            await _event(playerId, {
              'event': 'audio.onPrepared',
              'value': true,
            });
          case 'stop':
            await stopGate?.future;
          case 'release':
            releaseCount++;
            sources.remove(playerId);
            byteSources.remove(playerId);
          case 'resume':
            final path = sources[playerId];
            final bytes = byteSources[playerId];
            if (bytes != null) {
              played.add(_PlayedAudio(playerId, bytes));
            } else if (path != null && path.contains('fish_tts')) {
              played.add(
                _PlayedAudio(playerId, await File(path).readAsBytes()),
              );
            }
            if (failResumeEvents > 0) {
              failResumeEvents--;
              await error(playerId);
              if (completeAfterResumeError) await complete(playerId);
            }
          case 'getDuration':
            return 250;
          case 'getCurrentPosition':
            return 0;
        }
        return null;
      },
    );
  }

  Future<void> complete(String playerId) =>
      _event(playerId, {'event': 'audio.onComplete'});

  Future<void> error(String playerId) => messenger.handlePlatformMessage(
    'xyz.luan/audioplayers/events/$playerId',
    const StandardMethodCodec().encodeErrorEnvelope(
      code: 'AndroidAudioError',
      message: 'Failed to set source',
      details: 'MEDIA_ERROR_UNKNOWN {what:13}, MEDIA_ERROR_SYSTEM',
    ),
    (_) {},
  );

  Future<void> _event(String playerId, Map<String, Object> value) =>
      messenger.handlePlatformMessage(
        'xyz.luan/audioplayers/events/$playerId',
        const StandardMethodCodec().encodeSuccessEnvelope(value),
        (_) {},
      );

  void uninstall() {
    for (final name in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  }
}

Uint8List _monoWav() {
  const rate = 8000;
  const frames = rate ~/ 4;
  final bytes = Uint8List(44 + frames * 2);
  final data = ByteData.sublistView(bytes);
  for (final entry in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    bytes.setRange(entry.key, entry.key + 4, entry.value.codeUnits);
  }
  data.setUint32(4, bytes.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, frames * 2, Endian.little);
  for (var frame = 0; frame < frames; frame++) {
    final sample =
        6000 * sin(frame * 2 * pi * 440 / rate) +
        1200 * sin(frame * 2 * pi * 1300 / rate);
    data.setInt16(44 + frame * 2, sample.round(), Endian.little);
  }
  return bytes;
}

Uint8List _truncatedWav() {
  final bytes = Uint8List(12);
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  bytes.setRange(8, 12, 'WAVE'.codeUnits);
  ByteData.sublistView(bytes).setUint32(4, 4, Endian.little);
  return bytes;
}

Uint8List _emptyWav() {
  final bytes = Uint8List.fromList(_monoWav().sublist(0, 44));
  final header = ByteData.sublistView(bytes);
  header.setUint32(4, 36, Endian.little);
  header.setUint32(40, 0, Endian.little);
  return bytes;
}

void _expectLeftStereo(Uint8List bytes) {
  final wave = ByteData.sublistView(bytes);
  expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
  expect(wave.getUint16(22, Endian.little), 2);
  expect(wave.getUint32(24, Endian.little), 8000);
  expect(wave.getUint16(32, Endian.little), 4);
  expect(wave.getUint32(40, Endian.little), 2000 * 4);
  var leftEnergy = 0.0;
  var rightEnergy = 0.0;
  for (var offset = 44; offset < bytes.length; offset += 4) {
    final left = wave.getInt16(offset, Endian.little);
    final right = wave.getInt16(offset + 2, Endian.little);
    leftEnergy += left * left;
    rightEnergy += right * right;
  }
  expect(rightEnergy, greaterThan(0));
  expect(leftEnergy, greaterThan(rightEnergy * 2));
}
