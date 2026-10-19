enum ImageGenerationProtocol {
  auto,
  openAiImages,
  openAiResponses,
  gemini,
  syncJson,
  asyncTask,
  comfyUi,
}

extension ImageGenerationProtocolCodec on ImageGenerationProtocol {
  String get storageName => switch (this) {
    ImageGenerationProtocol.auto => 'auto',
    ImageGenerationProtocol.openAiImages => 'openai_images',
    ImageGenerationProtocol.openAiResponses => 'openai_responses',
    ImageGenerationProtocol.gemini => 'gemini',
    ImageGenerationProtocol.syncJson => 'sync_json',
    ImageGenerationProtocol.asyncTask => 'async_task',
    ImageGenerationProtocol.comfyUi => 'comfyui',
  };

  static ImageGenerationProtocol parse(Object? value) {
    final normalized = value?.toString().trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '',
    );
    return switch (normalized) {
      'openaiimages' || 'images' => ImageGenerationProtocol.openAiImages,
      'openairesponses' ||
      'responses' => ImageGenerationProtocol.openAiResponses,
      'gemini' || 'google' => ImageGenerationProtocol.gemini,
      'syncjson' || 'sync' => ImageGenerationProtocol.syncJson,
      'asynctask' || 'async' || 'task' => ImageGenerationProtocol.asyncTask,
      'comfyui' || 'comfy' => ImageGenerationProtocol.comfyUi,
      _ => ImageGenerationProtocol.auto,
    };
  }

  /// Protocols whose official request format always authenticates with the
  /// separately stored image-generation API key.
  ///
  /// Generic and local transports may be intentionally anonymous, so their
  /// empty key must be allowed through to the transport layer.
  bool get requiresApiKey => switch (this) {
    ImageGenerationProtocol.openAiImages ||
    ImageGenerationProtocol.openAiResponses ||
    ImageGenerationProtocol.gemini => true,
    ImageGenerationProtocol.auto ||
    ImageGenerationProtocol.syncJson ||
    ImageGenerationProtocol.asyncTask ||
    ImageGenerationProtocol.comfyUi => false,
  };
}

/// Public, non-secret settings for one image generation endpoint.
///
/// API keys deliberately do not belong to this value object. They are supplied
/// to the transport at call time and can therefore remain in secure storage.
class ImageGenerationConfig {
  const ImageGenerationConfig({
    this.enabled = false,
    this.baseUrl = 'https://api.openai.com/v1',
    this.model = 'gpt-image-1',
    this.protocol = ImageGenerationProtocol.auto,
    this.width = 1024,
    this.height = 1024,
    this.aspectRatio = '1:1',
    this.outputFormat = 'png',
    this.endpointPath = '',
    this.statusEndpointTemplate = '',
    this.pollIntervalSeconds = 2,
    this.maxPollAttempts = 450,
  });

  final bool enabled;
  final String baseUrl;
  final String model;
  final ImageGenerationProtocol protocol;
  final int width;
  final int height;
  final String aspectRatio;
  final String outputFormat;
  final String endpointPath;

  /// Optional asynchronous status endpoint. `{task_id}` is replaced with the
  /// submitted task id. Empty means use Location/status_url or safe defaults.
  final String statusEndpointTemplate;
  final int pollIntervalSeconds;
  final int maxPollAttempts;

  ImageGenerationConfig copyWith({
    bool? enabled,
    String? baseUrl,
    String? model,
    ImageGenerationProtocol? protocol,
    int? width,
    int? height,
    String? aspectRatio,
    String? outputFormat,
    String? endpointPath,
    String? statusEndpointTemplate,
    int? pollIntervalSeconds,
    int? maxPollAttempts,
  }) => ImageGenerationConfig(
    enabled: enabled ?? this.enabled,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    protocol: protocol ?? this.protocol,
    width: width ?? this.width,
    height: height ?? this.height,
    aspectRatio: aspectRatio ?? this.aspectRatio,
    outputFormat: outputFormat ?? this.outputFormat,
    endpointPath: endpointPath ?? this.endpointPath,
    statusEndpointTemplate:
        statusEndpointTemplate ?? this.statusEndpointTemplate,
    pollIntervalSeconds: pollIntervalSeconds ?? this.pollIntervalSeconds,
    maxPollAttempts: maxPollAttempts ?? this.maxPollAttempts,
  );

  factory ImageGenerationConfig.fromJson(Object? value) {
    if (value is! Map) return const ImageGenerationConfig();
    return ImageGenerationConfig(
      enabled: value['enabled'] == true,
      baseUrl: _stringOr(
        value['base_url'] ?? value['baseUrl'],
        'https://api.openai.com/v1',
      ),
      model: _stringOr(value['model'], 'gpt-image-1'),
      protocol: ImageGenerationProtocolCodec.parse(value['protocol']),
      width: _boundedDimension(value['width'], 1024),
      height: _boundedDimension(value['height'], 1024),
      aspectRatio: _stringOr(
        value['aspect_ratio'] ?? value['aspectRatio'],
        '1:1',
      ),
      outputFormat: _normalizedOutputFormat(
        value['output_format'] ?? value['outputFormat'],
      ),
      endpointPath: _optionalString(
        value['endpoint_path'] ?? value['endpointPath'] ?? value['endpoint'],
      ),
      statusEndpointTemplate: _optionalString(
        value['status_endpoint_template'] ??
            value['statusEndpointTemplate'] ??
            value['status_endpoint'],
      ),
      pollIntervalSeconds: _boundedInt(
        value['poll_interval_seconds'] ?? value['pollIntervalSeconds'],
        2,
        min: 1,
        max: 60,
      ),
      maxPollAttempts: _boundedInt(
        value['max_poll_attempts'] ?? value['maxPollAttempts'],
        450,
        min: 1,
        max: 600,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'base_url': baseUrl.trim(),
    'model': model.trim(),
    'protocol': protocol.storageName,
    'width': width,
    'height': height,
    'aspect_ratio': aspectRatio.trim(),
    'output_format': _normalizedOutputFormat(outputFormat),
    'endpoint_path': endpointPath.trim(),
    'status_endpoint_template': statusEndpointTemplate.trim(),
    'poll_interval_seconds': pollIntervalSeconds,
    'max_poll_attempts': maxPollAttempts,
  };

  /// Detects formats that are unambiguous from their endpoint alone.
  ///
  /// Unknown services deliberately remain [ImageGenerationProtocol.auto]. The
  /// service submits a single generic request and inspects that response as a
  /// synchronous image or an asynchronous task without submitting it again.
  static ImageGenerationProtocol detectProtocol(String baseUrl) {
    final value = baseUrl.trim();
    final uri = Uri.tryParse(value);
    if (uri == null) return ImageGenerationProtocol.auto;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase().replaceAll(RegExp(r'/+$'), '');
    final port = uri.hasPort ? uri.port : null;

    if (host.contains('generativelanguage.googleapis.com') ||
        path.contains(':generatecontent') ||
        path.contains(':predictlongrunning')) {
      return ImageGenerationProtocol.gemini;
    }
    if (port == 8188 ||
        host.contains('comfy') ||
        RegExp(r'/(prompt|history|view)$').hasMatch(path)) {
      return ImageGenerationProtocol.comfyUi;
    }
    if (path.endsWith('/responses')) {
      return ImageGenerationProtocol.openAiResponses;
    }
    if (path.endsWith('/images/generations')) {
      return ImageGenerationProtocol.openAiImages;
    }
    // Starlight exposes an OpenAI-compatible API under /v1; posting directly
    // to its API base can return the website's HTML shell with HTTP 200.
    // Limit this inference to the verified host and API-base paths so custom
    // endpoints and unrelated services keep their configured request shape.
    if (host == 'starlight.uno' && (path.isEmpty || path == '/v1')) {
      return ImageGenerationProtocol.openAiImages;
    }
    if (host == 'api.openai.com' ||
        host.endsWith('.openai.azure.com') ||
        RegExp(r'/openai/v\d+(?:beta\d*)?$').hasMatch(path)) {
      return ImageGenerationProtocol.openAiImages;
    }
    if (host.contains('replicate.com') ||
        host.contains('queue.fal.run') ||
        RegExp(r'/(predictions|jobs|tasks)$').hasMatch(path)) {
      return ImageGenerationProtocol.asyncTask;
    }
    return ImageGenerationProtocol.auto;
  }

  ImageGenerationProtocol get resolvedProtocol {
    if (protocol != ImageGenerationProtocol.auto) return protocol;
    if (endpointPath.trim().isNotEmpty) {
      final endpoint = endpointPath.trim();
      final endpointUri = Uri.tryParse(endpoint);
      if (endpointUri == null) return ImageGenerationProtocol.auto;
      if (endpointUri.hasScheme) return detectProtocol(endpoint);
      final base = Uri.tryParse(baseUrl.trim());
      if (base != null) {
        final baseDirectory = base.replace(
          path: '${base.path.replaceAll(RegExp(r'/+$'), '')}/',
          query: '',
          fragment: '',
        );
        return detectProtocol(baseDirectory.resolve(endpoint).toString());
      }
      return ImageGenerationProtocol.auto;
    }
    return detectProtocol(baseUrl);
  }

  /// Returns a localized-UI-friendly validation token, or null when valid.
  /// The UI can map the stable token to its own current language.
  String? get validationError {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return 'invalid_base_url';
    }
    if (_urlContainsCredentials(baseUrl) ||
        _urlContainsCredentials(endpointPath) ||
        _urlContainsCredentials(statusEndpointTemplate)) {
      return 'url_contains_credentials';
    }
    if (uri.scheme != 'https' &&
        !(uri.scheme == 'http' && _isLoopbackHost(uri.host))) {
      return 'https_required';
    }
    if (width < 64 || width > 8192 || height < 64 || height > 8192) {
      return 'invalid_dimensions';
    }
    if (!RegExp(r'^\d+(?:\.\d+)?:\d+(?:\.\d+)?$')
        .hasMatch(aspectRatio.trim())) {
      return 'invalid_aspect_ratio';
    }
    if (!const {
      'png',
      'jpg',
      'jpeg',
      'webp',
      'gif',
      'avif',
    }.contains(_normalizedOutputFormat(outputFormat))) {
      return 'unsupported_output_format';
    }
    if (pollIntervalSeconds < 1 ||
        pollIntervalSeconds > 60 ||
        maxPollAttempts < 1 ||
        maxPollAttempts > 600) {
      return 'invalid_polling';
    }
    return null;
  }

  static bool _isLoopbackHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'localhost' ||
        normalized == '127.0.0.1' ||
        normalized == '::1' ||
        normalized.endsWith('.localhost');
  }

  static bool _urlContainsCredentials(String value) {
    final text = value.trim();
    if (text.isEmpty) return false;
    final uri = Uri.tryParse(text);
    if (uri == null) return false;
    if (uri.userInfo.isNotEmpty) return true;
    for (final key in uri.queryParametersAll.keys) {
      final normalized = key.trim().toLowerCase().replaceAll('-', '_');
      if (const {
        'key',
        'api_key',
        'token',
        'access_token',
      }.contains(normalized)) {
        return true;
      }
    }
    return false;
  }

  static String _stringOr(Object? value, String fallback) {
    final text = value is String ? value.trim() : '';
    return text.isEmpty ? fallback : text;
  }

  static String _optionalString(Object? value) =>
      value is String ? value.trim() : '';

  static int _boundedInt(
    Object? value,
    int fallback, {
    required int min,
    required int max,
  }) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    if (parsed == null || parsed < min || parsed > max) return fallback;
    return parsed;
  }

  static int _boundedDimension(Object? value, int fallback) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    if (parsed == null || parsed < 64 || parsed > 8192) return fallback;
    return parsed;
  }

  static String _normalizedOutputFormat(Object? value) {
    final normalized = value?.toString().trim().toLowerCase() ?? '';
    if (normalized == 'jpeg') return 'jpg';
    return normalized.isEmpty ? 'png' : normalized;
  }
}
