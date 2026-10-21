import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../update/resource_integrity.dart';
import 'local_call_asr_config.dart';

class CallModelDownloadProgress {
  const CallModelDownloadProgress(
    this.message, {
    this.received = 0,
    this.total,
  });
  final String message;
  final int received;
  final int? total;
  double? get fraction =>
      total == null || total == 0 ? null : received / total!;
}

class CallModelDownloadCancelled implements Exception {
  const CallModelDownloadCancelled();
  @override
  String toString() => '模型下载已取消。';
}

class CallModelArtifact {
  const CallModelArtifact({
    required this.name,
    required this.bytes,
    required this.sha256,
    required this.url,
  });
  final String name;
  final int bytes;
  final String sha256;
  final Uri url;
}

/// Pinned official files. Gitee mirrors must contain the identical bytes;
/// discovering a newer release cannot silently change an installed model.
class CallAsrModelDownloader {
  CallAsrModelDownloader({
    Future<Directory> Function()? directoryProvider,
    http.Client Function()? clientFactory,
    this.giteeReleasesUrl,
    this.artifacts,
    this.extractor,
  }) : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory,
       _clientFactory = clientFactory ?? http.Client.new;

  static const bundleName =
      'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17';
  static const archiveName = '$bundleName.tar.bz2';
  static const _releaseBase =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models';
  static final officialArtifacts = <CallModelArtifact>[
    CallModelArtifact(
      name: archiveName,
      bytes: 163002883,
      sha256:
          '7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e',
      url: Uri.parse('$_releaseBase/$archiveName'),
    ),
    CallModelArtifact(
      name: 'silero_vad.onnx',
      bytes: 643854,
      sha256:
          '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
      url: Uri.parse('$_releaseBase/silero_vad.onnx'),
    ),
  ];
  static final defaultGiteeReleasesUrl = Uri.parse(
    const String.fromEnvironment(
      'CALL_ASR_GITEE_RELEASES_URL',
      defaultValue: 'https://gitee.com/api/v5/repos/MugenMahoro/AgentAtelierR/releases?per_page=100',
    ),
  );
  final Future<Directory> Function() _directoryProvider;
  final http.Client Function() _clientFactory;
  final Uri? giteeReleasesUrl;
  final List<CallModelArtifact>? artifacts;
  final Future<void> Function(String archive, String destination)? extractor;
  http.Client? _client;
  bool _cancelled = false;
  bool _running = false;

  void cancel() {
    _cancelled = true;
    _client?.close();
  }

  void _checkCancelled() {
    if (_cancelled) throw const CallModelDownloadCancelled();
  }

  Future<LocalCallAsrConfig> install({
    required LocalCallAsrConfig previous,
    void Function(CallModelDownloadProgress)? onProgress,
  }) async {
    if (_running) throw StateError('模型下载正在进行中。');
    _running = true;
    _cancelled = false;
    final client = _clientFactory();
    _client = client;
    Directory? staging;
    Directory? installed;
    var complete = false;
    try {
      final support = await _directoryProvider();
      final root = Directory('${support.path}/realtime_call/asr');
      await root.create(recursive: true);
      staging = await root.createTemp('.download-');
      onProgress?.call(const CallModelDownloadProgress('正在查询 Gitee 模型下载源…'));
      final mirrors = await _giteeAssets(client);
      final items = artifacts ?? officialArtifacts;
      for (final artifact in items) {
        _checkCancelled();
        final mirror = mirrors[artifact.name];
        var downloaded = false;
        if (mirror != null) {
          try {
            await _download(
              client,
              artifact,
              mirror,
              staging,
              'Gitee',
              onProgress,
            );
            downloaded = true;
          } on Object {
            _checkCancelled();
          }
        }
        if (!downloaded) {
          onProgress?.call(
            CallModelDownloadProgress(
              mirror == null
                  ? 'Gitee 暂无匹配资源，切换官方 GitHub：${artifact.name}'
                  : 'Gitee 下载失败，切换官方 GitHub：${artifact.name}',
            ),
          );
          await _download(
            client,
            artifact,
            artifact.url,
            staging,
            'GitHub',
            onProgress,
          );
        }
      }
      _checkCancelled();
      onProgress?.call(const CallModelDownloadProgress('下载完成，正在解压并校验模型…'));
      installed = await root.createTemp('sensevoice-20240717-');
      final archive = '${staging.path}/${items.first.name}';
      if (extractor != null) {
        await extractor!(archive, installed.path);
      } else {
        final destination = installed.path;
        await Isolate.run(() => extractCallAsrArchive(archive, destination));
      }
      _checkCancelled();
      final vad = File('${installed.path}/silero_vad.onnx');
      await File('${staging.path}/${items.last.name}').copy(vad.path);
      final next = LocalCallAsrConfig(
        modelPath: '${installed.path}/model.int8.onnx',
        tokensPath: '${installed.path}/tokens.txt',
        vadModelPath: vad.path,
        language: previous.language,
        silenceSeconds: previous.silenceSeconds,
      );
      await next.validateFiles();
      _checkCancelled();
      complete = true;
      onProgress?.call(const CallModelDownloadProgress('模型已安装，请保存通话设置。'));
      return next;
    } on Object {
      _checkCancelled();
      rethrow;
    } finally {
      client.close();
      _client = null;
      _running = false;
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      if (!complete && installed != null && await installed.exists()) {
        await installed.delete(recursive: true);
      }
    }
  }

  Future<Map<String, Uri>> _giteeAssets(http.Client client) async {
    try {
      final response = await _get(
        client,
        giteeReleasesUrl ?? defaultGiteeReleasesUrl,
      ).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return {};
      final bytes = await _readBounded(response.stream, 1024 * 1024);
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! List) return {};
      final result = <String, Uri>{};
      for (final release in json.whereType<Map>()) {
        final assets = release['assets'];
        final links = assets is List
            ? assets
            : assets is Map
            ? assets['links']
            : null;
        if (links is! List) continue;
        for (final asset in links.whereType<Map>()) {
          final name = asset['name'];
          final url =
              asset['browser_download_url'] ??
              asset['direct_asset_url'] ??
              asset['url'];
          if (name is! String || url is! String) continue;
          final parsed = Uri.tryParse(url);
          if (parsed != null && _secure(parsed)) {
            result.putIfAbsent(name, () => parsed);
          }
        }
      }
      return result;
    } on Object {
      _checkCancelled();
      return {};
    }
  }

  Future<void> _download(
    http.Client client,
    CallModelArtifact artifact,
    Uri url,
    Directory directory,
    String source,
    void Function(CallModelDownloadProgress)? onProgress,
  ) async {
    final file = File('${directory.path}/${artifact.name}');
    final response = await _get(
      client,
      url,
    ).timeout(const Duration(seconds: 25));
    if (response.statusCode != 200 ||
        (response.contentLength != null &&
            response.contentLength != artifact.bytes)) {
      throw FormatException(
        '$source 模型下载失败（HTTP ${response.statusCode} 或文件大小不符）。',
      );
    }
    var received = 0;
    final sink = file.openWrite();
    var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        _checkCancelled();
        received += chunk.length;
        if (received > artifact.bytes) {
          throw const FormatException('模型文件超过预期大小。');
        }
        sink.add(chunk);
        final now = DateTime.now();
        if (now.difference(lastProgress).inMilliseconds >= 120 ||
            received == artifact.bytes) {
          lastProgress = now;
          onProgress?.call(
            CallModelDownloadProgress(
              '$source · ${artifact.name}',
              received: received,
              total: artifact.bytes,
            ),
          );
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (received != artifact.bytes ||
        await resourceSha256File(file) != artifact.sha256) {
      throw const FormatException('模型下载不完整或 SHA-256 校验失败。');
    }
  }

  Future<http.StreamedResponse> _get(http.Client client, Uri uri) async {
    for (var redirect = 0; redirect < 6; redirect++) {
      _checkCancelled();
      if (!_secure(uri)) throw const FormatException('模型下载只支持 HTTPS。');
      final request = http.Request('GET', uri)..followRedirects = false;
      final response = await client.send(request);
      if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers['location'];
        await response.stream.drain<void>();
        if (location == null) throw const FormatException('模型下载重定向无效。');
        uri = uri.resolve(location);
      } else {
        return response;
      }
    }
    throw const FormatException('模型下载重定向次数过多。');
  }

  static bool _secure(Uri uri) =>
      uri.scheme == 'https' && uri.host.isNotEmpty && uri.userInfo.isEmpty;

  Future<List<int>> _readBounded(Stream<List<int>> stream, int maximum) async {
    final bytes = BytesBuilder(copy: false);
    await for (final part in stream.timeout(const Duration(seconds: 12))) {
      if (bytes.length + part.length > maximum) {
        throw const FormatException('模型源响应过大。');
      }
      bytes.add(part);
    }
    return bytes.takeBytes();
  }
}

/// Disk-backed decompression runs in a worker isolate. Only allowlisted regular
/// files are written, and both compressed and expanded sizes remain bounded.
void extractCallAsrArchive(String archivePath, String destination) {
  final input = InputFileStream(archivePath);
  final tarPath = '$destination/model.tar';
  final output = _BoundedFileOutput(tarPath, 500 * 1024 * 1024);
  try {
    if (!BZip2Decoder().decodeStream(input, output, verify: true)) {
      throw const FormatException('模型压缩包损坏。');
    }
  } finally {
    input.closeSync();
    output.closeSync();
  }
  final tarInput = InputFileStream(tarPath);
  try {
    final archive = TarDecoder().decodeStream(tarInput, verify: true);
    if (archive.length > 100) throw const FormatException('模型压缩包文件过多。');
    var total = 0;
    final found = <String>{};
    for (final entry in archive) {
      final path = entry.name.replaceAll('\\', '/');
      if (path.startsWith('/') ||
          path.contains(':') ||
          path.split('/').contains('..') ||
          entry.isSymbolicLink) {
        throw const FormatException('模型压缩包包含不安全路径。');
      }
      total += entry.size;
      if (entry.size < 0 || total > 500 * 1024 * 1024) {
        throw const FormatException('模型解压大小超限。');
      }
      if (!entry.isFile) continue;
      final name = path.split('/').last;
      if (!{'model.int8.onnx', 'tokens.txt'}.contains(name)) continue;
      if (!found.add(name) || entry.size == 0) {
        throw const FormatException('模型压缩包包含重复或空文件。');
      }
      final target = _BoundedFileOutput('$destination/$name', entry.size);
      try {
        entry.writeContent(target);
      } finally {
        target.closeSync();
      }
      if (File('$destination/$name').lengthSync() != entry.size) {
        throw const FormatException('模型解压不完整。');
      }
    }
    if (found.length != 2) {
      throw const FormatException('模型压缩包缺少 model.int8.onnx 或 tokens.txt。');
    }
  } finally {
    tarInput.closeSync();
    File(tarPath).deleteSync();
  }
}

class _BoundedFileOutput extends OutputFileStream {
  _BoundedFileOutput(String path, this.maximum)
    : super.withFileHandle(FileHandle(path, mode: FileAccess.write));
  final int maximum;
  @override
  void writeByte(int value) {
    if (length >= maximum) throw const FormatException('模型解压大小超限。');
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    if (this.length + (length ?? bytes.length) > maximum) {
      throw const FormatException('模型解压大小超限。');
    }
    super.writeBytes(bytes, length: length);
  }
}
