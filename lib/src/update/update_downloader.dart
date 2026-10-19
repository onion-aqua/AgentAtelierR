import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

enum UpdateDownloadPhase {
  idle,
  downloading,
  verifying,
  ready,
  cancelled,
  failed,
}

@immutable
class UpdateDownloadRequest {
  const UpdateDownloadRequest({
    required this.id,
    required this.urls,
    required this.sha256,
    required this.size,
    required this.fileExtension,
  });

  final String id;
  final List<Uri> urls;
  final String sha256;
  final int size;
  final String fileExtension;
}

@immutable
class UpdateDownloadState {
  const UpdateDownloadState({
    this.phase = UpdateDownloadPhase.idle,
    this.id,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.path,
    this.error,
  });

  final UpdateDownloadPhase phase;
  final String? id;
  final int receivedBytes;
  final int totalBytes;
  final String? path;
  final String? error;

  double? get progress =>
      totalBytes <= 0 ? null : (receivedBytes / totalBytes).clamp(0.0, 1.0);
}

class UpdateDownloader extends ChangeNotifier {
  UpdateDownloader({
    http.Client Function()? clientFactory,
    Future<Directory> Function()? supportDirectory,
    this.allowInsecureLocalhost = false,
    this.timeout = const Duration(seconds: 30),
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       assert(!allowInsecureLocalhost || !kReleaseMode);

  final http.Client Function() _clientFactory;
  final Future<Directory> Function() _supportDirectory;
  final bool allowInsecureLocalhost;
  final Duration timeout;
  http.Client? _activeClient;
  bool _cancelled = false;
  bool _running = false;
  bool _disposed = false;
  UpdateDownloadState _state = const UpdateDownloadState();

  UpdateDownloadState get state => _state;
  bool get isRunning => _running;

  Future<File> download(UpdateDownloadRequest request) async {
    if (_disposed) {
      throw const UpdateDownloadException('downloader_disposed', '更新下载器已关闭');
    }
    if (_running) {
      throw const UpdateDownloadException('download_in_progress', '已有更新文件正在下载');
    }
    _validateRequest(request);
    _running = true;
    _cancelled = false;
    late final Directory directory;
    try {
      directory = await _downloadDirectory();
    } on Object {
      _running = false;
      throw const UpdateDownloadException('storage_unavailable', '无法访问更新下载目录');
    }
    final safeId = _safeId(request.id);
    final extension = request.fileExtension.replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );
    final finalFile = File(
      '${directory.path}${Platform.pathSeparator}$safeId.$extension',
    );
    final partFile = File('${finalFile.path}.part');
    final metadataFile = File('${finalFile.path}.part.json');
    try {
      if (await _matches(finalFile, request)) {
        _setState(
          UpdateDownloadState(
            phase: UpdateDownloadPhase.ready,
            id: request.id,
            receivedBytes: request.size,
            totalBytes: request.size,
            path: finalFile.path,
          ),
        );
        return finalFile;
      }
      if (await finalFile.exists()) await finalFile.delete();

      Object? lastError;
      for (final url in request.urls) {
        if (_cancelled) throw const _DownloadCancelled();
        try {
          await _downloadFrom(
            request: request,
            url: url,
            partFile: partFile,
            metadataFile: metadataFile,
          );
          if (!await partFile.exists() ||
              await partFile.length() != request.size) {
            throw const UpdateDownloadException(
              'size_mismatch',
              '更新文件大小与签名清单不一致',
            );
          }
          _setState(
            UpdateDownloadState(
              phase: UpdateDownloadPhase.verifying,
              id: request.id,
              receivedBytes: request.size,
              totalBytes: request.size,
            ),
          );
          if (await _sha256(partFile) != request.sha256.toLowerCase()) {
            await partFile.delete();
            if (await metadataFile.exists()) await metadataFile.delete();
            throw const UpdateDownloadException(
              'sha256_mismatch',
              '更新文件校验失败，已删除损坏的下载内容',
            );
          }
          lastError = null;
          break;
        } on _DownloadCancelled {
          rethrow;
        } on Object catch (error) {
          if (_cancelled) throw const _DownloadCancelled();
          lastError = error;
        } finally {
          _activeClient?.close();
          _activeClient = null;
        }
      }
      if (lastError != null) throw lastError;
      if (!await partFile.exists() || await partFile.length() != request.size) {
        throw const UpdateDownloadException('size_mismatch', '更新文件大小与签名清单不一致');
      }
      if (_cancelled) throw const _DownloadCancelled();
      if (await finalFile.exists()) await finalFile.delete();
      await partFile.rename(finalFile.path);
      if (await metadataFile.exists()) await metadataFile.delete();
      _setState(
        UpdateDownloadState(
          phase: UpdateDownloadPhase.ready,
          id: request.id,
          receivedBytes: request.size,
          totalBytes: request.size,
          path: finalFile.path,
        ),
      );
      return finalFile;
    } on _DownloadCancelled {
      _setState(
        UpdateDownloadState(
          phase: UpdateDownloadPhase.cancelled,
          id: request.id,
          receivedBytes: await _lengthOrZero(partFile),
          totalBytes: request.size,
        ),
      );
      throw const UpdateDownloadException('cancelled', '下载已取消，可稍后继续');
    } on UpdateDownloadException catch (error) {
      _setState(
        UpdateDownloadState(
          phase: UpdateDownloadPhase.failed,
          id: request.id,
          receivedBytes: await _lengthOrZero(partFile),
          totalBytes: request.size,
          error: error.message,
        ),
      );
      rethrow;
    } on Object catch (_) {
      const error = UpdateDownloadException(
        'download_failed',
        '更新文件下载失败，请检查网络后重试',
      );
      _setState(
        UpdateDownloadState(
          phase: UpdateDownloadPhase.failed,
          id: request.id,
          receivedBytes: await _lengthOrZero(partFile),
          totalBytes: request.size,
          error: error.message,
        ),
      );
      throw error;
    } finally {
      _activeClient?.close();
      _activeClient = null;
      _running = false;
    }
  }

  void cancel() {
    if (!_running) return;
    _cancelled = true;
    _activeClient?.close();
  }

  Future<void> clearCache() async {
    if (_running) {
      throw const UpdateDownloadException(
        'download_in_progress',
        '下载期间不能清理更新缓存',
      );
    }
    final directory = await _downloadDirectory(create: false);
    if (await directory.exists()) await directory.delete(recursive: true);
    _setState(const UpdateDownloadState());
  }

  Future<void> _downloadFrom({
    required UpdateDownloadRequest request,
    required Uri url,
    required File partFile,
    required File metadataFile,
  }) async {
    _requireSecureUrl(url);
    var existing = await _lengthOrZero(partFile);
    var metadata = await _readMetadata(metadataFile);
    if (existing > 0 &&
        (metadata['sha256'] != request.sha256 ||
            metadata['size'] != request.size)) {
      await partFile.delete();
      if (await metadataFile.exists()) await metadataFile.delete();
      existing = 0;
      metadata = const {};
    }
    if (existing > request.size) {
      await partFile.delete();
      existing = 0;
    }
    final client = _clientFactory();
    _activeClient = client;
    final httpRequest = http.Request('GET', url)..followRedirects = false;
    if (existing > 0) {
      httpRequest.headers['Range'] = 'bytes=$existing-';
      final etag = metadata['etag'];
      if (etag is String && etag.isNotEmpty) {
        httpRequest.headers['If-Range'] = etag;
      }
    }
    final response = await _sendSecure(client, httpRequest);
    if (_cancelled) throw const _DownloadCancelled();
    var append = false;
    if (response.statusCode == HttpStatus.partialContent) {
      final range = _parseContentRange(response.headers['content-range']);
      if (range == null ||
          range.start != existing ||
          range.total != request.size) {
        throw const UpdateDownloadException(
          'invalid_range',
          '更新服务器返回了无效的断点续传范围',
        );
      }
      append = true;
    } else if (response.statusCode == HttpStatus.ok) {
      existing = 0;
    } else if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
        existing == request.size) {
      return;
    } else {
      throw UpdateDownloadException(
        'http_${response.statusCode}',
        '更新服务器暂时不可用（${response.statusCode}）',
      );
    }

    await metadataFile.writeAsString(
      jsonEncode({
        'v': 1,
        'sha256': request.sha256,
        'size': request.size,
        'etag': response.headers['etag'],
      }),
      flush: true,
    );
    final sink = partFile.openWrite(
      mode: append ? FileMode.append : FileMode.write,
    );
    var received = existing;
    var lastNotification = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await for (final chunk in response.stream.timeout(timeout)) {
        if (_cancelled) throw const _DownloadCancelled();
        received += chunk.length;
        if (received > request.size) {
          throw const UpdateDownloadException(
            'size_overflow',
            '更新服务器返回的数据超过签名清单大小',
          );
        }
        sink.add(chunk);
        final now = DateTime.now();
        if (now.difference(lastNotification) >=
                const Duration(milliseconds: 80) ||
            received == request.size) {
          lastNotification = now;
          _setState(
            UpdateDownloadState(
              phase: UpdateDownloadPhase.downloading,
              id: request.id,
              receivedBytes: received,
              totalBytes: request.size,
            ),
          );
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (received != request.size) {
      throw const UpdateDownloadException('incomplete_download', '更新文件尚未下载完整');
    }
  }

  void _validateRequest(UpdateDownloadRequest request) {
    if (request.urls.isEmpty || request.size <= 0) {
      throw const UpdateDownloadException('invalid_request', '签名清单没有可用的更新下载地址');
    }
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(request.sha256)) {
      throw const UpdateDownloadException('invalid_sha256', '签名清单中的更新文件摘要无效');
    }
    for (final url in request.urls) {
      _requireSecureUrl(url);
    }
  }

  void _requireSecureUrl(Uri url) {
    final local =
        url.host == 'localhost' || url.host == '127.0.0.1' || url.host == '::1';
    if (url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.fragment.isNotEmpty ||
        (url.scheme != 'https' &&
            !(allowInsecureLocalhost && local && url.scheme == 'http'))) {
      throw const UpdateDownloadException(
        'insecure_url',
        '更新文件必须使用受信任的 HTTPS 地址',
      );
    }
  }

  Future<http.StreamedResponse> _sendSecure(
    http.Client client,
    http.Request request,
  ) async {
    var next = request;
    for (var redirects = 0; redirects <= 5; redirects++) {
      _requireSecureUrl(next.url);
      final response = await client.send(next).timeout(timeout);
      if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return response;
      }
      final location = response.headers['location'];
      await response.stream.drain<void>().timeout(timeout);
      if (location == null || redirects == 5) {
        throw const UpdateDownloadException('invalid_redirect', '更新下载跳转无效');
      }
      final target = next.url.resolve(location);
      _requireSecureUrl(target);
      next = http.Request('GET', target)
        ..followRedirects = false
        ..headers.addAll(request.headers);
    }
    throw const UpdateDownloadException('invalid_redirect', '更新下载跳转无效');
  }

  Future<Directory> _downloadDirectory({bool create = true}) async {
    final base = await _supportDirectory();
    final directory = Directory(
      '${base.path}${Platform.pathSeparator}agent_atelier_updates_v1',
    );
    if (create) await directory.create(recursive: true);
    return directory;
  }

  Future<bool> _matches(File file, UpdateDownloadRequest request) async =>
      await file.exists() &&
      await file.length() == request.size &&
      await _sha256(file) == request.sha256.toLowerCase();

  Future<String> _sha256(File file) async {
    final sink = Sha256().toSync().newHashSink();
    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    final digest = await sink.hash();
    return digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<Map<String, Object?>> _readMetadata(File file) async {
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is Map) return value.cast<String, Object?>();
    } on Object {
      // A missing or corrupt resume hint only disables If-Range.
    }
    return const {};
  }

  void _setState(UpdateDownloadState value) {
    _state = value;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    cancel();
    _disposed = true;
    super.dispose();
  }

  static String _safeId(String value) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return safe.isEmpty
        ? 'update'
        : safe.substring(0, safe.length.clamp(1, 96));
  }

  static Future<int> _lengthOrZero(File file) async =>
      await file.exists() ? file.length() : 0;

  static _ContentRange? _parseContentRange(String? value) {
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(value ?? '');
    if (match == null) return null;
    return _ContentRange(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }
}

class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'UpdateDownloadException($code): $message';
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}

class _ContentRange {
  const _ContentRange(this.start, this.end, this.total);

  final int start;
  final int end;
  final int total;
}
