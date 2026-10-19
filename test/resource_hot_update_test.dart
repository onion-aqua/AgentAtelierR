import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ryza_chat_mvp/src/update/resource_downloader.dart';
import 'package:ryza_chat_mvp/src/update/resource_integrity.dart';
import 'package:ryza_chat_mvp/src/update/resource_models.dart';
import 'package:ryza_chat_mvp/src/update/resource_resolver.dart';
import 'package:ryza_chat_mvp/src/update/resource_store.dart';
import 'package:ryza_chat_mvp/src/update/resource_update_manager.dart';
import 'package:ryza_chat_mvp/src/update/update_manifest.dart';
import 'package:ryza_chat_mvp/src/update/update_models.dart';

final class _TransportPayload {
  const _TransportPayload(this.bytes);

  final Uint8List bytes;
}

final class _FakeTransport implements ResourceDownloadTransport {
  final Map<String, _TransportPayload> payloads = {};
  final Map<String, int> calls = {};
  bool closed = false;

  @override
  Future<ResourceDownloadResponse> get(Uri uri) async {
    calls.update(uri.toString(), (value) => value + 1, ifAbsent: () => 1);
    final payload = payloads[uri.toString()];
    if (payload == null) {
      return const ResourceDownloadResponse(
        statusCode: HttpStatus.notFound,
        body: Stream.empty(),
      );
    }
    return ResourceDownloadResponse(
      statusCode: HttpStatus.ok,
      body: Stream.value(payload.bytes),
      contentLength: payload.bytes.length,
    );
  }

  @override
  void cancelActive() {}

  @override
  void close() => closed = true;
}

final class _BlockingTransport implements ResourceDownloadTransport {
  final StreamController<List<int>> controller = StreamController<List<int>>();
  final Completer<void> started = Completer<void>();

  @override
  Future<ResourceDownloadResponse> get(Uri uri) async {
    if (!started.isCompleted) started.complete();
    return ResourceDownloadResponse(
      statusCode: HttpStatus.ok,
      body: controller.stream,
    );
  }

  @override
  void cancelActive() {
    if (!controller.isClosed) {
      controller.addError(const FileSystemException('cancelled'));
      unawaited(controller.close());
    }
  }

  @override
  void close() => cancelActive();
}

final class _BlockOneTransport implements ResourceDownloadTransport {
  _BlockOneTransport(this.payloads, this.blockedUrl);

  final Map<String, _TransportPayload> payloads;
  final String blockedUrl;
  final StreamController<List<int>> controller = StreamController<List<int>>();
  final Completer<void> blocked = Completer<void>();

  @override
  Future<ResourceDownloadResponse> get(Uri uri) async {
    if (uri.toString() == blockedUrl) {
      if (!blocked.isCompleted) blocked.complete();
      return ResourceDownloadResponse(
        statusCode: HttpStatus.ok,
        body: controller.stream,
      );
    }
    final payload = payloads[uri.toString()]!;
    return ResourceDownloadResponse(
      statusCode: HttpStatus.ok,
      body: Stream.value(payload.bytes),
      contentLength: payload.bytes.length,
    );
  }

  @override
  void cancelActive() {
    if (!controller.isClosed) {
      controller.addError(const FileSystemException('cancelled'));
      unawaited(controller.close());
    }
  }

  @override
  void close() => cancelActive();
}

final class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return handler(request);
  }
}

final class _MemoryAssetBundle extends CachingAssetBundle {
  _MemoryAssetBundle(Map<String, String> values)
    : _values = {
        for (final entry in values.entries)
          entry.key: Uint8List.fromList(utf8.encode(entry.value)),
      };

  final Map<String, Uint8List> _values;

  @override
  Future<ByteData> load(String key) async {
    final bytes = _values[key];
    if (bytes == null) throw FlutterError('Missing bundled test asset: $key');
    return ByteData.sublistView(bytes);
  }
}

final class _PublishedSnapshot {
  const _PublishedSnapshot(this.snapshot, this.objectHashes);

  final ResourceSnapshot snapshot;
  final Map<String, String> objectHashes;
}

Future<_PublishedSnapshot> _publishSnapshot(
  _FakeTransport transport, {
  required String id,
  required Map<String, String> objects,
  Set<String> runtimeIds = const {'runtime-1'},
  String assetKeyId = 'asset-key-1',
  int resourceApiVersion = 1,
  Map<String, String> servedOverrides = const {},
}) async {
  final records = <Map<String, Object>>[];
  final hashes = <String, String>{};
  var index = 0;
  for (final entry in objects.entries) {
    final expected = Uint8List.fromList(utf8.encode(entry.value));
    final hash = await resourceSha256Bytes(expected);
    final url = Uri.parse(
      'https://resources.example.test/$id/object-${index++}',
    );
    final served = Uint8List.fromList(
      utf8.encode(servedOverrides[entry.key] ?? entry.value),
    );
    transport.payloads[url.toString()] = _TransportPayload(served);
    hashes[entry.key] = hash;
    records.add({
      'path': entry.key,
      'sha256': hash,
      'size': expected.length,
      'urls': [url.toString()],
    });
  }
  final manifestJson = <String, Object>{
    'asset_key_id': assetKeyId,
    'canonicalization': resourceSnapshotCanonicalization,
    'compatible_runtime_ids': runtimeIds.toList()..sort(),
    'objects': records,
    'resource_api_version': resourceApiVersion,
    'schema_version': resourceSnapshotManifestSchemaVersion,
    'snapshot_id': id,
  };
  final manifestBytes = Uint8List.fromList(
    utf8.encode(canonicalJsonEncode(manifestJson)),
  );
  final manifestHash = await resourceSha256Bytes(manifestBytes);
  final manifestUrl = Uri.parse(
    'https://resources.example.test/$id/manifest.json',
  );
  transport.payloads[manifestUrl.toString()] = _TransportPayload(manifestBytes);
  return _PublishedSnapshot(
    ResourceSnapshot(
      id: id,
      schemaVersion: resourceSnapshotManifestSchemaVersion,
      compatibleRuntimeIds: runtimeIds,
      assetKeyId: assetKeyId,
      manifestSha256: manifestHash,
      manifestUrl: manifestUrl,
      size: manifestBytes.length,
    ),
    hashes,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _FakeTransport transport;
  late ResourceSnapshotStore store;
  late ResourceAssetResolver resolver;
  late ResourceUpdateManager manager;

  ResourceUpdateManager createManager({
    String runtimeId = 'runtime-1',
    int resourceApiVersion = 1,
    Set<String> assetKeyIds = const {'asset-key-1'},
    ResourceSnapshotHealthValidator? healthValidator,
  }) => ResourceUpdateManager(
    compatibility: ResourceRuntimeCompatibility(
      runtimeId: runtimeId,
      resourceApiVersion: resourceApiVersion,
      assetKeyIds: assetKeyIds,
    ),
    resolver: resolver,
    downloader: ResourceObjectDownloader(transport: transport),
    healthValidator: healthValidator,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('aar_resource_update_');
    transport = _FakeTransport();
    store = ResourceSnapshotStore(rootDirectory: () async => root);
    resolver = ResourceAssetResolver(store: store);
    manager = createManager();
    await manager.initialize();
  });

  tearDown(() async {
    manager.dispose();
    transport.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'complete snapshots apply additions, changes, reuse, and deletions',
    () async {
      final first = await _publishSnapshot(
        transport,
        id: 'snapshot-v1',
        objects: const {
          'assets/a.txt': 'hot-a-v1',
          'assets/b.txt': 'hot-b-v1',
          'assets/keep.txt': 'unchanged',
        },
      );
      await manager.applyVerifiedSnapshot(
        snapshot: first.snapshot,
        expectedResourceApiVersion: 1,
        releaseSeq: 1,
      );

      final second = await _publishSnapshot(
        transport,
        id: 'snapshot-v2',
        objects: const {
          'assets/b.txt': 'hot-b-v2',
          'assets/c.txt': 'hot-c-v2',
          'assets/keep.txt': 'unchanged',
        },
      );
      final prepared = await manager.applyVerifiedSnapshot(
        snapshot: second.snapshot,
        expectedResourceApiVersion: 1,
        releaseSeq: 2,
      );
      final bundled = _MemoryAssetBundle(const {
        'assets/a.txt': 'bundled-a',
        'assets/b.txt': 'bundled-b',
      });

      expect(prepared.downloadedObjectCount, 2);
      expect(prepared.reusedObjectCount, 1);
      expect(
        await resolver.loadString('assets/b.txt', fallback: bundled),
        'hot-b-v2',
      );
      expect(
        await resolver.loadString('assets/c.txt', fallback: bundled),
        'hot-c-v2',
      );
      expect(
        await resolver.loadString('assets/a.txt', fallback: bundled),
        'bundled-a',
      );
      expect(store.activeReference?.snapshotId, 'snapshot-v2');
      expect(store.previousReference?.snapshotId, 'snapshot-v1');
      expect(manager.state.phase, ResourceUpdatePhase.active);
      expect(
        (await store.activeManifest())!.objectsByPath.containsKey(
          'assets/a.txt',
        ),
        isFalse,
      );
      final activeFile = await resolver.resolveActiveFile('assets/b.txt');
      expect(activeFile, isNotNull);
      expect(await activeFile!.readAsString(), 'hot-b-v2');
      final overlay = ResourceOverlayAssetBundle(
        resolver: resolver,
        fallback: bundled,
      );
      expect(await overlay.loadString('assets/b.txt'), 'hot-b-v2');
      expect(await overlay.loadString('assets/a.txt'), 'bundled-a');
      resolver.setOverlayEnabled(false);
      expect(await overlay.loadString('assets/b.txt'), 'bundled-b');
      expect(await resolver.resolveActiveFile('assets/b.txt'), isNull);
      resolver.setOverlayEnabled(true);
    },
  );

  test('a bad object hash never replaces the active snapshot', () async {
    final first = await _publishSnapshot(
      transport,
      id: 'snapshot-good',
      objects: const {'assets/a.txt': 'known-good'},
    );
    await manager.applyVerifiedSnapshot(
      snapshot: first.snapshot,
      expectedResourceApiVersion: 1,
      releaseSeq: 1,
    );
    final bad = await _publishSnapshot(
      transport,
      id: 'snapshot-bad',
      objects: const {'assets/b.txt': 'good!'},
      servedOverrides: const {'assets/b.txt': 'evil!'},
    );

    await expectLater(
      manager.applyVerifiedSnapshot(
        snapshot: bad.snapshot,
        expectedResourceApiVersion: 1,
        releaseSeq: 2,
      ),
      throwsA(
        isA<ResourceUpdateException>().having(
          (error) => error.code,
          'code',
          'resource_hash_mismatch',
        ),
      ),
    );
    expect(store.activeReference?.snapshotId, 'snapshot-good');
    expect(manager.state.phase, ResourceUpdatePhase.failed);
  });

  test(
    'startup health check atomically rolls back a corrupt active snapshot',
    () async {
      final first = await _publishSnapshot(
        transport,
        id: 'snapshot-rollback-v1',
        objects: const {'assets/state.txt': 'stable-v1'},
      );
      await manager.applyVerifiedSnapshot(
        snapshot: first.snapshot,
        expectedResourceApiVersion: 1,
        releaseSeq: 1,
      );
      final second = await _publishSnapshot(
        transport,
        id: 'snapshot-rollback-v2',
        objects: const {'assets/state.txt': 'broken-v2'},
      );
      await manager.applyVerifiedSnapshot(
        snapshot: second.snapshot,
        expectedResourceApiVersion: 1,
        releaseSeq: 2,
      );
      final active = (await store.activeManifest())!;
      final activeObject = active.objectsByPath['assets/state.txt']!;
      await (await store.objectFile(activeObject.sha256))
          .writeAsString('corrupt!!', flush: true);

      final restarted = createManager();
      addTearDown(restarted.dispose);
      await restarted.initialize();

      expect(restarted.state.phase, ResourceUpdatePhase.rolledBack);
      expect(store.activeReference?.snapshotId, 'snapshot-rollback-v1');
      expect(
        await resolver.loadString(
          'assets/state.txt',
          fallback: _MemoryAssetBundle(const {'assets/state.txt': 'bundled'}),
        ),
        'stable-v1',
      );
    },
  );

  test(
    'a future-runtime snapshot stays pending and activates on next APK',
    () async {
      manager.dispose();
      manager = createManager(
        assetKeyIds: const {'asset-key-1', 'asset-key-2'},
      );
      await manager.initialize();
      final future = await _publishSnapshot(
        transport,
        id: 'snapshot-next-apk',
        objects: const {'assets/future.txt': 'future-runtime'},
        runtimeIds: const {'runtime-2'},
        assetKeyId: 'asset-key-2',
        resourceApiVersion: 2,
      );
      final prepared = await manager.prepareVerifiedSnapshot(
        snapshot: future.snapshot,
        expectedResourceApiVersion: 2,
        releaseSeq: 2,
        forNextRuntime: true,
      );

      expect(manager.state.phase, ResourceUpdatePhase.pending);
      expect(store.activeReference, isNull);
      expect((await store.pendingSnapshots()).single, prepared.reference);

      final nextRuntime = createManager(
        runtimeId: 'runtime-2',
        resourceApiVersion: 2,
        assetKeyIds: const {'asset-key-2'},
      );
      addTearDown(nextRuntime.dispose);
      await nextRuntime.initialize();

      expect(nextRuntime.state.phase, ResourceUpdatePhase.active);
      expect(store.activeReference?.snapshotId, 'snapshot-next-apk');
      expect(await store.pendingSnapshots(), isEmpty);
    },
  );

  test(
    'activating newest pending snapshot cannot reactivate an older one',
    () async {
      final older = await _publishSnapshot(
        transport,
        id: 'snapshot-pending-old',
        objects: const {'assets/version.txt': 'old'},
      );
      final newer = await _publishSnapshot(
        transport,
        id: 'snapshot-pending-new',
        objects: const {'assets/version.txt': 'new'},
      );
      await manager.prepareVerifiedSnapshot(
        snapshot: older.snapshot,
        expectedResourceApiVersion: 1,
        releaseSeq: 1,
      );
      await manager.prepareVerifiedSnapshot(
        snapshot: newer.snapshot,
        expectedResourceApiVersion: 1,
        releaseSeq: 2,
      );
      expect(await store.pendingSnapshots(), hasLength(2));

      final firstRestart = createManager();
      addTearDown(firstRestart.dispose);
      await firstRestart.initialize();
      expect(store.activeReference?.snapshotId, 'snapshot-pending-new');
      expect(await store.pendingSnapshots(), isEmpty);

      final secondRestart = createManager();
      addTearDown(secondRestart.dispose);
      await secondRestart.initialize();
      expect(store.activeReference?.snapshotId, 'snapshot-pending-new');
      expect(
        await resolver.loadString(
          'assets/version.txt',
          fallback: _MemoryAssetBundle(const {'assets/version.txt': 'bundled'}),
        ),
        'new',
      );
    },
  );

  test('new APK baseline disables an older active overlay', () async {
    final old = await _publishSnapshot(
      transport,
      id: 'snapshot-before-apk',
      objects: const {'assets/version.txt': 'old-overlay'},
    );
    await manager.applyVerifiedSnapshot(
      snapshot: old.snapshot,
      expectedResourceApiVersion: 1,
      releaseSeq: 47,
    );

    final afterApkInstall = createManager();
    addTearDown(afterApkInstall.dispose);
    await afterApkInstall.initialize(bundledReleaseSeq: 48);
    final bundled = _MemoryAssetBundle(const {
      'assets/version.txt': 'apk-bundled-48',
    });

    expect(store.activeReference, isNull);
    expect(afterApkInstall.state.phase, ResourceUpdatePhase.rolledBack);
    expect(
      await resolver.loadString('assets/version.txt', fallback: bundled),
      'apk-bundled-48',
    );
  });

  test(
    'rollback never crosses below the installed APK resource baseline',
    () async {
      final old = await _publishSnapshot(
        transport,
        id: 'snapshot-baseline-old',
        objects: const {'assets/version.txt': 'overlay-47'},
      );
      final current = await _publishSnapshot(
        transport,
        id: 'snapshot-baseline-current',
        objects: const {'assets/version.txt': 'overlay-48'},
      );
      await manager.applyVerifiedSnapshot(
        snapshot: old.snapshot,
        expectedResourceApiVersion: 1,
        releaseSeq: 47,
      );
      await manager.applyVerifiedSnapshot(
        snapshot: current.snapshot,
        expectedResourceApiVersion: 1,
        releaseSeq: 48,
      );
      final afterApkInstall = createManager();
      addTearDown(afterApkInstall.dispose);
      await afterApkInstall.initialize(bundledReleaseSeq: 48);

      await afterApkInstall.rollback();

      expect(store.activeReference, isNull);
      expect(afterApkInstall.state.phase, ResourceUpdatePhase.rolledBack);
    },
  );

  test(
    'automatic recovery uses bundled assets above an old previous snapshot',
    () async {
      final old = await _publishSnapshot(
        transport,
        id: 'snapshot-auto-old',
        objects: const {'assets/version.txt': 'overlay-47'},
      );
      final current = await _publishSnapshot(
        transport,
        id: 'snapshot-auto-current',
        objects: const {'assets/version.txt': 'overlay-48'},
      );
      await manager.applyVerifiedSnapshot(
        snapshot: old.snapshot,
        expectedResourceApiVersion: 1,
        releaseSeq: 47,
      );
      await manager.applyVerifiedSnapshot(
        snapshot: current.snapshot,
        expectedResourceApiVersion: 1,
        releaseSeq: 48,
      );
      final object =
          (await store.activeManifest())!.objectsByPath['assets/version.txt']!;
      await (await store.objectFile(object.sha256)).writeAsString('corrupt');

      final afterApkInstall = createManager();
      addTearDown(afterApkInstall.dispose);
      await afterApkInstall.initialize(bundledReleaseSeq: 48);

      expect(store.activeReference, isNull);
      expect(afterApkInstall.state.phase, ResourceUpdatePhase.rolledBack);
    },
  );

  test('a future runtime cannot self-authorize an unknown asset key', () async {
    final future = await _publishSnapshot(
      transport,
      id: 'snapshot-untrusted-key',
      objects: const {'assets/future.txt': 'future-runtime'},
      runtimeIds: const {'runtime-2'},
      assetKeyId: 'not-in-bootstrap',
      resourceApiVersion: 2,
    );

    await expectLater(
      manager.prepareVerifiedSnapshot(
        snapshot: future.snapshot,
        expectedResourceApiVersion: 2,
        releaseSeq: 2,
        forNextRuntime: true,
      ),
      throwsA(
        isA<ResourceUpdateException>().having(
          (error) => error.code,
          'code',
          'resource_key_mismatch',
        ),
      ),
    );
    expect(store.activeReference, isNull);
  });

  test(
    'content health validation rejects signed but unusable objects',
    () async {
      final unusable = await _publishSnapshot(
        transport,
        id: 'snapshot-invalid-content',
        objects: const {'assets/data/config.json': 'not-json'},
      );
      final validating = createManager(
        healthValidator: (manifest, objectStore) async {
          final object = manifest.objectsByPath['assets/data/config.json']!;
          jsonDecode(
            await (await objectStore.objectFile(object.sha256)).readAsString(),
          );
        },
      );
      addTearDown(validating.dispose);

      await expectLater(
        validating.prepareVerifiedSnapshot(
          snapshot: unusable.snapshot,
          expectedResourceApiVersion: 1,
          releaseSeq: 1,
        ),
        throwsA(
          isA<ResourceUpdateException>().having(
            (error) => error.code,
            'code',
            'resource_content_unhealthy',
          ),
        ),
      );
      expect(store.activeReference, isNull);
      expect(await store.pendingSnapshots(), isEmpty);
    },
  );

  test(
    'future-runtime content validation is deferred until next startup',
    () async {
      manager.dispose();
      var checks = 0;
      manager = createManager(
        assetKeyIds: const {'asset-key-1', 'asset-key-2'},
      );
      await manager.initialize();
      final future = await _publishSnapshot(
        transport,
        id: 'snapshot-future-content',
        objects: const {'assets/future.json': 'future-format'},
        runtimeIds: const {'runtime-2'},
        assetKeyId: 'asset-key-2',
        resourceApiVersion: 2,
      );
      await manager.prepareVerifiedSnapshot(
        snapshot: future.snapshot,
        expectedResourceApiVersion: 2,
        releaseSeq: 2,
        forNextRuntime: true,
      );
      expect(checks, 0);

      final nextRuntime = createManager(
        runtimeId: 'runtime-2',
        resourceApiVersion: 2,
        assetKeyIds: const {'asset-key-2'},
        healthValidator: (manifest, objectStore) async {
          checks++;
          throw const FormatException('future schema is unusable');
        },
      );
      addTearDown(nextRuntime.dispose);
      await nextRuntime.initialize();

      expect(checks, 1);
      expect(store.activeReference, isNull);
      expect(
        (await store.pendingSnapshots()).single.snapshotId,
        'snapshot-future-content',
      );
    },
  );

  test(
    'resolver safely falls back when platform storage is unavailable',
    () async {
      final unavailable = ResourceAssetResolver(
        store: ResourceSnapshotStore(
          rootDirectory: () async =>
              throw MissingPluginException('path_provider'),
        ),
      );
      final bundled = _MemoryAssetBundle(const {'assets/base.txt': 'bundled'});

      expect(
        await unavailable.loadString('assets/base.txt', fallback: bundled),
        'bundled',
      );
      expect(await unavailable.isOverridden('assets/base.txt'), isFalse);
      expect(await unavailable.resolveActiveFile('assets/base.txt'), isNull);
    },
  );

  test(
    'cancel stops an in-flight update without activating a snapshot',
    () async {
      final blocking = _BlockingTransport();
      final cancelledManager = ResourceUpdateManager(
        compatibility: ResourceRuntimeCompatibility(
          runtimeId: 'runtime-1',
          resourceApiVersion: 1,
          assetKeyIds: const {'asset-key-1'},
        ),
        resolver: resolver,
        downloader: ResourceObjectDownloader(transport: blocking),
      );
      addTearDown(cancelledManager.dispose);
      final expected = Uint8List.fromList(utf8.encode('{}'));
      final future = cancelledManager.prepareVerifiedSnapshot(
        snapshot: ResourceSnapshot(
          id: 'snapshot-cancel',
          schemaVersion: 1,
          compatibleRuntimeIds: const {'runtime-1'},
          assetKeyId: 'asset-key-1',
          manifestSha256: await resourceSha256Bytes(expected),
          manifestUrl: Uri.parse(
            'https://resources.example.test/snapshot-cancel/manifest.json',
          ),
          size: expected.length,
        ),
        expectedResourceApiVersion: 1,
        releaseSeq: 1,
      );
      await blocking.started.future;
      cancelledManager.cancel();

      await expectLater(
        future,
        throwsA(
          isA<ResourceUpdateException>().having(
            (error) => error.code,
            'code',
            'resource_cancelled',
          ),
        ),
      );
      expect(cancelledManager.state.phase, ResourceUpdatePhase.cancelled);
      expect(store.activeReference, isNull);
    },
  );

  test(
    'retry after cancellation reuses objects already committed by hash',
    () async {
      final published = await _publishSnapshot(
        transport,
        id: 'snapshot-resume',
        objects: const {
          'assets/first.txt': 'first-completes',
          'assets/second.txt': 'second-blocks',
        },
      );
      final blocking = _BlockOneTransport(
        transport.payloads,
        'https://resources.example.test/snapshot-resume/object-1',
      );
      final interrupted = ResourceUpdateManager(
        compatibility: ResourceRuntimeCompatibility(
          runtimeId: 'runtime-1',
          resourceApiVersion: 1,
          assetKeyIds: const {'asset-key-1'},
        ),
        resolver: resolver,
        downloader: ResourceObjectDownloader(transport: blocking),
      );
      addTearDown(interrupted.dispose);
      final inFlight = interrupted.prepareVerifiedSnapshot(
        snapshot: published.snapshot,
        expectedResourceApiVersion: 1,
        releaseSeq: 1,
      );
      await blocking.blocked.future;
      interrupted.cancel();
      await expectLater(
        inFlight,
        throwsA(
          isA<ResourceUpdateException>().having(
            (error) => error.code,
            'code',
            'resource_cancelled',
          ),
        ),
      );

      final resumed = await manager.prepareVerifiedSnapshot(
        snapshot: published.snapshot,
        expectedResourceApiVersion: 1,
        releaseSeq: 1,
      );
      expect(resumed.reusedObjectCount, 1);
      expect(resumed.downloadedObjectCount, 1);
      expect(store.activeReference, isNull);
      expect(manager.state.phase, ResourceUpdatePhase.pending);
    },
  );

  test('HTTP transport follows only explicit HTTPS redirects', () async {
    final bytes = Uint8List.fromList(utf8.encode('redirected'));
    late final _RecordingClient client;
    client = _RecordingClient((request) async {
      if (request.url.host == 'origin.example.test') {
        return http.StreamedResponse(
          const Stream.empty(),
          HttpStatus.found,
          headers: {'location': 'https://cdn.example.test/object'},
        );
      }
      return http.StreamedResponse(
        Stream.value(bytes),
        HttpStatus.ok,
        contentLength: bytes.length,
      );
    });
    final httpTransport = HttpResourceDownloadTransport(
      clientFactory: () => client,
    );
    addTearDown(httpTransport.close);
    final downloader = ResourceObjectDownloader(transport: httpTransport);

    final result = await downloader.downloadBytes(
      ResourceDownloadRequest(
        id: 'redirect',
        urls: [Uri.parse('https://origin.example.test/object')],
        sha256: await resourceSha256Bytes(bytes),
        size: bytes.length,
      ),
    );

    expect(result, bytes);
    expect(client.requests.map((request) => request.url.host), [
      'origin.example.test',
      'cdn.example.test',
    ]);
    expect(
      client.requests.every((request) => !request.followRedirects),
      isTrue,
    );
  });

  test('HTTP transport rejects a redirect downgrade to cleartext', () async {
    final client = _RecordingClient(
      (_) async => http.StreamedResponse(
        const Stream.empty(),
        HttpStatus.found,
        headers: {'location': 'http://cdn.example.test/object'},
      ),
    );
    final httpTransport = HttpResourceDownloadTransport(
      clientFactory: () => client,
    );
    addTearDown(httpTransport.close);

    await expectLater(
      httpTransport.get(Uri.parse('https://origin.example.test/object')),
      throwsFormatException,
    );
    expect(client.requests, hasLength(1));
  });

  test(
    'path traversal is rejected before a snapshot can become pending',
    () async {
      final malicious = await _publishSnapshot(
        transport,
        id: 'snapshot-traversal',
        objects: const {'../private/save.json': 'do-not-write'},
      );

      await expectLater(
        manager.prepareVerifiedSnapshot(
          snapshot: malicious.snapshot,
          expectedResourceApiVersion: 1,
          releaseSeq: 1,
        ),
        throwsA(
          isA<ResourceUpdateException>().having(
            (error) => error.code,
            'code',
            'invalid_resource_manifest_schema',
          ),
        ),
      );
      expect(store.activeReference, isNull);
      expect(await store.pendingSnapshots(), isEmpty);
    },
  );

  test('cache cleanup stays inside its managed directory', () async {
    final userData = File(
      '${root.parent.path}${Platform.pathSeparator}user-save.txt',
    );
    await userData.writeAsString('keep me');
    addTearDown(() async {
      if (await userData.exists()) await userData.delete();
    });
    final unrelated = File(
      '${root.path}${Platform.pathSeparator}user-owned.txt',
    );
    await unrelated.writeAsString('unknown files are not ours');
    final staleObject = File(
      '${root.path}${Platform.pathSeparator}objects${Platform.pathSeparator}aa${Platform.pathSeparator}${'a' * 64}',
    );
    await staleObject.parent.create(recursive: true);
    await staleObject.writeAsString('stale');

    await manager.clearUnreferencedCache();

    expect(await staleObject.exists(), isFalse);
    expect(await unrelated.exists(), isTrue);
    expect(await userData.exists(), isTrue);
  });
}
