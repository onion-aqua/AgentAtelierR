import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'update/resource_resolver.dart';

const virtualPhoneWallpaperCatalogPath =
    'assets/data/virtual_phone_wallpapers.json';

const _maxCatalogWallpapers = 64;
const _maxWallpaperBytes = 24 * 1024 * 1024;
const _maxWallpaperEdge = 8192;
const _maxWallpaperPixels = 32000000;

final _catalogId = RegExp(r'^catalog-[a-z0-9][a-z0-9._-]{0,63}$');
final _catalogAssetPath = RegExp(
  r'^assets/images/virtual_phone/wallpapers/'
  r'[A-Za-z0-9][A-Za-z0-9._-]{0,95}\.png$',
);

@immutable
class VirtualPhoneWallpaperCatalogEntry {
  const VirtualPhoneWallpaperCatalogEntry({
    required this.id,
    required this.name,
    required this.assetPath,
  });

  final String id;
  final String name;
  final String assetPath;
}

typedef VirtualPhoneWallpaperCatalogStringLoader = Future<String> Function(
  String path,
);
typedef VirtualPhoneWallpaperCatalogBytesLoader = Future<Uint8List> Function(
  String path,
);

/// Reads the optional hot-update catalogue. A malformed or missing catalogue
/// leaves the three bundled defaults in charge; one missing image only removes
/// that catalogue entry.
Future<List<VirtualPhoneWallpaperCatalogEntry>>
loadVirtualPhoneWallpaperCatalog({
  VirtualPhoneWallpaperCatalogStringLoader? loadString,
  VirtualPhoneWallpaperCatalogBytesLoader? loadBytes,
}) async {
  final resolver = ResourceAssetResolver.instance;
  final stringLoader = loadString ?? resolver.loadString;
  final bytesLoader = loadBytes ?? resolver.loadBytes;
  late final List<VirtualPhoneWallpaperCatalogEntry> entries;
  try {
    entries = parseVirtualPhoneWallpaperCatalog(
      await stringLoader(virtualPhoneWallpaperCatalogPath),
    );
  } on Object {
    return const [];
  }

  final available = <VirtualPhoneWallpaperCatalogEntry>[];
  for (final entry in entries) {
    try {
      final bytes = await bytesLoader(entry.assetPath);
      if (_isSupportedWallpaperPng(bytes)) available.add(entry);
    } on Object {
      // A partially published snapshot must not leave a broken card in UI.
    }
  }
  return List.unmodifiable(available);
}

List<VirtualPhoneWallpaperCatalogEntry> parseVirtualPhoneWallpaperCatalog(
  String source,
) {
  late final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    throw const FormatException('壁纸目录不是有效的 JSON');
  }
  if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
    throw const FormatException('壁纸目录必须是 JSON 对象');
  }
  final json = Map<String, dynamic>.from(decoded);
  _requireExactKeys(json, const {'schema_version', 'wallpapers'});
  if (json['schema_version'] != 1) {
    throw const FormatException('壁纸目录版本不受支持');
  }
  final values = json['wallpapers'];
  if (values is! List || values.length > _maxCatalogWallpapers) {
    throw const FormatException('壁纸目录条目数量无效');
  }

  final ids = <String>{};
  final paths = <String>{};
  final result = <VirtualPhoneWallpaperCatalogEntry>[];
  for (final value in values) {
    if (value is! Map || value.keys.any((key) => key is! String)) {
      throw const FormatException('壁纸目录条目必须是 JSON 对象');
    }
    final item = Map<String, dynamic>.from(value);
    _requireExactKeys(item, const {'id', 'name', 'asset_path'});
    final id = item['id'];
    final name = item['name'];
    final assetPath = item['asset_path'];
    if (id is! String || !_catalogId.hasMatch(id) || !ids.add(id)) {
      throw const FormatException('壁纸目录 ID 无效或重复');
    }
    if (name is! String ||
        name.trim() != name ||
        name.isEmpty ||
        name.runes.length > 80 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const FormatException('壁纸目录名称无效');
    }
    if (assetPath is! String ||
        !_catalogAssetPath.hasMatch(assetPath) ||
        !paths.add(assetPath)) {
      throw const FormatException('壁纸目录资源路径无效或重复');
    }
    result.add(
      VirtualPhoneWallpaperCatalogEntry(
        id: id,
        name: name,
        assetPath: assetPath,
      ),
    );
  }
  return List.unmodifiable(result);
}

bool isVirtualPhoneWallpaperCatalogId(String value) =>
    _catalogId.hasMatch(value);

void _requireExactKeys(Map<String, dynamic> json, Set<String> expected) {
  final actual = json.keys.toSet();
  if (actual.length != expected.length || !actual.containsAll(expected)) {
    throw const FormatException('壁纸目录字段集合无效');
  }
}

bool _isSupportedWallpaperPng(Uint8List bytes) {
  if (bytes.length < 24 || bytes.length > _maxWallpaperBytes) return false;
  const signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
  for (var index = 0; index < signature.length; index++) {
    if (bytes[index] != signature[index]) return false;
  }
  if (bytes[12] != 73 ||
      bytes[13] != 72 ||
      bytes[14] != 68 ||
      bytes[15] != 82) {
    return false;
  }
  final width = _uint32(bytes, 16);
  final height = _uint32(bytes, 20);
  return width > 0 &&
      height > 0 &&
      width <= _maxWallpaperEdge &&
      height <= _maxWallpaperEdge &&
      width * height <= _maxWallpaperPixels;
}

int _uint32(Uint8List bytes, int offset) =>
    bytes[offset] << 24 |
    bytes[offset + 1] << 16 |
    bytes[offset + 2] << 8 |
    bytes[offset + 3];
