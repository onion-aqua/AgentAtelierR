import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/audio_envelope.dart';
import 'package:ryza_chat_mvp/src/character_speech_driver.dart';

void main() {
  test('missing optional rig mappings never call native bone lookup', () {
    final queried = <String>[];
    String? lookup(String name) {
      queried.add(name);
      return name == 'head' ? name : null;
    }

    expect(resolveOptionalRigBone(null, lookup), isNull);
    expect(resolveOptionalRigBone('', lookup), isNull);
    expect(resolveOptionalRigBone('  ', lookup), isNull);
    expect(queried, isEmpty);
    expect(resolveOptionalRigBone('head', lookup), 'head');
    expect(resolveOptionalRigBone('missing', lookup), isNull);
    expect(queried, ['head', 'missing']);
  });
  CharacterPerformanceProfile fixture() => CharacterPerformanceProfile.parse(
    jsonEncode({
      'rigConfig': {
        'aimSlots': {
          'head': {'bone': 'test_head'},
        },
      },
      'emotionalGesture': {
        'DriverDefs': [
          {'Spec': 'malformed'},
          for (final emotion in ['happy', 'sad'])
            {
              'Spec': jsonEncode({
                'id': '${emotion}_n_1',
                'driver': 'head',
                'yawMin': 0.5,
                'yawMax': 0.5,
                'pitchMin': emotion == 'happy' ? 0.5 : -0.5,
                'pitchMax': emotion == 'happy' ? 0.5 : -0.5,
                'rollMin': 0.4,
                'rollMax': 0.4,
                'transitionMin': 0.6,
                'transitionMax': 0.6,
                'holdMin': 3,
                'holdMax': 3,
                'followers': [
                  {'part': 'body', 'scale': 0.8, 'delay': 0.4},
                ],
              }),
            },
        ],
      },
    }),
  );

  test(
    'resource drivers interpolate emotion changes with delayed followers',
    () {
      final profile = fixture();
      expect(profile.drivers.length, 2);
      expect(profile.aimBones['head'], 'test_head');
      final director = CharacterPerformanceDirector(profile, random: Random(4));
      Map<String, RigMotion> frame = {};
      for (var i = 0; i < 20; i++) {
        frame = director.sample(
          delta: 0.02,
          emotion: 'happy',
          speaking: true,
          energy: 1,
        );
      }
      expect(frame['head']!.pitch, greaterThan(0));
      expect(frame['body']!.pitch, lessThan(frame['head']!.pitch * 0.8));
      final previous = frame['head']!.pitch;
      frame = director.sample(
        delta: 0.02,
        emotion: 'sad',
        speaking: true,
        energy: 1,
      );
      expect((frame['head']!.pitch - previous).abs(), lessThan(0.05));
      for (var i = 0; i < 100; i++) {
        frame = director.sample(
          delta: 0.02,
          emotion: 'sad',
          speaking: true,
          energy: 1,
        );
      }
      expect(frame['head']!.pitch, lessThan(-0.4));
      for (var i = 0; i < 100; i++) {
        frame = director.sample(
          delta: 0.02,
          emotion: 'sad',
          speaking: true,
          energy: 1,
          suppressed: true,
        );
      }
      expect(frame['head']!.pitch.abs(), lessThan(0.001));
    },
  );

  test(
    'idle strength is lower and thousands of frames cannot accumulate drift',
    () {
      final talk = CharacterPerformanceDirector(fixture(), random: Random(1));
      final idle = CharacterPerformanceDirector(fixture(), random: Random(1));
      for (var i = 0; i < 10000; i++) {
        final a = talk.sample(
          delta: 1 / 60,
          emotion: 'happy',
          speaking: true,
          energy: 1,
        );
        final b = idle.sample(
          delta: 1 / 60,
          emotion: 'happy',
          speaking: false,
          energy: 0,
        );
        expect(a['head']!.yaw.abs(), lessThanOrEqualTo(0.5));
        if (i > 200) expect(b['head']!.yaw, lessThan(a['head']!.yaw));
      }
    },
  );

  test('syllable energy cannot modulate head, body or eye motion', () {
    final steady = CharacterPerformanceDirector(fixture(), random: Random(7));
    final pulsed = CharacterPerformanceDirector(fixture(), random: Random(7));
    for (var i = 0; i < 900; i++) {
      final baseline = steady.sample(
        delta: 1 / 60,
        emotion: i < 450 ? 'happy' : 'sad',
        speaking: true,
        energy: 0,
      );
      final frame = pulsed.sample(
        delta: 1 / 60,
        emotion: i < 450 ? 'happy' : 'sad',
        speaking: true,
        energy: (sin(i / 60 * 2 * pi * 5.2) + 1) / 2,
      );
      for (final part in baseline.keys) {
        expect(frame[part]!.yaw, baseline[part]!.yaw);
        expect(frame[part]!.pitch, baseline[part]!.pitch);
        expect(frame[part]!.roll, baseline[part]!.roll);
      }
    }
  });

  test('speaking begins and ends smoothly and a held pose comes to rest', () {
    final director = CharacterPerformanceDirector(fixture(), random: Random(1));
    Map<String, RigMotion> frame = {};
    for (var i = 0; i < 120; i++) {
      frame = director.sample(
        delta: 1 / 60,
        emotion: 'happy',
        speaking: false,
        energy: 0,
      );
    }
    expect(frame['head']!.yaw, closeTo(0.15, 0.001));
    final beforeSpeaking = frame['head']!.yaw;
    frame = director.sample(
      delta: 1 / 60,
      emotion: 'happy',
      speaking: true,
      energy: 1,
    );
    expect(frame['head']!.yaw - beforeSpeaking, inExclusiveRange(0, 0.02));
    for (var i = 0; i < 240; i++) {
      frame = director.sample(
        delta: 1 / 60,
        emotion: 'happy',
        speaking: true,
        energy: i.isEven ? 0 : 1,
      );
    }
    expect(frame['head']!.yaw, closeTo(0.425, 0.0001));
    final beforeRelease = frame['head']!.yaw;
    frame = director.sample(
      delta: 1 / 60,
      emotion: 'happy',
      speaking: false,
      energy: 0,
    );
    expect(beforeRelease - frame['head']!.yaw, inExclusiveRange(0, 0.02));
    final beforeSuppress = frame['head']!.yaw;
    frame = director.sample(
      delta: 1 / 60,
      emotion: 'happy',
      speaking: false,
      energy: 0,
      suppressed: true,
    );
    expect(frame['head']!.yaw, greaterThan(beforeSuppress * 0.8));
    for (var i = 0; i < 120; i++) {
      frame = director.sample(
        delta: 1 / 60,
        emotion: 'happy',
        speaking: false,
        energy: 0,
        suppressed: true,
      );
    }
    expect(frame['head']!.yaw.abs(), lessThan(0.0001));
  });

  test(
    'switching the lead part preserves each current pose before blending',
    () {
      final profile = CharacterPerformanceProfile.parse(
        jsonEncode({
          'emotionalGesture': {
            'DriverDefs': [
              for (final part in ['head', 'body'])
                {
                  'Spec': jsonEncode({
                    'id': '${part}_n_1',
                    'driver': part,
                    'yawMin': part == 'head' ? 0.7 : -0.7,
                    'yawMax': part == 'head' ? 0.7 : -0.7,
                    'transitionMin': 0.6,
                    'transitionMax': 0.6,
                    'holdMin': 3,
                    'holdMax': 3,
                    'followers': [
                      {
                        'part': part == 'head' ? 'eye' : 'head',
                        'scale': 0.3,
                        'delay': 0.2,
                      },
                    ],
                  }),
                },
            ],
          },
        }),
      );
      final director = CharacterPerformanceDirector(profile, random: Random(2));
      Map<String, RigMotion> frame = {};
      for (var i = 0; i < 180; i++) {
        frame = director.sample(
          delta: 1 / 60,
          emotion: 'head',
          speaking: true,
          energy: 1,
        );
      }
      expect(frame['head']!.yaw, greaterThan(0.5));
      expect(frame['body']!.yaw, 0);
      final before = frame;
      frame = director.sample(
        delta: 0,
        emotion: 'body',
        speaking: true,
        energy: 1,
      );
      for (final part in before.keys) {
        expect(frame[part]!.yaw, before[part]!.yaw);
      }
      for (var i = 0; i < 180; i++) {
        final previous = frame;
        frame = director.sample(
          delta: 1 / 60,
          emotion: 'body',
          speaking: true,
          energy: 1,
        );
        for (final part in previous.keys) {
          expect(
            (frame[part]!.yaw - previous[part]!.yaw).abs(),
            lessThan(0.04),
          );
        }
      }
      expect(frame['body']!.yaw, lessThan(-0.5));
      expect(frame['head']!.yaw, closeTo(-0.7 * 0.3 * 0.85, 0.001));
      expect(frame['eye']!.yaw.abs(), lessThan(0.001));
    },
  );

  test('unsupported resources fall back to bounded target and hold motion', () {
    final profile = CharacterPerformanceProfile.parse(
      jsonEncode({
        'rigConfig': {
          'aimSlots': {
            'head': {'bone': 'declared_head'},
          },
        },
        'emotionalGesture': {
          'attitudes': {'talk_low': 'not a legacy driver'},
        },
      }),
    );
    expect(profile.hasResourceDrivers, isFalse);
    expect(profile.aimBones['head'], 'declared_head');
    expect(CharacterPerformanceProfile.fallback().aimBones, isEmpty);
    final director = CharacterPerformanceDirector(profile, random: Random(3));
    var moved = false;
    Map<String, RigMotion> frame = {};
    for (var i = 0; i < 10000; i++) {
      frame = director.sample(
        delta: 1 / 60,
        emotion: 'happy',
        speaking: true,
        energy: 1,
      );
      moved = moved || frame['head']!.yaw.abs() > 0.001;
      expect(frame['head']!.yaw.abs(), lessThanOrEqualTo(0.08 * 0.85));
      expect(frame['head']!.pitch.abs(), lessThanOrEqualTo(0.08 * 0.85));
      expect(frame['head']!.roll.abs(), lessThanOrEqualTo(0.035 * 0.85));
    }
    expect(moved, isTrue);
    final before = frame;
    for (final delta in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
      -1.0,
    ]) {
      frame = director.sample(
        delta: delta,
        emotion: 'happy',
        speaking: true,
        energy: double.nan,
      );
      for (final part in before.keys) {
        expect(frame[part]!.yaw, before[part]!.yaw);
        expect(frame[part]!.pitch, before[part]!.pitch);
        expect(frame[part]!.roll, before[part]!.roll);
      }
    }
  });

  test('schema 4 attitude patterns drive gaze without legacy DriverDefs', () {
    final profile = CharacterPerformanceProfile.parse(
      jsonEncode({
        'projectConfig': {
          'ambientGaze': {
            'sizeMedium': 0.8,
            'dwellMedium': 1.5,
            'speedNormal': 1.0,
            'followScaleStrong': 0.9,
            'headFollowDelay': 0.1,
          },
        },
        'emotionalGesture': {
          'GesturePatternDefs': [
            {
              'patternId': 'A1',
              'directions': ['上'],
              'faceMovement': '追従（強）',
              'bodyMovement': '動かない',
              'points': 1,
            },
            {
              'patternId': 'A3',
              'directions': ['下'],
              'faceMovement': '追従（弱）',
              'bodyMovement': '動かない',
              'points': 1,
            },
          ],
          'AttitudePatterns': [
            for (final attitude in ['talk_low', 'talk_mid', 'talk_high'])
              {
                'attitude': attitude,
                'patternId': 'A1',
                'size': '中',
                'dwell': '中',
                'moveSpeed': '普通',
                'weight': 1,
              },
            for (final attitude in ['idle_low', 'idle_mid', 'idle_high'])
              {
                'attitude': attitude,
                'patternId': 'A3',
                'size': '中',
                'dwell': '中',
                'moveSpeed': '普通',
                'weight': 1,
              },
          ],
        },
      }),
    );
    expect(profile.drivers, isEmpty);
    expect(profile.hasResourceDrivers, isTrue);
    expect(profile.attitudeDrivers['talk_low'], hasLength(1));
    final director = CharacterPerformanceDirector(profile, random: Random(2));
    Map<String, RigMotion> frame = {};
    for (var i = 0; i < 120; i++) {
      frame = director.sample(
        delta: 1 / 60,
        emotion: 'neutral',
        speaking: true,
        energy: 0,
      );
    }
    expect(frame['eye']!.pitch, greaterThan(0.2));
    expect(frame['head']!.pitch, greaterThan(0));
    for (var i = 0; i < 180; i++) {
      frame = director.sample(
        delta: 1 / 60,
        emotion: 'neutral',
        speaking: false,
        energy: 0,
      );
    }
    expect(frame['eye']!.pitch, lessThan(0));
  });

  test(
    'schema 4 returns from a glance and keeps user-facing eyes centered',
    () {
      final profile = CharacterPerformanceProfile.parse(
        jsonEncode({
          'projectConfig': {
            'ambientGaze': {
              'yawLimit': 0.8,
              'sizeMedium': 0.85,
              'dwellShort': 0.6,
              'moveBaseSeconds': 0.15,
            },
          },
          'emotionalGesture': {
            'GesturePatternDefs': [
              {
                'patternId': 'C1',
                'eyeMovement': '指定方向',
                'faceMovement': '追従（弱）',
                'directions': ['横'],
                'route': '外して戻る',
                'points': 2,
              },
              {
                'patternId': 'B3',
                'eyeMovement': 'ユーザー注視',
                'faceMovement': '指定方向',
                'directions': ['横'],
                'route': '1点',
                'points': 1,
              },
            ],
            'AttitudePatterns': [
              {
                'attitude': 'idle_low',
                'patternId': 'C1',
                'size': '中',
                'dwell': '短',
                'moveSpeed': '普通',
                'repeatMin': 1,
                'repeatMax': 1,
                'weight': 1,
              },
              {
                'attitude': 'agree',
                'patternId': 'B3',
                'size': '中',
                'dwell': '短',
                'moveSpeed': '普通',
                'oneShotAnimation': 'motion_oneshot_D_001_active',
                'weight': 1,
              },
            ],
          },
        }),
      );
      expect(profile.oneShotAttitudes('agree'), hasLength(1));
      final director = CharacterPerformanceDirector(profile, random: Random(4));
      Map<String, RigMotion> frame = {};
      for (var i = 0; i < 35; i++) {
        frame = director.sample(
          delta: 1 / 60,
          emotion: 'neutral',
          speaking: false,
          energy: 0,
        );
      }
      final glance = frame['eye']!.yaw.abs();
      expect(glance, greaterThan(0.08));
      for (var i = 0; i < 75; i++) {
        frame = director.sample(
          delta: 1 / 60,
          emotion: 'neutral',
          speaking: false,
          energy: 0,
        );
      }
      expect(frame['eye']!.yaw.abs(), lessThan(glance * 0.4));

      director.cueAttitude(profile.oneShotAttitudes('agree').single);
      for (var i = 0; i < 35; i++) {
        frame = director.sample(
          delta: 1 / 60,
          emotion: 'neutral',
          speaking: false,
          energy: 0,
        );
      }
      expect(director.hasActiveAttitudeCue, isTrue);
      expect(frame['eye']!.yaw.abs(), lessThan(0.02));
      expect(frame['head']!.yaw.abs(), greaterThan(0.08));
    },
  );

  test('playback interpolation is bounded and audio end closes the mouth', () {
    expect(
      interpolatedSpeechPosition(
        const Duration(seconds: 1),
        const Duration(milliseconds: 75),
      ),
      const Duration(milliseconds: 1075),
    );
    expect(
      interpolatedSpeechPosition(
        const Duration(seconds: 1),
        const Duration(seconds: 5),
      ),
      const Duration(milliseconds: 1250),
    );
    const envelope = AudioAmplitudeEnvelope(
      frameDuration: Duration(milliseconds: 20),
      values: [0, 1],
    );
    expect(envelope.valueAt(const Duration(seconds: 1)), 0);
    expect(envelope.valueAt(const Duration(milliseconds: 10)), 0.5);
  });
}
