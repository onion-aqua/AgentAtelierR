import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/character_appearance.dart';
import 'package:ryza_chat_mvp/src/character_expression.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
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

  test('missing Fish emotion cue receives mood fallback', () {
    final speech = ttsTextForAssistantResponse(
      '莱莎：交给我吧！',
      fallbackMood: CharacterMood.happy,
    );

    expect(speech, '[happy] 交给我吧！');
  });

  test('assistant face cue controls expression but is excluded from TTS', () {
    const response = '莱莎：[happy][face:happy] 太好了！';
    final speech = ttsTextForAssistantResponse(
      response,
      fallbackMood: CharacterMood.neutral,
    );

    expect(expressionForAssistantResponse(response), CharacterExpression.happy);
    expect(speech, '[happy] 太好了！');
    expect(speech, isNot(contains('[face:')));
    expect(displayTextForAssistantResponse(response), '莱莎：太好了！');
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
      expect(request.headers['authorization'], 'Bearer test-key');
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
      apiKey: 'test-key',
      referenceId: 'voice-model-id',
      text: '[curious] 这个素材很特别。',
    );

    expect(bytes, [1, 2, 3]);
  });

  test(
    'Fish Audio defaults to s2-pro and prompt requires speaker contract',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();

      expect(controller.fishAudioModel, 's2-pro');
      expect(
        controller.buildCharacterPrompt(),
        contains('每个非空行只能以“旁白：”或“莱莎：”开头'),
      );
      expect(controller.buildCharacterPrompt(), contains('Fish Audio S2'));
      expect(controller.buildCharacterPrompt(), contains('[face:crying]'));
      expect(controller.buildCharacterPrompt(), contains('不要输出原始 Spine 动画名'));
    },
  );

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
    expect(seated.lipSync, 'facial_mouth_017_scrub_02');
    expect(standing.eye, 'facial_eye_007_idle');
    expect(standing.mouth, 'facial_mouth_006_idle');
    expect(standing.lipSync, 'facial_mouth_002_scrub_02');
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
    });
    expect(group.occupiedTracks, [6, 7]);
  });

  test('composited motion groups parse without bundled character data', () {
    final group = CharacterMotionGroup.fromJson({
      'GroupId': 'custom-wave',
      'Label': 'Custom wave',
      'OccupancyLetters': 'FG',
      'AnimName_1': 'custom_arm_left',
      'AnimName_2': 'custom_arm_right',
      'Alpha1': '0.8',
      'Alpha2': '0.6',
      'Speed1': '1.2',
      'Speed2': '0.9',
      'BlendTime': '0.25',
    });

    expect(group.id, 'custom-wave');
    expect(group.animation1, 'custom_arm_left');
    expect(group.animation2, 'custom_arm_right');
    expect(group.occupiedTracks, [6, 7]);
    expect(group.alpha1, 0.8);
    expect(group.alpha2, 0.6);
    expect(group.speed1, 1.2);
    expect(group.speed2, 0.9);
    expect(group.blendTime, 0.25);
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
