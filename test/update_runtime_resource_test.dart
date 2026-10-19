import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/update/apk_update_installer.dart';
import 'package:ryza_chat_mvp/src/update/release_source.dart';
import 'package:ryza_chat_mvp/src/update/resource_downloader.dart';
import 'package:ryza_chat_mvp/src/update/resource_integrity.dart';
import 'package:ryza_chat_mvp/src/update/resource_models.dart';
import 'package:ryza_chat_mvp/src/update/resource_resolver.dart';
import 'package:ryza_chat_mvp/src/update/resource_store.dart';
import 'package:ryza_chat_mvp/src/update/resource_update_manager.dart';
import 'package:ryza_chat_mvp/src/update/update_build_config.dart';
import 'package:ryza_chat_mvp/src/update/update_downloader.dart';
import 'package:ryza_chat_mvp/src/update/update_manifest.dart';
import 'package:ryza_chat_mvp/src/update/update_models.dart';
import 'package:ryza_chat_mvp/src/update/update_notes_loader.dart';
import 'package:ryza_chat_mvp/src/update/update_runtime.dart';
import 'package:ryza_chat_mvp/src/update/update_service.dart';

final class _PayloadTransport implements ResourceDownloadTransport {
  final Map<String, Uint8List> payloads = {};
  int calls = 0;

  @override
  Future<ResourceDownloadResponse> get(Uri uri) async {
    calls++;
    final bytes = payloads[uri.toString()];
    return ResourceDownloadResponse(
      statusCode: bytes == null ? HttpStatus.notFound : HttpStatus.ok,
      body: bytes == null ? const Stream.empty() : Stream.value(bytes),
      contentLength: bytes?.length,
    );
  }

  @override
  void cancelActive() {}

  @override
  void close() {}
}

final class _RuntimeWithPlan extends UpdateRuntime {
  _RuntimeWithPlan({
    required this.selectedPlan,
    required super.buildConfig,
    required super.downloader,
    required super.installer,
    required super.notesLoader,
    required super.resourceManager,
  }) : super(installed: null, service: null);

  final UpdatePlan selectedPlan;

  @override
  UpdatePlan get plan => selectedPlan;

  @override
  UpdateCheckResult get lastCheck =>
      UpdateCheckResult.available(selectedPlan, UpdateReleaseOrigin.gitee);
}

final class _PublishedResource {
  const _PublishedResource(this.snapshot);

  final ResourceSnapshot snapshot;
}

Future<_PublishedResource> _publishResource(
  _PayloadTransport transport, {
  required String snapshotId,
  required String value,
  Set<String> runtimes = const {'runtime-1'},
  int apiVersion = 1,
  bool corruptObject = false,
}) async {
  final expected = Uint8List.fromList(utf8.encode(value));
  final served = Uint8List.fromList(
    utf8.encode(
      corruptObject ? '${value.substring(0, value.length - 1)}!' : value,
    ),
  );
  final objectUrl = Uri.parse(
    'https://resources.example.test/$snapshotId/object',
  );
  transport.payloads[objectUrl.toString()] = served;
  final manifestBytes = Uint8List.fromList(
    utf8.encode(
      canonicalJsonEncode({
        'asset_key_id': 'asset-key-1',
        'canonicalization': resourceSnapshotCanonicalization,
        'compatible_runtime_ids': runtimes.toList()..sort(),
        'objects': [
          {
            'path': 'assets/data/$snapshotId.txt',
            'sha256': await resourceSha256Bytes(expected),
            'size': expected.length,
            'urls': [objectUrl.toString()],
          },
        ],
        'resource_api_version': apiVersion,
        'schema_version': resourceSnapshotManifestSchemaVersion,
        'snapshot_id': snapshotId,
      }),
    ),
  );
  final manifestUrl = Uri.parse(
    'https://resources.example.test/$snapshotId/manifest.json',
  );
  transport.payloads[manifestUrl.toString()] = manifestBytes;
  return _PublishedResource(
    ResourceSnapshot(
      id: snapshotId,
      schemaVersion: 1,
      compatibleRuntimeIds: runtimes,
      assetKeyId: 'asset-key-1',
      manifestSha256: await resourceSha256Bytes(manifestBytes),
      manifestUrl: manifestUrl,
      size: manifestBytes.length,
    ),
  );
}

UpdateBuildConfig _buildConfig({
  String runtimeId = 'runtime-1',
  int apiVersion = 1,
}) => UpdateBuildConfig(
  sources: ReleaseSourceConfig(
    giteeLatest: Uri.parse('https://updates.example.test/latest.json'),
  ),
  trustedKeys: {'.release-key': List<int>.filled(32, 1)},
  resourceAssetKeyIds: const {'asset-key-1'},
  releaseSeq: 46,
  channel: 'stable',
  runtimeCompatId: runtimeId,
  resourceApiVersion: apiVersion,
  updaterProtocolVersion: 1,
);

UpdateManifest _manifest({
  required ResourceSnapshot snapshot,
  required ResourceActivation activation,
  UpdateTargetApk? target,
  int releaseSeq = 47,
  int resourceApiVersion = 1,
}) => UpdateManifest(
  schemaVersion: 1,
  releaseId: 'release-$releaseSeq',
  releaseSeq: releaseSeq,
  displayVersion: '1.0.4.2',
  channel: 'stable',
  platform: 'android',
  updaterProtocolVersion: 1,
  publishedAt: DateTime.utc(2026, 10, 19),
  runtimeCompatId: activation == ResourceActivation.afterApkInstall
      ? 'runtime-2'
      : 'runtime-1',
  resourceApiVersion: resourceApiVersion,
  targetApk: target,
  apkDeltas: const [],
  resourceSnapshot: snapshot,
  notes: UpdateReleaseNotes(releaseId: 'release-$releaseSeq'),
  signedPayload: const {},
);

UpdatePlan _plan(
  UpdateManifest manifest, {
  required ResourceActivation activation,
}) => UpdatePlan(
  manifest: manifest,
  apk: manifest.targetApk == null
      ? null
      : ApkUpdateSelection.full(manifest.targetApk!),
  resource: ResourceUpdateSelection(manifest.resourceSnapshot!, activation),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const installerChannel = MethodChannel(ApkUpdateInstaller.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory root;
  late _PayloadTransport resourceTransport;
  late ResourceSnapshotStore store;
  late ResourceAssetResolver resolver;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('aar_runtime_resource_');
    resourceTransport = _PayloadTransport();
    store = ResourceSnapshotStore(rootDirectory: () async => root);
    resolver = ResourceAssetResolver(store: store);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(installerChannel, null);
    if (await root.exists()) await root.delete(recursive: true);
  });

  ResourceUpdateManager manager({
    String runtimeId = 'runtime-1',
    int apiVersion = 1,
  }) => ResourceUpdateManager(
    compatibility: ResourceRuntimeCompatibility(
      runtimeId: runtimeId,
      resourceApiVersion: apiVersion,
      assetKeyIds: const {'asset-key-1'},
    ),
    resolver: resolver,
    downloader: ResourceObjectDownloader(transport: resourceTransport),
  );

  UpdateDownloader apkDownloader([List<int>? apkBytes]) => UpdateDownloader(
    supportDirectory: () async => root,
    clientFactory: () => MockClient(
      (_) async => http.Response.bytes(apkBytes ?? const [1], HttpStatus.ok),
    ),
  );

  test(
    'resource-only update is prepared and activates on next startup',
    () async {
      final resource = await _publishResource(
        resourceTransport,
        snapshotId: 'snapshot-resource-only',
        value: 'hot resource',
      );
      final resourceManager = manager();
      await resourceManager.initialize();
      final manifest = _manifest(
        snapshot: resource.snapshot,
        activation: ResourceActivation.immediate,
      );
      final runtime = _RuntimeWithPlan(
        selectedPlan: _plan(manifest, activation: ResourceActivation.immediate),
        buildConfig: _buildConfig(),
        downloader: apkDownloader(),
        installer: ApkUpdateInstaller(channel: installerChannel),
        notesLoader: UpdateNotesLoader(),
        resourceManager: resourceManager,
      );
      addTearDown(runtime.dispose);

      await runtime.startUpdate();

      expect(runtime.phase, UpdateRuntimePhase.resourcesReady);
      expect(runtime.resourceState.phase, ResourceUpdatePhase.pending);
      expect(store.activeReference, isNull);
      expect(
        (await store.pendingSnapshots()).single.snapshotId,
        resource.snapshot.id,
      );
      await runtime.check(manual: true);
      expect(runtime.phase, UpdateRuntimePhase.resourcesReady);

      await resourceManager.initialize();
      expect(store.activeReference?.snapshotId, resource.snapshot.id);
    },
  );

  test('failed resource verification preserves the active snapshot', () async {
    final good = await _publishResource(
      resourceTransport,
      snapshotId: 'snapshot-good',
      value: 'known good',
    );
    final resourceManager = manager();
    await resourceManager.initialize();
    await resourceManager.applyVerifiedSnapshot(
      snapshot: good.snapshot,
      expectedResourceApiVersion: 1,
      releaseSeq: 46,
    );
    final bad = await _publishResource(
      resourceTransport,
      snapshotId: 'snapshot-bad',
      value: 'expected',
      corruptObject: true,
    );
    final manifest = _manifest(
      snapshot: bad.snapshot,
      activation: ResourceActivation.immediate,
    );
    final runtime = _RuntimeWithPlan(
      selectedPlan: _plan(manifest, activation: ResourceActivation.immediate),
      buildConfig: _buildConfig(),
      downloader: apkDownloader(),
      installer: ApkUpdateInstaller(channel: installerChannel),
      notesLoader: UpdateNotesLoader(),
      resourceManager: resourceManager,
    );
    addTearDown(runtime.dispose);

    await runtime.startUpdate();

    expect(runtime.phase, UpdateRuntimePhase.error);
    expect(runtime.errorCode, 'resource_hash_mismatch');
    expect(store.activeReference?.snapshotId, good.snapshot.id);
  });

  test(
    'combined update prepares future resources and resumes APK install',
    () async {
      final apkBytes = utf8.encode('complete-apk');
      final apkSha = await resourceSha256Bytes(apkBytes);
      final target = UpdateTargetApk(
        versionCode: 47,
        packageName: 'com.example.ryza_chat_mvp',
        abis: const {'arm64-v8a'},
        sha256: apkSha,
        certificateSha256: 'c' * 64,
        urls: [Uri.parse('https://downloads.example.test/app.apk')],
        size: apkBytes.length,
      );
      final resource = await _publishResource(
        resourceTransport,
        snapshotId: 'snapshot-next-runtime',
        value: 'future resource',
        runtimes: const {'runtime-2'},
        apiVersion: 2,
      );
      final resourceManager = manager();
      await resourceManager.initialize();
      final manifest = _manifest(
        snapshot: resource.snapshot,
        activation: ResourceActivation.afterApkInstall,
        target: target,
        resourceApiVersion: 2,
      );
      var permissionGranted = false;
      messenger.setMockMethodCallHandler(installerChannel, (call) async {
        switch (call.method) {
          case 'getAvailableUpdateSpace':
            return <String, Object>{'bytes': 512 * 1024 * 1024};
          case 'validateApk':
            return <String, Object?>{
              'valid': true,
              'packageName': target.packageName,
              'versionCode': target.versionCode,
              'versionName': '1.0.4.2',
              'sha256': target.sha256,
              'bytes': target.size,
              'signingCompatible': true,
            };
          case 'getInstallPermissionStatus':
            return <String, Object>{
              'required': true,
              'granted': permissionGranted,
            };
          case 'installApk':
            return <String, Object?>{
              'launched': true,
              'packageName': target.packageName,
              'versionCode': target.versionCode,
              'versionName': '1.0.4.2',
              'sha256': target.sha256,
              'bytes': target.size,
            };
        }
        fail('Unexpected installer call: ${call.method}');
      });
      final runtime = _RuntimeWithPlan(
        selectedPlan: _plan(
          manifest,
          activation: ResourceActivation.afterApkInstall,
        ),
        buildConfig: _buildConfig(),
        downloader: apkDownloader(apkBytes),
        installer: ApkUpdateInstaller(channel: installerChannel),
        notesLoader: UpdateNotesLoader(),
        resourceManager: resourceManager,
      );
      addTearDown(runtime.dispose);

      await runtime.startUpdate();

      expect(runtime.phase, UpdateRuntimePhase.permissionRequired);
      expect(runtime.readyApkPath, isNotNull);
      expect(store.activeReference, isNull);
      expect(
        (await store.pendingSnapshots()).single.snapshotId,
        resource.snapshot.id,
      );
      await runtime.check(trigger: UpdateCheckTrigger.foreground);
      expect(runtime.phase, UpdateRuntimePhase.permissionRequired);

      permissionGranted = true;
      await runtime.continueInstall();
      expect(runtime.phase, UpdateRuntimePhase.installerOpened);

      await runtime.clearCache();
      expect(runtime.phase, UpdateRuntimePhase.available);
      expect(runtime.readyApkPath, isNull);
      expect(
        (await store.pendingSnapshots()).single.snapshotId,
        resource.snapshot.id,
      );
    },
  );

  test(
    'unconfigured production runtime disables overlay and networking',
    () async {
      resolver.setOverlayEnabled(true);
      ResourceAssetResolver.instance.setOverlayEnabled(true);

      final runtime = await UpdateRuntime.production();
      addTearDown(runtime.dispose);

      expect(runtime.enabled, isFalse);
      expect(runtime.phase, UpdateRuntimePhase.disabled);
      expect(runtime.errorCode, 'not_configured');
      expect(ResourceAssetResolver.instance.overlayEnabled, isFalse);
    },
  );
}
