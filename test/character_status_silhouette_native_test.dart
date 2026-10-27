import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/character_status_silhouette.dart';
import 'package:spine_flutter/spine_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final native = Platform.environment['AAR_SPINE_NATIVE_TEST'] == '1';
  const root = 'assets/character/ryza/crf_skn_002_0001_99/crf_skn_002_0001_99';
  tearDown(CharacterStatusSilhouettes.clearCache);

  test(
    'one in-flight silhouette is shared and released idempotently',
    () async {
      final result = await _tinyImage();
      final pending = Completer<CharacterStatusSilhouette>();
      var count = 0;
      Future<CharacterStatusSilhouette> load() {
        count++;
        return pending.future;
      }

      final first = CharacterStatusSilhouettes.loadCachedForTest(load);
      final second = CharacterStatusSilhouettes.loadCachedForTest(load);
      expect(identical(first, second), isTrue);
      pending.complete(result);
      expect(await first, same(result));
      expect(await second, same(result));
      expect(count, 1);
      expect(result.isDisposed, isFalse);
      CharacterStatusSilhouettes.clearCache();
      CharacterStatusSilhouettes.clearCache();
      expect(result.isDisposed, isTrue);
    },
  );

  test('cleared pending render disposes its late image', () async {
    final result = await _tinyImage();
    final pending = Completer<CharacterStatusSilhouette>();
    final stale = CharacterStatusSilhouettes.loadCachedForTest(
      () => pending.future,
    );
    final caught = expectLater(stale, throwsStateError);
    CharacterStatusSilhouettes.clearCache();
    pending.complete(result);
    await caught;
    expect(result.isDisposed, isTrue);
    final next = await _tinyImage();
    expect(
      await CharacterStatusSilhouettes.loadCachedForTest(() async => next),
      same(next),
    );
  });

  test('failed load is evicted so a later view can retry', () async {
    await expectLater(
      CharacterStatusSilhouettes.loadCachedForTest(
        () => throw StateError('missing owned resource'),
      ),
      throwsStateError,
    );
    final result = await _tinyImage();
    expect(
      await CharacterStatusSilhouettes.loadCachedForTest(() async => result),
      same(result),
    );
    expect(result.isDisposed, isFalse);
  });

  test(
    'full standing Ryza renders to transparent monochrome with aligned anchors',
    () async {
      await initSpineFlutter();
      final drawable = await SkeletonDrawable.fromFile(
        '$root.atlas',
        '$root.skel',
      );
      CharacterStatusSilhouette? result;
      try {
        result = await CharacterStatusSilhouettes.renderFromDrawable(drawable);
        expect(result.image.width, 512);
        expect(result.image.height, 1024);
        final anchors = result.normalizedAnchors;
        expect(
          anchors.keys,
          containsAll([
            'head',
            'body',
            'arm_l',
            'arm_r',
            'weast',
            'breast',
            'chest',
            'abdomen',
            'arm',
            'legs',
            'hands',
            'waist',
            'intimate',
          ]),
        );
        for (final point in anchors.values) {
          expect(point.dx, inInclusiveRange(0, 1));
          expect(point.dy, inInclusiveRange(0, 1));
        }
        expect(anchors['head']!.dy, lessThan(anchors['chest']!.dy));
        expect(anchors['chest']!.dy, lessThan(anchors['abdomen']!.dy));
        expect(anchors['abdomen']!.dy, lessThan(anchors['legs']!.dy));
        expect(anchors['waist']!.dy, greaterThan(anchors['abdomen']!.dy));
        expect(anchors['waist']!.dy, lessThan(anchors['legs']!.dy));
        expect(anchors['intimate']!.dy, greaterThan(anchors['waist']!.dy));
        expect(anchors['intimate']!.dy, lessThan(anchors['legs']!.dy));
        expect(anchors['hands']!.dx, lessThan(anchors['arm_r']!.dx));
        final rgba = (await result.image.toByteData())!.buffer.asUint8List();
        var pixels = 0;
        var coloredPixels = 0;
        var top = result.image.height;
        var bottom = -1;
        for (var i = 0; i < rgba.length; i += 4) {
          if (rgba[i + 3] <= 10) continue;
          pixels++;
          if (rgba[i] != rgba[i + 1] || rgba[i + 1] != rgba[i + 2]) {
            coloredPixels++;
          }
          final y = (i ~/ 4) ~/ result.image.width;
          if (y < top) top = y;
          if (y > bottom) bottom = y;
        }
        expect(pixels, greaterThan(30000));
        expect(coloredPixels, 0);
        expect(rgba[3], 0, reason: 'No opaque screenshot/background rectangle');
        expect(
          top,
          greaterThan(0),
          reason: 'Keep the hair and ear tips intact',
        );
        expect(
          bottom,
          lessThan(1023),
          reason: 'Keep both boots inside the frame',
        );
        expect(
          bottom - top,
          greaterThan(850),
          reason: 'This must be a full-body rig',
        );
        expect(
          drawable.animationState.getCurrent(0)!.getAnimation().getName(),
          'motion_A_001_idle',
          reason: 'The renderer must not dispose a borrowed drawable',
        );
        final png = (await result.image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!;
        await Directory('build/status-audit').create(recursive: true);
        await File('build/status-audit/ryza-silhouette.png')
            .writeAsBytes(png.buffer.asUint8List());
      } finally {
        result?.dispose();
        drawable.dispose();
      }
    },
    skip: !native || !File('$root.skel').existsSync(),
  );

  test('bundle renderer owns its independent native resources', () async {
    await initSpineFlutter();
    final result = await CharacterStatusSilhouettes.fromBundle(_OwnedBundle());
    try {
      expect(result.image.height, 1024);
      expect(result.normalizedAnchors['head']!.dy, lessThan(.3));
      expect(result.isDisposed, isFalse);
    } finally {
      result.dispose();
    }
  }, skip: !native || !File('$root.skel').existsSync());
}

class _OwnedBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(await File(key).readAsBytes());
}

Future<CharacterStatusSilhouette> _tinyImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xFFFFFFFF), ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return CharacterStatusSilhouette(
      image: await picture.toImage(2, 2),
      normalizedAnchors: const {'head': ui.Offset(.5, .2)},
    );
  } finally {
    picture.dispose();
  }
}
