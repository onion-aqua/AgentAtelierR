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
