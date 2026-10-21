import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'local_call_asr_config.dart';
import 'local_call_asr_worker.dart';
import 'local_call_echo_filter.dart';

export 'local_call_asr_config.dart';

abstract interface class LocalCallMicrophone {
  Future<bool> hasPermission();
  Future<Stream<Uint8List>> start();
  Future<void> setPaused(bool paused);
  Future<void> stop();
  Future<void> dispose();
}

class RecordLocalCallMicrophone implements LocalCallMicrophone {
  AudioRecorder? _recorder;
  AudioRecorder get _audioRecorder => _recorder ??= AudioRecorder();
  bool _paused = false;

  @override
  Future<bool> hasPermission() => _audioRecorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start() async {
    if (!await _audioRecorder.isEncoderSupported(AudioEncoder.pcm16bits)) {
      throw StateError('当前设备不支持通话所需的 PCM16 麦克风录音。');
    }
    _paused = false;
    return _audioRecorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: LocalCallAsrConfig.sampleRate,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
        streamBufferSize: 2048,
        androidConfig: AndroidRecordConfig(
          // Select the communication capture path for device AEC while
          // leaving Android audio mode alone (our own mic is not a real call).
          audioSource: AndroidAudioSource.voiceCommunication,
          manageBluetooth: false,
        ),
      ),
    );
  }

  @override
  Future<void> setPaused(bool paused) async {
    if (_recorder == null || _paused == paused) return;
    if (paused) {
      await _audioRecorder.pause();
    } else {
      await _audioRecorder.resume();
    }
    _paused = paused;
  }

  @override
  Future<void> stop() async {
    await _recorder?.stop();
    _paused = false;
  }

  @override
  Future<void> dispose() async {
    await _recorder?.dispose();
    _recorder = null;
  }
}

/// Foreground local VAD/recognition. Capture stays live during character
/// playback so a real speech onset can interrupt it. Platform AEC and a bounded
/// playback-reference filter reduce speaker echo before it reaches VAD.
class LocalCallAsr {
  LocalCallAsr({
    LocalCallMicrophone? microphone,
    LocalCallAsrEngine Function()? engineFactory,
  }) : _microphone = microphone ?? RecordLocalCallMicrophone(),
       _engineFactory = engineFactory ?? SherpaLocalCallAsrEngine.new;

  final LocalCallMicrophone _microphone;
  final LocalCallAsrEngine Function() _engineFactory;
  final _events = StreamController<LocalCallAsrEvent>.broadcast();
  final _gate = LocalCallAsrGate();
  final _echoFilter = LocalCallEchoFilter();
  bool _playbackActive = false;
  DateTime? _echoTailUntil;
  LocalCallAsrEngine? _engine;
  StreamSubscription<Uint8List>? _audioSub;
  StreamSubscription<LocalCallAsrEvent>? _engineSub;
  Future<void> _operation = Future.value();
  Future<void> _captureOperation = Future.value();
  int _runGeneration = 0;
  bool _running = false;
  bool _disposed = false;

  Stream<LocalCallAsrEvent> get events => _events.stream;
  bool get isRunning => _running;
  bool get isMuted => _gate.muted;

  void addPlaybackPcm(Uint8List pcm) {
    if (_running && _playbackActive) _echoFilter.addPlaybackPcm(pcm);
  }

  /// Playback transitions do not pause the microphone. At automatic barge-in,
  /// preserve the VAD segment that contains the user's first syllables.
  Future<void> setPlaybackActive(
    bool active, {
    bool preserveSpeech = true,
  }) async {
    // Let a mute/unmute platform transition reopen its capture gate before
    // changing the result epoch. Otherwise a concurrent resume would see a
    // stale epoch and leave capture permanently closed.
    await _captureOperation;
    if (!_running || _playbackActive == active) return;
    _playbackActive = active;
    if (active) {
      _echoTailUntil = null;
      _echoFilter.reset();
    } else {
      _echoTailUntil = DateTime.now().add(const Duration(milliseconds: 250));
    }
    if (!preserveSpeech) {
      _echoFilter.resetMicrophone();
      _gate.reset();
      _engine?.reset(_gate.epoch);
    }
  }

  Future<void> _serial(Future<void> Function() action) {
    final result = _operation.then((_) => action());
    _operation = result.then((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> start(LocalCallAsrConfig config) {
    final generation = ++_runGeneration;
    return _serial(() async {
      if (_disposed) throw StateError('LocalCallAsr has been disposed.');
      await _cleanup();
      await config.validateFiles();
      if (generation != _runGeneration) return;
      if (!await _microphone.hasPermission()) {
        throw StateError('没有麦克风权限。请允许麦克风访问后重新拨打。');
      }
      if (generation != _runGeneration) return;
      try {
        final engine = _engineFactory();
        _engine = engine;
        _engineSub = engine.events.listen(_onEngineEvent);
        await engine.start(config);
        if (generation != _runGeneration) {
          await _cleanup();
          return;
        }
        final stream = await _microphone.start();
        if (generation != _runGeneration) {
          await _cleanup();
          return;
        }
        // Mute/listening are call-scoped controls. A hangup while muted or
        // while TTS owns the microphone must not leave the next call paused.
        _gate
          ..muted = false
          ..listeningEnabled = true
          ..captureReady = false;
        _running = true;
        _gate.reset();
        engine.reset(_gate.epoch);
        _audioSub = stream.listen(
          (bytes) {
            if (_running && _gate.acceptsAudio) {
              final suppressEcho =
                  _playbackActive ||
                  (_echoTailUntil?.isAfter(DateTime.now()) ?? false);
              engine.addPcm(
                suppressEcho ? _echoFilter.filter(bytes) : bytes,
                _gate.epoch,
              );
            }
          },
          onError: (Object _) => _fail('麦克风录音中断，请结束通话后重新拨打。'),
          onDone: () {
            if (_running) _fail('麦克风已停止，请结束通话后重新拨打。');
          },
        );
        await _updateCapture();
        if (generation == _runGeneration && _running) {
          _emit(
            LocalCallAsrEvent(LocalCallAsrEventKind.ready, epoch: _gate.epoch),
          );
        }
      } catch (_) {
        await _cleanup();
        rethrow;
      }
    });
  }

  void _onEngineEvent(LocalCallAsrEvent event) {
    if (event.kind == LocalCallAsrEventKind.error) {
      _fail(event.text);
    } else if (_running && _gate.acceptsResult(event.epoch)) {
      _emit(event);
    }
  }

  void _emit(LocalCallAsrEvent event) {
    if (!_disposed) _events.add(event);
  }

  void _fail(String message) {
    if (!_running) return;
    _emit(LocalCallAsrEvent(LocalCallAsrEventKind.error, text: message));
    unawaited(stop().catchError((Object _) {}));
  }

  Future<void> setMuted(bool muted) {
    if (_gate.muted == muted) return Future.value();
    _gate.muted = muted;
    return _updateCapture();
  }

  Future<void> setListeningEnabled(bool enabled) {
    if (_gate.listeningEnabled == enabled) return Future.value();
    _gate.listeningEnabled = enabled;
    return _updateCapture();
  }

  Future<void> _updateCapture() {
    // Close the logical gate before touching the platform recorder. A resume
    // can otherwise expose packets buffered before the playback/mute boundary.
    _gate.captureReady = false;
    _gate.reset();
    _echoFilter.resetMicrophone();
    final epoch = _gate.epoch;
    final shouldCapture = _gate.wantsAudio;
    _engine?.reset(epoch);
    final result = _captureOperation.then((_) async {
      if (!_running) return;
      try {
        await _microphone.setPaused(!shouldCapture);
      } on Object {
        if (_running) {
          _fail('无法切换麦克风收音状态，请结束通话后重新拨打。');
        }
        rethrow;
      }
      // A newer mute/listening request owns the gate now. It will perform its
      // own platform transition and decide when capture can reopen.
      if (_running && _gate.epoch == epoch) {
        _gate.captureReady = shouldCapture;
      }
    });
    _captureOperation = result.then(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> stop() {
    // Invalidate results immediately, even if a model is still loading.
    ++_runGeneration;
    _running = false;
    _gate.captureReady = false;
    _gate.reset();
    return _serial(_cleanup);
  }

  Future<void> _cleanup() async {
    _running = false;
    _playbackActive = false;
    _echoTailUntil = null;
    _echoFilter.reset();
    Object? firstError;
    StackTrace? firstStack;
    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } on Object catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }

    final audioSub = _audioSub;
    _audioSub = null;
    if (audioSub != null) await attempt(audioSub.cancel);
    await attempt(() => _captureOperation);
    await attempt(_microphone.stop);
    final engineSub = _engineSub;
    _engineSub = null;
    if (engineSub != null) await attempt(engineSub.cancel);
    final engine = _engine;
    _engine = null;
    if (engine != null) await attempt(engine.dispose);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    Object? firstError;
    StackTrace? firstStack;
    try {
      await stop();
    } on Object catch (error, stack) {
      firstError = error;
      firstStack = stack;
    }
    try {
      await _microphone.dispose();
    } on Object catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
    await _events.close();
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }
}
