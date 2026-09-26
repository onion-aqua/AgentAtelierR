import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'protected_asset_format.dart';
import 'local_skin_store.dart';
import 'character_idle_behavior.dart';

class ProtectedCharacterAssetBundle extends CachingAssetBundle {
  ProtectedCharacterAssetBundle(this._files);

  factory ProtectedCharacterAssetBundle.withTexture(
    Map<String, Uint8List> original,
    Uint8List? texture,
  ) {
    // Decrypted packs deliberately expose an immutable map. Never mutate it.
    final files = Map<String, Uint8List>.of(original);
    if (texture != null) {
      final pages = files.keys.where((key) => key.endsWith('.png')).toList();
      if (pages.length != 1) {
        throw FlutterError('Expected one character texture page');
      }
      files[pages.single] = texture;
    }
    return ProtectedCharacterAssetBundle(files);
  }

  final Map<String, Uint8List> _files;

  @override
  Future<ByteData> load(String key) async {
    final normalized = key.replaceAll('\\', '/');
    final bytes = _files[normalized];
    if (bytes == null) {
      throw FlutterError('Protected character asset not found: $normalized');
    }
    return ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
  }
}

class ProtectedCharacterAssets {
  ProtectedCharacterAssets._();

  static const _encodedKey = String.fromEnvironment(
    protectedCharacterAssetKeyDefine,
  );
  static String? _activeAssetName;
  static Future<ProtectedCharacterAssetBundle>? _activeBundle;
  static final Map<String, Future<Uint8List>> _previews = {};

  static Future<ProtectedCharacterAssetBundle> bundleFor(String assetName) {
    if (_activeAssetName == assetName && _activeBundle != null) {
      return _activeBundle!;
    }
    final future = _loadBundle(assetName);
    _activeAssetName = assetName;
    _activeBundle = future;
    return future;
  }

  static Future<Uint8List> previewFor(String assetName) =>
      _previews.putIfAbsent(assetName, () => _loadPreview(assetName));

  static Future<ProtectedCharacterAssetBundle> _loadBundle(
    String assetName,
  ) async {
    final files = await originalFilesFor(assetName);
    final texture = await LocalSkinStore.instance.textureFor(assetName);
    return ProtectedCharacterAssetBundle.withTexture(files, texture);
  }

  static Future<Map<String, Uint8List>> originalFilesFor(
    String assetName,
  ) async {
    final local = await LocalSkinStore.instance.filesFor(assetName);
    if (local != null) {
      final record = LocalSkinStore.instance.skins.firstWhere(
        (skin) => skin['id'] == assetName,
      );
      final base = record['base']!;
      // Restore only known-compatible Ryza rigs from their encrypted base pack.
      if (RegExp(r'^crf_skn_002_000[1-5]_(01|99)$').hasMatch(base)) {
        final reference = await originalFilesFor(base);
        final path =
            'assets/character/ryza/$assetName/${assetName}_gesture.json';
        final basePath = 'assets/character/ryza/$base/${base}_gesture.json';
        local[path] = Uint8List.fromList(
          utf8.encode(
            restoreMissingIdleDrivers(
              utf8.decode(local[path]!),
              utf8.decode(reference[basePath]!),
            ),
          ),
        );
      }
      return local;
    }
    final key = _key();
    final encrypted = await _loadRootBytes(
      'assets/protected/character/$assetName.aarpack',
    );
    final files = await decryptProtectedAssetFiles(
      encrypted: encrypted,
      key: key,
      packId: 'character/$assetName',
    );
    return files;
  }

  static Future<Uint8List> _loadPreview(String assetName) async {
    if (LocalSkinStore.instance.skins.any((skin) => skin['id'] == assetName)) {
      final preview = await LocalSkinStore.instance.previewFor(assetName);
      if (preview == null) {
        throw FlutterError('Local character preview not found: $assetName');
      }
      return preview;
    }
    final key = _key();
    final encrypted = await _loadRootBytes(
      'assets/protected/character/previews/$assetName.aarpreview',
    );
    final files = await decryptProtectedAssetFiles(
      encrypted: encrypted,
      key: key,
      packId: 'preview/$assetName',
    );
    final path = 'assets/images/skins/$assetName.png';
    final preview = files[path];
    if (preview == null) {
      throw FlutterError('Protected character preview not found: $path');
    }
    return preview;
  }

  static Uint8List _key() {
    if (_encodedKey.isEmpty) {
      throw FlutterError(
        'Character resources require a protected build. Run '
        'tool/build_protected.ps1 instead of flutter build directly.',
      );
    }
    return decodeProtectedAssetKey(_encodedKey);
  }

  static Future<Uint8List> _loadRootBytes(String path) async {
    final data = await rootBundle.load(path);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  static void clearCache() {
    _activeAssetName = null;
    _activeBundle = null;
    _previews.clear();
  }
}
