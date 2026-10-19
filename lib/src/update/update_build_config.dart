import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../protected_asset_format.dart';
import 'release_source.dart';

const updateConfigBlobDefine = 'AAR_UPDATE_CONFIG_BLOB';
const updateConfigKeyDefine = 'AAR_UPDATE_CONFIG_KEY';
const _packId = 'self-hosted-update-config-v1';
const _entryName = 'update.json';

class UpdateBuildConfig {
  const UpdateBuildConfig.disabled()
    : enabled = false,
      sources = null,
      trustedKeys = const {},
      resourceAssetKeyIds = const {},
      releaseSeq = 0,
      channel = 'stable',
      runtimeCompatId = 'android-bootstrap-v1',
      resourceApiVersion = 1,
      updaterProtocolVersion = 1;

  UpdateBuildConfig({
    required this.sources,
    required this.trustedKeys,
    required this.resourceAssetKeyIds,
    required this.releaseSeq,
    required this.channel,
    required this.runtimeCompatId,
    required this.resourceApiVersion,
    required this.updaterProtocolVersion,
  }) : enabled = true;

  final bool enabled;
  final ReleaseSourceConfig? sources;
  final Map<String, List<int>> trustedKeys;
  final Set<String> resourceAssetKeyIds;
  final int releaseSeq;
  final String channel;
  final String runtimeCompatId;
  final int resourceApiVersion;
  final int updaterProtocolVersion;

  factory UpdateBuildConfig.fromJson(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const FormatException('更新构建配置格式无效');
    }
    final json = Map<String, dynamic>.from(value);
    const keys = {
      'v',
      'gitee_latest_url',
      'cache_latest_url',
      'github_latest_url',
      'trusted_keys',
      'resource_asset_key_ids',
      'release_seq',
      'channel',
      'runtime_compat_id',
      'resource_api_version',
      'updater_protocol_version',
    };
    if (json.keys.toSet().difference(keys).isNotEmpty ||
        json['v'] != 1 ||
        json['release_seq'] is! int ||
        (json['release_seq'] as int) <= 0 ||
        json['channel'] is! String ||
        json['runtime_compat_id'] is! String ||
        json['resource_api_version'] is! int ||
        json['updater_protocol_version'] is! int ||
        json['trusted_keys'] is! Map ||
        json['resource_asset_key_ids'] is! List) {
      throw const FormatException('更新构建配置字段无效');
    }
    final trusted = <String, List<int>>{};
    for (final entry in (json['trusted_keys'] as Map).entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const FormatException('更新公钥配置无效');
      }
      late final Uint8List decoded;
      try {
        decoded = base64.decode(entry.value as String);
      } on FormatException {
        throw const FormatException('更新公钥编码无效');
      }
      if (decoded.length != 32 || base64.encode(decoded) != entry.value) {
        throw const FormatException('更新公钥长度无效');
      }
      trusted[entry.key as String] = List<int>.unmodifiable(decoded);
    }
    if (trusted.isEmpty) throw const FormatException('更新公钥不能为空');
    final resourceAssetKeyIds = <String>{};
    for (final value in json['resource_asset_key_ids'] as List) {
      if (value is! String ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value) ||
          !resourceAssetKeyIds.add(value)) {
        throw const FormatException('资源密钥标识配置无效');
      }
    }
    if (resourceAssetKeyIds.isEmpty || resourceAssetKeyIds.length > 32) {
      throw const FormatException('资源密钥标识不能为空或过多');
    }
    Uri? uri(String key) {
      final raw = json[key];
      if (raw == null) return null;
      if (raw is! String || raw.isEmpty) {
        throw const FormatException('更新来源地址无效');
      }
      return Uri.parse(raw);
    }

    final sources = ReleaseSourceConfig(
      giteeLatest: uri('gitee_latest_url'),
      cachedLatest: uri('cache_latest_url'),
      githubLatest: uri('github_latest_url'),
    );
    if (sources.isEmpty) throw const FormatException('更新来源不能为空');
    final channel = json['channel'] as String;
    final runtimeId = json['runtime_compat_id'] as String;
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$').hasMatch(channel) ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(runtimeId) ||
        (json['resource_api_version'] as int) <= 0 ||
        (json['updater_protocol_version'] as int) <= 0) {
      throw const FormatException('更新兼容配置无效');
    }
    return UpdateBuildConfig(
      sources: sources,
      trustedKeys: Map.unmodifiable(trusted),
      resourceAssetKeyIds: Set.unmodifiable(resourceAssetKeyIds),
      releaseSeq: json['release_seq'] as int,
      channel: channel,
      runtimeCompatId: runtimeId,
      resourceApiVersion: json['resource_api_version'] as int,
      updaterProtocolVersion: json['updater_protocol_version'] as int,
    );
  }

  static Future<UpdateBuildConfig> fromEnvironment() => fromProtectedDefines(
    encrypted: const String.fromEnvironment(updateConfigBlobDefine),
    key: const String.fromEnvironment(updateConfigKeyDefine),
  );

  static Future<UpdateBuildConfig> fromProtectedDefines({
    required String encrypted,
    required String key,
  }) async {
    if (encrypted.isEmpty && key.isEmpty) {
      return const UpdateBuildConfig.disabled();
    }
    try {
      if (encrypted.isEmpty || key.isEmpty || encrypted.length > 131072) {
        throw const FormatException();
      }
      final files = await decryptProtectedAssetFiles(
        encrypted: Uint8List.fromList(base64Url.decode(encrypted)),
        key: decodeProtectedAssetKey(key),
        packId: _packId,
      );
      if (files.length != 1 || !files.containsKey(_entryName)) {
        throw const FormatException();
      }
      return UpdateBuildConfig.fromJson(
        jsonDecode(utf8.decode(files[_entryName]!)),
      );
    } on Object {
      throw const FormatException('内置更新配置无法验证，已停用自动更新，请重新安装正确的构建版本。');
    }
  }
}

Future<Map<String, String>> protectUpdateBuildConfiguration(
  Object? config, {
  Uint8List? key,
}) async {
  UpdateBuildConfig.fromJson(config);
  final secret =
      key ??
      Uint8List.fromList(
        await (await AesGcm.with256bits().newSecretKey()).extractBytes(),
      );
  final encrypted = await encryptProtectedAssetFiles(
    files: {_entryName: Uint8List.fromList(utf8.encode(jsonEncode(config)))},
    key: secret,
    packId: _packId,
  );
  return {
    updateConfigBlobDefine: base64UrlEncode(encrypted),
    updateConfigKeyDefine: base64UrlEncode(secret),
  };
}
