import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_controller.dart';

class SecretStore {
  const SecretStore();

  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions());

  Future<String> readOpenAiKey() async =>
      await _storage.read(key: 'openai_api_key') ?? '';

  Future<String> readFishAudioKey() async =>
      await _storage.read(key: 'fish_audio_api_key') ?? '';

  Future<void> writeOpenAiKey(String value) =>
      _writeOrDelete('openai_api_key', value);

  Future<void> writeFishAudioKey(String value) =>
      _writeOrDelete('fish_audio_api_key', value);

  Future<void> _writeOrDelete(String key, String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty
        ? _storage.delete(key: key)
        : _storage.write(key: key, value: trimmed);
  }
}

class OpenAiCompatibleClient {
  OpenAiCompatibleClient({
    http.Client? client,
    WebSearchClient? webSearchClient,
  }) : _client = client ?? http.Client(),
       _webSearchClient = webSearchClient ?? WebSearchClient(client: client);

  final http.Client _client;
  final WebSearchClient _webSearchClient;

  Stream<String> streamChat({
    required String baseUrl,
    required String apiKey,
    required String model,
    required String systemPrompt,
    required List<ChatMessage> messages,
    String? reasoningEffort,
    double? outputMultiplier,
    bool agentEnabled = false,
  }) async* {
    final conversation = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': agentEnabled
            ? '$systemPrompt\n\n需要实时或不确定的网络信息时，调用 web_search。根据搜索结果回答，并在相关事实后保留来源 URL。'
            : systemPrompt,
      },
      for (final message in messages)
        {
          'role': message.isUser ? 'user' : 'assistant',
          'content': _messageContent(message),
        },
    ];
    if (agentEnabled) {
      yield* _streamAgentChat(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        conversation: conversation,
        reasoningEffort: reasoningEffort,
        outputMultiplier: outputMultiplier,
      );
      return;
    }

    yield* _streamRequest(
      baseUrl: baseUrl,
      apiKey: apiKey,
      body: _chatBody(
        model: model,
        stream: true,
        conversation: conversation,
        reasoningEffort: reasoningEffort,
        outputMultiplier: outputMultiplier,
      ),
    );
  }

  Stream<String> _streamAgentChat({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> conversation,
    required String? reasoningEffort,
    required double? outputMultiplier,
  }) async* {
    const maxToolRounds = 2;
    for (var round = 0; round < maxToolRounds; round += 1) {
      final assistant = await _completeMessage(
        baseUrl: baseUrl,
        apiKey: apiKey,
        body: _chatBody(
          model: model,
          stream: false,
          conversation: conversation,
          reasoningEffort: reasoningEffort,
          outputMultiplier: outputMultiplier,
          tools: const [_webSearchTool],
        ),
      );
      final toolCalls = (assistant['tool_calls'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      if (toolCalls.isEmpty) {
        final content = _messageText(assistant);
        if (content.isNotEmpty) yield content;
        return;
      }

      conversation.add({
        'role': 'assistant',
        'content': _messageText(assistant),
        'tool_calls': toolCalls,
      });
      for (var index = 0; index < toolCalls.length; index += 1) {
        final toolCall = toolCalls[index];
        conversation.add({
          'role': 'tool',
          'tool_call_id': toolCall['id'] as String? ?? 'web_search',
          'content': index < 2
              ? await _executeToolCall(toolCall)
              : '工具调用失败：单轮最多执行 2 个工具调用。',
        });
      }
    }

    yield* _streamRequest(
      baseUrl: baseUrl,
      apiKey: apiKey,
      body: _chatBody(
        model: model,
        stream: true,
        conversation: conversation,
        reasoningEffort: reasoningEffort,
        outputMultiplier: outputMultiplier,
        tools: const [_webSearchTool],
        toolChoice: 'none',
      ),
    );
  }

  Map<String, dynamic> _chatBody({
    required String model,
    required bool stream,
    required List<Map<String, dynamic>> conversation,
    required String? reasoningEffort,
    required double? outputMultiplier,
    List<Map<String, dynamic>>? tools,
    String? toolChoice,
  }) {
    final body = <String, dynamic>{
      'model': model,
      'stream': stream,
      'messages': conversation,
    };
    if (reasoningEffort != null) body['reasoning_effort'] = reasoningEffort;
    if (outputMultiplier != null) {
      body['max_completion_tokens'] = (4096 * outputMultiplier).round();
    }
    if (tools != null) body['tools'] = tools;
    if (toolChoice != null) body['tool_choice'] = toolChoice;
    return body;
  }

  Stream<String> _streamRequest({
    required String baseUrl,
    required String apiKey,
    required Map<String, dynamic> body,
  }) async* {
    final request = http.Request('POST', _endpoint(baseUrl, 'chat/completions'))
      ..headers.addAll({
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream',
      })
      ..body = jsonEncode(body);

    final response = await _client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw AiServiceException(
        'AI 请求失败 (${response.statusCode})${_serverMessage(body)}',
      );
    }

    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty || data == '[DONE]') continue;
      final decoded = jsonDecode(data) as Map<String, dynamic>;
      final error = decoded['error'];
      if (error is Map<String, dynamic>) {
        throw AiServiceException(error['message'] as String? ?? 'AI 流式响应返回错误');
      }
      final delta = _readDelta(decoded);
      if (delta.isNotEmpty) yield delta;
    }
  }

  Future<Map<String, dynamic>> _completeMessage({
    required String baseUrl,
    required String apiKey,
    required Map<String, dynamic> body,
  }) async {
    final response = await _client.post(
      _endpoint(baseUrl, 'chat/completions'),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiServiceException(
        'AI 请求失败 (${response.statusCode})${_serverMessage(response.body)}',
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = decoded['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) return <String, dynamic>{};
    final message = (choices.first as Map<String, dynamic>)['message'];
    return message is Map<String, dynamic> ? message : <String, dynamic>{};
  }

  Future<String> _executeToolCall(Map<String, dynamic> toolCall) async {
    final function = toolCall['function'];
    if (function is! Map<String, dynamic> || function['name'] != 'web_search') {
      return '工具调用失败：不支持该工具。';
    }
    try {
      final rawArguments = function['arguments'] as String? ?? '{}';
      final arguments = jsonDecode(rawArguments) as Map<String, dynamic>;
      final query = (arguments['query'] as String? ?? '').trim();
      if (query.isEmpty) return '搜索失败：query 不能为空。';
      final results = await _webSearchClient.search(query);
      return [
        '搜索词：$query',
        for (var index = 0; index < results.length; index += 1)
          '${index + 1}. ${results[index].title}\n${results[index].snippet}\n${results[index].url}',
      ].join('\n\n');
    } on Object catch (error) {
      return '搜索失败：$error';
    }
  }

  String _messageText(Map<String, dynamic> message) {
    final content = message['content'];
    if (content is String) return content;
    if (content is List<dynamic>) {
      return content
          .whereType<Map<String, dynamic>>()
          .map((part) => part['text'] as String? ?? '')
          .join();
    }
    return '';
  }

  static const Map<String, dynamic> _webSearchTool = {
    'type': 'function',
    'function': {
      'name': 'web_search',
      'description': '搜索公开网页，返回标题、摘要和来源 URL。用于需要当前信息或外部事实的问题。',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': '简洁、具体的搜索关键词'},
        },
        'required': ['query'],
        'additionalProperties': false,
      },
    },
  };

  Object _messageContent(ChatMessage message) {
    if (message.attachments.isEmpty) return message.text;
    final parts = <Map<String, dynamic>>[
      {
        'type': 'text',
        'text': message.text.trim().isEmpty ? '请分析这些附件。' : message.text,
      },
    ];
    for (final attachment in message.attachments) {
      final bytes = attachment.bytes;
      if (bytes == null) {
        parts.add({'type': 'text', 'text': '[之前发送的附件：${attachment.name}]'});
        continue;
      }
      final dataUrl =
          'data:${attachment.mimeType};base64,${base64Encode(bytes)}';
      if (attachment.isImage) {
        parts.add({
          'type': 'image_url',
          'image_url': {'url': dataUrl},
        });
      } else {
        parts.add({
          'type': 'file',
          'file': {'filename': attachment.name, 'file_data': dataUrl},
        });
      }
    }
    return parts;
  }

  Future<String> complete({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, String>> messages,
  }) async {
    final response = await _client.post(
      _endpoint(baseUrl, 'chat/completions'),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'model': model, 'stream': false, 'messages': messages}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiServiceException(
        '记忆整理失败 (${response.statusCode})${_serverMessage(response.body)}',
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = decoded['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) return '';
    final message = (choices.first as Map<String, dynamic>)['message'];
    if (message is! Map<String, dynamic>) return '';
    return message['content'] as String? ?? '';
  }

  Uri _endpoint(String baseUrl, String path) {
    var normalized = baseUrl.trim();
    if (normalized.isEmpty) normalized = 'https://api.openai.com/v1';
    normalized = normalized.replaceAll(RegExp(r'/+$'), '');
    if (normalized.endsWith('/chat/completions')) return Uri.parse(normalized);
    return Uri.parse('$normalized/$path');
  }

  String _readDelta(Map<String, dynamic> event) {
    if (event['type'] == 'response.output_text.delta') {
      return event['delta'] as String? ?? '';
    }
    final choices = event['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) return '';
    final choice = choices.first as Map<String, dynamic>;
    final delta = choice['delta'];
    if (delta is Map<String, dynamic>) {
      final content = delta['content'];
      if (content is String) return content;
      if (content is List<dynamic>) {
        return content
            .whereType<Map<String, dynamic>>()
            .map((part) => part['text'] as String? ?? '')
            .join();
      }
    }
    return '';
  }

  String _serverMessage(String body) {
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final error = decoded['error'];
      if (error is Map<String, dynamic>) {
        final message = error['message'] as String?;
        if (message != null && message.isNotEmpty) return '：$message';
      }
    } on FormatException {
      // Preserve a concise client-facing error when the server returns HTML.
    }
    return '';
  }
}

class WebSearchResult {
  const WebSearchResult({
    required this.title,
    required this.url,
    required this.snippet,
  });

  final String title;
  final String url;
  final String snippet;
}

class WebSearchClient {
  WebSearchClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<List<WebSearchResult>> search(String query) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty || normalizedQuery.length > 300) {
      throw AiServiceException('搜索词长度必须在 1 到 300 个字符之间');
    }
    final response = await _client
        .get(
          Uri.https('html.duckduckgo.com', '/html/', {'q': normalizedQuery}),
          headers: const {
            'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Mobile Safari/537.36',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AiServiceException('联网搜索失败 (${response.statusCode})');
    }

    final document = html_parser.parse(response.body);
    final results = <WebSearchResult>[];
    for (final element in document.querySelectorAll('.result')) {
      final anchor = element.querySelector('.result__a');
      if (anchor == null) continue;
      final title = anchor.text.trim();
      final url = _resultUrl(anchor.attributes['href'] ?? '');
      final snippet = element.querySelector('.result__snippet')?.text.trim();
      if (title.isEmpty || url.isEmpty) continue;
      results.add(
        WebSearchResult(title: title, url: url, snippet: snippet ?? ''),
      );
      if (results.length == 5) break;
    }
    if (results.isEmpty) throw AiServiceException('没有找到可用的搜索结果');
    return results;
  }

  String _resultUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) return '';
    final redirected = uri.queryParameters['uddg'];
    if (redirected != null && redirected.isNotEmpty) return redirected;
    if (uri.hasScheme) return uri.toString();
    return '';
  }
}

class FishAudioClient {
  FishAudioClient({http.Client? client}) : _client = client ?? http.Client();

  static const endpoint = 'https://api.fish.audio/v1/tts';
  final http.Client _client;

  Future<String> synthesize({
    required String apiKey,
    required String referenceId,
    required String text,
    String model = 's2-pro',
    String format = 'mp3',
    String latency = 'normal',
    double speed = 1.0,
  }) async {
    final bytes = await synthesizeBytes(
      apiKey: apiKey,
      referenceId: referenceId,
      text: text,
      model: model,
      format: format,
      latency: latency,
      speed: speed,
    );
    final extension = switch (format) {
      'wav' => 'wav',
      'opus' => 'opus',
      _ => 'mp3',
    };
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}fish_tts_${DateTime.now().millisecondsSinceEpoch}.$extension',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<Uint8List> synthesizeBytes({
    required String apiKey,
    required String referenceId,
    required String text,
    String model = 's2-pro',
    String format = 'mp3',
    String latency = 'normal',
    double speed = 1.0,
  }) async {
    final response = await _client.post(
      Uri.parse(endpoint),
      headers: {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
        'model': model,
      },
      body: jsonEncode({
        'text': text,
        'reference_id': referenceId,
        'normalize': true,
        'format': format,
        'latency': latency,
        'prosody': {
          'speed': speed.clamp(0.5, 2.0),
          'volume': 0.0,
          'normalize_loudness': true,
        },
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var details = '';
      try {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final message = decoded['message'] as String?;
        if (message != null && message.isNotEmpty) details = '：$message';
      } on Object {
        // Fish Audio can return a non-JSON proxy error.
      }
      throw AiServiceException(
        'Fish Audio 请求失败 (${response.statusCode})$details',
      );
    }
    return response.bodyBytes;
  }
}

class AiServiceException implements Exception {
  const AiServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}
