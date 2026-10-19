import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/update/update_downloader.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('aar-update-test-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('rejects public plaintext download endpoints', () async {
    final bytes = utf8.encode('update');
    final downloader = UpdateDownloader(
      supportDirectory: () async => temporary,
    );
    addTearDown(downloader.dispose);

    await expectLater(
      downloader.download(
        UpdateDownloadRequest(
          id: 'release-1',
          urls: [Uri.parse('http://example.com/update.apk')],
          sha256: await digest(bytes),
          size: bytes.length,
          fileExtension: 'apk',
        ),
      ),
      throwsA(
        isA<UpdateDownloadException>().having(
          (error) => error.code,
          'code',
          'insecure_url',
        ),
      ),
    );
  });

  test('resumes a partial file and verifies it before activation', () async {
    final bytes = utf8.encode('0123456789abcdefghijklmnopqrstuvwxyz');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    String? range;
    server.listen((request) async {
      range = request.headers.value(HttpHeaders.rangeHeader);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes 10-${bytes.length - 1}/${bytes.length}',
      );
      request.response.add(bytes.sublist(10));
      await request.response.close();
    });

    final cache = Directory(
      '${temporary.path}${Platform.pathSeparator}agent_atelier_updates_v1',
    );
    await cache.create();
    await File('${cache.path}${Platform.pathSeparator}release-1.apk.part')
        .writeAsBytes(bytes.sublist(0, 10));
    await File(
      '${cache.path}${Platform.pathSeparator}release-1.apk.part.json',
    ).writeAsString(
      jsonEncode({'v': 1, 'sha256': await digest(bytes), 'size': bytes.length}),
    );
    final downloader = UpdateDownloader(
      supportDirectory: () async => temporary,
      allowInsecureLocalhost: true,
    );
    addTearDown(downloader.dispose);
    final output = await downloader.download(
      UpdateDownloadRequest(
        id: 'release-1',
        urls: [Uri.parse('http://127.0.0.1:${server.port}/update.apk')],
        sha256: await digest(bytes),
        size: bytes.length,
        fileExtension: 'apk',
      ),
    );

    expect(range, 'bytes=10-');
    expect(await output.readAsBytes(), bytes);
    expect(downloader.state.phase, UpdateDownloadPhase.ready);
    expect(await File('${output.path}.part').exists(), isFalse);
  });

  test('deletes a completed file whose digest does not match', () async {
    final expected = utf8.encode('expected payload');
    final returned = utf8.encode('tampered payload');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.add(returned);
      await request.response.close();
    });
    final downloader = UpdateDownloader(
      supportDirectory: () async => temporary,
      allowInsecureLocalhost: true,
    );
    addTearDown(downloader.dispose);

    await expectLater(
      downloader.download(
        UpdateDownloadRequest(
          id: 'release-bad',
          urls: [Uri.parse('http://127.0.0.1:${server.port}/update.apk')],
          sha256: await digest(expected),
          size: returned.length,
          fileExtension: 'apk',
        ),
      ),
      throwsA(
        isA<UpdateDownloadException>().having(
          (error) => error.code,
          'code',
          'sha256_mismatch',
        ),
      ),
    );
    expect(
      await File(
        '${temporary.path}${Platform.pathSeparator}'
        'agent_atelier_updates_v1${Platform.pathSeparator}'
        'release-bad.apk.part',
      ).exists(),
      isFalse,
    );
  });

  test('corrupt mirror falls through to a verified mirror', () async {
    final expected = utf8.encode('verified payload');
    var calls = 0;
    final downloader = UpdateDownloader(
      supportDirectory: () async => temporary,
      clientFactory: () => MockClient((request) async {
        calls++;
        return http.Response.bytes(
          request.url.host == 'bad.example.test'
              ? List.filled(expected.length, 0)
              : expected,
          200,
        );
      }),
    );
    addTearDown(downloader.dispose);
    final file = await downloader.download(
      UpdateDownloadRequest(
        id: 'mirrored',
        urls: [
          Uri.parse('https://bad.example.test/a.apk'),
          Uri.parse('https://good.example.test/a.apk'),
        ],
        sha256: await digest(expected),
        size: expected.length,
        fileExtension: 'apk',
      ),
    );
    expect(await file.readAsBytes(), expected);
    expect(calls, 2);
  });

  test('HTTPS redirect cannot downgrade to public HTTP', () async {
    var calls = 0;
    final downloader = UpdateDownloader(
      supportDirectory: () async => temporary,
      clientFactory: () => MockClient((request) async {
        calls++;
        return http.Response(
          '',
          302,
          headers: {'location': 'http://public.example.test/a.apk'},
        );
      }),
    );
    addTearDown(downloader.dispose);
    await expectLater(
      downloader.download(
        UpdateDownloadRequest(
          id: 'redirect',
          urls: [Uri.parse('https://secure.example.test/a.apk')],
          sha256: await digest([1]),
          size: 1,
          fileExtension: 'apk',
        ),
      ),
      throwsA(
        isA<UpdateDownloadException>().having(
          (e) => e.code,
          'code',
          'insecure_url',
        ),
      ),
    );
    expect(calls, 1);
  });
}

Future<String> digest(List<int> bytes) async {
  final value = await Sha256().hash(bytes);
  return value.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}
