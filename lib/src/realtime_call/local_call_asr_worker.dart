import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'local_call_asr_config.dart';

abstract interface class LocalCallAsrEngine {
  Stream<LocalCallAsrEvent> get events;
  Future<void> start(LocalCallAsrConfig config);
  void addPcm(Uint8List bytes, int epoch);
  void reset(int epoch);
  Future<void> dispose();
}

/// Runs VAD and inference off the Flutter UI isolate. No network transport.
class SherpaLocalCallAsrEngine implements LocalCallAsrEngine {
  final _events = StreamController<LocalCallAsrEvent>.broadcast();
  ReceivePort? _receive;
  Isolate? _isolate;
  SendPort? _commands;
  Completer<void>? _ready;
  Completer<void>? _closed;
  int _pendingBytes = 0;
  bool _disposed = false;

  @override
  Stream<LocalCallAsrEvent> get events => _events.stream;

  @override
  Future<void> start(LocalCallAsrConfig config) async {
    if (_disposed || _isolate != null) {
      throw StateError('Local ASR engine has already been started/disposed.');
    }
    _ready = Completer<void>();
    _closed = Completer<void>();
    _receive = ReceivePort();
    _receive!.listen(_handle);
    _isolate = await Isolate.spawn(
      _runSherpaCallWorker,
      [_receive!.sendPort, config.toJson()],
      onError: _receive!.sendPort,
      onExit: _receive!.sendPort,
      errorsAreFatal: true,
      debugName: 'ryza-local-call-asr',
    );
    try {
      await _ready!.future.timeout(const Duration(seconds: 45));
    } catch (_) {
      await dispose();
      rethrow;
    }
  }

  void _handle(dynamic message) {
    if (message == null) {
      if (!(_closed?.isCompleted ?? true)) _closed!.complete();
      if (!(_ready?.isCompleted ?? true)) {
        _ready!.completeError(StateError('本地语音识别初始化意外退出。'));
      } else if (!_disposed) {
        _emit(
          const LocalCallAsrEvent(
            LocalCallAsrEventKind.error,
            text: '本地语音识别进程已停止，请结束通话后重试。',
          ),
        );
      }
      return;
    }
    if (message is! Map) {
      final error = StateError('本地语音识别进程发生错误。');
      if (!(_ready?.isCompleted ?? true)) {
        _ready!.completeError(error);
      } else {
        _emit(LocalCallAsrEvent(LocalCallAsrEventKind.error, text: '$error'));
      }
      return;
    }
    switch (message['type']) {
      case 'ready':
        _commands = message['port'] as SendPort;
        if (!(_ready?.isCompleted ?? true)) _ready!.complete();
      case 'ack':
        _pendingBytes = math.max(0, _pendingBytes - (message['bytes'] as int));
      case 'error':
        final text = message['message'] as String;
        if (!(_ready?.isCompleted ?? true)) {
          _ready!.completeError(StateError(text));
        } else {
          _emit(LocalCallAsrEvent(LocalCallAsrEventKind.error, text: text));
        }
      case 'event':
        final kind = LocalCallAsrEventKind.values.byName(
          message['kind'] as String,
        );
        _emit(
          LocalCallAsrEvent(
            kind,
            text: message['text'] as String? ?? '',
            level: (message['level'] as num?)?.toDouble() ?? 0,
            epoch: message['epoch'] as int? ?? 0,
          ),
        );
    }
  }

  void _emit(LocalCallAsrEvent event) {
    if (!_disposed) _events.add(event);
  }

  @override
  void addPcm(Uint8List bytes, int epoch) {
    if (_disposed || _commands == null) return;
    // Bound the isolate mailbox to ten seconds of 16 kHz mono PCM.
    if (_pendingBytes + bytes.length > 320000) {
      _emit(
        const LocalCallAsrEvent(
          LocalCallAsrEventKind.error,
          text: '设备本地识别速度不足，录音缓冲已满。请结束通话并关闭其他高负载应用。',
        ),
      );
      return;
    }
    _pendingBytes += bytes.length;
    _commands!.send({
      'type': 'audio',
      'epoch': epoch,
      'data': TransferableTypedData.fromList([bytes]),
      'bytes': bytes.length,
    });
  }

  @override
  void reset(int epoch) => _commands?.send({'type': 'reset', 'epoch': epoch});

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _commands?.send({'type': 'close'});
    if (_isolate != null) {
      try {
        await _closed?.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        _isolate?.kill(priority: Isolate.immediate);
      }
    }
    _commands = null;
    _isolate = null;
    _receive?.close();
    _receive = null;
    await _events.close();
  }
}

void _runSherpaCallWorker(List<dynamic> initial) {
  final reply = initial[0] as SendPort;
  final config = LocalCallAsrConfig.fromJson(
    Map<String, dynamic>.from(initial[1] as Map),
  );
  final commands = ReceivePort();
  sherpa.OfflineRecognizer? recognizer;
  sherpa.VoiceActivityDetector? vad;
  try {
    // Native bindings are isolate-local and must be initialized here.
    sherpa.initBindings();
    recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          senseVoice: sherpa.OfflineSenseVoiceModelConfig(
            model: config.modelPath,
            language: config.language,
            useInverseTextNormalization: true,
          ),
          tokens: config.tokensPath,
          numThreads: 2,
          debug: false,
          provider: 'cpu',
        ),
      ),
    );
    vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: config.vadModelPath,
          minSilenceDuration: config.silenceSeconds,
          minSpeechDuration: 0.25,
          maxSpeechDuration: 15,
          windowSize: LocalCallAsrConfig.vadWindowSamples,
        ),
        sampleRate: LocalCallAsrConfig.sampleRate,
        numThreads: 1,
        debug: false,
      ),
      bufferSizeInSeconds: 30,
    );
  } catch (_) {
    recognizer?.free();
    vad?.free();
    commands.close();
    // Native errors may contain local paths. Do not send model contents/logs.
    reply.send({
      'type': 'error',
      'message':
          '无法加载本地 SenseVoice / Silero 模型，请确认导入的是兼容的 ONNX 模型和对应 tokens.txt。',
    });
    return;
  }
  final decoder = LocalCallPcm16Decoder();
  final buffer = <double>[];
  var epoch = 0;
  var speaking = false;
  var levelWindows = 0;

  void event(LocalCallAsrEventKind kind, {String text = '', double level = 0}) {
    reply.send({
      'type': 'event',
      'kind': kind.name,
      'epoch': epoch,
      'text': text,
      'level': level,
    });
  }

  void reset(int nextEpoch) {
    epoch = nextEpoch;
    decoder.reset();
    buffer.clear();
    vad!.reset();
    speaking = false;
  }

  reply.send({'type': 'ready', 'port': commands.sendPort});
  commands.listen((dynamic message) {
    if (message is! Map) return;
    if (message['type'] == 'close') {
      vad!.free();
      recognizer!.free();
      commands.close();
      return;
    }
    if (message['type'] == 'reset') {
      reset(message['epoch'] as int);
      return;
    }
    if (message['type'] != 'audio') return;
    try {
      final nextEpoch = message['epoch'] as int;
      if (nextEpoch != epoch) reset(nextEpoch);
      final bytes = (message['data'] as TransferableTypedData)
          .materialize()
          .asUint8List();
      buffer.addAll(decoder.decode(bytes));
      var offset = 0;
      while (offset + LocalCallAsrConfig.vadWindowSamples <= buffer.length) {
        final frame = Float32List.fromList(
          buffer.sublist(offset, offset + LocalCallAsrConfig.vadWindowSamples),
        );
        offset += LocalCallAsrConfig.vadWindowSamples;
        vad!.acceptWaveform(frame);
        if (++levelWindows % 4 == 0) {
          final energy = frame.fold<double>(0, (sum, n) => sum + n * n);
          event(
            LocalCallAsrEventKind.level,
            level: math.min(1, math.sqrt(energy / frame.length) * 8),
          );
        }
        final detected = vad.isDetected();
        if (detected && !speaking) event(LocalCallAsrEventKind.speechStarted);
        if (!detected && speaking) event(LocalCallAsrEventKind.speechEnded);
        speaking = detected;
        while (!vad.isEmpty()) {
          final segment = vad.front();
          vad.pop();
          final stream = recognizer!.createStream();
          try {
            stream.acceptWaveform(
              samples: segment.samples,
              sampleRate: LocalCallAsrConfig.sampleRate,
            );
            recognizer.decode(stream);
            final text = recognizer
                .getResult(stream)
                .text
                .replaceAll(RegExp(r'<\|[^>]*\|>'), '')
                .trim();
            if (text.isNotEmpty) {
              event(LocalCallAsrEventKind.transcript, text: text);
            }
          } finally {
            stream.free();
          }
        }
      }
      if (offset > 0) buffer.removeRange(0, offset);
    } catch (_) {
      event(LocalCallAsrEventKind.error, text: '本地语音识别失败，请结束通话后检查模型文件并重试。');
    } finally {
      reply.send({'type': 'ack', 'bytes': message['bytes'] as int});
    }
  });
}
