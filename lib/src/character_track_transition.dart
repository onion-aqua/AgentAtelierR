import 'package:spine_flutter/spine_flutter.dart';

/// An absent track has no mixing source: mixDuration alone cannot fade it in.
/// Seed only absent tracks. Existing tracks must crossfade directly so their
/// visible pose is not replaced with the setup pose between gestures.
TrackEntry transitionCharacterTrack(
  AnimationState state,
  int track,
  String animation, {
  required bool loop,
  required double mixDuration,
}) {
  final TrackEntry entry;
  if (state.getCurrent(track) == null && mixDuration > 0) {
    state.setEmptyAnimation(track, 0);
    entry = state.addAnimationByName(track, animation, loop, 0)..setDelay(0);
  } else {
    entry = state.setAnimationByName(track, animation, loop);
  }
  return entry..setMixDuration(mixDuration);
}
