import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/character_startup_sleep.dart';
import 'package:ryza_chat_mvp/src/character_wake_performance.dart';
import 'package:ryza_chat_mvp/src/character_wake_variants.dart';
import 'package:spine_flutter/spine_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled = Platform.environment['AAR_SPINE_NATIVE_TEST'] == '1';
  final render = Platform.environment['AAR_WAKE_RENDER'] == '1';
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
      'native skin wake variants, contact and pose audit $id',
      () async {
        await initSpineFlutter();
        final drawable = await SkeletonDrawable.fromFile(
          '$root.atlas',
          '$root.skel',
        );
        final frames = <ui.Image>[];
        final contactFrames = <ui.Image>[];
        final report = <String, Object?>{'skin': id, 'variants': <Object?>[]};
        final skin = characterAppearances.firstWhere(
          (skin) => skin.assetName == 'crf_skn_002_$id',
        );
        final appearance = skin.id;
        final state = drawable.animationState;
        bool has(String name) =>
            drawable.skeletonData.findAnimation(name) != null;
        for (final idle in skin.idleAnimations) {
          expect(
            has(idle),
            isTrue,
            reason:
                '${skin.id} must not advertise an idle clip absent from this rig',
          );
        }
        report['appearance_id'] = appearance;
        report['idle_animations'] = skin.idleAnimations;
        void reset() {
          state.clearTracks();
          drawable.skeleton.setToSetupPose();
          state.setAnimationByName(0, 'motion_A_001_idle', true);
          final face = resolveStartupSleepFace(appearance, has);
          expect(face.eye, isNotNull);
          expect(face.mouth, isNotNull);
          state.setAnimationByName(11, face.eye!, true);
          state.setAnimationByName(12, face.eyebrow!, true);
          state.setAnimationByName(13, face.mouth!, true);
          for (var i = 0; i < 30; i++) {
            drawable.update(1 / 60);
          }
        }

        try {
          reset();
          final bounds = drawable.skeleton.getBounds();
          final crop = ui.Rect.fromLTWH(
            bounds.x,
            bounds.y,
            bounds.width,
            bounds.height,
          ).inflate(400);
          final chosen = <String>{};
          for (var variant = 0; variant < 3; variant++) {
            reset();
            final wake = CharacterWakePerformance(
              state: state,
              data: drawable.skeletonData,
              appearanceId: appearance,
              pose: 'motion_A_001_idle',
              variant: variant,
            );
            if (wake.stretch != null) chosen.add(wake.stretch!);
            (report['variants'] as List).add({
              'variant': variant,
              'touch': wake.touch,
              'stretch': wake.stretch,
              'mouth': wake.yawnMouth,
              'tear': wake.tear,
            });
            if (render) frames.add(await _render(drawable, crop));
            for (var frame = 0; frame < 360; frame++) {
              drawable.update(
                1 / 60,
                beforeApply: () => wake.advance(1 / 60),
                afterApply: () => wake.applyTearOpacity(drawable.skeleton),
              );
              expect(
                state.getCurrent(0)!.getAnimation().getName(),
                'motion_A_001_idle',
              );
              for (final bone in drawable.skeleton.getBones()) {
                expect(
                  bone.getWorldX().isFinite && bone.getWorldY().isFinite,
                  isTrue,
                );
              }
              if (render && [29, 95, 173, 293].contains(frame)) {
                frames.add(await _render(drawable, crop));
              }
            }
            expect(wake.finished, isTrue);
            wake.clear();
            for (var i = 0; i < 60; i++) {
              drawable.update(1 / 60);
            }
            for (final slot in drawable.skeleton.getSlots()) {
              if (slot.getData().getName().toLowerCase().contains('tear')) {
                expect(
                  slot.getAttachment() == null || slot.getColor().a == 0,
                  isTrue,
                );
              }
            }
            if (render) frames.add(await _render(drawable, crop));
          }
          if (appearance != 'standing_99' &&
              id != '0007_01' &&
              id != '0004_01') {
            expect(
              chosen.length,
              3,
              reason: 'All three B12 variants must really exist',
            );
          } else {
            expect(chosen, isEmpty);
          }
          final contacts = <String>[];
          for (var part = 1; part <= 7; part++) {
            reset();
            final name =
                'motion_touch_A_${part.toString().padLeft(3, '0')}_active';
            final wake = CharacterWakePerformance(
              state: state,
              data: drawable.skeletonData,
              appearanceId: appearance,
              pose: 'motion_A_001_idle',
              touchAnimation: name,
            );
            expect(
              wake.touch,
              name,
              reason: 'Body-part touch must belong to this skin',
            );
            contacts.add(wake.touch!);
            for (var i = 0; i < 33; i++) {
              drawable.update(1 / 60, beforeApply: () => wake.advance(1 / 60));
            }
            if (render) contactFrames.add(await _render(drawable, crop));
            wake.clear();
          }
          report['contacts'] = contacts;
          for (final pose in [
            'motion_A_003_idle',
            'motion_A_004_idle',
            'motion_A_026_idle',
          ]) {
            expect(
              CharacterWakeMotions.resolve(
                appearanceId: appearance,
                pose: pose,
                hasAnimation: has,
              ).stretch,
              isNull,
            );
          }
          final crossLegged = CharacterWakePerformance(
            state: state,
            data: drawable.skeletonData,
            appearanceId: appearance,
            pose: 'motion_A_001_idle',
            sittingId: 'sitting_agura',
          );
          expect(crossLegged.stretch, isNull);
          crossLegged.clear();
          await Directory('build/wake-audit').create(recursive: true);
          await File(
            'build/wake-audit/$id-audit.json',
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
          if (render) {
            await _sheet(frames, 6, 'build/wake-audit/$id-variants.png');
            await _sheet(contactFrames, 7, 'build/wake-audit/$id-contacts.png');
          }
        } finally {
          for (final image in [...frames, ...contactFrames]) {
            image.dispose();
          }
          drawable.dispose();
        }
      },
      skip: !enabled || !File('$root.skel').existsSync()
          ? 'Requires opt-in native runtime and owned local skins.'
          : false,
    );
  }
}

Future<ui.Image> _render(SkeletonDrawable drawable, ui.Rect crop) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)
    ..drawColor(const ui.Color(0xff38424a), ui.BlendMode.src);
  final scale = math.min(300 / crop.width, 500 / crop.height);
  canvas.translate(150, 250);
  canvas.scale(scale);
  canvas.translate(-crop.center.dx, -crop.center.dy);
  drawable.renderToCanvas(canvas);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(300, 500);
  } finally {
    picture.dispose();
  }
}

Future<void> _sheet(List<ui.Image> frames, int columns, String path) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  for (var i = 0; i < frames.length; i++) {
    canvas.drawImage(
      frames[i],
      ui.Offset((i % columns) * 300, (i ~/ columns) * 500),
      ui.Paint(),
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    columns * 300,
    ((frames.length + columns - 1) ~/ columns) * 500,
  );
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await File(path).writeAsBytes(data.buffer.asUint8List());
  } finally {
    image.dispose();
    picture.dispose();
  }
}
