import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_body_touch_part.dart';

void main() {
  test(
    'recognizes authored body slots and separates seated hands from arms',
    () {
      const expected = {
        '039_face': 'head',
        'mouth': 'head',
        '018_hair': 'head',
        'BB_breast': 'breast',
        '063_body': 'body',
        '060_weast': 'weast',
        '070_arm_R_010': 'arm_r',
        '069_arm_L_010': 'arm_l',
        '068_arm_R_020': 'arm_r',
        '067_arm_L_020': 'arm_l',
        '066_arm_R_030': 'hands',
        '065_arm_L_030': 'hands',
        '059_leg_R_010': 'legs',
        '058_leg_L_010': 'legs',
        '073_leg': 'legs',
        'foot_r': 'legs',
        'finger_l': 'hands',
      };
      for (final entry in expected.entries) {
        expect(
          characterBodyTouchPart(slotName: entry.key),
          entry.value,
          reason: entry.key,
        );
      }
    },
  );

  test('standing numeric hand pieces require an actual arm bone', () {
    for (final name in [
      '101_arm_01',
      '102_arm_01',
      '110_arm_01',
      '111_arm_01',
    ]) {
      expect(
        characterBodyTouchPart(slotName: name, boneName: 'arm_R'),
        'hands',
      );
      expect(
        characterBodyTouchPart(slotName: name, boneName: 'costume'),
        isNull,
      );
    }
    expect(
      characterBodyTouchPart(slotName: '116_arm_01', boneName: 'arm_L'),
      'arm_l',
    );
  });

  test('unknown clothing or accessories do not inherit their body bone', () {
    for (final name in [
      'cover',
      'fixture_unknown',
      'costume_sleeve',
      '600_arm_R_010',
      'arm_R_010_02_shadow',
      '170_arm_R_010_frill_F',
      '504_costume_waist',
      '037_ex_body',
      '014_acc',
    ]) {
      expect(
        characterBodyTouchPart(slotName: name, boneName: 'arm_R'),
        isNull,
        reason: name,
      );
    }
    expect(
      characterBodyTouchPart(
        slotName: '065_arm_L_030',
        attachmentPath: 'costume_hand_cover',
      ),
      isNull,
    );
  });
}
