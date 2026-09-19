part of 'ai_services.dart';

// SSE frames may span network chunks and may end at EOF without a blank line.
Stream<String> _geminiSseData(Stream<List<int>> bytes) async* {
  var data = <String>[];
  await for (final rawLine
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    final line = rawLine.replaceAll('\uFEFF', '').replaceAll('\u0000', '');
    if (line.startsWith('data:')) {
      data.add(line.substring(5).trimLeft());
    } else if (line.trim().isEmpty && data.isNotEmpty) {
      final payload = data.join('\n').trim();
      data = [];
      if (payload.isNotEmpty) yield payload;
    }
  }
  final payload = data.join('\n').trim();
  if (payload.isNotEmpty) yield payload;
}

// Native Interactions schema, verified against googleapis/python-genai _gaos.
extension _GeminiInteractions on OpenAiCompatibleClient {
  Uri _geminiEndpoint(String baseUrl) {
    var value = baseUrl.trim();
    if (value.isEmpty) {
      value = 'https://generativelanguage.googleapis.com/v1beta/interactions';
    }
    final uri = Uri.parse(value);
    if (!{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const AiServiceException('请填写不含查询参数或密钥的 Gemini API 地址');
    }
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    path = path.replaceFirst(RegExp(r'/chat/completions$'), '');
    path = path.replaceFirst(RegExp(r'/openai$'), '');
    if (path.isEmpty) path = '/v1beta';
    if (!path.endsWith('/interactions')) path = '$path/interactions';
    return uri.replace(path: path);
  }

  List<Map<String, dynamic>> _geminiContent(Object? content) {
    if (content is String) {
      return [
        {'type': 'text', 'text': content},
      ];
    }
    if (content is! List) return [];
    return content.whereType<Map>().map((part) {
      if (part['type'] == 'text') return Map<String, dynamic>.from(part);
      final image = part['type'] == 'image_url';
      final url = image
          ? part['image_url']['url'] as String
          : part['file']['file_data'] as String;
      final data = UriData.parse(url);
      if (!image && data.mimeType != 'application/pdf') {
        if (data.mimeType.startsWith('text/') ||
            data.mimeType == 'application/json') {
          return <String, dynamic>{
            'type': 'text',
            'text': utf8.decode(data.contentAsBytes()),
          };
        }
        throw const AiServiceException('Gemini 原生文档附件目前支持 PDF 和文本，请先转换此文件');
      }
      return <String, dynamic>{
        'type': image ? 'image' : 'document',
        'mime_type': data.mimeType,
        'data': base64Encode(data.contentAsBytes()),
      };
    }).toList();
  }

  String _geminiText(Map<String, dynamic> response) {
    final steps = response['steps'] ?? response['outputs'] ?? [];
    final result = StringBuffer();
    for (final step in (steps as List).whereType<Map>()) {
      if (step['type'] == 'text') result.write(step['text'] ?? '');
      if (step['type'] == 'model_output') {
        for (final content
            in (step['content'] as List? ?? []).whereType<Map>()) {
          if (content['type'] == 'text') result.write(content['text'] ?? '');
        }
      }
    }
    return result.toString();
  }

  void _geminiCheck(Map<String, dynamic> response) {
    if (response['error'] != null ||
        response['status'] == 'failed' ||
        response['status'] == 'cancelled' ||
        response['status'] == 'incomplete') {
      throw AiServiceException(
        'Gemini 请求未完成：${jsonEncode(response['error'] ?? response['errors'] ?? response['status'])}',
      );
    }
  }

  Stream<String> _geminiChat(
    String baseUrl,
    String apiKey,
    String model,
    List<Map<String, dynamic>> conversation,
    bool agent, {
    bool? thinkingEnabled,
    String? reasoningEffort,
  }) async* {
    final url = _geminiEndpoint(baseUrl);
    final system = conversation
        .where((m) => m['role'] == 'system')
        .map((m) => m['content'])
        .join('\n\n');
    final input = <Map<String, dynamic>>[
      for (final message in conversation.where((m) => m['role'] != 'system'))
        {
          'type': message['role'] == 'assistant'
              ? 'model_output'
              : 'user_input',
          'content': _geminiContent(message['content']),
        },
    ];
    var executedCalls = 0;
    for (var round = 0; round <= 10; round++) {
      final useTools = agent && round < 10 && executedCalls < 10;
      final body = <String, dynamic>{
        'model': model,
        'system_instruction': system,
        'input': input,
        'store': false,
        'stream': !useTools,
        ...identifyModelThinking(
          model,
          baseUrl: baseUrl,
          geminiNative: true,
        ).requestFields(enabled: thinkingEnabled, effort: reasoningEffort),
        if (useTools)
          'tools': [
            for (final tool in _agentTools)
              {'type': 'function', ...tool['function'] as Map<String, dynamic>},
          ],
      };
      RuntimeLog.instance.communication(
        source: 'LLM',
        direction: 'request',
        method: 'POST',
        url: url.toString(),
        payload: body,
      );
      final response = await withAiRequestRetries<http.StreamedResponse>(
        () {
          final request = http.Request('POST', url)
            ..headers.addAll({
              'x-goog-api-key': apiKey,
              'Content-Type': 'application/json',
              'Accept': useTools ? 'application/json' : 'text/event-stream',
            })
            ..body = jsonEncode(body);
          return _client.send(request);
        },
        shouldRetryResult: (result) => isRetryableHttpStatus(result.statusCode),
        disposeRetryResult: (result) => result.stream.drain<void>(),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = await response.stream.bytesToString();
        RuntimeLog.instance.communication(
          source: 'LLM',
          direction: 'response',
          method: 'POST',
          url: url.toString(),
          statusCode: response.statusCode,
          payload: error,
        );
        throw AiServiceException(
          'Gemini 请求失败 (${response.statusCode})${_serverMessage(error)}',
        );
      }
      if (useTools ||
          !(response.headers['content-type'] ?? '').contains(
            'text/event-stream',
          )) {
        final decoded = jsonDecode(
          await response.stream.bytesToString(),
        ) as Map<String, dynamic>;
        RuntimeLog.instance.communication(
          source: 'LLM',
          direction: 'response',
          method: 'POST',
          url: url.toString(),
          statusCode: response.statusCode,
          payload: decoded,
        );
        _geminiCheck(decoded);
        final steps = (decoded['steps'] ?? decoded['outputs'] ?? []) as List;
        final calls = steps
            .whereType<Map>()
            .where((s) => s['type'] == 'function_call')
            .toList();
        if (calls.isEmpty) {
          final text = _geminiText(decoded);
          if (text.isEmpty) throw const AiServiceException('Gemini 未返回可显示的文本');
          yield text;
          return;
        }
        if (!useTools) throw const AiServiceException('Gemini 超出允许的工具调用轮数');
        // Replay all steps verbatim, including thought signatures, in stateless mode.
        input.addAll(
          steps.whereType<Map>().map((s) => Map<String, dynamic>.from(s)),
        );
        for (var index = 0; index < calls.length; index++) {
          final call = calls[index];
          input.add({
            'type': 'function_result',
            'call_id': call['id'],
            'name': call['name'],
            'result': executedCalls >= 10
                ? '本次请求已达到 10 次工具调用上限，请使用已有结果回答。'
                : await (() {
                    executedCalls++;
                    return _executeToolCall({
                      'id': call['id'],
                      'function': {
                        'name': call['name'],
                        'arguments': jsonEncode(call['arguments'] ?? {}),
                      },
                    });
                  })(),
          });
        }
        continue;
      }
      var completed = false;
      final output = StringBuffer();
      await for (final data in _geminiSseData(response.stream)) {
        // Some servers append an OpenAI-style transport terminator, even on
        // the native Interactions endpoint. It is not a JSON event.
        if (data.toUpperCase() == '[DONE]') {
          completed = true;
          break;
        }
        final event = jsonDecode(data) as Map<String, dynamic>;
        _geminiCheck(event);
        if (event['event_type'] == 'interaction.completed') {
          _geminiCheck(
            Map<String, dynamic>.from(event['interaction'] as Map? ?? {}),
          );
          completed = true;
          break;
        }
        if (event['event_type'] == 'step.delta' ||
            event['event_type'] == 'content.delta') {
          final delta = event['delta'];
          if (delta is Map && delta['type'] == 'text') {
            final text = delta['text'] as String? ?? '';
            output.write(text);
            yield text;
          }
        }
      }
      RuntimeLog.instance.communication(
        source: 'LLM',
        direction: 'stream',
        method: 'POST',
        url: url.toString(),
        payload: {'text': output.toString(), 'completed': completed},
      );
      if (!completed) throw const AiServiceException('Gemini 流式连接提前结束，请重试');
      if (output.isEmpty) throw const AiServiceException('Gemini 未返回可显示的文本');
      return;
    }
  }
}
