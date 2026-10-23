import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../protected_asset_format.dart';
import '../protected_asset_runtime_cache.dart';
import 'resource_models.dart';
import 'resource_store.dart';

typedef ProtectedResourceContentValidator = Future<void> Function(
  Uint8List encrypted,
  Uint8List key,
  String packId,
);

/// Validates resource content after the update manager has authenticated the
/// manifest, checked compatibility, and verified every object's actual SHA-256.
///
/// That ordering is required: a content stamp only authenticates a previous
/// successful validation of the same bytes, pack identity and key. It must never
/// replace verification of the object currently stored on disk.
final class ProductionResourceHealthValidator {
  ProductionResourceHealthValidator({
    this.encodedKey = const String.fromEnvironment(
      protectedCharacterAssetKeyDefine,
    ),
    ProtectedAssetRuntimeCache? cache,
    ProtectedResourceContentValidator? validatePack,
  }) : cache = cache ?? ProtectedAssetRuntimeCache.instance,
       _validatePack = validatePack ?? _validatePackInBackground;

  final String encodedKey;
  final ProtectedAssetRuntimeCache cache;
  final ProtectedResourceContentValidator _validatePack;

  // Increase when the content validation rules change, independently of the
  // decrypted-file cache's storage format.
  static const validationVersion = 'protected-resource-json-v1';

  Future<void> call(
    ResourceSnapshotManifest manifest,
    ResourceSnapshotStore store,
  ) async {
    Uint8List? protectedAssetKey;
    for (final object in manifest.objects) {
      final path = object.path;
      final lowerPath = path.toLowerCase();
      final validateJson = lowerPath.endsWith('.json');
      final validatePack =
          lowerPath.endsWith('.aarpack') || lowerPath.endsWith('.aarpreview');
      if (!validateJson && !validatePack) continue;
      final file = await store.objectFile(object.sha256);
      if (validateJson) {
        await compute(_validateJsonResource, await file.readAsBytes());
        continue;
      }
      if (encodedKey.isEmpty) {
        throw const ResourceUpdateException(
          'resource_asset_key_unavailable',
          '当前应用没有可验证角色资源的内置密钥',
        );
      }
      final key = protectedAssetKey ??= decodeProtectedAssetKey(encodedKey);
      final name = _fileNameWithoutExtension(path);
      final packId = lowerPath.endsWith('.aarpreview')
          ? 'preview/$name'
          : 'character/$name';
      await cache.ensureValidated(
        packId: packId,
        sourceSha256: object.sha256,
        key: key,
        validationVersion: validationVersion,
        validate: () async {
          // A complete snapshot can contain many unused outfits. Validate them
          // off the UI isolate without filling the decrypted-file cache; the
          // character loader persists only outfits the user actually opens.
          await _validatePack(await file.readAsBytes(), key, packId);
        },
      );
    }
  }
}

typedef _PackValidationInput = ({
  Uint8List encrypted,
  Uint8List key,
  String packId,
});

Future<void> _validatePackInBackground(
  Uint8List encrypted,
  Uint8List key,
  String packId,
) => compute(_validateProtectedPack, (
  encrypted: encrypted,
  key: key,
  packId: packId,
));

Future<void> _validateProtectedPack(_PackValidationInput input) async {
  final files = await decryptProtectedAssetFiles(
    encrypted: input.encrypted,
    key: input.key,
    packId: input.packId,
  );
  for (final entry in files.entries) {
    if (entry.key.toLowerCase().endsWith('.json')) {
      _validateJsonResource(entry.value);
    }
  }
}

void _validateJsonResource(List<int> bytes) {
  jsonDecode(utf8.decode(bytes, allowMalformed: false));
}

String _fileNameWithoutExtension(String path) {
  final fileName = path.split('/').last;
  final extension = fileName.lastIndexOf('.');
  return extension <= 0 ? fileName : fileName.substring(0, extension);
}
