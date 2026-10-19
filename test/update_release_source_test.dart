import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/update/release_source.dart';
import 'package:ryza_chat_mvp/src/update/update_models.dart';

Map<String, dynamic> _envelope({
  String releaseId = 'release-47',
  int releaseSeq = 47,
}) => {
  'payload': {
    'schema_version': 1,
    'canonicalization': 'aar-cjson-v1',
    'release_id': releaseId,
    'release_seq': releaseSeq,
    'display_version': '1.0.4.2',
    'channel': 'stable',
    'platform': 'android',
    'updater_protocol_version': 1,
    'published_at': '2026-10-19T08:00:00Z',
    'runtime_compat_id': 'runtime-47',
    'resource_api_version': 1,
    'target_apk': {
      'version_code': 47,
      'package_name': 'com.example.app',
      'abis': ['arm64-v8a'],
      'sha256': 'b' * 64,
      'certificate_sha256': 'c' * 64,
      'urls': ['https://downloads.example.test/app.apk'],
      'size': 1000,
    },
    'apk_deltas': [],
    'notes': {'release_id': releaseId},
  },
  'signature': {
    'key_id': 'key-1',
    'algorithm': 'Ed25519',
    'signed_object': 'payload',
    'canonicalization': 'aar-cjson-v1',
    'value_base64': base64.encode(List<int>.filled(64, 0)),
  },
};

ReleaseHttpResponse _jsonResponse(int status, Object body) =>
    ReleaseHttpResponse(
      statusCode: status,
      bodyBytes: utf8.encode(jsonEncode(body)),
    );

final class _FakeTransport implements ReleaseHttpTransport {
  _FakeTransport(this.responses);

  final Map<Uri, Object> responses;
  final List<Uri> requested = [];

  @override
  Future<ReleaseHttpResponse> get(Uri uri) async {
    requested.add(uri);
    final value = responses[uri];
    if (value is Object Function()) return value() as ReleaseHttpResponse;
    if (value is ReleaseHttpResponse) return value;
    throw StateError('offline');
  }

  @override
  void close() {}
}

void main() {
  final gitee = Uri.parse('https://gitee.example.test/stable.json');
  final cache = Uri.parse('https://updates.example.test/stable.json');
  final privateChannel = Uri.parse(
    'https://updates.example.test/private/channels/android/stable.json',
  );
  final github = Uri.parse('https://github.example.test/stable.json');
  final manifestUrl = Uri.parse(
    'https://updates.example.test/releases/release-47/manifest.json',
  );

  test('default source order is Gitee, server cache, then GitHub', () async {
    final transport = _FakeTransport({
      gitee: _jsonResponse(503, {'error': 'unavailable'}),
      cache: _jsonResponse(200, {
        'schema_version': 1,
        'release_id': 'release-47',
        'release_seq': 47,
        'manifest_url': manifestUrl.toString(),
      }),
      manifestUrl: _jsonResponse(200, _envelope()),
      github: _jsonResponse(200, _envelope()),
    });
    final source = CascadingReleaseSource(
      config: ReleaseSourceConfig(
        giteeLatest: gitee,
        cachedLatest: cache,
        githubLatest: github,
      ),
      transport: transport,
    );

    final fetched = await source.fetchLatest();

    expect(fetched.origin, UpdateReleaseOrigin.cache);
    expect(fetched.envelope.payload['release_id'], 'release-47');
    expect(transport.requested, [gitee, cache, github, manifestUrl]);
  });

  test('GitHub preference checks GitHub first', () async {
    final transport = _FakeTransport({github: _jsonResponse(200, _envelope())});
    final source = CascadingReleaseSource(
      config: ReleaseSourceConfig(
        giteeLatest: gitee,
        cachedLatest: cache,
        githubLatest: github,
      ),
      transport: transport,
    );

    final fetched = await source.fetchLatest(
      preference: UpdateSourcePreference.github,
    );

    expect(fetched.origin, UpdateReleaseOrigin.github);
    expect(transport.requested, [github, cache, gitee]);
  });

  test(
    'authentication failure on first mirror falls back before selection',
    () async {
      final transport = _FakeTransport({
        gitee: _jsonResponse(200, _envelope(releaseId: 'unauthenticated-47')),
        cache: _jsonResponse(200, _envelope()),
      });
      final source = CascadingReleaseSource(
        config: ReleaseSourceConfig(giteeLatest: gitee, cachedLatest: cache),
        transport: transport,
        authenticate: (envelope) async {
          if (envelope.payload['release_id'] == 'unauthenticated-47') {
            throw const FormatException('signature mismatch');
          }
        },
      );
      expect((await source.fetchLatest()).origin, UpdateReleaseOrigin.cache);
      expect(transport.requested, [gitee, cache]);
    },
  );

  test(
    'pointer identity mismatch cannot be accepted as cached latest',
    () async {
      final transport = _FakeTransport({
        cache: _jsonResponse(200, {
          'schema_version': 1,
          'release_id': 'release-48',
          'release_seq': 48,
          'manifest_url': manifestUrl.toString(),
        }),
        manifestUrl: _jsonResponse(200, _envelope()),
        github: _jsonResponse(200, _envelope()),
      });
      final source = CascadingReleaseSource(
        config: ReleaseSourceConfig(cachedLatest: cache, githubLatest: github),
        transport: transport,
      );

      final fetched = await source.fetchLatest();

      expect(fetched.origin, UpdateReleaseOrigin.github);
      expect(transport.requested, [cache, github, manifestUrl]);
    },
  );

  test('Gitee relative pointer resolves only through private cache root', () async {
    final privateManifest = Uri.parse(
      'https://updates.example.test/private/releases/release-47/manifest.json',
    );
    final transport = _FakeTransport({
      gitee: _jsonResponse(200, {
        'schema_version': 1,
        'release_id': 'release-47',
        'release_seq': 47,
        'manifest_url': 'releases/release-47/manifest.json',
      }),
      privateChannel: _jsonResponse(503, {'error': 'offline'}),
      privateManifest: _jsonResponse(200, _envelope()),
    });
    final source = CascadingReleaseSource(
      config: ReleaseSourceConfig(
        giteeLatest: gitee,
        cachedLatest: privateChannel,
      ),
      transport: transport,
    );

    final fetched = await source.fetchLatest();

    expect(fetched.origin, UpdateReleaseOrigin.gitee);
    expect(fetched.endpoint, gitee);
    expect(transport.requested, [gitee, privateChannel, privateManifest]);
  });

  test(
    'relative pointer without private cache is rejected and falls back',
    () async {
      final transport = _FakeTransport({
        gitee: _jsonResponse(200, {
          'schema_version': 1,
          'release_id': 'release-47',
          'release_seq': 47,
          'manifest_url': 'releases/release-47/manifest.json',
        }),
        github: _jsonResponse(200, _envelope()),
      });
      final source = CascadingReleaseSource(
        config: ReleaseSourceConfig(giteeLatest: gitee, githubLatest: github),
        transport: transport,
      );

      expect((await source.fetchLatest()).origin, UpdateReleaseOrigin.github);
      expect(transport.requested, [gitee, github]);
    },
  );

  test('malicious relative pointer paths are rejected', () async {
    for (final path in <String>[
      '../releases/release-47/manifest.json',
      '/releases/release-47/manifest.json',
      '//evil.example.test/manifest.json',
      'releases/release-47/manifest.json?token=public',
      'releases/release-47/manifest.json#fragment',
      'releases/other-release/manifest.json',
    ]) {
      final transport = _FakeTransport({
        gitee: _jsonResponse(200, {
          'schema_version': 1,
          'release_id': 'release-47',
          'release_seq': 47,
          'manifest_url': path,
        }),
        privateChannel: _jsonResponse(503, {'error': 'offline'}),
        github: _jsonResponse(200, _envelope()),
      });
      final source = CascadingReleaseSource(
        config: ReleaseSourceConfig(
          giteeLatest: gitee,
          cachedLatest: privateChannel,
          githubLatest: github,
        ),
        transport: transport,
      );

      expect(
        (await source.fetchLatest()).origin,
        UpdateReleaseOrigin.github,
        reason: path,
      );
      expect(transport.requested, [
        gitee,
        privateChannel,
        github,
      ], reason: path);
    }
  });

  test('relative pointer still enforces signed manifest identity', () async {
    final privateManifest = Uri.parse(
      'https://updates.example.test/private/releases/release-48/manifest.json',
    );
    final transport = _FakeTransport({
      gitee: _jsonResponse(200, {
        'schema_version': 1,
        'release_id': 'release-48',
        'release_seq': 48,
        'manifest_url': 'releases/release-48/manifest.json',
      }),
      privateChannel: _jsonResponse(503, {'error': 'offline'}),
      privateManifest: _jsonResponse(200, _envelope()),
      github: _jsonResponse(200, _envelope()),
    });
    final source = CascadingReleaseSource(
      config: ReleaseSourceConfig(
        giteeLatest: gitee,
        cachedLatest: privateChannel,
        githubLatest: github,
      ),
      transport: transport,
    );

    expect((await source.fetchLatest()).origin, UpdateReleaseOrigin.github);
    expect(transport.requested, [
      gitee,
      privateChannel,
      github,
      privateManifest,
    ]);
  });

  test(
    'all failures report only source identities, never endpoint bodies',
    () async {
      final transport = _FakeTransport({
        gitee: _jsonResponse(503, {'token': 'must-not-leak'}),
        cache: _jsonResponse(200, '<html>not json</html>'),
      });
      final source = CascadingReleaseSource(
        config: ReleaseSourceConfig(giteeLatest: gitee, cachedLatest: cache),
        transport: transport,
      );

      await expectLater(
        source.fetchLatest(),
        throwsA(
          isA<ReleaseSourceException>()
              .having((error) => error.attempted, 'attempted', [
                UpdateReleaseOrigin.gitee,
                UpdateReleaseOrigin.cache,
              ])
              .having(
                (error) => error.toString(),
                'redacted message',
                isNot(contains('must-not-leak')),
              ),
        ),
      );
    },
  );

  test('source configuration rejects public cleartext URLs', () {
    expect(
      () => ReleaseSourceConfig(
        giteeLatest: Uri.parse('http://gitee.example.test/stable.json'),
      ),
      throwsFormatException,
    );
  });

  test(
    'a stale preferred mirror cannot hide the newer signed release',
    () async {
      final transport = _FakeTransport({
        gitee: _jsonResponse(200, _envelope(releaseSeq: 47)),
        cache: _jsonResponse(
          200,
          _envelope(releaseId: 'release-49', releaseSeq: 49),
        ),
        github: _jsonResponse(
          200,
          _envelope(releaseId: 'release-48', releaseSeq: 48),
        ),
      });
      final source = CascadingReleaseSource(
        config: ReleaseSourceConfig(
          giteeLatest: gitee,
          cachedLatest: cache,
          githubLatest: github,
        ),
        transport: transport,
      );
      final result = await source.fetchLatest();
      expect(result.origin, UpdateReleaseOrigin.cache);
      expect(result.envelope.payload['release_seq'], 49);
    },
  );

  test(
    'Gitee is preferred when signed mirrors have the same sequence',
    () async {
      final source = CascadingReleaseSource(
        config: ReleaseSourceConfig(
          giteeLatest: gitee,
          cachedLatest: cache,
          githubLatest: github,
        ),
        transport: _FakeTransport({
          gitee: _jsonResponse(200, _envelope()),
          cache: _jsonResponse(200, _envelope()),
          github: _jsonResponse(200, _envelope()),
        }),
      );
      expect((await source.fetchLatest()).origin, UpdateReleaseOrigin.gitee);
      expect(
        (await source.fetchLatest(preference: UpdateSourcePreference.github))
            .origin,
        UpdateReleaseOrigin.github,
      );
    },
  );

  test(
    'metadata follows HTTPS asset redirects and rejects HTTP downgrade',
    () async {
      var calls = 0;
      final transport = DefaultReleaseHttpTransport(
        client: MockClient((request) async {
          calls++;
          if (request.url.path == '/start') {
            return http.Response(
              '',
              302,
              headers: {'location': 'https://cdn.example.test/manifest'},
            );
          }
          if (request.url.path == '/unsafe') {
            return http.Response(
              '',
              302,
              headers: {'location': 'http://cdn.example.test/manifest'},
            );
          }
          return http.Response('{}', 200);
        }),
      );
      addTearDown(transport.close);
      expect(
        (await transport.get(Uri.parse('https://example.test/start')))
            .statusCode,
        200,
      );
      expect(calls, 2);
      await expectLater(
        transport.get(Uri.parse('https://example.test/unsafe')),
        throwsFormatException,
      );
      expect(calls, 3);
    },
  );
}
