import 'dart:collection';

const resourceSnapshotManifestSchemaVersion = 1;
const resourceSnapshotCanonicalization = 'aar-cjson-v1';

final class ResourceObject {
  ResourceObject({
    required this.path,
    required this.sha256,
    required this.size,
    required List<Uri> urls,
  }) : urls = List.unmodifiable(urls);

  final String path;
  final String sha256;
  final int size;
  final List<Uri> urls;

  Map<String, Object> toJson() => {
    'path': path,
    'sha256': sha256,
    'size': size,
    'urls': urls.map((url) => url.toString()).toList(growable: false),
  };
}

final class ResourceSnapshotManifest {
  ResourceSnapshotManifest({
    required this.schemaVersion,
    required this.snapshotId,
    required this.resourceApiVersion,
    required Set<String> compatibleRuntimeIds,
    required this.assetKeyId,
    required List<ResourceObject> objects,
  }) : compatibleRuntimeIds = Set.unmodifiable(compatibleRuntimeIds),
       objects = List.unmodifiable(objects),
       objectsByPath = UnmodifiableMapView({
         for (final object in objects) object.path: object,
       });

  final int schemaVersion;
  final String snapshotId;
  final int resourceApiVersion;
  final Set<String> compatibleRuntimeIds;
  final String assetKeyId;
  final List<ResourceObject> objects;
  final Map<String, ResourceObject> objectsByPath;

  int get totalObjectBytes =>
      objects.fold(0, (total, object) => total + object.size);

  Map<String, Object> toJson() => {
    'asset_key_id': assetKeyId,
    'canonicalization': resourceSnapshotCanonicalization,
    'compatible_runtime_ids': compatibleRuntimeIds.toList()..sort(),
    'objects': objects.map((object) => object.toJson()).toList(growable: false),
    'resource_api_version': resourceApiVersion,
    'schema_version': schemaVersion,
    'snapshot_id': snapshotId,
  };
}

final class ResourceRuntimeCompatibility {
  ResourceRuntimeCompatibility({
    required this.runtimeId,
    required this.resourceApiVersion,
    required Set<String> assetKeyIds,
    this.snapshotSchemaVersion = resourceSnapshotManifestSchemaVersion,
  }) : assetKeyIds = Set.unmodifiable(assetKeyIds) {
    if (!_identifier.hasMatch(runtimeId) ||
        resourceApiVersion <= 0 ||
        snapshotSchemaVersion <= 0 ||
        this.assetKeyIds.isEmpty ||
        this.assetKeyIds.any((value) => !_identifier.hasMatch(value))) {
      throw ArgumentError('Invalid resource runtime compatibility');
    }
  }

  final String runtimeId;
  final int resourceApiVersion;
  final Set<String> assetKeyIds;
  final int snapshotSchemaVersion;

  void requireCompatible(ResourceSnapshotManifest manifest) {
    if (manifest.schemaVersion > snapshotSchemaVersion) {
      throw const ResourceUpdateException(
        'resource_schema_too_new',
        '资源快照格式高于当前应用支持范围',
      );
    }
    if (manifest.resourceApiVersion > resourceApiVersion) {
      throw const ResourceUpdateException(
        'resource_api_too_new',
        '资源快照需要更新版本的应用',
      );
    }
    if (!manifest.compatibleRuntimeIds.contains(runtimeId)) {
      throw const ResourceUpdateException(
        'resource_runtime_mismatch',
        '资源快照与当前运行时不兼容',
      );
    }
    if (!assetKeyIds.contains(manifest.assetKeyId)) {
      throw const ResourceUpdateException(
        'resource_key_mismatch',
        '资源快照使用了当前应用不支持的资源密钥',
      );
    }
  }
}

final class ResourceSnapshotReference {
  const ResourceSnapshotReference({
    required this.releaseSeq,
    required this.snapshotId,
    required this.manifestSha256,
  });

  final int releaseSeq;
  final String snapshotId;
  final String manifestSha256;

  Map<String, Object> toJson() => {
    'manifest_sha256': manifestSha256,
    'release_seq': releaseSeq,
    'snapshot_id': snapshotId,
  };

  @override
  bool operator ==(Object other) =>
      other is ResourceSnapshotReference &&
      other.releaseSeq == releaseSeq &&
      other.snapshotId == snapshotId &&
      other.manifestSha256 == manifestSha256;

  @override
  int get hashCode => Object.hash(releaseSeq, snapshotId, manifestSha256);
}

final class ResourceActivationPointer {
  const ResourceActivationPointer({
    required this.generation,
    required this.active,
    required this.previous,
    required this.action,
  });

  final int generation;
  final ResourceSnapshotReference? active;
  final ResourceSnapshotReference? previous;
  final String action;
}

final class PreparedResourceSnapshot {
  const PreparedResourceSnapshot({
    required this.reference,
    required this.manifest,
    required this.downloadedObjectCount,
    required this.reusedObjectCount,
  });

  final ResourceSnapshotReference reference;
  final ResourceSnapshotManifest manifest;
  final int downloadedObjectCount;
  final int reusedObjectCount;
}

enum ResourceUpdatePhase {
  idle,
  downloadingManifest,
  validatingManifest,
  downloadingObjects,
  pending,
  activating,
  active,
  rollingBack,
  rolledBack,
  cancelled,
  failed,
}

final class ResourceUpdateState {
  const ResourceUpdateState({
    this.phase = ResourceUpdatePhase.idle,
    this.snapshotId,
    this.completedObjects = 0,
    this.totalObjects = 0,
    this.errorCode,
  });

  final ResourceUpdatePhase phase;
  final String? snapshotId;
  final int completedObjects;
  final int totalObjects;
  final String? errorCode;
}

final class ResourceUpdateException implements Exception {
  const ResourceUpdateException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'ResourceUpdateException($code): $message';
}

final _identifier = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
