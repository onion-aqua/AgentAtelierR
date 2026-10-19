import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/update/resource_integrity.dart';
import 'package:ryza_chat_mvp/src/update/resource_models.dart';
import 'package:ryza_chat_mvp/src/update/resource_resolver.dart';
import 'package:ryza_chat_mvp/src/update/resource_store.dart';
import 'package:ryza_chat_mvp/src/update/update_manifest.dart';

const _newWallpaper = 'assets/images/virtual_phone/hot_only_wallpaper.png';
const _fixtureColor = Color(0xFF2389D3);

final class _ManifestOnlyBundle extends CachingAssetBundle {
  final List<String> requested = [];

  @override
  Future<ByteData> load(String key) async {
    requested.add(key);
    if (key == 'AssetManifest.bin') {
      return const StandardMessageCodec().encodeMessage(<String, Object>{})!;
    }
    throw FlutterError('This asset was not shipped in the APK: $key');
  }
}

Future<Uint8List> _tinyPng() async {
  final recorder = ui.PictureRecorder();
  Canvas(
    recorder,
  ).drawRect(const Rect.fromLTWH(0, 0, 6, 10), Paint()..color = _fixtureColor);
  final picture = recorder.endRecording();
  final image = await picture.toImage(6, 10);
  picture.dispose();
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return Uint8List.sublistView(data);
  } finally {
    image.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final decoration in [false, true]) {
    testWidgets(
      '${decoration ? 'DecorationImage' : 'Image.asset resize'} decodes a new hot wallpaper absent from APK AssetManifest',
      (tester) async {
        late Directory directory;
        late ResourceAssetResolver resolver;
        late Uint8List png;
        await tester.runAsync(() async {
          directory = await Directory.systemTemp.createTemp('aar_hot_image_');
          png = await _tinyPng();
          final store = ResourceSnapshotStore(
            rootDirectory: () async => directory,
          );
          await store.initialize();
          final hash = await resourceSha256Bytes(png);
          final object = ResourceObject(
            path: _newWallpaper,
            sha256: hash,
            size: png.length,
            urls: [Uri.parse('https://resources.example.test/$hash')],
          );
          final temporary = await store.createStagingFile(hash);
          await temporary.writeAsBytes(png, flush: true);
          await store.commitObject(temporary, object);
          final manifest = ResourceSnapshotManifest(
            schemaVersion: 1,
            snapshotId: 'wallpaper-hot-only-51',
            resourceApiVersion: 1,
            compatibleRuntimeIds: const {'android-bootstrap-v1'},
            assetKeyId: 'test-asset-key',
            objects: [object],
          );
          final bytes = Uint8List.fromList(
            utf8.encode(canonicalJsonEncode(manifest.toJson())),
          );
          final reference = await store.stageSnapshot(
            manifest: manifest,
            authenticatedBytes: bytes,
            manifestSha256: await resourceSha256Bytes(bytes),
            releaseSeq: 51,
          );
          await store.activate(reference);
          resolver = ResourceAssetResolver(store: store)
            ..setOverlayEnabled(true);
        });
        addTearDown(() async {
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
          await directory.delete(recursive: true);
        });

        final fallback = _ManifestOnlyBundle();
        final bundle = ResourceOverlayAssetBundle(
          resolver: resolver,
          fallback: fallback,
        );
        final apkManifest = await AssetManifest.loadFromAssetBundle(fallback);
        expect(apkManifest.getAssetVariants(_newWallpaper), isNull);
        final resolvedBytes = await tester.runAsync(
          () => resolver.loadBytes(_newWallpaper, fallback: fallback),
        );
        expect(resolvedBytes, orderedEquals(png));

        const repaintKey = ValueKey('hot-wallpaper-repaint');
        final errors = <Object>[];
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) =>
                DefaultAssetBundle(bundle: bundle, child: child!),
            home: Center(
              child: RepaintBoundary(
                key: repaintKey,
                child: SizedBox(
                  width: 60,
                  height: 100,
                  child: decoration
                      ? const DecoratedBox(
                          decoration: BoxDecoration(
                            image: DecorationImage(
                              image: AssetImage(_newWallpaper),
                              fit: BoxFit.cover,
                            ),
                          ),
                        )
                      : Image.asset(
                          _newWallpaper,
                          fit: BoxFit.cover,
                          cacheWidth: 6,
                          errorBuilder: (_, error, _) {
                            errors.add(error);
                            return const SizedBox();
                          },
                        ),
                ),
              ),
            ),
          ),
        );
        for (var attempt = 0; attempt < 50; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          final cache = PaintingBinding.instance.imageCache;
          if (cache.currentSize > 0 && cache.pendingImageCount == 0) break;
        }
        await tester.pump();
        expect(errors, isEmpty);
        expect(tester.takeException(), isNull);
        if (!decoration) {
          final painted = tester.widget<RawImage>(find.byType(RawImage));
          expect(painted.image?.width, 6);
          expect(painted.image?.height, 10);
        }

        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(repaintKey),
        );
        final rgba = await tester.runAsync(() async {
          final painted = await boundary.toImage(pixelRatio: 1);
          try {
            return (await painted.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
          } finally {
            painted.dispose();
          }
        });
        final center = (50 * 60 + 30) * 4;
        expect(
          Uint8List.sublistView(rgba!, center, center + 4),
          orderedEquals([0x23, 0x89, 0xD3, 0xFF]),
        );
        expect(fallback.requested, contains('AssetManifest.bin'));
        expect(fallback.requested, isNot(contains(_newWallpaper)));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
