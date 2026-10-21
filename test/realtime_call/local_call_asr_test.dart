import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/realtime_call/local_call_asr.dart';
import 'package:ryza_chat_mvp/src/realtime_call/local_call_asr_worker.dart';
import 'package:ryza_chat_mvp/src/realtime_call/local_call_echo_filter.dart';

class _Microphone implements LocalCallMicrophone {
  final audio = StreamController<Uint8List>.broadcast();
  bool permission = true;
  bool paused = false;
  Object? pauseError;
  Object? stopError;
  int disposals = 0;
  int starts = 0;
  int stops = 0;
  @override
  Future<bool> hasPermission() async => permission;
  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    return audio.stream;
  }

  @override
  Future<void> setPaused(bool value) async {
    if (pauseError case final error?) throw error;
    paused = value;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (stopError case final error?) throw error;
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await audio.close();
  }
}

class _Engine implements LocalCallAsrEngine {
  final output = StreamController<LocalCallAsrEvent>.broadcast();
  final received = <({Uint8List bytes, int epoch})>[];
  Completer<void>? loading;
  int epoch = 0;
  bool disposed = false;
  @override
  Stream<LocalCallAsrEvent> get events => output.stream;
  @override
  Future<void> start(LocalCallAsrConfig config) async => loading?.future;
  @override
  void addPcm(Uint8List bytes, int epoch) =>
      received.add((bytes: bytes, epoch: epoch));
  @override
  void reset(int value) => epoch = value;
  @override
  Future<void> dispose() async {
    disposed = true;
    await output.close();
  }
}

void main() {
  late Directory directory;
  late LocalCallAsrConfig config;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ryza-local-call-asr-');
    final files = ['model.int8.onnx', 'tokens.txt', 'silero_vad.onnx'];
    for (final name in files) {
      await File('${directory.path}/$name').writeAsBytes([1]);
    }
    config = LocalCallAsrConfig(
      modelPath: '${directory.path}/${files[0]}',
      tokensPath: '${directory.path}/${files[1]}',
      vadModelPath: '${directory.path}/${files[2]}',
      language: 'ja',
    );
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'configuration round trips and validates imported local files',
    () async {
      final copy = LocalCallAsrConfig.fromJson(config.toJson());
      expect(copy.toJson(), config.toJson());
      await copy.validateFiles();
      await File(copy.vadModelPath).writeAsBytes([]);
      await expectLater(copy.validateFiles(), throwsFormatException);
    },
  );

  test(
    'invalid language and silence cannot reach native initialization',
    () async {
      for (final values in [
        {'language': 'unknown'},
        {'silenceSeconds': double.nan},
        {'silenceSeconds': 0.1},
        {'silenceSeconds': 5},
      ]) {
        final invalid = LocalCallAsrConfig.fromJson({
          ...config.toJson(),
          ...values,
        });
        await expectLater(invalid.validateFiles(), throwsFormatException);
      }
    },
  );

  test('PCM decoder retains split little endian signed samples', () {
    final decoder = LocalCallPcm16Decoder();
    expect(decoder.decode(Uint8List.fromList([0])), isEmpty);
    expect(decoder.decode(Uint8List(0)), isEmpty);
    expect(decoder.decode(Uint8List.fromList([128, 255, 127, 0])), [
      -1,
      32767 / 32768,
    ]);
    expect(decoder.decode(Uint8List.fromList([0])), [0]);
    decoder.decode(Uint8List.fromList([255]));
    decoder.reset();
    expect(decoder.decode(Uint8List.fromList([0, 0])), [0]);
  });

  test('mute and playback gate invalidate late recognition results', () {
    final gate = LocalCallAsrGate();
    final originalEpoch = gate.epoch;
    expect(gate.acceptsResult(originalEpoch), isTrue);
    gate.muted = true;
    gate.reset();
    expect(gate.acceptsResult(originalEpoch), isFalse);
    gate.muted = false;
    expect(gate.acceptsResult(originalEpoch), isFalse);
    gate.listeningEnabled = false;
    expect(gate.acceptsResult(gate.epoch), isFalse);
    gate.listeningEnabled = true;
    gate.captureReady = false;
    expect(gate.wantsAudio, isTrue);
    expect(gate.acceptsAudio, isFalse);
  });

  test(
    'capture transition stays closed until resume succeeds and fails closed',
    () async {
      final mic = _Microphone();
      final engine = _Engine();
      final asr = LocalCallAsr(microphone: mic, engineFactory: () => engine);
      final failures = <LocalCallAsrEvent>[];
      final sub = asr.events.listen((event) {
        if (event.kind == LocalCallAsrEventKind.error) failures.add(event);
      });
      await asr.start(config);
      await asr.setListeningEnabled(false);
      expect(mic.paused, isTrue);

      mic.pauseError = StateError('resume failed');
      await expectLater(asr.setListeningEnabled(true), throwsStateError);
      mic.audio.add(Uint8List.fromList([0, 0]));
      await Future<void>.delayed(Duration.zero);

      expect(asr.isRunning, isFalse);
      expect(engine.received, isEmpty);
      expect(failures.single.text, contains('切换麦克风收音状态'));
      mic.pauseError = null;
      await asr.stop();
      await sub.cancel();
      await asr.dispose();
    },
  );

  test(
    'denied microphone permission does not load engine or start capture',
    () async {
      final mic = _Microphone()..permission = false;
      var engineCreated = false;
      final asr = LocalCallAsr(
        microphone: mic,
        engineFactory: () {
          engineCreated = true;
          return _Engine();
        },
      );
      await expectLater(asr.start(config), throwsStateError);
      expect(mic.starts, 0);
      expect(engineCreated, isFalse);
      await asr.dispose();
    },
  );

  test(
    'TTS and mute pause capture, discard queued text and resume independently',
    () async {
      final mic = _Microphone();
      final engine = _Engine();
      final asr = LocalCallAsr(microphone: mic, engineFactory: () => engine);
      final emitted = <LocalCallAsrEvent>[];
      final sub = asr.events.listen(emitted.add);
      await asr.start(config);
      mic.audio.add(Uint8List.fromList([0, 0]));
      await Future<void>.delayed(Duration.zero);
      expect(engine.received, hasLength(1));
      final earlierEpoch = engine.epoch;
      await asr.setListeningEnabled(false);
      expect(mic.paused, isTrue);
      engine.output.add(
        LocalCallAsrEvent(
          LocalCallAsrEventKind.transcript,
          text: 'speaker echo',
          epoch: earlierEpoch,
        ),
      );
      await asr.setMuted(true);
      await asr.setListeningEnabled(true);
      expect(mic.paused, isTrue);
      await asr.setMuted(false);
      expect(mic.paused, isFalse);
      engine.output.add(
        LocalCallAsrEvent(
          LocalCallAsrEventKind.transcript,
          text: 'new user speech',
          epoch: engine.epoch,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        emitted
            .where((e) => e.kind == LocalCallAsrEventKind.transcript)
            .map((e) => e.text),
        ['new user speech'],
      );
      await asr.stop();
      expect(asr.isRunning, isFalse);
      expect(engine.disposed, isTrue);
      await sub.cancel();
      await asr.dispose();
    },
  );

  test('playback echo is suppressed but independent speech reaches VAD', () {
    final filter = LocalCallEchoFilter();
    final playback = List<double>.generate(
      24000,
      (i) =>
          .3 * math.sin(i * math.pi * 2 * 193 / 24000) +
          .2 * math.sin(i * math.pi * 2 * 601 / 24000),
    );
    filter.addPlaybackPcm(_pcm(playback));
    final delayedEcho = _pcm(
      List<double>.generate(1024, (i) => playback[2400 + i * 3 ~/ 2] * .17),
    );
    expect(filter.filter(delayedEcho), everyElement(0));

    filter.resetMicrophone();
    final user = _pcm(
      List<double>.generate(
        1024,
        (i) =>
            .18 * math.sin(i * math.pi * 2 * 373 / 16000) +
            .11 * math.sin(i * math.pi * 2 * 997 / 16000),
      ),
    );
    expect(filter.filter(user), user);
    expect(filter.filter(Uint8List(2048)), everyElement(0));
  });

  test(
    'barge-in keeps capture open and preserves the active user segment',
    () async {
      final mic = _Microphone();
      final engine = _Engine();
      final asr = LocalCallAsr(microphone: mic, engineFactory: () => engine);
      final emitted = <LocalCallAsrEvent>[];
      final sub = asr.events.listen(emitted.add);
      await asr.start(config);
      final beforePlayback = engine.epoch;
      await asr.setPlaybackActive(true);
      expect(mic.paused, isFalse);
      // Starting TTS must preserve an onset already being confirmed by VAD.
      expect(engine.epoch, beforePlayback);
      mic.audio.add(_pcm(List.filled(1024, .05)));
      await Future<void>.delayed(Duration.zero);
      expect(engine.received, hasLength(1));
      final speechEpoch = engine.epoch;
      engine.output.add(
        LocalCallAsrEvent(
          LocalCallAsrEventKind.speechStarted,
          epoch: speechEpoch,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await asr.setPlaybackActive(false, preserveSpeech: true);
      expect(engine.epoch, speechEpoch);
      engine.output.add(
        LocalCallAsrEvent(
          LocalCallAsrEventKind.transcript,
          text: '等一下，我想说',
          epoch: speechEpoch,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        emitted
            .where((e) => e.kind == LocalCallAsrEventKind.transcript)
            .single
            .text,
        '等一下，我想说',
      );

      await asr.setMuted(true);
      expect(mic.paused, isTrue);
      engine.output.add(
        LocalCallAsrEvent(
          LocalCallAsrEventKind.transcript,
          text: 'stale muted input',
          epoch: speechEpoch,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        emitted.where((e) => e.kind == LocalCallAsrEventKind.transcript),
        hasLength(1),
      );
      await sub.cancel();
      await asr.dispose();
    },
  );

  test(
    'hangup while models are loading never opens microphone afterward',
    () async {
      final mic = _Microphone();
      final engine = _Engine()..loading = Completer<void>();
      final asr = LocalCallAsr(microphone: mic, engineFactory: () => engine);
      final started = asr.start(config);
      // Wait for real async file validation and permission checks.
      while (asr.isRunning == false && engine.output.hasListener == false) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      final stopped = asr.stop();
      engine.loading!.complete();
      await started;
      await stopped;
      expect(mic.starts, 0);
      expect(engine.disposed, isTrue);
      await asr.dispose();
    },
  );

  test(
    'a new call resets mute and playback gates from the previous call',
    () async {
      final mic = _Microphone();
      final engines = [_Engine(), _Engine()];
      var index = 0;
      final asr = LocalCallAsr(
        microphone: mic,
        engineFactory: () => engines[index++],
      );

      await asr.start(config);
      await asr.setMuted(true);
      await asr.setListeningEnabled(false);
      await asr.stop();

      await asr.start(config);
      expect(asr.isMuted, isFalse);
      expect(mic.paused, isFalse);
      mic.audio.add(Uint8List.fromList([0, 0]));
      await Future<void>.delayed(Duration.zero);
      expect(engines[1].received, hasLength(1));
      await asr.dispose();
    },
  );

  test(
    'recording failure stops input and releases recognition engine',
    () async {
      final mic = _Microphone();
      final engine = _Engine();
      final asr = LocalCallAsr(microphone: mic, engineFactory: () => engine);
      final failed = asr.events.firstWhere(
        (e) => e.kind == LocalCallAsrEventKind.error,
      );
      await asr.start(config);
      mic.audio.addError(StateError('capture interrupted'));
      expect((await failed).text, contains('麦克风录音中断'));
      await asr.stop();
      expect(engine.disposed, isTrue);
      await asr.dispose();
    },
  );

  test(
    'cleanup releases engine and microphone when recorder stop fails',
    () async {
      final mic = _Microphone();
      final engine = _Engine();
      final asr = LocalCallAsr(microphone: mic, engineFactory: () => engine);
      await asr.start(config);
      mic.stopError = StateError('platform stop failed');

      await expectLater(asr.dispose(), throwsStateError);
      expect(engine.disposed, isTrue);
      expect(mic.disposals, 1);
    },
  );
}

Uint8List _pcm(List<double> samples) {
  final bytes = Uint8List(samples.length * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, (samples[i] * 32767).round(), Endian.little);
  }
  return bytes;
}
