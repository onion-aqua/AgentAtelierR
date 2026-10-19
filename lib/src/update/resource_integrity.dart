import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

Future<String> resourceSha256Bytes(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  return _hex(digest.bytes);
}

Future<String> resourceSha256File(File file) async {
  final sink = Sha256().toSync().newHashSink();
  await for (final chunk in file.openRead()) {
    sink.add(chunk);
  }
  sink.close();
  return _hex((await sink.hash()).bytes);
}

Future<bool> resourceFileMatches(
  File file, {
  required int size,
  required String sha256,
}) async {
  if (!await file.exists() || await file.length() != size) return false;
  return await resourceSha256File(file) == sha256.toLowerCase();
}

Uint8List resourceBytesCopy(List<int> bytes) => Uint8List.fromList(bytes);

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
