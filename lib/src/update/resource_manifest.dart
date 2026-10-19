import 'dart:convert';
import 'dart:typed_data';

import 'resource_integrity.dart';
import 'resource_models.dart';
import 'update_manifest.dart';
import 'update_models.dart';

const maxResourceSnapshotManifestBytes = 8 * 1024 * 1024;
const _maxObjects = 100000;
const _maxObjectBytes = 2 * 1024 * 1024 * 1024;

final class ResourceSnapshotManifestParser {
  const ResourceSnapshotManifestParser();

  Future<ResourceSnapshotManifest> parseAuthenticated({
    required Uint8List bytes,
    required ResourceSnapshot signedSnapshot,
    required int expectedResourceApiVersion,
  }) async {
    if (bytes.length != signedSnapshot.size) {
      throw const ResourceUpdateException(
        'resource_manifest_size_mismatch',
        '资源快照清单大小与签名发布清单不一致',
      );
    }
    final digest = await resourceSha256Bytes(bytes);
    if (digest != signedSnapshot.manifestSha256) {
      throw const ResourceUpdateException(
        'resource_manifest_hash_mismatch',
        '资源快照清单校验失败',
      );
    }
    final manifest = parseCanonical(bytes);
    if (manifest.snapshotId != signedSnapshot.id ||
        manifest.schemaVersion != signedSnapshot.schemaVersion ||
        manifest.assetKeyId != signedSnapshot.assetKeyId ||
        manifest.resourceApiVersion != expectedResourceApiVersion ||
        !_sameSet(
          manifest.compatibleRuntimeIds,
          signedSnapshot.compatibleRuntimeIds,
        )) {
      throw const ResourceUpdateException(
        'resource_manifest_identity_mismatch',
        '资源快照清单与签名发布信息不一致',
      );
    }
    return manifest;
  }

  ResourceSnapshotManifest parseCanonical(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxResourceSnapshotManifestBytes) {
      throw const ResourceUpdateException(
        'invalid_resource_manifest_size',
        '资源快照清单为空或过大',
      );
    }
    late final String source;
    late final Object? decoded;
    try {
      source = utf8.decode(bytes, allowMalformed: false);
      decoded = jsonDecode(source);
    } on Object {
      throw const ResourceUpdateException(
        'invalid_resource_manifest_json',
        '资源快照清单不是有效的 UTF-8 JSON',
      );
    }
    late final String canonical;
    try {
      canonical = canonicalJsonEncode(decoded);
    } on FormatException {
      throw const ResourceUpdateException(
        'invalid_resource_manifest_json',
        '资源快照清单包含不受支持的 JSON 值',
      );
    }
    if (canonical != source) {
      throw const ResourceUpdateException(
        'non_canonical_resource_manifest',
        '资源快照清单没有使用规定的规范化格式',
      );
    }
    try {
      return _parseObject(decoded);
    } on ResourceUpdateException {
      rethrow;
    } on FormatException catch (error) {
      throw ResourceUpdateException(
        'invalid_resource_manifest_schema',
        error.message,
      );
    }
  }

  ResourceSnapshotManifest _parseObject(Object? value) {
    final json = _object(value, 'resource manifest');
    _exactKeys(json, const {
      'asset_key_id',
      'canonicalization',
      'compatible_runtime_ids',
      'objects',
      'resource_api_version',
      'schema_version',
      'snapshot_id',
    });
    final schemaVersion = _positiveInt(json, 'schema_version');
    if (schemaVersion != resourceSnapshotManifestSchemaVersion ||
        json['canonicalization'] != resourceSnapshotCanonicalization) {
      throw const FormatException('资源快照 schema 或规范化协议不受支持');
    }
    final runtimeIds = _identifierSet(json, 'compatible_runtime_ids');
    final values = json['objects'];
    if (values is! List || values.length > _maxObjects) {
      throw const FormatException('objects 必须是长度受限的列表');
    }
    final paths = <String>{};
    final hashSizes = <String, int>{};
    final objects = <ResourceObject>[];
    for (final value in values) {
      final object = _parseResourceObject(value);
      if (!paths.add(object.path)) {
        throw const FormatException('objects 包含重复资源路径');
      }
      final previousSize = hashSizes[object.sha256];
      if (previousSize != null && previousSize != object.size) {
        throw const FormatException('相同资源 hash 不能声明不同大小');
      }
      hashSizes[object.sha256] = object.size;
      objects.add(object);
    }
    return ResourceSnapshotManifest(
      schemaVersion: schemaVersion,
      snapshotId: _identifier(json, 'snapshot_id'),
      resourceApiVersion: _positiveInt(json, 'resource_api_version'),
      compatibleRuntimeIds: runtimeIds,
      assetKeyId: _identifier(json, 'asset_key_id'),
      objects: objects,
    );
  }

  ResourceObject _parseResourceObject(Object? value) {
    final json = _object(value, 'resource object');
    _exactKeys(json, const {'path', 'sha256', 'size', 'urls'});
    final path = _string(json, 'path', maxLength: 512);
    requireSafeResourcePath(path);
    final size = _positiveInt(json, 'size');
    if (size > _maxObjectBytes) {
      throw const FormatException('资源对象超过客户端单文件限制');
    }
    final values = json['urls'];
    if (values is! List || values.isEmpty || values.length > 8) {
      throw const FormatException('资源对象 URL 列表为空或过长');
    }
    final seen = <String>{};
    final urls = <Uri>[];
    for (final value in values) {
      if (value is! String) throw const FormatException('资源对象 URL 无效');
      final uri = requireSecureResourceUri(value);
      if (!seen.add(uri.toString())) {
        throw const FormatException('资源对象 URL 重复');
      }
      urls.add(uri);
    }
    return ResourceObject(
      path: path,
      sha256: _sha256(json, 'sha256'),
      size: size,
      urls: urls,
    );
  }
}

String requireSafeResourcePath(String value) {
  if (value.isEmpty ||
      value.length > 512 ||
      value.startsWith('/') ||
      value.endsWith('/') ||
      value.contains('\\') ||
      value.contains('//') ||
      value.contains(':') ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    throw const FormatException('资源路径格式无效');
  }
  final segments = value.split('/');
  if (segments.any(
    (segment) => segment.isEmpty || segment == '.' || segment == '..',
  )) {
    throw const FormatException('资源路径不能离开受管理目录');
  }
  return value;
}

Uri requireSecureResourceUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw const FormatException('资源对象必须使用无凭据的 HTTPS 地址');
  }
  return uri;
}

Map<String, dynamic> _object(Object? value, String label) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('$label 必须是 JSON 对象');
  }
  return Map<String, dynamic>.from(value);
}

void _exactKeys(Map<String, dynamic> json, Set<String> expected) {
  final actual = json.keys.toSet();
  if (actual.length != expected.length || !actual.containsAll(expected)) {
    throw const FormatException('资源快照字段集合与 schema 不一致');
  }
}

String _string(Map<String, dynamic> json, String key, {int maxLength = 128}) {
  final value = json[key];
  if (value is! String ||
      value.isEmpty ||
      value.length > maxLength ||
      value.trim() != value) {
    throw FormatException('$key 字段格式无效');
  }
  return value;
}

String _identifier(Map<String, dynamic> json, String key) {
  final value = _string(json, key);
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value)) {
    throw FormatException('$key 标识格式无效');
  }
  return value;
}

int _positiveInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value <= 0) {
    throw FormatException('$key 必须是正整数');
  }
  return value;
}

String _sha256(Map<String, dynamic> json, String key) {
  final value = _string(json, key, maxLength: 64).toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw FormatException('$key 必须是 SHA-256 十六进制值');
  }
  return value;
}

Set<String> _identifierSet(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List || value.isEmpty || value.length > 32) {
    throw FormatException('$key 必须是非空且长度受限的列表');
  }
  final result = <String>{};
  for (final item in value) {
    if (item is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(item) ||
        !result.add(item)) {
      throw FormatException('$key 包含无效或重复标识');
    }
  }
  return result;
}

bool _sameSet(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);
