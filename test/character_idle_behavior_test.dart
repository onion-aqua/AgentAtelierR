import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_idle_behavior.dart';
import 'package:ryza_chat_mvp/src/character_speech_driver.dart';

void main() {
  test('speech permits only explicitly weighted torso tracks', () {
    expect(isSpeakingTorsoMotion('EH', 0.8), isTrue);
    expect(isSpeakingTorsoMotion('E', 2.5), isTrue);
    expect(isSpeakingTorsoMotion('FG', 2.5), isFalse);
    expect(isSpeakingTorsoMotion('CEH', 2.5), isFalse);
    expect(isSpeakingTorsoMotion('EH', 0), isFalse);
    expect(isSpeakingTorsoMotion('EH', null), isFalse);
    expect(isSpeakingTorsoMotion('EH', double.nan), isFalse);
  });
  test('idle supplement preserves outfit choices and explicit empty bindings', () {
    final current = {
      'emotionalGesture': {
        'MotionGroups': ['keep'],
        'EmotionProfilesV4': {
          'neutral': {
            'tensionProfiles': {
              'low': {'ambientBindings': []},
              'high': {},
            },
            'intensityProfiles': {
              'normal': {
                'expressionSets': ['keep'],
              },
            },
          },
        },
      },
    };
    final reference = {
      'emotionalGesture': {
        'DriverDefs': [
          {'Id': 'reference'},
        ],
        'MotionGroups': ['do-not-copy'],
        'EmotionProfilesV4': {
          'neutral': {
            'tensionProfiles': {
              'low': {
                'ambientBindings': ['low'],
              },
              'high': {
                'ambientBindings': ['high'],
              },
            },
          },
        },
      },
    };
    final merged = jsonDecode(
      restoreMissingIdleDrivers(jsonEncode(current), jsonEncode(reference)),
    )['emotionalGesture'];
    expect(merged['DriverDefs'], [
      {'Id': 'reference'},
    ]);
    expect(merged['MotionGroups'], ['keep']);
    expect(
      merged['EmotionProfilesV4']['neutral']['tensionProfiles']['low']['ambientBindings'],
      isEmpty,
    );
    expect(
      merged['EmotionProfilesV4']['neutral']['tensionProfiles']['high']['ambientBindings'],
      ['high'],
    );
    final once = jsonEncode({'emotionalGesture': merged});
    expect(restoreMissingIdleDrivers(once, jsonEncode(reference)), once);
  });

  test('eye modes respect zero weights, timing and long closed beats', () {
    final random = Random(8);
    final band = {
      'gaze': {
        'eyeModeEntries': [
          {'mode': 'blinkFast', 'weight': 0},
          {'mode': 'closed', 'weight': 1, 'durationSeconds': 1.5},
        ],
      },
    };
    for (var i = 0; i < 100; i++) {
      final beat = chooseCharacterBlink(band, random);
      expect(beat.fast, isFalse);
      expect(beat.closedFor, 1.5);
      expect(beat.gap, inInclusiveRange(4, 7));
    }
    expect(chooseCharacterBlink({}, random).closedFor, 0.12);
  });

  test(
    'idle chooses low-tension binding, never the speaking or disabled pattern',
    () {
      final profile = CharacterPerformanceProfile.parse(
        jsonEncode({
          'emotionalGesture': {
            'DriverDefs': [
              for (final id in ['low', 'high', 'forbidden'])
                {
                  'Spec': jsonEncode({
                    'id': id,
                    'driver': 'head',
                    'yawMin': id == 'low' ? -0.5 : 0.5,
                    'yawMax': id == 'low' ? -0.5 : 0.5,
                    'transitionMin': 0.5,
                    'transitionMax': 0.5,
                    'holdMin': 0.5,
                    'holdMax': 0.5,
                  }),
                },
            ],
            'EmotionProfilesV4': {
              'neutral': {
                'tensionProfiles': {
                  for (final band in ['low', 'mid', 'high'])
                    band: {
                      'ambientBindings': [
                        {
                          'driverDefId': band == 'low' ? 'low' : 'high',
                          'weight': 1,
                          'repeatMin': 3,
                          'repeatMax': 3,
                        },
                        {'driverDefId': 'forbidden', 'weight': 0},
                      ],
                    },
                },
              },
            },
          },
        }),
      );
      final director = CharacterPerformanceDirector(profile, random: Random(1));
      Map<String, RigMotion> frame = {};
      for (var i = 0; i < 600; i++) {
        frame = director.sample(
          delta: 1 / 60,
          emotion: 'neutral',
          speaking: false,
          energy: 0,
        );
        expect(frame['head']!.yaw, lessThanOrEqualTo(0));
      }
      expect(frame['head']!.yaw, lessThan(-0.2));
      for (var i = 0; i < 600; i++) {
        frame = director.sample(
          delta: 1 / 60,
          emotion: 'neutral',
          speaking: true,
          energy: 1,
        );
      }
      expect(director.tensionBand, 'high');
      expect(frame['head']!.yaw, greaterThan(0.3));
    },
  );

  test('explicit empty ambient bindings keep a resting pose', () {
    final director = CharacterPerformanceDirector(
      CharacterPerformanceProfile.parse(
        jsonEncode({
          'emotionalGesture': {
            'EmotionProfilesV4': {
              'neutral': {
                'tensionProfiles': {
                  'low': {'ambientBindings': []},
                },
              },
            },
          },
        }),
      ),
      random: Random(3),
    );
    for (var i = 0; i < 600; i++) {
      final frame = director.sample(
        delta: 1 / 60,
        emotion: 'neutral',
        speaking: false,
        energy: 0,
      );
      for (final part in frame.values) {
        expect([part.yaw, part.pitch, part.roll], [0, 0, 0]);
      }
    }
  });

  for (final posture in ['seated', 'standing']) {
    final file = File('assets/character/ryza/idle_references/$posture.json');
    test(
      'local $posture resource drivers resolve all ambient bindings',
      () {
        final profile = CharacterPerformanceProfile.parse(
          file.readAsStringSync(),
        );
        final ids = profile.drivers.map((d) => d['id']).toSet();
        expect(ids.length, greaterThan(20));
        for (final emotion in profile.emotionProfiles.keys) {
          for (final band in ['low', 'mid', 'high']) {
            final bindings =
                profile.tensionProfile(emotion, band)['ambientBindings']
                    as List? ??
                [];
            for (final binding in bindings) {
              expect(ids, contains(binding['driverDefId']));
            }
          }
        }
      },
      skip: !file.existsSync()
          ? 'Local original resources not installed'
          : false,
    );
  }
}
