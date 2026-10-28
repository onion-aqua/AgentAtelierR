import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../android_companion_runtime.dart';
import 'call_ui_models.dart';

export 'call_ui_models.dart' show CallAudioRoute;

abstract interface class CallPcmOutput {
  Future<void> start();
  Future<void> write(Uint8List pcm);
  Future<void> drain();
  Future<void> stop();
  Future<bool> setSpeaker(bool value);
}

/// Optional route support; outputs without platform routing stay compatible.
abstract interface class CallPcmRouteControl {
  Stream<CallAudioRoute> get routes;
  Future<void> resetRoute();
}

/// Android AudioTrack consumes 24 kHz PCM incrementally; no MP3 files or fake
/// amplitude clocks. Writes are bounded to keep cancellation responsive.
class AndroidCallPcmOutput implements CallPcmOutput, CallPcmRouteControl {
  AndroidCallPcmOutput({
    AndroidCompanionRuntime? runtime,
    MethodChannel? channel,
    EventChannel? routesChannel,
    bool Function()? isAndroid,
  }) : runtime = runtime ?? AndroidCompanionRuntime.instance,
       _channel = channel ?? const MethodChannel(channelName),
       _routesChannel = routesChannel ?? const EventChannel(routesChannelName),
       _isAndroid = isAndroid ?? (() => Platform.isAndroid);

  static const channelName = 'agent_atelier_r/realtime_pcm';
  static const routesChannelName = 'agent_atelier_r/realtime_pcm_routes';
  final AndroidCompanionRuntime runtime;
  final MethodChannel _channel;
  final EventChannel _routesChannel;
  final bool Function() _isAndroid;
  int _generation = 0;
  Object? _owner;
  Stream<CallAudioRoute>? _routes;

  @override
  Stream<CallAudioRoute> get routes => !_isAndroid()
      ? const Stream.empty()
      : _routes ??= _routesChannel
            .receiveBroadcastStream()
            .where((event) => event is String)
            .map(
              (event) => CallAudioRoute.values.firstWhere(
                (route) => route.name == event,
                orElse: () => CallAudioRoute.unknown,
              ),
            )
            .distinct();

  @override
  Future<void> resetRoute() async {
    if (_isAndroid()) await _channel.invokeMethod<void>('resetRoute');
  }

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
      if (_isAndroid()) await _channel.invokeMethod<void>('stop');
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
