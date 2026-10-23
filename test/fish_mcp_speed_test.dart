import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:ryza_chat_mvp/src/fish_mcp_service.dart';
import 'package:ryza_chat_mvp/src/speech_tempo.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _mp3 = <int>[0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0, 0, 0];

Tool _tool(String name, Map<String, dynamic> properties) => Tool(
  name: name,
  inputSchema: JsonSchema.fromJson({
    'type': 'object',
    'properties': properties,
    'additionalProperties': false,
  }),
);

class _SpeedClient extends McpClient {
  _SpeedClient({this.speedField, this.studio = false})
    : super(const Implementation(name: 'speed-local-only', version: '1'));

  final String? speedField;
  final bool studio;
  final requests = <CallToolRequest>[];
  final project = <String, dynamic>{
    'project_id': 'speed-local-project',
    'default_backend': 'drama-3',
    'scene_preset': 'off',
    'chapters': [
      {'anchor': 'speed-local-chapter'},
    ],
  };

  @override
  Future<ListToolsResult> listTools({
    ListToolsRequest? params,
    RequestOptions? options,
  }) async => ListToolsResult(
    tools: [
      _tool('text_to_speech', {
        'text': {'type': 'string'},
        if (!studio) 'model': {'type': 'string'},
        ?speedField: {'type': 'number'},
      }),
      if (studio) ...[
        _tool('studio_help', {}),
        _tool('studio_create_project', {
          'name': {'type': 'string'},
          'roster': {'type': 'array'},
          'default_voice_id': {'type': 'string'},
          'chapters': {'type': 'array'},
        }),
        _tool('studio_update_project', {
          'project_id': {'type': 'string'},
          'default_backend': {'type': 'string'},
          'scene_preset': {'type': 'string'},
        }),
        _tool('studio_project', {
          'project_id': {'type': 'string'},
        }),
        _tool('studio_write_blocks', {
          'project_id': {'type': 'string'},
          'ops': {'type': 'array'},
        }),
        _tool('studio_generate', {
          'project_id': {'type': 'string'},
          'blocks': {'type': 'array'},
          'dry_run': {'type': 'boolean'},
        }),
      ],
    ],
  );

  @override
  Future<CallToolResult> callTool(
    CallToolRequest params, {
    RequestOptions? options,
  }) async {
    requests.add(params);
    Map<String, dynamic> result;
    switch (params.name) {
      case 'text_to_speech':
        return CallToolResult(
          content: [
            AudioContent(data: base64Encode(_mp3), mimeType: 'audio/mpeg'),
          ],
        );
      case 'studio_help':
        result = {'overview': 'Local fixture'};
      case 'studio_create_project':
        project['default_voice_id'] = params.arguments['default_voice_id'];
        result = {...project};
      case 'studio_update_project':
        project.addAll(params.arguments);
        result = {...project};
      case 'studio_project':
        result = {...project};
      case 'studio_write_blocks':
        result = {
          'results': [
            {'anchor': 'speed-local-block'},
          ],
        };
      case 'studio_generate':
        result = params.arguments['dry_run'] == true
            ? {
                'blocks_to_generate': 1,
                'cached': 0,
                'estimated_credits': 10,
                'balance': 1000,
              }
            : {
                'status': 'done',
                'results': [
                  {
                    'anchor': 'speed-local-block',
                    'audio_url':
                        'https://platform.r2.fish.audio/local/speed.mp3',
                  },
                ],
              };
      default:
        throw StateError('Unexpected fixture tool');
    }
    return CallToolResult(content: const [], structuredContent: result);
  }

  int get generations => requests
      .where(
        (request) =>
            request.name == 'text_to_speech' ||
            (request.name == 'studio_generate' &&
                request.arguments['dry_run'] != true),
      )
      .length;

  @override
  Future<void> close() async {}
}

Future<(FishMcpService, Directory)> _service(
  _SpeedClient client,
  SpeechFileTempoProcessor processor,
) async {
  final directory = await Directory.systemTemp.createTemp('mcp-speed-test-');
  final downloader = MockClient((_) async => http.Response.bytes(_mp3, 200));
  final service = FishMcpService.forTesting(
    client: client,
    downloadClient: downloader,
    temporaryDirectory: () async => directory,
    tempoProcessor: processor,
  );
  addTearDown(() async {
    await service.disconnect();
    service.dispose();
    downloader.close();
    await directory.delete(recursive: true);
  });
  await service.discoverTools();
  return (service, directory);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final field in ['speed', 'prosody_speed']) {
    test(
      'declared $field is sent once without a local second adjustment',
      () async {
        final client = _SpeedClient(speedField: field);
        final (service, directory) = await _service(client, (
          _, {
          required speed,
          isCurrent,
        }) async {
          fail('Remote speed must not be applied again locally');
        });
        final path = await service.synthesize(
          text: 'local fixture',
          model: 's2.1-pro',
          speed: 0.9,
        );
        expect(client.generations, 1);
        expect(client.requests.single.arguments[field], 0.9);
        expect(File(path).existsSync(), isTrue);
        expect(directory.listSync(), hasLength(1));
        expect(
          (jsonDecode(service.diagnosticReport) as Map)['last_request'],
          containsPair('speed_control', 'server'),
        );
      },
    );
  }

  for (final studio in [false, true]) {
    test(
      '${studio ? "Studio" : "ordinary MCP"} without speed uses one local adjustment',
      () async {
        final client = _SpeedClient(studio: studio);
        var processed = 0;
        String? source;
        final (service, directory) = await _service(client, (
          path, {
          required speed,
          isCurrent,
        }) async {
          processed++;
          source = path;
          expect(speed, 0.9);
          expect(isCurrent?.call(), isTrue);
          final output = '$path.local.wav';
          await File(output).writeAsBytes([1, 2, 3]);
          return output;
        });
        final path = await service.synthesize(
          text: 'local fixture',
            voice: 'local-voice',
          model: studio ? 'drama-3' : 's2.1-pro-free',
          speed: 0.9,
        );
        expect(processed, 1);
        expect(client.generations, 1);
        expect(File(source!).existsSync(), isFalse);
        expect(File(path).existsSync(), isTrue);
        expect(directory.listSync(), hasLength(1));
        final request =
            (jsonDecode(service.diagnosticReport) as Map)['last_request']
                as Map;
        expect(request['requested_speed'], 0.9);
        expect(request['speed_control'], 'local');
      },
    );
  }

  test(
    'default speed keeps the existing generated file without processing',
    () async {
      final client = _SpeedClient();
      final (service, _) = await _service(
        client,
        (_, {required speed, isCurrent}) async =>
            fail('No processing at speed 1'),
      );
      final path = await service.synthesize(
        text: 'local fixture',
        model: 's2.1-pro',
      );
      expect(File(path).readAsBytesSync(), _mp3);
      expect(client.generations, 1);
    },
  );

  test(
    'local failure cleans original and prohibits retry or REST fallback',
    () async {
      final client = _SpeedClient();
      final (service, directory) = await _service(client, (
        _, {
        required speed,
        isCurrent,
      }) async {
        throw const SpeechTempoException(
          'tempo_decode_unsupported',
          'Local fixture unsupported',
        );
      });
      await expectLater(
        service.synthesize(
          text: 'local fixture',
          model: 's2.1-pro',
          speed: 0.9,
        ),
        throwsA(
          isA<FishMcpException>()
              .having((error) => error.generationSubmitted, 'submitted', isTrue)
              .having((error) => error.allowsRestFallback, 'fallback', isFalse)
              .having(
                (error) => error.code,
                'code',
                'tempo_decode_unsupported',
              ),
        ),
      );
      expect(client.generations, 1);
      expect(directory.listSync(), isEmpty);
    },
  );

  test(
    'cancellation during local processing deletes input and returned output',
    () async {
      final client = _SpeedClient();
      var current = true;
      final (service, directory) = await _service(client, (
        path, {
        required speed,
        isCurrent,
      }) async {
        final output = '$path.local.wav';
        await File(output).writeAsBytes([1, 2, 3]);
        current = false;
        expect(isCurrent?.call(), isFalse);
        return output;
      });
      await expectLater(
        service.synthesize(
          text: 'local fixture',
          model: 's2.1-pro',
          speed: 0.9,
          isCurrent: () => current,
        ),
        throwsA(
          isA<FishMcpException>().having(
            (error) => error.generationSubmitted,
            'submitted',
            isTrue,
          ),
        ),
      );
      expect(client.generations, 1);
      expect(directory.listSync(), isEmpty);
    },
  );

  test(
    'disconnect during processing discards both files after one generation',
    () async {
      final client = _SpeedClient();
      late FishMcpService service;
      final result = await _service(client, (
        path, {
        required speed,
        isCurrent,
      }) async {
        final output = '$path.local.wav';
        await File(output).writeAsBytes([1, 2, 3]);
        await service.disconnect();
        expect(isCurrent?.call(), isFalse);
        return output;
      });
      service = result.$1;
      await expectLater(
        service.synthesize(
          text: 'local fixture',
          model: 's2.1-pro',
          speed: 0.9,
        ),
        throwsA(
          isA<FishMcpException>().having(
            (error) => error.generationSubmitted,
            'submitted',
            isTrue,
          ),
        ),
      );
      expect(client.generations, 1);
      expect(result.$2.listSync(), isEmpty);
    },
  );

  test('nonfinite speed is rejected before submitting generation', () async {
    final client = _SpeedClient();
    final (service, directory) = await _service(
      client,
      (_, {required speed, isCurrent}) async => fail('No processing'),
    );
    await expectLater(
      service.synthesize(
        text: 'local fixture',
        model: 's2.1-pro',
        speed: double.nan,
      ),
      throwsA(
        isA<FishMcpException>().having(
          (error) => error.generationSubmitted,
          'submitted',
          isFalse,
        ),
      ),
    );
    expect(client.generations, 0);
    expect(directory.listSync(), isEmpty);
  });
}
