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
}
