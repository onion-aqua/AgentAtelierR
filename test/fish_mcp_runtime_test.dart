import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/fish_drama3_tags.dart';
import 'package:ryza_chat_mvp/src/fish_mcp_service.dart';
import 'package:ryza_chat_mvp/src/tts_text_normalizer.dart';
import 'package:shared_preferences/shared_preferences.dart';

// These tests exercise the complete local service path. The ID3 bytes only
// identify an MP3 container; playback and provider generation are not invoked.
const _mp3 = <int>[0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0];
const _s2WhisperCue =
    '[whispering intimately into the microphone, hushed and clearly articulated throughout]';

Tool _tool({
  String name = 'text_to_speech',
  String? description,
  Map<String, dynamic> properties = const {},
}) => Tool(
  name: name,
  description: description,
  inputSchema: JsonSchema.fromJson({
    'type': 'object',
    'properties': {
      'text': {'type': 'string', 'minLength': 1},
      ...properties,
    },
    'required': ['text'],
    'additionalProperties': false,
  }),
);

CallToolResult _inlineResult() => CallToolResult(
  content: [AudioContent(data: base64Encode(_mp3), mimeType: 'audio/mpeg')],
);

// This fixture deliberately uses the public text_to_speech schema without a
// model field, so an explicit model selection must use the real Studio path.
_FakeMcpClient _studioTagClient() {
  Tool studioTool(String name, Map<String, dynamic> properties) => Tool(
    name: name,
    inputSchema: JsonSchema.fromJson({
      'type': 'object',
      'properties': properties,
      'additionalProperties': false,
    }),
  );
  final project = <String, dynamic>{
    'project_id': 'local-tag-project',
    'default_backend': 's2.1-pro',
    'scene_preset': 'studio',
    'chapters': [
      {'anchor': 'local-tag-chapter'},
    ],
  };
  return _FakeMcpClient(
    pages: {
      null: ListToolsResult(
        tools: [
          _tool(
            properties: {
              'voice_id': {'type': 'string'},
            },
          ),
          studioTool('studio_help', {}),
          studioTool('studio_create_project', {
            'name': {'type': 'string'},
            'roster': {'type': 'array'},
            'default_voice_id': {'type': 'string'},
            'chapters': {'type': 'array'},
          }),
          studioTool('studio_update_project', {
            'project_id': {'type': 'string'},
            'default_backend': {'type': 'string'},
            'scene_preset': {'type': 'string'},
          }),
          studioTool('studio_project', {
            'project_id': {'type': 'string'},
          }),
          studioTool('studio_write_blocks', {
            'project_id': {'type': 'string'},
            'ops': {'type': 'array'},
          }),
          studioTool('studio_generate', {
            'project_id': {'type': 'string'},
            'blocks': {'type': 'array'},
            'dry_run': {'type': 'boolean'},
          }),
        ],
      ),
    },
    onCall: (request) {
      final arguments = request.arguments;
      final Map<String, dynamic> result;
      switch (request.name) {
        case 'text_to_speech':
          return _inlineResult();
        case 'studio_help':
          result = {'overview': 'Local tag fixture'};
          break;
        case 'studio_create_project':
          project['default_voice_id'] = arguments['default_voice_id'];
          result = {...project};
          break;
        case 'studio_update_project':
          project.addAll(arguments);
          result = {...project};
          break;
        case 'studio_project':
          result = {...project};
          break;
        case 'studio_write_blocks':
          result = {
            'results': [
              {'anchor': 'local-tag-block'},
            ],
          };
          break;
        case 'studio_generate':
          result = arguments['dry_run'] == true
              ? {
                  'blocks_to_generate': 1,
                  'cached': 0,
                  'estimated_credits': 20,
                  'balance': 1000,
                }
              : {
                  'status': 'done',
                  'results': [
                    {
                      'anchor': 'local-tag-block',
                      'audio_url':
                          'https://platform.r2.fish.audio/local/tag-test.mp3',
                    },
                  ],
                };
          break;
        default:
          fail('Unexpected local fixture tool ${request.name}');
      }
      return CallToolResult(content: const [], structuredContent: result);
    },
  );
}

class _FakeMcpClient extends McpClient {
  _FakeMcpClient({
    Map<String?, ListToolsResult>? pages,
    FutureOr<CallToolResult> Function(CallToolRequest request)? onCall,
  }) : pages =
           pages ??
           {
             null: ListToolsResult(
               tools: [
                 _tool(
                   properties: {
                     'model': {'type': 'string'},
                   },
                 ),
               ],
             ),
           },
       onCall = onCall ?? ((_) => _inlineResult()),
       super(const Implementation(name: 'local-test-only', version: '1'));

  final Map<String?, ListToolsResult> pages;
  final FutureOr<CallToolResult> Function(CallToolRequest request) onCall;
  final List<String?> cursors = [];
  final List<CallToolRequest> requests = [];

  @override
  Future<ListToolsResult> listTools({
    ListToolsRequest? params,
    RequestOptions? options,
  }) async {
    cursors.add(params?.cursor);
    return pages[params?.cursor]!;
  }

  @override
  Future<CallToolResult> callTool(
    CallToolRequest params, {
    RequestOptions? options,
  }) async {
    requests.add(params);
    return onCall(params);
  }

  @override
  Future<void> close() async {}
}

// Force a connection change exactly when an output path is first used. This
// models a disconnect during file creation without sleeps or large files.
class _DirectoryOnPath extends Fake implements Directory {
  _DirectoryOnPath(this.directory, this.onPath);

  final Directory directory;
  final void Function() onPath;
  bool _fired = false;

  @override
  String get path {
    if (!_fired) {
      _fired = true;
      onPath();
    }
    return directory.path;
  }
}

class _Harness {
  _Harness(this.service, this.client, this.downloads, this.directory);

  final FishMcpService service;
  final _FakeMcpClient client;
  final List<http.Request> downloads;
  final Directory directory;

  static Future<_Harness> create({
    _FakeMcpClient? client,
    FutureOr<http.Response> Function(http.Request request)? onDownload,
    Future<Directory> Function(Directory directory)? onTemporaryDirectory,
  }) async {
    final directory = await Directory.systemTemp.createTemp('fish-mcp-local-');
    final fake = client ?? _FakeMcpClient();
    final downloads = <http.Request>[];
    final downloadClient = MockClient((request) async {
      downloads.add(request);
      if (onDownload == null) {
        fail('No audio download was expected: ${request.url.host}');
      }
      return await onDownload(request);
    });
    final service = FishMcpService.forTesting(
      client: fake,
      downloadClient: downloadClient,
      temporaryDirectory: () =>
          onTemporaryDirectory?.call(directory) ?? Future.value(directory),
    );
    addTearDown(() async {
      await service.disconnect();
      service.dispose();
      downloadClient.close();
      await directory.delete(recursive: true);
    });
    return _Harness(service, fake, downloads, directory);
  }
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
  SharedPreferences.setMockInitialValues({});

  test('ASMR emotion off reaches ordinary MCP with a whole-script whisper and the new built-in voice', () async {
    const original =
        '今日はここでゆっくり休もう。窓の外には静かな夜が広がっているよ。'
        '明日もまた会えるから、今は何も急がなくて大丈夫。'
        '目を閉じたまま、今日あった楽しいことをひとつだけ思い出してみて。'
        '最後の言葉まで近くで話しているから、安心して聞いていてね。';
    final harness = await _Harness.create(
      client: _FakeMcpClient(
        pages: {
          null: ListToolsResult(
            tools: [
              _tool(
                properties: {
                  'voice_id': {'type': 'string'},
                },
              ),
            ],
          ),
        },
      ),
    );
    await harness.service.discoverTools();
    final prepared = normalizeFishAudioSynthesisText(
      applyFishEmotionIntensityPerSentence(
        original,
        TtsEmotionIntensity.off,
        asmr: true,
      ),
      asmr: true,
    );
    await harness.service.synthesize(
      text: prepared,
      voice: AppController.resolveFishAudioAsmrReferenceId(''),
    );
    expect(harness.client.requests, hasLength(1));
    final request = harness.client.requests.single;
    expect(request.name, 'text_to_speech');
    expect(request.arguments['voice_id'], '1380fd182e0f44639df49e1ae8feeed8');
    final text = request.arguments['text'] as String;
    expect(text, prepared);
    expect(text, startsWith('[whispering]'));
    expect(RegExp(r'\[whispering\]').allMatches(text), hasLength(1));
    expect(
      text,
      isNot(
        matches(RegExp(r'soft|panting|gasping|breath|\[relaxed\]|\[happy\]')),
      ),
    );
    expect(text.replaceAll(RegExp(r'\[[^\[\]\r\n]+\]|\s+'), ''), original);
  });

  for (final legacyLocalControls in [false, true]) {
    test(
      'ASMR Drama 3 ${legacyLocalControls ? 'replaces old local soft controls' : 'uses a stable full-script whisper'} in its single Studio generation',
      () async {
        const original =
            '今日はここでゆっくり休もう。秘密だよ。'
            '目を閉じたまま、今日あった楽しいことをひとつだけ思い出してみて。'
            '明日もまた会えるから、今は何も急がなくて大丈夫。'
            '最後の言葉まで近くで話しているから、安心して聞いていてね。';
        final source = legacyLocalControls
            ? '[soft]今日はここでゆっくり休もう。[whisper]秘密だよ。'
                  '[soft]目を閉じたまま、今日あった楽しいことをひとつだけ思い出してみて。'
                  '明日もまた会えるから、今は何も急がなくて大丈夫。'
                  '最後の言葉まで近くで話しているから、安心して聞いていてね。'
            : original;
        final harness = await _Harness.create(
          client: _studioTagClient(),
          onDownload: (_) => http.Response.bytes(
            _mp3,
            200,
            headers: {'content-type': 'audio/mpeg'},
          ),
        );
        await harness.service.discoverTools();
        final prepared = normalizeFishAudioSynthesisText(
          applyFishEmotionIntensityPerSentence(
            source,
            TtsEmotionIntensity.off,
            asmr: true,
            drama3: true,
          ),
          asmr: true,
        );
        await harness.service.synthesize(
          text: prepared,
          voice: AppController.resolveFishAudioAsmrReferenceId(''),
          model: 'drama-3',
        );
        final writes = harness.client.requests.where(
          (request) => request.name == 'studio_write_blocks',
        );
        expect(writes, hasLength(1));
        final block = (writes.single.arguments['ops'] as List).single as Map;
        expect(block['voice'], '1380fd182e0f44639df49e1ae8feeed8');
        final text = block['text'] as String;
        expect(text, startsWith('<whisper>'));
        expect(text, endsWith('</whisper>'));
        expect(RegExp(r'<whisper>').allMatches(text), hasLength(1));
        expect(RegExp(r'</whisper>').allMatches(text), hasLength(1));
        expect(
          text,
          isNot(
            matches(
              RegExp(r'soft|panting|gasping|breath|\[relaxed\]|\[happy\]'),
            ),
          ),
        );
        expect(
          stripFishDrama3Tags(text)
              .replaceAll(RegExp(r'\[[^\[\]\r\n]+\]|\s+'), ''),
          original,
        );
        expect(compileFishDrama3Text(text), text);
        expect(
          text
              .substring('<whisper>'.length, text.length - '</whisper>'.length)
              .replaceAll(RegExp(r'\s+'), ''),
          original,
        );
        final creations = harness.client.requests.where(
          (request) => request.name == 'studio_create_project',
        );
        expect(
          creations.single.arguments['default_voice_id'],
          '1380fd182e0f44639df49e1ae8feeed8',
        );
        final generations = harness.client.requests.where(
          (request) => request.name == 'studio_generate',
        );
        expect(
          generations.where((request) => request.arguments['dry_run'] == true),
          hasLength(1),
        );
        expect(
          generations.where((request) => request.arguments['dry_run'] != true),
          hasLength(1),
        );
        expect(harness.downloads, hasLength(1));
      },
    );
  }

  test(
    'MCP normalizes breathing tags before sending its single generation',
    () async {
      final harness = await _Harness.create();
      await harness.service.discoverTools();
      await harness.service.synthesize(
        text: '[panting][gasping][whispering][whispering]こんにちは。。。。',
        model: 'drama-3',
      );
      expect(
        harness.client.requests.single.arguments['text'],
        '<whisper>こんにちは。</whisper>',
      );
      final report = jsonDecode(harness.service.diagnosticReport) as Map;
      expect(
        (report['last_request'] as Map)['text_utf8_bytes'],
        utf8.encode('<whisper>こんにちは。</whisper>').length,
      );
      expect(harness.downloads, isEmpty);
    },
  );

  test(
    'Drama 3 compiles scoped tags into its only generated Studio block',
    () async {
      const claudiaVoice = '7b7667d545f94326a7089830d2b55261';
      final harness = await _Harness.create(
        client: _studioTagClient(),
        onDownload: (_) => http.Response.bytes(
          _mp3,
          200,
          headers: {'content-type': 'audio/mpeg'},
        ),
      );
      await harness.service.discoverTools();
      final path = await harness.service.synthesize(
        text:
            '[happy][panting][gasping][whispering]こんにちは。'
            '[emphasis]大切です。[soft]またね。',
        voice: claudiaVoice,
        model: 'drama-3',
      );
      expect(path, endsWith('.mp3'));
      final writes = harness.client.requests
          .where((request) => request.name == 'studio_write_blocks')
          .toList();
      expect(writes, hasLength(1));
      final block = (writes.single.arguments['ops'] as List).single as Map;
      final text = block['text'] as String;
      expect(text, contains('[happy]'));
      expect(text, contains('<whisper>'));
      expect(text, contains('</whisper>'));
      expect(text, contains('<emphasis>大切です。</emphasis>'));
      expect(text, contains('<soft>またね。</soft>'));
      expect(text, isNot(matches(RegExp(r'panting|gasping|breathy'))));
      expect(block['voice'], claudiaVoice);
      final created = harness.client.requests.singleWhere(
        (request) => request.name == 'studio_create_project',
      );
      expect(created.arguments['default_voice_id'], claudiaVoice);
      final generations = harness.client.requests
          .where((request) => request.name == 'studio_generate')
          .toList();
      expect(generations, hasLength(2));
      expect(
        generations.where((request) => request.arguments['dry_run'] != true),
        hasLength(1),
      );
      expect(
        harness.client.requests.where(
          (request) => request.name == 'text_to_speech',
        ),
        isEmpty,
      );
      expect(harness.downloads, hasLength(1));
    },
  );

  test('default and unknown models keep their original bracket cues', () async {
    final harness = await _Harness.create();
    await harness.service.discoverTools();
    for (final model in <String?>[null, 'unknown-model']) {
      await harness.service.synthesize(
        text: '[happy][whispering]こんにちは。[emphasis]大切です。',
        model: model,
      );
      expect(
        harness.client.requests.last.arguments['text'],
        '[happy][whispering]こんにちは。[emphasis]大切です。',
      );
    }
    expect(harness.client.requests, hasLength(2));
    expect(
      harness.client.requests.every(
        (request) => request.name == 'text_to_speech',
      ),
      isTrue,
    );
    expect(harness.downloads, isEmpty);
  });

  for (final model in ['s2-pro', 's2.1-pro', 's2.1-pro-free']) {
    test(
      'S2 Studio $model preserves the backend and descriptive whisper in one generation',
      () async {
        const original = '今日はここでゆっくり休もう。最後まで近くで話しているよ。';
        final harness = await _Harness.create(
          client: _studioTagClient(),
          onDownload: (_) => http.Response.bytes(
            _mp3,
            200,
            headers: {'content-type': 'audio/mpeg'},
          ),
        );
        await harness.service.discoverTools();
        final prepared = normalizeFishAudioSynthesisText(
          applyFishEmotionIntensityPerSentence(
            original,
            TtsEmotionIntensity.off,
            asmr: true,
          ),
          asmr: true,
        );
        final path = await harness.service.synthesize(
          text: prepared,
          voice: AppController.resolveFishAudioAsmrReferenceId(
            '',
            model: model,
          ),
          model: model,
        );
        expect(path, endsWith('.mp3'));
        final backendUpdates = harness.client.requests.where(
          (request) =>
              request.name == 'studio_update_project' &&
              request.arguments.containsKey('default_backend'),
        );
        expect(backendUpdates, hasLength(1));
        expect(backendUpdates.single.arguments['default_backend'], model);
        final creations = harness.client.requests.where(
          (request) => request.name == 'studio_create_project',
        );
        expect(creations, hasLength(1));
        expect(
          creations.single.arguments['default_voice_id'],
          'c5de0b3f9ac54e08b21fb63120e4ebdb',
        );
        final writes = harness.client.requests.where(
          (request) => request.name == 'studio_write_blocks',
        );
        expect(writes, hasLength(1));
        final block = (writes.single.arguments['ops'] as List).single as Map;
        expect(block['voice'], 'c5de0b3f9ac54e08b21fb63120e4ebdb');
        final text = block['text'] as String;
        expect(text, '$_s2WhisperCue今日はここでゆっくり休もう。 最後まで近くで話しているよ。');
        expect(text, isNot(contains('[whispering]')));
        expect(text, isNot(contains('<whisper>')));
        expect(text.replaceAll(RegExp(r'\[[^\[\]\r\n]+\]|\s+'), ''), original);
        final generations = harness.client.requests.where(
          (request) => request.name == 'studio_generate',
        );
        expect(
          generations.where((request) => request.arguments['dry_run'] == true),
          hasLength(1),
        );
        expect(
          generations.where((request) => request.arguments['dry_run'] != true),
          hasLength(1),
        );
        expect(
          harness.client.requests.where(
            (request) => request.name == 'text_to_speech',
          ),
          isEmpty,
        );
        expect(harness.downloads, hasLength(1));
        final report = jsonDecode(harness.service.diagnosticReport) as Map;
        expect(
          (report['last_request'] as Map)['speech_tag_format'],
          's2_descriptive_brackets',
        );
        expect((report['last_request'] as Map)['requested_model'], model);
        expect(harness.service.lastConfiguredBackend, model);
      },
    );
  }

  for (final asmr in [false, true]) {
    test(
      'S2 MCP ${asmr ? 'ASMR density off' : 'ordinary speech'} does not introduce delivery cues',
      () async {
        const original = '明日も会おう。待っているよ。';
        final prepared = normalizeFishAudioSynthesisText(
          applyFishEmotionIntensityPerSentence(
            asmr ? '[soft tone]明日も会おう。[whispering]待っているよ。' : original,
            TtsEmotionIntensity.off,
            asmr: asmr,
            density: asmr ? TtsCueDensity.off : TtsCueDensity.normal,
          ),
          asmr: asmr,
        );
        final harness = await _Harness.create();
        await harness.service.discoverTools();
        await harness.service.synthesize(text: prepared, model: 's2.1-pro');
        expect(harness.client.requests, hasLength(1));
        expect(
          harness.client.requests.single.arguments['text'],
          '明日も会おう。 待っているよ。',
        );
        expect(
          harness.client.requests.single.arguments['text'],
          isNot(contains('[')),
        );
        expect(harness.client.requests.single.arguments['model'], 's2.1-pro');
        expect(harness.downloads, isEmpty);
      },
    );
  }

  test('empty Drama 3 wrappers cannot submit a generation', () async {
    final harness = await _Harness.create(client: _studioTagClient());
    await harness.service.discoverTools();
    final error = await _failure(
      harness.service.synthesize(
        text: '<whisper> </whisper><soft></soft><emphasis> </emphasis>',
        voice: 'configured-voice',
        model: 'drama-3',
      ),
    );
    expect(error.code, 'empty_synthesis_text');
    expect(error.generationSubmitted, isFalse);
    expect(harness.client.requests, isEmpty);
    expect(harness.downloads, isEmpty);
  });

  test('breathing-only input is rejected before any paid MCP call', () async {
    final harness = await _Harness.create();
    await harness.service.discoverTools();
    final error = await _failure(
      harness.service.synthesize(text: '[panting][gasping][breathy]'),
    );
    expect(error.code, 'empty_synthesis_text');
    expect(error.generationSubmitted, isFalse);
    expect(harness.client.requests, isEmpty);
  });

  test('whisper-only input cannot submit an empty Studio generation', () async {
    final harness = await _Harness.create();
    await harness.service.discoverTools();
    final error = await _failure(
      harness.service.synthesize(text: '[whispering][whispering]'),
    );
    expect(error.code, 'empty_synthesis_text');
    expect(error.generationSubmitted, isFalse);
    expect(harness.client.requests, isEmpty);
  });

  group('requested and reported model evidence', () {
    test('official TTS schema without Studio cannot silently ignore a selected model', () async {
      final definition = jsonDecode(
        File('test/fixtures/fish_mcp_text_to_speech_2026-10-16.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      final harness = await _Harness.create(
        client: _FakeMcpClient(
          pages: {
            null: ListToolsResult(tools: [Tool.fromJson(definition)]),
          },
        ),
      );
      await harness.service.discoverTools();
      final error = await _failure(
        harness.service.synthesize(
          text: 'local fixture only',
          model: 'drama-3',
          voice: 'local-voice',
          language: 'ja',
        ),
      );
      expect(error.stage, 'studio_preflight');
      expect(error.generationSubmitted, isFalse);
      expect(error.allowsRestFallback, isFalse);
      expect(harness.client.requests, isEmpty);
      final report = jsonDecode(harness.service.diagnosticReport) as Map;
      expect(
        (report['tools'] as List).single['inputSchema']['additionalProperties'],
        isFalse,
      );
      expect(report['last_request'], isNull);
      expect(harness.service.modelSelectionStatus, 'no_request');
      expect(harness.service.lastReportedModel, isNull);
    });

    for (final reported in ['drama-3', 's2.1-pro']) {
      test(
        'compares requested drama-3 with explicit $reported metadata',
        () async {
          final harness = await _Harness.create(
            client: _FakeMcpClient(
              onCall: (_) => CallToolResult(
                content: _inlineResult().content,
                structuredContent: {
                  'model': 'drama-3',
                  'metadata': {'actual_model': reported},
                },
              ),
            ),
          );
          expect(harness.service.lastRequestedModel, isNull);
          expect(harness.service.lastReportedModel, isNull);
          expect(harness.service.modelSelectionStatus, 'no_request');
          await harness.service.discoverTools();
          await harness.service.synthesize(text: 'local', model: 'drama-3');
          expect(harness.client.requests.single.arguments['model'], 'drama-3');
          expect(harness.service.lastRequestedModel, 'drama-3');
          expect(harness.service.lastReportedModel, reported);
          final status = reported == 'drama-3' ? 'match' : 'mismatch';
          expect(harness.service.modelSelectionStatus, status);
          final report = jsonDecode(harness.service.diagnosticReport) as Map;
          expect(report['requested_model'], 'drama-3');
          expect(report['reported_model'], reported);
          expect(report['model_selection_status'], status);
          expect((report['last_result'] as Map)['reported_model'], reported);
          expect(harness.client.requests, hasLength(1));
        },
      );
    }

    test(
      'a request with no response model stays unreported, never inferred',
      () async {
        final harness = await _Harness.create();
        await harness.service.discoverTools();
        await harness.service.synthesize(text: 'local', model: 'drama-3');
        expect(harness.service.lastRequestedModel, 'drama-3');
        expect(harness.service.lastReportedModel, isNull);
        expect(harness.service.modelSelectionStatus, 'unreported');
        expect(harness.client.requests.single.arguments['model'], 'drama-3');
      },
    );

    test('service default is distinct from no submitted request', () async {
      final harness = await _Harness.create(
        client: _FakeMcpClient(
          onCall: (_) => CallToolResult(
            content: _inlineResult().content,
            meta: const {'model': 's2.1-pro'},
          ),
        ),
      );
      await harness.service.discoverTools();
      for (final model in <String?>[null, '', '   ']) {
        await harness.service.synthesize(text: 'local', model: model);
        expect(harness.service.lastRequestedModel, '');
        expect(harness.service.lastReportedModel, 's2.1-pro');
        expect(harness.service.modelSelectionStatus, 'server_default');
        expect(
          harness.client.requests.last.arguments.containsKey('model'),
          isFalse,
        );
      }
    });

    test(
      'tool errors and unknown outcomes cannot become a verified match',
      () async {
        final harness = await _Harness.create(
          client: _FakeMcpClient(
            onCall: (_) => const CallToolResult(
              content: [TextContent(text: 'Synthetic rejection')],
              isError: true,
              meta: {'model': 'drama-3'},
            ),
          ),
        );
        await harness.service.discoverTools();
        await _failure(
          harness.service.synthesize(text: 'local', model: 'drama-3'),
        );
        expect(harness.service.lastRequestedModel, 'drama-3');
        expect(harness.service.lastReportedModel, 'drama-3');
        expect(harness.service.modelSelectionStatus, 'request_failed');

        final timeoutHarness = await _Harness.create(
          client: _FakeMcpClient(
            onCall: (_) => throw TimeoutException('synthetic timeout'),
          ),
        );
        await timeoutHarness.service.discoverTools();
        await _failure(
          timeoutHarness.service.synthesize(text: 'local', model: 'drama-3'),
        );
        expect(timeoutHarness.service.lastReportedModel, isNull);
        expect(timeoutHarness.service.modelSelectionStatus, 'request_failed');
      },
    );

    test(
      'latest submitted request owns evidence despite reordered completions',
      () async {
        final completions = <String, Completer<CallToolResult>>{
          'drama-3': Completer<CallToolResult>(),
          's2.1-pro': Completer<CallToolResult>(),
        };
        final harness = await _Harness.create(
          client: _FakeMcpClient(
            onCall: (request) =>
                completions[request.arguments['model']]!.future,
          ),
        );
        await harness.service.discoverTools();
        final older = harness.service.synthesize(text: 'old', model: 'drama-3');
        final newer = harness.service.synthesize(
          text: 'new',
          model: 's2.1-pro',
        );
        expect(harness.service.lastRequestedModel, 's2.1-pro');
        expect(harness.service.lastReportedModel, isNull);
        expect(harness.service.modelSelectionStatus, 'pending');
        completions['s2.1-pro']!.complete(
          CallToolResult(
            content: _inlineResult().content,
            structuredContent: const {'model': 's2.1-pro'},
          ),
        );
        await newer;
        completions['drama-3']!.complete(
          CallToolResult(
            content: _inlineResult().content,
            structuredContent: const {'model': 'old-response-model'},
          ),
        );
        await older;
        expect(harness.service.lastRequestedModel, 's2.1-pro');
        expect(harness.service.lastReportedModel, 's2.1-pro');
        expect(harness.service.modelSelectionStatus, 'match');
        final report = jsonDecode(harness.service.diagnosticReport) as Map;
        expect((report['last_request'] as Map)['requested_model'], 's2.1-pro');
        expect((report['last_result'] as Map)['reported_model'], 's2.1-pro');
      },
    );

    test('preflight failures preserve the prior submitted request and response pair', () async {
      final harness = await _Harness.create();
      await harness.service.discoverTools();
      await harness.service.synthesize(text: 'local', model: 'drama-3');
      final prior = jsonDecode(harness.service.diagnosticReport) as Map;
      await harness.service.disconnect();
      await _failure(
        harness.service.synthesize(text: 'local', model: 's2.1-pro'),
      );
      final report = jsonDecode(harness.service.diagnosticReport) as Map;
      expect(harness.service.lastRequestedModel, 'drama-3');
      expect(harness.service.modelSelectionStatus, 'unreported');
      expect(report['last_request'], prior['last_request']);
      expect(report['last_result'], prior['last_result']);
    });

    test(
      'model diagnostic labels omit URL credentials without changing arguments',
      () async {
        const supplied = 'https://fish.audio/model?token=private-model-secret';
        final harness = await _Harness.create();
        await harness.service.discoverTools();
        await harness.service.synthesize(
          text: 'private dialogue',
          model: supplied,
        );
        expect(harness.client.requests.single.arguments['model'], supplied);
        expect(harness.service.lastRequestedModel, '[REDACTED]');
        expect(
          harness.service.diagnosticReport,
          isNot(contains('private-model-secret')),
        );
        expect(
          harness.service.diagnosticReport,
          isNot(contains('private dialogue')),
        );
      },
    );
  });

  test(
    'paged discovery selects generation rather than free balance tools',
    () async {
      final harness = await _Harness.create(
        client: _FakeMcpClient(
          pages: {
            null: ListToolsResult(
              tools: [
                _tool(
                  name: 'get_credit_balance',
                  description: 'Read credits for text-to-speech generation',
                ),
                _tool(name: 'tts'),
              ],
              nextCursor: 'page-2',
            ),
            'page-2': ListToolsResult(tools: [_tool()]),
          },
        ),
      );
      await harness.service.discoverTools();
      expect(harness.client.cursors, [null, 'page-2']);
      expect(harness.service.ttsToolName, 'text_to_speech');
      expect(harness.service.tools, hasLength(3));
      final path = await harness.service.synthesize(text: 'ローカルテスト');
      expect(harness.client.requests.single.name, 'text_to_speech');
      expect(await File(path).readAsBytes(), _mp3);
      expect(harness.downloads, isEmpty);
    },
  );

  test(
    'repeating pagination cursor stops discovery without generating',
    () async {
      final harness = await _Harness.create(
        client: _FakeMcpClient(
          pages: {
            null: ListToolsResult(tools: [_tool()], nextCursor: 'same'),
            'same': ListToolsResult(tools: [_tool()], nextCursor: 'same'),
          },
        ),
      );
      await expectLater(
        harness.service.discoverTools(),
        throwsA(
          isA<FishMcpException>().having(
            (e) => e.code,
            'code',
            'invalid_cursor',
          ),
        ),
      );
      expect(harness.client.cursors, [null, 'same']);
      expect(harness.client.requests, isEmpty);
      expect(harness.service.isReady, isFalse);
    },
  );

  test('tool error retains evidence and never resubmits generation', () async {
    final harness = await _Harness.create(
      client: _FakeMcpClient(
        onCall: (_) => const CallToolResult(
          content: [TextContent(text: 'Generic outer tool error')],
          isError: true,
          structuredContent: {
            'error': {
              'code': 'synthetic_plan_denied',
              'message': 'Synthetic account restriction',
            },
            'status': 402,
            'request_id': 'req-local-integration-001',
          },
        ),
      ),
    );
    await harness.service.discoverTools();
    final error = await _failure(harness.service.synthesize(text: '非公開の台詞'));
    expect(error.stage, 'result');
    expect(error.code, 'synthetic_plan_denied');
    expect(error.message, 'Synthetic account restriction');
    expect(error.status, 402);
    expect(error.requestId, 'req-local-integration-001');
    expect(error.generationSubmitted, isTrue);
    expect(error.allowsRestFallback, isFalse);
    expect(harness.service.lastError, same(error));
    expect(harness.client.requests, hasLength(1));
    expect(harness.downloads, isEmpty);
  });

  for (final resultKind in ['inline', 'url']) {
    test(
      'disconnect discards delayed $resultKind generation without writing or downloading',
      () async {
        final submitted = Completer<void>();
        final completed = Completer<CallToolResult>();
        final harness = await _Harness.create(
          client: _FakeMcpClient(
            onCall: (_) {
              submitted.complete();
              return completed.future;
            },
          ),
        );
        await harness.service.discoverTools();
        final failure = _failure(harness.service.synthesize(text: '非公開の遅延テスト'));
        await submitted.future;
        await harness.service.disconnect();
        completed.complete(
          resultKind == 'inline'
              ? _inlineResult()
              : const CallToolResult(
                  content: [
                    TextContent(text: 'https://fish.audio/late-result.mp3'),
                  ],
                ),
        );
        final error = await failure;
        expect(error.code, 'connection_changed');
        expect(error.generationSubmitted, isTrue);
        expect(error.allowsRestFallback, isFalse);
        expect(harness.service.state, FishMcpConnectionState.disconnected);
        expect(harness.service.isReady, isFalse);
        expect(harness.client.requests, hasLength(1));
        expect(harness.downloads, isEmpty);
        expect(await harness.directory.list().toList(), isEmpty);
      },
    );
  }

  test(
    'disconnect while resolving output directory never creates audio',
    () async {
      final requested = Completer<Directory>();
      final released = Completer<Directory>();
      final harness = await _Harness.create(
        onTemporaryDirectory: (directory) {
          requested.complete(directory);
          return released.future;
        },
      );
      await harness.service.discoverTools();
      final failure = _failure(harness.service.synthesize(text: 'local'));
      final directory = await requested.future;
      await harness.service.disconnect();
      released.complete(directory);
      final error = await failure;
      expect(error.code, 'connection_changed');
      expect(error.allowsRestFallback, isFalse);
      expect(harness.client.requests, hasLength(1));
      expect(await harness.directory.list().toList(), isEmpty);
    },
  );

  test(
    'disconnect during output creation removes the discarded file',
    () async {
      late FishMcpService service;
      final harness = await _Harness.create(
        onTemporaryDirectory: (directory) async =>
            _DirectoryOnPath(directory, () => unawaited(service.disconnect())),
      );
      service = harness.service;
      await service.discoverTools();
      final error = await _failure(service.synthesize(text: 'local'));
      expect(error.code, 'connection_changed');
      expect(error.allowsRestFallback, isFalse);
      expect(harness.client.requests, hasLength(1));
      expect(await harness.directory.list().toList(), isEmpty);
    },
  );

  test(
    'failed rediscovery invalidates the previously usable generation tool',
    () async {
      final harness = await _Harness.create();
      await harness.service.discoverTools();
      expect(harness.service.isReady, isTrue);
      harness.client.pages[null] = ListToolsResult(
        tools: [_tool()],
        nextCursor: 'repeat',
      );
      harness.client.pages['repeat'] = ListToolsResult(
        tools: [_tool()],
        nextCursor: 'repeat',
      );
      await expectLater(
        harness.service.discoverTools(),
        throwsA(
          isA<FishMcpException>().having(
            (e) => e.code,
            'code',
            'invalid_cursor',
          ),
        ),
      );
      expect(harness.service.isReady, isFalse);
      expect(harness.service.state, FishMcpConnectionState.error);
      final error = await _failure(harness.service.synthesize(text: 'local'));
      expect(error.code, 'not_ready');
      expect(error.generationSubmitted, isFalse);
      expect(harness.client.requests, isEmpty);
      expect(harness.downloads, isEmpty);
    },
  );

  test(
    'declared model and configured voice reach ordinary generation',
    () async {
      final harness = await _Harness.create();
      await harness.service.discoverTools();
      final path = await harness.service.synthesize(
        text: '非公開の台詞',
        model: 'drama-3',
        voice: 'configured-voice',
      );
      expect(path, endsWith('.mp3'));
      expect(harness.client.requests.single.arguments, {
        'text': '非公開の台詞',
        'model': 'drama-3',
        'voice_id': 'configured-voice',
      });
      expect(harness.service.lastError, isNull);
      expect(harness.downloads, isEmpty);
    },
  );

  for (final alias in ['model', 'model_id', 'modelId']) {
    test(
      'configured model bypasses stale $alias enum and reaches cloud',
      () async {
        final harness = await _Harness.create(
          client: _FakeMcpClient(
            pages: {
              null: ListToolsResult(
                tools: [
                  _tool(
                    properties: {
                      alias: {
                        'type': 'string',
                        'enum': ['old-server-model'],
                      },
                    },
                  ),
                ],
              ),
            },
          ),
        );
        await harness.service.discoverTools();
        expect(
          await harness.service.synthesize(text: 'local', model: 'drama-3'),
          endsWith('.mp3'),
        );
        expect(harness.client.requests.single.arguments, {
          'text': 'local',
          alias: 'drama-3',
        });
        expect(harness.downloads, isEmpty);
      },
    );
  }

  test(
    'incomplete text schema uses canonical text and preserves cloud rejection',
    () async {
      final harness = await _Harness.create(
        client: _FakeMcpClient(
          pages: {
            null: ListToolsResult(
              tools: [
                Tool(
                  name: 'text_to_speech',
                  inputSchema: JsonSchema.fromJson({
                    'type': 'object',
                    'properties': {
                      'content_new': {'type': 'string'},
                    },
                    'required': ['content_new', 'new_remote_field'],
                    'additionalProperties': false,
                  }),
                ),
              ],
            ),
          },
          onCall: (_) => const CallToolResult(
            content: [],
            isError: true,
            structuredContent: {
              'error': {
                'code': 'cloud_invalid_input',
                'message': 'Cloud rejected the request',
              },
              'request_id': 'req-cloud-validation',
            },
          ),
        ),
      );
      await harness.service.discoverTools();
      expect(harness.service.isReady, isTrue);
      final error = await _failure(harness.service.synthesize(text: 'local'));
      expect(harness.client.requests.single.arguments, {'text': 'local'});
      expect(error.code, 'cloud_invalid_input');
      expect(error.message, 'Cloud rejected the request');
      expect(error.requestId, 'req-cloud-validation');
      expect(error.generationSubmitted, isTrue);
      expect(error.allowsRestFallback, isFalse);
    },
  );

  test(
    'language maps to real enum and MP3 result keeps its actual suffix',
    () async {
      final harness = await _Harness.create(
        client: _FakeMcpClient(
          pages: {
            null: ListToolsResult(
              tools: [
                _tool(
                  properties: {
                    'language': {
                      'type': 'string',
                      'enum': ['Japanese', 'English'],
                    },
                    'output_format': {
                      'type': 'string',
                      'enum': ['wav', 'mp3'],
                    },
                    'voice_id': {'type': 'string'},
                  },
                ),
              ],
            ),
          },
          onCall: (_) => const CallToolResult(
            content: [
              TextContent(
                text: '[音频下载](https://cdn.fish.audio/result.mp3?signature=local-secret)',
              ),
            ],
          ),
        ),
        onDownload: (request) {
          expect(
            request.headers.keys.map((key) => key.toLowerCase()),
            isNot(contains('authorization')),
          );
          expect(request.followRedirects, isFalse);
          return http.Response.bytes(
            _mp3,
            200,
            headers: {'content-type': 'audio/mpeg'},
          );
        },
      );
      await harness.service.discoverTools();
      final path = await harness.service.synthesize(
        text: '秘密のテスト台詞',
        language: 'ja',
        format: 'wav',
        voice: 'local-voice',
      );
      expect(harness.client.requests.single.arguments, {
        'text': '秘密のテスト台詞',
        'language': 'Japanese',
        'output_format': 'wav',
        'voice_id': 'local-voice',
      });
      expect(path, endsWith('.mp3'));
      expect(await File(path).readAsBytes(), _mp3);
      expect(harness.downloads, hasLength(1));
      expect(harness.service.diagnosticReport, isNot(contains('秘密のテスト台詞')));
      expect(harness.service.diagnosticReport, isNot(contains('local-secret')));
    },
  );

  test('resource link downloads audio without regenerating', () async {
    final harness = await _Harness.create(
      client: _FakeMcpClient(
        onCall: (_) => const CallToolResult(
          content: [
            ResourceLink(
              uri: 'https://fish.audio/result.mp3',
              name: 'speech',
              mimeType: 'audio/mpeg',
            ),
          ],
        ),
      ),
      onDownload: (_) => http.Response.bytes(
        _mp3,
        200,
        headers: {'content-type': 'application/octet-stream'},
      ),
    );
    await harness.service.discoverTools();
    expect(await harness.service.synthesize(text: 'local'), endsWith('.mp3'));
    expect(harness.client.requests, hasLength(1));
    expect(harness.downloads, hasLength(1));
  });

  test(
    'array structured content retains nested audio instead of losing it',
    () async {
      final harness = await _Harness.create(
        client: _FakeMcpClient(
          onCall: (_) => CallToolResult(
            content: const [],
            structuredContentJson: JsonValue.array([
              {
                'result': {'audio_url': 'https://fish.audio/array-result.mp3'},
              },
            ]),
          ),
        ),
        onDownload: (_) => http.Response.bytes(
          _mp3,
          200,
          headers: {'content-type': 'audio/mpeg'},
        ),
      );
      await harness.service.discoverTools();
      final path = await harness.service.synthesize(text: '非公開の配列テスト');
      expect(path, endsWith('.mp3'));
      expect(await File(path).readAsBytes(), _mp3);
      expect(harness.client.requests, hasLength(1));
      expect(harness.downloads, hasLength(1));
      expect(harness.service.lastError, isNull);
      final report = jsonDecode(harness.service.diagnosticReport) as Map;
      expect(
        (report['last_result'] as Map).containsKey('structured_keys'),
        isFalse,
      );
    },
  );

  for (final entry in {
    'http://fish.audio/result.mp3': 'unsafe_audio_url',
    'https://untrusted.invalid/result.mp3': 'untrusted_audio_host',
    'https://fish.audio:8443/result.mp3': 'unsafe_audio_port',
  }.entries) {
    test(
      'unsafe result URL is rejected before download: ${entry.key}',
      () async {
        final harness = await _Harness.create(
          client: _FakeMcpClient(
            onCall: (_) =>
                CallToolResult(content: [TextContent(text: entry.key)]),
          ),
        );
        await harness.service.discoverTools();
        final error = await _failure(harness.service.synthesize(text: 'local'));
        expect(error.code, entry.value);
        expect(error.generationSubmitted, isTrue);
        expect(error.allowsRestFallback, isFalse);
        expect(harness.client.requests, hasLength(1));
        expect(harness.downloads, isEmpty);
      },
    );
  }

  test(
    'download redirect is revalidated and sends no request to unsafe host',
    () async {
      final harness = await _Harness.create(
        client: _FakeMcpClient(
          onCall: (_) => const CallToolResult(
            content: [TextContent(text: 'https://fish.audio/result.mp3')],
          ),
        ),
        onDownload: (_) => http.Response(
          '',
          302,
          headers: {'location': 'https://untrusted.invalid/stolen.mp3'},
        ),
      );
      await harness.service.discoverTools();
      final error = await _failure(harness.service.synthesize(text: 'local'));
      expect(error.code, 'untrusted_audio_host');
      expect(error.allowsRestFallback, isFalse);
      expect(harness.client.requests, hasLength(1));
      expect(harness.downloads.single.url.host, 'fish.audio');
    },
  );

  test('non-audio response never writes a file or regenerates', () async {
    final harness = await _Harness.create(
      client: _FakeMcpClient(
        onCall: (_) => const CallToolResult(
          content: [TextContent(text: 'https://fish.audio/result.mp3')],
        ),
      ),
      onDownload: (_) => http.Response(
        'not an audio container',
        200,
        headers: {'content-type': 'audio/mpeg'},
      ),
    );
    await harness.service.discoverTools();
    final error = await _failure(harness.service.synthesize(text: 'local'));
    expect(error.code, 'invalid_audio');
    expect(error.stage, 'audio_validate');
    expect(error.allowsRestFallback, isFalse);
    expect(harness.client.requests, hasLength(1));
    expect(harness.downloads, hasLength(1));
  });

  test(
    'audio download HTTP failure keeps request ID and does not retry',
    () async {
      final harness = await _Harness.create(
        client: _FakeMcpClient(
          onCall: (_) => const CallToolResult(
            content: [TextContent(text: 'https://fish.audio/result.mp3')],
          ),
        ),
        onDownload: (_) => http.Response(
          'unavailable',
          503,
          headers: {'x-request-id': 'req-download-002'},
        ),
      );
      await harness.service.discoverTools();
      final error = await _failure(harness.service.synthesize(text: 'local'));
      expect(error.code, 'audio_http_error');
      expect(error.status, 503);
      expect(error.requestId, 'req-download-002');
      expect(error.generationSubmitted, isTrue);
      expect(error.allowsRestFallback, isFalse);
      expect(harness.client.requests, hasLength(1));
      expect(harness.downloads, hasLength(1));
    },
  );

  test(
    'transport failure is outcome unknown and error report redacts secrets',
    () async {
      const privateText = 'PRIVATE_DIALOGUE_NOT_FOR_DIAGNOSTICS';
      final harness = await _Harness.create(
        client: _FakeMcpClient(
          onCall: (_) => throw TimeoutException(
            'Authorization: Bearer local-access-token https://api.fish.audio/mcp?access_token=local-query-token',
          ),
        ),
      );
      await harness.service.discoverTools();
      final error = await _failure(
        harness.service.synthesize(text: privateText),
      );
      expect(error.stage, 'transport');
      expect(error.outcomeUnknown, isTrue);
      expect(error.generationSubmitted, isTrue);
      expect(error.allowsRestFallback, isFalse);
      expect(harness.client.requests, hasLength(1));
      final report = harness.service.diagnosticReport;
      expect(report, isNot(contains(privateText)));
      expect(report, isNot(contains('local-access-token')));
      expect(report, isNot(contains('local-query-token')));
      final decoded = jsonDecode(report) as Map<String, dynamic>;
      expect(
        (decoded['last_request'] as Map)['text_utf8_bytes'],
        utf8.encode(privateText).length,
      );
      expect((decoded['last_error'] as Map)['outcome_unknown'], isTrue);
    },
  );
}
