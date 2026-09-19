import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/model_thinking.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final switchable = {
    'openai/gpt-5.1': {'reasoning_effort': 'none'},
    'gpt-5.4-2026-03-05': {'reasoning_effort': 'none'},
    'Qwen/Qwen3-32B': {'enable_thinking': false},
    'qwen3.5-plus': {'enable_thinking': false},
    'qwen-flash': {'enable_thinking': false},
    'deepseek-chat': {
      'thinking': {'type': 'disabled'},
    },
    'deepseek-v3.2': {
      'thinking': {'type': 'disabled'},
    },
    'deepseek-v4-flash': {
      'thinking': {'type': 'disabled'},
    },
    'z-ai/GLM-4.7': {
      'thinking': {'type': 'disabled'},
    },
    'glm-5.2': {
      'thinking': {'type': 'disabled'},
    },
    'moonshotai/kimi-k2.5': {
      'thinking': {'type': 'disabled'},
    },
    'kimi-k2.6': {
      'thinking': {'type': 'disabled'},
    },
    'MiniMax-M3': {
      'thinking': {'type': 'disabled'},
      'reasoning_split': true,
    },
    'claude-sonnet-4-6': {
      'thinking': {'type': 'disabled'},
    },
    'gemini-2.5-flash': {'reasoning_effort': 'none'},
  };
  for (final entry in switchable.entries) {
    test('${entry.key} sends real disable controls', () {
      final capability = identifyModelThinking(entry.key);
      expect(capability.canToggle, isTrue);
      expect(
        capability.requestFields(enabled: false, effort: 'high'),
        entry.value,
      );
    });
  }

  for (final name in [
    'gpt-5',
    'gpt-5-mini',
    'gpt-6-astra',
    'o3',
    'o4-mini',
    'gpt-oss:20b',
    'gemini-3.8-flash',
    'gemini-2.5-pro',
    'kimi-k3',
    'kimi-k2-thinking',
    'MiniMax-M2.5',
    'deepseek-reasoner',
    'deepseek-r1',
    'Qwen3-235B-A22B-Thinking-2507',
    'qwq-32b',
    'glm-5.3',
    'grok-4',
  ]) {
    test('$name never claims to disable mandatory reasoning', () {
      final capability = identifyModelThinking(name);
      expect(capability.alwaysOn, isTrue);
      expect(capability.canToggle, isFalse);
      final body = jsonEncode(
        capability.requestFields(enabled: false, effort: 'minimal'),
      );
      expect(body, isNot(contains('"none"')));
      expect(body, isNot(contains('"disabled"')));
    });
  }

  for (final name in [
    'gpt-4.1-mini',
    'qwen2.5-7b',
    'qwen3-coder-plus',
    'qwen3-30b-a3b-instruct-2507',
    'grok-4-fast-non-reasoning',
    'claude-3-5-sonnet',
    'custom-model',
    'my-gpt-5-alias',
    'ep-20260919-abc',
  ]) {
    test('$name is not given unsupported reasoning parameters', () {
      expect(
        identifyModelThinking(name)
            .requestFields(enabled: true, effort: 'high'),
        isEmpty,
      );
    });
  }

  test('provider wrappers take precedence over model-native fields', () {
    expect(
      identifyModelThinking(
        'qwen/qwen3-32b',
        baseUrl: 'https://openrouter.ai/api/v1',
      ).requestFields(enabled: false),
      {
        'reasoning': {'enabled': false},
      },
    );
    expect(
      identifyModelThinking(
        'qwen3:8b',
        baseUrl: 'http://localhost:11434/v1',
      ).requestFields(enabled: false),
      {'reasoning_effort': 'none'},
    );
    expect(
      identifyModelThinking(
        'Qwen/Qwen3-8B',
        baseUrl: 'http://localhost:8000/v1',
      ).requestFields(enabled: true),
      {
        'chat_template_kwargs': {'enable_thinking': true},
      },
    );
    expect(
      identifyModelThinking(
        'deepseek-v3.2',
        baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      ).requestFields(enabled: false),
      {'enable_thinking': false},
    );
    expect(
      identifyModelThinking(
        'qwen3',
        baseUrl: 'https://openrouter.ai.evil.test/v1',
      ).requestFields(enabled: false),
      {'enable_thinking': false},
    );
  });

  test('model-specific effort values are clamped to supported choices', () {
    expect(
      identifyModelThinking('gpt-5.1')
          .requestFields(enabled: true, effort: 'minimal'),
      {'reasoning_effort': 'low'},
    );
    expect(
      identifyModelThinking('grok-3-mini')
          .requestFields(enabled: true, effort: 'medium'),
      {'reasoning_effort': 'low'},
    );
    expect(
      identifyModelThinking(
        'gemini-3-pro-preview',
        geminiNative: true,
      ).requestFields(enabled: true, effort: 'medium'),
      {
        'generation_config': {'thinking_level': 'low'},
      },
    );
    expect(
      identifyModelThinking(
        'gemini-3.8-flash',
        geminiNative: true,
      ).requestFields(enabled: true, effort: 'minimal'),
      {
        'generation_config': {'thinking_level': 'low'},
      },
    );
    expect(
      identifyModelThinking('claude-sonnet-4-6')
          .requestFields(enabled: true, effort: 'high'),
      {
        'thinking': {'type': 'enabled', 'budget_tokens': 8192},
        'max_tokens': 16384,
      },
    );
  });

  test('ordinary streaming sends native Qwen switch, never OpenAI effort', () async {
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      expect(body['enable_thinking'], false);
      expect(body.containsKey('reasoning_effort'), isFalse);
      expect(body.containsKey('max_completion_tokens'), isFalse);
      return http.Response(
        'data: {"choices":[{"delta":{"content":"hello"}}]}\n\ndata: [DONE]\n\n',
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final result = await OpenAiCompatibleClient(client: client)
        .streamChat(
          baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
          apiKey: 'test',
          model: 'qwen3.5-plus',
          systemPrompt: 'test',
          messages: const [],
          thinkingEnabled: false,
          reasoningEffort: 'high',
        )
        .toList();
    expect(result.join(), 'hello');
  });

  test(
    'agent replays reasoning state and thinking controls on tool follow-up',
    () async {
      var requests = 0;
      var executions = 0;
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        expect(body['thinking'], {'type': 'enabled'});
        requests++;
        if (requests == 1) {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': '',
                    'reasoning_content': 'opaque state',
                    'reasoning_details': [
                      {
                        'type': 'reasoning.encrypted',
                        'data': 'opaque signature',
                      },
                    ],
                    'tool_calls': [
                      {
                        'id': 'one',
                        'type': 'function',
                        'function': {
                          'name': 'inspect_quests',
                          'arguments': '{}',
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }
        final messages = body['messages'] as List;
        final assistant =
            messages.firstWhere((m) => m['role'] == 'assistant') as Map;
        expect(assistant['reasoning_content'], 'opaque state');
        expect(assistant['reasoning_details'][0]['data'], 'opaque signature');
        expect(messages.last['role'], 'tool');
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'done'},
              },
            ],
          }),
          200,
        );
      });
      final result =
          await OpenAiCompatibleClient(
                client: client,
                contextToolExecutor: (name, args) async {
                  executions++;
                  return 'no quests';
                },
              )
              .streamChat(
                baseUrl: 'https://api.deepseek.com',
                apiKey: 'test',
                model: 'deepseek-v3.2',
                systemPrompt: 'test',
                messages: const [],
                thinkingEnabled: true,
                agentEnabled: true,
              )
              .toList();
      expect(result.join(), 'done');
      expect(requests, 2);
      expect(executions, 1);
    },
  );

  test('Gemini Interactions uses generation_config, including in agent mode', () async {
    for (final agent in [false, true]) {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        expect(body['generation_config'], {'thinking_level': 'high'});
        expect(body.containsKey('reasoning_effort'), isFalse);
        return http.Response(
          jsonEncode({
            'status': 'completed',
            'outputs': [
              {'type': 'text', 'text': 'done'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final result = await OpenAiCompatibleClient(client: client)
          .streamChat(
            baseUrl:
                'https://generativelanguage.googleapis.com/v1beta/interactions',
            apiKey: 'test',
            model: 'gemini-3.8-flash',
            provider: LlmProvider.gemini,
            systemPrompt: 'test',
            messages: const [],
            thinkingEnabled: true,
            reasoningEffort: 'high',
            agentEnabled: agent,
          )
          .toList();
      expect(result.join(), 'done');
    }
  });
}
