import 'dart:math' as math;

/// Conversation liveliness without replacing intentional character animation.
///
/// This policy only changes the speaking state. Idle gain and valid authored
/// idle intervals retain their existing values. Resource compatibility remains
/// the caller's responsibility; missing resources must use resourcesReady=false.
class ConversationMotionPolicy {
  const ConversationMotionPolicy._();

  static const double speakingLegProbability = 0.45;
  static const double speakingLegAlpha = 0.72;
  static const double speakingLegWeight = 0.9;
  static const Duration speakingLegCooldown = Duration(seconds: 6);

  /// Scales broad, smoothed conversation motion rather than syllable energy.
  /// Apply this before the rig's authored ambient limits are enforced.
  static double partScale(String part, {required double talkStrength}) {
    final strength = talkStrength.isFinite ? talkStrength.clamp(0.0, 1.0) : 0.0;
    return switch (part) {
      'head' => 1 + 0.4 * strength,
      'body' => 1 + 0.55 * strength,
      _ => 1,
    };
  }

  /// Speech gets a regular opportunity for a subtle authored motion beat.
  /// Existing valid idle intervals pass through without alteration.
  static ({double minimum, double maximum}) intervalSeconds({
    required bool speaking,
    required double idleMinimum,
    required double idleMaximum,
  }) {
    if (speaking) return (minimum: 2.8, maximum: 4.6);
    final minimum = idleMinimum.isFinite && idleMinimum > 0 ? idleMinimum : 5.0;
    final maximum = idleMaximum.isFinite && idleMaximum > 0 ? idleMaximum : 8.0;
    return (
      minimum: math.min(minimum, maximum),
      maximum: math.max(minimum, maximum),
    );
  }

  /// Automatic motion yields to authored gestures, queued intentions, gaze and
  /// tap reactions. Do not use the speaking gain to bypass these owners.
  static bool canAnimate({
    required bool resourcesReady,
    bool paused = false,
    bool tapActive = false,
    bool gazeActive = false,
    bool explicitMotionActive = false,
    bool pendingExplicit = false,
  }) =>
      resourcesReady &&
      !paused &&
      !tapActive &&
      !gazeActive &&
      !explicitMotionActive &&
      !pendingExplicit;

  /// Only the verified natural-sitting foot swing is added during speech.
  /// Other C clips can alter leg posture and never become automatic chatter.
  static bool shouldPlayLeg({
    required bool speaking,
    required String sittingId,
    required String occupancy,
    required String groupId,
    required double roll,
    required bool resourcesReady,
    Duration? sinceLastLeg,
    bool paused = false,
    bool tapActive = false,
    bool gazeActive = false,
    bool explicitMotionActive = false,
    bool pendingExplicit = false,
  }) =>
      speaking &&
      sittingId == 'sitting_normal' &&
      occupancy == 'C' &&
      groupId.trim().toLowerCase() == 'grp_c_01' &&
      roll.isFinite &&
      roll >= 0 &&
      roll < speakingLegProbability &&
      (sinceLastLeg == null || sinceLastLeg >= speakingLegCooldown) &&
      canAnimate(
        resourcesReady: resourcesReady,
        paused: paused,
        tapActive: tapActive,
        gazeActive: gazeActive,
        explicitMotionActive: explicitMotionActive,
        pendingExplicit: pendingExplicit,
      );

  /// Keep explicit clip alpha and every idle clip untouched.
  static double alphaScale({
    required bool speaking,
    required String occupancy,
    required String groupId,
  }) =>
      speaking && occupancy == 'C' && groupId.trim().toLowerCase() == 'grp_c_01'
      ? speakingLegAlpha
      : 1;
}
