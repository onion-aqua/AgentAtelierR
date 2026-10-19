import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'resource_integrity.dart';
import 'resource_manifest.dart';
import 'resource_models.dart';

final class ResourceDownloadRequest {
  ResourceDownloadRequest({
    required this.id,
    required List<Uri> urls,
    required this.sha256,
    required this.size,
  }) : urls = List.unmodifiable(urls);

  final String id;
  final List<Uri> urls;
  final String sha256;
  final int size;
}

final class ResourceDownloadResponse {
  const ResourceDownloadResponse({
    required this.statusCode,
    required this.body,
    this.contentLength,
  });

  final int statusCode;
  final Stream<List<int>> body;
  final int? contentLength;
}

abstract interface class ResourceDownloadTransport {
  Future<ResourceDownloadResponse> get(Uri uri);
  void cancelActive();
  void close();
}

final class HttpResourceDownloadTransport implements ResourceDownloadTransport {
  HttpResourceDownloadTransport({
    http.Client Function()? clientFactory,
    this.requestTimeout = const Duration(seconds: 20),
    this.readTimeout = const Duration(seconds: 30),
    this.maxRedirects = 5,
  }) : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;
  final Duration requestTimeout;
  final Duration readTimeout;
  final int maxRedirects;
  http.Client? _activeClient;
  bool _closed = false;

  @override
  Future<ResourceDownloadResponse> get(Uri uri) async {
    if (_closed) throw StateError('Resource download transport is closed');
    var current = requireSecureResourceUri(uri.toString());
    final client = _clientFactory();
    _activeClient = client;
    try {
      for (var redirects = 0; ; redirects++) {
        final request = http.Request('GET', current)..followRedirects = false;
        final response = await client.send(request).timeout(requestTimeout);
        if (_isRedirect(response.statusCode)) {
          if (redirects >= maxRedirects) {
            await response.stream.drain<void>();
            throw const ResourceUpdateException(
              'resource_redirect_limit',
              '资源下载重定向次数过多',
            );
          }
          final location = response.headers[HttpHeaders.locationHeader];
          await response.stream.timeout(readTimeout).drain<void>();
          if (location == null || location.isEmpty) {
            throw const ResourceUpdateException(
              'resource_redirect_invalid',
              '资源服务器返回了无效重定向',
            );
          }
          current = requireSecureResourceUri(
            current.resolve(location).toString(),
          );
          continue;
        }
        return ResourceDownloadResponse(
          statusCode: response.statusCode,
          body: _readBody(response.stream, client),
          contentLength: response.contentLength,
        );
      }
    } on Object {
      if (identical(_activeClient, client)) _activeClient = null;
      client.close();
      rethrow;
    }
  }

  @override
  void cancelActive() {
    _activeClient?.close();
    _activeClient = null;
  }

  @override
  void close() {
    _closed = true;
    cancelActive();
  }

  Stream<List<int>> _readBody(
    http.ByteStream source,
    http.Client client,
  ) async* {
    try {
      yield* source.timeout(readTimeout);
    } finally {
      if (identical(_activeClient, client)) _activeClient = null;
      client.close();
    }
  }

  static bool _isRedirect(int status) =>
      status == HttpStatus.movedPermanently ||
      status == HttpStatus.found ||
      status == HttpStatus.seeOther ||
      status == HttpStatus.temporaryRedirect ||
      status == HttpStatus.permanentRedirect;
}

final class ResourceObjectDownloader {
  ResourceObjectDownloader({ResourceDownloadTransport? transport})
    : _transport = transport ?? HttpResourceDownloadTransport(),
      _ownsTransport = transport == null;

  final ResourceDownloadTransport _transport;
  final bool _ownsTransport;
  bool _closed = false;
  bool _cancelled = false;

  Future<Uint8List> downloadBytes(ResourceDownloadRequest request) async {
    _requireOpen();
    _validateRequest(request);
    _cancelled = false;
    Object? lastError;
    for (final url in request.urls) {
      try {
        _throwIfCancelled();
        final response = await _transport.get(url);
        _validateResponse(response, request);
        final builder = BytesBuilder(copy: false);
        final hashSink = Sha256().toSync().newHashSink();
        var received = 0;
        await for (final chunk in response.body) {
          _throwIfCancelled();
          received += chunk.length;
          if (received > request.size) {
            throw const ResourceUpdateException(
              'resource_size_overflow',
              '资源服务器返回的数据超过清单大小',
            );
          }
          builder.add(chunk);
          hashSink.add(chunk);
        }
        hashSink.close();
        if (received != request.size) {
          throw const ResourceUpdateException(
            'resource_size_mismatch',
            '资源服务器返回的数据大小与清单不一致',
          );
        }
        final digest = _hex((await hashSink.hash()).bytes);
        if (digest != request.sha256) {
          throw const ResourceUpdateException(
            'resource_hash_mismatch',
            '下载资源的 SHA-256 校验失败',
          );
        }
        return builder.takeBytes();
      } on Object catch (error) {
        _transport.cancelActive();
        if (_cancelled) {
          throw const ResourceUpdateException('resource_cancelled', '资源更新已取消');
        }
        lastError = error;
      }
    }
    if (lastError is ResourceUpdateException) throw lastError;
    throw const ResourceUpdateException(
      'resource_download_failed',
      '资源下载失败，请检查网络后重试',
    );
  }

  Future<File> downloadFile(
    ResourceDownloadRequest request, {
    required File destination,
  }) async {
    _requireOpen();
    _validateRequest(request);
    _cancelled = false;
    if (await resourceFileMatches(
      destination,
      size: request.size,
      sha256: request.sha256,
    )) {
      return destination;
    }
    if (await destination.exists()) await destination.delete();
    await destination.parent.create(recursive: true);
    Object? lastError;
    for (final url in request.urls) {
      final partial = File('${destination.path}.part');
      try {
        _throwIfCancelled();
        if (await partial.exists()) await partial.delete();
        final response = await _transport.get(url);
        _validateResponse(response, request);
        final output = partial.openWrite(mode: FileMode.writeOnly);
        final hashSink = Sha256().toSync().newHashSink();
        var received = 0;
        try {
          await for (final chunk in response.body) {
            _throwIfCancelled();
            received += chunk.length;
            if (received > request.size) {
              throw const ResourceUpdateException(
                'resource_size_overflow',
                '资源服务器返回的数据超过清单大小',
              );
            }
            output.add(chunk);
            hashSink.add(chunk);
          }
          await output.flush();
        } finally {
          await output.close();
          hashSink.close();
        }
        if (received != request.size) {
          throw const ResourceUpdateException(
            'resource_size_mismatch',
            '资源服务器返回的数据大小与清单不一致',
          );
        }
        final digest = _hex((await hashSink.hash()).bytes);
        if (digest != request.sha256) {
          throw const ResourceUpdateException(
            'resource_hash_mismatch',
            '下载资源的 SHA-256 校验失败',
          );
        }
        await partial.rename(destination.path);
        return destination;
      } on Object catch (error) {
        lastError = error;
        _transport.cancelActive();
        if (await partial.exists()) await partial.delete();
        if (_cancelled) {
          throw const ResourceUpdateException('resource_cancelled', '资源更新已取消');
        }
      }
    }
    if (lastError is ResourceUpdateException) throw lastError;
    throw const ResourceUpdateException(
      'resource_download_failed',
      '资源下载失败，请检查网络后重试',
    );
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsTransport) _transport.close();
  }

  void cancel() {
    _cancelled = true;
    _transport.cancelActive();
  }

  void _validateRequest(ResourceDownloadRequest request) {
    if (request.urls.isEmpty || request.size <= 0) {
      throw const ResourceUpdateException(
        'invalid_resource_download',
        '资源下载参数无效',
      );
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(request.sha256)) {
      throw const ResourceUpdateException(
        'invalid_resource_hash',
        '资源 SHA-256 格式无效',
      );
    }
    for (final url in request.urls) {
      requireSecureResourceUri(url.toString());
    }
  }

  static void _validateResponse(
    ResourceDownloadResponse response,
    ResourceDownloadRequest request,
  ) {
    if (response.statusCode != HttpStatus.ok) {
      throw ResourceUpdateException(
        'resource_http_${response.statusCode}',
        '资源服务器暂时不可用（${response.statusCode}）',
      );
    }
    final contentLength = response.contentLength;
    if (contentLength != null && contentLength != request.size) {
      throw const ResourceUpdateException(
        'resource_content_length_mismatch',
        '资源服务器声明的文件大小与清单不一致',
      );
    }
  }

  void _requireOpen() {
    if (_closed) {
      throw StateError('ResourceObjectDownloader is closed');
    }
  }

  void _throwIfCancelled() {
    if (_cancelled) {
      throw const ResourceUpdateException('resource_cancelled', '资源更新已取消');
    }
  }

  static String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
