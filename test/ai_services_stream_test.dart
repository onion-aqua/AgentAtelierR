import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/runtime_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Sophie agent excludes Ryza world tools and rejects their calls',
    () async {
      SharedPreferences.setMockInitialValues({});
      var requests = 0;
      var worldToolCalls = 0;
      final transport = MockClient((request) async {
        requests++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final messages = body['messages'] as List<dynamic>;
        final system = (messages.first as Map)['content'] as String;
        expect(system, isNot(contains('莱莎')));
        final names = (body['tools'] as List<dynamic>)
            .map((tool) => (tool as Map)['function']['name'] as String)
            .toSet();
        expect(
          names,
          containsAll(['lookup_character', 'search_memory', 'web_search']),
        );
        expect(names, isNot(contains('create_quest')));
        expect(names, isNot(contains('travel_to_stage')));
        if (requests == 1) {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': '',
                    'tool_calls': [
                      {
                        'id': 'forbidden',
                        'type': 'function',
                        'function': {'name': 'create_quest', 'arguments': '{}'},
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }
        expect((messages.last as Map)['content'], contains('当前人物未启用该工具'));
      return http.Response.bytes(
        utf8.encode('{"choices":[{"message":{"content":"苏菲的回答"}}]}'),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
      });
      final client = OpenAiCompatibleClient(
        client: transport,
        contextToolExecutor: (_, _) async {
          worldToolCalls++;
          return 'unexpected';
        },
      );

      final output = await client
          .streamChat(
            baseUrl: 'https://example.test/v1',
            apiKey: 'test-key',
            model: 'test-model',
            systemPrompt: '你是苏菲',
            messages: const [ChatMessage(text: '你好', isUser: true)],
            agentEnabled: true,
            characterId: 'sophie',
          )
          .join();
      expect(output, '苏菲的回答');
      expect(worldToolCalls, 0);
      expect(requests, 2);
      transport.close();
    },
  );

  test('auxiliary completion reuses authentication without tools or heavy reasoning', () async {
    SharedPreferences.setMockInitialValues({});
    final client = MockClient((request) async {
      expect(request.headers['authorization'], 'Bearer test-key');
      final body = jsonDecode(request.body) as Map;
      expect(body['reasoning_effort'], 'none');
      expect(body.containsKey('tools'), isFalse);
      expect(body['messages'], hasLength(2));
      return http.Response('{"choices":[{"message":{"content":"done"}}]}', 200);
    });
    final output = await OpenAiCompatibleClient(client: client).complete(
      baseUrl: 'https://example.test/v1',
      apiKey: 'test-key',
      model: 'gpt-5.1',
      lightweight: true,
      messages: const [
        {'role': 'system', 'content': 'Translate only'},
        {'role': 'user', 'content': 'Hello'},
      ],
    );
    expect(output, 'done');
    client.close();
  });

  test('OpenAI stream accepts decorated DONE terminal frames', () async {
    SharedPreferences.setMockInitialValues({});
    final client = MockClient((_) async {
      return http.Response.bytes(
        utf8.encode(
          'data: {"choices":[{"delta":{"content":"完成"}}]}\n\n'
          'data: \uFEFF[DONE]\u0000  \n\n',
        ),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });

    final output = await OpenAiCompatibleClient(client: client)
        .streamChat(
          baseUrl: 'https://relay.example/v1',
          apiKey: 'test-key',
          model: 'test-model',
          systemPrompt: 'test',
          messages: const [ChatMessage(text: 'hello', isUser: true)],
        )
        .toList();

    expect(output.join(), '完成');
  });

  test('Ollama-compatible stream sends a trimmed bearer API key', () async {
    SharedPreferences.setMockInitialValues({});
    await RuntimeLog.instance.initialize();
    await RuntimeLog.instance.clear();
    final client = MockClient((request) async {
      expect(request.url.toString(), 'https://ollama.com/v1/chat/completions');
      expect(request.headers['authorization'], 'Bearer ollama-test-key');
      expect(request.headers['accept'], 'text/event-stream');
      expect(
        (jsonDecode(request.body) as Map<String, dynamic>)['stream'],
        isTrue,
      );
      return http.Response.bytes(
        utf8.encode(
          'data: {"choices":[{"delta":{"content":"正常"}}]}\n\n'
          'data: [DONE]\n\n',
        ),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });

    final output = await OpenAiCompatibleClient(client: client)
        .streamChat(
          baseUrl: 'https://ollama.com/v1/chat/completions',
          apiKey: '  ollama-test-key  ',
          model: 'test-model',
          systemPrompt: 'test',
          messages: const [ChatMessage(text: 'hello', isUser: true)],
        )
        .toList();

    expect(output.join(), '正常');
    final requestLog = RuntimeLog.instance.entries.firstWhere(
      (entry) => entry.source == 'LLM' && entry.message.contains('"direction"'),
    );
    expect(requestLog.message, contains('"Authorization": "[REDACTED]"'));
    expect(requestLog.message, isNot(contains('ollama-test-key')));
    await RuntimeLog.instance.clear();
  });

  test('OpenAI-compatible requests reject an empty API key before sending', () {
    final client = MockClient((_) async {
      fail('An empty API key must not reach the network.');
    });

    expect(
      OpenAiCompatibleClient(client: client)
          .streamChat(
            baseUrl: 'https://ollama.com/v1/chat/completions',
            apiKey: '   ',
            model: 'test-model',
            systemPrompt: 'test',
            messages: const [ChatMessage(text: 'hello', isUser: true)],
          )
          .toList(),
      throwsA(isA<AiServiceException>()),
    );
  });

  test(
    'OpenAI stream retries transient HTTP failures before yielding output',
    () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        if (requests <= 2) return http.Response('temporary failure', 503);
        return http.Response.bytes(
          utf8.encode(
            'data: {"choices":[{"delta":{"content":"恢复"}}]}\n\n'
            'data: [DONE]\n\n',
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });

      final output = await OpenAiCompatibleClient(client: client)
          .streamChat(
            baseUrl: 'https://relay.example/v1',
            apiKey: 'test-key',
            model: 'test-model',
            systemPrompt: 'test',
            messages: const [ChatMessage(text: 'hello', isUser: true)],
          )
          .toList();

      expect(output, ['恢复']);
      expect(requests, 3);
    },
  );

  test('OpenAI stream does not retry authentication failures', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('unauthorized', 401);
    });

    await expectLater(
      OpenAiCompatibleClient(client: client)
          .streamChat(
            baseUrl: 'https://relay.example/v1',
            apiKey: 'test-key',
            model: 'test-model',
            systemPrompt: 'test',
            messages: const [ChatMessage(text: 'hello', isUser: true)],
          )
          .toList(),
      throwsA(isA<AiServiceException>()),
    );
    expect(requests, 1);
  });

  test(
    'Fish Audio retries a transient response and returns audio bytes',
    () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        if (requests == 1) return http.Response('busy', 429);
        return http.Response.bytes(
          Uint8List.fromList(const [0x49, 0x44, 0x33, 0x04]),
          200,
          headers: {'content-type': 'audio/mpeg'},
        );
      });

      final bytes = await FishAudioClient(client: client).synthesizeBytes(
        apiKey: 'test-key',
        referenceId: 'voice-id',
        text: 'hello',
      );

      expect(bytes, isNotEmpty);
      expect(requests, 2);
    },
  );

  test(
    'Fish Audio request cleans ellipsis-small-tsu without changing words',
    () async {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['text'], '[breathy]あ……、待って！');
        return http.Response.bytes(
          Uint8List.fromList(const [0x49, 0x44, 0x33]),
          200,
        );
      });

      await FishAudioClient(client: client).synthesizeBytes(
        apiKey: 'test-key',
        referenceId: 'voice-id',
        text: '[breathy]あ……っ、待って！',
      );
    },
  );
}
