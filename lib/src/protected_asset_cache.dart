import 'dart:io';
import 'dart:typed_data';

import 'protected_asset_format.dart';

/// Reuses ciphertext only after decrypting and comparing its complete content
/// under the current key, format and pack identity. Changed content or keys use
/// fresh random AES-GCM nonces through the standard encoder.
Future<Uint8List> prepareCachedProtectedAsset({
  required File output,
  required Map<String, Uint8List> files,
  required Uint8List key,
  required String packId,
}) async {
  try {
    final existing = await output.readAsBytes();
    final decoded = await decryptProtectedAssetFiles(
      encrypted: existing,
      key: key,
      packId: packId,
    );
    if (_sameFiles(decoded, files)) return existing;
  } on Object {
    // Missing, damaged, obsolete-format and differently keyed objects are
    // regenerated. An unchecked cached ciphertext is never reused.
  }
  final encrypted = await encryptProtectedAssetFiles(
    files: files,
    key: key,
    packId: packId,
  );
  final decoded = await decryptProtectedAssetFiles(
    encrypted: encrypted,
    key: key,
    packId: packId,
  );
  if (!_sameFiles(decoded, files)) {
    throw const ProtectedAssetException(
      'Encrypted asset cache verification failed.',
    );
  }
  await output.parent.create(recursive: true);
  final temporary = File(
    '${output.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  try {
    await temporary.writeAsBytes(encrypted, flush: true);
    await temporary.rename(output.path);
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
  return encrypted;
}

bool _sameFiles(Map<String, Uint8List> left, Map<String, Uint8List> right) {
  if (left.length != right.length) return false;
  for (final entry in right.entries) {
    final bytes = left[entry.key];
    if (bytes == null || bytes.length != entry.value.length) return false;
    for (var index = 0; index < bytes.length; index++) {
      if (bytes[index] != entry.value[index]) return false;
    }
  }
  return true;
}
