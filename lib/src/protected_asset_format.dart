import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const protectedCharacterAssetKeyDefine = 'AAR_CHARACTER_ASSET_KEY';

const _encryptedMagic = <int>[0x41, 0x41, 0x52, 0x45, 0x4e, 0x43, 0x52, 0x31];
const _plainMagic = <int>[0x41, 0x41, 0x52, 0x50, 0x41, 0x43, 0x4b, 0x31];
const _formatVersion = 1;
const _nonceLength = 12;
const _macLength = 16;

class ProtectedAssetException implements Exception {
  const ProtectedAssetException(this.message);

  final String message;

  @override
  String toString() => 'ProtectedAssetException: $message';
}

Uint8List decodeProtectedAssetKey(String encoded) {
  final normalized = encoded.trim().replaceAll('-', '+').replaceAll('_', '/');
  if (normalized.isEmpty) {
    throw const ProtectedAssetException('The character asset key is missing.');
  }
  final padded = normalized.padRight((normalized.length + 3) ~/ 4 * 4, '=');
  late final Uint8List key;
  try {
    key = base64Decode(padded);
  } on FormatException {
    throw const ProtectedAssetException(
      'The character asset key is not valid Base64.',
    );
  }
  if (key.length != 32) {
    throw ProtectedAssetException(
      'The character asset key must contain 32 bytes, got ${key.length}.',
    );
  }
  return key;
}

Future<Uint8List> encryptProtectedAssetFiles({
  required Map<String, Uint8List> files,
  required Uint8List key,
  required String packId,
  List<int>? nonce,
}) async {
  if (key.length != 32) {
    throw const ProtectedAssetException('AES-256-GCM requires a 32-byte key.');
  }
  final plain = _encodeFiles(files);
  final algorithm = AesGcm.with256bits();
  final box = await algorithm.encrypt(
    plain,
    secretKey: SecretKey(key),
    nonce: nonce,
    aad: utf8.encode(packId),
  );
  if (box.nonce.length != _nonceLength || box.mac.bytes.length != _macLength) {
    throw const ProtectedAssetException('Unexpected AES-GCM output size.');
  }
  final output = BytesBuilder(copy: false)
    ..add(_encryptedMagic)
    ..addByte(_formatVersion)
    ..add(box.nonce)
    ..add(box.mac.bytes)
    ..add(box.cipherText);
  return output.takeBytes();
}

Future<Map<String, Uint8List>> decryptProtectedAssetFiles({
  required Uint8List encrypted,
  required Uint8List key,
  required String packId,
}) async {
  if (key.length != 32) {
    throw const ProtectedAssetException('AES-256-GCM requires a 32-byte key.');
  }
  final headerLength = _encryptedMagic.length + 1 + _nonceLength + _macLength;
  if (encrypted.length <= headerLength ||
      !_startsWith(encrypted, _encryptedMagic)) {
    throw const ProtectedAssetException('Invalid encrypted asset header.');
  }
  if (encrypted[_encryptedMagic.length] != _formatVersion) {
    throw const ProtectedAssetException('Unsupported encrypted asset version.');
  }
  var offset = _encryptedMagic.length + 1;
  final nonce = Uint8List.sublistView(encrypted, offset, offset + _nonceLength);
  offset += _nonceLength;
  final mac = Uint8List.sublistView(encrypted, offset, offset + _macLength);
  offset += _macLength;
  final cipherText = Uint8List.sublistView(encrypted, offset);
  late final List<int> plain;
  try {
    plain = await AesGcm.with256bits().decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: SecretKey(key),
      aad: utf8.encode(packId),
    );
  } on SecretBoxAuthenticationError {
    throw const ProtectedAssetException(
      'Character asset authentication failed. The pack or key is invalid.',
    );
  }
  return _decodeFiles(plain is Uint8List ? plain : Uint8List.fromList(plain));
}

/// Private, on-device cache representation. APK resources still use AES-GCM;
/// callers must authenticate the original pack before persisting this payload.
Uint8List encodeProtectedAssetPayload(Map<String, Uint8List> files) =>
    _encodeFiles(files);

/// Gives each decoded file its own backing buffer for the Spine native bridge.
Map<String, Uint8List> decodeProtectedAssetPayload(Uint8List bytes) =>
    _decodeFiles(bytes);

Uint8List _encodeFiles(Map<String, Uint8List> files) {
  if (files.isEmpty || files.length > 64) {
    throw const ProtectedAssetException(
      'A protected pack must contain between 1 and 64 files.',
    );
  }
  final output = BytesBuilder(copy: false)
    ..add(_plainMagic)
    ..add(_uint32(files.length));
  final names = files.keys.toList()..sort();
  for (final name in names) {
    final normalized = _normalizeName(name);
    final nameBytes = utf8.encode(normalized);
    if (nameBytes.isEmpty || nameBytes.length > 4096) {
      throw ProtectedAssetException('Invalid asset name: $name');
    }
    final bytes = files[name]!;
    output
      ..add(_uint16(nameBytes.length))
      ..add(nameBytes)
      ..add(_uint64(bytes.length))
      ..add(bytes);
  }
  return output.takeBytes();
}

Map<String, Uint8List> _decodeFiles(Uint8List bytes) {
  if (bytes.length < _plainMagic.length + 4 ||
      !_startsWith(bytes, _plainMagic)) {
    throw const ProtectedAssetException('Invalid decrypted asset payload.');
  }
  var offset = _plainMagic.length;
  final count = _readUint32(bytes, offset);
  offset += 4;
  if (count == 0 || count > 64) {
    throw const ProtectedAssetException('Invalid protected asset file count.');
  }
  final files = <String, Uint8List>{};
  for (var index = 0; index < count; index++) {
    _requireRemaining(bytes, offset, 2);
    final nameLength = _readUint16(bytes, offset);
    offset += 2;
    _requireRemaining(bytes, offset, nameLength + 8);
    final name = _normalizeName(
      utf8.decode(Uint8List.sublistView(bytes, offset, offset + nameLength)),
    );
    offset += nameLength;
    final fileLength = _readUint64(bytes, offset);
    offset += 8;
    _requireRemaining(bytes, offset, fileLength);
    if (files.containsKey(name)) {
      throw ProtectedAssetException('Duplicate protected asset: $name');
    }
    // spine_flutter currently reads ByteData.buffer without respecting the
    // view offset. Give every file its own exact backing buffer so an atlas
    // load cannot see adjacent encrypted-pack entries.
    files[name] = Uint8List.fromList(
      Uint8List.sublistView(bytes, offset, offset + fileLength),
    );
    offset += fileLength;
  }
  if (offset != bytes.length) {
    throw const ProtectedAssetException(
      'Unexpected trailing data in protected asset payload.',
    );
  }
  return Map.unmodifiable(files);
}

String _normalizeName(String value) {
  final name = value.replaceAll('\\', '/').trim();
  if (name.isEmpty ||
      name.startsWith('/') ||
      name.contains('../') ||
      name.contains('/..') ||
      name.contains('\u0000')) {
    throw ProtectedAssetException('Unsafe protected asset path: $value');
  }
  return name;
}

bool _startsWith(Uint8List bytes, List<int> expected) {
  if (bytes.length < expected.length) return false;
  for (var index = 0; index < expected.length; index++) {
    if (bytes[index] != expected[index]) return false;
  }
  return true;
}

void _requireRemaining(Uint8List bytes, int offset, int length) {
  if (length < 0 || offset < 0 || offset + length > bytes.length) {
    throw const ProtectedAssetException('Truncated protected asset payload.');
  }
}

Uint8List _uint16(int value) {
  final data = ByteData(2)..setUint16(0, value, Endian.big);
  return data.buffer.asUint8List();
}

Uint8List _uint32(int value) {
  final data = ByteData(4)..setUint32(0, value, Endian.big);
  return data.buffer.asUint8List();
}

Uint8List _uint64(int value) {
  final data = ByteData(8)..setUint64(0, value, Endian.big);
  return data.buffer.asUint8List();
}

int _readUint16(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes, offset, offset + 2).getUint16(0, Endian.big);

int _readUint32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.big);

int _readUint64(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes, offset, offset + 8).getUint64(0, Endian.big);
