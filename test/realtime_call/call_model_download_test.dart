import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/realtime_call/call_model_download.dart';
import 'package:ryza_chat_mvp/src/realtime_call/local_call_asr_config.dart';
import 'package:ryza_chat_mvp/src/update/resource_integrity.dart';

void main() {
  late Directory support;
  late List<int> archiveBytes;
  late List<CallModelArtifact> artifacts;
  const previous = LocalCallAsrConfig(
    modelPath: '/keep/model.onnx',
    tokensPath: '/keep/tokens.txt',
    vadModelPath: '/keep/vad.onnx',
    language: 'ja',
    silenceSeconds: .8,
  );

  List<int> packed(Iterable<ArchiveFile> files) {
    final archive = Archive();
    for (final file in files) {
      archive.add(file);
    }
    return BZip2Encoder().encodeBytes(TarEncoder().encode(archive));
  }

  setUp(() async {
    support = await Directory.systemTemp.createTemp('call-download-test-');
    archiveBytes = packed([
      ArchiveFile.bytes('bundle/model.int8.onnx', [1, 2, 3, 4]),
      ArchiveFile.string('bundle/tokens.txt', '<blank> 0\n'),
      ArchiveFile.string('bundle/README.md', 'do not install'),
    ]);
    artifacts = [
      CallModelArtifact(
        name: 'model.tar.bz2',
        bytes: archiveBytes.length,
        sha256: await resourceSha256Bytes(archiveBytes),
        url: Uri.parse('https://official.test/model.tar.bz2'),
      ),
      CallModelArtifact(
        name: 'silero_vad.onnx',
        bytes: 3,
        sha256: await resourceSha256Bytes([5, 6, 7]),
        url: Uri.parse('https://official.test/silero_vad.onnx'),
      ),
    ];
  });
  tearDown(() async {
    if (await support.exists()) await support.delete(recursive: true);
  });

  test(
    'Gitee exact-name assets are preferred, extracted and hash checked',
    () async {
      final requested = <String>[];
      final downloader = CallAsrModelDownloader(
        directoryProvider: () async => support,
        artifacts: artifacts,
        clientFactory: () => MockClient((request) async {
          requested.add(request.url.toString());
          if (request.url.host == 'gitee.com') {
            return http.Response(
              jsonEncode([
                {
                  'assets': [
                    for (final artifact in artifacts)
                      {
                        'name': artifact.name,
                        'browser_download_url':
                            'https://mirror.test/${artifact.name}',
                      },
                    {
                      'name': 'another-model.tar.bz2',
                      'browser_download_url': 'https://wrong.test/other',
                    },
                  ],
                },
              ]),
              200,
            );
          }
          return http.Response.bytes(
            request.url.path.endsWith('.bz2') ? archiveBytes : [5, 6, 7],
            200,
          );
        }),
      );
      final installed = await downloader.install(previous: previous);
      expect(requested, hasLength(3));
      expect(
        requested
            .skip(1)
            .every((url) => url.startsWith('https://mirror.test/')),
        isTrue,
      );
      expect(await File(installed.modelPath).readAsBytes(), [1, 2, 3, 4]);
      expect(await File(installed.tokensPath).readAsString(), '<blank> 0\n');
      expect(await File(installed.vadModelPath).readAsBytes(), [5, 6, 7]);
      expect(installed.language, 'ja');
      expect(installed.silenceSeconds, .8);
      expect(
        (await support.list(recursive: true).toList()).whereType<File>().length,
        3,
      );
    },
  );

  test('missing Gitee assets clearly fall back to official source', () async {
    final requested = <String>[];
    final messages = <String>[];
    final downloader = CallAsrModelDownloader(
      directoryProvider: () async => support,
      artifacts: artifacts,
      clientFactory: () => MockClient((request) async {
        requested.add(request.url.host);
        if (request.url.host == 'gitee.com') return http.Response('[]', 200);
        return http.Response.bytes(
          request.url.path.endsWith('.bz2') ? archiveBytes : [5, 6, 7],
          200,
        );
      }),
    );
    await downloader.install(
      previous: previous,
      onProgress: (p) => messages.add(p.message),
    );
    expect(requested, ['gitee.com', 'official.test', 'official.test']);
    expect(messages.any((m) => m.contains('Gitee 暂无匹配资源')), isTrue);
  });

  test('corrupt mirror is discarded before official fallback', () async {
    final requested = <String>[];
    final downloader = CallAsrModelDownloader(
      directoryProvider: () async => support,
      artifacts: artifacts,
      clientFactory: () => MockClient((request) async {
        requested.add(request.url.host);
        if (request.url.host == 'gitee.com') {
          return http.Response(
            jsonEncode([
              {
                'assets': [
                  {
                    'name': artifacts.first.name,
                    'browser_download_url': 'https://mirror.test/model.tar.bz2',
                  },
                ],
              },
            ]),
            200,
          );
        }
        if (request.url.host == 'mirror.test') {
          return http.Response.bytes(
            List<int>.filled(archiveBytes.length, 1),
            200,
          );
        }
        return http.Response.bytes(
          request.url.path.endsWith('.bz2') ? archiveBytes : [5, 6, 7],
          200,
        );
      }),
    );
    final installed = await downloader.install(previous: previous);
    expect(requested, [
      'gitee.com',
      'mirror.test',
      'official.test',
      'official.test',
    ]);
    expect(await File(installed.modelPath).readAsBytes(), [1, 2, 3, 4]);
  });

  test(
    'failed second download cleans staging and preserves existing model',
    () async {
      final old = File('${support.path}/keep-model.onnx');
      await old.writeAsBytes([9, 9]);
      final downloader = CallAsrModelDownloader(
        directoryProvider: () async => support,
        artifacts: artifacts,
        clientFactory: () => MockClient((request) async {
          if (request.url.host == 'gitee.com') return http.Response('[]', 200);
          return request.url.path.endsWith('.bz2')
              ? http.Response.bytes(archiveBytes, 200)
              : http.Response('failure', 503);
        }),
      );
      await expectLater(
        downloader.install(previous: previous),
        throwsFormatException,
      );
      expect(await old.readAsBytes(), [9, 9]);
      expect(
        (await support.list(recursive: true).toList()).whereType<File>().map(
          (f) => f.path.replaceAll('\\', '/'),
        ),
        [old.path.replaceAll('\\', '/')],
      );
    },
  );

  test(
    'cancel stops before fetching another artifact and removes staged files',
    () async {
      late CallAsrModelDownloader downloader;
      downloader = CallAsrModelDownloader(
        directoryProvider: () async => support,
        artifacts: artifacts,
        clientFactory: () => MockClient((request) async {
          if (request.url.host == 'gitee.com') return http.Response('[]', 200);
          return http.Response.bytes(archiveBytes, 200);
        }),
      );
      await expectLater(
        downloader.install(
          previous: previous,
          onProgress: (p) {
            if (p.received > 0) downloader.cancel();
          },
        ),
        throwsA(isA<CallModelDownloadCancelled>()),
      );
      expect(
        (await support.list(recursive: true).toList()).whereType<File>(),
        isEmpty,
      );
    },
  );

  test(
    'archive extraction rejects traversal, symlinks and incomplete bundles',
    () async {
      for (final malicious in [
        [
          ArchiveFile.bytes('../outside', [8]),
        ],
        [ArchiveFile.symlink('bundle/model.int8.onnx', '/tmp/target')],
        [
          ArchiveFile.bytes('bundle/model.int8.onnx', [8]),
        ],
      ]) {
        final folder = await support.createTemp('extract-');
        final archive = File('${folder.path}/source.tar.bz2');
        await archive.writeAsBytes(packed(malicious));
        expect(
          () => extractCallAsrArchive(archive.path, folder.path),
          throwsA(isA<Exception>()),
        );
        expect(await File('${support.path}/outside').exists(), isFalse);
      }
    },
  );
}
