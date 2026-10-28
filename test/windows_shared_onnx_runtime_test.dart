import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String? _cmakeExecutable() {
  final configured = Platform.environment['CMAKE_EXE'];
  if (configured != null && File(configured).existsSync()) return configured;
  final cache = File('build/windows/x64/CMakeCache.txt');
  if (cache.existsSync()) {
    final match = RegExp(
      r'^CMAKE_COMMAND:INTERNAL=(.+)$',
      multiLine: true,
    ).firstMatch(cache.readAsStringSync());
    final path = match?.group(1)?.trim();
    if (path != null && File(path).existsSync()) return path;
  }
  try {
    if (Process.runSync('cmake', ['--version']).exitCode == 0) return 'cmake';
  } on ProcessException {
    // Source-only environments do not necessarily contain the Windows SDK.
  }
  return null;
}

void main() {
  final cmake = _cmakeExecutable();
  final unavailable = cmake == null ? 'CMake is not installed' : false;
  late Directory fixture;

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('shared ort fixture ');
    for (final path in [
      'embedding/onnxruntime.dll',
      'sherpa/onnxruntime.dll',
      'sherpa/onnxruntime_providers_shared.dll',
      'sherpa/sherpa-onnx-c-api.dll',
      'unrelated/other.dll',
      'conflict/onnxruntime.dll',
    ]) {
      final file = File('${fixture.path}/$path');
      await file.parent.create(recursive: true);
      await file.writeAsString('fixture');
    }
  });
  tearDown(() => fixture.delete(recursive: true));

  Future<ProcessResult> select({
    bool conflict = false,
    bool noRuntime = false,
  }) async {
    final directory = fixture.path.replaceAll(r'\', '/');
    final module = File('windows/shared_onnx_runtime.cmake').absolute.path
        .replaceAll(r'\', '/');
    const sherpaList = r'${sherpa_onnx_windows_bundled_libraries}';
    const selectedList = r'${selected}';
    final script = File('${fixture.path}/select.cmake');
    await script.writeAsString('''
cmake_minimum_required(VERSION 3.14)
include([[$module]])
set(onnxruntime_bundled_libraries [[$directory/embedding/onnxruntime.dll]])
set(sherpa_onnx_windows_bundled_libraries
  [[$directory/sherpa/sherpa-onnx-c-api.dll]]
  ${noRuntime ? '' : '[[$directory/sherpa/onnxruntime.dll]]'})
set(PLUGIN_BUNDLED_LIBRARIES
  [[$directory/embedding/onnxruntime.dll]]
  [[$directory/unrelated/other.dll]]
  $sherpaList
  ${conflict ? '[[$directory/conflict/onnxruntime.dll]]' : ''})
aar_select_shared_onnx_runtime(selected)
file(WRITE [[$directory/selected.txt]] "$selectedList")
''');
    return Process.run(cmake!, ['-P', script.path]);
  }

  test(
    'both model users bundle exactly the Sherpa runtime and provider DLL',
    () async {
      final result = await select();
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      final paths = (await File(
        '${fixture.path}/selected.txt',
      ).readAsString()).split(';');
      expect(paths, hasLength(4));
      expect(
        paths.where((path) => path.endsWith('/onnxruntime.dll')),
        hasLength(1),
      );
      expect(paths.any((path) => path.contains('/embedding/')), isFalse);
      expect(
        paths.any((path) => path.endsWith('/sherpa/onnxruntime.dll')),
        isTrue,
      );
      expect(
        paths.any((path) => path.endsWith('/onnxruntime_providers_shared.dll')),
        isTrue,
      );
      expect(
        paths.any((path) => path.endsWith('/sherpa-onnx-c-api.dll')),
        isTrue,
      );
      expect(paths.any((path) => path.endsWith('/other.dll')), isTrue);
    },
    skip: unavailable,
  );

  test(
    'missing provider support fails instead of packaging an incomplete runtime',
    () async {
      await File('${fixture.path}/sherpa/onnxruntime_providers_shared.dll')
          .delete();
      final result = await select();
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('provider support DLL is missing'));
    },
    skip: unavailable,
  );

  test(
    'unknown same-name DLL fails instead of relying on copy order',
    () async {
      final result = await select(conflict: true);
      expect(result.exitCode, isNot(0));
      expect(
        result.stderr,
        contains('Unexpected conflicting ONNX Runtime DLL'),
      );
    },
    skip: unavailable,
  );

  test(
    'missing Sherpa runtime cannot silently select the older embedding DLL',
    () async {
      final result = await select(noRuntime: true);
      expect(result.exitCode, isNot(0));
      expect(
        result.stderr,
        contains('Expected exactly one Sherpa ONNX Runtime DLL'),
      );
    },
    skip: unavailable,
  );
}
