import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:ryza_chat_mvp/src/realtime_call/local_call_asr.dart';
import 'package:ryza_chat_mvp/src/realtime_call/local_call_asr_worker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _NativeRecordBridge native;

  setUp(() => native = _NativeRecordBridge()..install());
  tearDown(() => native.uninstall());

  test('real recorder serializes no independent focus pause and keeps communication source', () async {
    final mic = RecordLocalCallMicrophone();
    expect(await mic.hasPermission(), isTrue);
    await mic.start();
    final config = native.startArguments!;
    expect(config['audioInterruption'], AudioInterruptionMode.none.index);
    expect(config['encoder'], 'pcm16bits');
    expect(config['sampleRate'], 16000);
    expect(config['numChannels'], 1);
    expect(config['echoCancel'], isTrue);
    expect(config['noiseSuppress'], isTrue);
    final android = config['androidConfig'] as Map;
    expect(android['audioSource'], 'voiceCommunication');
    expect(android['audioManagerMode'], 'modeNormal');
    expect(android['manageBluetooth'], isFalse);
    await mic.dispose();
  });

  test('explicit capture changes consult native paused state rather than a Dart cache', () async {
    final mic = RecordLocalCallMicrophone();
    await mic.start();
    // A platform interruption does not go through RecordLocalCallMicrophone.
    native.paused = true;
    await mic.setPaused(false);
    expect(native.resumes, 1);
    expect(native.paused, isFalse);
    await mic.setPaused(false);
    expect(native.resumes, 1);
    await mic.setPaused(true);
    expect(native.pauses, 1);
    // Native state can also diverge in the opposite direction.
    native.paused = false;
    await mic.setPaused(true);
    expect(native.pauses, 2);
    await mic.dispose();
  });

  group('ASR with the actual Record microphone and native channels', () {
    late Directory directory;
    late LocalCallAsrConfig config;
    late LocalCallAsr asr;
    late _Engine engine;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('record-call-capture-');
      for (final file in ['model.onnx', 'tokens.txt', 'vad.onnx']) {
        await File('${directory.path}/$file').writeAsBytes([1]);
      }
      config = LocalCallAsrConfig(
        modelPath: '${directory.path}/model.onnx',
        tokensPath: '${directory.path}/tokens.txt',
        vadModelPath: '${directory.path}/vad.onnx',
      );
      engine = _Engine();
      asr = LocalCallAsr(
        microphone: RecordLocalCallMicrophone(),
        engineFactory: () => engine,
      );
      await asr.start(config);
    });

    tearDown(() async {
      await asr.dispose();
      await directory.delete(recursive: true);
    });

    test('playback and its completion keep PCM and speech events flowing without mute toggles', () async {
      final events = <LocalCallAsrEvent>[];
      final subscription = asr.events.listen(events.add);
      final epoch = engine.epoch;
      await native.sendPcm();
      expect(engine.received, hasLength(1));
      await asr.setPlaybackActive(true);
      await native.sendPcm();
      expect(engine.received, hasLength(2));
      engine.eventsController.add(
        LocalCallAsrEvent(LocalCallAsrEventKind.speechStarted, epoch: epoch),
      );
      await Future<void>.delayed(Duration.zero);
      await asr.setPlaybackActive(false, preserveSpeech: true);
      await asr.setListeningEnabled(true);
      await native.sendPcm();
      expect(engine.received, hasLength(3));
      engine.eventsController.add(
        LocalCallAsrEvent(
          LocalCallAsrEventKind.transcript,
          text: '可以打断，下一轮也能继续说话',
          epoch: epoch,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(engine.epoch, epoch);
      expect(
        events.map((e) => e.kind),
        containsAllInOrder([
          LocalCallAsrEventKind.speechStarted,
          LocalCallAsrEventKind.transcript,
        ]),
      );
      expect(native.pauses, 0);
      expect(native.resumes, 0);
      expect(native.paused, isFalse);
      expect(
        native.startArguments!['audioInterruption'],
        AudioInterruptionMode.none.index,
      );
      await subscription.cancel();
    });

    test(
      'playback transitions preserve explicit mute until the user unmutes',
      () async {
        await asr.setMuted(true);
        expect(native.pauses, 1);
        expect(native.paused, isTrue);
        await asr.setPlaybackActive(true);
        await asr.setPlaybackActive(false);
        await asr.setListeningEnabled(true);
        // Even a late native packet cannot enter VAD while explicitly muted.
        await native.sendPcm(evenWhenPaused: true);
        expect(engine.received, isEmpty);
        expect(asr.isMuted, isTrue);
        expect(native.resumes, 0);
        await asr.setMuted(false);
        expect(native.resumes, 1);
        await native.sendPcm();
        expect(engine.received, hasLength(1));
      },
    );
  });
}

/// Captures the real record plugin method-channel payload instead of replacing
/// RecordLocalCallMicrophone or merely asserting an in-memory config object.
class _NativeRecordBridge {
  static const _messages = MethodChannel('com.llfbandit.record/messages');
  final _messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final _eventNames = <String>[];
  String? _recorderId;
  Map<dynamic, dynamic>? startArguments;
  bool paused = false;
  int pauses = 0, resumes = 0;

  void install() {
    _messenger.setMockMethodCallHandler(_messages, (call) async {
      switch (call.method) {
        case 'create':
          _recorderId = (call.arguments as Map)['recorderId'] as String;
          for (final event in ['events', 'eventsRecord']) {
            final name = 'com.llfbandit.record/$event/$_recorderId';
            _eventNames.add(name);
            _messenger.setMockMethodCallHandler(
              MethodChannel(name),
              (_) async => null,
            );
          }
          return null;
        case 'hasPermission':
        case 'isEncoderSupported':
        case 'isRecording':
          return true;
        case 'startStream':
          startArguments = Map.of(call.arguments as Map);
          paused = false;
          return null;
        case 'isPaused':
          return paused;
        case 'pause':
          pauses++;
          paused = true;
          return null;
        case 'resume':
          resumes++;
          paused = false;
          return null;
        case 'stop':
        case 'dispose':
          return null;
        default:
          throw StateError('Unexpected recorder operation: ${call.method}');
      }
    });
  }

  Future<void> sendPcm({bool evenWhenPaused = false}) async {
    if (paused && !evenWhenPaused) return;
    final pcm = Uint8List.fromList(
      List.generate(2048, (i) => i.isEven ? 0 : 12),
    );
    await _messenger.handlePlatformMessage(
      'com.llfbandit.record/eventsRecord/$_recorderId',
      const StandardMethodCodec().encodeSuccessEnvelope(pcm),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  void uninstall() {
    _messenger.setMockMethodCallHandler(_messages, null);
    for (final name in _eventNames) {
      _messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  }
}

class _Engine implements LocalCallAsrEngine {
  final eventsController = StreamController<LocalCallAsrEvent>.broadcast();
  final received = <Uint8List>[];
  int epoch = 0;
  @override
  Stream<LocalCallAsrEvent> get events => eventsController.stream;
  @override
  Future<void> start(LocalCallAsrConfig config) async {}
  @override
  void addPcm(Uint8List bytes, int epoch) => received.add(bytes);
  @override
  void reset(int value) => epoch = value;
  @override
  Future<void> dispose() => eventsController.close();
}
