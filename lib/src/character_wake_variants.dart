/// Select only authored wake/touch clips that belong to the loaded skeleton.
/// This is deliberately independent of native Spine so missing and imported
/// resources can be validated without opening a drawable.
class CharacterWakeMotions {
  const CharacterWakeMotions({this.touch, this.stretch});

  final String? touch;
  final String? stretch;

  static const stretchPoses = {
    'motion_A_001_idle',
    'motion_A_002_idle',
    'motion_A_005_idle',
    'motion_A_006_idle',
    'motion_A_024_idle',
    'motion_A_025_idle',
    'motion_A_029_idle',
    'motion_A_030_idle',
    'motion_A_031_idle',
    'motion_A_032_idle',
    'motion_A_033_idle',
    'motion_A_034_idle',
  };

  static const _touchClips = {
    'motion_touch_A_001_active',
    'motion_touch_A_002_active',
    'motion_touch_A_003_active',
    'motion_touch_A_004_active',
    'motion_touch_A_005_active',
    'motion_touch_A_006_active',
    'motion_touch_A_007_active',
  };

  static CharacterWakeMotions resolve({
    required String appearanceId,
    required String? pose,
    required bool Function(String) hasAnimation,
    String sittingId = 'sitting_normal',
    String? touchAnimation,
    int variant = 0,
  }) {
    final touches = [
      if (_touchClips.contains(touchAnimation)) touchAnimation!,
      if (variant.isOdd) 'motion_touch_A_002_active',
      'motion_touch_A_001_active',
      'motion_touch_A_002_active',
    ];
    final touch = touches.where(hasAnimation).firstOrNull;
    final stretches = <String>[];
    // A B arm stretch cannot be layered over a persistent cross-legged FG
    // hand-rest pose. Other base poses retain their authored arm placement.
    // The T-shirt exports include B12 clips but their sleeve attachments do
    // not follow raised upper arms. Presence alone is not visual compatibility.
    final raisedArmsSupported = !const {
      'standing_99',
      'relaxed_shirt_01',
      'crf_skn_002_0004_01',
    }.contains(appearanceId);
    if (raisedArmsSupported &&
        sittingId == 'sitting_normal' &&
        stretchPoses.contains(pose)) {
      for (final stem in [
        'motion_add_B_016_active',
        'motion_add_B_017_active',
        'motion_add_B_018_active',
      ]) {
        final clip = [stem, '${stem}_ignore'].where(hasAnimation).firstOrNull;
        if (clip != null) stretches.add(clip);
      }
    }
    return CharacterWakeMotions(
      touch: touch,
      stretch: stretches.isEmpty ? null : stretches[variant % stretches.length],
    );
  }
}
