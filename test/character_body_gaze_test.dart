import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_gaze.dart';

void main() {
  Map<String, GazeBoneOffset> run(
    CharacterBodyGaze gaze, {
    int fps = 60,
    Offset direction = const Offset(1, 0),
    double influence = 1,
    bool standing = true,
    bool crossLegged = false,
    bool allowShoulders = true,
  }) {
    Map<String, GazeBoneOffset> result = {};
    for (var i = 0; i < fps; i++) {
      result = gaze.sample(
        direction: direction,
        delta: 1 / fps,
        influence: influence,
        standing: standing,
        crossLegged: crossLegged,
        allowShoulders: allowShoulders,
        busy: false,
        tapReaction: false,
      );
    }
    return result;
  }

  test('body follow is independent of 30/60/120 Hz rendering', () {
    final reference = run(CharacterBodyGaze());
    for (final fps in [30, 120]) {
      final actual = run(CharacterBodyGaze(), fps: fps);
      for (final bone in reference.keys) {
        expect(
          (actual[bone]!.translation - reference[bone]!.translation).distance,
          lessThan(0.000001),
        );
        expect(
          actual[bone]!.rotation,
          closeTo(reference[bone]!.rotation, 0.000001),
        );
      }
    }
  });

  test(
    'opposite drags follow opposite directions and extreme drag is bounded',
    () {
      final right = run(CharacterBodyGaze());
      final left = run(CharacterBodyGaze(), direction: const Offset(-10000, 0));
      expect(right['control_roll_body_upper']!.translation.dx, greaterThan(0));
      for (final bone in right.keys) {
        expect(
          (right[bone]!.translation + left[bone]!.translation).distance,
          lessThan(0.000001),
        );
        expect(right[bone]!.rotation, closeTo(-left[bone]!.rotation, 0.000001));
      }
    },
  );

  test('release removes all offsets and resets the next interaction', () {
    final gaze = CharacterBodyGaze();
    run(gaze);
    expect(run(gaze, influence: 0), isEmpty);
    final next = run(gaze, direction: const Offset(-1, 0));
    expect(next, run(CharacterBodyGaze(), direction: const Offset(-1, 0)));
  });

  test('seated poses reduce waist motion and protect authored arms', () {
    final standing = run(CharacterBodyGaze());
    final seated = run(CharacterBodyGaze(), standing: false);
    final crossed = run(
      CharacterBodyGaze(),
      standing: false,
      crossLegged: true,
    );
    final authored = run(CharacterBodyGaze(), allowShoulders: false);
    const waist = 'control_roll_body_lower';
    expect(
      seated[waist]!.translation.distance,
      lessThan(standing[waist]!.translation.distance),
    );
    expect(
      crossed[waist]!.translation.distance,
      lessThan(seated[waist]!.translation.distance),
    );
    for (final bone in ['shoulder_L', 'shoulder_R']) {
      expect(crossed[bone]!.rotation, 0);
      expect(authored[bone]!.rotation, 0);
    }
    expect(standing.keys, isNot(contains('root')));
  });
}
