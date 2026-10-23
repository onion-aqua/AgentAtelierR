import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/protected_asset_format.dart';
import 'package:ryza_chat_mvp/src/protected_asset_runtime_cache.dart';
import 'package:ryza_chat_mvp/src/protected_asset_runtime_loader.dart';
import 'package:ryza_chat_mvp/src/update/resource_integrity.dart';
import 'package:ryza_chat_mvp/src/update/resource_models.dart';
import 'package:ryza_chat_mvp/src/update/resource_resolver.dart';
import 'package:ryza_chat_mvp/src/update/resource_store.dart';
import 'package:ryza_chat_mvp/src/update/update_manifest.dart';

class _Bundle extends CachingAssetBundle {
  final data = <String, Uint8List>{};
  final reads = <String, int>{};

  @override
  Future<ByteData> load(String key) async {
    reads.update(key, (n) => n + 1, ifAbsent: () => 1);
    final bytes = data[key];
    if (bytes == null) throw FlutterError('Missing test asset: $key');
    return ByteData.sublistView(bytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  late Directory root;
  late _Bundle bundle;
  late ResourceAssetResolver resolver;
  late ResourceSnapshotStore store;
  final key = Uint8List.fromList(List.filled(32, 7));
  const path = 'assets/protected/character/example.aarpack';
  const packId = 'character/example';
  const asset = 'assets/character/example/example.skel';

  Future<Uint8List> pack(int value, {Uint8List? withKey}) =>
      encryptProtectedAssetFiles(
        files: {
          asset: Uint8List.fromList([value, 2, 3]),
        },
        key: withKey ?? key,
        packId: packId,
      );

  Future<void> setBundled(Uint8List bytes, {bool index = true}) async {
    bundle.data[path] = bytes;
    if (index) {
      bundle.data[protectedAssetIndexPath] = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'schema_version': 1,
            'objects': {
              path: {
                'sha256': await resourceSha256Bytes(bytes),
                'size': bytes.length,
              },
            },
          }),
        ),
      );
      bundle.evict(protectedAssetIndexPath);
    }
  }

  ProtectedAssetRuntimeLoader loader() => ProtectedAssetRuntimeLoader(
    bundledAssets: bundle,
    resolver: resolver,
    cache: ProtectedAssetRuntimeCache(rootDirectory: () async => root),
  );

  Future<Map<String, Uint8List>> load(
    ProtectedAssetRuntimeLoader instance, {
    Uint8List? withKey,
  }) => instance.load(path: path, packId: packId, key: withKey ?? key);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('aar-loader-');
    bundle = _Bundle();
    store = ResourceSnapshotStore(
      rootDirectory: () async => Directory('${root.path}/hot'),
    );
    resolver = ResourceAssetResolver(store: store);
    await resolver.initialize();
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'a later process uses private files without reopening the APK pack',
    () async {
      await setBundled(await pack(1));
      expect((await load(loader()))[asset], [1, 2, 3]);
      expect(bundle.reads[path], 1);
      final cached = await load(loader());
      expect(cached[asset], [1, 2, 3]);
      expect(bundle.reads[path], 1);
      expect(cached[asset]!.offsetInBytes, 0);
      expect(cached[asset]!.buffer.lengthInBytes, 3);
    },
  );

  test('old APK without an index still reuses decoded files', () async {
    await setBundled(await pack(1), index: false);
    expect((await load(loader()))[asset], [1, 2, 3]);
    expect((await load(loader()))[asset], [1, 2, 3]);
    expect(bundle.reads[path], 2); // Old packages need ciphertext identity.
  });

  test(
    'a new pack and rotated key cannot reuse earlier decoded bytes',
    () async {
      await setBundled(await pack(1));
      await load(loader());
      await setBundled(await pack(9));
      expect((await load(loader()))[asset], [9, 2, 3]);
      final rotated = Uint8List.fromList(List.filled(32, 8));
      await expectLater(
        load(loader(), withKey: rotated),
        throwsA(isA<ProtectedAssetException>()),
      );
      await setBundled(await pack(4, withKey: rotated));
      expect((await load(loader(), withKey: rotated))[asset], [4, 2, 3]);
    },
  );

  test('the APK index is checked before writing decoded data', () async {
    await setBundled(await pack(1));
    bundle.data[path] = await pack(2);
    await expectLater(load(loader()), throwsA(isA<ProtectedAssetException>()));
  });

  test(
    'an authenticated hot pack takes priority and corrupt data falls back',
    () async {
      await setBundled(await pack(1));
      await load(loader());
      final hotBytes = await pack(8);
      final hash = await resourceSha256Bytes(hotBytes);
      final hot = await store.objectFile(hash);
      await hot.parent.create(recursive: true);
      await hot.writeAsBytes(hotBytes);
      final manifest = ResourceSnapshotManifest(
        schemaVersion: 1,
        snapshotId: 'hot-1',
        resourceApiVersion: 1,
        compatibleRuntimeIds: {'runtime-1'},
        assetKeyId: 'key-1',
        objects: [
          ResourceObject(
            path: path,
            sha256: hash,
            size: hotBytes.length,
            urls: [Uri.parse('https://example.test/$hash')],
          ),
        ],
      );
      final manifestBytes = Uint8List.fromList(
        utf8.encode(canonicalJsonEncode(manifest.toJson())),
      );
      final reference = await store.stageSnapshot(
        manifest: manifest,
        authenticatedBytes: manifestBytes,
        manifestSha256: await resourceSha256Bytes(manifestBytes),
        releaseSeq: 1,
      );
      await store.activate(reference);
      resolver.setOverlayEnabled(true);
      expect((await load(loader()))[asset], [8, 2, 3]);
      expect((await load(loader()))[asset], [8, 2, 3]);
      await hot.writeAsBytes(Uint8List(hotBytes.length));
      expect((await load(loader()))[asset], [1, 2, 3]);
      resolver.setOverlayEnabled(false);
      expect((await load(loader()))[asset], [1, 2, 3]);
    },
  );
}
