import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/protected_asset_cache.dart';
import 'package:ryza_chat_mvp/src/protected_asset_format.dart';

void main() {
  test('unchanged content reuses verified bytes; changes and key rotation reencrypt', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'aar-encrypted-cache-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final output = File('${temporary.path}/pack.aarpack');
    final key = Uint8List.fromList(List.filled(32, 5));
    final files = {
      'assets/example.json': Uint8List.fromList([1, 2, 3]),
    };
    Future<Uint8List> prepare(Uint8List key) => prepareCachedProtectedAsset(
      output: output,
      files: files,
      key: key,
      packId: 'test/cache',
    );
    final first = await prepare(key);
    expect(await prepare(key), first);
    files['assets/example.json'] = Uint8List.fromList([1, 2, 4]);
    final changed = await prepare(key);
    expect(changed, isNot(first));
    final rotatedKey = Uint8List.fromList(List.filled(32, 6));
    final rotated = await prepare(rotatedKey);
    expect(rotated, isNot(changed));
    await output.writeAsBytes([0, 1, 2]);
    final repaired = await prepare(rotatedKey);
    expect(
      (await decryptProtectedAssetFiles(
        encrypted: repaired,
        key: rotatedKey,
        packId: 'test/cache',
      ))['assets/example.json'],
      [1, 2, 4],
    );
  });
}
