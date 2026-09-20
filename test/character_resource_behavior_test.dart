import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_resource_behavior.dart';

CharacterResourceBehavior parseProfiles(Map<String, Object?> profiles) =>
    CharacterResourceBehavior.parse(
      jsonEncode({
        'projectConfig': {'closedEyeAnimation': 'facial_eye_001_idle'},
        'emotionalGesture': {'EmotionProfilesV4': profiles},
      }),
    );

void main() {
  for (final id in [
    '0001_01',
    '0001_99',
    '0002_01',
    '0003_01',
    '0004_01',
    '0005_01',
  ]) {
    final skin = 'crf_skn_002_$id';
    final file = File('assets/character/ryza/$skin/${skin}_gesture.json');
    test(
      'all three intensity catalogs remain complete: $skin',
      () {
        final source = file.readAsStringSync();
        final raw = jsonDecode(source) as Map;
        final profiles = raw['emotionalGesture']['EmotionProfilesV4'] as Map;
        final parsed = CharacterResourceBehavior.parse(source);
        for (final emotion in profiles.entries) {
          final levels = emotion.value['intensityProfiles'] as Map;
          for (final level in levels.entries) {
            final expected = (level.value['expressionSets'] as List? ?? [])
                .cast<Map>()
                .where((row) => ((row['weight'] ?? 1) as num) > 0);
            final actual = parsed.profile(
              emotion.key as String,
              level.key as String,
            )!;
            expect(
              actual.expressionSets.map((row) => row.id).toList(),
              expected.map((row) => row['id']).toList(),
              reason: '$skin ${emotion.key}/${level.key}',
            );
          }
        }
      },
      skip: !file.existsSync()
          ? 'Licensed local resources are not distributed with source'
          : false,
    );
  }
  test('reads all intensity tuples and authored effect sets', () {
    final behavior = parseProfiles({
      'shy': {
        'intensityProfiles': {
          for (final level in ['weak', 'normal', 'strong'])
            level: {
              'expressionSets': [
                {
                  'id': level,
                  'eyeOpen': 'eye_$level',
                  'eyebrow': 'brow',
                  'mouth': 'mouth',
                },
                {
                  'id': 'disabled',
                  'eyeOpen': 'eye',
                  'eyebrow': 'brow',
                  'mouth': 'mouth',
                  'weight': 0,
                },
              ],
              'effectSets': [
                {
                  'names': ['blush002'],
                },
              ],
            },
        },
      },
    });
    for (final level in ['weak', 'normal', 'strong']) {
      final profile = behavior.profile('shy', level)!;
      expect(profile.expressionSets.single.id, level);
      expect(profile.effectSets.single, ['blush002']);
    }
    expect(behavior.profile('shy', 'unknown'), same(behavior.profiles['shy']));
  });
  for (final skin in ['crf_skn_002_0001_01', 'crf_skn_002_0001_99']) {
    final resource = File('assets/character/ryza/$skin/${skin}_gesture.json');
    test(
      'reads every authored normal expression and enabled attitude in $skin',
      () {
        final source = resource.readAsStringSync();
        final raw = jsonDecode(source) as Map<String, dynamic>;
        final sourceProfiles =
            (raw['emotionalGesture'] as Map)['EmotionProfilesV4'] as Map;
        final behavior = CharacterResourceBehavior.parse(source);
        expect(behavior.profiles.keys.toSet(), {
          'angry',
          'crying',
          'cuddle',
          'happy',
          'laughing',
          'neutral',
          'sad',
          'shy',
          'tease',
        });
        expect(
          behavior.fixedBasePoseMode,
          (raw['projectConfig'] as Map)['fixedBasePoseMode'],
        );
        for (final entry in sourceProfiles.entries) {
          final data = entry.value as Map;
          final profile = behavior.profiles[entry.key]!;
          final normal = (data['intensityProfiles'] as Map)['normal'] as Map;
          final expressions = (normal['expressionSets'] as List)
              .cast<Map>()
              .where((item) => ((item['weight'] ?? 1) as num) > 0)
              .toList();
          expect(
            profile.expressionSets.length,
            expressions.length,
            reason: '$skin ${entry.key}: no authored tuple may be lost',
          );
          for (var i = 0; i < expressions.length; i++) {
            final actual = profile.expressionSets[i];
            final expected = expressions[i];
            expect(
              [actual.eyeOpen, actual.eyeClosed, actual.eyebrow, actual.mouth],
              [
                expected['eyeOpen'],
                expected['eyeClosed'],
                expected['eyebrow'],
                expected['mouth'],
              ],
              reason: '$skin ${entry.key}: preserve each complete tuple',
            );
          }
          final sourceAttitudes =
              (data['fixedGestureBindingsByAttitude'] as Map?) ?? const {};
          for (final attitude in ['agree', 'deny', 'question']) {
            final expected = ((sourceAttitudes[attitude] as List?) ?? const [])
                .cast<Map>()
                .where((item) => (item['weight'] as num) > 0)
                .map(
                  (item) => [
                    item['oneShotAnimation'],
                    item['fixedGestureId'],
                    item['eye'],
                    (item['weight'] as num).toDouble(),
                  ],
                )
                .toList();
            final actual =
                (profile.fixedGestureBindingsByAttitude[attitude] ?? const [])
                    .map(
                      (item) => [
                        item.oneShotAnimation,
                        item.fixedGestureId,
                        item.eye,
                        item.weight,
                      ],
                    )
                    .toList();
            expect(
              actual,
              expected,
              reason: '$skin ${entry.key}/$attitude: retain enabled variants',
            );
          }
        }
      },
      skip: resource.existsSync()
          ? false
          : 'Optional original resource is not installed in this checkout.',
    );
  }

  test(
    'reads authored expression tuples and normal profile without renaming',
    () {
      final behavior = parseProfiles({
        'sad': {
          'baseAnimTimeScale': 0.75,
          'mixDurationMin': 1.5,
          'mixDurationMax': 2.5,
          'lipSyncScrubClip': 'facial_mouth_013_scrub_02',
          'intensityProfiles': {
            'normal': {
              'expressionSets': [
                {
                  'id': 'sad_pair',
                  'eyeOpen': 'facial_eye_007',
                  'eyeClosed': 'facial_eye_001_idle',
                  'eyebrow': 'facial_eyebrow_010_idle',
                  'mouth': 'facial_mouth_002',
                },
              ],
              'mixDurationEye': 0.58,
              'mixDurationEyebrow': 0.58,
              'poseRerollIntervalMin': 5,
              'poseRerollIntervalMax': 8,
            },
            'strong': {
              'expressionSets': [
                {
                  'eyeOpen': 'strong_eye',
                  'eyebrow': 'strong_brow',
                  'mouth': 'strong_mouth',
                },
              ],
            },
          },
        },
      });
      final profile = behavior.profiles['sad']!;
      final expression = profile.expressionSets.single;
      expect(expression.id, 'sad_pair');
      expect(expression.eyeOpen, 'facial_eye_007');
      expect(expression.eyeClosed, 'facial_eye_001_idle');
      expect(expression.eyebrow, 'facial_eyebrow_010_idle');
      expect(expression.mouth, 'facial_mouth_002');
      expect(profile.lipSyncScrubClip, 'facial_mouth_013_scrub_02');
      expect(profile.baseAnimTimeScale, 0.75);
      expect(profile.mixDurationEye, 0.58);
      expect(profile.mixDurationEyebrow, 0.58);
      expect(profile.mixDurationMin, 1.5);
      expect(profile.mixDurationMax, 2.5);
      expect(profile.poseRerollIntervalMin, 5);
      expect(profile.poseRerollIntervalMax, 8);
    },
  );

  test('preserves pose eligibility and explicit rare pose weights', () {
    final profile = parseProfiles({
      'neutral': {
        'intensityProfiles': {
          'normal': {
            'basePoses': [
              {
                'id': 'motion_A_001_idle',
                'poseTypeIds': ['posetype_01_freehand'],
              },
              {'id': 'motion_A_007_idle', 'weight': '0.05'},
              {
                'id': 'motion_A_029_idle',
                'applicableSittingIds': ['sitting_normal'],
              },
              {'id': 'disabled', 'weight': 0},
              {'id': 'invalid', 'weight': 'Infinity'},
            ],
          },
        },
      },
    }).profiles['neutral']!;
    expect(profile.basePoses.map((pose) => pose.id), [
      'motion_A_001_idle',
      'motion_A_007_idle',
      'motion_A_029_idle',
    ]);
    expect(profile.basePoses.first.poseTypeIds, ['posetype_01_freehand']);
    expect(profile.basePoses.first.weight, 1);
    expect(profile.basePoses[1].weight, 0.05);
    expect(profile.basePoses.last.supportsSitting('sitting_normal'), isTrue);
    expect(profile.basePoses.last.supportsSitting('sitting_agura'), isFalse);
    expect(profile.basePoses.first.supportsSitting('sitting_agura'), isTrue);
  });

  test('zero-weight attitude variants never become automatic reactions', () {
    final profile = parseProfiles({
      'sad': {
        'fixedGestureBindingsByAttitude': {
          'deny': [
            {
              'attitude': 'deny',
              'eye': 'lookAtUser',
              'oneShotAnimation': 'motion_oneshot_D_003_active',
              'fixedGestureId': '',
              'weight': 0,
            },
            {
              'attitude': 'deny',
              'eye': 'lookAtUser',
              'oneShotAnimation': 'motion_oneshot_D_007_active',
              'fixedGestureId': '',
              'weight': 1,
            },
          ],
          'question': [
            {'fixedGestureId': 'question_target', 'weight': 2},
            {'oneShotAnimation': '', 'fixedGestureId': '', 'weight': 1},
          ],
        },
      },
    }).profiles['sad']!;
    final deny = profile.fixedGestureBindingsByAttitude['deny']!;
    expect(deny.single.oneShotAnimation, 'motion_oneshot_D_007_active');
    expect(deny.single.eye, 'lookAtUser');
    expect(deny.single.attitude, 'deny');
    expect(
      profile.fixedGestureBindingsByAttitude['question']!.single.fixedGestureId,
      'question_target',
    );
    final random = Random(8);
    for (var i = 0; i < 30; i++) {
      expect(
        chooseResourceWeighted(
          deny,
          (binding) => binding.weight,
          random,
        )?.oneShotAnimation,
        'motion_oneshot_D_007_active',
      );
    }
  });

  test('bad fields fall back without fabricating mixed expression sets', () {
    final profile = parseProfiles({
      'neutral': {
        'baseAnimTimeScale': 0,
        'mixDurationMin': '3',
        'mixDurationMax': '1',
        'intensityProfiles': {
          'normal': {
            'mixDurationEye': 'NaN',
            'mixDurationEyebrow': -1,
            'poseRerollIntervalMin': 0,
            'poseRerollIntervalMax': 0,
            'expressionSets': [
              {'eyeOpen': 'one_eye', 'eyebrow': 'one_brow'},
              {'mouth': 'other_mouth'},
              {
                'eyeOpen': 'disabled_eye',
                'eyebrow': 'disabled_brow',
                'mouth': 'disabled_mouth',
                'weight': 0,
              },
            ],
          },
        },
      },
    }).profiles['neutral']!;
    expect(profile.expressionSets, isEmpty);
    expect(profile.baseAnimTimeScale, 1);
    expect(profile.mixDurationMin, 1);
    expect(profile.mixDurationMax, 3);
    expect(profile.mixDurationEye, 0.45);
    expect(profile.mixDurationEyebrow, 0.45);
    expect(profile.poseRerollIntervalMin, 5);
    expect(profile.poseRerollIntervalMax, 8);
    expect(profile.lipSyncScrubClip, isNull);
  });

  test('uses base fields only if there are no authored expression sets', () {
    final profile = parseProfiles({
      'neutral': {
        'intensityProfiles': {
          'normal': {
            'eyeBase': 'base_eye',
            'eyebrowBase': 'base_brow',
            'mouthBase': 'base_mouth',
          },
        },
      },
    }).profiles['neutral']!;
    expect(profile.expressionSets.single.eyeOpen, 'base_eye');
    expect(profile.expressionSets.single.eyeClosed, 'facial_eye_001_idle');
  });

  test('missing and malformed resources safely produce empty data', () {
    for (final source in ['no json', '[]', 'null', '{}']) {
      expect(CharacterResourceBehavior.parse(source).profiles, isEmpty);
    }
    final behavior = parseProfiles({
      '': {},
      'bad': [],
      'neutral': {
        'intensityProfiles': {
          'strong': {
            'basePoses': [
              {'id': 'should_not_be_used'},
            ],
          },
        },
      },
    });
    expect(behavior.profiles.keys, ['neutral']);
    expect(behavior.profiles['neutral']!.basePoses, isEmpty);
    expect(behavior.profiles['neutral']!.expressionSets, isEmpty);
  });

  test('keeps resource posture locks and defaults conservatively', () {
    final locked = CharacterResourceBehavior.parse('{}');
    expect(locked.fixedBasePoseMode, isTrue);
    expect(locked.lockSittingAxis, isTrue);
    final unlocked = CharacterResourceBehavior.parse(
      jsonEncode({
        'projectConfig': {'fixedBasePoseMode': false, 'lockSittingAxis': false},
      }),
    );
    expect(unlocked.fixedBasePoseMode, isFalse);
    expect(unlocked.lockSittingAxis, isFalse);
  });

  test('weighted choice excludes invalid weights and handles large values', () {
    final random = Random(4);
    expect(
      chooseResourceWeighted([0.0, -1.0, double.nan], (value) => value, random),
      isNull,
    );
    expect(
      chooseResourceWeighted(
        [0.0, double.infinity, 4.0],
        (value) => value,
        random,
      ),
      4,
    );
    final samples = [
      for (var i = 0; i < 200; i++)
        chooseResourceWeighted(['a', 'b'], (_) => double.maxFinite, random),
    ];
    expect(samples.toSet(), {'a', 'b'});
  });
}
