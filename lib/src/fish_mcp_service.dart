import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cryptography/cryptography.dart';
import 'package:url_launcher/url_launcher.dart';

import 'ai_services.dart' show detectAudioContainerExtension;
import 'fish_mcp_protocol.dart';
import 'fish_mcp_studio.dart';
import 'fish_drama3_tags.dart';
import 'fish_s2_tags.dart';
import 'runtime_log.dart';
import 'speech_tempo.dart';
import 'tts_text_normalizer.dart';

export 'fish_mcp_protocol.dart' show FishMcpException;

/// Connection state for the Fish Audio MCP transport.
enum FishMcpConnectionState {
  disconnected,
  connecting,
  authenticating,
  connected,
  toolsDiscovered,
  error,
}

class FishMcpToolInfo {
  const FishMcpToolInfo({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String name;
  final String? description;
  final Map<String, dynamic> inputSchema;

  Map<String, dynamic> toJson() => {
    'name': name,
    if (description != null) 'description': description,
    'inputSchema': inputSchema,
  };
}

/// OAuth storage and MCP client for Fish Audio.
///
/// OAuth credentials are deliberately kept in a namespace that is not part of
/// ServiceApiBackup. The MCP endpoint is never used until tools/list has
/// completed successfully, so a changed or unavailable server cannot trigger
/// a paid generation call by accident.
class FishMcpService extends ChangeNotifier {
  FishMcpService._()
    : _downloadClient = http.Client(),
      _temporaryDirectory = getTemporaryDirectory,
      _tempoProcessor = adjustSpeechFileTempo,
      _persistDiagnostics = true,
      _connectionClientFactory = null;

  @visibleForTesting
  FishMcpService.forTesting({
    required this._client,
    required this._downloadClient,
    required this._temporaryDirectory,
    this._connectionClientFactory,
    SpeechFileTempoProcessor? tempoProcessor,
  }) : _tempoProcessor = tempoProcessor ?? adjustSpeechFileTempo,
       _persistDiagnostics = false {
    state = _client == null
        ? FishMcpConnectionState.disconnected
        : FishMcpConnectionState.connected;
  }

  static final FishMcpService instance = FishMcpService._();

  static const endpoint = 'https://api.fish.audio/mcp';
  static const callbackUri = 'fishmcp://oauth/callback';
  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions());
  static const _credentialKey = 'fish_mcp_oauth_v1';
  static const _clientIdKey = 'fish_mcp_client_id_v1';
  static const _registerEndpoint = 'https://api.fish.audio/oauth/register';
  static const _tokenEndpoint = 'https://api.fish.audio/oauth/token';
  static const _authorizeEndpoint = 'https://fish.audio/oauth/authorize/';

  FishMcpConnectionState state = FishMcpConnectionState.disconnected;
  String? errorMessage;
  Uri? lastAuthorizationUri;
  List<FishMcpToolInfo> tools = const [];
  String? ttsToolName;
  bool drama3Supported = false;
  DateTime? lastDiscoveryAt;
  FishMcpException? lastError;
  Duration? lastGenerationLatency;
  Map<String, dynamic>? _lastRequestSummary;
  Map<String, dynamic>? _lastResultSummary;
  String? _lastRequestedModel;
  String? _lastReportedModel;
  String? _lastConfiguredBackend;
  String _modelSelectionStatus = 'no_request';
  int _modelRequestSerial = 0;

  /// Null means no tools/call; empty means the submitted service default.
  String? get lastRequestedModel => _lastRequestedModel;
  String? get lastReportedModel => _lastReportedModel;
  String? get lastConfiguredBackend => _lastConfiguredBackend;
  String get modelSelectionStatus => _modelSelectionStatus;

  final http.Client _downloadClient;
  final Future<Directory> Function() _temporaryDirectory;
  final SpeechFileTempoProcessor _tempoProcessor;
  final bool _persistDiagnostics;
  final McpClient Function()? _connectionClientFactory;
  int _connectionGeneration = 0;
  int _manualDisconnectGeneration = 0;
  Future<void>? _connectionAttempt;
  bool _automaticConnectionEnabled = true;

  McpClient? _client;
  FishMcpStudioSession? _studioSession;
  _FishMcpPendingAuthorization? _pendingAuthorization;
  bool _disposed = false;

  bool _isCurrent(int generation) =>
      !_disposed && generation == _connectionGeneration;

  void _ensureCurrent(int generation, McpClient client) {
    if (!_isCurrent(generation) || !identical(client, _client)) {
      throw FishMcpException(
        stage: 'cancelled',
        code: 'connection_changed',
        message: '连接已改变，已丢弃旧请求的语音；不会重新生成。',
      );
    }
  }

  bool get isReady =>
      state == FishMcpConnectionState.toolsDiscovered &&
      (ttsToolName != null || studioAvailable);

  List<String> get missingStudioTools => [
    for (final name in fishMcpStudioTools)
      if (!tools.any((tool) => tool.name == name)) name,
  ];

  List<String> get studioContractIssues {
    const fields = <String, List<String>>{
      'studio_create_project': [
        'name',
        'roster',
        'default_voice_id',
        'chapters',
      ],
      'studio_update_project': [
        'project_id',
        'default_backend',
        'scene_preset',
      ],
      'studio_project': ['project_id'],
      'studio_write_blocks': ['project_id', 'ops'],
      'studio_generate': ['project_id', 'blocks', 'dry_run'],
    };
    final issues = <String>[];
    for (final entry in fields.entries) {
      final tool = tools.where((tool) => tool.name == entry.key).firstOrNull;
      if (tool == null) continue;
      final properties = fishMcpSchemaProperties(tool.inputSchema);
      for (final field in entry.value) {
        if (!properties.containsKey(field)) {
          issues.add('${entry.key} 未声明字段 $field');
        }
      }
      if (entry.key == 'studio_generate' && properties.containsKey('dry_run')) {
        final definition = properties['dry_run'];
        final type = definition is Map ? definition['type'] : null;
        if (type != 'boolean' && !(type is List && type.contains('boolean'))) {
          issues.add('studio_generate.dry_run 未声明为 boolean');
        }
      }
    }
    return issues;
  }

  bool get studioAvailable =>
      missingStudioTools.isEmpty && studioContractIssues.isEmpty;

  bool get studioReadBlocksAvailable {
    final tool = tools
        .where((tool) => tool.name == 'studio_read_blocks')
        .firstOrNull;
    if (tool == null) return false;
    final properties = fishMcpSchemaProperties(tool.inputSchema);
    for (final field in const ['project_id', 'chapter']) {
      final definition = properties[field];
      if (definition is! Map || definition['type'] != 'string') return false;
    }
    final required = tool.inputSchema['required'];
    if (required != null && required is! List) return false;
    return fishMcpSchemaRequiredFields(tool.inputSchema)
        .every((field) => const ['project_id', 'chapter'].contains(field));
  }

  String generationRouteForModel(String? model) {
    if (model?.trim().isNotEmpty == true) {
      if (studioAvailable) return 'studio';
      final tool = selectedTtsTool;
      final properties = tool == null
          ? const <String, dynamic>{}
          : fishMcpSchemaProperties(tool.inputSchema);
      if (!const ['model', 'model_id', 'modelId'].any(properties.containsKey)) {
        return 'unavailable';
      }
    }
    return selectedTtsTool == null ? 'unavailable' : 'text_to_speech';
  }

  FishMcpToolInfo? get selectedTtsTool {
    for (final tool in tools) {
      if (tool.name == ttsToolName) return tool;
    }
    return null;
  }

  String get diagnosticReport => const JsonEncoder.withIndent('  ').convert(
    redactFishMcpValue({
      'endpoint': endpoint,
      'state': state.name,
      'tts_tool': ttsToolName,
      'discovered_at': lastDiscoveryAt?.toIso8601String(),
      'drama3_listed_in_schema': drama3Supported,
      'studio_available': studioAvailable,
      'studio_read_blocks_available': studioReadBlocksAvailable,
      'missing_studio_tools': missingStudioTools,
      'studio_contract_issues': studioContractIssues,
      'local_input_schema_validation': false,
      'studio_contract_validation': true,
      'requested_model': lastRequestedModel,
      'reported_model': lastReportedModel,
      'configured_backend': lastConfiguredBackend,
      'model_selection_status': modelSelectionStatus,
      'tools': tools.map((tool) => tool.toJson()).toList(),
      'last_request': _lastRequestSummary,
      'last_result': _lastResultSummary,
      'last_error': lastError?.toJson(),
      'last_generation_ms': lastGenerationLatency?.inMilliseconds,
    }),
  );

  Future<void> _saveDiagnostics() async {
    if (!_persistDiagnostics || _disposed) return;
    try {
      final directory = await _temporaryDirectory();
      await File('${directory.path}/fish_mcp_diagnostics.json')
          .writeAsString(diagnosticReport, flush: true);
    } on Object {
      // Diagnostics must not fail a successful request or start a retry.
    }
  }

  void _recordError(FishMcpException error) {
    lastError = error;
    errorMessage = error.toString();
    RuntimeLog.instance.warning('Fish MCP', error.toString());
    if (!_disposed) notifyListeners();
    unawaited(_saveDiagnostics());
  }

  String get statusLabel => switch (state) {
    FishMcpConnectionState.disconnected => '未连接',
    FishMcpConnectionState.connecting => '连接中',
    FishMcpConnectionState.authenticating => '等待 Fish Audio 授权',
    FishMcpConnectionState.connected => '已连接，待探测工具',
    FishMcpConnectionState.toolsDiscovered => '工具已探测',
    FishMcpConnectionState.error => '连接错误',
  };

  /// Restores an existing OAuth session without opening a browser, registering
  /// a client or calling any speech generation tools. All callers share the
  /// same in-flight handshake and tools/list request.
  Future<bool> restoreConnection() async {
    if (_disposed) return false;
    if (isReady) return true;
    if (!_automaticConnectionEnabled || _pendingAuthorization != null) {
      return false;
    }
    final cancellation = _manualDisconnectGeneration;
    await _startConnection(allowAuthorization: false, launchLogin: false);
    return !_disposed &&
        cancellation == _manualDisconnectGeneration &&
        _automaticConnectionEnabled &&
        isReady;
  }

  Future<void> connect({bool launchLogin = true}) async {
    if (_disposed) return;
    _automaticConnectionEnabled = true;
    final pending = _connectionAttempt;
    if (pending != null) {
      await pending;
      if (_disposed || !_automaticConnectionEnabled || isReady) return;
    }
    await _startConnection(allowAuthorization: true, launchLogin: launchLogin);
  }

  Future<void> _startConnection({
    required bool allowAuthorization,
    required bool launchLogin,
  }) {
    final pending = _connectionAttempt;
    if (pending != null) return pending;
    final completion = Completer<void>();
    _connectionAttempt = completion.future;
    // Publish the future before state notifications can reenter this method.
    unawaited(() async {
      var generation = _connectionGeneration;
      try {
        final stored = await hasStoredCredentials();
        if (!_isCurrent(generation) || !_automaticConnectionEnabled) return;
        if (!stored && !allowAuthorization) return;
        final closing = _disconnect(
          clearError: true,
          suppressAutomatic: false,
          clearAttempt: false,
        );
        generation = _connectionGeneration;
        await closing;
        if (!_isCurrent(generation) || !_automaticConnectionEnabled) return;
        if (!stored) {
          await beginAuthorization(launchLogin: launchLogin);
        } else {
          await _connectWithStoredCredentials(
            allowAuthorization: allowAuthorization,
            launchLogin: launchLogin,
          );
        }
      } on Object catch (cause) {
        if (_isCurrent(generation)) {
          _recordError(FishMcpException.fromCause(cause, stage: 'connection'));
          _setState(FishMcpConnectionState.error);
        }
      } finally {
        if (identical(_connectionAttempt, completion.future)) {
          _connectionAttempt = null;
        }
        completion.complete();
      }
    }());
    return completion.future;
  }

  Future<void> _connectWithStoredCredentials({
    required bool allowAuthorization,
    required bool launchLogin,
  }) async {
    final generation = _connectionGeneration;
    _setState(FishMcpConnectionState.connecting);
    final authProvider = _FishMcpOAuthProvider(
      isCurrent: () => _isCurrent(generation),
    );
    final client =
        _connectionClientFactory?.call() ??
        McpClient(
          const Implementation(name: 'agent-atelier-r', version: '1.0.4.5'),
        );
    final transport = StreamableHttpClientTransport(
      Uri.parse(endpoint),
      opts: StreamableHttpClientTransportOptions(
        authProvider: authProvider,
        oauthUriValidator: (uri, _) =>
            uri.scheme == 'https' &&
            (uri.host == 'api.fish.audio' || uri.host.endsWith('.fish.audio')),
      ),
    );
    _client = client;
    client.onclose = () {
      if (!_isCurrent(generation) || !identical(client, _client)) return;
      // Initialization failures are handled by the connection catch below.
      if (state == FishMcpConnectionState.connecting) return;
      _connectionGeneration++;
      _client = null;
      _studioSession = null;
      tools = const [];
      ttsToolName = null;
      drama3Supported = false;
      lastDiscoveryAt = null;
      _setState(FishMcpConnectionState.disconnected);
    };
    try {
      await client.connect(transport).timeout(const Duration(seconds: 30));
      if (!_isCurrent(generation) || !identical(client, _client)) {
        await client.close();
        return;
      }
      _setState(FishMcpConnectionState.connected);
      await discoverTools();
    } on UnauthorizedError {
      if (!_isCurrent(generation) || !identical(client, _client)) return;
      _client = null;
      await client.close();
      if (!_isCurrent(generation)) return;
      if (allowAuthorization) {
        await beginAuthorization(launchLogin: launchLogin);
      } else {
        _recordError(
          FishMcpException(
            stage: 'connection',
            code: 'authorization_required',
            message: 'Fish Audio 授权已失效，请在语音设置中重新登录。',
          ),
        );
        _setState(FishMcpConnectionState.error);
      }
    } on Object catch (cause) {
      if (!_isCurrent(generation) || !identical(client, _client)) return;
      if (!identical(cause, lastError)) {
        _recordError(FishMcpException.fromCause(cause, stage: 'connection'));
      }
      _setState(FishMcpConnectionState.error);
      _client = null;
      await client.close();
    }
  }

  /// Registers a public PKCE client (once) and opens the official browser
  /// authorization page. Registration happens only after the user explicitly
  /// taps the connect button; startup never creates a remote client.
  Future<void> beginAuthorization({bool launchLogin = true}) async {
    _automaticConnectionEnabled = true;
    final generation = _connectionGeneration;
    try {
      _setState(FishMcpConnectionState.connecting);
      final clientId = await _registeredClientId();
      if (!_isCurrent(generation)) return;
      final verifier = _randomUrlSafe(64);
      final challengeBytes = await Sha256().hash(utf8.encode(verifier));
      if (!_isCurrent(generation)) return;
      final challenge = base64UrlEncode(challengeBytes.bytes)
          .replaceAll('=', '');
      final stateValue = _randomUrlSafe(32);
      _pendingAuthorization = _FishMcpPendingAuthorization(
        clientId: clientId,
        codeVerifier: verifier,
        state: stateValue,
      );
      final authorizationUri = Uri.parse(_authorizeEndpoint).replace(
        queryParameters: {
          'response_type': 'code',
          'client_id': clientId,
          'redirect_uri': callbackUri,
          'scope': 'mcp',
          'state': stateValue,
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          'resource': endpoint,
        },
      );
      lastAuthorizationUri = authorizationUri;
      _setState(FishMcpConnectionState.authenticating);
      if (launchLogin) {
        final opened = await launchUrl(
          authorizationUri,
          mode: LaunchMode.externalApplication,
        );
        if (!_isCurrent(generation)) return;
        if (!opened) errorMessage = '无法打开 Fish Audio 授权页面，请手动打开授权地址。';
      }
    } on Object catch (cause) {
      if (!_isCurrent(generation)) return;
      errorMessage = _safeError(cause);
      _setState(FishMcpConnectionState.error);
    }
  }

  Future<void> discoverTools() async {
    final client = _client;
    if (client == null) {
      throw FishMcpException(
        stage: 'discovery',
        code: 'not_connected',
        message: 'MCP 尚未连接，请先登录并读取工具列表。',
      );
    }
    final generation = _connectionGeneration;
    tools = const [];
    ttsToolName = null;
    drama3Supported = false;
    lastDiscoveryAt = null;
    errorMessage = null;
    _setState(FishMcpConnectionState.connected);
    try {
      final discovered = <FishMcpToolInfo>[];
      final cursors = <String>{};
      String? cursor;
      do {
        final result = await client.listTools(
          params: cursor == null ? null : ListToolsRequest(cursor: cursor),
          options: RequestOptions(timeout: const Duration(seconds: 30)),
        );
        discovered.addAll(
          result.tools.map(
            (tool) => FishMcpToolInfo(
              name: tool.name,
              description: tool.description,
              inputSchema: tool.inputSchema.toJson(),
            ),
          ),
        );
        cursor = result.nextCursor;
        if (cursor != null && (!cursors.add(cursor) || cursors.length > 100)) {
          throw FishMcpException(
            stage: 'discovery',
            code: 'invalid_cursor',
            message: '工具列表分页异常，已停止读取。',
          );
        }
      } while (cursor != null);
      if (generation != _connectionGeneration || !identical(client, _client)) {
        return;
      }
      tools = List.unmodifiable(discovered);
      final selected = selectFishMcpTtsTool(
        discovered
            .map(
              (tool) => FishMcpToolDefinition(
                name: tool.name,
                description: tool.description,
                inputSchema: tool.inputSchema,
              ),
            )
            .toList(),
      );
      ttsToolName = selected?.name;
      drama3Supported = _detectDrama3ForSelectedTool();
      lastDiscoveryAt = DateTime.now();
      errorMessage = ttsToolName == null && !studioAvailable
          ? '工具列表中没有可识别的 TTS 或完整 Studio 生成工具。'
          : null;
      lastError = null;
      _setState(FishMcpConnectionState.toolsDiscovered);
      RuntimeLog.instance.info(
        'Fish MCP',
        'tools/list 成功，工具数=${tools.length}，TTS=${ttsToolName ?? "未发现"}',
      );
      await _saveDiagnostics();
    } on Object catch (cause) {
      final error = cause is FishMcpException
          ? cause
          : FishMcpException.fromCause(cause, stage: 'discovery');
      if (generation == _connectionGeneration && identical(client, _client)) {
        _setState(FishMcpConnectionState.error);
        _recordError(error);
      }
      throw error;
    }
  }

  bool _detectDrama3ForSelectedTool() {
    final tool = selectedTtsTool;
    if (tool == null) return false;
    final properties = fishMcpSchemaProperties(tool.inputSchema);
    for (final key in const ['model', 'model_id', 'modelId']) {
      final schema = properties[key];
      if (schema is Map &&
          ((schema['enum'] is List &&
                  (schema['enum'] as List).contains('drama-3')) ||
              schema['const'] == 'drama-3')) {
        return true;
      }
    }
    return false;
  }

  /// Handles an app-link callback, exchanges the short-lived PKCE code, and
  /// reconnects with the persisted access token. The verifier and state stay
  /// in memory only and are never written to logs or ordinary backups.
  Future<void> handleRedirectUri(Uri uri) async {
    if (uri.scheme != 'fishmcp' || uri.host != 'oauth') return;
    final code = uri.queryParameters['code'];
    final stateValue = uri.queryParameters['state'];
    final error = uri.queryParameters['error'];
    if (error != null) {
      errorMessage = 'Fish Audio 授权失败：$error';
      _setState(FishMcpConnectionState.error);
      return;
    }
    if (code == null || stateValue == null) {
      errorMessage = 'Fish Audio 授权回调缺少 code 或 state。';
      _setState(FishMcpConnectionState.error);
      return;
    }
    final pending = _pendingAuthorization;
    if (pending == null || pending.state != stateValue) {
      errorMessage = 'Fish Audio 授权 state 不匹配，已拒绝回调。';
      _setState(FishMcpConnectionState.error);
      return;
    }
    final generation = _connectionGeneration;
    try {
      final response = await http
          .post(
            Uri.parse(_tokenEndpoint),
            headers: const {
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: {
              'grant_type': 'authorization_code',
              'client_id': pending.clientId,
              'code': code,
              'redirect_uri': callbackUri,
              'code_verifier': pending.codeVerifier,
            },
          )
          .timeout(const Duration(seconds: 20));
      if (!_isCurrent(generation) ||
          !identical(pending, _pendingAuthorization)) {
        return;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('Fish Audio token 交换失败 (${response.statusCode})');
      }
      final payload = jsonDecode(response.body);
      if (payload is! Map || payload['access_token'] is! String) {
        throw StateError('Fish Audio token 响应格式无效');
      }
      final tokens = OAuthAuthorizationCodeTokens(
        accessToken: payload['access_token'] as String,
        refreshToken: payload['refresh_token'] as String?,
        expiresIn: (payload['expires_in'] as num?)?.toInt(),
        scope: payload['scope'] as String?,
      );
      await _FishMcpOAuthProvider.saveStoredTokens(
        tokens,
        isCurrent: () =>
            _isCurrent(generation) && identical(pending, _pendingAuthorization),
      );
      if (!_isCurrent(generation) ||
          !identical(pending, _pendingAuthorization)) {
        return;
      }
      _pendingAuthorization = null;
      await connect(launchLogin: false);
    } on Object catch (cause) {
      if (!_isCurrent(generation) ||
          !identical(pending, _pendingAuthorization)) {
        return;
      }
      errorMessage = _safeError(cause);
      _setState(FishMcpConnectionState.error);
    }
  }

  Future<String> synthesize({
    required String text,
    String? voice,
    String? model,
    String language = 'ja',
    String format = 'mp3',
    double speed = 1.0,
    bool Function()? isCurrent,
  }) async {
    text = normalizeFishAudioSynthesisText(text);
    final cancellation = _manualDisconnectGeneration;
    if (!isReady) await restoreConnection();
    var stage = 'preflight';
    var submitted = false;
    final generation = _connectionGeneration;
    var requestSerial = 0;
    final temporaryPaths = <String>{};
    final requestedModel = fishMcpModelDiagnosticLabel(model ?? '');
    void ensureRequestCurrent(McpClient client) {
      _ensureCurrent(generation, client);
      if (isCurrent != null && !isCurrent()) {
        throw FishMcpException(
          stage: 'cancelled',
          code: 'request_cancelled',
          message: '语音请求已取消，已停止后续操作；不会重新生成或回退。',
        );
      }
    }

    try {
      if (!speed.isFinite) {
        throw FishMcpException(
          stage: 'parameters',
          code: 'invalid_speed',
          message: '语速必须为有效的有限数值，未提交生成请求。',
        );
      }
      speed = speed.clamp(0.5, 2.0);
      if (cancellation != _manualDisconnectGeneration) {
        throw FishMcpException(
          stage: 'cancelled',
          code: 'connection_changed',
          message: '连接已由用户断开，已取消旧语音请求；不会重新生成。',
        );
      }
      final client = _client;
      final tool = selectedTtsTool;
      if (!isReady || client == null) {
        throw FishMcpException(
          stage: stage,
          code: 'not_ready',
          message: 'Fish MCP 尚未完成 tools/list，请先在语音设置连接并读取工具。',
        );
      }
      ensureRequestCurrent(client);
      final spokenText = stripFishDrama3Tags(text)
          .replaceAll(RegExp(r'\[[^\[\]\r\n]+\]'), '')
          .trim();
      final explicitVocalization = RegExp(
        r'\[(?:laughing|chuckling|crying|screaming|shouting)\]',
        caseSensitive: false,
      ).hasMatch(text);
      if (spokenText.isEmpty && !explicitVocalization) {
        throw FishMcpException(
          stage: 'preflight',
          code: 'empty_synthesis_text',
          message: '移除过度气声提示后没有可朗读内容，未提交语音生成。',
        );
      }
      if (isFishDrama3Model(model)) {
        text = compileFishDrama3Text(text);
      } else if (isFishS2Model(model)) {
        text = compileFishS2Text(text);
      }
      final route = generationRouteForModel(model);
      if (route == 'unavailable') {
        final issues = [
          ...missingStudioTools,
          ...studioContractIssues,
        ].join('；');
        throw FishMcpException(
          stage: 'studio_preflight',
          code: 'studio_tools_unavailable',
          message:
              '所选模型需要兼容的 Studio MCP 工具：$issues。请重新读取 tools/list；不会向普通 TTS 发送未声明的 model，也不会回退 REST。',
        );
      }
      final useStudio = route == 'studio';
      final generationTool = useStudio ? 'studio_generate' : tool!.name;
      stage = 'parameters';
      final omitted = <String, String>{};
      final arguments = useStudio
          ? const <String, dynamic>{}
          : buildFishMcpTtsArguments(
              tool: FishMcpToolDefinition(
                name: tool!.name,
                description: tool.description,
                inputSchema: tool.inputSchema,
              ),
              text: text,
              voice: voice,
              model: model,
              language: language,
              format: format,
              speed: speed,
              onOmittedOptionalField: (field, explanation) {
                omitted[field] = explanation;
              },
            );
      final serverSpeed =
          !useStudio &&
          (arguments.containsKey('speed') ||
              arguments.containsKey('prosody_speed'));
      final localSpeed = speed != 1.0 && !serverSpeed;
      final speedControl = speed == 1.0
          ? 'none'
          : serverSpeed
          ? 'server'
          : 'local';
      requestSerial = ++_modelRequestSerial;
      _lastRequestedModel = requestedModel;
      _lastReportedModel = null;
      _lastConfiguredBackend = null;
      _modelSelectionStatus = 'pending';
      lastGenerationLatency = null;
      final modelSchema = useStudio
          ? tools
                .firstWhere((tool) => tool.name == 'studio_update_project')
                .inputSchema
          : tool!.inputSchema;
      final properties = fishMcpSchemaProperties(modelSchema);
      final modelField = useStudio
          ? 'default_backend'
          : const [
              'model',
              'model_id',
              'modelId',
            ].where(arguments.containsKey).firstOrNull;
      final modelDeclared =
          modelField != null && properties.containsKey(modelField);
      _lastRequestSummary = {
        'route': route,
        'tool': generationTool,
        'argument_names': useStudio
            ? ['project_id', 'blocks']
            : arguments.keys.toList(),
        'text_utf8_bytes': utf8.encode(text).length,
        'speech_tag_format': isFishDrama3Model(model)
            ? 'drama3_paired'
            : isFishS2Model(model)
            ? 's2_descriptive_brackets'
            : 'generic_brackets',
        'requested_model': requestedModel,
        'requested_speed': speed,
        'speed_control': speedControl,
        'model_argument': ?modelField,
        'model_declared_in_schema': modelDeclared,
        'schema_rejects_extra_arguments':
            modelSchema['additionalProperties'] == false,
        'model_extension_override': false,
        if (omitted.isNotEmpty) 'omitted_optional_fields': omitted,
        'model_sent':
            arguments.containsKey('model') ||
            arguments.containsKey('model_id') ||
            arguments.containsKey('modelId'),
      };
      _lastResultSummary = null;
      lastError = null;
      errorMessage = null;
      stage = useStudio ? 'studio_prepare' : 'transport';
      final timer = Stopwatch()..start();
      late final CallToolResult result;
      String? configuredBackend;
      try {
        // A generation request is submitted only once. A transport timeout
        // cannot establish whether the server already consumed credits.
        if (useStudio) {
          final session = _studioSession ??= FishMcpStudioSession(
            client: client,
            ensureCurrent: () => _ensureCurrent(generation, client),
            readBlocksAvailable: studioReadBlocksAvailable,
          );
          result = await session.generate(
            text: text,
            voice: voice?.trim() ?? '',
            model: model!.trim(),
            ensureRequestCurrent: () => ensureRequestCurrent(client),
            onSubmitted: () {
              submitted = true;
              stage = 'studio_generate';
            },
            onConfigured: (backend) {
              configuredBackend = backend;
              if (requestSerial == _modelRequestSerial &&
                  _isCurrent(generation)) {
                _lastConfiguredBackend = fishMcpModelDiagnosticLabel(backend);
                _lastRequestSummary?['model_sent'] = true;
              }
            },
            onSummary: (summary) {
              if (requestSerial == _modelRequestSerial &&
                  _isCurrent(generation)) {
                _lastRequestSummary?.addAll(summary);
                if (summary.keys.any(
                  (key) =>
                      key.startsWith('studio_result_') ||
                      key.startsWith('studio_read_'),
                )) {
                  RuntimeLog.instance.info(
                    'Fish MCP',
                    'Studio 结果状态：${jsonEncode(summary)}',
                  );
                }
              }
            },
          );
        } else {
          submitted = true;
          result = await client.callTool(
            CallToolRequest(name: generationTool, arguments: arguments),
            options: RequestOptions(timeout: const Duration(seconds: 90)),
          );
        }
      } finally {
        if (requestSerial == _modelRequestSerial && _isCurrent(generation)) {
          lastGenerationLatency = timer.elapsed;
        }
      }
      ensureRequestCurrent(client);
      final structured = result.structuredContentJson?.toJson();
      final reportedModel = fishMcpReportedModel(result);
      final modelStatus = result.isError
          ? 'request_failed'
          : requestedModel.isEmpty
          ? 'server_default'
          : reportedModel == null
          ? configuredBackend == null
                ? 'unreported'
                : 'studio_configured'
          : requestedModel == reportedModel
          ? 'match'
          : 'mismatch';
      if (requestSerial == _modelRequestSerial) {
        _lastReportedModel = reportedModel;
        _modelSelectionStatus = modelStatus;
        _lastResultSummary = {
          'is_error': result.isError,
          'content_types': result.content.map((item) => item.type).toList(),
          'structured_type': structured.runtimeType.toString(),
          if (structured is Map) 'structured_keys': structured.keys.toList(),
          'reported_model': reportedModel,
          if (configuredBackend != null)
            'configured_backend': fishMcpModelDiagnosticLabel(
              configuredBackend!,
            ),
          'model_selection_status': modelStatus,
        };
        RuntimeLog.instance.info(
          'Fish MCP',
          '模型响应证据：requested=${requestedModel.isEmpty ? "服务默认" : requestedModel}, '
              'reported=${reportedModel ?? "未返回"}, status=$modelStatus',
        );
        if (!_disposed) notifyListeners();
      }
      stage = 'result';
      if (result.isError) {
        throw FishMcpException.fromToolResult(result, stage: stage);
      }
      stage = 'audio_parse';
      final audio = parseFishMcpAudioResult(result);
      Uint8List? bytes = audio.bytes;
      if (audio.uri != null) {
        stage = 'audio_download';
        bytes = await _downloadAudio(audio.uri!);
      }
      ensureRequestCurrent(client);
      stage = 'audio_validate';
      if (bytes == null || bytes.isEmpty) {
        throw FishMcpException(
          stage: stage,
          code: 'empty_audio',
          message: '工具返回了空音频。',
        );
      }
      if (bytes.length > 64 * 1024 * 1024) {
        throw FishMcpException(
          stage: stage,
          code: 'audio_too_large',
          message: '音频超过 64 MiB 限制，未重新生成语音。',
        );
      }
      final extension = detectAudioContainerExtension(bytes);
      if (extension == null) {
        throw FishMcpException(
          stage: stage,
          code: 'invalid_audio',
          message: '工具结果不是可识别的音频文件；已停止播放和自动重试。',
        );
      }
      stage = 'audio_file';
      final directory = await _temporaryDirectory();
      ensureRequestCurrent(client);
      final file = File(
        '${directory.path}/fish_mcp_${DateTime.now().microsecondsSinceEpoch}.$extension',
      );
      temporaryPaths.add(file.path);
      await file.writeAsBytes(bytes, flush: true);
      ensureRequestCurrent(client);
      var outputPath = file.path;
      if (localSpeed) {
        stage = 'audio_tempo';
        try {
          outputPath = await _tempoProcessor(
            file.path,
            speed: speed,
            isCurrent: () =>
                _isCurrent(generation) &&
                identical(client, _client) &&
                (isCurrent?.call() ?? true),
          );
          temporaryPaths.add(outputPath);
        } on SpeechTempoException catch (cause) {
          throw FishMcpException(
            stage: stage,
            code: cause.code,
            message: cause.message,
            generationSubmitted: true,
          );
        }
        ensureRequestCurrent(client);
      }
      RuntimeLog.instance.info(
        'Fish MCP',
        '音频已获取，route=$route, tool=$generationTool, format=${localSpeed ? "wav" : extension}, bytes=${bytes.length}, requested_speed=$speed, speed_control=$speedControl, generation_ms=${lastGenerationLatency?.inMilliseconds}',
      );
      await _saveDiagnostics();
      ensureRequestCurrent(client);
      if (!_disposed) notifyListeners();
      temporaryPaths.remove(outputPath);
      return outputPath;
    } on Object catch (cause) {
      final error = FishMcpException.fromCause(
        cause,
        stage: stage,
        outcomeUnknown: submitted && stage == 'transport',
        generationSubmitted: submitted,
      );
      if (generation == _connectionGeneration &&
          !_disposed &&
          (requestSerial == 0 || requestSerial == _modelRequestSerial)) {
        if (requestSerial != 0) {
          _modelSelectionStatus = 'request_failed';
          _lastResultSummary?['model_selection_status'] = 'request_failed';
        }
        _recordError(error);
      }
      throw error;
    } finally {
      for (final path in temporaryPaths) {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } on FileSystemException {
          // Cleanup must not replace a submitted generation's result/error.
        }
      }
    }
  }

  Future<Uint8List> _downloadAudio(Uri initialUri) async {
    const maximumBytes = 64 * 1024 * 1024;
    final policy = FishMcpAudioUrlPolicy();
    var uri = initialUri;
    for (var redirects = 0; redirects <= 5; redirects++) {
      policy.validate(uri);
      final abort = Completer<void>();
      final timer = Timer(const Duration(seconds: 45), () => abort.complete());
      final request =
          http.AbortableRequest('GET', uri, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers['Accept'] = 'audio/*, application/octet-stream';
      try {
        final response = await _downloadClient.send(request);
        final requestId =
            response.headers['x-request-id'] ??
            response.headers['request-id'] ??
            response.headers['x-correlation-id'];
        if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers['location'];
          // Do not send OAuth credentials to the audio host or follow an
          // arbitrary redirect. Check the next destination before issuing GET.
          await response.stream.drain<void>();
          if (location == null || redirects == 5) {
            throw FishMcpException(
              stage: 'audio_download',
              code: 'invalid_redirect',
              status: response.statusCode,
              message: '音频地址重定向异常。',
              requestId: requestId,
            );
          }
          uri = uri.resolve(location);
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.stream.drain<void>();
          throw FishMcpException(
            stage: 'audio_download',
            code: 'audio_http_error',
            status: response.statusCode,
            message: '音频下载失败（HTTP ${response.statusCode}）；不会再次提交生成。',
            requestId: requestId,
          );
        }
        final contentType = response.headers['content-type']
            ?.split(';')
            .first
            .trim()
            .toLowerCase();
        if (contentType != null &&
            !contentType.startsWith('audio/') &&
            contentType != 'application/octet-stream' &&
            contentType != 'binary/octet-stream') {
          await response.stream.drain<void>();
          throw FishMcpException(
            stage: 'audio_download',
            code: 'invalid_content_type',
            message: '音频地址返回了 $contentType，已拒绝播放。',
            requestId: requestId,
          );
        }
        final contentLength = response.contentLength;
        if (contentLength != null && contentLength > maximumBytes) {
          if (!abort.isCompleted) abort.complete();
          throw FishMcpException(
            stage: 'audio_download',
            code: 'audio_too_large',
            message: '音频文件超过 64 MB，已停止下载。',
          );
        }
        final output = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (output.length + chunk.length > maximumBytes) {
            if (!abort.isCompleted) abort.complete();
            throw FishMcpException(
              stage: 'audio_download',
              code: 'audio_too_large',
              message: '音频文件超过 64 MB，已停止下载。',
            );
          }
          output.add(chunk);
        }
        return output.takeBytes();
      } finally {
        timer.cancel();
      }
    }
    throw FishMcpException(
      stage: 'audio_download',
      code: 'invalid_redirect',
      message: '音频重定向次数过多。',
    );
  }

  Future<void> disconnect({bool clearError = false}) =>
      _disconnect(clearError: clearError);

  Future<void> _disconnect({
    bool clearError = false,
    bool suppressAutomatic = true,
    bool clearAttempt = true,
  }) async {
    if (suppressAutomatic) {
      _automaticConnectionEnabled = false;
      _manualDisconnectGeneration++;
    }
    if (clearAttempt) _connectionAttempt = null;
    _connectionGeneration++;
    if (_modelSelectionStatus == 'pending') {
      _modelSelectionStatus = 'request_failed';
    }
    final client = _client;
    _client = null;
    _studioSession = null;
    _pendingAuthorization = null;
    lastAuthorizationUri = null;
    tools = const [];
    ttsToolName = null;
    drama3Supported = false;
    lastDiscoveryAt = null;
    if (clearError) {
      errorMessage = null;
      lastError = null;
    }
    _setState(FishMcpConnectionState.disconnected);
    try {
      await client?.close();
    } on Object {
      // Closing a failed OAuth transport is best-effort.
    }
  }

  Future<void> logout() async {
    await disconnect(clearError: true);
    await _FishMcpOAuthProvider.queueCredentialWrite(
      () => _storage.delete(key: _credentialKey),
    );
    await _storage.delete(key: _clientIdKey);
    _pendingAuthorization = null;
  }

  Future<bool> hasStoredCredentials() async =>
      (await _storage.read(key: _credentialKey))?.trim().isNotEmpty == true;

  static Future<OAuthTokens?> _readValidTokens({
    required bool Function() isCurrent,
  }) async {
    final raw = await _storage.read(key: _credentialKey);
    if (!isCurrent()) return null;
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['accessToken'] is! String) return null;
      final expiresAt = json['expiresAt'] as String?;
      final expiry = expiresAt == null ? null : DateTime.tryParse(expiresAt);
      if (expiry == null ||
          expiry.isAfter(DateTime.now().add(const Duration(seconds: 30)))) {
        return OAuthTokens(
          accessToken: json['accessToken'] as String,
          refreshToken: json['refreshToken'] as String?,
        );
      }
      final refreshToken = json['refreshToken'] as String?;
      final clientId = await _storage.read(key: _clientIdKey);
      if (!isCurrent()) return null;
      if (refreshToken == null || clientId == null || clientId.isEmpty) {
        return null;
      }
      final response = await http
          .post(
            Uri.parse(_tokenEndpoint),
            headers: const {
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: {
              'grant_type': 'refresh_token',
              'client_id': clientId,
              'refresh_token': refreshToken,
            },
          )
          .timeout(const Duration(seconds: 20));
      if (!isCurrent()) return null;
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final payload = jsonDecode(response.body);
      if (payload is! Map || payload['access_token'] is! String) return null;
      final tokens = OAuthAuthorizationCodeTokens(
        accessToken: payload['access_token'] as String,
        refreshToken: payload['refresh_token'] as String? ?? refreshToken,
        expiresIn: (payload['expires_in'] as num?)?.toInt(),
        scope: payload['scope'] as String?,
      );
      await _FishMcpOAuthProvider.saveStoredTokens(
        tokens,
        isCurrent: isCurrent,
      );
      if (!isCurrent()) return null;
      return OAuthTokens(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
    } on Object {
      return null;
    }
  }

  Future<String> _registeredClientId() async {
    final existing = await _storage.read(key: _clientIdKey);
    if (existing != null && existing.trim().isNotEmpty) return existing.trim();
    final response = await http.post(
      Uri.parse(_registerEndpoint),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'client_name': 'AgentAtelierR',
        'redirect_uris': [callbackUri],
        'grant_types': ['authorization_code', 'refresh_token'],
        'response_types': ['code'],
        'token_endpoint_auth_method': 'none',
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Fish Audio OAuth 客户端注册失败 (${response.statusCode})');
    }
    final payload = jsonDecode(response.body);
    final clientId = payload is Map ? payload['client_id'] : null;
    if (clientId is! String || clientId.trim().isEmpty) {
      throw StateError('Fish Audio OAuth 注册响应缺少 client_id');
    }
    await _storage.write(key: _clientIdKey, value: clientId.trim());
    return clientId.trim();
  }

  static String _randomUrlSafe(int length) {
    final bytes = List<int>.generate(length, (_) => 0);
    final random = Random.secure();
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  String _safeError(Object cause) => redactFishMcpText(cause.toString());

  void _setState(FishMcpConnectionState next) {
    if (_disposed) return;
    state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(disconnect());
    _downloadClient.close();
    super.dispose();
  }
}

class _FishMcpPendingAuthorization {
  const _FishMcpPendingAuthorization({
    required this.clientId,
    required this.codeVerifier,
    required this.state,
  });

  final String clientId;
  final String codeVerifier;
  final String state;
}

// Interactive PKCE authorization is owned by FishMcpService. Using the basic
// provider prevents the transport from starting its own discovery/registration
// flow during an automatic reconnection rejected by the server.
class _FishMcpOAuthProvider implements OAuthClientProvider {
  _FishMcpOAuthProvider({required this.isCurrent});

  final bool Function() isCurrent;
  Future<OAuthTokens?>? _tokenRead;

  static Future<void> _credentialWriteTail = Future<void>.value();

  static Future<void> queueCredentialWrite(Future<void> Function() write) {
    final operation = _credentialWriteTail.then((_) => write());
    _credentialWriteTail = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  @override
  Future<void> redirectToAuthorization() async {}

  @override
  Future<OAuthTokens?> tokens() async {
    final pending = _tokenRead;
    if (pending != null) return pending;
    final reading = FishMcpService._readValidTokens(isCurrent: isCurrent);
    _tokenRead = reading;
    try {
      return await reading;
    } finally {
      if (identical(_tokenRead, reading)) _tokenRead = null;
    }
  }

  static Future<void> saveStoredTokens(
    OAuthTokens tokens, {
    required bool Function() isCurrent,
  }) async {
    final payload = <String, dynamic>{
      'accessToken': tokens.accessToken,
      if (tokens.refreshToken != null) 'refreshToken': tokens.refreshToken,
      if (tokens is OAuthAuthorizationCodeTokens && tokens.expiresIn != null)
        'expiresAt': DateTime.now()
            .add(Duration(seconds: tokens.expiresIn!))
            .toUtc()
            .toIso8601String(),
      if (tokens is OAuthIssuerBoundAuthorizationCodeTokens)
        'issuer': tokens.authorizationServerIssuer,
      if (tokens is OAuthIssuerBoundAuthorizationCodeTokens)
        'resource': tokens.resource.toString(),
    };
    await queueCredentialWrite(() async {
      if (!isCurrent()) return;
      await FishMcpService._storage.write(
        key: FishMcpService._credentialKey,
        value: jsonEncode(payload),
      );
    });
  }
}
