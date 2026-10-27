import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_wake_variants.dart';

void main() {
  const stretches = [
    'motion_add_B_016_active',
    'motion_add_B_017_active',
    'motion_add_B_018_active',
  ];
  CharacterWakeMotions select(
    Set<String> clips, {
    String appearance = 'seated_01',
    String? pose = 'motion_A_001_idle',
    String sitting = 'sitting_normal',
    String? touch,
    int variant = 0,
  }) => CharacterWakeMotions.resolve(
    appearanceId: appearance,
    pose: pose,
    sittingId: sitting,
    touchAnimation: touch,
    variant: variant,
    hasAnimation: clips.contains,
  );

  test('chooses three distinct authored stretches without mixing rigs', () {
    for (var variant = 0; variant < 6; variant++) {
      expect(
        select(stretches.toSet(), variant: variant).stretch,
        stretches[variant % 3],
      );
    }
    final ignoreOnly = stretches.map((name) => '${name}_ignore').toSet();
    for (var variant = 0; variant < 3; variant++) {
      expect(
        select(ignoreOnly, variant: variant).stretch,
        '${stretches[variant]}_ignore',
      );
    }
  });

  test('missing variants fall back within the same stretch family', () {
    expect(select({stretches[2]}, variant: 2).stretch, stretches[2]);
    expect(select({'motion_add_B_001_active'}).stretch, isNull);
    expect(select({}).stretch, isNull);
    expect(select({...stretches}, appearance: 'standing_99').stretch, isNull);
    for (final skin in ['relaxed_shirt_01', 'crf_skn_002_0004_01']) {
      expect(
        select({...stretches}, appearance: skin).stretch,
        isNull,
        reason: 'T-shirt sleeve attachments do not follow raised upper arms',
      );
    }
  });

  test(
    'incompatible arms, unknown poses and persistent leg poses skip stretch',
    () {
      for (final pose in [
        null,
        'motion_A_003_idle',
        'motion_A_004_idle',
        'motion_A_007_idle',
        'motion_A_008_idle',
        'motion_A_026_idle',
        'imported_pose',
      ]) {
        expect(select({...stretches}, pose: pose).stretch, isNull);
      }
      for (final sitting in ['sitting_agura', 'standing', 'unknown']) {
        expect(select({...stretches}, sitting: sitting).stretch, isNull);
      }
      for (final pose in CharacterWakeMotions.stretchPoses) {
        expect(select({...stretches}, pose: pose).stretch, stretches.first);
      }
    },
  );

  test('uses the clicked body part only when it exists in this skeleton', () {
    for (var part = 1; part <= 7; part++) {
      final touch = 'motion_touch_A_${part.toString().padLeft(3, '0')}_active';
      expect(select({touch}, touch: touch).touch, touch);
    }
    expect(
      select({
        'motion_touch_A_001_active',
      }, touch: 'motion_touch_A_006_active').touch,
      'motion_touch_A_001_active',
    );
    expect(select({}, touch: 'motion_touch_A_006_active').touch, isNull);
  });

  test('button wake alternates head reactions and rejects unrelated clips', () {
    const head = {'motion_touch_A_001_active', 'motion_touch_A_002_active'};
    expect(select(head).touch, 'motion_touch_A_001_active');
    expect(select(head, variant: 1).touch, 'motion_touch_A_002_active');
    expect(
      select({
        'motion_add_B_001_active',
      }, touch: 'motion_add_B_001_active').touch,
      isNull,
    );
  });
}
