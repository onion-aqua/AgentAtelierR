import 'dart:async';
import 'dart:typed_data';

class CallSpeech {
  const CallSpeech(this.pcm, this.cancel);
  final Stream<Uint8List> pcm;
  final Future<void> Function() cancel;
}

typedef CallSpeechFactory = CallSpeech Function(
  String text,
  String voice,
  String model,
  String apiKey,
);

class PendingCallSpeech {
  PendingCallSpeech(this.create);
  final CallSpeech Function() create;
  final ready = Completer<CallSpeech?>();
  _BufferedCallSpeech? _speech;
}

/// Two admitted sentences including the currently playing stream. Later text
/// waits without starting a paid request. Each idle stream holds one PCM chunk.
class CallSpeechPrefetch {
  CallSpeechPrefetch({
    required this.isCurrent,
    required this.onError,
    this.concurrency = 2,
  }) : assert(concurrency > 0);
  final bool Function() isCurrent;
  final void Function(Object error) onError;
  final int concurrency;
  final _waiting = <PendingCallSpeech>[];
  final _active = <PendingCallSpeech>{};
  bool _closed = false, _failed = false;

  PendingCallSpeech add(CallSpeech Function() create) {
    final item = PendingCallSpeech(create);
    _waiting.add(item);
    _pump();
    return item;
  }

  void _fail(Object error) {
    _failed = true;
    onError(error);
    for (final item in _waiting) {
      item.ready.complete(null);
    }
    _waiting.clear();
  }

  void _pump() {
    if (_closed || _failed || !isCurrent()) {
      for (final item in _waiting) {
        item.ready.complete(null);
      }
      _waiting.clear();
      return;
    }
    while (_waiting.isNotEmpty && _active.length < concurrency && !_failed) {
      final item = _waiting.removeAt(0);
      _active.add(item);
      try {
        final speech = _BufferedCallSpeech(item.create(), _fail);
        item._speech = speech;
        item.ready.complete(CallSpeech(speech.pcm, speech.cancel));
      } catch (error) {
        item.ready.complete(null);
        _fail(error);
      }
    }
  }

  Future<void> release(PendingCallSpeech item) async {
    await item._speech?.cancel();
    _active.remove(item);
    _pump();
  }

  Future<void> cancel() async {
    if (_closed) return;
    _closed = true;
    for (final item in _waiting) {
      item.ready.complete(null);
    }
    _waiting.clear();
    await Future.wait([
      for (final item in _active)
        if (item._speech != null) item._speech!.cancel(),
    ]);
    _active.clear();
  }
}

class _BufferedCallSpeech {
  _BufferedCallSpeech(this.source, this.onError) {
    _output = StreamController<Uint8List>(
      onListen: _wake,
      onResume: _wake,
      onCancel: cancel,
    );
    unawaited(_run());
  }
  final CallSpeech source;
  final void Function(Object) onError;
  late final StreamController<Uint8List> _output;
  StreamIterator<Uint8List>? _iterator;
  Completer<void>? _resume;
  bool _cancelled = false;
  Stream<Uint8List> get pcm => _output.stream;

  void _wake() {
    final pending = _resume;
    _resume = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  Future<void> _run() async {
    final iterator = _iterator = StreamIterator(source.pcm);
    try {
      while (!_cancelled && await iterator.moveNext()) {
        while (!_cancelled && (!_output.hasListener || _output.isPaused)) {
          await (_resume ??= Completer<void>()).future;
        }
        if (_cancelled) break;
        _output.add(iterator.current);
        // Let the consumer apply AudioTrack backpressure before reading again.
        await Future<void>.value();
      }
    } catch (error, stack) {
      if (!_cancelled) {
        onError(error);
        _output.addError(error, stack);
      }
    } finally {
      if (!_output.isClosed) unawaited(_output.close());
    }
  }

  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    _wake();
    await source.cancel();
    await _iterator?.cancel();
    if (!_output.isClosed) unawaited(_output.close());
  }
}
