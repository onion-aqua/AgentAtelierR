import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/story_clock.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _photoArgs = <String, dynamic>{
  'food_name': '草莓蛋糕',
  'visible_food_description': '照片里有一块铺着草莓的蛋糕',
};
const _atelierArgs = <String, dynamic>{
  'food_name': '森林面包',
  'description': '刚烤好的香草面包',
  'eat_now': false,
};

final _readableImage = ChatAttachment(
  name: 'cake.png',
  mimeType: 'image/png',
  size: 3,
  bytes: Uint8List.fromList([1, 2, 3]),
);

Map<String, dynamic> _tool(
  AppController controller,
  String name,
  Map<String, dynamic> args,
) =>
    jsonDecode(controller.queryContextTool(name, args)) as Map<String, dynamic>;

Future<AppController> _controller({
  bool agent = true,
  bool clock = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final controller = await AppController.load();
  addTearDown(controller.dispose);
  controller.storyClock = StoryClock(satiety: 40);
  if (clock) controller.setStoryClockEnabled(true);
  if (agent) controller.setAgentEnabled(true);
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'photo eating requires a readable image and explicit current invitation',
    () async {
      final controller = await _controller();

      controller.addUserMessage('莱莎，请吃这张图里的蛋糕', imageFoodInvitation: true);
      expect(
        _tool(controller, 'eat_food_from_image', _photoArgs)['ok'],
        isFalse,
      );

      controller.addUserMessage('莱莎，请吃这张图里的蛋糕', attachments: [_readableImage]);
      expect(
        _tool(controller, 'eat_food_from_image', _photoArgs)['ok'],
        isFalse,
      );

      controller.addUserMessage(
        '请描述这张照片',
        attachments: [_readableImage],
        imageFoodInvitation: true,
      );
      expect(
        _tool(controller, 'eat_food_from_image', _photoArgs)['ok'],
        isFalse,
      );

      controller.addUserMessage(
        '莱莎，请吃这张图里的蛋糕',
        attachments: [
          ChatAttachment(
            name: 'unavailable.png',
            mimeType: 'image/png',
            size: 3,
            thumbnailBytes: Uint8List.fromList([1, 2, 3]),
          ),
        ],
        imageFoodInvitation: true,
      );
      expect(
        _tool(controller, 'eat_food_from_image', _photoArgs)['ok'],
        isFalse,
      );
      expect(controller.storyClock.satiety, 40);

      controller.addUserMessage(
        '莱莎，请吃这张图里的蛋糕',
        attachments: [_readableImage],
        imageFoodInvitation: true,
      );
      controller.addUserMessage('这张图片是什么？');
      expect(
        _tool(controller, 'eat_food_from_image', _photoArgs)['ok'],
        isFalse,
      );
      expect(controller.storyClock.satiety, 40);
    },
  );

  test('photo eating grants at most 20 satiety once per user turn', () async {
    final controller = await _controller();
    controller.addUserMessage(
      '莱莎，请吃这张图里的蛋糕',
      attachments: [_readableImage],
      imageFoodInvitation: true,
    );

    expect(
      _tool(controller, 'eat_food_from_image', {
        'food_name': '草莓蛋糕',
        'visible_food_description': '',
      })['ok'],
      isFalse,
    );
    expect(controller.storyClock.satiety, 40);

    final first = _tool(controller, 'eat_food_from_image', _photoArgs);
    expect(first['ok'], isTrue);
    expect(first['satiety_gained'], 20);
    expect(first['satiety'], 60);
    expect(controller.storyClock.satiety, 60);

    expect(_tool(controller, 'eat_food_from_image', _photoArgs)['ok'], isFalse);
    expect(controller.storyClock.satiety, 60);

    controller.addUserMessage(
      '莱莎，请吃这张图里的蛋糕',
      attachments: [_readableImage],
      imageFoodInvitation: true,
    );
    expect(_tool(controller, 'eat_food_from_image', _photoArgs)['ok'], isTrue);
    expect(controller.storyClock.satiety, 80);
  });

  test(
    'Ryza Agent advertises food tools and returns local satiety to the model',
    () async {
      final controller = await _controller();
      controller.addUserMessage(
        '莱莎，请吃这张图里的蛋糕',
        attachments: [_readableImage],
        imageFoodInvitation: true,
      );
      var requests = 0;
      var dispatched = 0;
      final transport = MockClient((request) async {
        requests++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final messages = body['messages'] as List<dynamic>;
        if (requests == 1) {
          final tools = (body['tools'] as List<dynamic>)
              .cast<Map<String, dynamic>>();
          final functions = tools
              .map((tool) => tool['function'] as Map<String, dynamic>)
              .toList();
          expect(
            functions.map((function) => function['name']),
            containsAll(['eat_food_from_image', 'prepare_atelier_food']),
          );
          final photo = functions.firstWhere(
            (function) => function['name'] == 'eat_food_from_image',
          );
          final atelier = functions.firstWhere(
            (function) => function['name'] == 'prepare_atelier_food',
          );
          expect(
            (photo['parameters'] as Map<String, dynamic>)['required'],
            containsAll(['food_name', 'visible_food_description']),
          );
          expect(
            (atelier['parameters'] as Map<String, dynamic>)['required'],
            containsAll(['food_name', 'description', 'eat_now']),
          );
          expect(
            ((messages.last as Map<String, dynamic>)['content']
                    as List<dynamic>)
                .whereType<Map<String, dynamic>>()
                .any((part) => part['type'] == 'image_url'),
            isTrue,
          );
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
                          'id': 'eat_photo',
                          'type': 'function',
                          'function': {
                            'name': 'eat_food_from_image',
                            'arguments': jsonEncode(_photoArgs),
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
        final toolMessage = messages.last as Map<String, dynamic>;
        expect(toolMessage['role'], 'tool');
        expect(toolMessage['tool_call_id'], 'eat_photo');
        final result = jsonDecode(
          toolMessage['content'] as String,
        ) as Map<String, dynamic>;
        expect(result['ok'], isTrue);
        expect(result['satiety_gained'], 20);
        expect(result['satiety'], 60);
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': '莱莎：现在饱食度是${result['satiety']}。',
                  },
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      addTearDown(transport.close);
      final client = OpenAiCompatibleClient(
        client: transport,
        contextToolExecutor: (name, args) async {
          expect(name, 'eat_food_from_image');
          expect(args, _photoArgs);
          dispatched++;
          return controller.queryContextTool(name, args);
        },
      );

      final output = await client
          .streamChat(
            baseUrl: 'https://example.test/v1',
            apiKey: 'test-key',
            model: 'test-model',
            systemPrompt: '你是莱莎',
            messages: controller.messages.toList(),
            agentEnabled: true,
            characterId: 'ryza',
          )
          .join();
      expect(requests, 2);
      expect(dispatched, 1);
      expect(controller.storyClock.satiety, 60);
      expect(output, '莱莎：现在饱食度是60。');
    },
  );

  test('photo and atelier food require Agent and story clock', () async {
    final controller = await _controller(agent: false, clock: false);
    controller.addUserMessage(
      '莱莎，请吃这张图里的蛋糕',
      attachments: [_readableImage],
      imageFoodInvitation: true,
    );
    expect(
      controller.queryContextTool('eat_food_from_image', _photoArgs),
      contains('Agent 已关闭'),
    );
    expect(
      controller.queryContextTool('prepare_atelier_food', _atelierArgs),
      contains('Agent 已关闭'),
    );

    controller.setAgentEnabled(true);
    expect(_tool(controller, 'eat_food_from_image', _photoArgs)['ok'], isFalse);
    expect(
      _tool(controller, 'prepare_atelier_food', _atelierArgs)['ok'],
      isFalse,
    );
    expect(controller.storyClock.satiety, 40);
    expect(controller.alchemyState.inventory, isEmpty);
  });

  test('atelier food is limited to Ryza at the hideout', () async {
    final controller = await _controller();
    controller.selectLocation(
      areaId: 'area_01',
      stageId: 'stage_01_001_04',
      stageName: '莱莎的家',
    );
    expect(
      _tool(controller, 'prepare_atelier_food', _atelierArgs)['ok'],
      isFalse,
    );
    expect(controller.alchemyState.inventory, isEmpty);
  });

  test('Sophie cannot use Ryza food tools', () async {
    SharedPreferences.setMockInitialValues({
      'active_character_id_v1': 'sophie',
    });
    final sophie = await AppController.load();
    addTearDown(sophie.dispose);
    sophie.setAgentEnabled(true);
    sophie.setStoryClockEnabled(true);
    expect(
      sophie.queryContextTool('prepare_atelier_food', _atelierArgs),
      contains('苏菲的对应运行时资源尚未接入'),
    );
    expect(
      sophie.queryContextTool('eat_food_from_image', _photoArgs),
      contains('苏菲的对应运行时资源尚未接入'),
    );
    expect(sophie.alchemyState.inventory, isEmpty);
  });

  test(
    'atelier makes two portions, enforces the day limit across save reload',
    () async {
      final controller = await _controller();
      expect(
        _tool(controller, 'prepare_atelier_food', {
          ..._atelierArgs,
          'eat_now': 'false',
        })['ok'],
        isFalse,
      );
      expect(controller.alchemyState.inventory, isEmpty);
      final made = _tool(controller, 'prepare_atelier_food', _atelierArgs);
      expect(made['ok'], isTrue);
      expect(made['prepared_day'], 1);
      expect(made['satiety_gained'], 0);
      expect(made['satiety'], 40);
      final firstItem = made['item'] as Map<String, dynamic>;
      expect(firstItem['quantity'], 2);
      expect(firstItem['instance_id'], isNotEmpty);
      expect(controller.alchemyState.inventory.single.quantity, 2);

      expect(
        _tool(controller, 'prepare_atelier_food', _atelierArgs)['ok'],
        isFalse,
      );
      expect(controller.alchemyState.inventory.single.quantity, 2);
      await controller.saveToLocalSlot(0);

      final restored = await AppController.load();
      addTearDown(restored.dispose);
      await restored.loadFromLocalSlot(0);
      expect(restored.alchemyState.inventory.single.quantity, 2);
      expect(
        _tool(restored, 'prepare_atelier_food', _atelierArgs)['ok'],
        isFalse,
      );
      expect(restored.alchemyState.inventory.single.quantity, 2);

      final advanced = restored.settleStoryTime('next-day', {
        'time_advance': {'kind': 'time_skip', 'minutes': 1440},
      }, restored.dataRevision);
      expect(advanced, isTrue);
      expect(restored.storyClock.day, 2);

      final nextDay = _tool(restored, 'prepare_atelier_food', {
        'food_name': '野莓派',
        'description': '新鲜野莓烤成的派',
        'eat_now': true,
      });
      expect(nextDay['ok'], isTrue);
      expect(nextDay['prepared_day'], 2);
      expect(nextDay['satiety_gained'], 20);
      expect(nextDay['satiety'], 20);
      expect((nextDay['item'] as Map<String, dynamic>)['quantity'], 1);
      expect(restored.storyClock.satiety, 20);
      expect(
        restored.alchemyState.inventory
            .where((item) => item.customName == '野莓派')
            .single
            .quantity,
        1,
      );
    },
  );
}
