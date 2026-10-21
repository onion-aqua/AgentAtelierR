import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import 'android_companion_runtime.dart';
import 'runtime_log.dart';
import 'realtime_call/call_audio_priority.dart';

/// Saves the user's gain separately from the gain suppressed by a phone call.
/// Muting never restarts stopped audio or rewinds a conversation/ASMR segment.
class AppAudioPlayer extends AudioPlayer {
  AppAudioPlayer({super.playerId, AndroidCompanionRuntime? runtime})
    : _runtime = runtime ?? AndroidCompanionRuntime.instance {
    _runtime.addListener(_onRuntimeChanged);
    CallAudioPriority.instance.addListener(_onRuntimeChanged);
    _completion = onPlayerComplete.listen(
      (_) {
        if (releaseMode != ReleaseMode.loop) _setActive(false);
      },
      onError: (Object error, StackTrace stack) {
        // Source/playback failures are handled by their owning screen.
        _setActive(false);
      },
    );
    // A player created in the middle of a call must be silent from the outset.
    _applyVolumeSafely();
  }

  final AndroidCompanionRuntime _runtime;
  late final StreamSubscription<void> _completion;
  Future<void> _volumeTail = Future<void>.value();
  double _userVolume = 1;
  bool _closed = false;
  int _playEpoch = 0;

  @override
  double get volume => _userVolume;

  Future<void> _writeVolume() {
    final next = _volumeTail.then((_) async {
      if (!_closed) {
        await super.setVolume(
          _runtime.muted || CallAudioPriority.instance.value ? 0 : _userVolume,
        );
      }
    });
    _volumeTail = next.catchError((Object error) {
      RuntimeLog.instance.warning('Audio', '播放器音量更新失败：${error.runtimeType}');
    });
    return next;
  }

  void _applyVolumeSafely() =>
      unawaited(_writeVolume().catchError((Object _) {}));

  void _setActive(bool active) =>
      unawaited(_runtime.setPlayerActive(this, active));

  void _onRuntimeChanged() {
    if (_closed) return;
    if (_runtime.stopRequested) {
      unawaited(stop().catchError((Object _) {}));
    }
    _applyVolumeSafely();
  }

  @override
  Future<void> setVolume(double volume) {
    _userVolume = volume;
    return _writeVolume();
  }

  bool _canPlay(int epoch) =>
      !_closed && epoch == _playEpoch && !_runtime.stopRequested;

  void _ensurePlaybackAllowed() {
    if (_closed) throw StateError('播放器已关闭');
    if (_runtime.stopRequested) {
      throw StateError('后台陪伴已停止，请在声音设置中恢复陪伴通知');
    }
  }

  @override
  Future<void> play(
    Source source, {
    double? volume,
    double? balance,
    AudioContext? ctx,
    Duration? position,
    PlayerMode? mode,
  }) async {
    _ensurePlaybackAllowed();
    final epoch = ++_playEpoch;
    if (volume != null) _userVolume = volume;
    try {
      await _runtime.setPlayerActive(this, true);
      await _writeVolume();
      if (!_canPlay(epoch)) return;
      if (mode != null) await setPlayerMode(mode);
      if (balance != null) await setBalance(balance);
      if (ctx != null) await setAudioContext(ctx);
      if (!_canPlay(epoch)) return;
      await setSource(source);
      if (position != null && _canPlay(epoch)) await seek(position);
      if (_canPlay(epoch)) await super.resume();
    } catch (_) {
      if (epoch == _playEpoch) _setActive(false);
      rethrow;
    }
  }

  @override
  Future<void> resume() async {
    _ensurePlaybackAllowed();
    final epoch = ++_playEpoch;
    try {
      await _runtime.setPlayerActive(this, true);
      await _writeVolume();
      if (_canPlay(epoch)) await super.resume();
    } catch (_) {
      if (epoch == _playEpoch) _setActive(false);
      rethrow;
    }
  }

  @override
  Future<void> pause() async {
    final epoch = ++_playEpoch;
    try {
      await super.pause();
    } finally {
      if (epoch == _playEpoch) _setActive(false);
    }
  }

  @override
  Future<void> stop() async {
    final epoch = ++_playEpoch;
    try {
      await super.stop();
    } finally {
      if (epoch == _playEpoch) _setActive(false);
    }
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    ++_playEpoch;
    _runtime.removeListener(_onRuntimeChanged);
    CallAudioPriority.instance.removeListener(_onRuntimeChanged);
    await _completion.cancel();
    await _volumeTail;
    await super.dispose();
    await _runtime.setPlayerActive(this, false);
  }
}
