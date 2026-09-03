import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';
import 'package:ryza_chat_mvp/src/audio_envelope.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/character_camera.dart';
import 'package:ryza_chat_mvp/src/character_expression.dart';
import 'package:ryza_chat_mvp/src/character_performance.dart';
import 'package:ryza_chat_mvp/src/chat_screen.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/settings_screen.dart';
import 'package:ryza_chat_mvp/src/tap_reaction.dart';
import 'package:ryza_chat_mvp/src/world_map_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('scene time labels are available in Chinese', () {
    expect(SceneTime.morning.label, '早晨');
    expect(SceneTime.afternoon.label, '午后');
    expect(SceneTime.evening.label, '傍晚');
    expect(SceneTime.night.label, '夜晚');
  });

  test('mission becomes claimable after its activity is recorded', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    final mission = AppController.missions.first;

    expect(controller.isMissionComplete(mission), isFalse);
    controller.recordCharacterTouch();
    expect(controller.isMissionComplete(mission), isTrue);
    expect(controller.claimMission(mission), isTrue);
    expect(controller.stars, mission.reward);
    expect(controller.claimMission(mission), isFalse);
  });

  test('world hierarchy model parses fields and stages', () {
    final area = WorldArea.fromJson({
      'id': 'area_01',
      'name': '测试区域',
      'fields': [
        {
          'id': 'field_01',
          'name': '测试地点组',
          'stages': [
            {'id': 'stage_01', 'name': '测试地点'},
          ],
        },
      ],
    });

    expect(area.fields.single.stages.single.id, 'stage_01');
  });

  test('OpenAI compatible client parses streamed chat deltas', () async {
    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        'https://relay.example/v1/chat/completions',
      );
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['stream'], isTrue);
      return http.Response.bytes(
        utf8.encode(
          'data: {"choices":[{"delta":{"content":"你"}}]}\n\n'
          'data: {"choices":[{"delta":{"content":"好"}}]}\n\n'
          'data: [DONE]\n\n',
        ),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final service = OpenAiCompatibleClient(client: client);
    final parts = await service
        .streamChat(
          baseUrl: 'https://relay.example/v1',
          apiKey: 'test-key',
          model: 'test-model',
          systemPrompt: 'test',
          messages: const [ChatMessage(text: 'hello', isUser: true)],
        )
        .toList();

    expect(parts.join(), '你好');
  });

  test('OpenAI compatible client sends image and document content', () async {
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final messages = body['messages'] as List<dynamic>;
      final user = messages.last as Map<String, dynamic>;
      final content = user['content'] as List<dynamic>;
      expect(content[0], {'type': 'text', 'text': '分析附件'});
      expect((content[1] as Map<String, dynamic>)['type'], 'image_url');
      expect(
        ((content[1] as Map<String, dynamic>)['image_url']
            as Map<String, dynamic>)['url'],
        startsWith('data:image/png;base64,'),
      );
      expect((content[2] as Map<String, dynamic>)['type'], 'file');
      expect(
        ((content[2] as Map<String, dynamic>)['file']
            as Map<String, dynamic>)['filename'],
        'notes.pdf',
      );
      return http.Response.bytes(
        utf8.encode(
          'data: {"choices":[{"delta":{"content":"完成"}}]}\n\n'
          'data: [DONE]\n\n',
        ),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
    final service = OpenAiCompatibleClient(client: client);
    final output = await service
        .streamChat(
          baseUrl: 'https://relay.example/v1',
          apiKey: 'test-key',
          model: 'vision-model',
          systemPrompt: 'test',
          messages: [
            ChatMessage(
              text: '分析附件',
              isUser: true,
              attachments: [
                ChatAttachment(
                  name: 'photo.png',
                  mimeType: 'image/png',
                  size: 3,
                  bytes: Uint8List.fromList([1, 2, 3]),
                ),
                ChatAttachment(
                  name: 'notes.pdf',
                  mimeType: 'application/pdf',
                  size: 2,
                  bytes: Uint8List.fromList([4, 5]),
                ),
              ],
            ),
          ],
        )
        .toList();

    expect(output.join(), '完成');
  });

  test(
    'OpenAI GPT controls add reasoning and output token parameters',
    () async {
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['reasoning_effort'], 'high');
        expect(body['max_completion_tokens'], 6144);
        return http.Response.bytes(
          utf8.encode(
            'data: {"choices":[{"delta":{"content":"完成"}}]}\n\n'
            'data: [DONE]\n\n',
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final service = OpenAiCompatibleClient(client: client);
      final output = await service
          .streamChat(
            baseUrl: 'https://api.openai.com/v1',
            apiKey: 'test-key',
            model: 'gpt-5.4',
            systemPrompt: 'test',
            messages: const [ChatMessage(text: 'hello', isUser: true)],
            reasoningEffort: 'high',
            outputMultiplier: 1.5,
          )
          .toList();

      expect(output.join(), '完成');
    },
  );

  test('agent executes web search tool and returns result to model', () async {
    var apiCalls = 0;
    final client = MockClient((request) async {
      if (request.url.host == 'html.duckduckgo.com') {
        expect(request.url.queryParameters['q'], 'OpenAI 最新消息');
        return http.Response.bytes(
          utf8.encode('''
          <div class="result">
            <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fnews">新闻标题</a>
            <a class="result__snippet">新闻摘要</a>
          </div>
          '''),
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      }

      apiCalls += 1;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['stream'], isFalse);
      if (apiCalls == 1) {
        expect(body['tools'], isNotEmpty);
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': '',
                    'tool_calls': [
                      {
                        'id': 'call_search',
                        'type': 'function',
                        'function': {
                          'name': 'web_search',
                          'arguments': jsonEncode({'query': 'OpenAI 最新消息'}),
                        },
                      },
                    ],
                  },
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }

      final messages = body['messages'] as List<dynamic>;
      final toolMessage = messages.last as Map<String, dynamic>;
      expect(toolMessage['role'], 'tool');
      expect(toolMessage['content'], contains('https://example.com/news'));
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': '已根据搜索结果回答。'},
              },
            ],
          }),
        ),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final service = OpenAiCompatibleClient(client: client);
    final output = await service
        .streamChat(
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'test-key',
          model: 'gpt-5.4',
          systemPrompt: 'test',
          messages: const [ChatMessage(text: '搜索新闻', isUser: true)],
          agentEnabled: true,
        )
        .toList();

    expect(apiCalls, 2);
    expect(output.join(), '已根据搜索结果回答。');
  });

  test(
    'assistant response separates narrator and Ryza for display and TTS',
    () {
      const response = '''旁白：工房的窗外下着小雨。
莱莎：[curious] 这种湿度说不定会影响素材呢。[break] 我去看看！
旁白：（莱莎拿起篮子走到门边。）
莱莎：[excited] 要一起出发吗？''';

      final segments = parseAssistantSegments(response);
      final speech = ttsTextForAssistantResponse(
        response,
        fallbackMood: CharacterMood.neutral,
      );
      final display = displayTextForAssistantResponse(response);

      expect(segments, hasLength(4));
      expect(segments.first.speaker, ChatSpeaker.narrator);
      expect(speech, contains('[curious]'));
      expect(speech, contains('[excited]'));
      expect(speech, isNot(contains('工房的窗外')));
      expect(speech, isNot(contains('拿起篮子')));
      expect(display, contains('旁白：工房的窗外下着小雨。'));
      expect(display, contains('莱莎：这种湿度说不定会影响素材呢。 我去看看！'));
      expect(display, isNot(contains('[curious]')));
    },
  );

  test(
    'translated reply is displayed but excluded from TTS and performance',
    () {
      const response = '''旁白：The workshop is quiet.
莱莎：[happy][face:happy][action:wave] Welcome back!
译文：欢迎回来！''';

      final segments = parseAssistantSegments(response);
      final speech = ttsTextForAssistantResponse(
        response,
        fallbackMood: CharacterMood.neutral,
      );
      final performance = performanceSegmentsForAssistantResponse(
        response,
        fallbackMood: CharacterMood.neutral,
      );

      expect(segments.last.speaker, ChatSpeaker.translation);
      expect(displayTextForAssistantResponse(response), contains('译文：欢迎回来！'));
      expect(speech, contains('Welcome back!'));
      expect(speech, isNot(contains('欢迎回来')));
      expect(performance, hasLength(1));
    },
  );

  test('missing Fish emotion cue receives mood fallback', () {
    final speech = ttsTextForAssistantResponse(
      '莱莎：交给我吧！',
      fallbackMood: CharacterMood.happy,
    );

    expect(speech, '[happy] 交给我吧！');
  });

  test('assistant face cue controls expression but is excluded from TTS', () {
    const response = '莱莎：[happy][face:happy][action:excited] 太好了！';
    final speech = ttsTextForAssistantResponse(
      response,
      fallbackMood: CharacterMood.neutral,
    );

    expect(expressionForAssistantResponse(response), CharacterExpression.happy);
    expect(speech, '[happy] 太好了！');
    expect(speech, isNot(contains('[face:')));
    expect(speech, isNot(contains('[action:')));
    expect(displayTextForAssistantResponse(response), '莱莎：太好了！');
  });

  test('conversation raw output bypasses all assistant filtering', () {
    const response = ' 旁白：风吹过窗边。\n莱莎：[excited][face:happy][action:wave] 出发吧！\n';

    expect(
      conversationTextForAssistantResponse(response, showRawOutput: true),
      same(response),
    );
    final filtered = conversationTextForAssistantResponse(
      response,
      showRawOutput: false,
    );
    expect(filtered, isNot(contains('[face:')));
    expect(filtered, isNot(contains('[action:')));
    expect(filtered, isNot(endsWith('\n')));
  });

  test('assistant performance cue selects the latest face and action', () {
    const response = '''莱莎：[curious][face:tease][action:think] 让我想想。
莱莎：[excited][face:happy][action:explain] 我知道该怎么做了！''';

    final cue = performanceCueForAssistantResponse(response);

    expect(cue.expression, CharacterExpression.happy);
    expect(cue.action, CharacterAction.explain);
    expect(cue.actionCueCount, 2);
  });

  test('assistant performance segments preserve per-line timing cues', () {
    const response = '''旁白：风吹过工房门口。
莱莎：[curious][face:tease][action:think] 这个气味有点熟悉。
莱莎：[excited][face:happy][action:explain] 我知道了，是新素材！''';

    final segments = performanceSegmentsForAssistantResponse(
      response,
      fallbackMood: CharacterMood.neutral,
    );

    expect(segments, hasLength(2));
    expect(segments.first.speechText, '[curious] 这个气味有点熟悉。');
    expect(segments.first.expression, CharacterExpression.tease);
    expect(segments.first.action, CharacterAction.think);
    expect(segments.last.speechText, '[excited] 我知道了，是新素材！');
    expect(segments.last.expression, CharacterExpression.happy);
    expect(segments.last.action, CharacterAction.explain);
    expect(
      segments.expand((segment) => segment.speechText.codeUnits),
      isNotEmpty,
    );
    expect(
      segments.map((segment) => segment.speechText).join(),
      isNot(contains('风吹过')),
    );
    expect(
      segments.map((segment) => segment.speechText).join(),
      isNot(contains('[face:')),
    );
  });

  test('WAV envelope follows silence and speech energy', () {
    const sampleRate = 8000;
    const samples = sampleRate ~/ 2;
    final bytes = Uint8List(44 + samples * 2);
    final data = ByteData.sublistView(bytes);
    void writeAscii(int offset, String value) {
      for (var index = 0; index < value.length; index++) {
        bytes[offset + index] = value.codeUnitAt(index);
      }
    }

    writeAscii(0, 'RIFF');
    data.setUint32(4, bytes.length - 8, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, sampleRate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    writeAscii(36, 'data');
    data.setUint32(40, samples * 2, Endian.little);
    for (var index = samples ~/ 2; index < samples; index++) {
      final sample = index.isEven ? 18000 : -18000;
      data.setInt16(44 + index * 2, sample, Endian.little);
    }

    final envelope = AudioAmplitudeEnvelope.tryParseWav(bytes);

    expect(envelope, isNotNull);
    expect(envelope!.valueAt(const Duration(milliseconds: 80)), lessThan(0.05));
    expect(
      envelope.valueAt(const Duration(milliseconds: 420)),
      greaterThan(0.7),
    );
    final voicedFrames = envelope.values.skip(envelope.values.length ~/ 2);
    expect(
      voicedFrames.where((value) => value == 0).length,
      greaterThanOrEqualTo(2),
    );
    expect(voicedFrames.where((value) => value > 0.5), isNotEmpty);
    expect(envelope.values.every((value) => value >= 0 && value <= 1), isTrue);
  });

  test('invalid assistant face cue falls back to neutral', () {
    expect(
      expressionForAssistantResponse('莱莎：[excited][face:unknown] 出发吧！'),
      CharacterExpression.neutral,
    );
  });

  test('face cue alone still receives a Fish emotion fallback', () {
    final speech = ttsTextForAssistantResponse(
      '莱莎：[face:shy] 别一直盯着我看啦。',
      fallbackMood: CharacterMood.happy,
    );

    expect(speech, '[happy] 别一直盯着我看啦。');
  });

  test('Fish Audio request matches official S2 JSON API', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), FishAudioClient.endpoint);
      expect(request.headers['authorization'], 'Bearer fish-test-key');
      expect(request.headers['content-type'], startsWith('application/json'));
      expect(request.headers['model'], 's2-pro');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['text'], '[curious] 这个素材很特别。');
      expect(body['reference_id'], 'voice-model-id');
      expect(body['format'], 'mp3');
      expect(body['latency'], 'normal');
      expect(body['normalize'], isTrue);
      expect(
        (body['prosody'] as Map<String, dynamic>)['normalize_loudness'],
        isTrue,
      );
      return http.Response.bytes([1, 2, 3], 200);
    });

    final bytes = await FishAudioClient(client: client).synthesizeBytes(
      apiKey: 'fish-test-key',
      referenceId: 'voice-model-id',
      text: '[curious] 这个素材很特别。',
    );

    expect(bytes, [1, 2, 3]);
  });

  test('DashScope Qwen-TTS request follows official multimodal API', () async {
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        expect(request.url.toString(), 'https://audio.example/test.wav');
        return http.Response.bytes([4, 5, 6], 200);
      }
      expect(request.url.toString(), DashScopeTtsClient.endpoint);
      expect(request.headers['authorization'], 'Bearer dashscope-test-key');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['model'], 'qwen3-tts-instruct-flash');
      final input = body['input'] as Map<String, dynamic>;
      expect(input['text'], '今天去采集素材吧！');
      expect(input['voice'], 'Cherry');
      expect(input['language_type'], 'Chinese');
      expect(input['instructions'], contains('活泼'));
      expect(input['optimize_instructions'], isTrue);
      return http.Response(
        jsonEncode({
          'output': {
            'audio': {'url': 'https://audio.example/test.wav'},
          },
        }),
        200,
      );
    });

    final bytes = await DashScopeTtsClient(client: client).synthesizeBytes(
      apiKey: 'dashscope-test-key',
      text: '今天去采集素材吧！',
      model: 'qwen3-tts-instruct-flash',
      voice: 'Cherry',
      instructions: '活泼、明亮、语速稍快',
    );

    expect(bytes, [4, 5, 6]);
  });

  test('generic TTS uses the OpenAI audio speech contract', () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), 'https://tts.example/v1/audio/speech');
      expect(request.headers['authorization'], 'Bearer generic-test-key');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['model'], 'custom-tts');
      expect(body['input'], '测试通用语音。');
      expect(body['voice'], 'speaker-a');
      expect(body['response_format'], 'wav');
      expect(body['speed'], 1.2);
      return http.Response.bytes([7, 8, 9], 200);
    });

    final bytes = await GenericTtsClient(client: client).synthesizeBytes(
      baseUrl: 'https://tts.example/v1/',
      apiKey: 'generic-test-key',
      text: '测试通用语音。',
      model: 'custom-tts',
      voice: 'speaker-a',
      speed: 1.2,
    );

    expect(bytes, [7, 8, 9]);
  });

  test('conversation panel grows with the latest message', () {
    final short = conversationPanelFractionForText(
      text: '好呀！',
      viewportWidth: 400,
      viewportHeight: 800,
      isWide: false,
    );
    final long = conversationPanelFractionForText(
      text: List.filled(20, '这是一段需要让对话框自动拉长的回复。').join(),
      viewportWidth: 400,
      viewportHeight: 800,
      isWide: false,
    );

    expect(long, greaterThan(short));
    expect(long, lessThanOrEqualTo(0.68));
  });

  test('conversation panel includes assistant segment separators', () {
    final singleSegment = conversationPanelFractionForText(
      text: '相同长度的正文。',
      viewportWidth: 400,
      viewportHeight: 800,
      isWide: false,
    );
    final threeSegments = conversationPanelFractionForText(
      text: '相同长度的正文。',
      viewportWidth: 400,
      viewportHeight: 800,
      isWide: false,
      segmentCount: 3,
    );

    expect(threeSegments, greaterThan(singleSegment));
    expect(threeSegments - singleSegment, closeTo(34 / 800, 0.001));
  });

  test('image attachments reserve thumbnail height in conversation panel', () {
    final fileAttachment = conversationPanelFractionForText(
      text: '请查看附件。',
      viewportWidth: 400,
      viewportHeight: 800,
      isWide: false,
      hasAttachments: true,
    );
    final imageAttachment = conversationPanelFractionForText(
      text: '请查看图片。',
      viewportWidth: 400,
      viewportHeight: 800,
      isWide: false,
      hasAttachments: true,
      hasImageAttachments: true,
    );

    expect(imageAttachment, greaterThan(fileAttachment));
  });

  test(
    'Fish Audio defaults to s2-pro and prompt requires speaker contract',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();

      expect(controller.fishAudioModel, 's2-pro');
      expect(
        controller.buildCharacterPrompt(),
        contains('每个非空行只能以“旁白：”、“莱莎：”或“译文：”开头'),
      );
      expect(controller.buildCharacterPrompt(), contains('Fish Audio S2'));
      expect(controller.buildCharacterPrompt(), contains('[face:crying]'));
      expect(controller.buildCharacterPrompt(), contains('[action:comfort]'));
      expect(controller.buildCharacterPrompt(), contains('绝对不要输出原始动画名'));
    },
  );

  test('TTS provider and preview text persist locally', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    controller.setTtsProvider(TtsProvider.generic);
    controller.setTtsPreviewText('这是一段自定义试音文字。');
    await Future<void>.delayed(Duration.zero);

    final restored = await AppController.load();
    expect(restored.ttsProvider, TtsProvider.generic);
    expect(restored.ttsPreviewText, '这是一段自定义试音文字。');
  });

  test(
    'theme and language preferences persist, export, and enter prompt',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      controller.setThemePreference(AppThemePreference.dark);
      controller.configureLanguages(
        interface: AppLanguage.japanese,
        narrator: AppLanguage.english,
        characterReply: AppLanguage.japanese,
        translation: TranslationLanguage.chinese,
      );
      await Future<void>.delayed(Duration.zero);

      final restored = await AppController.load();
      final prompt = restored.buildCharacterPrompt();
      expect(restored.themePreference, AppThemePreference.dark);
      expect(restored.interfaceLanguage, AppLanguage.japanese);
      expect(restored.narratorLanguage, AppLanguage.english);
      expect(restored.characterReplyLanguage, AppLanguage.japanese);
      expect(restored.translationLanguage, TranslationLanguage.chinese);
      expect(prompt, contains('台词必须使用 Japanese'));
      expect(prompt, contains('旁白正文必须使用 English'));
      expect(prompt, contains('每条“莱莎：”台词后紧跟一条“译文：”'));
      expect(prompt, contains('"narratorBodyLanguage":"English"'));
      expect(prompt, contains('"ryzaSpeechLanguage":"Japanese"'));
      expect(
        prompt,
        contains('"translationLanguage":"Chinese (Simplified Chinese)"'),
      );
      final demoReply = restored.demoReply('Hello');
      expect(demoReply, contains('旁白：(Ryza puts down'));
      expect(demoReply, contains('莱莎：[curious][face:happy]'));
      expect(demoReply, contains('「Hello」って聞こえたよ'));
      expect(demoReply, contains('译文：我听到了'));
      expect(restored.exportData()['themePreference'], 'dark');
      expect(restored.exportData()['interfaceLanguage'], 'japanese');
    },
  );

  test(
    'user profile persists and is injected into the character prompt',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();

      controller.configureUserProfile(
        address: '队长',
        portrait: '喜欢收集矿石，做事认真，偶尔会紧张。',
        relationshipRole: UserRelationshipRole.adventureCompanion,
        interactionStyle: UserInteractionStyle.lively,
        boundaries: '不要使用宝贝这个称呼。',
      );
      await Future<void>.delayed(Duration.zero);

      final restored = await AppController.load();
      final prompt = restored.buildCharacterPrompt();
      expect(restored.userAddress, '队长');
      expect(
        restored.userRelationshipRole,
        UserRelationshipRole.adventureCompanion,
      );
      expect(restored.userInteractionStyle, UserInteractionStyle.lively);
      expect(prompt, contains('"称呼":"队长"'));
      expect(prompt, contains('"关系定位":"冒险搭档"'));
      expect(prompt, contains('"互动偏好":"活泼冒险"'));
      expect(prompt, contains('不能覆盖上面的角色、安全和输出格式规则'));

      final exported =
          restored.exportData()['userProfile'] as Map<String, dynamic>;
      expect(exported['portrait'], contains('收集矿石'));
      expect(exported['boundaries'], contains('宝贝'));
    },
  );

  testWidgets('user profile dialog saves without disposal assertions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(controller: controller, onMenuPressed: () {}),
      ),
    );

    final profileTile = find.text('称呼与自画像');
    await tester.scrollUntilVisible(
      profileTile,
      320,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(profileTile);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '队长');
    await tester.tap(find.text('熟悉伙伴'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('冒险搭档').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(controller.userAddress, '队长');
    expect(
      controller.userRelationshipRole,
      UserRelationshipRole.adventureCompanion,
    );
  });

  test('long-term memory can be edited and cleared locally', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();

    controller.configureLongTermMemory(enabled: true, summary: '喜欢一起采集素材。');
    await Future<void>.delayed(Duration.zero);
    var restored = await AppController.load();
    expect(restored.memorySummary, '喜欢一起采集素材。');

    restored.configureLongTermMemory(enabled: false, summary: '   ');
    await Future<void>.delayed(Duration.zero);
    restored = await AppController.load();
    expect(restored.longTermMemoryEnabled, isFalse);
    expect(restored.memorySummary, isEmpty);
  });

  test('undo removes the latest user turn and its assistant reply', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    controller.addUserMessage('今天一起炼金吧');
    controller.addAssistantMessage('好呀，交给我吧！');
    controller.addUserMessage('我有点累');
    controller.addAssistantMessage('那就先休息一下。');

    final withdrawn = controller.undoLastUserTurn();

    expect(withdrawn?.text, '我有点累');
    expect(
      controller.messages.any((message) => message.text == '我有点累'),
      isFalse,
    );
    expect(
      controller.messages.any((message) => message.text == '那就先休息一下。'),
      isFalse,
    );
    expect(controller.messages.last.text, '好呀，交给我吧！');
    expect(controller.userMessageCount, 1);
    expect(controller.relationshipPoints, 1);
    expect(controller.characterMood, CharacterMood.excited);
  });

  testWidgets('long-term memory dialog edits the current summary', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'memory_summary': '原来的记忆'});
    final controller = await AppController.load();
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(controller: controller, onMenuPressed: () {}),
      ),
    );

    final scrollable = find.byType(Scrollable).first;
    for (var attempt = 0; attempt < 6; attempt += 1) {
      if (find.text('长期记忆').evaluate().isNotEmpty) break;
      await tester.drag(scrollable, const Offset(0, -480));
      await tester.pumpAndSettle();
    }
    final memoryTile = find.text('长期记忆');
    expect(memoryTile, findsOneWidget);
    await tester.ensureVisible(memoryTile);
    await tester.pumpAndSettle();
    await tester.tap(memoryTile);
    await tester.pumpAndSettle();
    final editor = find.byType(TextField).last;
    expect(tester.widget<TextField>(editor).controller?.text, '原来的记忆');
    await tester.enterText(editor, '记得用户喜欢一起采集矿石。');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(controller.memorySummary, '记得用户喜欢一起采集矿石。');
  });

  test('legacy Fish model preference migrates once to s2-pro', () async {
    SharedPreferences.setMockInitialValues({
      'fish_audio_model': 's2.1-pro-free',
    });
    final controller = await AppController.load();

    expect(controller.fishAudioModel, 's2-pro');
    await Future<void>.delayed(Duration.zero);
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'fish_audio_s2_pro_migrated',
      ),
      isTrue,
    );
  });

  test('local export excludes API credentials', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    controller.configureAi(
      enabled: true,
      baseUrl: 'https://relay.example/v1',
      model: 'test-model',
    );
    final encoded = jsonEncode(controller.exportData());

    expect(encoded, contains('relay.example'));
    expect(encoded, isNot(contains('apiKey')));
    expect(encoded, isNot(contains('test-key')));
  });

  test('advanced OpenAI and agent preferences are persisted', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    controller.configureAi(
      enabled: true,
      baseUrl: 'https://relay.example/v1',
      model: 'gpt-5-compatible',
    );
    expect(controller.supportsOpenAiAdvancedControls, isTrue);
    controller.configureOpenAiAdvanced(
      enabled: true,
      reasoningEffort: ReasoningEffort.high,
      outputMultiplier: 1.5,
    );
    controller.setAgentEnabled(true);
    await Future<void>.delayed(Duration.zero);

    final restored = await AppController.load();
    expect(restored.openAiAdvancedEnabled, isTrue);
    expect(restored.openAiReasoningEffort, ReasoningEffort.high);
    expect(restored.openAiOutputMultiplier, 1.5);
    expect(restored.agentEnabled, isTrue);
    final preferences =
        restored.exportData()['preferences'] as Map<String, dynamic>;
    expect(preferences['openAiReasoningEffort'], 'high');
    expect(preferences['agentEnabled'], isTrue);
  });

  test('liquid glass chat UI preference is persisted and exported', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();

    controller.setLiquidGlassChatUi(true);
    controller.setShowMicrophoneButton(true);
    await Future<void>.delayed(Duration.zero);
    final restored = await AppController.load();

    expect(restored.liquidGlassChatUi, isTrue);
    expect(restored.showMicrophoneButton, isTrue);
    expect(restored.exportData()['liquidGlassChatUi'], isTrue);
    expect(restored.exportData()['showMicrophoneButton'], isTrue);
  });

  test('tap reaction preserves original part animation and voice routing', () {
    final leftArm = tapReactionsByPart['arm_l']!.single;
    final rightArm = tapReactionsByPart['arm_r']!.single;
    final head = tapReactionsByPart['head']!;

    expect(leftArm.number, 1);
    expect(leftArm.animation, 'motion_touch_A_005_active');
    expect(
      leftArm.voiceAsset(3),
      'audio/tap_voice/jp/normal/jp_normal_motion_touch_A_001_03.m4a',
    );
    expect(rightArm.animation, 'motion_touch_A_006_active');
    expect(head.map((reaction) => reaction.number), [5, 6]);
    expect(
      leftArm.localizedVoiceAsset(AppLanguage.chinese, 9),
      'audio/tap_voice/zh-tw/normal/zh-tw_normal_motion_touch_A_001_03.m4a',
    );
    expect(
      leftArm.localizedVoiceAsset(AppLanguage.english, 1),
      'audio/tap_voice/en/normal/en_normal_motion_touch_A_001_01.m4a',
    );
    expect(
      leftArm.localizedVoiceAsset(AppLanguage.japanese, 5),
      'audio/tap_voice/jp/normal/jp_normal_motion_touch_A_001_03.m4a',
    );
  });

  test('polygon hit testing distinguishes inside and outside points', () {
    const square = <double>[0, 0, 10, 0, 10, 10, 0, 10];

    expect(polygonContainsPoint(square, 5, 5), isTrue);
    expect(polygonContainsPoint(square, 15, 5), isFalse);
  });

  test('bundled character appearances expose their original motion pools', () {
    final seated = characterAppearanceById('seated_01');
    final standing = characterAppearanceById('standing_99');

    expect(characterAppearances, hasLength(5));
    expect(
      characterAppearances.where((appearance) => appearance.animated),
      hasLength(2),
    );
    expect(
      characterAppearances.where((appearance) => !appearance.animated),
      hasLength(3),
    );
    expect(seated.idleAnimations, hasLength(20));
    expect(seated.idleAnimations, contains('motion_A_034_idle'));
    expect(standing.idleAnimations, hasLength(7));
    expect(characterOneShotAnimations, hasLength(12));
  });

  test('expression presets use the original seated and standing face sets', () {
    final seated = characterExpressionPreset(
      'seated_01',
      CharacterExpression.angry,
    );
    final standing = characterExpressionPreset(
      'standing_99',
      CharacterExpression.crying,
    );

    expect(seated.eyebrow, 'facial_eyebrow_012_idle');
    expect(seated.lipSync, 'facial_mouth_017_scrub_01');
    expect(seated.lipSyncAlpha, lessThan(0.7));
    expect(standing.eye, 'facial_eye_007_idle');
    expect(standing.mouth, 'facial_mouth_006_idle');
    expect(standing.lipSync, 'facial_mouth_002_scrub_02');
    for (final expression in CharacterExpression.values) {
      expect(characterFacialDetails('seated_01', expression), isNotEmpty);
      expect(characterFacialDetails('standing_99', expression), isNotEmpty);
    }
    expect(
      characterFacialDetails(
        'seated_01',
        CharacterExpression.happy,
      ).map((detail) => detail.eye),
      containsAll(['facial_eye_005_idle', 'facial_eye_010_idle']),
    );
  });

  test('motion occupancy letters map to independent Spine tracks', () {
    expect(motionTrackForOccupancyLetter('B'), 2);
    expect(motionTrackForOccupancyLetter('F'), 6);
    expect(motionTrackForOccupancyLetter('J'), 10);
    expect(motionTrackForOccupancyLetter('A'), isNull);

    final group = CharacterMotionGroup.fromJson({
      'GroupId': 'fg-test',
      'Label': 'test',
      'OccupancyLetters': 'FG',
      'AnimName_1': 'motion_add_F_001_active',
      'AnimName_2': 'motion_add_G_001_active',
      'ApplicablePoseIds': 'motion_A_001_idle,motion_A_003_idle',
    });
    expect(group.occupiedTracks, [6, 7]);
    expect(group.supportsPose('motion_A_003_idle'), isTrue);
    expect(group.supportsPose('motion_A_006_idle'), isFalse);
  });

  test('semantic actions map to pose-specific safe motion plans', () {
    final seated = characterActionPlan('seated_01', CharacterAction.excited);
    final standing = characterActionPlan('standing_99', CharacterAction.shy);

    expect(seated.motionGroupIds, contains('grp_fg_030'));
    expect(standing.motionGroupIds, contains('grp_fg_004'));
    expect(
      characterActionPlan(
        'standing_99',
        CharacterAction.acknowledge,
      ).oneShotFallback,
      'motion_oneshot_D_001_active',
    );
  });

  test('gesture parser exposes composited groups and emotion weights', () {
    final groups = parseCharacterMotionGroups(
      jsonEncode({
        'emotionalGesture': {
          'MotionGroups': [
            {
              'GroupId': 'group-a',
              'Label': 'composited test group',
              'OccupancyLetters': 'FG',
              'AnimName_1': 'motion_add_F_001_active',
              'AnimName_2': 'motion_add_G_001_active',
              'ApplicablePoseIds': 'pose-a',
            },
          ],
          'EmotionProfilesV4': {
            'happy': {
              'intensityProfiles': {
                'normal': {
                  'armGroupWeights': {'group-a': 1.0},
                },
              },
            },
            'tease': {
              'intensityProfiles': {
                'normal': {
                  'armGroupWeightsByPoseType': {
                    '': {'group-a': 0.5},
                  },
                },
              },
            },
          },
        },
      }),
    );

    expect(groups, hasLength(1));
    expect(groups.single.animation2, isNotNull);
    expect(groups.single.weightFor(CharacterExpression.happy), 1.0);
    expect(groups.single.weightFor(CharacterExpression.tease), 0.5);
  });

  test('ambient motion prefers groups weighted for the current emotion', () {
    final weighted = _motionGroup(
      id: 'happy',
      emotionWeights: const {CharacterExpression.happy: 1},
    );
    final unweighted = _motionGroup(id: 'neutral');

    final selected = selectCharacterAmbientMotionGroup(
      groups: [unweighted, weighted],
      expression: CharacterExpression.happy,
      pose: 'pose-a',
      recentGroupIds: const {},
      random: Random(1),
      allowLargePostureChanges: true,
      explorationChance: 0,
    );

    expect(selected?.id, 'happy');
  });

  test('ambient motion avoids recently used group ids', () {
    final selected = selectCharacterAmbientMotionGroup(
      groups: [
        _motionGroup(id: 'recent'),
        _motionGroup(id: 'fresh'),
      ],
      expression: CharacterExpression.neutral,
      pose: 'pose-a',
      recentGroupIds: const {'recent'},
      random: Random(2),
      allowLargePostureChanges: true,
      explorationChance: 1,
    );

    expect(selected?.id, 'fresh');
  });

  test('speaking ambient motion excludes large posture changes', () {
    final selected = selectCharacterAmbientMotionGroup(
      groups: [
        _motionGroup(id: 'posture', occupancy: 'C'),
        _motionGroup(id: 'gesture'),
      ],
      expression: CharacterExpression.neutral,
      pose: 'pose-a',
      recentGroupIds: const {},
      random: Random(3),
      allowLargePostureChanges: false,
      explorationChance: 1,
    );

    expect(selected?.id, 'gesture');
  });

  test('ambient exploration still respects the active pose', () {
    final selected = selectCharacterAmbientMotionGroup(
      groups: [
        _motionGroup(id: 'wrong-pose', applicablePoseIds: const ['pose-b']),
        _motionGroup(id: 'right-pose', applicablePoseIds: const ['pose-a']),
      ],
      expression: CharacterExpression.neutral,
      pose: 'pose-a',
      recentGroupIds: const {},
      random: Random(4),
      allowLargePostureChanges: true,
      explorationChance: 1,
    );

    expect(selected?.id, 'right-pose');
  });

  testWidgets('two-finger pinch scales only the character camera', (
    tester,
  ) async {
    Offset? tappedPosition;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: CharacterCamera(
              onTap: (position) => tappedPosition = position,
              initialScale: 1,
              initialVerticalOffsetFraction: 0,
              child: const ColoredBox(color: Colors.orange),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final stage = find.byKey(characterCameraGestureKey);
    final transformFinder = find.byKey(characterCameraTransformKey);
    final offsetFinder = find.byKey(characterCameraOffsetKey);
    expect(stage, findsOneWidget);
    expect(transformFinder, findsOneWidget);
    expect(offsetFinder, findsOneWidget);
    expect(
      tester.widget<Transform>(transformFinder).transform.getMaxScaleOnAxis(),
      closeTo(1, 0.001),
    );

    final center = tester.getCenter(stage);
    final first = await tester.createGesture(pointer: 1);
    final second = await tester.createGesture(pointer: 2);
    await first.down(center + const Offset(-40, 0));
    await second.down(center + const Offset(40, 0));
    await first.moveTo(center + const Offset(-90, 0));
    await second.moveTo(center + const Offset(90, 0));
    await tester.pump();

    final scale = tester
        .widget<Transform>(transformFinder)
        .transform
        .getMaxScaleOnAxis();
    expect(scale, greaterThan(1));

    await first.moveBy(const Offset(0, 80));
    await second.moveBy(const Offset(0, 80));
    await tester.pump();
    final verticalOffset = tester
        .widget<Transform>(offsetFinder)
        .transform
        .storage[13];
    expect(verticalOffset, greaterThan(60));

    await first.up();
    await second.up();
    await tester.pump();
    expect(tappedPosition, isNull);

    await tester.pump(const Duration(milliseconds: 300));
    final stageRect = tester.getRect(stage);
    final visualPosition = Offset(
      stageRect.width / 2 + 80,
      stageRect.height - 120,
    );
    await tester.tapAt(stageRect.topLeft + visualPosition);
    await tester.pump();
    final origin = Offset(stageRect.width / 2, stageRect.height);
    final translated = visualPosition - Offset(0, verticalOffset);
    final expectedPosition = origin + (translated - origin) / scale;
    expect(tappedPosition?.dx, closeTo(expectedPosition.dx, 0.01));
    expect(tappedPosition?.dy, closeTo(expectedPosition.dy, 0.01));
  });

  testWidgets('character camera defaults to a closer upper-body framing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: CharacterCamera(
              onTap: (_) {},
              child: const ColoredBox(color: Colors.orange),
            ),
          ),
        ),
      ),
    );

    final scale = tester
        .widget<Transform>(find.byKey(characterCameraTransformKey))
        .transform
        .getMaxScaleOnAxis();
    final verticalOffset = tester
        .widget<Transform>(find.byKey(characterCameraOffsetKey))
        .transform
        .storage[13];
    expect(scale, closeTo(1.25, 0.001));
    expect(verticalOffset, closeTo(120, 0.01));
  });

  test(
    'selected appearance is persisted and included in local export',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();

      controller.setCharacterAppearance('standing_99');
      await Future<void>.delayed(Duration.zero);
      final restored = await AppController.load();

      expect(restored.selectedCharacterAppearanceId, 'standing_99');
      expect(
        restored.exportData()['selectedCharacterAppearanceId'],
        'standing_99',
      );
    },
  );
}

CharacterMotionGroup _motionGroup({
  required String id,
  String occupancy = 'F',
  List<String> applicablePoseIds = const [],
  Map<CharacterExpression, double> emotionWeights = const {},
}) => CharacterMotionGroup(
  id: id,
  label: id,
  occupancy: occupancy,
  animation1: 'motion_$id',
  animation2: null,
  alpha1: 1,
  alpha2: 1,
  speed1: 1,
  speed2: 1,
  blendTime: 0.3,
  applicablePoseIds: applicablePoseIds,
  emotionWeights: emotionWeights,
);
