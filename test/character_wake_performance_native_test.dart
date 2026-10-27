import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/character_expression.dart';
import 'package:ryza_chat_mvp/src/character_startup_sleep.dart';
import 'package:ryza_chat_mvp/src/character_wake_performance.dart';
import 'package:spine_flutter/spine_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = Platform.environment['AAR_SPINE_NATIVE_TEST'] == '1';
  final render = Platform.environment['AAR_WAKE_RENDER'] == '1';
  test('inspect yawn mouth resources', () async {
    await initSpineFlutter();
    const root =
        'assets/character/ryza/crf_skn_002_0001_01/crf_skn_002_0001_01';
    final drawable = await SkeletonDrawable.fromFile(
      '$root.atlas',
      '$root.skel',
    );
    final frames = <ui.Image>[];
    try {
      drawable.animationState.setAnimationByName(0, 'motion_A_001_idle', true);
      drawable.animationState.setAnimationByName(
        11,
        'facial_eye_001_idle',
        true,
      );
      for (final name in [
        'facial_mouth_019_idle',
        'facial_mouth_013_scrub_01',
        'facial_mouth_002_scrub_01',
        'facial_mouth_017_scrub_01',
      ]) {
        final animation = drawable.skeletonData.findAnimation(name);
        if (animation == null) continue;
        final entry =
            drawable.animationState.setAnimationByName(13, name, false)
              ..setTimeScale(0)
              ..setTrackTime(animation.getDuration() * .65)
              ..setMixDuration(0);
        for (var i = 0; i < 40; i++) {
          drawable.update(1 / 60);
        }
        expect(entry.getAnimation().getName(), name);
        final head = drawable.skeleton.findBone('head')!;
        final crop = ui.Rect.fromCenter(
          center: ui.Offset(head.getWorldX(), head.getWorldY()),
          width: 450,
          height: 700,
        );
        frames.add(await _render(drawable, crop));
      }
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      for (var i = 0; i < frames.length; i++) {
        canvas.drawImage(frames[i], ui.Offset(i * 360, 0), ui.Paint());
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(frames.length * 360, 640);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await Directory('build/wake-audit').create(recursive: true);
      await File('build/wake-audit/mouths.png')
          .writeAsBytes(png.buffer.asUint8List());
      image.dispose();
      picture.dispose();
    } finally {
      for (final image in frames) {
        image.dispose();
      }
      drawable.dispose();
    }
  }, skip: !enabled || !render);
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
    final root = 'assets/character/ryza/crf_skn_002_$id/crf_skn_002_$id';
    test(
      'native wake sequence plays and clears for $id',
      () async {
        await initSpineFlutter();
        final drawable = await SkeletonDrawable.fromFile(
          '$root.atlas',
          '$root.skel',
        );
        final frames = <ui.Image>[];
        try {
          final standing = id.endsWith('99');
          final appearance = characterAppearances
              .firstWhere((skin) => skin.assetName == 'crf_skn_002_$id')
              .id;
          final state = drawable.animationState;
          state.setAnimationByName(0, 'motion_A_001_idle', true);
          final sleep = resolveStartupSleepFace(
            appearance,
            (name) => drawable.skeletonData.findAnimation(name) != null,
          );
          state.setAnimationByName(11, sleep.eye!, true);
          state.setAnimationByName(12, sleep.eyebrow!, true);
          state.setAnimationByName(13, sleep.mouth!, true);
          for (var frame = 0; frame < 30; frame++) {
            drawable.update(1 / 60);
          }
          final bounds = drawable.skeleton.getBounds();
          final crop = ui.Rect.fromLTWH(
            bounds.x,
            bounds.y,
            bounds.width,
            bounds.height,
          ).inflate(320);
          final wake = CharacterWakePerformance(
            state: state,
            data: drawable.skeletonData,
            appearanceId: appearance,
            pose: 'motion_A_001_idle',
          );
          expect(wake.closedEye, isNotNull);
          expect(wake.openEye, isNotNull);
          expect(wake.yawnMouth, isNotNull);
          expect(wake.tear, isNotNull);
          if (wake.touch == null) {
            debugPrint(
              'touch candidates $id: ${drawable.skeletonData.getAnimations().map((a) => a.getName()).where((n) => n.contains('touch')).toList()}',
            );
          }
          expect(wake.touch, isNotNull);
          if (!standing && id != '0007_01' && id != '0004_01') {
            expect(wake.stretch, isNotNull);
          }
          if (id == '0004_01') expect(wake.stretch, isNull);
          debugPrint(
            '$id touch=${wake.touch} stretch=${wake.stretch} mouth=${wake.yawnMouth} tear=${wake.tear}',
          );
          debugPrint(
            'durations touch=${drawable.skeletonData.findAnimation(wake.touch!)!.getDuration()} stretch=${wake.stretch == null ? 0 : drawable.skeletonData.findAnimation(wake.stretch!)!.getDuration()} mouth=${drawable.skeletonData.findAnimation(wake.yawnMouth!)!.getDuration()}',
          );
          final base = state.getCurrent(0)!.getAnimation().getName();
          final shoulder = drawable.skeleton.findBone('shoulder_L')!;
          final shoulderStart = ui.Offset(
            shoulder.getWorldX(),
            shoulder.getWorldY(),
          );
          var stretchMovement = 0.0;
          var peakTearAlpha = 0.0;
          var sawStretch = false;
          if (render && id == '0001_01') {
            frames.add(await _render(drawable, crop));
          }
          for (var frame = 0; frame < 348; frame++) {
            drawable.update(
              1 / 60,
              beforeApply: () => wake.advance(1 / 60),
              afterApply: () => wake.applyTearOpacity(drawable.skeleton),
            );
            if (wake.elapsed > 1.1 &&
                wake.elapsed < 4.5 &&
                wake.stretch != null) {
              expect(
                state.getCurrent(2)!.getAnimation().getName(),
                wake.stretch,
              );
              sawStretch = true;
              stretchMovement = math.max(
                stretchMovement,
                (ui.Offset(shoulder.getWorldX(), shoulder.getWorldY()) -
                        shoulderStart)
                    .distance,
              );
            }
            for (final slot in drawable.skeleton.getSlots()) {
              if (slot.getData().getName().toLowerCase().contains('tear') &&
                  slot.getAttachment() != null) {
                peakTearAlpha = math.max(peakTearAlpha, slot.getColor().a);
                expect(slot.getColor().a, inInclusiveRange(0, .381));
              }
            }
            expect(state.getCurrent(0)!.getAnimation().getName(), base);
            for (final bone in drawable.skeleton.getBones()) {
              expect(
                bone.getWorldX().isFinite && bone.getWorldY().isFinite,
                isTrue,
              );
            }
            if (render &&
                id == '0001_01' &&
                [29, 95, 173, 293].contains(frame)) {
              frames.add(await _render(drawable, crop));
            }
            if (frame == 173) {
              final elapsed = wake.elapsed;
              for (var i = 0; i < 60; i++) {
                wake.advance(0);
              }
              expect(
                wake.elapsed,
                elapsed,
                reason: 'Background frames cannot finish the wake sequence',
              );
              if (render && id == '0001_01') {
                final head = drawable.skeleton.findBone('head')!;
                final image = await _render(
                  drawable,
                  ui.Rect.fromCenter(
                    center: ui.Offset(head.getWorldX(), head.getWorldY()),
                    width: 500,
                    height: 800,
                  ),
                );
                final png = (await image.toByteData(
                  format: ui.ImageByteFormat.png,
                ))!;
                await Directory('build/wake-audit').create(recursive: true);
                await File('build/wake-audit/yawn-face.png')
                    .writeAsBytes(png.buffer.asUint8List());
                image.dispose();
              }
            }
          }
          wake.advance(.05);
          expect(wake.finished, isTrue);
          if (wake.stretch != null) {
            expect(sawStretch, isTrue);
            expect(
              stretchMovement,
              greaterThan(5),
              reason: 'Stretch must move the native shoulder, not just select a name',
            );
          }
          expect(peakTearAlpha, greaterThan(.1));
          wake.clear();
          wake.clear();
          final normal = characterExpressionPreset(
            appearance,
            CharacterExpression.neutral,
          );
          state.setAnimationByName(11, normal.eye, true).setMixDuration(.3);
          state.setAnimationByName(13, normal.mouth, true).setMixDuration(.3);
          for (var frame = 0; frame < 60; frame++) {
            drawable.update(1 / 60);
          }
          expect(state.getCurrent(11)!.getAnimation().getName(), normal.eye);
          expect(state.getCurrent(13)!.getAnimation().getName(), normal.mouth);
          expect(state.getCurrent(0)!.getAnimation().getName(), base);
          final cancelled = CharacterWakePerformance(
            state: state,
            data: drawable.skeletonData,
            appearanceId: appearance,
            pose: 'motion_A_001_idle',
          );
          for (var i = 0; i < 150; i++) {
            drawable.update(
              1 / 60,
              beforeApply: () => cancelled.advance(1 / 60),
              afterApply: () => cancelled.applyTearOpacity(drawable.skeleton),
            );
          }
          cancelled.clear();
          for (var i = 0; i < 60; i++) {
            drawable.update(1 / 60);
          }
          for (final slot in drawable.skeleton.getSlots()) {
            if (slot.getData().getName().toLowerCase().contains('tear')) {
              expect(
                slot.getAttachment() == null || slot.getColor().a == 0,
                isTrue,
                reason: 'Cancelling must remove yawn tears',
              );
            }
          }
          if (render && id == '0001_01') {
            frames.add(await _render(drawable, crop));
            final recorder = ui.PictureRecorder();
            final canvas = ui.Canvas(recorder);
            for (var i = 0; i < frames.length; i++) {
              canvas.drawImage(frames[i], ui.Offset(i * 360, 0), ui.Paint());
            }
            final picture = recorder.endRecording();
            final image = await picture.toImage(frames.length * 360, 640);
            final png = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            await Directory('build/wake-audit').create(recursive: true);
            await File('build/wake-audit/sequence.png')
                .writeAsBytes(png.buffer.asUint8List());
            image.dispose();
            picture.dispose();
          }
        } finally {
          for (final image in frames) {
            image.dispose();
          }
          drawable.dispose();
        }
      },
      skip: !enabled || !File('$root.skel').existsSync()
          ? 'Requires opt-in native Spine runtime and owned local assets.'
          : false,
    );
  }
}

Future<ui.Image> _render(SkeletonDrawable drawable, ui.Rect crop) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff38424a), ui.BlendMode.src);
  final scale = math.min(360 / crop.width, 640 / crop.height);
  canvas.translate(180, 320);
  canvas.scale(scale);
  canvas.translate(-crop.center.dx, -crop.center.dy);
  drawable.renderToCanvas(canvas);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(360, 640);
  } finally {
    picture.dispose();
  }
}
