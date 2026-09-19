import 'character_appearance.dart';

/// Persistent posture is separate from short conversational gestures.
class CharacterPostureState {
  String sittingId = 'sitting_normal';
  bool manual = false;

  bool select(String id, {required bool supported, bool byUser = false}) {
    if (!supported || (!byUser && manual)) return false;
    if (id != 'sitting_normal' && id != 'sitting_agura') return false;
    if (byUser) manual = true;
    if (id == sittingId) return false;
    sittingId = id;
    return true;
  }

  void reset() {
    sittingId = 'sitting_normal';
    manual = false;
  }
}

/// Resolve the authored leg layer, never infer capability from outfit names.
CharacterMotionGroup? crossLeggedPostureGroup(
  Iterable<CharacterMotionGroup> groups, {
  required bool standing,
  required String? pose,
  required bool Function(String) hasAnimation,
}) {
  if (standing) return null;
  for (final group in groups) {
    if (group.occupancy == 'C' &&
        group.applicableSittingIds.contains('sitting_agura') &&
        group.supportsPose(pose) &&
        group.alpha1 > 0 &&
        group.animation2 == null &&
        hasAnimation(group.animation1)) {
      return group;
    }
  }
  return null;
}
