import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../desktop_tts_transport.dart';
import '../tts_text_normalizer.dart';

/// A single Fish REST request. The official endpoint streams its HTTP response;
/// it does not declare a `streaming` field in the JSON request schema.
class FishCallTtsClient {
  FishCallTtsClient({
    http.Client Function()? clientFactory,
    this.requestTimeout = const Duration(seconds: 45),
    this.chunkTimeout = const Duration(seconds: 15),
    this.maximumAudioDuration = const Duration(minutes: 2),
  }) : _clientFactory = clientFactory ?? _newTransport;

  static const sampleRate = 24000;
  static const channels = 1;
  static const encoding = 'pcm_s16le';
  static final defaultEndpoint = Uri.parse('https://api.fish.audio/v1/tts');

  final http.Client Function() _clientFactory;
  final Duration requestTimeout;
  final Duration chunkTimeout;
  final Duration maximumAudioDuration;

  static http.Client _newTransport() =>
      Platform.isWindows ? DesktopTtsClient() : http.Client();

  /// The caller reads the existing Fish REST key from SecretStore. Credentials
  /// are never attached to a URL, persisted here, or written to logs.
  ///
  /// Listening starts exactly one billable POST; no automatic retry or fallback
  /// is performed, including when a timeout leaves its outcome unknown.
  FishCallTtsStream synthesize({
    required String apiKey,
    required String text,
    required String voiceId,
    required String model,
    Uri? endpoint,
    double speed = 1,
    double temperature = .55,
  }) {
    final target = endpoint ?? defaultEndpoint;
    final cleanText = normalizeFishAudioSynthesisText(text);
    final spoken = cleanText.replaceAll(RegExp(r'\[[^\[\]\r\n]+\]'), '').trim();
    if (apiKey.trim().isEmpty ||
        voiceId.trim().isEmpty ||
        model.trim().isEmpty) {
      throw const FishCallTtsException(
        code: 'configuration_missing',
        message: '请先配置 Fish Audio API 密钥、音色和模型。',
      );
    }
    if (target.scheme != 'https' ||
        target.host.isEmpty ||
        target.userInfo.isNotEmpty ||
        target.hasQuery ||
        target.hasFragment) {
      throw const FishCallTtsException(
        code: 'insecure_endpoint',
        message: '通话语音接口必须使用不含凭据或查询参数的 HTTPS 地址。',
      );
    }
    // Accept future model IDs without a local allowlist, while rejecting header
    // injection. The service decides which model the account may use.
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._/-]{0,95}$').hasMatch(model.trim()) ||
        apiKey.contains(RegExp(r'[\r\n]'))) {
      throw const FishCallTtsException(
        code: 'invalid_configuration',
        message: 'Fish Audio 模型或密钥格式无效。',
      );
    }
    if (spoken.isEmpty || cleanText.runes.length > 2000) {
      throw const FishCallTtsException(
        code: 'invalid_text',
        message: '通话朗读需要有效文本，每段最多 2000 字。',
      );
    }
    if (!speed.isFinite || !temperature.isFinite) {
      throw const FishCallTtsException(
        code: 'invalid_configuration',
        message: '通话语速或温度无效。',
      );
    }
    return FishCallTtsStream._(
      _clientFactory,
      target,
      apiKey.trim(),
      model.trim(),
      {
        'text': cleanText,
        'reference_id': voiceId.trim(),
        'format': 'pcm',
        'sample_rate': sampleRate,
        'latency': 'low',
        'normalize': true,
        'temperature': temperature.clamp(0, 1),
        'prosody': {
          'speed': speed.clamp(.5, 2),
          'volume': 0,
          'normalize_loudness': true,
        },
      },
      requestTimeout,
      chunkTimeout,
      maximumAudioDuration.inMilliseconds * sampleRate * channels * 2 ~/ 1000,
    );
  }
}

/// A cancellable, single-subscription stream of sample-aligned PCM chunks.
class FishCallTtsStream {
  FishCallTtsStream._(
    this._clientFactory,
    this._endpoint,
    this._apiKey,
    this._model,
    this._body,
    this._requestTimeout,
    this._chunkTimeout,
    this._maximumBytes,
  ) {
    _output = StreamController<Uint8List>(
      onListen: () => unawaited(_run()),
      onCancel: cancel,
    );
  }

  final http.Client Function() _clientFactory;
  final Uri _endpoint;
  String _apiKey;
  final String _model;
  final Map<String, dynamic> _body;
  final Duration _requestTimeout;
  final Duration _chunkTimeout;
  final int _maximumBytes;
  final _abort = Completer<void>();
  late final StreamController<Uint8List> _output;
  http.Client? _client;
  StreamIterator<List<int>>? _audioIterator;
  bool _cancelled = false;
  bool _submitted = false;

  Stream<Uint8List> get pcm => _output.stream.where((_) => !_cancelled);
  bool get generationSubmitted => _submitted;

  /// Stops local delivery immediately and closes the dedicated HTTP transport.
  /// Cancellation cannot promise that an already accepted request was unbilled.
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    _abortRequest();
    // Explicitly cancel the body subscription as well as closing its transport.
    // This also releases a paused/timed stream supplied by a custom client.
    final iterator = _audioIterator;
    if (iterator != null) unawaited(iterator.cancel());
    if (!_output.isClosed) unawaited(_output.close());
  }

  void _abortRequest() {
    if (!_abort.isCompleted) _abort.complete();
    _client?.close();
    _apiKey = '';
  }

  Future<void> _run() async {
    if (_cancelled) return;
    try {
      _client = _clientFactory();
      final request =
          http.AbortableRequest('POST', _endpoint, abortTrigger: _abort.future)
            ..followRedirects = false
            ..headers.addAll({
              'Authorization': 'Bearer $_apiKey',
              'Content-Type': 'application/json',
              'Accept': 'audio/pcm, application/octet-stream',
              'model': _model,
            })
            ..body = jsonEncode(_body);
      _submitted = true;
      final response = await _client!.send(request).timeout(_requestTimeout);
      _apiKey = '';
      if (_cancelled) return;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // Never follow redirects carrying credentials or copy an upstream body,
        // which may contain request text, signed URLs, or account details.
        throw FishCallTtsException(
          code: response.statusCode >= 300 && response.statusCode < 400
              ? 'redirect_refused'
              : 'http_error',
          message: response.statusCode == 402
              ? 'Fish Audio 余额或套餐不足（402），本次未自动重试。'
              : 'Fish Audio 语音请求失败（${response.statusCode}），本次未自动重试。',
          statusCode: response.statusCode,
          requestId: _safeRequestId(response.headers),
          generationSubmitted: true,
        );
      }
      final mime = response.headers['content-type']?.split(';').first.trim();
      if (mime != null &&
          mime.isNotEmpty &&
          !const {
            'application/octet-stream',
            'audio/pcm',
            'audio/x-pcm',
            'audio/raw',
            'audio/x-raw',
          }.contains(mime.toLowerCase())) {
        throw FishCallTtsException(
          code: 'unexpected_audio_format',
          message: 'Fish Audio 未返回约定的原始 PCM 音频。',
          generationSubmitted: true,
          requestId: _safeRequestId(response.headers),
        );
      }
      var total = 0;
      int? pendingByte;
      final iterator = StreamIterator(response.stream.timeout(_chunkTimeout));
      _audioIterator = iterator;
      while (await iterator.moveNext()) {
        final bytes = iterator.current;
        if (_cancelled) return;
        if (bytes.isEmpty) continue;
        total += bytes.length;
        if (total > _maximumBytes) {
          throw const FishCallTtsException(
            code: 'audio_limit',
            message: '单段通话音频超出时长上限，已停止接收。',
            generationSubmitted: true,
          );
        }
        final joined = Uint8List(bytes.length + (pendingByte == null ? 0 : 1));
        var offset = 0;
        if (pendingByte != null) joined[offset++] = pendingByte;
        joined.setRange(offset, joined.length, bytes);
        pendingByte = joined.length.isOdd ? joined.last : null;
        final aligned = joined.length - (pendingByte == null ? 0 : 1);
        if (aligned > 0) _output.add(Uint8List.sublistView(joined, 0, aligned));
      }
      if (_cancelled) return;
      if (total == 0 || pendingByte != null) {
        throw const FishCallTtsException(
          code: 'truncated_audio',
          message: 'Fish Audio 返回的 PCM 音频为空或不完整，未自动重试。',
          generationSubmitted: true,
        );
      }
    } on Object catch (error, stack) {
      if (!_cancelled && !_output.isClosed) {
        _output.addError(
          error is FishCallTtsException
              ? error
              : FishCallTtsException(
                  code: error is TimeoutException
                      ? 'timeout'
                      : 'transport_error',
                  message: error is TimeoutException
                      ? 'Fish Audio 通话语音超时，结果未知，未自动重试。'
                      : 'Fish Audio 通话语音连接中断，未自动重试。',
                  generationSubmitted: _submitted,
                  outcomeUnknown: _submitted,
                ),
          stack,
        );
      }
    } finally {
      _abortRequest();
      final iterator = _audioIterator;
      if (iterator != null) await iterator.cancel();
      _audioIterator = null;
      if (!_output.isClosed) unawaited(_output.close());
    }
  }

  static String? _safeRequestId(Map<String, String> headers) {
    final value = headers['x-request-id'] ?? headers['request-id'];
    if (value == null || !RegExp(r'^[A-Za-z0-9_.:-]{1,160}$').hasMatch(value)) {
      return null;
    }
    return value;
  }
}

class FishCallTtsException implements Exception {
  const FishCallTtsException({
    required this.code,
    required this.message,
    this.statusCode,
    this.requestId,
    this.generationSubmitted = false,
    this.outcomeUnknown = false,
  });

  final String code;
  final String message;
  final int? statusCode;
  final String? requestId;
  final bool generationSubmitted;
  final bool outcomeUnknown;

  @override
  String toString() =>
      'FishCallTtsException($code, status=$statusCode, '
      'submitted=$generationSubmitted, outcomeUnknown=$outcomeUnknown): $message';
}
