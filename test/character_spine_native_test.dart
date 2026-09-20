import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:spine_flutter/spine_flutter.dart';
import 'package:ryza_chat_mvp/src/character_track_transition.dart';

// Opt-in: requires the local Spine native library on PATH and owned resources.
// Exercises the actual Flutter drawable/C++ runtime, not a JS emulation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = Platform.environment['AAR_SPINE_NATIVE_TEST'] == '1';
  for (final id in [
    '0001_01',
    '0001_99',
    '0002_01',
    '0003_01',
    '0004_01',
    '0005_01',
  ]) {
    final skin = 'crf_skn_002_$id';
    final root = 'assets/character/ryza/$skin/$skin';
    test(
      'native frame order, wind and motion stay finite for $skin',
      () async {
        await initSpineFlutter();
        final drawable = await SkeletonDrawable.fromFile(
          '$root.atlas',
          '$root.skel',
        );
        final baseline = SkeletonDrawable(
          drawable.atlas,
          drawable.skeletonData,
          false,
        );
        try {
          final data = drawable.skeletonData;
          // Regression: an empty overlay must have a mixing source, while a
          // live overlay must mix directly without visiting the setup pose.
          final gesture = data.getAnimations().firstWhere(
            (a) => a.getName().startsWith('motion_add_'),
          );
          final state = drawable.animationState;
          final entering =
              transitionCharacterTrack(
                  state,
                  2,
                  gesture.getName(),
                  loop: false,
                  mixDuration: 0.6,
                )
                ..setAlpha(0.85)
                ..setTimeScale(1.1);
          expect(entering.getMixDuration(), closeTo(0.6, 0.001));
          expect(await entering.getAlpha(), closeTo(0.85, 0.001));
          expect(entering.getTimeScale(), closeTo(1.1, 0.001));
          drawable.update(1 / 120);
          drawable.update(1 / 120);
          expect(state.getCurrent(2)!.getMixingFrom(), isNotNull);
          expect(state.getCurrent(2)!.getMixTime(), lessThan(0.6));
          for (var i = 0; i < 90; i++) {
            drawable.update(1 / 120);
          }
          final replacement = transitionCharacterTrack(
            state,
            2,
            gesture.getName(),
            loop: false,
            mixDuration: 0.6,
          );
          expect(
            replacement.getMixingFrom()!.getAnimation().getName(),
            gesture.getName(),
          );
          state.setEmptyAnimation(2, 0.6);
          for (var i = 0; i < 90; i++) {
            drawable.update(1 / 120);
          }
          expect(state.getCurrent(2), isNull);
          final base = data.getAnimations().firstWhere(
            (a) =>
                a.getName().endsWith('_idle') &&
                a.getName().startsWith('motion_A_'),
          );
          drawable.animationState.setAnimationByName(0, base.getName(), true);
          baseline.animationState.setAnimationByName(0, base.getName(), true);
          drawable.animationState.setAnimationByName(
              17,
              'effect_wind_001',
              true,
            )
            ..setMixBlend(MixBlend.replace)
            ..setAlpha(0.5)
            ..setTimeScale(0.65);
          final bones = drawable.skeleton.getBones();
          final rootBone = bones.first;
          final rootBase = baseline.skeleton.getBones().first;
          final control = drawable.skeleton.findBone('control_aim_head');
          double? previousX;
          var frame = 0;
          for (final fps in [24, 60, 120]) {
            for (var i = 0; i < fps * 3; i++) {
              if (previousX != null) control?.setX(previousX!);
              var prepared = false;
              var applied = false;
              drawable.update(
                1 / fps,
                beforeApply: () {
                  prepared = true;
                  expect(applied, isFalse);
                },
                afterApply: () {
                  expect(prepared, isTrue);
                  applied = true;
                  drawable.skeleton.updateWorldTransform(Physics.none);
                  previousX = control?.getX();
                  control?.setX(control.getX() + sin(frame / 60 * 0.8) * 8);
                },
              );
              baseline.update(1 / fps);
              expect(applied, isTrue);
              expect(
                rootBone.getWorldX(),
                closeTo(rootBase.getWorldX(), 0.001),
              );
              expect(
                rootBone.getWorldY(),
                closeTo(rootBase.getWorldY(), 0.001),
              );
              for (final bone in bones) {
                expect(
                  bone.getWorldX().isFinite && bone.getWorldY().isFinite,
                  isTrue,
                );
              }
              frame++;
            }
          }
          drawable.animationState.setEmptyAnimation(17, 0.6);
          for (var i = 0; i < 180; i++) {
            drawable.update(1 / 60);
          }
          expect(drawable.animationState.getCurrent(17), isNull);
        } finally {
          baseline.dispose();
          drawable.dispose();
        }
      },
      skip: !enabled || !File('$root.skel').existsSync()
          ? 'Opt-in native regression: AAR_SPINE_NATIVE_TEST=1 and local assets required.'
          : false,
    );
  }
}
