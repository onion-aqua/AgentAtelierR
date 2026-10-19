import 'dart:io';

import 'package:flutter/foundation.dart';

import 'resource_downloader.dart';
import 'resource_manifest.dart';
import 'resource_models.dart';
import 'resource_resolver.dart';
import 'resource_store.dart';
import 'update_models.dart';

typedef ResourceSnapshotHealthValidator = Future<void> Function(
  ResourceSnapshotManifest manifest,
  ResourceSnapshotStore store,
);

final class ResourceUpdateManager extends ChangeNotifier {
  ResourceUpdateManager({
    required this.compatibility,
    ResourceAssetResolver? resolver,
    ResourceObjectDownloader? downloader,
    ResourceSnapshotManifestParser? parser,
    this.healthValidator,
  }) : resolver = resolver ?? ResourceAssetResolver.instance,
       downloader = downloader ?? ResourceObjectDownloader(),
       _ownsDownloader = downloader == null,
       _parser = parser ?? const ResourceSnapshotManifestParser();

  final ResourceRuntimeCompatibility compatibility;
  final ResourceAssetResolver resolver;
  final ResourceObjectDownloader downloader;
  final bool _ownsDownloader;
  final ResourceSnapshotManifestParser _parser;
  final ResourceSnapshotHealthValidator? healthValidator;

  ResourceUpdateState _state = const ResourceUpdateState();
  PreparedResourceSnapshot? _pending;
  bool _busy = false;
  bool _cancelRequested = false;
  bool _disposed = false;
  int _bundledReleaseSeq = 0;

  ResourceUpdateState get state => _state;
  PreparedResourceSnapshot? get pending => _pending;
  bool get busy => _busy;

  /// Loads the active pointer and performs a startup health check. If the
  /// active snapshot is incompatible or incomplete, the previous verified
  /// snapshot is restored; otherwise bundled assets remain the final fallback.
  Future<void> initialize({int bundledReleaseSeq = 0}) async {
    if (bundledReleaseSeq < 0) {
      throw ArgumentError.value(
        bundledReleaseSeq,
        'bundledReleaseSeq',
        'must not be negative',
      );
    }
    _bundledReleaseSeq = bundledReleaseSeq;
    resolver.setOverlayEnabled(false);
    await resolver.initialize();
    final pendingSnapshots = await resolver.store.pendingSnapshots();
    final committedFloor = resolver.store.highestCommittedReleaseSeq;
    for (final reference in pendingSnapshots) {
      if (reference.releaseSeq < bundledReleaseSeq ||
          reference.releaseSeq < committedFloor ||
          (reference.releaseSeq == committedFloor &&
              reference != resolver.store.activeReference)) {
        await resolver.store.discardPending(reference);
        continue;
      }
      try {
        await _requireHealthy(reference);
        final pointer = await resolver.store.activate(reference);
        await resolver.refreshAfterActivation();
        resolver.setOverlayEnabled(true);
        _setState(
          ResourceUpdateState(
            phase: ResourceUpdatePhase.active,
            snapshotId: pointer.active?.snapshotId,
          ),
        );
        return;
      } on Object {
        // A snapshot prepared for a future APK remains pending until a runtime
        // with matching compatibility starts. Invalid pending data is never
        // allowed to disturb the currently active snapshot.
      }
    }
    final active = resolver.store.activeReference;
    if (active != null && active.releaseSeq < bundledReleaseSeq) {
      await resolver.store.deactivateForRecovery();
      await resolver.refreshAfterActivation();
      resolver.setOverlayEnabled(true);
      _setState(
        const ResourceUpdateState(phase: ResourceUpdatePhase.rolledBack),
      );
      return;
    }
    if (active == null) {
      resolver.setOverlayEnabled(true);
      _setState(const ResourceUpdateState());
      return;
    }
    try {
      await _requireHealthy(active);
      resolver.setOverlayEnabled(true);
      _setState(
        ResourceUpdateState(
          phase: ResourceUpdatePhase.active,
          snapshotId: active.snapshotId,
        ),
      );
    } on Object {
      final previous = resolver.store.previousReference;
      if (previous != null) {
        try {
          await _requireHealthy(previous);
          final pointer = await resolver.store.rollback();
          await resolver.refreshAfterActivation();
          resolver.setOverlayEnabled(true);
          _setState(
            ResourceUpdateState(
              phase: ResourceUpdatePhase.rolledBack,
              snapshotId: pointer.active?.snapshotId,
            ),
          );
          return;
        } on Object {
          // Neither hot snapshot is safe. The bundled assets remain readable.
        }
      }
      await resolver.store.deactivateForRecovery();
      await resolver.refreshAfterActivation();
      resolver.setOverlayEnabled(true);
      _setState(
        const ResourceUpdateState(phase: ResourceUpdatePhase.rolledBack),
      );
    }
  }

  /// [snapshot] must come from an UpdateManifest that has already passed the
  /// Ed25519 verifier. Its signed hash authenticates the canonical snapshot
  /// manifest downloaded here.
  Future<PreparedResourceSnapshot> prepareVerifiedSnapshot({
    required ResourceSnapshot snapshot,
    required int expectedResourceApiVersion,
    required int releaseSeq,
    bool forNextRuntime = false,
  }) async {
    if (_busy) {
      throw const ResourceUpdateException(
        'resource_update_in_progress',
        '已有资源更新正在进行',
      );
    }
    _busy = true;
    _cancelRequested = false;
    _pending = null;
    try {
      _requireSignedCompatibility(
        snapshot,
        expectedResourceApiVersion,
        forNextRuntime: forNextRuntime,
      );
      _setState(
        ResourceUpdateState(
          phase: ResourceUpdatePhase.downloadingManifest,
          snapshotId: snapshot.id,
        ),
      );
      final bytes = await downloader.downloadBytes(
        ResourceDownloadRequest(
          id: 'snapshot-${snapshot.id}',
          urls: [snapshot.manifestUrl],
          sha256: snapshot.manifestSha256,
          size: snapshot.size,
        ),
      );
      _throwIfCancelled();
      _setState(
        ResourceUpdateState(
          phase: ResourceUpdatePhase.validatingManifest,
          snapshotId: snapshot.id,
        ),
      );
      final manifest = await _parser.parseAuthenticated(
        bytes: bytes,
        signedSnapshot: snapshot,
        expectedResourceApiVersion: expectedResourceApiVersion,
      );
      if (!forNextRuntime) compatibility.requireCompatible(manifest);
      var downloaded = 0;
      var reused = 0;
      for (var index = 0; index < manifest.objects.length; index++) {
        _throwIfCancelled();
        final object = manifest.objects[index];
        _setState(
          ResourceUpdateState(
            phase: ResourceUpdatePhase.downloadingObjects,
            snapshotId: snapshot.id,
            completedObjects: index,
            totalObjects: manifest.objects.length,
          ),
        );
        if (await resolver.store.hasVerifiedObject(object)) {
          reused++;
          continue;
        }
        final staged = await resolver.store.createStagingFile(object.sha256);
        try {
          await downloader.downloadFile(
            ResourceDownloadRequest(
              id: object.path,
              urls: object.urls,
              sha256: object.sha256,
              size: object.size,
            ),
            destination: staged,
          );
          await resolver.store.commitObject(staged, object);
          downloaded++;
        } finally {
          if (await staged.exists()) await staged.delete();
          final partial = File('${staged.path}.part');
          if (await partial.exists()) await partial.delete();
        }
      }
      _throwIfCancelled();
      if (!forNextRuntime) {
        await _requireContentHealthy(manifest);
      }
      final reference = await resolver.store.stageSnapshot(
        manifest: manifest,
        authenticatedBytes: Uint8List.fromList(bytes),
        manifestSha256: snapshot.manifestSha256,
        releaseSeq: releaseSeq,
      );
      final prepared = PreparedResourceSnapshot(
        reference: reference,
        manifest: manifest,
        downloadedObjectCount: downloaded,
        reusedObjectCount: reused,
      );
      _pending = prepared;
      _setState(
        ResourceUpdateState(
          phase: ResourceUpdatePhase.pending,
          snapshotId: snapshot.id,
          completedObjects: manifest.objects.length,
          totalObjects: manifest.objects.length,
        ),
      );
      return prepared;
    } on ResourceUpdateException catch (error) {
      if (error.code == 'resource_cancelled') {
        _setState(
          ResourceUpdateState(
            phase: ResourceUpdatePhase.cancelled,
            snapshotId: snapshot.id,
            errorCode: error.code,
          ),
        );
        rethrow;
      }
      _setState(
        ResourceUpdateState(
          phase: ResourceUpdatePhase.failed,
          snapshotId: snapshot.id,
          errorCode: error.code,
        ),
      );
      rethrow;
    } on Object {
      const error = ResourceUpdateException(
        'resource_update_failed',
        '资源更新失败，当前资源未被替换',
      );
      _setState(
        ResourceUpdateState(
          phase: ResourceUpdatePhase.failed,
          snapshotId: snapshot.id,
          errorCode: error.code,
        ),
      );
      throw error;
    } finally {
      _busy = false;
    }
  }

  Future<void> activatePrepared(PreparedResourceSnapshot prepared) async {
    if (_busy) return;
    _busy = true;
    try {
      await _requireHealthy(prepared.reference);
      _setState(
        ResourceUpdateState(
          phase: ResourceUpdatePhase.activating,
          snapshotId: prepared.reference.snapshotId,
        ),
      );
      final pointer = await resolver.store.activate(prepared.reference);
      await resolver.refreshAfterActivation();
      resolver.setOverlayEnabled(true);
      _pending = null;
      _setState(
        ResourceUpdateState(
          phase: ResourceUpdatePhase.active,
          snapshotId: pointer.active?.snapshotId,
          completedObjects: prepared.manifest.objects.length,
          totalObjects: prepared.manifest.objects.length,
        ),
      );
    } on ResourceUpdateException catch (error) {
      _setState(
        ResourceUpdateState(
          phase: ResourceUpdatePhase.failed,
          snapshotId: prepared.reference.snapshotId,
          errorCode: error.code,
        ),
      );
      rethrow;
    } finally {
      _busy = false;
    }
  }

  Future<PreparedResourceSnapshot> applyVerifiedSnapshot({
    required ResourceSnapshot snapshot,
    required int expectedResourceApiVersion,
    required int releaseSeq,
  }) async {
    final prepared = await prepareVerifiedSnapshot(
      snapshot: snapshot,
      expectedResourceApiVersion: expectedResourceApiVersion,
      releaseSeq: releaseSeq,
    );
    await activatePrepared(prepared);
    return prepared;
  }

  Future<void> rollback() async {
    if (_busy) return;
    _busy = true;
    try {
      final previous = resolver.store.previousReference;
      if (previous == null) {
        throw const ResourceUpdateException(
          'resource_rollback_unavailable',
          '没有可回退的上一资源快照',
        );
      }
      if (previous.releaseSeq < _bundledReleaseSeq) {
        await resolver.store.deactivateForRecovery();
        await resolver.refreshAfterActivation();
        resolver.setOverlayEnabled(true);
        _setState(
          const ResourceUpdateState(phase: ResourceUpdatePhase.rolledBack),
        );
        return;
      }
      await _requireHealthy(previous);
      _setState(
        ResourceUpdateState(
          phase: ResourceUpdatePhase.rollingBack,
          snapshotId: previous.snapshotId,
        ),
      );
      final pointer = await resolver.store.rollback();
      await resolver.refreshAfterActivation();
      resolver.setOverlayEnabled(true);
      _setState(
        ResourceUpdateState(
          phase: ResourceUpdatePhase.rolledBack,
          snapshotId: pointer.active?.snapshotId,
        ),
      );
    } on ResourceUpdateException catch (error) {
      _setState(
        ResourceUpdateState(
          phase: ResourceUpdatePhase.failed,
          errorCode: error.code,
        ),
      );
      rethrow;
    } finally {
      _busy = false;
    }
  }

  Future<void> clearUnreferencedCache() async {
    if (_busy) {
      throw const ResourceUpdateException(
        'resource_update_in_progress',
        '资源更新期间不能清理资源缓存',
      );
    }
    await resolver.store.clearUnreferencedCache();
  }

  Future<ResourceSnapshotManifest> _requireHealthy(
    ResourceSnapshotReference reference,
  ) async {
    if (reference.releaseSeq < _bundledReleaseSeq) {
      throw const ResourceUpdateException(
        'resource_below_bundled_baseline',
        '资源快照早于当前安装包内置资源',
      );
    }
    final manifest = await resolver.store.loadSnapshot(reference);
    compatibility.requireCompatible(manifest);
    await resolver.store.verifySnapshotObjects(manifest);
    await _requireContentHealthy(manifest);
    return manifest;
  }

  Future<void> _requireContentHealthy(ResourceSnapshotManifest manifest) async {
    final validator = healthValidator;
    if (validator == null) return;
    try {
      await validator(manifest, resolver.store);
    } on ResourceUpdateException {
      rethrow;
    } on Object {
      throw const ResourceUpdateException(
        'resource_content_unhealthy',
        '资源内容健康检查失败，未激活该快照',
      );
    }
  }

  void _requireSignedCompatibility(
    ResourceSnapshot snapshot,
    int expectedResourceApiVersion, {
    required bool forNextRuntime,
  }) {
    if (snapshot.size > maxResourceSnapshotManifestBytes) {
      throw const ResourceUpdateException(
        'resource_manifest_too_large',
        '资源快照清单超过客户端限制',
      );
    }
    if (snapshot.schemaVersion > resourceSnapshotManifestSchemaVersion) {
      throw const ResourceUpdateException(
        'resource_schema_too_new',
        '资源快照格式高于当前应用支持范围',
      );
    }
    if (expectedResourceApiVersion <= 0 ||
        (!forNextRuntime &&
            expectedResourceApiVersion > compatibility.resourceApiVersion)) {
      throw const ResourceUpdateException(
        'resource_api_too_new',
        '资源快照需要更新版本的应用',
      );
    }
    if (!forNextRuntime &&
        !snapshot.compatibleRuntimeIds.contains(compatibility.runtimeId)) {
      throw const ResourceUpdateException(
        'resource_runtime_mismatch',
        '资源快照与当前运行时不兼容',
      );
    }
    if (!compatibility.assetKeyIds.contains(snapshot.assetKeyId)) {
      throw const ResourceUpdateException(
        'resource_key_mismatch',
        '资源快照使用了当前引导配置未信任的资源密钥',
      );
    }
  }

  void cancel() {
    if (!_busy) return;
    _cancelRequested = true;
    downloader.cancel();
  }

  void _throwIfCancelled() {
    if (_cancelRequested) {
      throw const ResourceUpdateException('resource_cancelled', '资源更新已取消');
    }
  }

  void _setState(ResourceUpdateState value) {
    _state = value;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_ownsDownloader) downloader.close();
    super.dispose();
  }
}
