import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ryza_chat_mvp/src/protected_asset_format.dart';
import 'package:ryza_chat_mvp/src/protected_asset_cache.dart';
import 'package:ryza_chat_mvp/src/character_idle_behavior.dart';
import 'package:ryza_chat_mvp/src/update/resource_integrity.dart';

Future<void> main(List<String> arguments) async {
  final project = Directory.current.absolute;
  final pubspec = File('${project.path}${Platform.pathSeparator}pubspec.yaml');
  if (!pubspec.existsSync()) {
    stderr.writeln('Run this tool from the Flutter project root.');
    exitCode = 64;
    return;
  }

  final keyFile = File(
    _argument(arguments, '--key-file') ??
        '${project.path}${Platform.pathSeparator}.asset_protection'
            '${Platform.pathSeparator}character_assets.key',
  );
  final key = await _loadOrCreateKey(keyFile);
  final sourceRoot = Directory(
    '${project.path}${Platform.pathSeparator}assets'
    '${Platform.pathSeparator}character${Platform.pathSeparator}ryza',
  );
  final previewRoot = Directory(
    '${project.path}${Platform.pathSeparator}assets'
    '${Platform.pathSeparator}images${Platform.pathSeparator}skins',
  );
  final outputRoot = Directory(
    '${project.path}${Platform.pathSeparator}assets'
    '${Platform.pathSeparator}protected${Platform.pathSeparator}character',
  );
  final previewOutput = Directory(
    '${outputRoot.path}${Platform.pathSeparator}previews',
  );
  await outputRoot.create(recursive: true);
  await previewOutput.create(recursive: true);

  final sourceDirectories =
      sourceRoot.listSync(followLinks: false).whereType<Directory>().where((
        directory,
      ) {
        final name = _baseName(directory.path);
        return File('${directory.path}${Platform.pathSeparator}$name.skel')
            .existsSync();
      }).toList()..sort((left, right) => left.path.compareTo(right.path));
  if (sourceDirectories.isEmpty) {
    throw StateError(
      'No character source directories were found under ${sourceRoot.path}.',
    );
  }

  final expectedOutputs = <String>{};
  final runtimeIndex = <String, Object>{};
  var sourceBytes = 0;
  var encryptedBytes = 0;
  for (final directory in sourceDirectories) {
    final name = _baseName(directory.path);
    final files = <String, Uint8List>{};
    for (final suffix in <String>['.atlas', '.png', '.skel', '_gesture.json']) {
      final file = File(
        '${directory.path}${Platform.pathSeparator}$name$suffix',
      );
      if (!file.existsSync()) {
        throw StateError('Required character source is missing: ${file.path}');
      }
      var bytes = await file.readAsBytes();
      if (suffix == '_gesture.json') {
        final posture = name.endsWith('_99') ? 'standing' : 'seated';
        final reference = File(
          '${sourceRoot.path}/idle_references/$posture.json',
        );
        if (reference.existsSync()) {
          final source = utf8.decode(bytes);
          final restored = restoreMissingIdleDrivers(
            source,
            await reference.readAsString(),
          );
          if (restored != source) {
            bytes = Uint8List.fromList(utf8.encode(restored));
            stdout.writeln('Restored missing local idle drivers: $name');
          }
        }
      }
      sourceBytes += bytes.length;
      files[_assetPath(project, file)] = bytes;
    }
    final output = File(
      '${outputRoot.path}${Platform.pathSeparator}$name.aarpack',
    );
    final encrypted = await prepareCachedProtectedAsset(
      output: output,
      files: files,
      key: key,
      packId: 'character/$name',
    );
    await _verifyPack(
      encrypted: encrypted,
      expected: files,
      key: key,
      packId: 'character/$name',
    );
    expectedOutputs.add(output.absolute.path.toLowerCase());
    runtimeIndex[_assetPath(project, output)] = {
      'sha256': await resourceSha256Bytes(encrypted),
      'size': encrypted.length,
    };
    encryptedBytes += encrypted.length;

    final preview = File(
      '${previewRoot.path}${Platform.pathSeparator}$name.png',
    );
    if (preview.existsSync()) {
      final previewBytes = await preview.readAsBytes();
      final texture = files['assets/character/ryza/$name/$name.png']!;
      if (!_sameBytes(previewBytes, texture)) {
        sourceBytes += previewBytes.length;
        final previewTarget = File(
          '${previewOutput.path}${Platform.pathSeparator}$name.aarpreview',
        );
        final protectedPreview = await prepareCachedProtectedAsset(
          output: previewTarget,
          files: {_assetPath(project, preview): previewBytes},
          key: key,
          packId: 'preview/$name',
        );
        await _verifyPack(
          encrypted: protectedPreview,
          expected: {_assetPath(project, preview): previewBytes},
          key: key,
          packId: 'preview/$name',
        );
        expectedOutputs.add(previewTarget.absolute.path.toLowerCase());
        runtimeIndex[_assetPath(project, previewTarget)] = {
          'sha256': await resourceSha256Bytes(protectedPreview),
          'size': protectedPreview.length,
        };
        encryptedBytes += protectedPreview.length;
      } else {
        stdout.writeln('Skipped atlas texture used as preview: $name');
      }
    } else {
      stdout.writeln('No optional preview found: $name');
    }
  }

  // This small index is regenerated with every protected build. Its digests
  // remain stable across code-only updates, so private decoded caches survive
  // APK replacement without trusting a version number or just a skin name.
  final indexFile = File(
    '${outputRoot.path}${Platform.pathSeparator}index.json',
  );
  final temporaryIndex = File('${indexFile.path}.tmp');
  await temporaryIndex.writeAsString(
    jsonEncode({'schema_version': 1, 'objects': runtimeIndex}),
    flush: true,
  );
  await temporaryIndex.rename(indexFile.path);
  expectedOutputs.add(indexFile.absolute.path.toLowerCase());

  for (final entity in outputRoot.listSync(recursive: true)) {
    if (entity is! File) continue;
    final lower = entity.absolute.path.toLowerCase();
    if (!expectedOutputs.contains(lower)) {
      await entity.delete();
    }
  }

  stdout.writeln(
    'Protected ${sourceDirectories.length} character sets '
    '(${_megabytes(sourceBytes)} MB source -> '
    '${_megabytes(encryptedBytes)} MB encrypted).',
  );
  stdout.writeln('Local key: ${keyFile.absolute.path}');
}

Future<Uint8List> _loadOrCreateKey(File file) async {
  if (file.existsSync()) {
    return decodeProtectedAssetKey(await file.readAsString());
  }
  await file.parent.create(recursive: true);
  final random = Random.secure();
  final key = Uint8List.fromList(
    List<int>.generate(32, (_) => random.nextInt(256)),
  );
  final encoded = base64UrlEncode(key).replaceAll('=', '');
  await file.writeAsString('$encoded\n', flush: true);
  return key;
}

Future<void> _verifyPack({
  required Uint8List encrypted,
  required Map<String, Uint8List> expected,
  required Uint8List key,
  required String packId,
}) async {
  final restored = await decryptProtectedAssetFiles(
    encrypted: encrypted,
    key: key,
    packId: packId,
  );
  if (restored.length != expected.length) {
    throw StateError('Protected pack verification failed: $packId');
  }
  for (final entry in expected.entries) {
    final actual = restored[entry.key];
    if (actual == null || !_sameBytes(actual, entry.value)) {
      throw StateError(
        'Protected pack verification failed: $packId / ${entry.key}',
      );
    }
  }
}

bool _sameBytes(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

String? _argument(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0) return null;
  if (index + 1 >= arguments.length) {
    throw FormatException('$name requires a value.');
  }
  return arguments[index + 1];
}

String _assetPath(Directory project, File file) {
  final prefix = '${project.path}${Platform.pathSeparator}';
  final absolute = file.absolute.path;
  if (!absolute.toLowerCase().startsWith(prefix.toLowerCase())) {
    throw StateError('Asset is outside the project: $absolute');
  }
  return absolute.substring(prefix.length).replaceAll('\\', '/');
}

String _baseName(String path) =>
    path.replaceAll('\\', '/').split('/').where((part) => part.isNotEmpty).last;

String _megabytes(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);
