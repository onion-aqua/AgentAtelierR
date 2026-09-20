import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_motion_dynamics.dart';

void main() {
  test('gesture transitions retain authored easing and bound invalid data', () {
    expect(smoothCharacterGestureMix(0.12, 0.6), 0.6);
    expect(smoothCharacterGestureMix(0.9, 0.6), 0.9);
    expect(smoothCharacterGestureMix(0, 0), 0.45);
    expect(smoothCharacterGestureMix(double.nan, double.nan), 0.6);
    expect(smoothCharacterGestureMix(100, 100), 2);
  });
  test(
    'pose distance chooses a longer mix for large moves, ignoring controls',
    () {
      final transitions = CharacterMotionTransitions({
        'projectConfig': {'mixDurationSaturationRatio': 0.1},
        'emotionalGesture': {
          'MixDurationPoses': {
            'animPoses': {
              'start': {
                'head': [0, 0],
                'control_aim_head': [0, 0],
              },
              'close': {
                'head': [10, 0],
                'control_aim_head': [1000000, 0],
              },
              'far': {
                'head': [500, 0],
              },
              'invalid': {
                'head': ['bad', 0],
              },
            },
          },
        },
      });
      double mix(String to) =>
          transitions.poseMix('start', to, minimum: 1, maximum: 2);
      expect(mix('close'), inInclusiveRange(0.12, 0.3));
      expect(mix('far'), greaterThan(1.5));
      expect(mix('close'), lessThan(mix('far')));
      expect(mix('missing'), 1);
      expect(mix('invalid'), 1);
    },
  );

  test('both arm ranks influence transitions including return to idle', () {
    final transitions = CharacterMotionTransitions({
      'projectConfig': {
        'armInOutPartConfig': {
          'rankPositions': {'0': 0, '2': 0.15, '4': 0.35},
          'byGroupId': {
            'near': {'left': 0, 'right': 2},
            'far': {'left': 4, 'right': 0},
          },
          'minSeconds': 0.4,
          'maxSeconds': 1,
          'pairStartDelayReferenceDistance': 0.35,
        },
      },
    });
    expect(transitions.groupMix(null, 'near', fallback: 0.6), lessThan(1));
    expect(transitions.groupMix('near', 'far', fallback: 0.6), 1);
    expect(transitions.groupMix('far', null, fallback: 0.6), 1);
    expect(transitions.groupMix('far', 'unknown', fallback: 0.6), 0.6);
  });

  test('indoor and unknown stages are calm; forest less windy than coast', () {
    for (final id in [
      'stage_00_000_00',
      'stage_01_001_04',
      'stage_01_004_01',
      'unknown',
    ]) {
      expect(characterWindForStage(id), 0);
    }
    expect(characterWindForStage('stage_01_002_01'), greaterThan(0));
    expect(
      characterWindForStage('stage_01_002_01'),
      lessThan(characterWindForStage('stage_01_003_01')),
    );
  });

  test(
    'wind transitions are frame-rate independent, settle, and bound stalls',
    () {
      double ramp(int fps) {
        final wind = CharacterWindEnvelope();
        for (var i = 0; i < fps * 3; i++) {
          wind.advance(1 / fps, 0.5);
        }
        return wind.strength;
      }

      expect(ramp(24), closeTo(ramp(120), 0.000001));
      final wind = CharacterWindEnvelope();
      expect(wind.advance(30, 0.5), lessThan(0.04));
      for (var i = 0; i < 120; i++) {
        wind.advance(1 / 30, 0.5);
      }
      var previous = wind.strength;
      for (var i = 0; i < 300; i++) {
        final next = wind.advance(1 / 30, 0);
        expect(next, inInclusiveRange(0, previous));
        previous = next;
      }
      expect(wind.strength, 0);
      expect(wind.advance(double.nan, 1), 0);
      expect(wind.advance(0.04, double.infinity), 0);
    },
  );
}
