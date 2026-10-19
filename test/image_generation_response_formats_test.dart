import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/image_generation_config.dart';
import 'package:ryza_chat_mvp/src/image_generation_service.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aOe8AAAAASUVORK5CYII=',
);

final Uint8List _jpeg = base64Decode(
  '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCdAAB//9k=',
);

const _submitProtocols = [
  ImageGenerationProtocol.auto,
  ImageGenerationProtocol.syncJson,
  ImageGenerationProtocol.openAiImages,
  ImageGenerationProtocol.openAiResponses,
  ImageGenerationProtocol.gemini,
  ImageGenerationProtocol.asyncTask,
];

ImageGenerationConfig _config(ImageGenerationProtocol protocol) =>
    ImageGenerationConfig(
      enabled: true,
      baseUrl: 'https://unknown.example/generate',
      model: 'image-test-model',
      protocol: protocol,
      maxPollAttempts: 3,
    );

http.Response _json(Object value, {int status = 200}) => http.Response.bytes(
  utf8.encode(jsonEncode(value)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response _eventStream(String value) => http.Response.bytes(
  utf8.encode(value),
  200,
  headers: {'content-type': 'text/event-stream; charset=utf-8'},
);

String _event(String name, Object value) =>
    'event: $name\ndata: ${jsonEncode(value)}\n\n';

Future<ImageGenerationException> _expectUnknownFailure(
  Future<ImageGenerationResult> result,
  String code,
) async {
  try {
    await result;
    fail('Expected ImageGenerationException with code $code');
  } on ImageGenerationException catch (error) {
    expect(error.code, code);
    expect(error.requestSubmitted, isTrue);
    expect(error.outcomeUnknown, isTrue);
    return error;
  }
}

void main() {
  group('direct image responses', () {
    for (final protocol in _submitProtocols) {
      for (final fixture in [
        (bytes: _png, mime: 'image/png'),
        (bytes: _jpeg, mime: 'image/jpeg'),
      ]) {
        test('${protocol.name} accepts ${fixture.mime} on submit', () async {
          var submits = 0;
          final client = MockClient((request) async {
            expect(request.method, 'POST');
            submits++;
            return http.Response.bytes(
              fixture.bytes,
              200,
              headers: {'content-type': fixture.mime},
            );
          });
          addTearDown(client.close);

          final result = await ImageGenerationService(client: client).generate(
            config: _config(protocol),
            apiKey: 'test-key',
            prompt: 'A small watercolor landscape',
          );

          expect(result.bytes, fixture.bytes);
          expect(result.mimeType, fixture.mime);
          expect(submits, 1);
        });
      }

      test(
        '${protocol.name} rejects an image MIME/signature mismatch',
        () async {
          var submits = 0;
          final client = MockClient((request) async {
            expect(request.method, 'POST');
            submits++;
            return http.Response.bytes(
              _png,
              200,
              headers: {'content-type': 'image/jpeg'},
            );
          });
          addTearDown(client.close);

          await _expectUnknownFailure(
            ImageGenerationService(client: client).generate(
              config: _config(protocol),
              apiKey: 'test-key',
              prompt: 'A small watercolor landscape',
            ),
            'mime_signature_mismatch',
          );
          expect(submits, 1);
        },
      );
    }

    test(
      'an octet-stream response is identified by its image signature',
      () async {
        var submits = 0;
        final client = MockClient((request) async {
          expect(request.method, 'POST');
          submits++;
          return http.Response.bytes(
            _png,
            200,
            headers: {'content-type': 'application/octet-stream'},
          );
        });
        addTearDown(client.close);

        final result = await ImageGenerationService(client: client).generate(
          config: _config(ImageGenerationProtocol.auto),
          apiKey: 'test-key',
          prompt: 'A small watercolor landscape',
        );

        expect(result.bytes, _png);
        expect(result.mimeType, 'image/png');
        expect(submits, 1);
      },
    );

    test('direct image responses obey the image byte limit', () async {
      var submits = 0;
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        submits++;
        return http.Response.bytes(
          _png,
          200,
          headers: {'content-type': 'image/png'},
        );
      });
      addTearDown(client.close);

      await _expectUnknownFailure(
        ImageGenerationService(
          client: client,
          maxImageBytes: _png.length - 1,
        ).generate(
          config: _config(ImageGenerationProtocol.auto),
          apiKey: 'test-key',
          prompt: 'A small watercolor landscape',
        ),
        'image_too_large',
      );
      expect(submits, 1);
    });

    for (final protocol in [
      ImageGenerationProtocol.auto,
      ImageGenerationProtocol.asyncTask,
    ]) {
      test(
        '${protocol.name} accepts a direct image from task polling',
        () async {
          var submits = 0;
          var polls = 0;
          final client = MockClient((request) async {
            if (request.method == 'POST') {
              submits++;
              return _json({
                'task_id': 'task-test-1',
                'status': 'queued',
                'status_url': '/tasks/task-test-1',
              }, status: 202);
            }
            expect(request.method, 'GET');
            expect(request.url.path, '/tasks/task-test-1');
            polls++;
            return http.Response.bytes(
              _jpeg,
              200,
              headers: {'content-type': 'image/jpeg'},
            );
          });
          addTearDown(client.close);

          final result =
              await ImageGenerationService(
                client: client,
                pollInterval: Duration.zero,
                sleeper: (_) async {},
              ).generate(
                config: _config(protocol),
                apiKey: 'test-key',
                prompt: 'A small watercolor landscape',
              );

          expect(result.bytes, _jpeg);
          expect(result.mimeType, 'image/jpeg');
          expect(submits, 1);
          expect(polls, 1);
        },
      );
    }
  });

  group('text response classification', () {
    for (final protocol in _submitProtocols) {
      test('${protocol.name} accepts UTF-8 BOM-prefixed JSON', () async {
        var submits = 0;
        final client = MockClient((request) async {
          expect(request.method, 'POST');
          submits++;
          return http.Response.bytes(
            [
              ...const [0xef, 0xbb, 0xbf],
              ...utf8.encode(
                jsonEncode({
                  'data': [
                    {'b64_json': base64Encode(_png)},
                  ],
                }),
              ),
            ],
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        });
        addTearDown(client.close);

        final result = await ImageGenerationService(client: client).generate(
          config: _config(protocol),
          apiKey: 'test-key',
          prompt: 'A small watercolor landscape',
        );

        expect(result.bytes, _png);
        expect(submits, 1);
      });
    }

    for (final fixture in [
      (
        name: 'HTML landing page',
        mime: 'text/html; charset=utf-8',
        body:
            '<!doctype html><html><body>private-response-content</body></html>',
        code: 'html_response',
        format: 'html',
      ),
      (
        name: 'HTML with a misleading JSON MIME',
        mime: 'application/json',
        body: '<html><body>private-response-content</body></html>',
        code: 'html_response',
        format: 'html',
      ),
      (
        name: 'truncated JSON',
        mime: 'application/json',
        body: '{"private-response-content":',
        code: 'invalid_json',
        format: 'json',
      ),
      (
        name: 'an arbitrary response MIME',
        mime: 'application/x-private-mime-value',
        body: '{"private-response-content":',
        code: 'invalid_json',
        format: 'other',
      ),
    ]) {
      test(
        '${fixture.name} reports safe diagnostics without resubmitting',
        () async {
          const apiKey = 'private-api-key';
          const headerSecret = 'private-header-secret';
          var submits = 0;
          final body = utf8.encode(fixture.body);
          final client = MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.headers['authorization'], 'Bearer $apiKey');
            submits++;
            return http.Response.bytes(
              body,
              200,
              headers: {
                'content-type': fixture.mime,
                'x-debug-secret': headerSecret,
              },
            );
          });
          addTearDown(client.close);

          final error = await _expectUnknownFailure(
            ImageGenerationService(client: client).generate(
              config: _config(ImageGenerationProtocol.auto),
              apiKey: apiKey,
              prompt: 'A small watercolor landscape',
            ),
            fixture.code,
          );

          expect(error.statusCode, 200);
          expect(
            error.toString(),
            contains('responseFormat=${fixture.format}'),
          );
          expect(error.toString(), contains('responseBytes=${body.length}'));
          for (final secret in [
            apiKey,
            headerSecret,
            'private-response-content',
            'private-mime-value',
          ]) {
            expect(error.toString(), isNot(contains(secret)));
          }
          expect(submits, 1);
        },
      );
    }
  });

  test('invalid UTF-8 is reported without exposing response bytes', () async {
    var submits = 0;
    const body = [0xff, 0xfe, 0x94, 0x00];
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      submits++;
      return http.Response.bytes(
        body,
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    addTearDown(client.close);

    final error = await _expectUnknownFailure(
      ImageGenerationService(client: client).generate(
        config: _config(ImageGenerationProtocol.auto),
        apiKey: 'test-key',
        prompt: 'A small watercolor landscape',
      ),
      'invalid_json',
    );
    expect(error.toString(), contains('responseFormat=json'));
    expect(error.toString(), contains('responseBytes=4'));
    expect(submits, 1);
  });

  test('an empty 202 with Location resumes the existing task', () async {
    var submits = 0;
    var polls = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        submits++;
        return http.Response.bytes(
          const [],
          202,
          headers: {'location': '/tasks/existing-paid-task'},
        );
      }
      expect(request.method, 'GET');
      expect(request.url.path, '/tasks/existing-paid-task');
      polls++;
      return _json({'image_base64': base64Encode(_png)});
    });
    addTearDown(client.close);

    final result =
        await ImageGenerationService(
          client: client,
          pollInterval: Duration.zero,
          sleeper: (_) async {},
        ).generate(
          config: _config(ImageGenerationProtocol.auto),
          apiKey: 'test-key',
          prompt: 'A small watercolor landscape',
        );
    expect(result.bytes, _png);
    expect(submits, 1);
    expect(polls, 1);
  });

  group('server-sent image generation events', () {
    test('image_generation.completed selects the final image only', () async {
      var submits = 0;
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        submits++;
        return _eventStream(
          ': generation heartbeat\n\n'
          '${_event('image_generation.partial_image', {'type': 'image_generation.partial_image', 'partial_image_index': 0, 'b64_json': base64Encode(_jpeg)})}'
          '${_event('image_generation.completed', {'type': 'image_generation.completed', 'b64_json': base64Encode(_png)})}'
          'data: [DONE]\n\n',
        );
      });
      addTearDown(client.close);

      final result = await ImageGenerationService(client: client).generate(
        config: _config(ImageGenerationProtocol.openAiImages),
        apiKey: 'test-key',
        prompt: 'A small watercolor landscape',
      );

      expect(result.bytes, _png);
      expect(result.mimeType, 'image/png');
      expect(submits, 1);
    });

    test('response.completed reads its terminal nested response', () async {
      var submits = 0;
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        submits++;
        return _eventStream(
          _event('response.image_generation_call.partial_image', {
                'type': 'response.image_generation_call.partial_image',
                'partial_image_index': 0,
                'partial_image_b64': base64Encode(_jpeg),
              }) +
              _event('response.completed', {
                'type': 'response.completed',
                'response': {
                  'status': 'completed',
                  'output': [
                    {
                      'type': 'image_generation_call',
                      'status': 'completed',
                      'result': base64Encode(_png),
                    },
                  ],
                },
              }),
        );
      });
      addTearDown(client.close);

      final result = await ImageGenerationService(client: client).generate(
        config: _config(ImageGenerationProtocol.openAiResponses),
        apiKey: 'test-key',
        prompt: 'A small watercolor landscape',
      );

      expect(result.bytes, _png);
      expect(submits, 1);
    });

    for (final doneMarker in [false, true]) {
      test('a partial image ${doneMarker ? 'with DONE' : 'without completion'} '
          'never becomes a successful image', () async {
        var submits = 0;
        final client = MockClient((request) async {
          expect(request.method, 'POST');
          submits++;
          return _eventStream(
            _event('image_generation.partial_image', {
                  'type': 'image_generation.partial_image',
                  'b64_json': base64Encode(_png),
                }) +
                (doneMarker ? 'data: [DONE]\n\n' : ''),
          );
        });
        addTearDown(client.close);

        await _expectUnknownFailure(
          ImageGenerationService(client: client).generate(
            config: _config(ImageGenerationProtocol.auto),
            apiKey: 'test-key',
            prompt: 'A small watercolor landscape',
          ),
          'incomplete_event_stream',
        );
        expect(submits, 1);
      });
    }

    test(
      'an error event is classified without exposing error content',
      () async {
        var submits = 0;
        final client = MockClient((request) async {
          expect(request.method, 'POST');
          submits++;
          return _eventStream(
            _event('error', {
              'type': 'error',
              'error': {
                'code': 'upstream_failure',
                'message': 'private-provider-error-content',
                'authorization': 'private-response-token',
              },
            }),
          );
        });
        addTearDown(client.close);

        final error = await _expectUnknownFailure(
          ImageGenerationService(client: client).generate(
            config: _config(ImageGenerationProtocol.auto),
            apiKey: 'test-key',
            prompt: 'A small watercolor landscape',
          ),
          'event_stream_error',
        );

        expect(
          error.toString(),
          isNot(contains('private-provider-error-content')),
        );
        expect(error.toString(), isNot(contains('private-response-token')));
        expect(submits, 1);
      },
    );
  });
}
