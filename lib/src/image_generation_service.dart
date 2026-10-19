import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'image_generation_config.dart';

enum ImageGenerationPhase { submitting, polling, downloading, completed }

typedef ImageGenerationProgressCallback = void Function(
  ImageGenerationPhase phase,
);
typedef ImageGenerationSleeper = Future<void> Function(Duration duration);

class ImageGenerationCancellationToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;
}

class ImageGenerationResult {
  const ImageGenerationResult({
    required this.bytes,
    required this.mimeType,
    required this.protocol,
    required this.model,
    this.sourceUrl,
  });

  final Uint8List bytes;
  final String mimeType;
  final ImageGenerationProtocol protocol;
  final String model;

  /// A diagnostic URL with its query removed. Signed download credentials are
  /// never retained in the result.
  final String? sourceUrl;
}

class ImageGenerationException implements Exception {
  const ImageGenerationException({
    required this.code,
    required this.stage,
    required this.message,
    this.statusCode,
    this.responseFormat,
    this.responseBytes,
    this.requestSubmitted = false,
    bool? outcomeUnknown,
  }) : outcomeUnknown = outcomeUnknown ?? requestSubmitted;

  final String code;
  final String stage;
  final String message;
  final int? statusCode;

  /// Only a fixed format category and length are retained, never response text.
  final String? responseFormat;
  final int? responseBytes;
  final bool requestSubmitted;

  /// A submitted request may have been billed even when its response cannot
  /// be read. Only an explicit rejection or terminal task failure clears this.
  final bool outcomeUnknown;

  @override
  String toString() {
    final status = statusCode == null ? '' : ', status=$statusCode';
    final format = responseFormat == null
        ? ''
        : ', responseFormat=$responseFormat';
    final bytes = responseBytes == null ? '' : ', responseBytes=$responseBytes';
    return 'ImageGenerationException(stage=$stage, code=$code$status$format$bytes, '
        'requestSubmitted=$requestSubmitted, outcomeUnknown=$outcomeUnknown): '
        '$message';
  }
}

/// Network-only image generation client.
///
/// It intentionally owns no settings or secret persistence. The caller reads
/// the API key from secure storage for each request and supplies it here.
class ImageGenerationService {
  ImageGenerationService({
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 900),
    this.pollInterval = const Duration(seconds: 2),
    this.maxPollAttempts = 450,
    this.maxImageBytes = 25 * 1024 * 1024,
    ImageGenerationSleeper? sleeper,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _sleeper = sleeper ?? Future<void>.delayed;

  final http.Client _client;
  final bool _ownsClient;
  final ImageGenerationSleeper _sleeper;
  final Duration requestTimeout;
  final Duration pollInterval;
  final int maxPollAttempts;
  final int maxImageBytes;

  int get _maxJsonBytes => maxImageBytes * 2 + 1024 * 1024;

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<ImageGenerationResult> generate({
    required ImageGenerationConfig config,
    required String apiKey,
    required String prompt,
    String negativePrompt = '',
    ImageGenerationCancellationToken? cancellationToken,
    ImageGenerationProgressCallback? onProgress,
    Map<String, dynamic>? comfyWorkflow,
  }) async {
    if (!config.enabled) {
      throw const ImageGenerationException(
        code: 'disabled',
        stage: 'configuration',
        message: '生图接口尚未启用。',
      );
    }
    final configError = config.validationError;
    if (configError != null) {
      throw ImageGenerationException(
        code: configError,
        stage: 'configuration',
        message: '生图接口配置无效。',
      );
    }
    final trimmedPrompt = prompt.trim();
    if (trimmedPrompt.isEmpty) {
      throw const ImageGenerationException(
        code: 'empty_prompt',
        stage: 'configuration',
        message: '生图提示词不能为空。',
      );
    }
    _throwIfCancelled(cancellationToken, requestSubmitted: false);

    final baseUri = _validatedUri(config.baseUrl, stage: 'configuration');
    final protocol = config.resolvedProtocol;
    return switch (protocol) {
      ImageGenerationProtocol.openAiImages => _generateOpenAiImages(
        baseUri: baseUri,
        config: config,
        apiKey: apiKey,
        prompt: trimmedPrompt,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
      ),
      ImageGenerationProtocol.openAiResponses => _generateOpenAiResponses(
        baseUri: baseUri,
        config: config,
        apiKey: apiKey,
        prompt: trimmedPrompt,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
      ),
      ImageGenerationProtocol.gemini => _generateGemini(
        baseUri: baseUri,
        config: config,
        apiKey: apiKey,
        prompt: trimmedPrompt,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
      ),
      ImageGenerationProtocol.syncJson => _generateSyncJson(
        endpoint: baseUri,
        config: config,
        apiKey: apiKey,
        prompt: trimmedPrompt,
        negativePrompt: negativePrompt,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
      ),
      ImageGenerationProtocol.asyncTask => _generateAsyncTask(
        endpoint: baseUri,
        config: config,
        apiKey: apiKey,
        prompt: trimmedPrompt,
        negativePrompt: negativePrompt,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
      ),
      ImageGenerationProtocol.comfyUi => _generateComfyUi(
        baseUri: baseUri,
        config: config,
        apiKey: apiKey,
        prompt: trimmedPrompt,
        negativePrompt: negativePrompt,
        workflow: comfyWorkflow,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
      ),
      ImageGenerationProtocol.auto => _generateAutoGeneric(
        endpoint: baseUri,
        config: config,
        apiKey: apiKey,
        prompt: trimmedPrompt,
        negativePrompt: negativePrompt,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
      ),
    };
  }

  Future<ImageGenerationResult> _generateOpenAiImages({
    required Uri baseUri,
    required ImageGenerationConfig config,
    required String apiKey,
    required String prompt,
    required ImageGenerationCancellationToken? cancellationToken,
    required ImageGenerationProgressCallback? onProgress,
  }) async {
    final endpoint = config.endpointPath.trim().isEmpty
        ? _openAiEndpoint(baseUri, 'images/generations')
        : _configuredEndpoint(baseUri, config.endpointPath);
    _notify(onProgress, ImageGenerationPhase.submitting);
    final response = await _postJson(
      endpoint,
      headers: _authorizationHeaders(apiKey),
      body: {
        if (config.model.trim().isNotEmpty) 'model': config.model.trim(),
        'prompt': prompt,
        'size': '${config.width}x${config.height}',
        'output_format': _providerOutputFormat(config.outputFormat),
      },
      stage: 'openai_images_submit',
      requestSubmittedOnFailure: true,
    );
    _ensureSuccess(response, stage: 'openai_images_submit', submitted: true);
    _throwIfCancelled(cancellationToken, requestSubmitted: true);
    final direct = _directImagePayload(response);
    final decoded = direct == null
        ? _decodeJson(response, stage: 'openai_images_result')
        : null;
    final payload = direct ?? _findGenericImagePayload(decoded);
    if (payload == null) {
      throw const ImageGenerationException(
        code: 'missing_image',
        stage: 'openai_images_result',
        message: '接口返回成功，但没有图片数据。',
        requestSubmitted: true,
      );
    }
    return _materialize(
      payload,
      endpoint: endpoint,
      apiKey: apiKey,
      protocol: ImageGenerationProtocol.openAiImages,
      config: config,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }

  Future<ImageGenerationResult> _generateOpenAiResponses({
    required Uri baseUri,
    required ImageGenerationConfig config,
    required String apiKey,
    required String prompt,
    required ImageGenerationCancellationToken? cancellationToken,
    required ImageGenerationProgressCallback? onProgress,
  }) async {
    final endpoint = config.endpointPath.trim().isEmpty
        ? _openAiEndpoint(baseUri, 'responses')
        : _configuredEndpoint(baseUri, config.endpointPath);
    _notify(onProgress, ImageGenerationPhase.submitting);
    final response = await _postJson(
      endpoint,
      headers: _authorizationHeaders(apiKey),
      body: {
        if (config.model.trim().isNotEmpty) 'model': config.model.trim(),
        'input': prompt,
        'tools': [
          {
            'type': 'image_generation',
            'size': '${config.width}x${config.height}',
            'output_format': _providerOutputFormat(config.outputFormat),
          },
        ],
      },
      stage: 'openai_responses_submit',
      requestSubmittedOnFailure: true,
    );
    _ensureSuccess(response, stage: 'openai_responses_submit', submitted: true);
    _throwIfCancelled(cancellationToken, requestSubmitted: true);
    final direct = _directImagePayload(response);
    final decoded = direct == null
        ? _decodeJson(response, stage: 'openai_responses_result')
        : null;
    final payload =
        direct ??
        _findOpenAiResponsePayload(decoded) ??
        _findGenericImagePayload(decoded);
    if (payload == null) {
      throw const ImageGenerationException(
        code: 'missing_image',
        stage: 'openai_responses_result',
        message: 'Responses 接口没有返回 image_generation 结果。',
        requestSubmitted: true,
      );
    }
    return _materialize(
      payload,
      endpoint: endpoint,
      apiKey: apiKey,
      protocol: ImageGenerationProtocol.openAiResponses,
      config: config,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }

  Future<ImageGenerationResult> _generateGemini({
    required Uri baseUri,
    required ImageGenerationConfig config,
    required String apiKey,
    required String prompt,
    required ImageGenerationCancellationToken? cancellationToken,
    required ImageGenerationProgressCallback? onProgress,
  }) async {
    final endpoint = config.endpointPath.trim().isEmpty
        ? _geminiEndpoint(baseUri, config.model)
        : _configuredEndpoint(baseUri, config.endpointPath);
    _notify(onProgress, ImageGenerationPhase.submitting);
    final response = await _postJson(
      endpoint,
      headers: _geminiHeaders(apiKey),
      body: {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': prompt},
            ],
          },
        ],
        'generationConfig': {
          'responseModalities': ['TEXT', 'IMAGE'],
          'imageConfig': {'aspectRatio': config.aspectRatio.trim()},
        },
      },
      stage: 'gemini_submit',
      requestSubmittedOnFailure: true,
    );
    _ensureSuccess(response, stage: 'gemini_submit', submitted: true);
    _throwIfCancelled(cancellationToken, requestSubmitted: true);
    final direct = _directImagePayload(response);
    final decoded = direct == null
        ? _decodeJson(response, stage: 'gemini_result')
        : null;
    final payload =
        direct ??
        _findGeminiPayload(decoded) ??
        _findGenericImagePayload(decoded);
    if (payload == null) {
      throw const ImageGenerationException(
        code: 'missing_image',
        stage: 'gemini_result',
        message: 'Gemini 返回成功，但没有 inlineData 图片。',
        requestSubmitted: true,
      );
    }
    return _materialize(
      payload,
      endpoint: endpoint,
      apiKey: apiKey,
      protocol: ImageGenerationProtocol.gemini,
      config: config,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }

  Future<ImageGenerationResult> _generateSyncJson({
    required Uri endpoint,
    required ImageGenerationConfig config,
    required String apiKey,
    required String prompt,
    required String negativePrompt,
    required ImageGenerationCancellationToken? cancellationToken,
    required ImageGenerationProgressCallback? onProgress,
  }) async {
    endpoint = _configuredEndpoint(endpoint, config.endpointPath);
    _notify(onProgress, ImageGenerationPhase.submitting);
    final response = await _postJson(
      endpoint,
      headers: _authorizationHeaders(apiKey),
      body: _genericRequestBody(config, prompt, negativePrompt),
      stage: 'sync_json_submit',
      requestSubmittedOnFailure: true,
    );
    _ensureSuccess(response, stage: 'sync_json_submit', submitted: true);
    _throwIfCancelled(cancellationToken, requestSubmitted: true);
    final direct = _directImagePayload(response);
    final decoded = direct == null
        ? _decodeJson(response, stage: 'sync_json_result')
        : null;
    final payload = direct ?? _findGenericImagePayload(decoded);
    if (payload == null) {
      throw const ImageGenerationException(
        code: 'missing_image',
        stage: 'sync_json_result',
        message: '同步接口返回成功，但没有可识别的图片 URL 或 Base64。',
        requestSubmitted: true,
      );
    }
    return _materialize(
      payload,
      endpoint: endpoint,
      apiKey: apiKey,
      protocol: ImageGenerationProtocol.syncJson,
      config: config,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }

  Future<ImageGenerationResult> _generateAsyncTask({
    required Uri endpoint,
    required ImageGenerationConfig config,
    required String apiKey,
    required String prompt,
    required String negativePrompt,
    required ImageGenerationCancellationToken? cancellationToken,
    required ImageGenerationProgressCallback? onProgress,
  }) async {
    endpoint = _configuredEndpoint(endpoint, config.endpointPath);
    _notify(onProgress, ImageGenerationPhase.submitting);
    final response = await _postJson(
      endpoint,
      headers: _authorizationHeaders(apiKey),
      body: _genericRequestBody(config, prompt, negativePrompt),
      stage: 'async_submit',
      requestSubmittedOnFailure: true,
    );
    _ensureSuccess(response, stage: 'async_submit', submitted: true);
    _throwIfCancelled(cancellationToken, requestSubmitted: true);
    final direct = _directImagePayload(response);
    final decoded = direct == null
        ? _decodeJson(response, stage: 'async_submit_result')
        : null;
    final immediate = direct ?? _findGenericImagePayload(decoded);
    if (immediate != null) {
      return _materialize(
        immediate,
        endpoint: endpoint,
        apiKey: apiKey,
        protocol: ImageGenerationProtocol.asyncTask,
        config: config,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
      );
    }
    final task = _taskReference(decoded, response.headers, endpoint, config);
    if (task == null) {
      throw const ImageGenerationException(
        code: 'missing_task_id',
        stage: 'async_submit_result',
        message: '异步接口没有返回任务 ID 或状态地址。',
        requestSubmitted: true,
        outcomeUnknown: true,
      );
    }
    return _pollAsyncTask(
      task: task,
      endpoint: endpoint,
      apiKey: apiKey,
      protocol: ImageGenerationProtocol.asyncTask,
      config: config,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }

  Future<ImageGenerationResult> _generateAutoGeneric({
    required Uri endpoint,
    required ImageGenerationConfig config,
    required String apiKey,
    required String prompt,
    required String negativePrompt,
    required ImageGenerationCancellationToken? cancellationToken,
    required ImageGenerationProgressCallback? onProgress,
  }) async {
    endpoint = _configuredEndpoint(endpoint, config.endpointPath);
    // The unknown endpoint is submitted exactly once. The returned shape then
    // decides whether it is a synchronous result or an asynchronous task.
    _notify(onProgress, ImageGenerationPhase.submitting);
    final response = await _postJson(
      endpoint,
      headers: _authorizationHeaders(apiKey),
      body: _genericRequestBody(config, prompt, negativePrompt),
      stage: 'auto_submit',
      requestSubmittedOnFailure: true,
    );
    _ensureSuccess(response, stage: 'auto_submit', submitted: true);
    _throwIfCancelled(cancellationToken, requestSubmitted: true);
    final direct = _directImagePayload(response);
    final decoded = direct == null
        ? _decodeJson(response, stage: 'auto_result')
        : null;
    final payload =
        direct ??
        _findOpenAiResponsePayload(decoded) ??
        _findGeminiPayload(decoded) ??
        _findGenericImagePayload(decoded);
    if (payload != null) {
      return _materialize(
        payload,
        endpoint: endpoint,
        apiKey: apiKey,
        protocol: ImageGenerationProtocol.syncJson,
        config: config,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
      );
    }
    final task = _taskReference(decoded, response.headers, endpoint, config);
    if (task == null) {
      throw const ImageGenerationException(
        code: 'unknown_response_shape',
        stage: 'auto_result',
        message: '无法从首次响应识别同步图片或异步任务；请求不会自动重发。',
        requestSubmitted: true,
        outcomeUnknown: true,
      );
    }
    return _pollAsyncTask(
      task: task,
      endpoint: endpoint,
      apiKey: apiKey,
      protocol: ImageGenerationProtocol.asyncTask,
      config: config,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }

  Future<ImageGenerationResult> _generateComfyUi({
    required Uri baseUri,
    required ImageGenerationConfig config,
    required String apiKey,
    required String prompt,
    required String negativePrompt,
    required Map<String, dynamic>? workflow,
    required ImageGenerationCancellationToken? cancellationToken,
    required ImageGenerationProgressCallback? onProgress,
  }) async {
    final configured = _configuredEndpoint(baseUri, config.endpointPath);
    final root = _comfyRoot(configured);
    final submitUri = config.endpointPath.trim().isEmpty
        ? _appendPath(root, 'prompt')
        : configured;
    final graph = workflow == null
        ? _defaultComfyWorkflow(config, prompt, negativePrompt)
        : _replaceWorkflowPlaceholders(
            workflow,
            config: config,
            prompt: prompt,
            negativePrompt: negativePrompt,
          ) as Map<String, dynamic>;
    _notify(onProgress, ImageGenerationPhase.submitting);
    final response = await _postJson(
      submitUri,
      headers: _authorizationHeaders(apiKey),
      body: {'prompt': graph},
      stage: 'comfy_submit',
      requestSubmittedOnFailure: true,
    );
    _ensureSuccess(response, stage: 'comfy_submit', submitted: true);
    _throwIfCancelled(cancellationToken, requestSubmitted: true);
    final decoded = _decodeJson(response, stage: 'comfy_submit_result');
    final promptId = _readString(decoded, const [
      ['prompt_id'],
      ['promptId'],
      ['data', 'prompt_id'],
    ]);
    if (promptId == null) {
      throw const ImageGenerationException(
        code: 'missing_prompt_id',
        stage: 'comfy_submit_result',
        message: 'ComfyUI 没有返回 prompt_id。',
        requestSubmitted: true,
        outcomeUnknown: true,
      );
    }

    final historyUri = _appendPath(
      root,
      'history/${Uri.encodeComponent(promptId)}',
    );
    for (var attempt = 0; attempt < _pollLimit(config); attempt++) {
      _throwIfCancelled(cancellationToken, requestSubmitted: true);
      _notify(onProgress, ImageGenerationPhase.polling);
      await _sleeper(_pollDelay(config));
      final history = await _get(
        historyUri,
        headers: _authorizationHeaders(apiKey),
        stage: 'comfy_poll',
        requestSubmittedOnFailure: true,
        maxBytes: _maxJsonBytes,
      );
      _ensureSuccess(history, stage: 'comfy_poll', submitted: true);
      final historyJson = _decodeJson(history, stage: 'comfy_history');
      final image = _findComfyOutput(historyJson, promptId);
      if (image != null) {
        final viewUri = _appendPath(root, 'view').replace(
          queryParameters: {
            'filename': image.filename,
            if (image.subfolder.isNotEmpty) 'subfolder': image.subfolder,
            if (image.type.isNotEmpty) 'type': image.type,
          },
        );
        return _materialize(
          _UrlImagePayload(viewUri.toString()),
          endpoint: root,
          apiKey: apiKey,
          protocol: ImageGenerationProtocol.comfyUi,
          config: config,
          cancellationToken: cancellationToken,
          onProgress: onProgress,
        );
      }
      final historyEntry = historyJson is Map
          ? historyJson[promptId] ?? historyJson
          : historyJson;
      if (_isFailureStatus(_readStatus(historyEntry))) {
        throw const ImageGenerationException(
          code: 'task_failed',
          stage: 'comfy_history',
          message: 'ComfyUI 工作流执行失败。',
          requestSubmitted: true,
          outcomeUnknown: false,
        );
      }
    }
    throw const ImageGenerationException(
      code: 'task_timeout',
      stage: 'comfy_poll',
      message: 'ComfyUI 任务仍未完成；不会自动重新提交。',
      requestSubmitted: true,
      outcomeUnknown: true,
    );
  }

  Future<ImageGenerationResult> _pollAsyncTask({
    required _TaskReference task,
    required Uri endpoint,
    required String apiKey,
    required ImageGenerationProtocol protocol,
    required ImageGenerationConfig config,
    required ImageGenerationCancellationToken? cancellationToken,
    required ImageGenerationProgressCallback? onProgress,
  }) async {
    for (var attempt = 0; attempt < _pollLimit(config); attempt++) {
      _throwIfCancelled(cancellationToken, requestSubmitted: true);
      _notify(onProgress, ImageGenerationPhase.polling);
      await _sleeper(_pollDelay(config));
      final response = await _get(
        task.statusUri,
        headers: _sameOrigin(endpoint, task.statusUri)
            ? _authorizationHeaders(apiKey)
            : const {'Accept': 'application/json'},
        stage: 'async_poll',
        requestSubmittedOnFailure: true,
        maxBytes: _maxJsonBytes,
      );
      if (_isRedirect(response.statusCode)) {
        final location = response.headers['location'];
        if (location != null && location.trim().isNotEmpty) {
          return _materialize(
            _UrlImagePayload(task.statusUri.resolve(location).toString()),
            endpoint: endpoint,
            apiKey: apiKey,
            protocol: protocol,
            config: config,
            cancellationToken: cancellationToken,
            onProgress: onProgress,
          );
        }
      }
      _ensureSuccess(response, stage: 'async_poll', submitted: true);
      final direct = _directImagePayload(response);
      final decoded = direct == null
          ? _decodeJson(response, stage: 'async_poll_result')
          : null;
      final payload = direct ?? _findGenericImagePayload(decoded);
      if (payload != null) {
        return _materialize(
          payload,
          endpoint: endpoint,
          apiKey: apiKey,
          protocol: protocol,
          config: config,
          cancellationToken: cancellationToken,
          onProgress: onProgress,
        );
      }
      final status = _readStatus(decoded);
      if (_isFailureStatus(status)) {
        throw const ImageGenerationException(
          code: 'task_failed',
          stage: 'async_poll_result',
          message: '异步生图任务失败或被取消。',
          requestSubmitted: true,
          outcomeUnknown: false,
        );
      }
      if (_isSuccessStatus(status)) {
        throw const ImageGenerationException(
          code: 'missing_image',
          stage: 'async_poll_result',
          message: '异步任务已完成，但没有返回图片。',
          requestSubmitted: true,
        );
      }
    }
    throw const ImageGenerationException(
      code: 'task_timeout',
      stage: 'async_poll',
      message: '异步生图任务仍未完成；不会自动重新提交。',
      requestSubmitted: true,
      outcomeUnknown: true,
    );
  }

  Future<ImageGenerationResult> _materialize(
    _ImagePayload payload, {
    required Uri endpoint,
    required String apiKey,
    required ImageGenerationProtocol protocol,
    required ImageGenerationConfig config,
    required ImageGenerationCancellationToken? cancellationToken,
    required ImageGenerationProgressCallback? onProgress,
  }) async {
    _throwIfCancelled(cancellationToken, requestSubmitted: true);
    late _ValidatedImage image;
    String? sourceUrl;
    if (payload is _BinaryImagePayload) {
      image = _validatedImage(payload.bytes, payload.mimeType);
    } else if (payload is _InlineImagePayload) {
      final inline = _decodeInlinePayload(payload);
      image = _validatedImage(inline.bytes, inline.mimeType);
    } else if (payload is _UrlImagePayload) {
      _notify(onProgress, ImageGenerationPhase.downloading);
      final target = endpoint.resolve(payload.url);
      image = await _downloadImage(
        target,
        endpoint: endpoint,
        apiKey: apiKey,
        cancellationToken: cancellationToken,
      );
      sourceUrl = _redactedUrl(target);
    } else {
      throw StateError('Unknown image payload type');
    }
    _notify(onProgress, ImageGenerationPhase.completed);
    return ImageGenerationResult(
      bytes: image.bytes,
      mimeType: image.mimeType,
      protocol: protocol,
      model: config.model.trim(),
      sourceUrl: sourceUrl,
    );
  }

  Future<_ValidatedImage> _downloadImage(
    Uri initial, {
    required Uri endpoint,
    required String apiKey,
    required ImageGenerationCancellationToken? cancellationToken,
  }) async {
    var current = _validatedUri(initial.toString(), stage: 'image_download');
    for (var redirects = 0; redirects <= 2; redirects++) {
      _throwIfCancelled(cancellationToken, requestSubmitted: true);
      final sameOrigin = _sameOrigin(endpoint, current);
      final response = await _get(
        current,
        headers: {
          'Accept': 'image/*',
          if (sameOrigin) ..._authorizationHeaders(apiKey),
        },
        stage: 'image_download',
        requestSubmittedOnFailure: true,
        maxBytes: maxImageBytes,
      );
      if (_isRedirect(response.statusCode)) {
        final location = response.headers['location'];
        if (location == null || location.trim().isEmpty || redirects == 2) {
          throw const ImageGenerationException(
            code: 'redirect_rejected',
            stage: 'image_download',
            message: '图片下载重定向无效或次数过多。',
            requestSubmitted: true,
          );
        }
        current = _validatedUri(
          current.resolve(location).toString(),
          stage: 'image_download',
        );
        continue;
      }
      _ensureSuccess(response, stage: 'image_download', submitted: true);
      return _validatedImage(
        response.bytes,
        _normalizedMime(response.headers['content-type']),
      );
    }
    throw StateError('Redirect loop ended unexpectedly');
  }

  Map<String, dynamic> _genericRequestBody(
    ImageGenerationConfig config,
    String prompt,
    String negativePrompt,
  ) => {
    'prompt': prompt,
    if (negativePrompt.trim().isNotEmpty)
      'negative_prompt': negativePrompt.trim(),
    if (config.model.trim().isNotEmpty) 'model': config.model.trim(),
    'width': config.width,
    'height': config.height,
    'size': '${config.width}x${config.height}',
    'aspect_ratio': config.aspectRatio.trim(),
    'output_format': _providerOutputFormat(config.outputFormat),
  };

  Map<String, String> _authorizationHeaders(String apiKey) {
    final key = apiKey.trim();
    return {
      'Accept': 'application/json',
      if (key.isNotEmpty) 'Authorization': 'Bearer $key',
    };
  }

  Map<String, String> _geminiHeaders(String apiKey) {
    final key = apiKey.trim();
    return {
      'Accept': 'application/json',
      if (key.isNotEmpty) 'x-goog-api-key': key,
    };
  }

  Future<_TransportResponse> _postJson(
    Uri uri, {
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required String stage,
    required bool requestSubmittedOnFailure,
  }) {
    final request = http.Request('POST', uri)
      ..followRedirects = false
      ..headers.addAll({...headers, 'Content-Type': 'application/json'})
      ..body = jsonEncode(body);
    return _send(
      request,
      stage: stage,
      requestSubmittedOnFailure: requestSubmittedOnFailure,
      maxBytes: _maxJsonBytes,
    );
  }

  Future<_TransportResponse> _get(
    Uri uri, {
    required Map<String, String> headers,
    required String stage,
    required bool requestSubmittedOnFailure,
    required int maxBytes,
  }) {
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers.addAll(headers);
    return _send(
      request,
      stage: stage,
      requestSubmittedOnFailure: requestSubmittedOnFailure,
      maxBytes: maxBytes,
    );
  }

  Future<_TransportResponse> _send(
    http.BaseRequest request, {
    required String stage,
    required bool requestSubmittedOnFailure,
    required int maxBytes,
  }) async {
    try {
      final streamed = await _client.send(request).timeout(requestTimeout);
      final declaredLength = int.tryParse(
        streamed.headers['content-length'] ?? '',
      );
      if (declaredLength != null && declaredLength > maxBytes) {
        throw ImageGenerationException(
          code: 'response_too_large',
          stage: stage,
          message: '接口响应超过允许大小。',
          statusCode: streamed.statusCode,
          requestSubmitted: requestSubmittedOnFailure,
        );
      }
      final bytes = await _readLimited(
        streamed.stream,
        maxBytes,
      ).timeout(requestTimeout);
      return _TransportResponse(
        statusCode: streamed.statusCode,
        headers: streamed.headers,
        bytes: bytes,
      );
    } on ImageGenerationException {
      rethrow;
    } on TimeoutException {
      throw ImageGenerationException(
        code: 'network_timeout',
        stage: stage,
        message: '生图接口请求超时。',
        requestSubmitted: requestSubmittedOnFailure,
        outcomeUnknown: requestSubmittedOnFailure,
      );
    } on Object {
      // Never include the raw exception: some transports include full request
      // headers or signed URLs in their error text.
      throw ImageGenerationException(
        code: 'network_error',
        stage: stage,
        message: '无法连接生图接口。',
        requestSubmitted: requestSubmittedOnFailure,
        outcomeUnknown: requestSubmittedOnFailure,
      );
    }
  }

  Future<Uint8List> _readLimited(Stream<List<int>> stream, int limit) async {
    final builder = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in stream) {
      length += chunk.length;
      if (length > limit) {
        throw const ImageGenerationException(
          code: 'response_too_large',
          stage: 'response_read',
          message: '接口响应超过允许大小。',
          requestSubmitted: true,
        );
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  _ImagePayload? _directImagePayload(_TransportResponse response) {
    final mime = _normalizedMime(response.headers['content-type']);
    if (mime?.startsWith('image/') == true ||
        _detectImageMime(response.bytes) != null) {
      return _BinaryImagePayload(response.bytes, mimeType: mime);
    }
    return null;
  }

  Object? _decodeJson(_TransportResponse response, {required String stage}) {
    // An empty 202 may still carry the asynchronous status URL in Location.
    if (response.bytes.isEmpty) return const <String, dynamic>{};
    late String text;
    try {
      text = utf8.decode(response.bytes).replaceFirst(RegExp(r'^\uFEFF'), '');
    } on FormatException {
      throw _responseError(
        response,
        stage: stage,
        code: 'invalid_json',
        message: '接口响应不是有效的 UTF-8 JSON。请核对协议和生图端点；请求不会自动重发。',
      );
    }
    final trimmed = text.trimLeft();
    final mime = _normalizedMime(response.headers['content-type']);
    if (mime == 'text/event-stream' ||
        RegExp(r'^(?:data:|event:|:)').hasMatch(trimmed)) {
      return _decodeEventStream(response, text, stage: stage);
    }
    try {
      return jsonDecode(text);
    } on FormatException {
      final html =
          mime == 'text/html' ||
          RegExp(
            r'^<(?:!doctype\s+html|html|head|body)\b',
            caseSensitive: false,
          ).hasMatch(trimmed);
      throw _responseError(
        response,
        stage: stage,
        code: html ? 'html_response' : 'invalid_json',
        format: html ? 'html' : null,
        message: html
            ? '接口返回了 HTML 网页，而非生图结果。请填写完整生图端点；OpenAI 兼容服务可选择 OpenAI Images 协议并填写 /v1 基础地址。请求不会自动重发。'
            : '接口返回的 JSON 无法解析，响应可能截断或协议不符。请求不会自动重发。',
      );
    }
  }

  /// Accept completed image events only. Preview frames and incomplete streams
  /// must never be mistaken for the final paid generation result.
  Object? _decodeEventStream(
    _TransportResponse response,
    String text, {
    required String stage,
  }) {
    Object? completed;
    Object? pending;
    var done = false;
    final frames = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n\n');
    for (final frame in frames) {
      var event = '';
      final data = <String>[];
      for (final line in frame.split('\n')) {
        if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          final value = line.substring(5);
          data.add(value.startsWith(' ') ? value.substring(1) : value);
        }
      }
      if (data.isEmpty) {
        if (event == 'error') {
          throw _responseError(
            response,
            stage: stage,
            code: 'event_stream_error',
            format: 'event_stream',
            message: '生图流返回错误事件；不会自动重新提交。',
          );
        }
        continue;
      }
      final payloadText = data.join('\n').trim();
      if (payloadText == '[DONE]') {
        done = true;
        continue;
      }
      if (payloadText.isEmpty) continue;
      late Object? decoded;
      try {
        decoded = jsonDecode(payloadText);
      } on FormatException {
        throw _responseError(
          response,
          stage: stage,
          code: 'invalid_json',
          format: 'event_stream',
          message: '生图流中的 JSON 数据不完整；不会自动重新提交。',
        );
      }
      final type = decoded is Map && decoded['type'] is String
          ? decoded['type'] as String
          : event;
      if (event == 'error' ||
          type == 'error' ||
          type.endsWith('.failed') ||
          type.endsWith('.error') ||
          decoded is Map && decoded['error'] != null ||
          _isFailureStatus(_readStatus(decoded))) {
        throw _responseError(
          response,
          stage: stage,
          code: 'event_stream_error',
          format: 'event_stream',
          message: '生图流返回错误事件；不会自动重新提交。',
        );
      }
      if (type.contains('partial') ||
          type.contains('delta') ||
          event.contains('partial') ||
          event.contains('delta')) {
        continue;
      }
      final payload =
          _findOpenAiResponsePayload(decoded) ??
          _findGeminiPayload(decoded) ??
          _findGenericImagePayload(decoded);
      if (payload == null) continue;
      final terminal =
          type.endsWith('.completed') ||
          type.endsWith('.done') ||
          const {'complete', 'completed', 'done'}.contains(type) ||
          _isSuccessStatus(_readStatus(decoded));
      if (terminal) {
        completed = decoded;
      } else {
        pending = decoded;
      }
    }
    if (completed != null) return completed;
    if (done && pending != null) return pending;
    throw _responseError(
      response,
      stage: stage,
      code: 'incomplete_event_stream',
      format: 'event_stream',
      message: '生图流未返回完整的最终图片。结果仍未知，不会自动重新提交。',
    );
  }

  ImageGenerationException _responseError(
    _TransportResponse response, {
    required String stage,
    required String code,
    required String message,
    String? format,
  }) => ImageGenerationException(
    code: code,
    stage: stage,
    message: message,
    statusCode: response.statusCode,
    responseFormat: format ?? _responseFormat(response),
    responseBytes: response.bytes.length,
    requestSubmitted: true,
  );

  String _responseFormat(_TransportResponse response) {
    final mime = _normalizedMime(response.headers['content-type']);
    if (mime == 'application/json' || mime?.endsWith('+json') == true) {
      return 'json';
    }
    if (mime == 'text/html') return 'html';
    if (mime == 'text/event-stream') return 'event_stream';
    if (mime?.startsWith('image/') == true) return 'image';
    if (mime == 'application/octet-stream') return 'binary';
    if (mime?.startsWith('text/') == true) return 'text';
    return 'other';
  }

  void _ensureSuccess(
    _TransportResponse response, {
    required String stage,
    required bool submitted,
  }) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw ImageGenerationException(
      code: 'http_error',
      stage: stage,
      message: '生图接口返回 HTTP ${response.statusCode}。',
      statusCode: response.statusCode,
      requestSubmitted: submitted,
      outcomeUnknown:
          submitted &&
          (response.statusCode >= 500 || !stage.endsWith('_submit')),
    );
  }

  Uri _validatedUri(String value, {required String stage}) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ImageGenerationException(
        code: 'invalid_url',
        stage: stage,
        message: '生图接口地址无效。',
        requestSubmitted: stage != 'configuration',
      );
    }
    final loopback = _isLoopback(uri.host);
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) {
      throw ImageGenerationException(
        code: 'https_required',
        stage: stage,
        message: '公网生图接口必须使用 HTTPS。',
        requestSubmitted: stage != 'configuration',
      );
    }
    return uri;
  }

  bool _isLoopback(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'localhost' ||
        normalized == '127.0.0.1' ||
        normalized == '::1' ||
        normalized.endsWith('.localhost');
  }

  Uri _openAiEndpoint(Uri base, String target) {
    final path = base.path.replaceAll(RegExp(r'/+$'), '');
    final known = RegExp(
      r'/(?:images/generations|responses|chat/completions)$',
    );
    if (target == 'responses' && path.endsWith('/responses') ||
        target == 'images/generations' &&
            path.endsWith('/images/generations')) {
      return base.replace(path: path);
    }
    if (known.hasMatch(path)) {
      return base.replace(path: path.replaceFirst(known, '/$target'));
    }
    if (path.isEmpty) {
      return base.replace(path: '/v1/$target');
    }
    return base.replace(path: '$path/$target');
  }

  Uri _geminiEndpoint(Uri base, String model) {
    final path = base.path.replaceAll(RegExp(r'/+$'), '');
    if (path.toLowerCase().contains(':generatecontent')) {
      return base.replace(path: path);
    }
    var modelName = model.trim();
    if (modelName.startsWith('models/')) {
      modelName = modelName.substring('models/'.length);
    }
    if (modelName.isEmpty) modelName = 'gemini-2.5-flash-image';
    final prefix = path.isEmpty ? '/v1beta' : path;
    return base.replace(
      path: '$prefix/models/${Uri.encodeComponent(modelName)}:generateContent',
    );
  }

  Uri _configuredEndpoint(Uri base, String endpointPath) {
    final value = endpointPath.trim();
    if (value.isEmpty) return base;
    final absolute = Uri.tryParse(value);
    if (absolute != null && absolute.hasScheme) {
      return _validatedUri(value, stage: 'configuration');
    }
    final baseDirectory = base.replace(
      path: '${base.path.replaceAll(RegExp(r'/+$'), '')}/',
      query: '',
      fragment: '',
    );
    return baseDirectory.resolve(value);
  }

  Uri _comfyRoot(Uri base) {
    var path = base.path.replaceAll(RegExp(r'/+$'), '');
    path = path.replaceFirst(RegExp(r'/(prompt|history(?:/[^/]+)?|view)$'), '');
    return base.replace(path: path.isEmpty ? '/' : path, query: null);
  }

  Uri _appendPath(Uri base, String suffix) {
    final path = base.path.replaceAll(RegExp(r'/+$'), '');
    return base.replace(path: '$path/$suffix', query: null);
  }

  Map<String, dynamic> _defaultComfyWorkflow(
    ImageGenerationConfig config,
    String prompt,
    String negativePrompt,
  ) => {
    '1': {
      'class_type': 'CheckpointLoaderSimple',
      'inputs': {'ckpt_name': config.model.trim()},
    },
    '2': {
      'class_type': 'CLIPTextEncode',
      'inputs': {
        'text': prompt,
        'clip': ['1', 1],
      },
    },
    '3': {
      'class_type': 'CLIPTextEncode',
      'inputs': {
        'text': negativePrompt,
        'clip': ['1', 1],
      },
    },
    '4': {
      'class_type': 'EmptyLatentImage',
      'inputs': {
        'width': config.width,
        'height': config.height,
        'batch_size': 1,
      },
    },
    '5': {
      'class_type': 'KSampler',
      'inputs': {
        'seed': Random().nextInt(0x7fffffff),
        'steps': 20,
        'cfg': 7,
        'sampler_name': 'euler',
        'scheduler': 'normal',
        'denoise': 1,
        'model': ['1', 0],
        'positive': ['2', 0],
        'negative': ['3', 0],
        'latent_image': ['4', 0],
      },
    },
    '6': {
      'class_type': 'VAEDecode',
      'inputs': {
        'samples': ['5', 0],
        'vae': ['1', 2],
      },
    },
    '7': {
      'class_type': 'SaveImage',
      'inputs': {
        'filename_prefix': 'AgentAtelierR',
        'images': ['6', 0],
      },
    },
  };

  Object? _replaceWorkflowPlaceholders(
    Object? value, {
    required ImageGenerationConfig config,
    required String prompt,
    required String negativePrompt,
  }) {
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          '${entry.key}': _replaceWorkflowPlaceholders(
            entry.value,
            config: config,
            prompt: prompt,
            negativePrompt: negativePrompt,
          ),
      };
    }
    if (value is List) {
      return [
        for (final item in value)
          _replaceWorkflowPlaceholders(
            item,
            config: config,
            prompt: prompt,
            negativePrompt: negativePrompt,
          ),
      ];
    }
    if (value is! String) return value;
    if (value == r'${width}') return config.width;
    if (value == r'${height}') return config.height;
    return value
        .replaceAll(r'${prompt}', prompt)
        .replaceAll(r'${negative_prompt}', negativePrompt)
        .replaceAll(r'${model}', config.model.trim())
        .replaceAll(r'${width}', '${config.width}')
        .replaceAll(r'${height}', '${config.height}');
  }

  _TaskReference? _taskReference(
    Object? decoded,
    Map<String, String> headers,
    Uri endpoint,
    ImageGenerationConfig config,
  ) {
    final id = _readString(decoded, const [
      ['task_id'],
      ['taskId'],
      ['id'],
      ['request_id'],
      ['prediction_id'],
      ['data', 'task_id'],
      ['data', 'taskId'],
      ['data', 'id'],
      ['output', 'task_id'],
    ]);
    final explicitUrl =
        _readString(decoded, const [
          ['status_url'],
          ['statusUrl'],
          ['poll_url'],
          ['pollUrl'],
          ['urls', 'get'],
          ['urls', 'status'],
          ['data', 'status_url'],
          ['data', 'statusUrl'],
        ]) ??
        headers['location'];
    if (explicitUrl != null && explicitUrl.trim().isNotEmpty) {
      final status = _validatedUri(
        endpoint.resolve(explicitUrl).toString(),
        stage: 'async_submit_result',
      );
      return _TaskReference(id: id ?? '', statusUri: status);
    }
    if (id == null || id.isEmpty) return null;
    final template = config.statusEndpointTemplate.trim();
    if (template.isNotEmpty) {
      final replaced = template.replaceAll(
        '{task_id}',
        Uri.encodeComponent(id),
      );
      return _TaskReference(
        id: id,
        statusUri: _configuredEndpoint(endpoint, replaced),
      );
    }
    final path = endpoint.path.replaceAll(RegExp(r'/+$'), '');
    final encoded = Uri.encodeComponent(id);
    final statusPath = RegExp(r'/(tasks|jobs|predictions)$').hasMatch(path)
        ? '$path/$encoded'
        : '${path.replaceFirst(RegExp(r'/[^/]*$'), '')}/tasks/$encoded';
    return _TaskReference(
      id: id,
      statusUri: endpoint.replace(path: statusPath, query: null),
    );
  }

  Duration _pollDelay(ImageGenerationConfig config) {
    if (pollInterval != const Duration(seconds: 2)) return pollInterval;
    return Duration(seconds: config.pollIntervalSeconds);
  }

  int _pollLimit(ImageGenerationConfig config) =>
      min(maxPollAttempts, config.maxPollAttempts);

  String? _readString(Object? root, List<List<String>> paths) {
    for (final path in paths) {
      Object? current = root;
      for (final segment in path) {
        if (current is! Map || !current.containsKey(segment)) {
          current = null;
          break;
        }
        current = current[segment];
      }
      if (current is String && current.trim().isNotEmpty) {
        return current.trim();
      }
      if (current is num) return '$current';
    }
    return null;
  }

  String? _readStatus(Object? decoded) => _readString(decoded, const [
    ['status'],
    ['state'],
    ['phase'],
    ['data', 'status'],
    ['data', 'state'],
    ['output', 'status'],
    ['status', 'status_str'],
  ]);

  bool _isSuccessStatus(String? value) {
    final status = value?.trim().toLowerCase();
    return const {
      'completed',
      'complete',
      'succeeded',
      'success',
      'done',
      'ready',
      'finished',
    }.contains(status);
  }

  bool _isFailureStatus(String? value) {
    final status = value?.trim().toLowerCase();
    return const {
      'failed',
      'failure',
      'error',
      'cancelled',
      'canceled',
      'rejected',
      'blocked',
    }.contains(status);
  }

  _ImagePayload? _findOpenAiResponsePayload(Object? value) {
    if (value is Map) {
      if (value['type'] == 'image_generation_call') {
        final result = value['result'];
        final payload = _payloadFromImageValue(
          result,
          mimeType:
              value['mime_type']?.toString() ?? value['mimeType']?.toString(),
        );
        if (payload != null) return payload;
      }
      for (final child in value.values) {
        final payload = _findOpenAiResponsePayload(child);
        if (payload != null) return payload;
      }
    } else if (value is List) {
      for (final child in value) {
        final payload = _findOpenAiResponsePayload(child);
        if (payload != null) return payload;
      }
    }
    return null;
  }

  _ImagePayload? _findGeminiPayload(Object? value) {
    if (value is Map) {
      final inline = value['inlineData'] ?? value['inline_data'];
      if (inline is Map) {
        final data = inline['data'];
        if (data is String && data.trim().isNotEmpty) {
          return _InlineImagePayload(
            data,
            mimeType:
                inline['mimeType']?.toString() ??
                inline['mime_type']?.toString(),
          );
        }
      }
      final imageBytes = value['imageBytes'] ?? value['image_bytes'];
      if (imageBytes is String && imageBytes.trim().isNotEmpty) {
        return _InlineImagePayload(
          imageBytes,
          mimeType:
              value['mimeType']?.toString() ?? value['mime_type']?.toString(),
        );
      }
      for (final child in value.values) {
        final payload = _findGeminiPayload(child);
        if (payload != null) return payload;
      }
    } else if (value is List) {
      for (final child in value) {
        final payload = _findGeminiPayload(child);
        if (payload != null) return payload;
      }
    }
    return null;
  }

  _ImagePayload? _findGenericImagePayload(
    Object? value, {
    bool imageContainer = false,
    int depth = 0,
  }) {
    if (depth > 12) return null;
    if (value is String) {
      return imageContainer ? _payloadFromImageValue(value) : null;
    }
    if (value is List) {
      if (!imageContainer) return null;
      for (final child in value) {
        final payload = _findGenericImagePayload(
          child,
          imageContainer: true,
          depth: depth + 1,
        );
        if (payload != null) return payload;
      }
      return null;
    }
    if (value is! Map) return null;

    final mime =
        value['mime_type']?.toString() ??
        value['mimeType']?.toString() ??
        value['content_type']?.toString();
    for (final key in const [
      'b64_json',
      'base64',
      'image_base64',
      'imageBase64',
      'base64Data',
      'image_bytes',
      'imageBytes',
    ]) {
      final raw = value[key];
      if (raw is String && raw.trim().isNotEmpty) {
        return _InlineImagePayload(raw, mimeType: mime);
      }
    }
    for (final key in const [
      'image_url',
      'imageUrl',
      'download_url',
      'downloadUrl',
      'output_url',
      'outputUrl',
    ]) {
      final payload = _payloadFromImageValue(value[key], mimeType: mime);
      if (payload != null) return payload;
    }
    if (imageContainer) {
      for (final key in const ['url', 'href', 'uri', 'data']) {
        final payload = _payloadFromImageValue(value[key], mimeType: mime);
        if (payload != null) return payload;
      }
    }

    for (final entry in value.entries) {
      final key = entry.key.toString().toLowerCase();
      final childIsImageContainer =
          const {
            'data',
            'image',
            'images',
            'output',
            'outputs',
            'result',
            'results',
            'artifact',
            'artifacts',
            'generated_images',
            'generatedimages',
          }.contains(key) ||
          key.contains('image');
      if (!childIsImageContainer) continue;
      final payload = _findGenericImagePayload(
        entry.value,
        imageContainer: true,
        depth: depth + 1,
      );
      if (payload != null) return payload;
    }
    return null;
  }

  _ImagePayload? _payloadFromImageValue(Object? value, {String? mimeType}) {
    if (value is Map || value is List) {
      return _findGenericImagePayload(value, imageContainer: true);
    }
    if (value is! String) return null;
    final text = value.trim();
    if (text.isEmpty) return null;
    if (text.startsWith('data:image/')) {
      return _InlineImagePayload(text, mimeType: mimeType);
    }
    final uri = Uri.tryParse(text);
    if (uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http' || uri.scheme.isEmpty) &&
        (uri.hasAuthority || uri.scheme.isEmpty && text.startsWith('/'))) {
      return _UrlImagePayload(text);
    }
    if (_looksLikeBase64Image(text)) {
      return _InlineImagePayload(text, mimeType: mimeType);
    }
    return null;
  }

  bool _looksLikeBase64Image(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), '');
    if (compact.length < 8 ||
        !RegExp(r'^[A-Za-z0-9_+/=-]+$').hasMatch(compact)) {
      return false;
    }
    try {
      final decoded = base64.decode(base64.normalize(compact));
      return _detectImageMime(Uint8List.fromList(decoded)) != null;
    } on Object {
      return false;
    }
  }

  _DecodedInline _decodeInlinePayload(_InlineImagePayload payload) {
    var encoded = payload.data.trim();
    var mimeType = payload.mimeType;
    final dataUri = RegExp(
      r'^data:([^;,]+);base64,(.*)$',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(encoded);
    if (dataUri != null) {
      mimeType = dataUri.group(1);
      encoded = dataUri.group(2)!;
    }
    encoded = encoded.replaceAll(RegExp(r'\s+'), '');
    try {
      final bytes = base64.decode(base64.normalize(encoded));
      return _DecodedInline(Uint8List.fromList(bytes), mimeType);
    } on Object {
      throw const ImageGenerationException(
        code: 'invalid_base64',
        stage: 'image_decode',
        message: '接口返回的图片 Base64 无法解析。',
        requestSubmitted: true,
      );
    }
  }

  _ValidatedImage _validatedImage(Uint8List bytes, String? claimedMime) {
    if (bytes.isEmpty) {
      throw const ImageGenerationException(
        code: 'empty_image',
        stage: 'image_validation',
        message: '接口返回了空图片。',
        requestSubmitted: true,
      );
    }
    if (bytes.length > maxImageBytes) {
      throw const ImageGenerationException(
        code: 'image_too_large',
        stage: 'image_validation',
        message: '生成图片超过允许大小。',
        requestSubmitted: true,
      );
    }
    final detected = _detectImageMime(bytes);
    if (detected == null) {
      throw const ImageGenerationException(
        code: 'invalid_image_signature',
        stage: 'image_validation',
        message: '返回内容不是支持的图片格式。',
        requestSubmitted: true,
      );
    }
    final normalizedClaim = _normalizedMime(claimedMime);
    if (normalizedClaim != null &&
        normalizedClaim != 'application/octet-stream' &&
        normalizedClaim != detected &&
        !(normalizedClaim == 'image/jpg' && detected == 'image/jpeg')) {
      throw const ImageGenerationException(
        code: 'mime_signature_mismatch',
        stage: 'image_validation',
        message: '图片 MIME 与文件签名不一致。',
        requestSubmitted: true,
      );
    }
    return _ValidatedImage(bytes, detected);
  }

  String? _detectImageMime(Uint8List bytes) {
    bool prefix(List<int> signature) {
      if (bytes.length < signature.length) return false;
      for (var i = 0; i < signature.length; i++) {
        if (bytes[i] != signature[i]) return false;
      }
      return true;
    }

    if (prefix(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
      return 'image/png';
    }
    if (prefix(const [0xff, 0xd8, 0xff])) return 'image/jpeg';
    if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'image/webp';
    }
    if (bytes.length >= 6) {
      final header = ascii.decode(bytes.sublist(0, 6), allowInvalid: true);
      if (header == 'GIF87a' || header == 'GIF89a') return 'image/gif';
    }
    if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(4, 8), allowInvalid: true) == 'ftyp') {
      final brand = ascii.decode(bytes.sublist(8, 12), allowInvalid: true);
      if (brand == 'avif' || brand == 'avis') return 'image/avif';
    }
    return null;
  }

  String? _normalizedMime(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return value.split(';').first.trim().toLowerCase();
  }

  String _providerOutputFormat(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'jpg' ? 'jpeg' : normalized;
  }

  _ComfyImage? _findComfyOutput(Object? value, String promptId) {
    Object? root = value;
    if (value is Map && value[promptId] != null) root = value[promptId];
    _ComfyImage? walk(Object? node, int depth) {
      if (depth > 12) return null;
      if (node is Map) {
        final images = node['images'];
        if (images is List) {
          for (final item in images) {
            if (item is! Map) continue;
            final filename = item['filename'];
            if (filename is String && filename.trim().isNotEmpty) {
              return _ComfyImage(
                filename: filename,
                subfolder: item['subfolder']?.toString() ?? '',
                type: item['type']?.toString() ?? 'output',
              );
            }
          }
        }
        for (final child in node.values) {
          final found = walk(child, depth + 1);
          if (found != null) return found;
        }
      } else if (node is List) {
        for (final child in node) {
          final found = walk(child, depth + 1);
          if (found != null) return found;
        }
      }
      return null;
    }

    return walk(root, 0);
  }

  bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  String _redactedUrl(Uri value) {
    final withoutUserOrFragment = value
        .replace(userInfo: '')
        .removeFragment()
        .toString();
    final queryStart = withoutUserOrFragment.indexOf('?');
    return queryStart < 0
        ? withoutUserOrFragment
        : withoutUserOrFragment.substring(0, queryStart);
  }

  void _throwIfCancelled(
    ImageGenerationCancellationToken? token, {
    required bool requestSubmitted,
  }) {
    if (token?.isCancelled != true) return;
    throw ImageGenerationException(
      code: 'cancelled',
      stage: 'cancellation',
      message: '生图任务已取消。',
      requestSubmitted: requestSubmitted,
      outcomeUnknown: requestSubmitted,
    );
  }

  void _notify(
    ImageGenerationProgressCallback? callback,
    ImageGenerationPhase phase,
  ) {
    if (callback == null) return;
    try {
      callback(phase);
    } on Object {
      // A presentation callback must never submit or lose a paid request.
    }
  }
}

sealed class _ImagePayload {
  const _ImagePayload();
}

class _BinaryImagePayload extends _ImagePayload {
  const _BinaryImagePayload(this.bytes, {this.mimeType});

  final Uint8List bytes;
  final String? mimeType;
}

class _InlineImagePayload extends _ImagePayload {
  const _InlineImagePayload(this.data, {this.mimeType});

  final String data;
  final String? mimeType;
}

class _UrlImagePayload extends _ImagePayload {
  const _UrlImagePayload(this.url);

  final String url;
}

class _TransportResponse {
  const _TransportResponse({
    required this.statusCode,
    required this.headers,
    required this.bytes,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List bytes;
}

class _DecodedInline {
  const _DecodedInline(this.bytes, this.mimeType);

  final Uint8List bytes;
  final String? mimeType;
}

class _ValidatedImage {
  const _ValidatedImage(this.bytes, this.mimeType);

  final Uint8List bytes;
  final String mimeType;
}

class _TaskReference {
  const _TaskReference({required this.id, required this.statusUri});

  final String id;
  final Uri statusUri;
}

class _ComfyImage {
  const _ComfyImage({
    required this.filename,
    required this.subfolder,
    required this.type,
  });

  final String filename;
  final String subfolder;
  final String type;
}
