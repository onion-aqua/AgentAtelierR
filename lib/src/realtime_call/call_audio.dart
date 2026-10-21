import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../android_companion_runtime.dart';

abstract interface class CallPcmOutput {
  Future<void> start();
  Future<void> write(Uint8List pcm);
  Future<void> drain();
  Future<void> stop();
  Future<bool> setSpeaker(bool value);
}

/// Android AudioTrack consumes 24 kHz PCM incrementally; no MP3 files or fake
/// amplitude clocks. Writes are bounded to keep cancellation responsive.
class AndroidCallPcmOutput implements CallPcmOutput {
  AndroidCallPcmOutput({
    AndroidCompanionRuntime? runtime,
    MethodChannel? channel,
    bool Function()? isAndroid,
  }) : runtime = runtime ?? AndroidCompanionRuntime.instance,
       _channel = channel ?? const MethodChannel(channelName),
       _isAndroid = isAndroid ?? (() => Platform.isAndroid);

  static const channelName = 'agent_atelier_r/realtime_pcm';
  final AndroidCompanionRuntime runtime;
  final MethodChannel _channel;
  final bool Function() _isAndroid;
  int _generation = 0;
  Object? _owner;

  Future<void> _release(Object owner) async {
    if (identical(_owner, owner)) _owner = null;
    await runtime.setPlayerActive(owner, false);
  }

  @override
  Future<void> start() async {
    if (!_isAndroid()) {
      throw const FormatException('实时通话的流式播放目前仅支持 Android。');
    }
    final generation = ++_generation;
    final previousOwner = _owner;
    final owner = Object();
    _owner = owner;
    try {
      await runtime.setPlayerActive(owner, true);
      if (previousOwner != null) {
        await runtime.setPlayerActive(previousOwner, false);
      }
      if (generation != _generation) {
        await _release(owner);
        return;
      }
      // A pending or temporarily lost media focus is not a system call. It
      // can occur while this call is acquiring its own AudioTrack focus and
      // must not make the virtual call reject itself.
      if (runtime.callActive || runtime.stopRequested) {
        throw const FormatException('当前有系统通话或音频中断，请结束后再拨打。');
      }
      await _channel.invokeMethod<void>('start');
      if (generation != _generation) await _release(owner);
    } catch (_) {
      await _release(owner);
      rethrow;
    }
  }

  @override
  Future<void> write(Uint8List pcm) =>
      _channel.invokeMethod<void>('write', {'pcm': pcm});
  @override
  Future<void> drain() => _channel.invokeMethod<void>('drain');
  @override
  Future<bool> setSpeaker(bool value) async =>
      await _channel.invokeMethod<bool>('speaker', {'enabled': value}) ?? false;
  @override
  Future<void> stop() async {
    ++_generation;
    final owner = _owner;
    _owner = null;
    try {
      await _channel.invokeMethod<void>('stop');
    } finally {
      if (owner != null) await runtime.setPlayerActive(owner, false);
    }
  }
}

double callPcmLevel(Uint8List bytes) {
  if (bytes.length < 2) return 0;
  final view = ByteData.sublistView(bytes);
  double sum = 0;
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    final sample = view.getInt16(i, Endian.little) / 32768;
    sum += sample * sample;
  }
  return (math.sqrt(sum / (bytes.length ~/ 2)) * 4).clamp(0.0, 1.0);
}
