import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_speech_driver.dart';
import 'package:ryza_chat_mvp/src/character_startup_sleep.dart';

void main() {
  test(
    'sleep closes the eyes using the matching seated or standing resource',
    () {
      for (final entry in {
        'seated_01': 'facial_eye_001_idle',
        'summer_yellow_01': 'facial_eye_001_idle',
        'standing_99': 'facial_eye_002_idle',
      }.entries) {
        final face = resolveStartupSleepFace(entry.key, (_) => true);
        expect(face.eye, entry.value);
        expect(face.eyebrow, 'facial_eyebrow_001_idle');
        expect(face.mouth, 'facial_mouth_001_idle');
      }
      final missing = resolveStartupSleepFace('imported', (_) => false);
      expect(missing.eye, isNull);
      expect(missing.eyebrow, isNull);
      expect(missing.mouth, isNull);
    },
  );

  test(
    'first sleep frame is closed and breathing remains periodic and bounded',
    () {
      final motion = CharacterStartupSleepMotion();
      final start = motion.sample(delta: 0, sleeping: true);
      expect(start.blend, 1);
      var minBreath = double.infinity;
      var maxBreath = double.negativeInfinity;
      for (var i = 0; i < 460; i++) {
        final frame = motion.sample(delta: .01, sleeping: true);
        minBreath = min(minBreath, frame.body.pitch);
        maxBreath = max(maxBreath, frame.body.pitch);
        expect(frame.blend, 1);
        expect(frame.head.pitch, inInclusiveRange(-.1740001, -.1459999));
        expect(frame.head.roll, inInclusiveRange(.0409999, .0490001));
        expect(frame.head.yaw, 0);
        expect(frame.body.yaw, 0);
        expect(frame.body.roll, 0);
      }
      final end = motion.sample(delta: 0, sleeping: true);
      expect(end.body.pitch, closeTo(start.body.pitch, .00001));
      expect(maxBreath - minBreath, greaterThan(.065));
    },
  );

  test(
    'sleep suppresses awake gaze and gestures without moving root or limbs',
    () {
      final awake = {
        'head': const RigMotion(.5, .7, .8),
        'body': const RigMotion(.4, .6, .3),
        'eye': const RigMotion(.6, .7),
      };
      final frame = CharacterStartupSleepMotion().sample(
        delta: 0,
        sleeping: true,
      );
      final parts = frame.merge(awake);
      expect(parts.keys.toSet(), {'head', 'body', 'eye'});
      expect(parts['head']!.pitch, closeTo(-.16, .00001));
      expect(parts['head']!.yaw, 0);
      expect(parts['eye']!.yaw, 0);
      expect(parts['eye']!.pitch, 0);
      expect(awake['head']!.pitch, .7);
    },
  );

  test(
    'waking eases to normal motion and eventually returns its original map',
    () {
      final motion = CharacterStartupSleepMotion();
      final awake = {'head': const RigMotion(.6, .5, .4)};
      final sleeping = motion.sample(delta: 0, sleeping: true);
      final first = motion.sample(delta: 0, sleeping: false);
      expect(first.blend, sleeping.blend);
      var previous = first.blend;
      var frames = 0;
      while (frames++ < 80) {
        final frame = motion.sample(delta: .01, sleeping: false);
        expect(frame.blend, lessThanOrEqualTo(previous));
        previous = frame.blend;
      }
      expect(previous, 0);
      final finalFrame = motion.sample(delta: .01, sleeping: false);
      expect(finalFrame.merge(awake), same(awake));
      expect(
        CharacterStartupSleepMotion().sample(delta: .01, sleeping: false).blend,
        0,
      );
    },
  );

  test(
    'invalid deltas and long uptime cannot accumulate bone offsets or NaN',
    () {
      final motion = CharacterStartupSleepMotion();
      for (final delta in [double.nan, double.infinity, -1.0, 600.0]) {
        final frame = motion.sample(delta: delta, sleeping: true);
        expect(frame.head.pitch.isFinite, isTrue);
        expect(frame.body.pitch.isFinite, isTrue);
      }
      for (var i = 0; i < 60000; i++) {
        final frame = motion.sample(delta: 1 / 60, sleeping: true);
        expect(frame.body.pitch, inInclusiveRange(-.0230001, .0470001));
        expect(frame.head.pitch, inInclusiveRange(-.1740001, -.1459999));
      }
    },
  );
}
