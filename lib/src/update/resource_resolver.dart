import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'resource_manifest.dart';
import 'resource_store.dart';

final class ResourceAssetResolver {
  ResourceAssetResolver({ResourceSnapshotStore? store})
    : store = store ?? ResourceSnapshotStore();

  static final ResourceAssetResolver instance = ResourceAssetResolver();

  final ResourceSnapshotStore store;
  Future<void>? _initializing;
  bool _overlayEnabled = false;

  bool get overlayEnabled => _overlayEnabled;

  void setOverlayEnabled(bool enabled) {
    _overlayEnabled = enabled;
  }

  Future<void> initialize() => _initializing ??= store.initialize();

  Future<void> refreshAfterActivation() async {
    await initialize();
    // The store owns the in-memory pointer and updates it atomically. This
    // method is an explicit lifecycle hook for callers that cache decoded
    // resources above the resolver.
  }

  Future<String?> activeSnapshotId() async {
    if (!_overlayEnabled) return null;
    try {
      await initialize();
      return store.activeReference?.snapshotId;
    } on Object {
      return null;
    }
  }

  Future<bool> isOverridden(String path) async {
    requireSafeResourcePath(path);
    if (!_overlayEnabled) return false;
    try {
      await initialize();
      final manifest = await store.activeManifest();
      return manifest?.objectsByPath.containsKey(path) ?? false;
    } on Object {
      return false;
    }
  }

  Future<File?> resolveActiveFile(String path) async {
    requireSafeResourcePath(path);
    if (!_overlayEnabled) return null;
    try {
      await initialize();
      return await store.resolveActiveFile(path);
    } on Object {
      return null;
    }
  }

  Future<Uint8List> loadBytes(String path, {AssetBundle? fallback}) async {
    requireSafeResourcePath(path);
    if (_overlayEnabled) {
      try {
        await initialize();
        final active = await store.readActiveAsset(path);
        if (active != null) return active;
      } on Object {
        // A corrupt hot object never reaches the caller. The bundled asset is
        // the safe minimum version until startup health recovery rolls back.
      }
    }
    final data = await (fallback ?? rootBundle).load(path);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<ByteData> load(String path, {AssetBundle? fallback}) async {
    final bytes = await loadBytes(path, fallback: fallback);
    return ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
  }

  Future<String> loadString(String path, {AssetBundle? fallback}) async =>
      utf8.decode(await loadBytes(path, fallback: fallback));
}

/// AssetBundle adapter for widgets that resolve images and JSON through a
/// DefaultAssetBundle. Decoded image caches remain owned by Flutter, so callers
/// should rebuild or restart a scene after activating a new snapshot.
final class ResourceOverlayAssetBundle extends CachingAssetBundle {
  ResourceOverlayAssetBundle({
    ResourceAssetResolver? resolver,
    AssetBundle? fallback,
  }) : resolver = resolver ?? ResourceAssetResolver.instance,
       fallback = fallback ?? rootBundle;

  final ResourceAssetResolver resolver;
  final AssetBundle fallback;

  @override
  Future<ByteData> load(String key) => resolver.load(key, fallback: fallback);

  @override
  Future<String> loadString(String key, {bool cache = true}) =>
      resolver.loadString(key, fallback: fallback);
}
