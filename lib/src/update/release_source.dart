import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'update_models.dart';
import 'strict_json.dart';

abstract interface class ReleaseSource {
  Future<FetchedUpdateManifest> fetchLatest({
    UpdateSourcePreference preference = UpdateSourcePreference.automatic,
  });
}

final class ReleaseSourceConfig {
  ReleaseSourceConfig({
    this.giteeLatest,
    this.cachedLatest,
    this.githubLatest,
  }) {
    for (final endpoint in [giteeLatest, cachedLatest, githubLatest]) {
      if (endpoint != null) _requireHttps(endpoint);
    }
  }

  final Uri? giteeLatest;
  final Uri? cachedLatest;
  final Uri? githubLatest;

  bool get isEmpty =>
      giteeLatest == null && cachedLatest == null && githubLatest == null;
}

final class ReleaseHttpResponse {
  const ReleaseHttpResponse({
    required this.statusCode,
    required this.bodyBytes,
  });

  final int statusCode;
  final List<int> bodyBytes;
}

abstract interface class ReleaseHttpTransport {
  Future<ReleaseHttpResponse> get(Uri uri);
  void close();
}

final class DefaultReleaseHttpTransport implements ReleaseHttpTransport {
  DefaultReleaseHttpTransport({
    http.Client? client,
    this.timeout = const Duration(seconds: 12),
  }) : _client = client ?? http.Client();

  static const maxManifestBytes = 2 * 1024 * 1024;

  final http.Client _client;
  final Duration timeout;

  @override
  Future<ReleaseHttpResponse> get(Uri uri) async {
    var endpoint = _requireHttps(uri);
    http.StreamedResponse? streamed;
    for (var redirects = 0; redirects <= 5; redirects++) {
      final request = http.Request('GET', endpoint)
        ..followRedirects = false
        ..headers['Accept'] = 'application/json';
      final response = await _client.send(request).timeout(timeout);
      if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        streamed = response;
        break;
      }
      final location = response.headers['location'];
      await response.stream.drain<void>().timeout(timeout);
      if (location == null || redirects == 5) {
        throw const ReleaseSourceException('invalid_redirect');
      }
      endpoint = _requireHttps(endpoint.resolve(location));
    }
    if (streamed == null) {
      throw const ReleaseSourceException('invalid_redirect');
    }
    final contentLength = streamed.contentLength;
    if (contentLength != null && contentLength > maxManifestBytes) {
      throw const ReleaseSourceException('response_too_large');
    }
    final bytes = <int>[];
    await for (final chunk in streamed.stream.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > maxManifestBytes) {
        throw const ReleaseSourceException('response_too_large');
      }
    }
    return ReleaseHttpResponse(
      statusCode: streamed.statusCode,
      bodyBytes: bytes,
    );
  }

  @override
  void close() => _client.close();
}

final class ReleaseSourceException implements Exception {
  const ReleaseSourceException(this.code, {this.attempted = const []});

  final String code;
  final List<UpdateReleaseOrigin> attempted;

  @override
  String toString() => 'ReleaseSourceException($code)';
}

/// Loads a signed manifest from mirrored channel pointers. A failed provider
/// never blocks the next one, while malformed or unsigned responses are never
/// treated as successful cache data.
final class CascadingReleaseSource implements ReleaseSource {
  CascadingReleaseSource({
    required this.config,
    required this.transport,
    this.authenticate,
  });

  final ReleaseSourceConfig config;
  final ReleaseHttpTransport transport;
  final Future<void> Function(UpdateManifestEnvelope envelope)? authenticate;

  @override
  Future<FetchedUpdateManifest> fetchLatest({
    UpdateSourcePreference preference = UpdateSourcePreference.automatic,
  }) async {
    if (config.isEmpty) {
      throw const ReleaseSourceException('not_configured');
    }
    final candidates = switch (preference) {
      UpdateSourcePreference.github => <(UpdateReleaseOrigin, Uri?)>[
        (UpdateReleaseOrigin.github, config.githubLatest),
        (UpdateReleaseOrigin.cache, config.cachedLatest),
        (UpdateReleaseOrigin.gitee, config.giteeLatest),
      ],
      UpdateSourcePreference.automatic ||
      UpdateSourcePreference.gitee => <(UpdateReleaseOrigin, Uri?)>[
        (UpdateReleaseOrigin.gitee, config.giteeLatest),
        (UpdateReleaseOrigin.cache, config.cachedLatest),
        (UpdateReleaseOrigin.github, config.githubLatest),
      ],
    };
    final configured = candidates
        .where((candidate) => candidate.$2 != null)
        .toList();
    // Compare authenticated mirrors so a stale preferred mirror cannot hide a
    // newer release or permanently block checks after a previous fallback.
    // Requests run together; provider order breaks ties at the same sequence.
    final fetchedCandidates = await Future.wait(
      configured.map((candidate) async {
        try {
          final fetched = await _fetch(candidate.$2!, candidate.$1);
          await authenticate?.call(fetched.envelope);
          return fetched;
        } on Object {
          return null;
        }
      }),
    );
    FetchedUpdateManifest? latest;
    for (final fetched in fetchedCandidates) {
      if (fetched != null &&
          (latest == null ||
              (fetched.envelope.payload['release_seq'] as int) >
                  (latest.envelope.payload['release_seq'] as int))) {
        latest = fetched;
      }
    }
    if (latest != null) return latest;
    throw ReleaseSourceException(
      'all_sources_failed',
      attempted: List.unmodifiable(configured.map((candidate) => candidate.$1)),
    );
  }

  Future<FetchedUpdateManifest> _fetch(
    Uri endpoint,
    UpdateReleaseOrigin origin,
  ) async {
    final first = await _getJson(endpoint);
    if (first.containsKey('payload') && first.containsKey('signature')) {
      return FetchedUpdateManifest(
        envelope: UpdateManifestEnvelope.fromJson(first),
        origin: origin,
        endpoint: endpoint,
      );
    }
    _exactPointerKeys(first);
    final manifestUrl = _resolveManifestPointer(first);
    final body = await _getJson(manifestUrl);
    final envelope = UpdateManifestEnvelope.fromJson(body);
    final payload = envelope.payload;
    if (payload['release_id'] != first['release_id'] ||
        payload['release_seq'] != first['release_seq']) {
      throw const ReleaseSourceException('pointer_manifest_mismatch');
    }
    return FetchedUpdateManifest(
      envelope: envelope,
      origin: origin,
      endpoint: endpoint,
    );
  }

  Future<UpdateJson> _getJson(Uri uri) async {
    final response = await transport.get(uri);
    if (response.statusCode != 200) {
      throw const ReleaseSourceException('http_error');
    }
    try {
      final decoded = decodeStrictUpdateJson(utf8.decode(response.bodyBytes));
      if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
        throw const FormatException();
      }
      return Map<String, dynamic>.from(decoded);
    } on FormatException {
      throw const ReleaseSourceException('invalid_json');
    }
  }

  void _exactPointerKeys(UpdateJson pointer) {
    const expected = {
      'schema_version',
      'release_id',
      'release_seq',
      'manifest_url',
    };
    if (pointer.keys.toSet().length != expected.length ||
        !pointer.keys.toSet().containsAll(expected) ||
        pointer['schema_version'] != 1 ||
        pointer['release_id'] is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')
            .hasMatch(pointer['release_id'] as String) ||
        pointer['release_seq'] is! int ||
        (pointer['release_seq'] as int) <= 0 ||
        pointer['manifest_url'] is! String) {
      throw const ReleaseSourceException('invalid_channel_pointer');
    }
  }

  Uri _resolveManifestPointer(UpdateJson pointer) {
    final rawUrl = pointer['manifest_url'] as String;
    final parsed = Uri.parse(rawUrl);
    if (parsed.isAbsolute) return _requireHttps(parsed);

    final releaseId = pointer['release_id'] as String;
    final expected = 'releases/$releaseId/manifest.json';
    if (rawUrl != expected) {
      throw const ReleaseSourceException('invalid_relative_pointer');
    }

    final cachedLatest = config.cachedLatest;
    if (cachedLatest == null) {
      throw const ReleaseSourceException('relative_pointer_cache_unavailable');
    }
    const marker = '/channels/android/';
    final markerIndex = cachedLatest.path.lastIndexOf(marker);
    if (markerIndex < 0) {
      throw const ReleaseSourceException('invalid_cache_channel_path');
    }
    final channelFile = cachedLatest.path.substring(
      markerIndex + marker.length,
    );
    if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}\.json$').hasMatch(channelFile)) {
      throw const ReleaseSourceException('invalid_cache_channel_path');
    }
    final rootPath = cachedLatest.path.substring(0, markerIndex);
    return _requireHttps(
      cachedLatest.replace(
        path: '$rootPath/$expected',
        query: null,
        fragment: null,
      ),
    );
  }

  void close() => transport.close();
}

Uri _requireHttps(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty) {
    throw const FormatException('更新来源必须是无账号和片段的 HTTPS URL');
  }
  return uri;
}
