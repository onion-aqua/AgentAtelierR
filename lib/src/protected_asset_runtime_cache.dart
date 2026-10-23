import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'protected_asset_format.dart';

// These files are derived data in the application's private support directory.
// The encryption key is used only to identify a revision and is never stored.
class ProtectedAssetRuntimeCache {
  ProtectedAssetRuntimeCache({Future<Directory> Function()? rootDirectory})
    : _rootDirectory = rootDirectory ?? _defaultRoot;

  static final instance = ProtectedAssetRuntimeCache();

  final Future<Directory> Function() _rootDirectory;
  static final _loads = <String, Future<Map<String, Uint8List>>>{};
  static final _validations = <String, Future<void>>{};
  static final _maintenance = <String, Future<void>>{};

  static Future<Directory> _defaultRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/protected_character_cache_v1');
  }

  Future<Map<String, Uint8List>> load({
    required String packId,
    required String sourceSha256,
    required Uint8List key,
    required Future<Map<String, Uint8List>> Function() decode,
  }) async {
    final identity = await _identity(packId, sourceSha256, key);
    final root = await _usableRoot();
    if (root == null) return decode();
    final flight = '${root.absolute.path}/${identity.name}';
    final existing = _loads[flight];
    if (existing != null) return existing;
    final pending = _load(root, identity, decode);
    _loads[flight] = pending;
    try {
      return await pending;
    } finally {
      if (identical(_loads[flight], pending)) _loads.remove(flight);
    }
  }

  /// The caller must first verify the actual encrypted source's SHA-256.
  /// A stamp skips content validation only for that source, key and validator.
  Future<void> ensureValidated({
    required String packId,
    required String sourceSha256,
    required Uint8List key,
    required String validationVersion,
    required Future<void> Function() validate,
  }) async {
    final identity = await _identity(packId, sourceSha256, key);
    final validator = await _sha(utf8.encode(validationVersion));
    final root = await _usableRoot();
    if (root == null) return validate();
    final stampName = '${identity.name}_$validator.stamp';
    final flight = '${root.absolute.path}/$stampName';
    final existing = _validations[flight];
    if (existing != null) return existing;
    final pending = _validate(root, identity, stampName, validator, validate);
    _validations[flight] = pending;
    try {
      await pending;
    } finally {
      if (identical(_validations[flight], pending)) {
        _validations.remove(flight);
      }
    }
  }

  Future<Directory?> _usableRoot() async {
    try {
      final root = await _rootDirectory();
      var type = await FileSystemEntity.type(root.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await root.create(recursive: true);
        type = await FileSystemEntity.type(root.path, followLinks: false);
      }
      // Never use a symlink as the cache root.
      return type == FileSystemEntityType.directory ? root : null;
    } on Exception {
      return null;
    }
  }

  Future<Map<String, Uint8List>> _load(
    Directory root,
    _Identity identity,
    Future<Map<String, Uint8List>> Function() decode,
  ) async {
    final path = '${root.path}/${identity.name}.aarcache';
    try {
      final cached = await compute(_readContainer, <String, String>{
        'path': path,
        'identity': identity.digest,
      });
      if (cached != null) return cached;
    } on Exception {
      // Missing, damaged or inaccessible derived data is just a cache miss.
    }

    // Keep this outside cache-I/O catch blocks. A failed authenticated decode
    // must propagate once, without a second generation/decryption attempt.
    final files = await decode();
    try {
      await _serializeMaintenance(root, () async {
        final written = await compute(_writeContainer, <String, Object>{
          'path': path,
          'identity': identity.digest,
          'files': files,
        });
        if (written) {
          await _prune(root, identity);
        }
      });
    } on Exception {
      // Cache storage must never prevent using a successfully decoded pack.
    }
    return files;
  }

  Future<void> _validate(
    Directory root,
    _Identity identity,
    String stampName,
    String validator,
    Future<void> Function() validate,
  ) async {
    final path = '${root.path}/$stampName';
    final expected = 'AAR_VALIDATED_1\n${identity.digest}\n$validator\n';
    try {
      final file = File(path);
      if (await FileSystemEntity.type(path, followLinks: false) ==
              FileSystemEntityType.file &&
          await file.length() == utf8.encode(expected).length &&
          await file.readAsString() == expected) {
        await _touch(file);
        return;
      }
    } on Exception {
      // A partial or inaccessible stamp cannot mark a pack as validated.
    }
    await validate();
    try {
      await _serializeMaintenance(root, () async {
        if (await _atomicWrite(
          path,
          Uint8List.fromList(utf8.encode(expected)),
        )) {
          await _prune(root, identity, keepStamp: stampName);
        }
      });
    } on Exception {
      // The successful validation remains usable even when persistence fails.
    }
  }

  static Future<void> _serializeMaintenance(
    Directory root,
    Future<void> Function() operation,
  ) async {
    final path = root.absolute.path;
    final before = _maintenance[path] ?? Future<void>.value();
    final done = Completer<void>();
    _maintenance[path] = done.future;
    try {
      await before;
      await operation();
    } finally {
      done.complete();
      if (identical(_maintenance[path], done.future)) _maintenance.remove(path);
    }
  }
}

const _cacheMagic = <int>[65, 65, 82, 67, 65, 67, 72, 49];
const _headerLength = 80; // magic + identity SHA-256 + payload SHA-256 + size
const _capacity = 192 * 1024 * 1024;
const _maxPayload = _capacity - _headerLength;
int _temporaryCounter = 0;

class _Identity {
  const _Identity(this.pack, this.digest);
  final String pack;
  final String digest;
  String get name => '${pack}_$digest';
}

Future<_Identity> _identity(
  String packId,
  String sourceSha256,
  Uint8List key,
) async {
  final keyHash = await _sha(Uint8List.fromList(key));
  final pack = await _sha(utf8.encode(packId));
  final digest = await _sha(
    utf8.encode(
      jsonEncode(<String>[
        'protected_character_cache_v1',
        packId,
        sourceSha256.toLowerCase(),
        keyHash,
      ]),
    ),
  );
  return _Identity(pack, digest);
}

Future<String> _sha(List<int> bytes) async =>
    (await Sha256().hash(bytes)).bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

Uint8List _unhex(String value) => Uint8List.fromList(<int>[
  for (var offset = 0; offset < value.length; offset += 2)
    int.parse(value.substring(offset, offset + 2), radix: 16),
]);

Future<Map<String, Uint8List>?> _readContainer(
  Map<String, String> request,
) async {
  final path = request['path']!;
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.file) {
    return null;
  }
  final file = File(path);
  final size = await file.length();
  if (size <= _headerLength || size > _capacity) return null;
  final input = await file.open();
  late final Uint8List bytes;
  try {
    // Bound the allocation even if a file changes after its length was read.
    bytes = await input.read(size);
    if (bytes.length != size || await input.readByte() != -1) return null;
  } finally {
    await input.close();
  }
  for (var index = 0; index < _cacheMagic.length; index++) {
    if (bytes[index] != _cacheMagic[index]) return null;
  }
  final identity = _unhex(request['identity']!);
  for (var index = 0; index < identity.length; index++) {
    if (bytes[8 + index] != identity[index]) return null;
  }
  final length = ByteData.sublistView(bytes).getUint64(72, Endian.big);
  if (length != size - _headerLength || length > _maxPayload) return null;
  final payload = Uint8List.sublistView(bytes, _headerLength);
  final hash = (await Sha256().hash(payload)).bytes;
  for (var index = 0; index < hash.length; index++) {
    if (bytes[40 + index] != hash[index]) return null;
  }
  final files = decodeProtectedAssetPayload(payload);
  await _touch(file);
  return files;
}

Future<bool> _writeContainer(Map<String, Object> request) async {
  final files = request['files']! as Map<String, Uint8List>;
  var size = 12;
  for (final entry in files.entries) {
    size += utf8.encode(entry.key).length + 10 + entry.value.length;
    if (size > _maxPayload) return false;
  }
  final payload = encodeProtectedAssetPayload(files);
  if (payload.length > _maxPayload) return false;
  final header = Uint8List(_headerLength);
  header.setRange(0, 8, _cacheMagic);
  header.setRange(8, 40, _unhex(request['identity']! as String));
  header.setRange(40, 72, (await Sha256().hash(payload)).bytes);
  ByteData.sublistView(header).setUint64(72, payload.length, Endian.big);
  // Stream the header and payload to avoid an extra full-size joined buffer.
  return _atomicWrite(request['path']! as String, header, tail: payload);
}

Future<bool> _atomicWrite(
  String path,
  Uint8List bytes, {
  Uint8List? tail,
}) async {
  final destinationType = await FileSystemEntity.type(path, followLinks: false);
  if (destinationType != FileSystemEntityType.notFound &&
      destinationType != FileSystemEntityType.file) {
    return false;
  }
  final temporary = File(
    '$path.$pid.${DateTime.now().microsecondsSinceEpoch}.${_temporaryCounter++}.tmp',
  );
  try {
    await temporary.create(exclusive: true);
    final output = await temporary.open(mode: FileMode.writeOnly);
    try {
      await output.writeFrom(bytes);
      if (tail != null) await output.writeFrom(tail);
      await output.flush();
    } finally {
      await output.close();
    }
    final currentType = await FileSystemEntity.type(path, followLinks: false);
    if (currentType == FileSystemEntityType.file) {
      await File(path).delete();
    } else if (currentType != FileSystemEntityType.notFound) {
      return false;
    }
    await temporary.rename(path);
    return true;
  } finally {
    if (await FileSystemEntity.type(temporary.path, followLinks: false) ==
        FileSystemEntityType.file) {
      await temporary.delete();
    }
  }
}

Future<void> _touch(File file) async {
  try {
    await file.setLastModified(DateTime.now());
  } on Exception {
    // Read-only support directories can still serve an intact cached pack.
  }
}

Future<void> _prune(
  Directory root,
  _Identity identity, {
  String? keepStamp,
}) async {
  final entries = <({File file, FileStat stat, String name})>[];
  await for (final entity in root.list(followLinks: false)) {
    if (await FileSystemEntity.type(entity.path, followLinks: false) !=
        FileSystemEntityType.file) {
      continue;
    }
    final name = entity.uri.pathSegments.last;
    if (RegExp(
      r'^[a-f0-9]{64}_[a-f0-9]{64}(?:_[a-f0-9]{64}\.stamp|\.aarcache)\.[0-9]+\.[0-9]+\.[0-9]+\.tmp$',
    ).hasMatch(name)) {
      await File(entity.path).delete();
      continue;
    }
    if (!RegExp(
      r'^[a-f0-9]{64}_[a-f0-9]{64}(?:_[a-f0-9]{64}\.stamp|\.aarcache)$',
    ).hasMatch(name)) {
      continue;
    }
    final file = File(entity.path);
    if (name.startsWith('${identity.pack}_') &&
        (!name.startsWith('${identity.name}.') &&
            !name.startsWith('${identity.name}_'))) {
      await file.delete();
      continue;
    }
    if (keepStamp != null &&
        name.startsWith('${identity.name}_') &&
        name != keepStamp) {
      await file.delete();
      continue;
    }
    entries.add((file: file, stat: await file.stat(), name: name));
  }
  var total = entries.fold<int>(0, (sum, entry) => sum + entry.stat.size);
  entries.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
  for (final entry in entries) {
    if (total <= _capacity) break;
    // Check again: a cache directory symlink is never traversed or removed.
    if (await FileSystemEntity.type(entry.file.path, followLinks: false) ==
        FileSystemEntityType.file) {
      await entry.file.delete();
      total -= entry.stat.size;
    }
  }
}
