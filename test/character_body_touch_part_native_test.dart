import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_body_touch_part.dart';
import 'package:ryza_chat_mvp/src/character_pelvis_region.dart';
import 'package:ryza_chat_mvp/src/character_touch_physics_rig.dart';
import 'package:spine_flutter/spine_flutter.dart';

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
    final root = 'assets/character/ryza/crf_skn_002_$id/crf_skn_002_$id';
    test(
      'authored $id has visible hands and legs independently of physics',
      () async {
        await initSpineFlutter();
        final drawable = await SkeletonDrawable.fromFile(
          '$root.atlas',
          '$root.skel',
        );
        final rig = CharacterTouchPhysicsRig();
        try {
          drawable.animationState.setAnimationByName(
            0,
            'motion_A_001_idle',
            true,
          );
          for (var i = 0; i < 30; i++) {
            drawable.update(1 / 60);
          }
          expect(rig.bodyPartHitTestReady, isFalse);
          await rig.prepare(drawable);
          expect(rig.bodyPartHitTestReady, isTrue);
          for (final part in ['hands', 'legs']) {
            final point = _findVisiblePart(drawable, rig, part);
            expect(
              point,
              isNotNull,
              reason: '$id must expose a real $part hit',
            );
            rig.begin(drawable.skeleton, point!);
            expect(rig.touchedBodyPart, part);
            expect(rig.touchedBodyPart, isNot('intimate'));
            rig.release();
            expect(
              rig.touchedBodyPart,
              part,
              reason: 'Tap can inspect the released contact',
            );
            rig.move(point, ui.Offset.zero);
            expect(rig.touchedBodyPart, part);
          }
          final bounds = drawable.skeleton.getBounds();
          final empty = ui.Offset(bounds.x - 10000, bounds.y - 10000);
          expect(rig.begin(drawable.skeleton, empty), isFalse);
          expect(rig.touchedBodyPart, isNull);
          rig.move(empty, const ui.Offset(1, 1));
          expect(rig.touchedBodyPart, isNull);
          rig.reset();
          expect(rig.touchedBodyPart, isNull);
          final pelvis = CharacterPelvisRegion.fromSkeleton(drawable.skeleton);
          expect(pelvis, isNotNull);
          final hits = <Map<String, Object?>>[];
          for (final x in [-.7, -.35, 0.0, .35, .7]) {
            for (final y in [-.7, -.35, 0.0, .35, .7]) {
              final point =
                  pelvis!.center +
                  pelvis.across * pelvis.halfWidth * x +
                  pelvis.down * pelvis.halfHeight * y;
              rig.begin(drawable.skeleton, point);
              hits.add({
                'x': point.dx,
                'y': point.dy,
                'part': rig.touchedBodyPart,
              });
              if (rig.touchedBodyPart == 'intimate') {
                expect(pelvis.contains(point), isTrue);
              }
            }
          }
          // Far lateral/below the region cannot become intimate just because
          // the broad authored waist box also covers the thighs.
          for (final point in [
            pelvis!.center + pelvis.across * pelvis.halfWidth * 2,
            pelvis.center - pelvis.across * pelvis.halfWidth * 2,
            pelvis.center + pelvis.down * pelvis.halfHeight * 3,
          ]) {
            rig.begin(drawable.skeleton, point);
            expect(rig.touchedBodyPart, isNot('intimate'));
          }
          if (const {'0001_01', '0001_99', '0004_01'}.contains(id)) {
            expect(
              hits.any((hit) => hit['part'] == 'intimate'),
              isTrue,
              reason:
                  'The exposed authored torso must retain a deliberate target',
            );
          }
          if (id == '0006_01') {
            expect(
              hits.every((hit) => hit['part'] == null),
              isTrue,
              reason:
                  'The opaque front skirt must not reveal hidden part identity',
            );
          }
          await Directory('build/status-audit').create(recursive: true);
          await File('build/status-audit/$id-intimate-hits.json')
              .writeAsString(const JsonEncoder.withIndent('  ').convert(hits));
        } finally {
          rig.reset(resetNative: false);
          drawable.dispose();
        }
      },
      skip: !enabled || !File('$root.skel').existsSync(),
    );
  }

  const atlasPath =
      'assets/character/ryza/crf_skn_002_0001_01/crf_skn_002_0001_01.atlas';
  test(
    'opaque unknown cover blocks body identity without requiring any spring',
    () async {
      await initSpineFlutter();
      final atlas = await Atlas.fromFile(atlasPath);
      Map<String, Object> quad(double x) => {
        'type': 'mesh',
        'path': 'face_01',
        'uvs': [.5, .5, .5, .5, .5, .5, .5, .5],
        'triangles': [0, 1, 2, 2, 3, 0],
        'vertices': [x - 45, -45, x - 45, 45, x + 45, 45, x + 45, -45],
        'hull': 4,
      };
      final data = SkeletonData.fromJson(
        atlas,
        jsonEncode({
          'skeleton': {'spine': '4.2.40'},
          'bones': [
            {'name': 'root'},
          ],
          'slots': [
            {'name': 'palm', 'bone': 'root', 'attachment': 'hand'},
            {'name': 'leg_l', 'bone': 'root', 'attachment': 'leg'},
            {'name': 'costume_sleeve', 'bone': 'root', 'attachment': 'cover'},
          ],
          'skins': [
            {
              'name': 'default',
              'attachments': {
                'palm': {'hand': quad(-120)},
                'leg_l': {'leg': quad(120)},
                'costume_sleeve': {'cover': quad(-120)},
              },
            },
          ],
          'animations': {'idle': {}},
        }),
      );
      final drawable = SkeletonDrawable(atlas, data, true);
      final rig = CharacterTouchPhysicsRig();
      try {
        drawable.update(1 / 60);
        final point = const ui.Offset(-120, 0);
        expect(rig.begin(drawable.skeleton, point), isFalse);
        expect(rig.touchedBodyPart, isNull, reason: 'Alpha mask is not ready');
        await rig.prepare(drawable);
        expect(drawable.skeleton.getPhysicsConstraints(), isEmpty);
        expect(rig.begin(drawable.skeleton, point), isFalse);
        expect(
          rig.touchedBodyPart,
          isNull,
          reason: 'Opaque clothing occludes the palm',
        );
        drawable.skeleton
            .findSlot('costume_sleeve')!
            .setColor(Color(1, 1, 1, 0));
        expect(rig.begin(drawable.skeleton, point), isFalse);
        expect(
          rig.touchedBodyPart,
          'hands',
          reason: 'Part identity needs no physics constraint',
        );
        rig.move(const ui.Offset(120, 0), ui.Offset.zero);
        expect(rig.touchedBodyPart, 'legs');
        rig.move(const ui.Offset(double.nan, 0), ui.Offset.zero);
        expect(rig.touchedBodyPart, isNull);
        rig.reset();
        expect(rig.touchedBodyPart, isNull);
      } finally {
        rig.reset(resetNative: false);
        drawable.dispose();
      }
    },
    skip: !enabled || !File(atlasPath).existsSync(),
  );

  test('intimate region only refines a confirmed visible torso hit', () async {
    await initSpineFlutter();
    final atlas = await Atlas.fromFile(atlasPath);
    Map<String, Object> quad() => {
      'type': 'mesh',
      'path': 'face_01',
      'uvs': [.5, .5, .5, .5, .5, .5, .5, .5],
      'triangles': [0, 1, 2, 2, 3, 0],
      'vertices': [-500, -500, -500, 500, 500, 500, 500, -500],
      'hull': 4,
    };
    final data = SkeletonData.fromJson(
      atlas,
      jsonEncode({
        'skeleton': {'spine': '4.2.40'},
        'bones': [
          {'name': 'root'},
          {'name': 'waist', 'parent': 'root'},
          {'name': 'body2', 'parent': 'root', 'y': -300},
          {'name': 'leg_L', 'parent': 'root', 'x': 200, 'y': 150},
          {'name': 'leg_R', 'parent': 'root', 'x': -200, 'y': 150},
        ],
        'slots': [
          {'name': 'body', 'bone': 'root', 'attachment': 'body'},
          {'name': 'costume_cover', 'bone': 'root', 'attachment': 'cover'},
        ],
        'skins': [
          {
            'name': 'default',
            'attachments': {
              'body': {'body': quad()},
              'costume_cover': {'cover': quad()},
            },
          },
        ],
        'animations': {'idle': {}},
      }),
    );
    final drawable = SkeletonDrawable(atlas, data, true);
    final rig = CharacterTouchPhysicsRig();
    try {
      drawable.update(1 / 60);
      await rig.prepare(drawable);
      final region = CharacterPelvisRegion.fromSkeleton(drawable.skeleton)!;
      expect(rig.begin(drawable.skeleton, region.center), isFalse);
      expect(
        rig.touchedBodyPart,
        isNull,
        reason: 'Opaque unknown cover blocks identity',
      );
      drawable.skeleton.findSlot('costume_cover')!.setColor(Color(1, 1, 1, 0));
      expect(rig.begin(drawable.skeleton, region.center), isFalse);
      expect(
        rig.touchedBodyPart,
        'intimate',
        reason: 'Part identity needs no spring',
      );
      for (final point in [
        region.center + region.down * region.halfHeight * 2,
        region.center + region.across * region.halfWidth * 2,
        region.center - region.down * region.halfHeight * 2,
      ]) {
        rig.begin(drawable.skeleton, point);
        expect(
          rig.touchedBodyPart,
          'body',
          reason: 'Adjacent torso points remain body',
        );
      }
      rig.begin(drawable.skeleton, const ui.Offset(2000, 2000));
      expect(rig.touchedBodyPart, isNull);
    } finally {
      rig.reset(resetNative: false);
      drawable.dispose();
    }
  }, skip: !enabled || !File(atlasPath).existsSync());
}

ui.Offset? _findVisiblePart(
  SkeletonDrawable drawable,
  CharacterTouchPhysicsRig rig,
  String part,
) {
  for (final slot in drawable.skeleton.getDrawOrder().reversed) {
    final attachment = slot.getAttachment();
    if (slot.getColor().a <= .01 || attachment is! MeshAttachment) continue;
    if (characterBodyTouchPart(
          slotName: slot.getData().getName(),
          boneName: slot.getBone().getData().getName(),
          attachmentPath: attachment.getPath(),
        ) !=
        part) {
      continue;
    }
    final vertices = attachment.computeWorldVertices(slot);
    final triangles = attachment.getTriangles();
    for (var t = 0; t + 2 < triangles.length; t += 3) {
      for (final weights in const [
        [1 / 3, 1 / 3, 1 / 3],
        [.6, .2, .2],
        [.2, .6, .2],
        [.2, .2, .6],
      ]) {
        var x = 0.0, y = 0.0;
        for (var i = 0; i < 3; i++) {
          x += vertices[triangles[t + i] * 2] * weights[i];
          y += vertices[triangles[t + i] * 2 + 1] * weights[i];
        }
        final point = ui.Offset(x, y);
        rig.begin(drawable.skeleton, point);
        if (rig.touchedBodyPart == part) return point;
      }
    }
  }
  return null;
}
