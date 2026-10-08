import 'dart:math' as math;

/// The lifetime of a gesture intention, including its entrance and pose hold.
///
/// Spine's `complete` event describes one animation cycle. It is not the end
/// of an intention: a short cycle can finish before its entrance mix, and a
/// zero-duration clip is an authored pose that still needs time to be seen.
class MotionPlaybackTiming {
  const MotionPlaybackTiming._({
    required this.loop,
    required this.duration,
    required this.mixDuration,
    required this.timeScale,
  });

  /// Computes timing from the clip's authored duration in seconds.
  ///
  /// [repeatCount] is an explicit requested cycle count, not the resource
  /// JSON's `RepeatCount`, whose zero value has no confirmed runtime meaning.
  /// Keep its default when playing the existing gesture resources.
  factory MotionPlaybackTiming.forClip(
    double duration, {
    required double mixDuration,
    double speed = 1,
    int repeatCount = 1,
  }) {
    final authoredDuration = duration.isFinite && duration > 0 ? duration : 0.0;
    final playbackSpeed = speed.isFinite && speed.abs() >= 0.01
        ? speed.abs()
        : 1.0;
    final requestedMix = mixDuration.isFinite
        ? mixDuration.clamp(0.0, 2.0)
        : 0.6;
    final authoredCycle = authoredDuration / playbackSpeed;

    if (authoredCycle == 0) {
      return MotionPlaybackTiming._(
        loop: false,
        duration: _seconds(requestedMix + 0.6),
        mixDuration: requestedMix,
        timeScale: playbackSpeed,
      );
    }

    // F/G050 are a complete out-and-back clap in just 0.2 seconds. Repeating
    // that clip to make it visible would turn "clap once" into many claps.
    // Preserve the authored path and cycle count, giving very short gestures
    // a readable cycle instead. Ordinary clips retain their authored speed.
    final cycle = math.max(authoredCycle, 0.6);
    final effectiveSpeed = authoredDuration / cycle;
    // Full influence is reached before the first half-cycle's gesture peak.
    final entrance = math.min(requestedMix, cycle * (cycle < 1.0 ? 0.25 : 0.5));
    final requestedCycles = repeatCount.clamp(1, 64);
    final hold = cycle < 1.0 ? math.max(entrance, 0.3) : entrance;
    return MotionPlaybackTiming._(
      loop: requestedCycles > 1,
      duration: _seconds(cycle * requestedCycles + hold),
      mixDuration: entrance,
      timeScale: effectiveSpeed,
    );
  }

  /// Only explicit repeated intentions loop; short clips keep one cycle.
  final bool loop;

  /// Release/advance the intention after this window, not on cycle completion.
  final Duration duration;

  /// Safe entrance mix in seconds, suitable for a Spine track entry.
  final double mixDuration;

  /// Authored speed adjusted only when a cycle would be too short to read.
  final double timeScale;

  static Duration _seconds(double seconds) =>
      Duration(microseconds: (seconds * Duration.microsecondsPerSecond).ceil());
}
