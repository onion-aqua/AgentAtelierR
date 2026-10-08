import 'chat_segments.dart';

typedef SpeechPerformanceDispatchCue = ({
  int ordinal,
  RyzaPerformanceSegment performance,
});

/// Dispatches each original primary dialogue line once, independently of TTS.
///
/// Ordinals belong to the complete primary dialogue, before filtering lines
/// whose audio service is unavailable. A plan can arrive during a line, between
/// lines, or after playback ends. Previously started lines stay eligible, while
/// future lines wait until [startPrimary] or [finishPlayback].
///
/// The caller owns turn cancellation and character/resource validation. Discard
/// this instance when its turn is cancelled; never apply returned cues to a
/// different turn or character.
class SpeechPerformanceDispatch {
  SpeechPerformanceDispatch(this.primaryCount) {
    if (primaryCount < 0) {
      throw RangeError.value(
        primaryCount,
        'primaryCount',
        'Must be nonnegative',
      );
    }
  }

  final int primaryCount;
  final Set<int> _started = {};
  final Set<int> _dispatched = {};
  List<RyzaPerformanceSegment>? _plan;
  bool _playbackFinished = false;

  /// Retains an aligned plan and returns cues for all eligible original lines.
  ///
  /// Replacing the plan never repeats a line already returned. An invalid plan
  /// leaves any previous valid plan intact.
  List<SpeechPerformanceDispatchCue> setPlan(
    List<RyzaPerformanceSegment> plan,
  ) {
    if (plan.length != primaryCount) {
      throw const FormatException(
        'Speech performance plan length does not match primary dialogue',
      );
    }
    _plan = List<RyzaPerformanceSegment>.unmodifiable(plan);
    return _drain();
  }

  /// Marks the original primary line as started, even without a ready plan.
  List<SpeechPerformanceDispatchCue> startPrimary(int ordinal) {
    if (ordinal < 0 || ordinal >= primaryCount) {
      throw RangeError.range(ordinal, 0, primaryCount - 1, 'ordinal');
    }
    _started.add(ordinal);
    return _drain();
  }

  /// Makes all remaining primary lines eligible, including lines without TTS.
  ///
  /// If the plan is not ready yet, [setPlan] will return those cues later.
  List<SpeechPerformanceDispatchCue> finishPlayback() {
    _playbackFinished = true;
    return _drain();
  }

  List<SpeechPerformanceDispatchCue> _drain() {
    final plan = _plan;
    if (plan == null) return const [];
    final result = <SpeechPerformanceDispatchCue>[];
    for (var ordinal = 0; ordinal < primaryCount; ordinal++) {
      if ((!_playbackFinished && !_started.contains(ordinal)) ||
          !_dispatched.add(ordinal)) {
        continue;
      }
      result.add((ordinal: ordinal, performance: plan[ordinal]));
    }
    return List<SpeechPerformanceDispatchCue>.unmodifiable(result);
  }
}
