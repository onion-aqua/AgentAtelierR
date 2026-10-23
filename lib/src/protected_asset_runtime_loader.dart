import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'protected_asset_format.dart';
import 'protected_asset_runtime_cache.dart';
import 'runtime_log.dart';
import 'update/resource_integrity.dart';
import 'update/resource_resolver.dart';

const protectedAssetIndexPath = 'assets/protected/character/index.json';

/// Uses an APK-owned content index to find private decoded data without reading
/// the large encrypted APK entry again. Hot objects use their verified digest.
class ProtectedAssetRuntimeLoader {
  ProtectedAssetRuntimeLoader({
    AssetBundle? bundledAssets,
    ResourceAssetResolver? resolver,
    ProtectedAssetRuntimeCache? cache,
  }) : _bundledAssets = bundledAssets ?? rootBundle,
       _resolver = resolver ?? ResourceAssetResolver.instance,
       _cache = cache ?? ProtectedAssetRuntimeCache.instance;

  final AssetBundle _bundledAssets;
  final ResourceAssetResolver _resolver;
  final ProtectedAssetRuntimeCache _cache;
  Future<Map<String, dynamic>>? _index;

  Future<Map<String, Uint8List>> load({
    required String path,
    required String packId,
    required Uint8List key,
  }) async {
    if (key.length != 32) {
      throw const ProtectedAssetException(
        'AES-256-GCM requires a 32-byte key.',
      );
    }
    final timer = Stopwatch()..start();
    // resolveActiveFile verifies the real object against the authenticated hot
    // manifest. A corrupt overlay falls back to the APK, never its old cache.
    final active = await _resolver.resolveActiveFile(path);
    String? digest;
    int? size;
    if (active != null) {
      final name = active.uri.pathSegments.last;
      if (RegExp(r'^[a-f0-9]{64}$').hasMatch(name)) digest = name;
    } else {
      final index = await (_index ??= _loadIndex());
      final entry = index[path];
      if (entry is Map &&
          entry['sha256'] is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(entry['sha256'] as String) &&
          entry['size'] is int &&
          (entry['size'] as int) > 0) {
        digest = entry['sha256'] as String;
        size = entry['size'] as int;
      }
    }

    Future<Uint8List> readEncrypted() async {
      if (active != null) return active.readAsBytes();
      final data = await _bundledAssets.load(path);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }

    // Compatibility with older packages that did not contain an index. They
    // still avoid AES on a hit, but must read/hash ciphertext to identify it.
    Uint8List? encrypted;
    if (digest == null) {
      encrypted = await readEncrypted();
      digest = await compute(resourceSha256Bytes, encrypted);
    }
    final sourceDigest = digest!;
    var decoded = false;
    final files = await _cache.load(
      packId: packId,
      sourceSha256: sourceDigest,
      key: key,
      decode: () async {
        decoded = true;
        return compute(_decryptVerifiedPack, (
          encrypted: encrypted ?? await readEncrypted(),
          key: key,
          packId: packId,
          digest: sourceDigest,
          size: size,
        ));
      },
    );
    RuntimeLog.instance.info(
      'CharacterAssets',
      '角色资源 $packId：${decoded ? '首次解密或缓存重建' : '私有磁盘缓存命中'}，'
          '${timer.elapsedMilliseconds}ms',
    );
    return files;
  }

  Future<Map<String, dynamic>> _loadIndex() async {
    try {
      // This index must come from the signed APK, not a resource overlay.
      final decoded = jsonDecode(
        await _bundledAssets.loadString(protectedAssetIndexPath),
      );
      if (decoded is Map &&
          decoded['schema_version'] == 1 &&
          decoded['objects'] is Map) {
        return Map<String, dynamic>.from(decoded['objects'] as Map);
      }
    } on Object {
      // Missing/old indexes use ciphertext identity instead.
    }
    return const {};
  }
}

Future<Map<String, Uint8List>> _decryptVerifiedPack(
  ({
    Uint8List encrypted,
    Uint8List key,
    String packId,
    String digest,
    int? size,
  })
  request,
) async {
  if ((request.size != null && request.encrypted.length != request.size) ||
      await resourceSha256Bytes(request.encrypted) != request.digest) {
    throw const ProtectedAssetException('Protected asset index mismatch.');
  }
  return decryptProtectedAssetFiles(
    encrypted: request.encrypted,
    key: request.key,
    packId: request.packId,
  );
}
