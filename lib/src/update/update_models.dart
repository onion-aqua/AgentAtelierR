import 'dart:collection';

const updateManifestSchemaVersion = 1;
const updateCanonicalization = 'aar-cjson-v1';

typedef UpdateJson = Map<String, dynamic>;

enum UpdateReleaseOrigin { gitee, cache, github }

enum UpdateSourcePreference { automatic, gitee, github }

enum UpdateCheckTrigger { startup, foreground, manual }

enum ApkUpdateKind { delta, full }

enum ResourceActivation { immediate, afterApkInstall }

/// Numeric prefix used for display-version ordering. Android versionCode and
/// release_seq remain the authoritative install and release identities.
final class UpdateVersion implements Comparable<UpdateVersion> {
  UpdateVersion._(this.parts);

  final List<int> parts;

  factory UpdateVersion.parse(String source) {
    final match = RegExp(r'^\s*(\d+(?:\.\d+)*)').firstMatch(source);
    if (match == null) {
      throw const FormatException('更新版本号缺少数字版本前缀');
    }
    final parts = match
        .group(1)!
        .split('.')
        .map((part) {
          final value = int.tryParse(part);
          if (value == null || value < 0) {
            throw const FormatException('更新版本号格式无效');
          }
          return value;
        })
        .toList(growable: false);
    return UpdateVersion._(parts);
  }

  @override
  int compareTo(UpdateVersion other) {
    final length = parts.length > other.parts.length
        ? parts.length
        : other.parts.length;
    for (var index = 0; index < length; index++) {
      final left = index < parts.length ? parts[index] : 0;
      final right = index < other.parts.length ? other.parts[index] : 0;
      if (left != right) return left.compareTo(right);
    }
    return 0;
  }

  @override
  String toString() => parts.join('.');
}

int compareDisplayVersions(String left, String right) =>
    UpdateVersion.parse(left).compareTo(UpdateVersion.parse(right));

final class UpdateTargetApk {
  const UpdateTargetApk({
    required this.versionCode,
    required this.packageName,
    required this.abis,
    required this.sha256,
    required this.certificateSha256,
    required this.urls,
    required this.size,
  });

  final int versionCode;
  final String packageName;
  final Set<String> abis;
  final String sha256;
  final String certificateSha256;
  final List<Uri> urls;
  final int size;
}

final class ApkDelta {
  const ApkDelta({
    required this.baseSha256,
    required this.targetSha256,
    required this.format,
    required this.patchProtocolVersion,
    required this.patchSha256,
    required this.urls,
    required this.size,
  });

  final String baseSha256;
  final String targetSha256;
  final String format;
  final int patchProtocolVersion;
  final String patchSha256;
  final List<Uri> urls;
  final int size;
}

final class ResourceSnapshot {
  const ResourceSnapshot({
    required this.id,
    required this.schemaVersion,
    required this.compatibleRuntimeIds,
    required this.assetKeyId,
    required this.manifestSha256,
    required this.manifestUrl,
    required this.size,
  });

  final String id;
  final int schemaVersion;
  final Set<String> compatibleRuntimeIds;
  final String assetKeyId;
  final String manifestSha256;
  final Uri manifestUrl;
  final int size;
}

final class UpdateReleaseNotes {
  const UpdateReleaseNotes({
    required this.releaseId,
    this.giteeUrl,
    this.githubUrl,
    this.cachedMarkdownUrl,
  });

  final String releaseId;
  final Uri? giteeUrl;
  final Uri? githubUrl;
  final Uri? cachedMarkdownUrl;
}

final class UpdateManifest {
  UpdateManifest({
    required this.schemaVersion,
    required this.releaseId,
    required this.releaseSeq,
    required this.displayVersion,
    required this.channel,
    required this.platform,
    required this.updaterProtocolVersion,
    required this.publishedAt,
    required this.runtimeCompatId,
    required this.resourceApiVersion,
    required this.targetApk,
    required List<ApkDelta> apkDeltas,
    required this.resourceSnapshot,
    required this.notes,
    required UpdateJson signedPayload,
  }) : apkDeltas = List.unmodifiable(apkDeltas),
       signedPayload = UnmodifiableMapView(signedPayload);

  final int schemaVersion;
  final String releaseId;
  final int releaseSeq;
  final String displayVersion;
  final String channel;
  final String platform;
  final int updaterProtocolVersion;
  final DateTime publishedAt;
  final String runtimeCompatId;
  final int resourceApiVersion;
  final UpdateTargetApk? targetApk;
  final List<ApkDelta> apkDeltas;
  final ResourceSnapshot? resourceSnapshot;
  final UpdateReleaseNotes notes;
  final Map<String, dynamic> signedPayload;
}

final class UpdateManifestSignature {
  const UpdateManifestSignature({
    required this.keyId,
    required this.algorithm,
    required this.signedObject,
    required this.canonicalization,
    required this.valueBase64,
  });

  final String keyId;
  final String algorithm;
  final String signedObject;
  final String canonicalization;
  final String valueBase64;

  factory UpdateManifestSignature.fromJson(Object? value) =>
      _parseSignature(value);
}

final class UpdateManifestEnvelope {
  const UpdateManifestEnvelope({
    required this.payload,
    required this.signature,
  });

  final UpdateJson payload;
  final UpdateManifestSignature signature;

  factory UpdateManifestEnvelope.fromJson(Object? value) =>
      _parseEnvelope(value);
}

final class FetchedUpdateManifest {
  const FetchedUpdateManifest({
    required this.envelope,
    required this.origin,
    required this.endpoint,
  });

  final UpdateManifestEnvelope envelope;
  final UpdateReleaseOrigin origin;
  final Uri endpoint;
}

final class InstalledUpdateState {
  InstalledUpdateState({
    required this.releaseSeq,
    required this.displayVersion,
    required this.nativeBuild,
    required this.packageName,
    required this.channel,
    required this.platform,
    required this.runtimeCompatId,
    required this.resourceApiVersion,
    required this.updaterProtocolVersion,
    required Set<String> supportedAbis,
    String? apkSha256,
    String? certificateSha256,
    this.resourceSnapshotId,
    Set<String> supportedDeltaFormats = const {},
    this.patchProtocolVersion = 1,
  }) : supportedAbis = Set.unmodifiable(supportedAbis),
       supportedDeltaFormats = Set.unmodifiable(supportedDeltaFormats),
       apkSha256 = apkSha256?.toLowerCase(),
       certificateSha256 = certificateSha256?.toLowerCase();

  final int releaseSeq;
  final String displayVersion;
  final int nativeBuild;
  final String packageName;
  final String channel;
  final String platform;
  final String runtimeCompatId;
  final int resourceApiVersion;
  final int updaterProtocolVersion;
  final Set<String> supportedAbis;
  final String? apkSha256;
  final String? certificateSha256;
  final String? resourceSnapshotId;
  final Set<String> supportedDeltaFormats;
  final int patchProtocolVersion;
}

final class ApkUpdateSelection {
  const ApkUpdateSelection.full(this.target)
    : kind = ApkUpdateKind.full,
      delta = null;

  const ApkUpdateSelection.delta(this.target, this.delta)
    : kind = ApkUpdateKind.delta;

  final ApkUpdateKind kind;
  final UpdateTargetApk target;
  final ApkDelta? delta;

  int get downloadSize => delta?.size ?? target.size;
}

final class ResourceUpdateSelection {
  const ResourceUpdateSelection(this.snapshot, this.activation);

  final ResourceSnapshot snapshot;
  final ResourceActivation activation;
}

final class UpdatePlan {
  const UpdatePlan({
    required this.manifest,
    this.apk,
    this.resource,
    this.unavailableReason,
  });

  final UpdateManifest manifest;
  final ApkUpdateSelection? apk;
  final ResourceUpdateSelection? resource;
  final String? unavailableReason;

  bool get isAvailable => unavailableReason == null;
  bool get hasUpdate => isAvailable && (apk != null || resource != null);
  int get downloadSize =>
      (apk?.downloadSize ?? 0) + (resource?.snapshot.size ?? 0);
}

final class UpdatePlanner {
  const UpdatePlanner({this.deltaSizeRatio = 0.75});

  final double deltaSizeRatio;

  UpdatePlan plan(InstalledUpdateState current, UpdateManifest manifest) {
    String? incompatible;
    if (manifest.platform != current.platform) {
      incompatible = 'platform_mismatch';
    } else if (manifest.channel != current.channel) {
      incompatible = 'channel_mismatch';
    } else if (manifest.updaterProtocolVersion >
        current.updaterProtocolVersion) {
      incompatible = 'updater_protocol_too_old';
    } else if (manifest.releaseSeq < current.releaseSeq) {
      incompatible = 'release_rollback';
    } else if (manifest.releaseSeq == current.releaseSeq &&
        ((manifest.targetApk != null &&
                current.apkSha256 != null &&
                manifest.targetApk!.sha256 != current.apkSha256) ||
            (manifest.resourceSnapshot != null &&
                current.resourceSnapshotId != null &&
                manifest.resourceSnapshot!.id != current.resourceSnapshotId))) {
      incompatible = 'release_identity_conflict';
    }
    if (incompatible != null) {
      return UpdatePlan(manifest: manifest, unavailableReason: incompatible);
    }

    ApkUpdateSelection? apk;
    final target = manifest.targetApk;
    final apkIsAlreadyInstalled = current.apkSha256 != null
        ? target?.sha256 == current.apkSha256
        : target?.versionCode == current.nativeBuild;
    if (target != null && !apkIsAlreadyInstalled) {
      if (target.packageName != current.packageName) {
        incompatible = 'package_mismatch';
      } else if (target.versionCode <= current.nativeBuild) {
        incompatible = 'native_build_not_newer';
      } else if (current.certificateSha256 != null &&
          target.certificateSha256 != current.certificateSha256) {
        incompatible = 'certificate_mismatch';
      } else if (target.abis.intersection(current.supportedAbis).isEmpty) {
        incompatible = 'abi_mismatch';
      } else {
        final currentSha = current.apkSha256;
        ApkDelta? selected;
        if (currentSha != null) {
          for (final candidate in manifest.apkDeltas) {
            if (candidate.baseSha256 == currentSha &&
                candidate.targetSha256 == target.sha256 &&
                current.supportedDeltaFormats.contains(candidate.format) &&
                candidate.patchProtocolVersion <=
                    current.patchProtocolVersion &&
                candidate.size <= target.size * deltaSizeRatio) {
              if (selected == null || candidate.size < selected.size) {
                selected = candidate;
              }
            }
          }
        }
        apk = selected == null
            ? ApkUpdateSelection.full(target)
            : ApkUpdateSelection.delta(target, selected);
      }
    }
    if (incompatible != null) {
      return UpdatePlan(manifest: manifest, unavailableReason: incompatible);
    }

    ResourceUpdateSelection? resource;
    final snapshot = manifest.resourceSnapshot;
    if (snapshot != null && snapshot.id != current.resourceSnapshotId) {
      final currentCanRead =
          manifest.resourceApiVersion <= current.resourceApiVersion &&
          snapshot.schemaVersion <= current.resourceApiVersion &&
          snapshot.compatibleRuntimeIds.contains(current.runtimeCompatId);
      if (currentCanRead) {
        resource = ResourceUpdateSelection(
          snapshot,
          ResourceActivation.immediate,
        );
      } else if (apk != null &&
          snapshot.compatibleRuntimeIds.contains(manifest.runtimeCompatId)) {
        resource = ResourceUpdateSelection(
          snapshot,
          ResourceActivation.afterApkInstall,
        );
      } else if (manifest.resourceApiVersion > current.resourceApiVersion ||
          snapshot.schemaVersion > current.resourceApiVersion) {
        incompatible = 'resource_api_too_old';
      } else {
        incompatible = 'resource_runtime_mismatch';
      }
    }
    return UpdatePlan(
      manifest: manifest,
      apk: apk,
      resource: resource,
      unavailableReason: incompatible,
    );
  }
}

UpdateManifestEnvelope _parseEnvelope(Object? value) {
  final json = _object(value, 'envelope');
  _exactKeys(json, const {'payload', 'signature'}, 'envelope');
  final payload = _object(json['payload'], 'payload');
  // Parse before signature verification so malformed schemas never reach the
  // planner. Verification still authenticates these exact, unmodified values.
  parseUpdateManifestPayload(payload);
  return UpdateManifestEnvelope(
    payload: Map<String, dynamic>.unmodifiable(payload),
    signature: _parseSignature(json['signature']),
  );
}

UpdateManifestSignature _parseSignature(Object? value) {
  final json = _object(value, 'signature');
  _exactKeys(json, const {
    'key_id',
    'algorithm',
    'signed_object',
    'canonicalization',
    'value_base64',
  }, 'signature');
  final signature = UpdateManifestSignature(
    keyId: _identifier(json, 'key_id'),
    algorithm: _string(json, 'algorithm'),
    signedObject: _string(json, 'signed_object'),
    canonicalization: _string(json, 'canonicalization'),
    valueBase64: _string(json, 'value_base64'),
  );
  if (signature.algorithm != 'Ed25519' ||
      signature.signedObject != 'payload' ||
      signature.canonicalization != updateCanonicalization) {
    throw const FormatException('更新清单签名协议不受支持');
  }
  return signature;
}

UpdateManifest parseUpdateManifestPayload(UpdateJson payload) {
  _allowedKeys(
    payload,
    required: const {
      'schema_version',
      'canonicalization',
      'release_id',
      'release_seq',
      'display_version',
      'channel',
      'platform',
      'updater_protocol_version',
      'published_at',
      'runtime_compat_id',
      'resource_api_version',
      'apk_deltas',
      'notes',
    },
    allowed: const {
      'schema_version',
      'canonicalization',
      'release_id',
      'release_seq',
      'display_version',
      'channel',
      'platform',
      'updater_protocol_version',
      'published_at',
      'runtime_compat_id',
      'resource_api_version',
      'target_apk',
      'apk_deltas',
      'resource_snapshot',
      'notes',
    },
    label: 'payload',
  );
  final schemaVersion = _positiveInt(payload, 'schema_version');
  if (schemaVersion != updateManifestSchemaVersion ||
      payload['canonicalization'] != updateCanonicalization) {
    throw const FormatException('更新清单 schema 或规范化协议不受支持');
  }
  final releaseId = _releaseId(payload, 'release_id');
  final publishedRaw = _string(payload, 'published_at');
  final publishedAt = DateTime.tryParse(publishedRaw);
  if (publishedAt == null ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')
          .hasMatch(publishedRaw) ||
      !publishedAt.isUtc) {
    throw const FormatException('published_at 必须是 UTC RFC3339 时间');
  }
  final displayVersion = _string(payload, 'display_version', maxLength: 96);
  UpdateVersion.parse(displayVersion);
  final target = payload.containsKey('target_apk')
      ? _parseTargetApk(payload['target_apk'])
      : null;
  final deltas = _list(
    payload,
    'apk_deltas',
  ).map(_parseApkDelta).toList(growable: false);
  if (target == null && deltas.isNotEmpty) {
    throw const FormatException('没有目标 APK 时不能包含差分');
  }
  if (target != null &&
      deltas.any((delta) => delta.targetSha256 != target.sha256)) {
    throw const FormatException('差分目标 hash 与目标 APK 不一致');
  }
  final snapshot = payload.containsKey('resource_snapshot')
      ? _parseResourceSnapshot(payload['resource_snapshot'])
      : null;
  if (target == null && snapshot == null) {
    throw const FormatException('更新清单没有任何可更新目标');
  }
  final notes = _parseNotes(payload['notes']);
  if (notes.releaseId != releaseId) {
    throw const FormatException('更新说明与清单 release_id 不一致');
  }
  return UpdateManifest(
    schemaVersion: schemaVersion,
    releaseId: releaseId,
    releaseSeq: _positiveInt(payload, 'release_seq'),
    displayVersion: displayVersion,
    channel: _lowerIdentifier(payload, 'channel', maxLength: 32),
    platform: _androidPlatform(payload),
    updaterProtocolVersion: _positiveInt(payload, 'updater_protocol_version'),
    publishedAt: publishedAt,
    runtimeCompatId: _identifier(payload, 'runtime_compat_id'),
    resourceApiVersion: _positiveInt(payload, 'resource_api_version'),
    targetApk: target,
    apkDeltas: deltas,
    resourceSnapshot: snapshot,
    notes: notes,
    signedPayload: Map<String, dynamic>.from(payload),
  );
}

UpdateTargetApk _parseTargetApk(Object? value) {
  final json = _object(value, 'target_apk');
  _exactKeys(json, const {
    'version_code',
    'package_name',
    'abis',
    'sha256',
    'certificate_sha256',
    'urls',
    'size',
  }, 'target_apk');
  final packageName = _string(json, 'package_name', maxLength: 240);
  if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$')
      .hasMatch(packageName)) {
    throw const FormatException('APK 包名格式无效');
  }
  return UpdateTargetApk(
    versionCode: _positiveInt(json, 'version_code'),
    packageName: packageName,
    abis: _stringSet(json, 'abis'),
    sha256: _sha256(json, 'sha256'),
    certificateSha256: _sha256(json, 'certificate_sha256'),
    urls: _uris(json, 'urls'),
    size: _positiveInt(json, 'size'),
  );
}

ApkDelta _parseApkDelta(Object? value) {
  final json = _object(value, 'apk_delta');
  _exactKeys(json, const {
    'base_sha256',
    'target_sha256',
    'format',
    'patch_protocol_version',
    'patch_sha256',
    'urls',
    'size',
  }, 'apk_delta');
  final base = _sha256(json, 'base_sha256');
  final target = _sha256(json, 'target_sha256');
  if (base == target) throw const FormatException('APK 差分基线不能等于目标');
  return ApkDelta(
    baseSha256: base,
    targetSha256: target,
    format: _lowerIdentifier(json, 'format', maxLength: 32),
    patchProtocolVersion: _positiveInt(json, 'patch_protocol_version'),
    patchSha256: _sha256(json, 'patch_sha256'),
    urls: _uris(json, 'urls'),
    size: _positiveInt(json, 'size'),
  );
}

ResourceSnapshot _parseResourceSnapshot(Object? value) {
  final json = _object(value, 'resource_snapshot');
  _exactKeys(json, const {
    'id',
    'schema_version',
    'compatible_runtime_ids',
    'asset_key_id',
    'manifest_sha256',
    'manifest_url',
    'size',
  }, 'resource_snapshot');
  return ResourceSnapshot(
    id: _identifier(json, 'id'),
    schemaVersion: _positiveInt(json, 'schema_version'),
    compatibleRuntimeIds: _stringSet(json, 'compatible_runtime_ids'),
    assetKeyId: _identifier(json, 'asset_key_id'),
    manifestSha256: _sha256(json, 'manifest_sha256'),
    manifestUrl: _httpsUri(_string(json, 'manifest_url')),
    size: _positiveInt(json, 'size'),
  );
}

UpdateReleaseNotes _parseNotes(Object? value) {
  final json = _object(value, 'notes');
  _allowedKeys(
    json,
    required: const {'release_id'},
    allowed: const {
      'release_id',
      'gitee_url',
      'github_url',
      'cached_markdown_url',
    },
    label: 'notes',
  );
  return UpdateReleaseNotes(
    releaseId: _releaseId(json, 'release_id'),
    giteeUrl: _optionalUri(json, 'gitee_url'),
    githubUrl: _optionalUri(json, 'github_url'),
    cachedMarkdownUrl: _optionalUri(json, 'cached_markdown_url'),
  );
}

UpdateJson _object(Object? value, String label) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('$label 必须是 JSON 对象');
  }
  return Map<String, dynamic>.from(value);
}

void _exactKeys(UpdateJson json, Set<String> expected, String label) {
  final actual = json.keys.toSet();
  if (actual.length != expected.length || !actual.containsAll(expected)) {
    throw FormatException('$label 字段集合与 schema 不一致');
  }
}

void _allowedKeys(
  UpdateJson json, {
  required Set<String> required,
  required Set<String> allowed,
  required String label,
}) {
  final actual = json.keys.toSet();
  if (!actual.containsAll(required) || !allowed.containsAll(actual)) {
    throw FormatException('$label 字段集合与 schema 不一致');
  }
}

String _string(UpdateJson json, String key, {int maxLength = 256}) {
  final value = json[key];
  if (value is! String ||
      value.isEmpty ||
      value.length > maxLength ||
      value.trim() != value) {
    throw FormatException('$key 字段格式无效');
  }
  return value;
}

String _identifier(UpdateJson json, String key) {
  final value = _string(json, key, maxLength: 128);
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value)) {
    throw FormatException('$key 标识格式无效');
  }
  return value;
}

String _lowerIdentifier(UpdateJson json, String key, {int maxLength = 128}) {
  final value = _string(json, key, maxLength: maxLength);
  if (!RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(value)) {
    throw FormatException('$key 标识格式无效');
  }
  return value;
}

String _releaseId(UpdateJson json, String key) {
  final value = _string(json, key, maxLength: 128);
  if (!RegExp(r'^[a-z0-9][a-z0-9._-]{7,127}$').hasMatch(value)) {
    throw FormatException('$key 发布标识格式无效');
  }
  return value;
}

String _androidPlatform(UpdateJson json) {
  final value = _string(json, 'platform', maxLength: 16);
  if (value != 'android') {
    throw const FormatException('清单 platform 必须是 android');
  }
  return value;
}

int _positiveInt(UpdateJson json, String key) {
  final value = json[key];
  if (value is! int || value <= 0) {
    throw FormatException('$key 必须是正整数');
  }
  return value;
}

String _sha256(UpdateJson json, String key) {
  final value = _string(json, key, maxLength: 64).toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw FormatException('$key 必须是 SHA-256 十六进制值');
  }
  return value;
}

List<Object?> _list(UpdateJson json, String key) {
  final value = json[key];
  if (value is! List) throw FormatException('$key 必须是列表');
  return value;
}

Set<String> _stringSet(UpdateJson json, String key) {
  final values = _list(json, key);
  if (values.isEmpty || values.length > 32) {
    throw FormatException('$key 列表为空或过长');
  }
  final result = <String>{};
  for (final value in values) {
    if (value is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value) ||
        !result.add(value)) {
      throw FormatException('$key 包含无效或重复值');
    }
  }
  return Set.unmodifiable(result);
}

List<Uri> _uris(UpdateJson json, String key) {
  final values = _list(json, key);
  if (values.isEmpty) {
    throw FormatException('$key URL 列表为空');
  }
  final seen = <String>{};
  return List.unmodifiable(
    values.map((value) {
      if (value is! String) throw FormatException('$key 包含无效 URL');
      final uri = _httpsUri(value);
      if (!seen.add(uri.toString())) {
        throw FormatException('$key 包含重复 URL');
      }
      return uri;
    }),
  );
}

Uri? _optionalUri(UpdateJson json, String key) {
  if (!json.containsKey(key)) return null;
  final value = json[key];
  if (value is! String) throw FormatException('$key 必须是 HTTPS URL 或 null');
  return _httpsUri(value);
}

Uri _httpsUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw const FormatException('更新地址必须是无账号和片段的 HTTPS URL');
  }
  return uri;
}
