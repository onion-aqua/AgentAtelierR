import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/protected_asset_format.dart';
import 'package:ryza_chat_mvp/src/protected_asset_runtime_cache.dart';
import 'package:ryza_chat_mvp/src/update/protected_resource_health.dart';
import 'package:ryza_chat_mvp/src/update/resource_integrity.dart';
import 'package:ryza_chat_mvp/src/update/resource_models.dart';
import 'package:ryza_chat_mvp/src/update/resource_resolver.dart';
import 'package:ryza_chat_mvp/src/update/resource_store.dart';
import 'package:ryza_chat_mvp/src/update/resource_update_manager.dart';
import 'package:ryza_chat_mvp/src/update/update_manifest.dart';

Future<void> _validatePack(
  Uint8List encrypted,
  Uint8List key,
  String packId,
) async {
  final files = await decryptProtectedAssetFiles(
    encrypted: encrypted,
    key: key,
    packId: packId,
  );
  for (final entry in files.entries) {
    if (entry.key.endsWith('.json')) jsonDecode(utf8.decode(entry.value));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final key = Uint8List.fromList(List.generate(32, (index) => index + 1));
  late Directory root;
  late ResourceSnapshotStore store;
  late Directory cacheRoot;
  late ProtectedAssetRuntimeCache cache;

  Future<ResourceObject> writeObject(String path, Uint8List bytes) async {
    final digest = await resourceSha256Bytes(bytes);
    final file = await store.objectFile(digest);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return ResourceObject(
      path: path,
      sha256: digest,
      size: bytes.length,
      urls: [Uri.parse('https://resources.example.test/$digest')],
    );
  }

  Future<ResourceObject> writePack(
    String json, {
    String packId = 'character/test',
    String path = 'assets/protected/character/test.aarpack',
  }) async => writeObject(
    path,
    await encryptProtectedAssetFiles(
      files: {
        'assets/character/test/test_gesture.json': Uint8List.fromList(
          utf8.encode(json),
        ),
      },
      key: key,
      packId: packId,
    ),
  );

  ResourceSnapshotManifest manifest(
    List<ResourceObject> objects, {
    String id = 'snapshot-1',
    Set<String> runtimes = const {'runtime-1'},
  }) => ResourceSnapshotManifest(
    schemaVersion: 1,
    snapshotId: id,
    resourceApiVersion: 1,
    compatibleRuntimeIds: runtimes,
    assetKeyId: 'asset-key-1',
    objects: objects,
  );

  Future<ResourceSnapshotReference> activate(
    ResourceSnapshotManifest value,
    int sequence,
  ) async {
    final bytes = Uint8List.fromList(
      utf8.encode(canonicalJsonEncode(value.toJson())),
    );
    final reference = await store.stageSnapshot(
      manifest: value,
      authenticatedBytes: bytes,
      manifestSha256: await resourceSha256Bytes(bytes),
      releaseSeq: sequence,
    );
    await store.activate(reference);
    return reference;
  }

  ResourceUpdateManager manager(ProductionResourceHealthValidator validator) =>
      ResourceUpdateManager(
        compatibility: ResourceRuntimeCompatibility(
          runtimeId: 'runtime-1',
          resourceApiVersion: 1,
          assetKeyIds: {'asset-key-1'},
        ),
        resolver: ResourceAssetResolver(store: store),
        healthValidator: validator.call,
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('aar_protected_health_');
    store = ResourceSnapshotStore(
      rootDirectory: () async => Directory('${root.path}/objects-store'),
    );
    cacheRoot = Directory('${root.path}/decrypted-cache');
    cache = ProtectedAssetRuntimeCache(rootDirectory: () async => cacheRoot);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('successful content stamps persist and separate changed objects', () async {
    var validations = 0;
    Future<void> validate(Uint8List bytes, Uint8List key, String packId) async {
      validations++;
      await _validatePack(bytes, key, packId);
    }

    ProductionResourceHealthValidator createValidator() =>
        ProductionResourceHealthValidator(
          encodedKey: base64Encode(key),
          cache: ProtectedAssetRuntimeCache(
            rootDirectory: () async => cacheRoot,
          ),
          validatePack: validate,
        );

    final first = manifest([await writePack('{"revision":1}')]);
    await store.verifySnapshotObjects(first);
    await createValidator().call(first, store);
    await createValidator().call(first, store);
    expect(validations, 1);

    final changed = manifest([await writePack('{"revision":2}')]);
    await store.verifySnapshotObjects(changed);
    await createValidator().call(changed, store);
    expect(validations, 2);
    // Obsolete revisions may be pruned. A rollback must validate the old bytes
    // again rather than using the newer object's successful stamp.
    await createValidator().call(first, store);
    expect(validations, 3);
  });

  test('changed key cannot reuse an old successful content stamp', () async {
    final value = manifest([await writePack('{}')]);
    await store.verifySnapshotObjects(value);
    await ProductionResourceHealthValidator(
      encodedKey: base64Encode(key),
      cache: cache,
    ).call(value, store);

    var validations = 0;
    final otherKey = Uint8List.fromList(key.reversed.toList());
    final changedKeyValidator = ProductionResourceHealthValidator(
      encodedKey: base64Encode(otherKey),
      cache: cache,
      validatePack: (bytes, key, packId) async {
        validations++;
        await _validatePack(bytes, key, packId);
      },
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(
        changedKeyValidator.call(value, store),
        throwsA(isA<ProtectedAssetException>()),
      );
    }
    expect(validations, 2);
  });

  test('invalid JSON never leaves a successful validation stamp', () async {
    final value = manifest([await writePack('{broken-json')]);
    await store.verifySnapshotObjects(value);
    var validations = 0;
    for (var attempt = 0; attempt < 2; attempt++) {
      final validator = ProductionResourceHealthValidator(
        encodedKey: base64Encode(key),
        cache: ProtectedAssetRuntimeCache(rootDirectory: () async => cacheRoot),
        validatePack: (bytes, key, packId) async {
          validations++;
          await _validatePack(bytes, key, packId);
        },
      );
      await expectLater(
        validator.call(value, store),
        throwsA(isA<FormatException>()),
      );
    }
    expect(validations, 2);
  });

  test(
    'default background validator checks JSON inside encrypted packs',
    () async {
      final validator = ProductionResourceHealthValidator(
        encodedKey: base64Encode(key),
        cache: cache,
      );
      final good = manifest([await writePack('{"valid":true}')]);
      await store.verifySnapshotObjects(good);
      await validator.call(good, store);
      final bad = manifest([await writePack('{broken')]);
      await store.verifySnapshotObjects(bad);
      await expectLater(
        validator.call(bad, store),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('preview packs retain their distinct authenticated pack identity', () async {
    final preview = manifest([
      await writePack(
        '{}',
        packId: 'preview/test',
        path: 'assets/protected/character/previews/test.aarpreview',
      ),
    ]);
    await store.verifySnapshotObjects(preview);
    final validator = ProductionResourceHealthValidator(
      encodedKey: base64Encode(key),
      cache: cache,
    );
    await validator.call(preview, store);
    // Identical bytes advertised under character/test must authenticate again.
    final bytes = await (await store.objectFile(preview.objects.single.sha256))
        .readAsBytes();
    final differentIdentity = manifest([
      await writeObject('assets/protected/character/test.aarpack', bytes),
    ]);
    await expectLater(
      validator.call(differentIdentity, store),
      throwsA(isA<ProtectedAssetException>()),
    );
  });

  test('ordinary JSON validation works without a character key', () async {
    final validator = ProductionResourceHealthValidator(
      encodedKey: '',
      cache: cache,
    );
    final good = manifest([
      await writeObject(
        'assets/data/config.json',
        Uint8List.fromList(utf8.encode('{}')),
      ),
    ]);
    await store.verifySnapshotObjects(good);
    await validator.call(good, store);
    final bad = manifest([
      await writeObject('assets/data/config.json', Uint8List.fromList([0xff])),
    ]);
    await store.verifySnapshotObjects(bad);
    await expectLater(
      validator.call(bad, store),
      throwsA(isA<FormatException>()),
    );
    final pack = manifest([await writePack('{}')]);
    await expectLater(
      validator.call(pack, store),
      throwsA(
        isA<ResourceUpdateException>().having(
          (error) => error.code,
          'code',
          'resource_asset_key_unavailable',
        ),
      ),
    );
  });

  test(
    'warm content stamp does not bypass actual object hash verification',
    () async {
      final value = manifest([await writePack('{}')]);
      final validator = ProductionResourceHealthValidator(
        encodedKey: base64Encode(key),
        cache: cache,
      );
      await store.verifySnapshotObjects(value);
      await validator.call(value, store);
      await activate(value, 1);
      final objectFile = await store.objectFile(value.objects.single.sha256);
      final bytes = await objectFile.readAsBytes();
      bytes[bytes.length - 1] ^=
          1; // Preserve size; the SHA-256 check must fail.
      await objectFile.writeAsBytes(bytes, flush: true);
      final updates = manager(validator);
      addTearDown(updates.dispose);
      await updates.initialize();
      expect(store.activeReference, isNull);
      expect(updates.state.phase, ResourceUpdatePhase.rolledBack);
    },
  );

  test(
    'warm content stamp does not bypass runtime compatibility checks',
    () async {
      final value = manifest(
        [await writePack('{}')],
        runtimes: {'future-runtime'},
      );
      final validator = ProductionResourceHealthValidator(
        encodedKey: base64Encode(key),
        cache: cache,
      );
      await store.verifySnapshotObjects(value);
      await validator.call(value, store);
      await activate(value, 1);
      final updates = manager(validator);
      addTearDown(updates.dispose);
      await updates.initialize();
      expect(store.activeReference, isNull);
      expect(updates.state.phase, ResourceUpdatePhase.rolledBack);
    },
  );

  test(
    'invalid active content rolls back to the previous healthy snapshot',
    () async {
      final good = manifest([await writePack('{"valid":true}')], id: 'good');
      final previous = await activate(good, 1);
      final broken = manifest([await writePack('{broken')], id: 'broken');
      await activate(broken, 2);
      final validator = ProductionResourceHealthValidator(
        encodedKey: base64Encode(key),
        cache: cache,
      );
      final updates = manager(validator);
      addTearDown(updates.dispose);
      await updates.initialize();
      expect(store.activeReference, previous);
      expect(updates.state.phase, ResourceUpdatePhase.rolledBack);
      // The failed candidate does not become healthy on a later startup.
      await expectLater(
        validator.call(broken, store),
        throwsA(isA<FormatException>()),
      );
    },
  );
}
