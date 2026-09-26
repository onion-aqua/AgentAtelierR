import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const maxSkinImportBytes = 64 * 1024 * 1024;

/// ZIPs are read into a whitelist, never extracted using archive paths.
Map<String, Uint8List> decodeSkinZip(Uint8List bytes) {
  if (bytes.length > maxSkinImportBytes) {
    throw const FormatException('ZIP exceeds 64 MB');
  }
  final archive = ZipDecoder().decodeBytes(bytes, verify: true);
  final files = <String, Uint8List>{};
  var total = 0;
  if (archive.length > 64) throw const FormatException('Too many ZIP entries');
  for (final entry in archive) {
    final path = entry.name.replaceAll('\\', '/');
    if (path.startsWith('/') ||
        path.contains(':') ||
        path.split('/').contains('..') ||
        entry.isSymbolicLink) {
      throw const FormatException('Unsafe ZIP path');
    }
    if (!entry.isFile) continue;
    total += entry.size;
    if (entry.size < 0 || total > maxSkinImportBytes) {
      throw const FormatException('Expanded ZIP exceeds 64 MB');
    }
    final name = path.split('/').last;
    if (!RegExp(r'^[a-zA-Z0-9_.-]+\.(atlas|png|skel|json)$').hasMatch(name)) {
      continue;
    }
    if (files.containsKey(name)) throw const FormatException('Duplicate file');
    final data = entry.readBytes();
    if (data == null || data.length != entry.size) {
      throw const FormatException('Invalid ZIP entry');
    }
    files[name] = data;
  }
  final atlases = files.keys.where((name) => name.endsWith('.atlas')).toList();
  if (atlases.length != 1) throw const FormatException('Expected one atlas');
  final base = atlases.single.replaceFirst(RegExp(r'\.atlas$'), '');
  for (final suffix in ['.png', '.skel', '_gesture.json']) {
    if (!files.containsKey('$base$suffix')) {
      throw FormatException('Missing $base$suffix');
    }
  }
  final atlas = utf8.decode(files['$base.atlas']!);
  final pages = atlas
      .split(RegExp(r'\r?\n'))
      .where((line) => line.trim().endsWith('.png'))
      .toList();
  if (pages.length != 1 || pages.single.trim() != '$base.png') {
    throw const FormatException('Expected a single matching PNG atlas page');
  }
  final gesture = jsonDecode(utf8.decode(files['${base}_gesture.json']!));
  if (gesture is! Map ||
      gesture['emotionalGesture'] is! Map ||
      gesture['emotionalGesture']['MotionGroups'] is! List) {
    throw const FormatException('Invalid gesture mapping');
  }
  // Spine 4.2 binary header: 8-byte hash followed by varint UTF-8 version.
  final skeleton = files['$base.skel']!;
  if (skeleton.length < 14 ||
      skeleton[8] < 4 ||
      skeleton[8] > 32 ||
      String.fromCharCodes(skeleton.sublist(9, 13)) != '4.2.') {
    throw const FormatException('Only Spine 4.2 skeletons are supported');
  }
  final dimensions = pngSize(files['$base.png']!);
  final declaredSize = RegExp(
    r'^size:\s*(\d+)\s*,\s*(\d+)',
    multiLine: true,
  ).firstMatch(atlas);
  if (declaredSize == null ||
      dimensions !=
          (int.parse(declaredSize[1]!), int.parse(declaredSize[2]!))) {
    throw const FormatException('PNG dimensions do not match the atlas');
  }
  final preview = [
    '${base}_preview.png',
    '$base-preview.png',
    'preview.png',
    'cover.png',
    'thumbnail.png',
  ].where((name) => name != '$base.png' && files.containsKey(name)).firstOrNull;
  if (preview != null) pngSize(files[preview]!);
  return {
    for (final suffix in ['.atlas', '.png', '.skel', '_gesture.json'])
      '$base$suffix': files['$base$suffix']!,
    ?preview: files[preview]!,
  };
}

(int, int) pngSize(Uint8List bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 33 ||
      !listEquals(bytes.take(8).toList(), signature) ||
      String.fromCharCodes(bytes.sublist(12, 16)) != 'IHDR') {
    throw const FormatException('Expected a PNG texture');
  }
  final data = ByteData.sublistView(bytes);
  final width = data.getUint32(16), height = data.getUint32(20);
  if (width == 0 ||
      height == 0 ||
      width > 8192 ||
      height > 8192 ||
      width * height > 33554432) {
    throw const FormatException('Invalid or oversized PNG');
  }
  return (width, height);
}

class LocalSkinStore {
  LocalSkinStore._();
  @visibleForTesting
  factory LocalSkinStore.forTesting() => LocalSkinStore._();
  static final instance = LocalSkinStore._();
  Directory? _root;
  SharedPreferences? _prefs;
  final List<Map<String, String>> skins = [];
  final Map<String, Map<String, dynamic>> _textures = {};

  Future<void> initialize({Directory? storageDirectory}) async {
    if (_root != null) return;
    final directory =
        storageDirectory ?? await getApplicationSupportDirectory();
    _root = await Directory('${directory.path}/imported_skins')
        .create(recursive: true);
    _prefs = await SharedPreferences.getInstance();
    for (final text
        in _prefs!.getStringList('localSkinPackages') ?? <String>[]) {
      try {
        final record = Map<String, String>.from(jsonDecode(text) as Map);
        if (_safe(record['id']!) &&
            _safe(record['base']!) &&
            await File('${_root!.path}/${record['id']}/${record['base']}.skel')
                .exists()) {
          final preview = record['preview'];
          if (preview != null &&
              (!_validPreviewName(preview, record['base']!) ||
                  !await File('${_root!.path}/${record['id']}/$preview')
                      .exists())) {
            record.remove('preview');
          }
          skins.add(record);
        }
      } on Object {
        /* Ignore invalid local metadata; preserve built-in skins. */
      }
    }
    try {
      final saved =
          jsonDecode(_prefs!.getString('localSkinTextures') ?? '{}') as Map;
      for (final entry in saved.entries) {
        final value = Map<String, dynamic>.from(entry.value as Map);
        if (_safe(entry.key as String) && _safe(value['file'] as String)) {
          _textures[entry.key as String] = value;
        }
      }
    } on Object {
      _textures.clear();
    }
  }

  static bool _safe(String name) => RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(name);

  static bool _validPreviewName(String name, String base) =>
      name != '$base.png' &&
      [
        '${base}_preview.png',
        '$base-preview.png',
        'preview.png',
        'cover.png',
        'thumbnail.png',
      ].contains(name);

  Future<Map<String, String>> importPackage(Uint8List bytes) async {
    await initialize();
    final files = await compute(decodeSkinZip, bytes);
    final base = files.keys
        .firstWhere((name) => name.endsWith('.atlas'))
        .split('.')
        .first;
    if (!_safe(base)) throw const FormatException('Invalid skin name');
    final preview = files.keys
        .where((name) => _validPreviewName(name, base))
        .firstOrNull;
    final id = 'local_${DateTime.now().microsecondsSinceEpoch}';
    final folder = await Directory('${_root!.path}/$id').create();
    for (final entry in files.entries) {
      await File('${folder.path}/${entry.key}')
          .writeAsBytes(entry.value, flush: true);
    }
    final record = {
      'id': id,
      'base': base,
      'label': '$base · ${skins.length + 1}',
      'preview': ?preview,
    };
    final next = [...skins, record];
    if (!await _prefs!.setStringList(
      'localSkinPackages',
      next.map(jsonEncode).toList(),
    )) {
      throw const FileSystemException('Could not save skin settings');
    }
    skins.add(record);
    return record;
  }

  Future<Map<String, Uint8List>?> filesFor(String id) async {
    final records = skins.where((record) => record['id'] == id);
    if (records.isEmpty) return null;
    final base = records.first['base']!;
    final root = 'assets/character/ryza/$id';
    final files = <String, Uint8List>{};
    for (final suffix in ['.atlas', '.skel', '_gesture.json']) {
      files['$root/$id$suffix'] = await File('${_root!.path}/$id/$base$suffix')
          .readAsBytes();
    }
    files['$root/$base.png'] = await File('${_root!.path}/$id/$base.png')
        .readAsBytes();
    return files;
  }

  Future<Uint8List?> previewFor(String id) async {
    await initialize();
    final records = skins.where((record) => record['id'] == id);
    if (records.isEmpty) return null;
    final preview = records.first['preview'];
    if (preview == null ||
        !_validPreviewName(preview, records.first['base']!)) {
      return null;
    }
    final file = File('${_root!.path}/$id/$preview');
    return await file.exists() ? file.readAsBytes() : null;
  }

  bool hasTexture(String id) => _textures.containsKey(id);
  bool usesTexture(String id) => _textures[id]?['enabled'] == true;

  Future<void> _deleteUnreferencedTexture(
    String? fileName,
    Map<String, Map<String, dynamic>> records,
  ) async {
    if (fileName == null ||
        !fileName.startsWith('texture_') ||
        !_safe(fileName) ||
        records.values.any((record) => record['file'] == fileName)) {
      return;
    }
    try {
      await File('${_root!.path}/$fileName.png').delete();
    } on FileSystemException {
      // A leftover local file is harmless once no saved texture refers to it.
    }
  }

  Future<void> importTexture(
    String id,
    Uint8List bytes,
    Uint8List original,
  ) async {
    await initialize();
    if (!_safe(id) ||
        bytes.length > maxSkinImportBytes ||
        pngSize(bytes) != pngSize(original)) {
      throw const FormatException(
        'PNG dimensions must match the original texture',
      );
    }
    final previousFile = _textures[id]?['file'] as String?;
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    var file = 'texture_$timestamp';
    var suffix = 1;
    while (await File('${_root!.path}/$file.png').exists()) {
      file = 'texture_${timestamp}_${suffix++}';
    }
    final textureFile = File('${_root!.path}/$file.png');
    await textureFile.writeAsBytes(bytes, flush: true);
    final next = {
      ..._textures,
      id: {'file': file, 'enabled': true},
    };
    try {
      if (!await _prefs!.setString('localSkinTextures', jsonEncode(next))) {
        throw const FileSystemException('Could not save texture settings');
      }
    } on Object {
      await _deleteUnreferencedTexture(file, _textures);
      rethrow;
    }
    _textures[id] = next[id]!;
    await _deleteUnreferencedTexture(previousFile, next);
  }

  Future<bool> deleteTexture(String id) async {
    await initialize();
    final record = _textures[id];
    if (record == null) return false;
    final next = {..._textures}..remove(id);
    if (!await _prefs!.setString('localSkinTextures', jsonEncode(next))) {
      throw const FileSystemException('Could not save texture settings');
    }
    _textures.remove(id);
    await _deleteUnreferencedTexture(record['file'] as String?, next);
    return true;
  }

  Future<void> setTextureEnabled(String id, bool enabled) async {
    if (!hasTexture(id)) return;
    final next = {
      ..._textures,
      id: {..._textures[id]!, 'enabled': enabled},
    };
    if (!await _prefs!.setString('localSkinTextures', jsonEncode(next))) {
      throw const FileSystemException('Could not save texture settings');
    }
    _textures[id] = next[id]!;
  }

  Future<Uint8List?> textureFor(String id) async {
    if (!usesTexture(id)) return null;
    final file = File('${_root!.path}/${_textures[id]!['file']}.png');
    return await file.exists() ? file.readAsBytes() : null;
  }
}
