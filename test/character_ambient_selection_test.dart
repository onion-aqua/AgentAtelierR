import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/character_expression.dart';

CharacterMotionGroup motion(
  String id, {
  double weight = 0,
  String occupancy = 'F',
  String poses = '',
  String sittings = '',
}) => CharacterMotionGroup.fromJson(
  {
    'GroupId': id,
    'AnimName_1': 'motion_$id',
    'OccupancyLetters': occupancy,
    'ApplicablePoseIds': poses,
    'ApplicableSittingIDs': sittings,
  },
  emotionWeights: {CharacterExpression.neutral: weight},
);

void main() {
  test('authored ambient never explores zero weight groups', () {
    final groups = [motion('unweighted'), motion('allowed', weight: 1)];
    final random = Random(9);
    for (var i = 0; i < 100; i++) {
      expect(
        selectCharacterAmbientMotionGroup(
          groups: groups,
          expression: CharacterExpression.neutral,
          pose: 'pose-a',
          recentGroupIds: {},
          random: random,
          allowLargePostureChanges: true,
          authoredOnly: true,
          explorationChance: 1,
        )?.id,
        'allowed',
      );
    }
    expect(
      selectCharacterAmbientMotionGroup(
        groups: groups,
        expression: CharacterExpression.sad,
        pose: 'pose-a',
        recentGroupIds: {},
        random: random,
        allowLargePostureChanges: true,
        authoredOnly: true,
      ),
      isNull,
    );
  });

  test(
    'recent fallback can repeat allowed motions but not unweighted ones',
    () {
      final selected = selectCharacterAmbientMotionGroup(
        groups: [motion('recent', weight: 1), motion('fresh-but-forbidden')],
        expression: CharacterExpression.neutral,
        pose: 'pose-a',
        recentGroupIds: {'recent'},
        random: Random(1),
        allowLargePostureChanges: true,
        authoredOnly: true,
      );
      expect(selected?.id, 'recent');
    },
  );

  test(
    'pose, sitting and large posture filters also constrain recent fallback',
    () {
      final groups = [
        motion('wrong-pose', weight: 1, poses: 'pose-b'),
        motion('cross-legged', weight: 1, sittings: 'sitting_agura'),
        motion('large-posture', weight: 1, occupancy: 'C'),
        motion('no-tracks', weight: 1, occupancy: ''),
      ];
      expect(groups[1].supportsSitting(), isFalse);
      expect(groups[1].supportsSitting('sitting_agura'), isTrue);
      expect(
        selectCharacterAmbientMotionGroup(
          groups: groups,
          expression: CharacterExpression.neutral,
          pose: 'pose-a',
          recentGroupIds: groups.map((group) => group.id).toSet(),
          random: Random(1),
          allowLargePostureChanges: false,
          authoredOnly: true,
        ),
        isNull,
      );
      expect(
        selectCharacterAmbientMotionGroup(
          groups: groups,
          expression: CharacterExpression.neutral,
          pose: 'pose-a',
          recentGroupIds: {},
          random: Random(1),
          allowLargePostureChanges: false,
          sittingId: 'sitting_agura',
          authoredOnly: true,
        )?.id,
        'cross-legged',
      );
    },
  );

  test('group variants do not multiply the authored probability', () {
    final groups = [
      motion('single', weight: 1),
      for (var i = 0; i < 10; i++) motion('many-variants', weight: 1),
    ];
    final random = Random(12);
    var singles = 0;
    for (var i = 0; i < 5000; i++) {
      final selected = selectCharacterAmbientMotionGroup(
        groups: groups,
        expression: CharacterExpression.neutral,
        pose: null,
        recentGroupIds: {},
        random: random,
        allowLargePostureChanges: true,
        authoredOnly: true,
      );
      if (selected?.id == 'single') singles++;
    }
    expect(singles / 5000, closeTo(0.5, 0.03));
  });

  test('speech can select approved leg groups without enabling posture changes', () {
    final groups = [
      motion('grp_c_01', weight: 0.45, occupancy: 'C'),
      motion('grp_c_02', weight: 1, occupancy: 'C'),
    ];
    expect(
      selectCharacterAmbientMotionGroup(
        groups: groups,
        expression: CharacterExpression.neutral,
        pose: null,
        recentGroupIds: {},
        random: Random(1),
        allowLargePostureChanges: false,
        allowSubtleLegChanges: true,
        authoredOnly: true,
      )?.id,
      'grp_c_01',
    );
  });

  test(
    'pose type tables override defaults including zero and missing groups',
    () {
      final groups = parseCharacterMotionGroups(
        jsonEncode({
          'emotionalGesture': {
            'MotionGroups': [
              for (final id in ['gesture', 'rest', 'absent'])
                {
                  'GroupId': id,
                  'AnimName_1': 'motion_$id',
                  'OccupancyLetters': 'F',
                  'ApplicableSittingIDs': ' sitting_normal, sitting_agura ',
                },
            ],
            'EmotionProfilesV4': {
              'neutral': {
                'intensityProfiles': {
                  'normal': {
                    'armGroupWeightsByPoseType': {
                      '': {'gesture': 1, 'rest': 0, 'absent': 1},
                      'posetype_12_freehand_resting': {'gesture': 0, 'rest': 1},
                    },
                  },
                },
              },
            },
          },
        }),
      );
      expect(groups.first.applicableSittingIds, [
        'sitting_normal',
        'sitting_agura',
      ]);
      expect(groups.first.weightFor(CharacterExpression.neutral), 1);
      expect(
        groups.first.weightFor(
          CharacterExpression.neutral,
          poseType: 'posetype_12_freehand_resting',
        ),
        0,
      );
      expect(
        groups.last.weightFor(
          CharacterExpression.neutral,
          poseType: 'posetype_12_freehand_resting',
        ),
        0,
      );
      expect(
        groups.first.weightFor(
          CharacterExpression.neutral,
          poseType: 'unknown',
        ),
        1,
      );
      expect(
        selectCharacterAmbientMotionGroup(
          groups: groups,
          expression: CharacterExpression.neutral,
          pose: null,
          poseType: 'posetype_12_freehand_resting',
          recentGroupIds: {},
          random: Random(1),
          allowLargePostureChanges: true,
          authoredOnly: true,
        )?.id,
        'rest',
      );
    },
  );

  test(
    'legacy callers keep exploration when authored mode is not requested',
    () {
      expect(
        selectCharacterAmbientMotionGroup(
          groups: [motion('unweighted')],
          expression: CharacterExpression.neutral,
          pose: null,
          recentGroupIds: {},
          random: Random(1),
          allowLargePostureChanges: true,
        )?.id,
        'unweighted',
      );
    },
  );
}
