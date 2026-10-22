import 'dart:async';

import 'fish_mcp_protocol.dart';
import 'tts_duration_guard.dart';

/// Observe a prefetch error immediately, even while an earlier clip is playing.
/// Only unwrap when its turn arrives so the owning flow can cancel or skip it.
class SpeechPreparation<T> {
  SpeechPreparation._(this._value, this.error, this._stack);
  final T? _value;
  final Object? error;
  final StackTrace? _stack;

  static Future<SpeechPreparation<T>> capture<T>(
    Future<T> Function() prepare,
  ) async {
    try {
      return SpeechPreparation<T>._(await prepare(), null, null);
    } catch (error, stack) {
      return SpeechPreparation<T>._(null, error, stack);
    }
  }

  T unwrap() {
    if (error case final Object failure) {
      Error.throwWithStackTrace(failure, _stack!);
    }
    return _value as T;
  }

  Future<void> discard(FutureOr<void> Function(T) dispose) async {
    if (error == null) await dispose(unwrap());
  }
}

/// Bounded lookahead, independent of completion order. Call [prefetch] only
/// when the consumer has room; a slow first result cannot grow the buffer.
class OrderedSpeechPreparation<T> {
  OrderedSpeechPreparation({
    required this.length,
    required this.prepare,
    required this.dispose,
    required this.isCurrent,
    this.concurrency = 2,
    this.onError,
  }) : assert(concurrency > 0);

  final int length, concurrency;
  final Future<T> Function(int index) prepare;
  final FutureOr<void> Function(T value) dispose;
  final bool Function() isCurrent;
  final void Function(Object error)? onError;
  final _pending = <int, Future<SpeechPreparation<T>>>{};
  final _rejected = <int>{};
  int _started = 0, _consumed = 0;
  bool _closed = false, _halted = false;
  bool _lastRejected = false;

  void prefetch({int? capacity}) {
    if (_rejected.isNotEmpty || (_lastRejected && _pending.isNotEmpty)) return;
    final slots = capacity == null
        ? concurrency
        : capacity.clamp(0, concurrency);
    while (!_closed &&
        !_halted &&
        isCurrent() &&
        _started < length &&
        _pending.length < slots) {
      final index = _started++;
      _pending[index] = SpeechPreparation.capture(() => prepare(index))
          .then((result) {
            if (result.error case final Object error) {
              if (isRejectedSpeechAudio(error)) {
                _rejected.add(index);
              } else {
                _halted = true;
              }
              onError?.call(error);
            }
            return result;
          });
    }
  }

  Future<SpeechPreparation<T>> take(int index, {int? capacity}) async {
    if (index != _consumed || _closed) {
      throw StateError('Invalid speech queue read');
    }
    prefetch(capacity: capacity);
    final pending = _pending[index];
    if (pending == null) throw StateError('Speech preparation stopped');
    final result = await pending;
    // close() owns disposal if the consumer was cancelled while waiting.
    if (_closed) throw StateError('Speech preparation cancelled');
    _pending.remove(index);
    _rejected.remove(index);
    _lastRejected = result.error != null;
    _consumed++;
    return result;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final result in _pending.values) {
      unawaited(
        result
            .then((value) => value.discard(dispose))
            .catchError((Object _) {}),
      );
    }
    _pending.clear();
  }
}

/// A 429 reduces subsequent batches for this provider during this app session.
/// Never retries the rejected or outcome-unknown generation itself.
class SpeechConcurrencyPolicy {
  static final _limited = <String>{};
  static int limit(String provider) =>
      provider == 'local' || _limited.contains(provider) ? 1 : 2;
  static void observe(String provider, Object error) {
    if ((error is FishMcpException && error.status == 429) ||
        RegExp(r'\b429\b').hasMatch(error.toString())) {
      _limited.add(provider);
    }
  }
}

/// A known invalid returned clip may be skipped. An uncertain generation,
/// billing/permission/transport error must stop rather than incur new requests.
bool isRejectedSpeechAudio(Object error) =>
    error is TtsAudioTooLongException ||
    (error is TtsAudioQualityException &&
        const {'audio_decode_failed', 'audio_silent'}.contains(error.code)) ||
    (error is FishMcpException &&
        error.stage == 'audio_validation' &&
        (error.status == null || error.status! < 400) &&
        !error.outcomeUnknown &&
        const {
          'audio_too_long',
          'audio_decode_failed',
          'audio_silent',
        }.contains(error.code));

/// Permit one bad returned clip, then stop on a consecutive failure. A valid
/// clip resets the streak; billing and uncertain results never advance it.
class SpeechRejectionBudget {
  int consecutive = 0;
  int total = 0;

  bool shouldSkip(Object error) {
    if (!isRejectedSpeechAudio(error)) return false;
    total++;
    consecutive++;
    return consecutive < 2;
  }

  void accepted() => consecutive = 0;
}

class TtsAudioQualityException implements Exception {
  const TtsAudioQualityException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}
