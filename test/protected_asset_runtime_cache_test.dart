import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ryza_chat_mvp/src/protected_asset_runtime_cache.dart';

void main() {
  late Directory root;
  late ProtectedAssetRuntimeCache cache;
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
  final source = 'a' * 64;
  final otherSource = 'b' * 64;
  final files = <String, Uint8List>{
    'character/test.atlas': Uint8List.fromList(<int>[1, 2, 3]),
    'character/test.png': Uint8List.fromList(<int>[4, 5, 6, 7]),
  };

  setUp(() async {
    root = await Directory.systemTemp.createTemp('aar_runtime_cache_');
    cache = ProtectedAssetRuntimeCache(rootDirectory: () async => root);
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<List<File>> cacheFiles() async => <File>[
    await for (final entity in root.list())
      if (entity is File && entity.path.endsWith('.aarcache')) entity,
  ];
  Future<List<File>> stamps() async => <File>[
    await for (final entity in root.list())
      if (entity is File && entity.path.endsWith('.stamp')) entity,
  ];

  Future<Map<String, Uint8List>> load({
    ProtectedAssetRuntimeCache? using,
    String? digest,
    Uint8List? usingKey,
    Future<Map<String, Uint8List>> Function()? decode,
  }) => (using ?? cache).load(
    packId: 'character/test',
    sourceSha256: digest ?? source,
    key: usingKey ?? key,
    decode: decode ?? () async => files,
  );

  Future<void> validate({
    ProtectedAssetRuntimeCache? using,
    String? digest,
    Uint8List? usingKey,
    String version = 'health-v1',
    required Future<void> Function() run,
  }) => (using ?? cache).ensureValidated(
    packId: 'character/test',
    sourceSha256: digest ?? source,
    key: usingKey ?? key,
    validationVersion: version,
    validate: run,
  );

  test('reuses disk container across instances without decoding', () async {
    var calls = 0;
    await load(
      decode: () async {
        calls++;
        return files;
      },
    );
    final second = ProtectedAssetRuntimeCache(rootDirectory: () async => root);
    final restored = await load(
      using: second,
      decode: () async {
        fail('an intact private cache must skip decryption');
      },
    );
    expect(calls, 1);
    expect(restored, files);
    expect(await cacheFiles(), hasLength(1));
    for (final bytes in restored.values) {
      expect(bytes.offsetInBytes, 0);
      expect(bytes.buffer.lengthInBytes, bytes.lengthInBytes);
    }
    final serialized = await (await cacheFiles()).single.readAsBytes();
    expect(_contains(serialized, key), isFalse);
  });

  test(
    'source and key changes invalidate and remove obsolete revisions',
    () async {
      var calls = 0;
      Future<Map<String, Uint8List>> decode() async {
        calls++;
        return files;
      }

      await load(decode: decode);
      final first = (await cacheFiles()).single.path;
      await load(digest: otherSource, decode: decode);
      final second = (await cacheFiles()).single.path;
      expect(second, isNot(first));
      expect(await File(first).exists(), isFalse);
      await load(digest: otherSource, usingKey: Uint8List(32), decode: decode);
      expect(calls, 3);
      expect(await cacheFiles(), hasLength(1));
      expect(await File(second).exists(), isFalse);
    },
  );

  test('same-length corruption is a miss and repaired atomically', () async {
    await load();
    final file = (await cacheFiles()).single;
    final data = await file.readAsBytes();
    data[data.length - 1] ^= 0xff;
    await file.writeAsBytes(data, flush: true);
    var calls = 0;
    expect(
      await load(
        decode: () async {
          calls++;
          return files;
        },
      ),
      files,
    );
    expect(calls, 1);
    expect(
      await load(decode: () async => throw StateError('unexpected')),
      files,
    );
  });

  test(
    'truncated container and interrupted temporary file are ignored',
    () async {
      await load();
      final file = (await cacheFiles()).single;
      final original = await file.readAsBytes();
      final abandoned = File('${file.path}.123.456.0.tmp');
      await abandoned.writeAsBytes(original.sublist(0, 20));
      await file.writeAsBytes(original.sublist(0, 20));
      var calls = 0;
      await load(
        decode: () async {
          calls++;
          return files;
        },
      );
      expect(calls, 1);
      expect(await abandoned.exists(), isFalse);
      expect(await cacheFiles(), hasLength(1));
    },
  );

  test('a copied container cannot impersonate another source', () async {
    await load();
    final previous = await (await cacheFiles()).single.readAsBytes();
    await load(digest: otherSource);
    final target = (await cacheFiles()).single;
    await target.writeAsBytes(previous);
    var calls = 0;
    await load(
      digest: otherSource,
      decode: () async {
        calls++;
        return files;
      },
    );
    expect(calls, 1);
  });

  test('inaccessible root falls back to decode without a retry', () async {
    final blocked = File('${root.path}/blocked');
    await blocked.writeAsString('not a directory');
    final unavailable = ProtectedAssetRuntimeCache(
      rootDirectory: () async => Directory(blocked.path),
    );
    var calls = 0;
    expect(
      await load(
        using: unavailable,
        decode: () async {
          calls++;
          return files;
        },
      ),
      files,
    );
    expect(calls, 1);
    expect(await blocked.readAsString(), 'not a directory');
  });

  test(
    'root-provider exception does not prevent successful decoding',
    () async {
      final unavailable = ProtectedAssetRuntimeCache(
        rootDirectory: () async => throw const FileSystemException('offline'),
      );
      expect(await load(using: unavailable), files);
    },
  );

  test('write failure does not discard an authenticated decode', () async {
    var calls = 0;
    final result = await load(
      decode: () async {
        calls++;
        // Remove the root while the decode is running: writing now fails.
        await root.delete();
        return files;
      },
    );
    expect(result, files);
    expect(calls, 1);
  });

  test('decode failure propagates once and creates no cache', () async {
    var calls = 0;
    await expectLater(
      load(
        decode: () async {
          calls++;
          throw StateError('authentication rejected');
        },
      ),
      throwsStateError,
    );
    expect(calls, 1);
    expect(await cacheFiles(), isEmpty);
    expect(await load(), files);
  });

  test('concurrent requests across instances share one decode', () async {
    final started = Completer<void>();
    final finish = Completer<void>();
    var calls = 0;
    Future<Map<String, Uint8List>> decode() async {
      calls++;
      if (!started.isCompleted) started.complete();
      await finish.future;
      return files;
    }

    final pending = List<Future<Map<String, Uint8List>>>.generate(12, (_) {
      return load(
        using: ProtectedAssetRuntimeCache(rootDirectory: () async => root),
        decode: decode,
      );
    });
    await started.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    finish.complete();
    final results = await Future.wait(pending);
    expect(calls, 1);
    expect(results, everyElement(files));
  });

  test(
    'validation stamps persist independently of decrypted containers',
    () async {
      var calls = 0;
      Future<void> run() async {
        calls++;
      }

      await validate(run: run);
      await validate(
        using: ProtectedAssetRuntimeCache(rootDirectory: () async => root),
        run: run,
      );
      expect(calls, 1);
      expect(await stamps(), hasLength(1));
      expect(await cacheFiles(), isEmpty);
    },
  );

  test(
    'validation source, key and validator versions are independent',
    () async {
      var calls = 0;
      Future<void> run() async {
        calls++;
      }

      await validate(run: run);
      await validate(version: 'health-v2', run: run);
      expect(await stamps(), hasLength(1));
      await validate(digest: otherSource, run: run);
      await validate(digest: otherSource, usingKey: Uint8List(32), run: run);
      expect(calls, 4);
      expect(await stamps(), hasLength(1));
    },
  );

  test('failed validation cannot produce or reuse a success stamp', () async {
    var calls = 0;
    await expectLater(
      validate(
        run: () async {
          calls++;
          throw const FormatException('invalid content');
        },
      ),
      throwsFormatException,
    );
    expect(calls, 1);
    expect(await stamps(), isEmpty);
    await validate(
      run: () async {
        calls++;
      },
    );
    expect(calls, 2);
    expect(await stamps(), hasLength(1));
  });

  test('damaged and partial validation stamps force validation', () async {
    await validate(run: () async {});
    final file = (await stamps()).single;
    final bytes = await file.readAsBytes();
    bytes[0] ^= 0xff;
    await file.writeAsBytes(bytes);
    var calls = 0;
    await validate(
      run: () async {
        calls++;
      },
    );
    await file.writeAsString('AAR_VALIDATED_1');
    await validate(
      run: () async {
        calls++;
      },
    );
    expect(calls, 2);
  });

  test('concurrent validation calls share a single validation', () async {
    final finish = Completer<void>();
    var calls = 0;
    final requests = List<Future<void>>.generate(8, (_) {
      return validate(
        run: () async {
          calls++;
          await finish.future;
        },
      );
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    finish.complete();
    await Future.wait(requests);
    expect(calls, 1);
  });

  test(
    'cache pruning leaves unrelated files and directories untouched',
    () async {
      final unrelated = File('${root.path}/notes.txt');
      await unrelated.writeAsString('keep');
      final nested = await Directory('${root.path}/nested').create();
      final nestedFile = File(
        '${nested.path}/${'a' * 64}_${'b' * 64}.aarcache',
      );
      await nestedFile.writeAsString('keep nested');
      await load();
      await load(digest: otherSource);
      expect(await unrelated.readAsString(), 'keep');
      expect(await nestedFile.readAsString(), 'keep nested');
    },
  );

  test('capacity eviction removes the least recently used container', () async {
    // A sparse old container exercises the real budget without allocating
    // hundreds of megabytes of test-process memory.
    final old = File('${root.path}/${'e' * 64}_${'f' * 64}.aarcache');
    final output = await old.open(mode: FileMode.write);
    await output.truncate(192 * 1024 * 1024);
    await output.close();
    await old.setLastModified(DateTime(2000));
    await load();
    expect(await old.exists(), isFalse);
    expect(await cacheFiles(), hasLength(1));
  });

  test('symlinks are not followed by cache reads or maintenance', () async {
    await load();
    final original = (await cacheFiles()).single;
    final outside = await Directory.systemTemp.createTemp('aar_outside_');
    try {
      final sentinel = File('${outside.path}/sentinel');
      await sentinel.writeAsString('leave outside alone');
      await original.delete();
      final link = Link(original.path);
      try {
        await link.create(sentinel.path);
      } on FileSystemException {
        markTestSkipped('Windows symlink permission is unavailable');
        return;
      }
      var calls = 0;
      expect(
        await load(
          decode: () async {
            calls++;
            return files;
          },
        ),
        files,
      );
      expect(calls, 1);
      expect(await sentinel.readAsString(), 'leave outside alone');
      await load(digest: otherSource);
      expect(
        (await link.target()).replaceAll('\\', '/'),
        sentinel.path.replaceAll('\\', '/'),
      );
      expect(await sentinel.readAsString(), 'leave outside alone');
    } finally {
      await outside.delete(recursive: true);
    }
  });
}

bool _contains(Uint8List haystack, Uint8List needle) {
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var matched = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}
