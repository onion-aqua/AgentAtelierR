import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/image_generation_config.dart';
import 'package:ryza_chat_mvp/src/image_generation_service.dart';

final Uint8List _png = Uint8List.fromList(const [
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0,
  0,
  0,
  0,
]);

final Uint8List _jpeg = Uint8List.fromList(const [
  0xff,
  0xd8,
  0xff,
  0xe0,
  0,
  0,
  0,
  0,
]);

http.Response _json(Object value, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(value)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

ImageGenerationConfig _config(
  ImageGenerationProtocol protocol, {
  String baseUrl = 'https://provider.example/v1',
  String model = 'image-model',
  String endpointPath = '',
  String statusEndpointTemplate = '',
  int maxPollAttempts = 10,
}) => ImageGenerationConfig(
  enabled: true,
  baseUrl: baseUrl,
  model: model,
  protocol: protocol,
  endpointPath: endpointPath,
  statusEndpointTemplate: statusEndpointTemplate,
  maxPollAttempts: maxPollAttempts,
);

void main() {
  test(
    'Starlight API base submits to the image endpoint exactly once',
    () async {
      var submits = 0;
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'https://starlight.uno/v1/images/generations',
        );
        expect(jsonDecode(request.body)['model'], 'image-model');
        submits++;
        return _json({
          'data': [
            {'b64_json': base64Encode(_png)},
          ],
        });
      });
      addTearDown(client.close);
      final result = await ImageGenerationService(client: client).generate(
        config: _config(
          ImageGenerationProtocol.auto,
          baseUrl: 'https://starlight.uno/v1',
        ),
        apiKey: 'test-key',
        prompt: 'A landscape',
      );
      expect(result.bytes, _png);
      expect(result.protocol, ImageGenerationProtocol.openAiImages);
      expect(submits, 1);
    },
  );

  for (final protocol in ImageGenerationProtocol.values) {
    for (final malformed in [true, false]) {
      test('${protocol.name} preserves unknown outcome after '
          '${malformed ? 'truncated JSON' : 'missing result'}', () async {
        var submits = 0;
        final client = MockClient((request) async {
          expect(request.method, 'POST');
          submits++;
          return malformed
              ? http.Response(
                  '{',
                  200,
                  headers: {'content-type': 'application/json'},
                )
              : _json({});
        });
        await expectLater(
          ImageGenerationService(client: client).generate(
            config: _config(protocol),
            apiKey: 'test-key',
            prompt: 'test',
          ),
          throwsA(
            isA<ImageGenerationException>()
                .having((error) => error.requestSubmitted, 'submitted', isTrue)
                .having((error) => error.outcomeUnknown, 'unknown', isTrue),
          ),
        );
        expect(submits, 1);
        client.close();
      });
    }
  }

  test(
    'image retrieval rejection does not become a safe regeneration',
    () async {
      var submits = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          submits++;
          return _json({'image_url': 'https://cdn.example/generated.png'});
        }
        return http.Response('expired', 403);
      });
      await expectLater(
        ImageGenerationService(client: client).generate(
          config: _config(ImageGenerationProtocol.syncJson),
          apiKey: 'test-key',
          prompt: 'test',
        ),
        throwsA(
          isA<ImageGenerationException>()
              .having((error) => error.stage, 'stage', 'image_download')
              .having((error) => error.outcomeUnknown, 'unknown', isTrue),
        ),
      );
      expect(submits, 1);
      client.close();
    },
  );

  test('explicit submit rejection remains a known failure', () async {
    final client = MockClient((_) async => http.Response('invalid model', 400));
    await expectLater(
      ImageGenerationService(client: client).generate(
        config: _config(ImageGenerationProtocol.syncJson),
        apiKey: 'test-key',
        prompt: 'test',
      ),
      throwsA(
        isA<ImageGenerationException>()
            .having((error) => error.statusCode, 'status', 400)
            .having((error) => error.outcomeUnknown, 'unknown', isFalse),
      ),
    );
    client.close();
  });

  for (final endpoint in ['/v3/jobs?version=2', 'jobs?version=2']) {
    test(
      'relative endpoint query survives submission and polling: $endpoint',
      () async {
        var submits = 0;
        var polls = 0;
        final client = MockClient((request) async {
          if (request.method == 'POST') {
            submits++;
            expect(
              request.url.path,
              endpoint.startsWith('/') ? '/v3/jobs' : '/v1/jobs',
            );
            expect(request.url.queryParameters['version'], '2');
            return _json({'task_id': 'task-1'}, status: 202);
          }
          polls++;
          expect(request.url.path, '/v3/status/task-1');
          expect(request.url.queryParameters['version'], '3');
          return _json({'status': 'done', 'image_base64': base64Encode(_png)});
        });
        final result =
            await ImageGenerationService(
              client: client,
              sleeper: (_) async {},
            ).generate(
              config: _config(
                ImageGenerationProtocol.asyncTask,
                endpointPath: endpoint,
                statusEndpointTemplate: '/v3/status/{task_id}?version=3',
              ),
              apiKey: 'test-key',
              prompt: 'test',
            );
        expect(result.bytes, _png);
        expect(submits, 1);
        expect(polls, 1);
        client.close();
      },
    );
  }

  test(
    'defaults allow long synchronous requests and fifteen-minute polling',
    () {
      final client = MockClient((_) async => _json({}));
      final service = ImageGenerationService(client: client);
      expect(service.requestTimeout, const Duration(seconds: 900));
      expect(service.pollInterval, const Duration(seconds: 2));
      expect(service.maxPollAttempts, 450);
      client.close();
    },
  );

  test(
    'OpenAI Images sends the selected model and accepts Base64 output',
    () async {
      final phases = <ImageGenerationPhase>[];
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/images/generations');
        expect(request.headers['authorization'], 'Bearer secret-key');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['model'], 'gpt-image-test');
        expect(body['prompt'], 'draw Ryza');
        expect(body['size'], '1024x1024');
        expect(body['output_format'], 'png');
        return _json({
          'data': [
            {'b64_json': base64Encode(_png)},
          ],
        });
      });
      final service = ImageGenerationService(client: client);

      final result = await service.generate(
        config: _config(
          ImageGenerationProtocol.openAiImages,
          model: 'gpt-image-test',
        ),
        apiKey: ' secret-key ',
        prompt: 'draw Ryza',
        onProgress: phases.add,
      );

      expect(result.bytes, _png);
      expect(result.mimeType, 'image/png');
      expect(result.protocol, ImageGenerationProtocol.openAiImages);
      expect(phases, [
        ImageGenerationPhase.submitting,
        ImageGenerationPhase.completed,
      ]);
      client.close();
    },
  );

  test(
    'OpenAI Responses uses image_generation and parses its result',
    () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/v1/responses');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['input'], 'portrait');
        expect((body['tools'] as List).single['type'], 'image_generation');
        return _json({
          'output': [
            {'type': 'reasoning', 'summary': 'not an image'},
            {'type': 'image_generation_call', 'result': base64Encode(_png)},
          ],
        });
      });
      final result = await ImageGenerationService(client: client).generate(
        config: _config(ImageGenerationProtocol.openAiResponses),
        apiKey: 'key',
        prompt: 'portrait',
      );
      expect(result.protocol, ImageGenerationProtocol.openAiResponses);
      expect(result.bytes, _png);
      client.close();
    },
  );

  test('Gemini uses x-goog-api-key and parses inlineData', () async {
    final client = MockClient((request) async {
      expect(
        request.url.path,
        '/v1beta/models/gemini-2.5-flash-image:generateContent',
      );
      expect(request.url.queryParameters.containsKey('key'), isFalse);
      expect(request.headers['x-goog-api-key'], 'gemini-secret');
      expect(request.headers.containsKey('authorization'), isFalse);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['generationConfig']['responseModalities'], ['TEXT', 'IMAGE']);
      expect(body['generationConfig']['imageConfig']['aspectRatio'], '1:1');
      return _json({
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': 'done'},
                {
                  'inlineData': {
                    'mimeType': 'image/png',
                    'data': base64Encode(_png),
                  },
                },
              ],
            },
          },
        ],
      });
    });
    final result = await ImageGenerationService(client: client).generate(
      config: _config(
        ImageGenerationProtocol.gemini,
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        model: 'gemini-2.5-flash-image',
      ),
      apiKey: 'gemini-secret',
      prompt: '一张图',
    );
    expect(result.protocol, ImageGenerationProtocol.gemini);
    expect(result.mimeType, 'image/png');
    client.close();
  });

  test(
    'sync JSON downloads a URL and does not leak auth cross-origin',
    () async {
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        if (request.method == 'POST') {
          expect(request.url.toString(), 'https://provider.example/generate');
          expect(request.headers['authorization'], 'Bearer provider-key');
          return _json({
            'result': {
              'images': [
                {'url': 'https://cdn.example/output.jpg'},
              ],
            },
          });
        }
        expect(request.url.toString(), 'https://cdn.example/output.jpg');
        expect(request.headers.containsKey('authorization'), isFalse);
        return http.Response.bytes(
          _jpeg,
          200,
          headers: {'content-type': 'image/jpeg'},
        );
      });
      final result = await ImageGenerationService(client: client).generate(
        config: _config(
          ImageGenerationProtocol.syncJson,
          baseUrl: 'https://provider.example/generate',
        ),
        apiKey: 'provider-key',
        prompt: 'test',
      );
      expect(requests, 2);
      expect(result.mimeType, 'image/jpeg');
      expect(result.sourceUrl, 'https://cdn.example/output.jpg');
      client.close();
    },
  );

  test(
    'async task submits once, polls, and downloads the final image',
    () async {
      var submits = 0;
      var polls = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          submits++;
          return _json({
            'data': {
              'id': 'task-1-123e4567-e89b-12d3-a456-426614174000',
              'status': 'processing',
              'status_url': '/v1/tasks/task-1',
            },
          }, status: 202);
        }
        if (request.url.path == '/v1/tasks/task-1') {
          polls++;
          expect(request.headers['authorization'], 'Bearer key');
          if (polls == 1) {
            return _json({
              'data': {
                'status': 'processing',
                'id': 'task-1-123e4567-e89b-12d3-a456-426614174000',
              },
            });
          }
          return _json({
            'status': 'succeeded',
            'output': ['https://provider.example/v1/files/result.png'],
          });
        }
        expect(request.url.path, '/v1/files/result.png');
        return http.Response.bytes(
          _png,
          200,
          headers: {'content-type': 'image/png'},
        );
      });
      final service = ImageGenerationService(
        client: client,
        pollInterval: Duration.zero,
        maxPollAttempts: 4,
        sleeper: (_) async {},
      );
      final result = await service.generate(
        config: _config(
          ImageGenerationProtocol.asyncTask,
          baseUrl: 'https://provider.example/v1/generate',
        ),
        apiKey: 'key',
        prompt: 'test',
      );
      expect(submits, 1);
      expect(polls, 2);
      expect(result.protocol, ImageGenerationProtocol.asyncTask);
      expect(result.bytes, _png);
      client.close();
    },
  );

  test(
    'cross-origin status and signed CDN URLs never receive provider auth',
    () async {
      var submits = 0;
      var statusPolls = 0;
      var downloads = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          submits++;
          expect(request.url.host, 'provider.example');
          expect(request.headers['authorization'], 'Bearer provider-secret');
          return _json({
            'task_id': 'task-cross-origin',
            'status_url': 'https://status.example/tasks/task-cross-origin?token=signed-status',
          }, status: 202);
        }
        if (request.url.host == 'status.example') {
          statusPolls++;
          expect(request.url.queryParameters['token'], 'signed-status');
          expect(request.headers.containsKey('authorization'), isFalse);
          return _json({
            'status': 'complete',
            'image_url': 'https://cdn-user:cdn-password@cdn.example/result.png?access_token=signed-image#download',
          });
        }
        downloads++;
        expect(request.url.host, 'cdn.example');
        expect(request.url.queryParameters['access_token'], 'signed-image');
        expect(
          request.headers['authorization'],
          isNot('Bearer provider-secret'),
        );
        return http.Response.bytes(
          _png,
          200,
          headers: {'content-type': 'image/png'},
        );
      });
      final service = ImageGenerationService(
        client: client,
        pollInterval: Duration.zero,
        sleeper: (_) async {},
      );
      final result = await service.generate(
        config: _config(
          ImageGenerationProtocol.asyncTask,
          baseUrl: 'https://provider.example/v1/generate',
        ),
        apiKey: 'provider-secret',
        prompt: 'test',
      );
      expect(submits, 1);
      expect(statusPolls, 1);
      expect(downloads, 1);
      expect(result.sourceUrl, 'https://cdn.example/result.png');
      client.close();
    },
  );

  test(
    'auto classifies the first unknown response without resubmitting',
    () async {
      var submits = 0;
      var polls = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          submits++;
          return _json({'id': 'abc', 'status': 'queued'}, status: 202);
        }
        polls++;
        expect(request.url.path, '/v2/tasks/abc');
        return _json({
          'state': 'done',
          'images': [
            {'base64': base64Encode(_png), 'mime_type': 'image/png'},
          ],
        });
      });
      final service = ImageGenerationService(
        client: client,
        pollInterval: Duration.zero,
        maxPollAttempts: 2,
        sleeper: (_) async {},
      );
      final result = await service.generate(
        config: _config(
          ImageGenerationProtocol.auto,
          baseUrl: 'https://unknown.example/v2/generate',
        ),
        apiKey: 'key',
        prompt: 'test',
      );
      expect(submits, 1);
      expect(polls, 1);
      expect(result.protocol, ImageGenerationProtocol.asyncTask);
      client.close();
    },
  );

  test('custom status template is used for async providers', () async {
    var submits = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        submits++;
        expect(request.url.path, '/v3/jobs');
        return _json({'job': 'ignored', 'task_id': 42}, status: 202);
      }
      expect(request.url.path, '/v3/status/42');
      return _json({'status': 'complete', 'output': base64Encode(_png)});
    });
    final service = ImageGenerationService(
      client: client,
      pollInterval: Duration.zero,
      sleeper: (_) async {},
    );
    final result = await service.generate(
      config: _config(
        ImageGenerationProtocol.asyncTask,
        baseUrl: 'https://provider.example',
        endpointPath: '/v3/jobs',
        statusEndpointTemplate: '/v3/status/{task_id}',
      ),
      apiKey: '',
      prompt: 'test',
    );
    expect(submits, 1);
    expect(result.bytes, _png);
    client.close();
  });

  test(
    'ComfyUI submits a graph, polls history, and fetches view output',
    () async {
      var submits = 0;
      var history = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/prompt') {
          submits++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final graph = body['prompt'] as Map<String, dynamic>;
          expect(graph['positive']['inputs']['text'], 'Comfy prompt');
          expect(graph['latent']['inputs']['width'], 1024);
          return _json({'prompt_id': 'prompt-7'});
        }
        if (request.url.path == '/history/prompt-7') {
          history++;
          return _json({
            'prompt-7': {
              'status': {'completed': true, 'status_str': 'success'},
              'outputs': {
                'save': {
                  'images': [
                    {
                      'filename': 'result.png',
                      'subfolder': 'AgentAtelierR',
                      'type': 'output',
                    },
                  ],
                },
              },
            },
          });
        }
        expect(request.url.path, '/view');
        expect(request.url.queryParameters['filename'], 'result.png');
        expect(request.url.queryParameters['subfolder'], 'AgentAtelierR');
        return http.Response.bytes(
          _png,
          200,
          headers: {'content-type': 'image/png'},
        );
      });
      final service = ImageGenerationService(
        client: client,
        pollInterval: Duration.zero,
        sleeper: (_) async {},
      );
      final result = await service.generate(
        config: _config(
          ImageGenerationProtocol.comfyUi,
          baseUrl: 'http://127.0.0.1:8188',
        ),
        apiKey: '',
        prompt: 'Comfy prompt',
        comfyWorkflow: {
          'positive': {
            'class_type': 'CLIPTextEncode',
            'inputs': {'text': r'${prompt}'},
          },
          'latent': {
            'class_type': 'EmptyLatentImage',
            'inputs': {'width': r'${width}', 'height': r'${height}'},
          },
        },
      );
      expect(submits, 1);
      expect(history, 1);
      expect(result.protocol, ImageGenerationProtocol.comfyUi);
      expect(result.bytes, _png);
      client.close();
    },
  );

  test('ComfyUI nested execution errors stop polling immediately', () async {
    var submits = 0;
    var polls = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        submits++;
        return _json({'prompt_id': 'failed-prompt'});
      }
      polls++;
      return _json({
        'failed-prompt': {
          'status': {'completed': false, 'status_str': 'error'},
          'outputs': <String, dynamic>{},
        },
      });
    });
    final service = ImageGenerationService(
      client: client,
      pollInterval: Duration.zero,
      sleeper: (_) async {},
    );
    await expectLater(
      service.generate(
        config: _config(
          ImageGenerationProtocol.comfyUi,
          baseUrl: 'http://127.0.0.1:8188',
        ),
        apiKey: '',
        prompt: 'test',
      ),
      throwsA(
        isA<ImageGenerationException>()
            .having((error) => error.code, 'code', 'task_failed')
            .having((error) => error.outcomeUnknown, 'unknown', isFalse),
      ),
    );
    expect(submits, 1);
    expect(polls, 1);
    client.close();
  });

  test('MIME and file signature must agree', () async {
    final client = MockClient(
      (_) async => _json({
        'images': [
          {'base64': base64Encode(_png), 'mime_type': 'image/jpeg'},
        ],
      }),
    );
    await expectLater(
      ImageGenerationService(client: client).generate(
        config: _config(ImageGenerationProtocol.syncJson),
        apiKey: 'secret',
        prompt: 'test',
      ),
      throwsA(
        isA<ImageGenerationException>().having(
          (error) => error.code,
          'code',
          'mime_signature_mismatch',
        ),
      ),
    );
    client.close();
  });

  test('image size limit is enforced after Base64 decode', () async {
    final client = MockClient(
      (_) async => _json({'image_base64': base64Encode(_png)}),
    );
    await expectLater(
      ImageGenerationService(client: client, maxImageBytes: 8).generate(
        config: _config(ImageGenerationProtocol.syncJson),
        apiKey: '',
        prompt: 'test',
      ),
      throwsA(
        isA<ImageGenerationException>().having(
          (error) => error.code,
          'code',
          'image_too_large',
        ),
      ),
    );
    client.close();
  });

  test(
    'unknown auto response is not retried and never exposes API key',
    () async {
      var calls = 0;
      const secret = 'never-print-this-key';
      final client = MockClient((request) async {
        calls++;
        expect(request.headers['authorization'], 'Bearer $secret');
        return _json({'status': 'accepted-but-no-id'}, status: 202);
      });
      Object? caught;
      try {
        await ImageGenerationService(client: client).generate(
          config: _config(
            ImageGenerationProtocol.auto,
            baseUrl: 'https://unknown.example/generate',
          ),
          apiKey: secret,
          prompt: 'test',
        );
      } on Object catch (error) {
        caught = error;
      }
      expect(calls, 1);
      expect(caught, isA<ImageGenerationException>());
      expect((caught! as ImageGenerationException).outcomeUnknown, isTrue);
      expect(caught.toString(), isNot(contains(secret)));
      client.close();
    },
  );

  test(
    'a forced sync protocol never switches to async after submission',
    () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return _json({'task_id': 'paid-task'}, status: 202);
      });
      await expectLater(
        ImageGenerationService(client: client).generate(
          config: _config(ImageGenerationProtocol.syncJson),
          apiKey: 'key',
          prompt: 'test',
        ),
        throwsA(
          isA<ImageGenerationException>().having(
            (error) => error.code,
            'code',
            'missing_image',
          ),
        ),
      );
      expect(calls, 1);
      client.close();
    },
  );
}
