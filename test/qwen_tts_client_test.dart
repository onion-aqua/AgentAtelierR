import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/qwen_tts_config.dart';
import 'package:ryza_chat_mvp/src/runtime_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _workspace = 'https://test-space.cn-beijing.maas.aliyuncs.com';
const _modernModel = 'qwen-audio-3.1-tts-flash';

http.Response _audioResult({String requestId = 'request-ok'}) => http.Response(
  jsonEncode({
    'request_id': requestId,
    'output': {
      'finish_reason': 'stop',
      'audio': {'data': '', 'url': 'https://audio.example/test.wav'},
    },
  }),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await RuntimeLog.instance.clear();
  });

  group('Qwen HTTP protocol separation', () {
    test(
      'current HTTP API sends singular instruction and modern controls',
      () async {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') {
            expect(request.headers, isNot(contains('authorization')));
            return http.Response.bytes([1, 2, 3], 200);
          }
          expect(
            request.url.toString(),
            '$_workspace${QwenTtsConfig.modernPath}',
          );
          expect(request.headers['authorization'], 'Bearer secret');
          expect(jsonDecode(request.body), {
            'model': _modernModel,
            'input': {
              'text': 'こんにちは。',
              'voice': 'longanhuan_v3.1',
              'format': 'wav',
              'sample_rate': 48000,
              'rate': 0.75,
              'pitch': 1.1,
              'volume': 65,
              'language_hints': ['ja'],
              'instruction': '静かで自然な声',
            },
          });
          return _audioResult();
        });

        final audio = await DashScopeTtsClient(client: client).synthesizeBytes(
          apiKey: 'secret',
          text: 'こんにちは。',
          model: _modernModel,
          voice: 'longanhuan_v3.1',
          baseUrl: _workspace,
          language: 'Japanese',
          instructions: '静かで自然な声',
          options: const QwenTtsOptions(
            sampleRate: 48000,
            rate: 0.75,
            pitch: 1.1,
            volume: 65,
            optimizeInstructions: false,
          ),
        );
        expect(audio, [1, 2, 3]);
        expect(requests.map((request) => request.method), ['POST', 'GET']);
      },
    );

    for (final model in ['qwen3-tts-flash', 'qwen3-tts-instruct-flash']) {
      test('$model preserves the multimodal HTTP contract', () async {
        final client = MockClient((request) async {
          if (request.method == 'GET') return http.Response.bytes([4], 200);
          expect(request.url.toString(), DashScopeTtsClient.endpoint);
          final input = (jsonDecode(request.body) as Map)['input'] as Map;
          expect(input['language_type'], 'Japanese');
          expect(input, isNot(contains('language_hints')));
          expect(input, isNot(contains('format')));
          expect(input, isNot(contains('rate')));
          if (model.contains('instruct')) {
            expect(input['instructions'], '轻声');
            expect(input['optimize_instructions'], false);
          } else {
            expect(input, isNot(contains('instructions')));
            expect(input, isNot(contains('optimize_instructions')));
          }
          return _audioResult();
        });
        await DashScopeTtsClient(client: client).synthesizeBytes(
          apiKey: 'secret',
          text: 'こんにちは。',
          model: model,
          voice: 'Cherry',
          language: 'ja',
          instructions: '轻声',
          options: const QwenTtsOptions(optimizeInstructions: false),
        );
      });
    }

    test('automatic language omits modern language_hints', () async {
      final client = MockClient((request) async {
        if (request.method == 'GET') return http.Response.bytes([4], 200);
        final input = (jsonDecode(request.body) as Map)['input'] as Map;
        expect(input, isNot(contains('language_hints')));
        expect(input, isNot(contains('instruction')));
        return _audioResult();
      });
      await DashScopeTtsClient(client: client).synthesizeBytes(
        apiKey: 'secret',
        text: '测试。',
        model: _modernModel,
        voice: 'longanhuan_v3.1',
        baseUrl: _workspace,
        language: 'Auto',
      );
    });

    test('3.0 English voices omit unsupported instructions', () async {
      final client = MockClient((request) async {
        if (request.method == 'GET') return http.Response.bytes([4], 200);
        final input = (jsonDecode(request.body) as Map)['input'] as Map;
        expect(input, isNot(contains('instruction')));
        return _audioResult();
      });
      await DashScopeTtsClient(client: client).synthesizeBytes(
        apiKey: 'secret',
        text: 'Hello.',
        model: 'qwen-audio-3.0-tts-flash',
        voice: 'loongmary',
        baseUrl: _workspace,
        language: 'en',
        instructions: 'gentle',
      );
    });

    test(
      'future custom model and voice reach the configured custom route',
      () async {
        final client = MockClient((request) async {
          if (request.method == 'GET') return http.Response.bytes([4], 200);
          expect(request.url.toString(), 'https://proxy.example/custom/tts');
          expect((jsonDecode(request.body) as Map)['model'], 'future-model');
          return _audioResult();
        });
        await DashScopeTtsClient(client: client).synthesizeBytes(
          apiKey: 'secret',
          text: '测试',
          model: 'future-model',
          voice: 'future-voice',
          baseUrl: 'https://proxy.example/custom/tts',
        );
      },
    );
  });

  group('URL normalization and safe preflight', () {
    for (final suffix in [
      '',
      '/',
      '/api/v1',
      '/api/v1/',
      '/compatible-mode/v1',
      QwenTtsConfig.legacyPath,
      QwenTtsConfig.modernPath,
    ]) {
      test('normalizes known base suffix $suffix', () {
        expect(
          QwenTtsConfig.synthesisEndpoint('$_workspace$suffix', _modernModel),
          '$_workspace${QwenTtsConfig.modernPath}',
        );
        expect(
          QwenTtsConfig.synthesisEndpoint(
            '$_workspace$suffix',
            'qwen3-tts-flash',
          ),
          '$_workspace${QwenTtsConfig.legacyPath}',
        );
      });
    }

    for (final invalid in [
      'http://public.example/api/v1',
      'https://YOUR_WORKSPACE_ID.cn-beijing.maas.aliyuncs.com',
      'https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com',
      'https://workspaceid.ap-southeast-1.maas.aliyuncs.com',
      'file:///tmp/tts',
      'https://user:password@proxy.example',
      DashScopeTtsClient.endpoint,
    ]) {
      test('rejects invalid modern endpoint $invalid before POST', () async {
        var calls = 0;
        final client = MockClient((request) async {
          calls++;
          throw StateError('No network request expected');
        });
        await expectLater(
          DashScopeTtsClient(client: client).synthesizeBytes(
            apiKey: 'secret',
            text: '测试',
            model: _modernModel,
            voice: 'longanhuan_v3.1',
            baseUrl: invalid,
          ),
          throwsA(isA<AiServiceException>()),
        );
        expect(calls, 0);
      });
    }

    for (final model in [
      'qwen3-tts-vc-realtime-2026-01-15',
      'qwen-audio-3.1-realtime-plus',
    ]) {
      test('rejects realtime model $model with HTTP guidance', () async {
        final client = MockClient(
          (request) async => throw StateError('No POST'),
        );
        await expectLater(
          DashScopeTtsClient(client: client).synthesizeBytes(
            apiKey: 'secret',
            text: '测试',
            model: model,
            voice: 'cloned-voice',
          ),
          throwsA(
            isA<AiServiceException>().having(
              (error) => error.message,
              'message',
              contains('WebSocket'),
            ),
          ),
        );
      });
    }

    test('known cross-family system and cloned voices are rejected', () async {
      final client = MockClient((request) async => throw StateError('No POST'));
      for (final voice in [
        'Cherry',
        'longanlingxin',
        'qwen-audio-3.0-tts-plus-myvoice-123',
      ]) {
        await expectLater(
          DashScopeTtsClient(client: client).synthesizeBytes(
            apiKey: 'secret',
            text: '测试',
            model: _modernModel,
            voice: voice,
            baseUrl: _workspace,
          ),
          throwsA(isA<AiServiceException>()),
        );
      }
    });

    test('invalid modern numeric options fail before POST', () async {
      final client = MockClient((request) async => throw StateError('No POST'));
      for (final options in const [
        QwenTtsOptions(rate: 0.1),
        QwenTtsOptions(pitch: 3),
        QwenTtsOptions(volume: 101),
        QwenTtsOptions(sampleRate: 12345),
      ]) {
        await expectLater(
          DashScopeTtsClient(client: client).synthesizeBytes(
            apiKey: 'secret',
            text: '测试',
            model: _modernModel,
            voice: 'longanhuan_v3.1',
            baseUrl: _workspace,
            options: options,
          ),
          throwsA(isA<AiServiceException>()),
        );
      }
    });
  });

  group('modern URL voice enrollment', () {
    test('uses documented enrollment fields and output.voice_id', () async {
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          '$_workspace${QwenTtsConfig.customizationPath}',
        );
        expect(jsonDecode(request.body), {
          'model': 'voice-enrollment',
          'input': {
            'action': 'create_voice',
            'target_model': _modernModel,
            'url': 'https://audio.example/reference.wav?signature=private',
            'prefix': 'Ryza01',
            'language_hints': ['ja'],
          },
        });
        return http.Response(
          jsonEncode({
            'request_id': 'enrollment-ok',
            'output': {'voice_id': '$_modernModel-Ryza01-id'},
          }),
          200,
        );
      });
      final voice = await DashScopeTtsClient(client: client)
          .createQwenVoiceFromUrl(
            apiKey: 'secret',
            targetModel: _modernModel,
            baseUrl: _workspace,
            audioUrl: 'https://audio.example/reference.wav?signature=private',
            prefix: 'Ryza01',
            language: 'Japanese',
          );
      expect(voice, '$_modernModel-Ryza01-id');
      expect(
        RuntimeLog.instance.formattedText,
        isNot(contains('signature=private')),
      );
      expect(
        RuntimeLog.instance.formattedText,
        isNot(contains('Bearer secret')),
      );
    });

    test('does not send local audio in a new-model enrollment', () async {
      final client = MockClient((request) async => throw StateError('No POST'));
      await expectLater(
        DashScopeTtsClient(client: client).createQwenVoice(
          apiKey: 'secret',
          audioBytes: Uint8List.fromList([1, 2]),
          mimeType: 'audio/wav',
          preferredName: 'Ryza',
          targetModel: _modernModel,
          baseUrl: _workspace,
        ),
        throwsA(
          isA<AiServiceException>().having(
            (error) => error.message,
            'message',
            contains('URL'),
          ),
        ),
      );
    });

    test(
      'prefix and nonpublic reference errors are detected before enrollment',
      () async {
        final client = MockClient(
          (request) async => throw StateError('No POST'),
        );
        for (final reference in [
          ('https://audio.example/reference.wav', 'too_long_prefix'),
          ('https://audio.example/reference.wav', 'under_score'),
          ('file:///tmp/reference.wav', 'Ryza'),
          ('data:audio/wav;base64,AQID', 'Ryza'),
          ('http://127.0.0.1/reference.wav', 'Ryza'),
        ]) {
          await expectLater(
            DashScopeTtsClient(client: client).createQwenVoiceFromUrl(
              apiKey: 'secret',
              targetModel: _modernModel,
              baseUrl: _workspace,
              audioUrl: reference.$1,
              prefix: reference.$2,
            ),
            throwsA(isA<AiServiceException>()),
          );
        }
      },
    );
  });

  group('service errors and billing-safe retries', () {
    test(
      'preserves error code, message, request id and redacts credentials',
      () async {
        var calls = 0;
        final client = MockClient((request) async {
          calls++;
          return http.Response(
            jsonEncode({
              'code': 'InvalidParameter',
              'message':
                  'bad Bearer secret data:audio/wav;base64,AQID '
                  'https://reference.example/audio?signature=private',
              'request_id': 'server-request-42',
            }),
            400,
          );
        });
        await expectLater(
          DashScopeTtsClient(client: client).synthesizeBytes(
            apiKey: 'secret',
            text: '测试',
            model: _modernModel,
            voice: 'longanhuan_v3.1',
            baseUrl: _workspace,
          ),
          throwsA(
            isA<AiServiceException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('InvalidParameter'),
                contains('bad'),
                contains('server-request-42'),
                isNot(contains('secret')),
                isNot(contains('AQID')),
                isNot(contains('signature=private')),
              ),
            ),
          ),
        );
        expect(calls, 1);
        expect(RuntimeLog.instance.formattedText, isNot(contains('secret')));
        expect(RuntimeLog.instance.formattedText, isNot(contains('AQID')));
        expect(
          RuntimeLog.instance.formattedText,
          isNot(contains('signature=private')),
        );
      },
    );

    test(
      'server failure does not repeat a potentially billable synthesis',
      () async {
        var calls = 0;
        final client = MockClient((request) async {
          calls++;
          return http.Response(
            jsonEncode({'code': 'InternalError', 'request_id': 'r5'}),
            503,
          );
        });
        await expectLater(
          DashScopeTtsClient(client: client).synthesizeBytes(
            apiKey: 'secret',
            text: '测试',
            model: _modernModel,
            voice: 'longanhuan_v3.1',
            baseUrl: _workspace,
          ),
          throwsA(isA<AiServiceException>()),
        );
        expect(calls, 1);
      },
    );

    test('server failure does not repeat voice enrollment', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response('{}', 503);
      });
      await expectLater(
        DashScopeTtsClient(client: client).createQwenVoiceFromUrl(
          apiKey: 'secret',
          targetModel: _modernModel,
          baseUrl: _workspace,
          audioUrl: 'https://audio.example/reference.wav',
          prefix: 'Ryza',
        ),
        throwsA(isA<AiServiceException>()),
      );
      expect(calls, 1);
    });

    test(
      'non-JSON response retains header request id without logging the page',
      () async {
        final client = MockClient(
          (request) async => http.Response(
            '<html>server-private-page</html>',
            200,
            headers: {'x-request-id': 'header-request'},
          ),
        );
        await expectLater(
          DashScopeTtsClient(client: client).synthesizeBytes(
            apiKey: 'secret',
            text: '测试',
            model: _modernModel,
            voice: 'longanhuan_v3.1',
            baseUrl: _workspace,
          ),
          throwsA(
            isA<AiServiceException>().having(
              (error) => error.message,
              'message',
              contains('header-request'),
            ),
          ),
        );
        expect(
          RuntimeLog.instance.formattedText,
          isNot(contains('server-private-page')),
        );
      },
    );

    test(
      'HTTP error page retains header request id without leaking HTML',
      () async {
        final client = MockClient(
          (request) async => http.Response(
            '<html>server-private-error</html>',
            503,
            headers: {'x-request-id': 'failed-header-request'},
          ),
        );
        await expectLater(
          DashScopeTtsClient(client: client).synthesizeBytes(
            apiKey: 'secret',
            text: '测试',
            model: _modernModel,
            voice: 'longanhuan_v3.1',
            baseUrl: _workspace,
          ),
          throwsA(
            isA<AiServiceException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('503'),
                contains('failed-header-request'),
                isNot(contains('server-private-error')),
              ),
            ),
          ),
        );
      },
    );

    test(
      'missing audio does not fail as an unhelpful type cast error',
      () async {
        final client = MockClient(
          (request) async => http.Response(
            jsonEncode({
              'request_id': 'missing-audio',
              'output': {'audio': []},
            }),
            200,
          ),
        );
        await expectLater(
          DashScopeTtsClient(client: client).synthesizeBytes(
            apiKey: 'secret',
            text: '测试',
            model: _modernModel,
            voice: 'longanhuan_v3.1',
            baseUrl: _workspace,
          ),
          throwsA(
            isA<AiServiceException>().having(
              (error) => error.message,
              'message',
              contains('missing-audio'),
            ),
          ),
        );
      },
    );
  });
}
