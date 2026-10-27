import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spine_flutter/spine_flutter.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/character_startup_sleep.dart';

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
    '0006_01',
    '0007_01',
  ]) {
    final skin = 'crf_skn_002_$id';
    final root = 'assets/character/ryza/$skin/$skin';
    test(
      'native sleep face and breathing remain active for $skin',
      () async {
        await initSpineFlutter();
        final drawable = await SkeletonDrawable.fromFile(
          '$root.atlas',
          '$root.skel',
        );
        try {
          final state = drawable.animationState;
          final face = resolveStartupSleepFace(
            characterAppearances
                .firstWhere((entry) => entry.assetName == skin)
                .id,
            (name) => drawable.skeletonData.findAnimation(name) != null,
          );
          expect(face.eye, isNotNull);
          expect(face.eyebrow, isNotNull);
          expect(face.mouth, isNotNull);
          state.setAnimationByName(0, 'motion_A_001_idle', true);
          state.setAnimationByName(11, face.eye!, true);
          state.setAnimationByName(12, face.eyebrow!, true);
          state.setAnimationByName(13, face.mouth!, true);
          final rootBone = drawable.skeleton.getBones().first;
          final rootPosition = (rootBone.getX(), rootBone.getY());
          final body = drawable.skeleton.findBone('control_aim_body');
          final head = drawable.skeleton.findBone('control_aim_head');
          expect(body, isNotNull);
          expect(head, isNotNull);
          final motion = CharacterStartupSleepMotion();
          final saved = <Bone, (double, double)>{};
          var minimumBodyPitch = double.infinity;
          var maximumBodyPitch = double.negativeInfinity;
          for (var i = 0; i < 600; i++) {
            drawable.update(
              1 / 60,
              beforeApply: () {
                for (final entry in saved.entries) {
                  entry.key
                    ..setX(entry.value.$1)
                    ..setY(entry.value.$2);
                }
                saved.clear();
              },
              afterApply: () {
                final frame = motion.sample(delta: 1 / 60, sleeping: true);
                for (final entry in {
                  head!: frame.head,
                  body!: frame.body,
                }.entries) {
                  final bone = entry.key;
                  saved[bone] = (bone.getX(), bone.getY());
                  bone.setY(bone.getY() + entry.value.pitch * 48);
                }
                minimumBodyPitch = frame.body.pitch < minimumBodyPitch
                    ? frame.body.pitch
                    : minimumBodyPitch;
                maximumBodyPitch = frame.body.pitch > maximumBodyPitch
                    ? frame.body.pitch
                    : maximumBodyPitch;
              },
            );
            expect(state.getCurrent(11)!.getAnimation().getName(), face.eye);
            expect(rootBone.getX(), rootPosition.$1);
            expect(rootBone.getY(), rootPosition.$2);
            for (final name in ['head', 'neck', 'shoulder_L', 'shoulder_R']) {
              final bone = drawable.skeleton.findBone(name)!;
              expect(bone.getWorldX().isFinite, isTrue);
              expect(bone.getWorldY().isFinite, isTrue);
            }
          }
          expect(state.getCurrent(0)!.getTrackTime(), greaterThan(9));
          expect(maximumBodyPitch - minimumBodyPitch, greaterThan(.065));
        } finally {
          drawable.dispose();
        }
      },
      skip: !enabled || !File('$root.skel').existsSync()
          ? 'Opt-in native regression: local Spine DLL and owned assets required.'
          : false,
    );
  }
}
