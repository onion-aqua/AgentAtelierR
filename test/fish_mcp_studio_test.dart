import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:ryza_chat_mvp/src/fish_mcp_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Local transport integration tests: every MCP result and audio download is a
// fixture. No OAuth request, live tool, or credit-consuming generation is used.
const _mp3 = <int>[0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0];
const _studioNames = [
  'studio_help',
  'studio_create_project',
  'studio_update_project',
  'studio_write_blocks',
  'studio_project',
  'studio_generate',
];

Tool _tool(
  String name, {
  Map<String, dynamic> properties = const {},
  List<String> required = const [],
}) => Tool(
  name: name,
  inputSchema: JsonSchema.fromJson({
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  }),
);

List<Tool> _tools({bool directModel = false}) => [
  _tool(
    'text_to_speech',
    properties: {
      'text': {'type': 'string'},
      'voice_id': {'type': 'string'},
      'language': {'type': 'string'},
      if (directModel) 'model': {'type': 'string'},
    },
    required: ['text'],
  ),
  _tool('studio_help'),
  _tool(
    'studio_create_project',
    properties: {
      'name': {'type': 'string'},
      'roster': {'type': 'array'},
      'default_voice_id': {'type': 'string'},
      'chapters': {'type': 'array'},
    },
    required: ['name'],
  ),
  _tool(
    'studio_update_project',
    properties: {
      'project_id': {'type': 'string'},
      'default_backend': {'type': 'string'},
      'scene_preset': {'type': 'string'},
    },
    required: ['project_id'],
  ),
  _tool(
    'studio_write_blocks',
    properties: {
      'project_id': {'type': 'string'},
      'ops': {'type': 'array'},
    },
    required: ['project_id', 'ops'],
  ),
  _tool(
    'studio_project',
    properties: {
      'project_id': {'type': 'string'},
    },
    required: ['project_id'],
  ),
  _tool(
    'studio_generate',
    properties: {
      'project_id': {'type': 'string'},
      'blocks': {'type': 'array'},
      'dry_run': {'type': 'boolean'},
    },
    required: ['project_id'],
  ),
];

CallToolResult _data(Map<String, dynamic> value) =>
    CallToolResult(content: const [], structuredContent: value);

CallToolResult _inline() => CallToolResult(
  content: [AudioContent(data: base64Encode(_mp3), mimeType: 'audio/mpeg')],
);

CallToolResult _error(String code) => CallToolResult(
  isError: true,
  content: const [TextContent(text: 'Synthetic Studio rejection')],
  structuredContent: {
    'error': {'code': code, 'message': 'Synthetic Studio rejection'},
    'request_id': 'req-local-studio',
  },
);

class _StudioClient extends McpClient {
  _StudioClient({List<Tool>? tools, this.intercept, this.inlineAudio = false})
    : definitions = tools ?? _tools(),
      super(const Implementation(name: 'studio-local-test', version: '1'));

  final List<Tool> definitions;
  final FutureOr<CallToolResult?> Function(CallToolRequest request)? intercept;
  final bool inlineAudio;
  final requests = <CallToolRequest>[];
  final projects = <String, Map<String, dynamic>>{};
  var _blockSerial = 0;

  List<CallToolRequest> named(String name) =>
      requests.where((request) => request.name == name).toList();

  List<CallToolRequest> get paidGenerations =>
      named('studio_generate')
          .where((request) => request.arguments['dry_run'] != true)
          .toList();

  @override
  Future<ListToolsResult> listTools({
    ListToolsRequest? params,
    RequestOptions? options,
  }) async => ListToolsResult(tools: definitions);

  @override
  Future<CallToolResult> callTool(
    CallToolRequest params, {
    RequestOptions? options,
  }) async {
    requests.add(params);
    final intercepted = await intercept?.call(params);
    if (intercepted != null) return intercepted;
    final arguments = params.arguments;
    switch (params.name) {
      case 'text_to_speech':
        return _inline();
      case 'studio_help':
        return _data({'overview': 'Local fixture', 'tools': _studioNames});
      case 'studio_create_project':
        final id = 'project-${projects.length + 1}';
        final project = <String, dynamic>{
          'project_id': id,
          'default_voice_id': arguments['default_voice_id'],
          'default_backend': 's2.1-pro',
          'scene_preset': 'studio',
          'chapters': [
            {'anchor': '$id-chapter'},
          ],
        };
        projects[id] = project;
        return _data({...project});
      case 'studio_update_project':
        final project = projects[arguments['project_id']]!;
        project.addAll(arguments);
        return _data({...project});
      case 'studio_project':
        return _data({...projects[arguments['project_id']]!});
      case 'studio_write_blocks':
        return _data({
          'results': [
            {'anchor': 'block-${++_blockSerial}'},
          ],
        });
      case 'studio_generate':
        if (arguments['dry_run'] == true) {
          return _data({
            'blocks_to_generate': 1,
            'cached': 0,
            'estimated_credits': 20,
            'balance': 1000,
          });
        }
        if (inlineAudio) return _inline();
        return _data({
          'status': 'done',
          'results': [
            {
              'anchor': (arguments['blocks'] as List).single,
              'audio_url': 'https://platform.r2.fish.audio/local/speech.mp3',
            },
          ],
        });
      default:
        fail('Unexpected MCP tool ${params.name}');
    }
  }

  @override
  Future<void> close() async {}
}

class _Harness {
  _Harness(this.service, this.client, this.directory, this.downloads);

  final FishMcpService service;
  final _StudioClient client;
  final Directory directory;
  final List<http.Request> downloads;

  static Future<_Harness> create({_StudioClient? client}) async {
    final fake = client ?? _StudioClient();
    final directory = await Directory.systemTemp.createTemp(
      'fish-studio-local-',
    );
    final downloads = <http.Request>[];
    final downloader = MockClient((request) async {
      downloads.add(request);
      expect(request.url.host, 'platform.r2.fish.audio');
      expect(
        request.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('authorization')),
      );
      return http.Response.bytes(
        _mp3,
        200,
        headers: {'content-type': 'audio/mpeg'},
      );
    });
    final service = FishMcpService.forTesting(
      client: fake,
      downloadClient: downloader,
      temporaryDirectory: () async => directory,
    );
    addTearDown(() async {
      await service.disconnect();
      service.dispose();
      downloader.close();
      await directory.delete(recursive: true);
    });
    await service.discoverTools();
    return _Harness(service, fake, directory, downloads);
  }

  Future<String> synthesize({
    String text = '非公開のローカルテスト',
    String model = 'drama-3',
    String? voice = 'ordinary-voice',
    bool Function()? isCurrent,
  }) => service.synthesize(
    text: text,
    model: model,
    voice: voice,
    language: 'ja',
    isCurrent: isCurrent,
  );
}

Future<FishMcpException> _failure(Future<String> result) async {
  try {
    await result;
  } on FishMcpException catch (error) {
    return error;
  }
  fail('Expected FishMcpException');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'parallel Studio synthesis shares initialization and keeps unique blocks',
    () async {
      final paid = <String, Completer<CallToolResult>>{};
      final bothSubmitted = Completer<void>();
      final harness = await _Harness.create(
        client: _StudioClient(
          intercept: (request) async {
            if (request.name != 'studio_generate' ||
                request.arguments['dry_run'] == true) {
              return null;
            }
            final block =
                (request.arguments['blocks'] as List).single as String;
            final result = paid[block] = Completer<CallToolResult>();
            if (paid.length == 2) bothSubmitted.complete();
            return result.future;
          },
        ),
      );
      final first = harness.synthesize(text: '最初の文です。');
      final second = harness.synthesize(text: '次の文です。');
      await bothSubmitted.future.timeout(const Duration(seconds: 3));
      final keys = paid.keys.toList();
      CallToolResult completed(String block) => _data({
        'status': 'done',
        'results': [
          {
            'anchor': block,
            'audio_url': 'https://platform.r2.fish.audio/local/$block.mp3',
          },
        ],
      });
      paid[keys.last]!.complete(completed(keys.last));
      final secondPath = await second;
      paid[keys.first]!.complete(completed(keys.first));
      final firstPath = await first;
      expect(firstPath, isNot(secondPath));
      expect(
        harness.client.requests
            .where((r) => r.name == 'studio_create_project')
            .length,
        1,
      );
      expect(
        harness.client.requests
            .where((r) => r.name == 'studio_write_blocks')
            .length,
        2,
      );
      expect(paid.length, 2);
      expect(harness.downloads.map((r) => r.url.path), [
        '/local/${keys.last}.mp3',
        '/local/${keys.first}.mp3',
      ]);
    },
  );

  test(
    'Drama 3 follows confirmed Studio configuration and only its new block',
    () async {
      final harness = await _Harness.create();
      expect(harness.service.studioAvailable, isTrue);
      expect(harness.service.missingStudioTools, isEmpty);
      expect(harness.service.generationRouteForModel('drama-3'), 'studio');
      final path = await harness.synthesize();
      expect(await File(path).readAsBytes(), _mp3);
      final calls = harness.client.requests;
      expect(calls.map((call) => call.name), [
        'studio_help',
        'studio_create_project',
        'studio_update_project',
        'studio_update_project',
        'studio_project',
        'studio_write_blocks',
        'studio_generate',
        'studio_generate',
      ]);
      final create = calls[1].arguments;
      expect(create['name'], startsWith('AgentAtelierR'));
      expect(create['roster'], [
        {'name': 'AgentAtelierR', 'voice_id': 'ordinary-voice'},
      ]);
      expect(create['default_voice_id'], 'ordinary-voice');
      expect(create['chapters'], isEmpty);
      expect(calls[2].arguments, {
        'project_id': 'project-1',
        'default_backend': 'drama-3',
      });
      expect(calls[3].arguments, {
        'project_id': 'project-1',
        'scene_preset': 'off',
      });
      expect(calls[4].arguments, {'project_id': 'project-1'});
      expect(calls[5].arguments, {
        'project_id': 'project-1',
        'ops': [
          {
            'append_to': 'project-1-chapter',
            'text': '非公開のローカルテスト',
            'voice': 'ordinary-voice',
          },
        ],
      });
      expect(calls[6].arguments, {
        'project_id': 'project-1',
        'blocks': ['block-1'],
        'dry_run': true,
      });
      expect(calls[7].arguments['blocks'], ['block-1']);
      expect(calls[7].arguments['dry_run'], isNot(true));
      expect(harness.client.paidGenerations, hasLength(1));
      expect(harness.client.named('text_to_speech'), isEmpty);
      expect(harness.service.lastRequestedModel, 'drama-3');
      expect(harness.service.lastConfiguredBackend, 'drama-3');
      expect(harness.service.lastReportedModel, isNull);
      expect(harness.service.modelSelectionStatus, 'studio_configured');
      expect(harness.downloads, hasLength(1));
      expect(harness.service.diagnosticReport, isNot(contains('非公開のローカルテスト')));
    },
  );

  test(
    'Studio rejects unidentified inline audio without a readback tool',
    () async {
      final harness = await _Harness.create(
        client: _StudioClient(inlineAudio: true),
      );
      final error = await _failure(harness.synthesize());
      expect(error.code, 'studio_identity_unconfirmed');
      expect(error.generationSubmitted, isTrue);
      expect(error.allowsRestFallback, isFalse);
      expect(harness.client.paidGenerations, hasLength(1));
      expect(harness.downloads, isEmpty);
    },
  );

  test(
    'Studio writes Drama 3 whisper pairs without repeated breath cues',
    () async {
      final harness = await _Harness.create();
      await harness.synthesize(
        text: '[panting][gasping][whispering][whispering]こんにちは。。。。',
      );
      final ops =
          harness.client.named('studio_write_blocks').single.arguments['ops']
              as List;
      expect((ops.single as Map)['text'], '<whisper>こんにちは。</whisper>');
      expect(harness.client.paidGenerations, hasLength(1));
    },
  );

  test('Studio diagnostics retain exact target duration but exclude chapter duration', () async {
    final harness = await _Harness.create(
      client: _StudioClient(
        intercept: (request) {
          if (request.name != 'studio_generate' ||
              request.arguments['dry_run'] == true) {
            return null;
          }
          return _data({
            'duration_s': 71,
            'results': [
              {
                'anchor': (request.arguments['blocks'] as List).single,
                'audio_url': 'https://platform.r2.fish.audio/local/speech.mp3',
                'duration_s': 8.25,
              },
            ],
          });
        },
      ),
    );
    await harness.synthesize();
    final report = jsonDecode(harness.service.diagnosticReport) as Map;
    expect(
      (report['last_request'] as Map)['studio_result_target_duration_s'],
      8.25,
    );
    expect(harness.service.diagnosticReport, isNot(contains('非公開のローカルテスト')));
    expect(harness.service.diagnosticReport, isNot(contains('speech.mp3')));
    expect(harness.client.paidGenerations, hasLength(1));
  });

  test(
    'explicitly supported direct model is used when Studio is unavailable',
    () async {
      final harness = await _Harness.create(
        client: _StudioClient(
          tools: _tools(directModel: true)
            ..removeWhere((tool) => tool.name.startsWith('studio_')),
        ),
      );
      expect(
        harness.service.generationRouteForModel('drama-3'),
        'text_to_speech',
      );
      await harness.synthesize();
      expect(harness.client.requests.single.name, 'text_to_speech');
      expect(harness.client.requests.single.arguments['model'], 'drama-3');
    },
  );

  test('complete Studio takes priority over the direct model field', () async {
    final harness = await _Harness.create(
      client: _StudioClient(tools: _tools(directModel: true)),
    );
    expect(harness.service.generationRouteForModel('drama-3'), 'studio');
    await harness.synthesize();
    expect(harness.client.named('text_to_speech'), isEmpty);
    expect(harness.client.paidGenerations, hasLength(1));
  });

  test('service default uses ordinary TTS with no Studio project', () async {
    final harness = await _Harness.create();
    expect(harness.service.generationRouteForModel(''), 'text_to_speech');
    await harness.synthesize(model: '');
    expect(harness.client.requests.single.name, 'text_to_speech');
    expect(
      harness.client.requests.single.arguments.containsKey('model'),
      isFalse,
    );
  });

  for (final missing in _studioNames) {
    test(
      'missing $missing blocks Studio before generation or direct fallback',
      () async {
        final harness = await _Harness.create(
          client: _StudioClient(
            tools: _tools()..removeWhere((tool) => tool.name == missing),
          ),
        );
        expect(harness.service.studioAvailable, isFalse);
        expect(harness.service.missingStudioTools, contains(missing));
        expect(
          harness.service.generationRouteForModel('drama-3'),
          'unavailable',
        );
        final error = await _failure(harness.synthesize());
        expect(error.allowsRestFallback, isFalse);
        expect(harness.client.requests, isEmpty);
        expect(harness.downloads, isEmpty);
      },
    );
  }

  test('missing dry_run field prevents every Studio operation', () async {
    final definitions = _tools();
    final index = definitions.indexWhere(
      (tool) => tool.name == 'studio_generate',
    );
    definitions[index] = _tool(
      'studio_generate',
      properties: {
        'project_id': {'type': 'string'},
        'blocks': {'type': 'array'},
      },
      required: ['project_id'],
    );
    final harness = await _Harness.create(
      client: _StudioClient(tools: definitions),
    );
    expect(harness.service.studioAvailable, isFalse);
    expect(harness.service.studioContractIssues, isNotEmpty);
    expect(harness.service.generationRouteForModel('drama-3'), 'unavailable');
    final error = await _failure(harness.synthesize());
    expect(error.allowsRestFallback, isFalse);
    expect(harness.client.requests, isEmpty);
    expect(harness.downloads, isEmpty);
  });

  for (final voice in <String?>[null, '', '   ']) {
    test(
      'Studio requires an explicit voice before creating project: $voice',
      () async {
        final harness = await _Harness.create();
        final error = await _failure(harness.synthesize(voice: voice));
        expect(error.allowsRestFallback, isFalse);
        expect(harness.client.requests, isEmpty);
      },
    );
  }

  test(
    'same model and voice reuse project while generating only fresh blocks',
    () async {
      final harness = await _Harness.create();
      await harness.synthesize(text: 'first');
      await harness.synthesize(text: 'second');
      expect(harness.client.named('studio_help'), hasLength(1));
      expect(harness.client.named('studio_create_project'), hasLength(1));
      expect(harness.client.named('studio_write_blocks'), hasLength(2));
      expect(
        harness.client.paidGenerations.map((call) => call.arguments['blocks']),
        [
          ['block-1'],
          ['block-2'],
        ],
      );
      expect(
        harness.client.paidGenerations.map(
          (call) => call.arguments['project_id'],
        ),
        ['project-1', 'project-1'],
      );
    },
  );

  test(
    'ordinary, ASMR and Klaudia voices have isolated Studio projects',
    () async {
      final harness = await _Harness.create();
      const voices = [
        'ordinary-voice',
        'asmr-voice',
        '7b7667d545f94326a7089830d2b55261',
      ];
      for (final voice in voices) {
        await harness.synthesize(voice: voice);
      }
      await harness.synthesize(voice: voices.first);
      expect(harness.client.named('studio_help'), hasLength(1));
      expect(harness.client.named('studio_create_project'), hasLength(3));
      final writes = harness.client.named('studio_write_blocks');
      expect(writes.map((call) => call.arguments['project_id']), [
        'project-1',
        'project-2',
        'project-3',
        'project-1',
      ]);
      for (var i = 0; i < writes.length; i++) {
        final operation = (writes[i].arguments['ops'] as List).single as Map;
        expect(operation['voice'], voices[i % voices.length]);
      }
      expect(harness.client.paidGenerations, hasLength(4));
    },
  );

  for (final editedField in ['default_backend', 'scene_preset']) {
    test(
      'reused project detects externally changed $editedField before writing',
      () async {
        final harness = await _Harness.create();
        await harness.synthesize(text: 'before project edit');
        final callsBefore = harness.client.requests.length;
        harness.client.projects['project-1']![editedField] =
            editedField == 'default_backend' ? 's2.1-pro' : 'studio';
        final error = await _failure(
          harness.synthesize(text: 'after project edit'),
        );
        expect(error.allowsRestFallback, isFalse);
        expect(
          harness.client.requests.skip(callsBefore).map((call) => call.name),
          ['studio_project'],
        );
        expect(harness.client.named('studio_create_project'), hasLength(1));
        expect(harness.client.named('studio_write_blocks'), hasLength(1));
        expect(harness.client.named('studio_generate'), hasLength(2));
        expect(harness.client.paidGenerations, hasLength(1));
        expect(harness.service.lastConfiguredBackend, isNull);
        expect(
          harness.service.modelSelectionStatus,
          isNot('studio_configured'),
        );
      },
    );
  }

  test('different models never reuse another model project', () async {
    final harness = await _Harness.create();
    await harness.synthesize(model: 'drama-3');
    await harness.synthesize(model: 's2.1-pro');
    await harness.synthesize(model: 'drama-3');
    expect(harness.client.named('studio_create_project'), hasLength(2));
    expect(
      harness.client.paidGenerations.map(
        (call) => call.arguments['project_id'],
      ),
      ['project-1', 'project-2', 'project-1'],
    );
  });

  test(
    'concurrent requests share setup and generate distinct new blocks',
    () async {
      final harness = await _Harness.create();
      final paths = await Future.wait([
        harness.synthesize(text: 'first parallel line'),
        harness.synthesize(text: 'second parallel line'),
      ]);
      expect(paths, hasLength(2));
      expect(harness.client.named('studio_help'), hasLength(1));
      expect(harness.client.named('studio_create_project'), hasLength(1));
      expect(harness.client.named('studio_write_blocks'), hasLength(2));
      expect(harness.client.paidGenerations, hasLength(2));
      final generatedBlocks = harness.client.paidGenerations
          .map((call) => (call.arguments['blocks'] as List).single)
          .toSet();
      expect(generatedBlocks, {'block-1', 'block-2'});
      expect(harness.client.named('text_to_speech'), isEmpty);
    },
  );

  test('read-back backend mismatch never writes or generates audio', () async {
    final harness = await _Harness.create(
      client: _StudioClient(
        intercept: (request) => request.name == 'studio_project'
            ? _data({
                'project_id': 'project-1',
                'default_backend': 's2.1-pro',
                'scene_preset': 'off',
              })
            : null,
      ),
    );
    final error = await _failure(harness.synthesize());
    expect(error.allowsRestFallback, isFalse);
    expect(harness.client.named('studio_write_blocks'), isEmpty);
    expect(harness.client.named('studio_generate'), isEmpty);
    expect(harness.service.lastConfiguredBackend, isNull);
    expect(harness.service.modelSelectionStatus, isNot('studio_configured'));
  });

  test('scene preset must be confirmed off before generating', () async {
    final harness = await _Harness.create(
      client: _StudioClient(
        intercept: (request) => request.name == 'studio_project'
            ? _data({
                'project_id': 'project-1',
                'default_backend': 'drama-3',
                'scene_preset': 'studio',
              })
            : null,
      ),
    );
    await _failure(harness.synthesize());
    expect(harness.client.named('studio_generate'), isEmpty);
  });

  for (final envelope in ['project', 'settings', 'data', 'result']) {
    test('confirms configuration in the $envelope envelope on reuse', () async {
      final harness = await _Harness.create(
        client: _StudioClient(
          intercept: (request) => request.name == 'studio_project'
              ? _data({
                  envelope: {
                    'project_id': 'project-1',
                    'default_backend': 'drama-3',
                    'scene_preset': 'off',
                  },
                })
              : null,
        ),
      );
      await harness.synthesize(text: 'first wrapped configuration');
      await harness.synthesize(text: 'second wrapped configuration');
      expect(harness.client.named('studio_create_project'), hasLength(1));
      expect(harness.client.named('studio_project'), hasLength(2));
      expect(harness.client.paidGenerations, hasLength(2));
      expect(harness.service.lastConfiguredBackend, 'drama-3');
      expect(
        harness.service.diagnosticReport,
        contains('studio_backend_readback'),
      );
      expect(
        harness.service.diagnosticReport,
        contains('$envelope.default_backend'),
      );
    });

    for (final field in ['default_backend', 'scene_preset']) {
      test('rejects conflicting $field in the $envelope envelope', () async {
        final harness = await _Harness.create(
          client: _StudioClient(
            intercept: (request) => request.name == 'studio_project'
                ? _data({
                    'default_backend': 'drama-3',
                    'scene_preset': 'off',
                    envelope: {
                      field: field == 'default_backend' ? 's2.1-pro' : 'studio',
                    },
                  })
                : null,
          ),
        );
        final error = await _failure(harness.synthesize());
        expect(error.code, 'studio_backend_not_confirmed');
        expect(error.message, contains('$envelope.$field'));
        expect(error.allowsRestFallback, isFalse);
        expect(harness.client.named('studio_write_blocks'), isEmpty);
        expect(harness.client.named('studio_generate'), isEmpty);
        expect(harness.client.named('text_to_speech'), isEmpty);
      });
    }
  }

  for (final preset in ['off', 'studio']) {
    test('reads saved scene.preset=$preset from Studio project', () async {
      final harness = await _Harness.create(
        client: _StudioClient(
          intercept: (request) => request.name == 'studio_project'
              ? _data({
                  'project_id': 'project-1',
                  'default_backend': 'drama-3',
                  'scene': {'preset': preset},
                })
              : null,
        ),
      );
      if (preset == 'off') {
        await harness.synthesize();
        expect(harness.client.paidGenerations, hasLength(1));
        expect(harness.service.lastConfiguredBackend, 'drama-3');
        expect(harness.service.diagnosticReport, contains('scene.preset=off'));
      } else {
        final error = await _failure(harness.synthesize());
        expect(error.code, 'studio_backend_not_confirmed');
        expect(error.message, contains('scene.preset=studio'));
        expect(error.allowsRestFallback, isFalse);
        expect(harness.client.named('studio_write_blocks'), isEmpty);
        expect(harness.client.named('studio_generate'), isEmpty);
      }
    });
  }

  test(
    'accepts nested saved scene.preset with matching legacy field',
    () async {
      final harness = await _Harness.create(
        client: _StudioClient(
          intercept: (request) => request.name == 'studio_project'
              ? _data({
                  'data': {
                    'project': {
                      'project_id': 'project-1',
                      'default_backend': 'drama-3',
                      'scene_preset': 'off',
                      'scene': {'preset': 'off'},
                    },
                  },
                })
              : null,
        ),
      );
      await harness.synthesize();
      expect(harness.client.paidGenerations, hasLength(1));
    },
  );

  for (final scene in [
    {
      'scene_preset': 'off',
      'scene': {'preset': 'studio'},
    },
    {
      'scene_preset': 'studio',
      'scene': {'preset': 'off'},
    },
  ]) {
    test('rejects conflicting saved and legacy scene values: $scene', () async {
      final harness = await _Harness.create(
        client: _StudioClient(
          intercept: (request) => request.name == 'studio_project'
              ? _data({'default_backend': 'drama-3', ...scene})
              : null,
        ),
      );
      final error = await _failure(harness.synthesize());
      expect(error.code, 'studio_backend_not_confirmed');
      expect(harness.client.named('studio_write_blocks'), isEmpty);
      expect(harness.client.named('studio_generate'), isEmpty);
    });
  }

  for (final field in ['default_backend', 'scene_preset']) {
    for (final invalid in <Object?>[
      null,
      true,
      3,
      <String, Object?>{},
      <Object>[],
    ]) {
      test('rejects invalid $field value ${invalid.runtimeType}', () async {
        final harness = await _Harness.create(
          client: _StudioClient(
            intercept: (request) => request.name == 'studio_project'
                ? _data({
                    'default_backend': 'drama-3',
                    'scene_preset': 'off',
                    field: invalid,
                  })
                : null,
          ),
        );
        final error = await _failure(harness.synthesize());
        expect(error.code, 'studio_backend_not_confirmed');
        expect(error.allowsRestFallback, isFalse);
        expect(error.generationSubmitted, isFalse);
        expect(harness.client.named('studio_write_blocks'), isEmpty);
        expect(harness.client.named('studio_generate'), isEmpty);
      });
    }

    test('missing $field respects the acknowledged scene setting', () async {
      final readback = <String, dynamic>{
        'default_backend': 'drama-3',
        'scene_preset': 'off',
      }..remove(field);
      final harness = await _Harness.create(
        client: _StudioClient(
          intercept: (request) =>
              request.name == 'studio_project' ? _data(readback) : null,
        ),
      );
      if (field == 'scene_preset') {
        await harness.synthesize();
        expect(harness.client.paidGenerations, hasLength(1));
        expect(
          harness.service.diagnosticReport,
          contains('accepted_unreported'),
        );
      } else {
        final error = await _failure(harness.synthesize());
        expect(error.code, 'studio_backend_not_confirmed');
        expect(error.message, contains('字段缺失'));
        expect(harness.client.named('studio_generate'), isEmpty);
      }
    });
  }

  for (final invalidScene in <Object?>[
    null,
    false,
    'off',
    {'preset': null},
    {},
  ]) {
    test('invalid saved scene $invalidScene cannot confirm off', () async {
      final harness = await _Harness.create(
        client: _StudioClient(
          intercept: (request) => request.name == 'studio_project'
              ? _data({'default_backend': 'drama-3', 'scene': invalidScene})
              : null,
        ),
      );
      final error = await _failure(harness.synthesize());
      expect(error.code, 'studio_backend_not_confirmed');
      expect(harness.client.named('studio_write_blocks'), isEmpty);
      expect(harness.client.named('studio_generate'), isEmpty);
    });
  }

  for (final ignoredEnvelope in [
    'roster',
    'chapters',
    'request',
    'arbitrary',
  ]) {
    test('ignores configuration under $ignoredEnvelope', () async {
      final harness = await _Harness.create(
        client: _StudioClient(
          intercept: (request) => request.name == 'studio_project'
              ? _data({
                  ignoredEnvelope: {
                    'default_backend': 'drama-3',
                    'scene_preset': 'off',
                  },
                })
              : null,
        ),
      );
      final error = await _failure(harness.synthesize());
      expect(error.code, 'studio_backend_not_confirmed');
      expect(harness.client.named('studio_generate'), isEmpty);
    });
  }

  for (final depth in [6, 7]) {
    test(
      'only reads approved configuration envelopes through depth six: $depth',
      () async {
        var readback = <String, dynamic>{
          'default_backend': 'drama-3',
          'scene_preset': 'off',
        };
        for (var level = 0; level < depth; level++) {
          readback = {'data': readback};
        }
        final harness = await _Harness.create(
          client: _StudioClient(
            intercept: (request) =>
                request.name == 'studio_project' ? _data(readback) : null,
          ),
        );
        if (depth == 6) {
          await harness.synthesize();
          expect(harness.client.paidGenerations, hasLength(1));
        } else {
          final error = await _failure(harness.synthesize());
          expect(error.code, 'studio_backend_not_confirmed');
          expect(harness.client.named('studio_generate'), isEmpty);
        }
      },
    );
  }

  test('accepts a complete project returned only as JSON text', () async {
    final harness = await _Harness.create(
      client: _StudioClient(
        intercept: (request) => request.name == 'studio_project'
            ? CallToolResult(
                content: [
                  TextContent(
                    text: jsonEncode({
                      'project': {
                        'default_backend': 'drama-3',
                        'scene': {'preset': 'off'},
                      },
                    }),
                  ),
                ],
              )
            : null,
      ),
    );
    await harness.synthesize();
    expect(harness.client.paidGenerations, hasLength(1));
  });

  for (final structuredBackend in <String?>[null, 's2.1-pro']) {
    test(
      'never fills structured response fields from conflicting text: $structuredBackend',
      () async {
        final harness = await _Harness.create(
          client: _StudioClient(
            intercept: (request) => request.name == 'studio_project'
                ? CallToolResult(
                    structuredContent: {
                      'default_backend': ?structuredBackend,
                      'scene_preset': 'off',
                    },
                    content: [
                      TextContent(
                        text: jsonEncode({
                          'default_backend': 'drama-3',
                          'scene_preset': 'off',
                        }),
                      ),
                    ],
                  )
                : null,
          ),
        );
        final error = await _failure(harness.synthesize());
        expect(error.code, 'studio_backend_not_confirmed');
        expect(error.message, contains(structuredBackend ?? '字段缺失'));
        expect(harness.client.named('studio_write_blocks'), isEmpty);
        expect(harness.client.named('studio_generate'), isEmpty);
      },
    );
  }

  test('real summary omitting scene uses update acceptance without claiming read-back', () async {
    final harness = await _Harness.create(
      client: _StudioClient(
        intercept: (request) => request.name == 'studio_project'
            ? _data({
                'project_id': 'project-1',
                'name': 'AgentAtelierR drama-3',
                'default_backend': 'drama-3',
                'roster': [
                  {'name': 'AgentAtelierR', 'voice_id': 'ordinary-voice'},
                ],
                'chapters': [
                  {'anchor': 'project-1-chapter'},
                ],
              })
            : null,
      ),
    );
    await harness.synthesize(text: 'first summary without scene');
    expect(harness.client.named('studio_update_project'), hasLength(2));
    expect(harness.client.paidGenerations, hasLength(1));
    expect(harness.service.lastConfiguredBackend, 'drama-3');
    final summary = jsonDecode(harness.service.diagnosticReport) as Map;
    expect(summary.toString(), contains('accepted_unreported'));
    expect(summary.toString(), isNot(contains('scene_preset=off')));

    final requestsBeforeReuse = harness.client.requests.length;
    await harness.synthesize(text: 'second summary without scene');
    expect(harness.client.named('studio_create_project'), hasLength(1));
    expect(harness.client.named('studio_update_project'), hasLength(3));
    expect(harness.client.paidGenerations, hasLength(2));
    expect(
      harness.client.requests
          .skip(requestsBeforeReuse)
          .map((call) => call.name),
      [
        'studio_project',
        'studio_update_project',
        'studio_write_blocks',
        'studio_generate',
        'studio_generate',
      ],
    );
    expect(harness.client.named('studio_update_project').last.arguments, {
      'project_id': 'project-1',
      'scene_preset': 'off',
    });
  });

  for (final reused in [false, true]) {
    test(
      'scene update rejection with omitted scene stops ${reused ? 'reused' : 'new'} project',
      () async {
        var rejectScene = !reused;
        final harness = await _Harness.create(
          client: _StudioClient(
            intercept: (request) {
              if (request.name == 'studio_update_project' &&
                  request.arguments.containsKey('scene_preset') &&
                  rejectScene) {
                return _error('scene_update_denied');
              }
              if (request.name == 'studio_project') {
                return _data({
                  'project_id': 'project-1',
                  'default_backend': 'drama-3',
                });
              }
              return null;
            },
          ),
        );
        if (reused) {
          await harness.synthesize(text: 'successful first request');
          rejectScene = true;
        }
        final writesBefore = harness.client.named('studio_write_blocks').length;
        final generationsBefore = harness.client
            .named('studio_generate')
            .length;
        final error = await _failure(harness.synthesize());
        expect(error.code, 'scene_update_denied');
        expect(error.allowsRestFallback, isFalse);
        expect(error.generationSubmitted, isFalse);
        expect(
          harness.client.named('studio_write_blocks'),
          hasLength(writesBefore),
        );
        expect(
          harness.client.named('studio_generate'),
          hasLength(generationsBefore),
        );
        expect(harness.client.named('text_to_speech'), isEmpty);
      },
    );
  }

  test(
    'read-back error describes safe values and redacts credentials',
    () async {
      const secret = 'secret-access-token-should-not-appear';
      final harness = await _Harness.create(
        client: _StudioClient(
          intercept: (request) => request.name == 'studio_project'
              ? _data({
                  'project': {
                    'default_backend': 's2.1-pro',
                    'scene': {'preset': 'Bearer $secret'},
                    'access_token': secret,
                    'authorization': 'Bearer $secret',
                  },
                })
              : null,
        ),
      );
      final error = await _failure(harness.synthesize());
      expect(error.message, contains('project.default_backend=s2.1-pro'));
      expect(error.message, contains('project.scene.preset=[REDACTED]'));
      expect(error.message, isNot(contains(secret)));
      expect(harness.service.diagnosticReport, isNot(contains(secret)));
      expect(harness.client.named('studio_generate'), isEmpty);
    },
  );

  test('read-back of a different project never generates', () async {
    final harness = await _Harness.create(
      client: _StudioClient(
        intercept: (request) => request.name == 'studio_project'
            ? _data({
                'project_id': 'different-project',
                'default_backend': 'drama-3',
                'scene': {'preset': 'off'},
              })
            : null,
      ),
    );
    final error = await _failure(harness.synthesize());
    expect(error.allowsRestFallback, isFalse);
    expect(error.generationSubmitted, isFalse);
    expect(harness.client.named('studio_write_blocks'), isEmpty);
    expect(harness.client.named('studio_generate'), isEmpty);
  });

  test(
    'cancellation during configuration read-back never writes a block',
    () async {
      var active = true;
      final harness = await _Harness.create(
        client: _StudioClient(
          intercept: (request) {
            if (request.name == 'studio_project') active = false;
            return null;
          },
        ),
      );
      final error = await _failure(harness.synthesize(isCurrent: () => active));
      expect(error.allowsRestFallback, isFalse);
      expect(error.generationSubmitted, isFalse);
      expect(harness.client.named('studio_write_blocks'), isEmpty);
      expect(harness.client.named('studio_generate'), isEmpty);
      expect(harness.downloads, isEmpty);
    },
  );

  for (final quoteKind in [
    'error',
    'malformed',
    'cached',
    'no_blocks',
    'insufficient',
  ]) {
    test('$quoteKind quote cannot trigger a paid generation', () async {
      final harness = await _Harness.create(
        client: _StudioClient(
          intercept: (request) {
            if (request.name != 'studio_generate' ||
                request.arguments['dry_run'] != true) {
              return null;
            }
            if (quoteKind == 'error') return _error('quote_denied');
            if (quoteKind == 'malformed') return _data({'status': 'done'});
            return _data({
              'blocks_to_generate':
                  quoteKind == 'no_blocks' || quoteKind == 'cached' ? 0 : 1,
              'cached': quoteKind == 'cached' ? 1 : 0,
              'estimated_credits': 20,
              'balance': quoteKind == 'insufficient' ? 1 : 1000,
            });
          },
        ),
      );
      final error = await _failure(harness.synthesize());
      expect(error.allowsRestFallback, isFalse);
      expect(harness.client.named('studio_generate'), hasLength(1));
      expect(harness.client.paidGenerations, isEmpty);
      expect(harness.client.named('text_to_speech'), isEmpty);
      expect(harness.downloads, isEmpty);
    });
  }

  test(
    'confirmed single cached block with zero credits can be retrieved once',
    () async {
      final harness = await _Harness.create(
        client: _StudioClient(
          intercept: (request) {
            if (request.name != 'studio_generate' ||
                request.arguments['dry_run'] != true) {
              return null;
            }
            return _data({
              'blocks_to_generate': 0,
              'cached': 1,
              'estimated_credits': 0,
              'balance': 0,
            });
          },
        ),
      );
      final path = await harness.synthesize();
      expect(await File(path).readAsBytes(), _mp3);
      expect(harness.client.named('studio_generate'), hasLength(2));
      expect(harness.client.paidGenerations, hasLength(1));
      expect(harness.client.paidGenerations.single.arguments['blocks'], [
        'block-1',
      ]);
    },
  );

  test('cancelled caller after quote cannot generate and next request remains usable', () async {
    var active = true;
    var cancelAtQuote = true;
    final harness = await _Harness.create(
      client: _StudioClient(
        intercept: (request) {
          if (cancelAtQuote &&
              request.name == 'studio_generate' &&
              request.arguments['dry_run'] == true) {
            active = false;
          }
          return null;
        },
      ),
    );
    final error = await _failure(harness.synthesize(isCurrent: () => active));
    expect(error.allowsRestFallback, isFalse);
    expect(harness.client.paidGenerations, isEmpty);
    expect(harness.client.named('studio_generate'), hasLength(1));
    expect(harness.downloads, isEmpty);
    expect(await harness.directory.list().toList(), isEmpty);
    expect(harness.service.isReady, isTrue);
    cancelAtQuote = false;
    active = true;
    final path = await harness.synthesize(
      text: 'new current request',
      isCurrent: () => active,
    );
    expect(await File(path).readAsBytes(), _mp3);
    expect(harness.client.named('studio_create_project'), hasLength(1));
    expect(harness.client.paidGenerations, hasLength(1));
    expect(harness.client.paidGenerations.single.arguments['blocks'], [
      'block-2',
    ]);
    expect(harness.service.modelSelectionStatus, 'studio_configured');
  });

  for (final actualModel in ['drama-3', 's2.1-pro']) {
    test(
      'Studio result actual_model $actualModel is execution evidence',
      () async {
        final harness = await _Harness.create(
          client: _StudioClient(
            intercept: (request) {
              if (request.name != 'studio_generate' ||
                  request.arguments['dry_run'] == true) {
                return null;
              }
              return _data({
                'status': 'done',
                'results': [
                  {
                    'anchor': (request.arguments['blocks'] as List).single,
                    'actual_model': actualModel,
                    'audio_url':
                        'https://platform.r2.fish.audio/local/speech.mp3',
                  },
                ],
              });
            },
          ),
        );
        final path = await harness.synthesize();
        expect(await File(path).readAsBytes(), _mp3);
        expect(harness.service.lastConfiguredBackend, 'drama-3');
        expect(harness.service.lastReportedModel, actualModel);
        expect(
          harness.service.modelSelectionStatus,
          actualModel == 'drama-3' ? 'match' : 'mismatch',
        );
      },
    );
  }

  for (final resultKind in ['error', 'timeout', 'pending']) {
    test(
      '$resultKind paid result is never retried or routed to ordinary TTS',
      () async {
        final harness = await _Harness.create(
          client: _StudioClient(
            intercept: (request) {
              if (request.name != 'studio_generate' ||
                  request.arguments['dry_run'] == true) {
                return null;
              }
              if (resultKind == 'error') return _error('generation_denied');
              if (resultKind == 'timeout') {
                throw TimeoutException('local timeout');
              }
              return _data({'status': 'running', 'results': []});
            },
          ),
        );
        final error = await _failure(harness.synthesize());
        expect(error.generationSubmitted, isTrue);
        expect(error.allowsRestFallback, isFalse);
        expect(harness.client.paidGenerations, hasLength(1));
        expect(harness.client.named('text_to_speech'), isEmpty);
        expect(harness.service.modelSelectionStatus, isNot('match'));
        expect(harness.downloads, isEmpty);
      },
    );
  }

  test(
    'unknown backend rejected by cloud is not reported as configured',
    () async {
      final harness = await _Harness.create(
        client: _StudioClient(
          intercept: (request) => request.name == 'studio_update_project'
              ? _error('unknown_backend')
              : null,
        ),
      );
      final error = await _failure(
        harness.synthesize(model: 'unknown-cloud-model'),
      );
      expect(error.code, 'unknown_backend');
      expect(
        harness.client
            .named('studio_update_project')
            .single
            .arguments['default_backend'],
        'unknown-cloud-model',
      );
      expect(harness.service.lastConfiguredBackend, isNull);
      expect(harness.service.modelSelectionStatus, isNot('studio_configured'));
      expect(harness.client.named('studio_generate'), isEmpty);
    },
  );

  for (final delayedTool in [
    'studio_update_project',
    'studio_project',
    'studio_generate',
  ]) {
    test(
      'disconnect during $delayedTool discards reply without further operations',
      () async {
        final submitted = Completer<void>();
        final released = Completer<CallToolResult>();
        final harness = await _Harness.create(
          client: _StudioClient(
            intercept: (request) {
              if (request.name != delayedTool) return null;
              if (delayedTool == 'studio_generate' &&
                  request.arguments['dry_run'] == true) {
                return null;
              }
              submitted.complete();
              return released.future;
            },
          ),
        );
        final failure = _failure(harness.synthesize());
        final reached = await Future.any([
          submitted.future.then((_) => true),
          failure.then((_) => false),
        ]);
        expect(
          reached,
          isTrue,
          reason: 'The delayed Studio call must be reached',
        );
        await harness.service.disconnect();
        final callsAtDisconnect = harness.client.requests.length;
        released.complete(
          delayedTool == 'studio_generate'
              ? _inline()
              : _data({'default_backend': 'drama-3', 'scene_preset': 'off'}),
        );
        final error = await failure;
        expect(error.code, 'connection_changed');
        expect(harness.client.requests, hasLength(callsAtDisconnect));
        expect(harness.downloads, isEmpty);
        expect(await harness.directory.list().toList(), isEmpty);
        expect(harness.service.isReady, isFalse);
      },
    );
  }
}
