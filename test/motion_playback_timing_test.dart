import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spine_flutter/spine_flutter.dart';
import 'package:ryza_chat_mvp/src/character_track_transition.dart';
import 'package:ryza_chat_mvp/src/motion_playback_timing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real clap has one readable cycle and a visible final pose', () {
    // F/G050 are 0.2 seconds, while the resource's BlendTime is 0.6 seconds.
    final timing = MotionPlaybackTiming.forClip(
      0.20000001788139343,
      mixDuration: 0.6,
    );

    expect(timing.loop, isFalse);
    expect(timing.mixDuration, closeTo(0.15, 0.00001));
    expect(timing.timeScale, closeTo(1 / 3, 0.00001));
    expect(timing.duration.inMicroseconds, inInclusiveRange(900000, 900001));
    expect(timing.duration, greaterThan(const Duration(milliseconds: 200)));
  });

  test('zero-duration pose gets an entrance followed by a readable hold', () {
    final timing = MotionPlaybackTiming.forClip(0, mixDuration: 0.6);

    expect(timing.loop, isFalse);
    expect(timing.mixDuration, 0.6);
    expect(timing.duration, const Duration(milliseconds: 1200));
    expect(
      timing.duration.inMicroseconds -
          (timing.mixDuration * Duration.microsecondsPerSecond).round(),
      600000,
    );
  });

  test('ordinary authored clip plays once with its original safe mix', () {
    final timing = MotionPlaybackTiming.forClip(3.33, mixDuration: 0.6);

    expect(timing.loop, isFalse);
    expect(timing.mixDuration, 0.6);
    expect(timing.duration.inMicroseconds, inInclusiveRange(3930000, 3930001));
  });

  test('one-second boundary stays a single authored cycle', () {
    final timing = MotionPlaybackTiming.forClip(1, mixDuration: 0.34);

    expect(timing.loop, isFalse);
    expect(timing.mixDuration, 0.34);
    expect(timing.duration.inMicroseconds, inInclusiveRange(1340000, 1340001));
  });

  test('playback speed affects the short cycle and safe entrance mix', () {
    final timing = MotionPlaybackTiming.forClip(
      0.2,
      mixDuration: 0.6,
      speed: 2,
    );

    expect(timing.loop, isFalse);
    expect(timing.mixDuration, closeTo(0.15, 0.00001));
    expect(timing.timeScale, closeTo(1 / 3, 0.00001));
    expect(timing.duration.inMicroseconds, inInclusiveRange(900000, 900001));
  });

  test('slowed short source can become a full single cycle', () {
    final timing = MotionPlaybackTiming.forClip(
      0.2,
      mixDuration: 0.6,
      speed: 0.1,
    );

    expect(timing.loop, isFalse);
    expect(timing.mixDuration, 0.6);
    expect(timing.timeScale, 0.1);
    expect(timing.duration, const Duration(milliseconds: 2600));
  });

  test('explicit cycles are finite and do not shorten the visible window', () {
    final timing = MotionPlaybackTiming.forClip(
      1.5,
      mixDuration: 0.4,
      repeatCount: 3,
    );

    expect(timing.loop, isTrue);
    expect(timing.duration.inMicroseconds, inInclusiveRange(4900000, 4900001));
    final shortTiming = MotionPlaybackTiming.forClip(
      0.2,
      mixDuration: 0.6,
      repeatCount: 2,
    );
    expect(shortTiming.loop, isTrue);
    expect(
      shortTiming.duration.inMicroseconds,
      inInclusiveRange(1500000, 1500001),
    );
  });

  test('unconfirmed zero repeat count does not mean endless playback', () {
    final timing = MotionPlaybackTiming.forClip(
      3,
      mixDuration: 0.6,
      repeatCount: 0,
    );

    expect(timing.loop, isFalse);
    expect(timing.duration, const Duration(milliseconds: 3600));
  });

  test(
    'invalid numeric input safely becomes a bounded pose or default speed',
    () {
      for (final duration in [-1.0, double.nan, double.infinity]) {
        final timing = MotionPlaybackTiming.forClip(
          duration,
          mixDuration: double.nan,
        );
        expect(timing.loop, isFalse);
        expect(timing.duration, const Duration(milliseconds: 1200));
        expect(timing.mixDuration, 0.6);
      }
      for (final speed in [0.0, double.nan, double.infinity]) {
        final timing = MotionPlaybackTiming.forClip(
          2,
          mixDuration: 0.4,
          speed: speed,
        );
        expect(timing.loop, isFalse);
        expect(timing.duration, const Duration(milliseconds: 2400));
      }
    },
  );

  test('oversized mix cannot drown a short clip', () {
    final timing = MotionPlaybackTiming.forClip(0.2, mixDuration: 100);

    expect(timing.mixDuration, closeTo(0.15, 0.00001));
    expect(timing.loop, isFalse);
    final pose = MotionPlaybackTiming.forClip(0, mixDuration: 100);
    expect(pose.mixDuration, 2);
    expect(pose.duration, const Duration(milliseconds: 2600));
  });

  final nativeEnabled = Platform.environment['AAR_SPINE_NATIVE_TEST'] == '1';
  const resource =
      'assets/character/ryza/crf_skn_002_0001_01/crf_skn_002_0001_01';
  test(
    'native real clap reaches full influence before its peak and completes once',
    () async {
      await initSpineFlutter();
      final drawable = await SkeletonDrawable.fromFile(
        '$resource.atlas',
        '$resource.skel',
      );
      try {
        final state = drawable.animationState;
        state.setAnimationByName(0, 'motion_A_001_idle', true);
        final clip = drawable.skeletonData.findAnimation(
          'motion_add_F_050_active',
        )!;
        expect(clip.getDuration(), closeTo(0.2, 0.00001));
        final timing = MotionPlaybackTiming.forClip(
          clip.getDuration(),
          mixDuration: 0.6,
        );
        var completedCycles = 0;
        for (final (track, name) in [
          (6, 'motion_add_F_050_active'),
          (7, 'motion_add_G_050_active'),
        ]) {
          final entry =
              transitionCharacterTrack(
                  state,
                  track,
                  name,
                  loop: timing.loop,
                  mixDuration: timing.mixDuration,
                )
                ..setTimeScale(timing.timeScale)
                ..setAlpha(1)
                ..setMixBlend(MixBlend.replace);
          if (track == 6) {
            entry.setListener((type, _, _) {
              if (type == EventType.complete) completedCycles++;
            });
          }
        }
        final bone = drawable.skeleton.findBone('arm_L3')!;
        double? initialY;
        double? peakY;
        double? finalY;
        for (var frame = 0; frame < 108; frame++) {
          drawable.update(1 / 120);
          if (frame == 18) initialY = bone.getY();
          if (frame == 36) {
            peakY = bone.getY();
            final current = state.getCurrent(6)!;
            expect(
              current.getMixTime(),
              greaterThanOrEqualTo(timing.mixDuration),
            );
            expect(current.getTrackTime(), lessThan(clip.getDuration()));
          }
          if (frame == 96) finalY = bone.getY();
        }
        expect(completedCycles, 1);
        expect(state.getCurrent(6)!.getAnimation().getName(), clip.getName());
        expect((peakY! - finalY!).abs(), greaterThan(2));
        expect((peakY - initialY!).abs(), greaterThan(2));
        for (final track in [6, 7]) {
          state.setEmptyAnimation(track, 0.6);
        }
        for (var frame = 0; frame < 90; frame++) {
          drawable.update(1 / 120);
        }
        expect(state.getCurrent(6), isNull);
        expect(state.getCurrent(7), isNull);
      } finally {
        drawable.dispose();
      }
    },
    skip: !nativeEnabled || !File('$resource.skel').existsSync()
        ? 'Opt-in native regression: AAR_SPINE_NATIVE_TEST=1 and local assets required.'
        : false,
  );
}
