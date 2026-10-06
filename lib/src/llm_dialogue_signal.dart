/// Samples actual primary dialogue responses, without issuing probe requests.
/// Only every tenth successfully completed dialogue produces a new signal.
class LlmDialogueSignalSampler {
  LlmDialogueSignalSampler({Duration Function()? monotonicNow}) {
    final clock = Stopwatch()..start();
    _now = monotonicNow ?? (() => clock.elapsed);
  }

  static const sampleInterval = 10;
  late final Duration Function() _now;
  int _completedTurns = 0;
  LlmDialogueSignalTurn? _pending;
  Duration? _latency;

  int get completedTurns => _completedTurns;
  Duration? get latency => _latency;
  int? get bars => _latency == null ? null : barsForLatency(_latency!);

  static int barsForLatency(Duration latency) {
    if (latency <= const Duration(seconds: 10)) return 4;
    if (latency <= const Duration(seconds: 20)) return 3;
    if (latency <= const Duration(seconds: 30)) return 2;
    if (latency <= const Duration(seconds: 40)) return 1;
    return 0;
  }

  /// [dataRevision] rejects work from a replaced character or save.
  /// Starting a new primary response also invalidates an older pending turn.
  LlmDialogueSignalTurn beginTurn({required int dataRevision}) {
    final sampled = (_completedTurns + 1) % sampleInterval == 0;
    final turn = LlmDialogueSignalTurn._(dataRevision, sampled ? _now() : null);
    _pending = turn;
    return turn;
  }

  /// Streaming measures the first nonempty text, not the entire generation.
  /// A nonstreaming adapter yields its text when the completed body arrives.
  void receiveContent(
    LlmDialogueSignalTurn turn,
    String content, {
    required int dataRevision,
  }) {
    if (!_isCurrent(turn, dataRevision) || content.trim().isEmpty) return;
    turn._receivedContent = true;
    if (turn._started == null || turn._firstContentLatency != null) return;
    final elapsed = _now() - turn._started;
    turn._firstContentLatency = elapsed.isNegative ? Duration.zero : elapsed;
  }

  /// Returns whether the signal changed. Failed, empty, cancelled and stale
  /// responses leave both the completed-round count and prior sample intact.
  bool completeTurn(LlmDialogueSignalTurn turn, {required int dataRevision}) {
    if (!_isCurrent(turn, dataRevision)) {
      cancelTurn(turn);
      return false;
    }
    _pending = null;
    if (!turn._receivedContent) return false;
    _completedTurns++;
    if (turn._firstContentLatency == null) return false;
    _latency = turn._firstContentLatency;
    return true;
  }

  void cancelTurn(LlmDialogueSignalTurn turn) {
    if (identical(_pending, turn)) _pending = null;
  }

  bool _isCurrent(LlmDialogueSignalTurn turn, int dataRevision) =>
      identical(_pending, turn) && turn.dataRevision == dataRevision;
}

/// Opaque identity shared across content chunks and completion of one response.
/// It contains no dialogue text or credentials.
class LlmDialogueSignalTurn {
  LlmDialogueSignalTurn._(this.dataRevision, this._started);

  final int dataRevision;
  final Duration? _started;
  Duration? _firstContentLatency;
  bool _receivedContent = false;
}
